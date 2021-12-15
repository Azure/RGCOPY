# RGCOPY
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

The full documention for RGCOPY is located in [rgcopy-docu.md](./rgcopy-docu.md)

!["RGCOPY"](/images/RGCOPY.png)

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft 
trademarks or logos is subject to and must follow 
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.