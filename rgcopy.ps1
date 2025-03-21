<#
rgcopy.ps1:       Copy Azure Resource Group
version:          0.9.68
version date:     March 2025
Author:           Martin Merdes
Public Github:    https://github.com/Azure/RGCOPY

//
// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.
//

#>
#Requires -Version 7.2 -Modules 'Az.Accounts', 'Az.Compute', 'Az.Storage', 'Az.Network', 'Az.Resources'

# by default, Parameter Set 'dualRG' is used
[CmdletBinding(	DefaultParameterSetName='dualRG',
				HelpURI="https://github.com/Azure/RGCOPY/blob/main/rgcopy-docu.md")]
param (
	#--------------------------------------------------------------
	# essential parameters
	#--------------------------------------------------------------
	# parameter is always mandatory
	 [Parameter(Mandatory=$True)]
	 [string] $sourceRG										# Source Resource Group

	# parameter is mandatory, dependent on used Parameter Set
	,[Parameter(Mandatory=$False,ParameterSetName='singleRG')]
	 [Parameter(Mandatory=$True, ParameterSetName='dualRG')]
	 [string] $targetRG										# Target Resource Group (will be created)
	,[switch] $allowExistingDisks							# do not check whether the targetRG already contains disks

	# parameter is mandatory, dependent on used Parameter Set
	,[Parameter(Mandatory=$False,ParameterSetName='singleRG')]
	 [Parameter(Mandatory=$True, ParameterSetName='dualRG')]
	 [string] $targetLocation								# Target Region

	# storage account
	,[string] $targetSA										# only needed if calculated name is not unique in subscription (= ANF account name)
	,[string] $sourceSA										# only needed if calculated name is not unique in subscription

	# subscriptions and User
	,[string] $sourceSub									# Source Subscription display name
	,[string] $sourceSubUser								#    User Name
	,[string] $sourceSubTenant								#    Tenant Name (optional)
	,[string] $targetSub									# Target Subscription display name
	,[string] $targetSubUser								#    User Name
	,[string] $targetSubTenant								#    Tenant Name (optional)

	#--------------------------------------------------------------
	# parameters for Copy Mode
	#--------------------------------------------------------------
	# operation switches
	,[switch] $skipArmTemplate								# skip ARM template creation
	,[switch] $skipSnapshots								# skip snapshot creation of disks and volumes (in sourceRG)
	,[switch]   $stopVMsSourceRG 							# stop VMs in the source RG before creating snapshots
	,[switch] $skipBackups									# skip backup of files (in sourceRG)
	,[switch] $skipDeployment								# skip deployment (in targetRG)
	,[switch]   $skipDeploymentVMs							# skip part step: deploy Virtual Machines
	,[switch]   $skipRestore								# skip part step: restore files
	,[switch]      $stopRestore								# run all steps until (excluding) Restore
	,[switch]      $continueRestore							# run Restore and all later steps
	,[switch] $startWorkload								# start workload
	,[switch] $stopVMsTargetRG 								# stop VMs in the target RG after deployment
	,[switch] $deleteSnapshots								# delete snapshots after deployment
	,[switch] $deleteSourceSA								# delete storage account in the source RG after deployment
	,[switch] $deleteTargetSA								# delete storage account in the target RG after deployment
	# simulating
	,[switch] $simulate										# just create ARM template

	# VM extensions
	,[switch] $skipExtensions								# do not install VM extensions
	,[switch] $autoUpgradeExtensions						# auto upgrade VM extensions
	,$installExtensionsSapMonitor	= @()					# Array of VMs where SAP extension should be installed
	,[string] $diagSettingsPub	= 'PublicSettings.json'
	,[string] $diagSettingsProt	= 'ProtectedSettings.json'
	,[string] $diagSettingsContainer
	,[string] $diagSettingsSA

	# disk creation options
	,[switch] $createDisksManually
	,[switch] $dualDeployment
	,[switch] $skipWorkarounds
	,[switch] $useIncSnapshots								# always use INCREMENTAL rather than FULL snapshots (even in same region and for standard disks)
	,[switch] $useRestAPI									# always use REST API rather than az-cmdlets when possible

	,[switch] $useSnapshotCopy								# always use SNAPSHOT copy (even in same region)
	,[switch] $useBlobCopy									# always use BLOB copy (even in same region)
	,[switch] $skipRemoteCopy								# skip BLOB/snapshot creation (in targetRG)
	,[switch] $restartRemoteCopy							# restart a failed BLOB Copy

	,[string] $blobsSA										# Storage Account of BLOBs
	,[string] $blobsRG										# Resource Group of BLOBs
	,[string] $blobsSaContainer								# Container of BLOBs

	# parameters for cleaning an incomplete RGCOPY run
	,[array]  $justCopyBlobs 				# only copy these disks to BLOBs (from existing snapshots)
	,[array]  $justCopySnapshots 			# only copy these disks to SNAPSHOTs (from existing snapshots)
	,[array]  $justCopyDisks				# only copy these disks (by creating snapshots and disks)
	,[switch] $justStopCopyBlobs

	#--------------------------------------------------------------
	# parameters for Archive Mode
	#--------------------------------------------------------------
	,[switch] $archiveMode									# create backup of source RG to BLOB, no deployment
	,[string] $archiveContainer								# container in storage account that is used for backups
	,[switch] $archiveContainerOverwrite					# allow overwriting existing archive container

	#--------------------------------------------------------------
	# parameters for Clone Mode
	#--------------------------------------------------------------
	# use Parameter Set singleRG when switch cloneMode is set
	,[Parameter(ParameterSetName='singleRG')]
	 [switch] $cloneMode
	,[int] $cloneNumber = 1
	,$cloneVMs						= @()
	,$attachVmssFlex 				= @()
	,$attachAvailabilitySet 		= @()
	,$attachProximityPlacementGroup	= @()
	# ,$setVmZone					= @()
	# ,$setVmFaultDomain 			= @()
	# ,$setVmName 					= @()
	# ,[switch] $renameDisks	# rename all disks using their VM name

	#--------------------------------------------------------------
	# parameters for Merge Mode
	#--------------------------------------------------------------
	,[Parameter(ParameterSetName='singleRG')]
	 [switch] $mergeMode
	,$setVmMerge = @()
	# usage: $setVmMerge = @("$net/$subnet@$vm1,$vm2,...", ...)
	#	with $net as virtual network name, $subnet as subnet name in target resource group
	# 	merge VM jumpbox into target RG:					@("vnet/default@jumpbox")
	# ,$attachVmssFlex	= @()								# parameter also available in Clone Mode, see above
	# ,$attachAvailabilitySet = @()							# parameter also available in Clone Mode, see above
	# ,$attachProximityPlacementGroup = @()					# parameter also available in Clone Mode, see above
	# ,$setVmZone					= @()
	# ,$setVmFaultDomain 			= @()
	# ,$setVmName 					= @()

	#--------------------------------------------------------------
	# parameters for Update Mode
	#--------------------------------------------------------------
	# use Parameter Set singleRG when switch updateMode is set
	,[Parameter(ParameterSetName='singleRG')]
	 [switch] $updateMode									# change properties in source RG
	# ,[switch] $simulate									# just simulate Updates
	# ,[switch] $stopVMsSourceRG 							# parameter also available in Copy Mode, see above
	# ,$setVmSize = @()										# parameter also available in Copy Mode, see below
	# ,$setDiskSize = @()									# parameter also available in Copy Mode, see below
	# ,$setDiskTier = @()									# parameter also available in Copy Mode, see below
	# ,$setDiskBursting = @()								# parameter also available in Copy Mode, see below
	# ,$setDiskMaxShares= @()								# parameter also available in Copy Mode, see below
	# ,$setDiskCaching = @()								# parameter also available in Copy Mode, see below
	# ,$setDiskSku = @()									# parameter also available in Copy Mode, see below
	# ,$setAcceleratedNetworking = @()						# parameter also available in Copy Mode, see below
	# ,[switch] $deleteSnapshots							# parameter also available in Copy Mode, see below
	,[switch] $deleteSnapshotsAll							# delete all snapshots
	,[string] $createBastion								# create bastion. Parameter format: <addressPrefix>@<vnet>
	,[switch] $deleteBastion								# delete bastion

	#--------------------------------------------------------------
	# parameters for Patch Mode
	#--------------------------------------------------------------
	# use Parameter Set singleRG when switch patchMode is set
	,[Parameter(ParameterSetName='singleRG')]
	 [switch] $patchMode									# apply Linux patches
	,$patchVMs					= '*'
	# ,$skipVMs 				= @()
	,[switch] $patchKernel			# install newest Linux kernel (and security patches)
	,[switch] $patchAll				# install ALL patches on VM (not only security patches)
	,[string] $prePatchCommand		# e.g. 'yum-config-manager --save --setopt=rhui-rhel-7-server-dotnet-rhui-rpms.skip_if_unavailable=true 1>/dev/null'
	,[switch] $skipPatch
	,[switch] $forceExtensions
	# ,[switch] $autoUpgradeExtensions
	# ,[switch] $stopVMsSourceRG
	,$defaultTags = @{}

	#--------------------------------------------------------------
	# file locations
	#--------------------------------------------------------------
	,[string] $pathArmTemplate								# given ARM template file
	,[string] $pathArmTemplateDisks							# given ARM template file for Disk creation
	,[string] $pathExportFolder	 = '~'						# default folder for all output files (log-, config-, ARM template-files)
	,[string] $pathPreSnapshotScript						# running before ARM template creation on sourceRG (after starting VMs and SAP)
	,[string] $pathPostDeploymentScript						# running after deployment on targetRG

	# script location of shell scripts inside the VM
	,[string] $scriptStartSapPath							# if not set, then calculated from vm tag rgcopy.ScriptStartSap
	,[string] $scriptStartLoadPath							# if not set, then calculated from vm tag rgcopy.ScriptStartLoad
	,[string] $scriptStartAnalysisPath						# if not set, then calculated from vm tag rgcopy.ScriptAnalyzeLoad

	#--------------------------------------------------------------
	# Azure NetApp Files
	#--------------------------------------------------------------
	,[string] $netAppServiceLevel	= 'Premium'				# Service Level for NetApp Capacity Pool: 'Standard', 'Premium', 'Ultra'
	,[string] $netAppAccountName							# in Copy Mode: Name of new Account
	,[string] $netAppPoolName								# in Copy Mode: Name of new Pool
	,[int]    $netAppPoolGB 		= 4 * 1024				# in Copy Mode: Size of new Pool in GB
	,[string] $netAppMovePool								# in Update Mode: Only move this pool: <account>/<pool>
	,[switch] $netAppMoveForce								# in Update Mode: Always move pools, even when Service Level is identical
	,[string] $netAppSubnet									# new Subnet for NetApp Parameter format: <addressPrefix>@<vnet>
	,[switch] $verboseLog									# detailed output for converting NetApp or disks
	,[string] $createDisksTier		= 'P20'					# minimum disk tier (in target RG) for converting NetApp or disks
	,[int]    $nfsQuotaGiB 			= 5120					# Quota for Azure NFS share (not NetApp!) 
	
	#--------------------------------------------------------------
	# default values
	#--------------------------------------------------------------	
	,[int] $grantTokenTimeSec		= 3 * 24 * 60 * 60		# grant access to source disks for 3 days
	,[int] $vmStartWaitSec			= 5 * 60				# wait time after VM start before using the VMs (before trying to run any script)
	,[int] $preSnapshotWaitSec		= 5 * 60				# wait time after running pre-snapshot script
	,[int] $vmAgentWaitMinutes		= 30					# maximum wait time until VM Agent is ready
	,[int] $snapshotWaitCreationMinutes		= 24 * 60
	,[int] $snapshotWaitCopyMinutes			= 3 * 24 * 60
	,[int] $maxDOP					= 16 					# max degree of parallelism for FOREACH-OBJECT
	,[string] $setOwner 			= '*'					# Owner-Tag of Resource Group; default: $targetSubUser
	,[string] $jumpboxName			= ''					# create FQDN for public IP of jumpbox
	,[switch] $ignoreTags									# ignore rgcopy*-tags for target RG CONFIGURATION
	,[switch] $copyDetachedDisks							# copy disks that are not attached to any VM

	#--------------------------------------------------------------
	# skip resources from sourceRG
	#--------------------------------------------------------------
	,$skipVMs 				= @()							# Names of VMs that will not be copied
	,$skipDisks				= @()							# Names of DATA disks that will not be copied
	,$skipSecurityRules		= @('SecurityCenter-JITRule*')	# Name patterns of rules that will not be copied
	,$keepTags				= @('rgcopy*')					# Name patterns of tags that will be copied, all others will not be copied
	,[switch] $skipVmssFlex									# do not copy VM Scale Sets Flexible
	,[switch] $skipAvailabilitySet							# do not copy Availability Sets
	,[switch] $skipProximityPlacementGroup					# do not copy Proximity Placement Groups
	,[switch] $skipBastion									# do not copy Bastion
	,[switch] $skipBootDiagnostics							# do not create Boot Diagnostics (managed storage account)
	,[switch] $skipIdentities								# do not copy user assigned identities
	,[switch] $skipNatGateway

	#--------------------------------------------------------------
	# resource configuration parameters
	#--------------------------------------------------------------
	,[switch] $skipVmChecks									# do not double check whether VMs can be deployed in target region
	,[switch] $forceVmChecks								# Do not automatically change resource properties to valid values
	,[switch] $skipRemoteReferences
	,[switch] $skipDefaultValues							# Do not use resource configuration Default Values in COPY MODE
	
	<#  parameter for changing multiple resources:
			[array] $parameter = @($rule1,$rule2, ...)
				with [string] $rule = "$configuration@$resourceName1,$resourceName2, ..."
				with [string] $configuration = "$config1/$config2"
			see examples for $setVmSize below
	#>

	,$setVmSize	= @()
	# usage: $setVmSize = @("$size@$vm1,$vm2,...", ...)
	# set size for single VM:							@("Standard_E32s_v3@hana1")
	# set size for ALL VMs:								@("Standard_E32s_v3")
	# set same size for 2 VMs (1 rule):					@("Standard_E32s_v3@hana1,hana2")
	# set size for 2 VMs separately (2 rules):			@("Standard_E32s_v3@hana1", "Standard_E16s_v3@hana2")
	# set 16 CPUs for single VM and 32 for others:		@("Standard_E16s_v3@hana2", "Standard_E32s_v3")
	# 	(first rule wins)

	,$setDiskSize = @()
	# usage: $setDiskSize = @("$size@$disk1,$disk1,...", ...) with $size in GB
	# set size of single disk to 1024 GB:				@("1024/hana1data1")

	,$setDiskTier = @()
	# usage: $setDiskTier = @("$tier@$disk1,$disk1,...", ...) 
	#  with $tier -in ('P1', 'P2', ...)    P0 for remove tier
	# set tier of single disk to P40:					@("P40/hana1data1")

	,$setDiskBursting = @()
	# usage: $setDiskBursting = @("$bursting@$disk1,$disk1...", ...)
	#  with $bursting -in ('True','False')

	,$setDiskIOps = @()
	,$setDiskMBps = @()

	,$setDiskMaxShares= @()
	# usage: $setDiskMaxShares = @("$maxShares@$disk1,$disk1...", ...)
	#  with $maxShares -in (1,2,3,...)

	,$setDiskCaching = @()
	# usage: $setDiskCaching = @("$caching/$writeAccelerator@$disk1,$disk1...", ...)
	#  with $caching -in @('ReadOnly','ReadWrite','None')
	#        $writeAccelerator -in ('True','False')
	# turn off writeAccelerator for all disks:			@("/False")
	# turn off all caches for all disks:				@("None/False")
	# set caching for 2 disks:							@("ReadOnly/True@hana1data1", "None/False@hana1os",)
	# turn on WA for one disk and off for all others: 	@("ReadOnly/True@hana1data1", "None/False")

	,$setDiskSku = 'Premium_LRS'				# default value in COPY MODE
	# usage: $setDiskSku = @("$sku@$disk1,$disk1,...", ...)
	#  with $sku -in ('Premium_LRS','StandardSSD_LRS','Standard_LRS','Premium_ZRS','StandardSSD_ZRS')

	,$setVmZone	= 0								# default value in COPY MODE
	# usage: $setVmZone = @("$zone@$vm1,$vm2,...", ...)
	#  with $zone in {none,1,2,3}
	# remove zone from all VMs							'0' or 'none'
	# set zone 1 for 2 VMs (hana 1 and hana2)			@("1@hana1,hana2")

	,$setVmFaultDomain = @()
	# usage: $setVmFaultDomain = @("$fault@$vm1,$vm2,...", ...)
	#  with $fault in {none,0,1,2}
	#  'none' means: remove Fault Domain configuration from the VM

	,$createVmssFlex = @()
	# usage: $createVmssFlex = @("$vmss/$fault$/$zones@$vm1,$vm2,...", ...)
	#	with $vmss:  name of VM Scale Set Flexible
	#        $zones: Allowed Zones in {none, 1, 2, 3, 1+2, 1+3, 2+3, 1+2+3}
	#        $fault: Fault domain count in in {none, 1, 2, 3, max}
	,$singlePlacementGroup # in {Null, True, False}

	,$createAvailabilitySet = @()
	# usage: $createAvailabilitySet = @("$avSet/$fd/$ud$@$vm1,$vm2,...", ...)
	#	with $avSet: name of AvailabilitySet
	#        $fd:    faultDomainCount
	#        $ud:    updateDomainCount
	# create AvSet with name 'asname' for 2 VMs (hana 1 and hana2):	@("asname/2/5@hana1,hana2")
	# see also parameter $skipAvailabilitySet

	,$createProximityPlacementGroup = @()
	# usage: $createProximityPlacementGroup = @("$ppg@$vm1,$vm2,...", ...)
	#	with $ppg: [string]
	# 	$vm: ether name of VM or name of AvSet
	# sets ppg with name 'ppgname' for 2 VMs (hana 1 and hana2):	@("ppgname@hana1,hana2")
	# creates Proximity Placement Group 'ppgname'
	# see also parameter $skipProximityPlacementGroup

	,$createVolumes	= @()
	# defines NetApp volumes for the target RG
	# usage: $createVolumes = @("$size@$mp1,$mp2,...", ...)
	#	with $size: volume size in GB (>= 100)
	#	with $mp = $vmName/$pathToMountPoint

	,$createDisks	= @()
	# defines additional disks for the target RG
	# usage: $createDisks = @("$size@$mp1,$mp2,...", ...)
	#	with $size: disk size in GB (>= 1)
	#	with $mp = $vmName/$pathToMountPoint

	,$snapshotVolumes	= @()
	# creates NetApp volume snapshots in the source RG
	# usage: $snapshotVolumes = @("$rg/$account/$pool@$vol1,$vol2,...", ...)
	# or:    $snapshotVolumes = @("$account/$pool@$vol1,$vol2,...", ...)
	#	with $rg:      resource group name (default: $sourceRG) of NetApp account
	#	with $account: NetApp account name
	#	with $pool:    NetApp pool name
	#	with $vol:     NetApp volume name

	,$setVmDeploymentOrder	= @()
	# deploy (start) VMs in specific order
	# usage: $setVmDeploymentOrder = @("$prio@$vm1,$vm2,...", ...)
	#	with $prio -in (1,2,3,...)
	# example with multiple priorities:					@("1@AdVM", "2@iscsi", "3@sofs1,sofs2", "4@hana1,hana2")

	,$setPrivateIpAlloc	= 'Static'					# default value in COPY MODE
	# usage: $setPrivateIpAlloc = @("$allocation@$ipName1,$ipName12,...", ...)
	#	with $allocation -in @('Dynamic', 'Static')

	,$removeFQDN = $True							# this default value is ALWAYS used
	# removes Full Qualified Domain Name from public IP address
	# usage: $removeFQDN = @("bool@$ipName1,$ipName12,...", ...)
	#	with $bool -in @('True')

	,$setAcceleratedNetworking = $True				# default value in COPY MODE
	# usage: $setAcceleratedNetworking = @("$bool@$nic1,$nic2,...", ...)
	#	with $bool -in @('True', 'False')

	,$setVmName = @()
	# renames VM resource name (not name on OS level)
	# usage: $setVmName = @("$vmNameNew@$vmNameOld", ...)
	# set VM name dbserver for VM hana (=rename hana)	@("dbserver@hana")

	,$swapSnapshot4disk = @()
	,$swapDisk4disk = @()

	,[switch] $renameDisks	# rename all disks using their VM name

	#--------------------------------------------------------------
	# other parameter
	#--------------------------------------------------------------
	,[switch] $ultraSSDEnabled # create VM with property ultraSSDEnabled even when not needed
	,[boolean] $useBicep	= $True
	# use Parameter Set singleRG when switch justCreateSnapshots is set
	,[Parameter(ParameterSetName='singleRG')]
	[switch] $justCreateSnapshots
	# use Parameter Set singleRG when switch justDeleteSnapshots is set
	,[Parameter(ParameterSetName='singleRG')]
	[switch] $justDeleteSnapshots
	,$defaultDiskZone
	,$defaultDiskName

	#--------------------------------------------------------------
	# experimental parameters: DO NOT USE!
	#--------------------------------------------------------------
	,[string] $monitorRG
	,$setVmTipGroup			= @()
	,$setGroupTipSession	= @()
	,[string] $setIpTag
	,[string] $setIpTagType	= 'FirstPartyUsage'
	,[switch] $allowRunningVMs
	,[switch] $skipGreenlist
	,[switch] $skipStartSAP
	,$generalizedVMs		= @()
	,$generalizedUser		= @()
	,$generalizedPasswd		= @() # will be checked below for data type [SecureString] or [SecureString[]]
	,[switch] $hostPlainText
	,[switch] $updateBicep
	,[switch] $useNewVmSizes

	# not used anymore
	,[int] $waitBlobsTimeSec = 5 * 60
)

#--------------------------------------------------------------
# For debugging, you need $ErrorActionPreference = 'Continue'
# Therefore, use:
# 
# set-Item 'Env:\ErrorActionPreference' 'Continue'
#
# For normal use, you need $ErrorActionPreference = 'Stop'
# Hereby, any exception can be caugth by RGCOPY
#--------------------------------------------------------------
$pref = (get-Item 'Env:\ErrorActionPreference' -ErrorAction 'SilentlyContinue').value
if ($Null -ne $pref )	{ $ErrorActionPreference = $pref }
else					{ $ErrorActionPreference = 'Stop' }

$boundParameterNames = $PSBoundParameters.keys

# general parameters
$configParameters = @(
	'snapshotVolumes'
	'createVolumes'
	'createDisks'
	'setVmDeploymentOrder'
	'setVmTipGroup'
	'setVmName'
	'swapSnapshot4disk'
	'swapDisk4disk'
	'setVmMerge'
	'cloneVMs'
	'setVmSize'
	'setVmZone'
	'setDiskSku'
	'setDiskSize'
	'setDiskMaxShares'
	'setDiskTier'
	'setDiskBursting'
	'setDiskIOps'
	'setDiskMBps'
	'setDiskCaching'
	'setAcceleratedNetworking'
	'setPrivateIpAlloc'
	'removeFQDN'
	'createProximityPlacementGroup'
	'createAvailabilitySet'
	'setGroupTipSession'
	'setVmFaultDomain'
	'createVmssFlex'
	'attachVmssFlex'
	'attachAvailabilitySet'
	'attachProximityPlacementGroup'
)

$workflowParameters = @(
	'cloneMode'
	'updateMode'
	'archiveMode'
	'mergeMode'
	'patchMode'
	'skipArmTemplate'
	'skipSnapshots'
	'stopVMsSourceRG'
	'skipBackups'
	'skipRemoteCopy'
	'skipDeployment'
	'skipDeploymentVMs'
	'skipRestore'
	'stopRestore'
	'continueRestore'
	'skipExtensions'
	'startWorkload'
	'stopVMsTargetRG'
	'deleteSnapshots'
	'deleteSourceSA'
	'simulate'
	'restartRemoteCopy'
	'justCopyBlobs'
	'justCopySnapshots'
	'justCopyDisks'
	'justStopCopyBlobs'
	'justCreateSnapshots'
	'justDeleteSnapshots'
	'skipStartSAP'
)

$program = 'RGCOPY'
$suppliedModes = @()
$cloneOrMergeMode = $False

# Clone Mode
if ($cloneMode) {
	$suppliedModes 		+= 'cloneMode'
	$rgcopyMode			= 'Clone Mode'
	$cloneOrMergeMode	= $True
	$useBicep			= $True
}

# Merge Mode
if ($mergeMode) {
	$suppliedModes 		+= 'mergeMode'
	$rgcopyMode			= 'Merge Mode'
	$cloneOrMergeMode	= $True
	$useBicep			= $True
}

# Patch Mode
if ($patchMode) {
	$suppliedModes 		+= 'patchMode'
	$rgcopyMode			= 'Patch Mode'
	$useBicep			= $True
}

# Update Mode
if ($updateMode) {
	$suppliedModes 		+= 'updateMode'
	$rgcopyMode			= 'Update Mode'
}

# Archive Mode
if ($archiveMode) {
	$suppliedModes 		+= 'archiveMode'
	$rgcopyMode			= 'Archive Mode'
}

# Copy Mode
if ($suppliedModes.count -eq 0) {
	$rgcopyMode			= 'Copy Mode'
	$copyMode = $True
}

# process only sourceRG ?
if (    $updateMode `
	-or $patchMode `
	-or $cloneMode `
	-or $justCreateSnapshots `
	-or $justDeleteSnapshots `
	-or ($mergeMode -and ('targetRG' -notin $boundParameterNames)) `
   ) {
	$SourceOnlyMode = $True
	$targetRG = $sourceRG
}
else {
	$SourceOnlyMode = $False
}

# constants
$snapshotExtension	= 'rgcopy'
$netAppSnapshotName	= 'rgcopy'
$targetSaContainer	= 'rgcopy'
$sourceSaShare		= 'rgcopy'
$netAppPoolSizeMinimum = 4 * 1024 * 1024 * 1024 * 1024

# azure tags
$azTagMonitorRule			= 'rgcopy.MonitorRule'
$azTagVmType 				= 'rgcopy.VmType'
$azTagTipGroup 				= 'rgcopy.TipGroup'
$azTagDeploymentOrder 		= 'rgcopy.DeploymentOrder'
$azTagSapMonitor 			= 'rgcopy.Extension.SapMonitor'
$azTagDiagSettingsSA 		= 'rgcopy.diagSettingsSA'
$azTagDiagSettingsContainer = 'rgcopy.diagSettingsContainer'
$azTagScriptStartSap 		= 'rgcopy.ScriptStartSap'
$azTagScriptStartLoad 		= 'rgcopy.ScriptStartLoad'
$azTagScriptStartAnalysis	= 'rgcopy.ScriptStartAnalysis'
$azTagSmbLike 				= 'rgcopy.smb.*'
$azTagSub 					= 'rgcopy.smb.Subscription'
$azTagRG 					= 'rgcopy.smb.ResourceGroup'
$azTagSA 					= 'rgcopy.smb.StorageAccount'
$azTagPath 					= 'rgcopy.smb.Path'
$azTagLun 					= 'rgcopy.smb.DiskLun'
$azTagVM 					= 'rgcopy.smb.VM'

if (!$IsWindows -and ('hostPlainText' -notin $boundParameterNames)) {
	$hostPlainText = $True
}

#--------------------------------------------------------------
function test-match {
#--------------------------------------------------------------
	param (
		$name,
		$value,
		$match,
		$partName,
		$syntax
	)

	if ($value -cnotmatch $match) {
		if ($Null -eq $syntax) {
			write-logFileError "Invalid parameter '$name'" `
								"Value is '$value'" `
								"Value must match '$match'"
		}
		else {
			write-logFileError "Invalid parameter '$name'" `
								"The syntax is: '$syntax'" `
								"Value of '$partName' is '$parameterValue'" `
								"Value must match '$match'"
		}
	}
}

#--------------------------------------------------------------
function test-names {
#--------------------------------------------------------------
	# netAppPoolGB
	if (($netAppPoolGB * 1024 * 1024 * 1024) -lt $netAppPoolSizeMinimum) {
		write-logFileError "Invalid parameter 'netAppPoolGB'" `
							"Value must be at least 4096"
	}

	test-values 'netAppServiceLevel' $netAppServiceLevel @('Standard', 'Premium', 'Ultra')
	test-values 'createDisksTier' $createDisksTier @('P2', 'P3', 'P4', 'P6', 'P10', 'P15', 'P20', 'P30', 'P40', 'P50')

	#--------------------------------------------------------------
	# resource groups
	# Can include alphanumeric, underscore, parentheses, hyphen, period (except at end)
	# length: 1-90
	$match = '^[a-zA-Z0-9_\-\(\)\.]{0,89}[a-zA-Z0-9_\-\(\)]$'

	test-match 'targetRG' $script:targetRG $match
	test-match 'sourceRG' $script:sourceRG $match
	if ($script:blobsRG.Length -ne 0) {
		test-match 'blobsRG' $script:blobsRG $match
	}

	#--------------------------------------------------------------
	# storage accounts
	# Lowercase letters and numbers
	# length: 3-24
	$match = '^[a-z0-9]{3,24}$'

	# targetSA
	if ($script:targetSA.Length -eq 0) {
		$name = ($script:targetRG -replace '[_\.\-\(\)]', '').ToLower()

		# truncate name
		$len = (24, $name.Length | Measure-Object -Minimum).Minimum
		$name = $name.SubString(0,$len)

		# name too short
		if ($len -lt 3) {
			$name = 'blob' + $name
		}

		$script:targetSA = $name
	}
	else {
		test-match 'targetSA' $script:targetSA $match
	}

	# sourceSA
	if ($script:sourceSA.Length -eq 0) {
		$name = ($script:sourceRG -replace '[_\.\-\(\)]', '').ToLower()

		# truncate name
		$len = (21, $name.Length | Measure-Object -Minimum).Minimum

		$script:sourceSA = 'nfs' + $name.SubString(0,$len)
	}
	else {
		test-match 'sourceSA' $script:sourceSA $match
	}

	# blobsSA
	if ($script:blobsSA.Length -ne 0) {
		test-match 'blobsSA' $script:blobsSA $match
	}

	#--------------------------------------------------------------
	# netAppAccountName
	# The name must begin with a letter and can contain letters, numbers, underscore ('_') and hyphens ('-') only.
	# The name must be between 1 and 128 characters.
	$match = '^[a-zA-Z][_\-a-zA-Z0-9]{0,127}$'

	if ($script:netAppAccountName.length -eq 0) {
		$script:netAppAccountName = 'rgcopy' + '-' + ($targetRG -replace '[\.\(\)]', '')
	}
	else {
		test-match 'netAppAccountName' $script:netAppAccountName $match
	}

	#--------------------------------------------------------------
	# netAppPoolName
	# The name must begin with a letter and can contain letters, numbers, underscore ('_') and hyphens ('-') only.
	# The name must be between 1 and 128 characters.
	$match = '^[a-zA-Z][_\-a-zA-Z0-9]{0,127}$'

	if ($script:netAppPoolName.length -eq 0) {
		$script:netAppPoolName = "rgcopy-$($netAppServiceLevel.ToLower()[0])-pool"
	}
	else {
		test-match 'netAppPoolName' $script:netAppPoolName $match
	}

	#--------------------------------------------------------------
	# archiveContainer
	# This name may only contain lowercase letters, numbers, and hyphens, and must begin with a letter or a number. 
	# Each hyphen must be preceded and followed by a non-hyphen character.
	# The name must also be between 3 and 63 characters long.
	$match = '^[a-z0-9][a-z0-9\-]{1,61}[a-z0-9]$'

	if ($script:archiveContainer.length -eq 0) {
		$name = ($sourceRG `
					-replace '[_\.\(\)]', '-' `
					-replace '\-+', '-' `
					-replace '^\-+', '' `
					-replace '\-+$', '' `
				).ToLower()

		# truncate name
		$len = (63, $name.Length | Measure-Object -Minimum).Minimum
		$name = $name.SubString(0,$len)

		# hyphen could be last character after truncation
		$name = $name -replace '\-+$', ''

		# name too short
		if ($name.length -lt 3) {
			$name += '-dir'
		}

		$script:archiveContainer = $name
	}
	else {
		test-match 'archiveContainer' $script:archiveContainer $match

		$test = $script:archiveContainer -replace '\-+', '-'
		if ($test -ne $script:archiveContainer) {
			write-logFileError "Invalid parameter 'archiveContainer'" `
								"Value is '$script:archiveContainer'" `
								"Each hyphen must be preceded and followed by a non-hyphen character"
		}
	}
}

#--------------------------------------------------------------
function test-values {
#--------------------------------------------------------------
	param (
		$parameterName,
		$parameterValue,
		$allowedValues,
		$partName,
		$syntax
	)

	$list = '{'
	$sep = ''
	foreach ($item in $allowedValues) {
		$list += "$sep $item"
		$sep = ','
	}
	$list += ' }'

	if ($parameterValue -notin $allowedValues) {
		if ($Null -ne $syntax) {
			write-logFileError "Invalid parameter '$parameterName'" `
								"The syntax is: '$syntax'" `
								"Value of '$partName' is '$parameterValue'" `
								"Allowed values are: $list"
		}
		elseif ($Null -ne $partName) {
			write-logFileError "Invalid parameter '$parameterName'" `
								"Value of $partName is '$parameterValue'" `
								"Allowed values are: $list"
		}
		else {
			write-logFileError "Invalid parameter '$parameterName'" `
								"Value is '$parameterValue'" `
								"Allowed values are: $list"
		}
	}
}

#--------------------------------------------------------------
function test-subnet {
#--------------------------------------------------------------
	param (
		$parameterName,
		$parameterValue,
		$defaultSubnet
	)

	$param = $parameterValue -replace '\s+', ''

	# check for parameter parts
	$addressPrefix, $vnetName = $param -split '@'
	if (($addressPrefix.count -ne 1) -or ($vnetName.count -ne 1)) {
		write-logFileError "Invalid parameter '$parameterName'" `
							"Parameter must match <addressPrefix>@<vnet>"
	}

	# check prefix
	if ($addressPrefix -notmatch '\d+\.\d+\.\d+\.\d+/\d+') {
		write-logFileError "Invalid parameter '$parameterName'" `
							"Invalid addressPrefix '$addressPrefix'" `
							"AddressPrefix must match '\d+\.\d+\.\d+\.\d+/\d+'"
	}

	# Get source VNETs
	$script:sourceVNETs = @( Get-AzVirtualNetwork `
		-ResourceGroupName $sourceRG `
		-ErrorAction 'SilentlyContinue' )
	test-cmdlet 'Get-AzVirtualNetwork'  "Could not get VNETs of resource group $sourceRG"

	$vnet = $script:sourceVNETs | Where-Object Name -eq $vnetName

	if ($Null -eq $vnet) {
		write-logFileError "Invalid parameter '$parameterName'" `
							"Vnet '$vnet' not found"
	}

	$subnetNames = $vnet.Subnets.Name
	$subnetName = $defaultSubnet

	$i = 1
	while ($subnetName -in $subnetNames) {
		$i++
		$subnetName = "$defaultSubnet$i"
	}

	return $vnetName, $subnetName, $addressPrefix
}

#--------------------------------------------------------------
function test-cmdlet {
#--------------------------------------------------------------
	param (	
		$azFunction,
		$errorText,
		$errorText2,
		[switch] $always
	)

	if (!$? -or $always -or $script:errorOccured) {
		write-logFileError $errorText `
							"$azFunction failed" `
							$errorText2 `
							-lastError
	}
}

#--------------------------------------------------------------
function write-logFile {
#--------------------------------------------------------------
	param (
		$print,
		$ForegroundColor,
		[switch] $NoNewLine,
		[switch] $blinking
	)

	$print = write-secureString $print

	if ($Null -eq $print) {
		$print = ' '
	}
	if ($blinking) {
		$print = "`e[5m" + $print + "`e[0m"
	}

	[string] $script:LogFileLine += $print

	$par = @{ Object = $print }
	if ($NoNewLine) {
		$par.Add('NoNewLine', $True)
	}
	if ($Null -ne $ForegroundColor) {
		$par.Add('ForegroundColor', $ForegroundColor)
	}

	# write to host
	if ($hostPlainText) {
		if (!$NoNewLine) {
			Write-Host $script:LogFileLine
		}
	}
	else {
		Write-Host @par
	}

	# write to log file
	if (!$NoNewLine) {
		try {
			$script:LogFileLine | Out-File $logPath -Append
		}
		catch {
			Start-Sleep 1
			# one retry (if file is opened by virus scanner)
			$script:LogFileLine | Out-File $logPath -Append
		}
		[string] $script:LogFileLine = ''
	}
}

#--------------------------------------------------------------
function write-LogFilePipe {
#--------------------------------------------------------------
	[CmdletBinding()]
	Param (
		[Parameter(Position=0, Mandatory=$true, ValueFromPipeline=$true)]
		$InputObject,
		[switch] $errorLog
	)
	begin {
		$log = @()
	}
	process {
		$log += $InputObject
	}
	end {
		$log | Out-Host
		if ($PsStyle.OutputRendering -eq 'Ansi') {
			$PsStyle.OutputRendering = 'PlainText'
			$log | Out-File $logPath -Append
			$PsStyle.OutputRendering = 'Ansi'
		}
		else {
			$log | Out-File $logPath -Append
		}
	}
}

#--------------------------------------------------------------
function write-logFileWarning {
#--------------------------------------------------------------
	param ( 
		$myWarning,
		$param2,
		$param3,
		$param4,
		$stopCondition,
		[switch] $stopWhenForceVmChecks,
		[switch] $noSkip
	)

	# write error
	if (($stopWhenForceVmChecks -and $forceVmChecks) `
	-or ($stopCondition -eq $True)) {

		if ($simulate) {
			write-logFile "WARNING: $myWarning" -ForegroundColor 'red'
		}
		else {
			write-logFileError $myWarning $param2 $param3 $param4
		}
	}
	# write warning
	else {
		write-logFile "WARNING: $myWarning" -ForegroundColor 'yellow'
	}

	if ($param2.length -ne 0) { write-logFile $param2 }
	if ($param3.length -ne 0) { write-logFile $param3 }
	if ($param4.length -ne 0) { write-logFile $param4 }
	# new line
	if (($param2.length -ne 0) -and !$noSkip) { write-logFile }
}

#--------------------------------------------------------------
function write-logFileConfirm {
#--------------------------------------------------------------
	param (
		$text
	)

	write-logFile ('-' * $starCount) -ForegroundColor 'Red'
	write-logFile $text -ForegroundColor 'red'
	write-logFile ('-' * $starCount) -ForegroundColor 'Red'
	write-logFile

	if ($simulate) {
		write-logFile "Enter 'yes' to continue"
		write-logFile "answer not needed in simulation mode"
		write-logFile
	}
	else {
		$answer = Read-Host "Enter 'yes' to continue"
		write-logFile
		if ($answer -ne 'yes') {
			write-logFile "The answer was '$answer'"
			write-logFile
			write-zipFile 0
		}
	}
}

#--------------------------------------------------------------
function write-zipFile {
#--------------------------------------------------------------
	param (
		$exitCode
	)

	# exit code 0: exit RGCOPY regularly (no error)
	if ($exitCode -eq 0) {
		write-logFile "RGCOPY ENDED: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz')" -ForegroundColor 'green' 
	}

	# any exit code: exit RGCOPY (with or without error)
	if ($Null -ne $exitCode) {
		write-logFile -ForegroundColor 'Cyan' "All files saved in zip file: $zipPath"
		write-logFile ('*' * $starCount) -ForegroundColor 'DarkGray'
		write-logFile "RGCOPY EXIT CODE:  $exitCode" -ForegroundColor 'DarkGray'
		write-logFile ('*' * $starCount) -ForegroundColor 'DarkGray'
		write-logFile
		$files = @($logPath)
		if ($(Test-Path -Path $savedRgcopyPath) -eq $True) 
			{$files += $savedRgcopyPath
		}
		$destinationPath = $zipPath
	}

	# no exit code: just create ZIP file and save it in BLOB
	else {
		$files = @()
		$destinationPath = $zipPath2
	}

	foreach ($logFileName in $script:armTemplateFilePaths) {
		if ($(Test-Path -Path $logFileName) -eq $True) 
			{$files += $logFileName
		}
	}

	$parameter = @{
		LiteralPath		= $files
		DestinationPath = $destinationPath
		ErrorAction 	= 'SilentlyContinue'
		force			= $True
	}
	Compress-Archive @parameter
	if (!$?) {
		$script:errorOccured = $True
	}

	# save zip file to BLOB
	if (($Null -eq $exitCode) `
	-or ($archiveMode -and ($exitCode -eq 0))) {
		try {
			# get SA
			$context = New-AzStorageContext `
							-StorageAccountName   $targetSA `
							-UseConnectedAccount `
							-ErrorAction 'Stop'
			if ($?) {
				# save ARM template as BLOB
				Set-AzStorageBlobContent `
					-Container	$targetSaContainer `
					-File		$destinationPath `
					-Context	$context `
					-Force `
					-ErrorAction 'Stop' | Out-Null
			}
		}
		catch {
			$script:errorOccured = $True
		}
	}

	# any exit code: exit RGCOPY (with or without error)
	if ($Null -ne $exitCode) {
		if (!$hostPlainText) {
			[console]::ResetColor()
		}
		$ErrorActionPreference = 'Continue'
		$PsStyle.OutputRendering = $PsStyleOutputRendering
		exit $exitCode
	}
}

#--------------------------------------------------------------
function write-logFileError {
#--------------------------------------------------------------
	param (
		$param1,
		$param2,
		$param3,
		$param4,
		[switch] $lastError
	)

	write-logFile
	write-logFile ('=' * 60) -ForegroundColor 'DarkGray'

	write-logFile $param1 -ForegroundColor 'yellow'

	if ($param2.length -ne 0) {
		write-logFile $param2 -ForegroundColor 'yellow'
	}
	if ($param3.length -ne 0) {
		write-logFile $param3 -ForegroundColor 'yellow'
	}
	if ($param4.length -ne 0) {
		write-logFile $param4 -ForegroundColor 'yellow'
	}

	if ($lastError) {
		$i = $error.count
		write-logFile
		write-logFile "messages, not necessarily errors:"
		foreach ($line in $error) {
			write-logFile -ForegroundColor 'DarkGray' "----- message number $i -----"
			write-logFile -ForegroundColor 'DarkGray' ($line -as [string])
			$i = $i -1
		}
	}

	write-logFile ('=' * 60) -ForegroundColor 'DarkGray'
	write-logFile

	$stack = Get-PSCallStack
	write-logFile "RGCOPY TERMINATED: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz')" -ForegroundColor 'red'
	write-logFile "CALL STACK: $("{0,5}" -f $stack[-1].ScriptLineNumber)  $($stack[-1].Command)" -ForegroundColor 'DarkGray'
	for ($i = $stack.count-2; $i -ge 2; $i--) {
		write-logFile "            $("{0,5}" -f $stack[$i].ScriptLineNumber)  $($stack[$i].Command)" -ForegroundColor 'DarkGray'
	}
	write-logFile "            $("{0,5}" -f $stack[1].ScriptLineNumber)  $($stack[1].Command)"
	write-logFile
	write-logFile "ERROR MESSAGE: $param1" -ForegroundColor 'red'
	write-zipFile 1
}

#--------------------------------------------------------------
function write-logFileUpdates {
#--------------------------------------------------------------
	param (	
		$resourceType,
		$resource,
		$action,
		$value,
		$comment1,
		$comment2,
		[switch] $NoNewLine,
		[switch] $continue,
		[switch] $defaultValue
	)

	# special color for variables
	if ($resource -like '<*') {
		$colorResource = 'Cyan'
	}
	else {
		$colorREsource = 'Gray'
	}
	
	# constant for string lengths
	$resourceTypeLength = 18
	$resourceLength = 35

	if ($continue) {
		# first 2 parameters have different meaning
		$action = $resourceType
		$value = $resource
	}
	else {
		# multi-part name
		$parts = $resource -split '/'
		$resourceType = $resourceType.PadRight($resourceTypeLength,' ').Substring(0,$resourceTypeLength)
	
		if ($parts.count -gt 1) {
			if ($parts[0].length -gt 14) {
				$part1 = $parts[0].Substring(0,11) + '.../'
			}
			else {
				$part1 = $parts[0] + '/'
			}
			$part2 = $parts[-1].PadRight($resourceLength - $part1.length,' ').Substring(0,$resourceLength - $part1.length)
	
			Write-logFile $resourceType -NoNewline -ForegroundColor 'DarkGray'
			write-logFile $part1 -NoNewline -ForegroundColor 'DarkGray'
			write-logFile $part2 -NoNewline -ForegroundColor $colorResource
		}
		else {
			if ($Null -eq $resource) {
				write-logFileError "Internal RGCOPY error"
			}
		
			$resource = $resource.PadRight($resourceLength,' ').Substring(0,$resourceLength)
	
			Write-logFile $resourceType -NoNewline -ForegroundColor 'DarkGray'
			write-logFile $resource -NoNewline -ForegroundColor $colorResource
		}
	}

	# colors for creation/deletion
	if (($action -like 'delete*') -or ($action -like 'disable*') -or ($action -like 'remove*') -or ($action -like 'skip*')) {
		$colorAction = 'Blue'
	}
	elseif (($action -like 'keep*') -or ($action -like 'no*')) {
		$colorAction = 'DarkGray'
	}
	else {
		$colorAction = 'Green'
	}

	$value = $value -as [string]
	$len = $action.length + $value.length + $comment1.length + $comment2.length
	if ($len -lt 24){
		$pad = ' ' * (24 - $len)
	}

	Write-logFile "$action "			-NoNewline -ForegroundColor $colorAction
	if ($defaultValue) {
		Write-logFile $value			-NoNewline -ForegroundColor 'DarkGray'
	}
	else {
		Write-logFile $value			-NoNewline
	}
	Write-logFile $comment1				-NoNewline -ForegroundColor 'Cyan'
	if ($NoNewLine) {
		Write-logFile "$comment2 $pad"	-NoNewline
	}
	else {
		Write-logFile $comment2
	}
}

#--------------------------------------------------------------
function write-logFileTab {
#--------------------------------------------------------------
	param (
		$resourceType,
		$resource,
		$info,
		[switch] $noColor
	)

	$resourceColor = 'Green'
	if ($noColor) { $resourceColor = 'Gray' }

	Write-logFile "  $($resourceType.PadRight(20))" -NoNewline
	write-logFile "$resource "						-NoNewline -ForegroundColor $resourceColor
	Write-logFile "$info"
}

#--------------------------------------------------------------
function write-stepStart {
#--------------------------------------------------------------
	param (
		$text,
		$maxDegree,
		[switch] $skipLF
	)

	if ($null -ne $maxDegree) {
		if ($maxDegree -gt 1) {
			$text = $text + " (max degree of parallelism: $maxDegree)"
		}
	}
	write-logFile ('*' * $starCount) -ForegroundColor DarkGray
	write-logFile $text
	write-logFile ('*' * $starCount) -ForegroundColor DarkGray
	# write-logFile ('>>>' + ('-' * ($starCount - 3))) -ForegroundColor DarkGray
	write-logFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') -ForegroundColor DarkGray -NoNewLine
	if ($copyMode) {
		write-logFile "  target RG: $targetRG" -ForegroundColor DarkGray 
	}
	else {
		write-logFile
	}
	if (!$skipLF) {
		write-logFile
	}
}

#--------------------------------------------------------------
function write-stepEnd {
#--------------------------------------------------------------
	# write-logFile
	# write-logFile ('<<<' + ('-' * ($starCount - 3))) -ForegroundColor DarkGray
	write-logFile
	write-logFile
}

#--------------------------------------------------------------
function write-logFileForbidden {
#--------------------------------------------------------------
	param (	
		$suppliedParameter,
		$forbiddenParameters
	)

	# Copy Mode (not a supplied parameter)
	if ($suppliedParameter -eq 'copyMode') {

		foreach ($forbidden in $forbiddenParameters) {
			if ($forbidden -in $boundParameterNames) {

				write-logFileError "Invalid parameter '$forbidden'" `
									"Parameter is not allowed in copyMode"
			}
		}	
	}

	# supplied parameter
	elseif ($suppliedParameter -in $boundParameterNames) {

		foreach ($forbidden in $forbiddenParameters) {
			if ($forbidden -in $boundParameterNames) {

				write-logFileError "Invalid parameter '$forbidden'" `
									"Parameter is not allowed when '$suppliedParameter' is supplied"
			}
		}
	}
}

#--------------------------------------------------------------
function write-logFileHashTable {
#--------------------------------------------------------------
	param (
		$paramHashTable,
		[switch] $rgcopyParam
	)

	$script:hashTableOutput = @()
	$paramHashTable.GetEnumerator()
	| ForEach-Object {

		$paramKey   = $_.Key
		$paramValue = $_.Value
		if (($paramValue -is [array]) -and ($paramValue.length -eq 0)) {
			$paramValue = $Null
		}

		# array
		if ($paramValue -is [array]) {
			for ($i = 0; $i -lt $paramValue.Count; $i++) {
				# simple array (or array of array)
				if ($paramValue[$i] -isnot [hashtable]) {
					write-hashTableOutput "$paramKey[$i]" $paramValue[$i]
				}
			}
		}

		# hashtable
		elseif ($paramValue -is [hashtable]) {
			foreach ($item in $paramValue.GetEnumerator()) {
				# simple hashtable (or hashtable of array)
				if ($item.Value -isnot [hashtable]) {
					write-hashTableOutput "$paramKey[$($item.Key)]" $item.Value
				}
				# hashtable of hashtable
				else {
					foreach ($subitem in $item.Value.GetEnumerator()) {
						if ($subitem.Value -isnot [hashtable]) {
							write-hashTableOutput "$paramKey[$($item.Key)][$($subitem.Key)]" $subitem.Value
						}
					}
				}
			}
		}

		# scalar
		else {
			write-hashTableOutput $paramKey $paramValue
		}
	}

	if ($rgcopyParam) {
		$script:hashTableOutput
		| Select-Object `
			@{label="Type"; expression={
				if (($_.Parameter -like 'source*') -or ($_.Parameter -like 'target*')) {
					'RG'
				}
				elseif ($_.Parameter -in $workflowParameters) {
					'workflow'
				}
				elseif (($_.Parameter -replace '\[\d+\]$', '') -in $configParameters) {
					'config'
				}
				else {
					"other"
				}
			}}, `
			Parameter, `
			Value
		| Sort-Object @{Expression = "Type"; Descending = $true}, Parameter
		| Format-Table
		| write-LogFilePipe
	}
	else {
		$script:hashTableOutput
		| Select-Object Parameter, Value
		| Sort-Object Parameter
		| Format-Table
		| write-LogFilePipe
	}
}

#--------------------------------------------------------------
function write-hashTableOutput {
#--------------------------------------------------------------
	param (
		$key,
		$value
	)

	if (($key -like '*passw*') -or ($key -like '*credential*')) {
		if ($value.length -eq 0) {
			$value = ' '
		}
		$value = ConvertTo-SecureString $value -AsPlainText -Force
	}

	$script:hashTableOutput += New-Object psobject -Property @{
		Parameter	= $key
		Value		= (write-secureString $value)
	}
}

#--------------------------------------------------------------
function write-secureString {
#--------------------------------------------------------------
	param (
		$print
	)

	if ($print -is [securestring]) {
		$print = '*****'
	}

	if (($print -isnot [array]) -and ($print -isnot [hashtable])) {
		return $print
	}
	Write-Output -NoEnumerate $print
}

#--------------------------------------------------------------
function compare-resources{
#--------------------------------------------------------------
	param (
		$res1,
		$res2
	)

	return (($res1 -replace '\s+', '') -eq ($res2 -replace '\s+', ''))
}

#--------------------------------------------------------------
function convertTo-array {
#--------------------------------------------------------------
	param (
		$convertFrom,
		[switch] $saveError
	)

	# save last error status
	if (($saveError) -and (!$?)) {
		$script:errorOccured = $True
	}

	# empty input
	if (($convertFrom.count -eq 0) -or ($convertFrom.length -eq 0)) {
		Write-Output -NoEnumerate @()
		return
	}

	# convert to array
	if ($convertFrom -isnot [array]) {
		Write-Output -NoEnumerate @($convertFrom)
		return
	}

	# removes empty entries from array: $Null, '', @(). Does not remove @{}
	$output = $convertFrom | Where-Object {$_.length -ne 0}

	# convert to array
	if (($output.count -eq 0) -or ($output.length -eq 0)) {
		Write-Output -NoEnumerate @()
		return
	}
	if ($output -isnot [array]) {
		Write-Output -NoEnumerate @($convertFrom)
		return
	}

	# output of array
	Write-Output -NoEnumerate $output
}

#--------------------------------------------------------------
function get-ParameterConfiguration {
#--------------------------------------------------------------
	param (
		$config
	)

	# split configuration
	$script:paramConfig1,$script:paramConfig2,$script:paramConfig3,$script:paramConfig4 = $config -split '/'

	# a maximum of 4 configuration parts:
	if ($script:paramConfig4.count -gt 1) {
		write-logFileError "Invalid parameter '$script:paramName'" `
							"Configuration: '$config'" `
							"The configuration contains more than three '/'"
	}
	$script:paramConfig1 = $script:paramConfig1 -replace '\s+', ''
	$script:paramConfig2 = $script:paramConfig2 -replace '\s+', ''
	$script:paramConfig3 = $script:paramConfig3 -replace '\s+', ''
	$script:paramConfig4 = $script:paramConfig4 -replace '\s+', ''

	if ($script:paramConfig1.length -eq 0) { $script:paramConfig1 = $Null }
	if ($script:paramConfig2.length -eq 0) { $script:paramConfig2 = $Null }
	if ($script:paramConfig3.length -eq 0) { $script:paramConfig3 = $Null }
	if ($script:paramConfig4.length -eq 0) { $script:paramConfig4 = $Null }

	# part 1 or part 2 must exist
	if (($Null -eq $script:paramConfig1) -and ($Null -eq $script:paramConfig2)) {
		write-logFileError "Invalid parameter '$script:paramName'" `
							"Configuration: '$config'" `
							"Ivalid configuration"
	}
}

#--------------------------------------------------------------
function get-ParameterRule {
#--------------------------------------------------------------
# a parameter is an array of rules
# each rule has the form: configuration@resources
# each configuration consists of many parts separated by slash (/)
# resources are separated by comma (,)
	$script:paramConfig				= $Null
	$script:paramConfig1			= $Null
	$script:paramConfig2			= $Null
	$script:paramConfig3			= $Null
	$script:paramConfig4			= $Null
	[array] $script:paramResources	= @()
	[array] $script:paramVMs		= @()
	[array] $script:paramDisks		= @()
	[array] $script:paramNICs		= @()

	# no rule exists or last rule reached
	if ($script:paramRules.count -le $script:paramIndex) {
		return
	}

	# get current rule
	$currentRule = $script:paramRules[$script:paramIndex++]

	# alternative data type: convert $True, $False to [string]
	if ($currentRule -eq $True) {
		$currentRule = 'True'
	}
	elseif ($currentRule -eq $False) {
		$currentRule = 'False'
	}
	# convert [char] to [string]
	if ($currentRule -is [char]) {
		$currentRule = $currentRule -as [string]
	}

	# check data type of rule
	if ($currentRule -isnot [string]) {
		write-logFileError "Invalid parameter '$script:paramName'" `
							"Invalid data type of array element '$currentRule'"
	}

	# remove white spaces
	$currentRule = $currentRule -replace '\s+', ''

	# check for quotes
	if (($currentRule -like '*"*') -or ($currentRule -like "*'*")) {
		write-logFileError "Invalid parameter '$script:paramName'" `
							"Rule: '$currentRule'" `
							'Quotes not allowed as part of a name'
	}
	# split rule
	$script:paramConfig, $resources = $currentRule -split '@'

	# there must be 1 configuration
	# and 0 or 1 comma separated list of resources ( not more than one @ allowed per rule)
	if ($script:paramConfig.length -eq 0) {
		write-logFileError "Invalid parameter '$script:paramName'" `
							"Rule: '$currentRule'" `
							'The rule does not contain a configuration'
	}
	if ($resources.count -gt 1) {
		write-logFileError "Invalid parameter '$script:paramName'" `
							"Rule: '$currentRule'" `
							"The rule contains more than one '@'"
	}
	if ($currentRule -like '*@') {
		write-logFileError "Invalid parameter '$script:paramName'" `
							"Rule: '$currentRule'" `
							"The rule contains no resource after the '@'"
	}

	# split configuration
	get-ParameterConfiguration $script:paramConfig

	# split resources
	$script:paramResources = convertTo-array ($resources -split ',')

	# get resource types: VMs, disks, NICs
	if ($script:paramResources.count -eq 0) {
		$script:paramVMs   = convertTo-array $script:copyVMs.keys
		$script:paramDisks = convertTo-array $script:copyDisks.keys
		$script:paramNICs  = convertTo-array $script:copyNICs.keys
	}
	else {
		$script:paramVMs   = convertTo-array ($script:copyVMs.keys   | Where-Object {$_ -in $script:paramResources})
		$script:paramDisks = convertTo-array ($script:copyDisks.keys | Where-Object {$_ -in $script:paramResources})
		$script:paramNICs  = convertTo-array ($script:copyNICs.keys  | Where-Object {$_ -in $script:paramResources})

		# check existence
		$notFound = @() 
		if ($script:paramName -like 'setVm*') {
			$notFound += convertTo-array ($script:paramResources | Where-Object {$_ -notin $script:paramVMs})
		}
		if (($script:paramName -like 'setDisk*') -or ($script:paramName -like 'swap*4disk')) {
			$notFound += convertTo-array ($script:paramResources | Where-Object {$_ -notin $script:paramDisks})
		}
		if ($script:paramName -eq 'setAcceleratedNetworking') {
			$notFound += convertTo-array ($script:paramResources | Where-Object {$_ -notin $script:paramNICs})
		}
		foreach ($item in $notFound) {
			write-logFileWarning "Invalid parameter '$script:paramName'" `
								"Resource '$item' not found" `
								-stopCondition $True
		}
	}
}

#--------------------------------------------------------------
function set-parameter {
#--------------------------------------------------------------
# a parameter is an array of rules
# each rule has the form: configuration@resources
# each configuration consists of many parts separated by slash (/)
# resources are separated by comma (,)
	param (
		$parameterName,
		$parameter,
		$type,
		$type2,
		$type3,
		[switch] $ignoreMissingResources
	)

	$script:paramName = $parameterName

	# alternative data types 
	# - convert $True, $False to string
	# - convert integer to string
	if (($parameter -is [boolean]) -and ($parameter -eq $True)) {
		$parameter = 'True'
	}
	elseif (($parameter -is [boolean]) -and ($parameter -eq $False)) {
		$parameter = 'False'
	}
	elseif ($parameter -is [int]) {
		$parameter = $parameter -as [string]
	}
	elseif ($Null -eq $parameter) {
		$parameter = @()
	}
	
	# check data type
	if (($parameter -isnot [array]) -and ($parameter -isnot [string])) {
		write-logFileError "Invalid parameter '$script:paramName'" `
							"invalid data type"
	}

	# paramRules as array
	$script:paramRules = convertTo-array $parameter

	# set script variable for index of rules (current rule)
	[int] $script:paramIndex = 0
	$script:paramValues = @{}

	if ($script:paramRules.count -gt 1) {
		# process first rule last -> first rule wins
		[array]::Reverse($script:paramRules)

		# process global rules (no @) first
		$head = convertTo-array ($script:paramRules | Where-Object {$_ -notlike '*@*'})
		$tail = convertTo-array ($script:paramRules | Where-Object {$_ -like '*@*'})
		$script:paramRules = convertTo-array ($head + $tail)
	}

	#--------------------------------------------------------------
	# get all resource names from ARM template
	if ($Null -ne $type) {
		$resourceNames = convertTo-array (($script:resourcesALL | Where-Object type -eq $type).name)
	}
	else {
		return # no ARM resource types supplied
	}
	if ($Null -ne $type2) {
		$resourceNames += convertTo-array (($script:resourcesALL | Where-Object type -eq $type2).name)
	}
	if ($Null -ne $type3) {
		$resourceNames += convertTo-array (($script:resourcesALL | Where-Object type -eq $type3).name)
	}

	$script:paramAllConfigs = @()
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$script:paramAllConfigs += @{
			paramConfig		= $script:paramConfig
			paramConfig1	= $script:paramConfig1
			paramConfig2	= $script:paramConfig2
			paramConfig3	= $script:paramConfig3
			paramConfig4	= $script:paramConfig4
		}

		if ($script:paramResources.count -eq 0)	{
			# configuration valid for no VM (just create the VMSS, PPG or AvSet without members)
			if ($parameterName -in @('createVmssFlex', 'createProximityPlacementGroup', 'createAvailabilitySet')) {
				$myResources = @()
			}
			
			# configuration valid for all resources
			else {
				$myResources = $resourceNames
			}
		}
		else {
			$myResources = $script:paramResources
			# check existence
			if (!$ignoreMissingResources) {
				$notFound = convertTo-array ($script:paramResources | Where-Object {$_ -notin $resourceNames})
				foreach ($item in $notFound) {
					write-logFileWarning "Invalid parameter '$script:paramName'" `
										"Resource '$item' not found" `
										-stopCondition $True
				}
			}
		}

		foreach ($res in $myResources) {
			$script:paramValues[$res] = $script:paramConfig
		}
		get-ParameterRule
	}
}

#--------------------------------------------------------------
function get-scriptBlockParam {
#--------------------------------------------------------------
	param (
		$scriptParameter,
		$scriptBlock, 
		$myMaxDOP
	)
	
	if ($myMaxDOP -eq 1) {
		return @{
			Process = $scriptBlock
		}
	}
	else {
		$scriptReturn = [Scriptblock]::Create($scriptParameter + $scriptBlock.toString())
		return @{
			ThrottleLimit	= $myMaxDOP
			Parallel		= $scriptReturn
		}
	}
}

#--------------------------------------------------------------
function get-functionBody {
#--------------------------------------------------------------
	param (
		$str,
		$inputString
	)

	$from = $str.IndexOf('(')
	if ($from -eq -1) {
		write-logFileError "Error parsing ARM resource:" `
							"$inputString"
	}
	$to = $str.LastIndexOf(')')
	if ($to -ne ($str.length -1)) {
		write-logFileError "Error parsing ARM resource:" `
							"$inputString"
	}
	$function = $str.Substring(0, $from)
	$body = $str.Substring( $from + 1, $to - $from - 1)

	return $function, $body
}

#--------------------------------------------------------------
function remove-dependencies {
#--------------------------------------------------------------
	param (
		$dependsOn,
		$remove,
		$keep
	)

	if ($keep.length -ne 0) {
		$return = convertTo-array ($dependsOn | Where-Object { $_ -like "*'$keep'*" })
	}
	elseif ($remove.length -ne 0) {
		$return = convertTo-array ($dependsOn | Where-Object { $_ -notlike "*'$remove'*" })
	}
	else {
		$return = @()
	}
	Write-Output -NoEnumerate $return
}

#--------------------------------------------------------------
function remove-resources {
#--------------------------------------------------------------
	param (
		$type,
		$names
	)

	# only type specified: wild card for type allowed
	if ('names' -notin $PSBoundParameters.Keys) {
		$script:resourcesALL = convertTo-array ($script:resourcesALL | Where-Object `
			type -notlike $type)
	}
	# name specified and wild card for name used
	elseif ($names[0] -match '\*$') {
		$script:resourcesALL = convertTo-array ($script:resourcesALL | Where-Object `
			{($_.type -ne $type) -or ($_.name -notlike $names)})
	}
	# array of names specified
	else {
		$script:resourcesALL = convertTo-array ($script:resourcesALL | Where-Object `
			{($_.type -ne $type) -or ($_.name -notin $names)})
	}
}

#--------------------------------------------------------------
function get-resourceString {
#--------------------------------------------------------------
	# assembles string for Azure Resource ID
	param (	
		$subscriptionID,	$resourceGroup,
		$resourceArea,
		$mainResourceType,	$mainResourceName,
		$subResourceType,	$subResourceName
	)

	$resID = "/subscriptions/$subscriptionID/resourceGroups/$resourceGroup/providers/$resourceArea/$mainResourceType/$mainResourceName"
	if ($Null -ne $subResourceType) { $resID += "/$subResourceType/$subResourceName" }
	return $resID
}

#--------------------------------------------------------------
function get-resourceFunction {
#--------------------------------------------------------------
	# assembles string for Azure Resource ID using function resourceId()
	param (
		$resourceArea,
		$mainResourceType, $mainResourceName,
		$subResourceType,  $subResourceName
	)

	# BICEP
	if ($useBicep) {
		$start = '<'
		$end = '>'
	}

	# ARM
	else {
		$start = '['
		$end = ']'
	}

	$resFunction = "$($start)resourceId('$resourceArea/$mainResourceType"
	if ($Null -ne $subResourceType) {
		$resFunction += "/$subResourceType"
	}

	# check for functions, e.g. parameters()
	if ($mainResourceName -like '*(*') {$ap = ''} else {$ap = "'"}
	$resFunction += "', $ap$mainResourceName$ap"

	if ($Null -ne $subResourceType) {
		# check for functions, e.g. parameters()
		if ($subResourceName -like '*(*') {$ap = ''} else {$ap = "'"}
		$resFunction += ", $ap$subResourceName$ap"
	}
	$resFunction += ")$end"

	return $resFunction
}

#--------------------------------------------------------------
function get-resourceComponents {
#--------------------------------------------------------------
	# gets Azure Resource data from Azure Resource ID string
	# examples for $inputString:
	#   "/subscriptions/mysub/resourceGroups/myrg/providers/Microsoft.Network/virtualNetworks/xxx"
	#   "/subscriptions/mysub/resourceGroups/myrg/providers/Microsoft.Network/virtualNetworks/xxx/subnets/yyy"
	#   "[resourceId('Microsoft.Network/virtualNetworks', 'xxx')]"
	#   "[resourceId('Microsoft.Network/virtualNetworks/subnets', 'xxx, 'yyy')]"
	#   "[concat(resourceId('Microsoft.Network/virtualNetworks', 'xxx'), '/subnets/yyy')]"
	#   "[resourceId('Microsoft.Compute/disks', 'disk12')]"
	#   "[concat(resourceId('Microsoft.Compute/disks', 'disk1'), '2')]"  # does not make sense, but found in exported ARM template!
	param (
		$inputString,
		$subscriptionID,
		$resourceGroup
	)

	# remove white spaces
	$condensedString = $inputString -replace '\s*', '' -replace "'", ''

	# process functions
	if (($condensedString -like '`[*') -or ($condensedString -like '<resourceId*')) {

		# remove Bicep brackets
		$condensedString = $condensedString -replace '<', '' -replace '>', ''
		$inputString = $inputString -replace '<', '' -replace '>', ''

		# remove square brackets

		# BICEP
		if ($useBicep) {
			$str = $condensedString -replace '\[', '' -replace '\]', ''
		}

		# ARM
		else {
			if ($condensedString[-1] -ne ']') {
				write-logFileError "Error parsing ARM resource:" `
									"$inputString"
			}
			if ($condensedString.length -le 2) {
				write-logFileError "Error parsing ARM resource:" `
									"$inputString"
			}
			$str = $condensedString.Substring(1,$condensedString.length -2)
		}

		# get function
		$function, $body = get-functionBody $str $inputString

		# function concat
		if ($function -eq 'concat') {
			# get concat value
			$commaPosition = $body.LastIndexOf(',')
			if ($commaPosition -lt 1) {
				write-logFileError "Error parsing ARM resource:" `
									"$inputString"
			}
			$head = $body.Substring(0, $commaPosition)
			$tail = $body.Substring($commaPosition + 1, $body.length - $commaPosition - 1)

			$function, $body = get-functionBody $head $inputString
			# converted to function resourceId
			if ($function -ne 'resourceId') {
				write-logFileError "Error parsing ARM resource:" `
									"$inputString"
			}

			# concatenated subresource
			if ($tail -like '*/*') {
				$x, $resType, $resName, $y = $tail -split '/'
				if (($Null -ne $x) -or ($Null -eq $resType) -or ($Null -eq $resName) -or ($Null -ne $y)) {
					write-logFileError "Error parsing ARM resource:" `
										"$inputString"
				}
				$str = $body
			}
			# concatenated string
			else {
				$str = "$body$tail"
			}

		}
		# function resourceId
		elseif ($function -eq 'resourceId') {
			$str = $body
		}
		else {
			write-logFileError "Error parsing ARM resource:" `
								"$inputString"
		}

		# no 3rd. function allowed
		if ($str -like '(') {
			write-logFileError "Error parsing ARM resource:" `
								"$inputString"
		}

		$resourceGroup,$resourceType,$mainResourceName,$subResourceName = $str -split ','
		if ($resourceGroup -like '*/*') {
			$subResourceName = $mainResourceName
			$mainResourceName = $resourceType
			$resourceType = $resourceGroup
			$resourceGroup = $Null
		}

		if ($Null -eq $resourceType) {
			write-logFileError "Error parsing ARM resource:" `
								"$inputString"
		}
		if ($Null -eq $mainResourceName) {
			write-logFileError "Error parsing ARM resource:" `
								"$inputString"
		}
		if ($subResourceName.count -gt 1) {
			write-logFileError "Error parsing ARM resource:" `
								"$inputString"
		}

		$resourceArea,$mainResourceType,$subResourceType = $resourceType -split '/'
		if ($Null -eq $resourceArea) {
			write-logFileError "Error parsing ARM resource:" `
								"$inputString"
		}
		if ($Null -eq $mainResourceType) {
			write-logFileError "Error parsing ARM resource:" `
								"$inputString"
		}
		if ($subResourceType.count -gt 1) {
			write-logFileError "Error parsing ARM resource:" `
								"$inputString"
		}

		# add concatenated subresource
		if ($Null -ne $resType) {
			$subResourceType = $resType
			$subResourceName = $resName
		}

		$resID = "/subscriptions/$subscriptionID/resourceGroups/$resourceGroup/providers/$resourceArea/$mainResourceType/$mainResourceName"
		if ($Null -ne $subResourceType) {
			$resID += "/$subResourceType/$subResourceName"
		}
	}

	# process resource ID
	elseif (($condensedString -like '/*') -or ($condensedString -like '</*')) {
		$resID = $inputString -replace '<', '' -replace '>', ''
		$x,$s,$subscriptionID,$r,$resourceGroup,$p,$resourceArea,$mainResourceType,$mainResourceName,$subResourceType,$subResourceName = $resId -split '/'
		if ($subResourceName.count -gt 1) {
			write-logFileError "Error parsing ARM resource:" `
								"$inputString"
		}
	}

	# process BICEP ID
	elseif ($inputString -like '<*.id>') {
		$bicepName = -join $inputString[1..($inputString.length -5)]

		if ($Null -ne $script:bicepNamesAll[$bicepName]) {
			$mainResourceName = $script:bicepNamesAll[$bicepName].name
			$mainResourceType = $script:bicepNamesAll[$bicepName].type
		}
		else {
			write-logFileError "Error parsing ARM resource:" `
								"BICEP name '$bicepName' not found"
		}
	}

	else {
		write-logFileError "Internal RGCOPY error while parsing ARM resource:" `
							"$inputString"
	}

	# new resource function w/o concatenate
	$resFunction = "[resourceId('$resourceArea/$mainResourceType"
	if ($Null -ne $subResourceType) {
		$resFunction += "/$subResourceType"
	}
	$resFunction += "', '$mainResourceName'"
	if ($Null -ne $subResourceType) {
		$resFunction += ", '$subResourceName'"
	}
	$resFunction += ")]"

	return @{
		resID 				= $resID
		resFunction			= $resFunction
		subscriptionID 		= $subscriptionID
		resourceGroup		= $resourceGroup
		resourceArea		= $resourceArea
		mainResourceType	= $mainResourceType
		mainResourceName	= $mainResourceName
		subResourceType		= $subResourceType
		subResourceName		= $subResourceName
	}
}

#--------------------------------------------------------------
function test-context{
#--------------------------------------------------------------
	param (
		$mySub,
		$mySubUser,
		$mySubTenant,
		$myType
	)

	# get context
	if ($mySubTenant.length -eq 0) {
		$myContext = Get-AzContext -ListAvailable
		| Where-Object {$_.Account.Id -eq $mySubUser}
		| Where-Object {$_.Subscription.Name -eq $mySub}
	}
	else {
		$myContext = Get-AzContext -ListAvailable
		| Where-Object {$_.Account.Id -eq $mySubUser}
		| Where-Object {$_.Subscription.Name -eq $mySub}
		| Where-Object {$_.Tenant.Id -eq $mySubTenant}
	}

	if ($Null -eq $myContext) {
		write-logFile 'list of existing contexts:'
		Get-AzContext -ListAvailable
		| Select-Object `
			@{label="AccountId";        expression={$_.Account.Id}}, `
			@{label="SubscriptionName"; expression={$_.Subscription.Name}}, `
			@{label="TenantId";         expression={$_.Tenant.Id}}
		| Format-Table
		| write-LogFilePipe

		write-logFileWarning "Run Connect-AzAccount before starting RGCOPY"
		write-logFile

		write-logFileError "Get-AzContext failed for user: $mySubUser" `
							"Subscription:                  $mySub"
	}

	# set context
	Set-AzContext `
		-Context		$myContext[0] `
		-ErrorAction	'SilentlyContinue' `
		-WarningAction	'SilentlyContinue' `
		| Out-Null

	if (!$?) {
		# This should never happen because Get-AzContext already worked:
		write-logFileError "Set-AzContext failed for user: $mySubUser" `
							"Subscription:                  $mySub" `
							"Tenant:                        $mySubTenant" `
							-lastError
	}
}

#--------------------------------------------------------------
function set-context {
#--------------------------------------------------------------
	param (
		$mySubscription
	)

	if ($mySubscription -eq $script:currentSub) {
		return
	}

	write-logFile "--- set subscription context $mySubscription ---" -ForegroundColor DarkGray

	if ($mySubscription -eq $sourceSub) {
		Set-AzContext `
			-Context		$sourceContext `
			-ErrorAction	'SilentlyContinue' `
			-WarningAction	'SilentlyContinue' `
			| Out-Null
		test-cmdlet 'Set-AzContext'  "Could not connect to Subscription '$mySubscription'"

		$script:currentAccountId = $sourceContext.Account.Id
	} 
	elseif ($mySubscription -eq $targetSub) {
		Set-AzContext `
			-Context		$targetContext `
			-ErrorAction	'SilentlyContinue' `
			-WarningAction	'SilentlyContinue' `
			| Out-Null
		test-cmdlet 'Set-AzContext'  "Could not connect to Subscription '$mySubscription'"

		$script:currentAccountId = $targetContext.Account.Id

	}
	else {
		# This should never happen because test-context() already worked:
		write-logFileError "Invalid Subscription '$mySubscription'"
	}

	$script:currentSub = $mySubscription
}

#--------------------------------------------------------------
$sizesSortedSSD   = @(  4,    8,   16,   32,   64,   128,   256,   512,  1024,  2048,  4096,  8192, 16384, 32767 )
$sizesSortedHDD   = @(                   32,   64,   128,   256,   512,  1024,  2048,  4096,  8192, 16384, 32767 )
$tierPremiumSSD   = @('P1', 'P2', 'P3', 'P4', 'P6', 'P10', 'P15', 'P20', 'P30', 'P40', 'P50', 'P60', 'P70', 'P80')
$tierStandardSSD  = @('E1', 'E2', 'E3', 'E4', 'E6', 'E10', 'E15', 'E20', 'E30', 'E40', 'E50', 'E60', 'E70', 'E80')
$tierStandardHDD  = @(                  'S4', 'S6', 'S10', 'S15', 'S20', 'S30', 'S40', 'S50', 'S60', 'S70', 'S80')
#--------------------------------------------------------------
function get-diskTier {
#--------------------------------------------------------------
	param (
		$sizeGB,
		$SkuName
	)

	if ($sizeGB -eq 0) {
		return $Null
	}

	switch ($SkuName) {
		{ 'Premium_LRS', 'Premium_ZRS' -eq $_ } {
			for ($i = 0; $i -lt $sizesSortedSSD.Count; $i++) {
				if ($sizeGB -le $sizesSortedSSD[$i]) {
					return $tierPremiumSSD[$i]
				}
			}
		}
		{ 'StandardSSD_LRS', 'StandardSSD_ZRS' -eq $_ } {
			for ($i = 0; $i -lt $sizesSortedSSD.Count; $i++) {
				if ($sizeGB -le $sizesSortedSSD[$i]) {
					return $tierStandardSSD[$i]
				}
			}
		}
		'Standard_LRS' {
			for ($i = 0; $i -lt $sizesSortedHDD.Count; $i++) {
				if ($sizeGB -le $sizesSortedHDD[$i]) {
					return $tierStandardHDD[$i]
				}
			}
		}
		'UltraSSD_LRS' {
			return 'Ultra'
		}
		'PremiumV2_LRS' {
			return 'PremV2'
		}
	}
	return ''
}

#--------------------------------------------------------------
function get-diskSize {
#--------------------------------------------------------------
	param (
		$tier
	)

	for ($i = 0; $i -lt $tierPremiumSSD.Count; $i++) {
		if ($tier -eq $tierPremiumSSD[$i]) {
			return $sizesSortedSSD[$i]
		}
	}
	for ($i = 0; $i -lt $tierStandardSSD.Count; $i++) {
		if ($tier -eq $tierStandardSSD[$i]) {
			return $sizesSortedSSD[$i]
		}
	}
	for ($i = 0; $i -lt $tierStandardHDD.Count; $i++) {
		if ($tier -eq $tierStandardHDD[$i]) {
			return $sizesSortedHDD[$i]
		}
	}
	return 0
}

#--------------------------------------------------------------
function save-skuDefaultValue {
#--------------------------------------------------------------
	param (
		$vmSize
	)

	if ($Null -eq $script:vmSkus[$vmSize]) {
		# if $skipVmChecks: all features are available
		$script:vmSkus[$vmSize] = New-Object psobject -Property @{
			Name                            = $vmSize
			Family                          = ''
			Tier                            = ''
			vCPUs                           = 1
			MemoryGB                        = 0
			MaxDataDiskCount                = 9999
			PremiumIO                       = $True
			MaxWriteAcceleratorDisksAllowed = 9999
			MaxNetworkInterfaces            = 9999
			AcceleratedNetworkingEnabled    = $True
			TrustedLaunchDisabled           = $False
			HyperVGenerations               = 'V1,V2'
			DiskControllerTypes             = 'SCSI,NVMe'
			CpuArchitectureType             = 'x64'
			UltraSSDAvailableZones         	= '1 2 3'
		}
	}
}

#--------------------------------------------------------------
function convertTo-Boolean {
#--------------------------------------------------------------
	param (
		$stringOrBool,
		[switch] $nullAsFalse
	)

	if ($Null -eq $stringOrBool) {
		if ($nullAsFalse) {
			return $False
		}
		else {
			return $Null
		}
	}
	if ($stringOrBool -is [boolean]) {
		return $stringOrBool
	}
	elseif ($stringOrBool -is [string]) {
		if ($stringOrBool -eq 'True') {
			return $True
		}
		else {
			return $False
		}
	}
	else {
		write-logFileError "Internal RGCOPY error"
	}
}

#--------------------------------------------------------------
function save-skuProperties {
#--------------------------------------------------------------
# save properties of each VM size
	$script:vmSkus = @{}

	$script:MaxRegionFaultDomains = 3
	if ($skipVmChecks) {
		return
	}

	$savedSub = $script:currentSub
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	# get SKUs for all VM sizes in target
	if ($Null -eq $script:AzComputeResourceSku) {
		$script:AzComputeResourceSku = Get-AzComputeResourceSku `
										-Location		$targetLocation `
										-ErrorAction	'SilentlyContinue'
		test-cmdlet 'Get-AzComputeResourceSku'  "Could not get SKU definition for region '$region'" `
					"You can skip this step using RGCOPY parameter switch 'skipVmChecks'"
	}

	# max fault domain count
	$script:AzComputeResourceSku
	| Where-Object ResourceType -eq 'availabilitySets'
	| Where-Object Name -eq 'Aligned'
	| ForEach-Object {

		$script:MaxRegionFaultDomains = `
			($_.Capabilities | Where-Object Name -eq 'MaximumPlatformFaultDomainCount').Value -as [int]
	}
	if ($script:MaxRegionFaultDomains -le 0) {
		write-logFileWarning "Could not get MaximumPlatformFaultDomainCount for region '$targetLocation'"
		$script:MaxRegionFaultDomains = 2
	}

	# VM SKUs
	$script:AzComputeResourceSku
	| Where-Object ResourceType -eq 'virtualMachines'
	| ForEach-Object {

		$vmSize   = $_.Name
		$vmFamily = $_.Family
		$vmTier   = $_.Tier

		# default SKU properties
		$vCPUs                           = 1
		$MemoryGB                        = 0
		$MaxDataDiskCount                = 9999
		$PremiumIO                       = $True
		$MaxWriteAcceleratorDisksAllowed = 0			# this property is not maintained in all SKUs
		$MaxNetworkInterfaces            = 9999
		$AcceleratedNetworkingEnabled    = $True
		$TrustedLaunchDisabled           = $False
		$HyperVGenerations               = 'V1,V2'		# 'V1, 'V2', 'V1,V2'
		$DiskControllerTypes             = 'SCSI'		# 'SCSI', 'NVMe', 'SCSI,NVMe'
		$CpuArchitectureType             = 'x64'		# 'x64', 'Arm64'
		$UltraSSDAvailableZones          = ''


		# get SKU properties
		foreach($cap in $_.Capabilities) {

			$capValueBoolean = convertTo-Boolean $cap.Value -nullAsFalse

			switch ($cap.Name) {
				'vCPUs'                             {$vCPUs                           = $cap.Value -as [int]; break}
				'MaxDataDiskCount'                  {$MaxDataDiskCount                = $cap.Value -as [int]; break}
				'MemoryGB'                          {$MemoryGB                        = $cap.Value -as [int]; break}
				'PremiumIO'                         {$PremiumIO                       = $capValueBoolean; break}
				'MaxWriteAcceleratorDisksAllowed'   {$MaxWriteAcceleratorDisksAllowed = $cap.Value -as [int]; break}
				'MaxNetworkInterfaces'              {$MaxNetworkInterfaces            = $cap.Value -as [int]; break}
				'AcceleratedNetworkingEnabled'      {$AcceleratedNetworkingEnabled    = $capValueBoolean; break}
				'TrustedLaunchDisabled'             {$TrustedLaunchDisabled           = $capValueBoolean; break}
				'HyperVGenerations'                 {$HyperVGenerations               = $cap.Value; break}
				'DiskControllerTypes'               {$DiskControllerTypes             = $cap.Value; break}
				'CpuArchitectureType'               {$CpuArchitectureType             = $cap.Value; break}
			}
		}

		# zone capabilities
		for ($info = 0; $info -lt $_.LocationInfo.Count; $info++) {
			for ($details = 0; $details -lt $_.LocationInfo[$info].ZoneDetails.Count; $details++) {
				foreach($cap in $_.LocationInfo[$info].ZoneDetails[$details].Capabilities) {

					if (($cap.Name -eq 'UltraSSDAvailable') -and ($cap.Value -eq 'True')) {
						$UltraSSDAvailableZones += " $($_.LocationInfo[$info].ZoneDetails[$details].Name -as [string])"
					}
				}
			}
		}

		# store SKU properties
		$script:vmSkus[$vmSize] = New-Object psobject -Property @{
			Name                            = $vmSize
			Family                          = $vmFamily
			Tier                            = $vmTier
			vCPUs                           = $vCPUs
			MemoryGB                        = $MemoryGB
			MaxDataDiskCount                = $MaxDataDiskCount
			PremiumIO                       = $PremiumIO
			MaxWriteAcceleratorDisksAllowed = $MaxWriteAcceleratorDisksAllowed
			MaxNetworkInterfaces            = $MaxNetworkInterfaces
			AcceleratedNetworkingEnabled    = $AcceleratedNetworkingEnabled
			TrustedLaunchDisabled           = $TrustedLaunchDisabled
			HyperVGenerations               = $HyperVGenerations
			DiskControllerTypes             = $DiskControllerTypes
			CpuArchitectureType             = $CpuArchitectureType
			UltraSSDAvailableZones          = $UltraSSDAvailableZones
		}
	}

	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function compare-quota {
#--------------------------------------------------------------
# check quotas in target region for each VM Family
	if ($skipVmChecks) {
		return
	}

	$savedSub = $script:currentSub
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	# VM quota
	$script:copyVMs.values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		test-vmSize `
			$targetLocation `
			$_.VmZone `
			$_.VmSize
		
		if ($updateMode) {
			test-vmSize `
				$targetLocation `
				$_.VmZone `
				$_.VmSizeOld `
				-1
		}
	}
	test-vmQuota $targetLocation

	# disk quota
	$diskCount = 1
	$script:copyDisks.values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		test-diskSku `
			$targetLocation `
			$_.DiskZone `
			$_.SkuName `
			$_.SizeGB `
			$diskCount
		
		if ($updateMode) {
			test-diskSku `
				$targetLocation `
				$_.DiskZone `
				$_.SkuNameOld `
				$_.SizeGBOld `
				$diskCount `
				-1
		}
	}
	$script:copyDisksNew.values
	| ForEach-Object {

		test-diskSku `
			$targetLocation `
			$_.DiskZone `
			$_.SkuName `
			$_.SizeGB `
			$diskCount
	}
	test-diskQuota $targetLocation
	
	show-quota $targetLocation

	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function import-newVmSizes {
#--------------------------------------------------------------
	# read capabilities from local file
	if ($Null -eq $script:newVmSizes) {

		$path = "$rgcopyPath\newVmSizes.csv"

		# read file content
		$text = Get-Content `
					-Raw `
					-Path $path `
					-ErrorAction 'SilentlyContinue'
		if (!$?) {
			write-logFileWarning "Reading file '$path' failed"
			$script:newVmSizes = @()
		}
		else {
			# convert to object
			$script:newVmSizes = ConvertFrom-Csv `
						-InputObject $text `
						-Delimiter ';' `
						-ErrorAction 'SilentlyContinue' `
						-WarningAction 'SilentlyContinue'
			test-cmdlet 'ConvertFrom-Csv'  "Converting to CSV failed"
		}
	}
}

#--------------------------------------------------------------
function get-usedPercent {
#--------------------------------------------------------------
	param (
		$usage
	)

	if ($null -eq $usage) {
		$used = 0
		$free = 0
		$usedPercent = 100
	}
	else {
		$used = $usage.CurrentValue
		$free = $usage.Limit - $usage.CurrentValue
		if ($usage.Limit -eq 0) {
			$usedPercent = 100
		}
		else {
			$usedPercent = ($usage.CurrentValue * 100 / $usage.Limit) -as [int]
		}
	}

	return $used, $free, $usedPercent
}

#--------------------------------------------------------------
function test-vmSize {
#--------------------------------------------------------------
	param (
		$region,
		$zone,
		$vmSize,
		[int] $factor = 1 # or -1 for removing VM
	)

	if ($Null -eq $script:AzComputeResourceSku) {
		$script:AzComputeResourceSku = Get-AzComputeResourceSku `
										-Location		$region `
										-ErrorAction	'SilentlyContinue'
		test-cmdlet 'Get-AzComputeResourceSku'  "Could not get SKU definition for region '$region'" `
					"You can skip this step using $program parameter switch 'skipVmChecks'"
	}

	$sku = $script:AzComputeResourceSku
			| Where-Object ResourceType -eq 'virtualMachines'
			| Where-Object Name -eq $vmSize

	$neededCPUs = 0
	$vmFamily	= $Null

	# get VM capabilities from Azure
	if ($Null -ne $sku) {
		$vmFamily	= $sku.Family
		$neededCPUs	= ($sku.Capabilities | Where-Object Name -eq 'vCPUs').Value -as [int]
	}

	# get VM capabilities from local file
	elseif($useNewVmSizes) {
		import-newVmSizes
		$myCaps = $script:newVmSizes | Where-Object name -eq $vmSize
		if ($Null -ne $myCaps) {
			$vmFamily   			= $myCaps.vmFamily
			$neededCPUs				= $myCaps.vCPUs -as [int]
		}
	}

	# save required resources
	if (($neededCPUs -gt 0) -and ($Null -ne $vmFamily)) {
		if ($Null -eq $script:resourcesPerFamily) {
			$script:resourcesPerFamily = @{}
		}
		if ($Null -eq $script:resourcesPerFamily[$vmFamily]) {
			$script:resourcesPerFamily[$vmFamily] = @{
				vmFamily	= $vmFamily
				neededCPUs	= ($neededCPUs * $factor)
				neededVMs	= $factor
			}
		}
		else {
			$script:resourcesPerFamily[$vmFamily].neededCPUs += ($neededCPUs * $factor)
			$script:resourcesPerFamily[$vmFamily].neededVMs += $factor
		}
	}

	# no further check for removed VMs
	if ($factor -lt 0) {
		return
	}

	# check region
	if (($Null -eq $sku) -and !$useNewVmSizes) {
		write-logFileWarning "VM Consistency check failed" `
							"VM Size '$vmSize' not found in region '$region'" `
							"You can override this check using file 'newVmSizes.csv' and parameter 'useNewVmSizes'" `
							-stopCondition $True
	}

	if ($Null -ne $sku) {
		# check zone
		if (($Null -ne $sku.LocationInfo.Zones) -and ($zone -gt 0) -and ($zone -notin $sku.LocationInfo.Zones)) {
			write-logFileWarning "VM Consistency check failed" `
								"VM Size '$vmSize' not available in zone $zone of region '$region'" `
								"You can skip this check using $program parameter switch 'skipVmChecks'" `
								-stopCondition $True
		}
	
		# check region restrictions
		$restriction = $sku.Restrictions | Where-Object Type -eq 'Location'
		if ($Null -ne $restriction) {
			if ($region -in $restriction.RestrictionInfo.Locations) {
				write-logFileWarning "VM Consistency check failed" `
								"VM Size '$vmSize' not available in region '$region': $($restriction.ReasonCode)" `
								"You can skip this check using $program parameter switch 'skipVmChecks'" `
								-stopCondition $True
			}
		}
	
		# check zone restrictions
		$restriction = $sku.Restrictions | Where-Object Type -eq 'Zone'
		if ($Null -ne $restriction) {
			if (($zone -gt 0) -and ($zone -in $restriction.RestrictionInfo.Zones)) {
				write-logFileWarning "VM Consistency check failed" `
									"VM Size '$vmSize' not available in in zone $zone of region '$region': $($restriction.ReasonCode)" `
									"You can skip this check using $program parameter switch 'skipVmChecks'" `
									-stopCondition $True
			}
		}
	}
}

#--------------------------------------------------------------
function test-vmQuota {
#--------------------------------------------------------------
	param (
		$region
	)

	if ($Null -eq $script:AzVMUsage) {
		$script:AzVMUsage = Get-AzVMUsage `
							-Location $region `
							-ErrorAction	'SilentlyContinue'
		test-cmdlet 'Get-AzVMUsage'  "Could not get quota for region '$region'" `
					"You can skip this step using $program parameter switch 'skipVmChecks'"
	}

	if ($Null -eq $script:quotaUsage) {
		$script:quotaUsage = @{}
	}
	
	# check all families
	$script:resourcesPerFamily.Values
	| ForEach-Object {
			
		$vmFamily	= $_.vmFamily
		$neededVMs	= $_.neededVMs
		$neededCPUs	= $_.neededCPUs

		if ($Null -ne $vmFamily) {

			# create quota usage of vmFamily
			$usage = $script:AzVMUsage | Where-Object {$_.Name.Value -eq $vmFamily}
			$used, $free, $usedPercent = get-usedPercent $usage
	
			if ($Null -eq $script:quotaUsage[$vmFamily]) {
				$script:quotaUsage[$vmFamily]= @{
					QuotaName	= "CPUs of $vmFamily"
					UsedPercent	= "$usedPercent %"
					Used		= $used
					Free		= $free
					Needed		= $neededCPUs
				}
			}
			else {
				$script:quotaUsage[$vmFamily] += $neededCPUs
			}
	
			# create quota usage of cores
			$usage = $script:AzVMUsage | Where-Object {$_.Name.Value -eq 'cores'}
			$used, $free, $usedPercent = get-usedPercent $usage
	
			if ($Null -eq $script:quotaUsage['cores']) {
				$script:quotaUsage['cores'] = @{
					QuotaName	= "total CPUs of region"
					UsedPercent	= "$usedPercent %"
					Used		= $used
					Free		= $free
					Needed		= $neededCPUs
				}
			}
			else {
				$script:quotaUsage['cores'].Needed += $neededCPUs
			}
	
			# create quota usage of virtualMachines
			$usage = $script:AzVMUsage | Where-Object {$_.Name.Value -eq 'virtualMachines'}
			$used, $free, $usedPercent = get-usedPercent $usage
	
			if ($Null -eq $script:quotaUsage['virtualMachines']) {
				$script:quotaUsage['virtualMachines'] = @{
					QuotaName	= "total VMs of region"
					UsedPercent	= "$usedPercent %"
					Used		= $used
					Free		= $free
					Needed		= $neededVMs
				}
			}
			else {
				$script:quotaUsage['virtualMachines'].Needed += $neededVMs
			}
		}
	}
}

#--------------------------------------------------------------
function test-diskSku {
#--------------------------------------------------------------
	param (
		$region,
		$zone,
		$diskSku,
		$diskSizeGB,
		$diskCount = 1,
		[int] $factor = 1 # or -1 for removing disks
	)

	if ($diskSku -like 'NFS*') {
		return
	}

	if ($Null -eq $script:AzComputeResourceSku) {
		$script:AzComputeResourceSku = Get-AzComputeResourceSku `
										-Location		$region `
										-ErrorAction	'SilentlyContinue'
		test-cmdlet 'Get-AzComputeResourceSku'  "Could not get SKU definition for region '$region'" `
					"You can skip this step using $program parameter switch 'skipVmChecks'"
	}

	$sku = $script:AzComputeResourceSku
			| Where-Object ResourceType -eq 'disks'
			| Where-Object Name -eq $diskSku

	# save required resources
	if ($Null -ne $sku) {		
		if ($Null -eq $script:resourcesPerDiskSku) {
			$script:resourcesPerDiskSku = @{}
		}
		if ($Null -eq $script:resourcesPerDiskSku[$diskSku]) {
			$script:resourcesPerDiskSku[$diskSku] = @{
				diskSku		= $diskSku
				neededGB	= ($diskSizeGB * $factor)
				neededDisks	= ($diskCount * $factor)
			}
		}
		else {
			$script:resourcesPerDiskSku[$diskSku].NeededGB += ($diskSizeGB * $factor)
			$script:resourcesPerDiskSku[$diskSku].NeededDisks += ($diskCount * $factor)
		}
	}

	# no further check for removed disks
	if ($factor -lt 0) {
		return
	}

	# check region
	if ($Null -eq $sku) {
		write-logFileWarning "Disk Consistency check failed" `
							"Disk SKU '$diskSku' not available in region '$region'" `
							"You can skip this check using $program parameter switch 'skipVmChecks'" `
							-stopCondition $True
	}
	$sku = $sku[0]
	
	# check zone
	if (($Null -ne $sku.LocationInfo.Zones) -and ($zone -gt 0) -and ($zone -notin $sku.LocationInfo.Zones)) {
		write-logFileWarning "Disk Consistency check failed" `
							"Disk SKU '$diskSku' not available in zone $zone of region '$region'" `
							"You can skip this check using $program parameter switch 'skipVmChecks'" `
							-stopCondition $True
	}

	# check region restrictions
	$restriction = $sku.Restrictions | Where-Object Type -eq 'Location'
	if ($Null -ne $restriction) {
		if ($region -in $restriction.RestrictionInfo.Locations) {
			write-logFileWarning "Disk Consistency check failed" `
							"Disk SKU '$diskSku' not available in region '$region': $($restriction.ReasonCode)" `
							"You can skip this check using $program parameter switch 'skipVmChecks'" `
							-stopCondition $True
		}
	}

	# check zone restrictions
	$restriction = $sku.Restrictions | Where-Object Type -eq 'Zone'
	if ($Null -ne $restriction) {
		if (($zone -gt 0) -and ($zone -in $restriction.RestrictionInfo.Zones)) {
			write-logFileWarning "Disk Consistency check failed" `
								"Disk SKU '$diskSku' not available in zone $zone of region '$region': $($restriction.ReasonCode)" `
								"You can skip this check using $program parameter switch 'skipVmChecks'" `
								-stopCondition $True
		}
	}

	# check special SKUs
	if ( (!($zone -gt 0)) `
	-and (($diskSku -like 'UltraSSD*') -or ($diskSku -like 'PremiumV2*'))) {
		write-logFileWarning "Disk Consistency check failed" `
							"Disk SKU '$diskSku' must be used for zonal deployment" `
							"Use RGCOPY parameter setVmZone" `
							"You can skip this check using $program parameter switch 'skipVmChecks'" `
							-stopCondition $True
	}
}

#--------------------------------------------------------------
function test-diskQuota {
#--------------------------------------------------------------
	param (
		$region
	)

	if ($Null -eq $script:AzVMUsage) {
		$script:AzVMUsage = Get-AzVMUsage `
							-Location $region `
							-ErrorAction	'SilentlyContinue'
		test-cmdlet 'Get-AzVMUsage'  "Could not get quota for region '$region'" `
					"You can skip this step using $program parameter switch 'skipVmChecks'"
	}

	$script:resourcesPerDiskSku.Values
	| ForEach-Object {

		$diskSku		= $_.diskSku
		$neededGB		= $_.neededGB
		$neededDisks	= $_.neededDisks

		$usageSizeName = ''

		switch ($diskSku) {
			'Standard_LRS' {
				$usageCountName = 'StandardDiskCount'
			}
			'StandardSSD_LRS' {
				$usageCountName = 'StandardSSDDiskCount'
			}
			'Premium_LRS' {
				$usageCountName = 'PremiumDiskCount'
			}
			'PremiumV2_LRS' {
				$usageCountName = 'PremiumV2DiskCount'
				$usageSizeName = 'PremiumV2DiskSizeInGB'
			}
			'UltraSSD_LRS' {
				$usageCountName = 'UltraSSDDiskCount'
				$usageSizeName = 'UltraSSDDiskSizeInGB'
			}
			'StandardSSD_ZRS' {
				$usageCountName = 'StandardSSDZRSDiskCount'
			}
			'Premium_ZRS' {
				$usageCountName = 'PremiumZRSDiskCount'
			}
			default {
				$usageCountName = ''
				write-logFileWarning "Unknown disk SKU '$diskSku'"
			}
		}

		$usageCount = $script:AzVMUsage | Where-Object {$_.Name.Value -eq $usageCountName}
		$usageSize  = $script:AzVMUsage | Where-Object {$_.Name.Value -eq $usageSizeName}

		# init quota
		if ($Null -eq $script:quotaUsage) {
			$script:quotaUsage = @{}
		}

		# quota for disk count
		if ($Null -ne $usageCount) {
			$used, $free, $usedPercent = get-usedPercent $usageCount

			$script:quotaUsage[$usageCountName] = @{
				QuotaName	= "Disk number of $diskSku"
				UsedPercent	= "$usedPercent %"
				Used		= $used
				Free		= $free
				Needed		= $neededDisks -as [int]
			}
		}

		# quota for disk size
		if ($Null -ne $usageSize) {
			$used, $free, $usedPercent = get-usedPercent $usageSize

			$script:quotaUsage[$usageSizeName] = @{
				QuotaName	= "Disk size [GiB] of $diskSku"
				UsedPercent	= "$usedPercent %"
				Used		= $used
				Free		= $free
				Needed		= $neededGB -as [int]
			}
		}
	}
}

#--------------------------------------------------------------
function show-quota {
#--------------------------------------------------------------
	param (
		$region
	)

	$script:quotaUsage.Values
	| ForEach-Object {
		if ($_.Free -lt $_.Needed) {
			$_.QuotaIssue = '<==='
		}
		else {
			$_.QuotaIssue = ''
		}
	}

	# display quota usage
	$script:quotaUsage.Values
	| Where-Object Needed -ne 0
	| Sort-Object QuotaName
	| Select-Object QuotaName, UsedPercent, Used, Free, Needed, QuotaIssue
	| Format-Table
	| write-LogFilePipe -errorLog

	# check quota limit
	if (!$skipVmChecks) {
		foreach ($quota in $script:quotaUsage.Values) {
			if($quota.Free -lt $quota.Needed) {
				write-logFileWarning "Quota check failed" `
									"Subscription quota for '$($quota.QuotaName)' not sufficient in region '$region'" `
									"You can skip this check using $program parameter switch 'skipVmChecks'" `
									-stopCondition $True
			}
		}
	}
}

#--------------------------------------------------------------
function assert-vmsStopped {
#--------------------------------------------------------------
	if ($stopVMsSourceRG `
	-or $allowRunningVMs `
	-or $skipSnapshots `
	-or ($justCopyBlobs.count -ne 0) `
	-or ($justCopySnapshots.count -ne 0)) {
	
		return
	}

	# check for running VM with more than one data disk or volume
	if ($script:VMsRunning -and ($pathPreSnapshotScript.length -eq 0)) {
		write-logFileWarning "Trying to copy non-deallocated VM with more than one data disk or volume" `
							"Asynchronous snapshots could result in data corruption in the target VM" `
							"Stop these VMs manually or use RGCOPY switch 'stopVMsSourceRG' for stopping ALL VMs" `
							-stopCondition $True
	}

	# check for running VM with WA
	$script:copyVMs.Values
	| ForEach-Object {

		if (($pathPreSnapshotScript -eq 0) `
		-and ($_.VmStatus -ne 'VM deallocated') `
		-and ($_.hasWA -eq $True)) {

			write-logFileWarning "Trying to copy non-deallocated VM with Write Accelerator enabled" `
								"snapshots might be incomplete and could result in data corruption in the target VM" `
								"Stop these VMs manually or use RGCOPY switch 'stopVMsSourceRG' for stopping ALL VMs" `
								-stopCondition $True
		}
	}
}

#--------------------------------------------------------------
function show-snapshots {
#--------------------------------------------------------------
	write-stepStart "Display required existing snapshots in resource group '$sourceRG'" -skipLF

	# Get source Snapshots again because additional snapshots have been created
	$script:sourceSnapshots = @( Get-AzSnapshot `
		-ResourceGroupName $sourceRG `
		-ErrorAction 'SilentlyContinue' )
	test-cmdlet 'Get-AzSnapshot'  "Could not get snapshots of resource group '$sourceRG'"
	$script:snapshotNames = $script:sourceSnapshots.Name

	$requiredSnapshots = @()

	# get required snapshots
	$script:copyDisks.Values
	| Where-Object { (($_.DiskSwapNew -eq $True) -or (($_.Skip -ne $True) -and ($_.DiskSwapOld -ne $True))) }
	| ForEach-Object {
		$requiredSnapshots += $_.SnapshotName
	}

	# show all reqired snapshots
	$script:sourceSnapshots
	| Where-Object Name -in $requiredSnapshots
	| Sort-Object TimeCreated
	| Select-Object `
		@{label="TimeCreated"; expression={
			'{0:yyyy-MM-dd HH:mm:ss \U\T\Cz}' -f ($_.TimeCreated).ToLocalTime()
		}}, `
		@{label="Gen"; expression={get-replacedOutput $_.HyperVGeneration $Null}}, `
		@{label="SektorSize"; expression={get-replacedOutput $_.CreationData.LogicalSectorSize $Null}}, `
		@{label="Incremental"; expression={get-replacedOutput $_.Incremental $False}}, `
		@{label="SizeGB"; expression={$_.DiskSizeGB}}, `
		Name
	| Format-Table
	| write-LogFilePipe


	if ($skipSnapshots -and ($pathArmTemplate -notin $boundParameterNames)) {		
		$script:copyDisks.values
		| Where-Object { (($_.DiskSwapNew -eq $True) -or (($_.Skip -ne $True) -and ($_.DiskSwapOld -ne $True))) }
		| ForEach-Object {
	
			$snapshotName = $_.SnapshotName
			$mySnapshot = $script:sourceSnapshots | Where-Object Name -eq $snapshotName
			if ($Null -eq $mySnapshot) {
				write-logFileWarning "Snapshot '$snapshotName' not found" `
									-stopCondition $True
			}
			elseif (($mySnapshot.Incremental -eq $False) `
			   -and ($_.IncrementalSnapshots -eq $True) `
			   -and ($skipSnapshots) ) {
				write-logFileWarning "Wrong property of snapshot '$snapshotName'" `
									"Property 'Incremental' is $($mySnapshot.Incremental), it should be: $($_.IncrementalSnapshots)" `
									"Remove parameter 'skipSnapshots'" `
									-stopCondition $True
			}
		}
	}

	write-stepEnd
}
#--------------------------------------------------------------
function get-replacedOutput {
#--------------------------------------------------------------
	param (
		$value,
		$replace
	)

	if ($value -eq $replace) {
		return '-'
	}
	else {
		return $value
	}
}

#--------------------------------------------------------------
function get-shortOutput {
#--------------------------------------------------------------
	param (
		$value,
		$maxLength
	)

	if ($value.length -eq 0) {
		return '-'
	}
	elseif ($value.length -gt $maxLength) {
		return "$($value.Substring(0,$maxLength)).."
	}
	else {
		return $value
	}
}

#--------------------------------------------------------------
function show-sourceVMs {
#--------------------------------------------------------------
	write-stepStart "Current VMs/disks in Source Resource Group $sourceRG" -skipLF

	$script:copyVMs.Values
	| Sort-Object Name
	| Select-Object `
		@{label="VM name";     expression={get-shortOutput $_.Name 42}}, `
		@{label="Zone";        expression={get-replacedOutput $_.VmZone 0}}, `
		@{label="VM size";     expression={$_.VmSize}}, `
		@{label="DataDisks";   expression={$_.DataDisks.count}}, `
		@{label="MountPoints"; expression={get-replacedOutput $_.MountPoints.count 0}}, `
		@{label="NICs";        expression={$_.NicCount}}, `
		@{label="Status";      expression={$_.VmStatus}}
	| Format-Table
	| write-LogFilePipe

	$script:copyDisks.Values
	| Sort-Object Name
	| Select-Object `
		@{label="Disk Name"; expression={get-shortOutput $_.Name 30}}, `
		@{label="Zone"; expression={get-replacedOutput $_.DiskZone 0}}, `
		@{label="VM Name"; expression={
			$VM = $_.ManagedBy[0]
			if ($_.ManagedBy.count -gt 1) {
				$VM = "{ $VM ...}"
			}
			get-shortOutput $VM 15
		}}, `
		@{label="Cache/WriteAccel"; expression={
			if ($_.VM.length -eq 0) {
				' ' * 16
			}
			elseif ($_.writeAcceleratorEnabled -eq $True) {
				"$(get-replacedOutput $_.Caching 'None') / True".PadLeft(16)
			}
			else {
				"$(get-replacedOutput $_.Caching 'None') / -".PadLeft(16)
			}
		}}, `
		SizeGB, `
		@{label="Size"; expression={$_.SizeTierName}}, `
		@{label="Tier"; expression={get-replacedOutput $_.performanceTierName $_.SizeTierName}}, `
		@{label="Burst"; expression={get-replacedOutput $_.BurstingEnabled $False}}, `
		@{label="ZRS"; expression={
			if ($_.SkuName -like '*ZRS') { 'ZRS' } 
			else { '-' } }}, `
		@{label="Shares"; expression={get-replacedOutput $_.MaxShares 1}}, `
		@{label="Skip"; expression={get-replacedOutput $_.Skip $False}}
	| Format-Table
	| write-LogFilePipe

	write-stepEnd

	if ($rgcopyMode	-ne 'Patch Mode') {
		write-stepStart "Copy method for disks" -skipLF
	
		$script:copyDisks.Values
		| Where-Object Skip -ne $True
		| Sort-Object Name
		| Select-Object `
			@{label="Disk Name"; expression={get-shortOutput $_.Name 30}}, `
			@{label="Swap"; expression={get-shortOutput $_.SwapName 20}}, `
			@{label="Gen"; expression={get-replacedOutput $_.HyperVGeneration ''}}, `
			@{label="NVMe"; expression={get-replacedOutput $_.DiskControllerType ''}}, `
			@{label="Sektor"; expression={get-replacedOutput $_.LogicalSectorSize $Null}}, `
			@{label="SecurityType"; expression={get-replacedOutput $_.SecurityType ''}}, `
			DiskCreationMethod
		| Format-Table
		| write-LogFilePipe
	
		write-stepEnd
	}
}

#--------------------------------------------------------------
function show-targetVMs {
#--------------------------------------------------------------
	# output of VMs
	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| Select-Object `
		@{label="VM name"; expression={
			$name   = get-shortOutput $_.Name 42
			$rename = get-shortOutput $_.Rename 42
			if ($_.Rename.length -eq 0) {
				$name
			}
			else {
				"$rename ($name)"
			}
		}}, `
		@{label="Zone"; expression={get-replacedOutput $_.VmZone 0}}, `
		@{label="VM size"; expression={$_.VmSize}}
	| Format-Table
	| write-LogFilePipe

	# oupput of disks
	$allDisks =  convertTo-array $script:copyDisks.Values
	$allDisks += convertTo-array $script:copyDisksNew.Values

	$allDisks
	| Sort-Object Name
	| Where-Object Skip -ne $True
	| Select-Object `
		@{label="Disk Name"; expression={
			if ($_.Rename.length -eq 0) {
				get-shortOutput $_.Name 30
			}
			else {
				get-shortOutput $_.Rename 30
			}
		}}, `
		@{label="Zone"; expression={get-replacedOutput $_.DiskZone 0}}, `
		@{label="VM"; expression={
			$vm1 = $_.ManagedBy[0]
			if ($Null -ne $vm1) {
				if ($script:copyVMs[$vm1].Rename.length -ne 0) {
					$vm1 = $script:copyVMs[$vm1].Rename
				}
			}
			$VM = $vm1
			if ($_.ManagedBy.count -gt 1) {
				$VM = "{ $VM ...}"
			}
			get-shortOutput $VM 15
		}}, `
		@{label="Cache/WriteAccel"; expression={
			if ($_.VM.length -eq 0) {
				' ' * 16
			}
			elseif ($_.writeAcceleratorEnabled -eq $True) {
				"$(get-replacedOutput $_.Caching 'None') / True".PadLeft(16)
			}
			else {
				"$(get-replacedOutput $_.Caching 'None') / -".PadLeft(16)
			}
		}}, `
		SizeGB, `
		@{label="Size"; expression={$_.SizeTierName}}, `
		@{label="PerfTier"; expression={get-replacedOutput $_.performanceTierName $_.SizeTierName}}, `
		@{label="Burst"; expression={get-replacedOutput $_.BurstingEnabled $False}}, `
		@{label="ZRS"; expression={
			if ($_.SkuName -like '*ZRS') { 'ZRS' } 
			else { '-' } }}, `
		@{label="Shares"; expression={get-replacedOutput $_.MaxShares 1}}
	| Format-Table
	| write-LogFilePipe
}

#--------------------------------------------------------------
function get-remoteSubnets {
#--------------------------------------------------------------
	param (
		$nicName,
		$ipConfigurations
	)

	$vnetRG			= $Null
	$vnetName		= $Null
	$vnetId			= $Null
	$ipAddressName	= $Null

	foreach ($conf in $ipConfigurations) {

		$subnetId = $conf.Subnet.Id
		if ($Null -ne $subnetId) {
			$r = get-resourceComponents $subnetId
			$vnet	= $r.mainResourceName
			$subnet = $r.subResourceName
			$rgName	= $r.resourceGroup
			$subID	= $r.subscriptionID
			$script:collectedSubnets["$rgName/$vnet/$subnet"] = $True

			if ($subID -ne $sourceSubID) {
				write-logFileError "RGCOPY does not support a VNET in a different subscriptions"
									"Subnet '$vnet/$subnet' of NIC '$nicName' is in subscription '$subID'"
			}

			# return $vnetId only for remote RGs
			if ($rgName -ne $sourceRG) {
				write-logFileWarning "Subnet '$vnet/$subnet' of NIC '$nicName' is stored in different resource group:" `
									"Resource Group:  $rgName"

				$vnetId = get-resourceString `
							$subID				$rgName `
							'Microsoft.Network' `
							'virtualNetworks'	$vnet
			}

			# always return $vnetRG, $vnetName
			$vnetRG = $rgName
			$vnetName = $vnet
		}

		$publicIpAddressId = $conf.PublicIpAddress.Id
		if ($Null -ne $publicIpAddressId) {
			$r = get-resourceComponents $publicIpAddressId
			$ipAddressName	= $r.mainResourceName
		}
	}

	return $vnetRG, $vnetName, $vnetId, $ipAddressName
}

#--------------------------------------------------------------
function update-disksFromVM {
#--------------------------------------------------------------
	$script:copyVMs.Values
	| ForEach-Object {

		$vmName = $_.Name

		# update OS disk
		$diskName = $_.OsDisk.Name
		if ($Null -eq $script:copyDisks[$diskName]) {
			write-logFileWarning "Disk '$diskName' of VM '$vmName' not found in source resource group" `
								"Move all disks to the resource group that contains the VMs" `
								-stopCondition $(!($_.Skip))
		}
		else {
			if ($_.Skip -eq $True) {
				$script:copyDisks[$diskName].Skip = $True
			}
			if ($_.Generalized -eq $True) {
				$script:copyDisks[$diskName].Image = $True
			}
			if ($_.OsDisk.WriteAcceleratorEnabled -eq $True) {
				$script:copyDisks[$diskName].WriteAcceleratorEnabled = $True
			}
			$script:copyDisks[$diskName].VM = $vmName
			$script:copyDisks[$diskName].Caching = $_.OsDisk.Caching
			$script:copyDisks[$diskName].DiskControllerType = $_.DiskControllerType

			# update OS Type
			if ($script:copyDisks[$diskName].OsType.length -ne 0) {
				$_.OsDisk.OsType = $script:copyDisks[$diskName].OsType
			}
			# update Hyper-V generation
			if ($script:copyDisks[$diskName].HyperVGeneration.length -ne 0) {
				$_.OsDisk.HyperVGeneration = $script:copyDisks[$diskName].HyperVGeneration
			}
		}

		# update data disks
		foreach($dataDisk in $_.DataDisks) {
			$diskName = $dataDisk.Name
			if ($Null -eq $script:copyDisks[$diskName]) {
				write-logFileWarning "Disk '$diskName' of VM '$vmName' not found in source resource group" `
									"Move all disks to the resource group that contains the VMs" `
									-stopCondition $(!($_.Skip))
			}
			else {
				if ($_.Skip -eq $True) {
					$script:copyDisks[$diskName].Skip = $True
				}
				if ($_.Generalized -eq $True) {
					$script:copyDisks[$diskName].Image = $True
				}
				if ($dataDisk.WriteAcceleratorEnabled -eq $True) {
					$script:copyDisks[$diskName].WriteAcceleratorEnabled = $True
				}
				$script:copyDisks[$diskName].VM = $vmName
				$script:copyDisks[$diskName].Caching = $dataDisk.Caching
			}
		}
	}

	# do not skip shared disks
	$script:copyDisks.Values
	| ForEach-Object {

		if (($_.Skip -eq $True) -and ($_.ManagedBy.count -gt 1)) {
			$_.Skip = $False
		}
	}
}

#--------------------------------------------------------------
function get-managingVMs {
#--------------------------------------------------------------
	param (
		$ManagedByExtended,
		$diskName
	)

	$vmNames = @()

	foreach ($id in $ManagedByExtended) {
		$r = get-resourceComponents $id

		if ($r.subscriptionID -ne $sourceSubID) {
			write-logFileWarning "Disk '$diskName' is managed by a resource in a different subscription"
			continue
		}

		if ($r.resourceGroup -ne $sourceRG) {
			write-logFileWarning "Disk '$diskName' is managed by a resource in a different resource group"
			continue
		}

		if ($r.mainResourceType -ne 'virtualMachines') {
			write-logFileWarning "Disk '$diskName' is managed by a resource of type '$($r.mainResourceType)'"
			continue
		}

		$vmNames += $r.mainResourceName
	}
	Write-Output -NoEnumerate $vmNames
}

#--------------------------------------------------------------
function get-NewCloneName {
#--------------------------------------------------------------
# maxLength:
# 80 for discs
# 80 for NICs
# 15 for Windows VMs
# 64 for Linux VMs

# $script:cloneNumber is script parameter

	param (
		$name
		,$maxLength
		# ,$cloneNumber
	)

	if ($name -notmatch '\-clone\d*$') {
		$head = $name
	}
	# remove "-clone\d*" at the end of the original name
	else {
		$head = $name.SubString(0,($name.length - $matches[0].length))
	}

	$tail = "-clone$cloneNumber"  

	# shorten name
	if ($head.length -gt ($maxLength - $tail.length)) {
		$len = (($maxLength - $tail.length), $head.Length | Measure-Object -Minimum).Minimum
		$head= $head.SubString(0,$len)
	}

	return "$head$tail"
}

#--------------------------------------------------------------
function save-cloneNames {
#--------------------------------------------------------------
	if (!$cloneMode) {
		return
	}

	if ('setVmName' -in $boundParameterNames) {
		$script:renameDisks = $True
		write-logFileWarning "Parameter 'renameDisks' is used because 'setVmName' was set"
	}

	$script:copyPublicIPs = @{}

	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/publicIPAddresses'
	| ForEach-Object {

		$script:copyPublicIPs[$_.name] = @{
			Name = $_.name
		}
	}

	$maxTries = 100
	$script:cloneNumber--
	do {
		$maxTries--
		$script:cloneNumber++
		$allNames = @()
		$allClones = @()

		$script:copyPublicIPs.values
		| ForEach-Object {
	
			$_.Rename = get-NewCloneName $_.Name 80
			$allClones += $_.Rename
			$allNames += $_.Name
		}

		$script:copyDisks.values
		| ForEach-Object {
	
			$_.Rename = get-NewCloneName $_.Name 80
			$allClones += $_.Rename
			$allNames += $_.Name
		}
	
		$script:copyVMs.values
		| ForEach-Object {
	
			if ($_.OsDisk.OsType -ne 'linux') {
				$maxLength = 15
			}
			else {
				$maxLength = 64
			}

			if ($_.Rename.length -ne 0) {
				$_.CloneName = $_.Rename
			}
			else {
				$_.CloneName = get-NewCloneName $_.Name $maxLength
			}

			$allClones += $_.CloneName
			$allNames += $_.Name
		}
	
		$script:copyNICs.values
		| ForEach-Object {
	
			$_.Rename = get-NewCloneName $_.NicName 80
			$allClones += $_.Rename
			$allNames += $_.NicName
		}

		$found = $False
		foreach ($clone in $allClones) {
			if ($clone -in $allNames) {
				$found = $True
				if ($maxtries -lt 5) {
					write-logFileWarning "Name '$clone' already in use"
				}
				break
			}
		}
		
	} while ($found -and ($maxTries -gt 0))

	if ($found) {
		write-logFileError "Could not get a unique clone name for all resources"
	}

	$script:copyVMs.values
	| ForEach-Object {

		$_.Rename = $_.CloneName
	}
}

#--------------------------------------------------------------
function save-copyDisks {
#--------------------------------------------------------------
	# process disks
	$script:copyDisks = @{}
	$script:copyDisksNew = @{}

	foreach ($disk in $script:sourceDisks) {

		$diskName			= $disk.Name
		$sku				= $disk.Sku.Name -as [string]
		$logicalSectorSize	= $disk.CreationData.LogicalSectorSize
		$securityType		= $disk.SecurityProfile.SecurityType -as [string]

		#--------------------------------------------------------------
		# copy mode
		if ($useBlobCopy) {
			# blob copy explicitly requested (only possible for OSS version of RGCOPY)
			$blobCopy 				= $True
			$snapshotCopy 			= $False
		}
		elseif ($useSnapshotCopy) {
			# snapshot copy explicitly requested
			$snapshotCopy 			= $True
			$blobCopy 				= $False
		}
		elseif ($sourceLocation -ne $targetLocation) {
			# snapshot copy is default for copying into different region
			$snapshotCopy 			= $True
			$blobCopy 				= $False
		}
		else {
			# default
			$snapshotCopy 			= $False
			$blobCopy 				= $False	
		}

		# different user or tenant
		if (($sourceSubUser   -ne $targetSubUser) `
		-or ($sourceSubTenant -ne $targetSubTenant)) {

			$blobCopy 			= $True
			$snapshotCopy 		= $False
		}

		# BLOB copy does not work for BLOBs larger than 4TiB using Start-AzStorageBlobCopy
		if (!$skipWorkarounds) {
			if ($blobCopy -and ($disk.DiskSizeGB -gt 4096)) {

				$blobCopy			= $False
				$snapshotCopy 		= $True

				if (!$messageShown) {
					$messageShown = $True
					write-logFileWarning "Using SNAPSHOT copy rather than BLOB copy for disks larger than 4TiB"
				}
			}
		}

		#--------------------------------------------------------------
		# snapshot mode
		if ($useIncSnapshots `
		-or $snapshotCopy `
		-or ($sku -in @('UltraSSD_LRS', 'PremiumV2_LRS'))) { `

			$incrementalSnapshots	= $True
		}
		else {
			$incrementalSnapshots	= $False
		}

		# workaraound for Azure bugs:

		# 1. BLOB COPY issue (Grant-AzSnapshotAccess)
		#--------------------------------------------------------------
		# Grant-AzSnapshotAccess fails for disks with logical sector size 4096 
		#   BadRequest ErrorMessage: Accessing disk or snapshot with a logical
     	#   sector size of 4096 requires specifying the file format. Set the fileFormat property to VHDX.
		# -> use REST API instead
		# implemented in function grant-access
		

		# 2. SNAPSHOT COPY issue (New-AzSnapshot)
		#--------------------------------------------------------------
		# security type trusted launch gets lost during snapshot copy
		# -> use REST API for snapshot copy when security type is set
		# implemented in function copy-snapshots 


		# 3. disk creation issue (ARM template)
		#-------------------------------------------------------------- 
		# security type trusted launch cannot be set when creating disks from BLOB in ARM template
		#   ErrorMessage: Security type of VM is not compatible with the security type of attached OS Disk.
		# -> create disks from BLOB outside ARM template
		if (!$skipWorkarounds) {
			if (($blobCopy -eq $True) -and ($securityType.Length -ne 0)) {
				if (!$script:createDisksManually) {
					$script:createDisksManually = $True

					write-logFileWarning "All disks will be created before deploying template" `
										"because ARM template does not support property 'securityType'" `
										"which is needed to create disk '$diskName' from BLOB"
		
					if (!$script:useBicep) {
						write-logFileWarning "Parameter 'useBicep' has been set to `$True" `
											"because disks will be created before deploying template"
		
						$script:useBicep = $True
					}
				}
			}
		}
		
		# 4. disk creation issue (New-AzDisk)
		# security type trusted launch cannot be set when creating disks from BLOB using New-AzDisk
		#-------------------------------------------------------------- 
		# -> use REST API for creating disk
		# implemented in function new-disks


		# 5. disk creation issue (New-AzDisk)
		# disk controller type NVMe cannot be set when creating disks from BLOB/snapshot using New-AzDisk
		#-------------------------------------------------------------- 
		# -> use REST API for creating disk
		# implemented in function new-disks

		# get bursting
		$burstingEnabled = $disk.BurstingEnabled
		if ($Null -eq $burstingEnabled) {
			$burstingEnabled = $False
		}

		# calculate Tier
		$SizeGB					= $disk.DiskSizeGB
		$SizeTierName			= get-diskTier $SizeGB $sku
		$SizeTierGB				= get-diskSize $SizeTierName
		$performanceTierName	= $disk.Tier -as [string]
		if (($sku -like 'Premium_?RS') -and ($performanceTierName.length -eq 0)) {
			$performanceTierName = $SizeTierName
		}
		elseif ($sku -notlike 'Premium_?RS') {
			$performanceTierName = $Null
		}
		$performanceTierGB		= get-diskSize $performanceTierName

		# get maxShares
		$maxShares = $disk.MaxShares
		if ($Null -eq $maxShares) {
			$maxShares = 1
		}

		# get VM names
		$ManagedBy = get-managingVMs $disk.ManagedByExtended $disk.Name
		if ($ManagedBy.count -eq 0) {
			$ManagedBy = get-managingVMs $disk.ManagedBy $disk.Name
		}

		# calculate snapshot name
		$snapshotName = "$($disk.Name).$snapshotExtension"
		$len = (80, $snapshotName.Length | Measure-Object -Minimum).Minimum
		$snapshotName = $snapshotName.SubString(0,$len)
		$snapshotName = $snapshotName -replace '\.$', '_'

		# get zone
		if ($disk.Zones.count -eq 0) {
			$diskZone = 0
		}
		else {
			$diskZone = $disk.Zones[0] -as [int]
		}
		if ($diskZone -notin @(1,2,3)) {
			$diskZone = 0
		}

		# OsType
		if ($Null -eq $disk.OsType) {
			$osType = $Null
		}
		else {
			$osType = $disk.OsType -as [string]
		}

		# IO performance
		$DiskIOPSReadWrite		= $disk.DiskIOPSReadWrite
		$DiskMBpsReadWrite		= $disk.DiskMBpsReadWrite
		if ($sku -notin @('UltraSSD_LRS', 'PremiumV2_LRS')) {
			$DiskIOPSReadWrite	= 0
			$DiskMBpsReadWrite	= 0
		}

		# save source disk
		$script:copyDisks[$disk.Name] = @{
			Name        			= $diskName
			SwapName				= $Null
			SnapshotName			= $snapshotName
			SnapshotId				= "/subscriptions/$sourceSubID/resourceGroups/$sourceRG/providers/Microsoft.Compute/snapshots/$snapshotName"
			IncrementalSnapshots	= $incrementalSnapshots
			SnapshotCopy			= $snapshotCopy
			SnapshotSwap			= $False
			DiskSwapOld				= $False
			DiskSwapNew				= $False
			BlobCopy				= $blobCopy
			Rename					= ''
			VM						= '' 		# will be updated below by VM info
			ManagedBy				= $ManagedBy
			MaxShares				= $maxShares
			Skip					= $False 	# will be updated below by VM info
			image					= $False 	# will be updated below by VM info
			Caching					= 'None'	# will be updated below by VM info
			DiskControllerType		= ''		# will be updated below by VM info
			WriteAcceleratorEnabled	= $False 	# will be updated below by VM info
			AbsoluteUri 			= ''		# access token for source snapshot
			DelegationToken 		= ''		# access token for target BLOB
			SkuName     			= $sku
			VmRestrictions			= $False	# will be updated later
			DiskIOPSReadWrite		= $DiskIOPSReadWrite  #e.g. 1024
			DiskMBpsReadWrite		= $DiskMBpsReadWrite  #e.g. 4
			BurstingEnabled			= $burstingEnabled
			SizeGB      			= $SizeGB					#e.g. 127
			SizeTierName			= $SizeTierName				#e.g. P10
			SizeTierGB				= $SizeTierGB				#e.g. 128	# maximum disk size for current tier
			performanceTierName		= $performanceTierName		#e.g. P15	# configured performance tier
			performanceTierGB		= $performanceTierGB		#e.g. 256	# size of configured performance tier
			OsType      			= $osType
			SecurityType			= $securityType
			HyperVGeneration		= $disk.HyperVGeneration -as [string]
			Id          			= $disk.Id
			Location    			= $disk.Location -as [string]
			Tags					= $disk.Tags
			DiskZone				= $diskZone
			LogicalSectorSize		= $logicalSectorSize
			TokenRestAPI			= $Null
			DiskCreationMethod		= $Null
		}
	}
}

#--------------------------------------------------------------
function save-copyVMs {
#--------------------------------------------------------------
	$script:copyVMs = @{}
	foreach ($vm in $script:sourceVMs) {

		$vmName = $vm.Name
		$hasWA = $False

		# get data disks
		$DataDisks = @()
		foreach ($disk in $vm.StorageProfile.DataDisks) {

			$DataDisks += @{
				Name					= $disk.Name
				Caching 				= $disk.Caching	-as [string]	# Disks will be updated later using this info
				WriteAcceleratorEnabled = $disk.WriteAcceleratorEnabled # Disks will be updated later using this info
				Lun						= $disk.Lun
			}
			if ($disk.WriteAcceleratorEnabled -eq $True) { $hasWA = $True }

			# check if data disk is in same resource group
			$r = get-resourceComponents $disk.ManagedDisk.Id
			if (($r.subscriptionID -ne $sourceSubID) -or `
				($r.resourceGroup -ne $sourceRG)) {
					write-logFileWarning "Disk '$($disk.Name)' is stored in different resource group:" `
										"Subscription ID: $($r.subscriptionID)" `
										"Resource Group:  $($r.resourceGroup)"
			}
		}

		# get OS disk
		$disk = $vm.StorageProfile.OsDisk
		$OsDisk = @{
			Name 						= $disk.Name
			Caching						= $disk.Caching	-as [string]	# Disks will be updated later using this info
			WriteAcceleratorEnabled		= $disk.WriteAcceleratorEnabled # Disks will be updated later using this info
			OsType						= '' # will be updated later using disk info
			HyperVGeneration			= '' # will be updated later using disk info
		}
		if ($disk.WriteAcceleratorEnabled -eq $True) { $hasWA = $True }

		# check if OS disk is in same resource group
		$r = get-resourceComponents $disk.ManagedDisk.Id
		if (($r.subscriptionID -ne $sourceSubID) -or `
			($r.resourceGroup -ne $sourceRG)) {
				write-logFileWarning "Disk '$($disk.Name)' is stored in different resource group:" `
									"Subscription ID: $($r.subscriptionID)" `
									"Resource Group:  $($r.resourceGroup)"
		}

		# get zone
		if ($vm.Zones.count -eq 0) {
			$vmZone = 0
		}
		else {
			$vmZone = $vm.Zones[0] -as [int]
		}
		if ($vmZone -notin @(1,2,3)) {
			$vmZone = 0
		}

		# get PlatformFaultDomain
		if ($Null -eq $vm.PlatformFaultDomain) {
			$platformFaultDomain = -1
		}
		else {
			$platformFaultDomain = $vm.PlatformFaultDomain -as [int]
		}		

		$script:copyVMs[$vmName] = @{
			Group					= 0
			Name        			= $vmName
			Id						= $vm.Id
			Rename					= ''
			Skip					= $(if ($vmName -in $skipVMs) {$True} else {$False})
			Generalized 			= $False
			GeneralizedUser			= $Null
			GeneralizedPasswd		= $Null
			VmSize					= $vm.HardwareProfile.VmSize -as [string]
			VmZone					= $vmZone # -in @(0,1,2,3)
			OsDisk					= $OsDisk
			DataDisks				= $DataDisks
			NewDataDiskCount		= $DataDisks.count
			NicCount				= $vm.NetworkProfile.NetworkInterfaces.count
			NicCountAccNw			= 0		# will be updated later
			NicNames 				= @()	# will be updated later
			IpNames 				= @()	# will be updated later
			VmPriority				= 2147483647 # default: highest INT number = lowest priority
			VmStatus				= $vm.PowerState -as [string]
			MergeNetSubnet			= $Null
			hasWA					= $hasWA
			Tags 					= $vm.Tags
			MountPoints				= @()
			VmssName				= $Null
			AvsetName 				= $Null
			Ppgname					= $Null
			PlatformFaultDomain 	= $platformFaultDomain
			DiskControllerType		= $vm.StorageProfile.DiskControllerType -as [string]
			SecurityType			= $vm.SecurityProfile.SecurityType -as [string]
		}
	}
}

#--------------------------------------------------------------
function save-copyNICs {
#--------------------------------------------------------------
	$script:remoteNames = @{}
	$script:copyNICs = @{}

	# get NICs from source RG
	foreach ($nic in $script:sourceNICs) {
		$nicName = $nic.Name
		$acceleratedNW = $nic.EnableAcceleratedNetworking
		if ($Null -eq $acceleratedNW) {
			$acceleratedNW = $False 
		}

		get-newRemoteName 'networkInterfaces' $sourceRG $nicName | Out-Null

		$vnetRG, $vnetName, $vnetId, $ipAddressName = get-remoteSubnets $nicName $nic.IpConfigurations
		$vnetNameNew = get-newRemoteName 'virtualNetworks' $vnetRG $vnetName

		# for BICEP, no duplicate resource names are allowed
		if ($useBicep) {
			$vnetNameNew = $vnetName
			$vnetRG = $sourceRG
			$vnetId = $Null
		}

		# save NIC
		$script:copyNICs[$nicName] = @{
			NicName 					= $nicName
			NicNameNew					= $nicName		# not changed
			NicRG						= $sourceRG		# not changed
			VnetName					= $vnetName
			VnetNameNew					= $vnetNameNew
			VnetRG						= $vnetRG
			VmName						= $Null # will be updated below
			EnableAcceleratedNetworking	= $acceleratedNW
			RemoteNicId					= $Null
			RemoteVnetId				= $vnetId
			IpAddressName				= $ipAddressName
			CloneName					= $Null
		}
	}

	# Update NICs from VMs
	# get NICs from other RGs
	foreach ($vm in $script:sourceVMs) {
		$vmName = $vm.Name
		foreach ($nicId in $vm.NetworkProfile.NetworkInterfaces.Id) {

			$r = get-resourceComponents $nicId
			$nicName = $r.mainResourceName
			$nicRG   = $r.resourceGroup
			$subID   = $r.subscriptionID

			if ($subID -ne $sourceSubID) {
				write-logFileError "RGCOPY does not support a NIC in a different subscriptions"
									"NIC '$nicName' of VM '$vmName' is in subscription '$subID'"
			}

			#--------------------------------------------------------------
			# local NIC
			if ($nicRG -eq $sourceRG) {
				$script:copyNICs[$nicName].VmName = $vmName
			}

			#--------------------------------------------------------------
			# remote NIC
			else {
				write-logFileWarning "NIC '$nicName' of VM '$vmName' is stored in different resource group:" `
									"Resource Group:  $nicRG"

				# get NIC from different resource group
				$remoteNIC = Get-AzNetworkInterface `
								-Name $nicName `
								-ResourceGroupName $nicRG `
								-ErrorAction 'SilentlyContinue'
				test-cmdlet 'Get-AzNetworkInterface'  "Could not get NIC '$nicName' of resource group '$nicRG'"

				# add NIC to $script:sourceNICs
				$script:sourceNICs += $remoteNIC

				$acceleratedNW = $remoteNIC.EnableAcceleratedNetworking
				if ($Null -eq $acceleratedNW) {
					$acceleratedNW = $False 
				}

				$nicNameNew = get-newRemoteName 'networkInterfaces' $nicRG $nicName

				$vnetRG, $vnetName, $vnetId, $ipAddressName = get-remoteSubnets $nicName $remoteNIC.IpConfigurations
				$vnetNameNew = get-newRemoteName 'virtualNetworks' $vnetRG $vnetName

				# for ARM, remote NICs and VNETs are renamed
				if (!$useBicep) {
					$script:copyNICs[$nicNameNew] = @{
						NicName 					= $nicName
						NicNameNew					= $nicNameNew
						NicRG						= $nicRG
						VnetName					= $vnetName
						VnetNameNew					= $vnetNameNew
						VnetRG						= $vnetRG
						VmName						= $vmName
						EnableAcceleratedNetworking	= $acceleratedNW
						RemoteNicId					= $nicId
						RemoteVnetId				= $vnetId
						IpAddressName				= $ipAddressName
						CloneName					= $Null
					}
				}

				# for BICEP, no duplicate resource names are allowed
				else {
					$script:copyNICs[$nicName] = @{	# <-------
						NicName 					= $nicName
						NicNameNew					= $nicName # <-------
						NicRG						= $sourceRG
						VnetName					= $vnetName
						VnetNameNew					= $vnetName
						VnetRG						= $sourceRG
						VmName						= $vmName
						EnableAcceleratedNetworking	= $acceleratedNW
						RemoteNicId					= $Null
						RemoteVnetId				= $Null
						IpAddressName				= $ipAddressName
						CloneName					= $Null
					}
				}
			}
		}
	}
	
	#  update VMs from NICs
	foreach ($nic in $script:copyNICs.Values) {
		$vmName = $nic.VmName
		if ($Null -ne $vmName) {
			# update NicCountAccNw
			if ($nic.EnableAcceleratedNetworking -eq $True) {
				$script:copyVMs[$vmName].NicCountAccNw++
			}

			# update NicNames
			$script:copyVMs[$vmName].NicNames += $nic.NicNameNew

			# update IpNames
			if ($Null -ne $nic.IpAddressName) {
				$script:copyVMs[$vmName].IpNames += $nic.IpAddressName
			}
		}
	}
}

#--------------------------------------------------------------
function get-newRemoteName {
#--------------------------------------------------------------
	param (
		$resType,
		$resGroup,
		$resName
	)
	
	$resKey = "$resType/$resGroup/$resName"

	# new name already saved
	if ($Null -ne $script:remoteNames[$resKey]) {
		return $script:remoteNames[$resKey].newName
	}

	# max length of resource name
	switch ($resType) {
		'networkInterfaces' {
			$maxLength = 80
		}
		'virtualNetworks' {
			$maxLength = 64
		}
		Default {
			$maxLength = 64
		}
	}

	$existingNames = ($script:remoteNames.values | Where-Object resType -eq $resType).newName

	# get postfix for new name
	$postfix = $resName -replace '^remote\d*-', ''
	if ($postfix.length -eq 0) {
		$postfix = $resType
	}

	# get full new name
	$newName = "remote-$postfix"
	# truncate name
	$len = ($maxLength, $newName.Length | Measure-Object -Minimum).Minimum
	$newName = $newName.SubString(0,$len)
	$i = 1
	while ($newName -in $existingNames) {
		$i++
		$newName = "remote$i-$postfix"
		# truncate name
		$len = ($maxLength, $newName.Length | Measure-Object -Minimum).Minimum
		$newName = $newName.SubString(0,$len)
	}

	# no rename needed for source RG
	if ($resGroup -eq $sourceRG) {
		$newName = $resName
	}
	else {
		$script:remoteRGs += $resGroup
	}
	
	# save new name
	$script:remoteNames[$resKey] = @{
		resType		= $resType
		resGroup	= $resGroup
		resName		= $resName
		newName		= $newName
	}

	return $newName
}

#--------------------------------------------------------------
function get-targetVMs {
#--------------------------------------------------------------
	if ($Null -ne $script:targetVMs) {
		return
	}

	$script:targetVMs = convertTo-array ( Get-AzVM `
											-ResourceGroupName $targetRG `
											-status `
											-WarningAction	'SilentlyContinue' `
											-ErrorAction 'SilentlyContinue' ) -saveError
	test-cmdlet 'Get-AzVM'  "Could not get VMs of resource group $targetRG"

	get-allFromTags $script:targetVMs $targetRG
}



#--------------------------------------------------------------
function get-remoteResourceStruct {
#--------------------------------------------------------------
	param (
		$id,
		[switch] $disallowed
	)

	if ($Null -eq $id) {
		return
	}

	# parse Id
	$r = get-resourceComponents $id
	$subscriptionID 	= $r.subscriptionID
	$resourceGroup		= $r.resourceGroup
	$mainResourceType	= $r.mainResourceType
	$mainResourceName	= $r.mainResourceName

	# no resources from different subscriptions allowed
	if ($subscriptionID -ne $sourceSubID) {
		write-logFileError "Resource '$mainResourceName' of type '$mainResourceType' is in wrong subscription" `
							"Subscription ID is $subscriptionID" `
							"Subscription ID of source RG is $sourceSubID"
	}

	# resource is in different resource group
	if ($resourceGroup -ne $sourceRG) {

		if ($disallowed) {
			write-logFileError "Resource '$mainResourceName' of type '$mainResourceType' is in wrong resource group" `
				"Resource group is '$resourceGroup'" `
				"Source RG is '$sourceRG'"
		}
		else {
			# collect resource
			return @{
				ResourceGroupName	= $resourceGroup
				Name 				= $mainResourceName
			}
		}
	}
}

#--------------------------------------------------------------
function get-sourceVMs {
#--------------------------------------------------------------

	# Get source disks
	$script:sourceDisks = @( Get-AzDisk `
								-ResourceGroupName $sourceRG `
								-ErrorAction 'SilentlyContinue' )
	test-cmdlet 'Get-AzDisk'  "Could not get disks of resource group $sourceRG"

	# Get source vms
	$script:sourceVMs = @( Get-AzVM `
								-ResourceGroupName $sourceRG `
								-status `
								-WarningAction	'SilentlyContinue' `
								-ErrorAction 'SilentlyContinue' )
	test-cmdlet 'Get-AzVM'  "Could not get VMs of resource group $sourceRG"

	# Get source NICs
	$script:sourceNICs = @( Get-AzNetworkInterface `
								-ResourceGroupName $sourceRG `
								-ErrorAction 'SilentlyContinue' )
	test-cmdlet 'Get-AzNetworkInterface'  "Could not get NICs of resource group $sourceRG"

	# Get source Snapshots
	$script:sourceSnapshots = @( Get-AzSnapshot `
								-ResourceGroupName $sourceRG `
								-ErrorAction 'SilentlyContinue' )
	test-cmdlet 'Get-AzSnapshot'  "Could not get snapshots of resource group '$sourceRG'"
	$script:snapshotNames = $script:sourceSnapshots.Name
	
	# save internal structures
	$script:collectedSubnets = @{}
	$script:remoteRGs = @()
	save-copyDisks
	save-copyVMs
	save-copyNICs

	test-vmParameter 'skipDisks' $skipDisks -checkSyntaxOnly
	test-vmParameter 'skipSecurityRules' $skipSecurityRules -checkSyntaxOnly
	test-vmParameter 'keepTags' $keepTags -checkSyntaxOnly
	test-vmParameter 'skipVMs' $script:skipVMs | Out-Null

	update-paramCloneVMs
	update-paramSetVmMerge
	update-paramSkipVMs
	update-paramGeneralizedVMs

	# Azure Monitor needed when using Data Collection Endpoints
	if ($monitorRG.length -ne 0) {
		$script:skipExtensions = $False
	}

	# run after update-paramSkipVMs
	$script:installExtensionsSapMonitor = convertTo-array (
		test-vmParameter 'installExtensionsSapMonitor'   $script:installExtensionsSapMonitor
	)
	$script:generalizedVMs = convertTo-array (
		test-vmParameter 'generalizedVMs' $script:generalizedVMs
	)
	$script:cloneVMs = convertTo-array (
		test-vmParameter 'cloneVMs' $script:cloneVMs
	)
	$script:patchVMs = convertTo-array (
		test-vmParameter 'patchVMs' $script:patchVMs
	)

	# run after update-paramSkipVMs
	update-disksFromVM

	update-paramSnapshotVolumes
	update-paramCreateVolumes
	update-paramCreateDisks
	update-paramSetVmDeploymentOrder
	update-paramSetVmTipGroup
	update-paramSetVmName
	update-paramSkipDisks
	update-paramSwapSnapshot4disk
	save-skuProperties
	get-DiskCreationMethod
	show-sourceVMs

	if (!$cloneOrMergeMode) {
		get-allFromTags $script:sourceVMs $sourceRG
	}
}

#--------------------------------------------------------------
function get-DiskCreationMethod {
#--------------------------------------------------------------
	$script:snapshotCopyNeeded	= $False
	$script:blobCopyNeeded		= $False

	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		# # wait for incremental snapshot completion required?
		# # This should not be neccesary anymore in the future
		# if (!$skipWorkarounds) {

		# 	# Dual deployment needed?
		# 	if ($_.incrementalSnapshots -and !$script:createDisksManually) {

		# 		$script:dualDeployment = $True
		# 		# useBicep set?
		# 		if (!$script:useBicep) {
		# 			write-logFileWarning "Parameter 'useBicep' has been set to `$True" `
		# 								"because disks have to be created in a separate template" `
		# 								"(disk '$($_.Name)' with SKU '$($_.SkuName)' needs incremental snapshots)"
	
		# 			$script:useBicep = $True
		# 		}
		# 	}
		# }

		if ($dualDeployment) {
			$script:useBicep = $True
		}

		# snapshot copy needed?
		if ($_.SnapshotCopy) {
			$script:snapshotCopyNeeded = $True
		}

		# BLOB copy needed?
		if ($_.BlobCopy) {
			$script:blobCopyNeeded = $True
		}

		# does snapshot exist?
		if ( ('skipSnapshots' -in $boundParameterNames) `
		-and ($_.SnapshotName -notin $script:snapshotNames)) {

			write-logFileWarning "Snapshot '$($_.SnapshotName)' not found" `
								"Remove parameter 'skipSnapshots'" `
								-stopCondition $True
		}
	}

	# save disk creation method
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		if ($_.SnapshotSwap) {
			$diskCreationMethod = '(SNAPSHOT)'
		}
		elseif ($_.IncrementalSnapshots) {
			$diskCreationMethod = 'inc. SNAP.'
			if ('skipSnapshots' -in $boundParameterNames) {
				$diskCreationMethod = '(inc. SNAP.)'
			}
		}
		else {
			$diskCreationMethod = 'full SNAP.'
			if ('skipSnapshots' -in $boundParameterNames) {
				$diskCreationMethod = '(full SNAP.)'
			}
		}

		if ($_.BlobCopy) {
			$diskCreationMethod += ' -> create BLOB  '
		}

		if ($_.SnapshotCopy) {
			$diskCreationMethod += ' -> copy SNAP.'
		}

		# create disks manually
		if ($script:createDisksManually) {
			if ((($_.SecurityType.Length -ne 0) -and $_.BlobCopy) `
			-or ($_.DiskControllerType -eq 'NVME') `
			-or $useRestAPI) {
				$diskCreationMethod += ' -> REST-API'
			}
			else {
				$diskCreationMethod += ' -> New-AzDisk'
			}
		}

		# create disks in separate template
		elseif ($script:dualDeployment) {
			$diskCreationMethod += ' -> 2nd. BICEP template'
		}

		# create disks in main template
		else {
			if ($useBicep) {
				$diskCreationMethod += ' -> BICEP template'
			}
			else {
				$diskCreationMethod += ' -> ARM template'
			}
		}

		$_.DiskCreationMethod = $diskCreationMethod
	}
}

#--------------------------------------------------------------
function update-paramSnapshotVolumes {
#--------------------------------------------------------------
	$script:snapshotList = @{}
	set-parameter 'snapshotVolumes' $snapshotVolumes
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		if ($Null -notin @($script:paramConfig1, $script:paramConfig2, $script:paramConfig3)) {
			$anfRG		= $script:paramConfig1
			$anfAccount = $script:paramConfig2
			$anfPool 	= $script:paramConfig3
		}
		elseif ($Null -notin @($script:paramConfig1, $script:paramConfig2)) {
			$anfRG		= $sourceRG
			$anfAccount = $script:paramConfig1
			$anfPool 	= $script:paramConfig2
		}
		else {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Invalid configuration '$script:paramConfig'"
		}

		$poolVolumes = Get-AzNetAppFilesVolume `
					-ResourceGroupName	$anfRG `
					-AccountName		$anfAccount `
					-PoolName			$anfPool `
					-ErrorAction 		'SilentlyContinue'
		if ($poolVolumes.count -eq 0) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"No NetApp volumes found in pool '$anfPool'"
		}

		# get all volumes
		if ($script:paramResources.count -eq 0) {
			$script:paramResources = ($poolVolumes.Name | ForEach-Object {$x,$y,$z = $_ -split '/'; $z})
		}
		# save volumes
		foreach($anfVolume in $script:paramResources) {
			$foundVolume = $poolVolumes | Where-Object Name -eq "$anfAccount/$anfPool/$anfVolume"
			if ($Null -eq $foundVolume) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"NetApp volume '$anfVolume' not found"
			}
			if ($foundVolume.SnapshotDirectoryVisible -ne $True) {
				write-logFileError "SnapShot Directory of NetApp volume '$anfVolume' is not visible"
			}
			$script:snapshotList."$anfRG/$anfAccount/$anfPool/$anfVolume" = @{
				RG			= $anfRG
				Account		= $anfAccount
				Pool		= $anfPool
				Volume		= $anfVolume
				Location 	= $foundVolume.Location
			}
		}
		get-ParameterRule
	}
}

#--------------------------------------------------------------
function update-paramCreateVolumes {
#--------------------------------------------------------------
	[int] $script:mountPointsCount = 0
	[int] $script:mountPointsVolumesGB = 0
	set-parameter 'createVolumes' $createVolumes
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$mountPointSizeGB = $script:paramConfig1 -as [int]
		if ($mountPointSizeGB -lt 100) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Invalid size: '$script:paramConfig1'" `
								"Size must be at least 100"
		}
		$DiskIOPSReadWrite = $script:paramConfig2 -as [int]
		$DiskMBpsReadWrite = $script:paramConfig3 -as [int]
		# both parameters must be NULL
		if (($DiskIOPSReadWrite -gt 0) -or ($DiskMBpsReadWrite -gt 0)) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"IOPS/MBPS must not be specified for volumes"
		}

		foreach ($paramResource in $script:paramResources) {
			$array = convertTo-array ($paramResource -split '/')
			if ($array.count -lt 2) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"Invalid mount point '$paramResource'"
			}

			# get VM name
			$mountPointVM = $array[0]
			# get mount path
			[string] $mountPointPath = ''
			for ($i = 1; $i -lt $array.Count; $i++) {
				$mountPointPath += "/$($array[$i])"
			}
			if ($Null -eq $script:copyVMs[$mountPointVM]) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"Vm '$mountPointVM' not found"
			}

			# save configuration
			[array] $script:copyVMs[$mountPointVM].MountPoints += @{
				Path = $mountPointPath
				Size = $mountPointSizeGB
				Type = 'NetApp'
				Iops = 0
				Mbps = 0
			}
			$script:mountPointsCount++
			$script:mountPointsVolumesGB += $mountPointSizeGB

			if ($script:copyVMs[$mountPointVM].OsDisk.OsType -ne 'linux') {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"VM '$mountPointVM' is not a Linux VM"
			}
		}
		get-ParameterRule
	}
}

#--------------------------------------------------------------
function update-paramCreateDisks {
#--------------------------------------------------------------
	set-parameter 'createDisks' $createDisks
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$mountPointSizeGB = $script:paramConfig1 -as [int]
		if ($mountPointSizeGB -le 0) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Invalid size: '$script:paramConfig1'" `
								"Size must be greater than 0"
		}
		$DiskIOPSReadWrite = $script:paramConfig2 -as [int]
		$DiskMBpsReadWrite = $script:paramConfig3 -as [int]
		# both parameters must be set or none of them
		if ((($DiskIOPSReadWrite -gt 0) -and ($DiskMBpsReadWrite -le 0)) `
		-or (($DiskIOPSReadWrite -le 0) -and ($DiskMBpsReadWrite -gt 0)) ) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Invalid configuration '$script:paramConfig'" `
								"Configuration must be in the form 'sizeMB/IOPS/MBPS'"
		}

		foreach ($paramResource in $script:paramResources) {
			$array = convertTo-array ($paramResource -split '/')
			if ($array.count -lt 2) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"invalid mount point '$paramResource'"
			}

			# get VM name
			$mountPointVM = $array[0]
			# get mount path
			[string] $mountPointPath = ''
			for ($i = 1; $i -lt $array.Count; $i++) {
				$mountPointPath += "/$($array[$i])"
			}
			if ($Null -eq $script:copyVMs[$mountPointVM]) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"Vm '$mountPointVM' not found"
			}

			# save configuration
			[array] $script:copyVMs[$mountPointVM].MountPoints += @{
				Path = $mountPointPath
				Size = $mountPointSizeGB
				Type = 'Disk'
				Iops = $DiskIOPSReadWrite
				Mbps = $DiskMBpsReadWrite
			}
			$script:mountPointsCount++
			$script:copyVMs[$mountPointVM].NewDataDiskCount++

			if ($script:copyVMs[$mountPointVM].OsDisk.OsType -ne 'linux') {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"VM '$mountPointVM' is not a Linux VM"
			}
		}

		get-ParameterRule
	}

	if ($script:snapshotList.count -lt $script:mountPointsCount) {
		write-logFileWarning "Wrong/missing parameter 'snapshotVolumes' could result in data loss" `
							"Is there a snapshot configured for all NetApp volumes (parameter 'snapshotVolumes')?" `
							"- number of snapshots (snapshotVolumes): $($script:snapshotList.count)" `
							"- number of mount points (createVolumes, createDisks): $script:mountPointsCount"
	}
}

#--------------------------------------------------------------
function update-paramSetVmDeploymentOrder {
#--------------------------------------------------------------
	set-parameter 'setVmDeploymentOrder' $setVmDeploymentOrder
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$priority = $script:paramConfig -as [int]
		if ($priority -le 0) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Invalid order number '$script:paramConfig'" `
								"Order number must be greater than 0"
		}

		$script:copyVMs.values
		| Where-Object Name -in $script:paramVMs
		| ForEach-Object {

			$_.VmPriority = $priority
		}

		get-ParameterRule
	}

	# update from tag (if parameter setVmDeploymentOrder was NOT used)
	if (($setVmDeploymentOrder.count -eq 0) -and !$ignoreTags) {

		$script:copyVMs.values
		| ForEach-Object {

			$priority = $_.Tags.$azTagDeploymentOrder -as [int]
			if ($priority -gt 0) {
				$_.VmPriority = $priority
			}
		}
	}
}

#--------------------------------------------------------------
function update-paramSetVmTipGroup {
#--------------------------------------------------------------
	set-parameter 'setVmTipGroup' $setVmTipGroup
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$tipGroup = $script:paramConfig -as [int]
		if ($tipGroup -le 0) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Invalid TiP group number '$script:paramConfig'" `
								"TiP group number must be greater than 0"
		}

		# update VMs
		$script:copyVMs.Values
		| Where-Object Name -in $script:paramVMs
		| ForEach-Object {

			$_.Group = $tipGroup
			if (!$script:tipEnabled) {
				write-logFileError "Parameter 'setVmTipGroup' not allowed" `
									"Subscription is not TiP-enabled"
			}
		}

		get-ParameterRule
	}

	# update from tag (if parameter setVmTipGroup was NOT used)
	$numberTags = 0
	if (($setVmTipGroup.count -eq 0) `
	-and ($createVmssFlex.count -eq 0) `
	-and ($createAvailabilitySet.count -eq 0) `
	-and ($createProximityPlacementGroup.count -eq 0) `
	-and !$ignoreTags `
	-and $script:tipEnabled ) {

		$script:copyVMs.values
		| ForEach-Object {

			$tipGroup = $_.Tags.$azTagTipGroup -as [int]
			if ($tipGroup -gt 0) {
				$_.Group = $tipGroup
				$numberTags++
			}
		}
	}

	if ($numberTags -gt 0) {
		write-logFileWarning "VM Tag 'rgcopy.TipGroup' was used" `
							"Use RGCOPY parameter 'ignoreTags' for preventing this"

		write-logFileWarning "ProximityPlacementGroups, AvailabilitySets and VmssFlex are removed" `
							"Use RGCOPY parameter 'ignoreTags' for preventing this"
	}

	$script:tipVMs = convertTo-array (($script:copyVMs.values | Where-Object Group -gt 0).Name)
	if ($script:tipVMs.count -ne 0) {
		$script:skipProximityPlacementGroup		= $True
		$script:skipAvailabilitySet 			= $True
		$script:skipVmssFlex 					= $True
		$script:createProximityPlacementGroup 	= @()
		$script:createAvailabilitySet 			= @()
		$script:createVmssFlex  				= @()
	}
}

#--------------------------------------------------------------
function update-paramSwapDisk4disk {
#--------------------------------------------------------------
	set-parameter 'swapDisk4disk' $swapDisk4disk
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		if ($script:paramDisks.count -ne 1) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"The syntax is: <newDisk>@<oldDisk>"
		}
		# check if old disk exists, already done in get-ParameterRule
		$oldDisk = $script:paramDisks[0]

		# check if new disk was supplied
		$newDisk = $script:paramConfig
		if ($Null -eq $NewDisk) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"The syntax is: <newDisk>@<oldDisk>"
		}

		# check if new disk exists
		if ($Null -eq $script:copyDisks[$newDisk]) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"The syntax is: <newDisk>@<oldDisk>" `
								"Disk '$newDisk' does not exist"
		}

		# do not allow OS disk
		if ($script:copyDisks[$oldDisk].OsType.Length -ne 0) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Not supported for OS disk:" `
								"'$oldDisk'"
		}
		if ($script:copyDisks[$newDisk].OsType.Length -ne 0) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Not supported for OS disk:" `
								"'$newDisk'"
		}

		# check if parameter swapSnapshot4disk/swapDisk4disk has already been set
		if (($script:copyDisks[$oldDisk].SnapshotSwap) `
		-or ($script:copyDisks[$oldDisk].DiskSwapOld) `
		-or ($script:copyDisks[$oldDisk].DiskSwapNew)) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"The syntax is: <newDisk>@<oldDisk>" `
								"Disk '$oldDisk' already used in swapping" 
		}	
		if (($script:copyDisks[$newDisk].SnapshotSwap) `
		-or ($script:copyDisks[$newDisk].DiskSwapOld) `
		-or ($script:copyDisks[$newDisk].DiskSwapNew)) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"The syntax is: <newDisk>@<oldDisk>" `
								"Disk '$newDisk' already used in swapping" 
		}

		if (!$script:copyDisks[$oldDisk].Skip) {
			if ($script:copyDisks[$oldDisk].LogicalSectorSize -ne $script:copyDisks[$newDisk].logicalSectorSize) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"The syntax is: <newDisk>@<oldDisk>" `
									"<newDisk> and <oldDisk> nust have same logical sector size" 
			}
		}

		# set swap old disk
		$script:copyDisks[$oldDisk].DiskSwapOld 			= $True  # skip snapshot
		$script:copyDisks[$oldDisk].SwapName				= $script:copyDisks[$newDisk].Name

		$script:copyDisks[$oldDisk].SnapshotName			= $script:copyDisks[$newDisk].SnapshotName
		$script:copyDisks[$oldDisk].SnapshotId				= $script:copyDisks[$newDisk].SnapshotId

		$script:copyDisks[$oldDisk].IncrementalSnapshots	= $script:copyDisks[$newDisk].IncrementalSnapshots
		$script:copyDisks[$oldDisk].SnapshotCopy			= $script:copyDisks[$newDisk].SnapshotCopy
		$script:copyDisks[$oldDisk].BlobCopy				= $script:copyDisks[$newDisk].BlobCopy

		# the following parameters can only be changed for <newDisk>:
		$script:copyDisks[$oldDisk].DiskIOPSReadWrite		= $script:copyDisks[$newDisk].DiskIOPSReadWrite
		$script:copyDisks[$oldDisk].DiskMBpsReadWrite		= $script:copyDisks[$newDisk].DiskMBpsReadWrite
		$script:copyDisks[$oldDisk].BurstingEnabled			= $script:copyDisks[$newDisk].BurstingEnabled
		$script:copyDisks[$oldDisk].SizeGB					= $script:copyDisks[$newDisk].SizeGB
		$script:copyDisks[$oldDisk].SizeTierName			= $script:copyDisks[$newDisk].SizeTierName
		$script:copyDisks[$oldDisk].SizeTierGB				= $script:copyDisks[$newDisk].SizeTierGB
		$script:copyDisks[$oldDisk].performanceTierName		= $script:copyDisks[$newDisk].performanceTierName
		$script:copyDisks[$oldDisk].performanceTierGB		= $script:copyDisks[$newDisk].performanceTierGB
		$script:copyDisks[$oldDisk].MaxShares				= $script:copyDisks[$newDisk].MaxShares

		# set swap new disk
		$script:copyDisks[$newDisk].DiskSwapNew				= $True  # snapshot required

		get-ParameterRule
	}
}

#--------------------------------------------------------------
function update-paramSwapSnapshot4disk {
#--------------------------------------------------------------
	set-parameter 'swapSnapshot4disk' $swapSnapshot4disk
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		if ($script:paramDisks.count -ne 1) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"The syntax is: <snapshot>@<disk>"
		}
		# check if disk exists, already done in get-ParameterRule
		$diskName = $script:paramDisks[0]

		$snapshotName = $script:paramConfig
		if ($Null -eq $snapshotName) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"The syntax is: <snapshot>@<disk>"
		}
		# check snapshot name
		if ($snapshotName -like '*.rgcopy') {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"The syntax is: <snapshot>@<disk>" `
								"<snapshot> must not be '*.rgcopy'"
		}

		$snap = $script:sourceSnapshots | Where-Object Name -eq $snapshotName
		# check if snapshot exists
		if ($Null -eq $snap) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"The syntax is: <snapshot>@<disk>" `
								"'$snapshotName' does not exist"
		}
		
		# check if snapshot fits to disk
		if ($script:copyDisks[$diskName].SizeGB -ne $snap.DiskSizeGB) {
			$sku 			= $script:copyDisks[$diskName].SkuName
			$SizeGB			= $snap.DiskSizeGB
			$SizeTierName	= get-diskTier $SizeGB $sku
			$SizeTierGB		= get-diskSize $SizeTierName
			if ($sku -like 'Premium_?RS') {
				$performanceTierName = $SizeTierName
			}
			else {
				$performanceTierName = $Null
			}
			$performanceTierGB = get-diskSize $performanceTierName

			write-logFileWarning "Adjusting size of disk '$diskName' to size of snapshot '$snapshotName'"
			$script:copyDisks[$diskName].SizeGB = $SizeGB
			$script:copyDisks[$diskName].SizeTierName = $SizeTierName
			$script:copyDisks[$diskName].SizeTierGB = $SizeTierGB

			if ($script:copyDisks[$diskName].performanceTierName -ne $performanceTierName) {
				write-logFileWarning "Removing performance tier of disk '$diskName'"
				$script:copyDisks[$diskName].performanceTierName = $performanceTierName
				$script:copyDisks[$diskName].performanceTierGB = $performanceTierGB
			}
		}
		if (($snap.CreationData.LogicalSectorSize -eq 4096) -and ($script:copyDisks[$diskName].LogicalSectorSize -ne 4096)) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"disk '$diskName' has a different logical sector size size than" `
								"snapshot '$snapshotName'"
		}

		if (!$script:copyDisks[$diskName].Skip) {
			# do not allow OS disk
			if ($script:copyDisks[$diskName].OsType.Length -ne 0) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"Not supported for OS disk:" `
									"'$diskName'"
			}
	
			# check if SnapshotCopy is required
			if ($script:copyDisks[$diskName].SnapshotCopy) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"Snapshot '$snapshotName' cannot be used" `
									"because SNAPSHOT COPY is required for disk '$diskName'"
			}

			# check logical sector size
			if (	(($script:copyDisks[$diskName].logicalSectorSize -eq 4096) `
					-and ($snap.CreationData.LogicalSectorSize -ne 4096)) `
				-or	(($script:copyDisks[$diskName].logicalSectorSize -ne 4096) `
					-and ($snap.CreationData.LogicalSectorSize -eq 4096))  ) {

				write-logFileError "Invalid parameter '$script:paramName'" `
									"Snapshot '$snapshotName' cannot be used" `
									"because logical sector size is different compared with disk '$diskName'"		
			}
		}

		# set swap snapshot
		$script:copyDisks[$diskName].SwapName		= $snapshotName
		$script:copyDisks[$diskName].SnapshotName	= $snapshotName
		$script:copyDisks[$diskName].SnapshotId		= "/subscriptions/$sourceSubID/resourceGroups/$sourceRG/providers/Microsoft.Compute/snapshots/$snapshotName"
		$script:copyDisks[$diskName].SnapshotSwap	= $True # skip snapshot

		get-ParameterRule
	}

	update-paramSwapDisk4disk
}

#--------------------------------------------------------------
function update-paramSetVmName {
#--------------------------------------------------------------
	set-parameter 'setVmName' $setVmName
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		if ($script:paramVMs.count -ne 1) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"The syntax is: <newName>@<oldName>"
		}
		$vmNameOld = $script:paramVMs[0]

		$vmNameNew = $script:paramConfig
		if ($Null -eq $vmNameNew) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"The syntax is: <newName>@<oldName>"
		}

		$match = '^[a-zA-Z0-9][a-zA-Z0-9\-]{0,62}[a-zA-Z0-9]$|^[a-zA-Z0-9]$'
		test-match 'setVmName' $vmNameNew $match

		$existingNames = @()
		$script:copyVMs.values
		| ForEach-Object {

			$existingNames += $_.Name
			$existingNames += $_.Rename
		}
		if (! ($mergeMode -and !$SourceOnlyMode)) {
			if ($vmNameNew -in $existingNames) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"Name '$vmNameNew' is already in use"
			}
		}

		$script:copyVMs[$vmNameOld].Rename = $vmNameNew

		get-ParameterRule
	}
}

#--------------------------------------------------------------
function update-paramCloneVMs {
#--------------------------------------------------------------
	if (!$cloneMode) {
		return
	}

	test-vmParameter 'cloneVMs' $cloneVMs | Out-Null

	if ($cloneVMs.count -eq 0) {
		write-logFileError "No VM is configured to be cloned" `
							"Use RGCOPY parameter 'cloneVMs'"
	}
}

#--------------------------------------------------------------
function update-paramSetVmMerge {
#--------------------------------------------------------------
	if (!$mergeMode) {
		return
	}

	$script:mergeVMs = @()

	set-parameter 'setVmMerge' $setVmMerge
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		if (($Null -eq $script:paramConfig1) -or ($Null -eq $script:paramConfig2)) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Required format: <vnet>/<subnet>@<vm>"
		}

		$script:copyVMs.values
		| Where-Object {$_.Name -in $script:paramVMs}
		| ForEach-Object {

			$_.MergeNetSubnet = "$($script:paramConfig1)/$($script:paramConfig2)"
			$script:mergeVMs += $_.Name
		}

		get-ParameterRule
	}

	if ($script:mergeVMs.count -eq 0) {
		write-logFileError "No VM is configured to be merged" `
							"Use RGCOPY parameter 'setVmMerge'"
	}
}

#--------------------------------------------------------------
function update-paramAttachVmssFlex {
#--------------------------------------------------------------
	set-parameter 'attachVmssFlex' $attachVmssFlex
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		if (($Null -eq $script:paramConfig1) -or ($Null -ne $script:paramConfig2)) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Required format: <vmssName>@<vm>"
		}

		$script:copyVMs.values
		| Where-Object {$_.Name -in $script:paramVMs}
		| ForEach-Object {

			$_.attachVmssFlex= "$targetRG/$($script:paramConfig1)"
		}

		get-ParameterRule
	}
}

#--------------------------------------------------------------
function update-paramAttachAvailabilitySet {
#--------------------------------------------------------------
	set-parameter 'attachAvailabilitySet' $attachAvailabilitySet
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		if (($Null -eq $script:paramConfig1) -or ($Null -ne $script:paramConfig2)) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Required format: <avSetName>@<vm>"
		}

		$script:copyVMs.values
		| Where-Object {$_.Name -in $script:paramVMs}
		| ForEach-Object {

			$_.attachAvailabilitySet= "$targetRG/$($script:paramConfig1)"
		}

		get-ParameterRule
	}
}

#--------------------------------------------------------------
function update-paramAttachProximityPlacementGroup {
#--------------------------------------------------------------
	set-parameter 'attachProximityPlacementGroup' $attachProximityPlacementGroup
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		if ($Null -eq $script:paramConfig1) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Required format:    <ppgName>@<vm>" `
								"or: <resourceGroup>/<ppgName>@<vm>"
		}
		if ($Null -eq $script:paramConfig2) {
			$script:paramConfig2 = $script:paramConfig1
			$script:paramConfig1 = $targetRG
		}

		$script:copyVMs.values
		| Where-Object {$_.Name -in $script:paramVMs}
		| ForEach-Object {

			$_.attachProximityPlacementGroup= "$($script:paramConfig1)/$($script:paramConfig2)"
		}

		get-ParameterRule
	}
}

#--------------------------------------------------------------
function update-paramGeneralizedVMs {
#--------------------------------------------------------------
	# convert to array
	if (($script:generalizedUser.count -eq 1) -and ($script:generalizedUser -isnot [array])) {
		$script:generalizedUser = @($script:generalizedUser)
	}
	if (($script:generalizedPasswd.count -eq 1) -and ($script:generalizedPasswd -isnot [array])) {
		$script:generalizedPasswd = @($script:generalizedPasswd)
	}
	# check array length
	if ($script:generalizedVMs.count -ne $script:generalizedUser.count) {
		write-logFileError "Invalid parameter 'generalizedUser'" `
							"Number of elements must match with parameter 'generalizedVMs'"
	}
	if ($script:generalizedVMs.count -ne $script:generalizedPasswd.count) {
		write-logFileError "Invalid parameter 'generalizedPasswd'" `
							"Number of elements must match with parameter 'generalizedVMs'"
	}
	# check data type
	foreach ($item in $script:generalizedUser) {
		if ($item -isnot [String]) {
			write-logFileError "Invalid parameter 'generalizedUser'" `
								"Data type must be array of [String]"
		}
	}
	foreach ($item in $script:generalizedPasswd) {
		if ($item -isnot [SecureString]) {
			write-logFileError "Invalid parameter 'generalizedPasswd'" `
								"Data type must be array of [SecureString]"
		}
	}

	# Generalized only allowed with snapshots
	if (($sourceLocation -ne $targetLocation) -and ($generalizedVMs.Count -ne 0)) {
		write-logFileError "Invalid parameter 'generalizedVMs'" `
							"Generalized VMs can only be created in the same region" `
							"Using BLOB copy is not allowed"
	}

	# update VMs
	$script:copyVMs.Values
	| ForEach-Object {

		for ($i = 0; $i -lt $generalizedVMs.Count; $i++) {
			if ($_.Name -eq $generalizedVMs[$i]) {
				$_.Generalized 			= $True
				$_.GeneralizedUser		= $GeneralizedUser[$i]
				$_.GeneralizedPasswd	= $GeneralizedPasswd[$i]
			}
		}
	}
}

#--------------------------------------------------------------
function update-paramSkipVMs {
#--------------------------------------------------------------
	# skipped VMs have already be marked in function save-copyVMs
	$script:skipVMs = @()
	$script:VMsRunning = $False

	$script:copyVMs.Values
	| ForEach-Object {

		# skip all other VMs if some VMs are merged
		if (($mergeMode) -and ($_.Name -notin $mergeVMs)) {
			$_.Skip = $True
		}

		# skip all other VMs if some VMs are cloned
		if ($cloneMode -and ($_.Name -notin $cloneVMs)) {
			$_.Skip = $True
		}

		# correct status and get $script:skipVMs
		if ($_.Skip -eq $True) {
			$_.VmStatus = "skipped (will not be copied)"
			$script:skipVMs += $_.Name
		}
		# check for running VM with more than one disk/volume
		elseif ($_.VmStatus -ne 'VM deallocated') {
			if (($_.DataDisks.count + $_.MountPoints.count) -gt 1) {
				$script:VMsRunning = $True
			}
		}
	}
}

#--------------------------------------------------------------
function update-paramSkipDisks {
#--------------------------------------------------------------
	if ($updateMode) {
		return
	}

	# skip disks when parameter is set
	foreach ($diskName in $skipDisks) {
		if ($Null -eq $script:copyDisks[$diskName]) {
			write-logFileWarning "Invalid parameter 'skipDisks'" `
								"Disk '$diskName' not found" `
								-stopCondition $True
			continue
		}
		if ($Null -ne $script:copyDisks[$diskName].OsType) {
			write-logFileWarning "Invalid parameter 'skipDisks'" `
								"Disk '$diskName' is an OS disk" `
								-stopCondition $True
			continue
		}
		$script:copyDisks[$diskName].Skip = $True

		# update number of data disks
		$vmName = $script:copyDisks[$diskName].VM
		if ($vmName.Length -ne 0) {
			$script:copyVMs[$vmName].NewDataDiskCount--
		}
	}

	# warning when skipDisks used:
	if ($skipDisks.count -ne 0) {
		write-logFileWarning "Parameter 'skipDisks' requires specific settings in /etc/fstab for LINUX VMs:" `
							"- use UUID or /dev/disk/azure/scsi1/lun*-part*" `
							"- use option 'nofail' for each disk"
	}

	# skip disks that are not attached to any VM
	if (!$copyDetachedDisks) {
		$detachedDisks = @()
		$script:copyDisks.values
		| ForEach-Object {

			if ($_.VM.length -eq 0) {
				$_.Skip = $True
				$detachedDisks += $_.Name
			}
		}

		if (($detachedDisks.count -ne 0) `
		-and !$cloneOrMergeMode `
		-and !$patchMode `
		-and ($justCopyBlobs.count -eq 0) `
		-and ($justCopySnapshots.count -eq 0) `
		-and ($justCopyDisks.count -eq 0) ) {

			write-logFileWarning "Some disks are not attached to any VM" `
								"These disks are not copied to the target RG" `
								"You can copy them using RGCOPY parameter switch 'copyDetachedDisks'"

			write-logFile "Detached disks:"
			$detachedDisks
			| Sort-Object
			| ForEach-Object {
				write-logFile "  $_"
			}
			write-logFile
		}
	}

	# skip disks (when remote copy originally failed only for a few VMs)
	if ($justCopyBlobs.count -ne 0) {
		$copySingleDisks = $justCopyBlobs
	}
	elseif ($justCopySnapshots.count -ne 0) {
		$copySingleDisks = $justCopySnapshots
	}
	elseif ($justCopyDisks.count -ne 0) {
		$copySingleDisks = $justCopyDisks

		# check parameter defaultDiskName
		if ($Null -ne $defaultDiskName) {
			if (($justCopyDisks.Count -gt 1) -or ($justCopyDisks[0] -isnot [string])) {
				write-logFileError "Invalid parameter 'defaultDiskName'" `
									"parameter only allowed when copying a single disk"
			}
		}
	}
	else {
		$copySingleDisks = $Null
	}

	if ($copySingleDisks) {

		# copy all disks
		if (($copySingleDisks[0] -is [boolean]) `
		-and ($copySingleDisks[0] -eq $True)) {

			$script:copyDisks.Values
			| ForEach-Object {
	
				$_.Skip = $False
			}
		}

		# copy specific disks
		else {

			# skip all disks
			$script:copyDisks.Values
			| ForEach-Object {
	
				$_.Skip = $True
			}
	
			# unskip configured disks
			foreach ($diskName in $copySingleDisks) {
				if ($Null -eq $script:copyDisks[$diskName]) {
					write-logFileError "Invalid parameter 'justCopyBlobs', 'justCopySnapshots' or 'justCopyDisks'" `
										"Disk '$diskName' not found"
				}
				$script:copyDisks[$diskName].Skip = $False
			}
		}
	}
}

#--------------------------------------------------------------
function test-vmParameter {
#--------------------------------------------------------------
	param (
		$paramName,
		$paramValue,
		[switch] $checkSyntaxOnly
	)

	# check data type
	if (($paramValue -is [string]) -or ($paramValue -is [char])) {
		$paramValue = @($paramValue)
	}
	if ($paramValue -isnot [array]) {
		write-logFileError "Invalid parameter '$paramName'" `
							"Invalid data type"
	}
	foreach ($item in $paramValue) {
		if ($item -is [char]) {
			$item = $item -as [string]
		}
		if ($item -isnot [string]) {
			write-logFileError "Invalid parameter '$paramName'" `
								"Invalid data type of array element '$item'"
		}
	}

	if ($checkSyntaxOnly) {
		return
	}

	# get allowed values for parameter
	if ($paramName -eq 'skipVMs') {
		$allowedVMs = convertTo-array $script:copyVMs.Values.Name
	}
	else {
		$allowedVMs = convertTo-array (($script:copyVMs.Values | Where-Object Skip -ne $True).Name)
	}

	# special parameter value '*'
	if (($paramValue.count -eq 1) -and ($paramName -ne 'generalizedVMs')) {
		if ($paramValue[0] -eq '*') {
				return $allowedVMs
		}
	}

	$checkedVMs = @()
	# check if VM exists
	foreach ($vmName in $paramValue) {
		if ($vmName -in $allowedVMs) {
			$checkedVMs += $vmName
		}
		else {
			write-logFileWarning "Invalid parameter '$paramName'" `
								"Vm '$vmName' not found or skipped" `
								-stopCondition $True
		}
	}
	return $checkedVMs
}

#--------------------------------------------------------------
function update-paramSetVmZone {
#--------------------------------------------------------------
	set-parameter 'setVmZone' $setVmZone
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$vmZone = $script:paramConfig
		# convert old syntax to new syntax to be compatible
		if ($vmZone -eq '0') {
			$vmZone = 'none'
		}

		test-values 'setVmZone' $vmZone @('none','1','2','3', 'false') 'zone'
		# convert to internal syntax
		if ($vmZone -eq 'none') {
			$vmZone = 0
		}
		$vmZone = $vmZone -as [int]

		$script:copyVMs.values
		| Where-Object Name -in $script:paramVMs
		| ForEach-Object {

			if ($vmZone -eq 'false') {
				$_.VmZoneNew = $_.VmZone
			}
			else {
				$_.VmZoneNew = $vmZone
			}
		}
		get-ParameterRule
	}

	# output of changes
	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$vmName 	= $_.Name
		$current	= $_.VmZone
		$wanted		= $_.VmZoneNew
		if ($Null -eq $wanted) {
			$wanted = $current
		}

		# update
		if ($current -ne $wanted) {
			$_.VmZone = $wanted
			$action = 'set'
		}
		else {
			$action = 'keep'
		}
		# output
		if ($_.VmZone -eq 0) {
			write-logFileUpdates 'virtualMachines' $vmName "$action zone" 'none' -defaultValue
		}
		else {
			write-logFileUpdates 'virtualMachines' $vmName "$action zone" $_.VmZone
		}
	}
}

#--------------------------------------------------------------
function update-paramSetVmSize {
#--------------------------------------------------------------
	# process RGCOPY parameter
	set-parameter 'setVmSize' $setVmSize
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$vmSizeConfig = $script:paramConfig
		$script:copyVMs.values
		| Where-Object Name -in $script:paramVMs
		| ForEach-Object {

			$_.VmSizeNew = $vmSizeConfig
		}
		get-ParameterRule
	}

	# output of changes
	$script:copyVMs.values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$_.VmSizeOld = $_.VmSize

		if (($Null -ne $_.VmSizeNew) -and ($_.VmSizeNew -ne $_.VmSize)) {
			$_.VmSize = $_.VmSizeNew
			write-logFileUpdates 'virtualMachines' $_.Name 'set size' $_.VmSize
		}
		else {
			write-logFileUpdates 'virtualMachines' $_.Name 'keep size' $_.VmSize
		}

		$vmSize = $_.VmSize
		if ($skipVmChecks -or $useNewVmSizes) {
			# all features are available for unknown VM sizes
			save-skuDefaultValue $_.VmSizeOld
			save-skuDefaultValue $vmSize
		}
		elseif ($Null -eq $script:vmSkus[$vmSize]) {
			write-logFileWarning "VM Size '$vmSize' not found in region '$targetLocation'" `
								"You can override this check using file 'newVmSizes.csv' and parameter 'useNewVmSizes'" `
								-stopCondition $True

			# all features are available for unknown VM sizes
			save-skuDefaultValue $vmSize
		}

		# set ultraSSDAllowed
		$vmZone = $_.VmZone -as [string]
		$allowedZones = $script:vmSkus[$vmSize].UltraSSDAvailableZones -split ' '
		if ($vmZone -in $allowedZones) {
			$_.ultraSSDAllowed = $True
		}
		else {
			$_.ultraSSDAllowed = $False
		}
	}

	# output of ALL issues
	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$vmName = $_.Name
		$vmSize = $_.VmSize

		# check data disk count
		$diskCount = $_.NewDataDiskCount
		$diskCountMax = $script:vmSkus[$vmSize].MaxDataDiskCount
		if ($diskCount -gt $diskCountMax) {
			write-logFileWarning "VM consistency check failed" `
								"Size '$vmSize' of VM '$vmName' only supports $diskCountMax data disk(s)" `
								"You can skip this check using RGCOPY parameter switch 'skipVmChecks'" `
								-stopCondition $True
		}

		# check NIC count
		$nicCount = $_.NicCount
		$nicCountMax = $script:vmSkus[$vmSize].MaxNetworkInterfaces
		if ($nicCount -gt $nicCountMax) {
			write-logFileWarning "VM consistency check failed" `
								"Size '$vmSize' of VM '$vmName' only supports $nicCountMax network interface(s)" `
								"You can skip this check using RGCOPY parameter switch 'skipVmChecks'" `
								-stopCondition $True
		}

		# check HyperVGeneration
		$hvGen = $_.OsDisk.HyperVGeneration
		if ($hvGen.length -eq 0) { 
			$hvGen = 'V1'
		}
		$hvGenAllowed = $script:vmSkus[$vmSize].HyperVGenerations
		if ($hvGenAllowed -notlike "*$hvGen*") {
			write-logFileWarning "VM consistency check failed" `
								"HyperVGeneration '$hvGen' of VM '$vmName' not supported by VM size '$vmSize'" `
								"You can skip this check using RGCOPY parameter switch 'skipVmChecks'" `
								-stopCondition $True
		}

		# check CpuArchitectureType: 'x64', 'Arm64'
		if (!$skipVmChecks) {
			$cpuTypeOld = $script:vmSkus[$_.VmSizeOld].CpuArchitectureType
			# old VM size might not be available in target region
			if ($Null -ne $cpuTypeOld) {
				$cpuTypeNew = $script:vmSkus[$_.VmSize].CpuArchitectureType
				if ($cpuTypeOld -ne $cpuTypeNew) {
					write-logFileWarning "Cannot change from CPU architecture '$cpuTypeOld' (VM size '$($_.VmSizeOld)')" `
										"to CPU architecture '$cpuTypeNew' (VM size '$vmSize')" `
										"You can skip this check using RGCOPY parameter switch 'skipVmChecks'" `
										-stopCondition $True
				}
			}
		}
	}
}

#--------------------------------------------------------------
function update-paramSetDiskSku {
#--------------------------------------------------------------
	# process RGCOPY parameter
	set-parameter 'setDiskSku' $setDiskSku
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$sku = $script:paramConfig
		test-values 'setDiskSku' $sku @('false', 'Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS', 'Premium_ZRS', 'StandardSSD_ZRS', 'PremiumV2_LRS', 'UltraSSD_LRS') 'sku'

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			if ($sku -eq 'false') {
				$_.SkuNameNew = $_.SkuName
			}
			else {
				$_.SkuNameNew = $sku
			}
		}
		get-ParameterRule
	}

	# output of changes
	$script:copyDisks.values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$_.SkuNameOld = $_.SkuName

		$diskName	= $_.Name
		$vmName		= $_.VM
		$current	= $_.SkuName
		$wanted		= $_.SkuNameNew
		
		if ($Null -eq $wanted) {
			$wanted = $current
		}

		#--------------------------------------------------------------
		# default value 'Premium_LRS' only used for 'StandardSSD_LRS' and 'Standard_LRS'
		if ('setDiskSku' -notin $boundParameterNames) {
			if ($current -notin @('Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS')) {
				$wanted = $current
				write-logFileWarning "Not using default value 'Premium_LRS' for disks with SKU '$current'"
			}
		}

		#--------------------------------------------------------------
		# current is ULTRA disk
		if ($current -in @('UltraSSD_LRS', 'PremiumV2_LRS')) {

			# check if SKU can be changed
			if (($wanted -notin @('UltraSSD_LRS', 'PremiumV2_LRS')) -and ($_.LogicalSectorSize -ne 512)) {
				write-logFileWarning "Disk SKU '$current' of disk '$diskName' cannot be changed to '$wanted'" `
									"because the logical sector size is not 512" `
									-stopWhenForceVmChecks
				$wanted = $current
			}
		}

		#--------------------------------------------------------------
		# wanted is ULTRA disk
		if ($wanted -in @('UltraSSD_LRS', 'PremiumV2_LRS')) {

			# check for OS disk
			if ($_.OsType.length -ne 0) {
				write-logFileWarning "Disk SKU '$wanted' of disk '$diskName' not supported for OS disks" `
									-stopWhenForceVmChecks
				$wanted = $current
			}

			# warning regarding sector size
			if ($current -notin @('UltraSSD_LRS', 'PremiumV2_LRS')) {
				write-logFileWarning "Using 512 Byte sector size for disk '$diskName'"
			}

			# check VM settings
			if ($vmName.length -ne 0) {
				$vmZone = $script:copyVMs[$vmName].VmZone
	
				# check if zone is set
				if ($vmZone -eq 0) {
					write-logFileWarning "Disk SKU '$wanted' of disk '$diskName' can only be used for zonal deployment" `
										"Use parameter 'setVmZone'" `
										-stopCondition $True
				}

				# check if zone supports UltraSSD_LRS
				if ($wanted -eq 'UltraSSD_LRS') {
					if ($script:copyVMs[$vmName].ultraSSDAllowed -eq $False) {

						write-logFileWarning "Disk SKU '$wanted' of disk '$diskName' cannot be used" `
											"for VM size '$vmSize' in zone $vmZone" `
											-stopCondition $True
					}					
				}
			}
		}

		# check if premiumIO is supported for VM
		if ($vmName.length -eq 0) {
			write-logFileWarning "Disk '$diskName' not attached to a VM"
			$allowedPremiumIO	= $True
		}
		else {
			foreach ($name in $_.ManagedBy) {
				$vmSize				= $script:copyVMs[$name].VmSize
				$allowedPremiumIO	= $script:vmSkus[$vmSize].PremiumIO
	
				if ($allowedPremiumIO -ne $True) {
					$_.VmRestrictions = $True # disks must be updated BEFORE updating VM size
					break
				}
			}
		}

		# do not allow changing shared disks to standard_LRS
		if (($_.ManagedBy.count -gt 1) -and ($wanted -eq 'Standard_LRS') -and ($current -ne $wanted)) {
			write-logFileWarning "Cannot changed disk SKU to 'Standard_LRS' because disk is attached to 2+ VMs" `
								-stopWhenForceVmChecks
			$wanted = $current
		}

		# premium not IO supported:
		if ($allowedPremiumIO -eq $False) {
			if ($wanted -in @('UltraSSD_LRS', 'PremiumV2_LRS')) {
				write-logFileWarning "Size '$vmSize' of VM '$vmName' does not support Premium IO" `
									"However, disk '$diskName' has SKU '$wanted'" `
									-stopCondition $True
			}
			elseif ($wanted -eq 'Premium_ZRS') {
				write-logFileWarning "Size '$vmSize' of VM '$vmName' does not support Premium IO" `
									-stopWhenForceVmChecks
				$wanted = 'StandardSSD_ZRS'
			}
			elseif ($wanted -eq 'Premium_LRS') {
				write-logFileWarning "Size '$vmSize' of VM '$vmName' does not support Premium IO" `
									-stopWhenForceVmChecks
				$wanted = 'StandardSSD_LRS'
			}
		}

		# output
		if ($wanted -eq $current) {
			write-logFileUpdates 'disks' $diskName 'keep SKU' $_.SkuName
		}
		else {
			# calculate new Tier
			$_.SkuName		= $wanted
			$_.SizeTierName	= get-diskTier $_.SizeGB $_.SkuName
			$_.SizeTierGB	= get-diskSize $_.SizeTierName

			write-logFileUpdates 'disks' $diskName 'set SKU' $_.SkuName
			$script:countDiskSku++

			# adjust perfromance tier if SKU has changed
			# SKU was premium and became non-premium
			if (($current -like 'Premium_?RS') -and ($wanted -notlike 'Premium_?RS')) {
				$_.performanceTierName	= $Null
				$_.performanceTierGB	= 0
			}
			# SKU was non-premium and became premium
			elseif (($current -notlike 'Premium_?RS') -and ($wanted -like 'Premium_?RS')) {
				$_.performanceTierName	= $_.SizeTierName
				$_.performanceTierGB	= $_.SizeTierGB
			}
		}
	}
}

#--------------------------------------------------------------
function update-paramSetDiskSize {
#--------------------------------------------------------------
	# process RGCOPY parameter
	set-parameter 'setDiskSize' $setDiskSize
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$diskSize_min = 4
		$diskSize_max = 32 * 1024 - 1
		$sizeGB = $script:paramConfig -as [int]
		if (($sizeGB -lt $diskSize_min) -or ($sizeGB -gt $diskSize_max)) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"sizeGB: '$sizeGB'" `
								"sizeGB must be between $diskSize_min and $diskSize_max"
		}

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			$_.sizeGBNew = $sizeGB
		}
		get-ParameterRule
	}

	# output of changes in show-paramSetDiskSize
	$script:copyDisks.values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$_.SizeGBOld = $_.SizeGB

		if (($Null -ne $_.SizeGBNew) -and ($_.SizeGB -gt $_.SizeGBNew)) {
			write-logFileError "Invalid parameter 'setDiskSize'" `
								"New size: $($_.SizeGBNew) GiB, current size: $($_.SizeGB) GiB" `
								"Cannot decrease disk size of disk '$($_.Name)'"
		}
		elseif (($Null -ne $_.SizeGBNew) -and ($_.SizeGB -ne $_.SizeGBNew)) {
			$_.SizeGB		= $_.SizeGBNew
			$_.SizeTierName	= get-diskTier $_.SizeGB $_.SkuName
			$_.SizeTierGB	= get-diskSize $_.SizeTierName
		}
	}
}

#--------------------------------------------------------------
function update-paramSetDiskMaxShares {
#--------------------------------------------------------------
	# process RGCOPY parameter
	set-parameter 'setDiskMaxShares' $setDiskMaxShares
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$maxSharesConfig = $script:paramConfig -as [int]
		if ($maxSharesConfig -le 0) {
			write-logFileError "Invalid parameter 'setDiskMaxShares'" `
								"value must be 1 or higher"
		}

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			$_.MaxSharesNew = $maxSharesConfig
		}
		get-ParameterRule
	}

	# output of changes
	$script:copyDisks.values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$current = $_.MaxShares
		$wanted  = $_.MaxSharesNew
		if ($Null -eq $wanted) {
			$wanted = $current
		}

		# check maximum number of shares
		$sizeTierName = $_.SizeTierName
		if ($sizeTierName -in @('P1','P2','P3','P4','P6','P10','P15','P20','E1','E2','E3','E4','E6','E10','E15','E20')) {
			$maxWanted = 3
		}
		elseif ($sizeTierName -in @('P30','P40','P50','E30','E40','E50')) {
			$maxWanted = 5
		}
		elseif ($sizeTierName -in @('P60','P70','P80','E60','E70','E80')) {
			$maxWanted = 10
		}
		elseif ($sizeTierName -eq 'Ultra') {
			$maxWanted = 15
		}
		elseif ($sizeTierName -eq 'PremV2') {
			$maxWanted = 15
		}
		else {
			$maxWanted = 1
		}
		if ($wanted -gt $maxWanted) {
			write-logFileWarning "Disk size '$sizeTierName' only supports up to $maxWanted shares" `
								-stopWhenForceVmChecks
			$wanted = $maxWanted
		}

		# check if it is a DATA disk
		if (($_.OsType.length -ne 0) -and ($wanted -gt 1)) {
			write-logFileWarning "Shared disks are only supported for data disks" `
								-stopWhenForceVmChecks
			$wanted = 1
			$maxWanted = 1
		}

		# check disk SKU
		if (($_.SkuName -notlike 'Premium_?RS') -and ($_.SkuName -notlike '*SSD*') -and ($wanted -gt 1)) {
			write-logFileWarning "Shared disks are not supported for SKU '$($_.SkuName)'" `
								-stopWhenForceVmChecks
			$wanted = 1
			$maxWanted = 1
		}

		# check if disk is detached
		if (($_.ManagedBy.count -ne 0) -and $updateMode -and ($wanted -ne $current)) {
			if ($current -le $maxWanted) {
				write-logFileWarning "Cannot change Disk Max Shares for an attached disk" `
									-stopWhenForceVmChecks
				$wanted = $current
			}
			else {
				write-logFileError "Cannot change Max Shares of disk '$($_.Name)' to $wanted" `
									"because disk SKU is '$($_.SkuName)'" `
									"and the disk is attached to VM '$($_.VM)'"
			}
		}

		# check for bursting
		if (($_.BurstingEnabled -eq $True) -and ($wanted -gt 1)) {
			write-logFileWarning "Bursting is not supported for shared disks" `
								-stopWhenForceVmChecks
			$_.BurstingEnabled = $False
			write-logFileUpdates 'disks' $_.Name 'set busting' 'off'
		}

		# update
		if ($current -ne $wanted) {
			$_.MaxShares = $wanted
			$action = 'set'
		}
		else {
			$action = 'keep'
		}
		# output
		if ($_.MaxShares -eq 1) {
			write-logFileUpdates 'disks' $_.Name "$action max shares" $_.MaxShares -defaultValue
		}
		else {
			write-logFileUpdates 'disks' $_.Name "$action max shares" $_.MaxShares
		}
	}
}

#--------------------------------------------------------------
function show-paramSetDiskSize {
#--------------------------------------------------------------
	param (
		$disk
	)

	if (($Null -ne $disk.SizeGBNew) -and ($disk.SizeGBOld -ne $disk.SizeGBNew)) {
		write-logFileUpdates 'disks' $_.Name 'set size' "$($disk.SizeGB) GiB ($($disk.SizeTierName))" -NoNewLine
	}
	else {
		write-logFileUpdates 'disks' $_.Name 'keep size' "$($disk.SizeGB) GiB ($($disk.SizeTierName))" -NoNewLine
	}	
}

#--------------------------------------------------------------
function update-paramSetDiskTier {
#--------------------------------------------------------------
	# process RGCOPY parameter
	set-parameter 'setDiskTier' $setDiskTier
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$tierName = $script:paramConfig.ToUpper()
		test-values 'setDiskTier' $tierName @( 'P0', 'P1', 'P2', 'P3', 'P4', 'P6', 'P10', 'P15', 'P20', 'P30', 'P40', 'P50', 'P60', 'P70', 'P80') 'tier'
		$tierSizeGB = get-diskSize $tierName

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			$_.performanceTierGBNew = $tierSizeGB
		}
		get-ParameterRule
	}

	# output of changes
	$script:copyDisks.values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$current = $_.performanceTierGB
		if ($current -eq $_.SizeTierGB) {
			$current = 0
		}
		$wanted  = $_.performanceTierGBNew
		if ($Null -eq $wanted) {
			$wanted = $current
		}

		# max performance tier is P50 for P1 .. P50
		if (($wanted -gt 4096) -and ($_.SizeTierGB -le 4096)) {
			$wanted = 4096
		}

		# less than minimum or no tier
		if ($wanted -le $_.SizeTierGB) {
			$wanted = 0
		}

		# sku not allowed
		if ($_.SkuName -notlike 'Premium_?RS') {
			$_.performanceTierGB = 0
			$_.performanceTierName = $Null
			show-paramSetDiskSize $_
			write-logFileUpdates "no performance tier possible" -continue
		}
		# premium SKU
		else {
			show-paramSetDiskSize $_

			# update
			if ($wanted -eq 0) {
				$_.performanceTierGB = $_.SizeTierGB
			}
			else {
				$_.performanceTierGB = $wanted
			}
			$_.performanceTierName = get-diskTier $_.performanceTierGB $_.SkuName

			# output
			if (($wanted -eq 0) -and ($current -eq -0)) {
				write-logFileUpdates 'no performance tier' -continue
			}
			elseif ($wanted -eq 0) {
				write-logFileUpdates 'clear performance tier' -continue
			}
			elseif ($wanted -eq $current) {
				write-logFileUpdates 'keep performance tier' $_.performanceTierName -continue
			}
			else {
				write-logFileUpdates 'set performance tier' $_.performanceTierName -continue
			}
		}
	}
}

#--------------------------------------------------------------
function update-paramSetDiskBursting {
#--------------------------------------------------------------
	# process RGCOPY parameter
	set-parameter 'setDiskBursting' $setDiskBursting
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		test-values 'setDiskBursting' $script:paramConfig @('True','False') 'bursting'
		$burstingConfig = $script:paramConfig -eq 'True'

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			$_.BurstingEnabledNew = $burstingConfig
		}
		get-ParameterRule
	}

	# output of changes
	$script:copyDisks.values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$current = $_.BurstingEnabled
		$wanted  = $_.BurstingEnabledNew
		if ($Null -eq $wanted) {
			$wanted = $current
		}

		# check for premium storage
		if (($_.SkuName -notlike 'Premium*_?RS') -and ($wanted -eq $True)) {
			write-logFileWarning "Disk '$($_.Name)': Bursting is not supported for SKU '$($_.SkuName)'" `
								-stopWhenForceVmChecks
			$wanted = $False
		}

		# check for minimum size
		if (($_.SizeGB -le 512) -and ($wanted -eq $True)) {
			write-logFileWarning "Disk '$($_.Name)': Bursting is only supported for disks larger than 512 GiB'" `
								-stopWhenForceVmChecks
			$wanted = $False
		}

		# update
		if ($current -ne $wanted) {
			$_.BurstingEnabled = $wanted
			$action = 'set'
		}
		else {
			$action = 'keep'
		}
		# output
		if ($_.BurstingEnabled -eq $False) {
			write-logFileUpdates 'disks' $_.Name "$action disk bursting" $_.BurstingEnabled -defaultValue
		}
		else {
			write-logFileUpdates 'disks' $_.Name "$action disk bursting" $_.BurstingEnabled
		}
	}
}

#--------------------------------------------------------------
function update-paramSetDiskIOps {
#--------------------------------------------------------------
	# process RGCOPY parameter
	set-parameter 'setDiskIOps' $setDiskIOps
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$DiskIOPSReadWrite = $script:paramConfig1 -as [int]

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			$_.DiskIOPSReadWriteNew = $DiskIOPSReadWrite
		}
		get-ParameterRule
	}
}

#--------------------------------------------------------------
function update-paramSetDiskMBps {
#--------------------------------------------------------------
	# process RGCOPY parameter
	set-parameter 'setDiskMBps' $setDiskMBps
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$DiskMBpsReadWrite = $script:paramConfig1 -as [int]

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			$_.DiskMBpsReadWriteNew = $DiskMBpsReadWrite
		}
		get-ParameterRule
	}
}

#--------------------------------------------------------------
function update-diskMBpsAndIOps {
#--------------------------------------------------------------

	$script:copyDisks.values
	| Where-Object {($_.SkuName -notlike 'PremiumV2*') -and ($_.SkuName -notlike 'UltraSSD*')}
	| ForEach-Object {

		$_.DiskIOPSReadWrite = 0
		$_.DiskMBpsReadWrite = 0
	}

	$script:copyDisks.values
	| Where-Object Skip -ne $True
	| Where-Object {($_.SkuName -like 'PremiumV2*') -or ($_.SkuName -like 'UltraSSD*')}
	| Sort-Object Name
	| ForEach-Object {

		$diskName = $_.Name
		$SkuName = $_.SkuName
		$SizeGB = $_.SizeGB

		# wanted IOPS
		$currentIOPS = $_.DiskIOPSReadWrite
		if (!($currentIOPS -gt 0)) {
			$currentIOPS = 0
		}
		$wantedIOPS  = $_.DiskIOPSReadWriteNew
		if ($Null -eq $wantedIOPS) {
			$wantedIOPS = $currentIOPS
		}

		# wanted MBPS
		$currentMBPS = $_.DiskMBpsReadWrite
		if (!($currentMBPS -gt 0)) {
			$currentMBPS = 0
		}
		$wantedMBPS  = $_.DiskMBpsReadWriteNew
		if ($Null -eq $wantedMBPS) {
			$wantedMBPS = $currentMBPS
		}

		# get minimum required IOPS for given MBPS
		$requiredIOPS = get-requiredIOPS $wantedMBPS
		if ($wantedIOPS -lt $requiredIOPS) {
			write-logFileWarning "Increasing IOps for disk '$diskName' to $requiredIOPS" `
								 "  (needed for requested $wantedMBPS MB/sec)" -noSkip
			$wantedIOPS = $requiredIOPS
		}

		# correct IOPS
		$wantedIOPS = get-IOPS $wantedIOPS  $diskName  $SkuName $SizeGB
		$_.DiskIOPSReadWrite = $wantedIOPS
		if ($currentIOPS -ne $wantedIOPS) {
			write-logFileUpdates 'disks' $diskName "set disk IOps" $wantedIOPS
		}
		else {
			write-logFileUpdates 'disks' $diskName "keep disk IOps" $wantedIOPS
		}

		# corrected MBPS
		$wantedMBPS = get-MBPS $wantedMBPS  $diskName  $SkuName $wantedIOPS
		$_.DiskMBpsReadWrite = $wantedMBPS
		if ($currentMBPS -ne $wantedMBPS) {
			write-logFileUpdates 'disks' $diskName "set disk MBps" $wantedMBPS
		}
		else {
			write-logFileUpdates 'disks' $diskName "keep disk MBps" $wantedMBPS
		}
	}
}

#-------------------------------------------------------------
function get-requiredIOPS {
#-------------------------------------------------------------
	param (
		[int] $wantedMBPS
	)

	# maximum 0.25 MB/s per set IOPS
	$requiredIOPS = $wantedMBPS * 4

	return $requiredIOPS
}

#-------------------------------------------------------------
function get-IOPS {
#-------------------------------------------------------------
	param (
		[int] $wanted,
		[string] $diskname,
		[string] $diskSKU,
		[int] $sizeGB
	)

	# UltraSSD
	if ($diskSKU -like 'UltraSSD*') {
		# minimum:
		$min = $sizeGB
		if ($min -lt 100) {
			$min = 100
		}

		# calculated maximum:
		$max = $sizeGB * 300

		# absolute maximum
		if ($max -gt 400000) {
			$max = 400000
		}
	}

	# PremiumV2
	else {
		# minimum:
		$min = 3000

		# calculated maximum:
		$max = $sizeGB  * 500

		# absolute maximum
		if ($max -gt 80000) {
			$max = 80000
		}
	}
	
	if ($wanted -lt $min) {
		write-logFileWarning "Correcting IOps for disk '$diskname' from $wanted to minimum value $min"
		$wanted = $min
	}
	elseif ($wanted -gt $max) {
		write-logFileWarning "Correcting IOps for disk '$diskname' from $wanted to maximum value $max" `
							"  (you might have to increase disk size)" -noSkip
		$wanted = $max
	}

	return $wanted
}

#-------------------------------------------------------------
function get-MBPS {
#-------------------------------------------------------------
	param (
		[int] $wanted,
		[string] $diskname,
		[string] $diskSKU,
		[int] $DiskIOPSReadWrite
	)

	# UltraSSD
	if ($diskSKU -like 'UltraSSD*') {
		# minimum:
		$min = 1

		# calculated maximum:
		# 0.25 MB/s per set IOPS (rounded off to full MBPS)
		$max = ($DiskIOPSReadWrite - ($DiskIOPSReadWrite % 4)) / 4

		# absolute maximum
		if ($max -gt 10000) {
			$max = 10000
		}
	}

	# PremiumV2
	else {
		# minimum:
		$min = 125
	
		# calculated maximum:
		# 0.25 MB/s per set IOPS (rounded off to full MBPS)
		$max = ($DiskIOPSReadWrite - ($DiskIOPSReadWrite % 4)) / 4

		# absolute maximum
		if ($max -gt 1200) {
			$max = 1200
		}
	}

	if ($wanted -lt $min) {
		write-logFileWarning "Correcting MBps for disk '$diskname' from $wanted to minimum value $min"
		$wanted = $min
	}
	elseif ($wanted -gt $max) {
		write-logFileWarning "Correcting MBps for disk '$diskname' from $wanted to maximum value $max" `
							"  (you might have to increase IOps of disk and/or disk size)" -noSkip
		$wanted = $max
	}

	return $wanted
}

#--------------------------------------------------------------
function update-paramSetDiskCaching {
#--------------------------------------------------------------
	# process RGCOPY parameter
	set-parameter 'setDiskCaching' $setDiskCaching
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$cachingConfig	= $script:paramConfig1
		if ($Null -ne $cachingConfig) {
			test-values 'setDiskCaching' $cachingConfig @('ReadOnly','ReadWrite','None') 'caching'
		}

		$waEnabledConfig = $script:paramConfig2
		if ($Null -ne $waEnabledConfig) {
			test-values 'setDiskCaching' $waEnabledConfig @('True','False') 'writeAccelerator'
			$waEnabledConfig = $waEnabledConfig -eq 'True'
		}

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			if ($Null -ne $cachingConfig) {
				$_.CachingNew = $cachingConfig
			}
			if ($Null -ne $waEnabledConfig) {
				$_.WriteAcceleratorEnabledNew = $waEnabledConfig
			}
		}
		get-ParameterRule
	}

	# save maximum number of WA disks per VM
	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$_.waMax = $script:vmSkus[$_.VmSize].MaxWriteAcceleratorDisksAllowed
		$_.waRemaining = $_.waMax
	}

	# output of changes
	$script:copyDisks.values
	| Where-Object Skip -ne $True
	| Where-Object {$_.VM.length -ne 0}
	| Sort-Object Name
	| ForEach-Object {

		$vmName = $_.VM

		$current = $_.Caching
		$wanted  = $_.CachingNew
		if ($Null -eq $wanted) {
			$wanted = $current
		}

		$currentWA = $_.WriteAcceleratorEnabled
		$wantedWA  = $_.WriteAcceleratorEnabledNew
		if ($Null -eq $wantedWA) {
			$wantedWA = $currentWA
		}

		# no caching for Ultra SSD
		if (($_.SkuName -in @('UltraSSD_LRS', 'PremiumV2_LRS')) -and ($wanted -ne 'None')) {
			write-logFileWarning "Caching '$wanted' not supported for disk SKU '$($_.SkuName)'" `
								-stopWhenForceVmChecks
			$wanted = 'None'
		}

		# ReadOnly caching not allowed for shared disks
		if (($_.MaxShares -gt 1) -and ($wanted -eq 'ReadOnly')) {
			write-logFileWarning "Caching '$wanted' not supported for shared disks" `
								-stopWhenForceVmChecks
			$wanted = 'None'
		}

		# WA only supported for premium disks
		if (($wantedWA -eq $True) -and ($_.SkuName -notin @('Premium_LRS', 'Premium_ZRS', 'UltraSSD_LRS', 'PremiumV2_LRS'))) {
			write-logFileWarning "Write accelerator not supported for disk SKU '$($_.SkuName)'" `
								-stopWhenForceVmChecks
			$wantedWA = $False
		}	

		# # WA not supported for OS disk ???
		# if (($wantedWA -eq $True) -and ($_.OsType.length -ne 0) -and !$updateMode) {
		# 	write-logFileError "Write Accelerator not supported by RGCOPY for OS disks" `
		# 						"You cannot create a snapshot of an OS disk with Write Accelerator" `
		# 						"Turn off Write Accelerator using RGCOPY Update Mode first"
		# }

		# check maximum number of WA disks
		if ($wantedWA -eq $True) {
			if ($script:copyVMs[$vmName].waRemaining -gt 0) {
				$script:copyVMs[$vmName].waRemaining--
			}
			else {
				$waMax  = $script:copyVMs[$vmName].waMax
				$vmSize = $script:copyVMs[$vmName].VmSize
				if ($waMax -gt 0) {
					write-logFileWarning "Size '$vmSize' of VM '$vmName' only supports $waMax write-acceleratored disk(s)" `
										-stopWhenForceVmChecks
				}
				else {
					write-logFileWarning "Size '$vmSize' of VM '$vmName' does not support Write Accelerator" `
										-stopWhenForceVmChecks
				}
				$wantedWA = $False
			}
		}

		# correct disk caching for WA
		if (($wantedWA -eq $True) -and ($wanted -eq 'ReadWrite')) {
			write-logFileWarning "Caching '$wanted' not supported when write accelerator is enabled" `
								-stopWhenForceVmChecks
			$wanted = 'ReadOnly'
		}
		
		# shared disks: disable chaching because current RGCOPY data structures do not support this
		if ($_.ManagedBy.count -gt 1) {
			if ($wanted -ne 'None') {
				$wanted = 'None'
				write-logFileWarning "RCOPY does not support caching of disks that are attached to more than one VM" `
									-stopWhenForceVmChecks
			}
			if ($wantedWA -ne $False) {
				$wantedWA = $False
				write-logFileWarning "RCOPY does not support write accelerator of disks that are attached to more than one VM" `
									-stopWhenForceVmChecks
			}
		}
		
		# update
		if ($current -ne $wanted) {
			$_.Caching = $wanted
			$action = 'set'
		}
		else {
			$action = 'keep'
		}
		# output
		if ($_.Caching -eq 'None') {
			write-logFileUpdates 'disks' $_.Name "$action caching" $_.Caching -defaultValue
		}
		else {
			write-logFileUpdates 'disks' $_.Name "$action caching" $_.Caching
		}

		# update
		if ($currentWA -ne $wantedWA) {
			$_.WriteAcceleratorEnabled = $wantedWA
			$action = 'set'
		}
		else {
			$action = 'keep'
		}
		# output
		if ($_.WriteAcceleratorEnabled -eq $False) {
			write-logFileUpdates 'disks' $_.Name "$action write accelerator" $_.WriteAcceleratorEnabled -defaultValue
		}
		else {
			write-logFileUpdates 'disks' $_.Name "$action write accelerator" $_.WriteAcceleratorEnabled
		}
	}
}

#--------------------------------------------------------------
function update-paramSetAcceleratedNetworking {
#--------------------------------------------------------------
	# process RGCOPY parameter
	set-parameter 'setAcceleratedNetworking' $setAcceleratedNetworking
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		test-values 'setAcceleratedNetworking' $script:paramConfig @('True','False') 'AcceleratedNetworking'
		$acceleratedNW = $script:paramConfig -eq 'True'

		$script:copyNICs.values
		| Where-Object {$_.NicNameNew -in $script:paramNICs}
		| ForEach-Object {

			$_.EnableAcceleratedNetworkingNew = $acceleratedNW
		}
		get-ParameterRule
	}

	# save maximum number of acc NICs per VM
	$script:copyVMs.Values
	| ForEach-Object {

		$vmSize = $_.VmSize

		if ($vmSize -in @(
					'Standard_DS1_v2',
					'Standard_D1_v2',
					'Standard_D2_v3',
					'Standard_D2s_v3',
					'Standard_D2_v4',
					'Standard_D2s_v4',
					'Standard_D2a_v4',
					'Standard_D2as_v4',
					'Standard_D2d_v4',
					'Standard_D2ds_v4',
					'Standard_E2_v3',
					'Standard_E2s_v3',
					'Standard_E2a_v4',
					'Standard_E2as_v4',
					'Standard_E2d_v4',
					'Standard_E2ds_v4',
					'Standard_E2_v4',
					'Standard_E2s_v4',
					'Standard_F2s_v2') `
		) {
			$accNwMax = 1
		}
		elseif ($vmSize -in @(
					'Standard_D2_v5',
					'Standard_D2s_v5',
					'Standard_D2d_v5',
					'Standard_D2ds_v5',
					'Standard_E2_v5',
					'Standard_E2s_v5',
					'Standard_E2d_v5',
					'Standard_E2ds_v5') `
		) {
			$accNwMax = 2
		}
		elseif ($script:vmSkus[$vmSize].AcceleratedNetworkingEnabled -eq $True) {
			$accNwMax = 9999
		}
		else {
			$accNwMax = 0
		}

		$_.accNwMax       = $accNwMax
		$_.accNwRemaining = $accNwMax
	}

	# output of changes
	$script:copyNICs.values
	| Where-Object Skip -ne $True
	| Sort-Object NicNameNew
	| ForEach-Object {

		$nicName	= $_.NicNameNew
		$vmName		= $_.VmName

		$current	= $_.EnableAcceleratedNetworking
		$wanted		= $_.EnableAcceleratedNetworkingNew
		if ($Null -eq $wanted) {
			$wanted = $current
		}

		# NIC not attached
		if ($vmName.length -eq 0) {
			if (($wanted -eq $True) -and ($current -eq $False)) {
				# NICs attached to NetApp volumes do not support Accelerated Networking
				write-logFileWarning "NIC '$nicName' not attached to a VM, setting of Accelerated Networking not possible"
				$wanted = $False
			}
			else {
				write-logFileWarning "NIC '$nicName' not attached to a VM"
				$wanted = $current
			}
		}
		# NIC attached
		else {

			# check maximum number of acc NICs
			if ($wanted -eq $True) {
				if ($script:copyVMs[$vmName].accNwRemaining -gt 0) {
					$script:copyVMs[$vmName].accNwRemaining--
				}
				else {
					$accNwMax = $script:copyVMs[$vmName].accNwMax
					$vmSize   = $script:copyVMs[$vmName].VmSize
					if ($accNwMax -gt 0) {
						write-logFileWarning "Size '$vmSize' of VM '$vmName' only supports $accNwMax NICs with Accelerated Networking" `
											-stopWhenForceVmChecks
					}
					else {
						write-logFileWarning "Size '$vmSize' of VM '$vmName' does not support Accelerated Networking" `
											-stopWhenForceVmChecks
					}
					$wanted = $False
				}
			}
		}

		# update
		if ($current -ne $wanted) {
			$_.EnableAcceleratedNetworking = $wanted
			$action = 'set'
		}
		else {
			$action = 'keep'
		}
		# output
		if ($_.EnableAcceleratedNetworking -eq $False) {
			write-logFileUpdates 'networkInterfaces' $nicName "$action Accelerated Networking" $_.EnableAcceleratedNetworking -defaultValue
		}
		else {
			write-logFileUpdates 'networkInterfaces' $nicName "$action Accelerated Networking" $_.EnableAcceleratedNetworking
		}
	}
}

#--------------------------------------------------------------
function new-SnapshotsVolumes {
#--------------------------------------------------------------
	if ($script:snapshotList.count -eq 0) {
		return
	}

	# using parameters for parallel execution
	$scriptParameter =  "`$netAppSnapshotName = '$netAppSnapshotName';"

	# parallel running script
	$script = {
		Write-Output "... creating snapshot on volume $($_.Volume)"

		# remove snapshot
		Remove-AzNetAppFilesSnapshot `
			-ResourceGroupName	$_.RG `
			-AccountName		$_.Account `
			-PoolName			$_.Pool `
			-VolumeName			$_.Volume `
			-Name				$netAppSnapshotName `
			-WarningAction 'SilentlyContinue' `
			-ErrorAction 'SilentlyContinue' | Out-Null

		# create snapshot
		New-AzNetAppFilesSnapshot `
			-ResourceGroupName	$_.RG `
			-Location			$_.Location `
			-AccountName		$_.Account `
			-PoolName			$_.Pool `
			-VolumeName			$_.Volume `
			-Name				$netAppSnapshotName `
			-WarningAction 'SilentlyContinue' `
			-ErrorAction 'Stop' | Out-Null
		if (!$?) {throw "Creation of NetApp snapshot on volume $($_.Volume) failed"}

		Write-Output "snapshot on volume $($_.Volume) created"
	}

	# start execution
	write-stepStart "CREATE NetApp SNAPSHOTS" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	$script:snapshotList.Values
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Creation of NetApp snapshots failed"
	}
	write-stepEnd
}

#--------------------------------------------------------------
function new-snapshots {
#--------------------------------------------------------------
	# using parameters for parallel execution
	$scriptParameter = "`$sourceRG = '$sourceRG';"

	# parallel running script
	$script = {

		$SnapshotName			= $_.SnapshotName
		if ($_.IncrementalSnapshots) {
			Write-Output "... creating inc. snapshot $SnapshotName"
		}
		else {
			Write-Output "... creating full snapshot $SnapshotName"
		}

		# revoke Access
		try {
			Revoke-AzSnapshotAccess `
				-ResourceGroupName  $sourceRG `
				-SnapshotName       $SnapshotName `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop' | Out-Null
		}
		catch { <# snapshot not found #> }

		# remove snapshot
		Remove-AzSnapshot `
			-ResourceGroupName  $sourceRG `
			-SnapshotName      	$SnapshotName `
			-Force `
			-WarningAction 'SilentlyContinue' `
			-ErrorAction 'Stop' | Out-Null

		# create snapshot config
		$parameter = @{
			SourceUri		= $_.Id
			CreateOption	= 'Copy'
			Location		= $_.Location
			ErrorAction		= 'Stop'
		}

		if ($_.OsType.length -ne 0) { 
			$parameter.OsType = $_.OsType
		}

		if ($_.IncrementalSnapshots) {
			$parameter.Incremental = $True
		}

		$conf = New-AzSnapshotConfig @parameter
		if (!$?) {throw "Creation of snapshot config '$SnapshotName' failed"}

		# create snapshot
		New-AzSnapshot `
			-Snapshot           $conf `
			-SnapshotName       $SnapshotName `
			-ResourceGroupName  $sourceRG `
			-WarningAction 'SilentlyContinue' `
			-ErrorAction 'Stop' | Out-Null
		if (!$?) {throw "Creation of snapshot '$SnapshotName' failed"}

		Write-Output "$SnapshotName created"
	}

	#--------------------------------------------------------------
	# create snapshots
	write-stepStart "CREATE SNAPSHOTS" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP

	$script:copyDisks.Values
	| Where-Object { (($_.DiskSwapNew -eq $True) -or (($_.Skip -ne $True) -and ($_.DiskSwapOld -ne $True))) }
	| Where-Object SnapshotSwap -ne $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Creation of snapshots failed"
	}
	
	write-stepEnd

	$incrementalSnapshots = @( $script:copyDisks.Values
								| Where-Object { (($_.DiskSwapNew -eq $True) -or (($_.Skip -ne $True) -and ($_.DiskSwapOld -ne $True))) }
								| Where-Object SnapshotSwap -ne $True
								| Where-Object IncrementalSnapshots -eq $True )

	if ($incrementalSnapshots.count -gt 0) {

		write-logFileWarning "Do not manually create INCREMENTAL snapshots while RGCOPY is running"
		write-logFile

		if (!$(wait-completion "INCREMENTAL SNAPSHOTS" `
					'snapshots' $sourceRG $snapshotWaitCreationMinutes)) {

			write-logFileError "Incremental Snapshot completion did not finish within $snapshotWaitCreationMinutes minutes"
		}
	}
}

#--------------------------------------------------------------
function wait-CopySnapshots {
#--------------------------------------------------------------
	$savedSub = $script:currentSub
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************


	if (!$(wait-completion "SNAPSHOT COPY" `
		'snapshots' $targetRG $snapshotWaitCopyMinutes)) {
		write-logFileError "Incremental Snapshot completion did not finish within $snapshotWaitCopyMinutes minutes"
		}

	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function copy-snapshots {
#--------------------------------------------------------------
	$savedSub = $script:currentSub
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	$secureToken= Get-AzAccessToken -AsSecureString -WarningAction 'SilentlyContinue'
	$token = ConvertFrom-SecureString $secureToken.Token -AsPlainText

	# update $script:copyDisks
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$_.TokenRestAPI = $Null

		if ($useRestAPI) {
			$_.TokenRestAPI = $token
		}

		if (!$skipWorkarounds) {
			# TrustedLaunch not supported yet with Az cmdlets
			if ($_.SecurityType.Length -ne 0) {
				$_.TokenRestAPI = $token
			}
		}
	}

	# using parameters for parallel execution
	$scriptParameter = @"
		`$targetLocation		= '$targetLocation'
		`$targetRG				= '$targetRG'
		`$sourceRG				= '$sourceRG'
		`$targetSubID			= '$targetSubID'
		`$sourceSubID			= '$sourceSubID'
"@

	#--------------------------------------------------------------
	# parallel running script
	$script = {

		$SnapshotName	= $_.SnapshotName
		$SnapshotId		= $_.SnapshotId
		$token			= $_.TokenRestAPI
		
		if (!$?) {
			throw "Getting snapshot'$SnapshotName' failed"
		}

		if ($Null -ne $token) {
			#--------------------------------------------------------------
			# use REST API
			Write-Output "... copying '$SnapshotName' to snapshot using REST API"

			$body = @{
				location = $targetLocation
				properties = @{
					creationData = @{
						createOption = 'CopyStart'
						sourceResourceId = $SnapshotId
					}
				}
			}

			if ($_.IncrementalSnapshots) {
				$body.properties.incremental = $True
			}

			if ($_.SecurityType.Length -ne 0) {
				$body.properties.securityProfile = @{securityType = $_.SecurityType}
			}

			if ($_.OsType.Length -ne 0) {
				$body.properties.osType = $_.OsType
			}

			if ($_.HyperVGeneration.Length -ne 0) {
				$body.properties.hyperVGeneration = $_.HyperVGeneration
			}

			$apiVersion='2023-10-02'
			$restUri = "https://management.azure.com/subscriptions/$targetSubID/resourceGroups/$targetRG/providers/Microsoft.Compute/snapshots/$SnapshotName`?api-version=$apiVersion"

			$invokeParam = @{
				Uri				= $restUri
				Method			= 'Put'
				ContentType		= 'application/json'
				Headers			= @{ Authorization = "Bearer $token" }
				Body			= ($body | ConvertTo-Json)
				WarningAction 	= 'SilentlyContinue'
				ErrorAction		= 'Stop'
			}

			try {
				Invoke-WebRequest @invokeParam | Out-Null
			}
			catch {
				$error
				throw "'$SnapshotName' snapshot copy failed"
			}
		}

		else {
			#--------------------------------------------------------------
			# use Az cmdlet
			Write-Output "... copying '$SnapshotName' to snapshot using Az cmdlet"

			# create snapshot config
			$param = @{
				Location			= $targetLocation
				CreateOption		= 'CopyStart'
				SourceResourceId	= $SnapshotId
				WarningAction 		= 'SilentlyContinue'
				ErrorAction			= 'Stop'
			}

			if ($_.IncrementalSnapshots) {
				$param.Incremental = $True
			}

			$conf = New-AzSnapshotConfig @param
			if (!$?) {
				$error
				throw "'$SnapshotName' snapshot copy failed"
			}

			# create snapshot copy
			New-AzSnapshot `
				-Snapshot           $conf `
				-SnapshotName       $SnapshotName `
				-ResourceGroupName  $targetRG `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop' | Out-Null
			#--------------------------------------------------------------
		}

		if (!$?) {
			throw "'$SnapshotName' snapshot copy failed"
		}
		Write-Output "'$SnapshotName' snapshot copy started"
	}

	#--------------------------------------------------------------
	# start execution
	write-stepStart "START COPY SNAPSHOTS" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP

	$script:copyDisks.Values
	| Where-Object { (($_.DiskSwapNew -eq $True) -or (($_.Skip -ne $True) -and ($_.DiskSwapOld -ne $True))) }
	| Where-Object SnapshotCopy -eq $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Copy of snapshots failed"
	}

	write-stepEnd
	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
$script:waitCount = 0
$script:waitArray = 1,1,1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2, 3,3,3,3,3,3, 4,4,4,4,4, 5,5,5,5, 6,6,6, 7,8,9
#--------------------------------------------------------------
function get-waitTime {
#--------------------------------------------------------------
	if ($script:waitCount -ge $script:waitArray.count) {
		$waitTime = 10
	}
	else {
		$waitTime = $script:waitArray[$script:waitCount]
	}

	$script:waitCount++
	return $waitTime
}

#--------------------------------------------------------------
function wait-completion {
#--------------------------------------------------------------
	param (
		$step,
		$type,
		$resourceGroup,
		$waitMinutes
	)

	$script:waitCount = 0

	write-stepStart "CHECK $step COMPLETION"
	$count = 0

	do {
		switch ($type) {
			'disks' {
				$res = @(
					Get-AzDisk `
						-ResourceGroupName $resourceGroup `
						-ErrorAction 'SilentlyContinue'
				)
				test-cmdlet 'Get-AzDisk'  "Could not get disks of resource group '$resourceGroup'"
			}

			'snapshots' {
				$res = @(
					Get-AzSnapshot `
						-ResourceGroupName $resourceGroup `
						-ErrorAction 'SilentlyContinue'
				)
				test-cmdlet 'Get-AzSnapshot'  "Could not get snapshots of resource group '$resourceGroup'"
			}

			Default {
				write-logFileError "Internal RGCOPY error"
			}
		}

		write-logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') $step COMPLETION"
		$percentAll = 100
		foreach ($item in $res) {
			if (($type -ne 'snapshots') -or ($item.Incremental -eq $True)) {
				$percent = 100
				if ($Null -ne $item.CompletionPercent) {
					$percent = $item.CompletionPercent
					if ($percentALL -gt $percent) {
						$percentALL = $percent
					}
				}
	
				$padPercent = $(' ' * 3) + $percent
				$padPercent = $padPercent.SubString($padPercent.length - 3, 3)
	
				if ($percent -eq 100) {
					write-logFile "$padPercent`% $($item.Name)" -ForegroundColor 'Green'
				}
				else {
					write-logFile "$padPercent`% $($item.Name)" -ForegroundColor 'DarkYellow'
				}
			}
		}
		write-logFile

		if ($percentAll -lt 100) {
			$delayMinutes = get-waitTime
			Start-Sleep -seconds (60 * $delayMinutes)
			$count += $delayMinutes
		}
	} 
	while ( ($percentAll -lt 100) -and ($count -lt $waitMinutes) )

	write-stepEnd
	return ($percentAll -eq 100) 
}

#--------------------------------------------------------------
function remove-snapshots {
#--------------------------------------------------------------
	param (
		$resourceGroup,
		$snapshotNames
	)

	# using parameters for parallel execution
	$scriptParameter = "`$resourceGroup = '$resourceGroup';"

	# parallel running script
	$script = {
		$SnapshotName = $_
		Write-Output "... removing $SnapshotName"
		try {
			Revoke-AzSnapshotAccess `
				-ResourceGroupName  $resourceGroup `
				-SnapshotName       $SnapshotName `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop' | Out-Null
		}
		catch [Microsoft.Azure.Commands.Compute.Common.ComputeCloudException] { <# snapshot not found #> }

		Remove-AzSnapshot `
			-ResourceGroupName  $resourceGroup `
			-SnapshotName      	$SnapshotName `
			-Force `
			-WarningAction 'SilentlyContinue' `
			-ErrorAction 'Stop' | Out-Null

		Write-Output "$SnapshotName removed"
	}

	# start execution
	write-stepStart "DELETE SNAPSHOTS IN RESOURCE GROUP '$resourceGroup'" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	$snapshotNames
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileWarning "Deletion of snapshots failed in resource group '$resourceGroup'"
	}

	write-stepEnd
}

#--------------------------------------------------------------
function add-ipRule {
#--------------------------------------------------------------
	if (!$msInternalVersion) {
		return
	}

	$savedSub = $script:currentSub
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	$ip = $Null

	# get public IP of local PC: first try
	try {
		$ip = (Invoke-WebRequest ifconfig.me/ip -ErrorAction 'Stop').Content.Trim()
	}
	catch {
		$ip = $Null
	}

	# check syntax for IPv4
	if ($ip -notmatch '^\d+\.\d+\.\d+\.\d+$') {
		# second try
		$ip = $Null
		try {
			$ip = (Resolve-DnsName `
				-Name			myip.opendns.com `
				-Server			208.67.222.220 `
				-ErrorAction	'Stop' `
				-WarningAction	'SilentlyContinue').IPAddress	
		}
		catch {
			$ip = $Null
		}
	}

	# check syntax for IPv4
	if ($ip -notmatch '^\d+\.\d+\.\d+\.\d+$') {
		write-logFileError 'Getting public IP Address of local PC failed'
	}

	write-logFile "Granting access to storage account '$targetSA' for public IP $ip ..."
	write-logFileWarning "All VPN connections must be closed"

	$vpns = get-vpnConnection -ErrorAction 'SilentlyContinue'
	$connectedVpns = ($vpns | Where-Object ConnectionStatus -eq 'Connected').Name
	if ($Null -ne $connectedVpns) {
		write-logFileError "Connected to VPN '$($connectedVpns -as [string])'"
	}

	Add-AzStorageAccountNetworkRule `
		-ResourceGroupName	$targetRG `
		-Name 				$targetSA `
		-IPAddressOrRange 	$ip `
		-ErrorAction		'SilentlyContinue' | Out-Null
	test-cmdlet 'Add-AzStorageAccountNetworkRule'  "Granting access to storage account '$targetSA' for public IP $ip failed"

	set-context $savedSub # *** CHANGE SUBSCRIPTION **************

	# wait before creating delegation token
	Start-Sleep -Seconds 10
}

#--------------------------------------------------------------
function new-delegationToken {
#--------------------------------------------------------------
	if (!$msInternalVersion) {
		return
	}

	$savedSub = $script:currentSub
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	write-logFile "Creating delegation token..."

	$context = New-AzStorageContext `
				-StorageAccountName		$targetSA `
				-UseConnectedAccount `
				-ErrorAction			'SilentlyContinue'
	test-cmdlet 'New-AzStorageContext'  "Getting Context for storage account '$targetSA' failed"

	$StartTime = (Get-date).ToUniversalTime()
	$EndTime = $startTime.AddDays(6)

	$script:delegationToken = New-AzStorageContainerSASToken `
			-Name			$targetSaContainer `
			-Permission 	'crwdl' `
			-StartTime		$startTime `
			-ExpiryTime		$endTime `
			-context		$context `
			-ErrorAction	'SilentlyContinue'
	test-cmdlet 'New-AzStorageContainerSASToken'  "Creating delegation token for storage account '$targetSA' failed"	

	# save token for each disk
	$script:copyDisks.values
	| ForEach-Object {
		$_.DelegationToken = $script:delegationToken
	}

	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function grant-access {
#--------------------------------------------------------------
	$secureToken = Get-AzAccessToken -AsSecureString -WarningAction 'SilentlyContinue'
	$token = ConvertFrom-SecureString $secureToken.Token -AsPlainText

	# update $script:copyDisks
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$_.TokenRestAPI = $Null

		if ($useRestAPI) {
			$_.TokenRestAPI = $token
		}

		if (!$skipWorkarounds) {
			# LogicalSectorSize not supported yet with Grant-AzSnapshotAccess
			if ($_.LogicalSectorSize -eq 4096) {
				$_.TokenRestAPI = $token
			}
		}
	}

	# using parameters for parallel execution
	$scriptParameter = @"
		`$sourceRG				= '$sourceRG'
		`$sourceSubID			= '$sourceSubID'
		`$grantTokenTimeSec		= '$grantTokenTimeSec'
"@

	#--------------------------------------------------------------
	# parallel running script
	$script = {
		$SnapshotName	= $_.SnapshotName
		$token			= $_.TokenRestAPI

		if ($Null -ne $token) {
			#--------------------------------------------------------------
			# use REST API
			Write-Output "... granting '$SnapshotName' using REST API"
			
			$body = @{
				access = 'Read'
				durationInSeconds = $grantTokenTimeSec
			}

			if ($_.LogicalSectorSize -eq 4096) {
				$body.fileFormat = 'VHDX'
			}

			$apiVersion='2023-10-02'
			$restUri = "https://management.azure.com/subscriptions/$sourceSubID/resourceGroups/$sourceRG/providers/Microsoft.Compute/snapshots/$SnapshotName/beginGetAccess?api-version=$apiVersion"

			$invokeParam = @{
				Uri				= $restUri
				Method			= 'Post'
				ContentType		= 'application/json'
				Headers			= @{ Authorization = "Bearer $token" }
				Body			= ($body | ConvertTo-Json)
				WarningAction 	= 'SilentlyContinue'
				ErrorAction		= 'Stop'
			}

			try {
				$response = Invoke-WebRequest @invokeParam
			}
			catch {
				throw "'$SnapshotName' granting failed (Post)"
			}

			$restUri = ($response).Headers.Location

			$invokeParam = @{
				Uri				= "$restUri" # conversion of data type needed
				Method			= 'Get'
				ContentType		= 'application/json'
				Headers			= @{ Authorization = "Bearer $token" }
				WarningAction 	= 'SilentlyContinue'
				ErrorAction		= 'Stop'
			}

			try {
				$response = Invoke-WebRequest @invokeParam
			}
			catch {
				throw "'$SnapshotName' granting failed (Get)"
			}
			Write-Output "'$SnapshotName' granted"

			$_.AbsoluteUri = (Convertfrom-json($response).Content).accessSAS
		}

		else {
			#--------------------------------------------------------------
			# use Az cmdlet
			Write-Output "... granting '$SnapshotName' using Az cmdlet"
	
			$sas = Grant-AzSnapshotAccess `
				-ResourceGroupName  $sourceRG `
				-SnapshotName       $SnapshotName `
				-Access             'Read' `
				-DurationInSecond   $grantTokenTimeSec `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop'

			if ($?) {
				Write-Output "'$SnapshotName' granted"
			}
			else {
				throw "'$SnapshotName' granting failed"
			}
	
			$_.AbsoluteUri = $sas.AccessSAS
			#--------------------------------------------------------------
		}
	}

	#--------------------------------------------------------------
	# start execution
	write-stepStart "GRANT ACCESS TO SNAPSHOTS" $maxDOP

	# add IP rule
	add-ipRule

	write-logFile
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP

	# granting BLOB access in parallel
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| Where-Object BlobCopy -eq $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host

	if (!$?) {
		write-logFileError "Grant Access to snapshot failed"
	}
	write-logFile

	# create delegation token
	new-delegationToken
	write-stepEnd
}

#--------------------------------------------------------------
function revoke-access {
#--------------------------------------------------------------
	# using parameters for parallel execution
	$scriptParameter =  "`$sourceRG = '$sourceRG';"

	# parallel running script
	$script = {
		$SnapshotName = $_.SnapshotName
		Write-Output "... revoking access from '$SnapshotName'"

		Revoke-AzSnapshotAccess `
			-ResourceGroupName  $sourceRG `
			-SnapshotName       $SnapshotName `
			-WarningAction 'SilentlyContinue' `
			-ErrorAction 'Stop' | Out-Null
		if (!$?) {throw "Revoke access from '$SnapshotName' failed"}

		Write-Output "'$SnapshotName' revoked"
	}

	# start execution
	write-stepStart "REVOKE ACCESS FROM SNAPSHOTS" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	try {
		$script:copyDisks.Values
		| Where-Object Skip -ne $True
		| Where-Object BlobCopy -eq $True
		| ForEach-Object @param
		| Tee-Object -FilePath $logPath -append
		| Out-Host
		if (!$?) {
			write-logFileError "Revoke access from snapshots failed"
		}
	}
	catch {
		write-logFileError "Revoke-AzSnapshotAccess failed" `
							"If Azure credentials have expired then run Connect-AzAccount" `
							"and restart RGCOPY with ADDITIONAL parameter 'restartRemoteCopy'" `
							-lastError
	}
	write-stepEnd
}

#--------------------------------------------------------------
function get-saKey {
#--------------------------------------------------------------
	param (
		$mySub,
		$myRG,
		$mySA
	)

	if ($msInternalVersion -or ($Null -ne $script:targetSaKey)) {
		return
	}

	$savedSub = $script:currentSub
	set-context $mySub # *** CHANGE SUBSCRIPTION **************

	# Get Storage Account KEY
	$script:targetSaKey = (Get-AzStorageAccountKey `
								-ResourceGroupName	$myRG `
								-AccountName 		$mySA `
								-WarningAction		'SilentlyContinue' `
								-ErrorAction		'SilentlyContinue' `
						| Where-Object KeyName -eq 'key1').Value

	test-cmdlet 'Get-AzStorageAccountKey'  "Could not get key for Storage Account '$mySA'"

	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function start-copyBlobs {
#--------------------------------------------------------------
	write-stepStart "START COPY TO BLOB" $maxDOP

	get-saKey $targetSub $targetRG $targetSA

	# using parameters for parallel execution
	$scriptParameter =  "`$targetSaContainer = '$targetSaContainer';"
	$scriptParameter += "`$targetSA = '$targetSA';"
	$scriptParameter += "`$targetSaKey = '$($script:targetSaKey -replace '''', '''''')';"

	# header using Delegation Token
	if ($msInternalVersion) {
		write-logFile "Using Delegation Token"

		$sc1 = {
			Write-Output "... copying '$($_.SnapshotName)' to BLOB '$($_.Name).vhd'"

			$destinationContext = New-AzStorageContext `
									-StorageAccountName		$targetSA `
									-SasToken				$_.DelegationToken `
									-ErrorAction			'SilentlyContinue'
		}
	}

	# header using Storage Account Key
	else {
		write-logFile "Using Storage Account Key"
		$sc1 = {
			Write-Output "... copying '$($_.SnapshotName)' to BLOB '$($_.Name).vhd'"
			
			$destinationContext = New-AzStorageContext `
									-StorageAccountName   	$targetSA `
									-StorageAccountKey    	$targetSaKey `
									-ErrorAction			'SilentlyContinue' `
									-WarningAction			'SilentlyContinue'
		}	
	}

	# body
	$sc2 = {

		$param = @{
			DestContainer	= $targetSaContainer
			DestContext     = $destinationContext
			DestBlob        = "$($_.Name).vhd"
			AbsoluteUri     = $_.AbsoluteUri
			Force			= $True
			WarningAction	= 'SilentlyContinue'
			ErrorAction		= 'Stop' 
		}
		
		Start-AzStorageBlobCopy @param | Out-Null
		# StandardBlobTier = 'Cool' cannot be set to PageBlob
		if (!$?) {
			Write-Host $param
			throw "Creation of Storage Account BLOB $($_.Name).vhd failed"
		}
		Write-Output "$($_.Name).vhd"
	}


	# start execution
	$script = [Scriptblock]::Create(($sc1 -as [string]) + ($sc2 -as [string]))
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| Where-Object SnapshotCopy -ne $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Creation of Storage Account BLOB failed"
	}
	write-stepEnd
}

#--------------------------------------------------------------
function stop-copyBlobs {
#--------------------------------------------------------------
	write-stepStart "STOP COPY TO BLOB" $maxDOP

	get-saKey $targetSub $targetRG $targetSA

	# using parameters for parallel execution
	$scriptParameter =  "`$targetSaContainer = '$targetSaContainer';"
	$scriptParameter += "`$targetSA = '$targetSA';"
	$scriptParameter += "`$targetSaKey = '$($script:targetSaKey -replace '''', '''''')';"
	
	# header using Delegation Token
	if ($msInternalVersion) {
		write-logFile "Using Delegation Token"

		$sc1 = {
			$diskname = $_.Name
			Write-Output "... stopping BLOB copy $diskname.vhd"

			$destinationContext = New-AzStorageContext `
									-StorageAccountName		$targetSA `
									-SasToken				$_.DelegationToken `
									-ErrorAction			'SilentlyContinue'
		}
	}

	# header using Storage Account Key
	else {
		write-logFile "Using Storage Account Key"

		$sc1 = {
			$diskname = $_.Name
			Write-Output "... stopping BLOB copy $diskname.vhd"

			$destinationContext = New-AzStorageContext `
									-StorageAccountName   	$targetSA `
									-StorageAccountKey    	$targetSaKey `
									-ErrorAction			'SilentlyContinue' `
									-WarningAction			'SilentlyContinue'
		}	
	}

	# body
	$sc2 = {
		try {
			Stop-AzStorageBlobCopy `
				-Container    $targetSaContainer `
				-Context      $destinationContext `
				-Blob         "$diskname.vhd" `
				-Force `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop' | Out-Null

			Write-Output "$diskname.vhd"
		}
		catch  { 
			Write-Output "FAILED: $diskname.vhd"
		}
	}

	# start execution
	$script = [Scriptblock]::Create(($sc1 -as [string]) + ($sc2 -as [string]))
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| Where-Object SnapshotCopy -ne $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Stop Copy Disk failed"
	}
	write-stepEnd
}

#--------------------------------------------------------------
function wait-copyBlobs {
#--------------------------------------------------------------
	write-stepStart "CHECK BLOB COPY COMPLETION" -skipLF

	get-saKey $targetSub $targetRG $targetSA

	# using Delegation Token
	if ($msInternalVersion) {
		write-logFile "Using Delegation Token"

		$destinationContext = New-AzStorageContext `
								-StorageAccountName		$targetSA `
								-SasToken				$script:delegationToken `
								-ErrorAction			'SilentlyContinue'
	}

	# using Storage Account Key
	else {
		write-logFile "Using Storage Account Key"

		$destinationContext = New-AzStorageContext `
								-StorageAccountName   	$targetSA `
								-StorageAccountKey    	$targetSaKey `
								-ErrorAction 			'SilentlyContinue' `
								-WarningAction			'SilentlyContinue'
	}

	test-cmdlet 'New-AzStorageContext'  "Could not get context for Storage Account '$targetSA'"

	# create tasks
	$runningBlobTasks = @()
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| Where-Object SnapshotCopy -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$runningBlobTasks += @{
			blob		= "$($_.Name).vhd"
			finished	= $False
			progress	= ''
		}
	}

	$script:waitCount = 0
	do {
		Write-logFile
		write-logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') BLOB COPY COMPLETION"
		$done = $True
		foreach ($task in $runningBlobTasks) {

			if ($task.finished) {
				Write-logFile $task.progress -ForegroundColor 'Green'
			}
			else {

				try {
					$state = Get-AzStorageBlob `
						-Blob       	$task.blob `
						-Container  	$targetSaContainer `
						-Context    	$destinationContext `
						-WarningAction	'SilentlyContinue' `
						-ErrorAction	'Stop' ` `
					| Get-AzStorageBlobCopyState
				}
				catch {
					write-logFileError "Get-AzStorageBlob failed" `
										"If Azure credentials have expired then run Connect-AzAccount" `
										"and restart RGCOPY with ADDITIONAL parameter 'restartRemoteCopy'" `
										-lastError
				}

				[int] $GB_total  = $state.TotalBytes  / 1024 / 1024 / 1024
				[int] $percent   = $state.BytesCopied / $state.TotalBytes * 100
				if (($percent -eq 100) -and ($state.BytesCopied -ne $state.TotalBytes)) { $percent = 99 }

				$padPercent = $(' ' * 3) + $percent
				$padPercent = $padPercent.SubString($padPercent.length - 3, 3)
				$padGB =  $(' ' * 7) + $GB_total
				$padGB = $padGB.SubString($padGB.length - 7, 7)

				$task.progress = "$padPercent% of $padGB GiB   $($task.blob)"

				if ($state.Status -eq 'Pending') {
					$done = $False
					Write-logFile $task.progress -ForegroundColor 'DarkYellow'

				} elseif ($state.Status -eq 'Success') {
					$task.finished = $True
					Write-logFile $task.progress -ForegroundColor 'Green'

				} else {
					Write-logFile $task.progress -ForegroundColor 'Red'
					write-logFileError "Copy to BLOB failed"
				}
			}
		}

		if (!$done) { 
			$delayMinutes = get-waitTime
			Start-Sleep -seconds (60 * $delayMinutes)
		}
	} while (!$done)
	write-stepEnd
}

#--------------------------------------------------------------
function new-disks {
#--------------------------------------------------------------
	$savedSub = $script:currentSub
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	$secureToken= Get-AzAccessToken -AsSecureString -WarningAction 'SilentlyContinue'
	$token = ConvertFrom-SecureString $secureToken.Token -AsPlainText

	# get storage account ID
	$blobsSaID = get-resourceString `
					$targetSubID		$blobsRG `
					'Microsoft.Storage' `
					'storageAccounts'	$blobsSA

	# update $script:copyDisks
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		# get snapshot ID
		if ($_.SnapshotCopy) {
			$subscriptionID = $targetSubID
			$resourceGroup  = $targetRG
		}
		else {
			$subscriptionID = $sourceSubID
			$resourceGroup  = $sourceRG	
		}

		$_.SnapshotId = get-resourceString `
							$subscriptionID		$resourceGroup `
							'Microsoft.Compute' `
							'snapshots'			$_.SnapshotName

		$_.TokenRestAPI = $Null

		if ($useRestAPI) {
			$_.TokenRestAPI = $token
		}

		if (!$skipWorkarounds) {
			# TrustedLaunch not supported yet for New-AzDisk
			if (($_.SecurityType.Length -ne 0) -and $_.BlobCopy) { `
				$_.TokenRestAPI = $token
			}

			# NVMe not supported yet for New-AzDisk
			if ($_.DiskControllerType -eq 'NVME') {
				$_.TokenRestAPI = $token
			}
		}
	}

	# using parameters for parallel execution
	$scriptParameter = @"
		`$blobsSaID				= '$blobsSaID'
		`$blobsSA				= '$blobsSA'
		`$blobsSaContainer		= '$blobsSaContainer'
		`$targetLocation		= '$targetLocation'
		`$targetRG				= '$targetRG'
		`$sourceRG				= '$sourceRG'
		`$targetSubID			= '$targetSubID'
		`$sourceSubID			= '$sourceSubID'
		`$defaultDiskName		= '$defaultDiskName'
"@
	
	#--------------------------------------------------------------
	# parallel running script
	$script = {

		$diskName	= $_.Name
		$token		= $_.TokenRestAPI

		# only when copying a single disk
		if ($defaultDiskName.length -gt 0) {
			$diskName = $defaultDiskName
		}

		if ($Null -ne $token) {
			#--------------------------------------------------------------
			# use REST API
			if ($_.BlobCopy) {
				Write-Output "... creating disk '$diskName' from BLOB using REST API"
			}
			else {
				Write-Output "... creating disk '$diskName' from SNAPSHOT using REST API"
			}

			$body = @{
				location = $targetLocation
				sku = @{
					name = $_.SkuName
				}
				properties = @{
					diskSizeGB          = $_.SizeGB
					creationData = @{}
				}
			}

			if ($_.OsType.Length -ne 0) {
				$body.properties.osType = $_.OsType
			}

			if ($_.HyperVGeneration.length -gt 0) {
				$body.properties.hyperVGeneration = $_.HyperVGeneration
			}

			if ($_.BurstingEnabled -eq $True) {
				$body.properties.burstingEnabled = $True
			}

			if ($_.performanceTierName.Length -gt 0) {
				$body.properties.tier = $_.performanceTierName
			}

			if ($_.DiskIOPSReadWrite -gt 0) {
				$body.properties.diskIOPSReadWrite = $_.DiskIOPSReadWrite
			}

			if ($_.DiskMBpsReadWrite -gt 0) {
				$body.properties.diskMBpsReadWrite = $_.DiskMBpsReadWrite
			}	

			if ($_.MaxShares -gt 1) {
				$body.properties.maxShares = $_.MaxShares
			}

			if ($_.DiskControllerType -eq 'NVME') {
				$body.properties.supportedCapabilities = @{diskControllerTypes = 'SCSI, NVMe'}
			}

			# sector size
			if ($_.SkuName -in @('UltraSSD_LRS', 'PremiumV2_LRS')) {
				if (($Null -eq $_.LogicalSectorSize) -or ($_.LogicalSectorSize -eq 512)) {
					$body.properties.creationData.logicalSectorSize = 512
				}
			}

			# zone
			if ($_.DiskZone -in @(1,2,3)) {
				$body.zones = @($_.DiskZone)
			}

			# create from BOLB
			if ($_.BlobCopy) {
				$body.properties.creationData.storageAccountId	= $blobsSaID
				$body.properties.creationData.sourceUri			= "https://$blobsSA.blob.core.windows.net/$blobsSaContainer/$($_.Name).vhd"
				$body.properties.creationData.createOption		= 'Import'

				# TrustedLaunch
				if ($_.SecurityType -eq 'TrustedLaunch') {
					$body.properties.securityProfile = @{securityType = 'TrustedLaunch'}
				}
			}

			# create from snapshot
			else {
				$body.properties.creationData.sourceResourceId	= $_.SnapshotId
				$body.properties.creationData.createOption		= 'Copy'
			}

			$apiVersion='2023-10-02'
			$restUri = "https://management.azure.com/subscriptions/$targetSubID/resourceGroups/$targetRG/providers/Microsoft.Compute/disks/$diskName`?api-version=$apiVersion"

			$invokeParam = @{
				Uri				= $restUri
				Method			= 'Put'
				ContentType		= 'application/json'
				Headers			= @{ Authorization = "Bearer $token" }
				Body			= ($body | ConvertTo-Json)
				WarningAction 	= 'SilentlyContinue'
				ErrorAction		= 'Stop'
			}

			try {
				Invoke-WebRequest @invokeParam | Out-Null
			}
			catch {
				throw "'$diskName' creation failed"
			}
		}

		else {
			#--------------------------------------------------------------
			# use Az cmdlet
			if ($_.BlobCopy) {
				Write-Output "... creating disk '$diskName' from BLOB using Az cmdlet"
			}
			else {
				Write-Output "... creating disk '$diskName' from SNAPSHOT using Az cmdlet"
			}

			$param = @{
				SkuName				= $_.SkuName
				Location			= $targetLocation
				DiskSizeGB			= $_.SizeGB
				ErrorAction			= 'Stop'
				WarningAction		= 'SilentlyContinue'
			}
	
			if ($_.BurstingEnabled -eq $True) {
				$param.BurstingEnabled = $True
			}
	
			if ($_.performanceTierName.Length -gt 0) {
				$param.Tier = $_.performanceTierName
			}
	
			if ($_.DiskIOPSReadWrite -gt 0) {
				$param.DiskIOPSReadWrite = $_.DiskIOPSReadWrite
			}	
	
			if ($_.DiskMBpsReadWrite -gt 0) {
				$param.DiskMBpsReadWrite = $_.DiskMBpsReadWrite
			}	
	
			if ($_.MaxShares -gt 1) {
				$param.MaxSharesCount = $_.MaxShares
			}
	
			if ($_.OsType.Length -ne 0) {
				$param.OsType = $_.OsType
			}
	
			if ($_.HyperVGeneration.length -gt 0) {
				$param.HyperVGeneration = $_.HyperVGeneration
			}
	
			# sector size
			if ($_.SkuName -in @('UltraSSD_LRS', 'PremiumV2_LRS')) {
				if (($Null -eq $_.LogicalSectorSize) -or ($_.LogicalSectorSize -eq 512)) {
					$param.LogicalSectorSize = 512
				}
			}
	
			# zone
			if ($_.DiskZone -in @(1,2,3)) {
				$param.Zone = @($_.DiskZone)
			}
	
			# create from BOLB
			if ($_.BlobCopy) {
				$param.StorageAccountId	= $blobsSaID
				$param.SourceUri		= "https://$blobsSA.blob.core.windows.net/$blobsSaContainer/$($_.Name).vhd"
				$param.CreateOption		= 'Import'
			}
	
			# create from snapshot
			else {
				$param.sourceResourceId	= $_.SnapshotId
				$param.createOption		= 'Copy'
			}
	
			$diskConfig = New-AzDiskConfig @param
	
			New-AzDisk `
				-DiskName           $diskName `
				-Disk               $diskConfig `
				-ResourceGroupName  $targetRG `
				-WarningAction		'SilentlyContinue' `
				-ErrorAction		'Stop' | Out-Null
			#--------------------------------------------------------------
		}

		if (!$?) {
			throw "'$diskName' creation failed"
		}
		Write-Output "'$diskName' created"
	}

	#--------------------------------------------------------------
	# start execution
	write-stepStart "CREATE DISKS" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP

	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host

	if (!$?) {
		write-logFileError "Creation of disks failed"
	}
	write-stepEnd

	if ($script:dualDeployment) {

		if (!$(wait-completion "DISK CREATION" `
					'disks' $targetRG $snapshotWaitCreationMinutes)) {

			write-logFileError "Disk creation completion did not finish within $snapshotWaitCreationMinutes minutes"
		}
	}

	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function update-publicIPAddresses {
#--------------------------------------------------------------
	# set publicIPAddresses Standard/Static: needed in newer APIs for VMs in Availability Zone
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/publicIPAddresses'
	| ForEach-Object {

		if ($_.sku.name -ne 'Standard') {
			$_.sku = @{ name = 'Standard' }
			write-logFileUpdates 'publicIPAddresses' $_.name 'set SKU' 'Standard'
		}
		if ($_.properties.publicIPAllocationMethod -ne 'Static') {
			$_.properties.publicIPAllocationMethod = 'Static'
			write-logFileUpdates 'publicIPAddresses' $_.name 'set AllocationMethod' 'Static'
		}
		if ($Null -ne $_.properties.ipAddress) {
			$_.properties.ipAddress = $Null
		}
	}
}

#--------------------------------------------------------------
function update-subnetDelegation {
#--------------------------------------------------------------
	# remove NICs in delegated subnets (NIC has to be created by delegation service)
	$collected = @()

	
	# BICEP
	if ($useBicep) {
		# get VNETs with delegation
		foreach ($net in $script:az_virtualNetworks) {
			foreach ($sub in $net.Subnets) {
				$subnetName = $Null
				foreach ($delegation in $sub.Delegations) {
					$vnetName	= $net.Name
					$subnetName = $sub.Name
				}
				if ($Null -ne $subnetName) {
					# get NIC for VNET
					foreach ($nic in $script:az_networkInterfaces) {
						foreach ($conf in $nic.IpConfigurations) {
							if ($Null -ne $conf.Subnet.Id) {
								$r = get-resourceComponents $conf.Subnet.Id
								if (($r.mainResourceName -eq $vnetName) -and ($r.subResourceName -eq $subnetName)) {
									$collected += $nic.Name
								}
							}
						}
					}
				}
			}
		}
	}
	
	# ARM
	else {
		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Network/virtualNetworks/subnets'
		| ForEach-Object {
	
			if ($Null -ne $_.properties.delegations) {
				if ($Null -ne $_.properties.delegations.name) {
	
					$vnet,$subnet = $_.name -split '/'
					$dependsSubnet = get-resourceFunction `
										'Microsoft.Network' `
										'virtualNetworks'	$vnet `
										'subnets'			$subnet
					# collect NICs
					$script:resourcesALL
					| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
					| ForEach-Object {
	
						foreach ($d in $_.dependsOn) {
							if ($True -eq (compare-resources $d $dependsSubnet)) {
								$collected += $_.name
							}
						}
					}
				}
			}
		}
	}

	# remove collected NICs
	foreach ($nic in $collected) {
		write-logFileUpdates 'networkInterfaces' $nic 'delete (used for delegation)'
	}
	remove-resources 'Microsoft.Network/networkInterfaces' $collected
}

#--------------------------------------------------------------
function update-acceleratedNetworking {
#--------------------------------------------------------------
	# process existing NICs
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
	| ForEach-Object {

		$nicName = $_.name
		$config = $script:copyNics[$nicName].EnableAcceleratedNetworking
		if ($Null -ne $config) {
			$_.properties.enableAcceleratedNetworking = $config
		}
	}
}

#--------------------------------------------------------------
function update-SKUs {
#--------------------------------------------------------------
	# process loadBalancers
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/loadBalancers'
	| ForEach-Object {

		if ($_.sku.name -ne 'Standard') {
			write-logFileUpdates 'loadBalancers' $_.name 'set SKU' 'Standard'
			$_.sku = @{ name = 'Standard' }
		}
	}

	# # remove SKU from bastionHosts (used to be required during rollout of SKU)
	# $script:resourcesALL
	# | Where-Object type -eq 'Microsoft.Network/bastionHosts'
	# | ForEach-Object {

	# 	if ($_.sku.count -ne 0) {
	# 		$_.sku = $Null
	# 		write-logFileUpdates 'bastionHosts' $_.name 'delete Sku' '' '' '(SKU not supported in all regions)'
	# 	}
	# }
}

#--------------------------------------------------------------
function update-IpAllocationMethod {
#--------------------------------------------------------------
	set-parameter 'setPrivateIpAlloc' $setPrivateIpAlloc 'Microsoft.Network/networkInterfaces'
	# process networkInterfaces
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
	| ForEach-Object {

		$value = $script:paramValues[$_.name]
		if ($Null -ne $value) {
			test-values 'setPrivateIpAlloc' $value @('Dynamic', 'Static') 'allocation type'

			for ($i = 0; $i -lt $_.properties.ipConfigurations.count; $i++) {
				$ip = $_.properties.ipConfigurations[$i].properties.privateIPAddress
				if ($_.properties.ipConfigurations[$i].properties.privateIPAllocationMethod -ne $value) {
					$_.properties.ipConfigurations[$i].properties.privateIPAllocationMethod = $value
					write-logFileUpdates 'privateIPAddresses' $ip 'set Allocation Method' $value
					$script:countPrivateIpAlloc++
				}
				else {
					write-logFileUpdates 'privateIPAddresses' $ip 'keep Allocation Method' $value
				}
			}
		}

		# remove IP for dynamic allocation method
		for ($i = 0; $i -lt $_.properties.ipConfigurations.count; $i++) {
			if ($_.properties.ipConfigurations[$i].properties.privateIPAllocationMethod -eq 'Dynamic') {
				$_.properties.ipConfigurations[$i].properties.privateIPAddress = $Null
			}
		}
	}
}

#--------------------------------------------------------------
function update-securityRules {
#--------------------------------------------------------------
	# collect deleted rules
	$deletedRules = @()
	$deletedRulesFullName = @()
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/networkSecurityGroups/securityRules'
	| ForEach-Object {

		# delete all automatically created rules
		$x, $name = $_.name -split '/'
		foreach ($ruleNamePattern in $skipSecurityRules) {
			if ($name -like $ruleNamePattern) {
				$deletedRules += $name
				$deletedRulesFullName += $_.name
				write-logFileUpdates 'networkSecurityRules' $name 'delete'
			}
		}
	}
	remove-resources 'Microsoft.Network/networkSecurityGroups/securityRules' $deletedRulesFullName

	# update networkSecurityGroups
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/networkSecurityGroups'
	| ForEach-Object {

		$_.properties.securityRules = convertTo-array ($_.properties.securityRules `
														| Where-Object name -notin $deletedRules)

		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/networkSecurityGroups/securityRules'
		$_.properties.securityRules = $Null
	}
}

#--------------------------------------------------------------
function update-dependenciesAS {
#--------------------------------------------------------------
# only used for ARM

# Circular dependency with availabilitySets:
#   Create resources in this order:
#   1. availabilitySets
#   2. virtualMachines

# process availabilitySets
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/availabilitySets'
	| ForEach-Object {

		$_.properties.virtualMachines = $Null

		$_.dependsOn = remove-dependencies $_.dependsOn -keep 'Microsoft.Compute/proximityPlacementGroups'
	}
}

#--------------------------------------------------------------
function update-dependenciesVNET {
#--------------------------------------------------------------
# only used for ARM

	$subnetsAll = @()

	# remove virtualNetworkPeerings 
	remove-resources 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings'
	
	# workaround for following sporadic issue when deploying subnets:
	#  "code": "Another operation on this or dependent resource is in progress.""
	#  "message": "Cannot proceed with operation because resource <vnet> ... is not in Succeeded state."
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks'
	| ForEach-Object {

		# remove virtualNetworkPeerings from VNET
		$_.properties.virtualNetworkPeerings = $Null

		# remove dependencies to virtualNetworkPeerings
		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings'

		# for virtualNetworkPeerings, there is a Circular dependency between VNETs
		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/virtualNetworks'
		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/virtualNetworks/subnets'

		# get subnets per vnet
		$vnet = $_.name
		$subnetsDependent = @()

		foreach ($s in $_.properties.subnets) {

			$subnet = $s.name

			# create dependency chain for subnets (do not deploy 2 subnets at the same time)
			$script:resourcesALL
			| Where-Object type -eq 'Microsoft.Network/virtualNetworks/subnets'
			| Where-Object name -eq "$vnet/$subnet"
			| ForEach-Object {

				[array] $_.dependsOn += $subnetsDependent
			}

			# save IDs
			$id = get-resourceFunction `
					'Microsoft.Network' `
					'virtualNetworks'	$vnet `
					'subnets'			$subnet
			
			$subnetsDependent += $id
			$subnetsAll += $id
		}

		# we have already defined the subnets as separate resource
		$_.properties.subnets = $Null
	}
}

#--------------------------------------------------------------
function update-dependenciesLB {
#--------------------------------------------------------------
# only used for ARM

# Circular dependency with loadBalancers:
#   Create resources in this order:
#   1. networkInterfaces
#   2. loadBalancers
#   3a. backendAddressPools
#   3b. inboundNatRules
#   4a. redeploy networkInterfaces
#   4b. redeploy loadBalancers

# process networkInterfaces
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
	| ForEach-Object {

		# save NIC (deep copy)
		$NIC = $_ | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20 -AsHashtable

		# remove dependencies
		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/loadBalancers*'

		# remove properties
		$changed = $False
		for ($i = 0; $i -lt $_.properties.ipConfigurations.count; $i++) {

			if ($_.properties.ipConfigurations[$i].properties.loadBalancerBackendAddressPools.count -ne 0) {
				$_.properties.ipConfigurations[$i].properties.Remove('loadBalancerBackendAddressPools')
				$changed = $True
			}

			if ($_.properties.ipConfigurations[$i].properties.LoadBalancerInboundNatRules.count -ne 0) {
				$_.properties.ipConfigurations[$i].properties.Remove('LoadBalancerInboundNatRules')
				$changed = $True
			}
		}

		# save modified NICs (with unmodified properties)
		if ($changed) {
			$script:resourcesNic += $NIC
		}
	}

# process loadBalancers
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/loadBalancers'
	| ForEach-Object {

		# save LB (deep copy)
		$LB = $_ | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20 -AsHashtable

		# modify dependencies
		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/loadBalancers/backendAddressPools'
		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/loadBalancers/inboundNatRules'
		$dependsVMs = @()

		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
		| ForEach-Object {

			$dependsVMs += get-resourceFunction `
							'Microsoft.Compute' `
							'virtualMachines'	$_.name
		}
		[array] $_.dependsOn += $dependsVMs

		# remove properties
		$changed = $False
		if ($_.properties.loadBalancingRules.count -ne 0) {

			$_.properties.Remove('loadBalancingRules')
			$changed = $True
		}

		if ($_.properties.inboundNatRules.count -ne 0) {

			$_.properties.Remove('inboundNatRules')
			$changed = $True
		}

		# save LBs
		if ($changed) {
			$script:resourcesLB += $LB
		}
	}
}

#--------------------------------------------------------------
function update-dependenciesNatGateways {
#--------------------------------------------------------------
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/publicIPPrefixes'
	| ForEach-Object {

		$_.properties.natGateway = $Null
		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/natGateways'
	}

	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/publicIPAddresses'
	| ForEach-Object {

		$_.properties.natGateway = $Null
		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/natGateways'
	}
}

#--------------------------------------------------------------
function update-reDeployment {
#--------------------------------------------------------------
# only used for ARM

# re-deploy networkInterfaces & loadBalancers
	$resourcesRedeploy = @()

	# get saved NIC resources
	$script:resourcesNic
	| ForEach-Object {

		$_.dependsOn = @()
		$resourcesRedeploy += $_
	}

	# get saved LB resources
	$script:resourcesLB
	| ForEach-Object {

		$_.dependsOn = @()
		$resourcesRedeploy += $_
	}

	$dependsOn = @()
	# get dependencies of Redeployment
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$dependsOn += get-resourceFunction `
			'Microsoft.Compute' `
			'virtualMachines'	$_.name
	}
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/loadBalancers/inboundNatRules'
	| ForEach-Object {

		$main,$sub = $_.name -split '/'

		$dependsOn += get-resourceFunction `
			'Microsoft.Network' `
			'loadBalancers'		$main `
			'inboundNatRules' 	$sub
	}
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/loadBalancers'
	| ForEach-Object {

		$dependsOn += get-resourceFunction `
			'Microsoft.Network' `
			'loadBalancers'		$_.name
	}
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
	| ForEach-Object {

		$dependsOn += get-resourceFunction `
			'Microsoft.Network' `
			'networkInterfaces'		$_.name
	}

	# create template
	$NicTemplate = @{
		contentVersion = '1.0.0.0'
		resources =	$resourcesRedeploy
	}
	$NicTemplate.Add('$schema', "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#")

	# create deployment
	$deployment = @{
		name			= "NIC_Redeployment"
		type 			= 'Microsoft.Resources/deployments'
		apiVersion		= '2019-07-01'
		resourceGroup	= '[resourceGroup().name]'
		dependsOn		= $dependsOn
	}
	$properties = @{
		mode 		= 'Incremental'
		template 	= $NicTemplate
	}
	$deployment.Add('properties', $properties)

	# add deployment
	if ($resourcesRedeploy.count -gt 0) {
		# write-logFileUpdates 'deployments' 'NIC_Redeployment' 'create'
		[array] $script:resourcesALL += $deployment
	}
}

#--------------------------------------------------------------
function update-FQDN {
#--------------------------------------------------------------
	$script:jumpboxIpName = $Null
	if ($jumpboxName.length -ne 0) {

		# get networkInterfaces of jumpbox
		$jumpboxNicNames = @()
		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
		| Where-Object name -like "*$jumpboxName*"
		| ForEach-Object {

			# process NICs
			if ($Null -ne $_.properties.networkProfile) {
				foreach($nic in $_.properties.networkProfile.networkInterfaces) {
					$jumpboxNicNames += (get-resourceComponents $nic.id).mainResourceName
				}
			}
		}

		# get publicIPAddresses of jumpbox
		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
		| Where-Object name -in $jumpboxNicNames
		| ForEach-Object {

			# process IP configurations
			foreach($conf in $_.properties.ipConfigurations) {
				if ($Null -ne $conf.properties) {

					# process publicIPAddress
					if ($Null -ne $conf.properties.publicIPAddress) {
						# just get a single IP Address
						$script:jumpboxIpName = (get-resourceComponents $conf.properties.publicIPAddress.id).mainResourceName
					}
				}
			}
		}
	}

	set-parameter 'removeFQDN' $removeFQDN 'Microsoft.Network/publicIPAddresses'
	# process publicIPAddresses
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/publicIPAddresses'
	| ForEach-Object {

		# get parameter
		$value = $script:paramValues[$_.name]
		if ($Null -ne $value) {
			if ($value -ne 'True') {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"value: '$value', allowed: 'True'"
			}

			# change Full Qualified Domain Name
			$FQDN = $Null
			if ($Null -ne $_.properties.dnsSettings) {
				$FQDN = $_.properties.dnsSettings.fqdn
			}
			if ($Null -ne $FQDN) {
				$_.properties.dnsSettings = $Null
				write-logFileUpdates 'publicIPAddresses' $_.name 'delete FQDN' $FQDN
			}
		}

		# add FQDN for Jumpbox
		if ($_.name -eq $script:jumpboxIpName) {

			$label = "toLower(replace(resourceGroup().name,'_','-'))"
			$fqdn = "[concat($label, concat('.', concat(resourceGroup().location, '.cloudapp.azure.com')))]"
			$label = "[$label]"

			$dnsSettings = @{
				domainNameLabel = $label
				fqdn = $fqdn
			}
			$_.properties.dnsSettings = $dnsSettings

			$label = $targetRG.Replace('_', '-').ToLower()
			$fqdn = "$label.$targetLocation.cloudapp.azure.com"
			write-logFileUpdates 'publicIPAddresses' $_.name 'set FQDN' $fqdn
		}
	}
}

#--------------------------------------------------------------
function get-vmssFlex {
#--------------------------------------------------------------
	$script:deletedVmss = @()
	
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachineScaleSets'
	| ForEach-Object {

		$vmssName = $_.name
		$faultDomainCount = $_.properties.platformFaultDomainCount
		if ($faultDomainCount -lt 2) {
			$faultDomainCount = 1
		}

		# remove unneeded VMSS
		if ($skipVmssFlex -or ($_.properties.orchestrationMode -ne 'Flexible')) {

			write-logFileUpdates 'vmScaleSets' $_.name 'delete'
			$script:deletedVmss += $_.name
		}

		# get existing VMSS
		else {
			$properties = "(FD Count=$faultDomainCount; Zones=$($_.zones -as [string]))"

			write-logFileUpdates 'vmScaleSets' $_.name 'keep' $properties

			# save properties of existing VMSS
			$script:vmssProperties[$vmssName] = @{
				name				= $vmssName
				faultDomainCount	= $faultDomainCount
				zones				= $_.zones
			}
		}
	}

	# delete unneeded resources
	foreach ($vmss in $script:deletedVmss) {
		remove-resources 'Microsoft.Compute/virtualMachineScaleSets' $vmss
	}
	# vmss FLEX does not have this subresource (although it is exported from source RG)
	remove-resources 'Microsoft.Compute/virtualMachineScaleSets/virtualMachines'

	#--------------------------------------------------------------
	# update VMs for VMSS Flex
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$vmName = $_.name
		$id = $_.properties.virtualMachineScaleSet.id
		if ($Null -ne $id) {
			$vmssName = (get-resourceComponents $id).mainResourceName

			# vmss not found in same resource group
			if ($vmssName -notin $script:vmssProperties.values.name) {
				# remove vmss from VM
				$_.properties.virtualMachineScaleSet = $Null
				$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Compute/virtualMachineScaleSets'
			}

			# save VMSS name
			else {
				$script:copyVMs[$vmName].VmssName = $vmssName
			}
		}
	}
}

#--------------------------------------------------------------
function new-vmssFlex {
#--------------------------------------------------------------
	$script:createdVmssNames = @()

	# fill [hashtable] $script:paramValues
	set-parameter 'createVmssFlex' $createVmssFlex 'Microsoft.Compute/virtualMachines'
	foreach ($config in $script:paramAllConfigs) {

		$vmssName		= $config.paramConfig1
		$faultDomains	= $config.paramConfig2
		$zoneList		= $config.paramConfig3

		# test vmssName: 1 to 64 characters
		$match = '^[a-zA-Z0-9][a-zA-Z0-9\-]{0,62}[a-zA-Z0-9]$|^[a-zA-Z]$'
		test-match 'createVmssFlex' $vmssName $match 'vmssName' 'vmssName/faultDomains/zones@VMs'
		test-values 'createVmssFlex' $zoneList @('none', '1', '2', '3', '1+2', '1+3', '2+3', '1+2+3') 'zones' 'vmssName/faultDomains/zones@VMs'
		test-values 'createVmssFlex' $faultDomains @('none', '1', '2', '3', 'max') 'faultDomains' 'vmssName/faultDomains/zones@VMs'

		# Zone and fault domain must not be set at the same time
		if (($zoneList -ne 'none') -and ($faultDomains -notin @('none', '1'))) {
			write-logFileError "Invalid parameter 'createVmssFlex'" `
					"The syntax is: 'vmssName/faultDomains/zones@VMs'" `
					"Value of 'faultDomains' is '$faultDomains', value of 'zones' is '$zoneList' " `
					"For zonal deployment, faultDomains must be set '1'"
		}

		# check recommended config for SAP
		if ($faultDomains -notin @('none', '1')) {
			write-logFileWarning "Parameter values of 'createVmssFlex' not recommended for SAP" `
					"The syntax is: 'vmssName/faultDomains/zones@VMs'" `
					"Value of 'faultDomains' is '$faultDomains', value of 'zones' is '$zoneList' " `
					"You should set faultDomains to '1'"
		}

		# correct values
		if ($faultDomains -eq 'none') {
			$numDomains = 1
		}
		elseif ($faultDomains -eq 'max') {
			$numDomains = $script:MaxRegionFaultDomains
		}
		else {
			$numDomains = $faultDomains -as [int]
		}

		if ($numDomains -gt $script:MaxRegionFaultDomains) {
			write-logFileWarning "Region '$targetLocation' only supports $script:MaxRegionFaultDomains fault domains"
			$numDomains = $script:MaxRegionFaultDomains
		}

		# create ARM resource
		$res = @{
			type 		= 'Microsoft.Compute/virtualMachineScaleSets'
			apiVersion	= '2021-11-01'
			name 		= $vmssName
			location	= $targetLocation
			properties	= @{
				orchestrationMode			= 'Flexible'
				platformFaultDomainCount	= $numDomains
			}
		}

		# assemble zones parameter
		$zoneArray = @()
		if ($zoneList -ne 'none') {
			for ($i = 1; $i -le 3; $i++) {
				if ($zoneList -like "*$i*") {
					$zoneArray += "$i"
				}
			}
			$res.zones = $zoneArray
		}

		# save ARM resource
		if ($vmssName -notin $script:createdVmssNames) {
			$script:createdVmssNames += $vmssName
			$properties = "(FD Count=$numDomains; Zones=$($zoneArray -as [string]))"
			write-logFileUpdates 'vmScaleSets' $vmssName 'create' $properties
			add-resourcesALL $res
		}

		# save properties of new VMSS
		$script:vmssProperties[$vmssName] = @{
			name				= $vmssName
			faultDomainCount	= $numDomains
			zones				= $zoneArray
		}

		# update VMs with new vmss
		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
		| ForEach-Object {

			$vmName = $_.name
			$vmssName, $x = $script:paramValues[$vmName] -split '/'

			if ($vmssName.length -ne 0) {

				# BICEP
				if ($useBicep) {
					$_.properties.virtualMachineScaleSet = get-bicepIdStructByType 'Microsoft.Compute/virtualMachineScaleSets' $vmssName
				}

				# ARM
				else {
					# get ID function
					$vmssID = get-resourceFunction `
								'Microsoft.Compute' `
								'virtualMachineScaleSets'	$vmssName
								
					# set property
					$_.properties.virtualMachineScaleSet = @{ id = $vmssID }
	
					# add new dependency
					[array] $_.dependsOn += $vmssID
				}

				# save VMSS name
				$script:copyVMs[$vmName].VmssName = $vmssName
			}
		}
	}
}

#--------------------------------------------------------------
function update-faultDomainCount {
#--------------------------------------------------------------
	# update fault domain count (of new and existing VMSS)
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachineScaleSets'
	| ForEach-Object {

		# check fault domain count
		if ($_.properties.platformFaultDomainCount -gt $script:MaxRegionFaultDomains ) {
			$_.properties.platformFaultDomainCount = $script:MaxRegionFaultDomains
			$script:vmssProperties[$_.name].faultDomainCount = $script:MaxRegionFaultDomains
			write-logFileWarning "The maximum fault domain count in region '$targetLocation' is $script:MaxRegionFaultDomains" `
								-stopWhenForceVmChecks
			write-logFileUpdates 'vmScaleSets' $_.name 'set faultDomainCount' $script:MaxRegionFaultDomains
		}
	}
}

#--------------------------------------------------------------
function update-vmFaultDomain {
#--------------------------------------------------------------
	# process RGCOPY parameter
	set-parameter 'setVmFaultDomain' $setVmFaultDomain
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$faultDomain = $script:paramConfig
		test-values 'setVmFaultDomain' $faultDomain @('none', '0', '1', '2') 'faultDomain'
		# convert to internal syntax
		if ($faultDomain -eq 'none') {
			$faultDomain = -1
		}
		$faultDomain = $faultDomain -as [int]

		$script:copyVMs.values
		| Where-Object Name -in $script:paramVMs
		| ForEach-Object {

			$_.PlatformFaultDomainNew = $faultDomain
		}
		get-ParameterRule
	}

	$script:MseriesWithFaultDomain = $False

	# output of changes
	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$vmName 	= $_.Name
		$vmssName	= $_.VmssName

		$current	= $_.PlatformFaultDomain
		$wanted		= $_.PlatformFaultDomainNew
		if ($Null -eq $wanted) {
			$wanted = $current
		}

		# check if VMSS is used
		if (($Null -eq $vmssName) -and ($wanted -ne -1)) {
			write-logFileWarning "VM '$vmName' is not part of a VM Scale Set. Fault Domains are not supported"
			$wanted = -1
		}

		# check VMSS properties
		if ($Null -ne $vmssName) {
			$max = $script:vmssProperties[$vmssName].faultDomainCount

			if (($max -le 1) -and ($wanted -ne -1)) {
				write-logFileWarning "VM Scale Set '$vmssName' does not support fault domains"
				$wanted = -1
			}

			if (($max -gt 1) -and ($wanted -eq -1)) {
				write-logFileError "VM Scale Set '$vmssName' supports fault domains" `
									"You must use RGCOPY parameter 'setVmFaultDomain' for VM '$vmName'"
			}

			if ($wanted -ge $max) {
				write-logFileError "VM Scale Set '$vmssName' only supports $max fault domains" `
									"You must use RGCOPY parameter 'setVmFaultDomain' for VM '$vmName'"
			}
		}

		# get M-series
		if ($Null -ne $vmssName) {
			if ($_.VmSize -like 'Standard_M*') {
				# save VM size property
				$script:vmssProperties[$vmssName].SeriesM = $True

				if ($wanted -ne -1) {
					$script:MseriesWithFaultDomain = $True
				}
			}
			else {
				# save VM size property
				$script:vmssProperties[$vmssName].SeriesOther = $True
			}
		}


		# update
		$_.PlatformFaultDomain = $wanted

		# output
		if ($current -ne $wanted) {
			$action = 'set'
		}
		else {
			$action = 'keep'
		}
		if ($_.PlatformFaultDomain -eq -1) {
			write-logFileUpdates 'virtualMachines' $vmName "$action fault domain" 'none' -defaultValue
		}
		else {
			write-logFileUpdates 'virtualMachines' $vmName "$action fault domain" $_.PlatformFaultDomain
		}
	}

	# update VM ARM resources
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$vmName = $_.name
		$platformFaultDomain = $script:copyVMs[$vmName].PlatformFaultDomain

		# update platformFaultDomain
		if ($platformFaultDomain -lt 0) {
			$_.properties.platformFaultDomain = $Null
		}
		else{
			$_.properties.platformFaultDomain = $platformFaultDomain
		}
	}
}

#--------------------------------------------------------------
function set-singlePlacementGroup {
#--------------------------------------------------------------
	$script:seriesMixed = $False

	#--------------------------------------------------------------
	# set singlePlacementGroup
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachineScaleSets'
	| ForEach-Object {

		$vmssName = $_.name
		$singlePG = $Null

		if ($_.properties.platformFaultDomainCount -gt 1) {
			if ($script:vmssProperties[$vmssName].SeriesOther -eq $True) {
				$singlePG = $False
				if ($script:vmssProperties[$vmssName].SeriesM -eq $True) {
					$script:seriesMixed = $True
				}
			}
		}

		if ('singlePlacementGroup' -in $boundParameterNames) {
			test-values 'singlePlacementGroup' $singlePlacementGroup @($Null, $True, $False)
			$singlePG = $singlePlacementGroup
		}
		elseif ($singlePG -eq $False) {
			write-logFileWarning "setting 'singlePlacementGroup' of VMSS '$vmssName' to false because of used VM size" `
								"You can override this by using RGCOPY parameter 'singlePlacementGroup'"
		}

		$_.properties.singlePlacementGroup = $singlePG
		$script:vmssProperties[$vmssName].singlePlacementGroup     = $_.properties.singlePlacementGroup
		$script:vmssProperties[$vmssName].platformFaultDomainCount = $_.properties.platformFaultDomainCount
	}

	if ($script:MseriesWithFaultDomain -eq $True) {
		write-logFileWarning "M-series VMs do CURRENTLY not support setting fault domain" `
							"Use parameter 'setVmFaultDomain' for setting fault domain to 'none'"
	}

	if ($script:seriesMixed) {
		write-logFileWarning "VMSS Flex (with FD Count >1) does CURRENTLY not support mixing M-Series VMs with other VMs" 
	}

	#--------------------------------------------------------------
	# save singlePlacementGroup in copyVMs for later output
	$script:copyVMs.Values
	| Where-Object {$Null -ne $_.VmssName}
	| ForEach-Object {

		$_.singlePlacementGroup     = $script:vmssProperties[$_.VmssName].singlePlacementGroup
		$_.platformFaultDomainCount = $script:vmssProperties[$_.VmssName].platformFaultDomainCount
	}

	#--------------------------------------------------------------
	# output of VMSS
	$script:copyVMs.Values
	| Where-Object {$Null -ne $_.VmssName}
	| Sort-Object VmssName, Name
	| Select-Object `
		@{label="VMSS name";    expression={get-shortOutput $_.VmssName 16}}, `
		@{label="VM name";      expression={get-shortOutput $_.Name 42}}, `
		@{label="Size";         expression={$_.VmSize}}, `
		@{label="Zone";         expression={get-replacedOutput $_.VmZone 0}}, `
		@{label="Fault Domain"; expression={get-replacedOutput $_.PlatformFaultDomain -1}}, `
		@{label="FD Count";     expression={$_.platformFaultDomainCount}}, `
		@{label="singlePlacementGroup"; expression={get-replacedOutput $_.singlePlacementGroup $Null}}
	| Format-Table
	| write-LogFilePipe
}

#--------------------------------------------------------------
function new-proximityPlacementGroup {
#--------------------------------------------------------------
	# fill [hashtable] $script:paramValues
	set-parameter 'createProximityPlacementGroup' $createProximityPlacementGroup `
		'Microsoft.Compute/virtualMachines' `
		'Microsoft.Compute/availabilitySets' `
		'Microsoft.Compute/virtualMachineScaleSets' -ignoreMissingResources
	$script:ppgOfAvset = @{}
	$script:createdPpgNames = @()

	#--------------------------------------------------------------
	# remove all ProximityPlacementGroups
	if ($skipProximityPlacementGroup) {

		# remove PPGs
		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Compute/proximityPlacementGroups'
		| ForEach-Object {

			write-logFileUpdates 'proximityPlacementGroups' $_.name 'delete'
		}
		remove-resources 'Microsoft.Compute/proximityPlacementGroups'

		# update VMs/AvSets/vmss
		$script:resourcesALL
		| Where-Object type -in @(	'Microsoft.Compute/virtualMachines',
									'Microsoft.Compute/availabilitySets',
									'Microsoft.Compute/virtualMachineScaleSets')
		| ForEach-Object {

			$x, $type = $_.type -split '/'
			if ($type -eq 'virtualMachineScaleSets') {
				$type = 'vmScaleSets'
			}

			if ($null -ne $_.properties.proximityPlacementGroup) {
				write-logFileUpdates $type $_.name 'remove proximityPlacementGroup' 
				$_.properties.proximityPlacementGroup = $Null
				$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Compute/proximityPlacementGroups'
			}
		}
	}

	#--------------------------------------------------------------
	# create new ProximityPlacementGroup
	foreach ($config in $script:paramAllConfigs) {

		$ppgName = $config.paramConfig
		
		# From documentation:
		#  Name must be less than 80 characters
		#  and start and end with a letter or number. You can use characters '-', '.', '_'.
		$match = '^[a-zA-Z0-9][a-zA-Z0-9_\.\-]{0,77}[a-zA-Z0-9]$|^[a-zA-Z0-9]$'
		test-match 'createProximityPlacementGroup' $ppgName $match 'ppgName' 'ppgName@resources (VMs or AvSets)'

		# save ProximityPlacementGroup per availabilitySet (or VM)
		foreach ($avSet in $script:paramResources) {
			$script:ppgOfAvset[$avSet] = $ppgName
		}

		# ARM resource for PPG
		$res = @{
			type 		= 'Microsoft.Compute/proximityPlacementGroups'
			apiVersion	= '2020-12-01'
			name 		= $ppgName
			location	= $targetLocation
			properties	= @{ proximityPlacementGroupType = 'Standard' }
		}

		# PPG has not been already created
		# (the same name might occur 2 times in the RGCOPY array-parameter)
		if ($ppgName -notin $script:createdPpgNames) {
			$script:createdPpgNames += $ppgName
			write-logFileUpdates 'proximityPlacementGroups' $ppgName 'create'
			add-resourcesALL $res
		}
	}
}

#--------------------------------------------------------------
function new-availabilitySet {
#--------------------------------------------------------------
	# fill [hashtable] $script:paramValues
	set-parameter 'createAvailabilitySet' $createAvailabilitySet 'Microsoft.Compute/virtualMachines'
	$deletedAvSet = @()
	$script:createdAvSetNames = @()

	#--------------------------------------------------------------
	# remove avsets
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/availabilitySets'
	| ForEach-Object {

		if ($skipAvailabilitySet -or ($_.name -like 'rgcopy.tipGroup*')) {
			write-logFileUpdates 'availabilitySets' $_.name 'delete'
			$deletedAvSet += $_.name
		}
	}

	# update VMs
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$id = $_.properties.availabilitySet.id
		if ($Null -ne $id) {
			$asName = (get-resourceComponents $id).mainResourceName
			if ($asName -in $deletedAvSet) {

				write-logFileUpdates 'virtualMachines' $_.name 'remove availabilitySet'
				$_.properties.availabilitySet = $Null
				$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Compute/availabilitySets'
			}
		}
	}

	# delete resource
	foreach ($asName in $deletedAvSet) {
		remove-resources 'Microsoft.Compute/availabilitySets' $asName
	}

	#--------------------------------------------------------------
	# create new availabilitySets
	foreach ($config in $script:paramAllConfigs) {

		$asName	= $config.paramConfig1
		$f		= $config.paramConfig2
		$u		= $config.paramConfig3

		# From documentation:
		#  The length must be between 1 and 80 characters
		#  The first character must be a letter or number.
		#  The last character must be a letter, number, or underscore.
		#  The remaining characters must be letters, numbers, periods, underscores, or dashes
		$match = '^[a-zA-Z0-9][a-zA-Z0-9_\.\-]{0,78}[a-zA-Z0-9_]$|^[a-zA-Z0-9]$'
		test-match 'createAvailabilitySet' $asName $match 'AVsetName' "AVsetName/faultDomainCount/updateDomainCount@VMs"

		if ($asName -like 'rgcopy.tipGroup*') {
			write-logFileError "Invalid parameter 'createAvailabilitySet'" `
								"AVsetName '$asName' is a reserved name for TiP sessions"
		}

		# check faultDomainCount
		$faultDomainCount = $f -as [int]
		test-values 'createAvailabilitySet' $faultDomainCount @(1, 2, 3) 'faultDomainCount' 'AVsetName/faultDomainCount/updateDomainCount@VMs'

		# check updateDomainCount
		$updateDomainCount = $u -as [int]
		test-values 'createAvailabilitySet' $updateDomainCount (1..20) 'updateDomainCount' 'AVsetName/faultDomainCount/updateDomainCount@VMs'
		
		# create ARM resource
		$res = @{
			type 		= 'Microsoft.Compute/availabilitySets'
			apiVersion	= '2019-07-01'
			name 		= $asName
			location	= $targetLocation
			sku			= @{ name = 'Aligned' }
			properties	= @{
				platformFaultDomainCount  = $faultDomainCount
				platformUpdateDomainCount = $updateDomainCount
			}
		}

		# AvSet has not been already created
		# (the same name might occur 2 times in the RGCOPY array-parameter)
		if ($asName -notin $script:createdAvSetNames) {
			$script:createdAvSetNames += $asName
			write-logFileUpdates 'availabilitySets' $asName 'create'
			add-resourcesALL $res
		}
	}

	#--------------------------------------------------------------
	# update fault domain count
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/availabilitySets'
	| ForEach-Object {

		# check fault domain count
		if ($_.properties.platformFaultDomainCount -gt $script:MaxRegionFaultDomains ) {
			write-logFileWarning "The maximum fault domain count in region '$targetLocation' is $script:MaxRegionFaultDomains" `
								-stopWhenForceVmChecks
			write-logFileUpdates 'availabilitySets' $_.name 'set faultDomainCount' $script:MaxRegionFaultDomains
			$_.properties.platformFaultDomainCount = $script:MaxRegionFaultDomains
		}
	}

	#--------------------------------------------------------------
	# update VMs
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$vmName = $_.name
		$asName, $x = $script:paramValues[$vmName] -split '/'
		$ppgName = $script:ppgOfAvset[$asName]

		if ($asName.length -ne 0) {

			# BICEP
			if ($useBicep) {
				$_.properties.availabilitySet = get-bicepIdStructByType 'Microsoft.Compute/availabilitySets' $asName
			}

			# ARM
			else {
				# get ID function
				$asID = get-resourceFunction `
							'Microsoft.Compute' `
							'availabilitySets'	$asName
	
				# set property
				$_.properties.availabilitySet = @{ id = $asID }
				
				# add new dependency
				[array] $_.dependsOn += $asID
			}
			write-logFileUpdates 'virtualMachines' $vmName 'set availabilitySet' $asName

			# for each VM in AvSet: add PPG if AvSet is part of the PPG
			if ($ppgName.length -ne 0) {

				# BICEP
				if ($useBicep) {
					$_.properties.proximityPlacementGroup = get-bicepIdStructByType 'Microsoft.Compute/proximityPlacementGroups' $ppgName
				}

				# ARM
				else {
					# get ID function
					$ppgID = get-resourceFunction `
								'Microsoft.Compute' `
								'proximityPlacementGroups'	$ppgName

					# set property
					$_.properties.proximityPlacementGroup = @{ id = $ppgID }
					
					# add new dependency
					[array] $_.dependsOn += $ppgID
				}
				write-logFileUpdates 'virtualMachines' $vmName 'set proximityPlacementGroup' $ppgName
			}
		}

		# save availabilitySet name
		if ($Null -ne $_.properties.availabilitySet.id) {
			$avsetName = (get-resourceComponents $_.properties.availabilitySet.id).mainResourceName
			$script:copyVMs[$vmName].AvsetName = $avsetName
			$script:copyVMs[$vmName].VmZone = 0
		}
	}
}

#--------------------------------------------------------------
function update-proximityPlacementGroup {
#--------------------------------------------------------------
	# This is called AFTER the new AvSets have been created
	# fill [hashtable] $script:paramValues
	set-parameter 'createProximityPlacementGroup' $createProximityPlacementGroup `
		'Microsoft.Compute/virtualMachines' `
		'Microsoft.Compute/availabilitySets' `
		'Microsoft.Compute/virtualMachineScaleSets'

	# update VMs and AvSets
	$script:resourcesALL
	| Where-Object type -in @(	'Microsoft.Compute/virtualMachines',
								'Microsoft.Compute/availabilitySets',
								'Microsoft.Compute/virtualMachineScaleSets')
	| ForEach-Object {

		$ppgName = $script:paramValues[$_.name]
		if ($null -ne $ppgName) {

			$x, $type = $_.type -split '/'
			if ($type -eq 'virtualMachineScaleSets') {

				$type = 'vmScaleSets'
				if (!($script:vmssProperties[$_.name].faultDomainCount -gt 1)) {
					write-logFileError "VM Scale Set '$($_.name)' cannot be part of a Proximity Placement Group'" `
										"because it uses multiple zones"
				}
			}
			write-logFileUpdates $type $_.name 'set proximityPlacementGroup' $ppgName

			# BICEP
			if ($useBicep) {
				$_.properties.proximityPlacementGroup = get-bicepIdStructByType 'Microsoft.Compute/proximityPlacementGroups' $ppgName
			}

			# ARM
			else {
				$id = get-resourceFunction `
						'Microsoft.Compute' `
						'proximityPlacementGroups'	$ppgName
	
				$_.properties.proximityPlacementGroup = @{id = $id}
				[array] $_.dependsOn += $id
			}
		}
	}

	# save PPG names
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		if ($Null -ne $_.properties.proximityPlacementGroup.id) {
			$ppgName = (get-resourceComponents $_.properties.proximityPlacementGroup.id).mainResourceName
			$script:copyVMs[$_.name].PpgName = $ppgName
		}
	}

	# collect PPGs
	$allPPGs = @{}
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$vmName = $_.name
		$ppgID = $_.properties.proximityPlacementGroup.id
		if ($null -ne $ppgID) {
			$ppgName = (get-resourceComponents $ppgID).mainResourceName
			if ($Null -ne $ppgName) {
				if ($Null -eq $allPPGs[$ppgName]) {
					$allPPGs[$ppgName] = New-Object psobject -Property @{
						name		= $ppgName
						vms			= @( $vmName )
						Zone		= 0
						vmsZone		= @()
						vmsOther	= @()
					}
				}
				else {
					$allPPGs[$ppgName].vms += $vmName
				}
			}
		}
	}

	# check zones
	foreach ($ppg in $allPPGs.Values) {
		foreach ($vmName in $ppg.vms) {
			$vmZone = $script:copyVMs[$vmName].VmZone
			if ($vmZone -eq 0) {
				$ppg.vmsOther += $vmName
			}
			else {
				$ppg.vmsZone += $vmName
				if ($ppg.zone -eq 0) {
					$ppg.zone = $vmZone
				}
				elseif ($ppg.zone -ne $vmZone) {
					write-logFileError "VMs of proximity placement group '$($ppg.name)' are in different zones"
				}
			}
		}
	}

	# make sure that VMs are deployed in right order
	foreach ($ppg in $allPPGs.Values) {
		if (($ppg.vmsZone.count -ne 0) -and ($ppg.vmsOther.count -ne 0)) {
			write-logFileWarning "Some VMs of proximity placement group '$($ppg.name)' are using zones, some not" `
									"Use RGCOPY parameter 'setVmDeploymentOrder' to:" `
									" firstly,  create VMs: $($ppg.vmsZone)" `
									" secondly, create VMs: $($ppg.vmsOther)" `
									-stopCondition $('setVmDeploymentOrder' -notin $boundParameterNames)
		}
	}
}

#--------------------------------------------------------------
function update-vmZone {
#--------------------------------------------------------------
	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$vmName 	= $_.Name
		$vmssName	= $_.VmssName
		$avsetName	= $_.AvsetName
		$vmZone		= $_.VmZone

		#--------------------------------------------------------------
		# check for vmss
		if ($Null -ne $vmssName) {
			$allowedZones = $script:vmssProperties[$vmssName].zones

			# VM configured without zone
			if ($vmZone -eq 0) {
				if ($allowedZones.count -gt 0) {
					write-logFileWarning "VMSS '$vmssName' is using zones" `
										"You must use RGCOPY parameter 'setVmZone' for VM '$vmName'" `
										-stopCondition $True
				}
			}

			# VM configured with zone
			else {
				if ($allowedZones.count -eq 0) {
					write-logFileWarning "VMSS '$vmssName' of VM '$vmName' does not support zones" `
										"You must use RGCOPY parameter 'setVmZone' for VM '$vmName'" `
										-stopCondition $True
				}

				elseif ("$vmZone" -notin $allowedZones) {
					write-logFileWarning "VMSS '$vmssName' of VM '$vmName' does not support zone $vmZone" `
										"You must use RGCOPY parameter 'setVmZone' for VM '$vmName'" `
										-stopCondition $True
				}
			}
		}

		#--------------------------------------------------------------
		# check for avset
		if (($Null -ne $avsetName) -and ($vmZone -ne 0)) {
			write-logFileWarning "VM '$vmName' is part of an Availability Set. It does not support zones" `
								"You must use RGCOPY parameter 'setVmZone' for VM '$vmName'" `
								-stopCondition $True
		}
	}

	#--------------------------------------------------------------
	# update virtualMachines
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$vmName = $_.name
		$zone = $script:copyVMs[$vmName].VmZone

		if ($zone -eq 0) {
			$_.zones = @()
		}
		else{
			$_.zones = @( "$zone" )
		}
	}
}

#--------------------------------------------------------------
function update-diskZone {
#--------------------------------------------------------------
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$diskName		= $_.Name
		$diskSku		= $_.SkuName 
		$diskZoneOld	= $_.DiskZone
		$diskZoneNew	= $diskZoneOld

		# attached disks
		if ($_.VM.Length -ne 0) {
			$diskZoneNew = $script:copyVMs[$_.VM].VmZone
		}
		# detached disks
		elseif ($Null -ne $defaultDiskZone) {
			$diskZoneNew = $defaultDiskZone
		}

		# just copy disks
		if (($justCopyDisks.count -ne 0) -and ($Null -ne $defaultDiskZone)) {
			$diskZoneNew = $defaultDiskZone
		}

		# check for ZRS
		if ($_.SkuName -like '*ZRS') {
			$diskZoneNew = 0
		}

		# set Zone
		if ($diskZoneNew -eq $diskZoneOld) {
			write-logFileUpdates 'disks' $diskName 'keep zone' $diskZoneNew
		}
		else {
			write-logFileUpdates 'disks' $diskName 'set zone' $diskZoneNew
			$_.DiskZone = $diskZoneNew
		}

		# check for ultra disks
		if ($diskSku -in @('UltraSSD_LRS', 'PremiumV2_LRS')) {
			if ($diskZoneNew -eq 0) {
				write-logFileWarning "Cannot change zone of disk '$diskName' to 0 because of its SKU '$diskSku'" `
									-stopCondition $True
			}
		}
	}
}

#--------------------------------------------------------------
function update-paramAll {
#--------------------------------------------------------------
	# required order:
	# 0. setVmZone
	update-paramSetVmZone

	# 1. setVmSize
	update-paramSetVmSize

	# 2. setDiskSku
	update-paramSetDiskSku

	# 3. setDiskSize (and setDiskTier)
	update-paramSetDiskSize
	update-paramSetDiskTier
	update-paramSetDiskBursting
	update-paramSetDiskMaxShares
	update-paramSetDiskIOps
	update-paramSetDiskMBps
	update-diskMBpsAndIOps

	# 4. setDiskCaching
	update-paramSetDiskCaching

	# 5. setAcceleratedNetworking
	update-paramSetAcceleratedNetworking

	# used for clone and merge mode
	update-paramAttachVmssFlex
	update-paramAttachAvailabilitySet
	update-paramAttachProximityPlacementGroup
}

#--------------------------------------------------------------
function update-resourcesAll {
#--------------------------------------------------------------
	# remove zones and tags
	update-zones
	update-tags

	# remove skipped resources 
	$script:skipIPs  = @()
	$script:skipNICs = @()
	update-skipVMsNICsIPs
	remove-resources 'Microsoft.Compute/virtualMachines' $script:skipVMs
	remove-resources 'Microsoft.Network/networkInterfaces' $script:skipNICs
	remove-resources 'Microsoft.Network/publicIPAddresses' $script:skipIPs
	
	$script:vmssProperties = @{}
	# merge/clone mode
	if ($cloneOrMergeMode) {
		update-attached4cloneOrMerge
		update-vmFaultDomain
	}

	# copy mode
	else {
		update-netApp
	
		if ($script:MaxRegionFaultDomains -lt 2) {
			write-logFileWarning "Region '$targetLocation' does not support VM Scale Sets Flexible"
			$script:skipVmssFlex	= $True
			$script:createVmssFlex	= @()
		}
	
		if (('createVmssFlex'					-in $boundParameterNames) `
		-or ('createAvailabilitySet'			-in $boundParameterNames) `
		-or ('createProximityPlacementGroup'	-in $boundParameterNames)) {
			
			write-logFileWarning "Existing Availability Sets, Proximity Placement Groups and VM Scale Sets are removed"
			$script:skipVmssFlex		 		= $True
			$script:skipAvailabilitySet 		= $True
			$script:skipProximityPlacementGroup = $True
		}
	
		# create PPG before AvSet and vmssFlex
		new-proximityPlacementGroup

		# get or remove existing VMSS
		get-vmssFlex
		
		# new VMSS after removing ALL existing VMSS
		new-vmssFlex
		update-faultDomainCount
		update-vmFaultDomain
		set-singlePlacementGroup

		# AvSets
		new-availabilitySet

		# TiP groups
		if ($msInternalVersion) {
			update-vmTipGroup
		}

		# update PPGs after VMSS and AvSets have been created
		update-proximityPlacementGroup
	}
	
	update-vmZone
	update-diskZone

	update-vmSize
	update-vmDisks
	update-vmBootDiagnostics
	update-vmPriority

	if (!$skipExtensions) {
		if ($msInternalVersion) {
			update-vmExtensionsMS
		}
		else {
			update-vmExtensionsPublic
		}
	}

	update-acceleratedNetworking
	update-subnetDelegation
	update-publicIPAddresses

	update-SKUs
	update-IpAllocationMethod
	update-FQDN
	
	if (!$useBicep) {
		# parameter skipSecurityRules has already been applied for BICEP (add-az_networkSecurityGroups)
		update-securityRules

		# parameter skipBastion has already been applied for BICEP (add-az_bastionHosts)
		update-bastion

		#--- process redeployment
		$script:resourcesNic = @()
		$script:resourcesLB = @()
		update-dependenciesAS
		update-dependenciesVNET
		update-dependenciesLB
		update-dependenciesNatGateways
		# Redeploy using saved NICS and LBs
		update-reDeployment
	}

	update-merge
	add-disksExisting
	add-disksNew
	update-images

	rename-VMs
	rename-disks
	rename-NICs
	rename-publicIPs
}

#--------------------------------------------------------------
function update-vmSize {
#--------------------------------------------------------------
	$script:templateVariables = @{}

	# change VM size
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$vmName = $_.name
		$vmSize   = $script:copyVMs[$vmName].VmSize
		$vmCpus   = $script:vmSkus[$vmSize].vCPUs
		$MemoryGB = $script:vmSkus[$vmSize].MemoryGB

		# vnName might contain special characters that are not allowed as variable name
		$name = $vmName -replace '[^A-Za-z0-9]', ''

		$script:templateVariables."vmSize$name" = $vmSize
		$script:templateVariables."vmCpus$name" = $vmCpus
		$script:templateVariables."vmMemGb$name" = $MemoryGB

		$_.properties.hardwareProfile.vmSize = $vmSize
	}
}

#--------------------------------------------------------------
function update-vmDisks {
#--------------------------------------------------------------
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$vmSize = $_.properties.hardwareProfile.vmSize
		$vmName = $_.name

		#--------------------------------------------------------------
		# disk controller type NVMe
		if ($_.properties.storageProfile.diskControllerType -eq 'NVMe') {
			
			# check if NVMe is supported for target VM size
			if ($script:vmSkus[$vmSize].DiskControllerTypes -notlike "*NVMe*") {
				write-logFileError "VM size '$vmSize' does not support disk controller type NVMe" `
									"Cannot change VM size of VM '$vmName'"
			}
		}

		#--------------------------------------------------------------
		# disk controller type SCSI
		else {

			# remove diskControllerType if it is not NVMe
			# This is needed as long as this property is not available in all regions
			if ($Null -ne $_.properties.storageProfile.diskControllerType) {
				$_.properties.storageProfile.diskControllerType = $Null
			}

			# check if NVMe is supported for target VM size
			if ($script:vmSkus[$vmSize].DiskControllerTypes -notlike "*SCSI*") {
				write-logFileError "VM size '$vmSize' does not support disk controller type SCSI" `
									"Cannot change VM size of VM '$vmName'"
			}
		}
		#--------------------------------------------------------------

		# check if TrustedLaunch is supported for target VM size
		if ($_.properties.securityProfile.securityType -eq 'TrustedLaunch') {
			if ($script:vmSkus[$vmSize].TrustedLaunchDisabled -eq $True) {
				write-logFileError "VM size '$vmSize' does not support trusted lauch" `
									"Cannot change VM size of VM '$vmName'"
			}
		}

		# remove image reference
		if ($Null -ne $_.properties.storageProfile.imageReference) {
			$_.properties.storageProfile.imageReference = $null
		}

		# remove osProfile
		if ($Null -ne $_.properties.osProfile) {
			$_.properties.osProfile = $null
		}

		# remove dependencies of old StorageAccounts and disks
		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Storage/StorageAccounts*'
		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Compute/disks'

		# OS disk
		$diskName = $_.properties.storageProfile.osDisk.name
		$_.properties.storageProfile.osDisk.createOption = 'Attach'
		$_.properties.storageProfile.osDisk.diskSizeGB = $Null
		$_.properties.storageProfile.osDisk.encryptionSettings = $Null
		$_.properties.storageProfile.osDisk.managedDisk.storageAccountType = $Null
		$_.properties.storageProfile.osDisk.caching = $script:copyDisks[$diskName].Caching
		$_.properties.storageProfile.osDisk.writeAcceleratorEnabled = $script:copyDisks[$diskName].WriteAcceleratorEnabled
		$ultraSSDNeeded = $False
		if ($script:copyDisks[$diskName].SkuName -eq 'UltraSSD_LRS') {
			$ultraSSDNeeded = $True
		}

		# ARM
		if (!$useBicep) {
			$r = get-resourceComponents $_.properties.storageProfile.osDisk.managedDisk.id
			$id = get-resourceFunction `
					'Microsoft.Compute' `
					'disks'	$r.mainResourceName
			$_.properties.storageProfile.osDisk.managedDisk.id = $id
			[array] $_.dependsOn += $id
		}

		# data disks
		for ($i = 0; $i -lt $_.properties.storageProfile.dataDisks.count; $i++) {
			$diskName = $_.properties.storageProfile.dataDisks[$i].name
			$_.properties.storageProfile.dataDisks[$i].createOption = 'Attach'
			$_.properties.storageProfile.dataDisks[$i].diskSizeGB = $Null
			$_.properties.storageProfile.dataDisks[$i].managedDisk.storageAccountType = $Null
			$_.properties.storageProfile.dataDisks[$i].caching = $script:copyDisks[$diskName].Caching
			$_.properties.storageProfile.dataDisks[$i].writeAcceleratorEnabled 	= $script:copyDisks[$diskName].WriteAcceleratorEnabled

			if ($diskName -in $skipDisks) {
				write-logFileUpdates 'virtualMachines' $_.name 'delete disk' $diskName
			}
			elseif ($script:copyDisks[$diskName].SkuName -eq 'UltraSSD_LRS') {
				$ultraSSDNeeded = $True
			}

			# ARM
			elseif (!$useBicep) {
				$r = get-resourceComponents $_.properties.storageProfile.dataDisks[$i].managedDisk.id
				$id = get-resourceFunction `
						'Microsoft.Compute' `
						'disks'	$r.mainResourceName
				$_.properties.storageProfile.dataDisks[$i].managedDisk.id = $id
				[array] $_.dependsOn += $id
			}
		}

		# remove skipped data disks
		$_.properties.storageProfile.dataDisks = convertTo-array ( `
			$_.properties.storageProfile.dataDisks | Where-Object name -notin $skipDisks )



		# set ultraSSDEnabled
		if ($Null -ne $_.properties.additionalCapabilities) {
			if ($ultraSSDEnabled -or $ultraSSDNeeded) {
				$_.properties.additionalCapabilities.ultraSSDEnabled = $True
				write-logFileUpdates 'virtualMachines' $_.name 'set Ultra SSD support'
			}
			else {
				$_.properties.additionalCapabilities.ultraSSDEnabled = $Null
				write-logFileUpdates 'virtualMachines' $_.name 'delete Ultra SSD support'
			}
		}
		elseif ($ultraSSDEnabled -or $ultraSSDNeeded) {
			$_.properties.additionalCapabilities = @{ ultraSSDEnabled = $True }
			write-logFileUpdates 'virtualMachines' $_.name 'set Ultra SSD support'
		}
	}
}

#--------------------------------------------------------------
function update-vmBootDiagnostics {
#--------------------------------------------------------------
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		# remove old dependencies to storage accounts
		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Storage/StorageAccounts*'

		# enable Boot diagnostics managed storage account
		if ($skipBootDiagnostics) {
			$_.properties.diagnosticsProfile = $Null
		}
		else {
			$_.properties.diagnosticsProfile = @{
				bootDiagnostics = @{
					enabled = $True
				}
			}
		}
	}
}

#--------------------------------------------------------------
function update-vmPriority {
#--------------------------------------------------------------
	# calculate dependencies based on priority
	[array] $nextDependentVMs	= @() # collect dependent VMs for next priority
	[array] $currentDependentVMs	= @()
	$currentPriority 			= 0
	$firstPriority				= 0

	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| Sort-Object VmPriority
	| ForEach-Object {

		$vmName 	= $_.Name
		$vmPriority = $_.VmPriority

		if ($firstPriority -eq 0) {
			$firstPriority = $vmPriority
		}

		# same priority as last VM
		if ($vmPriority -eq $currentPriority) {
			[array] $dependentVMs 			= $currentDependentVMs
		}
		# new priority
		else {
			[array] $dependentVMs 			= $nextDependentVMs
			[array] $currentDependentVMs	= $nextDependentVMs
			[array] $nextDependentVMs		= @()
		}

		$currentPriority = $vmPriority

		# BICEP
		if ($useBicep) {
			$bicepName = get-bicepNameByType 'Microsoft.Compute/virtualMachines' $vmName
			$nextDependentVMs += "<$bicepName>"
		}

		# ARM
		else {
			$nextDependentVMs += get-resourceFunction `
									'Microsoft.Compute' `
									'virtualMachines'	$vmName
		}

		# update (exactly one) VM
		if ($vmPriority -ne $firstPriority) {
			$script:resourcesALL
			| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
			| Where-Object name -eq $vmName
			| ForEach-Object {

				[array] $_.dependsOn += $dependentVMs
			}
		}
	}
}

#--------------------------------------------------------------
function add-disksNew {
#--------------------------------------------------------------
	$script:copyVMs.Values
	| Where-Object MountPoints.count -ne 0
	| ForEach-Object {

		$vmName = $_.Name
		$vmZone = $_.VmZone
		[array] $allLuns = $_.DataDisks.Lun

		# get AvSet
		$script:vmAvSet = $Null
		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
		| Where-Object name -eq $vmName
		| ForEach-Object {
			$script:vmAvSet = $_.properties.availabilitySet
		}

		# process new disks
		foreach ($mp in $_.MountPoints) {
			if ($mp.Type -eq 'Disk') {
				$diskSize = $mp.Size
				$iops = $mp.Iops
				$mbps = $mp.Mbps

				# get new LUN
				[int] $diskLun = -1
				$maxLun = ($allLuns | Measure-Object -Maximum).Maximum
				if ($maxLun -lt 63) {
					[int] $diskLun = $maxLun + 1
					[array] $allLuns += $diskLun
				}
				else {
					for ($i = 63; $i -ge 0; $i--) {
						if ($i -notin $allLuns) {
							[int] $diskLun = $i
							[array] $allLuns += $diskLun
							break
						}
					}
				}
				if ($diskLun -eq -1) {
					write-logFileError "Invalid parameter 'createDisks'" `
										"No free LUN in VM '$vmName'"
				}

				# get new disk name
				$diskName = "$vmName`__disk_lun_$diskLun"

				# disk properties
				$properties = @{
					diskSizeGB 		= $diskSize
					creationData	= @{ createOption = 'Empty' }
				}

				# UltraSSD_LRS
				if ($iops -gt 0) {
					$skuName = 'UltraSSD_LRS'

					if ($Null -ne $script:vmAvSet) {
						write-logFileError "Invalid parameter 'createDisks'" `
											"Ultra SSD disk should be created in VM '$vmName'" `
											"VM '$vmName' is part of an Availability Set (that does not allow Ultra SSD disks)"
					}
					if ($vmZone -eq 0) {
						write-logFileError "Invalid parameter 'createDisks'" `
											"Ultra SSD disk should be created in VM '$vmName'" `
											"Therefore, VM '$vmName' must be in an Availability Zone"
					}

					$SizeTierName = 'Ultra'
					$performanceTierName = ''
					$properties.Add('diskIOPSReadWrite', $iops)
					$properties.Add('diskMBpsReadWrite', $mbps)
					$info = "$diskSize GiB ($iops IOPs, $mbps MB/s)"
				}

				# Premium_LRS
				else {
					$skuName = 'Premium_LRS'

					# get performance tier
					$performanceTierName = $createDisksTier
					$performanceTierGB   = get-diskSize $performanceTierName
					$SizeTierName        = get-diskTier $diskSize $skuName
					$SizeTierGB          = get-diskSize $SizeTierName
					# set minimum performance tier
					if ($performanceTierGB -gt $SizeTierGB) {
						$properties.Add('tier', $performanceTierName)
						$tierInfo = ", performance=$performanceTierName"
					}
					else {
						$performanceTierName = ''
						$tierInfo = ''
					}
					$info = "$diskSize GiB ($SizeTierName)$tierInfo"
				}

				# save disk
				if ($vmZone -gt 0) {
					$diskZone = $vmZone
				}
				else {
					$diskZone = 0
				}

				$script:copyDisksNew[$diskName] = @{
					name					= "$diskName (NEW)"
					VM						= $vmName
					Skip					= $False
					Caching					= 'None'
					WriteAcceleratorEnabled	= $False
					SizeGB					= $diskSize
					SizeTierName			= $SizeTierName
					performanceTierName		= $performanceTierName
					SkuName					= $skuName
					DiskZone				= $diskZone
				}

				# create disk
				$disk = @{
					type 			= 'Microsoft.Compute/disks'
					apiVersion		= '2022-07-02'
					name 			= $diskName
					location		= $targetLocation
					sku				= @{ name = $skuName }
					properties		= $properties
					tags			= @{
						"$azTagSub"		= $sourceSub
						"$azTagRG"		= $sourceRG
						"$azTagSA"		= $sourceSA
						"$azTagPath"	= $mp.Path
						"$azTagLun"		= $diskLun
						"$azTagVM"		= $vmName
					}
				}

				# set disk zone
				if ($diskZone -gt 0) {
					$disk.Add('zones', @($diskZone) )
				}

				# add disk
				write-logFileUpdates 'disks' $diskName 'create empty disk' '' '' $info
				add-resourcesALL $disk

				# update a single vm
				$script:resourcesALL
				| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
				| Where-Object name -eq $vmName
				| ForEach-Object {

					$dataDisk = @{
						lun						= $diskLun
						name					= $diskName
						createOption			= 'Attach'
						caching					= 'None'
						writeAcceleratorEnabled	= $False
						toBeDetached			= $False
					}

					# BICEP
					if ($useBicep) {
						$dataDisk.managedDisk = get-bicepIdStructByType 'Microsoft.Compute/disks'	$diskName
					}

					# ARM
					else {
						$diskId = get-resourceFunction `
									'Microsoft.Compute' `
									'disks'	$diskName

						$dataDisk.managedDisk = @{ id = $diskId }
						[array] $_.dependsOn += $diskId
					}
					# add disk
					[array] $_.properties.storageProfile.dataDisks += $dataDisk

					# add ultraSSDEnabled
					if (($iops -gt 0) -or ($ultraSSDEnabled)) {
						$_.properties.additionalCapabilities = @{ultraSSDEnabled = $True}
						write-logFileUpdates 'virtualMachines' $_.name 'add Ultra SSD support'
					}
				}
			}
		}
	}
}

#--------------------------------------------------------------
function add-disksExisting {
#--------------------------------------------------------------
	# create disks
	$script:copyDisks.Values
	| ForEach-Object {

		$diskName = $_.Name
		$snapshotName = $_.SnapshotName

		if ($_.Skip -eq $True) {
			if (!$cloneOrMergeMode) {
				write-logFileUpdates 'disks' $diskName 'skip disk'
			}
		}
		elseif ($_.VM -in $generalizedVMs) {
			# nothing to do here
		}
		else {
			#--------------------------------------------------------------
			# creation from SNAPSHOT
			if (!$_.BlobCopy) {
				$from = 'snapshot'

				if ($_.SnapshotCopy) {
					$rg = $targetRG
					$subID = $targetSubID
				}
				else {
					$rg = $sourceRG
					$subID = $sourceSubID
				}


				# BICEP
				if ($useBicep) {
					$snapshotId = "<resourceId('$subID','$rg','Microsoft.Compute/snapshots','$snapshotName')>"
				}

				# ARM
				else {
					$snapshotId = get-resourceString `
									$subID		$rg `
									'Microsoft.Compute' `
									'snapshots'			$snapshotName
				}

				$creationData = @{
					createOption 		= 'Copy'
					sourceResourceId 	= $snapshotId
				}
			}
	
			#--------------------------------------------------------------
			# creation from BLOB
			else {
				$from = 'BLOB'

				# BICEP
				if ($useBicep) {
					$blobsSaID = "<resourceId('$targetSubID','$blobsRG','Microsoft.Storage/storageAccounts','$blobsSA')>"
				}

				# ARM
				else {
					$blobsSaID = get-resourceString `
									$targetSubID		$blobsRG `
									'Microsoft.Storage' `
									'storageAccounts'	$blobsSA
				}

				$creationData = @{
					createOption 		= 'Import'
					storageAccountId 	= $blobsSaID
					sourceUri 			= "https://$blobsSA.blob.core.windows.net/$blobsSaContainer/$diskName.vhd"
				}
			}

			# sector size
			if ($_.SkuName -in @('UltraSSD_LRS', 'PremiumV2_LRS')) {
				if (($Null -eq $_.LogicalSectorSize) -or ($_.LogicalSectorSize -eq 512)) {
					$creationData.logicalSectorSize = 512
				}
			}
	
			#--------------------------------------------------------------
			# general

			# disk properties
			$properties = @{
				diskSizeGB 			= $_.SizeGB
				creationData		= $creationData
				tier				= $_.performanceTierName
				burstingEnabled		= $_.BurstingEnabled 
			}

			if ($_.DiskIOPSReadWrite -gt 0) {
				$properties.diskIOPSReadWrite = $_.DiskIOPSReadWrite
			}	

			if ($_.DiskMBpsReadWrite -gt 0) {
				$properties.diskMBpsReadWrite = $_.DiskMBpsReadWrite
			}	

			if ($_.MaxShares -gt 1) {
				$properties.maxShares = $_.MaxShares
			}			

			if ($_.OsType.length -gt 0) {
				$properties.osType = $_.OsType
			}

			if ($_.HyperVGeneration.length -gt 0) {
				$properties.hyperVGeneration = $_.HyperVGeneration
			}
	
			if ($_.DiskControllerType -eq 'NVME') {
				$properties.supportedCapabilities =  @{diskControllerTypes = 'SCSI, NVMe'}
			}

			if ($useBicep) {
				$regionName = '<regionName>'
			}
			else {
				$regionName = $targetLocation
			}
	
			# new resource
			$resource = @{
				type 			= 'Microsoft.Compute/disks'
				apiVersion		= '2022-07-02'
				name 			= $diskName
				location		= $regionName
				sku				= @{
					name = $_.SkuName
				}
				properties		= $properties
			}
	
			# tags and zones
			$tags = $_.Tags -as [hashtable]
			if ($tags.count -ne 0) {
				$resource.tags = $tags 
			}
			if ($_.DiskZone -gt 0) {
				$resource.zones = @( $_.DiskZone -as [string] )
			}
	
			write-logFileUpdates 'disks' $diskName "create from $from" '' '' "$($_.SizeGB) GiB"
			add-resourcesALL $resource
		}
	}
}

#--------------------------------------------------------------
function update-images {
#--------------------------------------------------------------

	#--------------------------------------------------------------
	# add images
	$script:copyVMs.Values
	| Where-Object name -in $generalizedVMs
	| ForEach-Object {

		$imageName = "$($_.Name).$snapshotExtension"

		# add OS disk to image
		$diskName = $_.OsDisk.Name
		$snapshotName = $script:copyDisks[$diskName].SnapshotName
		$snapshotId = get-resourceString `
						$sourceSubID		$sourceRG `
						'Microsoft.Compute' `
						'snapshots'			$snapshotName

		$ImageOsDisk = @{
			snapshot			= @{ id = $snapshotId }
			diskSizeGB			= $script:copyDisks[$diskName].SizeGB
			storageAccountType	= $script:copyDisks[$diskName].SkuName
			osState				= 'Generalized'
		}
		if ($_.OsDisk.OsType.length -ne 0) 	{ $ImageOsDisk.Add('osType', $_.OsDisk.OsType) }
		if ($_.OsDisk.Caching.length -ne 0) { $ImageOsDisk.Add('caching', $_.OsDisk.Caching) }
		# WriteAcceleratorEnabled not supported for images

		# hyperV Generation
		$hyperVGeneration = 'V1'
		if ($_.OsDisk.hyperVGeneration.length -ne 0) {
			$hyperVGeneration = $_.OsDisk.hyperVGeneration
		}

		# add data disks to image
		$ImageDataDisks = @()
		foreach($disk in $_.DataDisks) {

			$diskName = $disk.Name
			$snapshotName = $script:copyDisks[$diskName].SnapshotName
			$snapshotId = get-resourceString `
							$sourceSubID		$sourceRG `
							'Microsoft.Compute' `
							'snapshots'			$snapshotName

			$imageDisk = @{
				snapshot			= @{ id = $snapshotId }
				diskSizeGB			= $script:copyDisks[$diskName].SizeGB
				storageAccountType	= $script:copyDisks[$diskName].SkuName
				lun					= $disk.Lun
			}
			if ($disk.Caching.length -ne 0) { $imageDisk.Add('caching', $disk.Caching) }
			# WriteAcceleratorEnabled not supported for images

			$ImageDataDisks += $imageDisk
		}

		# finish image creation
		$image = @{
			type 			= 'Microsoft.Compute/images'
			apiVersion		= '2019-12-01'
			name 			= $imageName
			location		= $targetLocation
			properties		= @{
				hyperVGeneration	= $hyperVGeneration
				storageProfile		= @{
					osDisk				= $ImageOsDisk
					dataDisks			= $ImageDataDisks
					zoneResilient 		= $False
				}
			}
		}
		write-logFileUpdates 'images' $_.name 'create'
		add-resourcesALL $image
	}

	#--------------------------------------------------------------
	# create VM from image
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| Where-Object name -in $generalizedVMs
	| ForEach-Object {

		# BICEP
		if ($useBicep) {
			$_.properties.storageProfile.imageReference = get-bicepIdStructByType 'Microsoft.Compute/images' $imageName
		}

		# ARM
		else {
			# image
			$imageId = get-resourceFunction `
							'Microsoft.Compute' `
							'images'	$imageName
	
			$_.properties.storageProfile.imageReference = @{ id = $imageId }
	
			# remove dependencies of disks
			$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Compute/disks'
			# add dependency of image
			[array] $_.dependsOn += $imageId
		}

		# os disk
		$_.properties.storageProfile.osDisk.managedDisk.id 	= $Null
		$_.properties.storageProfile.osDisk.createOption 	= 'fromImage'

		# data disks
		for ($i = 0; $i -lt $_.properties.storageProfile.dataDisks.count; $i++) {

			$_.properties.storageProfile.dataDisks[$i].managedDisk.id 	= $Null
			$_.properties.storageProfile.dataDisks[$i].createOption 	= 'fromImage'
		}

		# osProfile
		$osProfile = @{
			computerName	= $_.name
			adminUsername	= $script:copyVMs[$_.name].GeneralizedUser
			adminPassword	= (ConvertFrom-SecureString -SecureString $script:copyVMs[$_.name].GeneralizedPasswd -AsPlainText)
		}
		$_.properties.osProfile = $osProfile
	}
}

#--------------------------------------------------------------
function update-bastion {
#--------------------------------------------------------------
	if (!$skipBastion -and ($targetLocationDisplayName -ne 'Canary' )) {
		return
	}

	[array] $bastionSubNets = @()

	# get bastions
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/bastionHosts'
	| ForEach-Object {

		write-logFileUpdates 'bastionHosts' $_.name 'delete'

		# get bastion subnets
		foreach ($d in $_.dependsOn) {
			if ($d  -like "*'Microsoft.Network/virtualNetworks/subnets'*") {

				$r = get-resourceComponents $d
				$subnet = "$($r.mainResourceName)/$($r.subResourceName)"
				$bastionSubNets += $subnet
				write-logFileUpdates 'subnets' $subnet 'delete'

				#update vnet
				$script:resourcesALL
				| Where-Object type -eq 'Microsoft.Network/virtualNetworks'
				| Where-Object name -eq $r.mainResourceName
				| ForEach-Object {

					[array] $subNets = @()
					foreach ($s in $_.properties.subnets) {
						if ($s.name -ne $r.subResourceName) {
							$subNets += $s
						}
					}
					$_.properties.subnets = $subNets
				}
			}
		}
	}
	remove-resources 'Microsoft.Network/bastionHosts'
	remove-resources 'Microsoft.Network/virtualNetworks/subnets' $bastionSubNets
}

#--------------------------------------------------------------
function update-netApp {
#--------------------------------------------------------------
	if ($script:mountPointsVolumesGB -eq 0) {
		return
	}

	# check parameters
	if ($script:netAppPoolGB -lt $script:mountPointsVolumesGB) {
		$script:netAppPoolGB = $script:mountPointsVolumesGB
	}

	#--------------------------------------------------------------
	# add netAppAccount
	$res = @{
		type 		= 'Microsoft.NetApp/netAppAccounts'
		apiVersion	= '2021-04-01'
		name 		= $netAppAccountName
		location	= $targetLocation
		properties	= @{
			encryption = @{
				keySource = 'Microsoft.NetApp'
			}
		}
	}
	write-logFileUpdates 'netAppAccounts' $netAppAccountName 'create'
	add-resourcesALL $res

	#--------------------------------------------------------------
	# add capacityPool
	$res = @{
		type 		= 'Microsoft.NetApp/netAppAccounts/capacityPools'
		apiVersion	= '2021-04-01'
		name 		= "$netAppAccountName/$netAppPoolName"
		location	= $targetLocation
		properties	= @{
			serviceLevel	= $netAppServiceLevel
			size			= $script:netAppPoolGB * 1024 * 1024 * 1024
			qosType			= 'Auto'
			coolAccess		= $False
		}
	}

	# BICEP
	if ($useBicep) {
		$res.parent = "<$(get-bicepNameByType 'Microsoft.NetApp/netAppAccounts' $netAppAccountName)>"
	}

	# ARM
	else {
		[array] $dependsOn = get-resourceFunction `
								'Microsoft.NetApp' `
								'netAppAccounts'	$netAppAccountName

		$res.dependsOn = $dependsOn
	}

	write-logFileUpdates 'capacityPools' $netAppPoolName 'create'
	add-resourcesALL $res

	#--------------------------------------------------------------
	# get subnetID
	$vnet = $Null

	# BICEP
	if ($useBicep) {
		foreach ($net in $script:az_virtualNetworks) {
			foreach ($sub in $net.Subnets) {
				foreach ($delegation in $sub.Delegations) {
					if ($delegation.ServiceName -eq 'Microsoft.NetApp/volumes') {
						$vnet	= $net.Name
						$subnet = $sub.Name
					}
				}
			}
		}
	}

	# ARM
	else {
		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Network/virtualNetworks/subnets'
		| ForEach-Object {
	
			if ($Null -ne $_.properties.delegations) {
				if ($Null -ne $_.properties.delegations.properties) {
					if ($_.properties.delegations.properties.serviceName -eq 'Microsoft.NetApp/volumes') {
						$vnet,$subnet = $_.name -split '/'
					}
				}
			}
		}
	}

	# subnet not found, create one
	if ($Null -eq $vnet) {
		if ('netAppSubnet' -notin $boundParameterNames) {
			write-logFileError "Invalid parameter 'createVolumes'" `
								"Either a subnet with NetApp/volumes delegation must already exist" `
								"or parameter 'netAppSubnet' must be supplied"
		}
		else {
			$vnet, $subnet, $addressPrefix = test-subnet 'netAppSubnet' $netAppSubnet 'NetApp'
		}
	}

	$vnetId = get-resourceFunction `
					'Microsoft.Network' `
					'virtualNetworks'	$vnet

	$subnetId = get-resourceFunction `
					'Microsoft.Network' `
					'virtualNetworks'	$vnet `
					'subnets'			$subnet

	# ARM
	if (!$useBicep) {
		$dependsOn += $subnetId
		$dependsOn += get-resourceFunction `
						'Microsoft.NetApp' `
						'netAppAccounts'	$netAppAccountName `
						'capacityPools'		$netAppPoolName
	}

	if ($Null -ne $addressPrefix) {
		#--------------------------------------------------------------
		# modify vnet
		$existingVnet = $script:resourcesALL
						| Where-Object type -eq 'Microsoft.Network/virtualNetworks'
						| Where-Object name -eq $vnet

		if ($null -eq $existingVnet) {
			write-logFileError "Vnet '$vnet' not found"
		}

		$apiVersion = $existingVnet.apiVersion

		# create subnet inside VNET
		[array] $existingVnet.properties.subnets += @{
			name		= $subnet
			properties	= @{
				addressPrefix = $addressPrefix
				delegations = @(
					@{
						name		= 'Microsoft.Netapp.volumes'
						properties	= @{
							serviceName = 'Microsoft.Netapp/volumes'
						}
					}
				)
			}
		}

		#--------------------------------------------------------------
		# create sub-resource only for ARM needed
		$res = @{
			type 		= 'Microsoft.Network/virtualNetworks/subnets'
			apiVersion	= $apiVersion
			name 		= "$vnet/$subnet"
			properties	= @{
				addressPrefix = $addressPrefix
				delegations = @(
					@{
						name		= 'Microsoft.Netapp.volumes'
						properties	= @{
							serviceName = 'Microsoft.Netapp/volumes'
						}
					}
				)
			}
		}

		# ARM
		if (!$useBicep) {
			$res.dependsOn	= @( $vnetId )
			write-logFileUpdates 'subnet' $subnet 'create'
			add-resourcesALL $res
		}
	}

	#--------------------------------------------------------------
	# add volumes
	$rule = @{
		ruleIndex			= 1
		unixReadOnly		= $False
		unixReadWrite		= $True
		cifs				= $False
		nfsv3				= $False
		nfsv41				= $True
		allowedClients		= '0.0.0.0/0'
		kerberos5ReadOnly	= $False
		kerberos5ReadWrite	= $False
		kerberos5iReadOnly	= $False
		kerberos5iReadWrite	= $False
		kerberos5pReadOnly	= $False
		kerberos5pReadWrite	= $False
		hasRootAccess		= $True
	}

	# create volume
	$script:copyVMs.values
	| Where-Object MountPoints.count -ne 0
	| ForEach-Object {

		if ($_.Rename.length -ne 0)	{ $vmName = $_.Rename }
		else 						{ $vmName = $_.Name }

		$_.MountPoints
		| Where-Object Type -eq 'NetApp'
		| ForEach-Object {

			$path = $_.Path
			$volumeSizeGB = $_.Size
			$volumeName = "$vmName$($path -replace '/', '-')"

			$res = @{
				type 		= 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes'
				apiVersion	= '2021-04-01'
				name 		= "$netAppAccountName/$netAppPoolName/$volumeName"
				location	= $targetLocation
				properties	= @{
					# throughputMibps				= 65536
					coolAccess					= $False
					serviceLevel				= $netAppServiceLevel
					creationToken				= $volumeName
					usageThreshold				= $volumeSizeGB * 1024 * 1024 * 1024
					exportPolicy				= @{ rules = @( $rule ) }
					protocolTypes				= @( 'NFSv4.1' )
					snapshotDirectoryVisible	= $True
					kerberosEnabled				= $False
					securityStyle				= 'Unix'
					smbEncryption				= $False
					smbContinuouslyAvailable	= $False
					encryptionKeySource			= 'Microsoft.NetApp'
					ldapEnabled					= $False
				}
				tags			= @{
					"$azTagSub"		= $sourceSub
					"$azTagRG"		= $sourceRG
					"$azTagSA"		= $sourceSA
					"$azTagPath"	= $path
					"$azTagVM"		= $vmName
				}
			}

			# BICEP
			if ($useBicep) {
				$res.parent = "<$(get-bicepNameByType 'Microsoft.NetApp/netAppAccounts/capacityPools' "$netAppAccountName/$netAppPoolName")>"
				$res.properties.subnetId = $subnetId # <resourceId(...)>
				$res.dependsOn = @( "<$(get-bicepNameByType 'Microsoft.Network/virtualNetworks' $vnet)>" )
			}

			# ARM
			else {
				$res.properties.subnetId = $subnetId # [resourceId(...)]
				$res.dependsOn = $dependsOn
			}

			write-logFileUpdates 'volumes' $volumeName 'create' '' '' "$volumeSizeGB GiB"
			add-resourcesALL $res
		}
	}
}

#--------------------------------------------------------------
function rename-any {
#--------------------------------------------------------------
	param (
		$nameOld,
		$nameNew,
		$resourceArea,
		$mainResourceType,
		$subResourceType
	)

	$a,$b = $nameOld -split '/'
	$resourceOld = get-resourceFunction `
		$resourceArea `
		$mainResourceType	$a `
		$subResourceType	$b

	$c,$d = $nameNew -split '/'
	$resourceNew = get-resourceFunction `
		$resourceArea `
		$mainResourceType	$c `
		$subResourceType	$d

	if ($Null -eq $subResourceType) {
		$type = "$resourceArea/$mainResourceType"
	}
	else {
		$type = "$resourceArea/$mainResourceType/$subResourceType"
	}

	$found = $False
	# rename resource
	$script:resourcesALL
	| Where-Object name -eq $nameOld
	| Where-Object type -eq $type
	| ForEach-Object {

		$_.name = $nameNew
		$found = $True
	}

	# rename dependencies
	$script:resourcesALL
	| ForEach-Object {

		for ($i = 0; $i -lt $_.dependsOn.count; $i++) {
			if ($True -eq (compare-resources $_.dependsOn[$i]   $resourceOld)) {
				$_.dependsOn[$i] = $resourceNew
			}
		}
	}

	return ($found, $resourceNew)
}

#--------------------------------------------------------------
function rename-VMs {
#--------------------------------------------------------------
	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$nameOld 	= $_.Name
		$nameNew	= $nameOld

		if ($_.Rename.length -ne 0) {
			$nameNew	= $_.Rename
		}

		if ($nameOld -ne $nameNew) {
			$found, $resFunctionNew = rename-any $nameOld $nameNew 'Microsoft.Compute' 'virtualMachines'
			if($found) {
				write-logFileUpdates 'virtualMachines' $nameOld 'rename to' $nameNew
			}
		}
	}
}

#--------------------------------------------------------------
function rename-NICs {
#--------------------------------------------------------------
	$script:copyNICs.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$nameOld 	= $_.NicName
		$nameNew	= $nameOld

		if ($_.Rename.length -ne 0) {
			$nameNew	= $_.Rename
		}

		if ($nameOld -ne $nameNew) {
			$found, $resFunctionNew = rename-any $nameOld $nameNew 'Microsoft.Network' 'networkInterfaces'
			if($found) {
				write-logFileUpdates 'networkInterfaces' $nameOld 'rename to' $nameNew
			}
		}
	}
}

#--------------------------------------------------------------
function rename-publicIPs {
#--------------------------------------------------------------
	if (!$cloneMode) {
		return
	}	

	$script:copyPublicIPs.Values
	| ForEach-Object {

		$nameOld 	= $_.Name
		$nameNew	= $_.Rename

		if ($nameOld -ne $nameNew) {
			$found, $resFunctionNew = rename-any $nameOld $nameNew 'Microsoft.Network' 'publicIPAddresses'
			if($found) {
				write-logFileUpdates 'publicIPAddresses' $nameOld 'rename to' $nameNew
			}
		}
	}
}

#--------------------------------------------------------------
function rename-disks {
#--------------------------------------------------------------
	param (
		[switch] $getMergeNames
	)

	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {
		
		$vmName = $_.name
		if ($script:copyVMs[$vmName].Rename.length -ne 0) {
			$vmName =  $script:copyVMs[$vmName].Rename
		}
		
		# rename VM OS Disk
		$len = (71, $vmName.Length | Measure-Object -Minimum).Minimum
		$vmNameShort = $vmName.SubString(0,$len)

		$nameOld = $_.properties.storageProfile.osDisk.name
		$nameNew = $nameOld

		if ($cloneOrMergeMode) {
			$nameNew = $script:copyDisks[$nameOld].Rename
		}

		if ($renameDisks) {
			$nameNew = "$vmNameShort`__disk_os" #max length 80
		}

		if ($getMergeNames) {
			$script:mergeDiskNames += $nameNew
		}
		elseif ($nameOld -ne $nameNew) {
			write-logFileUpdates 'disks' $nameOld 'rename to' $nameNew
			# rename
			$found, $resFunctionNew = rename-any $nameOld $nameNew 'Microsoft.Compute' 'disks'

			$script:copyDisks[$nameOld].Rename = $nameNew
			$_.properties.storageProfile.osDisk.name = $nameNew

			if (!$useBicep) {
				$_.properties.storageProfile.osDisk.managedDisk.id = $resFunctionNew
			}
		}

		# rename VM Data Disks
		$len = (67, $vmName.Length | Measure-Object -Minimum).Minimum
		$vmNameShort = $vmName.SubString(0,$len)

		foreach ($disk in $_.properties.storageProfile.dataDisks) {

			$nameOld = $disk.name
			$nameNew = $nameOld

			if ($cloneOrMergeMode) {
				$nameNew = $script:copyDisks[$nameOld].Rename
			}

			if ($renameDisks) {
				$nameNew = "$vmNameShort`__disk_lun_$($disk.lun)" #max length 80
			}

			if ($getMergeNames) {
				$script:mergeDiskNames += $nameNew
			}
			elseif ($nameOld -ne $nameNew) {
				write-logFileUpdates 'disks' $nameOld 'rename to' $nameNew
				# rename
				$found, $resFunctionNew = rename-any $nameOld $nameNew 'Microsoft.Compute' 'disks'
				
				$script:copyDisks[$nameOld].Rename = $nameNew
				$disk.name = $nameNew
	
				if (!$useBicep) {
					$disk.managedDisk.id = $resFunctionNew
				}
			}
		}
	}
}

#--------------------------------------------------------------
function remove-resources4cloneOrMerge {
#--------------------------------------------------------------
	if (!$cloneOrMergeMode) {
		return
	}

	# keep VMs
	$keepResources = @(
		$script:resourcesALL `
		| Where-Object { ($_.type -eq 'Microsoft.Compute/virtualMachines') `
					-and (($_.name -in $script:cloneVMs) -or ($_.name -in $script:mergeVMs)) } `
	)
	
	# keep NICs
	$cloneNICs = ($script:copyNICs.Values | Where-Object VmName -in $script:cloneVMs).NicName

	$script:copyNICs.Values
	| ForEach-Object {
		if ($_.NicName -notin $cloneNICs) {
			$_.Skip = $True
		}
	}

	$keepResources += @(
		$script:resourcesALL `
		| Where-Object { ($_.type -eq 'Microsoft.Network/networkInterfaces') `
					-and ($_.name -in $cloneNICs) }
	)

	# keep public IP adresses
	$clonePublicIPs = ($script:copyNICs.Values | Where-Object NicName -in $cloneNICs).IpAddressName

	$keepResources += @(
		$script:resourcesALL `
		| Where-Object { ($_.type -eq 'Microsoft.Network/publicIPAddresses') `
					-and ($_.name -in $clonePublicIPs) }
	)

	# keep collected
	$script:resourcesALL = $keepResources
}

#--------------------------------------------------------------
function update-mergeAvailability {
#--------------------------------------------------------------
	param (
		$vm,
		$type,
		$name,
		$createdNames
	)

	if ($name.length -eq 0) {
		$vm.properties.$type = $Null

		Write-Output -NoEnumerate @()
	}
	else {
		$id = get-resourceString `
				$targetSubID		$targetRG `
				'Microsoft.Compute' `
				"$type`s"			$name

		# update VM with resource ID as string
		$vm.properties.$type = @{ id = $id }

		if ($name -in $createdNames) {
			# name will be created by the ARM/BICEP template
			Write-Output -NoEnumerate @()
		}
		else {
			# name that must already exist in the target RG
			Write-Output -NoEnumerate $name
		}
	}
}

#--------------------------------------------------------------
function update-attached4cloneOrMerge {
#--------------------------------------------------------------
	if (!$cloneOrMergeMode) {
		return
	}

	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {
		
		$vmName = $_.name

		#--------------------------------------------------------------
		# attachVmssFlex
		if ($Null -ne $_.properties.virtualMachineScaleSet) {
			write-logFileUpdates 'virtualMachines' $vmName 'remove virtualMachineScaleSet'
		}
		$_.properties.virtualMachineScaleSet = $Null
		$script:copyVMs[$vmName].vmssName = $Null

		if ($Null -ne $script:copyVMs[$vmName].attachVmssFlex) {
			$rg, $name = $script:copyVMs[$vmName].attachVmssFlex -split '/'
			$res = test-resourceInTargetRG 'attachVmssFlex' 'virtualMachineScaleSets' @($name) $targetRG -mustExist
			$vmss = $res | Where-Object Name -eq $name

			if ($vmss.OrchestrationMode -ne 'Flexible') {
				write-logFileError "Invalid parameter 'attachVmssFlex'" `
								"Orchestration Mode of VMSS '$name' is not 'Flexible'"
			}

			# save properties of existing VMSS
			$script:vmssProperties[$name] = @{
				name				= $name
				faultDomainCount	= $vmss.PlatformFaultDomainCount
				zones				= $vmss.Zones
			}
			$script:copyVMs[$vmName].vmssName = $name

			write-logFileUpdates 'virtualMachines' $vmName 'set virtualMachineScaleSet' $name
			$_.properties.virtualMachineScaleSet = @{
				id = "<resourceId('$rg','Microsoft.Compute/virtualMachineScaleSets','$name')>"
			}
		}

		#--------------------------------------------------------------
		# attachAvailabilitySet
		if ($Null -ne $_.properties.availabilitySet) {
			write-logFileUpdates 'virtualMachines' $vmName 'remove availabilitySet'
		}
		$_.properties.availabilitySet = $Null
		$script:copyVMs[$vmName].AvsetName = $Null

		if ($Null -ne $script:copyVMs[$vmName].attachAvailabilitySet) {
			$rg, $name = $script:copyVMs[$vmName].attachAvailabilitySet -split '/'
			test-resourceInTargetRG 'attachAvailabilitySet' 'availabilitySets' @($name) $targetRG -mustExist | Out-Null

			$script:copyVMs[$vmName].AvsetName = $name

			write-logFileUpdates 'virtualMachines' $vmName 'set availabilitySet' $name
			$_.properties.availabilitySet = @{
				id = "<resourceId('$rg','Microsoft.Compute/availabilitySets','$name')>"
			}
		}
		
		#--------------------------------------------------------------
		# attachProximityPlacementGroup
		if ($Null -ne $_.properties.proximityPlacementGroup) {
			write-logFileUpdates 'virtualMachines' $vmName 'remove proximityPlacementGroup'
		}
		$_.properties.proximityPlacementGroup = $Null
		$script:copyVMs[$vmName].PpgName = $Null

		if ($Null -ne $script:copyVMs[$vmName].attachProximityPlacementGroup) {
			$rg, $name = $script:copyVMs[$vmName].attachProximityPlacementGroup -split '/'
			test-resourceInTargetRG 'attachProximityPlacementGroup' 'proximityPlacementGroups' @($name) $targetRG -mustExist | Out-Null

			$script:copyVMs[$vmName].PpgName = $name

			write-logFileUpdates 'virtualMachines' $vmName 'set proximityPlacementGroup' $name
			if ($rg -ne $targetRG) {
				write-logFileWarning "Proximity Placement Group '$name' is located in resource group '$rg'"
			}
			$_.properties.proximityPlacementGroup = @{
				id = "<resourceId('$rg','Microsoft.Compute/proximityPlacementGroups','$name')>"
			}
		}
	}

	# remove all dependencies
	$script:resourcesALL
	| ForEach-Object {

		$_.dependsOn = $Null
	}
}

#--------------------------------------------------------------
function update-merge {
#--------------------------------------------------------------
	if (!$mergeMode) {
		return
	}

	write-logFileUpdates '*' '*' 'skip all' " (except merged VMs)"
	$script:resourcesALL = @(
		$script:resourcesALL `
		| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	)

	$script:mergeDiskNames = @()
	rename-disks -getMergeNames

	$script:mergeVMwithIP = @()
	foreach ($vmName in $script:mergeVMs) {
		if ($script:copyVMs[$vmName].IpNames.count -gt 0) {
			$script:mergeVMwithIP += $vmName
		}
	}

	$mergeVmNames    = @()
	$mergeNicNames   = @()
	$mergeNetSubnets = @()
	$mergeNets       = @()
	$mergeIPNames    = @()

	$script:copyVMs.values
	| Where-Object MergeNetSubnet -ne $Null
	| ForEach-Object {

		$enableAccNW = $script:vmSkus[$_.VmSize].AcceleratedNetworkingEnabled

		# resources for new VM
		$netSubnet		= $_.MergeNetSubnet
		$net, $subnet 	= $netSubnet -split '/'

		$nameOld 	= $_.Name
		$nameNew	= $nameOld
		if ($_.Rename.length -ne 0) {
			$nameNew	= $_.Rename
		}

		# NIC & IP names: 1-80 character
		# VM name: 1-64 character (already checked)
		$nicName		= "$nameNew-nic"
		$ipName			= "$nameNew-ip"

		# collect (renamed) VM and DISK names
		$mergeVmNames    += $nameNew
		$mergeNicNames   += $nicName
		$mergeNetSubnets += $netSubnet
		$mergeNets       += $net

		#--------------------------------------------------------------
		# update single VM
		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
		| Where-Object name -eq $nameOld
		| ForEach-Object {

			$_.properties.networkProfile = @{
				networkInterfaces = @(get-bicepIdStructByType 'Microsoft.Network/networkInterfaces' $nicName)
			}
		}

		#--------------------------------------------------------------
		# create NIC (on existing subnet in target RG)
		$id = get-resourceFunction `
				'Microsoft.Network' `
				'virtualNetworks'	$net `
				'subnets'			$subnet

		$nicRes = @{
			type		= 'Microsoft.Network/networkInterfaces'
			apiVersion	= '2020-11-01'
			name		= $nicName
			location	= '<regionName>'
			properties	= @{
				ipConfigurations = @( 
					@{
						name		= 'ipconfig1'
						properties	= @{
							privateIPAllocationMethod	= 'Dynamic'
							subnet						= @{ id = $id }
							primary						= $True
							privateIPAddressVersion		= 'IPv4'
						}
					}
				)
				enableAcceleratedNetworking = $enableAccNW
				enableIPForwarding			= $False
			}
		}
		
		#--------------------------------------------------------------
		# create and add publicIPAddress
		if ($nameOld -in $script:mergeVMwithIP) {

			$bicepStruct = get-bicepIdStructByType 'Microsoft.Network/publicIPAddresses' $ipName
			# update NIC
			$nicRes.properties.ipConfigurations[0].properties.publicIPAddress = $bicepStruct

			$mergeIPNames += $ipName

			$ipRes = @{
				type		= 'Microsoft.Network/publicIPAddresses'
				apiVersion	= '2020-11-01'
				name		= $ipName
				location	= '<regionName>'
				sku					= @{
					name = 'Standard'
				}
				properties	= @{
					publicIPAddressVersion		= 'IPv4'
					publicIPAllocationMethod	= 'Static'
				}
			}
			# first create IP Address
			write-logFileUpdates 'publicIPAddresses' $ipName 'create'
			add-resourcesALL $ipRes
		}

		# create updated NIC now
		write-logFileUpdates 'networkInterfaces' $nicName 'create'
		add-resourcesALL $nicRes
	}

	# make sure that merged resources DO NOT already exist
	test-resourceInTargetRG 'setVmMerge' 'virtualMachines'           $mergeVmNames   | Out-Null
	test-resourceInTargetRG 'setVmMerge' 'disks'                     $script:mergeDiskNames | Out-Null
	test-resourceInTargetRG 'setVmMerge' 'networkInterfaces'         $mergeNicNames  | Out-Null
	test-resourceInTargetRG 'setVmMerge' 'publicIPAddresses'         $mergeIPNames   | Out-Null
	# make sure that referenced resources DO already exist
	$res = test-resourceInTargetRG 'setVmMerge' 'virtualNetworks'    $mergeNets -mustExist

	# make sure that subnet already exist
	foreach ($netSubnet in $mergeNetSubnets) {
		$net, $subnet = $netSubnet -split '/'

		$currentVnet = $res | Where-Object Name -eq $net
		if ($subnet -notin $currentVnet.Subnets.Name) {
			write-logFileError "Invalid parameter 'setVmMerge'" `
								"Parameter must be in the form 'vnet/subnet@vm'" `
								"vnet/subnet '$netSubnet' does not exist in resource group '$targetRG'" 
		}
	}
}

#--------------------------------------------------------------
function test-resourceInTargetRG {
#--------------------------------------------------------------
	param (
		$testParam,
		$resType,
		$resNames,
		$rgName,
		[switch] $mustExist
	)

	if ($Null -eq $rgName) {
		$rgName = $targetRG
	}

	$param = @{
		ResourceGroupName	= $rgName
		WarningAction		= 'SilentlyContinue'
		ErrorAction 		= 'SilentlyContinue'
	}
	$resTypeName = "$resType`s"
	$paramName = $Null

	$savedSub = $script:currentSub
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	switch ($resType) {
		'virtualMachines' {
			$targetResources = @(Get-AzVM @param)
			$resFunction = 'Get-AzVM'
		}
		'disks' {
			$targetResources = @(Get-AzDisk @param)
			$resFunction = 'Get-AzDisk'
		}
		'networkInterfaces' {
			$targetResources = @(Get-AzNetworkInterface @param)
			$resFunction = 'Get-AzNetworkInterface'
		}
		'publicIPAddresses' {
			$targetResources = @(Get-AzPublicIpAddress @param)
			$resFunction = 'Get-AzPublicIpAddress'
		}
		'virtualMachineScaleSets' {
			$paramName = "and 'createVmssFlex'"
			$targetResources = @(Get-AzVmss @param)
			$resFunction = 'Get-AzVmss'
		}
		'availabilitySets' {
			$paramName = "and 'createAvailabilitySet'"
			$targetResources = @(Get-AzAvailabilitySet @param)
			$resFunction = 'Get-AzAvailabilitySet'
		}
		'proximityPlacementGroups' {
			$paramName = "and 'createProximityPlacementGroup'"
			$targetResources = @(Get-AzProximityPlacementGroup @param)
			$resFunction = 'Get-AzProximityPlacementGroup'
		}
		'virtualNetworks' {
			$targetResources = @(Get-AzVirtualNetwork @param)
			$resFunction = 'Get-AzVirtualNetwork'
		}
		Default {
			write-logFileError "Internal RGCOPY error"
		}
	}
	test-cmdlet $resFunction  "Could not get $resTypeName of resource group '$rgName'"

	set-context $savedSub # *** CHANGE SUBSCRIPTION **************

	if ($testParam -ne 'setVmMerge') {
		$paramName = $Null
	}
		
	foreach ($resName in $resNames) {
		if ($mustExist) {
			if ($resName -notin $targetResources.Name) {
				write-logFileError "Invalid parameter '$testParam' $paramName" `
									"'$resName' of type $resType does not exist in resource group '$rgName'"
				}	
		}
		else {
			if ($resName -in $targetResources.Name) {
			write-logFileError "Invalid parameter '$testParam'" `
								"'$resName' of type $resType already exists in resource group '$rgName'"
			}	
		}
	}

	return $targetResources
}

#--------------------------------------------------------------
function add-greenlist {
#--------------------------------------------------------------
	param (
		$level1,
		$level2,
		$level3,
		$level4,
		$level5,
		$level6
	)

	$script:greenlist."$level1  $level2  $level3  $level4  $level5  $level6" = $True
}

#--------------------------------------------------------------
function new-greenlist {
#--------------------------------------------------------------
# greenlist created from https://docs.microsoft.com/en-us/azure/templates in September 2020

	$script:greenlist = @{}
	$script:deniedProperties = @{}
	$script:allowedProperties = @{}

	add-greenlist 'Microsoft.Network/networkSecurityGroups' '*'
	add-greenlist 'Microsoft.Network/networkSecurityGroups/securityRules' '*'
	add-greenlist 'Microsoft.Network/bastionHosts' '*'

	# will be always removed by RGCOPY:
	# only added to green list to prevent warning
	add-greenlist 'Microsoft.Compute/disks' '*'
	add-greenlist 'Microsoft.Compute/snapshots' '*'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'osProfile' '*'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'diagnosticsProfile' '*'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'securityProfile' '*'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'diskControllerType'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'imageReference' '*'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'createOption'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'diskSizeGB'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'encryptionSettings'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'managedDisk' 'storageAccountType'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'createOption'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'diskSizeGB'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'managedDisk' 'storageAccountType'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'toBeDetached'
	add-greenlist 'Microsoft.Compute/virtualMachineScaleSets/virtualMachines' '*'

	# virtualMachines
	add-greenlist 'Microsoft.Compute/virtualMachines'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'additionalCapabilities'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'additionalCapabilities' 'ultraSSDEnabled'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'hardwareProfile'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'hardwareProfile' 'vmSize'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'osType'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'name'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'caching'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'writeAcceleratorEnabled'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'managedDisk'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'managedDisk' 'id'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'lun'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'name'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'caching'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'writeAcceleratorEnabled'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'managedDisk'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'managedDisk' 'id'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'networkProfile'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'networkProfile' 'networkInterfaces'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'networkProfile' 'networkInterfaces' 'id'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'networkProfile' 'networkInterfaces' 'properties'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'networkProfile' 'networkInterfaces' 'properties' 'primary'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'availabilitySet'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'availabilitySet' 'id'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'proximityPlacementGroup'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'proximityPlacementGroup'	'id'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'virtualMachineScaleSet'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'virtualMachineScaleSet' 'id'

	# availability
	add-greenlist 'Microsoft.Compute/virtualMachineScaleSets'
	add-greenlist 'Microsoft.Compute/virtualMachineScaleSets' 'orchestrationMode'
	add-greenlist 'Microsoft.Compute/virtualMachineScaleSets' 'platformFaultDomainCount'
	add-greenlist 'Microsoft.Compute/virtualMachineScaleSets' 'proximityPlacementGroup'
	add-greenlist 'Microsoft.Compute/virtualMachineScaleSets' 'proximityPlacementGroup' 'id'

	add-greenlist 'Microsoft.Compute/availabilitySets'
	add-greenlist 'Microsoft.Compute/availabilitySets' 'platformUpdateDomainCount'
	add-greenlist 'Microsoft.Compute/availabilitySets' 'platformFaultDomainCount'
	add-greenlist 'Microsoft.Compute/availabilitySets' 'virtualMachines'
	add-greenlist 'Microsoft.Compute/availabilitySets' 'virtualMachines' 'id'
	add-greenlist 'Microsoft.Compute/availabilitySets' 'proximityPlacementGroup'
	add-greenlist 'Microsoft.Compute/availabilitySets' 'proximityPlacementGroup' 'id'
	
	add-greenlist 'Microsoft.Compute/proximityPlacementGroups'
	add-greenlist 'Microsoft.Compute/proximityPlacementGroups' 'proximityPlacementGroupType'

	# virtualNetworks
	add-greenlist 'Microsoft.Network/virtualNetworks'
	add-greenlist 'Microsoft.Network/virtualNetworks' 'addressSpace'
	add-greenlist 'Microsoft.Network/virtualNetworks' 'addressSpace' 'addressPrefixes'
	# add-greenlist 'Microsoft.Network/virtualNetworks' 'dhcpOptions' '*'
	add-greenlist 'Microsoft.Network/virtualNetworks' 'subnets' '*'
	# add-greenlist 'Microsoft.Network/virtualNetworks' 'ipAllocations'

	# subnets
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'addressPrefix'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'addressPrefixes'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'delegations'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'delegations' 'name'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'delegations' 'properties'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'delegations' 'properties' 'serviceName' #e.g. "Microsoft.NetApp/volumes"
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'delegations' 'type'
	# add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'ipAllocations'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'natGateway'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'natGateway' 'id'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'networkSecurityGroup'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'networkSecurityGroup' 'id'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'routeTable' '*'

	# networkInterfaces
	add-greenlist 'Microsoft.Network/networkInterfaces'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'dnsSettings'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'dnsSettings' 'internalDnsNameLabel'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'dnsSettings' 'dnsServers'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'enableAcceleratedNetworking'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'enableIPForwarding'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'name'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'loadBalancerBackendAddressPools'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'loadBalancerBackendAddressPools' 'id'
	# add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'loadBalancerInboundNatRules'
	# add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'loadBalancerInboundNatRules' 'id'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'primary'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'privateIPAddress'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'privateIPAddressVersion'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'privateIPAllocationMethod'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'publicIPAddress'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'publicIPAddress' 'id'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'subnet'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'subnet' 'id'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'networkSecurityGroup'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'networkSecurityGroup' 'id'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'nicType'

	# publicIPAddresses
	add-greenlist 'Microsoft.Network/publicIPAddresses'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'dnsSettings'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'dnsSettings' 'domainNameLabel'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'dnsSettings' 'fqdn'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'dnsSettings' 'reverseFqdn'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'idleTimeoutInMinutes'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'ipAddress'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'ipTags'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'ipTags' 'ipTagType'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'ipTags' 'tag'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'natGateway'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'natGateway' 'id'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'publicIPAddressVersion'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'publicIPAllocationMethod'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'publicIPPrefix'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'publicIPPrefix' 'id'

	# natGateways
	add-greenlist 'Microsoft.Network/natGateways'
	add-greenlist 'Microsoft.Network/natGateways' 'idleTimeoutInMinutes'
	add-greenlist 'Microsoft.Network/natGateways' 'publicIpAddresses'
	add-greenlist 'Microsoft.Network/natGateways' 'publicIpAddresses' 'id'
	add-greenlist 'Microsoft.Network/natGateways' 'publicIpPrefixes'
	add-greenlist 'Microsoft.Network/natGateways' 'publicIpPrefixes' 'id'

	# publicIPPrefixes
	add-greenlist 'Microsoft.Network/publicIPPrefixes' '*'

	# loadBalancers TBD
	add-greenlist 'Microsoft.Network/loadBalancers'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'id'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'privateIPAddress'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'privateIPAllocationMethod'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'privateIPAddressVersion'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'subnet'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'subnet' 'id'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'publicIPAddress'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'publicIPAddress' 'id'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'publicIPPrefix'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'publicIPPrefix' 'id'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'name'
	# add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'zones'
	add-greenlist 'Microsoft.Network/loadBalancers' 'backendAddressPools'
	add-greenlist 'Microsoft.Network/loadBalancers' 'backendAddressPools' 'id'
	add-greenlist 'Microsoft.Network/loadBalancers' 'backendAddressPools' 'name'
	add-greenlist 'Microsoft.Network/loadBalancers' 'backendAddressPools' 'properties'
	add-greenlist 'Microsoft.Network/loadBalancers' 'backendAddressPools' 'properties' 'loadBalancerBackendAddresses'
	add-greenlist 'Microsoft.Network/loadBalancers' 'backendAddressPools' 'properties' 'loadBalancerBackendAddresses' 'name'
	add-greenlist 'Microsoft.Network/loadBalancers' 'backendAddressPools' 'properties' 'loadBalancerBackendAddresses' 'properties' '*'
	add-greenlist 'Microsoft.Network/loadBalancers' 'loadBalancingRules'
	add-greenlist 'Microsoft.Network/loadBalancers' 'loadBalancingRules' 'id'
	add-greenlist 'Microsoft.Network/loadBalancers' 'loadBalancingRules' 'name'
	add-greenlist 'Microsoft.Network/loadBalancers' 'loadBalancingRules' 'properties' '*'
	add-greenlist 'Microsoft.Network/loadBalancers' 'probes'
	add-greenlist 'Microsoft.Network/loadBalancers' 'probes' 'id'
	add-greenlist 'Microsoft.Network/loadBalancers' 'probes' 'name'
	add-greenlist 'Microsoft.Network/loadBalancers' 'probes' 'properties' '*'
	# add-greenlist 'Microsoft.Network/loadBalancers' 'inboundNatRules'
	# add-greenlist 'Microsoft.Network/loadBalancers' 'inboundNatPools'
	add-greenlist 'Microsoft.Network/loadBalancers' 'outboundRules'
	add-greenlist 'Microsoft.Network/loadBalancers' 'outboundRules' 'id'
	add-greenlist 'Microsoft.Network/loadBalancers' 'outboundRules' 'name'
	add-greenlist 'Microsoft.Network/loadBalancers' 'outboundRules' 'properties' '*'
	# add-greenlist 'Microsoft.Network/loadBalancers/inboundNatRules'

	# backendAddressPools TBD
	add-greenlist 'Microsoft.Network/loadBalancers/backendAddressPools'
	add-greenlist 'Microsoft.Network/loadBalancers/backendAddressPools' 'loadBalancerBackendAddresses'
	add-greenlist 'Microsoft.Network/loadBalancers/backendAddressPools' 'loadBalancerBackendAddresses' 'name'
	add-greenlist 'Microsoft.Network/loadBalancers/backendAddressPools' 'loadBalancerBackendAddresses' 'properties'
	add-greenlist 'Microsoft.Network/loadBalancers/backendAddressPools' 'loadBalancerBackendAddresses' 'properties' 'ipAddress'
	add-greenlist 'Microsoft.Network/loadBalancers/backendAddressPools' 'loadBalancerBackendAddresses' 'properties' 'virtualNetwork'
	add-greenlist 'Microsoft.Network/loadBalancers/backendAddressPools' 'loadBalancerBackendAddresses' 'properties' 'virtualNetwork' 'id'
}

#--------------------------------------------------------------
function test-greenlistSingle {
#--------------------------------------------------------------
	param (
		[array] $level
	)

	$level1 = $level[0]
	$level2 = $level[1]
	$level3 = $level[2]
	$level4 = $level[3]
	$level5 = $level[4]
	$level6 = $level[5]

	if ($level.count -eq 1) {
		if (($script:greenlist.ContainsKey("$level1  $level2  $level3  $level4  $level5  $level6")) -or `
			($script:greenlist.ContainsKey("$level1  *        "))  ) {

			# property found in greenlist
			$script:allowedProperties."$level1" = $True
			return $True
		}
		else {
			#property not found in greenlist
			$script:deniedProperties."$level1  $level2  $level3  $level4  $level5  $level6" = $True
			return $False
		}

	}
	else {

		if (($script:greenlist.ContainsKey("$level1  $level2  $level3  $level4  $level5  $level6")) -or `
			($script:greenlist.ContainsKey("$level1  $level2  $level3  $level4  $level5  *")) -or `
			($script:greenlist.ContainsKey("$level1  $level2  $level3  $level4  *  ")) -or `
			($script:greenlist.ContainsKey("$level1  $level2  $level3  *    ")) -or `
			($script:greenlist.ContainsKey("$level1  $level2  *      ")) -or `
			($script:greenlist.ContainsKey("$level1  *        "))  ) {

			# property found in greenlist
			return $True
		}
		else {
			#property not found in greenlist
			$script:deniedProperties."$level1  $level2  $level3  $level4  $level5  $level6" = $True
			return $False
		}
	}
}

#--------------------------------------------------------------
function test-greenlistAll {
#--------------------------------------------------------------
	param (
		[ref] $reference,
		[string] $objectKey,
		[array] $level
	)

	if ($level.count -gt 20) {
		# This cannot happen without changing RGCOPY source code
		write-logFileError "recursive overflow: $level"
	}

# objectKey provided
	if ($objectKey.length -ne 0) {

		# unvalid object
		if (!(test-greenlistSingle -level $level)) {
			$reference.Value.Remove($objectKey)
			return
		}

		# process arrays
		if ($reference.Value.$objectKey -is [array]) {

			# process array elements
			for ($i = $reference.Value.$objectKey.count - 1; $i -ge 0 ; $i--) {
				test-greenlistAll `
					-reference ([ref]($reference.Value.$objectKey[$i])) `
					-level $level
			}

			# remove invalid members from array
			$reference.Value.$objectKey = convertTo-array ($reference.Value.$objectKey | Where-Object {$_.count -ne 0})

		# process objects
		} elseif ($reference.Value.$objectKey -is [hashtable]) {

			$keys = $reference.Value.$objectKey.GetEnumerator().Name
			foreach($key in $keys) {
				$levelNew = [array] $level + $key
				test-greenlistAll `
					-reference ([ref]($reference.Value.$objectKey)) `
					-objectKey $key `
					-level $levelNew
			}
		}
	}

# objectKey NOT provided (called from array)
	else {
		# array member is object
		if ($reference.Value -is [hashtable]) {

			$keys = $reference.Value.GetEnumerator().Name
			foreach($key in $keys) {
				$levelNew = [array] $level + $key
				test-greenlistAll `
					-reference $reference `
					-objectKey $key `
					-level $levelNew
			}

		# array member is array
		} elseif ($reference.Value -is [array]) {

			for ($i = $reference.Value.count - 1; $i -ge 0 ; $i--) {
				test-greenlistAll `
					-reference ([ref]($reference.Value[$i])) `
					-level $level
			}

			# remove invalid members from array
			$reference.Value = convertTo-array ($reference.Value | Where-Object {$_.count -ne 0})

		# array member is string
		} else {
			# nothing to do
		}
	}
}

#--------------------------------------------------------------
function compare-greenlist {
#--------------------------------------------------------------
	if ($skipGreenlist) {
		return
	}

	new-greenlist

	# clean all resources
	$script:resourcesALL
	| ForEach-Object {

		# clean all properties
		test-greenlistAll `
			-reference ([ref]($_)) `
			-objectKey 'properties' `
			-level ($_.type)

		# if ($_.ContainsKey('resources')) {
			# $_.Delete('resources')
		# }
	}

	# remove deleted resources
	$script:resourcesALL = convertTo-array ($script:resourcesALL | Where-Object { (test-greenlistSingle -level $_.type) })

	# output of removed properties
	if (!$hostPlainText) {
		[console]::ForegroundColor = 'DarkGray'
	}
	$script:deniedProperties.GetEnumerator()
	| Sort-Object Key
	| Select-Object `
		@{label="Excluded resource properties (ignored by RGCOPY)"; expression={$_.Key}}
	| Format-Table
	| write-LogFilePipe

	# outout of kept properties
	$script:allowedProperties.GetEnumerator()
	| Sort-Object Key
	| Select-Object `
		@{label="Included resources (processed by RGCOPY)"; expression={$_.Key}}
	| Format-Table
	| write-LogFilePipe

	# restore colors
	if (!$hostPlainText) {
		[console]::ForegroundColor = 'Gray'
	}
}

#--------------------------------------------------------------
function remove-rgcopySpaces {
#--------------------------------------------------------------
	param (
		$key,
		$value
	)

	# convert to string
	$string = $value -as [string]

	# remove spaces
	# for path parameters (never an array), we must not remove spaces
	# for arrays, we must remove spaces in each element (space is the separator between elements)
	if ($key -notlike '*path*') {
		$string = $string -replace '\s+', ''
	}

	# remove apostrophs (apostroph is used as boundary of arrays)
	return ($string -replace "'", '')
}

#--------------------------------------------------------------
function set-rgcopyParam {
#--------------------------------------------------------------
	# rgcopyParamOrig: Original RGCOPY parameters ($PSBoundParameters) with [int], [string] and [array]
	# rgcopyParamFlat: Flat RGCOPY parameters with [string] (arrays coverted to [string])
	# rgcopyParamQuoted: set single quotes around rgcopyParamFlat

	# add optional RGCOPY parameters (calculated values)
	$script:rgcopyParamOrig.sourceSub		= $sourceSub
	$script:rgcopyParamOrig.sourceSubUser	= $sourceSubUser
	$script:rgcopyParamOrig.sourceSubTenant	= $sourceSubTenant
	$script:rgcopyParamOrig.targetSub		= $targetSub
	$script:rgcopyParamOrig.targetSubUser	= $targetSubUser
	$script:rgcopyParamOrig.targetSubTenant	= $targetSubTenant
	$script:rgcopyParamOrig.sourceLocation	= $sourceLocation
	$script:rgcopyParamOrig.targetSA		= $targetSA
	$script:rgcopyParamOrig.sourceSA		= $sourceSA

	# add VMsizes (stored in template variables)
	if ($script:templateVariables.count -ne 0) {
		$script:templateVariables.keys
		| ForEach-Object{
			$script:rgcopyParamOrig[$_] = $script:templateVariables[$_]
		}
	}

	# add deploy Parameters
	get-deployParameters -check $False
	if ($null -ne $script:deployParameters) {
		$script:deployParameters.keys
		| ForEach-Object{
			$script:rgcopyParamOrig[$_] = $script:deployParameters[$_]
		}
	}

	# add parameters for single TiP session
	if ($Null -ne $script:lastTipSessionID) {
		$script:rgcopyParamOrig.tipSessionID   = $script:lastTipSessionID
		$script:rgcopyParamOrig.tipClusterName = $script:lastTipClusterName
	}

	# local machine
	$script:rgcopyParamOrig.vmName = [Environment]::MachineName
	$script:rgcopyParamOrig.vmType = $Null

	# add all parameter names
	$names = @('rgcopyParameters')
	$names += convertTo-array ($script:rgcopyParamOrig.keys | Where-Object {$_ -ne 'rgcopyParameters'})
	$script:rgcopyParamOrig.rgcopyParameters = ($names | Sort-Object)

	# set rgcopyParamFlat and rgcopyParamQuoted
	$script:rgcopyParamFlat = @{}
	$script:rgcopyParamQuoted = @{}
	$script:rgcopyParamOrig.keys
	| ForEach-Object{
		if ($script:rgcopyParamOrig[$_] -is [SecureString]) {
			$script:rgcopyParamFlat[$_]   =  '*****'
			$script:rgcopyParamQuoted[$_] = "'*****'"
		}
		elseif ($script:rgcopyParamOrig[$_] -is [array]) {
			$array_new = @()
			foreach ($item in $script:rgcopyParamOrig[$_]) {
				$array_new += (remove-rgcopySpaces  $_  $item)
			}
			$string = $array_new -as [string]
			$script:rgcopyParamFlat[$_]   =   $string
			$script:rgcopyParamQuoted[$_] = "'$String'"
		}
		else {
			$string = (remove-rgcopySpaces  $_  $script:rgcopyParamOrig[$_])
			$script:rgcopyParamFlat[$_]   =   $string
			$script:rgcopyParamQuoted[$_] = "'$String'"
		}
	}
}

#--------------------------------------------------------------
function invoke-localScript {
#--------------------------------------------------------------
	# script running locally for modifying sourceRG
	param (
		$pathScript,
		$variableScript
	)

	write-stepStart "Run local PowerShell script from RGCOPY parameter '$variableScript'"

	if ($(Test-Path -Path $pathScript) -ne $True) {
		write-logFileWarning  "File not found. Script '$pathScript' not executed"
		write-stepEnd
		return
	}

	set-rgcopyParam
	if ($verboseLog) { write-logFileHashTable $script:rgcopyParamOrig }

	# convert named parameters to position parameters
	[array] $keys   = $script:rgcopyParamOrig.keys
	[array] $values = $script:rgcopyParamOrig.values
	$string = "param (`n"
	$sep = ' '
	for ($i = 0; $i -lt $keys.Count; $i++) {
		$string += "$sep[Parameter(Position=$i)] `$$($keys[$i]) `n"
		$sep = ','
	}
	$string += ")`n"

	# add parameters to file
	$string += Get-Content $pathScript -delimiter [char]0

	# convert string to script block
	$script = [scriptblock]::create($string)

	write-logFile "Script Path:         " -ForegroundColor DarkGray -NoNewLine
	write-logFile $pathScript 
	write-logFile "Script Parameters:   $($script:rgcopyParamFlat.rgcopyParameters)" -ForegroundColor DarkGray
	write-logFile

	# invoke script with position parameters
	Invoke-Command -Script $script -ErrorAction 'SilentlyContinue' -ArgumentList $values
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	test-cmdlet 'Invoke-Command'  "Local PowerShell script '$pathScript' failed"

	write-stepEnd
}

#--------------------------------------------------------------
function wait-vmAgent {
#--------------------------------------------------------------
	param (
		$resourceGroup,
		$scriptServer,
		$pathScript
	)

	for ($i = 1; $i -le $vmAgentWaitMinutes; $i++) {

		# get current vmAgent Status
		$vm = Get-AzVM `
				-ResourceGroupName	$resourceGroup `
				-Name				$scriptServer `
				-status `
				-WarningAction	'SilentlyContinue' `
				-ErrorAction 'SilentlyContinue'

		$status  = $vm.VMAgent.Statuses.DisplayStatus
		$version = $vm.VMAgent.VmAgentVersion

		# status unknown
		if ($Null -eq $status) {
			test-cmdlet 'Get-AzVM'  "VM '$scriptServer' not found in resource group '$resourceGroup'"  -always
		}
		# status ready
		elseif ($status -eq 'Ready') {
			write-logFile -ForegroundColor DarkGray "VM Agent status:     $status"
			write-logFile -ForegroundColor DarkGray "VM Agent version:    $version"

			# check minimum version 2.2.10
			if (!$skipVmChecks) {
				$v = $version -split '\.'
				if ($v.count -ge 3) {
					if ( (($v[0] -as [int]) -lt 2) `
					-or ((($v[0] -as [int]) -eq 2) -and (($v[1] -as [int]) -lt 2)) `
					-or ((($v[0] -as [int]) -eq 2) -and (($v[1] -as [int]) -eq 2) -and (($v[2] -as [int]) -lt 10))) {

						# https://docs.microsoft.com/en-us/troubleshoot/azure/virtual-machines/support-extensions-agent-version
						write-logFileError "VM Agent version check failed: version $version is too old" `
											"You can skip this check using RGCOPY parameter switch 'skipVmChecks'" `
											"Update VM Agent of VM '$scriptServer' to the latest version"
					}
				}
			}
			return
		}
		# status not ready yet
		else {
			write-logFile -ForegroundColor DarkGray "VM Agent Status:     $status ->waiting 1 minute..."
			Start-Sleep -Seconds 60
		}
	}

	# status not ready after 30 minutes ($vmAgentWaitMinutes)
	write-logFileError "VM Agent of VM '$scriptServer' is not ready" `
						"Script cannot be executed: '$pathScript'"
}

#--------------------------------------------------------------
function invoke-vmScript {
#--------------------------------------------------------------
# execute script (either path to file on VM or OS command)
	param (
		$parameterValue,
		$parameterName,
		$resourceGroup
	)

	write-stepStart "Run VM scripts from RGCOPY parameter '$parameterName'"

	if ($parameterValue.length -eq 0) {
		write-logFileWarning "RGCOPY parameter '$parameterName' not set. Script not started."
		write-stepEnd
		return
	}

	$isLocal = $False
	$scriptPath, $vmList = $parameterValue -split '@'

	# script contains an '@'
	if ($vmList.count -gt 1) {
		for ($i = 0; $i -lt ($vmList.Count -1); $i++) {
			$scriptPath += "@$($vmList[$i])"
		}
		$vmList = $vmList[-1]
	}
	
	# remove spaces at start and end of script path (path might contain spaces)
	$scriptPath = $scriptPath -replace '^\s+', ''  -replace '\s+$', ''
	# remove all spaces from VM list
	$vmList = $vmList -replace '\s+', ''

	# remove 'local:'
	if ($scriptPath -like 'local:*') {
		$scriptPath = $scriptPath.Substring(6,$scriptPath.length -6)
		$scriptPath = $scriptPath -replace '^\s+', '' 
		$isLocal = $True
	}

	if ($scriptPath.length -eq 0) {
		write-logFileError "Invalid parameter '$parameterName'" `
							"The syntax is: [local:]<path>@<VM>[,...n]" `
							"path is not provided"
	}

	# get script VMs
	$scriptVMs = @()
	$vmArray = $vmList -split ','
	foreach ($vm in $vmArray) {		
		if ($vm.length -ne 0) {
			$scriptVMs += $vm
		}
	}
	if ($scriptVMs.count -eq 0) {
		write-logFileError "Invalid parameter '$parameterName'" `
							"The syntax is: [local:]<path>@<VM>[,...n]" `
							"VM is not provided"
	}

	# check if VMs exists
	if ($resourceGroup -eq $sourceRG) {
		$currentVMs = $script:sourceVMs
	}
	else {
		$currentVMs = $script:targetVMs
	}
	foreach ($vm in $scriptVMs) {
		if ($vm -notin $currentVMs.Name) {
			write-logFileError "Invalid parameter '$parameterName'" `
								"The syntax is: [local:]<path>@<VM>[,...n]" `
								"VM '$vm' does not exist"
		}
	}

	# check if local file exists
	if ($isLocal -and ($(Test-Path -Path $scriptPath) -ne $True)) {
			write-logFileError "Invalid parameter '$parameterName'" `
								"The syntax is: [local:]<path>@<VM>[,...n]" `
								"Local script not found: '$scriptPath'"
	}

	#--------------------------------------------------------------
	# running the scripts
	foreach ($vm in $scriptVMs) {
		
		# script parameters
		set-rgcopyParam
		$script:rgcopyParamOrig.vmName   = $vm
		$script:rgcopyParamFlat.vmName   = $vm
		$script:rgcopyParamQuoted.vmName = "'$vm'"

		$vmType = $Null
		$script:rgcopyTags
		| Where-Object {($_.vmName -eq $vm) -and ($_.tagName -eq $azTagVmType)}
		| ForEach-Object {
			$vmType  = $_.value
		}

		if ($Null -ne $vmType) {
			$script:rgcopyParamOrig.vmType   = $vmType
			$script:rgcopyParamFlat.vmType   = $vmType
			$script:rgcopyParamQuoted.vmType = "'$vmType'"
		}

		# Windows or Linux?
		$osType = ($currentVMs | Where-Object Name -eq $vm).StorageProfile.OsDisk.OsType
		if ($osType -eq 'Linux') {
			$CommandId   = 'RunShellScript'
			$scriptParam = $script:rgcopyParamQuoted
			$displayDirectory = 'echo -n "RGCOPY info: current directory: " 1>&2; pwd 1>&2; echo 1>&2;'
		}
		else {
			$CommandId   = 'RunPowerShellScript'
			$scriptParam = $script:rgcopyParamFlat
			$displayDirectory = 'write-output "RGCOPY info: current directory: $(get-location)"; write-output; ""'
		}
		Write-Output $displayDirectory >$tempPathText

		# local or remote location of script?
		if ($isLocal) {
			Get-Content $scriptPath >>$tempPathText 
		}
		else {
			Write-Output $scriptPath >>$tempPathText
		}

		# script parameters
		$parameter = @{
			ResourceGroupName 	= $resourceGroup
			VMName				= $vm
			CommandId			= $CommandId
			ScriptPath 			= $tempPathText
			Parameter			= $scriptParam
			ErrorAction			= 'SilentlyContinue'
		}
		
		# wait for all services inside VMs to be started
		if (!$script:vmStartWaitDone) {
	
			# Only wait once (for each resource group). Do not wait a second time when running the second script.
			$script:vmStartWaitDone = $True
	
			write-logFile "Waiting $vmStartWaitSec seconds for starting all services inside VMs ..."
			write-logFile "(delay can be configured using RGCOPY parameter 'vmStartWaitSec')"
			write-logFile
			Start-Sleep -seconds $vmStartWaitSec
		}

		# output of parameters
		write-logFile -ForegroundColor DarkGray "Resource Group:      $resourceGroup"
		write-logFile -ForegroundColor DarkGray "Virtual Machine:     " -NoNewLine
		write-logFile "$vm ($osType)"
		# check VM agent status and version
		wait-vmAgent $resourceGroup $vm $scriptPath
		if ($isLocal) {
			write-logFile -ForegroundColor DarkGray "Script Path (local): " -NoNewLine
		}
		else {
			write-logFile -ForegroundColor DarkGray "Script Path:         " -NoNewLine
		}
		write-logFile $scriptPath
		write-logFile -ForegroundColor DarkGray "Script Parameters:   $($script:rgcopyParamFlat.rgcopyParameters)"
		write-logFile
		if ($verboseLog) {
			write-logFileHashTable $scriptParam
		}

		# execute script
		Invoke-AzVMRunCommand @parameter
		| Tee-Object -Variable result
		| Out-Null
	
		# check results
		if ($result.Status -ne 'Succeeded') {
			test-cmdlet 'Invoke-AzVMRunCommand'  "Executing script in VM '$vm' failed" `
							"Script path: '$scriptPath'" -always
		}
		else {
			write-logFile $result.Value[0].Message
			if ($result.Value[0].Message -like '*++ exit 1*') {
				write-logFileError "Script in VM '$vm' returned exit code 1" `
									"Script path: '$scriptPath'"
			}
		}
		write-logFile
	}
	Remove-Item -Path $tempPathText
	write-stepEnd
}

#--------------------------------------------------------------
function remove-hashProperties {
#--------------------------------------------------------------
	param (
		$hashTable,
		$supportedKeys
	)

	$removedKeys = @()
	foreach ($key in $hashTable.keys) {
		if ($key -notin $supportedKeys) {
			$removedKeys += $key
		}
	}

	foreach ($key in $removedKeys) {
		$hashTable.Remove($key)
	}
}

#--------------------------------------------------------------
function update-zones {
#--------------------------------------------------------------
	# remove zones
	$script:resourcesALL
	| ForEach-Object {

		$type = ($_.type -split '/')[1]
		if ( ($Null -ne $_.zones) `
		-and ($_.type -ne 'Microsoft.Compute/virtualMachines') `
		-and ($_.type -notlike 'Microsoft.Compute/virtualMachineScaleSets*' )) {

			write-logFileUpdates $type $_.name 'delete Zones'
			$_.zones = $Null
		}
	}
}

#--------------------------------------------------------------
function update-tags {
#--------------------------------------------------------------
	# remove tags
	$script:resourcesALL
	| ForEach-Object {

		$type = ($_.type -split '/')[1]
		$tagsOld = $_.tags
		$tagsNew = @{}

		# do not change tags of networkSecurityGroups
		if (($tagsOld.count -ne 0) -and ($type -ne 'networkSecurityGroups')) {
			foreach ($key in $tagsOld.keys) {

				# keep specific tags
				foreach ($tagNamePattern in $keepTags) {
					# always remove tags $azTagSmbLike ('rgcopy.MountPoint*')
					if (($key -like $tagNamePattern) -and ($key -notlike $azTagSmbLike)) {
						$tagsNew[$key] = $tagsOld[$key]
					}
				}

				# remove all other tags
				if ($Null -eq $tagsNew[$key]) {
					write-logFileUpdates $type $_.name 'delete Tag' $key
				}
			}
			$_.tags = $tagsNew
		}
	}

}

#--------------------------------------------------------------
function update-remoteSubnets {
#--------------------------------------------------------------
	# only for ARM
	param (
		$resourceGroup
	)

	$script:remoteResources
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks/subnets'
	| ForEach-Object {
		
		# remove unsupported properties
		remove-hashProperties $_.properties @(
			'addressPrefix', 
			'addressPrefixes'
		)

		$vnet, $subnet = $_.name -split '/'
		# new VNET name
		$resKey = "virtualNetworks/$resourceGroup/$vnet"
		$vnetNew = $script:remoteNames[$resKey].newName
		$_.name = "$vnetNew/$subnet"

		# new dependency
		[array] $_.dependsOn = get-resourceFunction `
								'Microsoft.Network' `
								'virtualNetworks'	$vnetNew
	}
}

#--------------------------------------------------------------
function update-remoteVNETs {
#--------------------------------------------------------------
	# only for ARM
	param (
		$resourceGroup
	)

	$remainingSubnetNames = @()

	$script:remoteResources
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks'
	| ForEach-Object {

		$vnetName = $_.name

		# remove unsupported properties
		remove-hashProperties $_.properties @(
			'addressSpace',
			'dhcpOptions',
			'subnets'
		)

		foreach ($subnet in $_.properties.subnets) {
			remove-hashProperties $subnet @(
				'name',
				'properties'
			)

			foreach ($property in $subnet.properties) {
				remove-hashProperties $property @(
					'addressPrefix',
					'addressPrefixes'
				)
			}
		}

		# remove unsued subnet properties
		$remainingSubnets = @()
		foreach ($subnet in $_.properties.subnets) {
			$subnetName = $subnet.name
			if ($Null -ne $script:collectedSubnets["$resourceGroup/$vnetName/$subnetName"]) {
				$remainingSubnets += $subnet
				$remainingSubnetNames += "$vnetName/$subnetName"
			}
		}
		$_.properties.subnets = $remainingSubnets

		# replace resource name
		$resKey = "virtualNetworks/$resourceGroup/$($_.name)"
		$_.name = $script:remoteNames[$resKey].newName
	}

	# remove unsued subnet resources
	$script:remoteResources = convertTo-array ($script:remoteResources | Where-Object `
		{($_.type -ne 'Microsoft.Network/virtualNetworks/subnets' ) -or ($_.name -in $remainingSubnetNames)})

	update-remoteSubnets $resourceGroup
}

#--------------------------------------------------------------
function update-remoteNICs {
#--------------------------------------------------------------
	# only for ARM
	param (
		$resourceGroup
	)

	$script:remoteResources
	| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
	| ForEach-Object {
		
		# remove unsupported properties
		remove-hashProperties $_.properties @(
			'dnsSettings', 
			'enableAcceleratedNetworking', 
			'ipConfigurations'
		)

		foreach ($config in $_.properties.ipConfigurations) {
			remove-hashProperties $config  @(
				'name', 
				'properties'
			)

			foreach ($property in $config.properties) {
				remove-hashProperties $property @(
					'subnet',
					'primary',
					'privateIPAddress',
					'privateIPAddressVersion',
					'privateIPAllocationMethod'
				)
			}
		}

		# new NIC name
		$nicName = $_.name
		$resKey = "networkInterfaces/$resourceGroup/$nicName"
		$_.name = $script:remoteNames[$resKey].newName
		$dependsOn = @()

		# new VNET name
		foreach ($conf in $_.properties.ipConfigurations) {

			# RGCOPY does not support a NIC in a remote resource group that is attached to a VNET in a different remote resource group
			if ($conf.properties.subnet.id -like '/*') {
				write-logFileError "Remote NIC '$nicName' in resource group '$resourceGroup' not allowed" `
									"A remote NIC must be attached to a VNET in the same resource group"
			}

			# get vnet and subnet
			$r = get-resourceComponents $conf.properties.subnet.id 
			$vnet	= $r.mainResourceName
			$subnet = $r.subResourceName

			$resKey = "virtualNetworks/$resourceGroup/$vnet"
			$vnetNew = $script:remoteNames[$resKey].newName

			$subnetID = get-resourceFunction `
							'Microsoft.Network' `
							'virtualNetworks'	$vnetNew `
							'subnets'			$subnet

			$conf.properties.subnet.id = $subnetID
			$dependsOn += $subnetID
		}

		$_.dependsOn = $dependsOn
	}
}

#--------------------------------------------------------------
function update-remoteSourceIP {
#--------------------------------------------------------------
	# only for ARM
	param (
		$resourceType,
		$configName
	)

	# networkInterfaces / loadBalancers / bastionHosts
	$script:resourcesALL
	| Where-Object type -eq $resourceType
	| ForEach-Object {

		foreach ($config in $_.properties.$configName) {
			if ($config.properties.subnet.id -like '/*') {

				# convert resource ID to to resource function
				$r = get-resourceComponents $config.properties.subnet.id

				# convert name
				$resKey = "virtualNetworks/$($r.resourceGroup)/$($r.mainResourceName)"
				$vnetName = $script:remoteNames[$resKey].newName
				$resFunction = get-resourceFunction `
								'Microsoft.Network' `
								'virtualNetworks'	$vnetName `
								'subnets'			$r.subResourceName

				# set ID and dependency
				$config.properties.subnet.id = $resFunction
				[array] $_.dependsOn += $resFunction

			}
		}
	}
}

#--------------------------------------------------------------
function update-remoteSourceRG {
#--------------------------------------------------------------
	# only for ARM
	if ($script:remoteRGs.count -eq 0) {
		return
	}

	# virtualMachines
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		foreach ($nic in $_.properties.networkProfile.networkInterfaces) {
			if ($nic.id -like '/*') {

				# convert resource ID to to resource function
				$r = get-resourceComponents $nic.id

				# convert name
				$resKey = "networkInterfaces/$($r.resourceGroup)/$($r.mainResourceName)"
				$nicName = $script:remoteNames[$resKey].newName
				$resFunction = get-resourceFunction `
								'Microsoft.Network' `
								'networkInterfaces'	$nicName

				# set ID and dependency
				$nic.id = $resFunction
				[array] $_.dependsOn += $resFunction
			}
		}
	}

	update-remoteSourceIP 'Microsoft.Network/networkInterfaces' 'ipConfigurations'
	update-remoteSourceIP 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations'
	update-remoteSourceIP 'Microsoft.Network/bastionHosts' 'ipConfigurations'
}

#--------------------------------------------------------------
function test-remoteID {
#--------------------------------------------------------------
	param (
		$type,
		$name,
		$subresource
	)

	if ($subresource.id -notlike '/*') {
		return $subresource
	}

	$r = get-resourceComponents $subresource.id
	$x,$typeName = $type -split '/'

	write-logFileWarning "Could not copy remote resource '$($r.mainResourceName)' of type '$($r.mainResourceType)'" `
						"The resource is in resource group '$($r.resourceGroup)'" `
						"It is referenced by resource '$name' of type '$typeName'" `
						"You can remove this reference using RGCOPY parameter switch 'skipRemoteReferences'" `
						-stopCondition $(!($skipRemoteReferences -as [boolean]))

	return $Null
}

#--------------------------------------------------------------
function remove-remoteIDs {
#--------------------------------------------------------------
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$_.properties.proximityPlacementGroup = test-remoteID $_.type $_.name $_.properties.proximityPlacementGroup
		$_.properties.virtualMachineScaleSet  = test-remoteID $_.type $_.name $_.properties.virtualMachineScaleSet
	}

	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/availabilitySets'
	| ForEach-Object {

		$_.properties.proximityPlacementGroup = test-remoteID $_.type $_.name $_.properties.proximityPlacementGroup
	}

	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachineScaleSets'
	| ForEach-Object {

		$_.properties.proximityPlacementGroup = test-remoteID $_.type $_.name $_.properties.proximityPlacementGroup
	}

	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks/subnets'
	| ForEach-Object {

		$_.properties.networkSecurityGroup = test-remoteID $_.type $_.name $_.properties.networkSecurityGroup
		$_.properties.natGateway           = test-remoteID $_.type $_.name $_.properties.natGateway
	}

	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
	| ForEach-Object {

		$_.properties.networkSecurityGroup = test-remoteID $_.type $_.name $_.properties.networkSecurityGroup

		foreach ($member in $_.properties.ipConfigurations) {
			$member.properties.publicIPAddress = test-remoteID $_.type $_.name $member.properties.publicIPAddress
		}
	}

	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/publicIPAddresses'
	| ForEach-Object {

		$_.properties.publicIPPrefix = test-remoteID $_.type $_.name $_.properties.publicIPPrefix
		$_.properties.natGateway     = test-remoteID $_.type $_.name $_.properties.natGateway
	}

	# TBD:
	# 'Microsoft.Network/loadBalancers'
	# 'Microsoft.Network/loadBalancers/backendAddressPools'
	# 'Microsoft.Network/natGateways'
}

#--------------------------------------------------------------
function set-templateParameters {
#--------------------------------------------------------------
	param (
		[ref] $ref
	)

	if ($useBicep) {

		# set "variables"
		$ref.value += '@metadata({'
		$ref.value += "  rgcopyVersion: '$rgcopyVersion'"
		$ref.value += "  bicepCreationDate: '$(Get-Date -Format 'yyyy-MM-dd')'"
		$keys = $script:templateVariables.keys | Sort-Object
		foreach ($key in $keys) {
			$value = $script:templateVariables.$key
			if ($key -notmatch '^[\w]*$') {
				$key = "'$key'"
			}
			$ref.value += "  $key`: '$value'"
		}
		$ref.value += '})'
		$ref.value += "param regionName string = resourceGroup().location"

		# TiP session parameters
		$bicepTipVariables = @()
		$tipGroups = $script:copyVMs.values.Group | Where-Object {$_ -gt 0} | Sort-Object -Unique
		foreach ($group in $tipGroups) {
			$ref.value += "param tipSessionID$group string = ''"
			$ref.value += "param tipClusterName$group string = ''"

			write-logFileUpdates 'template parameter' "<tipSessionID$group>" 'create'
			write-logFileUpdates 'template parameter' "<tipClusterName$group>" 'create'

			$bicepName = get-bicepNameByType 'Microsoft.Compute/availabilitySets' "rgcopy.tipGroup$group"
			$bicepTipVariables += "var tipAvSet$group = { id: $bicepName.id }"
		}

		# set variables for TiP sessions
		$ref.value += $bicepTipVariables
	}

	else {
		# set parameters
		$templateParameters = @{}
		$tipGroups = $script:copyVMs.values.Group | Where-Object {$_ -gt 0} | Sort-Object -Unique
		foreach ($group in $tipGroups) {
			$templateParameters."tipSessionID$group" = @{
				type			= 'String'
				defaultValue	= ''
			}
			$templateParameters."tipClusterName$group" = @{
				type			= 'String'
				defaultValue	= ''
			}
			write-logFileUpdates 'template parameter' "<tipSessionID$group>" 'create'
			write-logFileUpdates 'template parameter' "<tipClusterName$group>" 'create'
		}
		if ($tipGroups.count -ne 0) {
			$script:sourceTemplate.parameters = $templateParameters
		}

		# set variables
		$script:sourceTemplate.variables  = $script:templateVariables
	}
}

#--------------------------------------------------------------
function get-templateParameters {
#--------------------------------------------------------------
	if ($useBicep) {
		# save BICEP parameters and variables
		$bicepTemplate = (Get-Content -Path $DeploymentPath)
		$script:availableParameters = @()
		$script:templateVariables = @{}

		foreach ($line in $bicepTemplate) {
			if ($line -like 'resource*') {
				break
			}
			elseif ($line -like 'param*') {
				$s = $line -split ' '
				$script:availableParameters += $s[1]
			}
			elseif ($line -like '  *') {
				$s = $line -split ':'
				$key = $s[0] -replace ' ', '' -replace "'", ''
				$value = $s[1] -replace ' ', '' -replace "'", ''
				$script:templateVariables.$key = $value
			}
		}
	}

	else {
		# save ARM template parameters
		$armTemplate = (Get-Content -Path $DeploymentPath) | ConvertFrom-Json -Depth 20 -AsHashtable
		$script:availableParameters = @()
		if ($Null -ne $armTemplate.parameters) {
			[array] $script:availableParameters = $armTemplate.parameters.GetEnumerator().Name
		}

		# save ARM template variables
		$script:templateVariables = $armTemplate.variables
	}
}

#--------------------------------------------------------------
function new-templateSource {
#--------------------------------------------------------------
	$parameter = @{
		Path					= $importPath
		ResourceGroupName		= $sourceRG
		SkipAllParameterization	= $True
		force					= $True
		ErrorAction				= 'SilentlyContinue'
		WarningAction			= 'SilentlyContinue'
		WarningVariable         = 'warnings'
	}

	# read source ARM template
	Export-AzResourceGroup @parameter | Out-Null
	test-cmdlet 'Export-AzResourceGroup'  "Could not create JSON template from source RG"
	
	$script:importWarnings = convertTo-array ($warnings | Where-Object {$_ -notlike '*Some resources were not exported*'})
	write-logFile -ForegroundColor 'Cyan' "Source template saved: $importPath"
	$script:armTemplateFilePaths += $importPath
	$text = Get-Content -Path $importPath

	# convert ARM template to hash table
	$script:sourceTemplate = $text | ConvertFrom-Json -Depth 20 -AsHashtable
	$script:resourcesALL = convertTo-array $script:sourceTemplate.resources


	# get remote resource groups
	$parameter.Remove('WarningVariable')

	$script:remoteRGs = convertTo-array ( $script:remoteRGs | Sort-Object | Get-Unique )
	foreach ($rg in $script:remoteRGs) {

		# collect resource IDs
		$resIDs = @()
		$script:copyNICs.values
		| Where-Object NicRG -eq $rg
		| ForEach-Object {

			$resIDs += $_.RemoteNicId
			write-logFile "Copying NIC '$($_.NicName)' from resource group '$rg'"
		}

		$script:copyNICs.values
		| Where-Object VnetRG -eq $rg
		| ForEach-Object {

			$resIDs += $_.RemoteVnetId
			write-logFile "Copying vNet '$($_.VnetName)' from resource group '$rg'"
		}

		# remove duplicates
		$resIDs = convertTo-array ( $resIDs | Sort-Object | Get-Unique )

		# get ARM template for resource IDs
		$importPathExtern = Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$rg.SOURCE.json"
		$parameter.Path					= $importPathExtern
		$parameter.ResourceGroupName	= $rg
		$parameter.Resource				= $resIDs

		Export-AzResourceGroup @parameter | Out-Null
		test-cmdlet 'Export-AzResourceGroup'  "Could not create JSON template from resource group $rg"
		
		write-logFile -ForegroundColor 'Cyan' "Source template saved: $importPathExtern"
		$script:armTemplateFilePaths += $importPathExtern
		$text = Get-Content -Path $importPathExtern

		# convert ARM template to hash table
		$remoteTemplate = $text | ConvertFrom-Json -Depth 20 -AsHashtable
		$script:remoteResources = convertTo-array $remoteTemplate.resources

		# remove all dependencies
		$script:remoteResources
		| ForEach-Object {
			$_.dependsOn = @()
		}

		update-remoteNICs $rg
		update-remoteVNETs $rg

		# add to all resources
		$script:resourcesALL += $script:remoteResources
	}
	update-remoteSourceRG

	# remove remaining references to remote resource groups
	remove-remoteIDs
}

#--------------------------------------------------------------
function new-templateTarget {
#--------------------------------------------------------------
	# filter greenlist
	compare-greenlist

	# start output resource changes
	Write-logFile 'Resource                                  Changes by RGCOPY' -ForegroundColor 'Green'
	Write-logFile '--------                                  -----------------' -ForegroundColor 'Green'
	write-logFileUpdates '*' '*' 'set location' $targetLocation
	write-logFileUpdates 'storageAccounts' '*' 'delete'
	write-logFileUpdates 'snapshots'       '*' 'delete'
	write-logFileUpdates 'disks'           '*' 'delete'
	write-logFileUpdates 'images'          '*' 'delete'
	write-logFileUpdates 'extensions'      '*' 'delete'

	# change LOCATION
	$script:resourcesALL
	| ForEach-Object {

		if ($_.location.length -ne 0) {
			$_.location = $targetLocation
		}
	}

	if (!$patchMode) {
		# process identities
		$script:resourcesALL
		| ForEach-Object {
	
			$type = ($_.type -split '/')[1]
	
			# VM identities
			if ($type -eq 'virtualMachines') {
				if ($skipIdentities -or ($_.identity.type -notlike '*UserAssigned*')) {
					if ($_.identity.count -ne 0) {
						write-logFileUpdates $type $_.name 'delete Identities'
						$_.identity = $Null
					}
				}
	
				# user assigned identities
				else {
					write-logFileUpdates $type $_.name 'keep user assigned Identities'
					$_.identity.type = 'UserAssigned'
				}
			}
	
			# remove identities for all resources except VMs
			elseif ($_.identity.count -ne 0) {
				write-logFileUpdates $type $_.name 'delete Identities'
				$_.identity = $Null
			}
		}
	}

	remove-resources 'Microsoft.Storage/storageAccounts*'
	remove-resources 'Microsoft.Compute/snapshots'
	remove-resources 'Microsoft.Compute/disks'
	remove-resources 'Microsoft.Compute/images*'
	remove-resources 'Microsoft.Compute/virtualMachines/extensions'
	remove-resources 'Microsoft.Network/loadBalancers/backendAddressPools'

	#--- process resources
	update-paramAll
	update-resourcesAll

	# commit modifications
	set-templateParameters
	$script:sourceTemplate.resources = $script:resourcesALL
}

#--------------------------------------------------------------
function new-templateBicep {
#--------------------------------------------------------------
	$script:bicepNamesAll = @{}

	# --- start output resource changes
	Write-logFile 'Resource                                             Changes by RGCOPY' -ForegroundColor 'Green'
	Write-logFile '--------                                             -----------------' -ForegroundColor 'Green'

	#--- create internal structures
	$script:resourcesALL = @()
	add-az_virtualMachines
	add-az_virtualNetworks
	add-az_networkInterfaces
	add-az_publicIPAddresses
	add-az_networkSecurityGroups
	add-az_bastionHosts
	add-az_publicIPPrefixes
	add-az_natGateways
	add-az_proximityPlacementGroups
	add-az_availabilitySets
	add-az_virtualMachineScaleSet
	add-az_loadBalancers

	save-cloneNames
	remove-resources4cloneOrMerge

	#--- process resources
	update-paramAll
	update-resourcesAll

	#--- create bicep
	write-logFile
	$script:bicep = @()			# normal deployment (1 template)
	$script:bicepDisks = @()	# dual deployment (1st template)
	$script:bicepOther = @()	# dual deployment (2nd template)
	set-templateParameters ([ref] $script:bicepDisks)
	set-templateParameters ([ref] $script:bicepOther)
	set-templateParameters ([ref] $script:bicep)

	foreach ($res in $script:resourcesALL) {

		# other resources
		if ($res.type -ne 'Microsoft.Compute/disks') {
			$script:bicep				+= add-bicepResource $res
			# $script:bicepDisks		+= @()
			$script:bicepOther			+= add-bicepResource $res
		}

		# disk resource
		else {
			if ($script:createDisksManually) {
				$script:bicep			+= add-bicepResource $res -existing
				# $script:bicepDisks	+= @()
				# $script:bicepOther	+= @()
			}

			elseif ($script:dualDeployment) {
				# $script:bicep			+= @()
				$script:bicepDisks 		+= add-bicepResource $res
				$script:bicepOther		+= add-bicepResource $res -existing
			}

			else {
				$script:bicep 			+= add-bicepResource $res
				# $script:bicepDisks	+= @()
				# $script:bicepOther	+= @()
			}
		}
	}

	# save templates
	if ($script:dualDeployment) {
		save-bicepFile $exportPathDisks ([ref] $script:bicepDisks)
		save-bicepFile $exportPath      ([ref] $script:bicepOther)
	}
	else {
		save-bicepFile $exportPath		([ref] $script:bicep)
	}
}

#--------------------------------------------------------------
function save-bicepFile {
#--------------------------------------------------------------
	param (
		$exportPath,
		[ref] $ref
	)

	$ref.value | Out-File $exportPath -ErrorAction 'SilentlyContinue'
	if (!$?) {
		write-logFileError "Could not save BICEP file" `
								"Failed writing file '$exportPath'"
	}
	write-logFile -ForegroundColor 'Cyan' "BICEP file saved: $exportPath"
	$script:armTemplateFilePaths += $exportPath	
}


#--------------------------------------------------------------
function write-changedByDefault {
#--------------------------------------------------------------
	param (
		$parameter
	)

	if (!$script:countHeader) {
		$script:countHeader = $True
		write-logFileWarning "Resources changed by default value:"
	}

	write-LogFile $parameter
}

#--------------------------------------------------------------
function update-skipVMsNICsIPs {
#--------------------------------------------------------------
	$skipCanidates   = @()

	# output of skipped VMs
	foreach ($vm in $script:skipVMs) {
		if (!$cloneOrMergeMode) {
			write-logFileUpdates 'virtualMachines' $vm 'skip VM'
		}
	}

	if ($useBicep) {
		$script:copyVMs.Values
		| Where-Object Name -in $script:skipVMs
		| ForEach-Object {

			$script:skipNICs += $_.NicNames
			$script:skipIPs  += $_.IpNames
		}

		return
	}

	# save possible (candidate) NICs to skip
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| Where-Object name -in $script:skipVMs
	| ForEach-Object {

		foreach ($nic in $_.properties.networkProfile.networkInterfaces) {
			if ($Null -ne $nic.id) {
				$nicName = (get-resourceComponents $nic.id).mainResourceName
				if ($Null -ne $nicName) {
						$skipCanidates += $nicName
				}
			}
		}
	}

	# save NICs and public IPs to skip
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
	| Where-Object name -in $skipCanidates
	| ForEach-Object {

		$nicName = $_.name

		# check if NIC can be deleted
		$deletable = $True
		foreach ($conf in $_.properties.ipConfigurations) {
			if (($Null -ne $conf.properties.loadBalancerBackendAddressPools) `
			-or ($Null -ne $conf.properties.loadBalancerInboundNatRules)) {

				# do not delete NICs that are part of Load Balancers
				$deletable = $False
			}
		}
	
		if ($deletable) {
			$script:skipNICs += $nicName
			write-logFileUpdates 'networkInterfaces' $nicName 'skip NIC' '' '' 'from skipped VM'

			# collect IPs to delete
			foreach ($conf in $_.properties.ipConfigurations) {
				if ($Null -ne $conf.properties.publicIPAddress.id) {
					$ipName = (get-resourceComponents $conf.properties.publicIPAddress.id).mainResourceName
					if ($Null -ne $ipName) {

						# Public IP of a skipped NIC
						$script:skipIPs += $ipName
						write-logFileUpdates 'publicIPAddresses' $ipName 'skip IP address' '' '' 'from skipped VM'
					}
				}
			}
		}
	}
}

#--------------------------------------------------------------
function set-deploymentParameter {
#--------------------------------------------------------------
	param (
		$paramName,
		$paramValue,
		$group,
		$check
	)

	if ($check -and ($paramName -notin $script:availableParameters)) {
		# ARM template was passed to RGCOPY
		if ($pathArmTemplate -in $boundParameterNames) {
			write-logFileError 	"Invalid template: '$pathArmTemplate'" `
								"Template parameter '$paramName' is missing" `
								"Remove parameter 'setGroupTipSession' or use a template that contains TiP group $group"
		}
		# ARM template has just been created by RGCOPY
		else {
			write-logFileError "Invalid parameters 'setGroupTipSession' and 'setVmTipGroup'" `
								"Parameter 'setGroupTipSession' has been supplied for group $group" `
								"Set parameter 'setVmTipGroup' for missing group $group"
		}
	}
	$script:deployParameters.$paramName = $paramValue
}

#--------------------------------------------------------------
function get-deployParameters {
#--------------------------------------------------------------
	param (
		$check
	)

	$script:deployParameters = @{}

	# set template parameter for TiP
	if ($script:tipEnabled) {
		# process setGroupTipSession
		set-parameter 'setGroupTipSession' $setGroupTipSession
		get-ParameterRule
		while ($Null -ne $script:paramConfig) {

			# both, tipSessionID and tipClusterName must be supplied
			if (($Null -eq $script:paramConfig1) -or ($Null -eq $script:paramConfig2)) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"Required format: <sessionID>/<clusterName>@<group>"
			}
			# TiP group must be explicitly given
			if ($script:paramResources.count -eq 0) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"Required format: <sessionID>/<clusterName>@<group>"
			}

			foreach ($resource in $script:paramResources) {
				$group = $resource -as [int]
				if ($group -gt 0) {
					set-deploymentParameter "tipSessionID$group"   $script:paramConfig1 $group $check
					set-deploymentParameter "tipClusterName$group" $script:paramConfig2 $group $check
					$script:lastTipSessionID   = $script:paramConfig1
					$script:lastTipClusterName = $script:paramConfig2
				}
			}
			get-ParameterRule
		}
	}
}

#--------------------------------------------------------------
function deploy-templateTarget {
#--------------------------------------------------------------
	param (
		$DeploymentPath,
		$DeploymentName
	)

	write-stepStart "Deploy template $DeploymentPath" -skipLF

	$parameter = @{
		ResourceGroupName	= $targetRG
		Name				= $DeploymentName
		TemplateFile		= $DeploymentPath
		ErrorAction			= 'SilentlyContinue'
		ErrorVariable		= '+myDeploymentError'
		WarningAction		= 'SilentlyContinue'
	}

	get-templateParameters

	# get ARM deployment parameters
	get-deployParameters -check $True
	$parameter.TemplateParameterObject = $script:deployParameters
	write-logFileHashTable $parameter

	# deploy
	New-AzResourceGroupDeployment @parameter
	| write-LogFilePipe
	if (!$?) {
		write-logFile $myDeploymentError -ForegroundColor 'yellow'
		write-logFileError "Deployment '$DeploymentName' failed" `
							"Check the Azure Activity Log in resource group $targetRG"
	}

	write-stepEnd
}

#--------------------------------------------------------------
function deploy-linuxDiagnostic {
#--------------------------------------------------------------
	if (($diagSettingsSA.length -eq 0) -or ($diagSettingsContainer.length -eq 0)) {
		return
	}

	write-stepStart "Deploy Linux Diagnostic in VMs of Target Resource Group $targetRG"

	foreach ($vm in $targetVMs) {
		$vmName = $vm.Name

		# get parameter diagSettingsSA
		if ('diagSettingsSA' -notin $boundParameterNames) {
			$script:diagSettingsSA = ''
			$script:rgcopyTags
			| Where-Object {($_.vmName -eq $vmName) -and ($_.tagName -eq $azTagDiagSettingsSA)}
			| ForEach-Object {
				$script:diagSettingsSA = $_.value
			}
		}

		# get parameter diagSettingsContainer
		if ('diagSettingsContainer' -notin $boundParameterNames) {
			$script:diagSettingsContainer = ''
			$script:rgcopyTags
			| Where-Object {($_.vmName -eq $vmName) -and ($_.tagName -eq $azTagDiagSettingsContainer)}
			| ForEach-Object {
				$script:diagSettingsContainer = $_.value
			}
		}

		if (($diagSettingsSA.length -ne 0) -and ($diagSettingsContainer.length -ne 0)) {

			write-logFile "... deploying Linux Diagnostic Extension on VM '$vmName' using"
			write-logFile "      https://$diagSettingsSA.blob.core.windows.net/$diagSettingsContainer/$diagSettingsPub"
			write-logFile "      https://$diagSettingsSA.blob.core.windows.net/$diagSettingsContainer/$diagSettingsProt"
			write-logFile

			# set VM identity
			Update-AzVM `
				-ResourceGroupName	$targetRG `
				-VM					$vm `
				-IdentityType		'SystemAssigned' `
				-ErrorAction 		'SilentlyContinue' | Out-Null
			test-cmdlet 'Update-AzVM'  "Could not set system assigned identity for vm '$vmName'"

			$settingsRead = $True

			# get publicSettings
			$uri = " https://$diagSettingsSA.blob.core.windows.net/$diagSettingsContainer/$diagSettingsPub"
			try {
				$publicSettings = (Invoke-WebRequest `
									-Uri $uri `
									-ErrorAction 'Stop').Content
			}
			catch {
				write-logFileWarning "Could not read from '$uri'"
				$settingsRead = $False
			}

			# get protectedSettings
			$uri = " https://$diagSettingsSA.blob.core.windows.net/$diagSettingsContainer/$diagSettingsProt"
			try {
				$protectedSettings = (Invoke-WebRequest `
										-Uri $uri `
										-ErrorAction 'Stop').Content
			}
			catch {
				write-logFileWarning "Could not read from '$uri'"
				$settingsRead = $False
			}

			# publicSettings and protectedSettings read from Storage Account
			if ($settingsRead) {
				# install LinuxDiagnostic Extension
				Set-AzVMExtension `
					-ResourceGroupName		$targetRG `
					-VMName					$vmName `
					-Location				$targetLocation `
					-ExtensionType			'LinuxDiagnostic' `
					-Publisher				'Microsoft.Azure.Diagnostics' `
					-Name					'LinuxDiagnostic' `
					-SettingString			$publicSettings `
					-ProtectedSettingString	$protectedSettings `
					-TypeHandlerVersion		'3.0' `
					-ErrorAction			'SilentlyContinue' | Out-Null
				test-cmdlet 'Set-AzVMExtension'  "Could not deploy Linux Diagnostic Extension on VM '$vmName'"
			}

			# settings NOT read, but Storage Account set as RGCOPY parameter
			elseif (('diagSettingsSA' -in $boundParameterNames) -or ('diagSettingsContainer' -in $boundParameterNames)) {
				write-logError "Could not deploy Linux Diagnostic Extension on VM '$vmName'"
			}

			# settings NOT read, but Storage Account set as RGCOPY tag
			else {
				write-logFileWarning "Linux Diagnostic Extension on VM '$vmName' NOT deployed"
			}
		}
	}
	write-stepEnd
}

#--------------------------------------------------------------
function deploy-sapMonitor {
#--------------------------------------------------------------
	if ($installExtensionsSapMonitor.count -eq 0) {
		return
	}

	# using parameters for parallel execution
	$scriptParameter =  "`$targetRG = '$targetRG';"

	# parallel running script
	$script = {

		$vmName = $_
		Write-Output "... deploying VMAEME on $vmName"

		$res = Set-AzVMAEMExtension `
			-ResourceGroupName 	$targetRG `
			-VMName 			$vmName `
			-InstallNewExtension `
			-WarningAction 'SilentlyContinue' `
			-ErrorAction 'Stop'
		if (($res.IsSuccessStatusCode -ne $True) -or ($res.StatusCode -ne 'OK')) {
			throw "Deployment of VMAEME for SAP failed on $vmName"
		}

		Write-Output "VMAEME on $vmName deployed"
	}

	write-stepStart "Deploy VM Azure Enhanced Monitoring Extension (VMAEME) for SAP"
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	$installExtensionsSapMonitor
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileWarning "Deployment of VMAEME for SAP failed"
	}

	write-stepEnd
}

#--------------------------------------------------------------
function deploy-MonitorRules {
#--------------------------------------------------------------
	write-stepStart "Deploy Monitor Rules"

	$script:rgcopyTags
	| Where-Object tagName -eq $azTagMonitorRule
	| ForEach-Object {
		$vmName 	= $_.vmName
		$ruleName 	= $_.tagName

		# get rule
		$dcr = Get-AzDataCollectionRule `
					-ResourceGroupName	$monitorRG `
					-RuleName			$ruleName `
					-ErrorAction		'SilentlyContinue' `
					-WarningAction		'SilentlyContinue'
		test-cmdlet 'Get-AzDataCollectionRule'  "Could not get data collection rule '$ruleName' from resource group '$monitorRG'"

		# get VM resource ID
		$vmId = "/subscriptions/$targetSubID/resourceGroups/$targetRG/providers/Microsoft.Compute/virtualMachines/$vmName"

		# set rule
		New-AzDataCollectionRuleAssociation `
			-TargetResourceId	$vmId `
			-AssociationName	"$targetRG_$vmName" `
			-RuleId				$dcr.Id `
			-ErrorAction		'SilentlyContinue' | Out-Null
		test-cmdlet 'New-AzDataCollectionRuleAssociation'  "Data Collection Rule Association failed for VM '$vmName'"
	}

	write-stepEnd
}

#--------------------------------------------------------------
function stop-VMs {
#--------------------------------------------------------------
	param (
		$resourceGroup,
		$VMs
	)

	write-stepStart "Stop running VMs in Resource Group $resourceGroup" $maxDOP
	$VmNames = ($VMs | Where-Object PowerState -ne 'VM deallocated').Name
	if ($VmNames.count -eq 0) {
		write-logFile "All VMs are already stopped"
	}
	else {
		stop-VMsParallel $resourceGroup $VmNames
	}
	write-stepEnd
}

#--------------------------------------------------------------
function stop-VMsParallel {
#--------------------------------------------------------------
	param (
		$resourceGroup,
		$VmNames
	)

	$VmNames = $VmNames | Sort-Object -Unique

	# using parameters for parallel execution
	$scriptParameter =  "`$resourceGroup = '$resourceGroup';"

	# parallel running script
	$script = {

		Write-Output "... stopping $($_)"

		Stop-AzVM `
			-Force `
			-Name 				$_ `
			-ResourceGroupName 	$resourceGroup `
			-WarningAction 'SilentlyContinue' `
			-ErrorAction 'Stop' | Out-Null

		Write-Output "$($_) stopped"
	}

	# start execution
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP

	$VmNames
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host

	if (!$?) {
		write-logFileError "Could not stop VMs in resource group $resourceGroup" `
							"Stop-AzVM failed"
	}
}

#--------------------------------------------------------------
function start-VMsParallel {
#--------------------------------------------------------------
	param (
		$resourceGroup,
		$VmNames
	)

	$VmNames = $VmNames | Sort-Object -Unique

	# using parameters for parallel execution
	$scriptParameter =  "`$resourceGroup = '$resourceGroup';"

	# parallel running script
	$script = {

		if ($_.length -ne 0) {
			Write-Output "... starting $($_)"

			Start-AzVM `
			-Name 				$_ `
			-ResourceGroupName 	$resourceGroup `
			-WarningAction 'SilentlyContinue' `
			-ErrorAction 'Stop' | Out-Null

			Write-Output "$($_) started"
		}
	}

	# start execution
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP

	$VmNames
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host

	if (!$?) {
		write-logFileError "Could not start VMs in resource group $resourceGroup" `
							"Start-AzVM failed"
	}
}

#--------------------------------------------------------------
function start-VMs {
#--------------------------------------------------------------
	param (
		$resourceGroup
	)

	write-stepStart "Start COPIED VMs in Resource Group $resourceGroup" $maxDOP
	$currentVMs = @()
	$currentPrio = 0

	$script:copyVMs.values
	| Where-Object {($_.Skip -ne $true) -and ($_.Generalized -ne $True)}
	| Sort-Object VmPriority
	| ForEach-Object {

		if ($_.VmPriority -ne $currentPrio) {

			# start VMs with old priority
			if ($currentVMs.count -ne 0) {
				write-logFile "Starting VMs with priority $currentPrio"
				start-VMsParallel $resourceGroup $currentVMs
				Write-logFile
			}
			# new priority
			$currentPrio = $_.VmPriority
			$currentVMs  = @($_.Name)
		}
		else {
			$currentVMs += $_.Name
		}
	}

	# start VMs with old priority
	if ($currentVMs.count -ne 0) {
		write-logFile "Starting VMs with priority $currentPrio"
		start-VMsParallel $resourceGroup $currentVMs
	}
	write-stepEnd
}

#--------------------------------------------------------------
function start-sap {
#--------------------------------------------------------------
	param (
		$resourceGroup
	)

	if ($skipStartSAP -or $script:sapAlreadyStarted) {
		return $True
	}

	if ($scriptStartSapPath.length -eq 0) {
		write-logFileWarning "RGCOPY parameter 'scriptStartSapPath' not set. SAP not started."
		return $False
	}

	$script:sapAlreadyStarted = $True
	invoke-vmScript $scriptStartSapPath 'scriptStartSapPath' $resourceGroup
	return $True
}

#--------------------------------------------------------------
function save-tag {
#--------------------------------------------------------------
	param (
		$vmName,
		$tagName,
		$tagValue,
		$paramName,
		$paramSet
	)

	$script:rgcopyTags += @{
		vmName		= $vmName
		tagName		= $tagName
		value		= $tagValue
		paramName	= $paramName
		paramSet 	= $paramSet
	}
}

#--------------------------------------------------------------
function get-pathFromTags {
#--------------------------------------------------------------
	param (
		$vmName,
		$tagName,
		$tagValue, 
		 $refPath,
		$paramName
	)

	$paramSet = ' '

	if ($tagValue -match '\s') {
		write-logFileWarning "Value of tag '$tagName' of VM '$vmName' contains a white-space"
	}

	if ($tagValue.length -ne 0) {
		if (($refPath.Value.length -eq 0) -and !$ignoreTags) {
			$refPath.Value = $tagValue
			$paramSet = 'X'
		}
		save-tag $vmName $tagName $tagValue $paramName $paramSet
	}
}

#--------------------------------------------------------------
function get-allFromTags {
#--------------------------------------------------------------
	param (
		[array] $vms,
		$resourceGroup
	)

	$script:rgcopyTags = @()
	write-stepStart "Reading RGCOPY tags from VMs in resoure group '$resourceGroup'"

	$vmsFromTag = @()
	foreach ($vm in $vms) {
		[hashtable] $tags = $vm.Tags
		$vmName = $vm.Name

		# check tag names
		foreach ($key in $tags.keys) {
			if ($key -match '\s') {
				write-logFileWarning "Tag '$key' of VM '$vmName' contains a white-space"
			}
		}

		# updates variables from tags
		get-pathFromTags $vmName $azTagDiagSettingsSA        $tags.$azTagDiagSettingsSA        ([ref] $script:diagSettingsSA)          'diagSettingsSA'
		get-pathFromTags $vmName $azTagDiagSettingsContainer $tags.$azTagDiagSettingsContainer ([ref] $script:diagSettingsContainer)   'diagSettingsContainer'
		get-pathFromTags $vmName $azTagScriptStartSap        $tags.$azTagScriptStartSap        ([ref] $script:scriptStartSapPath)      'scriptStartSapPath'
		get-pathFromTags $vmName $azTagScriptStartLoad       $tags.$azTagScriptStartLoad       ([ref] $script:scriptStartLoadPath)     'scriptStartLoadPath'
		get-pathFromTags $vmName $azTagScriptStartAnalysis   $tags.$azTagScriptStartAnalysis   ([ref] $script:scriptStartAnalysisPath) 'scriptStartAnalysisPath'

		# tag azTagMonitorRule
		$tagName = $azTagMonitorRule
		$tagValue = $tags.$tagName
		if ($Null -ne $tagValue) {
			save-tag $vmName $tagName $tagValue
		}

		# tag azTagVmType
		$tagName = $azTagVmType
		$tagValue = $tags.$tagName
		if ($Null -ne $tagValue) {
			save-tag $vmName $tagName $tagValue
		}

		# tag azTagSapMonitor
		$tagName = $azTagSapMonitor
		$tagValue = $tags.$tagName
		$paramName = 'installExtensionsSapMonitor'
		$paramSet = ' '
		if ($tagValue.length -ne 0) {

			if ($tagValue -match '\s') {
				write-logFileWarning "Value of tag '$tagName' of VM '$vmName' contains a white-space"
			}

			if (($tagValue -eq 'true') `
			-and ($script:installExtensionsSapMonitor.count -eq 0) `
			-and !$ignoreTags ) {
				$paramSet = 'X'
				$vmsFromTag += $vmName
			}
			save-tag $vmName $tagName $tagValue $paramName $paramSet
		}

		# tag azTagTipGroup
		$tagName = $azTagTipGroup
		$tagValue = $tags.$tagName
		$paramName = 'setVmTipGroup'
		$paramSet = ' '
		$tipGroup = $tagValue -as [int]

		if ($tipGroup -gt 0) {
			if (($setVmTipGroup.count -eq 0) -and !$ignoreTags) {
				$paramSet = 'X'
				# parameter updated in function update-paramSetVmTipGroup
			}
			save-tag $vmName $tagName $tagValue $paramName $paramSet
		}

		# tag azTagDeploymentOrder
		$tagName = $azTagDeploymentOrder
		$tagValue = $tags.$tagName
		$paramName = 'setVmDeploymentOrder'
		$paramSet = ' '
		$priority = $tagValue -as [int]

		if ($priority -gt 0) {
			if (($setVmDeploymentOrder.count -eq 0) -and !$ignoreTags) {
				$paramSet = 'X'
				# parameter updated in function update-paramSetVmDeploymentOrder
			}
			save-tag $vmName $tagName $tagValue $paramName $paramSet
		}
	}

	if ($script:installExtensionsSapMonitor.count -eq 0) {
		$script:installExtensionsSapMonitor = $vmsFromTag
	}

	$script:rgcopyTags
	| Sort-Object vmName, tagName
	| Select-Object vmName, tagName, value,  paramName, paramSet
	| Format-Table
	| write-LogFilePipe

	if ($script:rgcopyTags.count -eq 0) {
		write-logFile "No RGCOPY tags found"
	}
	elseif ($ignoreTags) {
		write-logFileWarning "Tags ignored by RGCOPY"
	}
	else {
		write-logFile "Tags can be ignored using RGCOPY parameter switch 'ignoreTags'"
	}

	write-stepEnd
}

#--------------------------------------------------------------
function remove-storageAccount {
#--------------------------------------------------------------
	param (
		$myRG,
		$mySA
	)

	Get-AzStorageAccount `
		-ResourceGroupName 	$myRG `
		-Name 				$mySA `
		-ErrorAction 'SilentlyContinue' | Out-Null
	if (!$?) {
		# storage account does not exist -> nothing to do
		write-logFile
		return
	}

	# remove existing storage account
	Remove-AzStorageAccount `
		-ResourceGroupName	$myRG `
		-AccountName		$mySA `
		-Force
	test-cmdlet 'Remove-AzStorageAccount'  "Could not delete storage account $mySA"

	write-logFileWarning "Storage Account '$mySA' in Resource Group '$myRG' deleted"
	write-logFile
}

#--------------------------------------------------------------
function new-storageAccount {
#--------------------------------------------------------------
	param (
		$mySub,
		$mySubID,
		$myRG,
		$mySA,
		$myLocation,
		[switch] $fileStorage
	)

	if ($fileStorage) {
		$SkuName	= 'Premium_LRS'
		$Kind		= 'FileStorage'
		$accessTier = 'Hot'	
	}
	# Backups are stored zone redundant, as cheap as possibe
	# Cool for backups does not really help: PageBlob must be Hot
	elseif ($archiveMode) {
		$SkuName	= 'Standard_ZRS'
		$Kind		= 'StorageV2'
		$accessTier = 'Cool'
	}

	# BLOB is almost always remote: Standard should be sufficient
	# locally redundant should be sufficient for temporary data
	else {
		$SkuName	= 'Standard_LRS'
		# $SkuName	= 'Premium_LRS'
		$Kind		= 'StorageV2'
		$accessTier = 'Hot'
	}
	
	$savedSub = $script:currentSub
	set-context $mySub # *** CHANGE SUBSCRIPTION **************

	#--------------------------------------------------------------
	# Create Storage Account
	$currentSA = Get-AzStorageAccount `
		-ResourceGroupName 	$myRG `
		-Name 				$mySA `
		-ErrorAction 'SilentlyContinue'
	if ($?) {
		write-logFileTab 'Storage Account' $mySA 'already exists'
		if ($currentSA.Location -ne $myLocation) {
			write-logFileError "Storage Account '$mySA' is not in region '$myLocation'"
		}
	}
	else {
		$param = @{
			ResourceGroupName		= $myRG
			Name					= $mySA
			Location				= $myLocation
			SkuName					= $SkuName
			Kind					= $Kind
			AccessTier				= $accessTier
			MinimumTlsVersion 		= 'TLS1_2'
			AllowBlobPublicAccess	= $False
			WarningAction			= 'SilentlyContinue'
			ErrorAction				= 'SilentlyContinue'
		}

		#--------------------------------------------------------------
		# storage account for BLOB copy
		# currently: use delegation key and IP rule for RGCOPY MSFT version
		# therefore, no open VPN connection allowed
		#
		# in the future: use Network security perimeter
		if ($msInternalVersion) {
			$param.AllowSharedKeyAccess		= $False
			$param.PublicNetworkAccess 		= 'Enabled'
			$param.NetworkRuleSet 			= @{defaultAction	= 'Deny'}
		}

		# use storage account key for RGCOPY OSS version
		else {
			$param.AllowSharedKeyAccess		= $True
			$param.PublicNetworkAccess 		= 'Enabled'
		}

		#--------------------------------------------------------------
		# storage account for file share (backup/restore)
		if ($fileStorage) {
			$param.DnsEndpointType			= 'Standard'
			$param.PublicNetworkAccess 		= 'Disabled'
			if ($nfsQuotaGiB -gt 5120) {
				$param.EnableLargeFileShare	= $True
			}
			# Secure transfer required must be turned off for NFS
			# https://learn.microsoft.com/en-us/troubleshoot/azure/azure-storage/files/security/files-troubleshoot-linux-nfs
			$param.EnableHttpsTrafficOnly	= $False
		}

		New-AzStorageAccount @param | Out-Null
		test-cmdlet 'New-AzStorageAccount'  "The storage account name must be unique in whole Azure" `
						"Retry with other values of parameter 'targetRG' or 'targetSA'"

		write-logFileTab 'Storage Account' $mySA 'created'
	}

	if (!$fileStorage) {
		#--------------------------------------------------------------
		# Create Target Container
		$containerExisted = $False

		Get-AzRmStorageContainer `
			-ResourceGroupName	$myRG `
			-AccountName		$mySA `
			-ContainerName		$targetSaContainer `
			-ErrorAction 'SilentlyContinue' | Out-Null
		if ($?) {
			if ( ($archiveMode) `
			-and (!$archiveContainerOverwrite) `
			-and (!$restartRemoteCopy) ) {
				write-logFileError "Container '$targetSaContainer' already exists" `
									"Existing archive might be overwritten" `
									"Use RGCOPY switch 'archiveContainerOverwrite' for allowing this"
			}
			else {
				write-logFileTab 'Container' $targetSaContainer 'already exists'
				$containerExisted = $True
			}
		}

		else {
			# create container
			New-AzRmStorageContainer `
				-ResourceGroupName	$myRG `
				-AccountName		$mySA `
				-ContainerName		$targetSaContainer `
				-ErrorAction 'SilentlyContinue' | Out-Null
			test-cmdlet 'New-AzRmStorageContainer'  "Could not create container $targetSaContainer"

			write-logFileTab 'Container' $targetSaContainer 'created'
		}

		#--------------------------------------------------------------
		# add role
		$param = @{
			RoleDefinitionName = 'Storage Blob Data Owner'
			Scope = "/subscriptions/$mySubID/resourceGroups/$myRG/providers/Microsoft.Storage/storageAccounts/$mySA/blobServices/default/containers/$targetSaContainer"
			ErrorAction = 'SilentlyContinue'
		}

		# managed identity
		if ($script:currentAccountId -match "^[{]?[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}[}]?$") {
			$param.ApplicationId = $script:currentAccountId
		}
		# user
		else {
			$objectID = (Get-AzADUser -SignedIn -ErrorAction 'SilentlyContinue').Id
			test-cmdlet 'Get-AzADUser'  "Could not access Microsoft Entra ID"
			$param.ObjectID = $objectID
		}

		# role assignement
		New-AzRoleAssignment @param | Out-Null
		if (!$?) {
			# ignore error if container already existed (because the same role cannot be assigned a second time)
			if (!$containerExisted) {
				write-logFile
				write-logFileError "Could not grant access to container '$targetSaContainer'" `
									"Current user might not be privileged to change RBAC for the container" `
									"Use snapshot copy instead by using RGCOPY parameter 'useSnapshotCopy'" `
									-lastError
			}
		}
		else {
			write-logFileTab 'Container' $targetSaContainer 'access granted'
		}
	}

	#--------------------------------------------------------------
	# Create Source Share
	if ($fileStorage) {
		Get-AzRmStorageShare `
			-ResourceGroupName	$myRG `
			-StorageAccountName	$mySA `
			-Name				$sourceSaShare `
			-ErrorAction 'SilentlyContinue' | Out-Null
		if ($?) {
			write-logFileTab 'Share' $sourceSaShare 'already exists'
		}
		else {
			New-AzRmStorageShare `
				-ResourceGroupName	$myRG `
				-StorageAccountName	$mySA `
				-Name				$sourceSaShare `
				-EnabledProtocol	'NFS' `
				-QuotaGiB			$nfsQuotaGiB `
				-ErrorAction 'SilentlyContinue' | Out-Null
			test-cmdlet 'New-AzRmStorageShare'  "Could not create share $sourceSaShare"

			write-logFileTab 'Share' $sourceSaShare 'created'
		}
	}

	write-logFile
	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
}


#--------------------------------------------------------------
function remove-endpoint {
#--------------------------------------------------------------
	param (
			$resourceGroupName
	)

	$virtualNetworkName	= $script:nfsVnetName
	$storageAccountName	= $script:sourceSA
	$endpointName 		= "$storageAccountName-PrivateEndpoint"
	$dnsZoneName		= 'privatelink.file.core.windows.net'
	$dnsLinkName		= "$virtualNetworkName-DnsLink"

	# remove DNS record
	Remove-AzPrivateDnsRecordSet `
		-ResourceGroupName	$resourceGroupName `
		-ZoneName			$dnsZoneName `
		-Name				$storageAccountName `
		-RecordType			'A' `
		-ErrorAction		'SilentlyContinue' | Out-Null
	if ($?) {
		write-logFileTab 'DNS Record' $storageAccountName 'deleted'
	}
	else {
		write-logFileWarning "Removing DNS Record '$storageAccountName' failed"
	}

	# remove DNS link
	Remove-AzPrivateDnsVirtualNetworkLink `
		-ResourceGroupName	$resourceGroupName `
		-ZoneName			$dnsZoneName `
		-Name				$dnsLinkName `
		-ErrorAction		'SilentlyContinue' | Out-Null
	if ($?) {
		write-logFileTab 'DNS link' $dnsLinkName 'deleted'
	}
	else {
		write-logFileWarning "Removing DNS link '$dnsLinkName' failed"
	}

	# remove DNS zone
	Remove-AzPrivateDnsZone  `
		-ResourceGroupName	$resourceGroupName `
		-Name				$dnsZoneName `
		-ErrorAction		'SilentlyContinue' | Out-Null
	if ($?) {
		write-logFileTab 'DNS zone' $dnsZoneName 'deleted'
	}
	else {
		write-logFileWarning "Removing DNS zone '$dnsZoneName' failed"
	}
	
	# remove endpoint
	Remove-AzPrivateEndpoint `
		-Name				$endpointName `
		-ResourceGroupName	$resourceGroupName `
		-Force `
		-ErrorAction		'SilentlyContinue'| Out-Null
	if ($?) {
		write-logFileTab 'private endpoint' $endpointName 'deleted'
	}
	else {
		write-logFileWarning "Removing private endpoint '$endpointName' failed"
	}
}

#--------------------------------------------------------------
function new-endpoint {
#--------------------------------------------------------------
	param (
		 $resourceGroupName
	)

	$virtualNetworkName	= $script:nfsVnetName
	$subnetName			= $script:nfsSubnetName
	$storageAccountName	= $script:sourceSA
	$endpointName 		= "$storageAccountName-PrivateEndpoint"
	$dnsZoneName		= 'privatelink.file.core.windows.net'
	$dnsLinkName		= "$virtualNetworkName-DnsLink"
	$storageAccountId	= "/subscriptions/$sourceSubID/resourceGroups/$sourceRG/providers/Microsoft.Storage/storageAccounts/$storageAccountName"

	# get vnet
	$virtualNetwork = Get-AzVirtualNetwork `
						-ResourceGroupName	$resourceGroupName `
						-Name				$virtualNetworkName `
						-ErrorAction		'SilentlyContinue'
	test-cmdlet "'Get-AzVirtualNetwork' failed"
	
	# get subnet
	$subnet = $virtualNetwork
				| Select-Object -ExpandProperty Subnets
				| Where-Object Name -eq $subnetName
	test-cmdlet "'Get-AzVirtualNetwork' failed"


	# disable private endpoint network policies
	if ($subnet.PrivateEndpointNetworkPolicies -ne 'Disabled') {
		$subnet.PrivateEndpointNetworkPolicies = "Disabled"
		$virtualNetwork = $virtualNetwork | Set-AzVirtualNetwork -ErrorAction 'SilentlyContinue'
		test-cmdlet "'Set-AzVirtualNetwork' failed"
	}

	#--------------------------------------------------------------
	# private endpoint
	$privateEndpoint = Get-AzPrivateEndpoint `
							-Name				$endpointName `
							-ResourceGroupName	$resourceGroupName `
							-ErrorAction		'SilentlyContinue'

	if ($Null -ne $privateEndpoint) {
		write-logFileTab 'private endpoint' $endpointName 'already exists'
	}
	else {
		# create private link
		$privateEndpointConnection = New-AzPrivateLinkServiceConnection `
										-Name					"$storageAccountName-Connection" `
										-PrivateLinkServiceId 	$storageAccountId `
										-GroupId 				"file" `
										-ErrorAction			'SilentlyContinue'
	
		# create private endpoint
		$privateEndpoint = New-AzPrivateEndpoint `
							-ResourceGroupName				$resourceGroupName `
							-Name							$endpointName `
							-Location						$virtualNetwork.Location `
							-Subnet							$subnet `
							-PrivateLinkServiceConnection	$privateEndpointConnection `
							-ErrorAction					'SilentlyContinue'
		test-cmdlet "'New-AzPrivateEndpoint' failed"
		write-logFileTab 'private endpoint' $endpointName 'created'
	}

	#--------------------------------------------------------------
	# DNS zone
	$dnsZone = Get-AzPrivateDnsZone  `
					-ResourceGroupName	$resourceGroupName `
					-Name				$dnsZoneName `
					-ErrorAction		'SilentlyContinue'
	if ($Null -ne $dnsZone) {
		write-logFileTab 'DNS zone' $dnsZoneName 'already exists'
	}
	else {
		# create DNS zone
		New-AzPrivateDnsZone `
			-ResourceGroupName	$resourceGroupName `
			-Name				$dnsZoneName `
			-ErrorAction		'SilentlyContinue' | Out-Null
		test-cmdlet "'New-AzPrivateDnsZone' failed"
		write-logFileTab 'DNS zone' $dnsZoneName 'created'
	}

	#--------------------------------------------------------------
	# create DNS link
	$dnsLink = Get-AzPrivateDnsVirtualNetworkLink `
				-ResourceGroupName	$resourceGroupName `
				-ZoneName			$dnsZoneName `
				-Name				$dnsLinkName `
				-ErrorAction		'SilentlyContinue'
	if ($Null -ne $dnsLink) {
		write-logFileTab 'DNS link' $dnsLinkName 'already exists'
	}
	else {
		New-AzPrivateDnsVirtualNetworkLink `
			-ResourceGroupName	$resourceGroupName `
			-ZoneName			$dnsZoneName `
			-Name				$dnsLinkName `
			-VirtualNetworkId	$virtualNetwork.Id `
			-ErrorAction 		'SilentlyContinue' | Out-Null
		test-cmdlet "'New-AzPrivateDnsVirtualNetworkLink' failed"
		write-logFileTab 'DNS link' $dnsLinkName 'created'
	}

	#--------------------------------------------------------------
	# DNS record set
	$dnsRecordSet = Get-AzPrivateDnsRecordSet `
				-ResourceGroupName	$resourceGroupName `
				-ZoneName			$dnsZoneName `
				-Name				$storageAccountName `
				-RecordType			'A' `
				-ErrorAction		'SilentlyContinue'
	if ($Null -ne $dnsRecordSet) {
		write-logFileTab 'DNS Record' $storageAccountName 'already exists'
	}
	else {
		# get endpoint IP
		$privateEndpointIP = $privateEndpoint `
							| Select-Object -ExpandProperty NetworkInterfaces `
							| Select-Object @{ Name = "NetworkInterfaces"; Expression = { 
									Get-AzNetworkInterface `
										-ResourceId		$_.Id `
										-ErrorAction 	'SilentlyContinue'
								}} `
							| Select-Object -ExpandProperty NetworkInterfaces `
							| Select-Object -ExpandProperty IpConfigurations `
							| Select-Object -ExpandProperty PrivateIpAddress
		test-cmdlet "'Get-AzNetworkInterface' failed"

		
		# create endpoint config
		$privateDnsRecordConfig = New-AzPrivateDnsRecordConfig `
									-IPv4Address	$privateEndpointIP `
									-ErrorAction 		'SilentlyContinue'
		test-cmdlet "'New-AzPrivateDnsRecordConfig' failed"

		# create DNS record
		New-AzPrivateDnsRecordSet `
				-ResourceGroupName	$resourceGroupName `
				-Name				$storageAccountName `
				-RecordType 		'A' `
				-ZoneName			$dnsZoneName `
				-Ttl				600 `
				-PrivateDnsRecords	$privateDnsRecordConfig `
				-ErrorAction 'SilentlyContinue' | Out-Null
		test-cmdlet "'New-AzPrivateDnsRecordSet' failed"

		write-logFileTab 'DNS Record' $storageAccountName 'created'
	}
}

#--------------------------------------------------------------
function new-resourceGroup {
#--------------------------------------------------------------
	$rgNeeded = $False

	if (!$skipDeployment ) {
		$rgNeeded = $True
	}

	if (($blobCopyNeeded -and !$skipRemoteCopy) `
	-or ($snapshotCopyNeeded -and !$skipRemoteCopy)) {
		$rgNeeded = $True
	}

	if (($justCopyBlobs.count -ne 0) `
	-or ($justCopySnapshots.count -ne 0) `
	-or ($justCopyDisks.count -ne 0)) {
		$rgNeeded = $True
	}

	if (!$rgNeeded -or $simulate) {
		return
	}

	write-stepStart "CREATE RESOURCE GROUP"

	$savedSub = $script:currentSub
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	$currentRG = Get-AzResourceGroup `
					-Name 	$targetRG `
					-ErrorAction 'SilentlyContinue'

	# resource group already exists
	if ($?) {
		write-logFileTab 'Resource Group' $targetRG 'already exists'

		if (($currentRG.Location -ne $targetLocation) -and !$skipVmChecks) {
			write-logFileError "Resource Group '$targetRG' is not in region '$targetLocation'" `
								"You can skip this check using $program parameter switch 'skipVmChecks'"
		}

		if ( !$allowExistingDisks `
		-and !$skipDeploymentVMs `
		-and !$archiveMode `
		-and !$SourceOnlyMode `
		-and ($justCopyDisks.count -eq 0) ) {

			# Get target disks
			$disksTarget = Get-AzDisk `
								-ResourceGroupName $targetRG `
								-ErrorAction 'SilentlyContinue'
			test-cmdlet 'Get-AzDisk'  "Could not get disks of resource group '$targetRG'" 

			# check if targetRG already contains disks
			if ($disksTarget.count -ne 0) {
				write-logFileWarning "Target resource group '$targetRG' already contains resources (disks)" `
									"This is only allowed when parameter 'setVmMerge' is used" `
									"You can skip this check using RGCOPY parameter switch 'allowExistingDisks'" `
									-stopCondition $True
			}
		}
	}

	# in MERGE MODE, resource group must already exist
	elseif ($mergeMode) {
		write-logFileError "Target resource group '$targetRG' does not exist"
	}

	# CREATE resource group
	else {
		$tag = @{
			Created_by = 'rgcopy.ps1'
		}

		if ($Null -ne $setOwner) {
			$tag.Add('Owner', $setOwner)
		}

		New-AzResourceGroup `
			-Name 		$targetRG `
			-Location	$targetLocation `
			-Tag 		$tag `
			-ErrorAction 'SilentlyContinue' | Out-Null
		test-cmdlet 'New-AzResourceGroup'  "Could not create resource Group $targetRG"

		write-logFileTab 'Resource Group' $targetRG 'created'
	}
	
	# CREATE storage account
	if ($blobCopyNeeded) {
		new-storageAccount $targetSub $targetSubID $targetRG $targetSA $targetLocation
	}

	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
	write-stepEnd
}

#--------------------------------------------------------------
function invoke-mountPoint {
#--------------------------------------------------------------
	param (
		$resourceGroup,
		$scriptVm,
		$scriptName
	)

	Write-Output $scriptName >$tempPathText

	# script parameters
	$parameter = @{
		ResourceGroupName 	= $resourceGroup
		VMName            	= $scriptVM
		CommandId         	= 'RunShellScript'
		scriptPath 			= $tempPathText
		ErrorAction			= 'SilentlyContinue'
	}

	# execute script
	Invoke-AzVMRunCommand @parameter
	| Tee-Object -Variable result
	| Out-Null

	# check results
	if     ($result.Value[0].Message -like '*++ exit 0*')	{ $status = 0 }
	elseif ($result.Value[0].Message -like '*++ exit 2*')	{ $status = 2 }
	else 													{ $status = 1 }

	if ($status -eq 1) {
		write-logFileWarning $result.Value[0].Message
	}
	elseif ($verboseLog) {
		write-logFile        $result.Value[0].Message
	}

	Remove-Item -Path $tempPathText
	return $status
}

#--------------------------------------------------------------
function wait-mountPoint {
#--------------------------------------------------------------
$scriptFunction = @'
#!/bin/bash
test () {
	vmName=$1
	action=$2
	testFile=$3
	if [ "$4" == '' ];
		then echo "not enough parameters"; echo '++ exit 1'; exit 1;
		else shift 3;
	fi

	# mount point parameters
	declare -a mountPoints
	declare -i i=0
	while (( "$#" )); do
		mountPoints[$i]=$1;
		shift
		((i++))
	done

	declare -i numRunning=0
	declare -i numFinished=0
	echo "check $action status in VM $vmName"

	# process mount points
	len=${#mountPoints[*]}
	for ((n=0; n<len; n++)); do
		mountPoint=${mountPoints[$n]}

		# check backup file
		if [ ! -f "/mnt/rgcopy/$vmName$mountPoint/backup.tar" ];
			then echo "backup file /mnt/rgcopy/$vmName$mountPoint/backup.tar does not exist (VM rebooted?)"; echo '++ exit 1'; exit 1;
		fi

		# check test file
		if [ -f "/mnt/rgcopy/$vmName$mountPoint/$testFile" ];
			then echo "$action of mount point $mountPoint finished"; ((numFinished++));
			else echo "$action of mount point $mountPoint still running"; ((numRunning++));
		fi
	done

	echo "$numRunning processes running, $numFinished processes finished"
	if [ $numRunning -eq 0 ];
		then echo "++ exit 0";
		else echo "++ exit 2";
	fi
}

'@ # empty line above needed!

	write-stepStart "CHECK BACKGROUND JOBS COMPLETION"
	$firstLoop = $True
	$script:waitCount = 0
	do {
		if (!$firstLoop) {
			Write-logFile
			write-logFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz')
		}
		$firstLoop = $False
		$done = $True
		foreach ($task in $script:runningTasks) {

			$action = $task.action
			$vmName = $task.vmName

			if ($task.finished) {
				Write-logFile "$action finished for $vmName" -ForegroundColor 'Green'
			}
			else {
				# assemble test script parameters
				if ($action -eq 'backup') {
					$resourceGroup	= $sourceRG
					$testFile 		= 'backup-finished'
				}
				else {
					$resourceGroup 	= $targetRG
					$testFile		= "restore-$targetRG-finished"
				}

				# run shell script
				$script = $scriptFunction + "test $vmName $action $testFile " + $task.mountPoints
				$rc = invoke-mountPoint $resourceGroup $vmName $script

				# check status
				if ($rc -eq 0) {
					$task.finished = $True
					Write-logFile "$action finished for $vmName" -ForegroundColor 'Green'
				}
				elseif ($rc -eq 2) {
					$done = $False
					Write-logFile "$action still running for $vmName" -ForegroundColor 'DarkYellow'
				}
				else{
					write-logFileError "Mount point $action failed for resource group '$resourceGroup'" `
										"Checking status failed in VM '$vmName'" `
										"Invoke-AzVMRunCommand failed"
				}
			}
		}

		if (!$done) { 
			$delayMinutes = get-waitTime
			Start-Sleep -seconds (60 * $delayMinutes)
		}
	} while (!$done)
	write-stepEnd
}

#--------------------------------------------------------------
function get-nfsSubnet {
#--------------------------------------------------------------
	$vnet = $null
	$subnet = $Null

	# BICEP
	if ($useBicep) {
		foreach ($net in $script:az_virtualNetworks) {
			foreach ($sub in $net.Subnets) {
				if ($sub.Delegations.count -eq 0) {
					$vnet	= $net.Name
					$subnet = $sub.Name	
				}
			}
		}
	}
	return $vnet, $subnet
}

#--------------------------------------------------------------
function backup-mountPoint {
#--------------------------------------------------------------
$scriptFunction = @'
#!/bin/bash

backup () {
	storageAccount=$1
	vmName=$2
	if [ "$3" == '' ]; then echo "not enough parameters"; echo '++ exit 1'; exit 1; fi
	shift 2

	# mount point parameters
	declare -a mountPoints
	declare -i i=0
	while (( "$#" )); do
		mountPoints[$i]=$1; shift; ((i++))
	done

	# stop SAP
	systemctl stop sapinit; sleep 1
	killall -q hdbrsutil; sleep 1

	# install NFS
	suse=`cat /etc/os-release | grep -i suse | wc -l`
	redHat=`cat /etc/os-release | grep -i 'Red Hat' | wc -l`
	if [ $suse -gt 0 ]; then
		zypper -n -q install nfs-client
	elif [ $redHat -gt 0 ]; then
		yum -q -y install nfs-utils
	else
		apt-get install nfs-common
	fi
	sed -i 's/^.*Domain\s*=.*$/Domain = defaultv4iddomain.com/g' /etc/idmapd.conf
	systemctl restart rpcbind

	# mount share /mnt/rgcopy
	mkdir -p /mnt/rgcopy
	echo umount -f /mnt/rgcopy
	umount -f /mnt/rgcopy
	found=`cat /etc/fstab | grep $storageAccount.file.core.windows.net | wc -l`
	if [ $found -eq 0 ]; then
		echo $storageAccount.file.core.windows.net:/$storageAccount/rgcopy /mnt/rgcopy nfs4 vers=4,minorversion=1,sec=sys,nofail 0 0 >>/etc/fstab
	fi
	mount -a
	if [ $(cat /etc/mtab | grep "^\S\S*\s\s*/mnt/rgcopy\s" | wc -l) -lt 1 ]; then echo "share not mounted"; echo '++ exit 1'; exit 1; fi
	echo

	# process mount points
	len=${#mountPoints[*]}
	for ((n=0; n<len; n++)); do
		mountPoint=${mountPoints[$n]}
		backupDir=/mnt/rgcopy/$vmName$mountPoint

		# remove old log files
		mkdir -p $backupDir
		rm -f $backupDir/backup.tar
		rm -f $backupDir/backup-started
		rm -f $backupDir/backup-finished
		rm -f $backupDir/backup-output

		# check for open files
		cd /
		if [ ! -d $mountPoint ]; then echo "mount point $mountPoint not found"; echo '++ exit 1'; exit 1; fi
		if [ $(lsof $mountPoint 2>/dev/null |wc -l) -ne 0 ]; then echo "open files in $mountPoint"; lsof $mountPoint; echo '++ exit 1'; exit 1; fi

		# backup original directory
		if [ -d $mountPoint ];
			then cd $mountPoint;
			else echo "mount point $mountPoint does not exist"; echo '++ exit 1'; exit 1;
		fi
		# backup snapshot instead
		if [ -d "$mountPoint/.snapshot/rgcopy" ];
			then cd $mountPoint/.snapshot/rgcopy;
		fi

		# start TAR as background shop
		echo "starting backup of mount point $(pwd)"
		date >$backupDir/backup-started
		(tar -cvf $backupDir/backup.tar . >$backupDir/backup-output && date >$backupDir/backup-finished) &
	done
	echo '++ exit 0'; exit 0
}

'@ # empty line above needed!

	$script:runningTasks = @()
	$script:copyVMs.values
	| Where-Object {$_.MountPoints.count -ne 0}
	| ForEach-Object {

		$vmName = $_.Name
		write-logFile
		write-logFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz')
		write-logFile "Backup volumes/disks of VM $vmName`:"
		wait-vmAgent $sourceRG $vmName 'BACKUP VOLUMES/DISKS to NFS share'

		# save running Tasks
		$script:runningTasks += @{
			vmName 		= $vmName
			mountPoints	= $_.MountPoints.Path
			action		= 'backup'
			finished 	= $False
		}

		# run shell script
		$script = $scriptFunction + "backup $sourceSA $vmName " + $_.MountPoints.Path
		$rc = invoke-mountPoint $sourceRG $vmName $script
		if ($rc -ne 0) {
			write-logFileError "Backup of mount points failed for resource group '$sourceRG'" `
								"File Backup failed in VM '$vmName'" `
								"Invoke-AzVMRunCommand failed"
		}

		foreach ($path in $_.MountPoints.Path) {
			write-logFile "Backup job started on VM $vmName for mount point $path" -ForegroundColor Blue
		}
	}
	write-stepEnd
}

#--------------------------------------------------------------
function restore-mountPoint {
#--------------------------------------------------------------
	# collect mount points
	$restoreVMs = @{}

	# get disks in target RG
	$disks = Get-AzDisk `
		-ResourceGroupName	$targetRG `
		-ErrorAction		'SilentlyContinue'
	if (!$?) {
		write-logFileError "Mount point restore failed for resource group '$targetRG'" `
							"Could not get disks of resource group '$targetRG'" `
							'Get-AzDisk failed'
	}

	foreach ($disk in $disks) {
		$vmName	= $disk.Tags."$azTagVM"
		$path	= $disk.Tags."$azTagPath"
		$lun 	= $disk.Tags."$azTagLun"

		if (($Null -ne $vmName) -and ($Null -ne $path) -and ($Null -ne $lun)) {
			# mount point for disk
			$mountPoint = @{
				Path	= $path
				Lun		= $lun
				Nfs		= $Null
			}

			# add mount point to new VM
			if ($Null -eq $restoreVMs[$vmName]) {
				$restoreVMs[$vmName] = @{
					VmName		= $vmName
					MountPoints	= @( $mountPoint )
				}
			}
			# add mount point to existing VM
			else { $restoreVMs[$vmName].MountPoints += $mountPoint }

			# save storage account (same for all mount points)
			$Sub = $disk.Tags."$azTagSub"
			$RG  = $disk.Tags."$azTagRG"
			$SA  = $disk.Tags."$azTagSA"
		}
	}

	# get volumes in target RG
	# ignore errors, because there might be no NetApp account in the target RG
	$volumes = Get-AzNetAppFilesVolume `
				-ResourceGroupName	$targetRG `
				-AccountName		$netAppAccountName `
				-PoolName			$netAppPoolName `
				-ErrorAction 		'SilentlyContinue'

	foreach ($volume in $volumes) {
		$vmName	= $volume.Tags."$azTagVM"
		$path	= $volume.Tags."$azTagPath"

		if (($Null -ne $vmName) -and ($Null -ne $path)) {
			$x,$y,$volumeName = $volume.Name -split '/'

			# mount point for volume
			$mountPoint = @{
				Path	= $path
				Lun		= $Null
				Nfs		= "$($volume.MountTargets[0].IpAddress):/$volumeName"
			}

			# add mount point to new VM
			if ($Null -eq $restoreVMs[$vmName]) {
				$restoreVMs[$vmName] = @{
					VmName		= $vmName
					MountPoints	= @( $mountPoint )
				}
			}
			# add mount point to existing VM
			else { $restoreVMs[$vmName].MountPoints += $mountPoint }

			# save storage account (same for all mount points)
			$Sub = $volume.Tags."$azTagSub"
			$RG  = $volume.Tags."$azTagRG"
			$SA  = $volume.Tags."$azTagSA"
		}
	}

	# nothing found for Restore
	if (($Null -eq $Sub) -or ($Null -eq $RG) -or ($Null -eq $SA)) {
		$script:skipRestore = $True
		return
	}

	# get storage account key in source RG
	$script:restoreSA = $SA

$script1 = @'
#!/bin/bash

restore () {
	storageAccount=$1
	vmName=$2
	targetRG=$3
	if [ "$4" == '' ]; then echo "not enough parameters"; echo '++ exit 1'; exit 1; fi
	shift 3

	# mount point parameters
	declare -a mountPoints
	declare -a nfsVolumes
	declare -a luns
	declare -i i=0
	while (( "$#" )); do
		mountPoints[$i]=$1;
		nfsVolumes[$i]=$2;
		luns[$i]=$3;
		if (( "$#" )); then shift; fi
		if (( "$#" )); then shift; fi
		if (( "$#" )); then shift; fi
		((i++))
	done

	# fix NFS4 nobody issue
	sed -i 's/^.*Domain\s*=.*$/Domain = defaultv4iddomain.com/g' /etc/idmapd.conf
	systemctl restart rpcbind

	# stop SAP
	systemctl stop sapinit; sleep 1
	killall -q hdbrsutil; sleep 1

	# install NFS
	suse=`cat /etc/os-release | grep -i suse | wc -l`
	redHat=`cat /etc/os-release | grep -i 'Red Hat' | wc -l`
	if [ $suse -gt 0 ]; then
		zypper -n -q install nfs-client
	elif [ $redHat -gt 0 ]; then
		yum -q -y install nfs-utils
	else
		apt-get install nfs-common
	fi
	sed -i 's/^.*Domain\s*=.*$/Domain = defaultv4iddomain.com/g' /etc/idmapd.conf
	systemctl restart rpcbind

	# mount share /mnt/rgcopy
	mkdir -p /mnt/rgcopy
	echo umount -f /mnt/rgcopy
	umount -f /mnt/rgcopy
	found=`cat /etc/fstab | grep $storageAccount.file.core.windows.net | wc -l`
	if [ $found -eq 0 ]; then
	echo $storageAccount.file.core.windows.net:/$storageAccount/rgcopy /mnt/rgcopy nfs4 vers=4,minorversion=1,sec=sys,nofail 0 0 >>/etc/fstab
	fi
	mount -a
	if [ $(cat /etc/mtab | grep "^\S\S*\s\s*/mnt/rgcopy\s" | wc -l) -lt 1 ]; then echo "share not mounted"; echo '++ exit 1'; exit 1; fi
	echo

	# process mount points
	len=${#mountPoints[*]}
	cd /
	for ((n=0; n<len; n++)); do
		mountPoint=${mountPoints[$n]}
		nfsVolume=${nfsVolumes[$n]}
		lunNum=${luns[$n]}
		backupDir=/mnt/rgcopy/$vmName$mountPoint

		# check directories
		if [ ! -d $mountPoint ]; then echo "mount point $mountPoint does not exist"; echo '++ exit 1'; exit 1; fi
		if [ ! -f "$backupDir/backup.tar" ]; then echo "file $backupDir/backup.tar not found"; echo '++ exit 1'; exit 1; fi

		# check for open files
		if [ $(lsof $mountPoint 2>/dev/null |wc -l) -ne 0 ]; then echo "open files in $mountPoint"; lsof $mountPoint; echo '++ exit 1'; exit 1; fi

'@ # empty line above needed!

$script2 = @'
		# unmount
		echo umount -f $mountPoint
		umount -f $mountPoint
		sed -i "/^\S\S*\s\s*${mountPoint//[\/]/\\\/}\s/d" /etc/fstab
		echo systemctl daemon-reload
		systemctl daemon-reload

		if [[ $nfsVolume == 'null' ]]; then
			# partition disk
			lun="lun$lunNum"
			echo partition disk /dev/disk/azure/scsi1/$lun
			parted    /dev/disk/azure/scsi1/$lun --script mklabel gpt mkpart xfspart xfs 0% 100%
			sleep 1
			mkfs.xfs  /dev/disk/azure/scsi1/$lun-part1
			partprobe /dev/disk/azure/scsi1/$lun-part1

			# mount Disks
			echo mount /dev/disk/azure/scsi1/$lun-part1 $mountPoint
			mount /dev/disk/azure/scsi1/$lun-part1 $mountPoint
			if [ $(cat /etc/mtab | grep "^\S\S*\s\s*$mountPoint\s" | wc -l) -lt 1 ]; then echo "disk not mounted at $mountPoint"; echo '++ exit 1'; exit 1; fi
			echo /dev/disk/azure/scsi1/$lun-part1 $mountPoint xfs defaults,nofail 0 0 >> /etc/fstab

		else
			# mount NFS
			echo mount -t nfs -o rw,hard,rsize=1048576,wsize=1048576,sec=sys,vers=4.1,tcp $nfsVolume $mountPoint
			mount -t nfs -o rw,hard,rsize=1048576,wsize=1048576,sec=sys,vers=4.1,tcp $nfsVolume $mountPoint
			if [ $(cat /etc/mtab | grep "^\S\S*\s\s*$mountPoint\s" | wc -l) -lt 1 ]; then echo "NFS not mounted"; echo '++ exit 1'; exit 1; fi
			echo $nfsVolume $mountPoint nfs4 rw,hard,rsize=1048576,wsize=1048576,sec=sys,vers=4.1,tcp,nofail 0 0 >>/etc/fstab
		fi

'@ # empty line above needed!

$script3 = @'
		echo
	done

	# start TAR as background shop
	for ((n=0; n<len; n++)); do
		mountPoint=${mountPoints[$n]}
		backupDir=/mnt/rgcopy/$vmName$mountPoint

		# remove old log files
		rm -f $backupDir/restore-$targetRG-started
		rm -f $backupDir/restore-$targetRG-finished
		rm -f $backupDir/restore-$targetRG-output

		echo "starting restore of mount point $mountPoint"
		cd $mountPoint
		date >$backupDir/restore-$targetRG-started
		(tar -xvf $backupDir/backup.tar . >$backupDir/restore-$targetRG-output && date >$backupDir/restore-$targetRG-finished) &
	done
	echo '++ exit 0'; exit 0
}

'@ # empty line above needed!

	if ($continueRestore) {
		$scriptFunction = $script1 +            $script3
	}
	else { 
		$scriptFunction = $script1 + $script2 + $script3
	}

	write-stepStart 'RESTORE VOLUMES/DISKS from NFS share'
	new-endpoint $targetRG

	$script:runningTasks = @()
	$restoreVMs.Values
	| ForEach-Object {

		$vmName = $_.VmName
		$pathList = @()

		# create script text
		$script = $scriptFunction + "restore $script:restoreSA $vmName $targetRG"
		foreach ($mountPoint in $_.MountPoints) {
			$path = $mountPoint.Path
			$nfs  = $mountPoint.Nfs; if ($Null -eq $nfs) { $nfs = 'null' }
			$lun  = $mountPoint.Lun; if ($Null -eq $lun) { $lun = -1 }
			$script += " $path $nfs $lun"
			$pathList += $path
		}

		# save running Tasks
		$script:runningTasks += @{
			vmName 		= $vmName
			mountPoints	= $pathList
			action		= 'restore'
			finished 	= $False
		}

		# run shell script
		write-logFile
		write-logFile "Restore volumes/disks of VM $vmName`:"
		wait-vmAgent $targetRG $vmName 'RESTORE VOLUMES/DISKS from NFS share'

		$rc = invoke-mountPoint $targetRG $vmName $script
		if ($rc -ne 0) {
			write-logFileError "Mount point restore failed for resource group '$targetRG'" `
								"File restore failed in VM '$vmName'" `
								"Invoke-AzVMRunCommand failed"
		}

		foreach ($path in $pathList) {
			write-logFile "Restore job started on VM $vmName for mount point $path" -ForegroundColor Blue
		}
	}
	write-stepEnd
}

#-------------------------------------------------------------
function get-subscriptionFeatures {
#-------------------------------------------------------------

	# try-catch around first Az cmdlet in this script
	# This will catch authentication issues
	try {
		$subProp = (Get-AzProviderFeature -ListAvailable -ErrorAction 'Stop'
			| Where-Object FeatureName -in @('AvailabilitySetPinning', 'TiPNode')
			| Where-Object RegistrationState -eq 'Registered'
			).count
	}
	catch {
		test-cmdlet 'Get-AzProviderFeature'  'Getting subscription features failed' -always
	}

	# check TiP parameters
	if ($subProp -lt 2) {
		if (($setGroupTipSession.count -ne 0) -or ($setVmTipGroup.count -ne 0)) {
			write-logFileWarning 'Target Subscription is not TiP enabled' `
								-stopWhenForceVmChecks
		}
		$script:tipEnabled = $False
	}
	else {
		$script:tipEnabled = $True
	}
}

#-------------------------------------------------------------
function test-givenArmTemplate {
#-------------------------------------------------------------
	if ($pathArmTemplate.length -eq 0) {
		return 
	}

	# required steps:
	$script:skipArmTemplate 	= $True
	$script:skipSnapshots 		= $True
	$script:skipRemoteCopy 		= $True

	write-logFileForbidden 'pathArmTemplate' @(
		'useSnapshotCopy'
		'useBlobCopy'
		'skipRemoteCopy'
		'skipSnapshots'
	)

	# ARM template can only be applied in same region
	# This is the case for COPY mode with snapshpts
	# as well as for deploying a backup in ARCHIVE mode with BLOBs
	if ($sourceLocation -ne $targetLocation) {

		write-logFileError "Invalid parameter 'pathArmTemplate'" `
							"Source RG and target RG must be in the same region"
	}
}

#-------------------------------------------------------------
function test-justCopyBlobsSnapshotsDisks {
#-------------------------------------------------------------
# forbidden parameters:
	$forbidden = @(
# general parameters
		# 'simulate'
		# 'skipWorkarounds'
		# 'pathExportFolder'
		# 'hostPlainText'
		# 'maxDOP'
		# 'verboseLog'
# error handling		
		# 'skipVmChecks'
		# 'forceVmChecks'
		# 'skipRemoteReferences'
		# 'skipWorkarounds'
		# 'useNewVmSizes'
# RG parameters
		# 'sourceRG'
		# 'targetRG'
		# 'targetLocation'
		# 'targetSA'
		'sourceSA'
		# 'sourceSub'
		# 'sourceSubUser'
		# 'sourceSubTenant'
		# 'targetSub'
		# 'targetSubUser'
		# 'targetSubTenant'
# operation steps
		'skipArmTemplate'
			# 'skipSnapshots'
		'stopVMsSourceRG'
		'skipBackups'
		'skipRemoteCopy'
		'skipDeployment'
			'skipDeploymentVMs'
			'skipRestore'
			'stopRestore'
			'continueRestore'
			'skipExtensions'
		'startWorkload'
		'stopVMsTargetRG'
		'deleteSnapshots'
		'deleteSourceSA'
# operation modes
		'justCreateSnapshots'
		'justDeleteSnapshots'
# Clone Mode
		'cloneMode'
		'cloneNumber'
		'cloneVMs'
		'attachVmssFlex'
		'attachAvailabilitySet'
		'attachProximityPlacementGroup'
# Merge Mode
		'mergeMode'
		'setVmMerge'
		'setVmName'
		'renameDisks'
		'allowExistingDisks'
# Update Mode
		'updateMode'
		'deleteSnapshotsAll'
		'createBastion'
		'deleteBastion'
# Patch Mode
		'patchMode'
		'patchVMs'
		'patchKernel'
		'patchAll'
		'prePatchCommand'
		'skipPatch'
		'forceExtensions'
		'skipExtensions'
		'autoUpgradeExtensions'
# Archive Mode
		'archiveMode'
		'archiveContainer'
		'archiveContainerOverwrite'
# Copy Mode
		'swapSnapshot4disk'
		'swapDisk4disk'
		'pathArmTemplate'
		'pathArmTemplateDisks'
		'ignoreTags'
		'copyDetachedDisks'
		'jumpboxName'
		'skipDefaultValues'
		# 'defaultDiskZone'
		# 'defaultDiskName'
# BLOB copy
		# 'restartRemoteCopy'
		# 'justCopyBlobs'
		# 'justCopySnapshots'
		# 'justCopyDisks'
		'justStopCopyBlobs'
		# 'useBlobCopy'
		# 'useSnapshotCopy'
		# 'blobsSA'
		# 'blobsRG'
		# 'blobsSaContainer'
		# 'grantTokenTimeSec'
# scripts
		'skipStartSAP'
		'pathPreSnapshotScript'
		'pathPostDeploymentScript'
		'scriptStartSapPath'
		'scriptStartLoadPath'
		'scriptStartAnalysisPath'
		'vmStartWaitSec'
		'preSnapshotWaitSec'
		'vmAgentWaitMinutes'
# VM extensions
		'installExtensionsSapMonitor'
# Azure NetApp Files
		'createVolumes'
		'createDisks'
		# 'skipDisks'
		'snapshotVolumes'
		'netAppServiceLevel'
		'netAppAccountName'
		'netAppPoolName'
		'netAppPoolGB'
		'netAppMovePool'
		'netAppMoveForce'
		'netAppSubnet'
		'createDisksTier'
# get resources
		# 'allowRunningVMs'
		'skipGreenlist'
		'useBicep'
# skip resources
		# 'skipVMs'
		'skipSecurityRules'
		'keepTags'
		'skipVmssFlex'
		'skipAvailabilitySet'
		'skipProximityPlacementGroup'
		'skipBastion'
		'skipBootDiagnostics'
# configure resources
		'setVmSize'
		'setDiskSize'
		'setDiskTier'
		'setDiskBursting'
		'setDiskIOps'
		'setDiskMBps'
		'setDiskMaxShares'
		'setDiskCaching'
		'setDiskSku'
		# 'setVmZone'
		'setVmFaultDomain'
		'setPrivateIpAlloc'
		'removeFQDN'
		'setAcceleratedNetworking'
# create resources
		'createVmssFlex'
		'singlePlacementGroup'
		'createAvailabilitySet'
		'createProximityPlacementGroup'
# deploy resources
		'setVmDeploymentOrder'
		# 'setOwner'
# experimental parameters
		'monitorRG'
		'setVmTipGroup'
		'setGroupTipSession'
		'generalizedVMs'
		'generalizedUser'
		'generalizedPasswd'
		'diagSettingsPub'
		'diagSettingsProt'
		'diagSettingsContainer'
		'diagSettingsSA'
	)

	if ($justCopyBlobs.count -ne 0) {
		# required steps:
		$script:skipArmTemplate		= $True
		$script:skipSnapshots		= $True
		$script:skipDeployment 		= $True
		$script:skipCleanup			= $True
		
		# required settings:
		$script:useBlobCopy			= $True
		$script:useSnapshotCopy		= $False

		write-logFileForbidden 'justCopyBlobs' $forbidden
		write-logFileForbidden 'justCopyBlobs' @(
			# 'justCopyBlobs'
			'justCopySnapshots'
			'justCopyDisks'

			'useSnapshotCopy'
		)
	}


	elseif ($justCopySnapshots.count -ne 0) {
		# required steps:
		$script:skipArmTemplate		= $True
		$script:skipSnapshots		= $True
		$script:skipDeployment 		= $True
		$script:skipCleanup			= $True

		# required settings:
		$script:useBlobCopy			= $False
		$script:useSnapshotCopy		= $True

		write-logFileForbidden 'justCopySnapshots' $forbidden
		write-logFileForbidden 'justCopySnapshots' @(
			'justCopyBlobs'
			# 'justCopySnapshots'
			'justCopyDisks'

			'useBlobCopy'
		)
	}


	elseif ($justCopyDisks.count -ne 0) {
		# required steps:
		$script:skipArmTemplate		= $True
		# $script:skipSnapshots		= $True
		$script:skipDeployment 		= $True

		# required settings:
		$script:createDisksManually	= $True

		write-logFileForbidden 'justCopyDisks' $forbidden
		write-logFileForbidden 'justCopyDisks' @(
			'justCopyBlobs'
			'justCopySnapshots'
			# 'justCopyDisks'
		)
	}
}

#--------------------------------------------------------------
function test-restartRemoteCopy {
#--------------------------------------------------------------
	if (!$restartRemoteCopy) {
		return
	}

	# required steps:
	$script:skipSnapshots		= $True

	# forbidden parameters:
	write-logFileForbidden 'restartRemoteCopy' @(
		'skipRemoteCopy'
		)
}

#--------------------------------------------------------------
function test-stopRestore {
#--------------------------------------------------------------
	# parameter continueRestore (skip everything until deployment)
	if ($continueRestore) {

		# required steps:
		$script:skipArmTemplate		= $True
		$script:skipSnapshots		= $True
		$script:skipBackups			= $True
		$script:skipRemoteCopy		= $True
		$script:skipDeploymentVMs	= $True

		# forbidden parameters:
		write-logFileForbidden 'continueRestore' @(
			'stopRestore'
			'restartRemoteCopy'
			'justCopyBlobs'
			'justCopySnapshots'
			'justCopyDisks'
			'justStopCopyBlobs'
			)
	}
	# parameter stopRestore (skip everything after deployment)
	elseif ($stopRestore) {

		# required steps:
		$script:skipRestore			= $True
		$script:skipExtensions		= $True
		$script:skipCleanup			= $True

		# forbidden parameters:
		write-logFileForbidden 'stopRestore' @(
			'continueRestore'
			'restartRemoteCopy'
			'justCopyBlobs'
			'justCopySnapshots'
			'justCopyDisks'
			'justStopCopyBlobs'
			'startWorkload'
			'deleteSourceSA'
			)
	}
}

#--------------------------------------------------------------
function test-mergeMode {
#--------------------------------------------------------------
	if (!$mergeMode) {
		return
	}

	# required settings:
	$script:allowExistingDisks			= $True
	$script:skipDefaultValues			= $True
	$script:useBicep 					= $True
	$script:ignoreTags 					= $True
	$script:keepTags 					= '*'
	$script:setPrivateIpAlloc 			= 'Dynamic'
	$script:setAcceleratedNetworking 	= $True

	$script:renameDisks 				= $True

	$forbidden = @(
# general parameters
		# 'simulate'
		# 'pathExportFolder'
		# 'hostPlainText'
		'maxDOP'
		# 'verboseLog'
# error handling		
		# 'skipVmChecks'
		# 'forceVmChecks'
		# 'skipRemoteReferences'
		# 'skipWorkarounds'
		# 'useNewVmSizes'
# RG parameters
		# 'sourceRG'
		# 'targetRG'
		# 'targetLocation'
		'targetSA'
		'sourceSA'
		# 'sourceSub'
		# 'sourceSubUser'
		# 'sourceSubTenant'
		# 'targetSub'
		# 'targetSubUser'
		# 'targetSubTenant'
# operation steps
		'skipArmTemplate'
		#   'skipSnapshots'
		# 'stopVMsSourceRG'
		'skipBackups'
		'skipRemoteCopy'
		'skipDeployment'
		  'skipDeploymentVMs'
		  'skipRestore'
		    'stopRestore'
		    'continueRestore'
		  'skipExtensions'
		'startWorkload'
		'stopVMsTargetRG'
		# 'deleteSnapshots'
		'deleteSourceSA'
# operation modes
		'justCreateSnapshots'
		'justDeleteSnapshots'
# Clone Mode
		'cloneMode'
		'cloneNumber'
		'cloneVMs'
		# 'attachVmssFlex'
		# 'attachAvailabilitySet'
		# 'attachProximityPlacementGroup'
# Merge Mode
		# 'mergeMode'
		# 'setVmMerge'
		# 'setVmName'
		'renameDisks'
		'allowExistingDisks'
# Update Mode
		'updateMode'
		'deleteSnapshotsAll'
		'createBastion'
		'deleteBastion'
# Patch Mode
		'patchMode'
		'patchVMs'
		'patchKernel'
		'patchAll'
		'prePatchCommand'
		'skipPatch'
		# 'forceExtensions'
		# 'skipExtensions'
		# 'autoUpgradeExtensions'
# Archive Mode
		'archiveMode'
		'archiveContainer'
		'archiveContainerOverwrite'
# Copy Mode
		'swapSnapshot4disk'
		'swapDisk4disk'
		'pathArmTemplate'
		'pathArmTemplateDisks'
		'ignoreTags'
		'copyDetachedDisks'
		'jumpboxName'
		'skipDefaultValues'
		'defaultDiskZone'
		'defaultDiskName'
# BLOB copy
		'restartRemoteCopy'
		'justCopyBlobs'
		'justCopySnapshots'
		'justCopyDisks'
		'justStopCopyBlobs'
		# 'useBlobCopy'
		# 'useSnapshotCopy'
		'blobsSA'
		'blobsRG'
		'blobsSaContainer'
		'grantTokenTimeSec'
# scripts
		'skipStartSAP'
		'pathPreSnapshotScript'
		'pathPostDeploymentScript'
		'scriptStartSapPath'
		'scriptStartLoadPath'
		'scriptStartAnalysisPath'
		'vmStartWaitSec'
		'preSnapshotWaitSec'
		'vmAgentWaitMinutes'
# VM extensions
		'installExtensionsSapMonitor'
# Azure NetApp Files
		'createVolumes'
		'createDisks'
		'skipDisks'
		'snapshotVolumes'
		'netAppServiceLevel'
		'netAppAccountName'
		'netAppPoolName'
		'netAppPoolGB'
		'netAppMovePool'
		'netAppMoveForce'
		'netAppSubnet'
		'createDisksTier'
# get resources
		# 'allowRunningVMs'
		'skipGreenlist'
		'useBicep'
# skip resources
		'skipVMs'
		'skipSecurityRules'
		'keepTags'
		'skipVmssFlex'
		'skipAvailabilitySet'
		'skipProximityPlacementGroup'
		'skipBastion'
		# 'skipBootDiagnostics'
# configure resources
		# 'setVmSize'
		# 'setDiskSize'
		# 'setDiskTier'
		# 'setDiskBursting'
		# 'setDiskIOps'
		# 'setDiskMBps'
		# 'setDiskMaxShares'
		# 'setDiskCaching'
		# 'setDiskSku'
		# 'setVmZone'
		# 'setVmFaultDomain'
		'setPrivateIpAlloc'
		'removeFQDN'
		'setAcceleratedNetworking'
# create resources
		'createVmssFlex'
		'singlePlacementGroup'
		'createAvailabilitySet'
		'createProximityPlacementGroup'
# deploy resources
		# 'setVmDeploymentOrder'
		'setOwner'
# experimental parameters
		'monitorRG'
		'setVmTipGroup'
		'setGroupTipSession'
		'generalizedVMs'
		'generalizedUser'
		'generalizedPasswd'
		'diagSettingsPub'
		'diagSettingsProt'
		'diagSettingsContainer'
		'diagSettingsSA'
	)

	write-logFileForbidden 'mergeMode' $forbidden
}

#--------------------------------------------------------------
function test-cloneMode {
#--------------------------------------------------------------
	if (!$cloneMode) {
		return
	}

	# required settings:
	$script:allowExistingDisks			= $True
	$script:skipDefaultValues			= $True
	$script:useBicep 					= $True
	$script:ignoreTags 					= $True
	$script:keepTags 					= '*'
	$script:setPrivateIpAlloc 			= 'Dynamic'
	$script:setAcceleratedNetworking 	= $True

	$script:removeFQDN					= $True

	$forbidden = @(
# general parameters
		# 'simulate'
		# 'pathExportFolder'
		# 'hostPlainText'
		'maxDOP'
		# 'verboseLog'
# error handling		
		# 'skipVmChecks'
		# 'forceVmChecks'
		# 'skipRemoteReferences'
		# 'skipWorkarounds'
		# 'useNewVmSizes'
# RG parameters
		# 'sourceRG'
		'targetRG'
		'targetLocation'
		'targetSA'
		'sourceSA'
		# 'sourceSub'
		# 'sourceSubUser'
		# 'sourceSubTenant'
		'targetSub'
		'targetSubUser'
		'targetSubTenant'
# operation steps
		'skipArmTemplate'
		#   'skipSnapshots'
		# 'stopVMsSourceRG'
		'skipBackups'
		'skipRemoteCopy'
		'skipDeployment'
		  'skipDeploymentVMs'
		  'skipRestore'
		    'stopRestore'
		    'continueRestore'
		  'skipExtensions'
		'startWorkload'
		'stopVMsTargetRG'
		# 'deleteSnapshots'
		'deleteSourceSA'
# operation modes
		'justCreateSnapshots'
		'justDeleteSnapshots'
# Clone Mode
		# 'cloneMode'
		# 'cloneNumber'
		# 'cloneVMs'
		# 'attachVmssFlex'
		# 'attachAvailabilitySet'
		# 'attachProximityPlacementGroup'
# Merge Mode
		'mergeMode'
		'setVmMerge'
		# 'setVmName'
		# 'renameDisks'
		'allowExistingDisks'
# Update Mode
		'updateMode'
		'deleteSnapshotsAll'
		'createBastion'
		'deleteBastion'
# Patch Mode
		'patchMode'
		'patchVMs'
		'patchKernel'
		'patchAll'
		'prePatchCommand'
		'skipPatch'
		# 'forceExtensions'
		# 'skipExtensions'
		# 'autoUpgradeExtensions'
# Archive Mode
		'archiveMode'
		'archiveContainer'
		'archiveContainerOverwrite'
# Copy Mode
		'swapSnapshot4disk'
		'swapDisk4disk'
		'pathArmTemplate'
		'pathArmTemplateDisks'
		'ignoreTags'
		'copyDetachedDisks'
		'jumpboxName'
		'skipDefaultValues'
		'defaultDiskZone'
		'defaultDiskName'
# BLOB copy
		'restartRemoteCopy'
		'justCopyBlobs'
		'justCopySnapshots'
		'justCopyDisks'
		'justStopCopyBlobs'
		'useBlobCopy'
		'useSnapshotCopy'
		'blobsSA'
		'blobsRG'
		'blobsSaContainer'
		'grantTokenTimeSec'
# scripts
		'skipStartSAP'
		'pathPreSnapshotScript'
		'pathPostDeploymentScript'
		'scriptStartSapPath'
		'scriptStartLoadPath'
		'scriptStartAnalysisPath'
		'vmStartWaitSec'
		'preSnapshotWaitSec'
		'vmAgentWaitMinutes'
# VM extensions
		'installExtensionsSapMonitor'
# Azure NetApp Files
		'createVolumes'
		'createDisks'
		'skipDisks'
		'snapshotVolumes'
		'netAppServiceLevel'
		'netAppAccountName'
		'netAppPoolName'
		'netAppPoolGB'
		'netAppMovePool'
		'netAppMoveForce'
		'netAppSubnet'
		'createDisksTier'
# get resources
		# 'allowRunningVMs'
		'skipGreenlist'
		'useBicep'
# skip resources
		'skipVMs'
		'skipSecurityRules'
		'keepTags'
		'skipVmssFlex'
		'skipAvailabilitySet'
		'skipProximityPlacementGroup'
		'skipBastion'
		# 'skipBootDiagnostics'
# configure resources
		# 'setVmSize'
		# 'setDiskSize'
		# 'setDiskTier'
		# 'setDiskBursting'
		# 'setDiskIOps'
		# 'setDiskMBps'
		'setDiskMaxShares'
		# 'setDiskCaching'
		# 'setDiskSku'
		# 'setVmZone'
		# 'setVmFaultDomain'
		'setPrivateIpAlloc'
		'removeFQDN'
		'setAcceleratedNetworking'
# create resources
		'createVmssFlex'
		'singlePlacementGroup'
		'createAvailabilitySet'
		'createProximityPlacementGroup'
# deploy resources
		# 'setVmDeploymentOrder'
		'setOwner'
# experimental parameters
		'monitorRG'
		'setVmTipGroup'
		'setGroupTipSession'
		'generalizedVMs'
		'generalizedUser'
		'generalizedPasswd'
		'diagSettingsPub'
		'diagSettingsProt'
		'diagSettingsContainer'
		'diagSettingsSA'
	)

	write-logFileForbidden 'cloneMode' $forbidden
}

#-------------------------------------------------------------
function test-archiveMode {
#-------------------------------------------------------------
	if (!$archiveMode) {
		return
	}

	if ('skipVMs' -in $boundParameterNames) {
		$script:copyDetachedDisks = $True
	}
	else {
		write-logFileWarning "parameter 'skipVMs' is set" `
								"some VMs and disks (including all detached disks) are not copied"
	}

	if ($archiveContainer -eq 'rgcopy') {
		write-logFileError "Invalid parameter 'archiveContainer'" `
							"Value 'rgcopy' not allowed for this parameter"
	}

	# required steps:
	$script:skipDeployment 		= $True
	
	# required settings:
	$script:useBlobCopy			= $True
	$script:blobsRG				= $targetRG
	$script:blobsSA				= $targetSA
	$script:blobsSaContainer	= $archiveContainer
	$script:targetSaContainer	= $archiveContainer
	$script:allowExistingDisks	= $True
	$script:ignoreTags			= $True
	$script:skipDefaultValues	= $True
	$script:keepTags 			= '*'

	$params = @(
		'skipArmTemplate'
		'skipSnapshots'
		'skipRemoteCopy'
	)
	foreach ($param in $params) {
		if ($param -in $boundParameterNames) {
			write-logFileWarning "parameter '$param' is set" `
								"You might not be able to restore the archived resource group"
		}
	}

	$forbidden = @(
# general parameters
		# 'simulate'
		# 'pathExportFolder'
		# 'hostPlainText'
		# 'maxDOP'
		# 'verboseLog'
# error handling		
		# 'skipVmChecks'
		# 'forceVmChecks'
		# 'skipRemoteReferences'
		# 'skipWorkarounds'
		# 'useNewVmSizes'
# RG parameters
		# 'sourceRG'
		# 'targetRG'
		# 'targetLocation'
		# 'targetSA'
		# 'sourceSA'
		# 'sourceSub'
		# 'sourceSubUser'
		# 'sourceSubTenant'
		# 'targetSub'
		# 'targetSubUser'
		# 'targetSubTenant'
# operation steps
		# 'skipArmTemplate'
		#   'skipSnapshots'
		# 'stopVMsSourceRG'
		'skipBackups'
		# 'skipRemoteCopy'
		'skipDeployment'
		  'skipDeploymentVMs'
		  'skipRestore'
		    'stopRestore'
		    'continueRestore'
		  'skipExtensions'
		'startWorkload'
		'stopVMsTargetRG'
		# 'deleteSnapshots'
		'deleteSourceSA'
# operation modes
		# 'justCreateSnapshots'
		# 'justDeleteSnapshots'
# Clone Mode
		'cloneMode'
		'cloneNumber'
		'cloneVMs'
		'attachVmssFlex'
		'attachAvailabilitySet'
		'attachProximityPlacementGroup'
# Merge Mode
		'mergeMode'
		'setVmMerge'
		# 'setVmName'
		# 'renameDisks'
		'allowExistingDisks'
# Update Mode
		'updateMode'
		'deleteSnapshotsAll'
		'createBastion'
		'deleteBastion'
# Patch Mode
		'patchMode'
		'patchVMs'
		'patchKernel'
		'patchAll'
		'prePatchCommand'
		'skipPatch'
		# 'forceExtensions'
		# 'skipExtensions'
		# 'autoUpgradeExtensions'
# Archive Mode
		# 'archiveMode'
		# 'archiveContainer'
		# 'archiveContainerOverwrite'
# Copy Mode
		'swapSnapshot4disk'
		'swapDisk4disk'
		'pathArmTemplate'
		'pathArmTemplateDisks'
		'ignoreTags'
		# 'copyDetachedDisks'
		'jumpboxName'
		'skipDefaultValues'
		'defaultDiskZone'
		'defaultDiskName'
# BLOB copy
		# 'restartRemoteCopy'
		# 'justCopyBlobs'
		'justCopySnapshots'
		'justCopyDisks'
		# 'justStopCopyBlobs'
		'useBlobCopy'
		'useSnapshotCopy'
		'blobsSA'
		'blobsRG'
		'blobsSaContainer'
		# 'grantTokenTimeSec'
# scripts
		'skipStartSAP'
		'pathPreSnapshotScript'
		'pathPostDeploymentScript'
		'scriptStartSapPath'
		'scriptStartLoadPath'
		'scriptStartAnalysisPath'
		'vmStartWaitSec'
		'preSnapshotWaitSec'
		'vmAgentWaitMinutes'
# VM extensions
		'installExtensionsSapMonitor'
# Azure NetApp Files
		'createVolumes'
		'createDisks'
		'skipDisks'
		'snapshotVolumes'
		'netAppServiceLevel'
		'netAppAccountName'
		'netAppPoolName'
		'netAppPoolGB'
		'netAppMovePool'
		'netAppMoveForce'
		'netAppSubnet'
		'createDisksTier'
# get resources
		# 'allowRunningVMs'
		# 'skipGreenlist'
		# 'useBicep'
# skip resources
		# 'skipVMs'
		# 'skipSecurityRules'
		'keepTags'
		# 'skipVmssFlex'
		# 'skipAvailabilitySet'
		# 'skipProximityPlacementGroup'
		# 'skipBastion'
		# 'skipBootDiagnostics'
# configure resources
		# 'setVmSize'
		# 'setDiskSize'
		# 'setDiskTier'
		# 'setDiskBursting'
		# 'setDiskIOps'
		# 'setDiskMBps'
		# 'setDiskMaxShares'
		# 'setDiskCaching'
		# 'setDiskSku'
		# 'setVmZone'
		# 'setVmFaultDomain'
		# 'setPrivateIpAlloc'
		# 'removeFQDN'
		# 'setAcceleratedNetworking'
# create resources
		# 'createVmssFlex'
		# 'singlePlacementGroup'
		# 'createAvailabilitySet'
		# 'createProximityPlacementGroup'
# deploy resources
		# 'setVmDeploymentOrder'
		'setOwner'
# experimental parameters
		'monitorRG'
		'setVmTipGroup'
		'setGroupTipSession'
		'generalizedVMs'
		'generalizedUser'
		'generalizedPasswd'
		'diagSettingsPub'
		'diagSettingsProt'
		'diagSettingsContainer'
		'diagSettingsSA'
	)

	write-logFileForbidden 'archiveMode' $forbidden
}

#-------------------------------------------------------------
function test-updateMode {
#-------------------------------------------------------------
if (!$updateMode) {
	return
}

	$forbidden = @(
# general parameters
		# 'simulate'
		'pathExportFolder'
		# 'hostPlainText'
		'maxDOP'
		# 'verboseLog'
# error handling		
		# 'skipVmChecks'
		# 'forceVmChecks'
		'skipRemoteReferences'
		'skipWorkarounds'
		# 'useNewVmSizes'
# RG parameters
		# 'sourceRG'
		'targetRG'
		'targetLocation'
		'targetSA'
		'sourceSA'
		# 'sourceSub'
		# 'sourceSubUser'
		# 'sourceSubTenant'
		'targetSub'
		'targetSubUser'
		'targetSubTenant'
# operation steps
		'skipArmTemplate'
		  'skipSnapshots'
		# 'stopVMsSourceRG'
		'skipBackups'
		'skipRemoteCopy'
		'skipDeployment'
		  'skipDeploymentVMs'
		  'skipRestore'
		    'stopRestore'
		    'continueRestore'
		  'skipExtensions'
		'startWorkload'
		'stopVMsTargetRG'
		# 'deleteSnapshots'
		'deleteSourceSA'
# operation modes
		'justCreateSnapshots'
		'justDeleteSnapshots'
# Clone Mode
		'cloneMode'
		'cloneNumber'
		'cloneVMs'
		'attachVmssFlex'
		'attachAvailabilitySet'
		'attachProximityPlacementGroup'
# Merge Mode
		'mergeMode'
		'setVmMerge'
		'setVmName'
		'renameDisks'
		'allowExistingDisks'
# Update Mode
		# 'updateMode'
		# 'deleteSnapshotsAll'
		# 'createBastion'
		# 'deleteBastion'
# Patch Mode
		'patchMode'
		'patchVMs'
		'patchKernel'
		'patchAll'
		'prePatchCommand'
		'skipPatch'
		'forceExtensions'
		'skipExtensions'
		'autoUpgradeExtensions'
# Archive Mode
		'archiveMode'
		'archiveContainer'
		'archiveContainerOverwrite'
# Copy Mode
		'swapSnapshot4disk'
		'swapDisk4disk'
		'pathArmTemplate'
		'pathArmTemplateDisks'
		'ignoreTags'
		'copyDetachedDisks'
		'jumpboxName'
		# 'skipDefaultValues'
		'defaultDiskZone'
		'defaultDiskName'
# BLOB copy
		'restartRemoteCopy'
		'justCopyBlobs'
		'justCopySnapshots'
		'justCopyDisks'
		'justStopCopyBlobs'
		'useBlobCopy'
		'useSnapshotCopy'
		'blobsSA'
		'blobsRG'
		'blobsSaContainer'
		'grantTokenTimeSec'
# scripts
		'skipStartSAP'
		'pathPreSnapshotScript'
		'pathPostDeploymentScript'
		'scriptStartSapPath'
		'scriptStartLoadPath'
		'scriptStartAnalysisPath'
		'vmStartWaitSec'
		'preSnapshotWaitSec'
		'vmAgentWaitMinutes'
# VM extensions
		'installExtensionsSapMonitor'
# Azure NetApp Files
		'createVolumes'
		'createDisks'
		'skipDisks'
		'snapshotVolumes'
		# 'netAppServiceLevel'
		# 'netAppAccountName'		# ?
		# 'netAppPoolName'
		# 'netAppPoolGB'			# ?
		# 'netAppMovePool'
		# 'netAppMoveForce'
		# 'netAppSubnet'			# ?
		'createDisksTier'
# get resources
		'allowRunningVMs'
		'skipGreenlist'
		'useBicep'
# skip resources
		'skipVMs'
		'skipSecurityRules'
		'keepTags'
		'skipVmssFlex'
		'skipAvailabilitySet'
		'skipProximityPlacementGroup'
		'skipBastion'
		'skipBootDiagnostics'
# configure resources
		# 'setVmSize'
		# 'setDiskSize'
		# 'setDiskTier'
		# 'setDiskBursting'
		# 'setDiskIOps'
		# 'setDiskMBps'
		# 'setDiskMaxShares'
		# 'setDiskCaching'
		# 'setDiskSku'
		'setVmZone'
		'setVmFaultDomain'
		'setPrivateIpAlloc'
		'removeFQDN'
		# 'setAcceleratedNetworking'
# create resources
		'createVmssFlex'
		'singlePlacementGroup'
		'createAvailabilitySet'
		'createProximityPlacementGroup'
# deploy resources
		'setVmDeploymentOrder'
		'setOwner'
# experimental parameters
		'monitorRG'
		'setVmTipGroup'
		'setGroupTipSession'
		'generalizedVMs'
		'generalizedUser'
		'generalizedPasswd'
		'diagSettingsPub'
		'diagSettingsProt'
		'diagSettingsContainer'
		'diagSettingsSA'
	)

	write-logFileForbidden 'updateMode' $forbidden
}

#-------------------------------------------------------------
function test-patchMode {
#-------------------------------------------------------------
if (!$patchMode) {
	return
}

	# required settings:
	$script:ignoreTags			= $True

	$forbidden = @(
# general parameters
		# 'simulate'
		'pathExportFolder'
		# 'hostPlainText'
		'maxDOP'
		# 'verboseLog'
# error handling		
		# 'skipVmChecks'
		'forceVmChecks'
		'skipRemoteReferences'
		'skipWorkarounds'
		'useNewVmSizes'
# RG parameters
		# 'sourceRG'
		'targetRG'
		'targetLocation'
		'targetSA'
		'sourceSA'
		# 'sourceSub'
		# 'sourceSubUser'
		# 'sourceSubTenant'
		'targetSub'
		'targetSubUser'
		'targetSubTenant'
# operation steps
		'skipArmTemplate'
		'skipSnapshots'
		# 'stopVMsSourceRG'
		'skipBackups'
		'skipRemoteCopy'
		'skipDeployment'
		'skipDeploymentVMs'
		'skipRestore'
		'stopRestore'
		'continueRestore'
		# 'skipExtensions'
		'startWorkload'
		'stopVMsTargetRG'
		'deleteSnapshots'
		'deleteSourceSA'
# operation modes
		'justCreateSnapshots'
		'justDeleteSnapshots'
# Clone Mode
		'cloneMode'
		'cloneNumber'
		'cloneVMs'
		'attachVmssFlex'
		'attachAvailabilitySet'
		'attachProximityPlacementGroup'
# Merge Mode
		'mergeMode'
		'setVmMerge'
		'setVmName'
		'renameDisks'
		'allowExistingDisks'
# Update Mode
		'updateMode'
		'deleteSnapshotsAll'
		'createBastion'
		'deleteBastion'
# Patch Mode
		# 'patchMode'
		# 'patchVMs'
		# 'patchKernel'
		# 'patchAll'
		# 'prePatchCommand'
		# 'skipPatch'
		# 'forceExtensions'
		# 'skipExtensions'
		# 'autoUpgradeExtensions'
# Archive Mode
		'archiveMode'
		'archiveContainer'
		'archiveContainerOverwrite'
# Copy Mode
		'swapSnapshot4disk'
		'swapDisk4disk'
		'pathArmTemplate'
		'pathArmTemplateDisks'
		'ignoreTags'
		'copyDetachedDisks'
		'jumpboxName'
		'skipDefaultValues'
		'defaultDiskZone'
		'defaultDiskName'
# BLOB copy
		'restartRemoteCopy'
		'justCopyBlobs'
		'justCopySnapshots'
		'justCopyDisks'
		'justStopCopyBlobs'
		'useBlobCopy'
		'useSnapshotCopy'
		'blobsSA'
		'blobsRG'
		'blobsSaContainer'
		'grantTokenTimeSec'
# scripts
		'skipStartSAP'
		'pathPreSnapshotScript'
		'pathPostDeploymentScript'
		'scriptStartSapPath'
		'scriptStartLoadPath'
		'scriptStartAnalysisPath'
		'vmStartWaitSec'
		'preSnapshotWaitSec'
		# 'vmAgentWaitMinutes'
# VM extensions
		'installExtensionsSapMonitor'
# Azure NetApp Files
		'createVolumes'
		'createDisks'
		'skipDisks'
		'snapshotVolumes'
		'netAppServiceLevel'
		'netAppAccountName'		# ?
		'netAppPoolName'
		'netAppPoolGB'			# ?
		'netAppMovePool'
		'netAppMoveForce'
		'netAppSubnet'			# ?
		'createDisksTier'
# get resources
		'allowRunningVMs'
		'skipGreenlist'
		'useBicep'
# skip resources
		# 'skipVMs'
		'skipSecurityRules'
		'keepTags'
		'skipVmssFlex'
		'skipAvailabilitySet'
		'skipProximityPlacementGroup'
		'skipBastion'
		'skipBootDiagnostics'
# configure resources
		'setVmSize'
		'setDiskSize'
		'setDiskTier'
		'setDiskBursting'
		'setDiskIOps'
		'setDiskMBps'
		'setDiskMaxShares'
		'setDiskCaching'
		'setDiskSku'
		'setVmZone'
		'setVmFaultDomain'
		'setPrivateIpAlloc'
		'removeFQDN'
		'setAcceleratedNetworking'
# create resources
		'createVmssFlex'
		'singlePlacementGroup'
		'createAvailabilitySet'
		'createProximityPlacementGroup'
# deploy resources
		'setVmDeploymentOrder'
		'setOwner'
# experimental parameters
		'monitorRG'
		'setVmTipGroup'
		'setGroupTipSession'
		'generalizedVMs'
		'generalizedUser'
		'generalizedPasswd'
		'diagSettingsPub'
		'diagSettingsProt'
		'diagSettingsContainer'
		'diagSettingsSA'
	)

	write-logFileForbidden 'patchMode' $forbidden
}

#-------------------------------------------------------------
function test-copyMode {
#-------------------------------------------------------------
	if (!$copyMode) {
		return
	}

	$forbidden = @(
# general parameters
		# 'simulate'
		# 'pathExportFolder'
		# 'hostPlainText'
		# 'maxDOP'
		# 'verboseLog'
# error handling		
		# 'skipVmChecks'
		# 'forceVmChecks'
		# 'skipRemoteReferences'
		# 'skipWorkarounds'
		# 'useNewVmSizes'
# RG parameters
		# 'sourceRG'
		# 'targetRG'
		# 'targetLocation'
		# 'targetSA'
		# 'sourceSA'
		# 'sourceSub'
		# 'sourceSubUser'
		# 'sourceSubTenant'
		# 'targetSub'
		# 'targetSubUser'
		# 'targetSubTenant'
# operation steps
		# 'skipArmTemplate'
		#   'skipSnapshots'
		# 'stopVMsSourceRG'
		# 'skipBackups'
		# 'skipRemoteCopy'
		# 'skipDeployment'
		#   'skipDeploymentVMs'
		#   'skipRestore'
		    # 'stopRestore'
		    # 'continueRestore'
		#   'skipExtensions'
		# 'startWorkload'
		# 'stopVMsTargetRG'
		# 'deleteSnapshots'
		# 'deleteSourceSA'
# operation modes
		# 'justCreateSnapshots'
		# 'justDeleteSnapshots'
# Clone Mode
		'cloneMode'
		'cloneNumber'
		'cloneVMs'
		'attachVmssFlex'
		'attachAvailabilitySet'
		'attachProximityPlacementGroup'
# Merge Mode
		'mergeMode'
		'setVmMerge'
		# 'setVmName'
		# 'renameDisks'
		# 'allowExistingDisks'
# Update Mode
		'updateMode'
		'deleteSnapshotsAll'
		'createBastion'
		'deleteBastion'
# Patch Mode
		'patchMode'
		'patchVMs'
		'patchKernel'
		'patchAll'
		'prePatchCommand'
		'skipPatch'
		# 'forceExtensions'
		# 'skipExtensions'
		# 'autoUpgradeExtensions'
# Archive Mode
		'archiveMode'
		'archiveContainer'
		'archiveContainerOverwrite'
# Copy Mode
		# 'swapSnapshot4disk'
		# 'swapDisk4disk'
		# 'pathArmTemplate'
		# 'pathArmTemplateDisks'
		# 'ignoreTags'
		# 'copyDetachedDisks'
		# 'jumpboxName'
		# 'skipDefaultValues'
		# 'defaultDiskZone'
		# 'defaultDiskName'
# BLOB copy
		# 'restartRemoteCopy'
		# 'justCopyBlobs'
		# 'justCopySnapshots'
		# 'justCopyDisks'
		# 'justStopCopyBlobs'
		# 'useBlobCopy'
		# 'useSnapshotCopy'
		# 'blobsSA'
		# 'blobsRG'
		# 'blobsSaContainer'
		# 'grantTokenTimeSec'
# scripts
		# 'skipStartSAP'
		# 'pathPreSnapshotScript'
		# 'pathPostDeploymentScript'
		# 'scriptStartSapPath'
		# 'scriptStartLoadPath'
		# 'scriptStartAnalysisPath'
		# 'vmStartWaitSec'
		# 'preSnapshotWaitSec'
		# 'vmAgentWaitMinutes'
# VM extensions
		# 'installExtensionsSapMonitor'
# Azure NetApp Files
		# 'createVolumes'
		# 'createDisks'
		# 'skipDisks'
		# 'snapshotVolumes'
		# 'netAppServiceLevel'
		# 'netAppAccountName'
		# 'netAppPoolName'
		# 'netAppPoolGB'
		# 'netAppMovePool'
		# 'netAppMoveForce'
		# 'netAppSubnet'
		# 'createDisksTier'
# get resources
		# 'allowRunningVMs'
		# 'skipGreenlist'
		# 'useBicep'
# skip resources
		# 'skipVMs'
		# 'skipSecurityRules'
		# 'keepTags'
		# 'skipVmssFlex'
		# 'skipAvailabilitySet'
		# 'skipProximityPlacementGroup'
		# 'skipBastion'
		# 'skipBootDiagnostics'
# configure resources
		# 'setVmSize'
		# 'setDiskSize'
		# 'setDiskTier'
		# 'setDiskBursting'
		# 'setDiskIOps'
		# 'setDiskMBps'
		# 'setDiskMaxShares'
		# 'setDiskCaching'
		# 'setDiskSku'
		# 'setVmZone'
		# 'setVmFaultDomain'
		# 'setPrivateIpAlloc'
		# 'removeFQDN'
		# 'setAcceleratedNetworking'
# create resources
		# 'createVmssFlex'
		# 'singlePlacementGroup'
		# 'createAvailabilitySet'
		# 'createProximityPlacementGroup'
# deploy resources
		# 'setVmDeploymentOrder'
		# 'setOwner'
# experimental parameters
		# 'monitorRG'
		# 'setVmTipGroup'
		# 'setGroupTipSession'
		# 'generalizedVMs'
		# 'generalizedUser'
		# 'generalizedPasswd'
		# 'diagSettingsPub'
		# 'diagSettingsProt'
		# 'diagSettingsContainer'
		# 'diagSettingsSA'
	)
	write-logFileForbidden 'copyMode' $forbidden
}

#-------------------------------------------------------------
function update-paramDeleteSnapshots {
#-------------------------------------------------------------
	$snapshotsAll = Get-AzSnapshot `
						-ResourceGroupName $sourceRG `
						-ErrorAction 'SilentlyContinue'
	test-cmdlet 'Get-AzSnapshot'  "Could not get snapshots of resource group $sourceRG" 

	if ($deleteSnapshotsAll) {
		$script:snapshots2remove = $snapshotsAll
	}
	elseif ($deleteSnapshots) {
		$script:snapshots2remove = $snapshotsAll | Where-Object Name -in $script:copyDisks.values.SnapshotName
	}

	foreach ($snap in $snapshotsAll) {
		if ($snap.Name -in $script:snapshots2remove.Name) {
			write-logFileUpdates 'snapshot' $snap.Name 'delete'
		}
		else {
			write-logFileUpdates 'snapshot' $snap.Name 'keep'
		}
	}
}

#-------------------------------------------------------------
function update-paramCreateBastion {
#-------------------------------------------------------------
	# get bastion
	$script:sourceBastion = Get-AzBastion `
								-ResourceGroupName	$sourceRG `
								-ErrorAction		'SilentlyContinue'
	test-cmdlet 'Get-AzBastion'  "Could not get Bastion of resource group '$sourceRG'"

	# bastion already exists
	if ($Null -ne $script:sourceBastion) {
		$bastionName = $script:sourceBastion.Name
		if ($createBastion.length -ne 0) {
			$script:createBastion = $Null
			write-logFileWarning "Parameter 'createBastion' ignored. Bastion '$bastionName' already exists"
		}
		# delete bastion
		if ($deleteBastion) {
			write-logFileUpdates 'bastion' $bastionName 'delete'
		}
		# keep bastion
		else {
			write-logFileUpdates 'bastion' $bastionName 'keep'
		}
	}

	# create bastion
	elseif ($createBastion.length -ne 0) {

		$script:bastionVnet, $subnetName, $script:bastionAddressPrefix = test-subnet 'createBastion' $createBastion 'AzureBastionSubnet'
		write-logFileUpdates 'bastion' 'bastion' 'create'
	}
}

#-------------------------------------------------------------
function update-parameterNetAppServiceLevel {
#-------------------------------------------------------------
	$script:allMoves = @{}
	
	# collect all accounts
	$allVolumes			= @()
	$allPoolNames		= @()
	$allPoolNamesLong	= @()
	$allAccounts = Get-AzNetAppFilesAccount `
					-ResourceGroupName	$sourceRG `
					-ErrorAction 		'SilentlyContinue'
	test-cmdlet 'Get-AzNetAppFilesAccount'  "Could not get NetApp Accounts of resource group '$sourceRG'"

	foreach ($account in $allAccounts) {
		$accountName = $account.Name

		# collect all pool (names)
		$pools = Get-AzNetAppFilesPool `
					-ResourceGroupName	$sourceRG `
					-AccountName		$accountName `
					-ErrorAction 		'SilentlyContinue'
		test-cmdlet 'Get-AzNetAppFilesPool'  "Could not get NetApp Pools of account '$accountName'"

		foreach ($pool in $pools) {
			$accountName, $poolName = $pool.Name -split '/'
			$allPoolNames += $poolName
			$allPoolNamesLong += $pool.Name

			# collect all volumes
			$volumes = Get-AzNetAppFilesVolume `
						-ResourceGroupName	$sourceRG `
						-AccountName		$accountName `
						-PoolName			$poolName `
						-ErrorAction 		'SilentlyContinue'
			test-cmdlet 'Get-AzNetAppFilesVolume'  "Could not get NetApp Volumes of pool '$poolName'"
			
			if ($volumes.count -ne 0) {
				$allVolumes += $volumes
			}
		}
	}

	# check parameter
	if (($netAppMovePool.length -ne 0) -and ($netAppMovePool -notin $allPoolNamesLong)) {
		write-logFileError "Invalid parameter 'netAppMovePool'" `
							"Pool '$netAppMovePool' not found" `
							'Parameter format: <account>/<pool>'
	}

	# get Service Level for each volume
	foreach ($volume in $allVolumes) {
		$volumeNameLong	= $volume.Name 
		$accountName, $poolName, $volumeName = $volumeNameLong -split '/'
		$poolNameLong	= "$accountName/$poolName"
		$serviceLevel	= $volume.ServiceLevel
		$location		= $volume.Location
		$size			= $volume.UsageThreshold
		$sizeGB 		= '{0:f0} GiB' -f ($size / 1024 / 1024 /1024)

		# only process given pool
		if (($netAppMovePool.length -ne 0) -and ($netAppMovePool -ne $poolNameLong)) {
			write-logFileUpdates 'NetAppVolume' "$poolName/$volumeName" 'keep Service Level' $serviceLevel ' ' $sizeGB
			continue
		}
		
		if ( (!$netAppMoveForce) `
		-and (($serviceLevel -eq $netAppServiceLevel) -or ('netAppServiceLevel' -notin $boundParameterNames))) {
			write-logFileUpdates 'NetAppVolume' "$poolName/$volumeName" 'keep Service Level' $serviceLevel ' ' $sizeGB
		}
		else {
			write-logFileUpdates 'NetAppVolume' "$poolName/$volumeName" 'set Service Level' $netAppServiceLevel ' ' $sizeGB

			# collect new pools
			if ($Null -eq $script:allMoves[$poolNameLong]) {

				# get postfix for new pool name
				$postfix = $poolName -replace '^rgcopy-\w\d*-', ''
				if ($postfix.length -eq 0) {
					$postfix = 'pool'
				}
				if ('netAppPoolName' -in $boundParameterNames) {
					$postfix = $netAppPoolName
				}

				# get full name for new pool
				$i = 0
				do {
					$i++
					$newPoolName = "rgcopy-$($netAppServiceLevel.ToLower()[0])$i-$postfix"
					# truncate name
					$len = (128, $newPoolName.Length | Measure-Object -Minimum).Minimum
					$newPoolName = $newPoolName.SubString(0,$len)
				} until ($newPoolName -notin $allPoolNames)
				
				if (('netAppMovePool' -in $boundParameterNames) -and ('netAppPoolName' -in $boundParameterNames)) {
					$newPoolName = $netAppPoolName
					if ($newPoolName -in $allPoolNames) {
						write-logFileError "Invalid parameter 'netAppPoolName'" `
											"Pool '$netAppPoolName' already exists"
					}
				}
				
				$allPoolNames += $newPoolName

				# save requirements  for new pool
				$script:allMoves[$poolNameLong] = @{
					accountName		= $accountName
					newPoolName		= $newPoolName
					oldPoolName		= $poolName
					serviceLevel	= $netAppServiceLevel
					location		= $location
					size			= $size
					volumes			= @($volumeNameLong)
					deleteOldPool	= $False
				}
			}
			else {
				# add requirements for new pool
				$script:allMoves[$poolNameLong].volumes += $volumeNameLong
				$script:allMoves[$poolNameLong].size += $size
			}
		}
	}

	if ($script:allMoves.Values.count -ne 0) {
		write-logFile
		write-logFile "NetApp volume move steps in detail:"
	}

	# output of new pools
	$script:allMoves.Values
	| Sort-Object size
	| ForEach-Object {

		# minimal size of pool
		if ($_.size -lt $netAppPoolSizeMinimum) {
			$_.size = $netAppPoolSizeMinimum
		}

		# create pool
		$sizeGB = '{0:f0} GiB' -f ($_.size / 1024 / 1024 /1024)
		write-logFileUpdates 'NetAppPool' "$($_.accountName)/$($_.newPoolName)" 'create with size' $sizeGB

		# move volumes
		foreach ($volumeNameLong in $_.volumes) {
			$accountName, $poolName, $volumeName = $volumeNameLong -split '/'
			write-logFileUpdates 'NetAppVolume' "$poolName/$volumeName" 'move to pool' $_.newPoolName
		}

		# check old pool
		$like = "$($_.accountName)/$($_.oldPoolName)/*"
		$numVolumesExist = (convertTo-array ($allVolumes.Name | Where-Object {$_ -like $like})).count
		$numVolumesMove  = (convertTo-array ($_.volumes       | Where-Object {$_ -like $like})).count
		if ($numVolumesExist -eq $numVolumesMove) {
			$_.deleteOldPool = $True
			write-logFileUpdates 'NetAppPool' "$($_.accountName)/$($_.oldPoolName)" 'delete pool'
		}
	}
}

#-------------------------------------------------------------
function step-updateMode {
#-------------------------------------------------------------
	write-stepStart "Expected changes in resource group '$sourceRG'"
	# process resource parameters
	# required order:
	# 1. setVmSize
	# 2. setDiskSku
	# 3. setDiskSize (and setDiskTier)
	# 4. setDiskCaching
	# 5. setAcceleratedNetworking
	update-paramAll

	# 6. rest
	update-paramCreateBastion
	update-paramDeleteSnapshots

	if ($Null -ne $azAnfVersionString) {
		update-parameterNetAppServiceLevel
	}
	else {
		write-logFileWarning "Step 'NetApp volumes' skipped because module 'Az.NetAppFiles' is not installed"
	}

	update-diskZone
	compare-quota
	write-stepEnd

	# check for running VMs (except for Bastion and snapshots)
	if ((!$stopVMsSourceRG) `
	-and (	('setVmSize' -in $boundParameterNames) `
		-or ('setDiskSku' -in $boundParameterNames) `
		-or ('setDiskBursting' -in $boundParameterNames) `
		-or ('setDiskMaxShares' -in $boundParameterNames) `
		-or ('setDiskCaching' -in $boundParameterNames) `
		-or ('setAcceleratedNetworking' -in $boundParameterNames) `
		-or ('netAppServiceLevel' -in $boundParameterNames) `
	)) {

		$script:copyVMs.Values
		| ForEach-Object {
		
			if ($_.VmStatus -ne 'VM deallocated') {
				if ($simulate) { 
					write-logFileWarning "VM '$($_.Name)' is running"
				}
				else {
					write-logFileError "VM '$($_.Name)' is running" `
										"Parameter 'updateMode' can only be used when all VMs are stopped" `
										"Use parameter 'stopVMsSourceRG' for stopping all VMs"
				}
			}
		}
	}

	if ($simulate) { 
		write-logFileWarning "Nothing updated because parameter 'simulate' was set"
	}
	else {
		# stop VMs
		if ($stopVMsSourceRG) {
			stop-VMs $sourceRG $script:sourceVMs
		}

		write-stepStart "Updating resource group '$sourceRG'"

		write-logFile "Step Pre VM-update:"
		update-sourceDisks -beforeVmUpdate
		update-sourceNICs -beforeVmUpdate

		write-logFile
		write-logFile "Step VM-update:"
		update-sourceVMs

		write-logFile
		write-logFile "Step Post VM-update:"
		update-sourceDisks
		update-sourceNICs

		write-logFile
		update-sourceBastion
		write-logFile

		if ($Null -ne $azAnfVersionString) {
			update-netAppServiceLevel
		}

		if ($script:snapshots2remove.count -eq 0) {
			write-logFile
			write-LogFile 'Step Snapshots: Nothing to do'
		}
		write-stepEnd
	
		# remove snapshots
		if ($script:snapshots2remove.count -ne 0) {
			remove-snapshots $sourceRG $script:snapshots2remove.Name
		}
	}
}

#-------------------------------------------------------------
function update-netAppServiceLevel {
#-------------------------------------------------------------
	if ($script:allMoves.Values.count -eq 0) {
		write-logFile 'Step NetApp volumes: Nothing to do'
		return
	}

	write-logFile 'Step NetApp volumes:'
	$script:allMoves.Values
	| Sort-Object size
	| ForEach-Object {

		$newPoolName = $_.newPoolName

		# create pool
		write-logFile "  Creating NetApp Pool '$newPoolName'..."
		$newPool = New-AzNetAppFilesPool `
					-ResourceGroupName	$sourceRG `
					-AccountName		$_.accountName `
					-Name				$newPoolName `
					-Location			$_.location `
					-ServiceLevel		$_.serviceLevel `
					-PoolSize			$_.size `
					-ErrorAction		'SilentlyContinue'
		test-cmdlet 'New-AzNetAppFilesPool'  "Could not create NetApp Pool '$newPoolName'"
		$poolID = $newPool.Id

		# move volumes
		foreach ($volumeNameLong in $_.volumes) {
			$accountName, $poolName, $volumeName = $volumeNameLong -split '/'
			write-logFile "  Moving NetApp Voulume '$volumeName' to Pool '$newPoolName'..."
			Set-AzNetAppFilesVolumePool `
				-ResourceGroupName	$sourceRG `
				-AccountName		$accountName `
				-PoolName			$poolName `
				-Name				$volumeName `
				-NewPoolResourceId	$poolID `
				-ErrorAction		'SilentlyContinue' | Out-Null
			test-cmdlet 'Set-AzNetAppFilesVolumePool'  "Could not move NetApp Volume '$volumeName'"
		}

		# delete old pool
		if ($_.deleteOldPool -eq $True) {
			$poolName = $_.oldPoolName
			write-logFile "  Deleting NetApp Pool '$poolName'..."
			Remove-AzNetAppFilesPool `
				-ResourceGroupName	$sourceRG `
				-AccountName		$_.accountName `
				-Name				$poolName `
				-ErrorAction		'SilentlyContinue' | Out-Null
			test-cmdlet 'Remove-AzNetAppFilesPool'  "Could not delete NetApp Pool '$poolName'"
		}
	}
}

#-------------------------------------------------------------
function update-sourceVMs {
#-------------------------------------------------------------
	$updatedAny = $False
	foreach ($vm in $script:sourceVMs) {

		$vmName = $vm.Name
		$updated = $False
		$properties = @()

		if ($script:copyVMs[$vmName].Skip -eq $True) {
			continue
		}

		# process VM size
		$oldSize = $vm.HardwareProfile.VmSize
		$newSize = $script:copyVMs[$vmName].VmSize
		if ($oldSize -ne $newSize) {
			$vm.HardwareProfile.VmSize = $newSize
			$updated = $True
			$properties += 'vmSize'
		}	

		# process OS disk
		$disk = $vm.StorageProfile.OsDisk
		$diskName 	= $disk.Name
		$oldCaching	= $disk.Caching
		$oldWa		= $disk.WriteAcceleratorEnabled
		# sometimes, property WriteAcceleratorEnabled does not exists when it should be set to $False
		if ($Null -eq $oldWa) {
			$oldWa = $False
		}
		$newCaching = $script:copyDisks[$diskName].Caching
		$newWa		= $script:copyDisks[$diskName].WriteAcceleratorEnabled

		if (($oldCaching -ne $newCaching) -or ($oldWa -ne $newWa)) {
			$param = @{
				VM			= $vm
				Name		= $diskName
				ErrorAction	= 'SilentlyContinue'
			}
			if ($oldCaching -ne $newCaching) {
				$param.Caching = $newCaching
				$properties += 'caching'
			}
			if ($oldWa -ne $newWa) {
				$param.WriteAccelerator = $newWa
				$properties += 'writeAccelerator'
			}

			Set-AzVMOsDisk @param | Out-Null
			test-cmdlet 'Set-AzVMOsDisk'  "Colud not update VM '$vmName'"

			$updated = $True
		}

		# process data disks
		foreach ($disk in $vm.StorageProfile.DataDisks) {
			$diskName 	= $disk.Name
			$oldCaching	= $disk.Caching
			$oldWa		= $disk.WriteAcceleratorEnabled
			# sometimes, property WriteAcceleratorEnabled does not exists when it should be set to $False
			if ($Null -eq $oldWa) {
				$oldWa = $False
			}
			$newCaching = $script:copyDisks[$diskName].Caching
			$newWa		= $script:copyDisks[$diskName].WriteAcceleratorEnabled
	
			if (($oldCaching -ne $newCaching) -or ($oldWa -ne $newWa)) {
				$param = @{
					VM			= $vm
					Name		= $diskName
					ErrorAction	= 'SilentlyContinue'
				}
				if ($oldCaching -ne $newCaching) {
					$param.Caching = $newCaching
					if ('caching' -notin $properties) {
						$properties += 'caching'
					}
				}
				if ($oldWa -ne $newWa) {
					$param.WriteAccelerator = $newWa
					if ('writeAccelerator' -notin $properties) {
						$properties += 'writeAccelerator'
					}
				}

				Set-AzVMDataDisk @param | Out-Null
				test-cmdlet 'Set-AzVMDataDisk'  "Colud not update VM '$vmName'"

				$updated = $True
			}
		}

		# perform update
		if ($updated) {
			$updatedAny = $True
			write-logFile "  Changing VM '$vmName' properties: $properties..."
			Update-AzVM -ResourceGroupName $sourceRG -VM $vm -ErrorAction 'SilentlyContinue' | Out-Null
			test-cmdlet 'Update-AzVM'  "Colud not update VM '$vmName'"
		}
	}
	if (!$updatedAny) {
		write-logFile '  No update of any VM needed'
	}
}

#-------------------------------------------------------------
function update-sourceDisks {
#-------------------------------------------------------------
	param (
		[switch] $beforeVmUpdate
	)

	$updatedAny = $False
	foreach ($disk in $script:sourceDisks) {

		$diskName = $disk.Name
		$updated = $False
		$properties = @()

		if (($script:copyDisks[$diskName].Skip -eq $True) `
		-or ( $beforeVmUpdate -and ($script:copyDisks[$diskName].VmRestrictions -eq $False)) `
		-or (!$beforeVmUpdate -and ($script:copyDisks[$diskName].VmRestrictions -eq $True ))) {
			continue
		}

		# set SKU
		$oldSku = $disk.Sku.Name
		$newSku = $script:copyDisks[$diskName].SkuName
		$oldMaxShares = $disk.MaxShares
		if ($Null -eq $oldMaxShares) {
			$oldMaxShares = 1
		}
		if ($oldSku -ne $newSku) {

			# disable shared disks before converting to Standard_LRS
			if (($newSku -like 'Standard_?RS') -and ($oldSku -notlike 'Standard_?RS') -and ($oldMaxShares -gt 1)) {
				$disk.MaxShares = 1
				$oldMaxShares = 1
				write-logFile "  Changing disk '$diskName' properties: maxShares..."
				$disk | Update-AzDisk -ErrorAction 'SilentlyContinue' | Out-Null
				test-cmdlet 'Update-AzDisk'  "Colud not update disk '$diskName'"
			}

			$disk.Sku = [Microsoft.Azure.Management.Compute.Models.DiskSku]::new($newSku)
			$updated = $True
			$properties += 'SKU'
		}

		# set Size
		$oldSize = $disk.DiskSizeGB
		$newSize = $script:copyDisks[$diskName].SizeGB
		if ($oldSize -ne $newSize) {
			$disk.DiskSizeGB = $newSize
			$updated = $True
			$properties += 'size'
		}

		$reducedTier = $False
		# set Tier
		$oldTier = $disk.Tier
		$newTier = $script:copyDisks[$diskName].performanceTierName
		if ($oldTier -ne $newTier) {
			$newTierSize = get-diskSize $newTier
			$oldTierSize = get-diskSize $oldTier
			if (($newTier -like 'P*') -and ($oldTier -like 'P*') -and ($newTierSize -lt $oldTierSize)) {
				$reducedTier = $True
			}
			$disk.Tier = $newTier
			$updated = $True
			if ('SKU' -notin $properties) {
				$properties += 'performanceTier'
			}
		}

		# set bursting
		$oldBursting = $disk.BurstingEnabled
		if ($null -eq $oldBursting) {
			$oldBursting = $False
		}
		$newBursting = $script:copyDisks[$diskName].BurstingEnabled
		if ($oldBursting -ne $newBursting) {
			if (($newTier -like 'P*') -and ($oldTier -like 'P*') -and ($newBursting -eq $False)) {
				$reducedTier = $True
			}
			$disk.BurstingEnabled = $newBursting
			$updated = $True
			$properties += 'bursting'
		}

		# set shared disk
		#oldMaxShares see above
		$newMaxShares = $script:copyDisks[$diskName].MaxShares
		if ($oldMaxShares -ne $newMaxShares) {
			$disk.MaxShares = $newMaxShares
			$updated = $True
			$properties += 'maxShares'
		}

		# temporarily changing SKU
		if ($reducedTier) {
			if ($disk.Sku.Name -eq 'Premium_ZRS') {
				$tempSKU  = [Microsoft.Azure.Management.Compute.Models.DiskSku]::new('StandardSSD_ZRS')
				$finalSKU = [Microsoft.Azure.Management.Compute.Models.DiskSku]::new('Premium_ZRS')
			}
			else {
				$tempSKU  = [Microsoft.Azure.Management.Compute.Models.DiskSku]::new('StandardSSD_LRS')
				$finalSKU = [Microsoft.Azure.Management.Compute.Models.DiskSku]::new('Premium_LRS')
			}
			# reducing Tier: step 1
			$disk.Sku = $tempSKU
			$disk.Tier = $Null
			$disk.BurstingEnabled = $False

			$disk | Update-AzDisk -ErrorAction 'SilentlyContinue' | Out-Null
			test-cmdlet 'Update-AzDisk'  "Colud not update disk '$diskName'"

			# reducing Tier: step 2
			$disk.Sku = $finalSKU
			$disk.Tier = $newTier
			$disk.BurstingEnabled = $newBursting
		}

		# perfrom update
		if ($updated) {
			$updatedAny = $True
			write-logFile "  Changing disk '$diskName' properties: $properties..."
			$disk | Update-AzDisk -ErrorAction 'SilentlyContinue' | Out-Null
			if (!$?) {
				if ($reducedTier) {
					write-logFileWarning "Disk '$diskName' has been converted to 'StandardSSD'"
				}
				test-cmdlet 'Update-AzDisk'  "Colud not update disk '$diskName'"  -always
			}
		}
	}
	if (!$updatedAny) {
		write-logFile '  No update of any disk needed'
	}
}

#-------------------------------------------------------------
function update-sourceNICs {
#-------------------------------------------------------------
	param (
		[switch] $beforeVmUpdate
	)

	$updatedAny = $False
	foreach ($nic in $script:sourceNICs) {
		$nicName = $nic.Name
		$NicRG = $nic.ResourceGroupName
		$inRG = ''
		if ($NicRG -ne $sourceRG) {
			$inRG = "in resource group '$NicRG'"
		}

		$resKey = "networkInterfaces/$NicRG/$nicName"
		$nicNameNew = $script:remoteNames[$resKey].newName
		$newAcc = $script:copyNics[$nicNameNew].EnableAcceleratedNetworking
		$oldAcc = $nic.EnableAcceleratedNetworking

		if ($oldAcc -ne $newAcc) {

			if (($newAcc -eq $False) -and $beforeVmUpdate) {
				$nic.EnableAcceleratedNetworking = $newAcc
				$updatedAny = $True
				write-logFile "  Changing NIC '$nicName' $inRG property: Turning off Accelerated Networking..."
				Set-AzNetworkInterface -NetworkInterface $nic -ErrorAction 'SilentlyContinue' | Out-Null
				test-cmdlet 'Set-AzNetworkInterface'  "Colud not update network interface '$nicName'" 
			}
			if (($newAcc -eq $True) -and !$beforeVmUpdate) {
				$nic.EnableAcceleratedNetworking = $newAcc
				$updatedAny = $True
				write-logFile "  Changing NIC '$nicName' $inRG property: Turning on Accelerated Networking..."
				Set-AzNetworkInterface -NetworkInterface $nic -ErrorAction 'SilentlyContinue' | Out-Null
				test-cmdlet 'Set-AzNetworkInterface'  "Colud not update network interface '$nicName'" 
			}
		}
	}
	if (!$updatedAny) {
		write-logFile '  No update of any NIC needed'
	}
}

#-------------------------------------------------------------
function update-sourceBastion {
#-------------------------------------------------------------
	# create bastion
	if ($createBastion.length -ne 0) {

		write-LogFile 'Step Create Bastion:'
		# get vnet
		$vnet = Get-AzVirtualNetwork `
					-ResourceGroupName	$sourceRG `
					-Name				$script:bastionVnet `
					-ErrorAction		'SilentlyContinue'
		test-cmdlet 'Get-AzVirtualNetwork'  "Could not get VNET '$script:bastionVnet' of resource group '$sourceRG'"

		if ('AzureBastionSubnet' -in $vnet.Subnets.Name) {
			write-logFile "  Subnet 'AzureBastionSubnet' already exists"
		}
		else {
			# add subnet
			write-logFile "  Creating Subnet 'AzureBastionSubnet'..."
			Add-AzVirtualNetworkSubnetConfig `
				-Name 'AzureBastionSubnet' `
				-VirtualNetwork		$vnet `
				-AddressPrefix		$script:bastionAddressPrefix `
				-ErrorAction		'SilentlyContinue' | Out-Null
			test-cmdlet 'Add-AzVirtualNetworkSubnetConfig'  "Could not create subnet 'AzureBastionSubnet'"

			# save subnet
			$vnet | Set-AzVirtualNetwork -ErrorAction 'SilentlyContinue' | Out-Null
			test-cmdlet 'Set-AzVirtualNetwork'  "Could not create subnet 'AzureBastionSubnet' with prefix '$script:bastionAddressPrefix'"
		}

		$publicIP = Get-AzPublicIpAddress `
			-ResourceGroupName	$sourceRG `
			-name				'AzureBastionIP' `
			-ErrorAction		'SilentlyContinue'
		if ($?) {
			write-logFile "  Public IP Address 'AzureBastionIP' already exists"
		}
		else {
			# create PublicIpAddress
			write-logFile "  Creating Public IP Address 'AzureBastionIP'..."
			$publicIP = New-AzPublicIpAddress `
							-ResourceGroupName	$sourceRG `
							-name				'AzureBastionIP' `
							-location			$sourceLocation `
							-AllocationMethod	'Static' `
							-Sku				'Standard' `
							-ErrorAction		'SilentlyContinue'
			test-cmdlet 'New-AzPublicIpAddress'  "Could not create Public IP Address 'AzureBastionIP'"
		}

		# get vnet again (workaround for Bad Request issue)
		$vnet = Get-AzVirtualNetwork `
					-ResourceGroupName	$sourceRG `
					-Name				$script:bastionVnet `
					-ErrorAction		'SilentlyContinue'
		test-cmdlet 'Get-AzVirtualNetwork'  "Could not get VNET '$script:bastionVnet' of resource group '$sourceRG'"

		# create bastion
		write-logFile "  Creating Bastion 'AzureBastion'..."
		New-AzBastion `
			-ResourceGroupName	$sourceRG `
			-Name				'AzureBastion' `
			-PublicIpAddress	$publicIP `
			-VirtualNetwork		$vnet `
			-Sku				'Basic' `
			-ErrorAction		'SilentlyContinue' | Out-Null
		test-cmdlet 'New-AzBastion'  "Could not create Bastion 'AzureBastion'"

	}
	# delete bastion
	elseif ($deleteBastion) {

		write-LogFile 'Step Delete Bastion:'
		if ($Null -eq $script:sourceBastion.IpConfigurations) {
			write-logFile "  There is no bastion to be deleted"
			return
		}
		$bastionName = $script:sourceBastion.Name

		if ($Null -eq $script:sourceBastion.IpConfigurations[0].Subnet.Id) {
			write-logFileError "Bastion inconsistent"
		}
		$r = get-resourceComponents $script:sourceBastion.IpConfigurations[0].Subnet.Id
		$bastionVnet   = $r.mainResourceName
		$bastionVnetRG = $r.resourceGroup

		if ($Null -eq $script:sourceBastion.IpConfigurations[0].PublicIpAddress.Id) {
			write-logFileError "Bastion inconsistent"
		}
		$r = get-resourceComponents $script:sourceBastion.IpConfigurations[0].PublicIpAddress.Id
		$bastionPublicIP   = $r.mainResourceName
		$bastionPublicIpRG = $r.resourceGroup

		
		# delete bastion
		write-logFile "  Deleting Bastion '$bastionName'..."
		Remove-AzBastion `
			-ResourceGroupName	$sourceRG `
			-Name				$bastionName `
			-Force `
			-ErrorAction		'SilentlyContinue'
		test-cmdlet 'Remove-AzBastion'  "Could not delete Bastion '$bastionName' of resource group '$sourceRG'"

		# delete PublicIP
		write-logFile "  Deleting Public IP Address '$bastionPublicIP'..."
		Remove-AzPublicIpAddress `
			-ResourceGroupName	$bastionPublicIpRG `
			-Name				$bastionPublicIP `
			-Force `
			-ErrorAction		'SilentlyContinue'
		test-cmdlet 'Remove-AzPublicIpAddress'  "Could not delete Public IP Address '$bastionPublicIP' of Bastion '$bastionName'"

		# get vnet
		write-logFile "  Deleting Subnet 'AzureBastionSubnet'..."
		$vnet = Get-AzVirtualNetwork `
			-ResourceGroupName	$bastionVnetRG `
			-Name				$bastionVnet `
			-ErrorAction		'SilentlyContinue'
		test-cmdlet 'Get-AzVirtualNetwork'  "Could not get Bastion virtual network '$bastionVnet'"

		# remove subnet
		Remove-AzVirtualNetworkSubnetConfig `
			-Name 				'AzureBastionSubnet' `
			-VirtualNetwork		$vnet `
			-ErrorAction 		'SilentlyContinue'| Out-Null
		test-cmdlet 'Remove-AzVirtualNetworkSubnetConfig'  "Could not remove subnet 'AzureBastionSubnet'"

		# update vnet
		Set-AzVirtualNetwork `
			-VirtualNetwork		$vnet `
			-ErrorAction 		'SilentlyContinue'| Out-Null
		test-cmdlet 'Set-AzVirtualNetwork'  "Could not remove Subnet 'AzureBastionSubnet'"
	}
	else {
		write-LogFile 'Step Bastion: Nothing to do'
	}
}

#--------------------------------------------------------------
function get-az_used {
#--------------------------------------------------------------
	if ($script:resourceIDs.count -eq 0) {
		return @()
	}

	# parse first Id
	$r = get-resourceComponents $script:resourceIDs[0]
	$type = $r.mainResourceType

	switch ($type) {
		'publicIPPrefixes'			{ $ref = [ref] $script:az_publicIPPrefixes }
		'publicIPAddresses'			{ $ref = [ref] $script:az_publicIPAddresses }
		'networkSecurityGroups'		{ $ref = [ref] $script:az_networkSecurityGroups }
		'natGateways'				{ $ref = [ref] $script:az_natGateways }
		Default						{ write-logFileError 'Internal error' }
	}

	$usedResources = @()
	foreach ($res in $ref.Value) {
		if ($res.id -in $script:resourceIDs) {
			$usedResources += $res
		}
		else {
			$r = get-resourceComponents $res.id
			$name = $r.mainResourceName
			write-logFileWarning "Skip unused $type '$name'"
		}
	}

	return $usedResources
}

#--------------------------------------------------------------
function get-az_remote {
#--------------------------------------------------------------
	param (
		$id
	)

	# nothing to do
	if ($Null -eq $id) {
		return
	}

	# save resourceIDs
	$script:resourceIDs += $id

	# parse Id
	$r = get-resourceComponents $id
	$subscriptionID 	= $r.subscriptionID
	$type				= $r.mainResourceType
	$name				= $r.mainResourceName
	$resourceGroupName	= $r.resourceGroup

	# no resources from different subscriptions allowed
	if ($subscriptionID -ne $sourceSubID) {
		write-logFileError "Resource '$name' of type '$type' is in wrong subscription" `
							"Subscription ID is $subscriptionID" `
							"Subscription ID of source RG is $sourceSubID"
	}

	# resource is in same resource group: nothing to do
	if ($resourceGroupName -eq $sourceRG) {
		return
	}

	switch ($type) {
		'networkInterfaces'			{ $ref = [ref] $script:az_networkInterfaces }
		'publicIPPrefixes'			{ $ref = [ref] $script:az_publicIPPrefixes }
		'virtualNetworks'			{ $ref = [ref] $script:az_virtualNetworks }
		'publicIPAddresses'			{ $ref = [ref] $script:az_publicIPAddresses }
		'networkSecurityGroups'		{ $ref = [ref] $script:az_networkSecurityGroups }
		'natGateways'				{ $ref = [ref] $script:az_natGateways }
		'availabilitySets'			{ $ref = [ref] $script:az_availabilitySets }
		'proximityPlacementGroups'	{ $ref = [ref] $script:az_proximityPlacementGroups }
		'virtualMachineScaleSets'	{ $ref = [ref] $script:az_virtualMachineScaleSets }
		Default						{ write-logFileError 'Internal error' }
	}

	$resource = $ref.Value | Where-Object {($_.Name -eq $Name) -and ($_.ResourceGroupName -eq $ResourceGroupName)}

	# remote resource not already saved
	if ($Null -ne $resource) {
		return
	}

	write-logFileWarning "Reading $type '$Name' from resource group '$ResourceGroupName'..."
	$param = @{
		Name				= $Name
		ResourceGroupName 	= $ResourceGroupName
		WarningAction		= 'SilentlyContinue'
		ErrorAction 		= 'SilentlyContinue'
	}

	switch ($type) {
		'networkInterfaces'			{ $resource = Get-AzNetworkInterface @param }
		'publicIPPrefixes'			{ $resource = Get-AzPublicIpPrefix @param }
		'virtualNetworks'			{ $resource = Get-AzVirtualNetwork @param }
		'publicIPAddresses'			{ $resource = Get-AzPublicIPAddress @param }
		'networkSecurityGroups'		{ $resource = Get-AzNetworkSecurityGroup @param }
		'natGateways'				{ $resource = Get-AzNatGateway @param }
		'availabilitySets'			{ $resource = Get-AzAvailabilitySet @param }
		'proximityPlacementGroups'	{ $resource = Get-AzProximityPlacementGroup @param }
		'virtualMachineScaleSets'	{ $resource = Get-AzVmss @param }
		Default					{ write-logFileError 'Internal error' }
	}
	test-cmdlet 'Get-Az*' "Could not get $type '$Name' of resource group '$ResourceGroupName'"

	# add remote resource
	$ref.Value += $resource
}

#--------------------------------------------------------------
function get-az_local {
#--------------------------------------------------------------
	param (
		[switch] $vmsOnly
	)

	$script:az_all = @()
	$script:resourceIDs = @()
	#--------------------------------------------------------------
	# virtualMachines (collect only from source RG)
	#--------------------------------------------------------------
	if (!$vmsOnly) {
		write-logFile "Reading VMs from resource group $sourceRG..."
	}
	$script:az_virtualMachines = @( 
		Get-AzVM `
			-ResourceGroupName $sourceRG `
			-WarningAction	'SilentlyContinue' `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzVM'  "Could not get VMs of resource group '$sourceRG'"

	$script:az_all += $script:az_virtualMachines

	if ($vmsOnly) {
		return
	}

	#--------------------------------------------------------------
	# disks (make sure that all disks are in source RG)
	#--------------------------------------------------------------
	# after: az_virtualMachines
	write-logFile "Reading disks from resource group $sourceRG..."
	$script:az_disks = $script:sourceDisks

	# do not allow disks from other RGs
	foreach ($vm in $script:az_virtualMachines) {
		test-az_local $vm.StorageProfile.OsDisk.ManagedDisk.Id
		foreach ($disk in $vm.StorageProfile.DataDisks) {
			test-az_local $disk.Id
		}
	}

	$script:az_all += $script:sourceDisks

	#--------------------------------------------------------------
	# snapshots (save snapshot names, only from source RG)
	#--------------------------------------------------------------
	write-logFile "Reading snapshots from resource group $sourceRG..."

	$script:az_all += $script:sourceSnapshots

	#--------------------------------------------------------------
	# networkInterfaces
	#--------------------------------------------------------------
	# after: az_virtualMachines
	write-logFile "Reading NICs from resource group $sourceRG..."
	$script:az_networkInterfaces = @( 
		Get-AzNetworkInterface `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzNetworkInterface'  "Could not get NICs of resource group '$sourceRG'"

	# get NICs from other RGs
	foreach ($vm in $script:az_virtualMachines) { 
		foreach ($nic in $vm.NetworkProfile.NetworkInterfaces) {
			get-az_remote $nic.Id
		}
	}

	$script:az_all += $script:az_networkInterfaces

	if (!$cloneOrMergeMode) {
		#--------------------------------------------------------------
		# loadBalancers
		#--------------------------------------------------------------
		write-logFile "Reading loadBalancers from resource group $sourceRG..."
		$script:az_loadBalancers = @( 
			Get-AzLoadBalancer `
				-ResourceGroupName $sourceRG `
				-ErrorAction 'SilentlyContinue'
		)
		test-cmdlet 'Get-AzLoadBalancer'  "Could not get loadBalancers of resource group $sourceRG"

		$script:az_all += $script:az_loadBalancers
	}

	if (!$cloneOrMergeMode) {
		#--------------------------------------------------------------
		# bastionHosts
		#--------------------------------------------------------------
		write-logFile "Reading Bastions from resource group $sourceRG..."
		$script:az_bastionHosts = @( 
			Get-AzBastion `
				-ResourceGroupName $sourceRG `
				-ErrorAction 'SilentlyContinue'
		)
		test-cmdlet 'Get-AzBastion'  "Could not get Bastions of resource group $sourceRG"

		$script:az_all += $script:az_bastionHosts
	}

	#--------------------------------------------------------------
	# virtualNetworks
	#--------------------------------------------------------------
	# after: az_networkInterfaces
	# after: az_loadBalancers
	# after: az_bastionHosts
	write-logFile "Reading VNETs from resource group $sourceRG..."
	$script:az_virtualNetworks = @( 
		Get-AzVirtualNetwork `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzVirtualNetwork'  "Could not get VNETs of resource group $sourceRG"

	# get VNETs from other RGs
	foreach ($nic in $script:az_networkInterfaces) { 
		foreach ($conf in $nic.IpConfigurations) {
			if ($Null -ne $conf.Subnet.Id) {
				# get VNET ID
				$s = $conf.Subnet.Id -split '/'
				$vnetId = "/$($s[1])/$($s[2])/$($s[3])/$($s[4])/$($s[5])/$($s[6])/$($s[7])/$($s[8])"

				get-az_remote $vnetId
			}
		}
	}

	foreach ($lb in $script:az_loadBalancers) { 
		foreach ($conf in $lb.FrontendIpConfigurations) {
			if ($Null -ne $conf.Subnet.Id) {
				# get VNET ID
				$s = $conf.Subnet.Id -split '/'
				$vnetId = "/$($s[1])/$($s[2])/$($s[3])/$($s[4])/$($s[5])/$($s[6])/$($s[7])/$($s[8])"

				get-az_remote $vnetId
			}
		}
	}

	foreach ($bastion in $script:az_bastionHosts) { 
		foreach ($conf in $bastion.IpConfigurations) {
			if ($Null -ne $conf.Subnet.Id) {
				# get VNET ID
				$s = $conf.Subnet.Id -split '/'
				$vnetId = "/$($s[1])/$($s[2])/$($s[3])/$($s[4])/$($s[5])/$($s[6])/$($s[7])/$($s[8])"

				get-az_remote $vnetId
			}
		}
	}

	$script:az_all += $script:az_virtualNetworks

	if (!$cloneOrMergeMode) {
		if ($skipNatGateway) {
			write-logFileWarning 'Skip NAT gateways'
		}
		else {
			#--------------------------------------------------------------
			# natGateways
			#--------------------------------------------------------------
			# after:virtualNetworks
			write-logFile "Reading Gateways from resource group $sourceRG..."
			$script:az_natGateways = @( 
				Get-AzNatGateway `
					-ResourceGroupName $sourceRG `
					-ErrorAction 'SilentlyContinue'
			)
			test-cmdlet 'Get-AzNatGateway'  "Could not get Gateways of resource group $sourceRG"
	
			# collect used resources
			$script:resourceIDs = @()

			foreach ($net in $script:az_virtualNetworks) {
				foreach ($subnet in $net.subnets) {
					get-az_remote $subnet.NatGateway.Id
				}
			}

			# remove unused resources
			$script:az_natGateways = (get-az_used)
			$script:az_all += $script:az_natGateways
		}
	}

	if (!$cloneOrMergeMode) {
		#--------------------------------------------------------------
		# publicIPPrefixes
		#--------------------------------------------------------------
		# after: az_natGateways
		# after: az_loadBalancers
		write-logFile "Reading Public IP Prefixes from resource group $sourceRG..."
		$script:az_publicIPPrefixes = @( 
			Get-AzPublicIpPrefix `
				-ResourceGroupName $sourceRG `
				-ErrorAction 'SilentlyContinue'
		)
		test-cmdlet 'Get-AzPublicIpPrefix'  "Could not get Public IP Prefixes of resource group $sourceRG"

		# collect used resources
		$script:resourceIDs = @()

		foreach ($gateway in $script:az_natGateways) { 
			foreach ($prefix in $gateway.PublicIpPrefixes) {
				get-az_remote $prefix.Id
			}
		}

		foreach ($lb in $script:az_loadBalancers) { 
			foreach ($conf in $lb.FrontendIpConfigurations) {
				get-az_remote  $conf.PublicIPPrefix.Id
			}
		}

		# remove unused resources
		$script:az_publicIPPrefixes = (get-az_used)
		$script:az_all += $script:az_publicIPPrefixes
	}

	#--------------------------------------------------------------
	# publicIPAddresses
	#--------------------------------------------------------------
	# after: az_networkInterfaces
	# after: az_bastionHosts
	# after: az_natGateways
	# after: az_loadBalancers
	write-logFile "Reading Public IPs from resource group $sourceRG..."
	$script:az_publicIPAddresses = @( 
		Get-AzPublicIPAddress `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzPublicIPAddress'  "Could not get Public IP Addresses of resource group $sourceRG"

	# collect used resources
	$script:resourceIDs = @()

	# get PublicIPs from other RGs
	foreach ($nic in $script:az_networkInterfaces) { 
		foreach ($conf in $nic.IpConfigurations) {
			get-az_remote $conf.PublicIpAddress.Id
		}
	}

	foreach ($bastion in $script:az_bastionHosts) { 
		foreach ($conf in $bastion.IpConfigurations) {
			get-az_remote $conf.PublicIpAddress.Id
		}
	}

	foreach ($gateway in $script:az_natGateways) { 
		foreach ($ip in $gateway.PublicIpAddresses) {
			get-az_remote $ip.Id
		}
	}

	foreach ($lb in $script:az_loadBalancers) { 
		foreach ($conf in $lb.FrontendIpConfigurations) {
			get-az_remote $conf.PublicIpAddress.Id
		}
	}

	# remove unused resources
	$script:az_publicIPAddresses = (get-az_used)
	$script:az_all += $script:az_publicIPAddresses

	if (!$cloneOrMergeMode) {
		#--------------------------------------------------------------
		# networkSecurityGroups
		#--------------------------------------------------------------
		# after: az_virtualNetworks
		# after: az_networkInterfaces
		write-logFile "Reading NSGs from resource group $sourceRG..."
		$script:az_networkSecurityGroups = @( 
			Get-AzNetworkSecurityGroup `
				-ResourceGroupName $sourceRG `
				-ErrorAction 'SilentlyContinue'
		)
		test-cmdlet 'Get-AzNetworkSecurityGroup'  "Could not get NSGs of resource group $sourceRG"

		# collect used resources
		$script:resourceIDs = @()

		# get NSGs from other RGs
		foreach ($net in $script:az_virtualNetworks) {
			foreach ($subnet in $net.subnets) {
				get-az_remote $subnet.NetworkSecurityGroup.Id
			}
		}

		foreach ($nic in $script:az_networkInterfaces) {
			get-az_remote $nic.NetworkSecurityGroup.Id
		}

		# remove unused resources
		$script:az_networkSecurityGroups = (get-az_used)
		$script:az_all += $script:az_networkSecurityGroups
	}

	if (!$cloneOrMergeMode) {
		#--------------------------------------------------------------
		# availabilitySets
		#--------------------------------------------------------------
		# after: az_virtualMachines
		write-logFile "Reading Availability Sets from resource group $sourceRG..."
		$script:az_availabilitySets = @( 
			Get-AzAvailabilitySet `
				-ResourceGroupName $sourceRG `
				-ErrorAction 'SilentlyContinue'
		)
		test-cmdlet 'Get-AzAvailabilitySet'  "Could not get Availability Sets of resource group $sourceRG"

		foreach ($vm in $script:az_virtualMachines) { 
			get-az_remote $vm.AvailabilitySetReference.Id
		}

		$script:az_all += $script:az_availabilitySets
	}

	if (!$cloneOrMergeMode) {
		#--------------------------------------------------------------
		# proximityPlacementGroups
		#--------------------------------------------------------------
		# after: az_virtualMachines
		# after: az_availabilitySets
		write-logFile "Reading PPGs from resource group $sourceRG..."
		$script:az_proximityPlacementGroups = @( 
			Get-AzProximityPlacementGroup `
				-ResourceGroupName $sourceRG `
				-ErrorAction 'SilentlyContinue'
		)
		test-cmdlet 'Get-AzProximityPlacementGroup'  "Could not get PPG of resource group $sourceRG"

		foreach ($vm in $script:az_virtualMachines) { 
			get-az_remote $vm.ProximityPlacementGroup.Id
		}

		foreach ($avset in $script:az_availabilitySets) { 
			get-az_remote $avset.ProximityPlacementGroup.Id
		}

		$script:az_all += $script:az_proximityPlacementGroups
	}

	if (!$cloneOrMergeMode) {
		#--------------------------------------------------------------
		# virtualMachineScaleSets
		#--------------------------------------------------------------
		# after: az_virtualMachines
		write-logFile "Reading VMSS from resource group $sourceRG..."
		$script:az_virtualMachineScaleSets = @( 
			Get-AzVmss `
				-ResourceGroupName $sourceRG `
				-ErrorAction 'SilentlyContinue' `
				-WarningAction 'SilentlyContinue'
		)
		test-cmdlet 'az_virtualMachineScaleSets'  "Could not get VMSS of resource group $sourceRG"

		foreach ($vm in $script:az_virtualMachines) { 
			get-az_remote $vm.VirtualMachineScaleSet.Id
		}

		$script:az_all += $script:az_virtualMachineScaleSets
	}

	#--------------------------------------------------------------
	# save all
	#--------------------------------------------------------------
	write-logFile
	$text = $script:az_all | ConvertTo-Json -Depth 20
	Set-Content -Path $importPath -Value $text -ErrorAction 'SilentlyContinue'
	if (!$?) {
		write-logFileError "Could not save az json file" `
								"Failed writing file '$importPath'"
	}
	write-logFile -ForegroundColor 'Cyan' "Source az json file saved: $importPath"
	$script:armTemplateFilePaths += $importPath
	write-logFile
}

#--------------------------------------------------------------
function test-az_local {
#--------------------------------------------------------------
	param (
		$id
	)

	# nothing to do
	if ($Null -eq $id) {
		return
	}

	# parse Id
	$r = get-resourceComponents $id
	$subscriptionID 	= $r.subscriptionID
	$type				= $r.mainResourceType
	$name				= $r.mainResourceName
	$resourceGroupName	= $r.resourceGroup

	# different subscription
	if ($subscriptionID -ne $sourceSubID) {
		write-logFileError "Resource '$name' of type '$type' is in wrong subscription" `
							"Subscription ID is: $subscriptionID" `
							"Subscription ID should be: $sourceSubID"
	}

	# different resource group
	if ($resourceGroupName -ne $sourceRG) {
		write-logFileError "Resource '$name' of type '$type' is in wrong resource group" `
							"Resource group is: $resourceGroupName" `
							"Resource group should be: $sourceRG"
	}
}

#--------------------------------------------------------------
function get-NameByBicepName {
#--------------------------------------------------------------
	param (
		$bicepName
	)

	if ($Null -eq $script:bicepNamesAll[$bicepName]) {
		return $Null, $Null
	}
	else {
		return $script:bicepNamesAll[$bicepName].name, $script:bicepNamesAll[$bicepName].type
	}
}

#--------------------------------------------------------------
function get-bicepNameByType {
#--------------------------------------------------------------
	param (
		$type,	# multi-part type
		$name	# multi-part name
	)

	# single-part type and name
	$typeParts = $type -split '/'
	$nameParts = $name -split '/'
	if (($typeParts.count) -ne ($nameParts.count + 1)) {
		write-logFileError "Internal RGCOPY error in 'get-bicepNameByType'" `
							"type = $type" `
							"name = $name"
	}

	$typeShort = $typeParts[-1]
	$nameShort = $nameParts[-1]

	# ToLower(): woraround for Azure bug:
	# resource ID contained resource name in wrong case (upper case instead of lower case)
	$bicepName = ("$typeShort`_$nameShort" -replace '[\W]', '_').ToLower()
	$count = 1

	# check if name is already in use
	$nameSaved, $typeSaved = get-NameByBicepName $bicepName
	while (($Null -ne $nameSaved) -and (($name -ne $nameSaved) -or ($type -ne $typeSaved))) {
		$count++
		$bicepName = ("$typeShort$count`_$nameShort" -replace '[\W]', '_').ToLower()
		$nameSaved, $typeSaved = get-NameByBicepName $bicepName
	}

	if ($Null -eq $nameSaved) {
		# save unique bicep name
		$script:bicepNamesAll[$bicepName] = @{
			bicepName	= $bicepName
			type		= $type
			name		= $name
		} 
	}

	return $bicepName
}

#--------------------------------------------------------------
function get-bicepNameById {
#--------------------------------------------------------------
	param (
		$id
	)

	if ($Null -eq $id) {
		return $Null
	}

	$r = get-resourceComponents $id
	$type = $r.resourceArea + '/' + $r.mainResourceType 
	$name = $r.mainResourceName

	# always get the name of the MAIN resource !!!
	return (get-bicepNameByType $type $name)
}

#--------------------------------------------------------------
function get-bicepIdStructByType {
#--------------------------------------------------------------
	param (
		$type,
		$name
	)

	$bicepName = get-bicepNameByType $type $name
	if ($Null -eq $bicepName) {
		return $Null
	}
	else {
		return @{
			id = "<$bicepName`.id>"
		}
	}
}
	

#--------------------------------------------------------------
function get-bicepIdStructById {
#--------------------------------------------------------------
	param (
		$id,
		[switch] $forceBicep
	)

	if ($Null -eq $id) {
		return $Null
	}

	if (($cloneOrMergeMode) -and (!$forceBicep)) {
		return (get-bicepResourceFunctionById $id)
	}
	else {
		# always get the name of the MAIN resource !!!
		$bicepName = get-bicepNameById $id
		return @{
			id = "<$bicepName`.id>"
		}
	}
}

#--------------------------------------------------------------
function get-bicepResourceFunctionById {
#--------------------------------------------------------------
	param (
		$id,
		[ref] $depensOn
	)

	$bicepName = get-bicepNameById $id
	if ($Null -eq $bicepName) {
		return $Null
	}

	else {
		# for a sub resoure, the main resource is added to the dependency list
		if ($Null -ne $depensOn) {
			$depensOn.Value += "<$bicepName>"
		}

		$r = get-resourceComponents $id

		# add resource group name
		if ($cloneOrMergeMode) {
			$rg = "'$($r.resourceGroup)', "
		}
		else {
			$rg = $Null
		}

		# ID of main resource was passed as parameter
		if ($Null -eq $r.subResourceType) {
			$string = "<resourceId($rg'$($r.resourceArea)/$($r.mainResourceType)', '$($r.mainResourceName)')>"

		}

		# ID of sub resource was passed as parameter: This is the typical case
		else {
			$string = "<resourceId($rg'$($r.resourceArea)/$($r.mainResourceType)/$($r.subResourceType)', '$($r.mainResourceName)', '$($r.subResourceName)')>"
		}

		return @{
			id = $string
		}
	}
}

#--------------------------------------------------------------
function add-bicepResource {
#--------------------------------------------------------------
	param (
		$res,
		$tabCount = 1,
		[switch] $existing
	)

	$textArray = @()
	$tabString = '  '

	if ($tabCount -ne 1) {
		$keysSorted = $res.keys | Sort-Object
	}
	else {
		# calculate symbolc name
		$bicepName = $res.bicepName

		$condition = ''
		if ($Null -ne $res.if) {
			$condition = "if($($res.if)) "
		}

		# new resource
		$textArray += ''

		if ($existing) {
			$textArray += "resource $bicepName '$($res.type)@$($res.apiVersion)' existing = {"
		}
		else {
			$textArray += "resource $bicepName '$($res.type)@$($res.apiVersion)' = $condition{"
		}

		# sort keys
		$keysUnsorted = $res.keys | Sort-Object
		$keysSorted = @()
		$sortOrder = @('name', 'parent', 'type', 'location', 'apiVersion', 'sku', 'tags', 'dependsOn')

		# start with sorted keys
		foreach ($key in $sortOrder) {
			if (($key -in $keysUnsorted) -and ($key -ne 'properties')) {
				$keysSorted += $key
			}
		}
	
		# other keys
		foreach ($key in $keysUnsorted) {
			if (($key -notin $sortOrder) -and ($key -ne 'properties')) {
				$keysSorted += $key
			}
		}
	
		# end with properties key
		if ('properties' -in $keysUnsorted) {
			$keysSorted += 'properties'
		}
	}

	if ($existing) {
		$textArray += $tabString * $tabCount + "name: '$($res.name)'"
	}

	else {

		# process all keys
		foreach ($key in $keysSorted) {
			
			$value = $res.$key
			
			# recursion level 1
			if ($tabCount -eq 1) {

				# isKeyOfATag
				if ($key -eq 'tags') {
					$script:isKeyOfATag = $True
				}
				else {
					$script:isKeyOfATag = $False
				}

				# allowEmptyValues: copy also keys with empty values
				if ($key -eq 'identity') {
					$script:allowEmptyValues = $True
				}
				else {
					$script:allowEmptyValues = $False
				}


				switch ($key) {
					'type' {
						$script:verboseType = $value
					}
					'name' {
						$script:verboseName = $value
						# if parent is given then use single-part name
						if ($Null -ne $res.parent) {
							$value = ($value -split '/')[-1]
						}
					}
					'dependsOn' {
						$newValue = @()
						foreach ($item in $value) {
							# only allow dependsOn with values <*> for BICEP
							# other values have been created for ARM templates
							if ($item -like '<*>') {
								$newValue += $item
							}
						}
						$value = $newValue
					}
				}

				if ($key -in @( 'if', 'type', 'apiVersion', 'resourceGroupName', 'bicepName')) {
					continue
				}
			}

			# Null value or empty array/hashtable
			if (($value.count -eq 0) -and !$script:allowEmptyValues) {
				if ($verboseLog) {
					# used for detecting wrong parsing of az-cmdlet results
					write-logFileWarning "Bicep: $script:verboseType/$script:verboseName`: empty key: $key"
				}
				continue
			}

			# quoted keys required if key name contains special characters
			if ($key -notmatch '^[\w]*$') {
				$key = "'$key'"
			}
			
			# HASH
			if ($value -is [hashtable]) {
				$textArraySubLevel = @()
				$textArraySubLevel += add-bicepResource $value $($tabCount + 1)
				# check for empty hash table
				if (($textArraySubLevel.count -ne 0) -or$script:allowEmptyValues) {
					$textArray += $tabString * $tabCount + "$key`: {"
					$textArray += $textArraySubLevel
					$textArray += $tabString * $tabCount + "}"
				}
			}

			# ARRAY
			elseif ($value -is [array]) {
				$textArray += $tabString * $tabCount + "$key`: ["
				foreach ($item in $value) {

					# ARRAY item: HASH
					if ($item -is [hashtable]) {
						$textArray += $tabString * ($tabCount + 1) + "{"
						$textArray += add-bicepResource $item $($tabCount + 2)
						$textArray += $tabString * ($tabCount + 1) + "}"
					}

					else {
						# ARRAY item: STRING
						if ($item -is [string]) {

							# string that does not need quotes (e.g. parameter name)
							if ($item -like '<*>') {
								$item = test-angleBrackets $item
								$textArray += $tabString * ($tabCount + 1) + "$item"
							}
							
							# nornal string
							else {
								$item = $item	-replace '\\', '\\' `
												-replace '\$', '\$' `
												-replace "'", "\'" `
												-replace '\r', '\r' `
												-replace '\n', '\n' `
												-replace '\f', '\f' `
												-replace '\t', '\t' `
												-replace '\v', '\v'
								$textArray += $tabString * ($tabCount + 1) + "'$item'"
							}
						}

						# ARRAY item: BOOL
						elseif ($item -is [boolean]) {
							$bool = ($item -as [string]).toLower()
							$textArray += $tabString * ($tabCount + 1) + "$bool"
						}

						# ARRAY item: NUMERIC
						else {
							$textArray += $tabString * ($tabCount + 1) + "$item"
						}
					}
				}
				$textArray += $tabString * $tabCount + "]"
			}

			# STRING
			elseif ($value -is [string]) {

				# empty string
				if ($value.length -eq 0) {
					if ($verboseLog) {
						# used for detecting wrong parsing of az-cmdlet results
						write-logFileWarning "Bicep: $script:verboseType/$script:verboseName`: empty key: $key"
					}
					continue
				}

				# string that does not need quotes (e.g. parameter name)
				# except for tags values ($script:isKeyOfATag -eq $True)
				if ($value -like '<*>') {
					if (!$script:isKeyOfATag -or ($key -eq "'TipNode.SessionId'")) {
						$value = test-angleBrackets $value
						$textArray += $tabString * $tabCount + "$key`: $value"
					}
				}

				# nornal string
				elseif ($value.length -gt 0) {
					$value = $value	-replace '\\', '\\' `
									-replace '\$', '\$' `
									-replace "'", "\'" `
									-replace '\r', '\r' `
									-replace '\n', '\n' `
									-replace '\f', '\f' `
									-replace '\t', '\t' `
									-replace '\v', '\v'
					$textArray += $tabString * $tabCount + "$key`: '$value'"
				}
			}

			# BOOL
			elseif ($value -is [boolean]) {
				$bool = ($value -as [string]).toLower()
				$textArray += $tabString * $tabCount + "$key`: $bool"
			}

			# NUMERIC
			else {
				$textArray += $tabString * $tabCount + "$key`: $value"
			}
		}
	}

	if ($tabCount -eq 1) {
		$textArray += '}'
	}

	# return result with original data type
	Write-Output -NoEnumerate $textArray
}

#--------------------------------------------------------------
function add-resourcesALL {
#--------------------------------------------------------------
	param (
		$resource,
		$azres
	)

	if (!$useBicep) {
		$script:resourcesALL += $resource
		return
	}

	# resource read by cmdlet (two parameters provided)
	if ($Null -ne $azres) {
		$resource.name 				= $az_res.Name
		$resource.resourceGroupName	= $az_res.ResourceGroupName

		# tags for most resources
		$tags = $az_res.Tags -as [hashtable]
		if ($tags.count -gt 0) {
			$resource.tags = $tags
		}
		# tags for some resources
		else {
			$tags = $az_res.Tag -as [hashtable]
			if ($tags.count -gt 0) {
				$resource.tags = $tags
			}
		}
		
		# zones
		$zones = $az_res.Zones -as [array]
		if ($zones.count -gt 0) {
			$resource.zones = $zones
		}
	}

	# resource manually added
	else {
		$resource.resourceGroupName = $sourceRG
	}

	$bicepName = get-bicepNameByType $resource.type $resource.name
	$resource.location		= '<regionName>'
	$resource.bicepName		= $bicepName

	# add resource
	$script:resourcesALL += $resource
}

#--------------------------------------------------------------
function add-az_virtualMachines {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_virtualMachines) {

		$dependsOn = @()

		#--------------------------------------------------------------
		# OS disk
		$disk = $az_res.StorageProfile.OsDisk
		$bicepName = get-bicepNameByType 'Microsoft.Compute/disks' $disk.Name

		$osDisk				= @{
			name					= $disk.Name
			osType					= $disk.OsType -as [string]
			caching					= $disk.Caching -as [string]
			writeAcceleratorEnabled	= convertTo-Boolean $disk.WriteAcceleratorEnabled
			createOption			= 'Attach'
			deleteOption			= $disk.DeleteOption -as [string]
			managedDisk				= @{
				id = "<$bicepName`.id>"
			}
		}
		# needed for dual deployment (disks)
		if ($script:dualDeployment) {
			$dependsOn += "<$bicepName>"
		}

		#--------------------------------------------------------------
		# data disks
		$dataDisks = @()
		foreach ($disk in $az_res.StorageProfile.DataDisks) {
			$bicepName = get-bicepNameByType 'Microsoft.Compute/disks' $disk.Name

			$dataDisks += @{
				name					= $disk.Name
				caching					= $disk.Caching -as [string]
				writeAcceleratorEnabled	= convertTo-Boolean $disk.WriteAcceleratorEnabled
				createOption			= 'Attach'
				deleteOption			= $disk.DeleteOption -as [string]
				lun						= $disk.Lun
				managedDisk				= @{
					id = "<$bicepName`.id>"
				}
			}
			# needed for dual deployment (disks)
			if ($script:dualDeployment) {
				if ($script:copyDisks[$disk.Name].Skip -ne $True) {
					$dependsOn += "<$bicepName>"
				}
			}
		}

		#--------------------------------------------------------------
		# storageProfile
		$storageProfile = @{
			osDisk				= $osDisk
			dataDisks			= $dataDisks
		}

		$diskControllerType = $az_res.StorageProfile.DiskControllerType -as [string]
		if ($diskControllerType -eq 'NVMe') {
			$storageProfile.diskControllerType = $diskControllerType
		}

		#--------------------------------------------------------------
		# NetworkInterfaces
		$networkInterfaces = @()
		foreach ($nic in $az_res.NetworkProfile.NetworkInterfaces) {
			$bicepName = get-bicepNameById $nic.Id
			$networkInterfaces += @{
				properties = @{
					deleteOption	= $nic.DeleteOption -as [string]
					primary			= convertTo-Boolean $nic.Primary
				}
				id = "<$bicepName`.id>"
			}
		}

		#--------------------------------------------------------------
		# additionalCapabilities
		if ($Null -eq $az_res.AdditionalCapabilities) {
			$additionalCapabilities = $Null
		}
		else {
			$additionalCapabilities = @{
				hibernationEnabled	= convertTo-Boolean $az_res.AdditionalCapabilities.HibernationEnabled
				ultraSSDEnabled		= convertTo-Boolean $az_res.AdditionalCapabilities.UltraSSDEnabled
			}
		}


		#--------------------------------------------------------------
		# securityProfile
		if ($Null -eq $az_res.SecurityProfile) {
			$securityProfile = $Null
		}
		else {
			if ($Null -eq $az_res.SecurityProfile.UefiSettings) {
				$uefiSettings = $Null
			}
			else {
				$uefiSettings = @{
					secureBootEnabled 	= convertTo-Boolean $az_res.SecurityProfile.UefiSettings.SecureBootEnabled
					vTpmEnabled			= convertTo-Boolean $az_res.SecurityProfile.UefiSettings.VTpmEnabled
				}
			}

			$securityProfile = @{
				encryptionAtHost	= convertTo-Boolean $az_res.SecurityProfile.EncryptionAtHost
				securityType		= $az_res.SecurityProfile.SecurityType -as [string]
				uefiSettings		= $uefiSettings
			}
		}

		#--------------------------------------------------------------
		# properties
		$properties = @{
			additionalCapabilities	= $additionalCapabilities
			# applicationProfile
			availabilitySet			= get-bicepIdStructById $az_res.AvailabilitySetReference.Id
			# billingProfile
			# capacityReservation
			diagnosticsProfile = @{
				bootDiagnostics 	= @{
					enabled			= convertTo-Boolean $az_res.DiagnosticsProfile.BootDiagnostics.Enabled
					storageUri		= $az_res.DiagnosticsProfile.BootDiagnostics.StorageUri -as [string]
				}
			}
			evictionPolicy			= $az_res.EvictionPolicy
			# extensionsTimeBudget
			hardwareProfile = @{
				vmSize = $az_res.HardwareProfile.VmSize -as [string]
				# vmSizeProperties (in preview)
			}
			# host
			# hostGroup
			licenseType				= $az_res.LicenseType
			networkProfile = @{
				# networkApiVersion
				# networkInterfaceConfigurations
				networkInterfaces	= $networkInterfaces
			}
			# osProfile
			platformFaultDomain 	= $az_res.PlatformFaultDomain
			priority				= $az_res.Priority
			proximityPlacementGroup	= get-bicepIdStructById $az_res.ProximityPlacementGroup.Id
			# scheduledEventsProfile
			securityProfile 		= $securityProfile
			storageProfile 			= $storageProfile
			userData				= $az_res.UserData
			virtualMachineScaleSet	= get-bicepIdStructById $az_res.VirtualMachineScaleSet.Id
		}

		#--------------------------------------------------------------
		# identities
		$identity = $Null
		if (!$patchMode) {
			if ($skipIdentities -or ($az_res.Identity.Type -notlike '*UserAssigned*')) {
				if ($az_res.Identity.count -ne 0) {
					write-logFileUpdates 'virtualMachines' $az_res.Name 'delete Identities'
					$identity = $Null
				}
			}
			else {
				write-logFileUpdates 'virtualMachines' $az_res.Name 'keep user assigned Identities'
				$identity = @{
					type = 'UserAssigned'
					userAssignedIdentities = @{}
				}

				$count = 0
				foreach ($id in $az_res.Identity.UserAssignedIdentities.Keys) {
					$name = ($id -split '/')[8]

					# remove azSecPack identity when copying to a different region
					if (($sourceLocation -eq $targetLocation) -or ($name -notlike '*AzSecPackAutoConfigUA-*' )) {
						$identity.userAssignedIdentities.$id = @{}
						$count += 1
					}
				}

				if ($count -eq 0) {
					$identity = $Null
				}
			}
		}

		# create resource
		$resource = @{
			type 				= 'Microsoft.Compute/virtualMachines'
			apiVersion			= '2022-11-01'
			properties			= $properties
			dependsOn			= @($dependsOn | Sort-Object -Unique)
			# ExtendedLocation
		}

		if ($Null -ne $identity) {
			$resource.identity = $identity
		}

		$vmLocation = $az_res.Location
		if ($sourceLocation -ne $vmLocation) {
			write-logFileError "VM '$($az_res.Name)' is in different region" `
								"Source region: '$sourceLocation'" `
								"VM region: '$vmLocation'"
		}

		add-resourcesALL $resource $az_res
	}
}

#--------------------------------------------------------------
function add-az_virtualNetworks {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_virtualNetworks) {

		# Subnets
		$subnets = @()
		foreach ($sub in $az_res.Subnets) {

			$delegations = @()
			foreach ($del in $sub.Delegations) {
				$delegation = @{
					name = $del.Name
					properties	= @{
						serviceName = $del.ServiceName
					}
				}
				$delegations += $delegation
			}

			$subnet = @{
				name = $sub.Name
				properties = @{
					addressPrefix			= $sub.AddressPrefix[0]
					networkSecurityGroup	= get-bicepIdStructById $sub.NetworkSecurityGroup.Id
					delegations				= $delegations
				}
			}

			if (!$skipNatGateway) {
				$subnet.properties.natGateway = get-bicepIdStructById $sub.NatGateway.Id
			}

			$subnets += $subnet
		}

		# create resource
		$resource = @{
			type 				= 'Microsoft.Network/virtualNetworks'
			apiVersion			= '2022-05-01'
			properties			= @{
				addressSpace = @{
					addressPrefixes = $az_res.AddressSpace.AddressPrefixes -as [array]
				}
				subnets		= $subnets
			} 
		}

		add-resourcesALL $resource $az_res
	}
}

#--------------------------------------------------------------
function add-az_networkInterfaces {
#--------------------------------------------------------------

	foreach ($az_res in $script:az_networkInterfaces) {

		$ipConfigurations = @()
		$dependsOn = @()

		# ipConfigurations
		foreach ($conf in $az_res.IpConfigurations) {

			# loadBalancerBackendAddressPools
			$backendAddressPools = @()
			foreach ($item in $conf.LoadBalancerBackendAddressPools) {
				$backendAddressPools += get-bicepResourceFunctionById $item.Id ([ref] $dependsOn)
			}

			# loadBalancerInboundNatRules
			$inboundNatRules = @()
			foreach ($item in $conf.LoadBalancerInboundNatRules) {
				$inboundNatRules += get-bicepResourceFunctionById $item.Id ([ref] $dependsOn)
			}

			$ipConfig = @{
				name 		= $conf.Name
				properties 	= @{
					privateIPAllocationMethod		= $conf.PrivateIpAllocationMethod -as [string]
					privateIPAddressVersion			= $conf.PrivateIpAddressVersion
					privateIPAddress				= $conf.PrivateIpAddress
					primary							= $conf.Primary
					publicIPAddress					= get-bicepIdStructById $conf.PublicIpAddress.Id -forceBicep
					loadBalancerBackendAddressPools	= $backendAddressPools
					loadBalancerInboundNatRules		= $inboundNatRules
				}
			}

			if ($cloneOrMergeMode) {
				$ipConfig.properties.subnet = get-bicepIdStructById $conf.Subnet.Id
			}
			else {
				$ipConfig.properties.subnet = get-bicepResourceFunctionById $conf.Subnet.Id ([ref] $dependsOn)
			}

			$ipConfigurations += $ipConfig
		}

		# # dnsSettings
		# if (!$cloneOrMergeMode -or ($Null -eq $az_res.DnsSettings)) {
		# 	$dnsSettings = $Null
		# }
		# else {
		# 	dnsServers = $az_res.
		# }

		# properties
		$properties = @{
			# auxiliaryMode				= $az_res.AuxiliaryMode
			# auxiliarySku				= $az_res.AuxiliarySku
			disableTcpStateTracking		= convertTo-Boolean $az_res.DisableTcpStateTracking
			# dnsSettings					= $dnsSettings


			enableAcceleratedNetworking = $az_res.EnableAcceleratedNetworking
			ipConfigurations			= $ipConfigurations
			networkSecurityGroup		= get-bicepIdStructById $az_res.NetworkSecurityGroup.Id
		}

		# create resource
		$dependsOn = @($dependsOn | Sort-Object -Unique)
		$resource = @{
			type 				= 'Microsoft.Network/networkInterfaces'
			apiVersion			= '2023-02-01'
			dependsOn 			= $dependsOn 
			properties			= $properties
			# extendedLocation
		}

		add-resourcesALL $resource $az_res
	}
}

#--------------------------------------------------------------
function add-az_publicIPAddresses {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_publicIPAddresses) {

		if ($setIpTag.length -ne 0) {
			# create new IP tag
			$ipTags = @(
				@{
					ipTagType	= $setIpTagType
					tag			= $setIpTag
				}
			)
		}

		elseif ('setIpTag' -notin $boundParameterNames) {
			# copy existing IP tags
			$ipTags = @()
			foreach ($tag in $az_res.IpTags) {
				if ($tag.Tag.Length -ne 0) {
					$ipTags += @{
						ipTagType	= $tag.IpTagType
						tag			= $tag.Tag
					}
				}
			}
		}

		else {
			# delete IP tags
			$ipTags = @()
		}

		# create resource
		$resource = @{
			type 				= 'Microsoft.Network/publicIPAddresses'
			apiVersion			= '2022-11-01'
			sku					= @{
				name = $az_res.Sku.Name -as [string]
			}
			properties			= @{
				publicIPAddressVersion		= $az_res.PublicIpAddressVersion -as [string]
				publicIPAllocationMethod	= $az_res.PublicIpAllocationMethod -as [string]
				idleTimeoutInMinutes		= $az_res.IdleTimeoutInMinutes
				ipTags						= $ipTags
			}
		}

		add-resourcesALL $resource $az_res
	}
}

#--------------------------------------------------------------
function test-angleBrackets {
#--------------------------------------------------------------
	param (
		$string
	)

	if ($string -like '<*>') {
		$string = $string	-replace '<', '' `
							-replace '>', ''
	}

	return $string
}

#--------------------------------------------------------------
function add-az_networkSecurityGroups {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_networkSecurityGroups) {
		
		$securityRules = @()
		foreach ($rule in $az_res.SecurityRules) {

			$securityRule = @{
				name				= $rule.Name
				properties			= @{
					access						= $rule.Access -as [string]
					description					= test-angleBrackets $rule.Description
					# destinationApplicationSecurityGroups
					direction					= $rule.Direction -as [string]
					priority					= $rule.Priority
					protocol					= $rule.Protocol -as [string]
					# sourceApplicationSecurityGroups
				}
			}

			$daPrefixes = @($rule.DestinationAddressPrefix)
			if ($daPrefixes.count -gt 1) {
				$securityRule.properties.destinationAddressPrefixes = $daPrefixes
			}
			elseif ($daPrefixes.count -eq 1) {
				$securityRule.properties.destinationAddressPrefix = $daPrefixes[0]
			}

			$daPortRange = @($rule.DestinationPortRange)
			if ($daPortRange.count -gt 1) {
				$securityRule.properties.destinationPortRanges = $daPortRange
			}
			elseif ($daPortRange.count -eq 1) {
				$securityRule.properties.destinationPortRange = $daPortRange[0]
			}

			$saPrefixes = @($rule.SourceAddressPrefix)
			if ($saPrefixes.count -gt 1) {
				$securityRule.properties.sourceAddressPrefixes = $saPrefixes
			}
			elseif ($saPrefixes.count -eq 1) {
				$securityRule.properties.sourceAddressPrefix = $saPrefixes[0]
			}

			$saPortRange = @($rule.SourcePortRange)
			if ($saPortRange.count -gt 1) {
				$securityRule.properties.sourcePortRanges = $saPortRange
			}
			elseif ($saPortRange.count -eq 1) {
				$securityRule.properties.sourcePortRange = $saPortRange[0]
			}

			# check for parameter skipSecurityRules
			$toBedeleted = $False
			foreach ($ruleNamePattern in $skipSecurityRules) {
				if ($rule.Name -like $ruleNamePattern) {
					$toBedeleted = $True
				}
			}

			if (!$toBedeleted) {
				$securityRules += $securityRule 
			}
		}

		# create resource
		$resource = @{
			type 				= 'Microsoft.Network/networkSecurityGroups'
			apiVersion			= '2022-11-01'
			properties			= @{
				securityRules = $securityRules
			}
		}

		add-resourcesALL $resource $az_res
	}
}

#--------------------------------------------------------------
function add-az_publicIPPrefixes {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_publicIPPrefixes) {

		# create resource
		$resource = @{
			type 				= 'Microsoft.Network/publicIPPrefixes'
			apiVersion			= '2022-11-01'
			sku					= @{
				name = $az_res.Sku.Name -as [string]
			}
			properties			= @{
				prefixLength			= $az_res.PrefixLength
				publicIPAddressVersion	= $az_res.PublicIpAddressVersion -as [string]
			}
		}

		add-resourcesALL $resource $az_res
	}
}

#--------------------------------------------------------------
function add-az_natGateways {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_natGateways) {

		$publicIpAddresses = @()
		foreach ($ip in $az_res.PublicIpAddresses) {
			$publicIpAddresses += get-bicepIdStructById $ip.Id
		}

		$publicIpPrefixes = @()
		foreach ($prefix in $az_res.PublicIpPrefixes) {
			$publicIpPrefixes += get-bicepIdStructById $prefix.Id
		}

		# create resource
		$resource = @{
			type 				= 'Microsoft.Network/natGateways'
			apiVersion			= '2022-11-01'
			sku					= @{
				name = $az_res.Sku.Name -as [string]
			}
			properties		= @{
				idleTimeoutInMinutes	= $az_res.IdleTimeoutInMinutes
				publicIpAddresses		= $publicIpAddresses
				publicIpPrefixes		= $publicIpPrefixes
			}
		}

		add-resourcesALL $resource $az_res
	}
}

#--------------------------------------------------------------
function add-az_bastionHosts {
#--------------------------------------------------------------
	if ($skipBastion) {
		return
	}

	foreach ($az_res in $script:az_bastionHosts) {

		$dependsOn = @()
		$ipConfigurations = @()
		foreach ($conf in $az_res.IpConfigurations) {

			$ipConfiguration = @{
				name		= $conf.Name
				properties = @{
					privateIPAllocationMethod	= $conf.PrivateIpAllocationMethod -as [string]
					publicIPAddress 			= get-bicepIdStructById $conf.PublicIpAddress.Id
					subnet						= get-bicepResourceFunctionById $conf.Subnet.Id ([ref] $dependsOn)
				}
			}

			$ipConfigurations += $ipConfiguration
		}

		# properties
		$properties		= @{
			dnsName		= $az_res.DnsName
			scaleUnits	= $az_res.ScaleUnit
			ipConfigurations = $ipConfigurations
		}

		# create resource
		$resource = @{
			type 				= 'Microsoft.Network/bastionHosts'
			apiVersion			= '2022-11-01'
			sku					= @{
				name = $az_res.Sku.Name -as [string]
			}
			dependsOn 		= $dependsOn 
			properties		= $properties
		}

		add-resourcesALL $resource $az_res
	}
}

#--------------------------------------------------------------
function add-az_availabilitySets {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_availabilitySets) {

		# properties
		$properties =  @{
			platformUpdateDomainCount	= $az_res.PlatformUpdateDomainCount
			platformFaultDomainCount	= $az_res.PlatformFaultDomainCount
			virtualMachines				= $virtualMachines
			proximityPlacementGroup		= get-bicepIdStructById $az_res.ProximityPlacementGroup.Id
		}

		# create resource
		$resource =  @{
			type 				= 'Microsoft.Compute/availabilitySets'
			apiVersion			= '2023-03-01'
			sku					= @{
				name = $az_res.Sku -as [string] # "$az_res.Sku", not "$az_res.Sku.Name" !
			}
			properties			= $properties
		}

		add-resourcesALL $resource $az_res
	}
}

#--------------------------------------------------------------
function add-az_proximityPlacementGroups {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_proximityPlacementGroups) {

		# create resource
		$resource = @{
			type 				= 'Microsoft.Compute/proximityPlacementGroups'
			apiVersion			= '2023-03-01'
			properties			= @{
				proximityPlacementGroupType	= $az_res.ProximityPlacementGroupType -as [string]
			}
		}

		add-resourcesALL $resource $az_res
	}
}

#--------------------------------------------------------------
function add-az_loadBalancers {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_loadBalancers) {

		$backendAddressPools = @()
		$frontendIPConfigurations = @()
		$inboundNatPools = @()
		$inboundNatRules = @()
		$loadBalancingRules	= @()
		$outboundRules = @()
		$loadBalancingProbes = @()

		$dependsOn = @()

		#--------------------------------------------------------------
		# backendAddressPools
		foreach ($pool in $az_res.BackendAddressPools) {

			$addressPool = @{
				name = $pool.Name
			}

			$backendAddressPools += $addressPool
		}

		#--------------------------------------------------------------
		# frontendIPConfigurations
		foreach ($conf in $az_res.FrontendIpConfigurations) {

			$ipConfig = @{
				name		= $conf.Name
				properties	= @{
					# gatewayLoadBalancer
					privateIPAddress			= $conf.PrivateIpAddress
					privateIPAddressVersion		= $conf.PrivateIpAddressVersion
					privateIPAllocationMethod	= $conf.PrivateIpAllocationMethod -as [string]
					publicIPAddress				= get-bicepIdStructById $conf.PublicIpAddress.Id
					publicIPPrefix				= get-bicepIdStructById $conf.PublicIPPrefix.Id
					subnet						= get-bicepResourceFunctionById $conf.Subnet.Id ([ref] $dependsOn)
				}
			}

			$zones = @()
			foreach ($zone in $conf.Zones) {
				$zones += $zone -as [string]
			}

			if ($zones.count -gt 0) {
				$ipConfig.zones = $zones 
			}

			$frontendIPConfigurations += $ipConfig
		}

		#--------------------------------------------------------------
		# inboundNatPools
		foreach ($pool in $az_res.inboundNatPools) {
			$natpool = @{
				name		= $pool.Name
				properties	= @{
					backendPort					= $pool.BackendPort
					enableFloatingIP			= $pool.EnableFloatingIP
					enableTcpReset				= $pool.EnableTcpReset
					frontendIPConfiguration		= get-bicepResourceFunctionById $pool.FrontendIPConfiguration.Id
					frontendPortRangeEnd		= $pool.FrontendPortRangeEnd
					frontendPortRangeStart		= $pool.FrontendPortRangeStart
					idleTimeoutInMinutes		= $pool.IdleTimeoutInMinutes
					protocol					= $pool.Protocol
				}
			}
			$inboundNatPools += $natpool
		}
		#--------------------------------------------------------------
		# inboundNatRules
		foreach ($rule in $az_res.InboundNatRules) {
			$natrule = @{
				name		= $rule.Name
				properties	= @{
					backendAddressPool			= get-bicepResourceFunctionById $rule.BackendAddressPool.Id
					backendPort					= $rule.BackendPort
					enableFloatingIP			= $rule.EnableFloatingIP
					enableTcpReset				= $rule.EnableTcpReset
					frontendIPConfiguration		= get-bicepResourceFunctionById $rule.FrontendIPConfiguration.Id
					frontendPort				= $rule.FrontendPort
					frontendPortRangeEnd		= $rule.FrontendPortRangeEnd
					frontendPortRangeStart		= $rule.FrontendPortRangeStart
					idleTimeoutInMinutes		= $rule.IdleTimeoutInMinutes
					protocol					= $rule.Protocol
				}
			}
			$inboundNatRules += $natrule
		}

		#--------------------------------------------------------------
		# loadBalancingRules
		foreach ($rule in $az_res.LoadBalancingRules) {

			$pools = @()
			foreach ($pool in $rule.BackendAddressPools) {
				$pools += get-bicepResourceFunctionById $pool.Id
			}

			$lbRule = @{
				name = $rule.Name
				properties = @{
					backendAddressPool		= get-bicepResourceFunctionById $rule.BackendAddressPool.Id
					backendAddressPools		= $pools
					backendPort				= $rule.BackendPort
					disableOutboundSnat		= $rule.DisableOutboundSNAT
					enableFloatingIP		= $rule.EnableFloatingIP
					enableTcpReset			= $rule.EnableTcpReset
					frontendIPConfiguration	= get-bicepResourceFunctionById $rule.FrontendIPConfiguration.Id
					frontendPort			= $rule.FrontendPort
					idleTimeoutInMinutes	= $rule.IdleTimeoutInMinutes
					loadDistribution		= $rule.LoadDistribution -as [string]
					probe					= get-bicepResourceFunctionById $rule.Probe.Id
					protocol				= $rule.Protocol -as [string]
				}
			}
			
			$loadBalancingRules += $lbRule
		}

		#--------------------------------------------------------------
		# outboundRules
		foreach ($rule in $az_res.OutboundRules) {

			$frontendConfigs = @()
			foreach ($frontendConfig in $rule.FrontendIPConfigurations) {
				$frontendConfigs += get-bicepResourceFunctionById $frontendConfig.Id
				
			}

			$obrule = @{
				name = $rule.Name
				properties = @{
					allocatedOutboundPorts		= $rule.AllocatedOutboundPorts
					backendAddressPool			= get-bicepResourceFunctionById $rule.BackendAddressPool.Id
					enableTcpReset				= $rule.EnableTcpReset
					frontendIPConfigurations	= $frontendConfigs
					idleTimeoutInMinutes		= $rule.IdleTimeoutInMinutes
					protocol					= $rule.Protocol
				}
			}

			$outboundRules += $obrule
		}

		#--------------------------------------------------------------
		# probes
		foreach ($probe in $az_res.Probes) {

			$lbProbe = @{
				name = $probe.Name
				properties = @{
					intervalInSeconds	= $probe.IntervalInSeconds
					numberOfProbes		= $probe.NumberOfProbes
					port				= $probe.Port
					probeThreshold		= $probe.ProbeThreshold
					protocol			= $probe.Protocol -as [string]
					requestPath			= $probe.RequestPath
				}
			}

			$loadBalancingProbes += $lbProbe
		}

		#--------------------------------------------------------------
		# create resource
		$dependsOn = @($dependsOn | Sort-Object -Unique)

		# $extendedLocation = $Null
		# if ($Null -ne $az_res.ExtendedLocation) {
		# 	$extendedLocation = @{
		# 		name = $az_res.ExtendedLocation.Name
		# 		type = $az_res.ExtendedLocation.Type -as [string]
		# 	}
		# }

		# $extendedLocation = $az_res.ExtendedLocation

		$resource = @{
			type 				= 'Microsoft.Network/loadBalancers'
			apiVersion			= '2023-02-01'
			sku					= @{
				name = $az_res.Sku.Name -as [string]
				tier = $az_res.Sku.Tier -as [string]
			}
			# extendedLocation	= $extendedLocation
			dependsOn 			= $dependsOn

			properties			=  @{
				backendAddressPools			= $backendAddressPools
				frontendIPConfigurations	= $frontendIPConfigurations
				inboundNatPools				= $inboundNatPools
				inboundNatRules				= $inboundNatRules
				loadBalancingRules			= $loadBalancingRules
				outboundRules				= $outboundRules
				probes						= $loadBalancingProbes
			}
		}

		add-resourcesALL $resource $az_res
	}
}


#--------------------------------------------------------------
function add-az_virtualMachineScaleSet {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_virtualMachineScaleSets) {

		# create resource
		$resource = @{
			type 				= 'Microsoft.Compute/virtualMachineScaleSets'
			apiVersion			= '2023-03-01'
			properties			= @{
				singlePlacementGroup		= $az_res.SinglePlacementGroup
				orchestrationMode			= $az_res.OrchestrationMode -as [string]
				platformFaultDomainCount	= $az_res.PlatformFaultDomainCount
			}
		}

		add-resourcesALL $resource $az_res
	}
}

#-------------------------------------------------------------
function step-prepareClone {
#--------------------------------------------------------------
	if (!$cloneMode) {
		return
	}

	write-stepStart 'Prepare source RG for clone VMs'

	write-logFile ('-' * $starCount) -ForegroundColor 'Red'
	write-logFile -ForegroundColor 'red' "The follwing VMs will be stopped and Azure lock 'ReadOnly' will be set:"
	write-logFile ('-' * $starCount) -ForegroundColor 'Red'
	foreach ($vm in $cloneVMs) {
		write-logFile $vm
	}
	write-logFile

	if ($simulate) {
		write-logFile "Enter 'yes' to continue" -ForegroundColor 'Red'
		write-logFile
		write-logFile "answer not needed in simulation mode"
	}
	else {
		$answer = Read-Host "Enter 'yes' to continue"
		write-logFile
		if ($answer -ne 'yes') {
			write-logFile "The answer was '$answer'"
			write-zipFile 0
		}
	}

	if (!$simulate) {
		# stopping VMs serially
		$script:sourceVMs
		| Where-Object Name -in $cloneVMs
		| ForEach-Object {
			
			$vmName = $_.Name

			if ($_.PowerState -ne 'VM deallocated') {
				write-logFile "Stopping VM '$vmName'..."
				Stop-AzVM `
					-Force `
					-Name 				$vmName `
					-ResourceGroupName 	$sourceRG `
					-WarningAction 'SilentlyContinue' `
					-ErrorAction 'SilentlyContinue' | Out-Null
				test-cmdlet 'Stop-AzVM'  "Could not stop VM '$vmName'" `
							"Make sure that no Resource Lock is already set"
			}

			write-logFile "Setting ReadOnly lock for VM '$vmName'..."
			New-AzResourceLock `
				-LockLevel 'ReadOnly' `
				-LockName "ReadOnly" `
				-ResourceName $vmName `
				-ResourceGroupName $sourceRG `
				-ResourceType 'microsoft.compute/virtualMachines' `
				-Force | Out-Null
			test-cmdlet 'New-AzResourceLock'  "Could not set resource lock ReadOnly for VM '$vmName"
		}
	}
	write-stepEnd
}

#--------------------------------------------------------------
function step-armTemplate {
#--------------------------------------------------------------
	if ($skipArmTemplate) {
		return
	}

	# count parameter changes caused by default values:
	$script:countDiskSku				= 0
	$script:countVmZone					= 0
	$script:countPrivateIpAlloc			= 0
	$script:countAcceleratedNetworking	= 0
	# do not count modifications if parameter was supplied explicitly
	if ('setDiskSku'				-in $boundParameterNames) { $script:countDiskSku				= -999999}
	if ('setVmZone'					-in $boundParameterNames) { $script:countVmZone					= -999999}
	if ('setPrivateIpAlloc'			-in $boundParameterNames) { $script:countPrivateIpAlloc			= -999999}
	if ('setAcceleratedNetworking'	-in $boundParameterNames) { $script:countAcceleratedNetworking	= -999999}

	# create termplate
	# BICEP
	if ($useBicep) {
		write-stepStart "Create BICEP template"

		get-az_local
		new-templateBicep
	}

	# ARM
	else {
		write-stepStart "Create ARM template"

		new-templateSource
		new-templateTarget
	}

	write-logFile

	# changes caused by default value
	if ($copyMode) {
		if ($script:countDiskSku				-gt 0) { write-changedByDefault "setDiskSku = $setDiskSku" }
		if ($script:countVmZone					-gt 0) { write-changedByDefault "setVmZone = $setVmZone" }
		if (!$cloneOrMergeMode) {
			if ($script:countPrivateIpAlloc		-gt 0) { write-changedByDefault "setPrivateIpAlloc = $setPrivateIpAlloc" }
		}
		if ($script:countAcceleratedNetworking	-gt 0) { write-changedByDefault "setAcceleratedNetworking = $setAcceleratedNetworking" }
		write-logFile
	}

	if (!$useBicep) {
		# resources not read from source RG
		if ($script:importWarnings.count -ne 0) {
			write-logFileWarning "The following resources could not be exported from the source RG:"
			foreach ($warning in $importWarnings) {
				write-logFile $warning
			}
			write-logFile
		}

		# resources not copied
		$deniedResources = @{}
		$script:deniedProperties.keys | ForEach-Object {
			$level1,$level2,$level3,$level4,$level5,$level6 = $_ -split '  '
			if ($level2.length -eq 0) {
				$area,$type,$subtypes = $level1 -split '/'
				$deniedResources."$area/$type" = $True
			}
		}
		$deniedResources."Microsoft.Storage/storageAccounts"			= $True
		$deniedResources."Microsoft.Compute/snapshots"					= $True
		$deniedResources."Microsoft.Compute/images"						= $True
		$deniedResources."Microsoft.Compute/virtualMachines/extensions" = $True
		$deniedResourcesKeys= $deniedResources.keys | Sort-Object

		write-logFileWarning "The following resource types in the source RG were not copied:"
		foreach ($resource in $deniedResourcesKeys) {
			write-logFile $resource
		}

		# write target ARM template to local file
		$text = $script:sourceTemplate | ConvertTo-Json -Depth 20
		Set-Content -Path $exportPath -Value $text -ErrorAction 'SilentlyContinue'
		if (!$?) {
			write-logFileError "Could not save target template" `
									"Failed writing file '$exportPath'"
		}
		write-logFile -ForegroundColor 'Cyan' "Target template saved: $exportPath"
		$script:armTemplateFilePaths += $exportPath
	}
	
	#--------------------------------------------------------------
	# output of priority
	#--------------------------------------------------------------
	if ($setVmDeploymentOrder.count -ne 0) {

		$script:copyVMs.Values
		| Sort-Object VmPriority,Name
		| Select-Object `
			@{label="Deployment Order"; expression={
				if ($_.VmPriority -ne 2147483647) {
					$_.VmPriority
				}
				else {
					''
				}
			}}, `
			Name
		| Format-Table
		| write-LogFilePipe
	}
	write-stepEnd

	#--------------------------------------------------------------
	write-stepStart "Configured VMs/disks for Target Resource Group $targetRG" -skipLF
	#--------------------------------------------------------------
	show-targetVMs
	compare-quota
	write-stepEnd
}

#--------------------------------------------------------------
function step-snapshots {
#--------------------------------------------------------------
	if (!$skipSnapshots -and !$simulate) {
		# run PreSnapshotScript
		if ($pathPreSnapshotScript.length -ne 0) {

			# start VMs
			start-VMs $sourceRG

			# start SAP
			start-sap $sourceRG | Out-Null
			$script:vmStartWaitDone = $False

			# run pre-snapshot script
			invoke-localScript $pathPreSnapshotScript 'pathPreSnapshotScript'

			# wait before snapshots
			write-logFile "Waiting $preSnapshotWaitSec seconds after running PreSnapshotScript ..."
			write-logFile "(delay can be configured using RGCOPY parameter 'preSnapshotWaitSec')"
			write-logFile
			Start-Sleep -seconds $preSnapshotWaitSec

			# Get running VMs
			$script:sourceVMs = @( Get-AzVM `
										-ResourceGroupName $sourceRG `
										-status `
										-WarningAction	'SilentlyContinue' `
										-ErrorAction 'SilentlyContinue' )
			test-cmdlet 'Get-AzVM'  "Could not get VMs of resource group $sourceRG"

			# stop running VMs
			stop-VMs $sourceRG $script:sourceVMs
		}

		elseif ($stopVMsSourceRG) {
			# stop VMs
			stop-VMs $sourceRG $script:sourceVMs
		}

		# create snapshots of disks
		new-snapshots

		# create snapshots of NetApp volumes
		if (!$justCreateSnapshots) {
			new-SnapshotsVolumes
		}
	}
	elseif ($stopVMsSourceRG -and !$simulate) {
		stop-VMs $sourceRG $script:sourceVMs
	}

	show-snapshots
}

#--------------------------------------------------------------
function step-backups {
#--------------------------------------------------------------
	if ($skipBackups -or ($script:mountPointsCount -eq 0)) {
		return
	}

	# simulate running Tasks for restartRemoteCopy
	$script:runningTasks = @()
	# collect not-running VMs
	$script:toBeStartedVMs = @()

	$script:copyVMs.values
	| Where-Object {$_.MountPoints.count -ne 0}
	| ForEach-Object {

		$script:runningTasks += @{
			vmName 		= $_.Name
			mountPoints	= $_.MountPoints.Path
			action		= 'backup'
			finished 	= $False
		}

		if ($_.VmStatus -ne 'VM running') {
			$script:toBeStartedVMs += $_.Name
		}
	}
	# simulate running Tasks for restartRemoteCopy
	if ($restartRemoteCopy) {
		return
	}

	$script:runningTasks = @()
	
	# start needed VMs (HANA and SAP must NOT auto-start)
	if ($script:toBeStartedVMs.count -ne 0) {
		write-stepStart "Start VMs before backup in Resource Group $sourceRG" $maxDOP
		start-VMsParallel $sourceRG $script:toBeStartedVMs
		write-stepEnd
	}

	write-stepStart "BACKUP VOLUMES/DISKS to NFS share"
	write-logFile "NFS Share for volume backups:"
	write-logFileTab 'Resource Group' $sourceRG
	new-storageAccount $sourceSub $sourceSubID $sourceRG $sourceSA $sourceLocation -fileStorage
	new-endpoint $sourceRG

	# backup
	backup-mountPoint
}

#--------------------------------------------------------------
function save-archiveTemplate {
#--------------------------------------------------------------
	# save RGCOPY PowerShell template
	$text = "# generated script by RGCOPY for restoring
`$param = @{
	# set targetRG:
	targetSub           = '$sourceSub'
	targetRG            = '$sourceRG'
	
	#--- do not change the rest of the parameters:
	sourceSub           = '$targetSub'
	sourceRG            = '$targetRG'
	targetLocation      = '$targetLocation'
	pathArmTemplate     = '$exportPath'
"

	if ($script:dualDeployment ) {
		$text += "	pathArmTemplateDisks = '$exportPathDisks'
"
	}

	$text += "	#---
}
$PSCommandPath @param
"

	Set-Content -Path $restorePath -Value $text -ErrorAction 'SilentlyContinue'
	if (!$?) {
		write-logFileError "Could not save RGCOPY PowerShell template" `
							"Failed writing file '$restorePath'"
	}
	$script:armTemplateFilePaths += $restorePath
	write-zipFile
	if ($script:errorOccured) {
		write-logFileError "Could not save file to storage account BLOB" `
							"File name: '$zipPath2'" `
							"Storage account container: '$targetSaContainer'"
	}
}

#--------------------------------------------------------------
function step-copyBlobsAndSnapshots {
#--------------------------------------------------------------
	if ($simulate) {
		return
	}

	if ($archiveMode) {
		save-archiveTemplate
	}

	if ($blobCopyNeeded -and !$skipRemoteCopy) {
		if (!$restartRemoteCopy) {
			grant-access
			start-copyBlobs
		}
	}

	if ($snapshotCopyNeeded -and !$skipRemoteCopy) {
		if (!$restartRemoteCopy) {
			copy-snapshots
		}
		wait-CopySnapshots
	}

	if ($blobCopyNeeded -and !$skipRemoteCopy) {
		if ($restartRemoteCopy) {
			add-ipRule
			new-delegationToken
			write-logFile
		}
		wait-copyBlobs
		revoke-access
	}

	# wait for backup finished (not done in step step-backups)
	if ($script:runningTasks.count -ne 0) {
		wait-mountPoint
		# stop those VMs that have been started before
		if ($script:toBeStartedVMs.count -ne 0) {
			write-stepStart "Stop VMs after backup in Resource Group $sourceRG" $maxDOP
			stop-VMsParallel $sourceRG $script:toBeStartedVMs
			write-stepEnd
		}
		else {
			write-logFileWarning "Some VMs in source resource group '$sourceRG' are still running"
		}
	}
}

#--------------------------------------------------------------
function step-deployment {
#--------------------------------------------------------------
	if ($skipDeployment) {
		return
	}

	#--------------------------------------------------------------
	# Deploy Virtual Machines
	if (!$skipDeploymentVMs) {

		# creating disks manually
		if ($createDisksManually) {
			new-disks
		}

		# dual deployment: wait for disk creation has finished
		elseif ($dualDeployment) {
			deploy-templateTarget $exportPathDisks "$sourceRG-Disks.$timestampSuffix"
		}
		
		# wait for disk creation completion
		if ($createDisksManually -or $dualDeployment) {

			if (!$(wait-completion "DISK CREATION" `
						'disks' $targetRG $snapshotWaitCreationMinutes)) {

				write-logFileError "Disk creation completion did not finish within $snapshotWaitCreationMinutes minutes"
			}
		}

		# deployment of the rest (with or without disks)
		deploy-templateTarget $exportPath "$sourceRG.$timestampSuffix"
	}

	if (!$cloneOrMergeMode) {
		get-targetVMs
	}

	#--------------------------------------------------------------
	# Restore files
	if (!$skipRestore) { 
		restore-mountPoint
		# this sets $skipRestore = $True if there is nothing to restore
	}
	if (!$skipRestore) {
		wait-mountPoint
		remove-endpoint $targetRG
	}

	#--------------------------------------------------------------
	# Deploy Extensions
	deploy-sapMonitor
	deploy-linuxDiagnostic

	#--------------------------------------------------------------
	# Deploy Monitor Rules
	if ($monitorRG.length -ne 0) {
		deploy-MonitorRules
	}

	#--------------------------------------------------------------
	# run Post Deployment Script
	if ($pathPostDeploymentScript.length -ne 0) {
		start-sap $targetRG | Out-Null
		invoke-localScript $pathPostDeploymentScript 'pathPostDeploymentScript'
	}
}

#--------------------------------------------------------------
function step-workload {
#--------------------------------------------------------------
	if (!$startWorkload) {
		return
	}

	get-targetVMs
	# start workload
	$done = start-sap $targetRG
	if (!$done) {
		write-logFileError "Workload could not be started because SAP is not running"
	}
	else {
		invoke-vmScript $scriptStartLoadPath 'scriptStartLoadPath' $targetRG
		invoke-vmScript $scriptStartAnalysisPath 'scriptStartAnalysisPath' $targetRG
	}
}

#--------------------------------------------------------------
function step-cleanup {
#--------------------------------------------------------------
	if ($skipCleanup) {
		return
	}

	#--------------------------------------------------------------
	# stop VMs
	if ($stopVMsTargetRG) {
		if ($skipDeployment -or $skipDeploymentVMs) {
			write-logFileWarning "parameter 'stopVMsTargetRG' ignored" `
								"The VMs have not been created during the current run of RGCOPY" `
								"Stop the VMs manually"
		}
		else {
			set-context $targetSub # *** CHANGE SUBSCRIPTION **************
			get-targetVMs
			stop-VMs $targetRG $script:targetVMs
		}
	}


	#--------------------------------------------------------------
	# ALWAYS delete snapshots in target RG
	$snapshotNames = ( $script:copyDisks.Values `
						| Where-Object { (($_.DiskSwapNew -eq $True) -or (($_.Skip -ne $True) -and ($_.DiskSwapOld -ne $True))) } `
						| Where-Object SnapshotCopy -eq $True ).SnapshotName

	if ($snapshotNames.count -gt 0) {

		set-context $targetSub # *** CHANGE SUBSCRIPTION **************
		remove-snapshots $targetRG $snapshotNames
	}


	#--------------------------------------------------------------
	# delete snapshots in source RG
	$snapshotNames = ( $script:copyDisks.Values `
						| Where-Object { (($_.DiskSwapNew -eq $True) -or (($_.Skip -ne $True) -and ($_.DiskSwapOld -ne $True))) } `
						| Where-Object SnapshotSwap -ne $True ).SnapshotName

	if ($snapshotNames.count -gt 0) {
		
		if ($deleteSnapshots) {

			set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
			remove-snapshots $sourceRG $snapshotNames
		}
		else {
			write-logFileWarning "Parameter 'deleteSnapshots' was not supplied" `
								"Snapshots '*.rgcopy' in source RG '$sourceRG' have not been deleted"
		}
	}


	#--------------------------------------------------------------
	# delete storage account in source RG
	if ($deleteSourceSA) {

		if ($skipRestore) {
			if ('deleteSourceSA' -in $boundParameterNames) {
				write-logFileWarning "parameter 'deleteSourceSA' ignored" `
									"Storage account '$sourceSA' has not been used during the current run of RGCOPY" `
									"Delete the storage account manually'"
			}
		}
		else {
			set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
			remove-endpoint $sourceRG
			remove-storageAccount $sourceRG $sourceSA
		}
	}


	#--------------------------------------------------------------
	# delete storage account in target RG
	if ($deleteTargetSA) { # set by default

		if ($skipDeployment -or $skipDeploymentVMs) {
			write-logFileWarning "Storage account '$targetSA' has not been deleted" `
								"because disks have not been deployed"

		}
		else {
			set-context $targetSub # *** CHANGE SUBSCRIPTION **************
			remove-storageAccount $targetRG $targetSA
		}
	}
}

#-------------------------------------------------------------
function step-patchMode {
#-------------------------------------------------------------
	write-stepStart "Patching VMs"
	get-shellScripts

	if (!$simulate) {
		start-VMsParallel $sourceRG $patchVMs
	}
	
	foreach ($vmName in $patchVMs) {
			$osType = $script:copyVMs[$vmName].OsDisk.OsType
			write-logFile
			write-logFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') -ForegroundColor 'DarkGray'
			write-logfile '----------------------------------------------------------------------'
			write-logfile "Patch VM '$vmName' ($osType)"
	
			if (!$simulate) {
				if ($script:copyVMs[$vmName].OsDisk.osType -eq 'linux') {
					new-scriptPatch $vmName -Linux
				}
				else {
					new-scriptPatch $vmName -Windows
				}
			}
	}
	write-logFile

	if ($patchVMs.count -eq 0) {
		write-logFileWarning "No VMs to patch"
	}
	else {
		write-logFileWarning "OS patches might still be installing"
	}
	write-stepEnd
}

#--------------------------------------------------------------
function new-scriptPatch {
#--------------------------------------------------------------
	param (
		$vmName,
		[switch] $Linux,
		[switch] $Windows
	)

	if ($Windows) {
		invoke-patchScript $sourceRG $vmName $script:WindowsPatchScript 'RunPowerShellScript'
		
	}

	elseif ($Linux) {
		invoke-patchScript $sourceRG $vmName $script:LinuxPatchScript 'RunShellScript'
	
		# second try for ZYPPER
		if ($script:ZYPPER_EXIT_INF_RESTART_NEEDED -eq $True) {
	
			write-logfile
			write-logfile "Waiting 30 seconds on reboot..."
			write-logfile
			Start-Sleep -seconds 30
	
			invoke-patchScript $sourceRG $vmName $script:LinuxPatchScript 'RunShellScript'
			$script:ZYPPER_EXIT_INF_RESTART_NEEDED = $False
		}
	}
}

#--------------------------------------------------------------
function invoke-patchScript {
#--------------------------------------------------------------
	param (
		$resourceGroup,
		$scriptVm,
		$scriptText,
		$commandId = 'RunShellScript'
	)

	# script parameters
	$parameter = @{
		ResourceGroupName 	= $resourceGroup
		VMName            	= $scriptVM
		CommandId         	= $commandId
		ScriptString 		= $scriptText
		ErrorAction			= 'SilentlyContinue'
	}

	wait-vmAgent $resourceGroup $scriptVm 'PATCH VM'

	# execute script
	write-logFile "SCRIPT RUNNING IN VM" -blinking
	Invoke-AzVMRunCommand @parameter
	| Tee-Object -Variable result
	| Out-Null

	# check results
	if ($result.Status -ne 'Succeeded') {
		write-logFileWarning "Script in VM '$scriptVm' failed" `
							"Script Status is not 'Succeeded': $($result.Status)"
		$script:patchesFailed++
	}
	else {
		$messages = $result.Value[0].Message
		write-logFile $messages -ForegroundColor 'Cyan'

		$script:ZYPPER_EXIT_INF_RESTART_NEEDED = $False
		if ($messages -like '*zypper exit code: 103*') {
			$script:ZYPPER_EXIT_INF_RESTART_NEEDED = $True
		}

		if ($messages -like '*++ exit 1*') {
			write-logFileWarning "Script in VM '$scriptVm' returned exit code 1"
			$script:patchesFailed++
		}

		elseif ($messages -like '*Last script execution didn''t finish*') {
			write-logFileWarning "Script in VM '$scriptVm' failed"
			$script:patchesFailed++
		}
	}
}

#--------------------------------------------------------------
function get-shellScripts {
#--------------------------------------------------------------
	# flag: install only security updates
	$patchSecurity = 1
	if ($patchAll) {
		$patchSecurity = 0
	}

	# flag: patch kernel
	$patchKernelInteger = 0
	if ($patchKernel) {
		$patchKernelInteger = 1
	}

#--------------------------------------------------------------
# Windows patches
#--------------------------------------------------------------
	$category = ''
	if (!$patchAll) {
		$category = " -Category 'Security Updates' "
	}

	$logDir  = "C:\Packages\Plugins\RGCOPY"
	$logFile = "C:\Packages\Plugins\RGCOPY\RGCOPY_WindowsUpdate_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')"

	$script:WindowsPatchScript = @"
New-Item '$logDir' -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider -Name NuGet -Force *>>'$logFile'
Install-Module -Name PSWindowsUpdate -Force *>>'$logFile'
Import-Module PSWindowsUpdate *>>'$logFile'

Get-WUInstallerStatus | Format-Table
Get-WURebootStatus | Format-Table
Get-WULastResults | Format-Table

Write-Host 'Last 10 updates:'
Get-WUHistory -Last 10 | Format-Table

Write-Host 'Starting updates as job and reboot...'

`$string = @'
	Import-Module PSWindowsUpdate
	Get-WindowsUpdate -MicrosoftUpdate -Install $category -AcceptAll -AutoReboot *>>'$logFile'
'@

`$script = [Scriptblock]::Create(`$string)
Start-Job -ScriptBlock `$script *>>'$logFile'
"@

#--------------------------------------------------------------
# Linux patches
#--------------------------------------------------------------
# runs as script.sh
# header file not used. Only parameter patchSecurity is used.
	$script:LinuxPatchScript = 
@"
#!/bin/bash
patchSecurity=$patchSecurity
patchKernel=$patchKernelInteger

$prePatchCommand
`n
"@ + @'
suse=`cat /etc/os-release | grep -i suse | wc -l`
redHat=`cat /etc/os-release | grep -i 'Red Hat' | wc -l`
ubuntu=`cat /etc/os-release | grep -i Ubuntu | wc -l`

echo "SCRIPT_DIRECTORY='$(pwd)'" 1>&2
echo "OS_KERNEL_OLD='$(uname -r)'" 1>&2
echo "$(cat /etc/os-release | grep PRETTY_NAME)" 1>&2

function waitForPatches {
    isSuse=$1
	declare -i waited=0

    if [ $isSuse -gt 0 ]; then
		while [ $(ps -Af | grep zypper | grep -v grep |  wc -l) -gt 0 -a $waited -lt 300 ];
			do
			waited+=5
			echo "waiting $waited seconds for another instance of ZYPPER to finish..."
			sleep 5
			done
    else
		while [ $(ps -Af | grep yum | grep -v grep | wc -l) -gt 0 -a $waited -lt 300 ];
			do
			waited+=5
			echo "waiting $waited seconds for another instance of YUM to finish..."
			sleep 5
			done
    fi
}

if [ $suse -gt 0 ]; then

	waitForPatches $suse
	registercloudguest --force-new
	waitForPatches $suse
	zypper --quiet patch-check
	waitForPatches $suse

	if [ $patchKernel -eq 1 ]; then
		echo " "
		echo "========================================="
		echo "installing kernel update using zypper ..."
		zypper --non-interactive update --with-interactive --auto-agree-with-licenses kernel-default 1> patch.out
		exitCode=$?
		echo "zypper exit code: $exitCode"
		echo "========================================="

		if [ $exitCode -ne 0 ] && [ $exitCode -lt 100 ]; then
			cat patch.out
			echo "++ exit 1"
			exit 1
		fi
	fi

	echo " "
	echo "========================================="
	if [ $patchSecurity -eq 1 ]; then
		echo "installing security patches using zypper ..."
		zypper --non-interactive --quiet patch --with-interactive --auto-agree-with-licenses --category=security 1> patch.out
	else
		echo "installing patches using zypper ..."
		zypper --non-interactive --quiet patch --with-interactive --auto-agree-with-licenses  1> patch.out
	fi
	exitCode=$?
	echo "zypper exit code: $exitCode"
	echo "========================================="

	if [ $exitCode -ne 0 ] && [ $exitCode -lt 100 ]; then
		cat patch.out
		echo ' '
		echo 'waiting 120 seconds and retry...'
		sleep 120

		echo " "
		echo "========================================="
		if [ $patchSecurity -eq 1 ]; then
			echo "installing security patches using zypper ..."
			zypper --non-interactive patch --with-interactive --auto-agree-with-licenses --category=security 1> patch.out
		else
			echo "installing patches using zypper ..."
			zypper --non-interactive patch --with-interactive --auto-agree-with-licenses  1> patch.out
		fi
		exitCode=$?
		echo "zypper exit code: $exitCode"
		echo "========================================="

		if [ $exitCode -ne 0 ] && [ $exitCode -lt 100 ]; then
			cat patch.out
			echo "++ exit 1"
			exit 1
		fi
	fi
	echo " "

	waitForPatches $suse
	zypper --quiet patch-check


elif [ $redHat -gt 0 ]; then

	waitForPatches $suse
	yum update -y --disablerepo='*' --enablerepo='*microsoft*'
	echo 'exclude=WALinuxAgent*' >>/etc/yum.conf
	yum updateinfo
	waitForPatches $suse

	if [ $patchKernel -eq 1 ]; then
		echo " "
		echo "========================================="
		echo "installing kernel update using yum ..."
		yum -y update kernel 1> patch.out
		exitCode=$?
		echo "yum exit code: $exitCode"
		echo "========================================="

		if [ $exitCode -ne 0 ]; then
			cat patch.out
			echo "++ exit 1"
			exit 1
		fi
	fi

	echo " "
	echo "========================================="
	if [ $patchSecurity -eq 1 ]; then
		echo "installing security patches using yum ..."
		yum -y update --security 1> patch.out
	else
		echo "installing patches using yum ..."
		yum -y update 1> patch.out
	fi
	exitCode=$?
	echo "yum exit code: $exitCode"
	echo "========================================="

	if [ $exitCode -ne 0 ]; then
		cat patch.out
		echo ' '
		echo 'waiting 120 seconds and retry...'
		sleep 120

		echo ' '
		echo "========================================="
		if [ $patchSecurity -eq 1 ]; then
			echo "installing security patches using yum ..."
			yum -y update --security 1> patch.out
		else
			echo "installing patches using yum ..."
			yum -y update 1> patch.out
		fi
		exitCode=$?
		echo "yum exit code: $exitCode"
		echo "========================================="

		if [ $exitCode -ne 0 ]; then
			cat patch.out
			echo "++ exit 1"
			exit 1
		fi
		echo " "
	fi
	echo " "

	waitForPatches $suse
	yum updateinfo
	yum list kernel


elif [ $ubuntu -gt 0 ]; then

	apt-get update 1>/dev/null 2>/dev/null
	apt list --upgradable 2>/dev/null | grep "\-security"

	echo " "
	echo "========================================="
	echo "installing security patches using unattended-upgrade ..."
	unattended-upgrade

	exitCode=$?
	echo "unattended-upgrade exit code: $exitCode"
	echo "========================================="

	echo " "
	apt list --upgradable 2>/dev/null | grep "\-security"


else
	echo "No supported Linux distribution found"
	echo "No updates are installed"
fi

echo " "
echo "wait 10 seconds and reboot VM..."
(sleep 10; reboot) &
'@ + "`n`n"
}

#--------------------------------------------------------------
function get-BicepFromPath {
#--------------------------------------------------------------
	# add current directory to path on Linux
	if ($IsLinux) {
		if ('.' -notin ($Env:PATH -split ':')) {
			$Env:PATH += ':.' 
			$Env:PATH | Out-Null # needed to re-load environment
		}
	}

	# use local BICEP on Linux if exists
	$whichBicep = get-command bicep -ErrorAction 'SilentlyContinue'

	if ($Null -ne $whichBicep.Path) {
		write-logFile ('-' * $starCount) -ForegroundColor DarkGray
		write-logFile "BICEP already installed in $($whichBicep.Path)" -ForegroundColor DarkGray
		write-logFile ('-' * $starCount) -ForegroundColor DarkGray
		write-logFile
	}

	elseif (!$bicepNeeded) {
		write-logFile ('-' * $starCount) -ForegroundColor DarkGray
		write-logFile "BICEP not needed" -ForegroundColor DarkGray
		write-logFile ('-' * $starCount) -ForegroundColor DarkGray
		write-logFile
	}

	$bicepVersion = $Null
	if ($Null -ne $whichBicep.Path) {
		try { $bicepVersion = (bicep --version | Out-String)  -replace '\n', '' }
		catch {}
	}
	return $bicepVersion 
}

#--------------------------------------------------------------
function get-bicepFromGithub {
#--------------------------------------------------------------
	write-logFile ('-' * $starCount) -ForegroundColor DarkGray
	write-logFile "Trying to install BICEP..." -ForegroundColor DarkGray

	# install bicep
	if ($isWindows) {
		try {
			$installPath = "$env:USERPROFILE\.bicep" # hidden BICEP directory
			$installDir = New-Item -ItemType Directory -Path $installPath -Force
			$installDir.Attributes += 'Hidden'
			# Fetch the latest Bicep CLI binary
			(New-Object Net.WebClient).DownloadFile("https://github.com/Azure/bicep/releases/latest/download/bicep-win-x64.exe", "$installPath\bicep.exe")
			# Add bicep to your PATH
			$currentPath = (Get-Item -path "HKCU:\Environment" ).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
			if (-not $currentPath.Contains("%USERPROFILE%\.bicep")) { 
				setx PATH ($currentPath + ";%USERPROFILE%\.bicep") 
			}
			if (-not $env:path.Contains($installPath)) { 
				$env:path += ";$installPath" 
				$env:path | Out-Null # needed to re-load environment
			}
		}
		catch {
		}
	}

	elseif ($isLinux) {
		# remove old download
		if (Test-Path -Path './bicep-linux-x64') {
			Remove-Item -Path './bicep-linux-x64' -Force -ErrorAction 'SilentlyContinue'
		}

		try { curl -Lo bicep-linux-x64 https://github.com/Azure/bicep/releases/latest/download/bicep-linux-x64 }
		catch {}

		# download successful
		if (Test-Path -Path './bicep-linux-x64') {
			write-logFile "BICEP downloaded from GitHub" -ForegroundColor DarkGray

			if (Test-Path -Path './bicep') {
				Remove-Item -Path './bicep' -Force -ErrorAction 'SilentlyContinue'
			}
			Rename-Item -Path './bicep-linux-x64' -NewName "bicep" -Force
			chmod +x ./bicep
		}
	}

	elseif ($IsMacOS) {
		try {
			# Fetch the latest Bicep CLI binary
			curl -Lo bicep https://github.com/Azure/bicep/releases/latest/download/bicep-osx-x64
			# Mark it as executable
			chmod +x ./bicep
			# Add Gatekeeper exception (requires admin)
			sudo spctl --add ./bicep
			# Add bicep to your PATH (requires admin)
			sudo mv ./bicep /usr/local/bin/bicep
		}
		catch {
		}
	}
	
	$bicepVersion = $Null
	$whichBicep = get-command bicep -ErrorAction 'SilentlyContinue'
	if ($Null -ne $whichBicep.Path) {
		write-logFile "BICEP installed in $($whichBicep.Path)" -ForegroundColor DarkGray
		try { $bicepVersion = (bicep --version | Out-String)  -replace '\n', '' }
		catch {}
	}
	else {
		write-logFile "BICEP installation failed"
	}
	write-logFile ('-' * $starCount) -ForegroundColor DarkGray
	write-logFile

	return $bicepVersion
}

#-------------------------------------------------------------
function show-vmExtensions {
#-------------------------------------------------------------
	write-stepStart "Installed extensions in resource group $sourceRG" -skipLF

	$res = @()
	foreach ($vmName in $script:sourceVMs.Name) {
		$extensions = Get-AzVMExtension -ResourceGroupName $sourceRG -VMName $vmName -Status
		test-cmdlet 'Get-AzVMExtension'  "Could not get extensions for VM '$vmName'"

		foreach ($ext in $extensions) {
			$Config = $Null
			if ($Null -ne $ext.PublicSettings) {
				$Config = ($ext.PublicSettings | ConvertFrom-Json -AsHashtable).Keys -as [string]
			}
			$res += @{
				VM		= $vmName
				Name	= $ext.Name
				Vers	= $ext.TypeHandlerVersion
				Config	= $Config
				Status	= $ext.ProvisioningState
			}
		}
	}

	$res 
	| Select-Object VM, Name, Vers, Config, Status  
	| Format-Table
	| write-LogFilePipe
}

#--------------------------------------------------------------
function new-vmExtension {
#--------------------------------------------------------------
	param(
		$vmName,
		$extensionType,
		$extensionName,
		$publisher,
		$handlerVersion,
		$settings,
		[switch] $autoUpgradePossible
	)

	$found = $False
	foreach ($existingExtension in $script:existingExtensions) {
		if ($existingExtension -like "*$extensionName*") {
			$found = $True
		}
	}

	if ($found) {
		write-logFileUpdates 'extensions' $extensionName 'keep'
		return
	}

	$agentName = "$vmName/$extensionName"

	$properties = @{
		type					= $extensionType
		publisher				= $publisher
		typeHandlerVersion		= $handlerVersion
		autoUpgradeMinorVersion = $True
	}

	if ($Null -ne $settings) {
		$properties.settings = $settings
	}


	if ($autoUpgradePossible -and $autoUpgradeExtensions) {
		$properties.enableAutomaticUpgrade = $True
	}

	# extension
	$res = @{
		type 		= 'Microsoft.Compute/virtualMachines/extensions'
		apiVersion	= '2023-09-01'
		name 		= $agentName
		location	= $targetLocation
		properties	= $properties
	}

	# BICEP
	if ($useBicep) {
		$res.parent = "<$(get-bicepNameByType 'Microsoft.Compute/virtualMachines' $vmName)>"
	}

	# ARM
	else {
		[array] $depends = get-resourceFunction `
							'Microsoft.Compute' `
							'virtualMachines'	$vmName
		$res.dependsOn = $depends
	}

	if ($patchMode) {
		$script:vmsWithNewExtension += $vmName
	}
	write-logFileUpdates 'extensions' $extensionName 'create'
	add-resourcesALL $res
}

#--------------------------------------------------------------
function update-vmExtensionsPublic {
#--------------------------------------------------------------
	$script:copyVMs.values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$vmName = $_.Name
		$script:existingExtensions = @()

		# LINUX
		if ($_.OsDisk.OsType -eq 'linux') {

			new-vmExtension $vmName `
				'AzureMonitorLinuxAgent' `
				'AzureMonitorLinuxAgent' `
				'Microsoft.Azure.Monitor' `
				'1.30' `
				@{
					GCS_AUTO_CONFIG = $True
				} -autoUpgradePossible
		}

		# WINDOWS
		else {

			new-vmExtension $vmName `
				'AzureMonitorWindowsAgent' `
				'AzureMonitorWindowsAgent' `
				'Microsoft.Azure.Monitor' `
				'1.24' `
				@{
					GCS_AUTO_CONFIG = $True
				} -autoUpgradePossible
		}
	}
}

#**************************************************************
# Main program
#**************************************************************
$PsStyleOutputRendering = $PsStyle.OutputRendering
if ($hostPlainText) {
	$PsStyle.OutputRendering = 'PlainText'
}
else {
	[console]::ForegroundColor = 'Gray'
	[console]::BackgroundColor = 'Black'
}
Clear-Host
$error.Clear()
$pref = (get-Item 'Env:\rgcopyBreakingChangeWarnings' -ErrorAction 'SilentlyContinue').value
if ($pref -ne 'True')	{
	Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"
}

$rgcopyPath = Split-Path -Parent $PSCommandPath

# file names and location
$folder = (get-Item 'Env:\rgcopyExportFolder' -ErrorAction 'SilentlyContinue').value
if ($Null -ne $folder )	{
	$pathExportFolder = $folder
}
if ($(Test-Path $pathExportFolder) -ne $True) {
	$pathExportFolderNotFound = $pathExportFolder
	$pathExportFolder = '~'

}
$pathExportFolder = Resolve-Path $pathExportFolder

# filter out special charactes for file names
$sourceRG2 = $sourceRG -replace '\.', '-'   -replace '[^\w-_]', ''
$targetRG2 = $targetRG -replace '\.', '-'   -replace '[^\w-_]', ''

# default file paths
$importPath 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.SOURCE.json"
$exportPath 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.TARGET.json"
if ($useBicep) {
	$exportPath 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.TARGET.bicep"
	$exportPathDisks 	= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.DISKS.bicep"
}
$logPath			= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.TARGET.log"
if ($archiveMode) {
	$logPath		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.$sourceRG2.ARCHIVE.log"
}
if ($justCopyDisks.count -ne 0) {
	$logPath		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.DISKS.$($justCopyDisks[0]).log"
}

$timestampSuffix 	= (Get-Date -Format 'yyyy-MM-dd__HH-mm-ss')
# fixed file paths
$tempPathText 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.TEMP.txt"
$zipPath 			= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.$timestampSuffix.zip"
$zipPath2 			= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.arm-templates.zip"
$savedRgcopyPath	= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.txt"
$restorePath 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.RESTORE.ps1.txt"

# file names for source RG processing
if ($SourceOnlyMode) {
	$logPath		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.SOURCE.log"
	$zipPath 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.$timestampSuffix.zip"
}

# file names for backup RG
if ($archiveMode) {
	$exportPath 	= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.TARGET.json"
	if ($useBicep) {
		$exportPath 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.TARGET.bicep"
		$exportPathDisks 	= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.DISKS.bicep"
	}
}

# test RGCOPY version
$msInternalVersion = $True
try {
	test-msInternalVersion
}
catch {
	$msInternalVersion = $False
}

# create logfile
New-Item $logPath -Force -ErrorAction SilentlyContinue | Out-Null
$script:armTemplateFilePaths = @()

try {
	# save source code as rgcopy.txt
	$text = Get-Content -Path $PSCommandPath
	# get version
	foreach ($line in $text) {
		if ($line -like 'version*') {
			$main,$mid,$minor = $line -split '\.'
			$rgcopyVersion = "0.$mid.$minor"
			break
		}
	}

	if ($msInternalVersion) {
		$starCount = 75
		write-logFile ('*' * $starCount) -ForegroundColor DarkGray
		write-logFile "$repositoryURL " -NoNewLine
		write-logFile $rgcopyVersion -NoNewLine -ForegroundColor DarkGray
		write-logFile $rgcopyMode.PadLeft($starCount - 55 - $rgcopyVersion.length) -ForegroundColor 'Yellow'
		write-logFile ('*' * $starCount) -ForegroundColor DarkGray
		write-logFile "Get help at: $repositoryHelpURL" -ForegroundColor DarkGray
		test-msInternalRestrictions
	}
	else {
		$starCount = 70
		write-logFile ('*' * $starCount) -ForegroundColor DarkGray
		write-logFile 'https://github.com/Azure/RGCOPY ' -NoNewLine
		write-logFile 'version ' -ForegroundColor DarkGray -NoNewLine
		write-logFile $rgcopyVersion -NoNewLine
		write-logFile $rgcopyMode.PadLeft($starCount - 40 - $rgcopyVersion.length) -ForegroundColor 'Yellow'
		write-logFile ('*' * $starCount) -ForegroundColor DarkGray
		write-logFile "Get help at: https://github.com/Azure/RGCOPY/blob/main/rgcopy-docu.md" -ForegroundColor DarkGray
	}
	
	write-logFile
	write-logFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') -ForegroundColor DarkGray
	if ($hostPlainText) {
		write-logFile "Setting host output rendering to 'PlainText'"
	}
	if ($simulate) {
		write-logFile 'WARNING: running as simulation' -ForegroundColor 'Red'
	}
	$script:rgcopyParamOrig = $PSBoundParameters
	write-logFileHashTable $PSBoundParameters -rgcopyParam
	
	write-logFile -ForegroundColor 'Cyan' "Log file saved: $logPath"
	if ($pathExportFolderNotFound.length -ne 0) {
		write-logFileWarning "provided path '$pathExportFolderNotFound' of parameter 'pathExportFolder' not found"
	}
	write-logFile

	Set-Content -Path $savedRgcopyPath -Value $text -ErrorAction 'SilentlyContinue'
	if (!$?) {
		write-logFileWarning "Could not save rgcopy backup '$savedRgcopyPath'" 
	}

	if ($suppliedModes.count -gt 1) {
		write-logFileError "You must not set more than one mode parameter." `
							"Parameters set: $suppliedModes"
	}

	# processing only source RG
	write-logFileForbidden 'CloneMode'				@('targetRG', 'targetLocation')
	write-logFileForbidden 'updateMode'				@('targetRG', 'targetLocation')
	write-logFileForbidden 'justCreateSnapshots'	@('targetRG', 'targetLocation')
	write-logFileForbidden 'justDeleteSnapshots'	@('targetRG', 'targetLocation')

	# check name-parameter values
	test-names

	# Storage Account for disk creation
	if ($blobsRG.Length -eq 0) {
		$blobsRG = $targetRG
	}
	if ($blobsSA.Length -eq 0) {
		$blobsSA = $targetSA
	}
	if ($blobsSaContainer.Length -eq 0)	{
		$blobsSaContainer = $targetSaContainer
	}
	
	#--------------------------------------------------------------
	# check files
	#--------------------------------------------------------------
	# given ARM template
	if ($pathArmTemplate.length -ne 0) {
	
		if ($(Test-Path -Path $pathArmTemplate) -ne $True) {
			write-logFileError "Invalid parameter 'pathArmTemplate'" `
								"File not found: '$pathArmTemplate'"
		}
		$exportPath = $pathArmTemplate
		$script:armTemplateFilePaths += $pathArmTemplate

		# check if BICEP or ARM template
		if ('useBicep' -notin $boundParameterNames) {
			if ($pathArmTemplate -like '*.bicep') {
					$script:useBicep = $True
			}
			else {
					$script:useBicep = $False
			}
		}

		# template for disks
		if ($pathArmTemplateDisks.length -ne 0) {
			if ($(Test-Path -Path $pathArmTemplateDisks) -ne $True) {
				write-logFileError "Invalid parameter 'pathArmTemplateDisks'" `
									"File not found: '$pathArmTemplateDisks'"
			}
			$exportPathDisks = $pathArmTemplateDisks
			$script:armTemplateFilePaths += $pathArmTemplateDisks
			$script:dualDeployment = $True
		}
	}
	
	#--------------------------------------------------------------
	# check software version
	#--------------------------------------------------------------
	# minimal Az-version to 11.5.0 (needed by Get-AzAccessToken with parameter AsSecureString)

	$azVersion = (Get-InstalledModule Az -MinimumVersion 11.5.0 -ErrorAction 'SilentlyContinue')
	if ($azVersion.count -eq 0) {
		write-logFileError 'Minimum required version of module Az is 11.5.0' `
							'Run "Install-Module -Name Az -AllowClobber" to install or update'
	}
	
	# display Az.NetAppFiles version
	$azAnfVersion = (Get-InstalledModule Az.NetAppFiles -ErrorAction 'SilentlyContinue')
	if ($azAnfVersion.count -ne 0) {
		$azAnfVersionString = $azAnfVersion.version
	}
	if (($createVolumes.count -ne 0) -or ($snapshotVolumes.count -ne 0)) {
	# check Az.NetAppFiles version
		$azAnfVersion = (Get-InstalledModule Az.NetAppFiles -MinimumVersion 0.13 -ErrorAction 'SilentlyContinue')
		if ($azAnfVersion.count -eq 0) {
			write-logFileError 'Minimum required version of module Az.NetAppFiles is 0.13' `
								'Run "Install-Module -Name Az.NetAppFiles -AllowClobber" to install or update'
		}
	}

	if ($useBicep -or $cloneMode -or $mergeMode) {
		$bicepNeeded = $True
	}
	else {
		$bicepNeeded = $False
	}

	$bicepVersion = get-BicepFromPath

	if ($updateBicep -or ($bicepNeeded -and ($bicepVersion.length -eq 0))) {
		$bicepVersion = get-bicepFromGithub
	}
	
	# check for running in Azure Cloud Shell
	if (($env:ACC_LOCATION).length -ne 0) {
		write-logFile 'RGCOPY running in Azure Cloud Shell' -ForegroundColor 'yellow'
		write-logFile
	}

	# check for RDP connection
	if ((($env:SESSIONNAME).length -ne 0) -and ($env:SESSIONNAME -ne 'Console')) {
		write-logFile 'RGCOPY running in Terminal Server Connection' -ForegroundColor 'yellow'
		write-logFile
	}

	# output of sofware versions
	write-logFile 'RGCOPY environment:'
	$psVersionString = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch)"
	write-logFileTab 'Powershell version'	$psVersionString -noColor
	write-logFileTab 'Az version'			$azVersion.version -noColor
	write-logFileTab 'Az.NetAppFiles'		$azAnfVersionString -noColor
	write-logFileTab 'BICEP version'		$bicepVersion -noColor
	write-logFileTab 'OS version'			$PSVersionTable.OS -noColor
	write-logFile

	if ($bicepNeeded -and ($bicepVersion.length -eq 0)) {
		write-logFileError "Install BICEP manually as described at" `
							"https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install"
	}
	
	#--------------------------------------------------------------
	# check user and subscription
	#--------------------------------------------------------------
	# if ONLY source or ONY target is specified: use parameters for both (source AND target)
	# allow using target instead of source for parameters *Sub *SubUser, *SubTenant
	if (($targetSub.length -eq 0)		-and ($sourceSub.length -ne 0)) 		{ $targetSub = $sourceSub }
	if (($sourceSub.length -eq 0)		-and ($targetSub.length -ne 0)) 		{ $sourceSub = $targetSub }
	if (($targetSubUser.length -eq 0)	-and ($sourceSubUser.length -ne 0)) 	{ $targetSubUser = $sourceSubUser }
	if (($sourceSubUser.length -eq 0)	-and ($targetSubUser.length -ne 0)) 	{ $sourceSubUser = $targetSubUser }
	if (($targetSubTenant.length -eq 0)	-and ($sourceSubTenant.length -ne 0))	{ $targetSubTenant = $sourceSubTenant }
	if (($sourceSubTenant.length -eq 0)	-and ($targetSubTenant.length -ne 0))	{ $sourceSubTenant = $targetSubTenant }
	
	# get context
	$mySetting = Get-AzContextAutosaveSetting
	if ($Null -ne $mySetting) {
		$myMode = $mySetting.Mode
	}
	$myContext = Get-AzContext
	if ($Null -eq $myContext) {
		if ($myMode -eq 'CurrentUser') {
			write-logFileError 'No valid Az-Context context exists' `
								'Run "Connect-AzAccount" before starting RGCOPY'
		}
		else {
			write-logFileError 'No valid Az-Context context exists' `
								'Run "Enable-AzContextAutosave" and "Connect-AzAccount" before starting RGCOPY'
		}
	}
	if ($myContext.Account.Id.Length -eq 0) {
		write-logFileError 'No valid Az-Context context exists' `
							'Run Connect-AzAccount before starting RGCOPY'
	}
	
	#--------------------------------------------------------------
	# use current context (no parameter for user supplied)
	#--------------------------------------------------------------
	if  (($sourceSub.Length -eq 0) `
	-and ($sourceSubUser.Length -eq 0) `
	-and ($sourceSubTenant.Length -eq 0) `
	-and ($myContext.Subscription.Name.Length -ne 0) `
	-and ($myContext.Account.Id.Length -ne 0) `
	-and ($myContext.Tenant.Id.Length -ne 0)) {
	
		$sourceSub			= $myContext.Subscription.Name
		$sourceSubUser		= $myContext.Account.Id
		$sourceSubTenant	= $myContext.Tenant.Id
		$targetSub   		= $sourceSub
		$targetSubUser   	= $sourceSubUser
		$targetSubTenant 	= $sourceSubTenant
		$sourceContext		= $myContext
		$targetContext		= $myContext
		$currentSub			= $sourceSub
		write-logFileWarning "using current Az-Context User:         $sourceSubUser"
		write-logFileWarning "using current Az-Context Subscription: $sourceSub"
		write-logFile
	}
	
	#--------------------------------------------------------------
	# set context according to RGCOPY parameters
	#--------------------------------------------------------------
	else {
	
		# ensure that subscription is set
		if ($sourceSub.Length -eq 0) {
			if ($myContext.Subscription.Name.Length -eq 0) {
				write-logFileError 'Current Az-Context context has no subscription assigned' `
									"RGCOPY parameter 'sourceSub' required"
			}
			else {
				$sourceSub = $myContext.Subscription.Name
				$targetSub = $myContext.Subscription.Name
				write-logFileWarning "using current Az-Context Subscription:   $sourceSub"
				write-logFile
			}
		}
	
		# ensure that user is set
		if ($sourceSubUser.Length -eq 0) {
			$sourceSubUser = $myContext.Account.Id
			$targetSubUser = $myContext.Account.Id
			write-logFileWarning "using current Az-Context User:   $sourceSubUser"
			write-logFile
		}
	
		# connect to Source Subscription
		test-context $sourceSub $sourceSubUser $sourceSubTenant 'Source Subscription'
		$sourceContext = Get-AzContext
	
		# connect to Target Subscription
		# only one subscription & one user
		if (	 ($sourceSub 		-eq $targetSub) `
			-and ($sourceSubUser 	-eq $targetSubUser) `
			-and ($sourceSubTenant 	-eq $targetSubTenant)) {
	
			$targetContext 	= $sourceContext
			$currentSub		= $sourceSub
		}
		# two subscriptions
		else
		{
			test-context $targetSub $targetSubUser $targetSubTenant 'Target Subscription'
			$targetContext	= Get-AzContext
			$currentSub		= $targetSub
		}
	
		# tenant might not been provided as parameter
		$sourceSubTenant	= $sourceContext.Tenant.Id
		$targetSubTenant	= $targetContext.Tenant.Id
	}
	
	#--------------------------------------------------------------
	# default for Owner Tag
	if ($setOwner -eq '*') {
		$setOwner = $targetSubUser
	}
	
	get-subscriptionFeatures

	#--------------------------------------------------------------
	# source resource group
	#--------------------------------------------------------------
	set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
	$script:currentAccountId = $sourceContext.Account.Id

	# Check Source Subscription
	$sourceSubID = (Get-AzSubscription -SubscriptionName $sourceSub -ErrorAction 'SilentlyContinue').Id
	if ($Null -eq $sourceSubID) {
		write-logFileError "Source Subscription '$sourceSub' not found" -lastError
	}
	# Check Source Resource Group
	$sourceRgObject = Get-AzResourceGroup -Name $sourceRG -ErrorAction 'SilentlyContinue'
	# tag names are case insensitive
	$tagName = $sourceRgObject.Tags.Keys | Where-Object {$_ -eq 'Owner'}
	# result of (Get-AzResourceGroup).Tags.Keys is case sensitive
	if (($Null -ne $tagName) -and ($Null -ne $sourceRgObject)) {
		$rgOwner = $sourceRgObject.Tags.$tagName
	}

	$sourceLocation = $sourceRgObject.Location
	$sourceRgNotFound = ''

	if ($Null -eq $sourceLocation) {
		# allow startWorkload even when source RG does not exist any more
		if ($startWorkload `
		-and $skipArmTemplate `
		-and $skipSnapshots `
		-and $skipDeployment `
		-and $copyMode) {

			$sourceLocation = $targetLocation
			$sourceRgNotFound = '(not found)'
		}
		# source RG does not exist
		else {
			write-logFileError "Source Resource Group '$sourceRG' not found" -lastError
		}
	}
	write-logFile 'Source:'
	write-logFileTab 'Subscription'		$sourceSub
	write-logFileTab 'SubscriptionID'	$sourceSubID
	write-logFileTab 'User'				$sourceSubUser
	write-logFileTab 'Tenant'			$sourceSubTenant -noColor
	write-logFileTab 'Region'			$sourceLocation -noColor
	write-logFileTab 'Resource Group'	$sourceRG $sourceRgNotFound
	write-logFile

	#--------------------------------------------------------------
	# target resource group
	#--------------------------------------------------------------
	if ($SourceOnlyMode) {
		$targetSub			= $sourceSub
		$targetSubID		= $sourceSubID
		$targetSubUser		= $sourceSubUser
		$targetSubTenant	= $sourceSubTenant
		$targetLocation		= $sourceLocation
		$targetRG			= $sourceRG
		if ($mergeMode) {
			write-logFileWarning "Using source RG as target RG in Merge Mode"
		}
	}
	else {
		set-context $targetSub # *** CHANGE SUBSCRIPTION **************

		write-logFile 'Target:'
		# Target Subscription
		$targetSubID = (Get-AzSubscription -SubscriptionName $targetSub).Id
		if ($Null -eq $targetSubID) {
			write-logFileError "Target Subscription '$targetSub' not found"
		}
		if ($targetSub -eq $sourceSub) {
			write-logFileTab 'Subscription' 'ditto' -noColor
			write-logFileTab 'SubscriptionID' 'ditto' -noColor
		}
		else {
			write-logFileTab 'Subscription' $targetSub
			write-logFileTab 'SubscriptionID' $targetSubID
		}
		
		# Target User
		if ($targetSubUser -eq $sourceSubUser) {
			write-logFileTab 'User' 'ditto' -noColor
		}
		else {
			write-logFileTab 'User' $targetSubUser
		}
		
		# Target Tenant
		if ($targetSubTenant -eq $sourceSubTenant) {
			write-logFileTab 'Tenant' 'ditto' -noColor
		}
		else {write-logFileTab 'Tenant' $targetSubTenant
		}
		
		# Target Location for MERGE MODE
		if ($mergeMode) {
			$mergeLocation = (Get-AzResourceGroup -Name $targetRG -ErrorAction 'SilentlyContinue').Location
			if ($Null -eq $mergeLocation) {
				write-logFileError "Target Resource Group '$targetRG' not found"
			}
			if ($targetLocation.length -eq 0) {
				$targetLocation = $mergeLocation
			}
			elseif ($targetLocation -ne $mergeLocation) {
				write-logFileWarning "Using Target Region '$mergeLocation' of Target Resource Group"
				$targetLocation = $mergeLocation
			}
		}

		# Target Location
		$targetLocationDisplayName = (Get-AzLocation | Where-Object Location -eq $targetLocation).DisplayName
		if ($null -eq $targetLocationDisplayName) {
			if ($targetLocation -like '*euap') {
				$targetLocationDisplayName = 'Canary'
			}
			else {
				write-logFileError "Target Region '$targetLocation' not found"
			}
		}
		write-logFileTab 'Region' $targetLocation "($targetLocationDisplayName)"
		
		# Target Resource Group
		write-logFileTab 'Resource Group' $targetRG

		#--------------------------------------------------------------
		# check if source and target are identical
		#--------------------------------------------------------------
		if ( ($sourceSub -eq $targetSub) `
		-and ($sourceRG -eq $targetRG) `
		-and (!$mergeMode) ) {
			
			write-logFileError "Source and Target Resource Group are identical"
		}

		#--------------------------------------------------------------
		# BLOG resource group
		#--------------------------------------------------------------
		# output blobsRG
		if ($targetRG -ne $blobsRG) {
			Get-AzResourceGroup `
				-Name 	$blobsRG `
				-ErrorAction 'SilentlyContinue' | Out-Null
			if (!$?) {
				write-logFileError "Disk Resource Group '$blobsRG' not found"
			}
			write-logFileTab 'Disk Resource Group' $blobsRG
		}
		# output blobsSA
		if (($targetSA -ne $blobsSA) -or ($targetRG -ne $blobsRG)) {
			Get-AzStorageAccount `
				-ResourceGroupName	$blobsRG `
				-Name 				$blobsSA `
				-ErrorAction 'SilentlyContinue' | Out-Null
			if (!$?) {
				write-logFileError "Disk Storage Account '$blobsSA' not found"
			}
			write-logFileTab 'Disk Storage Account' $blobsSA
		}
		# output blobsSaContainer
		if (($targetSaContainer -ne $blobsSaContainer) -or ($targetSA -ne $blobsSA) -or ($targetRG -ne $blobsRG)) {
			Get-AzRmStorageContainer `
				-ResourceGroupName 	$blobsRG `
				-AccountName 		$blobsSA `
				-ContainerName 		$blobsSaContainer `
				-ErrorAction 'SilentlyContinue' | Out-Null
			if (!$?) {
				write-logFileError "Disk Storage Account Container '$blobsSaContainer' not found"
			}
			write-logFileTab 'Disk Storage Account Container' $blobsSaContainer
		}
		write-logFile
		set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
	}
	write-logFile

	#--------------------------------------------------------------
	# disable-defaultValues
	#--------------------------------------------------------------
	if (!$copyMode -or $skipDefaultValues) {
	
		if ('setDiskSku' -notin $boundParameterNames) {
			$setDiskSku = @()
		}
		if ('setAcceleratedNetworking' -notin $boundParameterNames) {
			$setAcceleratedNetworking = @()
		}
		if ('setVmZone' -notin $boundParameterNames) {
			$setVmZone = @()
		}
		if ('setPrivateIpAlloc' -notin $boundParameterNames) {
			$setPrivateIpAlloc = @()
		}
	}
	
	#--------------------------------------------------------------
	# debug actions
	#--------------------------------------------------------------

	# parameter justDeleteSnapshots
	# Caution: skipVMs and skipDisks are taken into account
	if ($justDeleteSnapshots) {
		get-sourceVMs
		$snapshotNames = ($script:sourceSnapshots | Where-Object Name -like '*.rgcopy').Name
		if ($snapshotNames.count -gt 0) {
			remove-snapshots $sourceRG $snapshotNames
		}
		else {
			write-logFileWarning "No RGCOPY snapshot found"
		}
		write-zipFile 0
	}

	# parameter justCreateSnapshots
	# Caution: skipVMs and skipDisks are taken into account
	elseif ($justCreateSnapshots) {
		get-sourceVMs
		assert-vmsStopped
		step-snapshots
		write-zipFile 0
	}

	# parameter justStopCopyBlobs
	# Caution: skipVMs and skipDisks are taken into account
	elseif ($justStopCopyBlobs) {
		if ($archiveMode) {
			$blobsSaContainer	= $archiveContainer
			$targetSaContainer	= $archiveContainer
		}
		get-sourceVMs
		stop-copyBlobs
		write-zipFile 0
	}

	# UPDATE MODE
	elseif ($updateMode) {
		test-updateMode
		get-sourceVMs
		step-updateMode
		write-zipFile 0
	}

	# PATCH MODE
	elseif ($patchMode) {
		test-patchMode
		get-sourceVMs
		write-logFileConfirm "Patch and Reboot VMs in resource group '$SourceRG'"
		
		# check RG Owner tag
		if ($Null -eq $rgOwner) {
			write-logFileWarning "Owner tag of resource group '$sourceRG' was not set" `
								"setting it to '$setOwner'"
			$tags = $sourceRgObject.Tags
			$tags += @{Owner = $setOwner}
			Set-AzResourceGroup -Name $sourceRG -Tag $tags -ErrorAction 'SilentlyContinue' | Out-Null
			test-cmdlet 'Set-AzResourceGroup'  "Could not set tag to resource group '$sourceRG'"
		}
		elseif ($rgOwner -ne $setOwner) {
			write-logFileWarning "Owner tag of resource group '$sourceRG' is not set to '$setOwner'" `
								"Current value is '$rgOwner'"
		}

		# install OS patches
		$script:patchesFailed = 0
		if (!$skipPatch) {
			step-patchMode
		}

		# install VM extensions
		$script:vmsWithNewExtension  = @()
		if ($forceExtensions -and $msInternalVersion) {
			step-patchExtensions
			show-vmExtensions
		}

		# stop VMs
		if (!$stopVMsSourceRG) {
			write-logFileWarning "VMs in resource group '$sourceRG' have not been stopped" `
								"Use parameter 'stopVMsSourceRG' the next time"
		}
		else {
			write-stepStart "Stopping VMs"
			stop-VMsParallel $sourceRG $patchVMs
		}

		# display failed OS patches
		if ($script:patchesFailed -gt 0) {
			write-logFileError "Patches of $($script:patchesFailed) VMs failed"
		}

		write-zipFile 0
	}
	
	#--------------------------------------------------------------
	# get RGCOPY steps
	#--------------------------------------------------------------
	# special cases:
	test-copyMode
	test-cloneMode
	test-mergeMode
	test-archiveMode			# useBlobCopy = $True
	test-justCopyBlobsSnapshotsDisks
	test-restartRemoteCopy
	test-stopRestore			# skipRemoteCopy = $True
	test-givenArmTemplate		# skipRemoteCopy = $True

	# delete storage account in target RG by default
	if (('deleteTargetSA' -notin $boundParameterNames) -and ($copyMode -or $mergeMode)) {
		$deleteTargetSA = $True
	}
	
	# some not needed steps:
	if (($createVolumes.count -eq 0) -and ($createDisks.count -eq 0)) {
		$skipBackups = $True
		$skipRestore = $True
	}

	if ($simulate) {
		$skipSnapshots	= $True
		$skipBackups	= $True
		$skipRemoteCopy	= $True
		$skipDeployment	= $True
		$skipExtensions = $True
		$skipCleanup	= $True
		$startWorkload	= $False
	}

	if ($skipDeployment) {
		$skipDeploymentVMs = $True
		$skipExtensions    = $True
	}

	if ('skipRemoteCopy' -in $boundParameterNames) {
		$skipSnapshots = $True
	}

	# BLOB/snapshot copy needed?
	$RemoteCopyNeeded = $False
	if ($useBlobCopy `
	-or $useSnapshotCopy `
	-or ($sourceLocation -ne $targetLocation)) {

		$RemoteCopyNeeded = $True
	}

	if (($sourceSubUser   -ne $targetSubUser) `
	-or ($sourceSubTenant -ne $targetSubTenant)) {

		$RemoteCopyNeeded = $True
	}

	if (!$RemoteCopyNeeded) {
		$skipRemoteCopy = $True
	}
	
	# output of steps
	if ($skipArmTemplate  ) {$doArmTemplate     = '[ ]'} else {$doArmTemplate     = '[X]'}
	if ($skipSnapshots    ) {$doSnapshots       = '[ ]'} else {$doSnapshots       = '[X]'}
	if ($skipRemoteCopy   ) {$doRemoteCopy      = '[ ]'} else {$doRemoteCopy      = '[X]'}
	if ($skipDeploymentVMs) {$doDeployment      = '[ ]'} else {$doDeployment      = '[X]'}
	if ($skipExtensions   ) {$doExtensions      = '[ ]'} else {$doExtensions      = '[X]'}
	if ($startWorkload    ) {$doWorkload        = '[X]'} else {$doWorkload        = '[ ]'}
	if ($deleteSnapshots  ) {$doDeleteSnapshots = '[X]'} else {$doDeleteSnapshots = '[ ]'}
	if ($deleteSourceSA   ) {$doDeleteSourceSA  = '[X]'} else {$doDeleteSourceSA  = '[ ]'}
	if ($stopVMsTargetRG  ) {$doStopVMsTargetRG = '[X]'} else {$doStopVMsTargetRG = '[ ]'}

	write-logFile 'Required steps:'
	#--------------------------------------------------------------
	# clone mode
	if ($cloneOrMergeMode) {
		write-logFile	"  $doArmTemplate Create BICEP Template (refering to snapshots)"
		write-logFile	"  $doSnapshots Create snapshots of disks"
		write-logFile	"  $doDeployment Deployment"
		write-logFile	"  $doDeleteSnapshots Delete Snapshots"
	}

	#--------------------------------------------------------------
	# justCopyDisks	
	elseif ($justCopyDisks.count -ne 0) {
		write-logFile	"  $doSnapshots Create snapshots of disks (in source RG)"
		write-logFile	"  $doRemoteCopy Copy snapshots (into target RG)"
		if ($simulate) {
			write-logFile	"  [ ] Create disks manually"	
		}
		else {
			write-logFile	"  [X] Create disks manually"	
		}
	}

	#--------------------------------------------------------------
	# other modes
	else {
		# prepare
		write-logFile	"  Prepare:"
		if ($useBicep) {
			write-logFile	"    $doArmTemplate Create BICEP Template (referring to snapshots)"
		}
		else {
			write-logFile	"    $doArmTemplate Create ARM Template (refering to snapshots)"
		}
		write-logFile		"    $doSnapshots Create snapshots (in source RG)"
		if (!$skipBackups) {
			write-logFile	"    [X] Create file backup (of disks and volumes in source RG NFS Share)"
		}
		write-logFile		"    $doRemoteCopy Copy snapshots (into target RG)"

		# deployment
		write-logFile	"  Deploy:"
		write-logFile		"    $doDeployment Deploy Virtual Machines"
		if (!$skipRestore) {
			write-logFile	"    [X] Restore files"
		}
		write-logFile 		"    $doExtensions Deploy Extensions"

		# workload
		write-logFile	"  Workload:"
		write-logFile	"    $doWorkload Run and Analysis"

		# cleanup
		write-logFile	"  Cleanup:"
		write-logFile		"    $doDeleteSnapshots Delete Snapshots (in source RG)"
		if ($doDeleteSourceSA -eq '[X]') {
			write-logFile	"    $doDeleteSourceSA Delete Storage Account (in source RG)"
		}
		write-logFile		"    $doStopVMsTargetRG Stop VMs (in target RG)"

	}
	write-logFile
	
	#--------------------------------------------------------------
	# run steps
	#--------------------------------------------------------------
	$script:sapAlreadyStarted = $False
	$script:vmStartWaitDone = $False

	if ($allowRunningVMs) {
		write-logFileWarning 'Parameter allowRunningVMs is set. This could result in inconsistent disk copies.'
		write-logFile
	}

	# get source VMs/Disks
	if (!$skipArmTemplate `
	-or !$skipSnapshots `
	-or !$skipRemoteCopy `
	-or !$skipBackups `
	-or !$skipRestore `
	-or ($justCopyDisks.count -ne 0) ) {

		get-sourceVMs
		assert-vmsStopped
	}

	step-armTemplate
	new-resourceGroup
	step-prepareClone
	step-snapshots

	$script:nfsVnetName, $script:nfsSubnetName= get-nfsSubnet
	step-backups
	step-copyBlobsAndSnapshots
	
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************
	$script:sapAlreadyStarted = $False
	if (($justCopyDisks.count -ne 0) -and !$simulate) {
		update-diskZone
		new-disks
	}

	step-deployment
	step-workload
	step-cleanup

	set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
}
catch {
	Write-Output $error[0]
	Write-Output $error[0] *>>$logPath
	write-logFileError "PowerShell exception caught" `
						$error[0]
}

write-zipFile 0
