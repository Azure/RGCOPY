# RGCOPY
RGCOPY is a tool that copies the most important resources of an Azure resource group (**source RG**) to a new resource group (**target RG**). This tool has been developed for copying an SAP test landscape consisting of many servers within a single Azure resource group. RGCOPY is based on Azure Resource Manager (ARM).

The main features of RGCOPY are:
- RGCOPY is a PowerShell script which has been tested on **Windows** and **Linux**. It should run on **MacOS**, too.
- Copy between different Regions, Subscriptions and Tenants.
- Changing resource properties like VM size, disk SKU, disk performance tier, disk caching, Write Accelerator, Accelerated Networking, Availability Zone.
- Add, remove and change Proximity Placement Groups Availability Sets and Availability Zones.
- Support for the most important Azure resources (for SAP), like virtual machines, managed disks, NetApp volumes (on LINUX) and Load Balancers.
- Converting disks to NetApp volumes and vice versa (on LINUX).
- Converting Ultra SSD disks to Premium SSD disks and vice versa (on LINUX).
- Merging VMs from one resource group into another. Cloning a VM inside a resource group.
- VMs with just one data disk can be copied even while they are running.

!["RGCOPY"](/images/RGCOPY.png)

## Documentation

The documention for RGCOPY is  located in [rgcopy-docu.md](./rgcopy-docu.md)

## Contributing

This project welcomes contributions and suggestions.  Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.opensource.microsoft.com.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft 
trademarks or logos is subject to and must follow 
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.