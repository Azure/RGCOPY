# RGCOPY documentation
**Version: 0.9.36<BR>Mai 2022**
***

### Introduction

RGCOPY (**R**esource **G**roup **COPY**) is a tool that copies the most important resources of an Azure resource group (**source RG**) to a new resource group (**target RG**). It can copy a whole landscape consisting of many servers within a single Azure resource group to a new resource group. The target RG might be in a different region, subscription or tenant. RGCOPY has been tested on **Windows**, **Linux** and in **Azure Cloud Shell**. It should run on **MacOS**, too.

RGCOPY has been developed for copying an SAP landscape and testing Azure with SAP workload. Therefore, it [supports](./rgcopy-docu.md#Supported-Azure-Resources) the most important Azure resources needed for SAP, as virtual machines, managed disks and Load Balancers. However, you can use RGCOPY also for other workloads.

> RGCOPY is not an SAP deployment tool. It simply copies Azure resources (VMs, disks, NICs ...). It does not change anything inside the VMs like changing the server name at the OS level or applying SAP license keys.

RGCOPY has 3 different operation modes. By default, RGCOPY is running in Copy Mode. 

- In **[Copy Mode](./rgcopy-docu.md#Workflow)**, an ARM template is exported from the source RG, modified and deployed on the target RG. Hereby, you can change several [resource properties](./rgcopy-docu.md#Resource-Configuration-Parameters) in the target RG:
    - Changing VM size, disk SKU, disk performance tier, disk bursting, disk caching, Write Accelerator, Accelerated Networking
    - Adding, removing, and changing [availability](./rgcopy-docu.md#Parameters-for-Availability) configuration: Proximity Placement Groups, Availability Sets, Availability Zones, and VM Scale Sets
    - Converting disks to [NetApp Volumes](./rgcopy-docu.md#NetApp-Volumes-and-Ultra-SSD-Disks) and vice versa (on Linux VMs)
    - Converting [Ultra SSD disks](./rgcopy-docu.md#NetApp-Volumes-and-Ultra-SSD-Disks) to Premium SSD disks and vice versa (on Linux VMs)
    - [Merging](./rgcopy-docu.md#Merging-and-Cloning-VMs) single VMs into an existing subnet (target RG already exists)
    - [Cloning](./rgcopy-docu.md#Merging-and-Cloning-VMs) a VM inside a resource group (target RG = source RG)

- In **[Archive Mode](./rgcopy-docu.md#Archive-Mode)**, a backup of all disks to cost-effective BLOB storage is created in an storage account of the target RG. An ARM template that contains the resources of the source RG is also stored in the BLOB storage. In this mode, no other resource is deployed in the target RG.

- In **[Update Mode](./rgcopy-docu.md#Update-Mode)**, you can change resource properties in the source RG, for example VM size, disk performance tier, disk bursting, disk caching, Write Accelerator, Accelerated Networking. For saving costs of unused resource groups, RGCOPY can do the following:
    - Changing disk SKU to 'Standard_LRS' (or any other SKU except for 'UltraSSD_LRS')
    - Deletion of an Azure Bastion including subnet and IP Address (or creation of a Bastion)
    - Deletion of all snapshots in the source RG
    - Stopping all VMs in the source RG
    - Changing NetApp service level to 'Standard' (or any other service level)

This documentation is also available using the following command:

```powershell
Get-Help .\rgcopy.ps1 -Online
```

An introduction to RGCOPY is available as a **[YouTube video](https://www.youtube.com/watch?v=8pCN10CRXtY)**. An overview of Update Mode is also on **[YouTube](https://www.youtube.com/watch?v=_iiSeyci7TY)**.

The following example demonstrates the user interface of RGCOPY in **Copy Mode**:

```powershell
$rgcopyParameter = @{
    sourceRG        = 'sap_vmss_zone'
    targetRG        = 'sap_vmss_zone_copy'
    targetLocation  = 'eastus'
    setVmSize       = 'Standard_E4ds_v4'
    setDiskSku      = 'Premium_LRS'
}
.\rgcopy.ps1 @rgcopyParameter
```

!["RGCOPY"](/images/RGCOPY.png)

<div style="page-break-after: always"></div>

### Installation
- Install **PowerShell** 7.1.2 (or higher)
- Install Azure PowerShell Module **Az** 6.0 (or higher): <BR>`Install-Module -Name Az -Scope AllUsers -AllowClobber -Force`
- Copy `rgcopy.ps1` into the user home directory (~)
- In PowerShell 7, run `Connect-AzAccount` for each subscription and each Azure Account that will be used by RGCOPY. The Azure Account needs privileges for creating the target RG and for creating snapshots in the source RG.

>You can run RGCOPY also in **Azure Cloud Shell**. However, you have to copy the file **`rgcopy.ps1`** into Azure Cloud Drive first. There is no need to install PowerShell or Az module in Azure Cloud Shell. You also do not have to run `Connect-AzAccount` since you are already connected with a Managed System Identity, for example MSI@0815. 

### Examples
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
    targetLocation  = 'westus'
}
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
    targetLocation  = 'westus'
}
.\rgcopy.ps1 @rgcopyParameter
```

Changing VM size to Standard_M16ms (for VMs HANA1 and HANA2), Standard_M8ms (for VM SAPAPP) and Standard_D2s_v4 (for all other VMs)
```powershell
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'

    setVmSize = @(
        'Standard_M16ms @ HANA1, HANA2',
        'Standard_M8ms @ SAPAPP',
        'Standard_D2s_v4'
    )	
}
.\rgcopy.ps1 @rgcopyParameter
```

You can even run RGCOPY without any parameter. In this case, you are prompted for the mandatory parameters
```powershell
.\rgcopy.ps1
```

```powershell
cmdlet rgcopy.ps1 at command pipeline position 1
Supply values for the following parameters:
sourceRG:
```

<div style="page-break-after: always"></div>

### Workflow
In **Copy Mode**, the workflow of RGCOPY consists of the following steps. RGCOPY decides on its own for each step whether it is needed. However, you can skip each step separately using an RGCOPY switch parameter.

Step|parameter<BR>skip switch|usage
:---|:---|:---
*create ARM template*|**`skipArmTemplate`**|This step creates an ARM template (json file) that will used for deploying in the target RG. <BR>The template refers either to the snapshots in the source RG or to BLOBs in the target RG. Therefore, the template is only valid as long as the snapshots and BLOBs exist.<BR>Using various RGCOPY parameters, you can change [properties](./rgcopy-docu.md#Resource-Configuration-Parameters) of resources (e.g. VM size) compared with the Source RG. Be aware that some properties are changed to default values even when not explicitly using RGCOPY parameters.
*create snapshots*|**`skipSnapshots`**|This step creates snapshots of disks (and [NetApp Volumes](./rgcopy-docu.md#NetApp-Volumes-and-Ultra-SSD-Disks)) in the source RG. During this time, VMs with more than one data disk must be stopped. See section [Application Consistency](./rgcopy-docu.md#Application-Consistency) for details. When setting parameter switch **`stopVMsSourceRG`**, RGCOPY stops *all* VMs in the source RG before creating snapshots.
*create backups*|**`skipBackups`**|This step is only needed when using (or converting) [NetApp Volumes](./rgcopy-docu.md#NetApp-Volumes-and-Ultra-SSD-Disks) on LINUX. A file backup of specified mount points is created on an Azure SMB file share in the source RG.
*create BLOBs*|**`skipBlobs`**|This step is needed when the source RG and the target RG are not in the same region. The snapshots in the source RG are copied as [BLOBs](./rgcopy-docu.md#Parameters-for-BLOB-Copy) into a storage account in the target RG. Dependent on the disk sizes and the region, this might take several hours.
*deployment*|**`skipDeployment`**|The deployment consists of several part steps:<BR><BR>*deploy VMs:* Deploy ARM template in the target RG.<BR>Part step can be skipped by **`skipDeploymentVMs`**<BR><BR>*restore backups:* Restore file backup on disks or [NetApp Volumes](./rgcopy-docu.md#NetApp-Volumes-and-Ultra-SSD-Disks) in the target RG if needed.<BR> Part step can be skipped by **`skipRestore`**<BR><BR>*deploy AMS:* Deploy [Azure Monitor for SAP](./rgcopy-docu.md#Azure-Monitor-for-SAP) if either parameter `createArmTemplateAms` or `pathArmTemplateAms` is set.<BR><BR>*install VM Extensions*: install [VM Extensions](./rgcopy-docu.md#VM-Extensions) if explicitly configured using RGCOPY parameters.<BR>Part step can be skipped by **`skipExtensions`**
*start workload*| *optional step* | This step is used for testing SAP Workload. It has to be explicitly activated using switch **`startWorkload`**.
*cleanup*| *optional step* | By default, created snapshots are not deleted by RGCOPY. However, you can activate a cleanup using RGCOPY parameters. See section [Cost Efficiency](./rgcopy-docu.md#Cost-Efficiency) for details.

When setting the parameter switch **`simulate`**, only an ARM template is created. All other steps are skipped. This is useful for checking whether configured resource changes are possible (VM size available in target region? Disk properties compatible with VM size? Subscription quota sufficient? ...)

<div style="page-break-after: always"></div>

***
## Parameters

### Resource Group Parameters
The resource group parameters are essential for running RGCOPY:

parameter|[DataType]: usage
:---|:---
**`sourceRG`**			|**[string]**: name of the source resource group<BR><BR>parameter is **mandatory**
**`targetRG`**			|**[string]**: name of the target resource group<BR>Source and target resource group must not be identical unless you use parameter `setVmMerge` as described below.<BR>The target resource group might already exist. However, it should not contain resources. For safety reasons, RGCOPY does not allow using a target resource group that already contains disks (unless you set switch parameter **`allowExistingDisks`**).<BR><BR>parameter is **mandatory** in **Copy Mode** and **Archive Mode**<BR>parameter is **not allowed** in **Update Mode**
**`targetLocation`**	|**[string]**: *location name* of the Azure region for the target RG, for example 'eastus'.<BR>Do **not** use the *display name* ('East US') instead.<BR><BR>parameter is **mandatory** in **Copy Mode** and **Archive Mode**<BR>parameter is **not allowed** in **Update Mode**
**`targetSA`**         |**[string]**: name of the storage account that will be created in the target RG for storing BLOBs.<BR><BR>parameter is normally not needed\*
**`sourceSA`**         |**[string]**: name of the storage account that will be created in the source RG for storing file backups. This storage account is only created when parameter **`createVolumes`** or **`createDisks`** is set.<BR><BR>parameter is normally not needed\*

 \* You normally do not need these two parameters because RGCOPY is calculating the storage account name based on the name of the resource group. However, this could result in deployment errors because the storage account name must be unique in whole Azure (not only in the current subscription). Once you run into this issue, repeat RGCOPY and set the parameter to a unique name.


### Azure Connection Parameters
RGCOPY is using the current Azure Context (account and subscription) when no Azure Connection Parameter is provided. PowerShell caches the password of the Azure account inside the Azure Context for several hours. Therefore, you do not need to provide a password to RGCOPY. Simply run the following cmdlet just before RGCOPY:<BR>**`Connect-AzAccount -Subscription 'Subscription Name'`**<BR>The cmdlet opens the default browser and you can enter account name and password.



RGCOPY can use two different Azure accounts for connecting to the source RG and the target RG. In this case, you must run `Connect-AzAccount` for both accounts before starting RGCOPY. Furthermore, you must provide the RGCOPY connection parameters as described below. Hereby, RGCOPY knows which account has to be used for which resource group.

PowerShell caches the Azure context only for a few hours. Once it is expired, you must run `Connect-AzAccount` again.

!["RGCOPY"](/images/failedAzAccount.png)

>You should run `Connect-AzAccount` immediately before starting a copy to a different region (which might take several hours) because the cached credentials might expire during the runtime of RGCOPY.<BR>Once this happens, yo do not need to start RGCOPY from scratch. There is an RGCOPY parameter that allows resuming in this particular case. See [Parameters for BLOB Copy](./rgcopy-docu.md#Parameters-for-BLOB-Copy)

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

### Resource Configuration Parameters
With resource configuration parameters you can change properties of various resources in the Target ARM template.

Each of the configuration parameters has the following scheme:

```powershell
     [string] $parameter     = "$rule1"
or    [array] $parameter     = @("$rule1","$rule2", ...)
or  [boolean] $parameter     # $True is converted to 'True', $False is converted to 'False'
or      [int] $parameter     # 1, 2, 3 ... are converted to '1', '2', '3' ...

with [string] $rule          = "$configuration @ $resources"
     [string] $resources     = "$resourceName1, $resourceName2, ..."
     [string] $configuration = "$part1 / $part2 / $part3"
```

A resource configuration parameter is an array of strings. Each string represents a rule. Each rule has the form configuration@resources. Resources are separated by commas (,). A configuration might consist of up-to 3 parts separated by a slash (/).

Let's explain this for the parameter `setVmSize` which changes the size of VMs. In the examples, hana1 and hana2 are Azure resource names of virtual machines:

setVmSize parameter value|result
:---|:---
`@("Standard_E32s_v3@hana1")`	|changes the VM size of one VM (hana1) to Standard_E32s_v3
`"Standard_E32s_v3@hana1"`		|same as above but using a PowerShell string rather than an array
`'Standard_E32s_v3 @ hana1'`		|same as above but using single quotes and separated by spaces
`'Standard_E32s_v3'`			|changes the VM size of *all* VMs to Standard_E32s_v3
`"Standard_E32s_v3 @ hana1, hana2"`|changes the VM size of 2 VMs (hana1 and hana2)<BR>to Standard_E32s_v3 (using one rule)
`@(`<BR>`'Standard_E32s_v3 @ hana1',`<BR>` 'Standard_E16s_v3 @ hana2'`<BR>`)`	|changes the VM size for 2 VMs separately:<BR>Standard_E32s_v3 for hana1 and Standard_E16s_v3 for hana2<BR>using 2 rules - therefore data type array is needed
`@(`<BR>`"Standard_E16s_v3 @ hana2",`<BR>`"Standard_E32s_v3"`<BR>`)`		|changes the VM size of hana2 to Standard_E16s_v3 <BR>and of *all other* VMs to Standard_E32s_v3. <BR>In this example, 2 rules fit for resource hana2. <BR> The more specific rule `Standard_E16s_v3 @ hana2` wins.

The following resource configuration parameters exist:

parameter|usage (data type is always [string] or [array])
:---|:---
**`setVmSize`** =<BR>`@("size@vm1,vm2,...", ...)`	|Set VM Size: <BR>**size**: VM size (e.g. Standard_E32s_v3) <BR>**vm**: VM name
**`setDiskSku`** =<BR>`@("sku@disk1,disk2,...", ...)`			|Set Disk SKU: <BR>**sku** in {Premium_LRS, StandardSSD_LRS, Standard_LRS, Premium_ZRS, StandardSSD_ZRS} <BR>**disk**: disk name
**`setDiskSize`** = <BR>`@("size@disk1,disk1,...", ...)`			|Set Disk Size: <BR>**size** in GB <BR>**disk**: disk name<BR>It's only possible to *increase* the size of a disk. Partitions on the disk are not changed. This parameter was originally intended for increasing disk I/O on the target RG. Nowadays, you better should use parameter `setDiskTier` instead.
**`setDiskTier`** = <BR>`@("tier@disk1,disk1,...", ...)`			|Set Disk Performance Tier:<BR>**tier** in {P0, P1, ..., P80} <BR>**disk**: disk name<BR>To remove existing  performance tier configuration, set tier to P0.
**`setDiskBursting`** = <BR>`@("bool@disk1,disk2,...", ...)`|Set Disk Bursting: <BR>**bool** in {True, False} <BR>**disk**: disk name
**`setDiskMaxShares`** = <BR>`@("number@disk1,disk2,...", ...)`|Set maximum number of shares for a Shared Disk: <BR>**number** in {1, 2, 3, ...}  <BR>**disk**: disk name <BR>For number = 1, it is not a Shared Disk anymore
**`setDiskCaching`** = <BR>`@("caching/wa@disk1,disk2...", ...)`	|Set Disk Caching: <BR>**caching** in {ReadOnly, ReadWrite, None} <BR>**wa (writeAccelerator)** in {True, False} <BR>**disk**: disk name<BR><BR>Examples:<BR>`'ReadOnly'`: turns on ReadOnly cache for all disks<BR>`'None/False'`: turns off caching and writeAccelerator for all disks<BR>`'/False'`: turns off writeAccelerator for all disks (but keeps caching property)<BR>`@('ReadOnly/True@disk1', '/False')`: turns on writeAccelerator (with ReadOnly cache) for disk1 and turns it off for all other disks in the resource group
**`setVmDeploymentOrder`** = <BR>`@("prio@vm1,vm2,...", ...)`				|Set VM deployment Order: <BR>**prio** in {1, 2, 3, ...}  <BR>**vm**: VM name <BR>This parameter is used during ARM template creation. You can define priories for deploying VMs. A VM with higher priority (lower number) will be deployed before VMs with lower priority. Hereby, you can ensure that an important VM (for example a domain controller) will be deployed before other VMs.
**`setLoadBalancerSku`** = <BR>`@("sku@lb1,lb2,...", ...)`	|Set Load Balancer SKU: <BR>**sku** in {Basic, Standard}<BR>**lb (loadBalancer)**: Load Balancer name.
**`setPublicIpSku`** = <BR>`@("sku@ip1,ip2,...", ...)`		|Set Public IP SKU: <BR>**sku** in {Basic, Standard} <BR>**ip**: name of Public IP Address.
**`setPublicIpAlloc`** = <BR>`@("allocation@ip1,ip2,...", ...)`		|Set Public IP Allocation Method: <BR>**allocation** in {Dynamic, Static}<BR>**ip**: name of Public IP Address.
**`setPrivateIpAlloc`** = <BR>`@("allocation@ip1,ip2,...", ...)`		|Set Private IP Allocation Method: <BR>**allocation** in {Dynamic, Static}<BR>**ip**: name of Private IP Address.
**`removeFQDN`** = <BR>`@("bool@ip1,ip2,...", ...)`		|Remove Fully Qualified Domain Names: <BR>**bool** in {True} <BR>**ip**: name of Public IP Address.
**`setAcceleratedNetworking`** = <BR>`@("bool@nic1,nic2,...", ...)`		|Set Accelerated Networking: <BR>**bool** in {True, False} <BR>**nic**: name of Virtual Network Interface.
**`createVolumes`**<BR>**`createDisks`**<BR>**`snapshotVolumes`**|see section [NetApp Volumes and Ultra SSD Disks](./rgcopy-docu.md#NetApp-Volumes-and-Ultra-SSD-Disks).

### Default values
RGCOPY uses default parameter values in **Copy Mode**. If you do not want this then set parameter switch **`skipDefaultValues`** or explicitly set the individual parameters to a different value. In **Archive Mode** and **Update Mode** no default values are used. These are the default values in **Copy Mode**:

parameter|default value|default behavior
:---|:---:|:---
**`setDiskSku`**        |'Premium_LRS'   |converts all disks to Premium SSD<BR>(except Ultra SSD disks - they cannot be copied directly)
**`setVmZone`**         |0             |removes zone configuration from VMs
**`setLoadBalancerSku`**|'Standard'      |sets SKU of Load Balancers to Standard
**`setPrivateIpAlloc`** |'Static'        |sets allocation of Private IP Addresses to Static
**`setAcceleratedNetworking`**|$True    |enables Accelerated Networking

Parameter **`removeFQDN`** always has the default value `$True` (even when `skipDefaultValues` is set)

### VM consistency checks

RGCOPY performs several consistency checks. Some of the found issues are automatically corrected by default. In this case, a warning is written into the RGCOPY log file. You should have a close look at this file to become aware of the (possibly unwanted) mediation of these issues. For example:

- Premium SSD disks are  converted to Standard SSD disks if the VM size does not support Premium IO
- Accelerated Networking and Write Accelerator are disabled if not supported by the VM size
- Read-write caching is disabled if Write Accelerator is enabled

Some issues cannot be corrected by RGCOPY and result in an error, for example when:

- VM size does not exist in the target region
- Maximum number of NICs or disks is exceeds when changing the VM size
- Subscription quota for the VM size and region is not sufficient

You can change the default behavior of RGCOPY consistency checks using the following parameters:

parameter|[DataType]: usage
:---|:---
**`forceVmChecks`**| **[switch]**: Do not automatically adjust any resource property<BR>Once this switch is set, RGCOPY terminates if an incompatible resource property is set. RGCOPY does not try solving such issues automatically. For example, it does not automatically convert Premium SSD disks if the VM size does not support Premium IO.
**`skipVmChecks`**| **[switch]**: Ignore any incompatible resource property<BR>Normally, setting this parameter switch does not make any sense. When allowing incompatible resource properties then the deployment will fail. However, there is one scenario where this parameter is useful: RGCOPY relies on SKU information retrieved by `Get-AzComputeResourceSku`. If this information is wrong for any reason and you are sure that you know it better then you can set this parameter switch.
**`simulate`**| **[switch]**: Do not stop for (most of the) found consistency errors.<BR>For each found error, RGCOPY writes a warning in red color. This is useful for detecting *all* errors by just running RGCOPY once. However, it is a simulation. You cannot copy a resource group while parameter `simulate` is set.

### Parameters for skipping resources

parameter|[DataType]: usage
:---|:---
**`skipVMs`**|**[array] of VM names**: These VMs and their disks are not copied by RGCOPY.<BR>NICs that are bound only to these VMs and Public IP Addresses are skipped, too. However, NICs that are also bound to Load Balancers are still copied.
**`skipDisks`**|**[array] of disk names**: These disks are not copied by RGCOPY.<BR>Take care with this parameter. Starting their VMs could fail in the target RG. See section [NetApp Volumes and Ultra SSD disks](./rgcopy-docu.md#NetApp-Volumes-and-Ultra-SSD-Disks)
**`skipSecurityRules`**|**[array] of name patterns**: default value: `@('SecurityCenter-JITRule*')`<BR>Skips all security rules that name matches any element of the array.<BR>By default, only Just-in-Time security rules are skipped (This is needed to avoid permanently opend ports in the target RG). All other security rules are copied.
**`skipAvailabilitySet`**<BR>**`skipProximityPlacementGroup`**|see [Parameters for Availability](./rgcopy-docu.md#Parameters-for-Availability)
**`skipBastion`**|**[switch]**: do not copy Azure Bastion from source RG
**`keepTags`**|**[array] of name patterns**: default value: `@('rgcopy*')`<BR>Skips all Azure resource tags except the ones that name matches any element of the array.<BR>By default, only Azure resource tags with a name starting with 'rgcopy' are copied. By setting parameter `keepTags` to `@('*')`, all Azure resource tags are copied.

### Parameters for Availability
RGCOPY can change Availability Zones, Availability Sets and Proximity Placement Groups in the target RG. It does not touch the source RG configuration.


parameter|[DataType]: usage
:---|:---
**`setVmZone`** = <BR>`@("zone@vm1,vm2,...", ...)`			|Set VM Availability Zone: <BR>**zone** in {none, 1, 2, 3} <BR>**vm**: VM name <BR>Rather than 'none', you can use '0' for removing zone information
**`setVmFaultDomain`** = <BR>`@("fault@vm1,vm2,...", ...)`			|Set VM Fault Domain: <BR>**fault**: Used Fault Domain in {none, 0, 1, 2} <BR>**vm**: VM name <BR> The value 'none' removes the Fault Domain configuration from the VM.<BR>Values {0, 1, 2} are only allowed if the VM is part of a VMSS Flex.
**`skipVmssFlex`**|**[switch]**: do not copy existing VM Scale Sets Flexible. <BR>Hereby, the target RG does not contain any VM Scale Set.
**`skipAvailabilitySet`**|**[switch]**: do not copy existing Availability Sets. <BR>Hereby, the target RG does not contain any Availability Set.
**`skipProximityPlacementGroup`**|**[switch]**: do not copy existing Proximity Placement Groups. <BR>Hereby, the target RG does not contain any Proximity Placement Group.
**`createVmssFlex`** = <BR>`@("vmss/fault/zones@vm1,vm2,...", ...)`			|Create a VMSS Flex (VM Scale Set with Flexible orchestration mode) for given VMs: <BR>**vmss**: VM Scale Set Name <BR>**fault**: Fault domain count in {none, 2, 3, max}.<BR>**zones** Allowed Zones in {none, 1+2, 1+3, 2+3, 1+2+3}  <BR>**vm**: VM name <BR>When you are using this parameter for creating new VM Scale Sets then all existing VM Scale Sets are removed first.<BR>**Either *zones* or *fault* must have the value *none***<BR>A fault domain count of *max* automatically creates the maximum number of fault domains in the target region.
**`createAvailabilitySet`** = <BR>`@("avset/fault/update@vm1,vm2,...", ...)`			|Create Azure Availability Set for given VMs: <BR>**avset**: Availability Set Name <BR>**fault**: Fault domain count<BR>**update**: Update domain count<BR>**vm**: VM name <BR>When you are using this parameter for creating new Availability Sets then all existing Availability Sets *and* Proximity Placement Groups are removed first.
**`createProximityPlacementGroup`** = <BR>`@("ppg@res1,res2,...", ...)`			|Create Azure Proximity Placement Group for given VMs or Availability Sets: <BR>**ppg**: Proximity Placement Group Name <BR>**res**: resource name (either VM or Availability Set) <BR>When you are using this parameter for creating new Proximity Placement Groups then all existing Proximity Placement Groups *and* Availability Sets are removed first.<BR><BR>Caution: You might use the same name for a VM and an Availability Set and add this name as resource name to this parameter. In this case, the VM as well as the Availability Set will be added to the Proximity Placement Group.

In Azure you cannot directly configure the Availability Zone for an Availability Set. However, you can indirectly pin an Availability Set to an Availability Zone. The trick is to deploy an additional VM that is in the Availability Zone. If this VM and the Availability Set are in the same Proximity Placement Group then they are also in the same Availability Zone. However, this only works if the VM is deployed first. If you deploy the Availability Set first then it might be deployed in a different Availability Zone. Afterwards, the deployment of the VM fails because the requirements for Availability Zone and Proximity Placement Group cannot be fulfilled at the same time. Luckily, you can define the deployment order in RGCOPY:

```powershell
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'
    
    createAvailabilitySet = @(
        'avset1/2/5 @ app1a, app1b', 
        'avset2/2/5 @ app2a, app2b')

    setVmZone = @(
        '1 @ hana1, ascs1',
        '2 @ hana2, ascs2')
    
    createProximityPlacementGroup = @(
        'ppg1 @ ascs1, avset1',
        'ppg2 @ ascs2, avset2')
        
    setVmDeploymentOrder = @('1 @ ascs1, ascs2')
}
.\rgcopy.ps1 @rgcopyParameter
```

> RGCOPY ensures in this example that the VMs 'ascs1' and 'ascs2' are deployed before all other VMs. After stopping all VMs, the VMs in the Availability Sets are not bound to a Availability Zone anymore. Therefore, you have to take care on your own that 'ascs1' and 'ascs2' are always started before the other VMs in their Availability Sets.

An alternative for using Azure Availability Zones is using **VMSS Flex** (VM Scale Set with Flexible orchestration mode) **with zones**. Hereby, you can define the zone per VM. In each zone, Azure automatically distributes the VMs over different fault domains on best effort basis. This results in a mixture of zone deployment and using fault domains. Using Azure Availability Sets would not allow zones. Using Azure Availability Zones would not utilize fault domains.

Example of VMSS Flex **with zones**:

```powershell
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'

    createVmssFlex = @(
        'vmss/none/1+2 @ hana1, hana2, ascs1, ascs2, app1a, app1b, app2a, app2b'
    )
    setVmZone = @(
        '1 @ hana1, ascs1, app1a, app1b',
        '2 @ hana2, ascs2, app2a, app2b'
    )
}
.\rgcopy.ps1 @rgcopyParameter
```

An alternative for using Azure Availability Sets is using **VMSS Flex with fault domains**. In this case you can even define the fault domain individually per VM (which is not possible when using an Azure Availability Set). You cannot define the zone number in this case. However, all VMs of the VMSS Flex with fault domains are deployed in the same zone. This is much more flexible compared with an Availability Set (which would require that all VMs fit into the same cluster).

Example of VMSS Flex **with fault domains**:

```powershell
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'
    
    createVmssFlex = @(
        'vmss/2/none @ hana1, hana2, ascs1, ascs2, app1a, app1b, app2a, app2b'
    )
    setVmFaultDomain = @(
        '0 @ hana1, ascs1, app1a, app1b',
        '1 @ hana2, ascs2, app2a, app2b'
    )
}
.\rgcopy.ps1 @rgcopyParameter
```

When using more than one instance of VMSS Flex with fault domains, you can use a Proximity Placement Group for pinning them to the same zone (this is not possible for VMSS Flex with zones).

Example of VMSS Flex **with fault domains** and **PPG**:

```powershell
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'
    
	createProximityPlacementGroup = 'ppg @ vmss1, vmss2'

	createVmssFlex = @(
		'vmss1/2/none @ hana1, hana2',
		'vmss2/2/none @ ascs1, ascs2, app1a, app1b, app2a, app2b'
	)
	setVmFaultDomain = @(
		'0 @ hana1, ascs1, app1a, app1b',
		'1 @ hana2, ascs2, app2a, app2b'
    )
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

### Path of RGCOPY files
`pathExportFolder` is the default path for RGCOPY output files. The other parameters are full file paths of RGCOPY input files:

parameter|[DataType]: usage
:---|:---
**`pathExportFolder`**<BR>|**[string]**: By default, RGCOPY creates all files in the user home directory. You can change the path for all RGCOPY files by setting parameter `pathExportFolder`.
**`pathArmTemplate`**|**[string]**: You can deploy an existing (main) ARM template by setting this parameter. No snapshots are created, no ARM template is created and no resource configuration changes are possible.
**`pathArmTemplateAms`**|**[string]**: You can provide an existing ARM template for deploying the AMS instance and providers. <BR><BR>Caution: *Only* ARM templates that were created by RGCOPY can be used here because the ARM template parameter `amsInstanceName` is required.

### Other Parameters
parameter|[DataType]: usage
:---|:---
**`copyDetachedDisks`** |**[switch]**: By default, only disks that are attached to a VM are copied to the target RG. By setting this switch, also detached disks are copied.
**`maxDOP`**               |**[int]**: RGCOPY performs the following operations in parallel:<BR>- snapshot creation<BR>- access token creation<BR>- access token deletion<BR>- snapshot deletion<BR>- VM start<BR>- VM stop<BR>By default, RGCOPY uses 16 parallel running threads for these tasks. You can change this using parameter `maxDOP`.
**`jumpboxName`**          |**[string]**: When setting a jumpboxName, RGCOPY adds a Full Qualified Domain Name (FQDN) to the Public IP Address of the jumpbox. The FQDN is calculated from the name of the target RG. <BR><BR>For example, `targetRG`=*test_resource_group* and `targetLocation`=*eastus*<BR>results in FQDN: *test-resource-group.eastus.cloudapp.azure.com*. <BR>RGCOPY uses the first Public IP Address of the first VM which fits the search for `*jumpboxName*`
**`justCreateSnapshots`**  |**[switch]**: When setting this switch, RGCOPY only creates snapshots on the source RG (no ARM template creation, no deployment). This is useful for refreshing the snapshots for an existing ARM template.<BR><BR>Setting this switch aso enables the **Update Mode**
**`justDeleteSnapshots`**  |**[switch]**: When setting this switch, RGCOPY only deletes snapshots on the source RG (no ARM template creation, no deployment). <BR>Caution: you typically want to keep the existing snapshots since ARM templates within the same region refer to these snapshots.<BR><BR>Setting this switch aso enables the **Update Mode**

<div style="page-break-after: always"></div>

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


The following RGCOPY parameters are available:

parameter|usage
:---|:---
**`skipDisks`** = <BR>`@('diskName1',  ...)`	|**[array] of disk names**: These disks are not copied by RGCOPY.<BR>Take care with this parameter. Starting their VMs could fail in the target RG. When using this parameter, you must set **`/etc/fstab`** for all disks (not only the skipped disks) as described above.
**`createVolumes`** = <BR>`@("size@,mp1,mp2,...", ...)`			|Create new NetApp volumes in the target RG<BR>**size**: volume size in GB <BR>**mp**: mount point `/<server>/<path>` (e.g. /dbserver/hana/shared)
**`createDisks`** = <BR>`@("size@,mp1,mp2,...", ...)`<BR>`@("size/iops/mbps@mp1,mp2,...", ...)`|Create new disks in the target RG<BR>**size**: disk size in GB<BR>**iops**: I/Os per second: only needed and allowed for Ultra SSD disks<BR>**mbps**: megabytes per second: only needed and allowed for Ultra SSD disks<BR>**mp**: mount point `/<server>/<path>` (e.g. /dbserver/hana/shared)
**`snapshotVolumes`** = <BR>`@("account/pool@vol1,vol2...", ...)`<BR>`@("rg/account/pool@vol1,vol2...", ...)`			|Create NetApp volume snapshots in the source RG<BR>**rg**: resource group name that contains the NetApp account (optional)<BR>**account**: NetApp account name<BR>**pool**: NetApp pool name<BR>**vol**: NetApp volume name<BR>rg is optional. Default value is `sourceRG`
**`netAppSubnet`**=<BR>`'<addrPrefix>@<vnet>'`|Create NetApp subnet:<BR>**vnet:** existing virtual Network name<BR>**addrPrefix:** Address Prefix that is used for creating the new subnet<BR><BR>RGCOPY automatically uses an existing NetApp subnet when creating NetApp volumes. If no subnet with delegation for NetApp Volumes exists then you must provide parameter `netAppSubnet`.


You can use these parameters for the following scenarios:

#### Copying NetApp volumes
The NetApp volumes used in the source RG can be located in any NetApp account and capacity pool. You might use different NetApp accounts in different resource groups. In the target RG, RGCOPY creates a single NetApp account with a single capacity pool that contains all volumes for the target RG. The size of the volumes in the target RG does not need to be the same as in the source RG.

When copying a NetApp volume, you must use two RGCOPY parameters:
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
createVolumes = '1024 @ hanadb/hana/data, hanadb/hana/log'
```

#### Converting NetApp volumes to disks

This also works similar to copying NetApp volumes. Here, you need the following parameters:
- **`snapshotVolumes`** = `@(`**`"rg/account/pool@vol1,vol2..."`**`, ...)`<BR>See parameter description above.
- **`createDisks`** = `@(`**`"size@,mp1,mp2,..."`**`, ...)`<BR>This parameter works just the same as `createVolumes`. However, it creates a new premium SSD disk in the target RG rather than a NetApp volume. The size of the disk can be very small (even 1 GiB) as long as all files of the mount point fit into the new disk.

Example:
```powershell
snapshotVolumes = 'anfAccount/anfPool@anfVolume1, anfVolume2'
createDisks = @(
    '1024 @ vmName/volumes/mount1', 
    '512  @ vmName/volumes/mount2'
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
createDisks = '1024/2048/8 @ vmName/disks/disk1, vmName/disks/disk2'
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
    '1024/2048/8 @ vmName/disks/disk1', 
    '1024/2048/8 @ vmName/disks/disk2'
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
createDisks = @('1024 @ vmName/disks/disk1, vmName/disks/disk2')
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
**`netAppAccountName`** | **[string]**: Name of the created NetApp Account in the target RG.<BR>Default is `rgcopy-<targetRG>`<BR>NetApp Account names must be unique in Azure. This should be no issue when using the default name. Be aware that the NetApp Account name is stored as a constant in the ARM template created by RGCOPY. Therefore, it is not possible to re-use this ARM template for deploying another resource group.
**`netAppServiceLevel`** | **[string]**:Service Level of the created NetApp Pool.<BR>Allowed values: Standard, Premium, Ultra. Default is `Premium`
**`netAppPoolName`** | **[string]**: Name of the created NetApp Pool.<BR>Default is `rgcopy-s-pool`, `rgcopy-p-pool`, `rgcopy-u-pool` (for Service Level **S**tandard, **P**remium, **U**ltra)
**`netAppPoolGB`** | **[int]**: Size of the created NetApp Pool.<BR>Default value is 4096<BR>RGCOPY creates a larger NetApp pool if the sum of all volumes is larger than 4096 GiB. Using this parameter you can increase the capacity pool size in the target RG, even if the size of all created volumes is less than 4096 GiB.
**`smbTier`**	|**[string]**: Tier of SMB share in the source RG for storing the file backups.<BR>Allowed values: Premium_LRS, Standard_LRS. Default is `Premium_LRS`<BR><BR>For cost efficiency, you might delete the Premium SMB share later rather then using a Standard SMB share. See parameter `deleteSourceSA` in section [Cost Efficiency](./rgcopy-docu.md#Cost-Efficiency)
**`createDisksTier`** | **[string]**: By default, disks created by RGCOPY parameter `createDisks` have the minimum performance tier 'P20' to speed-up backup/restore on small disks. You can change the minimum performance tier to any value between 'P2' and 'P50' using parameter `createDisksTier`
**`verboseLog`** |**[switch]**: By setting this switch, RGCOPY writes a more detailed log file during backup/restore and when starting additional scripts.

<div style="page-break-after: always"></div>

***
## Archive Mode
Stopping not needed VMs reduces Azure costs. However, premium disks can cause a significant part of the overall costs. You will be charged for the disks even when all VMs have been stopped. One solution would be changing the disk SKU from Premium_LRS to Standard_LRS. This can be done easily using RGCOPY [Update Mode](./rgcopy-docu.md#Update-Mode).

In **Archive Mode**, a backup of all disks to cost-effective BLOB storage is created. An ARM template that contains the resources of the source RG is also stored in the BLOB storage. After that, you could delete the source RG for saving costs. You can restore the original source RG using the saved ARM template **in the same region**. However, you cannot use RGCOPY for modifying the saved ARM template. This might be needed if you have reached your subscription quota for a used VM size at the point in time you want to restore. Regardless of this, you can always manually modify the ARM template and deploy it without using RGCOPY.

>Be careful when deleting the source RG. RGCOPY does not copy *all* resources in the source RG (see section [Supported Azure Resources](./rgcopy-docu.md#Supported-Azure-Resources)). When using Archive Mode, you should carefully read all warnings in the RGCOPY log file *before* deleting the source RG.

Archive Mode is activated by RGCOPY parameter switch **`archiveMode`**. You must provide parameters `targetRG` and `targetLocation`. The target location might or might not be the same as the location of the source RG. However, the saved BLOBs can only be used for deploying disks in the target location (region).

In Archive Mode, a storage account is created the same way as usual when copying a resource group using RGCOPY with parameter switch `useBlobs`. However, the name of the storage account container is not 'rgcopy'. Instead, the container name is the name of the source RG (after removing special characters). The idea is having just a single (target) resource group that can contain the BLOB backups of many source RGs.

The following example shows how to use parameter `archiveMode`. You could add additional RGCOPY parameters for changing resource properties in the created ARM template. This does not change the source RG. The ARM template will not be deployed. It will just be stored in the BLOB storage:

```powershell
$rgcopyParameter = @{
    sourceSub       = 'Contoso Subscription'
    sourceRG        = 'contoso_source_rg'

    targetRG        = 'contoso_backup_rg'
    targetLocation  = 'eastus'
    archiveMode     = $True
}
.\rgcopy.ps1 @rgcopyParameter
```

After running this, the BLOB storage will contain the following files:
- one BLOB for each disk containing the backup
- the file rgcopy.arm-templates.zip that contains all exported ARM templates, the generated ARM template by RGCOPY and a PowerShell script that can be used for restoring the source RG.
- the RGCOPY zip file containing all logs

The generated PowerShell script in this example looks like this:

```powershell
# generated script by RGCOPY for restoring
$param = @{
    sourceSubUser       = 'user@contoso.com'
    
    # do not change:
    sourceSub           = 'Contoso Subscription'
    sourceRG            = 'contoso_backup_rg'
    targetLocation      = 'eastus'

    # set targetRG:
    targetRG            = 'contoso_source_rg'
    
    # set pathArmTemplate:
    pathArmTemplate     = 'C:\Users\user\rgcopy.contoso_source_rg.TARGET.json'
}
C:\Users\user\rgcopy.ps1 @param
```

The following special parameters can be set in Archive Mode:

parameter|[DataType]: usage
:---|:---
**`archiveMode`**|**[switch]**: Turns on Archive Mode
**`archiveContainer`**|**[string]**: Name of the storage account container used for the backup if you do not want to use the calculated default name. The container 'rgcopy' is reserved for **Copy Mode** and therefore not allowed here.
**`archiveContainerOverwrite`**|**[switch]**: By default, RGCOPY does not allow archiving into an existing container to prevent overwriting a backup. Using this switch, you can skip this safety check.
**`targetSA`**|**[string]**: Name of the storage account used for the backup if you do not want to use the calculated default name. This is the same parameter as in **Copy Mode**.
**`restartBlobs`**<BR>**`justStopCopyBlobs`**<BR>**`justCopyBlobs`**<BR>| Same parameters as in **Copy Mode**. They are described in section [Parameters for BLOB Copy](./rgcopy-docu.md#Parameters-for-BLOB-Copy). These parameters are useful once the long-running BLOB copy fails for any reason.
**`deleteSnapshots`**| Same parameter as in **Copy Mode**. This are described in section [Cost Efficiency](./rgcopy-docu.md#Cost-Efficiency).
**`setVmSize`**<BR>**`setDiskSize`**<BR>**`setDiskTier`**<BR>**`setDiskCaching`**<BR>**`setDiskSku`**<BR>**`setAcceleratedNetworking`**|Same parameters as in **Copy Mode**. They are described in section [Resource Configuration Parameters](./rgcopy-docu.md#Resource-Configuration-Parameters). Be aware that these parameters only have an impact on the created ARM template. The ARM template is not deployed. Properties are not changed in the source RG when using these parameters in **Archive Mode**

In Archive Mode all disks are copied, including detached disks. However, in this mode you cannot copy or convert **Ultra SSD disks** or **NetApp volumes**. You should use parameter `skipVMs` for VMs that have an Ultra SSD disk. parameter `skipDisks` is not allowed in Archive Mode. Once parameter `skipVMs` is set, detached disks are not copied (unless you set parameter `copyDetachedDisks`).
For archiving **Ultra SSD disks** or **NetApp volumes**, you might create a copy of the source RG using parameters `createDisks` and `createVolumes` in RGCOPY **Copy Mode** first. Hereby you can convert them to Premium Storage. In a next step, you can use **Archive Mode** for creating a backup of the just created resource group.

<div style="page-break-after: always"></div>

***
## Update Mode
You can activate RGCOPY Update Mode by setting parameter switch **`updateMode`**. In this mode, you can update resource properties in the source RG. No ARM template is created. No target RG is created or even used. Therefore, parameters `targetRG` and `targetLocation` are not allowed in this mode. Be aware that the RGCOPY log file name also changes in Update Mode, see section [Created Files](./rgcopy-docu.md#Created-Files).

A simple example of this mode looks like this:

```powershell
$rgcopyParameter = @{
    sourceRG        = 'contoso_source_rg'
    updateMode      = $True
    setDiskSku      = 'Standard_LRS'
}
.\rgcopy.ps1 @rgcopyParameter
```

The following special parameters can be set in **Update Mode**:

parameter|[DataType]: usage
:---|:---
**`updateMode`**|**[switch]**: Turns on Update Mode
**`simulate`**|**[switch]**: You can use this switch for checking the status of the source RG. Once this switch is set, nothing is changed in the source RG. Instead, the expected changes are displayed. 
**`stopVMsSourceRG`** |**[switch]**: When setting this switch, RGCOPY stops all VMs in the source RG. <BR>Be aware, that *all* VMs must be stopped anyway when using Update Mode.
**`setVmSize`**<BR>**`setDiskSize`**<BR>**`setDiskTier`**<BR>**`setDiskCaching`**<BR>**`setDiskSku`**<BR>**`setAcceleratedNetworking`**|Same parameters as in **Copy Mode**. However, this time they are used for changing the source RG using Az cmdlets. The parameters are described in section [Resource Configuration Parameters](./rgcopy-docu.md#Resource-Configuration-Parameters).<BR>You can combine all these parameters. RGCOPY will update all required resources (VMs, disks, NICs). When there are several changes of a single resource then the resource will only be updated once (containing all changes). 
**`deleteSnapshots`** |**[switch]**: When setting this switch, RGCOPY deletes snapshots with the extension **'.rgcopy'**. These snapshots have been originally created by RGCOPY.
**`deleteSnapshotsAll`** |**[switch]**: When setting this switch, RGCOPY deletes **all** snapshots in the source RG.
**`createBastion`** =<BR>`'<addrPrefix>@<vnet>'`|Create Bastion:<BR>**vnet:** existing virtual Network name<BR>**addrPrefix:** Address Prefix that is used for creating the new subnet<BR>When setting this parameter the following is created in the source RG by RGCOPY:<BR>- a new subnet 'AzureBastionSubnet'<BR>- a new Public IP Address 'AzureBastionIP'<BR>- a new Bastion 'AzureBastion'.
**`deleteBastion`**|**[switch]**: When setting this switch, RGCOPY deletes the following resources in the source RG:<BR>- the Bastion in the source RG<BR>- the Public IP Address used by the Bastion<BR>- the subnet 'AzureBastionSubnet'
**`netAppServiceLevel`** | **[string]** allowed: Standard, Premium, Ultra<BR>When setting this parameter in **Update Mode**, the Service Level of existing NetApp Pools can be changed. For one pool after the other, a new pool is created using the new Service Level, all volumes are moved to the new pool, finally the old pool is deleted. This does not happen for pools that already have the required Service Level.<BR><BR>For using this feature, you must enable the dynamically change of NetApp Service Levels for your subscription. This is described at https://docs.microsoft.com/en-us/azure/azure-netapp-files/dynamic-change-volume-service-level
**`netAppMovePool`** | **[string]** Pool name in the format `<account>/<pool>`<BR>When setting this parameter, Service Level changes only happens for this given pool. All other pools are not touched by parameter `netAppServiceLevel`
**`netAppMoveForce`** | **[switch]** Parameter for test purposes<BR>When setting this switch, volumes are moved to a new pool even when the Service Level already fits parameter `netAppServiceLevel`
**`netAppPoolName`** | **[string]** in Update mode: Name of the newly created pool if parameter `netAppMovePool` is also set.<BR>By default, the created pool has the name `rgcopy-s1-<old-pool>`, `rgcopy-p1-<old-pool>`, `rgcopy-u1-<old-pool>` (for Service Level **S**tandard, **P**remium, **U**ltra). If the name already exists then the number is increased, for example `rgcopy-s2-my_old_pool_name`.

In Update Mode, you cannot convert Ultra SSD disks or NetApp volumes using parameters `createDisks` and `createVolumes`. **Detached disks** are not ignored in Update Mode. There is no explicit parameter for excluding disks (like `skipDisk` or `skipVMs`). You can update *all* disks or explicitly specify the disk you want to update. Not specified disks are not processed. For example:

```powershell
$rgcopyParameter = @{
    sourceSub       = 'Contoso Subscription'
    sourceRG        = 'contoso_source_rg'
    updateMode      = $True

    # stopVMsSourceRG  = $True
    # simulate         = $True

    # update 3 disks: disk_lun_0, disk_lun_1, disk_lun_3
    SetDiskTier = @(
        'P40 @ disk_lun_0, disk_lun_1',
        'P30 @ disk_lun_3'
    )

    # turn on write accelerator for one disk (write_acc_disc)
    # turn off WA and enable ReadOnly cache for all other disks
    SetDiskCaching  = @(
        'None/True @ write_acc_disc',
        'ReadOnly/False'
    )

    # update all disks and NICs
    setDiskSku      = 'Premium_LRS'
    setAcceleratedNetworking = $True
}
.\rgcopy.ps1 @rgcopyParameter
```

For reducing cost of a resource group that is not in use (all VMs stopped), you could run the following script:

```powershell
$rgcopyParameter = @{
    sourceSub          = 'Contoso Subscription'
    sourceRG           = 'contoso_source_rg'
    updateMode         = $True

    deleteBastion      = $True
    setDiskSku         = 'Standard_LRS'
    deleteSnapshotsAll = $True
}
.\rgcopy.ps1 @rgcopyParameter
```

<div style="page-break-after: always"></div>

***
## Starting Scripts from RGCOPY

RGCOPY can start scripts in specific scenarios. These are either [locally running scripts](./rgcopy-docu.md#Locally-running-scripts) (PowerShell scripts running on the same machine that runs RGCOPY) or [remotely running scripts](./rgcopy-docu.md#Remotely-running-scripts) (scripts running inside the VMs). These scripts have to be developed on your own. RGCOPY continues once the scripts have finished. The ouptut of the scripts is contained in the RGCOPY log file (when using `Write-Output` or `echo`).

In addition, RGCOPY starts scripts for backup/restore. These scripts are part of RGCOPY and cannot be changed. They are used for copying [NetApp Volumes and Ultra SSD Disks](./rgcopy-docu.md#NetApp-Volumes-and-Ultra-SSD-Disks).



RGCOPY passes the following parameters to your scripts:
1. All supplied RGCOPY parameters.
2. Some of the optional RGCOPY parameters, even when not supplied. For example `targetSub`.
3. Parameter `sourceLocation` that contains the region of the source RG
4. Parameter `vmName` that contains the name of the VM that is running the script (or your local machine name for locally running scripts).
5. Parameters `vmSize<vmName>`, `vmCpus<vmName>`, `vmMemGb<vmName>` that contain Azure VM size configuration for all deployed VMs. `<vmName>` is the Azure name of the VM that only contains word characters and numbers. All special characters are removed.
6. Parameter `rgcopyParameters` that contains the names of all passed parameters.

In all scripts you can simply access the passed parameters using variables, for example `$targetSub`. Only *remotely* running *PowerShell* scripts must contain a `param` clause.

RGCOPY uses `Invoke-AzVMRunCommand` for remotely running scripts. RGCOPY terminates with an error message if the output of such a script contains the text `++ exit 1` within the last lines. Be aware that `Invoke-AzVMRunCommand` does only return the last few dozen lines of `stdout` and `stderr`.

### Locally running scripts
RGCOPY can start local PowerShell scripts in the following two scenarios. These scripts have to be developed on your own. An example of such a script is [examplePostDeployment.ps1](./examples/examplePostDeployment.ps1).

parameter|[DataType]: usage
:---|:---
**`pathPostDeploymentScript`**|**[string]**: path to local PowerShell script<BR>You can use this script for deploying additional ARM resources that cannot be exported from the source RG.<BR><BR>When using this RGCOPY parameter, the following happens after deploying the ARM templates (in RGCOPY step *deployment*):<BR>1. SAP is started using parameter `scriptStartSapPath` (see below).<BR>2. The PowerShell script located in `pathPostDeploymentScript` is started.
**`pathPreSnapshotScript`**|**[string]**: path to local PowerShell script<BR><BR>When using this RGCOPY parameter, the following happens:<BR>1. All VMs in the source RG  are started.<BR>2. SAP is started using another script inside a VM. The script has to be specified using parameter`scriptStartSapPath` (see below).<BR>3. The PowerShell script located in `pathPreSnapshotScript` is started.<BR>4. RGCOPY waits by default for 5 minutes. This can be configured using parameter **`preSnapshotWaitSec`**<BR>5. **All VMs in the source RG are stopped** (even when they where running before RGCOPY was started)<BR>6. The disk snapshots are created.

### Remotely running scripts

For the following scenarios, remotely running scripts (running inside the VMs) can be started by RGCOPY. For Windows VMs, the scripts must be PowerShell scripts. For LINUX VMs, the scripts must be Shell scripts. Examples of such scripts are [exampleStartAnalysis.ps1](./examples/exampleStartAnalysis.ps1) and [exampleStartAnalysis.sh](./examples/exampleStartAnalysis.sh).

parameter|[DataType]: usage
:---|:---
**`scriptStartSapPath`** =<BR>`'[local:]<path>@<VM>[,...n]'`|**[string]**: Runs a script for starting the SAP system (database and NetWeaver), for example `'/root/startSAP.sh @ sapserver'`<BR><BR>**path**: Path of the script to be started. The script path is typically inside the VM. However, you can use a script that is stored on your local PC by prefixing 'local:', for example `'local:c:\scripts\startSAP.sh @ sapserver'` <BR><BR>**VM**: Name of the VM where the script should be executed. If you specify several comma seperated VM names then the script will be executed on each VM, one after the other, for example  `'/root/startSAP.sh @ sapserver1, sapserver2'`<BR><BR>Rather than specifying a script name, you can exexute a command, for example `'su - sidadm -c startsap @ sapserver'`<BR><BR>The script is started using PowerShell cmdlet `Invoke-AzVMRunCommand`. This will fail if the script does not finish within roughly half an hour. Therefore, you cannot use this for long running tasks (as an SAP benchmark). In this case, you must write a script that triggers or schedules the long running task and finishes without waiting for the task to complete.
**`scriptStartLoadPath`** =<BR>`'[local:]<path>@<VM>[,...n]'`|**[string]**: Runs a script for starting SAP Workload (SAP benchmark).<BR><BR>Same details apply here as for parameter `scriptStartSapPath` above.
**`scriptStartAnalysisPath`** =<BR>`'[local:]<path>@<VM>[,...n]'`|**[string]**: Runs a script for starting Workload Analysis.<BR><BR>Same details apply here as for parameter `scriptStartSapPath` above.
**`startWorkload`**|**[switch]**: Enables the last step of RGCOPY: *Workload and Analysis*.<BR><BR>This switch enables the RGCOPY step *Start Workload*. In this step, the following is performed:<BR>1. SAP is started using parameter `scriptStartSapPath`<BR>2. The workload is started using parameter `scriptStartLoadPath`<BR>3. The workload analysis is started using parameter `scriptStartAnalysisPath`<BR><BR>Even when [Azure Tags](./rgcopy-docu.md#RGCOPY-Azure-Tags) are used, SAP workload does not start automatically. You must set the switch `startWorkload` in addition.
**`vmStartWaitSec`**|**[int]**: Wait time in seconds, default value: `5 * 60`<BR><BR>After starting the VMs, RGCOPY gives the VMs some time to become fully operational. This delay might be needed for starting all services (for example, SSH service) inside the VM.
**`vmAgentWaitMinutes`** |**[int]**: Maximum wait time in minutes, default value: `30`<BR><BR>Before running Invoke-AzVMRunCommand, RGCOPY waits until the Azure Agent status is 'Ready'. This is checked every minute. If the status is still not 'Ready' after the maximum wait time then RGCOPY gives up and terminates with an error.

> For remotely running scripts, RGCOPY uses the cmdlet **`Invoke-AzVMRunCommand`** that connects to the Azure Agent running inside the VM. Make sure that you have installed a **recent version of the Azure Agent**. See also https://docs.microsoft.com/en-US/troubleshoot/azure/virtual-machines/support-extensions-agent-version.

`Invoke-AzVMRunCommand` expects that the script finishes within roughly one hour. If the script takes longer then `Invoke-AzVMRunCommand` (and RGCOPY) terminates with "Long running operation failed". If you want to use longer running scripts then you must write a wrapper script that just triggers or schedules your original script. The wrapper script can then be started using RGCOPY.

RGCOPY writes the working directory of `Invoke-AzVMRunCommand` to stdout respectively stderr (and the RGCOY log file), for example `/var/lib/waagent/run-command/download/4`. You might double check the log files in this directory once `Invoke-AzVMRunCommand` fails with a timeout.


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

    scriptStartSapPath       = '/root/startSAP.sh @ SAPAPP'
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

<div style="page-break-after: always"></div>

***
## Special cases

### Merging and Cloning VMs
Normally, RGCOPY is used for copying all resources of a source RG into a new (or empty) target RG. By using parameter `setVmMerge` you can copy discrete VMs and attach them to an existing subnet in the target RG. You can use this to copy a standard VM (e.g. jump box) into several other resource groups.
By using parameter `setVmName`, you can rename the VMs in the target RG. Herby, you can copy a VM even in the source RG (source RG = target RG). The VM disks are automatically renamed. You might use this for cloning application servers. Be aware that parameter `setVmName` does not rename the VM on OS level.

parameter|[DataType]: usage
:---|:---
**`setVmMerge`**= <BR>`@("net/subnet@vm1,vm2", ...)`|**[string] or [array]**: Merge VMs of the source RG into an existing subnet of the target RG:<BR>**vm**: VM name in source RG<BR>**net**: vnet name in target RG<BR>**subnet**: subnet name in target RG<BR>When setting this parameter, *only* the specified VMs and their disks are copied. The disks are automatically renamed. A new network interface using a dynamic IP address (IPv4) is created and attached to the existing subnet (in the target RG). A new public IP address is created if any network interface of the VM in the source system has a public IP address.
**`setVmName`**	= <BR>`@("vmNameNew@vmNameOld", ...)`			|Rename VM: <BR>**vmNameOld**: VM name in source RG <BR>**vmNameNew**: VM name in target RG <BR>This renames the Azure *resource* name of the copied VM in the target RG. It does not touch the original VM. RGCOPY does not rename the *host* name of the VM. You have to do this on OS level inside the VM after the VM has been copied.<BR>You can use this parameter also independent from `setVmMerge`.
**`renameDisks`**|**[switch]**: Renames all disks of all VMs with the following naming convention:<BR>- OS disk: `<vmName>__disk_os`<BR>- Data disks: `<vmName>__disk_lun_<lunNumber>`<BR>This parameter is automatically set when using parameter `setVmMerge`. However, you can set this parameter also independent from `setVmMerge`.
**`setVmZone`**<BR>**`setVmFaultDomain`**<BR>**`createAvailabilitySet`**<BR>**`createProximityPlacementGroup`**<BR>**`createVmssFlex`**| These parameters have already been described above. They can also be used in combination with `setVmMerge`. However, they work differently in this case:<BR>No *new* Availability Set, Proximity Placement Group or VM Scale Set is created. Instead, they already have to exist in the target RG.

The following example clones the VM 'app1' to 'app2' and puts the new VM app2 into the existing availability set 'avset1'.
In this example, the source RG and the target RG are identical. Keep in mind that this does not change the OS name of 'app2'. This has to be done after RGCOPY has created the azure resource 'app2':

```powershell
$rgcopyParameter = @{
    sourceRG               = 'SAP_master'
    targetRG               = 'SAP_master'
    targetLocation         = 'westus'

    setVmMerge             = 'vnet/subnet @ app1'
    setVmName              = 'app2 @ app1'
    createAvailabilitySet  = 'avset1/3/5 @ app1'
}
.\rgcopy.ps1 @rgcopyParameter
```

### VM Extensions
You can install several VM extensions. You can skip the installation of all extensions by using RGCOPY switch parameter `skipExtensions`.

parameter|[DataType]: usage
:---|:---
**`installExtensionsAzureMonitor`** |**[array]**: Names of VMs for deploying the Azure Agents<BR>(AzureMonitorWindowsAgent or AzureMonitorLinuxAgent).<BR>The Azure Agent is intalled on all VMs when setting the parameter to `@('*')`
**`installExtensionsSapMonitor`** |**[array]**: Names of VMs for deploying the SAP Monitor Extension.<BR>Alternatively, you can set the Azure tag `rgcopy.Extension.SapMonitor` for the VM. If you do not want to install the SAP Monitor Extension although the Azure tag has been set, use switch `ignoreTags`.

### Azure Monitor for SAP
RGCOPY can copy *up to one* AMS instance and multiple AMS providers. For installing the SapHana provider, SAP HANA must already be running. However, this is not guarantied during the ARM deployment. Therefore, RGCOPY creates a separate ARM template just for the AMS instance and providers. This ARM template will be deployed in the target RG after SAP HANA has been started. Therefore, RGCOPY is using the script `scriptStartSapPath` as described above.

>**Azure Monitor for SAP (AMS) is currently in public review with version v1. Version v2 will probably be in public review in 2022. RGCOPY only supports version v1. Once version v2 is available, RGCOPY might remove its support for AMS completely.**

The following RGCOPY parameters exist for AMS:
parameter|[DataType]: usage
:---|:---
**`createArmTemplateAms`**|**[switch]**: Export an ARM template for the AMS resources from the source RG.<BR>If you want to copy the AMS instance and providers then you must either use parameter `createArmTemplateAms` or `pathArmTemplateAms`.
**`pathArmTemplateAms`**|**[string]**: Use an exsisting AMS ARM template for deploying AMS in the target RG
**`amsInstanceName`**|**[string]**: Name of the AMS instance in the target RG.<BR>When not setting this parameter, RGCOPY calculates an AMS instance name based on the target RG name.
**`amsWsName`** |**[string]**: Name of an existing log analytics workspace that should be used by AMS.<BR>If not set, then AMS creates a new workspace in the managed resource group.
**`amsWsRG`**   |**[string]**: Resource group name of the existing log analytics workspace used by AMS. <BR>It must be in the target subscription.
**`amsWsKeep`** |**[switch]**: By setting this switch, the AMS instance in the target RG is using the same log analytics workspace as the source RG. No new workspace is created. Parameters `amsWsName` and `amsWsRG`are ignored.
**`amsShareAnalytics`**  |**[switch]**: When setting this switch then AMS enables Customer Analytics. In this case, collected AMS data is visible for Microsoft support. This is not the case by default (without setting this switch).
**`dbPassword`**|**[SecureString]**: For AMS providers SapHana and MsSqlServer, you must provide the database password to RGCOPY as a secure string as follows:<BR>`dbPassword = (ConvertTo-SecureString -String 'secure-password' -AsPlainText -Force)`
**`amsUsePowerShell`**|**[boolean]**: (default value: \$True): This parameter just defines, *how* RGCOPY is installing AMS:<BR><BR>When set to **\$False**, then RGCOPY uses an ARM template for installing AMS. In this case, the PowerShell module *Az.HanaOnAzure* is not needed. The parameter `dbPassword` must be supplied during ARM template *creation*. Be aware, that the created ARM template contains the **password in plain text**. This is not the case when parameter `amsUsePowerShell` is not used.<BR><BR>When set to **\$True**, then RGCOPY uses PowerShell cmdlets for installing AMS. In this case, the newest version of the PowerShell module Az.HanaOnAzure must be installed. The parameter `dbPassword` must be supplied during ARM template *deployment*.

### Virtual Network Peerings for AMS in the source RG
RGCOPY can copy Azure virtual network peerings for AMS instances. This is useful because AMS is only supported in some specific regions yet, for example in eastus. If your resource group is located in an unsupported region then you can create an AMS instance in an additional virtual network in a supported region. Afterwards, you create a network peering between your main virtual network and the additional virtual network. **The AMS instance and all virtual networks must be located in the source RG.** RGCOPY does not support an AMS instance for monitoring resources in different resource groups. However, AMS instances in different resource groups can share the same log analytics workspace.


### Cost Efficiency
You can save Azure costs by using RGCOPY [Archive Mode](./rgcopy-docu.md#Archive-Mode) and [Update Mode](./rgcopy-docu.md#Update-Mode) as described above. This chapter describes how to save costs caused by RGCOPY.

By default, RGCOPY does not delete its intermediate storage (snapshots, BLOBs, and file backups). This can save a lot of time when regularly copying the same resource group. However, the intermediate storage results in Azure charges.

The following parameters activate additional steps at the very end of an RGCOPY run:

parameter|[DataType]: usage
:---|:---
**`deleteSnapshots`** |**[switch]**: By setting this switch, RGCOPY deletes those **snapshots** in the source RG that have been created by the current run of RGCOPY.<BR>When skipping some VMs or disks, RGCOPY does not create snapshots of these disks and does not delete them afterwards.
**`deleteSourceSA`** |**[switch]**: By setting this switch, RGCOPY deletes the storage account in the source RG that has been used for storing **file backups** (during the copy process of NetApp volumes or Ultra SSD disks).
**`deleteTargetSA`** |**[switch]**: By setting this switch, RGCOPY deletes the storage account in the target RG that has been used for storing **BLOBs** (when copying to a different region).
**`stopVMsTargetRG`** |**[switch]**: When setting this switch in **Copy Mode**, RGCOPY stops all VMs in the target RG after deploying it. Typically, this is not what you want. However, it might be useful for saving costs when deploying a resource group that is not used immediately.

Tip: You can use the following RGCOPY parameters for reducing cost in the target RG: `setVmSize`, `setDiskSku`, `setDiskTier`, `createDisksTier`, `netAppServiceLevel`, `netAppPoolGB`, `smbTier`, and `skipBastion`.
The *default* values of some RGCOPY parameters also have some cost impact. See parameters `createDisksTier`, `setDiskSku`, and `setLoadBalancerSku` above.

The behavior of RGCOPY changed for copying NetApp volumes or Ultra SSD disks. It now starts only *needed* Ms in the source RG. These VMs are stopped again by RGCOPY. In earlier versions of RGCOPY *all* VMs were started in the source RG and you had to stop them on your own.

<div style="page-break-after: always"></div>

***
## Appendix

### Supported Azure Resources
RGCOPY uses a list of well-known resources and properties. **All other resources in the source Resource RG are skipped and not copied to the target RG**. This feature was introduced to avoid RGCOPY issues caused by future resource properties.

The following ARM resources are copied from the source RG:
- Microsoft.Compute/virtualMachines
- Microsoft.Compute/disks
- Microsoft.Compute/availabilitySets
- Microsoft.Compute/proximityPlacementGroups
- Microsoft.Compute/virtualMachineScaleSets
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

**Resources must not refer to resources in other resource groups** with two exceptions:
- VMs might use NICs from remote resource groups
- NICs might be connected to a subnet of a remote resource group

In these cases, RGCOPY creates a copy of the remote NICs, vnets and subnetsin the target RG. The resource names are changed (prefixed with 'remote-') to make sure that they are unique within the target RG.


### Changes in the source RG
- RGCOPY creates snapshots of all disks in the source RG with the name **\<diskname>.rgcopy**.
- if BLOB copy is used, then RGCOPY grants access to the snapshots at the beginning and revokes this access at the end of the BLOB copy.
- If RGCOPY parameter `snapshotVolumes` is supplied, then snapshots of NetApp volumes with the name **rgcopy** are created.
- If RGCOPY parameter `createVolumes` or `createDisks` is supplied, then a **storage account** with a premium SMB share is created in the source RG. All needed VMs are started (and stopped later) in the source RG. In these VMs, the SMB share **/mnt/rgcopy** is mounted, the service **sapinit** is stopped and process **hdbrsutil** is killed. The storage account will not be deleted again unless you use RGCOPY parameter `deleteSourceSA`.
- If RGCOPY parameter `pathPreSnapshotScript` is supplied, then the specified PowerShell script is executed before creating the snapshots. In this case, all VMs are started, SAP is started, the PowerShell script (located on the local PC) is executed and finally **all VMs are stopped in the source RG**

### Application Consistency
>Snapshots of disks are made independently. However, database files could be distributed over several data disks. Using these snapshots for creating a VM could result in inconsistencies and database corruptions in the target RG. Therefore, RGCOPY cannot copy VMs with more than one data disk while the source VM is running. However, RGCOPY does work with running VMs that have only a single data disk (and no NetApp volume) or a single NetApp volume (and no data disk).

In the unlikely case that database files are distributed over the data disk (or volume) and the OS disk, you must stop the VM before starting RGCOPY. RGCOPY does not (and cannot) double check this unlikely case.

>When using NetApp volumes, RGCOPY does not know which volume belongs to which VM. Therefore, you must specify the volume snapshots using RGCOPY parameter **`snapshotVolumes`**. Not doing so results in using an outdated snapshot and inconsistent VM in the target RG.

>RGCOPY can convert a managed disk in the source RG to a NetApp volume in the target RG (and vice versa) by changing mount points. Herby, a file backup is made from the mount points in the source RG. A mount point is either a disk or a NetApp volume.<BR>Before starting the backup/restore, RGCOPY double checks that there is no open file in the mount point directory. However, it does not check this *during* backup/restore. Therefore, you must you must make sure that no LINUX service or job that changes files in the mount point directories is started during backup/restore.

### Multiple instances of RGCOPY
It is not allowed, running multiple instances of RGCOPY at the *same* time for deploying/changing the *same* target RG. However, running multiple instances of RGCOPY using the same source RG is possible with the following restrictions:
1. each parallel running RGCOPY instance must have its own working directory. This can be forced by setting a different value for parameter `pathExportFolder` for each RGCOPY instance.
2. The source RG must not be changed. Therefore:
    - snapshots must not be created (use parameter `skipSnapshots`)
    - the following parameters are *not* allowed: `snapshotVolumes`, `createVolumes`, `createDisks`, and `pathPreSnapshotScript`
    - only one of the parallel running RGCOPY instances uses BLOB copy (source RG and target RG are in different regions). When starting a BLOB copy while another BLOB copy from the same source RG is still running, then the first BLOB copy fails.

RGCOPY does not double check whether another instance of RGCOPY is running. When running multiple instances of RGCOPY in parallel, you must take care of the restrictions on your own.


### Created Files
RGCOPY creates the following files in the user home directory (or in the directory which has been set using RGCOPY parameter `pathExportFolder`) on the PC where RGCOPY is running:

file|*[DataType]*: usage
:---|:---
`rgcopy.<source_RG>.SOURCE.json`|Exported ARM template(s) from the source RG(s).
`rgcopy.<target_RG>.TARGET.json`<BR>`rgcopy.<source_RG>.TARGET.json`|ARM template which is generated by RGCOPY<BR>*Ditto* when using **Archive Mode**
`rgcopy.<target_RG>.AMS.json`<BR><BR>`rgcopy.<source_RG>.AMS.json`|ARM template for Azure Monitor for SAP (AMS).<BR>It will only be created if the source RG contains an AMS Instance.<BR>*Ditto* when using **Archive Mode**
`rgcopy.<target_RG>.TARGET.log`<BR>`rgcopy.<source_RG>.SOURCE.log`|Standard RGCOPY log file<BR>*Ditto* when using **Update Mode**
`rgcopy.txt`|Backup of the running script rgcopy.ps1 used for support
`rgcopy.<source_RG>.RESTORE.ps1.txt`|Generated PowerShell script when using **Archive Mode**
`rgcopy.<target_RG>.<time>.zip`<BR>`rgcopy.<source_RG>.<time>.zip`| Compressed ZIP file that contains all files above<BR>*Ditto*  when using **Update Mode**
`rgcopy.arm-templates.zip`|ZIP file containing ARM templates when using **Archive Mode**
`rgcopy.<target_RG>.TEMP.json`<BR>`rgcopy.<target_RG>.TEMP.txt`| temporary files


### Required Azure Permissions
RGCOPY can be executed using any Azure Security Principal (Azure User, Service Principal or Managed Identity). You can use Azure role-based access control for assigning the role subscription `Owner` or `Contributor` to the Security Principal. However, you could use more restrictive roles for running RGCOPY. In brief, RGCOPY typically needs permissions for the following resource groups:
1. Source RG: read permission and permission to create snapshots
2. Target RG: all permissions on the target RG
3. Some subscription level read permissions and the permission to create a new resource group

In detail, RGCOPY needs the permissions to execute the following cmdlets:

Resource Group| PowerShell cmdlet
:---|:---
Source RG | Export-AzResourceGroup<BR>Get-AzVM<BR>Get-AzDisk<BR>Get-AzNetworkInterface<BR>Get-AzVirtualNetwork<BR>Get-AzBastion<BR>Get-AzNetAppFilesVolume<BR>New-AzNetAppFilesSnapshot<BR>Remove-AzNetAppFilesSnapshot<BR>Stop-AzVM<BR>Start-AzVM<BR>Get-AzStorageAccount<BR>New-AzStorageAccount<BR>Get-AzRmStorageShare<BR>New-AzRmStorageShare<BR>New-AzSnapshot<BR>Remove-AzSnapshot<BR>New-AzSnapshotConfig<BR>Grant-AzSnapshotAccess<BR>Grant-AzDiskAccess<BR>Revoke-AzSnapshotAccess<BR>Revoke-AzDiskAccess<BR>Get-AzStorageAccountKey<BR>Invoke-AzVMRunCommand
Source RG<BR>when using<BR>**Update Mode**| Set-AzVMOsDisk<BR>Set-AzVMDataDisk<BR>Update-AzVM<BR>Update-AzDisk<BR>Set-AzNetworkInterface<BR>Get-AzVirtualNetwork<BR>Add-AzVirtualNetworkSubnetConfig<BR>Remove-AzVirtualNetworkSubnetConfig<BR>Set-AzVirtualNetwork<BR>Get-AzPublicIpAddress<BR>New-AzPublicIpAddress<BR>Remove-AzPublicIpAddress<BR>New-AzBastion<BR>Remove-AzBastion
Target RG | Get-AzVM<BR>Get-AzDisk<BR>Get-AzNetAppFilesVolume<BR>New-AzStorageContext<BR>Get-AzStorageBlob<BR>Get-AzStorageBlobCopyState<BR>Start-AzStorageBlobCopy<BR>Stop-AzStorageBlobCopy<BR>Stop-AzVM<BR>Get-AzStorageAccount<BR>New-AzStorageAccount<BR>Get-AzRmStorageContainer<BR>New-AzRmStorageContainer<BR>Get-AzStorageAccountKey<BR>New-AzSapMonitor<BR>New-AzSapMonitorProviderInstance<BR>Set-AzVMAEMExtension<BR>Invoke-AzVMRunCommand
Target RG<BR>when using parameter<BR>`setVmMerge` | Get-AzAvailabilitySet<BR>Get-AzVmss<BR>Get-AzProximityPlacementGroup<BR>Get-AzNetworkInterface<BR>Get-AzPublicIpAddress<BR>Get-AzVirtualNetwork
Other RGs<BR>when using other special<BR>RGCOPY parameters | Get-AzOperationalInsightsWorkspace<BR>Get-AzOperationalInsightsWorkspaceSharedKey<BR>Get-AzNetAppFilesVolume<BR>New-AzNetAppFilesSnapshot<BR>Remove-AzNetAppFilesSnapshot<BR>Get-AzRmStorageContainer
RG independent | Get-AzSubscription<BR>Get-AzResourceGroup<BR>New-AzResourceGroup<BR>Get-AzVMUsage<BR>Get-AzComputeResourceSku<BR>Get-AzProviderFeature<BR>Get-AzLocation<BR>New-AzResourceGroupDeployment

If you do not want to assign permissions for `New-AzResourceGroup` then you can create the target RG before starting RGCOPY. RGCOPY can deploy into an existing target RG.

### RGCOPY Azure Tags
For starting a workload test you need two things:
1. A source RG with the workload (VMs containing SAP System and script for starting SAP)
2. The deployment tool (RGCOPY)

RGCOPY tags are used to decouple these two parts. For example, the path of the SAP start script should not be part of the deployment (RGCOPY parameter `scriptStartSapPath`). It should rather be part of the workload. You can achieve this by setting the Azure Tag `rgcopy.ScriptStartSap` on any VM in the source RG. Keep in mind that this is a tag of a VM , not a tag of the resource group.

With RGCOPY Azure TAgs you can impact the RGCOPY behavior. These tags will also be copied to the VMs in the target RG. The tags are evaluated by RGCOPY as long as parameter switch **`ignoreTags`** is not set:

virtual machine tag|[DataType]: usage
:---|:---
**`rgcopy.DeploymentOrder`**  |**[int]**: When not setting parameter `setVmDeploymentOrder`, the value of the tag is used to define the deployment order of the VM (that has the tag)
**`rgcopy.Extension.SapMonitor`**       |**[string]**: When not setting parameter `installExtensionsSapMonitor` and setting the tag to 'true', the Azure Enhanced Monitoring Extension for SAP will be installed on the vm (that has the tag).

The following 3 tags must contain the VM name in their value (for example, tag `rgcopy.ScriptStartSap` with value `/root/startSAP.sh@vm2`). Therefore, they can be set on any VM. However, you should not set the same tag using different values on different VMs. 

virtual machine tag|[DataType]: usage
:---|:---
**`rgcopy.ScriptStartSap`**   |**[string]**: Sets the parameter `scriptStartSapPath` to the value of the tag <BR>if the parameter is not already explicitly set (and `ignoreTags` is not set).
**`rgcopy.ScriptStartLoad`**  |**[string]**: Sets the parameter `scriptStartLoadPath` to the value of the tag <BR>if the parameter is not already explicitly set (and `ignoreTags` is not set).
**`rgcopy.ScriptStartAnalysis`**|**[string]**: Sets the parameter `scriptStartAnalysisPath` to the value of the tag <BR>if the parameter is not already explicitly set (and `ignoreTags` is not set).

In addition, RGCOPY writes the following two tags. These are **tags of the Resource Group** while all other tags above are **tags of the Virtual Machine**
resource group tag|[DataType]: usage
:---|:---
**`Owner`**|**[string]**: Default value is `targetSubUser`.<BR>You can set the tag to any value by using parameter **`setOwner`**.<BR>When setting this parameter it to $Null, no "Owner" tag will be created.
**`Created_by`**|**[string]**: This tag is set to 'rgcopy.ps1' in the target RG.

You can easily read all Azure VM tags of a resource group using the PowerShell script tag-get.ps1:

```powershell
# tag-get.ps1
#Requires -Version 7.0
param (
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
param (
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
param (
    $resourceGroup 
)
tag-set.ps1 $resourceGroup vm1 'rgcopy.DeploymentOrder=1'
tag-set.ps1 $resourceGroup vm2 'rgcopy.DeploymentOrder=2'
tag-set.ps1 $resourceGroup vm3 'rgcopy.DeploymentOrder=2'
tag-set.ps1 $resourceGroup vm1 'rgcopy.Extension.SapMonitor=true'
tag-set.ps1 $resourceGroup vm2 'rgcopy.ScriptStartSap=/root/startSAP.sh@vm2'
```


### Analyzing Failed Deployments
Azure is validating an ARM template as the first step of an deployment. This validation might fail for various reasons. In this case, you can see the errors **in the output of RGCOPY** (on the host and in the RGCOPY log file). RGCOPY performs several checks (including quota of VM families) before starting the deployment. The screenshot below is from a deployment that explicitly turned off RGCOPY quota checks (using RGCOPY switch `skipVmChecks`)

If the ARM template validation succeeds but errors occur during deployment then you can check details of the deployment errors **in the Azure Portal**.

!["failedDeploymentRGCOPY"](/images/failedDeployment.png)
