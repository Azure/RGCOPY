# RGCOPY documentation
***
version 0.9.26<BR>December 2021
***
RGCOPY (**R**esource **G**roup **COPY**) is a tool that copies the most important resources of an Azure resource group (**source RG**) to a new resource group (**target RG**). It can copy a whole landscape consisting of many servers within a single Azure resource group to a new resource group. The target RG might be in a different region, subscription or tenant. RGCOPY has been tested on **Windows**, **Linux** and in **Azure Cloud Shell**. It should run on **MacOS**, too.

RGCOPY has been developed for copying an SAP landscape and testing Azure with SAP workload. Therefore, it supports the most important Azure resources needed for SAP, as virtual machines, managed disks and Load Balancers. However, you can use RGCOPY also for other workloads.

> RGCOPY is not an SAP deployment tool. It simply copies Azure resources (VMs, disks, NICs ...).<BR>It does not change anything inside the VMs like changing the server name on OS level or applying SAP license keys.

RGCOPY can change several resource properties in the target RG:
- VM size, disk SKU, disk performance tier, disk caching, Write Accelerator, Accelerated Networking
- Adding, removing and changing Proximity Placement Groups, Availability Sets and Availability Zones.
- Converting disks to NetApp volumes and vice versa (on Linux VMs).
- Converting Ultra SSD disks to Premium SSD disks and vice versa (on Linux VMs).
- Merging single VMs into an existing subnet (target RG already exists)
- Cloning a VM inside a resource group (target RG = source RG)

!["RGCOPY"](/images/RGCOPY.png)

<div style="page-break-after: always"></div>

***
## Installation
- Install **PowerShell** 7.1.2 (or higher)
- Install Azure PowerShell Module **Az** 5.5 (or higher): <BR>`Install-Module -Name Az -Scope AllUsers -AllowClobber`
- Copy `rgcopy.ps1` into the user home directory (~)
- In PowerShell 7, run `Connect-AzAccount` for each subscription and each Azure Account that will be used by RGCOPY. The Azure Account needs privileges for creating the target RG and for creating snapshots in the source RG.

>You can run RGCOPY also in **Azure Cloud Shell**. However, you have to copy the file **`rgcopy.ps1`** into Azure Cloud Drive first. There is no need to install PowerShell or Az module in Azure Cloud Shell. You also do not have to run `Connect-AzAccount` since you are already connected with a Managed System Identity, for example MSI@0815. 

***
## Examples
The following examples show the usage of RGCOPY. In all examples, a source RG with the name 'SAP_master' is copied to the target RG 'SAP_copy'. For better readability, the examples use parameter splatting, see <https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_splatting>. Before starting RGCOPY, you must run the PowerShell cmdlet `Connect-AzAccount`.

Simple Example - using current Az-Context

```powershell
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'
}
.\rgcopy.ps1 @rgcopyParameter
```

Simple Example - specifying Azure account and subscription

```powershell
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    sourceSub       = 'Contoso Subscription'
    sourceSubUser   = 'user@contoso.com'

    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'   }
.\rgcopy.ps1 @rgcopyParameter
```

Different Subscriptions and Azure accounts

```powershell
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    sourceSub       = 'Contoso Subscription'
    sourceSubUser   = 'user@contoso.com'

    targetRG        = 'SAP_copy'
    targetSub       = 'AME Subscription'
    targetSubUser   = 'USER@ame.gbl'
    targetLocation  = 'westus'   }
.\rgcopy.ps1 @rgcopyParameter
```

Changing VM size to Standard_M16ms (for VMs HANA1 and HANA2), Standard_M8ms (for VM SAPAPP) and Standard_D2s_v4 (for all other VMs)
```powershell
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'

    setVmSize = @(
        'Standard_M16ms@HANA1,HANA2',
        'Standard_M8ms@SAPAPP',
        'Standard_D2s_v4'
    )	
}
.\rgcopy.ps1 @rgcopyParameter
```

***
## Supported Azure Resources
RGCOPY uses a list of well-known resources and properties. **All other resources in the source Resource RG are skipped and not copied to the target RG**. This feature was introduced to avoid RGCOPY issues caused by future resource properties.

The following ARM resources are copied from the source RG:
- Microsoft.Compute/virtualMachines
- Microsoft.Compute/disks
- Microsoft.Compute/availabilitySets
- Microsoft.Compute/proximityPlacementGroups
- Microsoft.Network/virtualNetworks
- Microsoft.Network/virtualNetworks/subnets
- Microsoft.Network/networkInterfaces
- Microsoft.Network/publicIPAddresses
- Microsoft.Network/loadBalancers **\***
- Microsoft.Network/loadBalancers/backendAddressPools
- Microsoft.Network/networkSecurityGroups
- Microsoft.Network/bastionHosts
- Microsoft.Network/natGateways
- Microsoft.Network/publicIPPrefixes
- Microsoft.HanaOnAzure/sapMonitors
- Microsoft.HanaOnAzure/sapMonitors/providerInstances

**\* RGCOPY does not support** Microsoft.Network/loadBalancers/**loadBalancerInboundNatRules** yet

In the target RG, the following ARM resources might be deployed in addition:
- Microsoft.Compute/images
- Microsoft.Compute/virtualMachines/extensions
- Microsoft.Storage/storageAccounts
- Microsoft.Storage/storageAccounts/blobServices
- Microsoft.Storage/storageAccounts/fileServices
- Microsoft.Storage/storageAccounts/blobServices/containers
- Microsoft.Network/virtualNetworks/virtualNetworkPeerings 
- Microsoft.NetApp/netAppAccounts
- Microsoft.NetApp/netAppAccounts/capacityPools
- Microsoft.NetApp/netAppAccounts/capacityPools/volumes

**Resources must not refer to resources in other resource groups** with one exception: network interfaces might be connected to a virtual network in another resource group. In this case, RGCOPY creates a provisional virtual network in the target RG. The VMs in the target RG use this provisional network rather than the original network. Herby, you can still copy all VMs but the connection to the original virtual network is lost.

***
## Workflow
The workflow of RGCOPY consists of the following steps. Each step can be skipped separately using an RGCOPY switch parameter.

*RGCOPY step*<BR>**`skip switch`**|usage
:---|:---
*create ARM template*<BR>**`skipArmTemplate`**|This step creates an ARM template (json file) that will used for deploying in the target RG. <BR>The template refers either to the snapshots in the source RG or to BLOBs in the target RG. Therefore, the template is only valid as long as the snapshots and BLOBs exist.<BR>Using various RGCOPY parameters, you can change properties of resources (e.g. VM size) compared with the Source RG. Be aware that some properties are changed to default values even when not explicitly using RGCOPY parameters.
*create snapshots*<BR>**`skipSnapshots`**|This step creates snapshots of disks in the source RG.<BR>If configured, snapshots of Azure NetApp volumes are also created.
*create backups*<BR>**`skipBackups`**|This step is only needed when using (or converting) NetApp volumes on LINUX. A file backup of specified mount points is created on an Azure SMB file share in the source RG.
*create BLOBs*<BR>**`skipBlobs`**|This step is needed when the source RG and the target RG are not in the same region. The snapshots in the source RG are copied as BLOBs into a storage account in the target RG. Dependent on the disk sizes and the region, this might take several hours.
*deployment*<BR>**`skipDeployment`**|The deployment consists of several part steps:<BR><BR>*deploy VMs:* Deploy ARM template in the target RG.<BR>Part step can be skipped by **`skipDeploymentVMs`**<BR><BR>*restore backups:* Restore file backup on disks or NetApp volumes in the target RG if needed.<BR> Part step can be skipped by **`skipRestore`**<BR><BR>*deploy AMS:* Deploy Azure Monitor for SAP if exists in source RG.<BR>Part step can be skipped by **`skipDeploymentAms`**<BR><BR>*install VM Extensions*: install VM extensions if explicitly configured using RGCOPY parameters.<BR>Part step can be skipped by **`skipExtensions`**

There is an additional, hidden step: *Workload and Analysis*. This step has to be explicitly activated using switch **`startWorkload`**. 

### Application consistency
>Snapshots of disks are made independently. However, database files could be distributed over several data disks. Using these snapshots for creating a VM could result in inconsistencies and database corruptions in the target RG. Therefore, RGCOPY cannot copy VMs with more than one data disk while the source VM is running. However, RGCOPY does work with running VMs that have only a single data disk (and no NetApp volume) or a single NetApp volume (and no data disk).

In the unlikely case that database files are distributed over the data disk (or volume) and the OS disk, you must stop the VM before starting RGCOPY. RGCOPY does not (and cannot) double check this unlikely case.

>When using NetApp volumes, RGCOPY does not know which volume belongs to which VM. Therefore, you must specify the volume snapshots using RGCOPY parameter **`snapshotVolumes`**. Not doing so results in using an outdated snapshot and inconsistent VM in the target RG.

>RGCOPY can convert a managed disk in the source RG to a NetApp volume in the target RG (and vice versa) by changing mount points. Herby, a file backup is made from the mount points in the source RG. A mount point is either a disk or a NetApp volume.<BR>Before starting the backup/restore, RGCOPY double checks that there is no open file in the mount point directory. However, it does not check this *during* backup/restore. Therefore, you must you must make sure that no LINUX service or job that changes files in the mount point directories is started during backup/restore.

### Changes in the source RG
- RGCOPY creates snapshots of all disks in the source RG with the name **\<diskname>.rgcopy**.
- If RGCOPY parameter `snapshotVolumes` is supplied, then snapshots of NetApp volumes with the name **rgcopy** are created.
- If RGCOPY parameter `createVolumes` or `createDisks` is supplied, then a **storage account** with a premium SMB share is created in the source RG. **All VMs are started in the source RG**. In configured VMs, the SMB share **/mnt/rgcopy** is mounted, the service **sapinit** is stopped and process **hdbrsutil** is killed.
- If RGCOPY parameter `pathPreSnapshotScript` is supplied, then the specified PowerShell script is executed before creating the snapshots. In this case, all VMs are started, SAP is started, the PowerShell script (located on the local PC) is executed and finally **all VMs are stopped in the source RG**

### Created files
RGCOPY creates the following files in the user home directory (or in the directory which has been set using RGCOPY parameter `pathExportFolder`) on the PC where RGCOPY is running:

file|*[DataType]*: usage
:---|:---
`rgcopy.<source_RG>.SOURCE.json`|Exported ARM template from the source RG.
`rgcopy.<target_RG>.TARGET.json`|ARM template which is generated by RGCOPY<BR>for deploying in the target RG.
`rgcopy.<target_RG>.AMS.json`|ARM template for Azure Monitoring for SAP (AMS).<BR>It will only be created if the source RG contains an AMS Instance.
`rgcopy.<target_RG>.TARGET.log`|RGCOPY log file.
`rgcopy.txt`|Backup of the running script rgcopy.ps1 used for support
`rgcopy.<target_RG>.<time>.zip`| Compressed ZIP file that contains all files above
`rgcopy.<target_RG>.TEMP.json`| temporary file
`rgcopy.<target_RG>.TEMP.txt`| temporary file

### Required Azure Permissions
RGCOPY can be executed using any Azure Security Principal (Azure User, Service Principal or Managed Identity). You can use Azure role-based access control for assigning the role subscription `Owner` or `Contributor` to the Security Principal. However, you could use more restrictive roles for running RGCOPY. In brief, RGCOPY typically needs permissions for the following resource groups:
1. Source RG: read permission and permission to create snapshots
2. Target RG: all permissions on the target RG
3. Some subscription level read permissions and the permission to create a new resource group

In detail, RGCOPY needs the permissions to execute the following cmdlets:

Resource Group| PowerShell cmdlet
:---|:---
Source RG | Export-AzResourceGroup<BR>Get-AzVM<BR>Get-AzDisk<BR>Get-AzNetAppFilesVolume<BR>New-AzNetAppFilesSnapshot<BR>Remove-AzNetAppFilesSnapshot<BR>Stop-AzVM<BR>Start-AzVM<BR>Get-AzStorageAccount<BR>New-AzStorageAccount<BR>Get-AzRmStorageShare<BR>New-AzRmStorageShare<BR>New-AzSnapshot<BR>Remove-AzSnapshot<BR>New-AzSnapshotConfig<BR>Grant-AzSnapshotAccess<BR>Grant-AzDiskAccess<BR>Revoke-AzSnapshotAccess<BR>Revoke-AzDiskAccess<BR>Get-AzStorageAccountKey<BR>Invoke-AzVMRunCommand
Target RG | Get-AzVM<BR>Get-AzDisk<BR>Get-AzNetAppFilesVolume<BR>New-AzStorageContext<BR>Get-AzStorageBlob<BR>Get-AzStorageBlobCopyState<BR>Start-AzStorageBlobCopy<BR>Stop-AzStorageBlobCopy<BR>Stop-AzVM<BR>Get-AzStorageAccount<BR>New-AzStorageAccount<BR>Get-AzRmStorageContainer<BR>New-AzRmStorageContainer<BR>Get-AzStorageAccountKey<BR>New-AzSapMonitor<BR>New-AzSapMonitorProviderInstance<BR>Set-AzVMAEMExtension<BR>Invoke-AzVMRunCommand
Target RG<BR>when using parameter<BR>`setVmMerge` | Get-AzAvailabilitySet<BR>Get-AzProximityPlacementGroup<BR>Get-AzNetworkInterface<BR>Get-AzPublicIpAddress<BR>Get-AzVirtualNetwork
Other RGs<BR>when using other special<BR>RGCOPY parameters | Get-AzOperationalInsightsWorkspace<BR>Get-AzOperationalInsightsWorkspaceSharedKey<BR>Get-AzNetAppFilesVolume<BR>New-AzNetAppFilesSnapshot<BR>Remove-AzNetAppFilesSnapshot<BR>Get-AzRmStorageContainer
RG independent | Get-AzSubscription<BR>Get-AzResourceGroup<BR>New-AzResourceGroup<BR>Get-AzVMUsage<BR>Get-AzComputeResourceSku<BR>Get-AzProviderFeature<BR>Get-AzLocation<BR>New-AzResourceGroupDeployment

If you do not want to assign permissions for `New-AzResourceGroup` then you can create the target RG before starting RGCOPY. RGCOPY can deploy into an existing target RG.

***
## Parameters

### Resource Group Parameters
The first 3 parameters in the following list are mandatory for RGCOPY:

parameter|[DataType]: usage
:---|:---
**`sourceRG`**			|**[string]**: name of the source resource group
**`targetRG`**			|**[string]**: name of the target resource group<BR>Source and target resource group must not be identical unless you use parameter `setVmMerge` as described below.<BR>The target resource group might already exist. However, it should not contain resources. For safety reasons, RGCOPY does not allow using a target resource group that already contains disks (unless you set switch parameter `skipDiskChecks`).
**`targetLocation`**	|**[string]**: *location name* of the Azure region for the target RG, for example 'eastus'.<BR>Do **not** use the *display name* ('East US') instead.
**`targetSA`**\*         |**[string]**: name of the storage account that will be created in the target RG for storing BLOBs.
**`sourceSA`**\*         |**[string]**: name of the storage account that will be created in the source RG for storing file backups. This storage account is only created when parameter **`createVolumes`** or **`createDisks`** is set.

 \* You normally do not need these two parameters because RGCOPY is calculating the storage account name based on the name of the resource group. However, this could result in deployment errors because the storage account name must be unique in whole Azure (not only in the current subscription). Once you run into this issue, repeat RGCOPY and set the parameter to a unique name.


### Azure Connection Parameters
RGCOPY is using the current Azure Context (account and subscription) when no Azure Connection Parameter is provided. PowerShell cashes the password of the Azure account inside the Azure Context for several hours. Therefore, you do not need to provide a password to RGCOPY. Simply run the following cmdlet just before RGCOPY:<BR>**`Connect-AzAccount -Subscription 'Subscription Name'`**<BR>The cmdlet opens the default browser and you can enter account name and password.



RGCOPY can use two different Azure accounts for connecting to the source RG and the target RG. In this case, you must run `Connect-AzAccount` for both accounts before starting RGCOPY. Furthermore, you must provide the RGCOPY connection parameters as described below. Hereby, RGCOPY knows which account has to be used for which resource group.

PowerShell caches the Azure context only for a few hours. Once it is expired, you must run `Connect-AzAccount` again.

!["RGCOPY"](/images/failedAzAccount.png)

>You should run `Connect-AzAccount` immediately before starting a copy to a different region (which might take several hours) because the cached credentials might expire during the runtime of RGCOPY.<BR>Once this happens, yo do not need to start RGCOPY from scratch. There is an RGCOPY parameter that allows resuming in this particular case. See section 'Parameters for BLOB Copy' below.

You can also use an Azure Managed System Identity (MSI) for running RGCOPY. Therefore, you have to create a VM (or container) with an MSI. Once you have assigned the required roles to the MSI and installed PowerShell and the Az module in the VM, you can run RGCOPY inside the VM. In this case, you must run the following command:<BR>`Connect-AzAccount `**`-Identity`**` -Subscription 'Subscription Name'`.<BR>After that, you can start RGCOPY without an RGCOPY Azure Connection Parameter.

Powershell cashes several Azure Contexts. `Get-AzContext -ListAvailable` shows all cached contexts. `Get-AzContext` shows the current context. When providing the below RGCOPY parameters then RGCOPY uses `Set-AzContext` for setting the current Azure Context. To be on the save side, you should always provide RGCOPY parameters `sourceSub` and `sourceSubUser`.

parameter|[DataType]: usage
:---|:---
**`sourceSub`**			|**[string]**: *name* of source subscription. Do **not** use the *subscription id* instead.
**`sourceSubUser`**		|**[string]**: Azure account name (user, service principal or MSI) for source subscription.<BR>The account name for an MSI looks like this: `MSI@0815`. You can get the current account name by running `Get-AzContext`
**`sourceSubTenant`**	|**[string]**: Azure tenant id for source subscription.<BR>*This parameter is only needed if the user context is ambiguous without the tenant.*
**`targetSub`**			|**[string]**: *name* of target subscription. Do **not** use the *subscription id* instead.<BR>*Not needed if source and target subscription are identical.*
**`targetSubUser`**		|**[string]**: Azure account name (user or service principal) for target subscription.<BR>*Not needed if the accounts for source and target RG are identical.*
**`targetSubTenant`**	|**[string]**: Azure tenant id for target subscription.<BR>*This parameter is only needed if the user context is ambiguous without the tenant.*<BR>*Not needed if the accounts for source and target RG are identical.*

### Path of RGCOPY files
`pathExportFolder` is the default path for RGCOPY output files. The other parameters are full file paths of RGCOPY input files:

parameter|[DataType]: usage
:---|:---
**`pathExportFolder`**<BR>|**[string]**: By default, RGCOPY creates all files in the user home directory. You can change the path for all RGCOPY files by setting parameter `pathExportFolder`.
**`pathArmTemplate`**|**[string]**: You can deploy an existing (main) ARM template by setting this parameter. No snapshots are created, no ARM template is created and no resource configuration changes are possible.<BR><BR>Caution: *Only* ARM templates that were created by RGCOPY can be used here because the ARM template parameter `storageAccountName` is required.
**`pathArmTemplateAms`**|**[string]**: You can provide an existing ARM template for deploying the AMS instance and providers. <BR><BR>Caution: *Only* ARM templates that were created by RGCOPY can be used here because the ARM template parameter `amsInstanceName` is required.

### Resource Configuration Parameters
With resource configuration parameters you can change properties of various resources in the Target ARM template.

Each of the configuration parameters has the following scheme:

```powershell
     [string] $parameter     = "$rule1"
or   [array]  $parameter     = @("$rule1","$rule2", ...)

with [string] $rule          = "$configuration@$resources"
     [string] $resources     = "$resourceName1,$resourceName2, ..."
     [string] $configuration = "$part1/$part2/$part3"
```

A resource configuration parameter is an array of strings. Each string represents a rule. Each rule has the form configuration@resources. Resources are separated by commas (,). A configuration might consist of up-to 3 parts separated by a slash (/).

Let's explain this for the parameter `setVmSize` which changes the size of VMs. In the examples, hana1 and hana2 are Azure resource names of virtual machines:

setVmSize parameter value|result
:---|:---
`@("Standard_E32s_v3@hana1")`	|changes the VM size of one VM (hana1) to Standard_E32s_v3
`"Standard_E32s_v3@hana1"`		|same as above but using a PowerShell string rather than an array
`'Standard_E32s_v3@hana1'`		|same as above but using single quotes
`'Standard_E32s_v3'`			|changes the VM size of *all* VMs to Standard_E32s_v3
`"Standard_E32s_v3@hana1,hana2"`|changes the VM size of 2 VMs (hana1 and hana2) to Standard_E32s_v3 (using one rule)
`@("Standard_E32s_v3@hana1", "Standard_E16s_v3@hana2")`	|changes the VM size for 2 VMs separately: Standard_E32s_v3 for hana1 and Standard_E16s_v3 for hana2 (using 2 rules - therefore data type array is needed)
`@("Standard_E16s_v3@hana2", "Standard_E32s_v3")`		|changes the VM size of hana2 to Standard_E16s_v3 and of *all other* VMs to Standard_E32s_v3. This is an example where 2 rules fit for one resource (hana2). In this case, the first rule wins.

The following resource configuration parameters exist:

parameter|usage (data type is always [string] or [array])
:---|:---
**`setVmSize`** =<BR>`@("size@vm1,vm2,...", ...)`	|Set VM Size: <BR>**size**: VM size (e.g. Standard_E32s_v3) <BR>**vm**: VM name
**`setDiskSize`** = <BR>`@("size@disk1,disk1,...", ...)`			|Set Disk Size: <BR>**size** in GB <BR>**disk**: disk name<BR>It's only possible to *increase* the size of a disk. Partitions on the disk are not changed. This parameter was originally intended for increasing disk I/O on the target RG. Nowadays, you better should use parameter `setDiskTier` instead.
**`setDiskTier`** = <BR>`@("tier@disk1,disk1,...", ...)`			|Set Disk Performance Tier:<BR>**tier** in {P0, P1, ..., P80} <BR>**disk**: disk name<BR>To remove existing  performance tier configuration, set tier to P0.
**`setDiskCaching`** = <BR>`@("caching/wa@disk1,disk2...", ...)`	|Set Disk Caching: <BR>**caching** in {ReadOnly, ReadWrite, None} <BR>**wa (writeAccelerator)** in {True, False} <BR>**disk**: disk name<BR><BR>Examples:<BR>`'None/False'`: turns off caching and writeAccelerator for all disks<BR>`'/False'`: turns off writeAccelerator for all disks (but keeps caching property)<BR>`@('ReadOnly/True@disk1', '/False')`: turns on writeAccelerator for disk1 and turns it off for all other disks in the resource group
**`setDiskSku`** =<BR>`@("sku@disk1,disk2,...", ...)`			|Set Disk SKU: <BR>**sku** in {Premium_LRS, StandardSSD_LRS, Standard_LRS} <BR>**disk**: disk name
**`setVmDeploymentOrder`** = <BR>`@("prio@vm1,vm2,...", ...)`				|Set VM deployment Order: <BR>**prio** -in {1, 2, 3, ...}  <BR>**vm**: VM name <BR>This parameter is used during ARM template creation. You can define priories for deploying VMs. A VM with higher priority (lower number) will be deployed before VMs with lower priority. Hereby, you can ensure that an important VM (for example a domain controller) will be deployed before other VMs.
**`setLoadBalancerSku`** = <BR>`@("sku@lb1,lb2,...", ...)`	|Set Load Balancer SKU: <BR>**sku** in {Basic, Standard}<BR>**lb (loadBalancer)**: Load Balancer name.
**`setPublicIpSku`** = <BR>`@("sku@ip1,ip2,...", ...)`		|Set Public IP SKU: <BR>**sku** in {Basic, Standard} <BR>**ip**: name of Public IP Address.
**`setPublicIpAlloc`** = <BR>`@("allocation@ip1,ip2,...", ...)`		|Set Public IP Allocation Method: <BR>**allocation** in {Dynamic, Static}<BR>**ip**: name of Public IP Address.
**`setPrivateIpAlloc`** = <BR>`@("allocation@ip1,ip2,...", ...)`		|Set Private IP Allocation Method: <BR>**allocation** in {Dynamic, Static}<BR>**ip**: name of Private IP Address.
**`removeFQDN`** = <BR>`@("bool@ip1,ip2,...", ...)`		|Remove Fully Qualified Domain Names: <BR>**bool** in {True} <BR>**ip**: name of Public IP Address.
**`setAcceleratedNetworking`** = <BR>`@("bool@nic1,nic2,...", ...)`		|Set Accelerated Networking: <BR>**bool** in {True, False} <BR>**nic**: name of Virtual Network Interface.
**`createVolumes`**<BR>**`createDisks`**<BR>**`snapshotVolumes`**|see section NetApp volumes below




### Default values
There are lots of dependencies between Azure resource configurations. For example, when changing form M-series to other VM sizes, you must turn off Write Accelerator. Therefore, RGCOPY uses default parameter values to avoid deployment failures. If you do not want the default behavior, then you must explicitly set the parameters to a different value. RGCOPY uses the following default values for resource configuration parameters:

parameter|default value|default behavior
:---|:---:|:---
**`setDiskSku`**        |@('Premium_LRS')    |converts all disks to Premium SSD<BR>(except Ultra SSD disks - they cannot be copied directly) 
**`setVmZone`**         |@('0')             |removes zone configuration from VMs
**`setLoadBalancerSku`**|@('Standard')      |sets SKU of Load Balancers to Standard
**`setPublicIpSku`**    |@('Standard')      |sets SKU of Public IP Addresses to Standard
**`setPublicIpAlloc`**  |@('Static')        |sets allocation of Public IP Addresses to Static
**`setPrivateIpAlloc`** |@('Static')        |sets allocation of Private IP Addresses to Static
**`removeFQDN`**        |@('True')          |removes Full Qualified Domain Name from public IP addresses
**`setAcceleratedNetworking`**|@('True')   |enables Accelerated Networking

### Parameters for skipping resources

parameter|[DataType]: usage
:---|:---
**`skipVMs`**|**[array] of VM names**: These VMs and their disks are not copied by RGCOPY.<BR>NICs that are bound only to these VMs and Public IP Addresses are skipped, too. However, NICs that are also bound to Load Balancers are still copied.
**`skipDisks`**|**[array] of disk names**: These disks are not copied by RGCOPY.<BR>Take care with this parameter. Starting their VMs could fail in the target RG. See section NetApp Volumes for details and solution.
**`skipSecurityRules`**|**[array] of name patterns**: default value: `@('SecurityCenter-JITRule*')`<BR>Skips all security rules that name matches any element of the array.<BR>By default, only Just-in-Time security rules are skipped (This is needed to avoid permanently opend ports in the target RG). All other security rules are copied.
**`keepTags`**|**[array] of name patterns**: default value: `@('rgcopy*')`<BR>Skips all Azure resource tags except the ones that name matches any element of the array.<BR>By default, only Azure resource tags with a name starting with 'rgcopy' are copied. By setting parameter `keepTags` to `@('*')`, all Azure resource tags are copied.
**`skipAms`**|**[switch]**: do not copy Azure Monitoring for SAP from source RG
**`skipBastion`**|**[switch]**: do not copy Azure Bastion from source RG
**`skipBootDiagnostics`**|**[switch]**: do not create VM Boot Diagnostics in the storage account of the target RG
**`skipAvailabilitySet`**<BR>**`skipProximityPlacementGroup`**|see below


### Parameters for Availability
RGCOPY can change Availability Zones, Availability Sets and Proximity Placement Groups in the target RG. It does not touch the source RG configuration.


parameter|[DataType]: usage
:---|:---
**`setVmZone`** = <BR>`@("zone@vm1,vm2,...", ...)`			|Set Azure Availability Zone: <BR>**zone** in {0, 1, 2, 3} <BR>**vm**: VM name <BR> The default value is 0 which removes the Availability Zone configuration from all VMs in the target RG.
**`skipAvailabilitySet`**|**[switch]**: do not copy existing Availability Sets. <BR>Hereby, the target RG does not contain any Availability Set.
**`skipProximityPlacementGroup`**|**[switch]**: do not copy existing Proximity Placement Groups. <BR>Hereby, the target RG does not contain any Proximity Placement Group.
**`createAvailabilitySet`** = <BR>`@("avset/fault/update@vm1,vm2,...", ...)`			|Create Azure Availability Set for given VMs: <BR>**avset**: Availability Set Name <BR>**fault**: Fault domain count<BR>**update**: Update domain count<BR>**vm**: VM name <BR>When you are using this parameter for creating new Availability Sets then all existing Availability Sets *and* Proximity Placement Groups are removed first.
**`createProximityPlacementGroup`** = <BR>`@("ppg@res1,res2,...", ...)`			|Create Azure Proximity Placement Group for given VMs or Availability Sets: <BR>**ppg**: Proximity Placement Group Name <BR>**res**: resource name (either VM or Availability Set) <BR>When you are using this parameter for creating new Proximity Placement Groups then all existing Proximity Placement Groups *and* Availability Sets are removed first.<BR><BR>Caution: You might use the same name for a VM and an Availability Set and add this name as resource name to this parameter. In this case, the VM as well as the Availability Set will be added to the Proximity Placement Group.

In Azure you cannot directly configure the Availability Zone for an Availability Set. However, you can indirectly pin an Availability Set to an Availability Zone. The trick is to deploy an additional VM that is in the Availability Zone. If this VM and the Availability Set are in the same Proximity Placement Group then they are also in the same Availability Zone. However, this only works if the VM is deployed first. If you deploy the Availability Set first then it might be deployed in a different Availability Zone. Afterwards, the deployment of the VM fails because the requirements for Availability Zone and Proximity Placement Group cannot be fulfilled at the same time. Luckily, you can define the deployment order in RGCOPY:

```powershell
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'

    setVmZone = @(
        '1@hana1,ascs1',
        '2@hana2,ascs2')
    
    createAvailabilitySet = @(
        'avset1/2/5@app1a,app1b', 
        'avset2/2/5@app2a,app2b')
    
    createProximityPlacementGroup = @(
        'ppg1@ascs1,avset1',
        'ppg2@ascs2,avset2')
        
    setVmDeploymentOrder = @('1@ascs1,ascs2')
}
.\rgcopy.ps1 @rgcopyParameter
```

> RGCOPY ensures in this example that the VMs 'ascs1' and 'ascs2' are deployed before all other VMs. After stopping all VMs, the VMs in the Availability Sets are not bound to a Availability Zone anymore. Therefore, you have to take care on your own that 'ascs1' and 'ascs2' are always started before the other VMs in their Availability Sets.

### Merging and Cloning VMs
Normally, RGCOPY is used for copying all resources of a source RG into a new (or empty) target RG. By using parameter `setVmMerge` you can copy discrete VMs and attach them to an existing subnet in the target RG. You can use this to copy a standard VM (e.g. jump box) into several other resource groups.
By using parameter `setVmName`, you can rename the VMs in the target RG. Herby, you can copy a VM even in the source RG (source RG = target RG). The VM disks are automatically renamed. You might use this for cloning application servers. Be aware that parameter `setVmName` does not rename the VM on OS level.

parameter|[DataType]: usage
:---|:---
**`setVmMerge`**= <BR>`@("net/subnet@vm1,vm2", ...)`|**[string] or [array]**: Merge VMs of the source RG into an existing subnet of the target RG:<BR>**vm**: VM name in source RG<BR>**net**: vnet name in target RG<BR>**subnet**: subnet name in target RG<BR>When setting this parameter, *only* the specified VMs and their disks are copied. The disks are automatically renamed. A new network interface using a dynamic IP address (IPv4) is created and attached to the existing subnet (in the target RG). A new public IP address is created if any network interface of the VM in the source system has a public IP address.
**`setVmName`**	= <BR>`@("vmNameNew@vmNameOld", ...)`			|Rename VM: <BR>**vmNameOld**: VM name in source RG <BR>**vmNameNew**: VM name in target RG <BR>This renames the Azure *resource* name of the copied VM in the target RG. It does not touch the original VM. RGCOPY does not rename the *host* name of the VM. You have to do this on OS level inside the VM after the VM has been copied.<BR>You can use this parameter also independent from `setVmMerge`.
**`renameDisks`**|**[switch]**: Renames all disks of all VMs with the following naming convention:<BR>- OS disk: `<vmName>__disk_os`<BR>- Data disks: `<vmName>__disk_lun_<lunNumber>`<BR>This parameter is automatically set when using parameter `setVmMerge`. However, you can set this parameter also independent from `setVmMerge`.
**`setVmZone`**<BR>**`createAvailabilitySet`**<BR>**`createProximityPlacementGroup`**| These parameters are described above. They can also be used in combination with `setVmMerge`. However, they work differently in this case:<BR>No *new* Availability Set or Proximity Placement Group is created. Instead, they already have to exist in the target RG.

The following example clones the VM 'app1' to 'app2' and puts the new VM app2 into the existing availability set 'avset1'.
In this example, the source RG and the target RG are identical. Keep in mind that this does not change the OS name of 'app2'. This has to be done after RGCOPY has created the azure resource 'app2':

```powershell
$rgcopyParameter = @{
    sourceRG               = 'SAP_master'
    targetRG               = 'SAP_master'
    targetLocation         = 'westus'

    setVmMerge             = 'vnet/subnet@app1'
    setVmName              = 'app2@app1'
    createAvailabilitySet  = 'avset1/3/5@app1'
}
.\rgcopy.ps1 @rgcopyParameter
```

### Parameters for BLOB Copy
When the source RG and the target RG are in different regions (or tenants) then RGCOPY cannot use snapshots for creating the disks. In this case, the workflow looks like this:
1. create snapshots in the source RG
2. create access tokens on these snapshots
3. start asynchronously copying the snapshots as BLOBs to a storage account on the target RG
4. wait for finish of copy process
5. delete access tokens
7. deploy ARM template (that references the BLOBs rather than snapshots)

!["waitBlobsTimeSec"](/images/Copy_Status.png)

>You should run `Connect-AzAccount` immediately before starting a copy to a different region (which might take several hours) because the cached credentials might expire during the runtime of RGCOPY.

You can change the BLOB copy behavior using the following parameters:

parameter|[DataType]: usage
:---|:---
**`useBlobs`**         |**[switch]**: Always create BLOBs (for testing), even in the same region and tenant.<BR>Using BLOBs is much slower compared with using snapshots in the same region. Therefore, this parameter is only useful for testing RGCOPY.
**`useBlobsFromDisk`** |**[switch]**: Always create BLOBs from disks (rather than using snapshots from disks).<BR>This is useful when you want to copy a resource group where you have no privileges for creating snapshots. However, this only works if all VMs in the source RG are deallocated.
**`grantTokenTimeSec`**|**[int]**: Time in seconds, default value: `3*24*3600`<BR>Before copying the BLOBs, access tokens are generated for the snapshots (or disks). These access tokens expire after 3 days. If the BLOB copy takes longer, then it fails. You can define a longer token life time using this parameter (before starting the BLOB copy).
**`waitBlobsTimeSec`**|**[int]**: Time in seconds, default value: `5*60`<BR>Since the copy process can take hours, the progress is displayed every 5 minutes by RGCOPY. This time interval can be changed using this parameter.
**`restartBlobs`**|**[switch]**: If RGCOPY fails while the BLOB copy process is still running asynchronously then you can restart RGCOPY using the same parameters plus the *additional* switch parameter `restartBlobs`. In this case, the BLOB copy process is not interrupted. You do not have to start copying from the very beginning.<BR>This is useful when your local PC rebooted while RGCOPY was running or when your cached credentials expired. However, this does not work when snapshot access tokens have expired.



If the BLOBs already exist in the target region, then you can use them by setting the following parameters:

parameter|[DataType]: usage
:---|:---
**`blobsRG`**			|**[string]**: resource group where the BLOBs are located
**`blobsSA`**			|**[string]**: storage account where the BLOBs are located
**`blobsSaContainer`**	|**[string]**: folder in storage account where the BLOBs are located
**`skipBlobs`**         |**[switch]**: required for the other 3 parameters above

The BLOBs might exists partly in the target region because the BLOB copy failed just for one or a few disks. In this case, you can use the following parameters:

parameter|[DataType]: usage
:---|:---
**`justCopyBlobs`** |**[array] of disk names**: When set, only these disks are copied to BLOBs in the target RG. <BR>Nothing else is done (no snapshots, no deployment).<BR>Use the disk names, not the snapshot names for this parameter.
**`justStopCopyBlobs`** |**[switch]**: when set, the currently running BLOB copy is being terminated.<BR>Nothing else is done (no snapshots, no deployment).



### VM extensions
You can install several VM extensions. You can skip the installation of all extensions by using RGCOPY switch parameter `skipExtensions`.

parameter|[DataType]: usage
:---|:---
**`installExtensionsAzureMonitor`** |**[array]**: Names of VMs for deploying the Azure Agents<BR>(AzureMonitorWindowsAgent or AzureMonitorLinuxAgent).<BR>The Azure Agent is intalled on all VMs when setting the parameter to `@('*')`
**`installExtensionsSapMonitor`** |**[array]**: Names of VMs for deploying the SAP Monitor Extension.<BR>See below in section *SAP specific tasks*


### Other Parameters

parameter|[DataType]: usage
:---|:---
**`skipVmChecks`**| **[switch]**: Do not perform VM consistency checks<BR>By default (if switch is not set), RGCOPY performs several checks before deploying a VM:<BR>- Support of premium disks<BR>- Maximum number of disks per VM<BR>- Maximum number of write-accelerated disks per VM<BR>- Maximum number of NICs per VM<BR>- Support of Accelerated Networking
**`skipDiskChecks`**| **[switch]**: Do not check whether the target resource group already contains disks.<BR>For safety reasons, RGCOPY does not allow deploying into a resource group containing disks unless you set this parameter.
**`copyDetachedDisks`** |**[switch]**: By default, only disks that are attached to a VM are copied to the target RG. By setting this switch, also detached disks are copied.
**`stopVMs`** |**[switch]**: When setting this switch, RGCOPY stops all VMs in the target RG after deploying it. This is normally not intended but might be useful for saving costs.
**`maxDOP`**               |**[int]**: RGCOPY performs the following operations in parallel:<BR>- snapshot creation<BR>- access token creation<BR>- access token deletion<BR>- snapshot deletion<BR>- VM start<BR>- VM stop<BR>By default, RGCOPY uses 16 parallel running threads for these tasks. You can change this using parameter `maxDOP`.
**`jumpboxName`**          |**[string]**: When setting a jumpboxName, RGCOPY adds a Full Qualified Domain Name (FQDN) to the Public IP Address of the jumpbox. The FQDN is calculated from the name of the target RG. <BR><BR>For example, `targetRG`=*test_resource_group* and `targetLocation`=*eastus*<BR>results in FQDN: *test-resource-group.eastus.cloudapp.azure.com*. <BR>RGCOPY uses the first Public IP Address of the first VM which fits the search for `*jumpboxName*`
**`justCreateSnapshots`**  |**[switch]**: When setting this switch, RGCOPY only creates snapshots on the source RG (no ARM template creation, no deployment). This is useful for refreshing the snapshots for an existing ARM template.
**`justDeleteSnapshots`**  |**[switch]**: When setting this switch, RGCOPY only deletes snapshots on the source RG (no ARM template creation, no deployment). <BR>Caution: you typically want to keep the existing snapshots since ARM templates within the same region refer to these snapshots.

***
## NetApp Volumes and Ultra SSD Disks

In Azure, you cannot create a snapshot from an Ultra SSD Disk. You cannot export the snapshot of a NetApp volume to a BLOB or restore it in another region. Therefore, RGCOPY cannot directly copy Ultra SSD disks or NetApp volumes. However, RGCOPY supports Ultra SSD disks and NetApp volumes on LINUX using file copy (rather than disk or volume copy). Herby, the following scenarios are possible:

source RG|target RG|procedure
:---|:---|:---
Disks|NetApp volumes NFSv4.1|skip disks and create new volumes
NetApp volumes|Premium SSD disks|create new Premium SSD disks
NetApp volumes|NetApp volumes NFSv4.1|create new volumes
Ultra SSD disks|Premium SSD disks|skip Ultra SSD disks and create new Premium SSD disks
Disks|Ultra SSD disks|skip disks and create new Ultra SSD disks
Ultra SSD disks|Ultra SSD disks|skip Ultra SSD disks and create new Ultra SSD disks

> Unlike other RGCOPY features, NetApp Volumes and Ultra SSD Disks require running code inside the source RG and the target RG. **Therefore, the stability of this feature depends on the OS and other running software inside the VMs.** This feature has been tested with SUSE Linux Enterprise Server and SAP workload. Using this feature is on your own risk. To be on the save side, you should use database backup and restore rather than converting the database disks using RGCOPY.

For the source RG, RGCOPY must know the mount points inside the VMs for all disks and volumes. Hereby, RGCOPY can backup all files that are stored in these mount points to an SMB share in the source RG. In the target RG, new disks or volumes are created for these mount points. After that, RGCOPY restores the files from the SMB share to the mount points in the target RG.

The following requirements must be met in the source RG:
- The VMs must run on Linux: This feature has only been tested on **SUSE** Linux Enterprise Server.
- Disks might be added or removed. Therefore, you must set the option `nofail` for all disks in **`/etc/fstab`**. Furthermore, device names `/dev/sd*` are not allowed here. You must either use UUIDs (Universally Unique Identifiers) or the Azure specific device names `/dev/disk/azure/scsi1/lun*-part*`
- Linux jobs or **services** that access files in the specified mount points **must not start automatically**. This could cause trouble during file backup and restore. However, RGCOPY takes care of SAP HANA by stopping `sapinit` and killing the process `hdbrsutil`. RGCOPY further double checks that there is no open file in the mount point before starting the file backup or restore.

In addition, the following is required when using NetApp volumes:
- The NFSv4 domain name must be set to `defaultv4iddomain.com` in **`/etc/idmapd.conf`**. This is described in https://docs.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-configure-nfsv41-domain
- The **snapShot directory** of NetApp volumes must be visible inside the VMs.
- The source RG **must already contain a subnet** for `Microsoft.Netapp/volumes` delegation.

The following RGCOPY parameters are available:

parameter|[DataType]: usage
:---|:---
**`createVolumes`** = <BR>`@("size@,mp1,mp2,...", ...)`			|Create new NetApp volumes in the target RG<BR>**size**: volume size in GB <BR>**mp**: mount point `/<server>/<path>` (e.g. /dbserver/hana/shared)
**`createDisks`** = <BR>`@("size@,mp1,mp2,...", ...)`<BR>`@("size/iops/mbps@mp1,mp2,...", ...)`|Create new disks in the target RG<BR>**size**: disk size in GB<BR>**iops**: I/Os per second: only needed and allowed for Ultra SSD disks<BR>**mbps**: megabytes per second: only needed and allowed for Ultra SSD disks<BR>**mp**: mount point `/<server>/<path>` (e.g. /dbserver/hana/shared)
**`snapshotVolumes`** = <BR>`@("account/pool@vol1,vol2...", ...)`<BR>`@("rg/account/pool@vol1,vol2...", ...)`			|Create NetApp volume snapshots in the source RG<BR>**rg**: resource group name that contains the NetApp account (optional)<BR>**account**: NetApp account name<BR>**pool**: NetApp pool name<BR>**vol**: NetApp volume name<BR>rg is optional. Default value is `sourceRG`


You can use these parameters for the following scenarios:

#### Copying NetApp volumes
The NetApp volumes used in the source RG can be located in any NetApp account and capacity pool. You might use different NetApp accounts in different resource groups. In the target RG, RGCOPY creates a single NetApp account with a single capacity pool that contains all volumes for the target RG. The size of the volumes in the target RG does not need to be the same as in the source RG.<BR>When copying a NetApp volume, you must use two RGCOPY parameters:
- **`snapshotVolumes`** = `@(`**`"rg/account/pool@vol1,vol2..."`**`, ...)`<BR>This parameter specifies all NetApp volumes that are used in the source RG. It results in performing NetApp volume snapshots with the name *'rgcopy'*. Existing snapshots with this name will be overwritten. You have to specify the resource group (**rg**), the NetApp account (**account**), the capacity pool (**pool**) and all volume names (**vol1, vol2, ...**). You can skip the resource group (**rg**) if the NetApp account is in the source RG.
- **`createVolumes`** = `@(`**`"size@,mp1,mp2,..."`**`, ...)`<BR>This parameter specifies all mount points (**mp1, mp2, ...**). A mount point has the format **vmName/path**. For each mount point, RGCOPY backups the files in the source RG, creates and mounts a new NetApp volume in the target RG and restores the files. You have to specify the size of the new NetApp volume (**size**) in GiB. The minimum size is 100 GiB.

In this example, three volumes are in the source RG and one volume in resource group remoteRG. In VM hanadb, 3 mount points exist: /hana/data and /hana/log with 1 TiB and /test with 128 GiB:

```powershell
snapshotVolumes = @(
    'account/pool1@vol1, vol2, vol3',
    'remoteRG/accountRem/poolRemote@vol4'
)
createVolumes = @(
    '1024@hanadb/hana/data, hanadb/hana/log', 
    '128@hanadb/test'
)
```

>RGCOPY backups all files from the path `<mountPoint>/.snapshot/rgcopy/*` This is the directory for the snapshot with the name 'rgcopy'. If this snapshot directory does not exists then RGCOPY backups the files in `<mountPoint>/*`<BR>Not setting parameter `snapshotVolumes` results in using an outdated snapshot and in inconsistent data in the target RG.

#### Converting disks to a NetApp volumes

This works similar to copying NetApp volumes. However, you do not need parameter `snapshotVolumes` here. Instead, you need:
- **`skipDisks`** = `@(`**`"diskName1"`**`, ...)`<BR>Hereby, you specify the disks in the source RG that contained the data of the mount points. As a result, all these disks are not copied. No snapshot for these disks is created, no BLOB for these disks has to be copied to a remote region.
- **`createVolumes`** = `@(`**`"size@,mp1,mp2,..."`**`, ...)`<BR>See parameter description above.

Example:
```powershell
skipDisks = @(
    'hanaData', 
    'hanaLog'
)
createVolumes = '1024@hanadb/hana/data, hanadb/hana/log'
```

#### Converting NetApp volumes to disks

This also works similar to copying NetApp volumes. Here, you need the following parameters:
- **`snapshotVolumes`** = `@(`**`"rg/account/pool@vol1,vol2..."`**`, ...)`<BR>See parameter description above.
- **`createDisks`** = `@(`**`"size@,mp1,mp2,..."`**`, ...)`<BR>This parameter works just the same as `createVolumes`. However, it creates a new premium SSD disk in the target RG rather than a NetApp volume. The size of the disk can be very small (even 1 GiB) as long as all files of the mount point fit into the new disk.

Example:
```powershell
snapshotVolumes = 'anfAccount/anfPool@anfVolume1, anfVolume2'
createDisks = @(
    '1024@vmName/volumes/mount1', 
    '512@vmName/volumes/mount2'
)
```

#### Copying Ultra SSD Disks

For this scenario, you have to set two parameters:
- **`skipDisks`** = `@(`**`"UssdDiskName1"`**`, ...)`<BR>The parameter contains the names of *all* Ultra SSD disks in the source RG.
- **`createDisks`** = `@(`**`"size/iops/mbps@mp1,mp2,..."`**`, ...)`<BR>This is similar as above. You have to specify the mount points for each Ultra SSD disk. **size** is the size of the new disk in the target RG. By specifying **iops** (maximum number of IOs per second) and **mbps** (maximum MiB per second), RGCOPY creates an Ultra SSD disk rather than a Premium SSD disk.

Example:
```powershell
skipDisks = @(
    'ultraDisk1',
    'ultraDisk2'
)
createDisks = '1024/2048/8@vmName/disks/disk1, vmName/disks/disk2'
```

#### Converting disks to Ultra SSD Disks

In this scenario, you need the same parameters as in the last scenario. The difference is that the skipped disks do not need to be Ultra SSD disks:
- **`skipDisks`** = `@(`**`"diskName1"`**`, ...)`<BR>The parameter contains the names of all data disks that have to be converted.
- **`createDisks`** = `@(`**`"size/iops/mbps@,mp1,mp2,..."`**`, ...)`<BR>By specifying iops and mbps, RGCOPY creates an Ultra SSD disk rather than a Premium SSD disk.

Example:
```powershell
skipDisks = @(
    'disk1', 
    'disk2'
)
createDisks = @(
    '1024/2048/8@vmName/disks/disk1', 
    '1024/2048/8@vmName/disks/disk2'
)
```

#### Converting Ultra SSD Disks to Premium SSD Disks

This is similar to copying Ultra SSD disks. The difference is that you create Premium SSD disks in the target RG rather than Ultra SSD disks:

- **`skipDisks`** = `@(`**`"UssdDiskName1"`**`, ...)`<BR>The parameter contains the names of *all* Ultra SSD disks in the source RG
- **`createDisks`** = `@(`**`"size@mp1,mp2,..."`**`, ...)`<BR>See parameter description above.

Example:
```powershell
skipDisks = @(
    'ultraDisk1', 
    'ultraDisk2'
)
createDisks = @('1024@vmName/disks/disk1, vmName/disks/disk2')
```

### Changing number and path of mount points

In the scenarios above, you could change the storage type (disk or volume) and size. However, you were not able to change the number of mount points. However, RGCOPY also supports the following scenario: Assume, you are using 3 disks for the 3 SAP HANA mount points:
- /hana/data
- /hana/log
- /hana/shared

You might want to convert these 3 disks to a single NetApp volume using mount point /hana. Doing this, will allow you performing NetApp volume snapshots that are consistent over all 3 directories. You can implement such scenarios by performing 3 steps:

1. Run RGCOPY with parameters `snapshotVolumes`, `createVolumes`, `createDisks` and `skipDisks` according to your needs as described above. In addition, set parameter **`stopRestore`**. Hereby, RGCOPY stops before performing the file restore. All disks and volumes have already been created in the target RG, but they are not mounted yet. New disks are not partitioned and not formatted yet.
2. Mount the disks and volumes on your own. Partition and format the additional disks. Change the file `/etc/fstab` accordingly.
3. Start RGCOPY again using exactly the same parameters as in step 1 with one exception: Use parameter **`continueRestore`** rather than `stopRestore`. This results in restoring the files and performing all following RGCOPY steps.

### Tips and configuration options
You can use RGCOPY for creating the target RG in a different region. Therefore, BLOBs have to be copied to the target region. The runtime of the BLOB copy depends on the size of the disks. When creating a new disk or volume using backup/restore as described above, the runtime does not depend on the disk/volume size. It depends on the total size of all files inside the disk/volume. Therefore, it might be a good idea deleting unneeded files before copying a resource group. In particular for databases, you can decrease the total file size (and RGCOPY runtime) by deleting archive log files or unneeded database backups.

parameter|[DataType]: usage
:---|:---
**`smbTierStandard`**	|**[switch]**: By default, RGCOPY creates a *Premium* SMB share in the source RG for storing the file backups. This results in faster backup/restore. By setting the switch `smbTierStandard`, a Standard SMB share will be created instead (as long as the Premium SMB share does not already exist).
**`createDisksTier`** | **[string]**: By default, disks created by RGCOPY parameter `createDisks` have the minimum performance tier 'P20' to speed-up backup/restore on small disks. You can change the minimum performance tier to any value between 'P2' and 'P50' using parameter `createDisksTier`
**`capacityPoolGB`** | **[int]**: The minimum size of an Azure NetApp capacity pool is 4096 GiB. This is the default size that is used by RGCOPY when creating the capacity pool in the target RG. RGCOPY creates a larger capacity pool if the sum of all volumes is larger than 4096 GiB. Using parameter `capacityPoolGB` you can increase the capacity pool size in the target RG, even if the size of all created volumes is less than 4096 GiB.
**`verboseLog`** |**[switch]**: By setting this switch, RGCOPY writes a more detailed log file during backup/restore and when starting additional scripts.

***
## Starting Scripts from RGCOPY

RGCOPY can start different kind of scripts\* that are not part of RGCOPY. These scripts have to be developed on your own:
1. **Locally running PowerShell scripts** on the same machine as RGCOPY.<BR>They must be stored locally (typically on your PC).<BR>These scripts **must not** contain a `param` statement. The supplied parameters are directly accessible using variables.<BR>See example script `examplePostDeployment.ps1`
2. **Remotely running PowerShell scripts** inside a Windows VM<BR>They can either be stored locally (on your PC) or remotely (on the VM that is running the script).<BR>These scripts **must** contain a simple `param` statement (no data type or parameter options).<BR>Parameters of type array are converted to string. See example script `exampleStartAnalysis.ps1`
3. **Remotely running Shell scripts** inside a LINUX VM<BR>These scripts can either be stored locally (on your PC) or remotely (on the VM that is running the script).<BR>Parameters of type array are converted to string. See example script `exampleStartAnalysis.sh`

RGCOPY passes the following parameters to the scripts:
1. All supplied RGCOPY parameters.
2. Some of the optional RGCOPY parameters, even when not supplied. For example `targetSub`.
3. All ARM template parameters that are generated by RGCOPY.
4. Parameter `sourceLocation` that contains the region of the source RG
5. Parameter `vmName` that contains the name of the VM that is running the script.
6. Parameter `rgcopyParameters` that contains the names of all passed parameters.

In all scripts you can simply access the passed parameters using variables, for example `$targetSub`. Only remotely running PowerShell scripts must contain a `param` clause.

RGCOPY terminates with an error message if the output of the script contains the text `++ exit 1`. Be aware that `Invoke-AzVMRunCommand` does only return the last few dozen lines of `stdout` and `stderr`.

\* In addition to the scripts described above, RGCOPY uses LINUX scripts for backup/restore. These scripts are part of RGCOPY and cannot be changed. They are used for copying NetApp Volumes and Ultra SSD Disks (see above).

### Locally running scripts
You can start two different local PowerShell scripts using the following parameters:

parameter|[DataType]: usage
:---|:---
**`pathPostDeploymentScript`**|**[string]**: path to local PowerShell script<BR>You could use this script for deploying additional ARM resources that cannot be exported from the source RG.<BR><BR>When using this RGCOPY parameter, the following happens after deploying the ARM templates (in RGCOPY step *deployment*):<BR>1. SAP is started using another script inside a VM. The script has to be specified using parameters `scriptVm` and `scriptStartSapPath` (see below).<BR>2. The PowerShell script located in `pathPostDeploymentScript` is started.
**`pathPreSnapshotScript`**|**[string]**: path to local PowerShell script<BR><BR>When using this RGCOPY parameter, the following happens before creating the snapshots (in RGCOPY step *create snapshots*):<BR>1. All VMs in the source RG  are started.<BR>2. SAP is started using another script inside a VM. The script has to be specified using parameters `scriptVm` and `scriptStartSapPath` (see below).<BR>3. The PowerShell script located in `pathPreSnapshotScript` is started.<BR>4. All VMs in the source RG  are stopped.

### Remotely running scripts

The following parameters are used for starting SAP, SAP workload or workload analysis. Rather than using these parameters, you could set the Azure tags `rgcopy.ScriptStartSap`, `rgcopy.ScriptStartLoad` and `rgcopy.ScriptStartAnalysis` as described below.

parameter|[DataType]: usage
:---|:---
**`scriptVm`**|**[string]**: Name of the VM that runs the following scripts.<BR>All scripts have to run on the *same* VM (as long as you do not use the suffix '@*vmname*').
**`scriptStartSapPath`**|**[string]**: Runs a script for starting the SAP system (database and NetWeaver).<BR><BR>- The parameter specifies a path inside the VM, for example<BR>`'/root/startSAP.sh'`<BR><BR>- By prefixing **'local:'**, you can use a local script that is stored on your PC. However, the script is still being executed inside the VM. For example<BR>`'local:c:\Users\martin\startSAP.sh'`<BR><BR>- You can execute the script on any VM by adding **'@*vmname*'**. Hereby, parameter `scriptVM` will be ignored. For example:<BR>`'/root/startSAP.sh@sapserver'`<BR><BR>Rather than using a script, you can directly use a command. However, this command could contain an @ (which is used for specifying the vm name). In this case, you can use the **'command:'** prefix that allows any character in the command. In Return, it does not allow specifying a vm name, for Example:<BR>`'command:su - sidadm -c startsap'`<BR><BR>The script is started using PowerShell cmdlet `Invoke-AzVMRunCommand`. This will fail if the script does not finish within roughly half an hour. Therefore, you cannot use this for long running tasks (as an SAP benchmark). In this case, you must write a script that triggers or schedules the long running task and finishes without waiting for the task to complete.
**`scriptStartLoadPath`**|**[string]**: Runs a script for starting SAP Workload (SAP benchmark).<BR><BR>Same details apply here as for parameter `scriptStartSapPath` above.
**`scriptStartAnalysisPath`**|**[string]**: Runs a script for starting Workload Analysis.<BR><BR>Same details apply here as for parameter `scriptStartSapPath` above.
**`startWorkload`**|**[switch]**: Enables the last step of RGCOPY: *Workload and Analysis*.<BR><BR>Just using parameters `scriptStartLoadPath` and `scriptStartAnalysisPath` is not sufficient for starting the workload. You must explicitly enable the *Workload and Analysis* step using parameter `startWorkload`. This prevents an unintended start of the workload if Azure tags are used (rather than RGCOPY parameters `scriptStartLoadPath` and `scriptStartAnalysisPath`).

> For remotely running scripts, RGCOPY uses the cmdlet **`Invoke-AzVMRunCommand`** that connects to the Azure Agent running inside the VM. Make sure that you have installed a **recent version of the Azure Agent**. See also https://docs.microsoft.com/en-US/troubleshoot/azure/virtual-machines/support-extensions-agent-version.<BR><BR>`Invoke-AzVMRunCommand` expects that the script finishes within roughly one hour. If the script takes longer then `Invoke-AzVMRunCommand` (and RGCOPY) terminates with "Long running operation failed". If you want to use longer running scripts then you must write a wrapper script that just triggers or schedules your original script. The wrapper script can then be started using RGCOPY.

### Starting SAP
For starting SAP, you must write your own script. This script must contain `systemctl start sapinit` if you are using NetApp volumes. The path of the script has to be specified using parameter `scriptStartSapPath` (see above). This script will be started by RGCOPY in the following cases:
1. In the source RG: before running the local script specified by parameter `pathPreSnapshotScript`
2. In the target RG: before installing an AMS instance
3. In the target RG: before running the local script specified by parameter `pathPostDeploymentScript`
4. In the target RG: at the beginning of step *Workload and Analysis* (if parameter `startWorkload` is set)

If more than one case applies in the target RG then SAP will only be started once.

For example, using a Post-Deployment-Script works like this:


```powershell
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'

    scriptVm                 = 'SAPAPP'
    scriptStartSapPath       = '/root/startSAP.sh'
    pathPostDeploymentScript = 'c:\scripts\PostDeploymentScript.ps1'
}
.\rgcopy.ps1 @rgcopyParameter
```

If you just want to start SAP without implementing a Post-Deployment-Script, you can simply pass an invalid path for `pathPostDeploymentScript`, for example:

```powershell
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'

    scriptStartSapPath       = '/root/startSAP.sh@SAPAPP'
    pathPostDeploymentScript = 'dummy'
}
.\rgcopy.ps1 @rgcopyParameter
```

***
## SAP Monitor Extension (VMAEME)
You can install the VM Azure Enhanced Monitoring Extension (VMAEME) for SAP on specific VMs.

parameter|[DataType]: usage
:---|:---
**`installExtensionsSapMonitor`** |**[array]**: Names of VMs for deploying the SAP Monitor Extension.<BR>Alternatively, you can set the Azure tag `rgcopy.Extension.SapMonitor` for the VM. If you do not want to install the SAP Monitor Extension although the Azure tag has been set, use switch `ignoreTags`.

***
## Azure Monitoring for SAP (AMS)
RGCOPY can copy up to one AMS instance and multiple AMS providers. If there is more than one AMS instance in the source RG then you can use RGCOPY switch parameter `skipAms`. Hereby, RGCOPY will ignore AMS resources in the source RG.

>**AMS is still in public review which might result in changing APIs. RGCOPY relies on these APIs. Therefore, AMS installation using RGCOPY might not always be working as expected.**

For installing the SapHana provider, SAP HANA must already be running. However, this is not guarantied during the ARM deployment. Therefore, RGCOPY creates a separate ARM template just for the AMS instance and providers. This ARM template will be deployed in the target RG after SAP HANA has been started. Therefore, RGCOPY is using the script `scriptStartSapPath` as described above.


The following RGCOPY parameters exist for AMS:
parameter|[DataType]: usage
:---|:---
**`amsInstanceName`**|**[string]**: Name of the AMS instance in the target RG.<BR>When not setting this parameter, RGCOPY calculates an AMS instance name based on the target RG name.
**`amsWsName`** |**[string]**: Name of an existing log analytics workspace that should be used by AMS.<BR>If not set, then AMS creates a new workspace in the managed resource group.
**`amsWsRG`**   |**[string]**: Resource group name of the existing log analytics workspace used by AMS. <BR>It must be in the target subscription.
**`amsWsKeep`** |**[switch]**: By setting this switch, the AMS instance in the target RG is using the same log analytics workspace as the source RG. No new workspace is created. Parameters `amsWsName` and `amsWsRG`are ignored.
**`amsShareAnalytics`**  |**[switch]**: When setting this switch then AMS enables Customer Analytics. In this case, collected AMS data is visible for Microsoft support. This is not the case by default (without setting this switch).
**`skipAms`**|**[switch]**: Do not copy Azure Monitoring for SAP from source RG
**`dbPassword`**|**[SecureString]**: For AMS providers SapHana and MsSqlServer, you must provide the database password to RGCOPY as a secure string as follows:<BR>`dbPassword = (ConvertTo-SecureString -String 'secure-password' -AsPlainText -Force)`
**`amsUsePowerShell`**|**[boolean]**: (default value: \$True): This parameter just defines, *how* RGCOPY is installing AMS:<BR><BR>When set to **\$False**, then RGCOPY uses an ARM template for installing AMS. In this case, the PowerShell module *Az.HanaOnAzure* is not needed. The parameter `dbPassword` must be supplied during ARM template *creation*. Be aware, that the created ARM template contains the **password in plain text**. This is not the case when parameter `amsUsePowerShell` is not used.<BR><BR>When set to **\$True**, then RGCOPY uses PowerShell cmdlets for installing AMS. In this case, the newest version of the PowerShell module Az.HanaOnAzure must be installed. The parameter `dbPassword` must be supplied during ARM template *deployment*.

### Virtual Network Peerings for AMS in the source RG
RGCOPY can copy Azure virtual network peerings for AMS instances. This is useful because AMS is only supported in some specific regions yet, for example in eastus. If your resource group is located in an unsupported region then you can create an AMS instance in an additional virtual network in a supported region. Afterwards, you create a network peering between your main virtual network and the additional virtual network. **The AMS instance and all virtual networks must be located in the source RG.** RGCOPY does not support an AMS instance for monitoring resources in different resource groups. However, AMS instances in different resource groups can share the same log analytics workspace.


***
## RGCOPY Azure Tags
You can impact the RGCOPY behavior by setting Azure resource tags for the virtual machines in the source RG. These tags will also be copied to the target RG. All following tags are evaluated by RGCOPY (as long as parameter switch **`ignoreTags`** is not set):

virtual machine tag|[DataType]: usage
:---|:---
**`rgcopy.DeploymentOrder`**  |**[int]**: When not setting parameter `setVmDeploymentOrder`, the value of the tag is used to define the deployment order of the VM.
**`rgcopy.Extension.SapMonitor`**       |**[string]**: When set to 'true' and not setting parameter `installExtensionsSapMonitor`, the Azure Enhanced Monitoring Extension for SAP will be installed on this vm.

The following 3 tags can be used as a replacement for RGCOPY parameters `scriptStartSapPath`, `scriptStartLoadPath` and `scriptStartAnalysisPath`. The tags are only used when the RGCOPY parameters are not set (and `ignoreTags` is not set). The RGCOPY parameter `scriptVm` is automatically set to the VM name that has the tag. Therefore, you should not set these tags for different VMs. However, the file path (value of the tag) might end with '@vmName' as described in section 'Remotely running scripts' above. Hereby you can start the different scripts on different VMs and you do not need parameter `scriptVm` at all.

virtual machine tag|[DataType]: usage
:---|:---
**`rgcopy.ScriptStartSap`**   |**[string]**: This is the file path inside the VM that contains a shell script for starting SAP.
**`rgcopy.ScriptStartLoad`**  |**[string]**: This is the file path inside the VM that contains a shell script for starting the SAP workload (benchmark).
**`rgcopy.ScriptStartAnalysis`**|**[string]**: This is the file path inside the VM that contains a shell script for starting the workload analysis.

In addition, RGCOPY writes the following tags:
resource group tag|[DataType]: usage
:---|:---
**`Owner`**|**[string]**: Default value is `targetSubUser`.<BR>You can set the tag to any value by using parameter **`setOwner`**.<BR>When setting this parameter it to $Null, no "Owner" tag will be created.
**`Created_by`**|**[string]**: This tag is set to 'rgcopy.ps1' in the target RG.

You can easily read all Azure VM tags of a resource group using the PowerShell script tag-get.ps1:

```powershell
# tag-get.ps1
#Requires -Version 7.0
param(
    [Parameter(Mandatory = $True,  Position = 0)] [string]$resourceGroup,
    [Parameter(Mandatory = $False, Position = 1)] [string]$vmName   # single VM only
)
$parameter = @{
    ResourceGroupName = $resourceGroup
}
if ($vmName.length -ne 0) {
    $parameter.Add('Name', $vmName)
}
$vms = Get-AzVM @parameter
$allTags = @()
$vms | ForEach-Object {
    [hashtable] $tags = $_.Tags
    foreach($tag in $tags.getenumerator()) {
        $row = @{
            vm      = $_.Name
            tag     = $tag.Name
            value   = $tag.value
        }
        [array] $script:allTags += $row
    }
}
$allTags `
| Select-Object vm, tag, value `
| Sort-Object vm, tag `
| Format-Table
```

You can set Azure VM tags of a resource group using the PowerShell script tag-set.ps1:

```powershell
# tag-set.ps1 $resourceGroup $vmName @('tag1=value1', 'tag2=value2', ...)
#Requires -Version 7.0
param(
    [Parameter(Mandatory = $True, Position = 0)] [string] $resourceGroup,
    [Parameter(Mandatory = $True, Position = 1)] [string] $vmName,
    [Parameter(Mandatory = $True, Position = 2)] $tags,
    [switch] $removeOldTags
)
# get old tags
$vm = Get-AzVM -ResourceGroupName $resourceGroup -Name $vmName

# remove old tags
if ($removeOldTags -eq $True) {
    $vm.Tags.Clear()
}

# process new tags
foreach ($tag in $tags) {
    $tagKey,$tagValue = $tag -split '='
    if (($tagKey.length -ne 0) -and ($tagValue.length -ne 0)) {
        if ($tagValue -eq '$Null') {
            $vm.Tags.Remove($tagKey) | Out-Null
        }
        else {
            $vm.Tags.$tagKey = $tagValue
        }
    }
}

# set new tags
$res = Set-AzResource `
    -ResourceGroupName  $resourceGroup `
    -Name               $vmName `
    -ResourceType       'Microsoft.Compute/VirtualMachines' `
    -Tag                $vm.Tags `
    -Force

# output of new tags
$allTags = @()
[hashtable] $tagsHash = $res.Tags
foreach($t in $tagsHash.getenumerator()) {
    $row = @{
        vm      = $vm.Name
        tag     = $t.Name
        value   = $t.value
    }
    [array] $script:allTags += $row
}
$allTags `
| Select-Object vm, tag, value `
| Sort-Object vm, tag `
| Format-Table
m, tag `
| Format-Table
```

The following script sets the RGCOPY tags for a whole resource group:

```powershell
param(
    $resourceGroup 
)
tag-set.ps1 $resourceGroup vm1 'rgcopy.DeploymentOrder=1'
tag-set.ps1 $resourceGroup vm2 'rgcopy.DeploymentOrder=2'
tag-set.ps1 $resourceGroup vm3 'rgcopy.DeploymentOrder=2'
tag-set.ps1 $resourceGroup vm1 'rgcopy.Extension.SapMonitor=true'
tag-set.ps1 $resourceGroup vm2 'rgcopy.ScriptStartSap=/root/startSAP.sh'
```

***
## Analyzing Failed Deployments
Azure is validating an ARM template as the first step of an deployment. This validation might fail for various reasons. In this case, you can see the errors **in the output of RGCOPY** (on the host and in the RGCOPY log file). The screenshot below is from an old version of RGCOPY. In the meanwhile, RGCOPY performs several checks (including number of data disks) before starting the deployment.
If the ARM template validation succeeds but errors occur during deployment then you can check details of the deployment errors **in the Azure Portal**.

!["failedDeploymentRGCOPY"](/images/failedDeployment.png)
