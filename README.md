# RGCOPY

RGCOPY (**R**esource **G**roup **COPY**) is a tool that copies the most important resources of an Azure resource group (**source RG**) to a new resource group (**target RG**). It can copy a whole landscape consisting of many servers within a single Azure resource group to a new resource group. The target RG might be in a different region or subscription. RGCOPY has been tested on **Windows**, **Linux** and in **Azure Cloud Shell**. It should run on **MacOS**, too.

The following example demonstrates the user interface of RGCOPY

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

RGCOPY has been developed for copying an SAP landscape and testing Azure with SAP workload. Therefore, it supports the most important Azure resources needed for SAP, as virtual machines, managed disks and Load Balancers. However, you can use RGCOPY also for other workloads.

>:memo: **Note:** The list of supported Azure resources is maintained in the RGCOPY documentation: **[https://github.com/Azure/RGCOPY/blob/main/rgcopy-docu.md#Supported-Azure-Resources](./rgcopy-docu.md#Supported-Azure-Resources)** 

## RGCOPY operation modes

RGCOPY has different operation modes. By default, RGCOPY is running in Copy Mode. 
- In **[Copy Mode](./rgcopy-docu.md#Workflow)**, an BICEP or ARM template is exported from the source RG, modified and deployed in the target RG. Disks are copied using snapshots. You can change several [resource properties](./rgcopy-docu.md#Resource-Configuration-Parameters) in the target RG:
    - Changing **VM size**, disk performance tier, disk bursting, disk caching, Write Accelerator, Accelerated Networking
    - Adding, removing, and changing [availability](./rgcopy-docu.md#Parameters-for-Availability) configuration: **Proximity Placement Groups**, **Availability Sets**, **Availability Zones**, and **VM Scale Sets**
    - Converting **disk SKUs** `Premium_LRS`, `StandardSSD_LRS`, `Standard_LRS`, `Premium_ZRS`, `StandardSSD_ZRS`, `UltraSSD_LRS` and `PremiumV2_LRS` using (incremental) **snapshots** and snapshot copy. Changing the logical sector size is not possible.
    - Converting disks to [NetApp Volumes](./rgcopy-docu.md#NetApp-Volumes-and-Ultra-SSD-Disks) and vice versa using **file copy**
- In **[Clone Mode](./rgcopy-docu.md#Clone-Mode)**, a VM is cloned within the same resource group. This can be used for adding application servers
- In **[Merge Mode](./rgcopy-docu.md#Merge-Mode)**, a VM is merged into a different resource group. This can be used for copying a jump box to a different resource group.
- In **[Update Mode](./rgcopy-docu.md#Update-Mode)**, you can change resource properties in the source RG, for example VM size, disk performance tier, disk bursting, disk caching, Write Accelerator, Accelerated Networking. For saving costs of unused resource groups, RGCOPY can do the following:
    - Changing disk SKU to 'Standard_LRS' (if the source disk has a logical sector size of 512 byte)
    - Deletion of an Azure Bastion including subnet and IP Address (or creation of a Bastion)
    - Deletion of all snapshots in the source RG
    - Stopping all VMs in the source RG
    - Changing NetApp service level to 'Standard' (or any other service level)

## Using RGCOPY for copying SAP systems

I'm frequently asked by SAP customers whether it's a good idea to use RGCOPY for moving their SAP landscape to a different region. The answer is: **it depends**. Actually, we are using RGCOPY for moving our SAP test landscapes. However, one should consider the following: <ul><li>RGCOPY performs a *copy*, not a *move*. Therefore, the SAP license becomes invalid. RGCOPY is not an SAP deployment tool. It just copies Azure resources. It does not change anything inside the VMs like changing the server name at the OS level or applying SAP license keys. </li><li> RGCOPY copies resources of a single Azure Resource Group. By default, it also copies the virtual network (to a new virtual network). Therefore, you cannot simply copy a landscape that is distributed over different resource groups and networks.</li><li> The resource types that are supported by RGCOPY is limited. Unsupported resources are not copied.</li><li> The downtime of a productive system would be quite huge because disk copy to a different region might take a whole day. If you just want to make a copy from production to a test system then downtime is very short: You just need to stop your productive servers for creating the disk snapshots.</li><li> Since it is a *copy* you might simply try RGCOPY. First of all, you should start RGCOPY with the parameter `simulate`. Hereby, you can detect possible issues: RGCOPY checks whether the used VM sizes are available in the target region and zone for your subscription. Furthermore, you can see whether the subscription quota (of VM families, total CPUs and disks) is sufficient. </li><li> You might use RGCOPY just for copying all disks (in parallel). For this, use the RGCOPY parameter `justCopyDisks`</li></ul> 

>:memo: **Note:** Be aware, that RGCOPY has been developed and is maintained by a single person. It is an open source tool, not an official Microsoft product. You can report bugs using GitHub Issues but you will not get help from Microsoft Product Support.

## Open Source version of RGCOPY
RGCOPY has been released as Open Source Software (OSS) in
- **https://github.com/Azure/RGCOPY**

The documentation of the OSS version is available here:

- **[https://github.com/Azure/RGCOPY/blob/main/rgcopy-docu.md](./rgcopy-docu.md)** 

There also exists a Microsoft internal version of RGCOPY with additional features. It is stored in a different repository. 

## YouTube training
You can watch an introduction to RGCOPY on YouTube (22:35):

[![RGCOPY](https://i.ytimg.com/vi/8pCN10CRXtY/hqdefault.jpg)](https://www.youtube.com/watch?v=8pCN10CRXtY)


## Trademarks
This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft 
trademarks or logos is subject to and must follow 
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.

