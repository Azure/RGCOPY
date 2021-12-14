# Support

## Troubleshooting tips

#### Keep Software up-to-date
RGCOPY relies on several PowerShell modules. A malfunction of these modules might directly result in a failure of RGCOPY. Therefore, you should make sure that you always use the newest version of:

- PowerShell
- PowerShell modules **Az**, **Az.NetAppFiles** and **Az.HanaOnAzure**
- RGCOPY

#### Analyze deployment errors

The most important feature of RGCOPY is deploying an ARM template. This might fail for various reasons that are not under control of RGCOPY. For example, a specific VM size might not be available in the requested region and zone. In case of an error, check the following log files:

- **RGCOPY log file**<BR>All error messages and the call stack are displayed on the console and are written to the RGCOPY log file.
- **Activity log**<BR>This is available in Azure Portal for the resource group and for each resource.
- **Deployments log**<BR>This is available in Azure Portal for the resource group.

#### Analyze custom script errors

RGCOPY allows you running your own scripts inside the VMs. Failures of these scripts are not the responsibility of RGCOPY.
For running these scripts, RGCOPY uses the cmdlet `Invoke-AzVMRunCommand`. This cmdlet is communicating with the Azure Agent that is installed inside the VM. If this does not work reliably then you should **update the Azure Agent** (waagent) to the newest version. 
Any other software component inside the VM could also cause problems with  `Invoke-AzVMRunCommand`. To be on the save side, you should use an OS image from the Azure Marketplace rather than your own custom OS image.

#### Supported resources

Azure is permanently releasing new resource types and new features for existing resources. RGCOPY only supports a limited set of resource types. It is simply impossible to support all of them. In particular, RGCOPY does not support *classic* VMs. Some features (e.g. Network Peering) are only supported for very specific boundary conditions. Adding support for further resource types to RGCOPY might or might not happen in the future.
A new feature of a supported resource might cause issues with RGCOPY in the future. Therefore, you should always use the newest version of RGCOPY.


## How to file issues and get help  

This project uses GitHub Issues to track bugs and feature requests. Please search the existing 
issues before filing new issues to avoid duplicates. For new issues, file your bug or 
feature request as a new Issue. For better analysis, the RGCOPY zip file might be needed.

## Microsoft Support Policy  

Support for rgcopy.ps1 is limited to the resources listed above.
