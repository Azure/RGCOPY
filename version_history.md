## Version history
#### RGCOPY 0.9.65 September 2024
type|change
:---|:---
feature|Support for IP tags.
feature|New value `false` for parameter `setVmZone` (and `setDiskSku`). When set, the existing zone of the VM (or SKU of the disk) is not changed by RGCOPY. 
experimental feature|Patching Windows VMs (not only Linux) in PATCH mode. Set RG owner in patch mode.
feature|Fix compatibility issue with Az version 13: Breaking change of Get-AzAccessToken.
feature|Allow BLOB copy for Microsoft internal version of RGCOPY (using storage account network rules and delegation keys).

#### RGCOPY 0.9.64 June 2024
type|change
:---|:---
feature|Make snapshot copy default when copying into a different region. Therefore, no storage account is needed anymore.
feature|Use variable wait times. Remove parameters `testDelayCreation` and `testDelayCopy`.
feature|Always SNAPSHOT copy rather than BLOB copy for disks larger than 4TiB
feature|Rename parameter `useBlobs` to `useBlobCopy`. Rename `skipBlobs` to `skipRemoteCopy`. Rename `restartBlobs` to `restartRemoteCopy`.
feature|New parameter `dualDeployment`. Without setting this parameter, a separate template for disk creation is never used.
bug fix|Always delete snapshots in target RG *before* deleting snapshots in source RG

#### RGCOPY 0.9.63 May 2024
type|change
:---|:---
feature|Never allow shared key access for storage accounts.<BR>You should use snapshot copy rather than BLOB copy if RGCOPY has only the `Subscription Contributor` role in the target subscription.
bug fix|Stop all VMs after creating snapshots once parameter `pathPreSnapshotScript` had been set.
feature|Change file copy for NetApp volumes: Use NFS with private endpoint rather than SMB with storage account keys. Remove parameter `smbTier`. New parameter `nfsQuotaGiB`

#### RGCOPY 0.9.62 April 2024
type|change
:---|:---
feature| Hardening storage accounts:<ul><li>Do not allow shared key access by default. Instead, RGCOPY is trying to assign the role `Storage Blob Data Owner` to the user or managed identity that is running RGCOPY. However, the RGCOPY user often has the `Subscription Contributor` role. This role is not sufficient to assign the `Storage Blob Data Owner` role. In this case, RGCOPY still uses shared key access for the lifetime of the storage account. This is more secure than expanding the privileges for all RGCOPY users.</li><li>Delete the storage account in target RG by default as soon as it is not needed anymore (at the end of RGCOPY)</li></ul>.

#### RGCOPY 0.9.61 April 2024
type|change
:---|:---
feature| Allow deploying a ZRS disk for a zonal VM.

#### RGCOPY 0.9.60 April 2024
type|change
:---|:---
feature| Copy user assigned managed identities by default. New parameter `skipIdentities`

#### RGCOPY 0.9.59 April 2024
type|change
:---|:---
feature| Using Get-AzAccessToken instead of .NET API AcquireAccessToken, as recommended by Azure DEV.
feature| Always install VM extensions `AzureMonitor*Agent`(except when parameter `skipExtensions` is set). Remove parameter `installExtensionsAzureMonitor`. New parameter `autoUpgradeExtensions`.

#### RGCOPY 0.9.58 March 2024
type|change
:---|:---
feature| Allow snapshot copy to a different subscription
feature| New parameter `skipWorkarounds`
experimental<BR>feature| New parameters `swapSnapshot4disk` and `swapDisk4disk`
bug fix| Fix a bug that was introduced in RGCOPY 0.9.55 that did not allow to deploy TiP sessions using BICEP
feature| New parameter `useNewVmSizes`

#### RGCOPY 0.9.57 February 2024
type|change
:---|:---
feature| Workarounds for open Azure issues.
feature| New parameters `useIncSnapshots`, `createDisksManually` and `useRestAPI`

#### Workarounds in RGCOPY for open Azure issues:
**1. BLOB COPY issue (Grant-AzSnapshotAccess)**
Grant-AzSnapshotAccess fails for disks with logical sector size 4096
https://github.com/Azure/azure-powershell/issues/24129
https://github.com/Azure/azure-cli/issues/28320
*-> use REST API rather than Grant-AzSnapshotAccess*

**2. SNAPSHOT COPY issue (New-AzSnapshot)**
security type trusted launch gets lost during snapshot copy
https://github.com/Azure/azure-powershell/issues/24242
https://github.com/Azure/azure-cli/issues/28457
*-> use REST API for snapshot copy when security type is set*

**3. disk creation issue (ARM template)**
security type trusted launch cannot be set when creating disks from BLOB in ARM template
https://github.com/Azure/azure-powershell/issues/24253
*-> create disks from BLOB outside ARM template (New-AzDisk)*

**4. disk creation issue (New-AzDisk)**
security type trusted launch cannot be set when creating disks from BLOB using New-AzDisk
https://github.com/Azure/azure-powershell/issues/24253
*-> use REST API for creating disk*

**5. disk creation issue (New-AzDisk)**
disk controller type NVMe cannot be set when creating disks from BLOB using New-AzDisk
https://github.com/Azure/azure-powershell/issues/24347
*-> use REST API for creating disk*

#### RGCOPY 0.9.56 January 2024
type|change
:---|:---
feature| Allow existing incremental snapshots. However, you must not create an additional incremental snapshot while RGCOPY is running. RGCOPY 0.9.56 always deletes copied incremental snapshots at the very end. This allows starting a new RGCOPY run with parameter `skipSnapshots` afterwards. 
feature| Remove check for trusted launch on premium V2 disks. This restriction has been removed by Azure as of January 2024.
feature|New syntax for `createVmssFlex`: <BR>- Allow using `1` instead of the synonym `none` for the fault domain count.<BR>- Allow `1` for zones. <BR>- Allow `none` for zones *and* `none` for fault domain count at the same time - although this is not a recommended configuration for SAP. We need this for testing non-SAP scenarios.
feature|Allow creating AvSets, PPGs and VMSS without members. Just do not add an `@<vm1>, ...` to the parameter.
experimental feature| New patch mode, that installs Linux updates.<BR>New parameters `patchMode`, `patchVMs`, `patchKernel`, `patchAll`, `prePatchCommand` and `skipStopVMsAfterPatching`
feature|Automatically remove Availability Zone if VM was not part of an AvSet but becomes part of a new AvSet by using parameter `createAvailabilitySet`
feature| Allow parameters `setDiskMBps` and `setDiskIOps` also for UltraSSD disks. However, parameter values are not checked for consistency.
feature| workaround for Azure bugs:<BR>- use snapshot copy rather than BLOB copy if disk sector size is 4096 <BR>- use BLOB copy rather than snapshot copy if OS disk is configured as Trusted Launch
feature| remove unneeded snapshot revoke for snapshot copy

#### RGCOPY 0.9.55 November 2023
type|change
:---|:---
bug fix|Allow copying load balancer with outbound rules
bug fix|Allow new line `\n` as part of a string in BICEP, e.g. in security rule description

#### RGCOPY 0.9.54 October 2023
type|change
:---|:---
feature|In `Archive` mode: Support for disk SKUs `PremiumV2_LRS` and `UltraSSD_LRS` . New parameter `pathArmTemplateDisks`.
feature|Changing data type of `justCopyDisks` to `array`. This allows defining discrete disks to be copied. 
feature|New parameter `defaultDiskZone` for detached disks or when parameter `justCopyDisks` was set
feature|New parameter `defaultDiskName`

#### RGCOPY 0.9.52 September 2023
type|change
:---|:---
feature|Using existing snapshots rather than blob copy even when copying to a different subscription (but only when using the same az-user for source RG and target RG).
feature|Default value of `Premium_LRS` is now only used when disk SKU in source RG is `Standard_LRS` or `StandardSSD_LRS`. Hereby, disk SKU `PremiumV2_LRS` will not be downgraded by chance when parameter `setDiskSku` was forgotten.

#### RGCOPY 0.9.51 September 2023
type|change
:---|:---
feature|Adding more log information when installing BICEP. The BICEP version used by RGCOPY is determined in the following order:<BR>1. If BICEP is installed (found in the path) then this version is used.<BR>2. If BICEP is not installed then RGCOPY downloads the newest version of BICEP from GitHub.<BR>3. If the download fails **on Linux** then RGCOPY is looking for the file `bicep` in the directory of the file `rgcopy.ps1` and is using this one. 

#### RGCOPY 0.9.50 September 2023
type|change
:---|:---
feature|Clone Mode: New parameters `cloneMode`, `cloneNumber`, `cloneVMs`, `attachVmssFlex`, `attachAvailabilitySet`, `attachProximityPlacementGroup`.
feature|Merge Mode: New parameter `mergeMode`.
feature|Support for disk SKU `PremiumV2_LRS` (except for Update Mode). New parameters `setDiskIOps`, `setDiskMBps`. 
feature|Converting disk SKU to `PremiumV2_LRS` and `UltraSSD_LRS` using Incremental Snapshots. Copying incremental snapshots within the same region.
feature|New parameter `ultraSSDEnabled`.
feature|Set default of parameter `useBicep` to `$True`.
feature|Automatically install BICEP tools if they are not available
feature|New parameter `useSnapshotCopy`, remove parameter `blobsfromdisk`
feature|Support for inbound Nat Rules/Pools in Load Balancers
feature|In Linux, it is sufficient to copy the file `bicep` into the same directory as `rgcopy.ps1` (rather than installing BICEP).

#### RGCOPY 0.9.48 July 2023
type|change
:---|:---
feature|Support for diskControllerType NVMe (for region westeurope)
feature|Using BICEP rather than ARM templates when parameter `useBicep` is set to `$True`

#### RGCOPY 0.9.46 July 2023
type|change
:---|:---
feature|New calculated parameter `vmType` for scripts that are started from RGCOPY. New VM tag `rgcopy.VmType`.
feature|New parameter `monitorRG`. New VM tag `rgcopy.MonitorRule`.
feature|Double check region of target resource group and of storage account if it already exists.
bug fix|Parameter `setVmMerge` did not work when specifying several VMs
bug fix|Support for public IP Addresses in NAT Gateways. When using publicIPAddresses rather than publicIPPrefixes in older versions of RGCOPY, the deployment failed with a Circular Dependency. 
feature|Double checking if new VM size supports trusted launch (if set in the source RG)
feature|Double checking if new VM size supports the disk controller type (of the source RG)
feature|Double checking if all disks are in the same resource group as the VMs

#### RGCOPY 0.9.44 March 2023
type|change
:---|:---
bug fix| Fix ARM deployment error under the following conditions:<BR>1. The source resource group contains a VM that is connected to a vNet in a different resource group<BR>2. This vNet uses Network Peering to another vNet<BR>Network Peering and all its dependencies are now fully removed from the ARM template. This is possible because Network Peering has only been supported for AMS v1 and support for AMS v1 has been removed in RGCOPY 0.9.40.

#### RGCOPY 0.9.42 December 2022
type|change
:---|:---
bug fix| regression in RGCOPY 0.9.40 resulted in deployment errors when copying to a different region

#### RGCOPY 0.9.40 December 2022
type|change
:---|:---
warning|**Always install the newest version of PowerShell *and* az-cmdlets!** <BR>When installing the newest PowerShell (7.3.0) with older az-cmdlets then RGCOPY might terminate with the following error:<BR>`GenericArguments[0], 'Microsoft.Azure.Management.Compute.Models.VirtualMachine', on 'T MaxInteger[T](System.Collections.Generic.IEnumerable1[T])' violates the constraint of type 'T'.`<BR>If you install the newest az version 9.1.1 then RGCOPY works fine even with the newest PowerShell version 7.3.0
UI| Removed support for AMS v1 as announced in February 2022.<BR>Remove parameters `pathArmTemplateAms`, `createArmTemplateAms`, `amsInstanceName`, `amsWsName`, `amsWsRG`, `amsWsKeep`, `amsShareAnalytics`, `dbPassword`, `amsUsePowerShell` and `justRedeployAms`.
UI | Added a warning that ProximityPlacementGroups, AvailabilitySets and VmssFlex are removed if VM Tag `rgcopy.TipGroup` was used.
workaround for Azure changes|**The behavior of VMSS Flex has changed for Fault Domain Count FD>1:**<BR>The **current** behavior is the following: <ul><li>For M-Series VMs:<BR>You must not set the fault domain for the VM. If you do so, RGCOPY gives a warning: use parameter 'setVmFaultDomain' for setting fault domain to 'none'.<BR>Hereby, a VMSS Flex with FD>1 that contains M-series VMs behaves like an Availability Set.</li><li>For non M-Series VMs:<BR>You must now set the VMSS Flex property  `singlePlacementGroup` = `False`.<BR>This is done now automatically by RGCOPY. However, you can use RGCOPY parameter `singlePlacementGroup` for changing this (once the VMSS Flex behavior changes in the future).</li><li>Mixing M-Series VMs with other VMs is not allowed inside a VMSS Flex<BR>In this case, RGCOPY gives a warning.</li></ul>In older versions of RGCOPY you might get the deployment error:<BR>`Cannot set 'platformFaultDomain' on Virtual Machine 'hana2' because the Virtual Machine Scale Set 'vmss' that it references has 'singlePlacementGroup' = true. (Code:BadRequest)`
 workaround for Azure changes| **The semantic of zone definition for Public IP Addresses has changed (see below):**<BR>As a workaround, RGCOPY now always sets SKU = `Standard` and IPAllocationMethod = `Static` for Public IP Addresses. Parameters `setPublicIpSku` and `setPublicIpAlloc` have been removed.<BR>In older versions of RGCOPY you will see the following error when deploying a VM with a public IP address to an Availability Zone:<BR>`Compute resource /subscriptions/.../virtualMachines/... has a zone constraint 3 but the PublicIPAddress /subscriptions/... used by the compute resource via NetworkInterface or LoadBalancer has a different zone constraint Regional. (Code: ComputeResourceZoneConstraintDoesNotMatchPublicIPAddressZoneConstraint)`
  UI| RGCOPY now always sets SKU = `Standard` for Load Balancers. Parameter `setLoadBalancerSku` has been removed.

 Semantic changes of zone definition for Public IP Addresses:
```
WARNING: Upcoming breaking changes in the cmdlet ‘New-AzPublicIpAddress’ :
Default behavior of Zone will be changed
Cmdlet invocation changes :
 Old Way : Sku = Standard means the Standard Public IP is zone-redundant.
 New Way : Sku = Standard and Zone = {} means the Standard Public IP has no zones. 
 If you want to create a zone-redundant Public IP address, please specify 
 all the zones in the region. For example, Zone = [‘1’, ‘2’, ‘3’]. 
 ```

#### RGCOPY 0.9.38 October 2022
type|change
:---|:---
bug fix| Regression when parameter `skipBastion` is used (one of 127 parameters): error during deployment "The resource 'Microsoft.Network/virtualNetworks/.../subnets/AzureBastionSubnet' is not defined in the template."
feature| New experimental parameters:<BR>`diagSettingsSA`, `diagSettingsContainer`, `diagSettingsPub`, `diagSettingsProt`
feature| New parameter switch `hostPlainText`<BR>Set this switch for getting better readable output when starting RGCOPY from a Linux script.
UI| Increased minimum required PowerShell version to 7.2 (required for $PsStyle)
feature| New parameter `justCopyDisks`
feature| Improved quota check
documentation|Clarification about moving customer SAP landscapes to a different region using RGCOPY.
workaround for Azure changes| RGCOPY exports an ARM template from the source RG and modifies it.<BR>**The structure of this exported ARM template has changed:**. It now contains `circular dependencies` between:<UL><LI>vnets and their subnet</LI><LI>network security groups and their rules</LI><LI>NAT Gateways and their Public IP Prefixes</LI></UL>Therefore, a workaround had to be implemented in RGCOPY. All older versions of RGCOPY do not work anymore.

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

#### RGCOPY 0.9.34 April 2022
type|change
:---|:---
feature| Support for VM Scale Sets Flex. New parameters `skipVmssFlex`, `createVmssFlex`, and `setVmFaultDomain`.
feature| Since RGCOPY 0.9.30 Boot Diagnostics is not enabled by default. Hereby, a separate Storage Account is not needed by default in the target RG.<BR>By using the new Azure feature "Boot Diagnostics with managed storage account", we can now turn on Boot Diagnostics by default again. Therefore, the parameters changed again: New parameter `skipBootDiagnostics`, remove parameter ~~`enableBootDiagnostics`~~.
UI| Remove ARM template parameter ~~`storageAccountName`~~. It is not needed anymore for Boot Diagnostics.
feature| Allowing to run VM scripts on more than one VM. New syntax for scriptStartSapPath, scriptStartLoadPath and scriptStartAnalysisPath: `[local:]<path>@<VM>[,...n]`. Removing parameter ~~`scriptVm`~~ since it is not needed anymore. Remove the prefix ~~`command:`~~. Commands containing an @ now work even without the prefix.
UI|New parameter `preSnapshotWaitSec`
workaround for Azure changes|Workaround for sporadic Azure issues when deploying subnets in parallel: create dependency chain in ARM template to prevent parallel deployment. Sporadic deployment error was: `Another operation on this or dependent resource is in progress`

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

#### RGCOPY 0.9.26 December 2021 (first public release)
type|change
:---|:---
bug fix| error `Snapshot xxx not found. Remove parameter skipSnapshots`:<BR>add snapshots to white list
