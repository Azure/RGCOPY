## Version history
#### RGCOPY 0.9.26 December 2021 (first public release)
type|change
:---|:---
bug fix| error `Snapshot xxx not found. Remove parameter skipSnapshots`:<BR>add snapshots to white list

#### RGCOPY 0.9.28 January 2022
type|change
:---|:---
feature|Add new variables for scripts that were started from RGCOPY: <BR>`vmSize<vmName>`, `vmCpus<vmName>`, `vmMemGb<vmName>`
UI|Check that provided ARM template has been created by RGCOPY:<BR>change misleading error message `Invalid ARM template`
feature|Check status and version of VM Agent (parameter `vmAgentWaitMinutes`).<BR>Wait for VM Agent start rather than VM start before executing Invoke-AzVMRunCommand.
UI|In case of errors of `Invoke-AzVMRunCommand`: Display error message rather than throw exception
VS Code|Avoid VS Code warning: convert non-breaking spaces to spaces
VS Code|Avoid wrong VS Code warning: The variable 'hasIP' is assigned but never used.
bug fix|Error `Invalid data type, the rule is not a string` while parsing parameters:<BR>allow [char] in addition to [string]
etc|New function convertTo-array that ensures data type [array]
feature|Wait for VM services to be started (parameter `vmStartWaitSec`)
bug fix|RGCOPY VM tags for remotely running scripts not working<BR>(`rgcopy.ScriptStartSap`, `rgcopy.ScriptStartLoad`, `rgcopy.ScriptStartAnalysis`)

#### RGCOPY 0.9.30 February 2022
type|change
:---|:---
feature|**Update Mode**: New parameters `updateMode`, `skipUpdate`, `deleteSnapshotsAll`, `createBastion`, `deleteBastion`. By default, RGCOPY is running in Copy Mode. Once the Update Mode is enabled, you can use RGCOPY for changing resource properties in the source RG rather than copying a resource group.
feature|**Archive Mode**: New parameters `archiveMode`,`archiveContainer`, `archiveContainerOverwrite`. In Archive Mode, a backup of all disks to cost-effective BLOB storage is created in an storage account of the target RG. An ARM template that contains the resources of the source RG is also stored in the BLOB storage. In this mode, no other resource is deployed in the target RG.
feature|New parameter `justRedeployAms` for test purposes
feature|Checking that HyperV-generation, cpu architecture, and number of network interfaces is still supported when changing VM size.
bug fix|Variables for scripts `vmSize<vmName>`, `vmCpus<vmName>`, `vmMemGb<vmName>` did not work with special characters in VM names: Remove special characters from `<vmName>`
UI|Display explicitly all resource types that have *not* been copied by RGCOPY (because these types are not supported by RGCOPY)
UI|New section "Reading RGCOPY tags from VMs" to display Azure tags that impact RGCOPY behavior.
feature|Cost efficiency: New parameters `deleteSnapshots`, `deleteSourceSA`, `deleteTargetSA` for deleting unneeded resources in a cleanup step at the end of an RGCOPY run.
feature|New parameter `enableBootDiagnostics`, remove parameter ~~`skipBootDiagnostics`~~. Hereby, the storage account that is just used for storing the boot diagnostics is not needed by default.
feature|Only start *needed* (rather than all) VMs when copying NetApp volumes or Ultra SSD disks. Stop these VMs afterwards (rather than keep them running).
bug fix|Divide by zero error if a quota for a used VM family was explicitly set to 0 (rather than deleting the quota)
feature|Check version of VM Agent and wait until VM Agent is started (new parameter `vmAgentWaitMinutes`). 
feature|New parameter `stopVMsSourceRG`, `stopVMsTargetRG`. Remove parameters ~~`stopVMs`~~
feature|**Moving NetApp Volumes** in Update Mode: Hereby, the Service Level of the volumes can be changed. New parameters `netAppAccountName`, `netAppPoolName`, `netAppServiceLevel`, `netAppPoolGB`, `netAppMovePool`, `netAppMoveForce`, `smbTier`. Remove parameters ~~`capacityPoolGB`~~, ~~`smbTierStandard`~~
feature|Adding an explicitly maintained list of VM sizes with specific restrictions to Accelerated Networking ("Accelerated networking can only be applied to a single NIC for size ..."). These restrictions were not visible when just using Get-AzComputeResourceSku. Now, RGCOPY double checks these restrictions before trying to deploy the VMs/NICs.
feature|Create NetApp volumes without having a NetApp subnet in the source RG. New parameter `netAppSubnet`
feature|Renaming of remote NICs and VNETs. Hereby, you can copy a resource group that uses the same name for a local and a remote VNET (often the name of the vnet is simply 'vnet')
UI|Do not copy AMS by default. New parameter `createArmTemplateAms`.  Remove parameters ~~`skipAms`~~, ~~`skipDeploymentAms`~~<BR>Azure Monitor for SAP (AMS) is currently in public review with version v1. Version v2 will probably be in public review in 2022. RGCOPY only supports version v1. Once version v2 is available, copying AMS using RGCOPY might not work anymore.
bug fix| Consistency check for values of parameter setVmZone failed if using different zones for different VMs

#### RGCOPY 0.9.32 March 2022
type|change
:---|:---
feature| Display snapshot creation time for all RGCOPY-snapshots before deploying VMs
feature| Add wait time (parameter `vmStartWaitSec`) after Pre Snapshot Script (`pathPreSnapshotScript`)
feature| Support for disk bursting. New parameter `setDiskBursting`
feature| Support for zone redundant disks. New SKUs `Premium_ZRS`,`StandardSSD_ZRS`
feature| Support for shared disks. New parameter `setDiskMaxShares`
feature| New parameter `forceVmChecks`. Added explanation of parameter `skipVmChecks` to to documentation. Fixed exception that happened in combination with parameter `skipVmChecks`
bug fix| Fix exceptions when trying to copy an Ultra SSD disk
UI| New parameter `allowExistingDisks`. Remove parameters ~~`skipDiskChecks`~~ 
UI| New parameter `skipDefaultValues`. <BR>Remove default values for parameters `setPublicIpSku` and `setPublicIpAlloc`
UI| Increase minimum required Az version from 5.5 to 6.0 (needed for shared disks)
UI| New parameter `simulate` that works in all RGCOPY modes. Remove parameter ~~`skipUpdate`~~ that did only work in Update Mode

#### RGCOPY 0.9.34 April 2022
type|change
:---|:---
feature| Support for VM Scale Sets Flex. New parameters `skipVmssFlex`, `createVmssFlex`, and `setVmFaultDomain`.
feature| Since RGCOPY 0.9.30 Boot Diagnostics is not enabled by default. Hereby, a separate Storage Account is not needed by default in the target RG.<BR>By using the new Azure feature "Boot Diagnostics with managed storage account", we can now turn on Boot Diagnostics by default again. Therefore, the parameters changed again: New parameter `skipBootDiagnostics`, remove parameter ~~`enableBootDiagnostics`~~.
UI| Remove ARM template parameter ~~`storageAccountName`~~. It is not needed anymore for Boot Diagnostics.
feature| Allowing to run VM scripts on more than one VM. New syntax for scriptStartSapPath, scriptStartLoadPath and scriptStartAnalysisPath: `[local:]<path>@<VM>[,...n]`. Removing parameter ~~`scriptVm`~~ since it is not needed anymore. Remove the prefix ~~`command:`~~. Commands containing an @ now work even without the prefix.
UI|New parameter `preSnapshotWaitSec`
bug fix|Workaround for sporadic Azure issues when deploying subnets in parallel: create dependency chain in ARM template to prevent parallel deployment. Sporadic deployment error was: `Another operation on this or dependent resource is in progress`

#### RGCOPY 0.9.36 Mai 2022
type|change
:---|:---
feature| VNETs and NICs of other resource groups are also copied if they are referenced in the source RG. All other referenced remote resources cause an error in RGCOPY. When setting the new parameter `skipRemoteReferences`, these remote resources (for example a Network Security Group or an Availability Set) are simply ignored.
bug fix|Snapshot with a name longer than 80 characters caused an error. This has been fixed by truncating the name. Therefore, not *all* RGCOPY snapshots have now the extension `.rgcopy` anymore.
feature|When using the parameter `simulate`, several errors are just displayed. RGCOPY continues running but does not deploy anything. Hereby, you can see all errors in a single RGCOPY run, for example: skipped VM not found, number of NICs not supported for VM size, quota of VM size in region exceeded.
bug fix| Exceeded CPU quota not always detected by RGCOPY. Resulting CPU usage of 100.1% (that cannot be deployed) was rounded to 100% (that can be deployed). Everything greater than 100% is now rounded to 101%.
workflow| Revoking access from snapshots after BLOB copy. This was done in the past only when deleting snapshots (or automatically after 3 days)
feature| Creating a public IP address when merging a VM that originally had at least one public IP address
bug fix| Could not explicitly disable Disk Bursting, Write Accelerator, Accelerated Networking. Parameter value was always evaluated to True
UI|Improved consistency checks for parameters:<BR>- `skipVMs`, `skipDisks`, `skipSecurityRules`, `keepTags`: checking for (disallowed) data type: array of array of string<BR>- `archiveContainer`: checking for upper case characters.<BR>- `setAcceleratedNetworking`: checking that NIC is not connected to NetApp volume

#### RGCOPY 0.9.38 October 2022
type|change
:---|:---
bug fix| Regression when parameter `skipBastion` is used (one of 127 parameters): error during deployment "The resource 'Microsoft.Network/virtualNetworks/.../subnets/AzureBastionSubnet' is not defined in the template."
feature| New experimental parameters:<BR>`diagSettingsSA`, `diagSettingsContainer`, `diagSettingsPub`, `diagSettingsProt`
feature| New parameter switch `hostPlainText`<BR>Set this switch for getting better readable output when starting RGCOPY from a Linux script.
bug fix| Increased minimum required PowerShell version to 7.2 (required for $PsStyle)
feature| New parameter `justCopyDisks`
feature| Improved quota check
documentation|Clarification about moving customer SAP landscapes to a different region using RGCOPY.
bug fix| RGCOPY exports an ARM template from the source RG and modifies it.<BR>**The structure of this exported ARM template has changed:**. It now contains circular dependencies between:<UL><LI>vnets and their subnet</LI><LI>network security groups and their rules</LI><LI>NAT Gateways and their Public IP Prefixes</LI></UL>Therefore, a workaround had to be implemented in RGCOPY. All older versions of RGCOPY do not work anymore (at least in some regions).

