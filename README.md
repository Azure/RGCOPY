# RGCOPY

RGCOPY (**R**esource **G**roup **COPY**) is a tool that copies resources of an Azure resource group (**source RG**) to a new resource group (**target RG**). It can copy a whole landscape consisting of many servers within a single Azure resource group. The target RG might be in a different region or subscription. RGCOPY is running on **Windows** and in a **Linux** VM.

RGCOPY has been developed for copying and testing SAP systems in Azure. Therefore, it [supports](./rgcopy-docu.md#Supported-Azure-Resources) the most important Azure resources needed for SAP, for example **VMs**, **disks**, **load balancers**, storage accounts including the content of **containers**, **SMB** and **NFS shares**.

 >:memo: **Note:** Recent versions of *RGCOPY* can create parallel running *AzCopy* jobs for copying disks to another region (by using parameter `useAzCopy`). This is the [fastest possible way for cross-region disk copy]( https://techcommunity.microsoft.com/blog/sapapplications/accelerating-cross-region-azure-disk-copying/4539245).
 If you just want to copy disks you could use AzCopy without RGCOPY. However, this would be much more complicated because you would have to create network rules, user delegation tokens and SAS tokens on your own. RGCOPY handles these tasks for you and coordinates concurrent jobs. In addition, RGCOPY takes care of special cases, such as OS disks of confidential VMs that require three blob copies per disk instead of a single one.
 
RGCOPY is a PowerShell script that uses cached credentials. Before starting RGCOPY, you must run the PowerShell cmdlet `Connect-AzAccount` to create the credentials. For example:


```powershell
Update-AzConfig -EnableLoginByWam $true

# create context
Connect-AzAccount `
    -AuthScope 'Storage' `
    -TenantId '7b5ebd57-e5fd-445f-a920-55897cd71921' `
    -Subscription 'Contoso Subscription'

# start RGCOPY using cached credentials
$rgcopyParameter = @{
    # mandatory parameters
    sourceRG        = 'SAP_master'
    targetRG        = 'SAP_copy'
    targetLocation  = 'westus'

    # optional parameters for setting context
    sourceSub       = 'Contoso Subscription'
    sourceSubUser   = 'user@contoso.com'
    sourceSubTenant = '7b5ebd57-e5fd-445f-a920-55897cd71921'

    # optional configuration parameters (examples):
    setVmSize = @(
        'Standard_M16ms @ HANA1, HANA2'     # M16ms for DB servers
        'Standard_M8ms @ SAPAPP'            # M8ms for app server    
        'Standard_D2s_v4'                   # D2s_v4 for all other VMs
    )
    setVmZone = 1   # zone 1 for all VMs (could be configured separately)
}
.\rgcopy.ps1 @rgcopyParameter
```
RGCOPY has different operation modes. By default, RGCOPY is running in Copy Mode. 
- In **[Copy Mode](./rgcopy-docu.md#Workflow)**, a BICEP template is created and deployed in the target RG. Disks are copied using snapshots. You can change several [resource properties](./rgcopy-docu.md#Resource-Configuration-Parameters) in the target RG:
    - Changing **VM size**, disk performance tier, disk bursting, disk caching, Write Accelerator, Accelerated Networking, ...
    - Adding, removing, and changing [availability](./rgcopy-docu.md#Parameters-for-Availability) configuration: **Proximity Placement Groups**, **Availability Sets**, **Availability Zones**, and **VM Scale Sets Flexible**.
    - Converting **disk SKUs** from and to `Premium_LRS`, `StandardSSD_LRS`, `Standard_LRS`, `Premium_ZRS`, `StandardSSD_ZRS`, `UltraSSD_LRS` and `PremiumV2_LRS`. Changing the logical sector size is not possible. Disks are copied using full or incremental snapshots, snapshot copy, blob copy or AzCopy. 
    - Renaming resources (VMs, disks, NICs, PIPs, VNETs, subnets) and **changing Address Space of VNETs** and subnets.
    - Converting disks to [NetApp Volumes](./rgcopy-docu.md#NetApp-Volumes-and-Ultra-SSD-Disks) and vice versa using **file copy**
- In **[Clone Mode](./rgcopy-docu.md#Clone-Mode)**, a VM is cloned within the same resource group. This can be used for changing VM zone, availibility set, PPG or VMSS Flex without deleting the existing VM.
- In **[Merge Mode](./rgcopy-docu.md#Merge-Mode)**, a VM is merged into a different resource group. This can be used for copying a jump box to a different resource group.


>:memo: **Copying or moving an (SAP) system to a different region**
>
 >RGCOPY has been originally developed to copy an SAP system within a single resource group for Microsoft internal testing. RGCOPY did not copy ***all*** resource types in this resource group and did it not copy ***all*** properties of these resources.
>
>In recent versions, the scope of RGCOPY has changed from a specialized tool (that supports only features needed Microsoft internally) to a more universal tool. The following improvements have been implemented:
>- The number of supported resource types has grown. RGCOPY can even copy storage accounts including the content of BLOB containers and SMB/NFS shares. The full **list of supported resource types** is included in the **[documentation](./rgcopy-docu.md#Supported-Azure-Resources)**.
>- The most important resource properties are copied. If a resource property is not copied then RGCOPY gives a **warning regarding the missing property**. As a starting point, run RGCOPY with parameter `simulate` and check all yellow warnings.
>- RGCOPY still requires a single source resource group that contains all VMs and all disks within a single region. However, **referenced resources in different resource groups** (e.g. VNETs and NICs) are also copied.
>
>Using RGCOPY for moving SAP systems still has some limitations:
>- Nature of copy
>    - RGCOPY performs a ***copy***, not a ***move***. The original system still exists if anything fails.<BR>
>    - RGCOPY does not change anything inside the VMs like changing the server name at the OS level or applying SAP license keys.
>- User Interface
>    - RGCOPY is a command-line tool optimized for automation. You can change almost every property in the target (compared with the source),  resulting in about 200 RGCOPY parameters.
>    - However, RGCOPY is not integrated into Azure portal and there is no other GUI.
>- Downtime
>    - If you want to *copy* a productive system to a test system then the downtime is very short: You just need to stop your productive servers for creating the disk snapshots.
>    - However, the downtime for *moving* a productive system is much longer. It includes the **time needed for copying the disks** to a different region, deploying the new resource group and **performing manual follow-up steps** like applying license keys. 
>- Support
>    - RGCOPY has been developed and is maintained by a single developer. It is an Open Source tool available in GitHub, not an official Microsoft product. Microsoft Product Support will not provide support for RGCOPY. However, you can suggest future features and report bugs using GitHub Issues.

**Open Source version of RGCOPY**
RGCOPY has been released as Open Source Software (OSS) in
- **https://github.com/Azure/RGCOPY**

There also exists a Microsoft internal version of RGCOPY with additional features. It is stored in a different repository. 

**Documentation**
The complete documentation is contained in file **[rgcopy-docu.md](./rgcopy-docu.md)** 

**YouTube training**
You can watch an introduction to RGCOPY on YouTube (22:35). This video shows an older version of RGCOPY from the year 2022:

[![RGCOPY](https://i.ytimg.com/vi/8pCN10CRXtY/hqdefault.jpg)](https://www.youtube.com/watch?v=8pCN10CRXtY)


## Trademarks
This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft 
trademarks or logos is subject to and must follow 
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.
