# RGCOPY documentation
***
**Version: 0.9.77<BR>SEptember 2026**
***
RGCOPY (**R**esource **G**roup **COPY**) is a tool that copies resources of an Azure resource group (**source RG**) to a new resource group (**target RG**). It can copy a whole landscape consisting of many servers within a single Azure resource group. The target RG might be in a different region or subscription. RGCOPY is running on **Windows** and in a **Linux** VM.

RGCOPY has been developed for copying and testing SAP systems in Azure. Therefore, it [supports](./rgcopy-docu.md#Supported-Azure-Resources) the most important Azure resources needed for SAP, for example **VMs**, **disks**, **load balancers**, storage accounts including the content of **containers**, **SMB** and **NFS shares**.

 >:memo: **Note:** Recent versions of *RGCOPY* can create parallel running *AzCopy* jobs for copying disks to another region (by using parameter `useAzCopy`). This is the [fastest possible way for cross-region disk copy]( https://techcommunity.microsoft.com/blog/sapapplications/accelerating-cross-region-azure-disk-copying/4539245).
 If you just want to copy disks you could use AzCopy without RGCOPY. However, this would be much more complicated because you would have to create network rules, user delegation tokens and SAS tokens on your own. RGCOPY handles these tasks for you and coordinates concurrent jobs. In addition, RGCOPY takes care of special cases, such as OS disks of confidential VMs that require three blob copies per disk instead of a single one.

## Overview
### RGCOPY operation modes

RGCOPY has different operation modes. By default, RGCOPY is running in Copy Mode. 
- In **[Copy Mode](./rgcopy-docu.md#Workflow)**, a BICEP template is created and deployed in the target RG. Disks are copied using snapshots. You can change several [resource properties](./rgcopy-docu.md#Resource-Configuration-Parameters) in the target RG:
    - Changing **VM size**, disk performance tier, disk bursting, disk caching, Write Accelerator, Accelerated Networking, ...
    - Adding, removing, and changing [availability](./rgcopy-docu.md#Parameters-for-Availability) configuration: **Proximity Placement Groups**, **Availability Sets**, **Availability Zones**, and **VM Scale Sets Flexible**.
    - Converting **disk SKUs** from and to `Premium_LRS`, `StandardSSD_LRS`, `Standard_LRS`, `Premium_ZRS`, `StandardSSD_ZRS`, `UltraSSD_LRS` and `PremiumV2_LRS`. Changing the logical sector size is not possible. Disks are copied using full or incremental snapshots, snapshot copy, blob copy or AzCopy. 
    - Renaming resources (VMs, disks, NICs, PIPs, VNETs, subnets) and **changing Address Space of VNETs** and subnets.
    - Converting disks to NetApp Volumes and vice versa using [file copy](./rgcopy-docu.md#File-Copy-of-NetApp-Volumes).
- In **[Clone Mode](./rgcopy-docu.md#Clone-Mode)**, a VM is cloned within the same resource group. This can be used for changing VM zone, availibility set, PPG or VMSS Flex without deleting the existing VM.
- In **[Merge Mode](./rgcopy-docu.md#Merge-Mode)**, a VM is merged into a different resource group. This can be used for copying a jump box to a different resource group.

### Installation
- Install the newest version of **PowerShell 7**
- Install Azure PowerShell Module **Az** in the newest version: <BR>`Install-Module -Name Az -Scope AllUsers -AllowClobber -Force`
- When copying or creating NetApp resources, install Azure PowerShell Module **Az.NetAppFiles**,
- Download the RGCOPY repository from GitHub (`Download ZIP` from the popup-menu `<> Code`). Unblock the downloaded zip file using the PowerShell command `Unblock-File -path <zip file name>` and extract the zip file to the **user home directory (~)**.
- RCCOPY automatically installs **BICEP** and **AZCOPY** on Windows and Linux if it's not already installed. If you want to upgrade an existing version of BICEP or AZCOPY then start RGCOPY with parameters `updateBicep` and `updateAzcopy` once.
- In PowerShell 7, run **`Connect-AzAccount -AuthScope Storage -Subscription '<SubscriptionName>'`** for each subscription and each Azure Account that will be used by RGCOPY.
- The used Azure accounts should have the RBAC role **`Contributor`** in the source RG and in the target subscription (in the target RG, if it already exists). Additional RBAC roles for storage accounts are required for multi-tenant scenarios or when file copy or storage account copy is used (see below). This is even the case when RBAC role `Owner` is assigned.

### Examples
The following examples show the usage of RGCOPY. In all examples, a source RG with the name 'SAP_master' is copied to the target RG 'SAP_copy'. For better readability, the examples use [parameter splatting](https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_splatting). Before starting RGCOPY, you must run the PowerShell cmdlet `Connect-AzAccount` to create the credentials.

```powershell
# connect to Azure
Update-AzConfig -EnableLoginByWam $true

Connect-AzAccount `
    -AuthScope 'Storage' `
    -TenantId '7b5ebd57-e5fd-445f-a920-55897cd71921' `
    -Subscription 'Contoso Subscription'


# start RGCOPY using cached credentials
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'
}
.\rgcopy.ps1 @rgcopyParameter
```

You might have cached credentials for different subscriptions and users. In this case, you must specify user and subscription using RGCOPY parameters:


```powershell
$rgcopyParameter = @{
    # parameters for subscription and user 
    sourceSub       = 'Contoso Subscription'
    sourceSubUser   = 'user@contoso.com'
    sourceSubTenant = '7b5ebd57-e5fd-445f-a920-55897cd71921'

    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'
}
.\rgcopy.ps1 @rgcopyParameter
```

You can store often used parameters in a separate parameter file and pass the filename to RGCOPY. The example above looks like this when having the parameter file `parameterFiles\contoso.json` 

```powershell
$rgcopyParameter = @{
    # using a parameter file
    parameterFile   = 'parameterFiles\contoso.json'

    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'
}
.\rgcopy.ps1 @rgcopyParameter
```

```json
{
    // file 'parameterFiles\contoso.json'
    "sourceSub": "Contoso Subscription",
    "sourceSubUser": "user@contoso.com",
    "sourceSubTenant": "7b5ebd57-e5fd-445f-a920-55897cd71921",

    "targetSub": "Contoso Subscription",
    "targetSubUser": "user@contoso.com",
    "targetSubTenant": "7b5ebd57-e5fd-445f-a920-55897cd71921"
}
```

You can change almost all properties of VMs and disks in the target RG. The following example changes the VM size to Standard_M16ms (for VMs HANA1 and HANA2), Standard_M8ms (for VM SAPAPP) and Standard_D2s_v4 (for all other VMs):
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

### Workflow
In **Copy Mode**, the workflow of RGCOPY consists of the following steps. RGCOPY decides on its own for each step whether it is needed. However, you can skip each step separately using an RGCOPY switch parameter.

Step|parameter<BR>skip switch|usage
:---|:---|:---
:clock12: *create BICEP template*|**`skipArmTemplate`**|This step creates the BICEP template that will used for deploying in the target RG. <BR>:memo: **Note:** The template refers either to the snapshots in the source RG or target RG. Therefore, the template is only valid as long as these snapshots exist.<BR>:warning: **Warning:** Using various RGCOPY parameters, you can change [properties](./rgcopy-docu.md#Resource-Configuration-Parameters) of resources (e.g. VM size) compared with the Source RG. Be aware that some properties are changed to default values even when not explicitly using RGCOPY parameters.
:clock1: *create snapshots*|**`skipSnapshots`**|This step creates snapshots of disks (and [NetApp Volumes](./rgcopy-docu.md#File-Copy-of-NetApp-Volumes)) in the source RG. During this time, VMs with more than one data disk must be stopped. See section [Application Consistency](./rgcopy-docu.md#Application-Consistency) for details. <BR> :bulb: **Tip:** When setting parameter switch **`stopVMsSourceRG`**, RGCOPY stops *all* VMs in the source RG before creating snapshots.
:clock2: *create backups*|**`skipBackups`**|This step is only needed when using (or converting) [NetApp Volumes](./rgcopy-docu.md#File-Copy-of-NetApp-Volumes) on LINUX. A file backup of specified mount points is created on an Azure NFS file share in the source RG.
:clock3: *copy snapshots*|**`skipRemoteCopy`**|In this step, the snapshots in the source RG are copied to snapshots or BLOBs in the target RG. This step is not needed when the source RG is in the same region as the target RG and when using the same azure user for both RGs.
:clock4: *deployment*||The deployment consists of several part steps:<ul><li>*deploy VMs:* Deploy BICEP template in the target RG.<BR>Part step can be skipped by **`skipDeployment`**</li><li>*restore backups:* Restore file backup on disks or [NetApp Volumes](./rgcopy-docu.md#File-Copy-of-NetApp-Volumes) in the target RG if needed.<BR> Part step can be skipped by **`skipRestore`**</li><li>*install VM Extensions*: install [VM Extensions](./rgcopy-docu.md#VM-Extensions) <BR>Part step can be skipped by **`skipExtensions`**</li></ul>
:clock5: *start workload*| *optional step* | This step is used for testing SAP Workload. It has to be explicitly activated using switch **`startWorkload`**.
:clock6: *cleanup*| *optional step* | By default, created snapshots in the source RG are not deleted by RGCOPY. <BR>:bulb: **Tip:** you can activate a cleanup using RGCOPY parameters. See section [Cost Efficiency](./rgcopy-docu.md#Cost-Efficiency) for details.

> :bulb: **Tip:** When setting the parameter switch **`simulate`**, only a BICEP template is created. All other steps are skipped. This is useful for checking whether configured resource changes are possible (VM size available in target region? Disk properties compatible with VM size? Subscription quota sufficient? ...)


### Disk Creation

The following table explains the needed steps for disk creation in the target RG. "same az-user" means that parameters `sourceSubUser` = `targetSubUser` and `sourceSubTenant` = `targetSubTenant`.

`useAzCopy`|same az-user<BR>same region|same az-user<BR>different region|different az-user
:---|:---|:---|:---
not set|<ul><li>create snapshot *</li><li>create disk from snapshot</li></ul>|<ul><li>create incremental snapshot</li><li>**snapshot copy**<BR>(copy snapshot to target)</li><li>create disk from copied snapshot</li></ul>|<ul><li>create snapshot *</li><li>**BLOB copy**<BR>(copy snapshot to BLOB)</li><li>create disk from BLOB</li></ul>
set|<ul><li>create snapshot *</li><li>create disk from snapshot</li></ul>|<ul><li>create snapshot *</li><li>BLOB copy **using AzCopy**</li><li>create disk from BLOB</li></ul>|<ul><li>create snapshot *</li><li>BLOB copy **using AzCopy**</li><li>create disk from BLOB</li></ul>




\* Normally, a full snapshot is used. For `UltraSSD_LRS` and `PremiumV2_LRS` an incremental snapshot is used instead.

> :warning: **Warning:** RGCOPY uses the same name for incremental and full snapshots. When copying to a different region, an existing full snapshot cannot be used. Creating new snapshots can break parallel running RGCOPY runs that use the same source RG.

You can further change the behavior by setting the following parameters:

 parameter|[DataType]: usage
:---|:---
**`useBlobCopy`** |**[switch]**: Always use BLOB copy (even when source RG and target RG are in the same region). This parameter is only needed for testing. When `useAzCopy` is set in addition then AzCopy is used (even when source RG and target RG are in the same region).
**`useSnapshotCopy`** |**[switch]**:Always use snapshot copy (even when source RG and target RG are in the same region). This parameter is only needed for testing. When `useAzCopy` is set in addition then AzCopy is used (even when source RG and target RG are in the same region).
**`useAzCopy`** |**[switch]**: RGCOPY is neither using BLOB copy nor snapshot copy when parameter `useAzCopy` is set. Instead, multiple instances of AzCopy are started in parallel. This results in much higher CPU load and network traffic on the control plane, but it is much faster.<BR>Therefore, you should start RGCOPY inside an Azure VM when using this feature.<BR>:memo: **Note:** AzCopy is aways used for copying storage account content (containers, SMB and NFS shares), independent of parameter `useAzCopy`.
**`useIncSnapshots`** |**[switch]**: Always use incremental snapshots rather than full snapshots
**`createDisksManually`** |**[switch]**: Do not use an BICEP-template for creating disks (use `New-AzDisk` or a REST-API call instead)
**`skipDiskCreation`** |**[switch]**: Expect that all needed disks already exist in target RG
**`justCopyDisks`** |**[array]** or **[boolean]** : Only copy the given disks to target RG. Do not deploy anything else in target RG.<BR>If the list contains detached disks then you might set one of the parameters parameters: `defaultDiskZone`, `switchZone0`, `switchZone1`, `switchZone2`, `switchZone3`.<BR>These parameters apply then to all disks, not only the detached ones. Parameter `setVmZone` is not allowed together with `justCopyDisks`.<BR>When setting `justCopyDisks` to `$true` then all disks of the resource group are copied.
**`useRestAPI`** |**[switch]**: *Always* Use REST-API calls instead of using `Grant-AzSnapshotAccess`, `New-AzDisk` and `New-AzSnapshot` (for snapshot copy)
**`useInternetEndpoint`** |**[switch]**: Storage account for BLOB copy with additional internet endpoint.<BR>This is an experimental parameter for BLOB copy (with or without AzCopy). It might help when there are connection problems from the control plane to the storage account in the target RG. Do not use it as long as you do not see connection issues. The internet endpoint might slow down the blob copy process.

 > :memo: **Note:** `UltraSSD_LRS` and `PremiumV2_LRS` disks can use a logical sector size of either 512 byte or 4 KB. A disk that is using  a **locical sector size of 512 byte** can be converted to any SKU. However, a disk with a locical sector size of 4 KB can only be copied to `UltraSSD_LRS` or `PremiumV2_LRS`

#### Disk Creation in Same Region
If target RG and source RG are in the same region and the same user is used for both RGs then the BICEP template can use the snapshots in the source RG for creating the disks in the target RG.  
!["same region"](/images/disks_same_region.png)

#### Disk Creation in Different Region
For different regions, RGCOPY creates a temporary incremental snapshot in the target RG (as a copy of the incremental snapshot in the source RG). However, this is not the case when parameter `useAzCopy` is set. In this instance, BLOB copy is used as described below.
!["different region"](/images/disks_different_region.png)

#### Disk Creation in Different Tenant
You must use the same user and tenant for the accessing the source RG and target RG for using snapshot copy. When the subscriptions of the source RG and target RG are in different tenants then this is not possible. 

In this case, RGCOPY creates a temporary storage account for storing the disks content as BLOBs in the target RG. This is also the case when setting parameter **`useAzCopy`**.

> :warning: **Warning:** The storage account for BLOB copy has **disabled storage account keys** if the target subscription is a Microsoft internal subscription or when RGCOPY parameter **`disableTargetSaKeys`** is set. In this case, the Azure user for the target subscription must have RBAC role **`Storage Blob Data Contributor`** 

!["different tenant"](/images/disks_different_tenant.png)

#### Disk Creation Only
By setting parameter `justCopyDisks`, RGCOPY only creates the disks in the target RG. No other Azure resources are deployed. Dependent on the target region and tenant, a snapshot copy or BLOB copy might be used.
!["disk creation only"](/images/disks_creation_only.png)

#### Disk Creation Skipping
By setting parameter `skipDiskCreation`, RGCOPY expects that all needed disks already exist in the target RG. This is useful if you want to use a different tool for copying (or replicating) the disks to the target RG.
!["skip disk creation"](/images/disks_skip_creation.png)

### RGCOPY storage accounts
RGCOPY needs access to files in shares and containers of storage accounts in the following scenarios:
- **Blob-Copy:**
RGCOPY copies disk snapshots from the source RG to BLOBs in the target RG if the target RG is in a different region or the target subscription is using a different tenant. Therefore, a storage account is created in the target RG with an automatically generated name. This storage account is automatically deleted after Blob-Copy.
- **File-Copy:**
RGCOPY can copy files from mount points in the source RG to mount points in the target RG (when VMs are running on Linux). This is used for copying NetApp volumes or for converting them do disks. The copy is not performed directly. Instead, a storage account with an NFS share is created in the source RG that contains the backups of all mount points. The name of this storage account is also automatically generated based on the resource group name. However, this storage account is not automatically deleted
- **Share-Copy:**
When copying the content of shares, RGCOPY needs access to the copied storage accounts in the target RG. These storage accounts must be configured using RGCOPY parameter **`renameSa`** (since the name of storage accounts must be unique in whole Azure, you must give them a new name using parameter `renameSa` when copying from source RG to target RG).

All these storage accounts are created by RGCOPY. In Microsoft internal subscriptions, these storage accounts are additionally secured by disabling storage account keys and allowing network access only to selected networks.

Furthermore, a network security perimeter (NSP) is created and associated with the storage accounts in *Learning Mode*. NSPs in *Enforced Mode* are not supported by RGCOPY yet.

This is not the case for other subscriptions. However, you can configure these additional security settings for other subscriptions using the following RGCOPY parameter switches:

parameter|[DataType]: usage
:---|:---
**`disableTargetSaKeys`**|**[switch]:** Disable storage account keys for the storage account in the target RG (used for Blob-Copy).
**`disableSourceSaKeys`**|**[switch]:** Disable storage account keys for the storage account in the source RG (used for File-Copy).
**`disableShareSaKeys`**|**[switch]:** Disable storage account keys for the storage accounts copied to the target RG (used for Share-Copy).
**`disableTargetSaAllNwAccess`**|**[switch]:** Restrict public network access to selected networks for the storage account in the target RG (used for Blob-Copy)
**`disableSourceSaAllNwAccess`**|**[switch]:** Restrict public network access to selected networks for the storage account in the source RG (used for File-Copy)
**`disableShareSaAllNwAccess`**|**[switch]:** Restrict public network access to selected networks for copied storage accounts to the target RG (used at Share-Copy)
**`useNSP`**|**[switch]:** Associate the storage accounts with a network security perimeter (NSP)


### RGCOPY snapshots
RGCOPY might use snapshots in the following scenarios:
- **Disk-Creation:**
RGCOPY automatically creates snapshots from all copied disks in the source RG. The name of these snapshots always ends with `.rgcopy`. Disk snapshots can either be full snapshots or incremental snapshots.
- **File-Copy:**
The source of a file copy can either be a NetApp volume or a disk. For file copy from disks, you cannot use a snapshot. For file copy from NetApp volumes, a snapshot with name `rgcopy` is automatically used if it exists. When the snapshot with name `rgcopy` is not found then files are directly copied form the volume.
RGCOPY does not know which volume is mounted on which VM. The volume might even be located in a different resource group. Therefore, you must use RGCOPY parameter **`snapshotVolumes`** if you want to create a volume snapshot before starting file copy. 
- **Share-Copy:**
RGCOPY creates and uses share snapshots of NFS and SMB shares automatically if parameter **`useShareSnapshots`** is set. These snapshots have the metadata comment `rgcopy`. RGCOPY does not use snapshots when copying containers.

You can only create one RGCOPY snapshot for each disk/volume/share. if you create a new RGCOPY snapshot then the old snapshot is deleted. You can skip snapshot creation (and use an older, existing snapshot) by setting RGCOPY parameter **`skipSnapshots`**. You can skip the snapshots of a prticular type by using parameters **`skipSnapshotsDisks`**, **`skipSnapshotsShares`** or **`skipSnapshotsShares`**.


***
## Parameters

### Resource Group Parameters
The resource group parameters are essential for running RGCOPY:

parameter|[DataType]: usage
:---|:---
**`sourceRG`**			|**[string]**: name of the source resource group<ul><li> parameter is **mandatory**</li></ul>
**`targetRG`**			|**[string]**: name of the target resource group<ul><li> parameter is **mandatory** in **Copy Mode** or **Merge Mode**</li><li>parameter is **not allowed** in **Clone Mode** </li></ul> :memo: **Note:** Source and target resource group must not be identical except in **Merge Mode**<BR>:memo: **Note:** The target resource group might already exist. However, it should not contain resources. For safety reasons in Copy Mode, RGCOPY does not allow using a target resource group that already contains disks (unless you set switch parameter **`allowExistingDisks`**).
**`targetLocation`**	|**[string]**: *location name* of the Azure region for the target RG, for example 'eastus'.<ul><li>parameter is **mandatory** in **Copy Mode**</li><li> parameter is **not allowed** in **Clone Mode**</li></ul>:memo: **Note:** Use the location name (for example, 'eastus'). Do **not** use the *display name* ('East US') instead.
**`targetSA`**         |**[string]**: optional parameter<BR>name of the storage account that will be created in the target RG for storing BLOBs.
**`sourceSA`**         |**[string]**: optional parameter<BR>name of the storage account that will be created in the source RG for storing file backups. This storage account is only created when parameter **`createVolumes`** or **`createDisks`** is set.

> :memo: **Note:**  Parameters `targetSA` and `sourceSA` are normally not needed because RGCOPY is calculating them based on the name of the resource group. However, this could result in deployment errors because the storage account name must be unique in whole Azure (not only in the current subscription). Once you run into this issue, repeat RGCOPY and set these parameter to a unique name.


### Azure Connection Parameters
RGCOPY is using the current Azure Context (account, tenant and subscription) when no Azure Connection Parameter is provided. PowerShell caches the credentials of the Azure account inside the Azure Context. Therefore, you do not need to provide a password to RGCOPY. Simply run the following cmdlet for authentication just before starting RGCOPY:

**`Update-AzConfig -EnableLoginByWam $true`**

**`Connect-AzAccount -AuthScope 'Storage' -TenantId '<id>' -Subscription '<name>'`**

RGCOPY can use different Azure accounts for connecting to the source RG and the target RG. In this case, you must run `Connect-AzAccount` for both accounts before starting RGCOPY. Furthermore, you must provide the RGCOPY connection parameters as described below. Hereby, RGCOPY knows which account has to be used for which resource group.

You can also use an Azure Managed System Identity (MSI) for running RGCOPY. Therefore, you have to create a VM (or container) with an MSI. Once you have assigned the required roles to the MSI and installed PowerShell and the Az module in the VM, you can run RGCOPY inside the VM. In this case, you must run the following command:

**`Connect-AzAccount -AuthScope 'Storage' -Identity -AccountId '<id>'  -Subscription '<name>'`**

Powershell cashes several Azure Contexts. `Get-AzContext -ListAvailable` shows all cached contexts. `Get-AzContext` shows the current context. When providing the below RGCOPY parameters then RGCOPY uses `Set-AzContext` for changing the current Azure Context. To be on the save side, you should always provide RGCOPY parameters `sourceSub` and `sourceSubUser`.

parameter|[DataType]: usage
:---|:---
**`sourceSub`**			|**[string]**: *name* of source subscription. Do **not** use the *subscription id* instead.
**`sourceSubUser`**		|**[string]**: Azure account name (user, service principal or MSI) for source subscription.<BR>:memo: *The account name for a **M**anaged **S**ystem **I**dentity looks like this:* `MSI@0815`. *You can get the current account name by running* `Get-AzContext`
**`sourceSubTenant`**	|**[string]**: Azure tenant id for source subscription.<BR>:bulb: *This parameter is only needed if you have cached credentials in different tenants*
**`targetSub`**<BR>**`targetSubUser`**<BR>**`targetSubTenant`** | Same parameters as above but for the target subscription.<BR>Not needed if source and target subscription are identical

### Resource Configuration Parameters
With resource configuration parameters you can change properties of various resources in the BICEP template.

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
**`setVmSize`** =<BR>`@("size @ vm1,vm2,...", ...)`	|Set VM Size: <ul><li>**size**: VM size (e.g. Standard_E32s_v3) </li><li>**vm**: VM name</li></ul> 
**`setVmEncryptionAtHost`** = <BR>`@("bool @ vm1,vm2,...", ...)`		|Set Encryption At Host: <ul><li>**bool** in {True, False} </li><li>**vm**: VM name</li></ul> 
**`setDiskSku`** =<BR>`@("sku @ disk1,disk2,...", ...)`			|Set Disk SKU (default value is **`Premium_LRS`**).<BR>When setting to `false` (or `$False` or `$Null`), the disk SKU is not changed.<ul><li>**sku** in {`Premium_LRS`, `StandardSSD_LRS`, `Standard_LRS`, `Premium_ZRS`, `StandardSSD_ZRS`, `PremiumV2_LRS`, `UltraSSD_LRS`, `false`} </li><li>**disk**: disk name</li></ul> :memo: **Note:** There are several restrictions:<ul><li> Converting **from** `PremiumV2_LRS` or `UltraSSD_LRS` requires incremental snapshots. Creating an 1TB disk from an incremental snapshot can take more then 1 hour.</li><li> Converting **to** `PremiumV2_LRS` or `UltraSSD_LRS` requires a zonal deployment. Therefore, parameter `setVmZone` must be used. </li><li> Converting **from** `PremiumV2_LRS` or `UltraSSD_LRS` to a different SKU is only possible if the logical sector size is 512.</li><li>When converting from a different SKU **to** `PremiumV2_LRS` or `UltraSSD_LRS`, the logical sector size is set to 512.</li><li>If the VM size does not support premium IO then the disk SKU is automatically adopted. For example, `Premium_ZRS` is converted to `StandardSSD_ZRS`.</li></ul>
**`setDiskIOps`** = <BR>`@("iops @ disk1,disk1,...", ...)`|Set Disk IOps: <ul><li>**iops**: maximum IOs per second</li><li>**disk**: disk name</li></ul>:memo: **Note:** This parameter only works for Premium V2 disks. It cannot be used for Ultra SSD disks.
**`setDiskMBps`** = <BR>`@("mbps @ disk1,disk1,...", ...)`|Set Disk MBps: <ul><li>**mbps**: maximum MB per second</li><li>**disk**: disk name</li></ul>:memo: **Note:** This parameter only works for Premium V2 disks. It cannot be used for Ultra SSD disks.
**`setDiskSize`** = <BR>`@("size @ disk1,disk1,...", ...)`			|Set Disk Size: <ul><li>**size** in GB </li><li>**disk**: disk name</li></ul> :warning: **Warning:** It's only possible to *increase* the size of a disk. Partitions on the disk are not changed. This parameter was originally intended for increasing disk I/O on the target RG. Nowadays, you better should use parameter `setDiskTier` instead.
**`setDiskTier`** = <BR>`@("tier @ disk1,disk1,...", ...)`			|Set Disk Performance Tier:<ul><li>**tier** in {P0, P1, ..., P80} </li><li>**disk**: disk name</li></ul>:memo: **Note:** To remove existing  performance tier configuration, set tier to P0.
**`setDiskBursting`** = `@("bool @ disk1,disk2,...", ...)`|Set Disk Bursting: <ul><li>**bool** in {True, False} </li><li>**disk**: disk name</li></ul> 
**`setDiskMaxShares`** = <BR>`@("number @ disk1,disk2,...", ...)`|Set maximum number of shares for a Shared Disk: <ul><li>**number** in {1, 2, 3, ...}  </li><li>**disk**: disk name </li></ul> :memo: **Note:** For number = 1, it is not a Shared Disk anymore
**`setDiskCaching`** = <BR>`@("caching/wa @ disk1,disk2...", ...)`	|Set Disk Caching: <ul><li>**caching** in {ReadOnly, ReadWrite, None} </li><li>**wa (writeAccelerator)** in {True, False} </li><li>**disk**: disk name</li></ul> :memo: **Examples:**<ul><li>`'ReadOnly'`: turns on ReadOnly cache for all disks</li><li>`'None/False'`: turns off caching and writeAccelerator for all disks</li><li>`'/False'`: turns off writeAccelerator for all disks (but keeps caching property)</li><li>`@('ReadOnly/True@disk1', '/False')`: turns on writeAccelerator (with ReadOnly cache) for disk1 and turns it off for all other disks in the resource group</li></ul>
**`setVmDeploymentOrder`** = <BR>`@("prio @ vm1,vm2,...", ...)`				|Set VM deployment Order: <ul><li>**prio** in {1, 2, 3, ...}  </li><li>**vm**: VM name </li></ul>:memo: **Note:** This parameter is used during BICEP template creation. You can define priories for deploying VMs. A VM with higher priority (lower number) will be deployed before VMs with lower priority. Hereby, you can ensure that an important VM (for example a domain controller) will be deployed before other VMs.
**`setPrivateIpAlloc`** = <BR>`@("allocation @ ip1,ip2,...", ...)`		|Set Private IP Allocation Method: <ul><li>**allocation** in {Dynamic, Static}</li><li>**ip**: name of Private IP Address.</li></ul>
**`setAcceleratedNetworking`** = <BR>`@("bool @ nic1,nic2,...", ...)`		|Set Accelerated Networking: <ul><li>**bool** in {True, False} </li><li>**nic**: name of Virtual Network Interface.</li></ul>
**`createVolumes`**<BR>**`createDisks`**<BR>**`snapshotVolumes`**|see section [NetApp Volumes](./rgcopy-docu.md#File-Copy-of-NetApp-Volumes).
**`ultraSSDEnabled`**|**[switch]**: By default, VMs in the target RG only support Ultra SSD disks if such a disk is already attached. If you want to attach a new Ultra SSD disk later then you must set this RGCOPY switch when creating the target RG.

### Default values
RGCOPY uses default parameter values in **Copy Mode**. If you do not want this then set parameter switch **`skipDefaultValues`** or explicitly set the individual parameters to a different value.

parameter|default value|default behavior
:---|:---:|:---
**`setDiskSku`**        |'Premium_LRS'   |converts all disks to `Premium_LRS` if they originally were `StandardSSD_LRS` or `Standard_LRS`.
**`setVmZone`**         |0             |removes zone configuration from VMs
**`setPrivateIpAlloc`** |'Static'        |sets allocation of Private IP Addresses to Static
**`setAcceleratedNetworking`**|$True    |enables Accelerated Networking

In addition, RGCOPY always performs the following changes:
- set the IP Allocation Method of Public IP Addresses to `Static`
- set the SKU of Public IP Addresses to `Standard`
- set the SKU of Load Balancers to `Standard`


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
**`forceVmChecks`**| **[switch]**: Do not automatically adjust any resource property<BR>:warning: **Warning:** Once this switch is set, RGCOPY terminates if an incompatible resource property is set. RGCOPY does not try solving such issues automatically. For example, it does not automatically convert Premium SSD disks if the VM size does not support Premium IO.
**`skipVmChecks`**| **[switch]**: Ignore any incompatible resource property<BR>:memo: **Note:** Normally, setting this parameter switch does not make any sense. When allowing incompatible resource properties then the deployment will fail.<BR>However, there is one scenario where this parameter is useful: RGCOPY relies on SKU information retrieved by `Get-AzComputeResourceSku`. If this information is wrong for any reason and you are sure that you know it better then you can set this parameter switch.
**`simulate`**| **[switch]**: Do not stop for (most of the) found consistency errors.<BR>:memo: **Note:** For each found error, RGCOPY writes a warning in red color. This is useful for detecting *all* errors by just running RGCOPY once. However, it is a simulation. You cannot copy a resource group while parameter `simulate` is set.


### Parameters for skipping resources

parameter|[DataType]: usage
:---|:---
**`skipVMs`**|**[array] of VM names**: These VMs and their disks are not copied by RGCOPY.
**`takeVMs`**|**[array] of VM names**: Only these VMs and their disks are copied by RGCOPY (opposite of parmeter `skipVMs`).
**`skipDisks`**|**[array] of disk names**: These disks are not copied by RGCOPY.<BR> :warning: **Warning:** Take care with this parameter. Starting their VMs could fail in the target RG. See section [NetApp Volumes](./rgcopy-docu.md#File-Copy-of-NetApp-Volumes)
**`skipSecurityRules`**|**[array] of name patterns**: default value: `@('SecurityCenter-JITRule*')`<BR>Skips all security rules that name matches any element of the array.<BR>:memo: **Note:** By default, only Just-in-Time security rules are skipped (This is needed to avoid permanently opend ports in the target RG). All other security rules are copied.
**`skipAvailabilitySet`**<BR>**`skipProximityPlacementGroup`**|see [Parameters for Availability](./rgcopy-docu.md#Parameters-for-Availability)
**`skipBastion`**|**[switch]**: do not copy Azure Bastion from source RG
**`skipIdentities`**|**[switch]**: By default, target VMs have the same (user assigned) managed identities assigned as the source VMs. You can skip this by using parameter `skipIdentities`.
**`keepTags`**|**[array] of name patterns**: default value: `@('rgcopy*')`<BR>Skips all Azure resource tags except the ones that name matches any element of the array.<BR>:memo: **Note:** By default, only Azure resource tags with a name starting with 'rgcopy' are copied. By setting parameter `keepTags` to `@('*')`, all Azure resource tags are copied.
**`keepUnusedResources`**|**[switch]**: As long as this parameter is not set, all unused networkSecurityGroups, applicationSecurityGroups, publicIPAddresses and publicIPPrefixes are not copied to the target RG.

!["skip VMs"](/images/disks_skipping.png)


### Parameters for renaming resources
The following parameters can be used for renaming Azure resources, see [Comparing RGCOPY Modes](./rgcopy-docu.md#Comparing-RGCOPY-Modes) 

renameDisks
parameter|[DataType]: usage
:---|:---
**`setVmName`**	= <BR>`@("newName @ oldName", ...)`	|Rename VMs: <ul><li>**newName**: VM name in the target RG </li><li>**oldName**: VM name in source RG </li></ul>
**`renameDisks`**|**[switch]**: Rename all attached disks to a standard name using their VM names.
**`renameNICs`**|**[switch]**: Rename all NICs to a standard name
**`renameIPs`**|**[switch]**: Rename all public IP addresses and public IP prefixes to a standard name
**`renameNSGs`**|**[switch]**: Rename all network security groups to a standard name
**`renameAll`**|**[switch]**: Rename all disks, NICs, public IP addresses, public IP prefixes and NSGs to a standard name
**`renameVnets`**|**[boolean]** or **[string]**: When set to `$true`, rename all vnets using the resource group name.<BR>When set to a string, use that value rather than the resource group name.<BR>Parameter `renameVnets` will overwrite a vnet name defined in parameter `setAddressSpace`.
**`setAddressSpace`** = <BR> `@("addr @ vnet [=vnetNew],`<BR>`addr @ subnet [=subnetNew], ...` <BR> `", ...)`|**[array] of [string]**: Sets address spaces of vnets and subnets and optionally renames them:RG:<ul><li>**vnet**: name in the vnet in the source RG </li><li>**vnetNew**: optionally: name in the vnet in the target RG </li><li>**subnet**: name in the subnet in the source RG </li><li>**subnetNew**: optionally: name in the subnet in the target RG </li><li>**addr**: list of address spaces separated by semikolon, for example `10.0.0.0/16` or `10.0.0.0/24;10.0.1.0/24`</li></ul>Each string in the array contains the complete configuration of a vnet with all its subnets separated by comma. The array must contain as many strings as vnets exist in the target RG. For example:<BR>`-setAddressSpace @('10.0.0.0/16 @ vnet, 10.0.0.0/24;10.0.1.0/24 @ subnet1, 10.0.2.0/24 @ subnet2')`<BR><BR>You can skip the vnet or subnet name when having only a single vnet or subnet. You can use a string rather than an array if only one vnet exists. For example, the following parameter is valid:<BR>`-setAddressSpace '10.0.0.0/16, 10.0.0.0/24'`
**`renameSa`**	= <BR>`@("newSaName @ oldSaName", ...)`	|Define, which storage accounts are copied (without content)<ul><li>**oldSaName**: Storage account name in the source RG </li><li>**newSaName**: New storage account name in the target RG </li></ul>







### Parameters for Availability
RGCOPY can change Availability Zones, Availability Sets and Proximity Placement Groups in the target RG. It does not touch the source RG configuration.


parameter|[DataType]: usage
:---|:---
**`setVmZone`** = <BR>`@("zone @ vm1,vm2,...", ...)`			|Set VM Availability Zone: <ul><li>**zone** in {none, 0, 1, 2, 3, false} </li><li>**vm**: VM name </li></ul>The default value is '0' which removes the zone configuration.<BR>:bulb: **Tip:**  Rather than 'none', you can use '0' for removing zone configuration. When setting to 'false', the existing zone is not changed.<BR>:bulb: **Tip:** Disks are always created in the same zone as their VMs. Detached disks are only copied when parameter `copyDetachedDisks` was set.
**`defaultDiskZone`** = `zone`|**zone** in {0, 1, 2, 3}<BR>When set then all detached disks are moved to the specified zone.
**`switchZone0`** = `zone`<BR>**`switchZone1`** = `zone`<BR>**`switchZone2`** = `zone`<BR>**`switchZone3`** = `zone`<BR>|**zone** in {0, 1, 2, 3}<BR>If one of these parameters is set then all VMs and disks of a given zone are moved to the configured zone.<BR>Parameters `defaultDiskZone` and `setVmZone` are ignored in this case. All other VMs and disks stay in their original zone.<BR>For example, by setting `switchZone0=1` and `switchZone1=2`, all non-zonal VMs and disks are moved to zone 1 and all VMs and disks that were originally in zone 1 are moved to zone 2. VMs and disks in zone 2 and 3 stay in their zones.
**`setVmFaultDomain`** = <BR>`@("fault @ vm1,vm2,...", ...)`			|Set VM Fault Domain: <ul><li>**fault**: Used Fault Domain in {none, 0, 1, 2} </li><li>**vm**: VM name </li></ul>:bulb: **Tip:**  The value 'none' removes the Fault Domain configuration from the VM.<BR>:warning: **Warning:** Values {0, 1, 2} are only allowed if the VM is part of a VMSS Flex.
**`skipVmssFlex`**|**[switch]**: do not copy existing VM Scale Sets Flexible. <BR>Hereby, the target RG does not contain any VM Scale Set.
**`skipAvailabilitySet`**|**[switch]**: do not copy existing Availability Sets. <BR>Hereby, the target RG does not contain any Availability Set.
**`skipProximityPlacementGroup`**|**[switch]**: do not copy existing Proximity Placement Groups. <BR>Hereby, the target RG does not contain any Proximity Placement Group.
**`createVmssFlex`** = <BR>`@("vmss/fault/zones @ vm1,vm2,...", ...)`			|Create a VMSS Flex (VM Scale Set with Flexible orchestration mode) for given VMs: <ul><li>**vmss**: VM Scale Set Name </li><li>**fault**: Fault domain count in {`none`, `1`, `2`, `3`, `max`}.<BR>`none` is a synonym for `1`. `max` is a synonym for the maximum number of fault domains in the target region</li><li>**zones** Allowed Zones in {`none`, `1`, `2`, `3`, `1+2`, `1+3`, `2+3`, `1+2+3`}  </li><li>**vm**: VM name </li></ul>:memo: **Note:** When you are using this parameter for creating new VM Scale Sets then all existing VM Scale Sets are removed first.<BR>:memo: **Note:** for zonal deployment, *fault* must have the value `1` (or `none`)<BR>:warning: **Warning:** For SAP, we recommend zonal deployment (and therefore, *fault* must have the value `1` or `none`).<BR>:memo: **Note:** When not specifying any VM then this configuration is *not* valid for all VMs. Instead, a VMSS flex is created without any member.
**`singlePlacementGroup`**|Set property `singlePlacementGroup` for all VMSS Flex.<BR>Allowed values in {`$Null`, `$True`, `$False`}<BR>Setting this parameter is normally not needed.
**`createAvailabilitySet`** = <BR>`@("avset/fault/update @ vm1,vm2,...", ...)`			|Create Azure Availability Set for given VMs:<ul><li>**avset**: Availability Set Name </li><li>**fault**: Fault domain count</li><li>**update**: Update domain count</li><li>**vm**: VM name </li></ul>:memo: **Note:** When you are using this parameter for creating new Availability Sets then all existing Availability Sets *and* Proximity Placement Groups are removed first.<BR>:memo: **Note:** When not specifying any VM then this configuration is *not* valid for all VMs. Instead, an AvSet is created without any member.
**`createProximityPlacementGroup`** = <BR>`@("ppg @ res1,res2,...", ...)`			|Create Azure Proximity Placement Group for given resources: <ul><li>**ppg**: Proximity Placement Group Name </li><li>**res**: resource name (either VM, Availability Set or VMSS Flex) </li></ul>:memo: **Note:** When you are using this parameter for creating new Proximity Placement Groups then all existing Proximity Placement Groups *and* Availability Sets are removed first.<BR>:warning: **Warning:** You might use the same name for a VM and an Availability Set and add this name as resource name to this parameter. In this case, the VM as well as the Availability Set will be added to the Proximity Placement Group.<BR>:memo: **Note:** When not specifying any resource then this configuration is *not* valid for all VMs. Instead, a PPG is created without any member.

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

> :warning: **Warning:** RGCOPY ensures in this example that the VMs 'ascs1' and 'ascs2' are deployed before all other VMs. After stopping all VMs, the VMs in the Availability Sets are not bound to a Availability Zone anymore. Therefore, you have to take care on your own that 'ascs1' and 'ascs2' are always started before the other VMs in their Availability Sets.

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

### Parameters for BLOB Copy
When the source RG and the target RG are in different regions or subscriptions then the snapshots have to be copied into the target RG as snapshots or BLOBs. This is running *asynchronously* in background and can take several hours.

If your PC reboots while asynchronous BLOB copy or snapshot copy is running, you can restart RGCOPY using the same parameters of the original run plus the additional parameter switch **`waitRemoteCopy`**

We highly recommend using parameter `useAzCopy`. This results in *synchronously* running BLOB copy using RGCOPY. In this case, RGCOPY automatically repeats a failed BLOB copy one or multiple times. You can configure this by using parameter **`azCopyRepeatCount`**.

If a snapshot copy or a BLOB copy finally fails for a single disk, you do not need to repeat the copy of all disks. In this case, you can do the following:

1. In the target RG, delete all snapshots or BLOBs that have not been fully copied yet.
2. Copy the missing snapshots (or BLOBs) manually by running RGCOPY with the parameter **`justCopySnapshots`** (or **`justCopyBlobs`**). The parameter is an array of (disks) names that have to be copied: Use the corresponding disk name, not the snapshot name or BLOB name.
3. Restart RGCOPY using the same parameters of the original run plus the additional parameter switch **`skipRemoteCopy`**.

> :warning: **Warning:** all copied snapshots (and BLOBs) in the target RG are deleted by RGCOPY once the VM deployment in the target RG was successful.

**Additional BLOB parameters**
The following parameters are typically not needed and only work with BLOB copy:

parameter|[DataType]: usage
:---|:---
**`grantTokenTimeSec`**|**[int]**: Time in seconds, default value: `3*24*3600`<BR>Before copying the BLOBs, access tokens are generated for the snapshots (or disks). These access tokens expire after 3 days. If the BLOB copy takes longer, then it fails. You can define a longer token life time using this parameter (before starting the BLOB copy).
**`blobsRG`**			|**[string], *optional***: resource group where the BLOBs are located
**`blobsSA`**			|**[string], *optional***: storage account where the BLOBs are located
**`blobsSaContainer`**	|**[string], *optional***: folder in storage account where the BLOBs are located
**`justStopCopyBlobs`** |**[switch]**: when set, the currently *asynchronously* running BLOB copies are being terminated. This does not apply for *synchronously* running BLOB copies started with parameter `useAzCopy`.

### Other Parameters
parameter|[DataType]: usage
:---|:---
**`pathExportFolder`**<BR>|**[string]**: By default, RGCOPY creates all files in the user home directory. You can change the path for all RGCOPY files by setting parameter `pathExportFolder`.
**`pathArmTemplate`**|**[string]**: You can deploy an existing BICEP template by setting this parameter. No snapshots are created, no BICEP template is created and no resource configuration changes are possible.
**`copyDetachedDisks`** |**[switch]**: By default, only disks that are attached to a VM are copied to the target RG. By setting this switch, also detached disks are copied.
**`maxDOP`**               |**[int]**: RGCOPY performs the following operations in parallel:<ul><li>disk snapshot creation, deletion</li><li>disk snapshot access token granting, revoking</li><li>NetApp snapshot creation</li><li>starting async BLOB copy or snapshot copy</li><li>running sync BLOB copy using AzCopy</li><li>copying content of containers, NFS, SMB shares using AzCopy</li><li>VM starting, stopping</li><li>disk creation (when not done by BICEP template)</li></ul>By default, RGCOPY uses 16 parallel running threads for these tasks. You can change this using parameter `maxDOP`. Setting the value to `0` results in no limitation of parallelism.
**`justCreateSnapshots`**  |**[switch]**: When setting this switch, RGCOPY only creates snapshots on the source RG (no BICEP template creation, no deployment). <BR>You can use parameter **`useIncSnapshots`** in addition for creating incremental snapshots rather than full snapshots.
**`justDeleteSnapshots`**  |**[switch]**: When setting this switch, RGCOPY only deletes snapshots on the source RG (no BICEP template creation, no deployment). 


***
## Applying OS patches
RGCOPY can apply OS patches on all VMs of a resource group **in parallel**. This works for Windows, RedHat, Suse and Ubuntu VMs. RGCOPY automatically reboots the VMs and repeats applying OS patches if needed. By default, all available patches are applied on Windows and all security patches on Linux.
To speed-up Windows update, the Powershell module **`PSWindowsUpdate`** is installed inside the Windows VMs. For Linux VMs, `zipper`, `yum` or `unattended-upgrade` is used.

>:memo: **Note:** RGCOPY needs additional files in the directories `./bash` and `./powershell` for applying OS patches. It tests whether these files are fitting to the running RGCOPY version. RGCOPY works fine without these files as long as the OS patch feature (and file copy feature) is not used.

### Applying OS patches in Copy Mode
By setting parameter **`patchVMsTargetRG`**, OS Update is running on all copied VMs in the target RG just after deploying them. For example:

```powershell
$rgcopyParameter = @{
    sourceRG            = 'SAP_master'
    targetRG            = 'SAP_copy'
    targetLocation      = 'westus'
    patchVMsTargetRG    = 'patchVMsTargetRG'
}
.\rgcopy.ps1 @rgcopyParameter
```

### Applying OS patches in Patch Mode
By default, RGCOPY is not changing the VMs in the source RG. However, you can manually update VMs in any resource group using RGCOPY patch mode:

```powershell
$rgcopyParameter = @{
    patchMode   = $true
    sourceRG    = 'rg_name'
}
.\rgcopy.ps1 @rgcopyParameter
```

### Parameters for patching
The following parameters can be set in Patch Mode:

parameter|[DataType]: usage
:---|:---
**`patchVMsTargetRG`**|**[switch]**: Patches VMs in Copy Modes
**`patchMode`**|**[switch]**: Turns on Patch Mode.
**`patchVMs`**|**[array]**: Name of VMs to patch: default value: `'*'`
**`patchAll`**|**[switch]**: Install *all* available OS patches in the VM (not only security patches). This switch is always turned on for Windows VMs. The switch does not work for Ubuntu VMs. For these VMs, you must edit `/etc/apt/apt.conf.d/50unattended-upgrades` instead.
**`ignorePatchErrors`** |**[switch]**: Ignore errors during OS patch installation (turned on by default).<BR>You can disable this switch by setting `ignorePatchErrors = $false`
**`prePatchCommand`**|**[string]**: Linux command that will be executed before installing the patches, for example `yum-config-manager --save --setopt=rhui-rhel-7-server-dotnet-rhui-rpms.skip_if_unavailable=true 1>/dev/null`
**`postPatchCommand`**|**[string]**: Linux command that will be executed after installing the patches

RGCOPY does not try to fix any repository issue. Only fixes of enabled repositories are applied.


***
## Copying Storage Accounts
By default, RGCOPY does not copy storage accounts. However you can copy storage accounts including FILE and BLOB services when specifying new names for the storage accounts using parameter **`renameSa`**. For example:

```powershell
$rgcopyParameter = @{
    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'

    # COPY STORAGE ACCOUNT AZURE RESOURCES
    renameSa = @(
        'newSaName1 @ saName1',
        'newSaName2 @ saName2'
    )

    # copy storage ALL account content
    copySaShares = $true

    # alternatively: define shares to copy
    # copySaShares = @(
    #     'container'
    #     'nfs'
    #     'smb'
    # )

    # OPTIONAL PARAMETER: Subnet ID if control plane subnet
    subnetIdControlPlane = $null
}
.\rgcopy.ps1 @rgcopyParameter
```
This will copy the storage accounts `saName1` and `saName2` from the source RG to the target RG and rename them to `newSaName1` and `newSaName2`. Other storage accounts in the source RG will not be copied.

### Copy storage account Azure resources
- All source storage accounts (source SA) must be located in the source RG. The target SAs will be created in the target RG. If source RG and target RG are in the same subscription then a single Azure user can be used for source and target.
- You must use parameter **`renameSa`** to define the names of the target SAs. You cannt use the names of the source SAs since storage account names must be unique in whole Azure.
> :memo: **Note:** Mounting the shares inside the VMs and changing **`/etc/fstab`** has to be done manually after running RGCOPY.

> :memo: **Note:** RGCOPY does not copy private endpoints. Granting network access for the storage accounts from the VMs has to be done manually in the target RG.

### Copy storage account content (share-copy)
You can copy all BLOBs in **containers** as well as all files in **SMB** and **NFS** file shares by setting parameter **`copySaShares`**. This uses the tool **azcopy** which is called by RGCOPY.

**For share-copy, special restrictions exist:** AzCopy must either authenticate using storage account keys or by using the managed identity of a VM that is running RGCOPY.
- Everything works fine fine if the source SA and the target SA are both configured to allow SA keys.
- When one of them does not allow using SA keys then you must run RGCOPY inside an Azure VM with a managed identity.
- When both do not allow storage account keys then you must use the same Azure user (the managed identity) for the source SA and target SA. In this case, cross-tenant copy is not possible.

#### Share-copy using an Azure VM
When using an Azure VM for starting RGCOPY then you should assign a **user assigned managed identity** to this VM. In this case, RGCOPY creates a subnet rule for each needed storage account using the subnet of the VM. RGCOPY tries ro figure out the ID of the subnet on its own. To be on the save side, you can use RGCOPY parameter **`subnetIdControlPlane`** for setting the subnet ID. In this subnet, the service endpoint **`Microsoft.Storage.Global`** must be enabled.

#### Cross-tenant share-copy 
You can even copy containers, NFS-shares and SMB-shares between different tenants. For this, you need two Azure users (one per tenant) having the **Required RBAC roles** (see below).

> :memo: **Note:** Copying files of NFS or SMB shares between **between different tenants** is only possible if either the source SA or the target SA is configured allowing SA keys.

In this scenario, let's call the tenant that contains the storage account with allowed SA keys *tenantKey*, and the other tenant *tenantOther*. For storage account copy, you should follow these steps:
- Add a user assigned managed identity to the control plane VM. This managed identity must be in *tenantOther*.
- Run **`connect-AzAccount -Identity -AccountId <id> -AuthScope Storage -SubscriptionName '<name>'`** for *tenantOther*.
- Run **`connect-AzAccount -DeviceAuth -AuthScope Storage -SubscriptionName '<name>'`** for *tenantKey*.
- Start RGCOPY in the control plane VM.


#### Required Network access in source RG
The storage accounts in the source RG might or might not be associated with a network security perimeter (**NSP**) in *Learning Mode*. **NSPs in *Enforced Mode* are not supported by RGCOPY yet.**

> :memo: **Note:** If you want to copy shares of a storage account then you must **enable Public Network Access (for selected networks)** in the source SA before starting RGCOPY.
This can be configured independently from an associated NSP.

#### Network access to storage accounts (in source RG or target RG)
When running inside a VM then RGCOPY creates a subnet rule to allow network access to the storage accounts. Otherwise, RGCOPY creates IP rules in the firewall of either the storage account or an associated Network security perimeter.

#### Required RBAC roles
The users that are used for accessing the source subscription and target subscription must have the following RBAC roles (in addition to **`Contributor`**):
- when copying blobs:
**`Storage Blob Data Contributor`** 
- when copying files from SMB shares:
**`Storage File Data SMB Share Elevated Contributor`**  
- when copying files from NFS shares:
**`Storage File Data Privileged Contributor`**
    
These RBAC roles should be set on *subscription level* to grant access for the source RG and target RG. However, *resource group level* is sufficient for the source RG.

#### Authentication of azcopy
RGCOPY calls azcopy and defines the authentication type for the source and target storage account separately. One of the following authentication types is used (in this order):
1. **Token using storage account key**
If the storage account is configured to allow storage account keys then RGCOPY creates an SAS token using storage account key 1 (see parameter `copySaKeyName` below)
2. **User delegation token**
For BLOB containers, RGCOPY tries to create a user delegation SAS token. This is only possible if the RBAC roles mentioned above are set.
3. **MSI authentication**
If an SAS token cannot be created then Managed Identity authentication is used. In this case, you must run RGCOPY in an Azure VM and connect to Azure using the manged identity:
**`connect-AzAccount -Identity -AccountId <id> -AuthScope Storage -SubscriptionName '<name>'`**

#### Using snapshots
You can directly copy from a file share or copy from a file share snapshot that has been created by RGCOPY when using parameter switch **`useShareSnapshots`**. 

> :warning: **Warning:** SMB permissions are **not** copied when using a snapshot.
NFS permissions **are** copied, whether a snapshot is used or not.

> :memo: **Note:** Using BLOB snapshots is not possible with RGCOPY.

Azure file share snapshots (SMB and NFS) do not have a name. They only have a creation date and metadata. RGCOPY uses the metadata `Comment=rgcopy` for its snapshots. There can only be one RGCOPY snapshot per share. Before RGCOPY creates a new share snapshot, it deletes its previous RGCOPY snapshot. 

You might manually delete an RGCOPY file share snapshot using Azure portal. However, there is no feature implemented in RGCOPY to delete an old RGCOPY file share snapshot (rather than creating a new one).

RGCOPY file share snapshots are only created when using parameter `useShareSnapshots` and not setting parameter `skipSnapshots`. The latter parameter skips creating file share snapshots as well as disk snapshots and volume snapshots.

#### Repeating failed content copies
RGCOPY uses the tool `azcopy` to copy the content of storage accounts. This might fail for any reason. In this case, you can simply repeat RGCOPY by adding the parameter switch **`justCopySaShares`** (and adjusting parameter `copySaShares`). This will skip creating snapshots and deploying the BICEP template (However, a new BICEP template will be created).

### Parameters

parameter|usage
:---|:---
**`renameSa`**	= <BR>`@("newSaName @ oldSaName", ...)`	|Set the names of of the new storage accounts: <ul><li>**oldSaName**: Storage account name in the source RG </li><li>**newSaName**: New storage account name in the target RG </li></ul> Copies storage accounts (without content).
**`skipSaNwRules`**|**[switch]**: Do not copy IpRules, ResourceAccessRules and VirtualNetworkRules of copied storage accounts.
**`copySaShares`**|**[boolean]** or **[array]**: Copies storage account content (BLOBs and files) after deploying target RG. When set to `true`, all containers and shares are copied. When passing an array of names, all containers and shares include in this array are copied.
**`subnetIdControlPlane`**|**[string]**:Subnet ID of control plane (VM that runs RGCOPY), for example: <BR>`/subscriptions/5b0f1c1f-e257-4872-a1e3-bf4ad6f452e7/resourceGroups/control_plane/providers/Microsoft.Network/virtualNetworks/vnet-name/subnets/default`<BR>This subnet will be granted to all copied storage accounts. RGCOPY tries to figure out the subnet ID on its own. If this does not work then you have to set parameter `subnetIdControlPlane` manually.
**`justCopySaShares`**|**[switch]** Just copy the BLOBs and files defined by parameter `copySaShares`. <BR>Do not create snapshots and do not deploy anything.
**`useShareSnapshots`**|**[switch]**: Create file share snapshots and use them as the source when copying file shares.<BR>:warning: **Warning:** SMB permissions are not copied when using a snapshot.
**`copySaKeyName`**|**[string]**: If storage account key should be used for azcopy then you can define here which key.<BR>**allowed:** `key1`, `key2`<BR>**default:** `key1`
**`copySaRevokeCpAccess`**|**[switch]**: Revoke access from control plane VM after content has been copied.
**`azCopyRepeatCount`**|**[int]**:Number of automatic retries of AzCopy, default value: `1`
**`azCopyLogLocation`**|**[string]**:Location of the AzCopy log file.
**`azCopyEnvironment`**|**[hashtable]**: Environment variables and their value that are set when azcopy is running. Default value is:<BR>`@{`<BR>`  AZCOPY_DISABLE_SYSLOG = 'true'`<BR>`  NO_PROXY = '*'`<BR>`}`
**`showAzCopyLogs`**|**[switch]**:Display the console output of AzCopy (not the log file) after a successful run. For failed runs, the complete console output is always displayed.


***
## File Copy of NetApp Volumes

In Azure, you cannot export the snapshot of a NetApp volume to a BLOB or restore it in another region. Therefore, RGCOPY cannot directly copy NetApp volumes. However, RGCOPY supports NetApp volumes on LINUX using file copy (rather than disk or volume copy). Hereby, the following scenarios are possible:

source RG|target RG|procedure
:---|:---|:---
Disks|NetApp volumes NFSv4.1|skip disks and create new volumes
NetApp volumes|Premium SSD disks|create new Premium SSD disks
NetApp volumes|NetApp volumes NFSv4.1|create new volumes

For the source RG, RGCOPY must know the mount points inside the VMs for all disks and volumes. Hereby, RGCOPY can backup all files that are stored in these mount points to an NFS share in the source RG. In the target RG, new disks or volumes are created for these mount points. After that, RGCOPY restores the files from the NFS share to the mount points in the target RG.

>:memo: **Note:** RGCOPY needs additional files in the directories `./bash` and `./powershell` for using file copy. It tests whether these files are fitting to the running RGCOPY version. RGCOPY works fine without these files as long as the file copy feature (and OS patch feature) is not used.

> :warning: **Warning:** Unlike other RGCOPY features, File Copy requires running code inside the source RG and the target RG. **Therefore, the stability of this feature depends on the OS and other running software inside the VMs.** Using this feature is on your own risk. To be on the save side, you should use database backup and restore rather than converting the database disks using RGCOPY.

There are several restrictions for using this feature:
- Requirements for the source VMs:
    - NFS client must be installed
    - `/etc/fstab` must be in specific format: `nofail` must be set for all disks and mount points (except for `/`, `/boot`, `/boot/efi`). When skipping disks, the device names `/dev/sd*` (and `/dev/nvme*`) might change. Therefore, you should use the Azure specific device names, for example `/dev/disk/azure/scsi1/lun*-part*` (or `/dev/disk/azure/data/by-lun/*`).
    - For NetApp, the NFSv4 domain name should be set to `defaultv4iddomain.com`, see https://learn.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-configure-nfsv41-domain
- Requirements in Azure
    - All NetApp volumes in the source RG must be configured to allow snapshot access inside the VMs.
    - In the target RG, only a single NetApp account and a single volume pool is created. All VMs that access NetApp volumes in the target RG must use the same subnet for accessing NetApp volumes. This subnet must already exist in the source RG and use delegation for `Microsoft.NetApp/volumes`. You must define this subnet using RGCOPY parameter `subnetNetApp`.
    - In the source RG, all VMs involved in file copy must use a second subnet with disabled Private Endpoint Network Policies (typically the default subnet). You must define this subnet using RGCOPY parameter `subnetEndpoint`.
- Consistent backup (keep content of different mount points in sync)
    - During file backup and restore, no open files must exists in the copied mount points. You should disable automatically starting services like SAP and databases.
    - In most cases, the VMs must be stopped to create snapshots from disk. For the file copy, the VMs have to be started again. File copy from NetApp volumes uses NetApp snapshots. However, file copy from disks never uses snapshots. Therefore, the content of disks, copied mount points from disks and copied mount points from NetApp volumes might not be in sync in the target VMs.
    - Do never forget to set parameter `snapshotVolumes` when copying mount points from NetApp volumes

The following RGCOPY parameters are available:

parameter|usage
:---|:---
**`skipDisks`** = <BR>`@('diskName1',  ...)`	|**[array] of disk names**: These disks are not copied by RGCOPY.<BR>:warning: **Warning:** Take care with this parameter. Starting their VMs could fail in the target RG. When using this parameter, you must set **`/etc/fstab`** for all disks (not only the skipped disks) as described above.
**`createVolumes`** = <BR>`@("size @ mp1,mp2,...", ...)`			|Create new NetApp volumes in the target RG<ul><li>**size**: volume size in GB </li><li>**mp**: mount point `/<server>/<path>` (e.g. /dbserver/hana/shared)</li></ul>
**`createDisks`** = <BR>`@("size @ mp1,mp2,...", ...)`<BR>`@("size/iops/mbps@mp1,mp2,...", ...)`|Create new disks in the target RG<ul><li>**size**: disk size in GB</li><li>**iops**: I/Os per second: only needed and allowed for Ultra SSD disks</li><li>**mbps**: megabytes per second: only needed and allowed for Ultra SSD disks</li><li>**mp**: mount point `/<server>/<path>` (e.g. /dbserver/hana/shared)</li></ul>
**`snapshotVolumes`** = <BR>`@("account/pool @ vol1,vol2...", ...)`<BR>`@("rg/account/pool @ vol1,vol2...", ...)`			|Create NetApp volume snapshots in the source RG<ul><li>**rg**: resource group name that contains the NetApp account (optional)</li><li>**account**: NetApp account name</li><li>**pool**: NetApp pool name</li><li>**vol**: NetApp volume name</li></ul>rg is optional. Default value is `sourceRG`
**`subnetEndpoint`**=<BR>`'<vnet>/<subnet>'`|**[string]**: Existing subnet in source RG that can be used for RGCOPY NFS share during file copy.<BR><ul><li>**vnet**: name of the vnet </li><li>**subnet**: name of the subnet (normally `default`) </li></ul>The private endpoint network policies of this subnet must be disabled.
**`subnetNetApp`**=<BR>`'<vnet>/<subnet>'`|**[string]**: Existing subnet in source RG that will be used for NetApp volumes during file copy.
**`fileCopyVerify`**|**[string]**: Default value: `compare`<BR>allowed values:<ul><li>`none`: No veritfy after TAR backup (`tar -c`) and TAR restore (`tar -x`)</li><li> `verify`: running `tar -d` after TAR backup and TAR restore</li><li> `compare`: Comparing meta data using `tar -tv` and `find . -type f` after TAR backup</li></ul>

### Procedure
When using file copy of mount points the following happens:
!["file copy"](/images/copy_files.png)

1. For each volume (parameter `snapshotVolumes`), the NetApp snapshot `rgcopy` is deleted and created again.
2. The stortage account with the name `rgcopy<sourceRG>` is created in the source RG. Alternatively, you can define the name using parameter `sourceSA`. The NFS file share `rgcopy` is created in the storage account. A private endpoint is created in the NFS subnet (parameter `subnetEndpoint`) of the source RG.
3. A backup script is started in each involved VM in the source RG. This script mounts the NFS share and backups the content of the mount points (parameters `createDisks`, `createVolumes`) to the file **`<vmName>/<mountPoint>/backup.tar`** in the NFS share **`rgcopy`**.
4. The BICEP template contains new disks and volumes (parameters `createDisks`, `createVolumes`) and skips disks (parameter `skipDisks`). After deploying the BICEP template in the target RG, a private endpoint is created in the NFS subnet of the target RG.
5. A restore script is started in each involved VM in the target RG. It partitions, formats and mounts newly created disks and changes `/etc/fstab`. After that, it mounts the NFS share and restores the files to the mount points (parameters `createDisks`, `createVolumes`).
6. In the target RG, the private endpoints to the NFS share are deleted once all restore scripts (in all VMs) have finished.
7. In the source RG, neither the private endpoints to the NFS share nor the NFS share and storage account are deleted (as long as you do not set parameter `deleteBackups`). If you want to delete them later, you can start RGCOPY again with parameter `justDeleteBackups`.

When rebooting a VM in the source RG, the NFS share is unmounted. You can mount it again using bash script `/mnt/mntrgcopy.sh`.

You can use the following scenarios:

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

> :warning: **Warning:** RGCOPY backups all files from the path `<mountPoint>/.snapshot/rgcopy/*` This is the directory for the snapshot with the name 'rgcopy'. If this snapshot directory does not exists then RGCOPY backups the files in `<mountPoint>/*`<BR>Not setting parameter `snapshotVolumes` results in using an outdated snapshot and in inconsistent data in the target RG.

#### Converting disks to a NetApp volumes

This works similar to copying NetApp volumes. However, you do not need parameter `snapshotVolumes` here. Instead, you need:
- **`skipDisks`** = `@(`**`"diskName1"`**`, ...)`<BR>Hereby, you specify the disks in the source RG that contained the data of the mount points. As a result, all these disks are not copied. No snapshot for these disks is created.
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
You can use RGCOPY for creating the target RG in a different region. Therefore, disks have to be copied to the target region. The runtime depends on the size of the disks. When creating a new disk or volume using backup/restore as described above, the runtime does not depend on the disk/volume size. It depends on the total size of all files inside the disk/volume. Therefore, it might be a good idea deleting unneeded files before copying a resource group. In particular for databases, you can decrease the total file size (and RGCOPY runtime) by deleting archive log files or unneeded database backups.

parameter|[DataType]: usage
:---|:---
**`netAppAccountName`** | **[string]**: Name of the created NetApp Account in the target RG.<BR>Default is `rgcopy-<targetRG>`<BR>:warning: **Warning:** NetApp Account names must be unique in Azure. This should be no issue when using the default name. Be aware that the NetApp Account name is stored as a constant in the BICEP template created by RGCOPY. Therefore, it is not possible to re-use this BICEP template for deploying another resource group.
**`netAppServiceLevel`** | **[string]**:Service Level of the created NetApp Pool.<BR>Allowed values: Standard, Premium, Ultra. Default is `Premium`
**`netAppNetworkFeatures`** | **[string]**:Network Features for NetApp Volumes.<BR>Allowed values: Standard, Basic. Default is `Standard`
**`netAppPoolName`** | **[string]**: Name of the created NetApp Pool.<BR>Default is `rgcopy-s-pool`, `rgcopy-p-pool`, `rgcopy-u-pool` (for Service Level **S**tandard, **P**remium, **U**ltra)
**`netAppPoolGB`** | **[int]**: Size of the created NetApp Pool.<BR>Default value is 4096<BR>:memo: **Note:** RGCOPY creates a larger NetApp pool if the sum of all volumes is larger than 4096 GiB. Using this parameter you can increase the capacity pool size in the target RG, even if the size of all created volumes is less than 4096 GiB.
**`createDisksTier`** | **[string]**: By default, disks created by RGCOPY parameter `createDisks` have the minimum performance tier 'P20' to speed-up backup/restore on small disks. You can change the minimum performance tier to any value between 'P2' and 'P50' using parameter `createDisksTier`
**`nfsQuotaGiB`**|**[int]** Maximum size of the temporary RGCOPY NFS share. Default value is 5120.
**`waitBackup`**|**[switch]**: You can restart RGCOPY using this additional switch if RGCOPY has been terminated while waiting for file backup to finish.
**`waitRestore`**|**[switch]**: You can restart RGCOPY using this additional switch if RGCOPY has been terminated while waiting for file restore to finish.


***
## Clone and Merge Mode
### Clone Mode

In Clone mode, one or more VMs are cloned within the same resource group. Hereby, new VMs are created having the same configuration as their original VM. The disks, NICs and public IP addresses of the cloned VMs are also cloned. A cloned VM is by default not part of any Availability Group, Proximity Placement Group or VMSS Flex. However, you can attach the VM to an existing Availability Group, Proximity Placement Group or VMSS Flex by using RGCOPY parameters.

The OS name of an original VM and a cloned VM is identical. However, you must change the Azure resource name of the cloned VM using parameter `setVmName` (this parameter also defines, which VMs are cloned). The names of the cloned disks, NICs and public IP addresses are automatically changed.

 The original VM and the cloned VM are attached to the same virtual subnet. This is possible since the following changes are done:
- The original VM is stopped. This prevents a name reolution issue when having two VMs with the same OS name in the same subnet.
- An Azure Read Only resource lock is created that prevents starting the original VM.
- Private IP Addresses of the clone are changed to dynamic.

#### Using clone mode for changing availibility features
A use case of clone mode is moving a VM from an Availibity Set to an Availability Zone. This cannot be done without deleting the VM first. However, recreating the VM in the new zone might fail for any reason, for example capacity issues in the new zone. Recreating them in the old zone might also fail.

Using RGCOPY for this is much more save because you can create clones while the original VMs still exist. You should delete the original VM only if the clone creation worked fine. The following example moves VMs app1 (which is part of an Availibity Set) to zone 1 and VM app2 to zone 2:

1. **create clones**
    Hereby, the VMs app1 and app2 are stopped and a read-only lock is set on these VMs. Two additional VMs app1-clone and app2-clone are created and attached to the same subnet. The OS names of the cloned VMs is still app1 and app2. This is done with the following script:

```powershell
# clone VMs
$rgcopyParameter = @{
    cloneMode   = $True
    sourceRG    = 'clone_test'
    setVmName = @(
        'app1-clone @ app1'
        'app2-clone @ app2'
    )
    setVmZone = @(
        '1 @ app1'
        '2 @ app2'
    )
}
.\rgcopy.ps1 @rgcopyParameter
```

The script copies all disks (including database files) of theses VMs using snapshots. Therefore, the cloned VMs contain the complete state.

2. **test the cloned VMs**
    To be on the save side, you might test your workload with the cloned VMs. In case of any issue, you can still stop the VMs app1-clone and app2-clone, remove the read-only lock and start the original VMs app1 and app2 again. Afterwards, you can delete app1-clone and app2-clone with their disks, NICs and public IP addresses.
    Keep in mind that testing your workload might change the state of the cloned VMs (e.g. content of database). If you decide to go back to the original VMs then the original state is automatically restored. If you want to keep the state changes during your test and still want to go back to the original VMs then you need to create new disk snapshots of the cloned disks and restore them on the original disks.

3. **delete the original VMs**
    Delete the original VMs app1 and app2. If you want to change the Azure resource names app1-clone and app2-clone back to their original names then you have to repeat the clone process. However, this is not really needed.

You can change any configuration with RGCOPY. The following script moves the VMs from Availibility Sets to a VMSS Flex:

```powershell
# create VMSS Flex Config
$paramConfig = @{
    Location                    = 'eastus'
    OrchestrationMode           = 'Flexible'
    PlatformFaultDomainCount    = 1
    Zone                        = @('1', '2')
}
$vmssConfig = New-AzVmssConfig @paramConfig
# create VMSS Flex 
$paramVmss = @{
    ResourceGroupName           = 'clone_test'
    VMScaleSetName              = 'vmssZone'
    VirtualMachineScaleSet      = $vmssConfig
}
New-AzVmss @paramVmss

# clone VMs
$rgcopyParameter = @{
    cloneMode = $True
    sourceRG  = 'clone_test'
    setVmName = @(
        'app1-clone @ app1'
        'app2-clone @ app2'
    )
    setVmZone = @(
        '1 @ app1'
        '2 @ app2'
    )
    attachVmssFlex = 'vmssZone'
}
.\rgcopy.ps1 @rgcopyParameter
```

#### Clone mode parameters
The following parameters can be set in Clone Mode:

parameter|[DataType]: usage
:---|:---
**`cloneMode`**|**[switch]**: Turns on Clone Mode.
**`setVmName`**	= <BR>`@("vmNameClone @ vmNameOriginal", ...)`	|Define, which VMs should be cloned and set the new names of the cloned VMs: <ul><li>**vmNameClone**: VM name of the cloned VM in the source RG </li><li>**vmNameOriginal**: VM name in source RG </li></ul>RGCOPY does not rename the *host* name of the VM. You have to do this on OS level inside the VM after the VM has been cloned.
**`attachVmssFlex`**	= <BR>`@("vmssFlexName @ vmNameOriginal", ...)`	|By default, the cloned VMs are detached from their Virtual Machine Scale Set. However, you can attach them to the same or a different VM Scale Set (compared with the original VM) using this parameter:<ul><li>**vmssFlexName**: VM name of an existing VM Scale Set Flexible in the source RG</li><li>**vmNameOriginal**: VM name in source RG </li></ul>
**`attachAvailabilitySet`**	= <BR>`@("avSetName @ vmNameOriginal", ...)`	|By default, the cloned VMs are detached from their Availability Set. However, you can attach them to the same or a different Availability Set (compared with the original VM) using this parameter:<ul><li>**avSetName**: VM name of an existing Availability Set in the source RG</li><li>**vmNameOriginal**: VM name in source RG </li></ul>
**`attachProximityPlacementGroup`**	= <BR>`@("[ppgRG/] ppgName @ vmNameOriginal", ...)`|By default, the cloned VMs are detached from their Proximity Placement Group. However, you can attach them to the same or a different Proximity Placement Group (compared with the original VM) using this parameter:<ul><li>**ppgName**: VM name of an existing Proximity Placement Group</li><li>**vmNameOriginal**: VM name in source RG </li><li>optionally **ppgRG**: Resource group that contains the Proximity Placement Group. This is only needed if the PPG is not part of the source RG</li></ul>
**`setVmSize`**<BR>**`setVmZone`**<BR>**`setVmFaultDomain`**<BR>**`setDiskSize`**<BR>**`setDiskTier`**<BR>**`setDiskBursting`**<BR>**`setDiskCaching`**<BR>**`setDiskSku`**|Same parameters as in **Copy Mode**. They are described in section [Resource Configuration Parameters](./rgcopy-docu.md#Resource-Configuration-Parameters). Be aware that these parameters only have an impact on the newly created resources in the sourceRG. Already existing resources are not modified (except setting a ReadOnly lock on the cloned VMs).


***
### Merge Mode

In Merge mode, one or more VMs are copied and attached at an existing subnet in the target RG. The names of the VMs can be optionally changed using parameter `setVMName`. The disks, NICs and public IP addresses of the copied VMs are also copied and automatically renamed. The private IP address is changed to `Dynamic`.

The following limitations exist in Merge Mode:
- The target RG must already exist and contain the virtual subnets  that are defined by parameter `setVmMerge`
- The VM name on OS level is not changed

Merge Mode can be used for copying a jumpbox from one resource group to a different subnet in another resource group.

The following parameters can be set in Merge Mode:

parameter|[DataType]: usage
:---|:---
**`mergeMode`**|**[switch]**: Turns on Merge Mode.
**`setVmMerge`**= <BR>`@("net/subnet@vm1,vm2", ...)`|**[string] or [array]**: Merge VMs of the source RG into an existing subnet of the target RG:<ul><li>**vm**: VM name in source RG</li><li>**net**: vnet name in target RG</li><li>**subnet**: subnet name in target RG</li></ul>*Only* the specified VMs, their disks, NICs and public IP addresses are copied.
**`setVmName`**<BR><BR>**`attachVmssFlex`**<BR>**`attachAvailabilitySet`**<BR>**`attachProximityPlacementGroup`**<BR><BR>**`setVmSize`**<BR>**`setVmZone`**<BR>**`setVmFaultDomain`**<BR>**`setDiskSize`**<BR>**`setDiskTier`**<BR>**`setDiskBursting`**<BR>**`setDiskCaching`**<BR>**`setDiskSku`**|Same parameters as in **Clone Mode**.

The following example copies VMs 'app1' and 'app2' from the source RG ('source_rg') and merges them into the subnet 'vnet/subnet' of the target RG ('target_rg'). The VM names in the target RG are changed to 'app10' and 'app20' and the availablilty zones for these VMs are set. Keep in mind that RGCOPY changes only the Azure resource names of these VMs. The names on OS level are not changed.

```powershell
$rgcopyParameter = @{
    sourceRG        = 'source_rg'
    targetRG        = 'target_rg'
    targetLocation  = 'eastus'
    MergeMode       = $True

    setVmMerge = @(
        'vnet/subnet @ app1'
        'vnet/subnet @ app2'
    )
    setVmName = @(
        'app10 @ app1'
        'app20 @ app2'
    )
    setVmZone = @(
        '1 @ app1'
        '2 @ app2'
    )
}
.\rgcopy.ps1 @rgcopyParameter
```


***
### Comparing RGCOPY Modes

feature|Copy Mode|Merge Mode|Clone Mode
:---|:---|:---|:---
Deployment| Target RG only|Target RG<BR>(might be same as source RG)|Source RG only
Virtual networks|<ul><li>Vnets are copied</li><li>VMs stay attached</li></ul>|<ul><li>Vnets must already exist</li><li>Merged VMs must be manually attched using `setVmMerge`</li></ul>|<ul><li>Cloned VMs are automatically attached to same subnet</li></ul>
Changes in<BR>source RG|<ul><li>Snapshots</li></ul>|<ul><li>Snapshots</li><li>New VMs, disks, NICs,<BR>Public IP addresses<BR>(if source RG = target RG)</ul>|<ul><li>Snapshots</li><li>New VMs, disks, NICs,<BR>Public IP addresses</li><li>Read lock on original VMs</li></ul>
OS names of VMs|Not changed<BR>by RGCOPY|Not changed<BR>by RGCOPY|Not changed<BR>by RGCOPY
Azure names of VMs|Same names as in source RG.<BR>**Might be changed** using `setVmName`.|Same names as in source RG.<BR> **Might be changed** using `setVmName`.<BR>Must be changed if source RG and target RG are identical.|**Must be changed** using `setVmName`
Other Azure names|Optionally use:<ul><li>`renameDisks`</li><li>`renameNICs`</li><li>`renameIPs`</li><li>`renameNSGs`</li><li>`renameAll`</li><li>`renameVnets`</li></ul>|Automatically renamed:<ul><li>disks</li><li>NICs</li><li>IP addresses</li></ul>| see Merge Mode
Availability resources<ul><li>PPGs</li><li>AvSets</li><li>VMSS Flex</li>|<ul><li>PPGs, AvSets, VMSS copied by default. This can be changed using <ul><li>`skipProximityPlacementGroup`</li><li>`skipAvailabilitySet`</li><li>`skipVmssFlex`</li></ul><li>**VMs keep being attached** to the same PPGs, AvSets, VMss as in source RG.</li><li>Changes possible by creating new PPGs, AvSets, VMSS using the following parameters:<ul><li>`createProximityPlacementGroup`</li><li>`createAvailabilitySet`</li><li>`createVmssFlex`</li></ul>:warning: **Warning:** if one of the three createXX parameters is set then all of the three skipXX parameters are automatically set, too.</ul>|<ul><li>VMs are **detached by default** from all PPGs, AvSets, VMSS</li><li>VMs can be attached using<ul><li>`attachProximityPlacementGroup`<BR>(PPG in different RG possible)</li><li>`attachAvailabilitySet`</li><li>`attachVmssFlex`</li></ul><li>In this case, PPGs, AvSets, VMSS must already exist before starting RGCOPY.</li></ul>|see Merge Mode
Availability Zone|**removed** by default<BR>(can be changed using `setVmZone`)|copied by default<BR>(can be changed using `setVmZone`)|see Merge Mode
Disk SKU|set to **Premium_LRS** by default<BR>(can be changed using `setDiskSku`)|copied by default<BR>(can be changed using `setDiskSku`)|see Merge Mode


***
## Just copy disks
By using parameter **`justCopyDisks`**, you can copy all or specific disks from the source RG to the target RG. This includes detached disks. 

The zone property of the disks is also copied. If you want to deploy the disks in the target RG in a different zone then you must set parameter **`defaultDiskZone`**. This parameter is then applied to all disks. Setting it to `0` will remove zonal deployment. 

Alternatively, you can set one of the following parameters: **`switchZone0`**, **`switchZone1`**, **`switchZone2`**, **`switchZone3`**. If one of these parameters is set then all disks of a given zone are moved to the configured zone. Parameter `defaultDiskZone` is ignored in this case. All other disks stay in their original zone. For example, by setting `switchZone0=1` and `switchZone1=2`, all non-zonal disks are moved to zone 1 and all disks that were originally in zone 1 are moved to zone 2. Disks in zone 2 and 3 stay in their zones.

You can use parameters `useBlobCopy`, `useSnapshotCopy` and `useAzCopy` to configure the copy process. When copying to a differenet region, we recommend using parameter `useAzCopy`, see the following BLOG for details: https://techcommunity.microsoft.com/blog/sapapplications/accelerating-cross-region-azure-disk-copying/4539245


Example 1: copy all disks with keeping their zone using AzCopy (if the source region is different from the target region)

```powershell
$rgcopyParameter = @{
    sourceRG        = 'contoso_source_rg'
    targetRG        = 'contoso_target_rg'
    targetLocation  = 'eastus'

    justCopyDisks   = $true
    useAzCopy        = $true
}
.\rgcopy.ps1 @rgcopyParameter
```

Example 2: copy specific disks to zone 1

```powershell
$rgcopyParameter = @{
    sourceRG        = 'contoso_source_rg'
    targetRG        = 'contoso_target_rg'
    targetLocation  = 'eastus'

    justCopyDisks   = @('disk1', 'disk2')
    defaultDiskZone = 1
    useAzCopy        = $true
}
.\rgcopy.ps1 @rgcopyParameter
```

When a disk with the same name already exists in the target RG then you can use parameter **`defaultDiskName`** to copy a *single* disk and rename it. In the following example, the disk is not zonal deployed:

```powershell
$rgcopyParameter = @{
    sourceRG        = 'contoso_source_rg'
    targetRG        = 'contoso_target_rg'
    targetLocation  = 'eastus'

    justCopyDisks   = @('disk1')
    defaultDiskZone = 0
    defaultDiskName = 'disk1_newName'
    useAzCopy        = $true
}
.\rgcopy.ps1 @rgcopyParameter
```


***
## Starting Scripts from RGCOPY

RGCOPY can start scripts in specific scenarios. These are either [locally running scripts](./rgcopy-docu.md#Locally-running-scripts) (PowerShell scripts running on the same machine that runs RGCOPY) or [remotely running scripts](./rgcopy-docu.md#Remotely-running-scripts) (scripts running inside the VMs). These scripts have to be developed on your own. RGCOPY continues once the scripts have finished. The ouptut of the scripts is contained in the RGCOPY log file (when using `Write-Output` or `echo`).

In addition, RGCOPY starts scripts for backup/restore. These scripts are part of RGCOPY and cannot be changed. They are used for copying [NetApp Volumes](./rgcopy-docu.md#File-Copy-of-NetApp-Volumes).



RGCOPY passes the following parameters to your scripts:
1. All supplied RGCOPY parameters.
2. Some of the optional RGCOPY parameters, even when not supplied. For example `targetSub`.
3. Parameter **`sourceLocation`** that contains the region of the source RG
4. Parameter **`vmName`** that contains the name of the VM that is running the script (or your local machine name for locally running scripts).
5. Parameter **`vmType`** that contains the value of the VM tag `rgcopy.VmType` of the VM that is running the script.
6. Parameters **`vmSize<vmName>`**, **`vmCpus<vmName>`**, **`vmMemGb<vmName>`** that contain Azure VM size configuration for all deployed VMs. `<vmName>` is the Azure name of the VM that only contains word characters and numbers. All special characters are removed.
7. Parameter **`rgcopyParameters`** that contains the names of all passed parameters.

In all scripts you can simply access the passed parameters using variables, for example `$targetSub`. Only *remotely* running *PowerShell* scripts must contain a `param` clause.

RGCOPY uses `Invoke-AzVMRunCommand` for remotely running scripts. RGCOPY terminates with an error message if the output of such a script contains the text `++ exit 1` within the last lines. Be aware that `Invoke-AzVMRunCommand` does only return the last few dozen lines of `stdout` and `stderr`.

### Locally running scripts
RGCOPY can start local PowerShell scripts in the following two scenarios. These scripts have to be developed on your own. An example of such a script is [examplePostDeployment.ps1](./examples/examplePostDeployment.ps1).

parameter|[DataType]: usage
:---|:---
**`pathPostDeploymentScript`**|**[string]**: path to local PowerShell script<BR>You can use this script for deploying additional resources.<BR>When using this RGCOPY parameter, the following happens after deploying the BICEP templates (in RGCOPY step *deployment*):<ol><li>SAP is started using parameter `scriptStartSapPath` (see below).</li><li>The PowerShell script located in `pathPostDeploymentScript` is started.</li></ol>
**`pathPreSnapshotScript`**|**[string]**: path to local PowerShell script<BR>When using this RGCOPY parameter, the following happens:<ol><li>All VMs in the source RG  are started.</li><li>SAP is started using another script inside a VM. The script has to be specified using parameter`scriptStartSapPath` (see below).</li><li>The PowerShell script located in `pathPreSnapshotScript` is started.</li><li>RGCOPY waits by default for 5 minutes. This can be configured using parameter **`preSnapshotWaitSec`**</li><li>**All VMs in the source RG are stopped** (even when they where running before RGCOPY was started)</li><li>The disk snapshots are created.</li></ol>

### Remotely running scripts

For the following scenarios, remotely running scripts (running inside the VMs) can be started by RGCOPY. For Windows VMs, the scripts must be PowerShell scripts. For LINUX VMs, the scripts must be Shell scripts. Examples of such scripts are [exampleStartAnalysis.ps1](./examples/exampleStartAnalysis.ps1) and [exampleStartAnalysis.sh](./examples/exampleStartAnalysis.sh).

parameter|[DataType]: usage
:---|:---
**`scriptStartSapPath`** =<BR>`'[local:]<path>@<VM>[,...n]'`|**[string]**: Runs a script for starting the SAP system (database and NetWeaver), for example `'/root/startSAP.sh @ sapserver'`<ul><li>**path**: Path of the script to be started. The script path is typically inside the VM. However, you can use a script that is stored on your local PC by prefixing 'local:', for example `'local:c:\scripts\startSAP.sh @ sapserver'` </li><li>**VM**: Name of the VM where the script should be executed. If you specify several comma seperated VM names then the script will be executed on each VM, one after the other, for example  `'/root/startSAP.sh @ sapserver1, sapserver2'`</li></ul>:bulb: **Tip:** Rather than specifying a script name, you can exexute a command, for example `'su - sidadm -c startsap @ sapserver'`<BR>:bulb: **Tip:** The script is started using PowerShell cmdlet `Invoke-AzVMRunCommand`. This will fail if the script does not finish within roughly half an hour. Therefore, you cannot use this for long running tasks (as an SAP benchmark). In this case, you must write a script that triggers or schedules the long running task and finishes without waiting for the task to complete.
**`scriptStartLoadPath`** =<BR>`'[local:]<path>@<VM>[,...n]'`|**[string]**: Runs a script for starting SAP Workload (SAP benchmark).<BR><BR>Same details apply here as for parameter `scriptStartSapPath` above.
**`scriptStartAnalysisPath`** =<BR>`'[local:]<path>@<VM>[,...n]'`|**[string]**: Runs a script for starting Workload Analysis.<BR><BR>Same details apply here as for parameter `scriptStartSapPath` above.
**`startWorkload`**|**[switch]**: Enables the last step of RGCOPY: *Workload and Analysis*.<BR><BR>This switch enables the RGCOPY step *Start Workload*. In this step, the following is performed:<ol><li>SAP is started using parameter `scriptStartSapPath`</li><li>The workload is started using parameter `scriptStartLoadPath`</li><li>The workload analysis is started using parameter `scriptStartAnalysisPath`</li></ol>:memo: **Note:** Even when [Azure Tags](./rgcopy-docu.md#RGCOPY-Azure-Tags) are used, SAP workload does not start automatically. You must set the switch `startWorkload` in addition.
**`vmStartWaitSec`**|**[int]**: Wait time in seconds, default value: `5 * 60`<BR><BR>After starting the VMs, RGCOPY gives the VMs some time to become fully operational. This delay might be needed for starting all services (for example, SSH service) inside the VM.
**`vmAgentWaitMinutes`** |**[int]**: Maximum wait time in minutes, default value: `30`<BR><BR>Before running Invoke-AzVMRunCommand, RGCOPY waits until the Azure Agent status is 'Ready'. This is checked every minute. If the status is still not 'Ready' after the maximum wait time then RGCOPY gives up and terminates with an error.

> :warning: **Warning:** For remotely running scripts, RGCOPY uses the cmdlet **`Invoke-AzVMRunCommand`** that connects to the Azure Agent running inside the VM. Make sure that you have installed a **recent version of the Azure Agent**. See also https://docs.microsoft.com/en-US/troubleshoot/azure/virtual-machines/support-extensions-agent-version.

`Invoke-AzVMRunCommand` expects that the script finishes within roughly one hour. If the script takes longer then `Invoke-AzVMRunCommand` (and RGCOPY) terminates with "Long running operation failed". If you want to use longer running scripts then you must write a wrapper script that just triggers or schedules your original script. The wrapper script can then be started using RGCOPY.

RGCOPY writes the working directory of `Invoke-AzVMRunCommand` to stdout respectively stderr (and the RGCOY log file), for example `/var/lib/waagent/run-command/download/4`. You might double check the log files in this directory once `Invoke-AzVMRunCommand` fails with a timeout.


### Starting SAP
For starting SAP, you must write your own script. This script must contain `systemctl start sapinit` if you are using NetApp volumes. The path of the script has to be specified using parameter `scriptStartSapPath` (see above). This script will be started by RGCOPY in the following cases:
1. In the source RG: before running the local script specified by parameter `pathPreSnapshotScript`
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


***
## Special cases

### VM Extensions
By default, RGCOPY installs the VM extension `AzureMonitorLinuxAgent` (on Linux) or `AzureMonitorWindowsAgent` (on Windows). RGCOPY ignores all errors related to a VM extension installation.


You can skip this by using RGCOPY switch parameter **`skipExtensions`**. When parameter `autoUpgradeExtensions` is set then the extensions will automatically upgrade in the future.

You can configure VM extension installation using the following RGCOPY parameters:

parameter|[DataType]: usage
:---|:---
**`skipExtensions`** |**[switch]**: Do not install any VM extension
**`ignoreExtensionErrors`** |**[switch]**: Ignore errors during VM extension installation (turned on by default).<BR>You can disable this switch by setting `ignoreExtensionErrors = $false`
**`autoUpgradeExtensions`** |**[switch]**: Install the extension with Auto-Upgrade property set.
**`installExtensionsSapMonitor`** |Installs the **Azure VM extension for SAP solutions**<BR> **[array]**: Names of VMs for deploying this extension.<BR>Alternatively, you can set the Azure tag `rgcopy.Extension.SapMonitor` for the VM. If you do not want to install the SAP Monitor Extension although the Azure tag has been set, use switch `ignoreTags`.

### Cost Efficiency
By default, RGCOPY does not delete all its intermediate storage (snapshots in source RG, file backups). This can save a lot of time when regularly copying the same resource group. However, the intermediate storage results in Azure charges.

The following parameters activate additional steps at the very end of an RGCOPY run:

parameter|[DataType]: usage
:---|:---
**`deleteSnapshots`** |**[switch]**: By setting this switch, RGCOPY deletes those **snapshots** in the source RG that have been created by the current run of RGCOPY.<BR>When skipping some VMs or disks, RGCOPY does not create snapshots of these disks and does not delete them afterwards.
**`deleteBackups`** |**[switch]**: By setting this switch, RGCOPY deletes the storage account in the source RG that has been used for storing **file backups** (during the copy process of NetApp volumes).
**`stopVMsTargetRG`** |**[switch]**: When setting this switch in **Copy Mode**, RGCOPY stops all VMs in the target RG after deploying it. Typically, this is not what you want. However, it might be useful for saving costs when deploying a resource group that is not used immediately.

Tip: You can use the following RGCOPY parameters for reducing cost in the target RG: `setVmSize`, `setDiskSku`, `setDiskTier`, `createDisksTier`, `netAppServiceLevel`, `netAppPoolGB` and `skipBastion`.
The *default* values of some RGCOPY parameters also have some cost impact. See parameters `createDisksTier` and `setDiskSku` above.

The behavior of RGCOPY changed for copying NetApp volumes. It now starts only *needed* VMs in the source RG. These VMs are stopped again by RGCOPY. In earlier versions of RGCOPY *all* VMs were started in the source RG and you had to stop them on your own.


***
## Appendix

### Supported Azure Resources
RGCOPY copies the following resources from the **source RG**:

- Microsoft.Compute/virtualMachines
- Microsoft.Compute/disks
- Microsoft.Network/virtualNetworks
- Microsoft.Network/networkSecurityGroups
- Microsoft.Network/applicationSecurityGroups
- Microsoft.Network/networkInterfaces
- Microsoft.Network/publicIPAddresses
- Microsoft.Network/publicIPPrefixes
- Microsoft.Network/routeTables
- Microsoft.Network/privateDnsZones
- Microsoft.Network/privateEndpoints
- Microsoft.Network/loadBalancers
- Microsoft.Network/natGateways
- Microsoft.Compute/availabilitySets
- Microsoft.Compute/proximityPlacementGroups
- Microsoft.Compute/virtualMachineScaleSets (only VMSS Flex)
- Microsoft.Network/bastionHosts
- Microsoft.Storage/storageAccounts/fileServices
- Microsoft.Storage/storageAccounts/blobServices
- Microsoft.NetApp/netAppAccounts/capacityPools/volumes (using file copy)

In addition, it copies the following resources from **other resource groups** (within the same subscription) if they are **referrenced** by any other copied resource:

- Microsoft.Network/virtualNetworks
- Microsoft.Network/networkSecurityGroups
- Microsoft.Network/applicationSecurityGroups
- Microsoft.Network/networkInterfaces
- Microsoft.Network/publicIPAddresses
- Microsoft.Network/publicIPPrefixes
- Microsoft.Network/routeTables
- Microsoft.Network/natGateways
- Microsoft.Compute/availabilitySets
- Microsoft.Compute/proximityPlacementGroups
- Microsoft.Compute/virtualMachineScaleSets (only VMSS Flex)

As long as you do not set parameter **`keepUnusedResources`**, the following resources are **not copied** if they are **not referrenced** by other resources:

- Microsoft.Network/networkSecurityGroups
- Microsoft.Network/applicationSecurityGroups
- Microsoft.Network/publicIPAddresses
- Microsoft.Network/publicIPPrefixes

Resources that are not mentioned above are **not copied**, even if they are located in the source RG. RGCOPY can **only copy VMs that are located in the same region** as the source RG. Existing **snapshots are not copied**. However, RGCOPY creates its own snapshots (with suffix `.rgcopy`) for copying disks.

Not all properties of the resources are copied, for example Network Peering is not copied. However, RGCOPY displays a warning for each property that is ignored by RGCOPY.

In the **target RG**, the following resources might be deployed in addition:

- Microsoft.Compute/virtualMachines/extensions
- Microsoft.NetApp/netAppAccounts
- Microsoft.Compute/images

### Changes in the source RG
- RGCOPY creates snapshots of all disks in the source RG with the name `<diskname>.rgcopy`.
- if BLOB copy is used, then RGCOPY grants access to the snapshots at the beginning and revokes this access at the end of the BLOB copy.
- If RGCOPY parameter `snapshotVolumes` is supplied, then snapshots of NetApp volumes with the name `rgcopy` are created.
- If RGCOPY parameter `createVolumes` or `createDisks` is supplied, then a **storage account** with a premium NFS share is created in the source RG. All needed VMs are started (and stopped later) in the source RG. In these VMs, the NFS share `/mnt/rgcopy` is mounted. The storage account will not be deleted again unless you use RGCOPY parameter `deleteSourceSA`.
- If RGCOPY parameter `pathPreSnapshotScript` is supplied, then the specified PowerShell script is executed before creating the snapshots. In this case, all VMs are started, the PowerShell script (located on the local PC) is executed and finally all VMs are stopped in the source RG.

### Application Consistency
>:warning: **Warning:** Snapshots of disks are made independently. However, database files could be distributed over several data disks. Using these snapshots for creating a VM could result in inconsistencies and database corruptions in the target RG. Therefore, RGCOPY cannot copy VMs with more than one data disk while the source VM is running. However, RGCOPY does work with running VMs that have only a single data disk (and no NetApp volume) or a single NetApp volume (and no data disk).

In the unlikely case that database files are distributed over the data disk (or volume) and the OS disk, you must stop the VM before starting RGCOPY. RGCOPY does not (and cannot) double check this unlikely case.

> :warning: **Warning:** When using NetApp volumes, RGCOPY does not know which volume belongs to which VM. Therefore, you must specify the volume snapshots using RGCOPY parameter **`snapshotVolumes`**. Not doing so results in using an outdated snapshot and inconsistent VM in the target RG.

>:warning: **Warning:** RGCOPY can convert a managed disk in the source RG to a NetApp volume in the target RG (and vice versa) by changing mount points. Herby, a file backup is made from the mount points in the source RG. A mount point is either a disk or a NetApp volume.<BR>Before starting the backup/restore, RGCOPY double checks that there is no open file in the mount point directory. However, it does not check this *during* backup/restore. Therefore, you must you must make sure that no LINUX service or job that changes files in the mount point directories is started during backup/restore.

### Multiple instances of RGCOPY
It is not allowed, running multiple instances of RGCOPY at the *same* time for deploying/changing the *same* target RG. However, running multiple instances of RGCOPY using the same source RG is possible with the following restrictions:
1. Each parallel running RGCOPY instance must have its own working directory. This can be forced by setting a different value for parameter `pathExportFolder` for each RGCOPY instance (or by running the different RGCOPY instances on different PCs).
2. The source RG must not be changed. Therefore:
    - snapshots must not be created (use parameter `skipSnapshots`)
    - the following parameters are *not* allowed: `snapshotVolumes`, `createVolumes`, `createDisks`, and `pathPreSnapshotScript`
3. The source RG and all target RGs must be in the same region when running multiple instances of RGCOPY in parallel.
  
RGCOPY does not double check whether another instance of RGCOPY is running. When running multiple instances of RGCOPY in parallel, you must take care of the restrictions on your own.


### Created Files
RGCOPY creates the following files in the user home directory (or in the directory which has been set using RGCOPY parameter `pathExportFolder`) on the PC where RGCOPY is running:

file|*[DataType]*: usage
:---|:---
`rgcopy.<source_RG>.SOURCE.json`|Exported template from the source RG
`rgcopy.<target_RG>.TARGET.json`<BR>`rgcopy.<source_RG>.TARGET.json`<BR>`rgcopy.<target_RG>.TARGET.bicep`<BR>`rgcopy.<target_RG>.DISKS.bicep`|Generated template files created by RGCOPY<BR>(dependent on used RGCOPY mode)
`rgcopy.<target_RG>.TARGET.log`<BR>`rgcopy.<source_RG>.SOURCE.log`|Standard RGCOPY log file<BR>(dependent on used RGCOPY mode)
`rgcopy.txt`|Backup of the running script rgcopy.ps1 used for support
`rgcopy.<target_RG>.<time>.zip`<BR>`rgcopy.<source_RG>.<time>.zip`| Compressed ZIP file that contains all files above<BR>(dependent on used RGCOPY mode)
`rgcopy.<target_RG>.TEMP.json`<BR>`rgcopy.<target_RG>.TEMP.txt`| temporary files

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
**`rgcopy.VmType`**       |**[string]**: When starting s script from RGCOPY using parameters `scriptStartSapPath`, `scriptStartLoadPath` or `scriptStartAnalysisPath` then the value of this tag is contained in variable `vmType`. Hereby, the script can behave differently dependent on the VM where it has been started.

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
Azure is validating a BICEP template as the first step of an deployment. This validation might fail for various reasons. In this case, you can see the errors **in the output of RGCOPY** (on the host and in the RGCOPY log file). RGCOPY performs several checks (including quota of VM families) before starting the deployment.

If the BICEP template validation succeeds but errors occur during deployment then you can check details of the deployment errors **in the Azure Portal**.
