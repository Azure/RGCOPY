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

#### RGCOPY 0.9.30 March 2022
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
bug fix|Divide by zero error if a quota for a used VM family does exists but the quota is 0
feature|Check version of VM Agent and wait until VM Agent is started (new parameter `vmAgentWaitMinutes`). 
feature|New parameter `stopVMsSourceRG`, `stopVMsTargetRG`. Remove parameters ~~`stopVMs`~~
feature|**Moving NetApp Volumes** in Update Mode: Hereby, the Service Level of the volumes can be changed. New parameters `netAppAccountName`, `netAppPoolName`, `netAppServiceLevel`, `netAppPoolGB`, `netAppMovePool`, `netAppMoveForce`, `smbTier`. Remove parameters ~~`capacityPoolGB`~~, ~~`smbTierStandard`~~
feature|Adding an explicitly maintained list of VM sizes with specific restrictions to Accelerated Networking ("Accelerated networking can only be applied to a single NIC for size ..."). These restrictions were not visible when just using Get-AzComputeResourceSku. Now, RGCOPY double checks these restrictions before trying to deploy the VMs/NICs.
feature|Create NetApp volumes without having a NetApp subnet in the source RG. New parameter `netAppSubnet`
feature|Renaming of remote NICs and VNETs. Hereby, you can copy a resource group that uses the same name for a local and a remote VNET (often the name of the vnet is simply 'vnet')
UI|Do not copy AMS by default. New parameter `createArmTemplateAms`.  Remove parameters ~~`skipAms`~~, ~~`skipDeploymentAms`~~<BR>Azure Monitor for SAP (AMS) is currently in public review with version v1. Version v2 will probably be in public review in 2022. RGCOPY only supports version v1. Once version v2 is available, copying AMS using RGCOPY might not work anymore.






