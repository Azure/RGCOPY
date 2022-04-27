# RGCOPY

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

The **[online documentation](./rgcopy-docu.md)** of RGCOPY is available using the following command:

```powershell
Get-Help .\rgcopy.ps1 -Online
```

An introduction to RGCOPY is available as a **[YouTube video](https://www.youtube.com/watch?v=8pCN10CRXtY)**.


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

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft 
trademarks or logos is subject to and must follow 
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.