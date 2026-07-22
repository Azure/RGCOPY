<#
rgcopy.ps1:       Copy Azure Resource Group
version:          0.9.75
version date:     July 2026
Author:           Martin Merdes
Public Github:    https://github.com/Azure/RGCOPY

//
// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.
//

#>
#Requires -Version 7.3

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

	# additional parameters
	,$parameterFile
	,[string] $subnetIdControlPlane							# resource ID of control plane VM subnet

	# storage account
	,[string] $targetSA										# only needed if calculated name is not unique in subscription (= ANF account name)
	,[string] $sourceSA										# only needed if calculated name is not unique in subscription
	,[string] $sourceSaPrefix = 'rgcopy'	

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
	,[switch]   $waitBackup									# restart waiting file copy (backup)
	,[switch] $skipRemoteCopy								# skip BLOB/snapshot creation (in targetRG)
	,[switch]   $waitRemoteCopy								# restart waiting for BLOB or snapshot copy 
	,[switch] $skipDeployment								# skip deployment (in targetRG)
	,[switch]   $skipExtensions								# do not install VM extensions
	,[switch]   $ignoreExtensionErrors						# deploying BICEP will not fail if extension installation fails
	,[switch] $skipRestore									# skip part step: restore files
	,[switch]   $waitRestore								# restart waiting file copy (restore)
	,[switch]   $stopRestore								# run all steps until (excluding) Restore
	,[switch]   $continueRestore							# run Restore and all later steps
	,[switch] $startWorkload								# start workload
	,[switch] $stopVMsTargetRG 								# stop VMs in the target RG after deployment
	,[switch] $patchVMsTargetRG 							# apply security patches on target VMs after deploying
	,[switch] $deleteSnapshots								# delete snapshots after deployment
	,[switch] $deleteBackups
	,[switch] $deleteBackupsOnly

	# simulating
	,[switch] $simulate										# just create ARM template

	# VM extensions
	,[switch] $autoUpgradeExtensions						# auto upgrade VM extensions
	,$installExtensionsSapMonitor	= @()					# Array of VMs where SAP extension should be installed
	,[string] $diagSettingsPub	= 'PublicSettings.json'
	,[string] $diagSettingsProt	= 'ProtectedSettings.json'
	,[string] $diagSettingsContainer
	,[string] $diagSettingsSA

	# disk creation options
	,[switch] $skipDiskCreation
	,[switch] $createDisksManually
	,[switch] $useIncSnapshots								# always use INCREMENTAL rather than FULL snapshots (even in same region and for standard disks)
	,[switch] $useRestAPI									# always use REST API rather than az-cmdlets when possible

	,[switch] $useSnapshotCopy								# always use SNAPSHOT copy (even in same region)
	,[switch] $useBlobCopy									# always use BLOB copy (even in same region)
	,[switch] $removeRemoteSnapshotsEarly

	,[string] $blobsSA										# Storage Account of BLOBs
	,[string] $blobsRG										# Resource Group of BLOBs
	,[string] $blobsSaContainer								# Container of BLOBs

	# parameters for cleaning an incomplete RGCOPY run
	,[array]  $justCopyBlobs 				# only copy these disks to BLOBs (from existing snapshots)
	,[array]  $justCopySnapshots 			# only copy these disks to SNAPSHOTs (from existing snapshots)
	,[array]  $justCopyDisks				# only copy these disks (by creating snapshots and disks)
	,[switch] $justStopCopyBlobs

	,[Parameter(ParameterSetName='singleRG')]
	[switch] $justCreateSnapshots		# just create snapshots in source RG

	,[Parameter(ParameterSetName='singleRG')]
	[switch] $justDeleteSnapshots		# just delete snapshots in source RG

	#--------------------------------------------------------------
	# parameters for AzCopy
	#--------------------------------------------------------------
	,[switch] $useAzCopy									# uses AzCopy rather than SnapshotCopy or BlobCopy
	,[string] $azCopyLogLocation = '/mnt/resource/azcopy'	# only for Linux Control Plane
	,[int] $azCopyRepeatCount		= 1						# by default, repeat each failed AzCopy job once
	,[switch] $showAzCopyLogs								# show console output of AzCopy even when job was successful
	,$azCopyEnvironment = @{								# environment variables set for azcopy
		AZCOPY_DISABLE_SYSLOG		= 'true'
		NO_PROXY 					= '*'
	}

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
	# ,$takeVMs 				= @()
	# ,$skipVMs 				= @()
	,[switch] $patchAll				# install ALL patches on VM (not only security patches)
	,[switch] $ignorePatchErrors	# ignore any error during OS Patch deployment
	,[string] $prePatchCommand		# e.g. 'yum-config-manager --save --setopt=rhui-rhel-7-server-dotnet-rhui-rpms.skip_if_unavailable=true 1>/dev/null'
	,[string] $postPatchCommand
	,[switch] $skipPatch
	,[switch] $forceExtensions
	# ,[switch] $autoUpgradeExtensions
	# ,[switch] $stopVMsSourceRG
	,$defaultTags = @{}

	#--------------------------------------------------------------
	# file locations
	#--------------------------------------------------------------
	,[string] $pathArmTemplate								# given ARM template file
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
	,[ValidateSet('Standard', 'Premium', 'Ultra')]
	 [string] $netAppServiceLevel	= 'Premium'				# Service Level for NetApp Capacity Pool

	,[ValidateSet('Basic', 'Standard')]
	 [string] $netAppNetworkFeatures = 'Standard'			# Network Features for NetApp Volumes: 'Basic', 'Standard'

	,[string] $netAppAccountName							# in Copy Mode: Name of new Account
	,[string] $netAppPoolName								# in Copy Mode: Name of new Pool
	,[int]    $netAppPoolGB 		= 4 * 1024				# in Copy Mode: Size of new Pool in GB
	,[string] $netAppMovePool								# in Update Mode: Only move this pool: <account>/<pool>
	,[switch] $netAppMoveForce								# in Update Mode: Always move pools, even when Service Level is identical
	,[switch] $verboseLog									# detailed output for converting NetApp or disks
	,[string] $createDisksTier		= 'P20'					# minimum disk tier (in target RG) for converting NetApp or disks
	,[int]    $nfsQuotaGiB 			= 5120					# Quota for Azure NFS share (not NetApp!) 
	,[string] $subnetEndpoint								# <vnetName/subnetName>: existing subnet for private endpoints
	,[string] $subnetNetApp									# <vnetName/subnetName>: existing subnet for ANF endpoint
	,[int] $TAR_BLOCKSIZE_KB		= 4

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
	,[int] $waitSeconds4nwRule		= 30					# 10 seconds is not enough
	,[string] $setOwner 			= '*'					# Owner-Tag of Resource Group; default: $targetSubUser
	,[string] $jumpboxName			= ''					# create FQDN for public IP of jumpbox
	,[switch] $ignoreTags									# ignore rgcopy*-tags for target RG CONFIGURATION
	,[switch] $copyDetachedDisks							# copy disks that are not attached to any VM

	#--------------------------------------------------------------
	# skip resources from sourceRG
	#--------------------------------------------------------------
	,$takeVMs				= @()							# Names of VMs that will be copied
	,$skipVMs 				= @()							# Names of VMs that will not be copied
	,$skipDisks				= @()							# Names of DATA disks that will not be copied
	,$skipSecurityRules		= @('SecurityCenter-JITRule*')	# Name patterns of rules that will not be copied
	,$keepTags				= @('rgcopy*')					# Name patterns of tags that will be copied, all others will not be copied
	,[switch] $keepUnusedResources							
	,[switch] $skipVmssFlex									# do not copy VM Scale Sets Flexible
	,[switch] $skipAvailabilitySet							# do not copy Availability Sets
	,[switch] $skipProximityPlacementGroup					# do not copy Proximity Placement Groups
	,[switch] $skipBastion									# do not copy Bastion
	,[switch] $skipBootDiagnostics							# do not create Boot Diagnostics (managed storage account)
	,[switch] $skipIdentities								# do not copy user assigned identities
	,[switch] $skipSaNwRules

	,[switch] $copyVMsOnly

	#--------------------------------------------------------------
	# rename resources
	#--------------------------------------------------------------
	,$setVmName = @()
	# renames VM resource name (not name on OS level)
	# usage: $setVmName = @("$vmNameNew@$vmNameOld", ...)
	# set VM name dbserver for VM hana (=rename hana)	@("dbserver@hana")
	,$renameSa = @()
	,[switch] $renameDisks	# rename all disks using their VM name

	#--------------------------------------------------------------
	# resource configuration parameters
	#--------------------------------------------------------------
	,[switch] $skipVmChecks									# do not double check whether VMs can be deployed in target region
	,[switch] $forceVmChecks								# Do not automatically change resource properties to valid values
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

	,$setVmEncryptionAtHost = @()
	# usage: $setVmEncryptionAtHost = @("$bool@$vm1,$vm2,...", ...)
	#	with $bool -in @('True', 'False')

	,$swapSnapshot4disk = @()
	,$swapDisk4disk = @()

	#--------------------------------------------------------------
	# parameters for file copy
	#--------------------------------------------------------------
	# ,$skipDisks	# see above

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

	,[ValidateSet('compare', 'verify', 'none')]
	 $fileCopyVerify = 'compare'

	#--------------------------------------------------------------
	# parameters for storage account copy
	#--------------------------------------------------------------
	# ,$renameSa = @()
	,$copySaShares 					= $false  	# $false, $true, or [array] of share names
	,[switch] $copySaUsingSnapshots				# use RGCOPY snapshot of SMB/NFS share rather than share content
	,[switch] $copySaRevokeCpAccess				# revoke access from control plane VM after content was copied
	,[ValidateSet('key1', 'key2')]
	 [string] $copySaKeyName 		= 'key1'	# choose storage account key 'key1' or 'key2' (if SA key is used)
	,[switch] $justCopySaShares					# just copy containers and shares defined in copySaShares. No snapshots, no deployment

	#--------------------------------------------------------------
	# other parameter
	#--------------------------------------------------------------
	,[switch] $updateBicep				# update BICEP when starting RGCOPY
	,[switch] $updateAzcopy				# update AzCopy when starting RGCOPY
	,[switch] $hostPlainText			# do not use colors in console
	,[switch] $ultraSSDEnabled 			# create VM with property ultraSSDEnabled even when not needed
	,[switch] $useNewVmSizes			# get VM capabilities from local file
	,[switch] $targetNoSaKeys			# do not allow using SA keys for snapshot-to-BLOB copy (SA in target RG)
	,[switch] $sourceNoSaKeys			# do not allow using SA keys for file copy (SA in source RG)
	,[ValidateSet(0, 1, 2, 3)]
	 $defaultDiskZone					# zone for detached disks or when using justCopyDisks
	,$defaultDiskName					# use for justCopyDisks with a single disk: rename disk it target RG

	#--------------------------------------------------------------
	# experimental parameters: DO NOT USE!
	#--------------------------------------------------------------
	,[switch] $allowRunningVMs			# DANGEROUS: allow snapshots of running VMs with more than one data disk
	,[switch] $keepIdentities			# keep existing azSecPack identity (it will be re-created anyway)
	,[switch] $skipStartSAP				# specific parameter for SAP tests
	,[string] $monitorRG				# specific parameter for SAP tests
	,[switch] $copyDNS
	,[switch] $keepRemoteSnapshotsBlobs
	
	# use tags for public IP addresses
	,[string] $setIpTag
	,[string] $setIpTagType	= 'FirstPartyUsage'

	# use TiP sessions
	,$setVmTipGroup			= @()
	,$setGroupTipSession	= @()

	# create VMs from given image (no additional data disks allowed)
	,$generalizedVMs		= @()
	,$generalizedUser		= @()
	,$generalizedPasswd		= @() 		# will be checked below for data type [SecureString] or [SecureString[]]

	# just for debugging AzCopy:
	,[switch] $ignoreDelKeySource
	,[switch] $ignoreDelKeyTarget
	,[switch] $ignoreSaKeySource
	,[switch] $ignoreSaKeyTarget
	,[switch] $useAzureCLI				# using 'AZCLI' rather than 'PSCRED' for storageCredentialType
	,$screenWidthLarge = 160
	,$screenWidthSmall = 120
)

$nspApiVersion = '2024-07-01'
$nspName = 'rgcopyNSP'
$storageCredentialType = 'PSCRED'
if ($useAzureCLI) {
	$storageCredentialType = 'AZCLI'
}

#--------------------------------------------------------------
# save parameters in $pwshParameters, $boundParameterNames
# converts data type [PSBoundParametersDictionary] to [hashtable]
#--------------------------------------------------------------
$pwshParameters = @{}
foreach ($key in $PSBoundParameters.Keys) {
	if ($PSBoundParameters.$key -is [securestring]) {
		$pwshParameters.$key = '[securestring]'
	}
	elseif ($PSBoundParameters.$key -is [switch]) {
		$pwshParameters.$key = $PSBoundParameters.$key -as [boolean]
	}
	else {
		$pwshParameters.$key = $PSBoundParameters.$key
	}
}
$boundParameterNames = $PSBoundParameters.keys

#--------------------------------------------------------------
function get-environment {
#--------------------------------------------------------------
	param (
		$variable,
		$default
	)

	# no entry in $error if environment variable is not set:
	$exists = get-Item "Env:$variable*" 
	if ($Null -eq $exists) {
		return $default
	}
	
	# however, there might be an $error entry, if similar environment variable exists ($variable*)
	$env = get-Item "Env:$variable" -ErrorAction 'SilentlyContinue'
	if ($Null -eq $env) {
		return $default
	}

	return $env.value
}

#--------------------------------------------------------------
function test-isAzure {
#--------------------------------------------------------------
	$script:isAzure = $false
	try {
		$azureData = Invoke-RestMethod `
						-Headers @{Metadata = 'true'} `
						-Method 'Get' `
						-Uri 'http://169.254.169.254/metadata/instance?api-version=2021-02-01'
		if ($azureData) {
			$script:isAzure = $true
			$script:azureVM = $azureData.compute.name
			$script:azureRegion = $azureData.compute.location
			# $script:azureRgName = $azureData.compute.resourceGroupName
		}
	} 
	catch {}
}

#--------------------------------------------------------------
# For debugging, you have to set: $Env:ErrorActionPreference = 'Continue'
$ErrorActionPreference	= get-environment 'ErrorActionPreference' 'Stop'
$ProgressPreference		= 'SilentlyContinue'
$InformationPreference	= 'SilentlyContinue'
$VerbosePreference		= 'SilentlyContinue'

#-------------------------------------------------------------
function set-mode {
#-------------------------------------------------------------
	$script:suppliedModes = @()
	$script:cloneOrMergeMode = $False

	# Clone Mode
	if ($cloneMode) {
		$script:suppliedModes 		+= 'cloneMode'
		$script:rgcopyMode			= 'clone'
		$script:cloneOrMergeMode	= $True
	}

	# Merge Mode
	if ($mergeMode) {
		$script:suppliedModes 		+= 'mergeMode'
		$script:rgcopyMode			= 'merge'
		$script:cloneOrMergeMode	= $True
	}

	# Patch Mode
	if ($patchMode) {
		$script:suppliedModes 		+= 'patchMode'
		$script:rgcopyMode			= 'patch'
	}

	# Update Mode
	if ($updateMode) {
		$script:suppliedModes 		+= 'updateMode'
		$script:rgcopyMode			= 'update'
	}

	# Archive Mode
	if ($archiveMode) {
		$script:suppliedModes 		+= 'archiveMode'
		$script:rgcopyMode			= 'archive'
	}

	# Copy Mode
	if ($suppliedModes.count -eq 0) {
		$script:rgcopyMode			= 'copy'
		$script:copyMode = $True
	}

	# process only sourceRG ?
	if (    $updateMode `
		-or $patchMode `
		-or $cloneMode `
		-or $justCreateSnapshots `
		-or $justDeleteSnapshots `
		-or ($mergeMode -and ('targetRG' -notin $boundParameterNames)) `
	) {
		$script:SourceOnlyMode = $True
		$script:targetRG = $sourceRG
	}
	else {
		$script:SourceOnlyMode = $False
	}
}

#-------------------------------------------------------------
function set-constants {
#-------------------------------------------------------------
	# constants
	$script:snapshotExtension			= 'rgcopy'
	$script:netAppSnapshotName			= 'rgcopy'
	$script:targetSaContainer			= 'rgcopy'
	$script:sourceSaShare				= 'rgcopy'
	$script:netAppPoolSizeMinimum		= 4 * 1024 * 1024 * 1024 * 1024

	# azure tags
	$script:azTagMonitorRule			= 'rgcopy.MonitorRule'
	$script:azTagVmType 				= 'rgcopy.VmType'
	$script:azTagTipGroup 				= 'rgcopy.TipGroup'
	$script:azTagDeploymentOrder 		= 'rgcopy.DeploymentOrder'
	$script:azTagSapMonitor 			= 'rgcopy.Extension.SapMonitor'
	$script:azTagDiagSettingsSA 		= 'rgcopy.diagSettingsSA'
	$script:azTagDiagSettingsContainer	= 'rgcopy.diagSettingsContainer'
	$script:azTagScriptStartSap 		= 'rgcopy.ScriptStartSap'
	$script:azTagScriptStartLoad 		= 'rgcopy.ScriptStartLoad'
	$script:azTagScriptStartAnalysis	= 'rgcopy.ScriptStartAnalysis'
}

#-------------------------------------------------------------
function set-paths {
#-------------------------------------------------------------
	# file names and location
	$script:pathExportFolder = get-environment 'rgcopyExportFolder' $pathExportFolder

	if ($(Test-Path $pathExportFolder) -ne $True) {
		$script:pathExportFolderNotFound = $pathExportFolder
		$script:pathExportFolder = '~'
	}
	$script:pathExportFolder = Resolve-Path $pathExportFolder

	# filter out special characters for file names
	$script:timestampSuffix = (Get-Date -Format 'yyyy-MM-dd__HH-mm-ss')
	$sourceRG2 = $sourceRG -replace '\.', '-'   -replace '[^\w-_]', ''
	$targetRG2 = $targetRG -replace '\.', '-'   -replace '[^\w-_]', ''
	if ($justCopySaShares) {
		$sourceRG2 = $sourceRG2 + '.shares'
		$targetRG2 = $targetRG2 + '.shares'
	}
	$script:logPrefixSource		= "rgcopy.$sourceRG2"
	$script:logPrefixTarget		= "rgcopy.$targetRG2"

	# default file paths
	$script:importPath 			= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.SOURCE.json"
	$script:exportPath 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.TARGET.bicep"

	# log path
	$script:logPath				= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.TARGET.log"
	if ($archiveMode) {
		$script:logPath			= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.$sourceRG2.ARCHIVE.log"
	}
	if ($justCopyDisks.count -ne 0) {
		if ($justCopyDisks[0] -eq $true) {
			$script:logPath		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.DISKS.log"
		}
		else {
			$script:logPath		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.DISKS.$($justCopyDisks[0]).log"
		}
	}

	# fixed file paths
	$script:tempPathText 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.TEMP.txt"
	$script:zipPath 			= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.$timestampSuffix.zip"
	$script:zipPath2 			= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.arm-templates.zip"
	$script:savedpwshPath		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.txt"
	$script:restorePath 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.RESTORE.ps1.txt"

	# file names for source RG processing
	if ($SourceOnlyMode) {
		$script:logPath			= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.SOURCE.log"
		$script:zipPath 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.$timestampSuffix.zip"
	}

	# file names for backup RG
	if ($archiveMode) {
		$script:exportPath 	= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.TARGET.bicep"
	}

	# test RGCOPY version
	$script:msInternalVersion = $True
	try {
		test-msInternalVersion
	}
	catch {
		$script:msInternalVersion = $False
	}
}

#--------------------------------------------------------------
function get-fileHashUTF8 {
#--------------------------------------------------------------
    param (
        $path
    )

    # read file, remove CR
    $text = (Get-Content -Path $path -Raw) -replace "`r", ''

    # convert to UTF8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)

    # Create hash
    $hashAlgorithm = [System.Security.Cryptography.HashAlgorithm]::Create('SHA256')
    $hash = $hashAlgorithm.ComputeHash($bytes)

    # Convert to string
    return ([BitConverter]::ToString($hash) -replace '-', '')
}

#--------------------------------------------------------------
function assert-hashes {
#--------------------------------------------------------------
	param (
		$text
	)

	if ($script:installationIssues.count -gt 0) {
		write-logFileWarning $text

		$script:installationIssues
		| Select-Object file, issue
		| write-logFilePipe

		write-logFileError "RGCOPY not installed correctly"
	}
}

#--------------------------------------------------------------
function test-hashes {
#--------------------------------------------------------------
	$hashFile = 'bash\hashes.csv'
	$hashFilePath = Join-Path $pwshPath -ChildPath $hashFile
	$script:installationIssues = @()

	if (!(Test-Path $hashFilePath)) {
		$script:installationIssues += @{
			file = $hashFile
			issue = 'file not found'
		}
	}

	else {
		$text = Get-Content $hashFilePath -ErrorAction 'SilentlyContinue'
		$list = ConvertFrom-Csv $text -Delimiter ';' -ErrorAction 'SilentlyContinue'
		if ($list.count -lt 2) {
			$script:installationIssues += @{
				file = $hashFile
				issue = 'file invalid'
			}
		}

		else {
			# check version
			if ($list[0].hash -ne $pwshVersion) {
				$script:installationIssues += @{
					file = $hashFile
					issue = 'wrong version'
				}
			}
	
			# check other files
			for ($i = 1; $i -lt $list.Count; $i++) {
				$file 			= $list[$i].file
				$hashExpected	= $list[$i].hash
	
				$path = Join-Path $pwshPath -ChildPath $file
	
				# file not found
				if (!(Test-Path $path)) {
					$script:installationIssues += @{
						file = $file
						issue = 'file not found'
					}
				}
	
				# file found
				else {
					$hash = get-fileHashUTF8 $path
	
					# hash wrong
					if ($hash -ne $hashExpected) {
						$script:installationIssues += @{
							file = $file
							issue = 'wrong hash'
						}
					}
				}
			}
		}
	}

	if ($script:installationIssues.count -gt 0) {
		write-logFileTab 'RGCOPY'	'Installation check failed (missing files)' -darkGray
	}
	else {
		write-logFileTab 'RGCOPY'	'Installation check passed'					-darkGray
	}
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
		$len = ((24 - $sourceSaPrefix.Length), $name.Length | Measure-Object -Minimum).Minimum

		$script:sourceSA = $sourceSaPrefix + $name.SubString(0,$len)
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
		$delegationService,
		$defaultSubnet,
		[switch] $create,	# include address prefix for bastion creation
		[switch] $endpoint	# check that no endpoint policy exists
	)

	$param = $parameterValue -replace '\s+', ''
	$vnetName = $null
	$subnetName = $null

	#--------------------------------------------------------------
	# test parameter

	# create new subnet
	if ($create) {
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
	}

	# use existing subnet
	else {
		$vnetName, $subnetName = $param -split '/'
		if ($vnetName.length -eq 0) {
			write-logFileError "Parameter '$parameterName' must be set" `
								"Parameter must match <vnet>/<subnet>"
		}
		if ($null -eq $subnetName) {
			write-logFileError "Invalid parameter '$parameterName'" `
								"Parameter must match <vnet>/<subnet>"
		}
	}

	#--------------------------------------------------------------
	# get vnet from source RG

	# Get source VNETs
	if ($null -eq $script:sourceVNETs) {
		$script:sourceVNETs = @( Get-AzVirtualNetwork `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue' )
		test-cmdlet 'Get-AzVirtualNetwork'  "Could not get VNETs of resource group $sourceRG"
	}

	$vnet = $script:sourceVNETs | Where-Object Name -eq $vnetName

	if ($Null -eq $vnet) {
		write-logFileError "Invalid parameter '$parameterName'" `
							"Vnet '$vnetName' not found"
	}

	#--------------------------------------------------------------
	# get subnet from source RG

	$subnetNames = $vnet.Subnets.Name
	# create new subnet: check if already exists
	if ($create) {
		$subnetName = $defaultSubnet
		if ($subnetName -in $subnetNames) {
			write-logFileError "Invalid parameter '$parameterName'" `
								"Subnet '$subnetName' already exists"
		}

		return $vnetName, $subnetName, $addressPrefix
	}

	# use existing subnet: check delegation and policies
	else {
		if ($subnetName -notin $subnetNames) {
			write-logFileError "Invalid parameter '$parameterName'" `
								"Subnet '$subnetName' not found"
		}

		# check delegation
		$delegations = @()
		foreach ($sub in $vnet.Subnets) {
			if ($sub.Name -eq $subnetName) {
				foreach ($del in $sub.Delegations) {
					$delegations += $del.ServiceName
				}
			}
		}

		# delegation not required, but exists
		if (($null -eq $delegationService) -and ($delegations.count -ne 0)) {
			write-logFileError "Invalid parameter '$parameterName'" `
								"Subnet '$subnetName' has delegation '$($delegations[0])'"
		}

		# delegation reuired, but not exists
		if (($null -ne $delegationService) -and ($delegations.count -eq 0)) {
			write-logFileError "Invalid parameter '$parameterName'" `
								"Subnet '$subnetName' has not delegation '$delegationService'"
		}

		# check PrivateEndpointNetworkPolicies
		if ($endpoint) {
			foreach ($sub in $vnet.Subnets) {
				if ($sub.Name -eq $subnetName) {
					if ($sub.PrivateEndpointNetworkPolicies -ne 'Disabled') {
						write-logFileError "Invalid parameter '$parameterName'" `
											"Subnet '$subnetName' has private endpoint policy '$($sub.PrivateEndpointNetworkPolicies)'"
					}
				}
			}
		}

		return $vnetName, $subnetName
	}	
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
							$errorText2
	}
}

#--------------------------------------------------------------
function write-retry {
#--------------------------------------------------------------
	param (
		$path,
		$line
	)

	# try 5 times 
	# there might be a virus scanner issue: cannot open file
	# or an issue with onedrive
	for ($i = 0; $i -lt 5; $i++) {
		try {
			if ($script:logWriteFailure -eq $true) {
				$lastError = $null
				if ($error.count -gt 0) {
					$lastError = ($error[0] -as [string])
				}
				Write-Host "##### Writing to log file '$path' failed" -ForegroundColor 'Yellow'
				Write-Host "##### $lastError"                         -ForegroundColor 'Yellow'
				"##### Writing to log file failed: $lastError" | Out-File $path -Append -ErrorAction 'Stop'
				$script:logWriteFailure = $false
			}
			$line | Out-File $path -Append -ErrorAction 'Stop'
			break
		}
		catch {
			$script:logWriteFailure = $true
			Start-Sleep -Milliseconds (Get-Random -Minimum 100 -Maximum 500)
		}
	}
}

#--------------------------------------------------------------
function write-logFile {
#--------------------------------------------------------------
	param (
		$print,
		$ForegroundColor,
		[switch] $NoNewLine,
		[switch] $timestamp
	)

	$print = write-secureString $print

	if (!$IsWindows) {
		if ($ForegroundColor -eq 'Gray') {
			$ForegroundColor = $null
		}
		elseif ($ForegroundColor -eq 'DarkGray') {
			$ForegroundColor = $null
		}
		elseif ($ForegroundColor -like '*Blue*') {
			$ForegroundColor = 'Cyan'
		}
	}

	if ($Null -eq $print) {
		$print = ' '
	}
	elseif ($timestamp) {
		$print = "$print $((get-date).toString('HH:mm:ss'))"
	}

	# append to current line
	[string] $script:LogFileLine += $print

	$par = @{ Object = $print }
	if ($NoNewLine) {
		$par.Add('NoNewLine', $True)
	}
	if ($Null -ne $ForegroundColor) {
		$par.Add('ForegroundColor', $ForegroundColor)
	}

	# output to HOST
	if ($hostPlainText) {
		if (!$NoNewLine) {
			Write-Host $script:LogFileLine
		}
	}
	else {
		Write-Host @par
	}

	# output to log file
	if (!$NoNewLine) {
		write-retry $logPath $script:LogFileLine

		# end of line
		[string] $script:LogFileLine = ''
	}
}

#--------------------------------------------------------------
function write-logFilePipe {
#--------------------------------------------------------------
	[CmdletBinding()]
	Param (
		[Parameter(Position=0, Mandatory=$true, ValueFromPipeline=$true)]
		$InputObject,
		[switch] $tab
	)
	begin {
		$log = @()
	}
	process {
		$log += $InputObject
	}
	end {
		# convert to string and add 2 spaces per line
		if ($tab) {
			$log = ($log | out-string).Replace("`r`n","`n").Replace("`n","`n  ")
		}

		# output to HOST
		$log | Out-Host

		# output to log file
		$rendering = $PsStyle.OutputRendering 
		if ($rendering -eq 'Ansi') {
			$PsStyle.OutputRendering = 'PlainText'
		}

		write-retry $logPath $log

		if ($rendering -eq 'Ansi') {
			$PsStyle.OutputRendering = 'Ansi'
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

	try {
		$startTime = $script:rgcopyStatistics[0].timestamp
		$endTime = get-date
		$duration = ($endTime - $startTime).TotalMinutes

		$finalStep = @{
			step			= 'RGCOPY END'
			timestamp		= $endTime
			usedMinutes		= $null
			elapsedMinutes	= $duration
			sizeGB			= $null
			objects			= $null
		}

		if ($exitCode -ne 0) {
			$finalStep.step = "RGCOPY FAILURE: EXIT CODE $exitCode"
		}

		$script:rgcopyStatistics += $finalStep

		write-taskStart "RGCOPY Summary ($sourceLocation -> $targetLocation)" 
		$day = ($script:rgcopyStatistics[0].timestamp).ToString('yyyy-MM-dd')
	
		$script:rgcopyStatistics `
		| Select-Object * `
		| Format-Table `
			@{ Name = "timestamp`n[$day]"; Expression = { $_.timestamp.ToString('HH:mm:ss')}; Width = 12  }, `
			@{ Name = "step`n[name]"; Expression = { $_.step }; Width = 34 }, `
			@{ Name = "elapsed`n[minutes]"; Expression = { "{0:F2}" -f $_.elapsedMinutes }; Alignment = 'Right'; Width = 10 }, `
			@{ Name = "worker`n[minutes]"; Expression = { "{0:F2}" -f $_.usedMinutes }; Alignment = 'Right'; Width = 10 }, `
			@{ Name = "size`n[GiB]"; Expression = { $_.sizeGB }; Alignment = 'Right'; Width = 10 } `
		| Out-String -Width $screenWidthLarge `
		| write-logFilePipe
	}
	catch {}


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
		if ($(Test-Path -Path $savedpwshPath) -eq $True) 
			{$files += $savedpwshPath
		}
		$destinationPath = $zipPath
	}

	# no exit code: just create ZIP file and save it in BLOB
	else {
		$files = @()
		$destinationPath = $zipPath2
	}

	foreach ($logFileName in $script:logFiles) {
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
		$param4
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

	$i = $error.count
	write-logFile ('=' * 60) -ForegroundColor 'DarkGray'
	write-logFile
	write-logFile "messages, not necessarily errors:"
	foreach ($line in $error) {
		write-logFile -ForegroundColor 'DarkGray' "----- message number $i -----"
		write-logFile -ForegroundColor 'DarkGray' ($line -as [string])
		$i = $i -1
	}
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
		$warning,				# write warning
		[switch] $NoNewLine,
		[switch] $continue,
		[switch] $defaultValue,	# write value in gray, because it is the standard value
		[switch] $valueWarning	# write value in yellow
	)

	# shorten type by given replacements
	if ($null -ne $script:shortTypeName[$resourceType]) {
		$resourceType = $script:shortTypeName[$resourceType]
	}

	# special color for variables
	if ($resource -like '<*') {
		$colorResource = 'Cyan'
	}
	else {
		$colorREsource = 'Gray'
	}
	
	# constant for string lengths
	# $resourceTypeLength = 18
	# $resourceLength = 35
	$totalLength = 45

	# continue
	if ($continue) {
		# first 2 parameters have different meaning
		$action = $resourceType
		$value = $resource
	}

	# output of resourceType/resource
	else {
		# resource Type
		Write-logFile -NoNewline "$resourceType/" -ForegroundColor 'DarkGray'

		# resource Name
		$parts = $resource -split '/'
		# multi-part name
		if ($parts.count -gt 1) {

			if ($parts[0].length -gt 14) {
				$part1 = $parts[0].Substring(0,11) + '.../'
			}
			else {
				$part1 = $parts[0] + '/'
			}

			$part2 = $parts[-1].PadRight(100,' ').Substring(0,($totalLength - $resourceType.Length - 1 - $part1.Length))
			write-logFile -NoNewline $part1 -ForegroundColor 'DarkGray'
			write-logFile -NoNewline $part2 -ForegroundColor $colorResource
		}

		# normal name
		else {
			$resource = $resource.PadRight(100,' ').Substring(0,($totalLength - $resourceType.Length - 1))
			write-logFile -NoNewline $resource -ForegroundColor $colorResource
		}
	}

	# warning text
	if ($null -ne $warning) {
		write-logFile $warning -ForegroundColor 'yellow'
		return
	}

	# colors for creation/deletion
	if (($action -like 'delete*') `
	-or ($action -like 'disable*') `
	-or ($action -like 'enable*') `
	-or ($action -like 'remove*') `
	-or ($action -like 'skip*')) {

		$colorAction = 'Blue'
	}
	elseif (($action -like 'keep*') `
	    -or ($action -like 'no*') `
	    -or ($action -like 'has*')) {

		$colorAction = 'DarkGray'
	}
	else {
		$colorAction = 'Green'
	}
	$value = $value -as [string]

	# action value
	Write-logFile -NoNewline "$action " -ForegroundColor $colorAction
	if ($defaultValue) {
		Write-logFile -NoNewline $value	 -ForegroundColor 'DarkGray'
	}
	elseif ($valueWarning) {
		Write-logFile -NoNewline $value -ForegroundColor 'yellow'
	}
	else {
		Write-logFile -NoNewline $value
	}

	# comment1
	Write-logFile $comment1				-NoNewline -ForegroundColor 'Cyan'

	# comment2
	$len = $action.length + $value.length + $comment1.length + $comment2.length
	if ($len -lt 24){
		$pad = ' ' * (24 - $len)
	}

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
		[switch] $noColor,
		[switch] $darkGray
	)

	$typeColor		= 'Gray'
	$resourceColor	= 'Green'
	$infoColor		= 'Gray'

	if ($darkGray) {
		$typeColor		= 'DarkGray'
		$resourceColor	= 'DarkGray'
		$infoColor		= 'DarkGray'
	}

	if ($noColor) {
		$resourceColor	= 'Gray'
		$infoColor		= 'Green'
	}

	$tab = 20

	if ($resource.count -gt 1) {
		Write-logFile "  $($resourceType.PadRight($tab))"	-NoNewline -ForegroundColor $typeColor
		write-logFile "$($resource[0]) "					-ForegroundColor $resourceColor
		foreach ($item in $resource[1..($resource.count - 1)]) {
			Write-logFile "$(' ' * ($tab + 2))$item" 		-ForegroundColor $resourceColor
		}
	}

	else {
		Write-logFile "  $($resourceType.PadRight($tab))" 	-NoNewline -ForegroundColor $typeColor
		write-logFile "$resource "							-NoNewline -ForegroundColor $resourceColor
		Write-logFile $info 								-ForegroundColor $infoColor
	}
}

#--------------------------------------------------------------
function write-taskStart {
#--------------------------------------------------------------
	param (
		$text
	)

	write-logFile ('-' * $starCount) -ForegroundColor 'DarkGray'
	write-logFile $text -ForegroundColor 'Green'
	write-logFile ('-' * $starCount) -ForegroundColor 'DarkGray'
}

#--------------------------------------------------------------
function write-stepStart {
#--------------------------------------------------------------
	param (
		$text,
		$maxDegree,
		[switch] $startMeasurement,
		[switch] $skipLF
	)

	write-logFile ('*' * $starCount) -ForegroundColor DarkGray
	if ($maxDegree -gt 1) {
		write-logFile "$text (up-to $maxDegree threads)" -ForegroundColor 'Green'
	}
	else {
		write-logFile $text -ForegroundColor 'Green'
	}
	write-logFile ('*' * $starCount) -ForegroundColor DarkGray
	# write-logFile ('>>>' + ('-' * ($starCount - 3))) -ForegroundColor DarkGray
	write-logFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') -ForegroundColor DarkGray -NoNewLine
	if ($copyMode) {
		write-logFile "  (target RG: $targetRG)" -ForegroundColor DarkGray 
	}
	else {
		write-logFile
	}

	if (!$skipLF) {
		write-logFile
	}

	if ($startMeasurement) {
		$script:stepText = $text
		$script:stepStartTime = Get-Date
		$script:stepTotalTime = 0
		$script:stepTotalSizeGB = 0
		$script:stepTotalObjects = 0
	}	
}

#--------------------------------------------------------------
function write-stepEnd {
#--------------------------------------------------------------
	param (
		[switch] $endMeasurement
	)

	if ($endMeasurement) {
		$script:stepEndTime = Get-Date
		$script:stepElapsedTime = ($script:stepEndTime - $script:stepStartTime).TotalMinutes
		if ($script:stepTotalSizeGB -eq 0) {
			$script:stepTotalSizeGB = $null
		}
		if ($script:stepTotalObjects -eq 0) {
			$script:stepTotalObjects = $null
		}
		if ($script:stepTotalTime -eq 0) {
			$script:stepTotalTime = $null
		}


		$script:rgcopyStatistics += @{
			step			= $script:stepText
			timestamp		= $script:stepStartTime
			usedMinutes		= $script:stepTotalTime
			elapsedMinutes	= $script:stepElapsedTime
			sizeGB			= $script:stepTotalSizeGB
			objects			= $script:stepTotalObjects
		}

		write-logFile
		# write-logFile "Step '$script:stepText':" -ForegroundColor 'DarkGray'

		# if ($script:stepTotalObjects -gt 0) {
		# 	write-logFile "Step total objects: $script:stepTotalObjects " -ForegroundColor 'DarkGray' 
		# }
		# if ($script:stepTotalSizeGB -gt 0) {
		# 	write-logFile "Step total size: $script:stepTotalSizeGB GiB" -ForegroundColor 'DarkGray' 
		# }
		# if ($script:stepTotalTime -gt 0) {
		# 	write-logFile "Step total time: $("{0:F2}" -f $script:stepTotalTime) minutes" -ForegroundColor 'DarkGray' 
		# }
		write-logFile "'$script:stepText' elapsed time: $("{0:F2}" -f $script:stepElapsedTime) minutes" -ForegroundColor 'DarkGray'
	}
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
		[switch] $environment
	)

	if ($null -eq $paramHashTable) {
		return
	}

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

	if ($environment) {
		$script:hashTableOutput
		| Select-Object @{Name='Environment';Expression={$_.Parameter}}, Value
		| Sort-Object Environment
		| Format-Table
		| Out-String -Width $screenWidthLarge
		| write-logFilePipe
	}
	else {
		$script:hashTableOutput
		| Select-Object Parameter, Value, Type
		| Sort-Object Parameter
		| Format-Table
		| Out-String -Width $screenWidthLarge
		| write-logFilePipe
	}

	if ($script:hashTableOutput.count -eq 0) {
		write-logFile
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

	if ($Null -eq $value) {
		$type = 'Null'
	}
	else {
		$type = $value.gettype().Name
	}

	$script:hashTableOutput += New-Object psobject -Property @{
		Parameter	= $key
		Type		= $type
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
	}

	# skalar input
	elseif ($convertFrom -isnot [array]) {
		Write-Output -NoEnumerate @($convertFrom)
	}

	# array input
	else {
		# removes empty entries from input array: $Null, '', @(). Does not remove @{}
		$output = $convertFrom | Where-Object {$_.length -ne 0}
	
		# empty output
		if (($output.count -eq 0) -or ($output.length -eq 0)) {
			Write-Output -NoEnumerate @()
		}

		# skalar output
		elseif ($output -isnot [array]) {
			Write-Output -NoEnumerate @($output)
		}

		# array output
		else {
			Write-Output -NoEnumerate $output
		}
	}
}

#--------------------------------------------------------------
function get-parameterConfiguration {
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
function get-parameterRule {
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
	get-parameterConfiguration $script:paramConfig

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
	get-parameterRule
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
		get-parameterRule
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
		write-logFileError "Error parsing resource ID:" `
							"$inputString"
	}
	$to = $str.LastIndexOf(')')
	if ($to -ne ($str.length -1)) {
		write-logFileError "Error parsing resource ID:" `
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
	
	if ($Null -ne $subResourceType) {
		$resID += "/$subResourceType/$subResourceName" 
	}

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

	$start = '<'
	$end = '>'

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
		$str = $condensedString -replace '\[', '' -replace '\]', ''

		# get function
		$function, $body = get-functionBody $str $inputString

		# function concat
		if ($function -eq 'concat') {
			# get concat value
			$commaPosition = $body.LastIndexOf(',')
			if ($commaPosition -lt 1) {
				write-logFileError "Error parsing resource ID:" `
									"$inputString"
			}
			$head = $body.Substring(0, $commaPosition)
			$tail = $body.Substring($commaPosition + 1, $body.length - $commaPosition - 1)

			$function, $body = get-functionBody $head $inputString
			# converted to function resourceId
			if ($function -ne 'resourceId') {
				write-logFileError "Error parsing resource ID:" `
									"$inputString"
			}

			# concatenated subresource
			if ($tail -like '*/*') {
				$x, $resType, $resName, $y = $tail -split '/'
				if (($Null -ne $x) -or ($Null -eq $resType) -or ($Null -eq $resName) -or ($Null -ne $y)) {
					write-logFileError "Error parsing resource ID:" `
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
			write-logFileError "Error parsing resource ID:" `
								"$inputString"
		}

		# no 3rd. function allowed
		if ($str -like '(') {
			write-logFileError "Error parsing resource ID:" `
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
			write-logFileError "Error parsing resource ID:" `
								"$inputString"
		}
		if ($Null -eq $mainResourceName) {
			write-logFileError "Error parsing resource ID:" `
								"$inputString"
		}
		if ($subResourceName.count -gt 1) {
			write-logFileError "Error parsing resource ID:" `
								"$inputString"
		}

		$resourceArea,$mainResourceType,$subResourceType = $resourceType -split '/'
		if ($Null -eq $resourceArea) {
			write-logFileError "Error parsing resource ID:" `
								"$inputString"
		}
		if ($Null -eq $mainResourceType) {
			write-logFileError "Error parsing resource ID:" `
								"$inputString"
		}
		if ($subResourceType.count -gt 1) {
			write-logFileError "Error parsing resource ID:" `
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
			write-logFileError "Error parsing resource ID:" `
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
			write-logFileError "Error parsing resource ID:" `
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
		$myContext = $script:availableContexts
		| Where-Object {$_.Account.Id -eq $mySubUser}
		| Where-Object {$_.Subscription.Name -eq $mySub}
	}
	else {
		$myContext = $script:availableContexts
		| Where-Object {$_.Account.Id -eq $mySubUser}
		| Where-Object {$_.Subscription.Name -eq $mySub}
		| Where-Object {$_.Tenant.Id -eq $mySubTenant}
	}

	# display existing contexts
	if ($myContext.count -ne 1) {
		write-logFile 'list of existing contexts:'
		$script:availableContexts
		| Select-Object `
			@{label="AccountId";        expression={$_.Account.Id}}, `
			@{label="SubscriptionName"; expression={$_.Subscription.Name}}, `
			@{label="TenantId";         expression={$_.Tenant.Id}}
		| Format-Table
		| Out-String -Width $screenWidthLarge
		| write-logFilePipe
	}

	# no context found for user/subscription
	if ($myContext.count -eq 0) {
		write-logFileWarning "Run Connect-AzAccount before starting RGCOPY"
		write-logFile

		write-logFileError  "Get-AzContext failed for user: $mySubUser" `
							"Subscription:                  $mySub"
	}

	# multiple contexts found for user/subscription
	if ($myContext.count -gt 1) {
		write-logFileError  "Get-AzContext ambiguous for user: $mySubUser" `
							"Subscription:                     $mySub"
	}

	# set context
	Set-AzContext `
		-Context		$myContext `
		-ErrorAction	'SilentlyContinue' `
		-WarningAction	'SilentlyContinue' `
		| Out-Null

	if (!$?) {
		# This should never happen because Get-AzContext already worked:
		write-logFileError  "Set-AzContext failed for user: $mySubUser" `
							"Subscription:                  $mySub" `
							"Tenant:                        $mySubTenant"
	}
}

#--------------------------------------------------------------
function set-context {
#--------------------------------------------------------------
	param (
		$mySubscription,
		[switch] $restore,
		[switch] $always,		# always display context (even when not changed)
		[switch] $azCliContext	# in addition, set subscription for Azure CLI
	)

	if ($azCliContext) {
		if ($storageCredentialType -eq 'AZCLI') {
			write-logFile "--- set subscription azCLI context $mySubscription ---" -ForegroundColor DarkGray
			try {
				az account set --subscription $mySubscription 2>$null
			}
			catch {
				write-logFileError "'az account set --subscription $mySubscription' failed"
			}
		}
	}

	if ($restore) {
		$mySubscription = $script:savedSub
	}
	$script:savedSub = $script:currentSub

	if (($mySubscription -eq $script:currentSub) -and ($null -ne $script:currentContext)) {
		if ($always) {
			write-logFile "--- set subscription context $mySubscription ---" -ForegroundColor DarkGray
		}
		return
	}

	write-logFile "--- set subscription context $mySubscription ---" -ForegroundColor DarkGray

	# source subscription
	if ($mySubscription -eq $sourceSub) {
		$myContext = $sourceContext
	}

	# target subscription
	elseif ($mySubscription -eq $targetSub) {
		$myContext = $targetContext
	}

	# control plane subscription
	elseif ($mySubscription -eq $controlPlaneSub) {
		$myContext = $controlPlaneContext
	}

	# This should never happen because test-context() already worked:
	else {
		write-logFileError "Invalid Subscription '$mySubscription'"
	}

	Set-AzContext `
		-Context		$myContext `
		-ErrorAction	'SilentlyContinue' `
		-WarningAction	'SilentlyContinue' `
		| Out-Null
	test-cmdlet 'Set-AzContext'  "Could not connect to Subscription '$mySubscription'"

	$script:currentAccountId = $myContext.Account.Id
	$script:currentContext = $myContext
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
			EncryptionAtHostSupported       = $false
			MaxWriteAcceleratorDisksAllowed = 9999
			MaxNetworkInterfaces            = 9999
			AcceleratedNetworkingEnabled    = $True
			TrustedLaunchDisabled           = $False
			LowPriorityCapable				= $false
			CapacityReservationSupported	= $false
			SupportedCapacityReservationTypes = ''
			ConfidentialComputingType		= ''
			HyperVGenerations               = 'V1,V2'
			DiskControllerTypes             = 'SCSI,NVMe'
			CpuArchitectureType             = 'x64'
			UltraSSDAvailableZones         	= '1 2 3'
		}
	}
}

#--------------------------------------------------------------
function convertTo-String {
#--------------------------------------------------------------
	param (
		$value,
		$separator
	)

	if ($null -ne $separator) {
		$sep = $null
		$string = ''
		foreach ($item in $value) {
			$string += "$sep$item"
			$sep = $separator
		}
		return $string
	}

	elseif ($value.Length -eq 0) {
		return $null
	}

	else {
		return ($value -as [string]) # empty string <> $null
	}
}

#--------------------------------------------------------------
function convertTo-Boolean {
#--------------------------------------------------------------
	param (
		$stringOrBool,
		[switch] $nullAsFalse
	)

	# NULL
	if ($Null -eq $stringOrBool) {
		if ($nullAsFalse) {
			return $False
		}
		else {
			return $Null
		}
	}

	# [boolean]
	if ($stringOrBool -is [boolean]) {
		return $stringOrBool
	}

	# [string]
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
function get-skuProperties {
#--------------------------------------------------------------
	if ($Null -ne $script:skuProperties) {
		return
	}

	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	# get SKUs for all VM sizes in target
	$script:skuProperties = Get-AzComputeResourceSku `
								-Location $targetLocation `
								-ErrorAction 'SilentlyContinue'

	test-cmdlet 'Get-AzComputeResourceSku'  "Could not get SKU definition for region '$targetLocation'"

	set-context -restore # *** CHANGE SUBSCRIPTION **************
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

	get-skuProperties

	# max fault domain count
	$script:skuProperties
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
	$script:skuProperties `
	| Where-Object ResourceType -eq 'virtualMachines' `
	| ForEach-Object {

		$vmSize   = $_.Name
		$vmFamily = $_.Family
		$vmTier   = $_.Tier

		# default SKU properties
		$vCPUs                           = 1
		$MemoryGB                        = 0
		$MaxDataDiskCount                = 9999
		$PremiumIO                       = $True
		$EncryptionAtHostSupported       = $false
		$MaxWriteAcceleratorDisksAllowed = 0			# this property is not maintained in all SKUs
		$MaxNetworkInterfaces            = 9999
		$AcceleratedNetworkingEnabled    = $True
		$TrustedLaunchDisabled           = $False
		$LowPriorityCapable              = $false
		$CapacityReservationSupported    = $false
		$SupportedCapacityReservationTypes = ''         # 'Open,Targeted', ''
		$ConfidentialComputingType       = ''           # 'SNP', 'TDX', ''
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
				'EncryptionAtHostSupported'         {$EncryptionAtHostSupported       = $capValueBoolean; break}
				'MaxWriteAcceleratorDisksAllowed'   {$MaxWriteAcceleratorDisksAllowed = $cap.Value -as [int]; break}
				'MaxNetworkInterfaces'              {$MaxNetworkInterfaces            = $cap.Value -as [int]; break}
				'AcceleratedNetworkingEnabled'      {$AcceleratedNetworkingEnabled    = $capValueBoolean; break}
				'TrustedLaunchDisabled'             {$TrustedLaunchDisabled           = $capValueBoolean; break}
				'LowPriorityCapable'                {$LowPriorityCapable              = $capValueBoolean; break}
				'CapacityReservationSupported'      {$CapacityReservationSupported    = $capValueBoolean; break}
				'SupportedCapacityReservationTypes' {$SupportedCapacityReservationTypes  = $cap.Value; break}
				'ConfidentialComputingType'         {$ConfidentialComputingType       = $cap.Value; break}
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
			EncryptionAtHostSupported		= $EncryptionAtHostSupported
			MaxWriteAcceleratorDisksAllowed = $MaxWriteAcceleratorDisksAllowed
			MaxNetworkInterfaces            = $MaxNetworkInterfaces
			AcceleratedNetworkingEnabled    = $AcceleratedNetworkingEnabled
			TrustedLaunchDisabled           = $TrustedLaunchDisabled
			LowPriorityCapable				= $LowPriorityCapable
			CapacityReservationSupported    = $CapacityReservationSupported
			SupportedCapacityReservationTypes = $SupportedCapacityReservationTypes
			ConfidentialComputingType       = $ConfidentialComputingType
			HyperVGenerations               = $HyperVGenerations
			DiskControllerTypes             = $DiskControllerTypes
			CpuArchitectureType             = $CpuArchitectureType
			UltraSSDAvailableZones          = $UltraSSDAvailableZones
		}
	}
}

#--------------------------------------------------------------
function compare-quota {
#--------------------------------------------------------------
# check quotas in target region for each VM Family
	if ($skipVmChecks) {
		return
	}

	write-taskStart "Quotas for Target Resource Group $targetRG"

	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	# VM quota
	if (!$justCopyDisks) {
		$script:copyVMs.values
		| Where-Object Skip -ne $True
		| ForEach-Object {
	
			test-vmSize `
				$_.VmZone `
				$_.VmSize
			
			if ($updateMode) {
				test-vmSize `
					$_.VmZone `
					$_.VmSizeOld `
					-1
			}
		}
		test-vmQuota $targetLocation
	}

	# disk quota
	$diskCount = 1
	$script:copyDisks.values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		test-diskSku `
			$_.DiskZone `
			$_.SkuName `
			$_.SizeGB `
			$diskCount
		
		if ($updateMode) {
			test-diskSku `
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
			$_.DiskZone `
			$_.SkuName `
			$_.SizeGB `
			$diskCount
	}

	test-diskQuota $targetLocation
	show-quota $targetLocation
	set-context -restore # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function import-newVmSizes {
#--------------------------------------------------------------
	# read capabilities from local file
	if ($Null -eq $script:newVmSizes) {

		$path = "$pwshPath\newVmSizes.csv"

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
		$zone,
		$vmSize,
		[int] $factor = 1 # or -1 for removing VM
	)

	get-skuProperties
	$sku = $script:skuProperties
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
							"VM Size '$vmSize' not found in region '$targetLocation'" `
							"You can override this check using file 'newVmSizes.csv' and parameter 'useNewVmSizes'" `
							-stopCondition $True
	}

	if ($Null -ne $sku) {
		# check zone
		if (($zone -gt 0) -and ($zone -notin $sku.LocationInfo.Zones)) {
			write-logFileWarning "VM Consistency check failed" `
								"VM Size '$vmSize' not available in zone $zone of region '$targetLocation'" `
								-stopCondition $True
		}
	
		# check region restrictions
		$restriction = $sku.Restrictions | Where-Object Type -eq 'Location'
		if ($Null -ne $restriction) {
			if ($targetLocation -in $restriction.RestrictionInfo.Locations) {
				write-logFileWarning "VM Consistency check failed" `
								"VM Size '$vmSize' not available in region '$targetLocation': $($restriction.ReasonCode)" `
								-stopCondition $True
			}
		}
	
		# check zone restrictions
		$restriction = $sku.Restrictions | Where-Object Type -eq 'Zone'
		if ($Null -ne $restriction) {
			if (($zone -gt 0) -and ($zone -in $restriction.RestrictionInfo.Zones)) {
				write-logFileWarning "VM Consistency check failed" `
									"VM Size '$vmSize' not available in in zone $zone of region '$targetLocation': $($restriction.ReasonCode)" `
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
		test-cmdlet 'Get-AzVMUsage'  "Could not get quota for region '$region'"
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
		$zone,
		$diskSku,
		$diskSizeGB,
		$diskCount = 1,
		[int] $factor = 1 # or -1 for removing disks
	)

	if ($diskSku -like 'NFS*') {
		return
	}

	get-skuProperties
	$sku = $script:skuProperties
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
							"Disk SKU '$diskSku' not available in region '$targetLocation'" `
							-stopCondition $True
	}
	$sku = $sku[0]
	
	# check zone
	if (($zone -gt 0) -and ($zone -notin $sku.LocationInfo.Zones)) {
		write-logFileWarning "Disk Consistency check failed" `
							"Disk SKU '$diskSku' not available in zone $zone of region '$targetLocation'" `
							-stopCondition $True
	}

	# check region restrictions
	$restriction = $sku.Restrictions | Where-Object Type -eq 'Location'
	if ($Null -ne $restriction) {
		if ($targetLocation -in $restriction.RestrictionInfo.Locations) {
			write-logFileWarning "Disk Consistency check failed" `
							"Disk SKU '$diskSku' not available in region '$targetLocation': $($restriction.ReasonCode)" `
							-stopCondition $True
		}
	}

	# check zone restrictions
	$restriction = $sku.Restrictions | Where-Object Type -eq 'Zone'
	if ($Null -ne $restriction) {
		if (($zone -gt 0) -and ($zone -in $restriction.RestrictionInfo.Zones)) {
			write-logFileWarning "Disk Consistency check failed" `
								"Disk SKU '$diskSku' not available in zone $zone of region '$targetLocation': $($restriction.ReasonCode)" `
								-stopCondition $True
		}
	}

	# check special SKUs
	if ( (!($zone -gt 0)) `
	-and (($diskSku -like 'UltraSSD*') -or ($diskSku -like 'PremiumV2*'))) {
		write-logFileWarning "Disk Consistency check failed" `
							"Disk SKU '$diskSku' must be used for zonal deployment" `
							"Use RGCOPY parameter setVmZone" `
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
		test-cmdlet 'Get-AzVMUsage'  "Could not get quota for region '$region'"
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
	| Out-String -Width $screenWidthLarge
	| write-logFilePipe

	# check quota limit
	if (!$skipVmChecks) {
		foreach ($quota in $script:quotaUsage.Values) {
			if($quota.Free -lt $quota.Needed) {
				write-logFileWarning "Quota check failed" `
									"Subscription quota for '$($quota.QuotaName)' not sufficient in region '$region'" `
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
	write-taskStart "Required existing snapshots in resource group '$sourceRG'"

	# Get source Snapshots again because additional snapshots have been created
	$script:sourceSnapshots = @( Get-AzSnapshot `
		-ResourceGroupName $sourceRG `
		-ErrorAction 'SilentlyContinue' )
	test-cmdlet 'Get-AzSnapshot'  "Could not get snapshots of resource group '$sourceRG'"

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
	| Out-String -Width $screenWidthSmall
	| write-logFilePipe

	if ($skipSnapshots -and ($pathArmTemplate -notin $boundParameterNames)) {

		if ((!$skipDeployment) `
		-or (!$skipRemoteCopy -and $RemoteCopyNeeded)) {

			# check for missing or wrong snapshots
			$script:copyDisks.values
			| Where-Object { (($_.DiskSwapNew -eq $True) -or (($_.Skip -ne $True) -and ($_.DiskSwapOld -ne $True))) }
			| ForEach-Object {
		
				$snapshotName = $_.SnapshotName
				$mySnapshot = $script:sourceSnapshots | Where-Object Name -eq $snapshotName
				if ($Null -eq $mySnapshot) {
					write-logFileError "Snapshot '$snapshotName' not found" `
										-stopCondition $true
				}
				elseif (($mySnapshot.Incremental -eq $False) `
				-and ($_.IncrementalSnapshots -eq $True) `
				-and ($skipSnapshots) ) {
					write-logFileWarning "Wrong property of snapshot '$snapshotName'" `
										"Property 'Incremental' is $($mySnapshot.Incremental), it should be: $($_.IncrementalSnapshots)" `
										-stopCondition $true
				}
			}
		}
	}

	write-logFile
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
function test-controlPlane {
#--------------------------------------------------------------
	if ($shareCopyNeeded) {
		if(!$isAzure) {
			write-logFile "For using share-copy, you must start RGCOPY inside an Azure VM with managed identity:" -ForegroundColor 'red'
			show-azCopyInstructions
			write-logFileError "You must start RGCOPY inside an Azure VM when parameter 'copySaShares' is used."
								"See instructions above."
			return
		}
	}

	if ($blobCopyNeeded -or $snapshotCopyNeeded) {
		if (!$useAzCopy) {
			write-logFile "Disk-copy is much faster when using parameter 'useAzCopy':" -ForegroundColor 'red'
			write-logFile "+ Use an Azure VM with managed identity as control plane for RGCOPY"
			show-azCopyInstructions
		}
		elseif (!$isAzure) {
			write-logFile "AzCopy creates high network I/O. Therefore:" -ForegroundColor 'red'
			write-logFile "+ Use an Azure VM with managed identity as control plane for RGCOPY"
			show-azCopyInstructions
		}
	}
}

#--------------------------------------------------------------
function show-azCopyInstructions {
#--------------------------------------------------------------
	write-logFile "+ Make sure that Service Endpoint 'Microsoft.Storage.Global' is enabled for the VM subnet."
	write-logFile "+ Make sure that the the managed identity has the following RBAC roles on subscription level:"
	write-logFile "    Contributor"
	write-logFile "    Storage Blob Data Contributor                    (needed for share-copy)"
	write-logFile "    Storage File Data Privileged Contributor         (needed for share-copy)"
	write-logFile "    Storage File Data SMB Share Elevated Contributor (needed for share-copy)"
	write-logFile "+ Run connect-AzAccount inside the VM with parameters:"
	write-logFile "    -AuthScope 'Storage', -Identity, -AccountId <managed identity> -SubscriptionName <name>"
	write-logFile "  For cross tenant copy, authenticate the user in the other tenant with connect-AzAccount:"
	write-logFile "    -AuthScope 'Storage', -DeviceAuth, -SubscriptionName <name2>"
	write-logFile "+ Start RGCOPY in the control plane VM using parameters:"
	write-logFile "    -useAzCopy -sourceSubUser <managed identity> [-subnetIdControlPlane <id>] [-maxDOP 0]"
	write-logFile "  maxDOP defines AzCopy parallelism (0 uses maximal parallelism)."
	write-logFile "  subnetIdControlPlane might be needed if RGCOPY does not detect the subnet automatically"
	write-logFile
}

#--------------------------------------------------------------
function show-sourceVMs {
#--------------------------------------------------------------
	write-taskStart "Current VMs/disks in Source Resource Group $sourceRG"

	$script:copyVMs.Values
	| Sort-Object Name
	| Select-Object `
		@{label="VM name";     expression={get-shortOutput $_.Name 42}}, `
		@{label="Zone";        expression={get-replacedOutput $_.VmZone 0}}, `
		@{label="VM size";     expression={$_.VmSize}}, `
		@{label="DataDisks";   expression={$_.DataDisks.count}}, `
		@{label="MountPoints"; expression={get-replacedOutput $_.MountPoints.count 0}}, `
		@{label="NICs";        expression={$_.NicCount}}, `
		@{label="Status";      expression={$_.VmStatus}}, `
		@{label="SecurityType"; expression={get-replacedOutput $_.SecurityType ''}}, `
		@{label="Encr@Host";   expression={get-replacedOutput $_.EncryptionAtHost $False}}
	| Format-Table -Property *
	| Out-String -Width $screenWidthSmall
	| write-logFilePipe

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
		@{label="Skip"; expression={get-replacedOutput $_.Skip $False}}, `
		@{label="SecurityType"; expression={get-replacedOutput $_.SecurityType ''}}
	| Format-Table -Property *
	| Out-String -Width $screenWidthSmall
	| write-logFilePipe

	write-stepEnd

	if (($rgcopyMode -ne 'patch') -and !$justCreateSnapshots) {
		write-taskStart "Copy method for disks"

		if ($createDisksManually) {
			write-logFile "RGCOPY is creating disks manually before deploying BICEP template"
		}
	
		$script:copyDisks.Values
		| Where-Object Skip -ne $True
		| Sort-Object Name
		| Select-Object `
			@{label="Disk Name"; expression={get-shortOutput $_.Name 30}}, `
			@{label="Swap"; expression={get-shortOutput $_.SwapName 20}}, `
			@{label="Gen"; expression={get-replacedOutput $_.HyperVGeneration ''}}, `
			@{label="NVMe"; expression={get-replacedOutput $_.DiskControllerType ''}}, `
			@{label="Sektor"; expression={get-replacedOutput $_.LogicalSectorSize $Null}}, `
			DiskCreationMethod, `
			@{label="SecurityType"; expression={get-replacedOutput $_.SecurityType ''}}
		| Format-Table -Property *
		| Out-String -Width $screenWidthSmall
		| write-logFilePipe
		
		if ($script:blobCopyNeeded) {
			# default for non MS internal subscriptions:
			# use storage account keys
			if (!$targetNoSaKeys) {
				write-logFileWarning 'Using storage account key for BLOB copy to target RG'
				write-logFile "You can change this by using switch 'targetNoSaKeys'"
			}

			# check RBAC roles
			elseif (('Storage Blob Data Contributor' -notin $targetSubRoles) `
			   -and ('Storage Blob Data Owner' -notin $targetSubRoles)) {

				write-logFileError "RBAC role 'Storage Blob Data Contributor' required for target subscription"
			}

			# use delegation keys
			else {
				write-logFile 'Using user delegation token for BLOB copy to target RG'
			}
		}
	
		write-stepEnd
	}
}

#--------------------------------------------------------------
function show-targetVMs {
#--------------------------------------------------------------
	write-taskStart "Configured VMs/disks for Target Resource Group $targetRG"

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
	| Out-String -Width $screenWidthSmall
	| write-logFilePipe

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
	| Format-Table -Property *
	| Out-String -Width $screenWidthSmall
	| write-logFilePipe
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
function get-newCloneName {
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
	
			$_.Rename = get-newCloneName $_.Name 80
			$allClones += $_.Rename
			$allNames += $_.Name
		}

		$script:copyDisks.values
		| ForEach-Object {
	
			$_.Rename = get-newCloneName $_.Name 80
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
				$_.CloneName = get-newCloneName $_.Name $maxLength
			}

			$allClones += $_.CloneName
			$allNames += $_.Name
		}
	
		$script:copyNICs.values
		| ForEach-Object {
	
			$_.Rename = get-newCloneName $_.NicName 80
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
function update-restApiNeeded {
#--------------------------------------------------------------	
	$script:copyDisks.Values
	| ForEach-Object {

		# default value
		$_.RestApiNeeded = $useRestAPI -as [boolean]

		# TrustedLaunch not supported yet (as of June 2026) with Az cmdlets (New-AzSnapshotConfig)
		if ($_.SecurityType -eq 'TrustedLaunch') {
			if ($_.SnapshotCopy) {
				$_.RestApiNeeded = $true	# copy-snapshots
			}
		}

		# LogicalSectorSize not supported yet with Grant-AzSnapshotAccess
		if ($_.LogicalSectorSize -eq 4096) {
			if ($_.BlobCopy) {
				$_.RestApiNeeded = $true	# grant-copySnapshots2Blobs
			}
		}

		# TrustedLaunch/ConfidentialVM was not supported for New-AzDiskConfig
		# (in the meanwhile, parameter SupportedSecurityOption has been added,
		#  but is not working in all subscriptions/regoions)
		if ($_.SecurityType.Length -ne 0) { 
			if ($script:createDisksManually) {
				$_.RestApiNeeded = $true	# new-disks
			}
		}

		# NVMe not supported yet for New-AzDiskConfig
		# Use REST API call instead
		if ($_.DiskControllerType -eq 'NVME') {
			if ($script:createDisksManually) {
				$_.RestApiNeeded = $true	# new-disks
			}
		}
	}
}

#--------------------------------------------------------------
function save-copyDisks {
#--------------------------------------------------------------
	# process disks
	$script:copyDisks = @{}
	$script:copyDisksNew = @{}

	if ($IsLinux -and $isAzure) {
		if (!$useAzCopy) {
			if ('useAzCopy' -notin $boundParameterNames) {
				# $script:useAzCopy = $true
				# write-logFileWarning "Using parameter 'useAzCopy' on Linux VM" `
				# 					"You could change this by explicitly setting 'useAzCopy=`$false'"

			}
		}
	}

	foreach ($disk in $script:sourceDisks) {

		$diskName			= $disk.Name
		$sku				= $disk.Sku.Name -as [string]
		$logicalSectorSize	= $disk.CreationData.LogicalSectorSize
		$securityType		= $disk.SecurityProfile.SecurityType -as [string]
		$encryptionType		= $disk.Encryption.Type -as [string]

		#--------------------------------------------------------------
		# RGCOPY cannot use a confidential VM with encrypted disks
		# because the snapshot must be applied on a different VM (with different TPM)
		if ($securityType -notin @(
			# 'ConfidentialVM_DiskEncryptedWithCustomerKey'
			# 'ConfidentialVM_DiskEncryptedWithPlatformKey'
			# 'ConfidentialVM_NonPersistedTPM'
			'ConfidentialVM_VMGuestStateOnlyEncryptedWithPlatformKey'
			'TrustedLaunch'
			'' )
		) {
			write-logFileError "Security type '$securityType' of disk '$diskName' not supported by RGCOPY"
		}

		#--------------------------------------------------------------
		# RGCOPY only checks that default encryption type (EncryptionAtRestWithPlatformKey) is used
		# The default type is never passed to BICEP by RGCOPY
		if ($encryptionType -notin @(
			# 'EncryptionAtRestWithCustomerKey'
			# 'EncryptionAtRestWithPlatformAndCustomerKeys'
			'EncryptionAtRestWithPlatformKey'
			'' )
		) {
			write-logFileError "Encryption type '$encryptionType' of disk '$diskName' not supported by RGCOPY"
		}
		# do not set default value
		if ($encryptionType -eq 'EncryptionAtRestWithPlatformKey') {
			$encryptionType = ''
		}

		#--------------------------------------------------------------
		# copy mode: default
		if ($useBlobCopy) {
			# blob copy explicitly requested
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
			# same region: no remote copy
			$snapshotCopy 			= $False
			$blobCopy 				= $False	
		}

		#--------------------------------------------------------------
		# copy mode: change default

		# different user or tenant
		if ($differentTenantOrUser) {
			$blobCopy 				= $True
			$snapshotCopy 			= $False
		}

		# parameter useAzCopy overrides default for $blobCopy/$snapshotCopy
		if ($blobCopy -or $snapshotCopy) {
			if ($useAzCopy) {
				$blobCopy 				= $True
				$snapshotCopy 			= $False
			}
		}

		#--------------------------------------------------------------
		# BLOB copy does not work for BLOBs larger than 4TiB using Start-AzStorageBlobCopy
		if ($blobCopy -and ($disk.DiskSizeGB -gt 4096)) {
			
			write-logFileWarning "Cannot use BLOB copy for disks larger than 4TiB -> SNAPSHOT copy"
			$blobCopy			= $False
			$snapshotCopy 		= $True

			if ($differentTenantOrUser) {
				write-logFileError "Cannot use SNAPSHOT copy when using different tenants or users"
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

		#--------------------------------------------------------------
		# confidential VM
		# BadRequest ErrorMessage: Incremental snapshot support is not available for confidential vm.	
		if ($securityType -like 'ConfidentialVM*' ) {
			if ($incrementalSnapshots) {
				$incrementalSnapshots	= $False
			}

			if ($snapshotCopy) {
				write-logFileWarning "Cannot use incremental snapshots for confidential VMs -> BLOB copy"
				$blobCopy 				= $true
				$snapshotCopy 			= $false

				if ($disk.DiskSizeGB -gt 4096) {
					write-logFileError "Cannot use BLOB copy for disks larger than 4TiB"
				}
			}
		}

		# using createDisksManually
		if ($securityType -like 'ConfidentialVM*' ) {
			if ($blobCopy -or $snapshotCopy) {
				if (!$createDisksManually) {
					write-logFileWarning "Creating disks separately outside BICEP template for Confidential VMs"
					write-logFile
					$script:createDisksManually = $true
				}
			}
		}

		#--------------------------------------------------------------
		# OTHER properties
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
			if ($disk.Zones.count -gt 1) {
				write-logFileError "RGCOPY does not support multiple zones for disks"
			}
			$diskZone = $disk.Zones[0] -as [int]
			if ($diskZone -notin @(1,2,3)) {
				write-logFileError "RGCOPY does not support disk zone $diskZone"
			}
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
			AccessSAS 				= ''		# access token for source snapshot
			SecurityDataAccessSAS 	= ''		# access token for source snapshot
			SecurityMetadataAccessSAS 	= ''	# access token for source snapshot
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
			RestApiNeeded			= $false
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
			if ($vm.Zones.count -gt 1) {
				write-logFileError "RGCOPY does not support multiple zones for VMs"
			}	
			$vmZone = $vm.Zones[0] -as [int]
			if ($vmZone -notin @(1,2,3)) {
				write-logFileError "RGCOPY does not support VM zone $vmZone"
			}
		}

		# get PlatformFaultDomain
		if ($Null -eq $vm.PlatformFaultDomain) {
			$platformFaultDomain = -1
		}
		else {
			$platformFaultDomain = $vm.PlatformFaultDomain -as [int]
		}

		# skip/take VMs
		$skip = $false
		if ($takeVMs.count -ne 0) {
			$skip = $true
			if ($vmName -in $takeVMs) {
				$skip = $false
			}
		}
		if ($vmName -in $skipVMs) {
			$skip = $true
		}

		#--------------------------------------------------------------
		# check for future VM security types
		$securityType = $vm.SecurityProfile.SecurityType -as [string]
		if ($securityType -notin @(
			'ConfidentialVM'
			'Standard'
			'TrustedLaunch'
			'' )
		) {
			write-logFileError "Security type '$securityType' of VM '$vmName' not supported by RGCOPY"
		}
		# do not set default value
		if ($securityType -eq 'Standard') {
			$securityType = ''
		}

		#--------------------------------------------------------------
		$script:copyVMs[$vmName] = @{
			Group					= 0
			Name        			= $vmName
			Id						= $vm.Id
			Rename					= ''
			Skip					= $skip
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
			PpgName					= $Null
			PlatformFaultDomain 	= $platformFaultDomain
			DiskControllerType		= $vm.StorageProfile.DiskControllerType -as [string]
			SecurityType			= $securityType
			EncryptionAtHost		= convertTo-Boolean $vm.SecurityProfile.EncryptionAtHost -nullAsFalse
		}
	}
}

#--------------------------------------------------------------
function save-copyNICs {
#--------------------------------------------------------------
	$script:copyNICs = @{}

	# get NICs from source RG
	foreach ($nic in $script:sourceNICs) {
		$nicName = $nic.Name

		$acceleratedNW = $nic.EnableAcceleratedNetworking
		if ($Null -eq $acceleratedNW) {
			$acceleratedNW = $False 
		}

		$ipAddressNames = @()
		foreach ($conf in $nic.IpConfigurations) {

			if ($Null -ne $conf.PublicIpAddress.Id) {
				$r = get-resourceComponents $conf.PublicIpAddress.Id
				$ipAddressNames += $r.mainResourceName
			}
		}

		# save NIC
		$script:copyNICs[$nicName] = @{
			NicName 					= $nicName
			IpAddressNames				= $ipAddressNames
			EnableAcceleratedNetworking	= $acceleratedNW
			VmName						= $Null # will be updated below
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

				# for BICEP, no duplicate resource names are allowed
				if ($nicName -in $script:copyNICs.Values.NicName) {
					write-logFileError "NIC-name '$nicName' is already used in different resource group"
				}

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

				$ipAddressNames = @()
				foreach ($conf in $remoteNIC.IpConfigurations) {

					if ($Null -ne $conf.PublicIpAddress.Id) {
						$r = get-resourceComponents $conf.PublicIpAddress.Id
						$ipAddressNames += $r.mainResourceName
					}
				}

				$script:copyNICs[$nicName] = @{
					NicName 					= $nicName
					IpAddressNames				= $ipAddressNames
					EnableAcceleratedNetworking	= $acceleratedNW
					VmName						= $vmName
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
			$script:copyVMs[$vmName].NicNames += $nic.NicName

			# update IpNames
			$script:copyVMs[$vmName].IpNames += $nic.IpAddressNames
		}
	}
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
function test-disksTargetRG {
#--------------------------------------------------------------
	$targetDisks = @( Get-AzDisk `
						-ResourceGroupName $targetRG `
						-ErrorAction 'SilentlyContinue' )
	test-cmdlet 'Get-AzDisk'  "Could not get disks of resource group $targetRG"

	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$name = $_.Name
		if ($defaultDiskName.Length -gt 0) {
			$name = $defaultDiskName
		}	

		if ($name -in $targetDisks.Name) {
			write-logFileError "Disk $name already exists in target RG"
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
	
	# save internal structures
	save-copyDisks
	save-copyVMs
	save-copyNICs

	test-vmParameter 'skipDisks' $skipDisks -checkSyntaxOnly
	test-vmParameter 'skipSecurityRules' $skipSecurityRules -checkSyntaxOnly
	test-vmParameter 'keepTags' $keepTags -checkSyntaxOnly
	test-vmParameter 'skipVMs' $script:skipVMs | Out-Null
	test-vmParameter 'takeVMs' $script:takeVMs | Out-Null

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

	# run after update-paramSkipVMs:
	update-disksFromVM
	# run after update-disksFromVM:
	update-restApiNeeded

	# copy storage accounts
	$script:copySA = @{}
	update-paramRenameSa

	# file copy
	update-paramSnapshotVolumes
	[int] $script:mountPointsCount = 0
	[int] $script:mountPointsVolumesGB = 0
	$script:fileCopyNeeded = $false
	update-paramCreateVolumes
	if ($script:mountPointsCount -ne 0) {
		# parameter CreateVolumes set:
		# test if parameter subnetNetApp is also set and is valid
		test-subnet 'subnetNetApp' $subnetNetApp 'Microsoft.NetApp/volumes' | Out-Null
	}
	update-paramCreateDisks
	if ($script:mountPointsCount -ne 0) {
		# parameter CreateDisks OR CreateVolumes set:
		# test if parameter subnetEndpoint is also set and is valid
		# (endpoint is needed for copying files)
		test-subnet 'subnetEndpoint' $subnetEndpoint -endpoint | Out-Null

		if ($isWindows) {
			get-VPN
			test-VPN
		}
		$script:fileCopyNeeded = $true
	}
	if ($justCopySaShares) {
		$script:fileCopyNeeded = $false
		$script:stopVMsSourceRG = $false
		$script:stopVMsTargetRG = $false
		if ($script:copySaShares -eq $false) {
			$script:copySaShares = $true
		}
	}

	update-paramSetVmDeploymentOrder
	update-paramSetVmTipGroup
	update-paramSetVmName
	update-paramSkipDisks
	update-paramSwapSnapshot4disk
	save-skuProperties
	get-diskCreationMethod
	test-controlPlane
	show-sourceVMs

	if ($createDisksManually) {
		if ('createDisks' -in $boundParameterNames) {
			write-logFileError "Parameter 'createDisks' not allowed when creating disks manually"
		}
	}

	if (!$cloneOrMergeMode) {
		get-allFromTags $script:sourceVMs $sourceRG
	}

	if ($fileCopyNeeded) {
		assert-hashes "For the file copy feature, additional RGCOPY files are needed"
	}

	# update parameter maxDOP
	if ($copyMode -and ($maxDOP -eq 0)) {
		# one thread for each vhd BLOB to copy
		$script:maxDOP = @($script:copyDisks.Values
							| Where-Object Skip -ne $true).Count

		# there is no need to increase maxDOP for copying meta and state BLOBs 
		# because they are very small and copying them is therefore fast
			
		write-logFileWarning "Changing maxDOP=0 to maxDOP=$script:maxDOP"
	}
}

#--------------------------------------------------------------
function get-diskCreationMethod {
#--------------------------------------------------------------
	$script:snapshotCopyNeeded	= $False
	$script:blobCopyNeeded		= $False

	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		# snapshot copy needed?
		if ($_.SnapshotCopy) {
			$script:snapshotCopyNeeded = $True
		}

		# BLOB copy needed?
		if ($_.BlobCopy) {
			$script:blobCopyNeeded = $True
		}
	}

	# save disk creation method
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		# snapshot method
		if ($_.SnapshotSwap) {
			$diskCreationMethod = 'SNAP (swap)'
		}
		elseif ($_.IncrementalSnapshots) {
			$diskCreationMethod = 'SNAP (inc)'
			if ('skipSnapshots' -in $boundParameterNames) {
				$diskCreationMethod = 'SNAP (inc,exists)'
			}
		}
		else {
			$diskCreationMethod = 'SNAP (full)'
			if ('skipSnapshots' -in $boundParameterNames) {
				$diskCreationMethod = 'SNAP (full,exist)'
			}
		}


		# copy method
		if ($_.BlobCopy) {
			if ($useAzCopy) {
				$diskCreationMethod += ' -> BLOB (AzCopy)'
			}
			else {
				$diskCreationMethod += ' -> BLOB (async)'
			}
		}

		if ($_.SnapshotCopy) {
			$diskCreationMethod += ' -> SNAP COPY'
		}


		# disk creation method
		if ($script:createDisksManually) {
			if ($_.RestApiNeeded) {
				$diskCreationMethod += ' -> DISK (REST-API)'
			}
			else {
				$diskCreationMethod += ' -> DISK'
			}
		}

		else {
			$diskCreationMethod += ' -> BICEP'
		}

		if ($skipDiskCreation) {
			$diskCreationMethod = 'use existing disk'
		}


		# resulting method as string
		$_.DiskCreationMethod = $diskCreationMethod
	}
}

#--------------------------------------------------------------
function update-paramRenameSa {
#--------------------------------------------------------------
	$saNames = @()
	set-parameter 'renameSa' $renameSa
	get-parameterRule
	while ($Null -ne $script:paramConfig) {
		
		if (($Null -ne $script:paramConfig2) -or ($script:paramResources.count -ne 1)) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Invalid configuration '$script:paramConfig'"
		}
		
		$oldName = $script:paramResources[0]
		$newName = $script:paramConfig1

		if ($oldName -in $saNames) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Storage account name '$oldName' already in use"
		}
		$saNames += $oldName

		if ($newName -in $saNames) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Storage account name '$newName' already in use"
		}
		$saNames += $newName

		# source RG
		$script:copySA[$oldName] = @{
			sourceRG = $true
			oldName = $oldName
			newName = $newName
			found = $false
			allowSharedKeyAccess = $null	# [bool] 
			publicNetworkAccess = $null		# 'Disabled', 'Enabled', SecuredByPerimeter'
			defaultAction = $null			# 'Deny', 'Allow'
		}

		# target RG
		$script:copySA[$newName] = @{
			sourceRG = $false
			oldName = $oldName
			newName = $newName
			found = $false
			allowSharedKeyAccess = $null	# [bool] 
			publicNetworkAccess = $null		# 'Disabled', 'Enabled', SecuredByPerimeter'
			defaultAction = $null			# 'Deny', 'Allow'
		}	

		get-parameterRule
	}
}

#--------------------------------------------------------------
function update-paramSnapshotVolumes {
#--------------------------------------------------------------
	$script:snapshotList = @{}
	set-parameter 'snapshotVolumes' $snapshotVolumes
	get-parameterRule
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
		get-parameterRule
	}
}

#--------------------------------------------------------------
function update-paramCreateVolumes {
#--------------------------------------------------------------
	set-parameter 'createVolumes' $createVolumes
	get-parameterRule
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
				Lun				= $null
				VolumeName 		= $null
			}
			$script:mountPointsCount++
			$script:mountPointsVolumesGB += $mountPointSizeGB

			if ($script:copyVMs[$mountPointVM].OsDisk.OsType -ne 'linux') {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"VM '$mountPointVM' is not a Linux VM"
			}
		}
		get-parameterRule
	}
}

#--------------------------------------------------------------
function update-paramCreateDisks {
#--------------------------------------------------------------
	set-parameter 'createDisks' $createDisks
	get-parameterRule
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
				Lun				= $null
				VolumeName 		= $null
			}
			$script:mountPointsCount++
			$script:copyVMs[$mountPointVM].NewDataDiskCount++

			if ($script:copyVMs[$mountPointVM].OsDisk.OsType -ne 'linux') {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"VM '$mountPointVM' is not a Linux VM"
			}
		}

		get-parameterRule
	}

	if ($script:snapshotList.count -lt $script:mountPointsCount) {
		write-logFileWarning "Create snapshots for all NetApp volumes (parameter 'snapshotVolumes')" `
							"- number of snapshots (snapshotVolumes): $($script:snapshotList.count)" `
							"- number of mount points (createVolumes, createDisks): $script:mountPointsCount"
	}
}

#--------------------------------------------------------------
function update-paramSetVmDeploymentOrder {
#--------------------------------------------------------------
	set-parameter 'setVmDeploymentOrder' $setVmDeploymentOrder
	get-parameterRule
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

		get-parameterRule
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
	get-parameterRule
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

		get-parameterRule
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
	get-parameterRule
	while ($Null -ne $script:paramConfig) {

		if ($script:paramDisks.count -ne 1) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"The syntax is: <newDisk>@<oldDisk>"
		}
		# check if old disk exists, already done in get-parameterRule
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

		get-parameterRule
	}
}

#--------------------------------------------------------------
function update-paramSwapSnapshot4disk {
#--------------------------------------------------------------
	set-parameter 'swapSnapshot4disk' $swapSnapshot4disk
	get-parameterRule
	while ($Null -ne $script:paramConfig) {

		if ($script:paramDisks.count -ne 1) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"The syntax is: <snapshot>@<disk>"
		}
		# check if disk exists, already done in get-parameterRule
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

		get-parameterRule
	}

	update-paramSwapDisk4disk
}

#--------------------------------------------------------------
function update-paramSetVmName {
#--------------------------------------------------------------
	set-parameter 'setVmName' $setVmName
	get-parameterRule
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

		get-parameterRule
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
	get-parameterRule
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

		get-parameterRule
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
	get-parameterRule
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

		get-parameterRule
	}
}

#--------------------------------------------------------------
function update-paramAttachAvailabilitySet {
#--------------------------------------------------------------
	set-parameter 'attachAvailabilitySet' $attachAvailabilitySet
	get-parameterRule
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

		get-parameterRule
	}
}

#--------------------------------------------------------------
function update-paramAttachProximityPlacementGroup {
#--------------------------------------------------------------
	set-parameter 'attachProximityPlacementGroup' $attachProximityPlacementGroup
	get-parameterRule
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

		get-parameterRule
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
	$script:collectedSkipVMs = @()
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

		# correct status
		if ($_.Skip -eq $True) {
			$_.VmStatus = "skipped (will not be copied)"
			$script:collectedSkipVMs += $_.Name
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

	# skip disks that are not attached to any VM
	$detachedDisks = @()
	$script:copyDisks.values
	| ForEach-Object {
		
		if ($_.VM.length -eq 0) {
			$detachedDisks += $_.Name

			if (!$copyDetachedDisks -and !$justCopyDisks) {
				$_.Skip = $True
			}
		}
	}

	if ($copyDetachedDisks -and !$justCreateSnapshots) {
		if ($detachedDisks.Count -gt 0) {
			if ($null -eq $defaultDiskZone) {
				write-logFileError "Parameter 'defaultDiskZone' must be suppied when parameter 'copyDetachedDisks' is set"
			}
		}
	}
	
	else {
		if (($detachedDisks.count -ne 0) `
		-and !$cloneOrMergeMode `
		-and !$patchMode `
		-and !$copyDetachedDisks `
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
	if ($paramName -in @('skipVMs', 'takeVMs')) {
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
function update-paramsetVmEncryptionAtHost {
#--------------------------------------------------------------
	set-parameter 'setVmEncryptionAtHost' $setVmEncryptionAtHost
	get-parameterRule
	while ($Null -ne $script:paramConfig) {

		test-values 'setVmEncryptionAtHost' $script:paramConfig @('True','False') 'EncryptionAtHost'

		$script:copyVMs.values
		| Where-Object Name -in $script:paramVMs
		| ForEach-Object {

			$_.EncryptionAtHostNew = ($script:paramConfig -eq 'True')
		}
		get-parameterRule
	}

	# output of changes
	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$vmName 	= $_.Name
		$vmSize 	= $_.VmSize
		$current	= $_.EncryptionAtHost
		$wanted		= $_.EncryptionAtHostNew
		if ($Null -eq $wanted) {
			$wanted = $current
		}

		if ($wanted -eq $true) {
			# check if EncryptionAtHost is supported by vmSize
			if (!$script:vmSkus[$vmSize].EncryptionAtHostSupported) {
				$wanted = $false
				write-logFileWarning "EncryptionAtHost not supported for $vmSize"
			}

			# check if EncryptionAtHost is availbale in target subscription
			if (!$targetSubEncryptionAtHost) {
				$wanted = $false
				write-logFileWarning "EncryptionAtHost not supported in target subscription"
			}
		}

		# update
		if ($current -ne $wanted) {
			$_.EncryptionAtHost = $wanted
			$action = 'set'
		}
		else {
			$action = 'keep'
		}

		# output
		if ($_.EncryptionAtHost -eq $False) {
			write-logFileUpdates 'virtualMachines' $vmName "$action EncryptionAtHost" $_.EncryptionAtHost -defaultValue
		}
		else {
			write-logFileUpdates 'virtualMachines' $vmName "$action EncryptionAtHost" $_.EncryptionAtHost
		}
	}
}

#--------------------------------------------------------------
function update-paramSetVmZone {
#--------------------------------------------------------------
	set-parameter 'setVmZone' $setVmZone
	get-parameterRule
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
		get-parameterRule
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
	get-parameterRule
	while ($Null -ne $script:paramConfig) {

		$vmSizeConfig = $script:paramConfig
		$script:copyVMs.values
		| Where-Object Name -in $script:paramVMs
		| ForEach-Object {

			$_.VmSizeNew = $vmSizeConfig
		}
		get-parameterRule
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
								-stopCondition $True
		}

		# check NIC count
		$nicCount = $_.NicCount
		$nicCountMax = $script:vmSkus[$vmSize].MaxNetworkInterfaces
		if ($nicCount -gt $nicCountMax) {
			write-logFileWarning "VM consistency check failed" `
								"Size '$vmSize' of VM '$vmName' only supports $nicCountMax network interface(s)" `
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
								-stopCondition $True
		}

		# check CpuArchitectureType: 'x64', 'Arm64'
		$cpuTypeOld = $script:vmSkus[$_.VmSizeOld].CpuArchitectureType
		# old VM size might not be available in target region
		if ($Null -ne $cpuTypeOld) {
			$cpuTypeNew = $script:vmSkus[$_.VmSize].CpuArchitectureType
			if ($cpuTypeOld -ne $cpuTypeNew) {
				write-logFileWarning "Cannot change from CPU architecture '$cpuTypeOld' (VM size '$($_.VmSizeOld)')" `
									"to CPU architecture '$cpuTypeNew' (VM size '$vmSize')" `
									-stopCondition $True
			}
		}
	}
}

#--------------------------------------------------------------
function update-paramSetDiskSku {
#--------------------------------------------------------------
	# process RGCOPY parameter
	set-parameter 'setDiskSku' $setDiskSku
	get-parameterRule
	while ($Null -ne $script:paramConfig) {

		$sku = $script:paramConfig
		test-values 'setDiskSku' $sku @(
									'false'
									'Premium_LRS'
									'StandardSSD_LRS'
									'Standard_LRS'
									'Premium_ZRS'
									'StandardSSD_ZRS'
									'PremiumV2_LRS'
									'UltraSSD_LRS') 'sku'

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
		get-parameterRule
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
				if (!$skipDefaultValues) {
					write-logFileWarning "Not using default value 'Premium_LRS' for disks with SKU '$current'"
				}
			}
		}

		#--------------------------------------------------------------
		# current is ULTRA disk
		if ($current -in @('UltraSSD_LRS', 'PremiumV2_LRS')) {
			# check if SKU can be changed
			if ($wanted -notin @('UltraSSD_LRS', 'PremiumV2_LRS')) {
				if ($_.LogicalSectorSize -ne 512) {
					write-logFileWarning "Disk SKU '$current' of disk '$diskName' cannot be changed to '$wanted'" `
										"because the logical sector size is not 512" `
										-stopWhenForceVmChecks
					$wanted = $current
				}
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

			# check VM settings (not when justCopyDisks)
			if ($justCopyDisks.count -eq 0) {

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
		}

		#--------------------------------------------------------------
		# check VM properties (not when justCopyDisks)
		if ($justCopyDisks.count -eq 0) {

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
		}

		#--------------------------------------------------------------
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
	get-parameterRule
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
		get-parameterRule
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
	get-parameterRule
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
		get-parameterRule
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
		if ($updateMode) {
			if ($wanted -ne $current) {
				if ($_.ManagedBy.count -ne 0) {
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
	get-parameterRule
	while ($Null -ne $script:paramConfig) {

		$tierName = $script:paramConfig.ToUpper()
		test-values 'setDiskTier' $tierName @( 'P0', 'P1', 'P2', 'P3', 'P4', 'P6', 'P10', 'P15', 'P20', 'P30', 'P40', 'P50', 'P60', 'P70', 'P80') 'tier'
		$tierSizeGB = get-diskSize $tierName

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			$_.performanceTierGBNew = $tierSizeGB
		}
		get-parameterRule
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
	get-parameterRule
	while ($Null -ne $script:paramConfig) {

		test-values 'setDiskBursting' $script:paramConfig @('True','False') 'bursting'
		$burstingConfig = $script:paramConfig -eq 'True'

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			$_.BurstingEnabledNew = $burstingConfig
		}
		get-parameterRule
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
	get-parameterRule
	while ($Null -ne $script:paramConfig) {

		$DiskIOPSReadWrite = $script:paramConfig1 -as [int]

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			$_.DiskIOPSReadWriteNew = $DiskIOPSReadWrite
		}
		get-parameterRule
	}
}

#--------------------------------------------------------------
function update-paramSetDiskMBps {
#--------------------------------------------------------------
	# process RGCOPY parameter
	set-parameter 'setDiskMBps' $setDiskMBps
	get-parameterRule
	while ($Null -ne $script:paramConfig) {

		$DiskMBpsReadWrite = $script:paramConfig1 -as [int]

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			$_.DiskMBpsReadWriteNew = $DiskMBpsReadWrite
		}
		get-parameterRule
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
	get-parameterRule
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
		get-parameterRule
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
	get-parameterRule
	while ($Null -ne $script:paramConfig) {

		test-values 'setAcceleratedNetworking' $script:paramConfig @('True','False') 'AcceleratedNetworking'
		$acceleratedNW = $script:paramConfig -eq 'True'

		$script:copyNICs.values
		| Where-Object {$_.NicName -in $script:paramNICs}
		| ForEach-Object {

			$_.EnableAcceleratedNetworkingNew = $acceleratedNW
		}
		get-parameterRule
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
	| Sort-Object NicName
	| ForEach-Object {

		$nicName	= $_.NicName
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
function new-snapshotsVolumes {
#--------------------------------------------------------------
	if ($script:snapshotList.count -eq 0) {
		return
	}

	write-stepStart "CREATE NetApp SNAPSHOTS" $maxDOP -startMeasurement

	#--------------------------------------------------------------
	# create script and parameters
	$scriptParameter =  "`$netAppSnapshotName = '$netAppSnapshotName';"

	$script = {
		Write-Output "... $($_.Volume)"

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
			-ErrorAction 'SilentlyContinue' | Out-Null
		if (!$?) {
			Write-Output "---> $($error[0] -as [string])"
			throw "Creation of NetApp snapshot on volume $($_.Volume) failed"
		}

		Write-Output "$($_.Volume)"
	}

	#--------------------------------------------------------------
	# start script in parallel
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	write-logFile "Creating NetApp snapshot..."

	$script:snapshotList.Values
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Creation of NetApp snapshots failed"
	}

	$script:stepTotalObjects = $script:snapshotList.Count
	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
function new-snapshots {
#--------------------------------------------------------------
	write-stepStart "CREATE SNAPSHOTS" $maxDOP -startMeasurement

	#--------------------------------------------------------------
	# create script and parameters
	$scriptParameter = "`$sourceRG = '$sourceRG';"

	$script = {
		$startTime = get-date
		$SnapshotName = $_.SnapshotName

		if ($_.IncrementalSnapshots) {
			Write-Output "... $SnapshotName (inc. snapshot)"
		}
		else {
			Write-Output "... $SnapshotName (full snapshot)"
		}

		#--------------------------------------------------------------
		try {
			# revoke Access
			Revoke-AzSnapshotAccess `
				-ResourceGroupName  $sourceRG `
				-SnapshotName       $SnapshotName `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop' | Out-Null

			# remove snapshot
			Remove-AzSnapshot `
				-ResourceGroupName  $sourceRG `
				-SnapshotName      	$SnapshotName `
				-Force `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop' | Out-Null
		}
		catch { 
			# snapshot not found
			# continue RGCOPY
		}

		#--------------------------------------------------------------
		try {
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

			# create snapshot
			New-AzSnapshot `
				-Snapshot           $conf `
				-SnapshotName       $SnapshotName `
				-ResourceGroupName  $sourceRG `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop' | Out-Null		
		}
		catch {
			Write-Output "---> $($error[0] -as [string])"
			throw "Creation of snapshot '$SnapshotName' failed"
		}

		# display single statistics
		$endTime = get-date
		$_.TotalMinutes = ($endTime - $startTime).TotalMinutes
		Write-Output "$SnapshotName ($($_.sizeGB) GB, $("{0:F2}" -f $_.TotalMinutes) minutes)"
	}

	#--------------------------------------------------------------
	# start script in parallel
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	write-logFile "Creating snapshot..."

	$script:copyDisks.Values
	| Where-Object { (($_.DiskSwapNew -eq $True) -or (($_.Skip -ne $True) -and ($_.DiskSwapOld -ne $True))) }
	| Where-Object SnapshotSwap -ne $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Creation of snapshots failed"
	}

	#--------------------------------------------------------------
	# calculate total statistics
	$script:copyDisks.Values
	| Where-Object { (($_.DiskSwapNew -eq $True) -or (($_.Skip -ne $True) -and ($_.DiskSwapOld -ne $True))) }
	| Where-Object SnapshotSwap -ne $True
	| ForEach-Object {

		$script:stepTotalObjects	+= 1
		$script:stepTotalSizeGB		+= $_.SizeGB
		$script:stepTotalTime		+= $_.TotalMinutes
	}
	write-stepEnd -endMeasurement


	#==============================================================
	# wait for snapshot completion
	$incrementalSnapshots = @( $script:copyDisks.Values
								| Where-Object { (($_.DiskSwapNew -eq $True) -or (($_.Skip -ne $True) -and ($_.DiskSwapOld -ne $True))) }
								| Where-Object SnapshotSwap -ne $True
								| Where-Object IncrementalSnapshots -eq $True )

	if ($incrementalSnapshots.count -gt 0) {

		write-logFileWarning "Do not manually create INCREMENTAL snapshots while RGCOPY is running"
		write-logFile

		if (!$(wait-completion "INCREMENTAL SNAPSHOT" `
					'snapshots' $sourceRG $snapshotWaitCreationMinutes)) {

			write-logFileError "INCREMENTAL SNAPSHOT COMPLETION did not finish within $snapshotWaitCreationMinutes minutes"
		}
	}
}

#--------------------------------------------------------------
function wait-copySnapshots {
#--------------------------------------------------------------
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************


	if (!$(wait-completion "SNAPSHOT COPY" `
		'snapshots' $targetRG $snapshotWaitCopyMinutes)) {
		write-logFileError "SNAPSHOT COPY COMPLETION did not finish within $snapshotWaitCopyMinutes minutes"
		}

	set-context -restore # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function get-azureToken {
#--------------------------------------------------------------
	param (
		$ResourceUrl
	)

	$param = @{
		AsSecureString = $true
		WarningAction = 'SilentlyContinue'
		ErrorAction = 'SilentlyContinue'
	}

	if ($null -ne $ResourceUrl) {
		$param.ResourceUrl = $ResourceUrl
	}

	$secureToken = Get-AzAccessToken @param 
	test-cmdlet 'Get-AzAccessToken'  "Could not get Azure token"
	
	return (ConvertFrom-SecureString $secureToken.Token -AsPlainText)
}

#--------------------------------------------------------------
function set-copyDisksAzureToken {
#--------------------------------------------------------------
	$token = get-azureToken

	$script:copyDisks.Values
	| ForEach-Object {

		if ($_.RestApiNeeded) {
			$_.TokenRestAPI = $token
		}
		else {
			$_.TokenRestAPI = $Null
		}
	}
}

#--------------------------------------------------------------
function copy-snapshots {
#--------------------------------------------------------------
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	write-stepStart "START COPY SNAPSHOTS" $maxDOP -startMeasurement

	set-copyDisksAzureToken

	#--------------------------------------------------------------
	# create script and parameters
	$scriptParameter = @"
		`$targetLocation		= '$targetLocation'
		`$targetRG				= '$targetRG'
		`$sourceRG				= '$sourceRG'
		`$targetSubID			= '$targetSubID'
		`$sourceSubID			= '$sourceSubID'
"@

	$script = {
		$SnapshotName	= $_.SnapshotName
		$SnapshotId		= $_.SnapshotId
		$token			= $_.TokenRestAPI

		if ($Null -ne $token) {
			#--------------------------------------------------------------
			# use REST API
			Write-Output "... $SnapshotName (using REST API)"

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
				Write-Output "---> $($error[0] -as [string])"
				throw "'$SnapshotName' snapshot copy failed"
			}
		}

		else {
			#--------------------------------------------------------------
			# use Az cmdlet
			Write-Output "... $SnapshotName"

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
				Write-Output "---> $($error[0] -as [string])"
				throw "'$SnapshotName' snapshot copy failed"
			}

			# create snapshot copy
			New-AzSnapshot `
				-Snapshot           $conf `
				-SnapshotName       $SnapshotName `
				-ResourceGroupName  $targetRG `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop' | Out-Null
			}
			
		#--------------------------------------------------------------
		if (!$?) {
			Write-Output "---> $($error[0] -as [string])"
			throw "'$SnapshotName' snapshot copy failed"
		}
		Write-Output $SnapshotName
	}

	#--------------------------------------------------------------
	# start script in parallel
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	write-logFile "Copying snapshot to snapshot..."

	$script:copyDisks.Values
	| Where-Object { (($_.DiskSwapNew -eq $True) -or (($_.Skip -ne $True) -and ($_.DiskSwapOld -ne $True))) }
	| Where-Object SnapshotCopy -eq $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Copy of snapshots failed"
	}

	#--------------------------------------------------------------
	# calculate total statistics
	$script:copyDisks.Values
	| Where-Object { (($_.DiskSwapNew -eq $True) -or (($_.Skip -ne $True) -and ($_.DiskSwapOld -ne $True))) }
	| Where-Object SnapshotCopy -eq $True
	| ForEach-Object {

		$script:stepTotalObjects	+= 1
		$script:stepTotalSizeGB		+= $_.SizeGB
	}
	write-stepEnd -endMeasurement

	set-context -restore # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
$script:waitCount = 0
$script:waitArray = 0,0, 1,1,1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2, 3,3,3,3,3,3, 4,4,4,4,4, 5,5,5,5, 6,6,6, 7,8,9
#--------------------------------------------------------------
function get-waitTime {
#--------------------------------------------------------------
	if ($script:waitCount -ge $script:waitArray.count) {
		$script:waitTime = 10
	}
	else {
		$script:waitTime = $script:waitArray[$script:waitCount++]
	}
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

	write-stepStart "$step COMPLETION" -startMeasurement

	$script:waitCount = 0
	$count = 0
	$res = $null
	do {
		switch ($type) {
			'disks' {
				$res = @(
					Get-AzDisk `
						-ResourceGroupName $resourceGroup `
						-ErrorAction 'SilentlyContinue'
				)
			}

			'snapshots' {
				$res = @(
					Get-AzSnapshot `
						-ResourceGroupName $resourceGroup `
						-ErrorAction 'SilentlyContinue'
				)
			}

			Default {
				write-logFileError "Internal RGCOPY error"
			}
		}
		if (!$?) {
			write-logFileWarning "Could not get $type of resource group '$resourceGroup'"
			get-waitTime
			write-logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') $step COMPLETION. Next wait time: $script:waitTime minutes" -ForegroundColor 'DarkGray'
			Start-Sleep -seconds (60 * $script:waitTime)
			write-logFile
			continue
		}

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
				$padGB = $(' ' * 5) + $item.DiskSizeGB
				$padGB = $padGB.SubString($padGB.length - 5, 5)
	
				if ($percent -eq 100) {
					write-logFile "$padPercent`% (of $padGB`GB) $($item.Name)" -ForegroundColor 'Green'
				}
				else {
					write-logFile "$padPercent`% (of $padGB`GB) $($item.Name)" -ForegroundColor 'DarkYellow'
				}
			}
		}

		if ($percentAll -lt 100) {
			get-waitTime
			write-logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') $step COMPLETION. Next wait time: $script:waitTime minutes" -ForegroundColor 'DarkGray'
			Start-Sleep -seconds (60 * $script:waitTime)
			$count += $script:waitTime
			write-logFile
		}
	} 
	while ( ($percentAll -lt 100) -and ($count -lt $waitMinutes) )

	#--------------------------------------------------------------
	# calculate total statistics
	$script:stepTotalObjects = $res.Count
	write-stepEnd -endMeasurement

	return ($percentAll -eq 100) 
}

#--------------------------------------------------------------
function get-rgType {
#--------------------------------------------------------------
	param (
		$resourceGroup
	)

	if ($resourceGroup -eq $sourceRG) {
		return 'SOURCE RG'
	}
	elseif ($resourceGroup -eq $targetRG) {
		return 'TARGET RG'
	}
	else {
		write-logFileError 'Internal RGCOPY error'
	}
}

#--------------------------------------------------------------
function remove-snapshots {
#--------------------------------------------------------------
	param (
		$resourceGroup,
		$snapshotNames
	)

	$rgType = get-rgType $resourceGroup
	write-stepStart "DELETE SNAPSHOTS IN $rgType" $maxDOP -startMeasurement

	$snapshots = @()
	foreach ($name in $snapshotNames) {
		$snapshots += @{
			Name = $name
			TotalMinutes = 0
		}
	}

	#--------------------------------------------------------------
	# create script and parameters
	$scriptParameter = "`$resourceGroup = '$resourceGroup';"

	$script = {
		$startTime = get-date
		$snapshotName = $_.Name

		Write-Output "... $snapshotName"
		try {
			Revoke-AzSnapshotAccess `
				-ResourceGroupName  $resourceGroup `
				-SnapshotName       $snapshotName `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop' | Out-Null
		}
		catch {
			# [Microsoft.Azure.Commands.Compute.Common.ComputeCloudException]
			# snapshot not found
			# continue RGCOPY
		}

		try {
			Remove-AzSnapshot `
				-ResourceGroupName  $resourceGroup `
				-SnapshotName      	$snapshotName `
				-Force `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop' | Out-Null
		}
		catch {
			Write-Output "---> $($error[0] -as [string])"
			# continue RGCOPY
		}

		$endTime = get-date
		$_.TotalMinutes = ($endTime - $startTime).TotalMinutes

		Write-Output $snapshotName
	}

	#--------------------------------------------------------------
	# start script in parallel
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	write-logFile "Removing snapshot..."

	$snapshots
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileWarning "Deletion of snapshots failed in resource group '$resourceGroup'"
	}

	$snapshots
	| ForEach-Object {
		$script:stepTotalObjects	+= 1
		$script:stepTotalTime		+= $_.TotalMinutes
	}

	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
function get-subnetIdControlPlane {
#--------------------------------------------------------------
	if ($subnetIdControlPlane.Length -ne 0) {
		return
	}

	if ($null -eq $controlPlaneSub) {
		# was not able to figure out the subscription of the control plane VM
		write-logFileError "Parameter 'subnetIdControlPlane' required"
	}

	set-context $controlPlaneSub # *** CHANGE SUBSCRIPTION **************

	$vm = Get-azVM `
			-ResourceId $cpMetaData.compute.resourceId `
			-ErrorAction 'SilentlyContinue'
	if (!$?) {
		set-context -restore # *** CHANGE SUBSCRIPTION **************
		write-logFileError "Parameter 'subnetIdControlPlane' required"
	}

	$nic = Get-AzNetworkInterface `
			-ResourceId $vm.NetworkProfile.NetworkInterfaces[0].Id `
			-ErrorAction 'SilentlyContinue'
	if (!$?) {
		set-context -restore # *** CHANGE SUBSCRIPTION **************
		write-logFileError "Parameter 'subnetIdControlPlane' required"
	}

	set-context -restore # *** CHANGE SUBSCRIPTION **************
	$script:subnetIdControlPlane = $nic.IpConfigurations[0].Subnet.Id
}

#--------------------------------------------------------------
function add-subnetRule {
#--------------------------------------------------------------
	param (
		$saNm,
		$saRG,
		$saSub,
		$subnetId
	)

	set-context $saSub # *** CHANGE SUBSCRIPTION **************

	$r = get-resourceComponents $subnetId
	$vnet	= $r.mainResourceName
	$subnet = $r.subResourceName
	$rgName	= $r.resourceGroup

	write-logFileTab 'Storage Account' "$saNm ($saRG)"

	# get subnets
	$ruleSet = Get-AzStorageAccountNetworkRuleSet `
			-ResourceGroupName $saRG `
			-Name $saNm `
			-ErrorAction 'SilentlyContinue'
	test-cmdlet 'Get-AzStorageAccountNetworkRuleSet'  "Could not read storage account '$saNm'"

	if ($subnetId -in $ruleSet.VirtualNetworkRules.VirtualNetworkResourceId) {
		write-logFileTab 'Subnet access' "$rgName/$vnet/$subnet" 'already granted'
	}
	else {
		write-logFileTab 'Subnet access' "$rgName/$vnet/$subnet" 'granting...'

		# add subnet
		Add-AzStorageAccountNetworkRule `
			-ResourceGroupName $saRG `
			-Name $saNm `
			-VirtualNetworkResourceId $subnetId `
			-ErrorAction 'SilentlyContinue' | Out-Null
		test-cmdlet 'Add-AzStorageAccountNetworkRule'  "Could not change storage account '$saNm'"
		$script:waitRequired = $true
	}

	set-context -restore # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function remove-subnetRule {
#--------------------------------------------------------------
	param (
		$saNm,
		$saRG,
		$saSub,
		$subnetId
	)

	set-context $saSub # *** CHANGE SUBSCRIPTION **************

	$r = get-resourceComponents $subnetId
	$vnet	= $r.mainResourceName
	$subnet = $r.subResourceName
	$rgName	= $r.resourceGroup

	write-logFileTab 'Storage Account' "$saNm ($saRG)"

	# get subnets
	$ruleSet = Get-AzStorageAccountNetworkRuleSet `
			-ResourceGroupName $saRG `
			-Name $saNm `
			-ErrorAction 'SilentlyContinue'
	test-cmdlet 'Get-AzStorageAccountNetworkRuleSet'  "Could not read storage account '$saNm'"

	if ($subnetId -in $ruleSet.VirtualNetworkRules.VirtualNetworkResourceId) {
		write-logFileTab 'Subnet access' "$rgName/$vnet/$subnet" 'revoking...'
		# remove subnet
		Remove-AzStorageAccountNetworkRule `
			-ResourceGroupName $saRG `
			-Name $saNm `
			-VirtualNetworkRule (@{VirtualNetworkResourceId="$subnetId";Action="allow"}) `
			-ErrorAction 'SilentlyContinue' | Out-Null
		test-cmdlet 'Remove-AzStorageAccountNetworkRule'  "Could not change storage account '$saNm'"
	}

	set-context -restore # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function grant-ipAccess {
#--------------------------------------------------------------
# add IP rule
# this is either an NSP IP rule or an SA IP rule
	param (
		$ipAddress,

		$saNm,
		$saRG,
		$saSub,
		$saSubID
	)

	set-context $saSub # *** CHANGE SUBSCRIPTION **************
	$saNSP = get-saNspConfig $saNm $saSubID $saRG

	#--------------------------------------------------------------
	# use NSP
	if ($saNSP.count -gt 0) {

		# RGCOPY supports only one NSP per SA
		if ($saNSP.count -gt 1) {
			write-logFileError "Storage account $saNm is associated with more than one NSP"
		}

		# get NSP
		$r = get-resourceComponents $saNSP[0].properties.networkSecurityPerimeter.id
		$nspName	= $r.mainResourceName
		$nspRG		= $r.resourceGroup
		$nspSubID	= $r.subscriptionID
		$nspProfileName = $saNSP[0].properties.profile.name

		# get subscription of NSP
		if ($nspSubID -eq $targetSubID) {
			$nspSub = $targetSub
		}
		elseif ($nspSubID -eq $sourceSubID) {
			$nspSub = $sourceSub
		}
		else {
			write-logFileError "Subscription ID $nspSubID for NSP is invalid"
		}
		
		# restore context now to save original context
		set-context -restore # *** CHANGE SUBSCRIPTION **************
		set-context $nspSub # *** CHANGE SUBSCRIPTION **************

		# get NSP rules
		$rules = get-nspRules $nspSubID $nspRG $nspName $nspProfileName
		$inboundRules = $rules | Where-Object {$_.properties.direction -eq 'Inbound'}	
		$addressPrefixes = $inboundRules.properties.addressPrefixes

		# add NSP rule
		if ("$ipAddress/32" -notin $addressPrefixes) {
			write-logFileTab 'NSP IP rule' "$nspName/$ipAddress" 'granting...'
			add-nspRule $ipAddress $nspSubID $nspRG $nspName $nspProfileName

			$script:waitRequired = $true
		}
		else {
			write-logFileTab 'NSP IP rule' "$nspName/$ipAddress" 'already granted'
		}
	}

	#--------------------------------------------------------------
	# use SA
	else {
		add-ipRule $saNm $saRG $saSub $ipAddress
	}

	set-context -restore # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function revoke-ipAccess {
#--------------------------------------------------------------
# remove IP rule
# this is either an NSP IP rule or an SA IP rule
	param (
		$ipAddress,

		$saNm,
		$saRG,
		$saSub,
		$saSubID
	)

	set-context $saSub # *** CHANGE SUBSCRIPTION **************
	$saNSP = get-saNspConfig $saNm $saSubID $saRG

	#--------------------------------------------------------------
	# use NSP
	if ($saNSP.count -gt 0) {

		# RGCOPY supports only one NSP per SA
		if ($saNSP.count -gt 1) {
			write-logFileError "Storage account $saNm is associated with more than one NSP"
		}

		# get NSP
		$r = get-resourceComponents $saNSP[0].properties.networkSecurityPerimeter.id
		$nspName	= $r.mainResourceName
		$nspRG		= $r.resourceGroup
		$nspSubID	= $r.subscriptionID
		$nspProfileName = $saNSP[0].properties.profile.name

		# get subscription of NSP
		if ($nspSubID -eq $targetSubID) {
			$nspSub = $targetSub
		}
		elseif ($nspSubID -eq $sourceSubID) {
			$nspSub = $sourceSub
		}
		else {
			write-logFileError "Subscription ID $nspSubID for NSP is invalid"
		}
		
		# restore context now to save original context
		set-context -restore # *** CHANGE SUBSCRIPTION **************
		set-context $nspSub # *** CHANGE SUBSCRIPTION **************

		# get NSP rules
		$rules = get-nspRules $nspSubID $nspRG $nspName $nspProfileName
		$inboundRules = $rules | Where-Object {$_.properties.direction -eq 'Inbound'}	

		# only remove if IP address is the only one
		$foundRule = $inboundRules 
			| Where-Object {$_.properties.addressPrefixes.count -eq 1}
			| Where-Object {$_.properties.addressPrefixes[0] -eq "$ipAddress/32"}

		if ($null -ne $foundRule) {
			# remove NSP rule
			remove-nspRule $foundRule.name $nspSubID $nspRG $nspName $nspProfileName
		}
	}

	#--------------------------------------------------------------
	# use SA
	else {
		remove-ipRule $saNm $saRG $saSub $ipAddress
	}

	set-context -restore # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function grant-copySnapshots2Blobs {
#--------------------------------------------------------------
	write-stepStart "GRANT ACCESS TO SNAPSHOTS" $maxDOP -startMeasurement

	set-copyDisksAzureToken
	new-blobCopyToken
	set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
	write-logFile

	#--------------------------------------------------------------
	# create script and parameters
	$scriptParameter = @"
		`$sourceRG				= '$sourceRG'
		`$sourceSubID			= '$sourceSubID'
		`$grantTokenTimeSec		= '$grantTokenTimeSec'
"@
	$script = {
		$startTime 		= get-date
		$SnapshotName	= $_.SnapshotName
		$token			= $_.TokenRestAPI

		$count = 0
		$repeatCount = 5
		# run up-to 5 times
		do {
			$count += 1
			$dots = '...' * $count
			#--------------------------------------------------------------
			# use REST API
			if ($Null -ne $token) {
					Write-Output "$dots $SnapshotName (using REST API)"

				# Post Method
				try {
					$body = @{
						access = 'Read'
						durationInSeconds = $grantTokenTimeSec
					}

					if ($_.SecurityType -like 'ConfidentialVM*') {
						$body.getSecureVMGuestStateSAS = $true
					}

					if ($_.LogicalSectorSize -eq 4096) {
						$body.fileFormat = 'VHDX'
					}

					$apiVersion='2023-10-02'
					$restUri = "https://management.azure.com/subscriptions/$sourceSubID/resourceGroups/$sourceRG/providers/Microsoft.Compute/snapshots/$SnapshotName/beginGetAccess?api-version=$apiVersion"

					$invokeParam = @{
						Uri				= "$restUri"
						Method			= 'Post'
						ContentType		= 'application/json'
						Headers			= @{ Authorization = "Bearer $token" }
						Body			= ($body | ConvertTo-Json)
						WarningAction 	= 'SilentlyContinue'
						ErrorAction		= 'Stop'
					}

					$response = Invoke-WebRequest @invokeParam
				}
				catch {
					Write-Output "---> $($error[0] -as [string])"
					if ($count -ge $repeatCount) {
						throw "$SnapshotName   FAILED (Post)"
					}
				}

				$restUri = ($response).Headers.Location

				# Get Method
				try {
					$invokeParam = @{
						Uri				= "$restUri" # conversion of data type needed
						Method			= 'Get'
						ContentType		= 'application/json'
						Headers			= @{ Authorization = "Bearer $token" }
						WarningAction 	= 'SilentlyContinue'
						ErrorAction		= 'Stop'
					}

					$response = Invoke-WebRequest @invokeParam
					$json = $response.Content | ConvertFrom-Json
					$_.AccessSAS 					= $json.accessSAS
					$_.SecurityDataAccessSAS		= $json.securityDataAccessSAS
					$_.SecurityMetadataAccessSAS	= $json.securityMetadataAccessSAS
				}
				catch {
					Write-Output "---> $($error[0] -as [string])"
					if ($count -ge $repeatCount) {
						throw "$SnapshotName   FAILED (Get)"
					}
				}
			}

			#--------------------------------------------------------------
			# use Az cmdlet
			else {
				Write-Output "$dots $SnapshotName"
		
				try {
					$param = @{
						ResourceGroupName	= $sourceRG
						SnapshotName		= $SnapshotName
						Access				= 'Read'
						DurationInSecond	= $grantTokenTimeSec
						WarningAction		= 'SilentlyContinue'
						ErrorAction			= 'Stop'
					}

					if ($_.SecurityType -like 'ConfidentialVM*') {
						$param.SecureVMGuestStateSAS = $true
					}

					$sas = Grant-AzSnapshotAccess @param
					$_.AccessSAS 					= $sas.AccessSAS
					$_.SecurityDataAccessSAS		= $sas.SecurityDataAccessSAS
					$_.SecurityMetadataAccessSAS	= $sas.SecurityMetadataAccessSAS			
				}
				catch {
					Write-Output "---> $($error[0] -as [string])"
					if ($count -ge 3) {		
						throw "$SnapshotName   FAILED"
					}
				}	
			}

			#--------------------------------------------------------------
			$sasList = ''
			if ($null -ne $_.AccessSAS) {
				$sasList += 'vhd'
			}
			if ($null -ne $_.SecurityDataAccessSAS) {
				$sasList += ',state'
			}
			if ($null -ne $_.SecurityDataAccessSAS) {
				$sasList += ',meta'
			}
			
			Write-Output "$SnapshotName ($sasList)"

			# check if done
			$done = $true
			if ($_.AccessSAS.Length -eq 0) {
				$done = $false
				Start-Sleep 1
			}
			elseif ($_.SecurityType -like 'ConfidentialVM*') {
				if (($_.SecurityDataAccessSAS.Length -eq 0) `
				-or ($_.SecurityMetadataAccessSAS.Length -eq 0)) {
					$done = $false
					Start-Sleep 1
				}
			}	
		} 
		until ( $done )

		#--------------------------------------------------------------
		# get statistics (including repeat)
		$endTime = get-date
		$_.TotalMinutes = ($endTime - $startTime).TotalMinutes
	}

	#--------------------------------------------------------------
	# start script in parallel
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	write-logFile "Creating temporary token for snapshot..."

	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| Where-Object BlobCopy -eq $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host

	if (!$?) {
		write-logFileError "Grant Access to snapshot failed"
	}

	#--------------------------------------------------------------
	# calculate total statistics
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| Where-Object BlobCopy -eq $True
	| ForEach-Object {

		$script:stepTotalObjects	+= 1
		$script:stepTotalTime		+= $_.TotalMinutes
	}	
	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
function revoke-copySnapshots2Blobs {
#--------------------------------------------------------------
	write-stepStart "REVOKE ACCESS FROM SNAPSHOTS" $maxDOP -startMeasurement

	#--------------------------------------------------------------
	# create script and parameters
	$scriptParameter =  "`$sourceRG = '$sourceRG';"

	$script = {
		$startTime = get-date
		$SnapshotName = $_.SnapshotName
		Write-Output "... $SnapshotName"

		Revoke-AzSnapshotAccess `
			-ResourceGroupName  $sourceRG `
			-SnapshotName       $SnapshotName `
			-WarningAction 'SilentlyContinue' `
			-ErrorAction 'SilentlyContinue' | Out-Null
		if (!$?) {
			Write-Output "---> $($error[0] -as [string])"
			throw "Revoke access from '$SnapshotName' failed"
		}

		# display single statistics
		$endTime = get-date
		$_.TotalMinutes = ($endTime - $startTime).TotalMinutes
		Write-Output "$SnapshotName ($("{0:F2}" -f $_.TotalMinutes) minutes)"
	}

	#--------------------------------------------------------------
	# start script in parallel
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	Write-logFile "Revoking access from snapshot..."

	try {
		$script:copyDisks.Values
		| Where-Object Skip -ne $True
		| Where-Object BlobCopy -eq $True
		| ForEach-Object @param
		| Tee-Object -FilePath $logPath -append
		| Out-Host
		if (!$?) {
			write-logFileWarning "Revoke access from snapshots failed"
		}
	}
	catch {
		write-logFileWarning "Revoke access from snapshots failed"
	}

	#--------------------------------------------------------------
	# calculate total statistics
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| Where-Object BlobCopy -eq $True
	| ForEach-Object {

		$script:stepTotalObjects	+= 1
		$script:stepTotalTime		+= $_.TotalMinutes
	}
	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
# Define ANSI color escape codes
$ansiRed	= [char]27 + "[31m"
$ansiGreen	= [char]27 + "[32m"
$ansiYellow = [char]27 + "[33m"
$ansiReset	= [char]27 + "[0m"
#--------------------------------------------------------------
function start-azCopyJobsBlobs {
#--------------------------------------------------------------
	write-stepStart "START AZCOPY JOBS FOR BLOBS" $maxDOP -startMeasurement

	$script:AzCopyJobs = @()
	write-logfile "Starting AzCopy for blobs..."
	get-controlPlaneStats
	$script:controlPlaneStatsStart = $script:controlPlaneStats.clone()

	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| Where-Object BlobCopy -eq $True
	| Sort-Object Name
	| ForEach-Object {

		$token		= $_.DelegationToken
		$diskname	= $_.Name
		$sizeGB 	= $_.sizeGB

		foreach ($step in @(
			@{ext = 'vhd';   sas = $_.AccessSAS}
			@{ext = 'state'; sas = $_.SecurityDataAccessSAS}
			@{ext = 'meta';  sas = $_.SecurityMetadataAccessSAS}
		)) {

			$ext 		= $step.ext
			$sas 		= $step.sas
			$blobName	= "$diskname.$ext"

			if ($ext -ne 'vhd') {
				$sizeGB = $null
			}

			if ($null -ne $sas) {
				$sourceUri	= $sas
				$targetUri 	= "https://$targetSA.blob.core.windows.net/$targetSaContainer/$blobName`?$token"

				$cmd = ''
				# place log file on local disk of Azure VM
				if ($IsLinux -and $isAzure) {
					$cmd = @"
mkdir -p $azCopyLogLocation
`$Env:AZCOPY_LOG_LOCATION = '$azCopyLogLocation'
`$Env:AZCOPY_LOG_LOCATION | Out-Null
`n
"@
				}

				$cmd += @"
$azcopyPath copy '$sourceUri' '$targetUri' --blob-type PageBlob --log-level=ERROR
if (!`$?) { throw 'AzCopy failed' }
`n
"@
				
				if ($script:AzCopyJobs.Count -eq $maxDOP) {
					write-logfile
					write-logfile "Queueing AzCopy for blob..." -ForegroundColor 'DarkGray'
				}

				# start job immediately
				if ($script:AzCopyJobs.Count -lt $maxDOP) {
					
					$script = [scriptblock]::create($cmd) 
					$jobObj = Start-Job -ScriptBlock $script -ErrorAction 'SilentlyContinue'
					test-cmdlet 'Start-Job'  "Could not start azCopy job for blob $blobname"
					write-logFile "... $blobName"

					$script:AzCopyJobs += @{
						source			= 'disk'		# disk, container, nfs-share, smb-share
						type			= 'blob'		# blob, share
						name			= $blobName

						jobObj			= $jobObj
						jobId			= $jobObj.Id
						state			= $jobObj.State
						displayState	= "$ansiYellow$($jobObj.State)$ansiReset"

						cmd				= $cmd
						sizeGB			= $sizeGB
						startTime		= $jobObj.PSBeginTime 
						endTime			= $null
						minutes			= $null
						percent			= $null
						azCopyId		= $null
						repeatCount 	= 0
					}
				}

				# add job to queue
				else {
					write-logFile "... $blobName" -ForegroundColor 'DarkGray'
					add-azCopyJob 'disk' 'blob' $blobName $cmd $sizeGB
				}
			}
		}
	}

	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
function add-azCopyJob {
#--------------------------------------------------------------
	param (
		$source,
		$type,
		$name,
		$cmd,
		$sizeGB,
		$repeatCount = 0
	)

		$script:AzCopyJobs += @{
			source			= $source		# disk, container, nfs-share, smb-share
			type			= $type			# blob, share
			name			= $name

			jobObj			= $null
			jobId			= $null
			state			= 'MaxDopReached'
			displayState	= 'MaxDopReached'

			cmd				= $cmd
			sizeGB			= $sizeGB
			startTime		= $null
			endTime			= $null
			minutes			= $null
			percent			= $null
			azCopyId		= $null
			repeatCount 	= $repeatCount
		}
}

#--------------------------------------------------------------
function start-azCopyJobWaiting {
#--------------------------------------------------------------
	foreach ($j in $script:AzCopyJobs) {
		if ($j.state -eq 'MaxDopReached') {

			$script = [scriptblock]::create($j.cmd) 
			$jobObj = Start-Job -ScriptBlock $script -ErrorAction 'SilentlyContinue'
			test-cmdlet 'Start-Job'  "Could not start azCopy job for $($j.type) '$($j.name)'"
			
			$j.jobObj			= $jobObj
			$j.jobId			= $jobObj.Id
			$j.state			= $jobObj.State
			$j.displayState		= "$ansiYellow$($jobObj.State)$ansiReset"

			$j.startTime		= $jobObj.PSBeginTime
			break
		}
	}
}

#--------------------------------------------------------------
function show-azCopyJobs {
#--------------------------------------------------------------
	$script:AzCopyJobs
	| Select-Object *
	| Format-Table `
		@{ Name = 'job'; Expression = { $_.jobId } }, `
		@{ Name = 'state'; Expression = { $_.displayState } }, `
		@{ Name = 'done[%]'; Expression = { $_.percent }; Alignment = 'Right' }, `
		@{ Name = 'size[GiB]'; Expression = { $_.sizeGB } }, `
		@{ Name = '[minutes]'; Expression = { "{0:F2}" -f $_.minutes }; Alignment = 'Right' }, `
		@{ Name = '[TiB/h]'; Expression = {
			if (($_.minutes -gt 0) -and ($_.sizeGB -gt 0)) {
				"{0:F2}" -f ( ($_.sizeGB / 1024.0) / ($_.minutes / 60.0) )
			}
			else { $null }
		}; Alignment = 'Right' }, `
		source, `
		name
	| write-logFilePipe
	# do not use Out-String because this remove the color in colomn state

	show-controlPlaneStats
}

#--------------------------------------------------------------
function get-controlPlaneStats {
#--------------------------------------------------------------
	if (!$IsLinux -and !$IsWindows) {
		return $null
	}

	$script:controlPlaneStats = @{
		Date = $null
	}

	try {
		if ($IsLinux) {
			$line = Get-Content '/proc/stat' -Head 1 -ErrorAction 'Stop'
			$parts = $line -split '\s+'

			[double] $user 		= $parts[1]
			$user += $parts[2]	# includes nice
			[double] $system 	= $parts[3]
			[double] $idle 		= $parts[4]
			[double] $total = 0
			for ($i = 1; $i -lt $parts.Length; $i++) {
				$total += $parts[$i]
			}
		
			$script:controlPlaneStats = @{
				Date	= Get-Date
				RxBytes	= (Get-Content '/sys/class/net/ens1/statistics/rx_bytes' -ErrorAction 'Stop') -as [double]
				TxBytes	= (Get-Content '/sys/class/net/ens1/statistics/tx_bytes' -ErrorAction 'Stop') -as [double]
				User	= $user
				System	= $system
				Idle	= $idle
				Total	= $total
			}
		}

		if ($IsWindows) {
			$raw = Get-CimInstance -ClassName 'Win32_PerfRawData_PerfOS_Processor' -Filter "Name='_Total'" -ErrorAction 'Stop'

			$NetStats = Get-NetAdapterStatistics -ErrorAction 'Stop'

			$script:controlPlaneStats = @{
				Date		= Get-Date
				RxBytes		= ($NetStats.ReceivedBytes | Measure-Object -Sum).Sum -as [double]
				TxBytes		= ($NetStats.SentBytes     | Measure-Object -Sum).Sum -as [double]
				User		= $raw.PercentUserTime			-as [double]
				System		= $raw.PercentPrivilegedTime	-as [double]
				Idle		= $raw.PercentIdleTime			-as [double]
				Total		= $raw.Timestamp_Sys100NS		-as [double]
			}
		}
	}
	catch {
		$script:controlPlaneStats = @{
			Date = $null
		}
	}
}

#--------------------------------------------------------------
function show-controlPlaneStats {
#--------------------------------------------------------------
	param (
		$start
	)

	if (!$IsLinux -and !$IsWindows) {
		return
	}

	if ($null -eq $start) {
		# no start statistics are supplied: use current one
		$start = $script:controlPlaneStats.clone()
	}
	# create new statistics and use them as end-stats
	get-controlPlaneStats
	$end = $script:controlPlaneStats.clone()
	if (($null -eq $start.Date) -or ($null -eq $end.Date)) {
		return
	}

	[string] $startTime = $start.Date.toString('HH:mm:ss')
	[string] $endTime 	= $end.Date.toString('HH:mm:ss')
	[double] $seconds 	= ($end.Date - $start.Date).TotalSeconds
	if ($seconds -le 0) {
		return
	}

	[double] $diff_total 	= $end.Total 	- $start.Total
	[double] $diff_user		= $end.User 	- $start.User
	[double] $diff_system 	= $end.System 	- $start.System
	[double] $diff_idle   	= $end.Idle 	- $start.Idle
	[double] $diff_rxBytes  = $end.RxBytes 	- $start.RxBytes
	[double] $diff_txBytes  = $end.TxBytes 	- $start.TxBytes
	[double] $total_MB		= ($diff_rxBytes + $diff_txBytes) / 1MB

	if ($diff_total -le 0) {
		return
	}

	@{
		startTime  	= $startTime
		endTime		= $endTime
		pct_user   	= (($diff_user   / $diff_total) * 100)
		pct_system 	= (($diff_system / $diff_total) * 100)
		pct_idle   	= (($diff_idle   / $diff_total) * 100)
		rx_KBperSec = $diff_rxBytes / 1KB / $seconds
		tx_KBperSec = $diff_txBytes / 1KB / $seconds
		total_MB	= $total_MB
	} `
	| Select-Object * `
	| Format-Table `
		@{ Name = $startTime	; Expression = { $_.endTime		            }; Width = 10 ; Alignment = 'Right'}, `
		@{ Name = '%user'		; Expression = { "{0:F2}" -f $_.pct_user	}; Width = 10 ; Alignment = 'Right'}, `
		@{ Name = '%system'		; Expression = { "{0:F2}" -f $_.pct_system	}; Width = 10 ; Alignment = 'Right'}, `
		@{ Name = '%idle'		; Expression = { "{0:F2}" -f $_.pct_idle	}; Width = 10 ; Alignment = 'Right'}, `
		@{ Name = 'rx KiB/sec'	; Expression = { "{0:F2}" -f $_.rx_KBperSec	}; Width = 10 ; Alignment = 'Right'}, `
		@{ Name = 'tx KiB/sec'	; Expression = { "{0:F2}" -f $_.tx_KBperSec	}; Width = 10 ; Alignment = 'Right'}, `
		@{ Name = 'total MiB'	; Expression = { "{0:F2}" -f $_.total_MB	}; Width = 10 ; Alignment = 'Right'} `
	| Out-String -Width $screenWidthSmall `
	| write-logFilePipe
}

#--------------------------------------------------------------
function wait-azCopyJobs {
#--------------------------------------------------------------
	write-stepStart "WAITING FOR AZCOPY JOBS" -startMeasurement
	write-logFile "$([Environment]::ProcessorCount) logical CPUs on control plane"

	$runningJobs = $script:AzCopyJobs 
					| Where-Object state -notin @('Completed', 'Failed', 'Stopped', 'MaxDopReached')

	show-azCopyJobs
	$firstRun = $true
	write-logFile "waiting 10 seconds..."
	Start-Sleep 10

	while ($runningJobs.count -gt 0) {

		if (!$firstRun) {
			$timeout = 300
			write-logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') waiting up-to 5 minutes for running AzCopy jobs" -ForegroundColor 'DarkGray'	
			Wait-Job -Id $runningJobs.jobObj.Id -Any -TimeOut $timeout | Out-Null
		}
		$firstRun = $false

		# get current state
		foreach ($j in $runningJobs) {
			# get azCopyId
			if ($null -eq $j.azCopyId) {
				$j.azCopyId = get-azCopyId $j.jobId
			}

			# get percent
			$j.percent = get-azCopyPercent $j.jobId

			# Possible states of Powershell jobs
				# 'NotStarted'
				# 'Running'
				# 'Blocked'
				# 'Suspended'
				# 'Disconnected'
				# 'Failed'
				# 'Stopped'
				# 'Completed'

			# get job state
			$j.state = $j.jobObj.State

			# verify AzCopy stateg
			if ($j.state -eq 'Completed') {
				$finalStatus = get-azCopyFinalStatus $j.jobId
				if ($finalStatus -ne 'Completed') {
					$j.state = 'Failed'
					$j.sizeGB = $null
					write-logFileWarning "AzCopy job finished, but console output does not end with 'Final Job Status: Completed'"
				}
			}

			# finished
			if ($j.state -in @('Completed', 'Failed', 'Stopped')) {

				$j.endTime = $j.jobObj.PSEndTime
				$j.minutes = ($j.endTime - $j.startTime).TotalMinutes

				# display log from console
				if ($showAzCopyLogs -or ($j.state -in @('Failed', 'Stopped'))) {
					$log = receive-job $j.jobId -keep -ErrorAction 'SilentlyContinue'
					write-logFile 
					write-logFile ('-' * $starCount) -ForegroundColor 'DarkGray'
					write-logFile "Job ID $($j.jobId) $($j.source) '$($j.name)' $($j.state)"
					write-logFile ('-' * $starCount) -ForegroundColor 'DarkGray'
					foreach ($line in $log) {
						write-logFile $line -ForegroundColor 'Cyan'
					}
					write-logFile
				}

				# process failed job
				if ($j.state -in @('Failed', 'Stopped')) {

					# repeat
					if ($j.repeatCount -lt $azCopyRepeatCount) {
						write-logFileWarning "Repeating AzCopy for $($j.source) '$($j.name)'"
						Start-Sleep 5
						add-azCopyJob $j.source $j.type $j.name $j.cmd $j.sizeGB ($j.repeatCount + 1)
					}

					# stop RGCOPY if it fails a second time
					else {
						$j.displayState = "$ansiRed$($j.state)$ansiReset"
						show-azCopyJobs
						write-logFileError "Copying $($j.source) '$($j.name)' failed $($azCopyRepeatCount + 1) times"
					}
				}

				# try to start another job (as replacement for finished/failed job)
				start-azCopyJobWaiting
			}

			# set color
			if ($hostPlainText) {
				$j.displayState = $j.state
			}
			else {
				if ($j.state -eq 'Completed') {
					$j.displayState = "$ansiGreen$($j.state)$ansiReset"
				}
				elseif ($j.state -in @('Failed', 'Stopped')) {
					$j.displayState = "$ansiRed$($j.state)$ansiReset"
				}
				else {
					$j.displayState = "$ansiYellow$($j.state)$ansiReset"
				}
			}
		}

		show-azCopyJobs
		
		$runningJobs = $script:AzCopyJobs 
						| Where-Object state -notin @('Completed', 'Failed', 'Stopped', 'MaxDopReached')
	}

	# get statistics
	foreach ($j in $script:AzCopyJobs) {
		$script:stepTotalObjects += 1
		$script:stepTotalSizeGB += $j.sizeGB
		$script:stepTotalTime += $j.minutes
	}

	write-logFile "Overall statistics while AzCopy was running"
	show-controlPlaneStats $script:controlPlaneStatsStart

	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
function get-azCopyFinalStatus {
#--------------------------------------------------------------
	param (
		$jobId
	)

	$log = receive-job $jobId -keep -ErrorAction 'SilentlyContinue'
	
	$finalStatus = $null
	for ($i = $log.Count - 1; $i -ge 0; $i--) {
		$split = $log[$i] -split ' Job Status: '
		if ($split[0] -eq 'Final') {
			$finalStatus = $split[1]
			break
		}
	}
	return $finalStatus
}

#--------------------------------------------------------------
function get-azCopyPercent {
#--------------------------------------------------------------
	param (
		$jobId
	)

	$log = receive-job $jobId -keep -ErrorAction 'SilentlyContinue'
	
	$percent = $null
	for ($i = $log.Count - 1; $i -ge 0; $i--) {
		$split = $log[$i] -split ' '
		if ($split[1] -like '%*') {
			$percent = $split[0]
			break
		}
	}
	return $percent
}

#--------------------------------------------------------------
function get-azCopyId {
#--------------------------------------------------------------
	param (
		$jobId
	)

	$log = receive-job $jobId -keep -ErrorAction 'SilentlyContinue'

	$azCopyId = $null
	foreach ($line in $log) {
		if ($line -like 'Job *') {
			$split = $line -split ' '
			$azCopyId = $split[1]
			break
		}
	}
	return $azCopyId
}

#--------------------------------------------------------------
function get-azcopyToken {
#--------------------------------------------------------------
	param (
		$saName,
		$shareName,
		$shareType,
		$rgName,
		$saKeysAllowed,
		$rbacRoles,
		$ignoreDelKey,
		$ignoreSaKey
	)

	$token = $null
	$kind = $null

	# 1st try: token using storage account key
	# token valid as long as SA Key is valid
	if (!$ignoreSaKey -and ($null -eq $token)) {
		
			if ($saKeysAllowed) {
				$token = get-sasTokenBySaKey $saName $rgName
				if ($null -ne $token) {
					write-logFile "Created token using storage account key"
					$kind = '<saKeyToken>'
				}
				else {
					write-logFile "Creating token using storage account key failed" -ForegroundColor 'DarkGray'
				}
			}
	}

	# 2nd try: user delegation token
	# token valid for 6 days (defined in RGCOPY function get-sasDelegationToken)
	# only works for BLOB storage, not for FILE storage
	if (!$ignoreDelKey -and ($null -eq $token)) {

		if (('Storage Blob Data Contributor' -in $rbacRoles) `
		-or ('Storage Blob Data Owner' -in $rbacRoles)) {

			$token = get-sasDelegationToken $saName $shareName $shareType
			if ($null -ne $token) {
				write-logFile "Created user delegation token"
				$kind = '<delegationToken>'
			}
			else {
				write-logFile "Creating user delegation token failed" -ForegroundColor 'DarkGray'
			}
		}
		else {
			write-logFile "Creating user delegation token not possible. RBAC role missing."  -ForegroundColor 'DarkGray'
		}
	}

	# 3rd try: oAuth (no token)
	if ($null -eq $token) {
		write-logFile "Using oAuth authentication"
		$kind = $null
	}

	return $token, $kind
}

#--------------------------------------------------------------
function start-azCopyJobsShares {
#--------------------------------------------------------------
	param (
		$saNameSource,
		$saNameTarget,
		$type, 			# blob, file (different from type in $script:AzCopyJobs)
		$source, 		# container, nfs-share, smb-share
		$shareName,
		$sizeGB,
		$shareSnapshot
	)

	set-context $sourceSub -always # *** CHANGE SUBSCRIPTION **************
	$sourceRoles = get-rbacRoles $sourceSubID $sourceSubUser $saNameSource $sourceRG

	$sourceSaKeysAllowed 	= $script:copySA[$saNameSource].allowSharedKeyAccess
	$sourceNwAccess 		= $script:copySA[$saNameSource].publicNetworkAccess
	$sourceDefaultAction 	= $script:copySA[$saNameSource].defaultAction
	if (($sourceNwAccess -eq 'Enabled') -and ($sourceDefaultAction -eq 'Deny')) {
		$sourceNwAccess += ' for selected networks'
	}

	write-logFile 'Source:' -ForegroundColor 'green'
	write-logFileTab 'Storage account' $saNameSource
	write-logFileTab 'Public NW access' $sourceNwAccess
	write-logFileTab 'SA keys allowed' $sourceSaKeysAllowed
	write-logFileTab 'User' $sourceSubUser

	set-context $targetSub -always # *** CHANGE SUBSCRIPTION **************
	$targetRoles = get-rbacRoles $targetSubID $targetSubUser $saNameTarget $targetRG

	$targetSaKeysAllowed 	= $script:copySA[$saNameTarget].allowSharedKeyAccess
	$targetNwAccess 		= $script:copySA[$saNameTarget].publicNetworkAccess
	$targetDefaultAction 	= $script:copySA[$saNameTarget].defaultAction
	if (($targetNwAccess -eq 'Enabled') -and ($targetDefaultAction -eq 'Deny')) {
		$targetNwAccess += ' for selected networks'
	}

	write-logFile 'Target:' -ForegroundColor 'green'
	write-logFileTab 'Storage account' $saNameTarget
	write-logFileTab 'Public NW access' $targetNwAccess
	write-logFileTab 'SA keys allowed' $targetSaKeysAllowed
	write-logFileTab 'User' $targetSubUser

	# user delegation key currently only possible for BLOB
	if ($type -eq 'file') {
		if ('ignoreDelKeySource' -notin $boundParameterNames) {
			$script:ignoreDelKeySource = $true
		}
		if ('ignoreDelKeyTarget' -notin $boundParameterNames) {
			$script:ignoreDelKeyTarget = $true
		}
	}
	
	# get tokens
	write-logFile "creating token for source storage account $saNameSource..."
	set-context $sourceSub -always # *** CHANGE SUBSCRIPTION **************
	$sasTokenSource, $kindTokenSource = get-azcopyToken $saNameSource $shareName $type $sourceRG `
														$sourceSaKeysAllowed $sourceRoles `
														$ignoreDelKeySource $ignoreSaKeySource
	
	write-logFile "creating token for target storage account $saNameTarget..."
	set-context $targetSub -always # *** CHANGE SUBSCRIPTION **************
	$sasTokenTarget, $kindTokenTarget = get-azcopyToken $saNameTarget $shareName $type $targetRG `
														$targetSaKeysAllowed $targetRoles `
														$ignoreDelKeyTarget $ignoreSaKeyTarget
	#--------------------------------------------------------------
	# calculate snapshot name
	if ($copySaUsingSnapshots -and ($type -eq 'file')) {
		# different time format for REST:
		# remove 'Z' at the end and add '.0000000Z'
		# <Reason>Must be in the specific snapshot date time format.</Reason>
		$shareSnapshot = "$(-join $shareSnapshot[0..($shareSnapshot.length - 2)]).0000000Z"
	}
	else {
		$shareSnapshot = $null
	}

	#--------------------------------------------------------------
	# default URL
	$sourceURL = "https://$saNameSource.$type.core.windows.net"
	$targetURL = "https://$saNameTarget.$type.core.windows.net"

	# add share name
	if ($null -ne $shareName) {
		$sourceURL = "$sourceURL/$shareName"
		$targetURL = "$targetURL/$shareName"
	}

	# add snapshot
	if ($null -ne $shareSnapshot) {
		$sourceURL = "$sourceURL`?snapshot=$shareSnapshot"
	}

	# add token to URL
	if ($null -ne $kindTokenSource) {
		if ($null -eq $shareSnapshot) {
			$sourceURL		= "$sourceURL`?$sasTokenSource"
		}
		else {
			$sourceURL 		= "$sourceURL&$sasTokenSource"
		}
	}
	if ($null -ne $kindTokenTarget) {
		$targetURL		= "$targetURL`?$sasTokenTarget"
	}

	#--------------------------------------------------------------
	# options
	if ($source -eq 'smb-share') {
		if (!$copySaUsingSnapshots) {
			$options = '--from-to=FileSMBFileSMB --preserve-smb-permissions=true --preserve-smb-info=true'
		}
		else {
			# preserve-smb-permissions does not work with snapshots:
			# ERROR message in AZCOPY log: 
			# <Reason>This operation is only allowed on the root blob. Snapshot should not be provided.</Reason>
			$options = '--from-to=FileSMBFileSMB'
		}
	}

	if ($source -eq 'nfs-share') {
		$options = '--from-to=FileNFSFileNFS --preserve-permissions=true --preserve-info=true'
	}

	if ($source -eq 'container') {
		$options = '--from-to=BlobBlob'
	}

	#--------------------------------------------------------------
	# get environment
	# no token for source SA AND no token for target SA
	if ( ($null -eq $kindTokenSource) `
	-and ($null -eq $kindTokenTarget)) {

		# source and target user are NOT the same
		if ($differentTenantOrUser) {
			write-logFileError "OAuth authentication only possible for source AND target when using same user"
			# do not use parameters source-oauth-token or destination-oauth-token
			# Thes parameters are not documented. Furthermore, an oAuth token is only guarantied for 5 minutes
		}

		$AZCOPY_AUTO_LOGIN_TYPE = "'$storageCredentialType'"
		# context does not matter in this case: source context = target context
		# hower, azCliContext must be set (it could be ANY context when not set)
		$AZCOPY_TENANT_ID 		= "'$sourceSubTenant'"
		set-context $sourceSub -always -azCliContext # *** CHANGE SUBSCRIPTION **************
	}

	# no token for source SA
	elseif ($null -eq $kindTokenSource) {
		$AZCOPY_AUTO_LOGIN_TYPE = "'$storageCredentialType'"
		$AZCOPY_TENANT_ID 		= "'$sourceSubTenant'"
		# must set source context
		set-context $sourceSub -always -azCliContext # *** CHANGE SUBSCRIPTION **************
	}
	
	# no token for target SA
	elseif ($null -eq $kindTokenTarget) {
		$AZCOPY_AUTO_LOGIN_TYPE = "'$storageCredentialType'"
		$AZCOPY_TENANT_ID 		= "'$targetSubTenant'"
		# must set target context
		set-context $targetSub -always -azCliContext # *** CHANGE SUBSCRIPTION **************
	}

	# token for source SA and target SA
	else {
		$AZCOPY_AUTO_LOGIN_TYPE = '$null'
		$AZCOPY_TENANT_ID 		= '$null'
		# context does not matter in this case:
		# set source context (to be on the save side)
		set-context $sourceSub -always -azCliContext # *** CHANGE SUBSCRIPTION **************
	}

	# check for managed identity
	$AZCOPY_MSI_CLIENT_ID = '$null'
	if ($isAzure -and !$useAzureCLI) {
		if ($AZCOPY_AUTO_LOGIN_TYPE -ne '$null') {
			$clientID = (get-azContext).Account.Id
			if ($clientID -match "^[{]?[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}[}]?$") {
				$AZCOPY_AUTO_LOGIN_TYPE = "'MSI'"
				$AZCOPY_MSI_CLIENT_ID = "'$clientID'"
			}
		}
	}

	# assemble command
	$cmd = ''

	foreach ($key in $azCopyEnvironment.Keys) {
		$cmd += "`$Env:$key = '$($azCopyEnvironment.$key)'`n"
		$cmd += "`$Env:$key | Out-Null`n"
	}

	if ($IsLinux -and $isAzure) {
		$cmd += @"
mkdir -p $azCopyLogLocation
`$Env:AZCOPY_LOG_LOCATION = '$azCopyLogLocation'
`$Env:AZCOPY_LOG_LOCATION | Out-Null
`n
"@
	}

	$cmd += @"
`$Env:AZCOPY_AUTO_LOGIN_TYPE = $AZCOPY_AUTO_LOGIN_TYPE
`$Env:AZCOPY_TENANT_ID       = $AZCOPY_TENANT_ID
`$Env:AZCOPY_MSI_CLIENT_ID   = $AZCOPY_MSI_CLIENT_ID
# read environment to prevent caching issues
`$Env:AZCOPY_AUTO_LOGIN_TYPE | Out-Null
`$Env:AZCOPY_TENANT_ID       | Out-Null
`$Env:AZCOPY_MSI_CLIENT_ID   | Out-Null
$azcopyPath copy ``
  `"$sourceURL`" ``
  `"$targetURL`" ``
  $options ``
  --log-level=ERROR --recursive 2>&1
"@

	# start job immediately
	if ($script:AzCopyJobs.Count -lt $maxDOP) {
		$script = [scriptblock]::create($cmd) 
		$jobObj = Start-Job -ScriptBlock $script -ErrorAction 'SilentlyContinue'
		test-cmdlet 'Start-Job'  "Could not start azCopy job for $source '$shareName'"
		write-logFile "Started AzCopy job for $source '$shareName'" -ForegroundColor 'Cyan'
		write-logFile
		write-logFile

		$script:AzCopyJobs += @{
			source			= $source		# disk, container, nfs-share, smb-share
			type			= 'share'		# blob, share
			name			= $shareName

			jobObj			= $jobObj
			jobId			= $jobObj.Id
			state			= $jobObj.State
			displayState	= "$ansiYellow$($jobObj.State)$ansiReset"

			cmd				= $cmd
			sizeGB			= $sizeGB
			startTime		= $jobObj.PSBeginTime
			endTime			= $null
			minutes			= $null
			percent			= $null
			azCopyId		= $null
			repeatCount 	= 0
		}
	}

	# add job to queue
	else {
		write-logFile "Queued AzCopy job for $source '$shareName'" -ForegroundColor 'Cyan'
		write-logFile
		write-logFile
		add-azCopyJob $source 'share' $shareName $cmd $sizeGB
	}
}

#--------------------------------------------------------------
function get-containerSize {
#--------------------------------------------------------------
	param (
		$saName,
		$containerName
	)

	$bytes = 0
	# This has only be tested with PowerShell 7.6 and .Net 10
	# TRY-CATCH if it fails
	try {
		$blobEndpoint = "https://$saName.blob.core.windows.net"
		$token = get-sasDelegationToken $saName $containerName 'blob'
	
		$blobServiceClient = [Azure.Storage.Blobs.BlobServiceClient]::new([Uri]$blobEndpoint, $token)
		$blobContainerClient = $blobServiceClient.GetBlobContainerClient($containerName)
	
		[long] $bytes = 0
		foreach ($blobItem in $blobContainerClient.GetBlobs()) {
			$bytes += $blobItem.Properties.ContentLength
		}
	}
	catch {}

	return $bytes
}

#--------------------------------------------------------------
function get-shareSize {
#--------------------------------------------------------------
	param (
		$saName,
		$shareName,
		$rgName
	)

	$share = Get-AzRmStorageShare `
		-ResourceGroupName $rgName `
		-StorageAccountName $saName `
		-Name $shareName `
		-GetShareUsage `
		-ErrorAction 'SilentlyContinue' `
		-WarningAction 'SilentlyContinue'
	if (!$?) {
		write-logFileWarning "Could not get Size of share $shareName"
	}

	return $share.ShareUsageBytes
}

#--------------------------------------------------------------
function start-copySnapshots2Blobs {
#--------------------------------------------------------------
	write-stepStart "START COPY BLOBS" $maxDOP -startMeasurement

	#--------------------------------------------------------------
	# create script and parameters
	$scriptParameter =  "`$targetSaContainer = '$targetSaContainer';"
	$scriptParameter += "`$targetSA = '$targetSA';"
	
	$script = {
		try {
			$startTime = get-date
			$diskname = $_.Name
			
			$destinationContext = New-AzStorageContext `
									-StorageAccountName		$targetSA `
									-SasToken				$_.DelegationToken `
									-ErrorAction			'SilentlyContinue'

			$param = @{
				DestContainer	= $targetSaContainer
				DestContext     = $destinationContext
				DestBlob        = "$diskname.vhd"
				AbsoluteUri     = $_.AccessSAS
				Force			= $True
				WarningAction	= 'SilentlyContinue'
				ErrorAction		= 'Stop' 
			}

			if ($null -ne $_.SecurityDataAccessSAS) {
				# copy state
				$param.DestBlob		= "$diskname.state"
				$param.AbsoluteUri	= $_.SecurityDataAccessSAS

				Write-Output "... $diskname.state"
				Start-AzStorageBlobCopy @param | Out-Null
				Write-Output "$diskname.state"
			}

			if ($null -ne $_.SecurityMetadataAccessSAS) {
				# copy meta data
				$param.DestBlob		= "$diskname.meta"
				$param.AbsoluteUri	= $_.SecurityMetadataAccessSAS
	
				Write-Output "...  $diskname.meta"
				Start-AzStorageBlobCopy @param | Out-Null
				Write-Output "$diskname.meta"
			}

			$param.DestBlob		= "$diskname.vhd"
			$param.AbsoluteUri	= $_.AccessSAS
			Write-Output "... $diskname.vhd"
			Start-AzStorageBlobCopy @param | Out-Null

			# display single statistics
			$endTime = get-date
			$_.TotalMinutes = ($endTime - $startTime).TotalMinutes
			Write-Output "$diskname.vhd ($("{0:F2}" -f $_.TotalMinutes) minutes)"
		}
		catch {
			Write-Output "---> $($error[0] -as [string])"
			# Write-Output $param	
			throw "$diskname.vhd   FAILED"
		}
	}

	#--------------------------------------------------------------
	# start script in parallel
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	write-logFile "Start copy snapshot to BLOB..."

	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| Where-Object BlobCopy -eq $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Creation of Storage Account BLOB failed"
	}

	#--------------------------------------------------------------
	# calculate total statistics
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| Where-Object BlobCopy -eq $True
	| ForEach-Object {

		$script:stepTotalObjects	+= 1
		$script:stepTotalTime		+= $_.TotalMinutes
	}
	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
function stop-copySnapshots2Blobs {
#--------------------------------------------------------------
	write-stepStart "STOP COPY TO BLOB" $maxDOP -startMeasurement

	#--------------------------------------------------------------
	# create script and parameters
	$scriptParameter =  "`$targetSaContainer = '$targetSaContainer';"
	$scriptParameter += "`$targetSA = '$targetSA';"

	$script = {
		$startTime = get-date
		$diskname = $_.Name
		Write-Output "... $diskname.vhd"

		$destinationContext = New-AzStorageContext `
								-StorageAccountName		$targetSA `
								-SasToken				$_.DelegationToken `
								-ErrorAction			'SilentlyContinue'

		$param = @{
			Container		= $targetSaContainer
			Context     	= $destinationContext
			Blob        	= "$diskname.vhd"
			Force			= $True
			WarningAction	= 'SilentlyContinue'
			ErrorAction		= 'SilentlyContinue' 
		}

		# ignore all errors
		Stop-AzStorageBlobCopy @param | Out-Null

		if ($_.SecurityType -like 'ConfidentialVM*') {
			$param.Blob = "$diskname.state"
			Stop-AzStorageBlobCopy @param | Out-Null

			$param.Blob = "$diskname.meta"
			Stop-AzStorageBlobCopy @param | Out-Null
		}

		# display single statistics
		$endTime = get-date
		$_.TotalMinutes = ($endTime - $startTime).TotalMinutes
		Write-Output "$diskname.vhd ($("{0:F2}" -f $_.TotalMinutes) minutes)"
	}

	#--------------------------------------------------------------
	# start script in parallel
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	write-logFile "Stop copy snapshot to BLOB..."

	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| Where-Object BlobCopy -eq $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Stop Copy Disk failed"
	}

	#--------------------------------------------------------------
	# calculate total statistics
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| Where-Object BlobCopy -eq $True
	| ForEach-Object {

		$script:stepTotalObjects	+= 1
		$script:stepTotalTime		+= $_.TotalMinutes
	}
	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
function wait-copySnapshots2Blobs {
#--------------------------------------------------------------
	write-stepStart "BLOB COPY COMPLETION" -skipLF -startMeasurement

	$destinationContext = New-AzStorageContext `
							-StorageAccountName		$targetSA `
							-SasToken				$script:delegationToken `
							-ErrorAction			'SilentlyContinue'

	test-cmdlet 'New-AzStorageContext'  "Could not get context for Storage Account '$targetSA'"

	# create tasks
	$runningBlobTasks = @()
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| Where-Object BlobCopy -eq $True
	| Sort-Object Name
	| ForEach-Object {

		$runningBlobTasks += @{
			blob		= "$($_.Name).vhd"
			finished	= $False
			progress	= ''
			blobObject	= $null
		}

		if ($_.SecurityType -like 'ConfidentialVM*') {
			$runningBlobTasks += @{
				blob		= "$($_.Name).state"
				finished	= $False
				progress	= ''
				blobObject	= $null
			}

			$runningBlobTasks += @{
				blob		= "$($_.Name).meta"
				finished	= $False
				progress	= ''
				blobObject	= $null
			}
		}
	}

	$runningBlobTasks
	| ForEach-Object -ThrottleLimit $maxDOP -Parallel {

		$_.blobObject = Get-AzStorageBlob `
							-Blob       	$_.blob `
							-Container  	$using:targetSaContainer `
							-Context    	$using:destinationContext `
							-WarningAction	'SilentlyContinue' `
							-ErrorAction	'SilentlyContinue'
	}

	$script:waitCount = 0
	do {
		Write-logFile
		$done = $True
		foreach ($task in $runningBlobTasks) {

			if ($task.finished) {
				Write-logFile $task.progress -ForegroundColor 'Green'
			}
			else {

				try {
					$state = $task.blobObject | Get-AzStorageBlobCopyState -InformationAction 'Ignore'
				}
				catch {
					write-logFile " xx% status unknown   $($task.blob)" -ForegroundColor 'DarkYellow'
					$done = $False
					continue
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
					write-logFileError "Copy to BLOB failed ($($state.Status))" `
										$state.StatusDescription
				}
			}
		}

		if (!$done) { 
			get-waitTime
			write-logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') BLOB COPY COMPLETION. Next wait time: $script:waitTime minutes" -ForegroundColor 'DarkGray'
			write-logFile
			Start-Sleep -seconds (60 * $script:waitTime)
		}
	} while (!$done)

	$script:stepTotalObjects = $runningBlobTasks.Count
	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
function new-disks {
#--------------------------------------------------------------
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************
	# manually created disks using Az-cmdlet or REST API

	write-stepStart "CREATE DISKS" $maxDOP -startMeasurement

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
	}

	set-copyDisksAzureToken

	#--------------------------------------------------------------
	# create script and parameters
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
	$script = {
		$startTime 	= get-date
		$diskName	= $_.Name
		$token		= $_.TokenRestAPI

		# only when copying a single disk
		if ($defaultDiskName.length -gt 0) {
			$diskName = $defaultDiskName
		}

		if ($Null -ne $token) {
			#--------------------------------------------------------------
			# use REST API

			try {
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

				#--------------------------------------------------------------
				# supportedCapabilities
				$supportedCapabilities = @{}

				if ($_.DiskControllerType -eq 'NVME') {
					$supportedCapabilities.diskControllerTypes = 'SCSI, NVMe'
				}

				if ($_.SecurityType -like 'ConfidentialVM*') {
					# $apiVersion='2026-03-02'
					# $apiVersion='2023-10-02'
					# "message": "Could not find member \u0027confidentialVMSupported\u0027 on object
					# $supportedCapabilities.confidentialVMSupported = $true

					# $apiVersion='2026-03-02'
					# "message": "\u0027disk.supportedCapabilities.supportedSecurityOption\u0027 is not supported for this subscription/region"
					# $supportedCapabilities.supportedSecurityOption = 'TrustedLaunchAndConfidentialVMSupported'
				}

				if ($supportedCapabilities.count -gt 0) {
					$body.properties.supportedCapabilities = $supportedCapabilities
				}

				#--------------------------------------------------------------
				# create from BOLB
				if ($_.BlobCopy) {
					Write-Output "... $diskName (from BLOB using REST API)"

					if ($_.SecurityType.Length -gt 0) {
						$body.properties.securityProfile = @{
							securityType = $_.SecurityType
						}
					}

					$body.properties.creationData.storageAccountId	= $blobsSaID
					$body.properties.creationData.sourceUri			= "https://$blobsSA.blob.core.windows.net/$blobsSaContainer/$($_.Name).vhd"
					$body.properties.creationData.createOption		= 'Import'

					# confidential VMs
					if ($_.SecurityType -like 'ConfidentialVM*') {
						$body.properties.creationData.createOption			= 'ImportSecure'
						$body.properties.creationData.securityDataUri		= "https://$blobsSA.blob.core.windows.net/$blobsSaContainer/$($_.Name).state"
						$body.properties.creationData.securityMetadataUri	= "https://$blobsSA.blob.core.windows.net/$blobsSaContainer/$($_.Name).meta"
						$body.properties.encryption = @{
							type = 'EncryptionAtRestWithPlatformKey'
						}
					}
				}

				#--------------------------------------------------------------
				# create from snapshot
				else {
					Write-Output "... $diskName (from SNAPSHOT using REST API)"

					$body.properties.creationData.sourceResourceId	= $_.SnapshotId
					$body.properties.creationData.createOption		= 'Copy'
				}

				#--------------------------------------------------------------
				$apiVersion='2026-03-02'
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

				Invoke-WebRequest @invokeParam | Out-Null
			}
			catch {
				Write-Output "---> $($error[0] -as [string])"
				throw "'$diskName' creation failed"
			}
		}

		else {
			#--------------------------------------------------------------
			# use Az cmdlet
			try {
				
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

				#--------------------------------------------------------------
				# special cases
				if ($_.DiskControllerType -eq 'NVME') {
					# no parameter exists yet
				}

				# disk.supportedCapabilities.supportedSecurityOption' is not supported for this subscription/region
				if ($_.SecurityType -like 'ConfidentialVM*') {
					# 	$param.SupportedSecurityOption = 'TrustedLaunchAndConfidentialVMSupported'
				}
				elseif ($_.SecurityType -eq 'TrustedLaunch') {
					# 	$param.SupportedSecurityOption = 'TrustedLaunchSupported'
				}

				#--------------------------------------------------------------
				# create from BOLB
				if ($_.BlobCopy) {
					Write-Output "... $diskName (from BLOB using New-AzDisk)"

					$param.StorageAccountId	= $blobsSaID
					$param.SourceUri		= "https://$blobsSA.blob.core.windows.net/$blobsSaContainer/$($_.Name).vhd"
					$param.CreateOption		= 'Import'

					if ($_.SecurityType -like 'ConfidentialVM*') {
						$param.CreateOption		= 'ImportSecure'
						$param.SecurityDataUri	= "https://$blobsSA.blob.core.windows.net/$blobsSaContainer/$($_.Name).state"
						$param.SecurityType		= $_.SecurityType
					}
				}
		
				#--------------------------------------------------------------
				# create from snapshot
				else {
					Write-Output "... $diskName (from SNAPSHOT using New-AzDisk)"

					$param.sourceResourceId	= $_.SnapshotId
					$param.createOption		= 'Copy'
				}
		
				#--------------------------------------------------------------
				$diskConfig = New-AzDiskConfig @param
		
				New-AzDisk `
					-DiskName           $diskName `
					-Disk               $diskConfig `
					-ResourceGroupName  $targetRG `
					-WarningAction		'SilentlyContinue' `
					-ErrorAction		'Stop' | Out-Null
				#--------------------------------------------------------------
			}
			catch {
				Write-Output "---> $($error[0] -as [string])"
				throw "'$diskName' creation failed"
			}
		}

		# display single statistics
		$endTime = get-date
		$_.TotalMinutes = ($endTime - $startTime).TotalMinutes
		Write-Output "$diskName ($($_.sizeGB) GB, $("{0:F2}" -f $_.TotalMinutes) minutes)"
	}

	#--------------------------------------------------------------
	# start execution
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	write-logFile "Creating disk..."

	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host

	if (!$?) {
		write-logFileError "Creation of disks failed"
	}

	#--------------------------------------------------------------
	# calculate total statistics
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$script:stepTotalObjects	+= 1
		$script:stepTotalSizeGB		+= $_.SizeGB
		$script:stepTotalTime		+= $_.TotalMinutes
	}
	write-stepEnd -endMeasurement


	#==============================================================
	# wait for disk creation completion
	$disksV2 = @( $script:copyDisks.Values
					| Where-Object Skip -ne $True
					| Where-Object SkuName -in @('UltraSSD_LRS', 'PremiumV2_LRS') )

	if ($disksV2.count -gt 0) {

		if (!$(wait-completion "DISK CREATION" `
					'disks' $targetRG $snapshotWaitCreationMinutes)) {

			write-logFileError "DISK CREATION COMPLETION did not finish within $snapshotWaitCreationMinutes minutes"
		}
	}

	set-context -restore # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function update-nics2skip {
#--------------------------------------------------------------
	# remove NICs in delegated subnets (NIC has to be created by delegation service)
	$collected4delegation = @()
	# remove NICs used for endpoints
	$collected4endpoint = @()

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
								$collected4delegation += $nic.Name
							}
						}
					}
				}
			}
		}
	}

	# resource was skipped in add-az_networkInterfaces (but still exists in $script:copyNICs)
	# get NICs for endpoints
	foreach ($nic in $script:az_networkInterfaces) {
		if ($Null -ne $nic.PrivateEndpoint.Id) {
			$collected4endpoint += $nic.Name
		}
	}

	# remove collected NICs
	foreach ($nic in $collected4delegation) {
		if ($null -ne $script:copyNICs[$nic]) {
			write-logFileUpdates 'networkInterfaces' $nic 'delete (used for delegation)'
			$script:copyNICs[$nic].skip = $True
		}
	}
	remove-resources 'Microsoft.Network/networkInterfaces' $collected4delegation

	foreach ($nic in $collected4endpoint) {
		if ($null -ne $script:copyNICs[$nic]) {
			write-logFileUpdates 'networkInterfaces' $nic 'delete (used in private endpoint)'
			$script:copyNICs[$nic].skip = $True
		}
	}
	remove-resources 'Microsoft.Network/networkInterfaces' $collected4endpoint
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

		# update privateIPAllocationMethod
		$value = $script:paramValues[$_.name]
		if ($Null -ne $value) {
			test-values 'setPrivateIpAlloc' $value @('Dynamic', 'Static') 'allocation type'

			for ($i = 0; $i -lt $_.properties.ipConfigurations.count; $i++) {
				$ip = $_.properties.ipConfigurations[$i].properties.privateIPAddress

				# change
				if ($_.properties.ipConfigurations[$i].properties.privateIPAllocationMethod -ne $value) {

					$_.properties.ipConfigurations[$i].properties.privateIPAllocationMethod = $value
					write-logFileUpdates 'privateIPAddresses' $ip 'set Allocation Method' $value -valueWarning
				}

				# keep
				else {
					write-logFileUpdates 'privateIPAddresses' $ip 'keep Allocation Method' $value
				}
			}
		}

		# correct privateIPAddress, privateIPAddressPrefixLength
		for ($i = 0; $i -lt $_.properties.ipConfigurations.count; $i++) {
			
			# Dynamic
			if ($_.properties.ipConfigurations[$i].properties.privateIPAllocationMethod -eq 'Dynamic') {
				# calculate prefix
				if ($null -eq $_.properties.ipConfigurations[$i].properties.privateIPAddressPrefixLength) {
					$prefix = ($_.properties.ipConfigurations[$i].properties.privateIPAddress -split '/')[1]
					if ($null -ne $prefix) {
						$_.properties.ipConfigurations[$i].properties.privateIPAddressPrefixLength = ($prefix -as [int])
					}
				}

				# remove privateIPAddress
				$_.properties.ipConfigurations[$i].properties.privateIPAddress = $null
			}

			# Static
			else {
				# remove privateIPAddressPrefixLength
				$_.properties.ipConfigurations[$i].properties.privateIPAddressPrefixLength = $null
			}
		}
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
function update-vmssFlex {
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

				$bicepName = get-bicepNameByType 'Microsoft.Compute/virtualMachineScaleSets' $vmssName
				# for new resources, parameter collectReferences does not work
				$_.bicepNamesReferenced += $bicepName

				$_.properties.virtualMachineScaleSet = @{
					id = "<$bicepName.id>"
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
	get-parameterRule
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
		get-parameterRule
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
	| Out-String -Width $screenWidthSmall
	| write-logFilePipe
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

			$bicepName = get-bicepNameByType 'Microsoft.Compute/availabilitySets' $asName
			# for new resources, parameter collectReferences does not work
			$_.bicepNamesReferenced += $bicepName

			$_.properties.availabilitySet = @{
				id = "<$bicepName.id>"
			}

			write-logFileUpdates 'virtualMachines' $vmName 'set availabilitySet' $asName

			# for each VM in AvSet: add PPG if AvSet is part of the PPG
			if ($ppgName.length -ne 0) {

				$bicepName = get-bicepNameByType 'Microsoft.Compute/proximityPlacementGroups' $ppgName
				# for new resources, parameter collectReferences does not work
				$_.bicepNamesReferenced += $bicepName

				$_.properties.proximityPlacementGroup = @{
					id = "<$bicepName.id>"
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

			$bicepName = get-bicepNameByType 'Microsoft.Compute/proximityPlacementGroups' $ppgName
			# for new resources, parameter collectReferences does not work
			$_.bicepNamesReferenced += $bicepName
			
			$_.properties.proximityPlacementGroup = @{
				id = "<$bicepName.id>"
			}
			write-logFileUpdates $type $_.name 'set proximityPlacementGroup' $ppgName
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
		# detached disk, but parameter defaultDiskZone not set
		else {
			write-logFileError "You must set parameter 'defaultDiskZone' when copying detached disks"
		}

		# for just copy disks: parameter defaultDiskZone overrides zone setting
		if ($justCopyDisks.count -ne 0) {
			if ($Null -ne $defaultDiskZone) {
				$diskZoneNew = $defaultDiskZone
			}
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
	update-paramsetVmEncryptionAtHost

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
	update-nics2skip
	update-paramSetAcceleratedNetworking

	# used for clone and merge mode
	update-paramAttachVmssFlex
	update-paramAttachAvailabilitySet
	update-paramAttachProximityPlacementGroup
}

#--------------------------------------------------------------
function update-resourcesAll {
#--------------------------------------------------------------
	update-tags

	# remove skipped resources 
	$script:collectedSkipIPs  = @()
	$script:collectedSkipNICs = @()
	update-skipVMsNICsIPs
	remove-resources 'Microsoft.Compute/virtualMachines' $script:collectedSkipVMs
	remove-resources 'Microsoft.Network/networkInterfaces' $script:collectedSkipNICs
	remove-resources 'Microsoft.Network/publicIPAddresses' $script:collectedSkipIPs
	
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
		update-vmssFlex
		
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

	update-SKUs
	update-IpAllocationMethod
	update-FQDN

	update-storageAccounts

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
		if ($script:copyVMs[$vmName].EncryptionAtHost) {
			$_.properties.securityProfile.encryptionAtHost = $true
		}
		else {
			$_.properties.securityProfile.encryptionAtHost = $null
		}
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
				write-logFileError "VM size '$vmSize' does not support feature 'TrustedLaunch'" `
									"Cannot change VM size of VM '$vmName'"
			}
		}

		# check if ConfidentialVM is supported for target VM size
		if ($_.properties.securityProfile.securityType -eq 'ConfidentialVM') {
			if ($script:vmSkus[$vmSize].ConfidentialComputingType.Length -eq 0) {
				write-logFileError "VM size '$vmSize' does not support feature 'ConfidentialVM'" `
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

		$nextDependentVMs += "<$(get-bicepNameByType 'Microsoft.Compute/virtualMachines' $vmName)>"

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
	# add new disks (not existing in source RG) to the ARM template
	# disks have been defined by RGCOPY parameter 'createDisks'

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

				# save new disks
				$script:copyDisksNew[$diskName] = @{
					Name					= $diskName
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

				# update $script:copyVMs[].MountPoints
				$mp.Lun 		= $diskLun

				# create disk
				$disk = @{
					type 			= 'Microsoft.Compute/disks'
					apiVersion		= '2022-07-02'
					name 			= $diskName
					location		= $targetLocation
					sku				= @{ name = $skuName }
					properties		= $properties
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

					$bicepName = get-bicepNameByType 'Microsoft.Compute/disks'	$diskName
					# for new resources, parameter collectReferences does not work
					$_.bicepNamesReferenced += $bicepName

					$dataDisk.managedDisk = @{
						id = "<$bicepName.id>"
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
	# add existing disks (existing in source RG) to the ARM template

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

				$snapshotId = "<resourceId('$subID','$rg','Microsoft.Compute/snapshots','$snapshotName')>"

				$creationData = @{
					createOption 		= 'Copy'
					sourceResourceId 	= $snapshotId
				}
			}
	
			#--------------------------------------------------------------
			# creation from BLOB
			else {
				$from = 'BLOB'
				$blobsSaID = "<resourceId('$targetSubID','$blobsRG','Microsoft.Storage/storageAccounts','$blobsSA')>"

				$creationData = @{
					createOption 		= 'Import'
					storageAccountId 	= $blobsSaID
					sourceUri 			= "https://$blobsSA.blob.core.windows.net/$blobsSaContainer/$diskName.vhd"
				}

				# if ($_.SecurityType -like 'ConfidentialVM*') {
				# 	$creationData.createOption = 'ImportSecure'
				# }
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

			# add SecurityType when importing from BLOB
			if ($properties.creationData.createOption -eq 'Import') {
				if ($_.SecurityType.Length -ne 0) {
					# New ARM property securityProfile for disks.
					$properties.securityProfile = @{
						securityType = $_.SecurityType
					}
				}
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

			$regionName = '<regionName>'
	
			# new resource
			$resource = @{
				type 			= 'Microsoft.Compute/disks'
				apiVersion		= '2025-01-02'
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

		$bicepName = get-bicepNameByType 'Microsoft.Compute/images' $imageName
		# for new resources, parameter collectReferences does not work
		$_.bicepNamesReferenced += $bicepName

		$_.properties.storageProfile.imageReference  = @{
			id = "<$bicepName.id>"
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
		apiVersion	= '2025-01-01'
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
		apiVersion	= '2025-01-01'
		name 		= "$netAppAccountName/$netAppPoolName"
		location	= $targetLocation
		properties	= @{
			serviceLevel	= $netAppServiceLevel
			size			= $script:netAppPoolGB * 1024 * 1024 * 1024
			qosType			= 'Auto'
			coolAccess		= $False
		}
	}

	$res.parent = "<$(get-bicepNameByType 'Microsoft.NetApp/netAppAccounts' $netAppAccountName)>"

	write-logFileUpdates 'capacityPools' $netAppPoolName 'create'
	add-resourcesALL $res

	#--------------------------------------------------------------
	# get vnet, subnet
	$vnet, $subnet = test-subnet 'subnetNetApp' $subnetNetApp 'Microsoft.NetApp/volumes'

	$subnetId = get-resourceFunction `
					'Microsoft.Network' `
					'virtualNetworks'	$vnet `
					'subnets'			$subnet

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

		if ($_.Rename.length -ne 0)	{ 
			$vmName = $_.Rename 
		}
		else { 
			$vmName = $_.Name
		}

		$_.MountPoints
		| Where-Object Type -eq 'NetApp'
		| ForEach-Object {

			$path = $_.Path
			$volumeSizeGB = $_.Size
			$volumeName = "$vmName$($path -replace '/', '-')"

			# update $script:copyVMs[].MountPoints
			$_.VolumeName 	= $volumeName

			$res = @{
				type 		= 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes'
				apiVersion	= '2025-01-01'
				name 		= "$netAppAccountName/$netAppPoolName/$volumeName"
				location	= $targetLocation
				properties	= @{
					# throughputMibps				= 65536
					coolAccess					= $False
					serviceLevel				= $netAppServiceLevel
					networkFeatures				= $netAppNetworkFeatures
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
			}

			$res.parent = "<$(get-bicepNameByType 'Microsoft.NetApp/netAppAccounts/capacityPools' "$netAppAccountName/$netAppPoolName")>"
			$res.properties.subnetId = $subnetId # <resourceId(...)>
			$res.dependsOn = @( "<$(get-bicepNameByType 'Microsoft.Network/virtualNetworks' $vnet)>" )

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

		$nameOld = $_.NicName

		if ($_.Rename.length -ne 0) {
			$nameNew = $_.Rename
		}
		else {
			$nameNew = $_.NicName
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
	$clonePublicIPs = ($script:copyNICs.Values | Where-Object NicName -in $cloneNICs).IpAddressNames

	$keepResources += @(
		$script:resourcesALL `
		| Where-Object { ($_.type -eq 'Microsoft.Network/publicIPAddresses') `
					-and ($_.name -in $clonePublicIPs) }
	)

	# keep collected
	$script:resourcesALL = $keepResources
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
				networkInterfaces = @(
					@{
						id = "<$(get-bicepNameByType 'Microsoft.Network/networkInterfaces' $nicName).id>"
					}
				)
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

			# update NIC
			$nicRes.properties.ipConfigurations[0].properties.publicIPAddress = @{
				id = "<$(get-bicepNameByType 'Microsoft.Network/publicIPAddresses' $ipName).id>"
			}

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

	set-context -restore # *** CHANGE SUBSCRIPTION **************

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
	if ($verboseLog) {
		write-logFileHashTable $script:rgcopyParamOrig
	}

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
		$rgName,
		$scriptVm
	)

	for ($i = 1; $i -le $vmAgentWaitMinutes; $i++) {

		# get current vmAgent Status
		$vm = Get-AzVM `
				-ResourceGroupName	$rgName `
				-Name				$scriptVm `
				-status `
				-WarningAction 	'SilentlyContinue' `
				-ErrorAction 'SilentlyContinue'
		test-cmdlet 'Get-AzVM'  "Getting VM status failed"

		$status  = $vm.VMAgent.Statuses.DisplayStatus
		$version = $vm.VMAgent.VmAgentVersion
		$osType  = $vm.StorageProfile.OsDisk.OsType

		# status unknown
		if ($Null -eq $status) {
			write-logFileError "Getting VM Agent status failed"
		}
		
		# status ready
		elseif ($status -eq 'Ready') {
			write-logFile -ForegroundColor 'DarkGray' "VM Agent status:  $status"
			write-logFile -ForegroundColor 'DarkGray' "VM Agent version: $version"
			
			if ((!$skipVmChecks) -and ($version.Length -gt 0)) {
				try {
					# test 3 parts of version
					$v = [int[]] ($version -split '\.') + @(0,0,0,0)
					# main version: 1 digit  -> shift 8
					# mid version:  3 digits -> shift 5
					# sub version:  5 digits
					[int64] $versionInt64 = $v[2] + 100000 * $v[1] + 100000000 * $v[0]

					# https://docs.microsoft.com/en-us/troubleshoot/azure/virtual-machines/support-extensions-agent-version
					# check minimum version for Linux
					if ($osType -eq 'Linux') {
						$minVersionStr = '2.2.53.1'
						[int64] $minVersionInt64 = 200200053
					}

					# check minimum version for Windows
					else {
						$minVersionStr = '2.7.41491.1010'
						[int64] $minVersionInt64 = 200741491
					}

					if ($versionInt64 -lt $minVersionInt64) {
						write-logFileWarning "VM Agent version check failed: version $version is older than $minVersionStr" `
											"You should update VM Agent of VM '$scriptVm' to the latest version"
					}
				}
				catch {}
			}

			return
		}

		# status not ready yet
		else {
			write-logFile -ForegroundColor 'DarkGray' "VM Agent Status:  $status ->waiting 1 minute..."
			Start-Sleep -Seconds 60
		}
	}

	# status not ready after 30 minutes ($vmAgentWaitMinutes)
	write-logFileError "VM Agent of VM '$scriptVm' is not ready"
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
		wait-vmAgent $resourceGroup $vm
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
function update-storageAccounts {
#--------------------------------------------------------------
	$script:allShares = @()
	# storage account names that have file or blob services in target RG:
	$script:fileservices = @()
	$script:blobservices = @()

	#--------------------------------------------------------------
	# storageAccounts
	$sa4deletion = @()
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Storage/storageAccounts'
	| ForEach-Object {

		$oldName = $_.name

		if ($null -eq $script:copySA[$oldName]) {
			# remove resource
			$sa4deletion += $_.name
			write-logFileUpdates 'storageAccounts' $oldName  "delete (not defined in parameter 'renameSa')"
		}

		else {
			$newName = $script:copySA[$oldName].newName

			# check name availabilty
			$test = Get-AzStorageAccountNameAvailability $newName
			if ($test.NameAvailable -eq $false) {
				if ($simulate -or $skipDeployment) {
					write-logFileWarning "Storage account name '$newName' not available ($($test.Reason))"
				}
				else {
					write-logFileError "Storage account name '$newName' not available" `
										$test.Reason `
										$test.Message
				}
			}
			
			# set name
			write-logFileUpdates 'storageAccounts' $oldName "rename" $newName
			$_.name = $newName

			#--------------------------------------------------------------
			$script:copySA[$oldName].found					= $true
			$script:copySA[$oldName].allowSharedKeyAccess 	= $_.properties.allowSharedKeyAccess # [bool]
			$script:copySA[$oldName].publicNetworkAccess	= $_.properties.publicNetworkAccess # 'Disabled', 'Enabled', SecuredByPerimeter'
			$script:copySA[$oldName].defaultAction			= $_.properties.networkAcls.defaultAction # 'Deny', 'Allow'

			$script:copySA[$newName].found					= $true
			$script:copySA[$newName].allowSharedKeyAccess	= $script:copySA[$oldName].allowSharedKeyAccess					
			$script:copySA[$newName].publicNetworkAccess	= $script:copySA[$oldName].publicNetworkAccess	
			$script:copySA[$newName].defaultAction			= $script:copySA[$oldName].defaultAction			

			#--------------------------------------------------------------
			# allowSharedKeyAccess (Do not change source SA)

			# was TRUE
			if ($_.properties.allowSharedKeyAccess -eq $true) {
				if (!$targetSubInternal) {
					write-logFileUpdates 'storageAccounts' $newName "keep allowSharedKeyAccess" $true
				}
				else {
					# change allowSharedKeyAccess for MS internal subscriptions
					# required by policy
					write-logFileUpdates 'storageAccounts' $newName "set allowSharedKeyAccess" $false
					$_.properties.allowSharedKeyAccess = $false
					$script:copySA[$newName].allowSharedKeyAccess = $false
				}
			}

			# was FALSE
			else {
				if ($targetSubInternal -or $targetNoSaKeys) {
					write-logFileUpdates 'storageAccounts' $newName "keep allowSharedKeyAccess" $false
				}
				else {
					# change allowSharedKeyAccess for non-MS internal subscriptions
					# more reliable for content copy
					# required for cross-tenant content copy
					write-logFileUpdates 'storageAccounts' $newName "set allowSharedKeyAccess" $true -valueWarning
					$_.properties.allowSharedKeyAccess = $true
					$script:copySA[$newName].allowSharedKeyAccess = $true
					write-logFileWarning "Allowing Shared Key Access for SA $newName" `
										"You might change this manually after SA content has been copied"		
				}
			}

			#--------------------------------------------------------------
			# publicNetworkAccess (Do not change source SA)

			# was Enabled
			if ($_.properties.publicNetworkAccess -eq 'Enabled') {
				write-logFileUpdates 'storageAccounts' $newName "keep publicNetworkAccess" 'Enabled'
			}

			# was Disabled
			elseif ($_.properties.publicNetworkAccess -eq 'Disabled') {
				write-logFileUpdates 'storageAccounts' $newName "keep publicNetworkAccess" 'Disabled'
				# content copy would only work if you also change the source SA
				write-logFileWarning "Cannot copy content of SA $oldName because of disabled Public Network Access"		
			}

			# was SecuredByPerimeter
			elseif ($_.properties.publicNetworkAccess -eq 'SecuredByPerimeter') {
				
				write-logFileUpdates 'storageAccounts' $newName "set publicNetworkAccess" 'Disabled' -valueWarning
				$_.properties.publicNetworkAccess = 'Disabled'
				$script:copySA[$newName].publicNetworkAccess = 'Disabled'

				# content copy (azcopy) is currently not possible with SecuredByPerimeter
				write-logFileWarning "Cannot copy content of SA $oldName because Public Network Access is SecuredByPerimeter"		
			}

			#--------------------------------------------------------------
			# networkAcls.defaultAction (Do not change source SA)
			if (($_.properties.networkAcls.defaultAction -eq 'Allow') ) {
					# always change default action to Deny
					# Therefore, only selected IPs can access when publicNetworkAccess is enabled
					write-logFileUpdates 'storageAccounts' $newName "set networkAcls.defaultAction" 'Deny'
					$_.properties.networkAcls.defaultAction = 'Deny'
					$script:copySA[$newName].defaultAction = 'Deny'
			}
			else {
				write-logFileUpdates 'storageAccounts' $newName "keep networkAcls.defaultAction" $_.properties.networkAcls.defaultAction
			}

		}
	}
	remove-resources 'Microsoft.Storage/storageAccounts' $sa4deletion

	#--------------------------------------------------------------
	# fileServices
	$items2delete = @()
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Storage/storageAccounts/fileServices'
	| ForEach-Object {

		$oldName = ($_.name -split '/')[0]
		$serviceName = ($_.name -split '/')[1]

		if ($Null -eq $script:copySA[$oldName]) {
			# remove resource
			$items2delete += $_.name
		}

		else {
			$newName = $script:copySA[$oldName].newName
			$_.name = "$newName/$serviceName"
			$script:fileservices += $newName
		}
	}
	remove-resources 'Microsoft.Storage/storageAccounts/fileServices' $items2delete

	#--------------------------------------------------------------
	# blobServices
	$items2delete = @()
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Storage/storageAccounts/blobServices'
	| ForEach-Object {

		$oldName = ($_.name -split '/')[0]
		$serviceName = ($_.name -split '/')[1]

		if ($Null -eq $script:copySA[$oldName]) {
			# remove resource
			$items2delete += $_.name
		}

		else {
			$newName = $script:copySA[$oldName].newName
			$_.name = "$newName/$serviceName"
			$script:blobservices += $newName
		}	
	}
	remove-resources 'Microsoft.Storage/storageAccounts/blobServices' $items2delete

	#--------------------------------------------------------------
	# container and shares
	foreach ($resType in @( 'Microsoft.Storage/storageAccounts/blobServices/containers'
							'Microsoft.Storage/storageAccounts/fileServices/shares')) {

		$serviceType = ((($resType -split '/')[2]) -split 'Services')[0] # blob or file
		
		$items2delete = @()
		$script:resourcesALL
		| Where-Object type -eq $resType
		| ForEach-Object {

			if ($serviceType -eq 'blob') {
				$type = 'BLOB'
			}
			else {
				$type = $_.properties.enabledProtocols # SMB or NFS
			}

			$oldName = ($_.name -split '/')[0]
			$serviceName = ($_.name -split '/')[1]
			$shareName = ($_.name -split '/')[2]

			# storage account not defined in parameter renameSa
			if ($Null -eq $script:copySA[$oldName]) {
				# remove resource
				$items2delete += $_.name
			}

			else {
				# rename container or share
				$newName = $script:copySA[$oldName].newName
				$_.name = "$newName/$serviceName/$shareName"

				# skipping container/share
				$reason = $null
				$skip = $false

				# global flag
				if ($copySaShares -is [boolean]) {
					$skip = !$copySaShares
					if ($skip) {
						$reason = "parameter 'copySaShares' is `$false"
					}
				}
				# list of containers/shares to copy
				elseif ($shareName -notin $copySaShares) {
					$skip = $true
					$reason = "share not in 'copySaShares'"
				}

				$script:allShares += @{
					StorageAccount	= $oldName
					NewName			= $newName
					Share			= $shareName
					Type			= $type
					Skip			= $skip
					Reason			= $reason
					Snapshot		= $Null
					SizeGB			= $null
				}
			}	
		}
		remove-resources $resType $items2delete	
	}

	#--------------------------------------------------------------
	$script:copySA.values
	| Where-Object sourceRG -eq $true
	| Where-Object found -ne $true
	| ForEach-Object {

		write-logFileError "Storage account $($_.oldName) not found in source RG"
	}

	#--------------------------------------------------------------
	# check publicNetworkAccess
	$script:copySA.values
	| Where-Object sourceRG -eq $true
	| ForEach-Object {
		
		$oldName = $_.oldName
		$publicNetworkAccess = $_.publicNetworkAccess

		if ($publicNetworkAccess -in @('Disabled', 'SecuredByPerimeter')) {
			
			$script:allShares
			| Where-Object StorageAccount -eq $oldName
			| ForEach-Object {
	
				$_.Skip = $true
				$_.Reason = "Public NW access = $publicNetworkAccess"
			}
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
					if ($key -like $tagNamePattern) {
						if ($key -notlike 'rgcopySnapshot*') {
							$tagsNew[$key] = $tagsOld[$key]
						}
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
function set-templateParameters {
#--------------------------------------------------------------
	param (
		[ref] $ref
	)

	# set "variables"
	$ref.value += '@metadata({'
	$ref.value += "  rgcopyVersion: '$pwshVersion'"
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

#--------------------------------------------------------------
function get-templateParameters {
#--------------------------------------------------------------
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

#--------------------------------------------------------------
function show-defaultValues {
#--------------------------------------------------------------
	param (
		$rgcopyPar,
		[switch] $silent
	)

	if ($rgcopyPar -notin $boundParameterNames) {
		$script:defaultValuesExists = $true
		if (!$silent) {
			write-logFile "$rgcopyPar = '$(Get-Variable -Name $rgcopyPar -ValueOnly -Scope 'Script')'" -ForegroundColor 'yellow'
		}
	}
}

#--------------------------------------------------------------
function show-warningDefaultValues {
#--------------------------------------------------------------
	if ($skipDefaultValues) {
		return
	}

	$parlist = @(
		'setDiskSku'
		'setVmZone'
		'setPrivateIpAlloc'
		'setAcceleratedNetworking'
	)
	
	$script:defaultValuesExists = $false
	foreach ($p in $parlist) {
		show-defaultValues $p -silent
	}

	if ($script:defaultValuesExists) {
		write-logFile ('-' * $starCount) -ForegroundColor 'yellow'
		write-logFileWarning "RGCOPY uses default values for the following parameters:"
		write-logFile ('-' * $starCount) -ForegroundColor 'yellow'

		foreach ($p in $parlist) {
			show-defaultValues $p
		}
		write-logFile
		write-logFile "You can disable default values by setting parameter 'skipDefaultValues'"
		write-logFile "or by setting the above parameters explicitly to a different value."
		write-logFile
		write-logFile
	}

	if ('setPrivateIpAlloc' -in $boundParameterNames) {
		write-logFileWarning "Using Dynamic Private IP Allocations in target RG is not recommended" `
								"It could cause issues, e.g. for Private DNS zones"
	}
}

#--------------------------------------------------------------
function new-templateBicep {
#--------------------------------------------------------------
	show-warningDefaultValues

	$script:bicepNamesAll = @{}
	# get zones from targetRG
	get-skuProperties
	$script:allTargetZones = $script:skuProperties.LocationInfo.Zones | Sort-Object -Unique
	# special case: region eastus2euap has zone 4
	if ($script:allTargetZones.count -notin @(1, 2, 3)) {
		$script:allTargetZones = @()
	}

	# --- start output resource changes
	Write-logFile 'Resource                                     Changes by RGCOPY' -ForegroundColor 'Green'
	Write-logFile '--------                                     -----------------' -ForegroundColor 'Green'

	#--- create internal structures
	$script:resourcesALL = @()
	add-az_virtualMachines
	add-az_privateEndpoints
	add-az_virtualNetworks
	add-az_networkInterfaces
	
	add-az_networkSecurityGroups
	add-az_applicationSecurityGroups
	add-az_bastionHosts
	add-az_routeTables
	if ($copyDNS) {
		add-az_dnsZones
	}
	add-az_privateDnsZones
	add-az_natGateways
	add-az_publicIPPrefixes
	add-az_publicIPAddresses
	add-az_proximityPlacementGroups
	add-az_availabilitySets
	add-az_virtualMachineScaleSet
	add-az_loadBalancers
	add-az_storageAccounts

	save-cloneNames
	remove-resources4cloneOrMerge

	#--- process resources
	update-paramAll
	update-resourcesAll

	#--- create bicep
	write-logFile
	$script:bicep = @()
	set-templateParameters ([ref] $script:bicep)

	foreach ($res in $script:resourcesALL) {
		# disk resource
		if ($res.type -eq 'Microsoft.Compute/disks') {
			if ($createDisksManually) {
				$script:bicep	+= add-bicepResource $res -existing
			}
			else {
				$script:bicep	+= add-bicepResource $res
			}
		}

		# other resources
		else {
			$script:bicep		+= add-bicepResource $res
		}
	}

	# save template
	save-bicepFile $exportPath  ([ref] $script:bicep)
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
	$script:logFiles += $exportPath	
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
	# output of skipped VMs
	foreach ($vm in $script:collectedSkipVMs) {
		if (!$cloneOrMergeMode) {
			write-logFileUpdates 'virtualMachines' $vm 'skip VM'
		}
	}

	$script:copyVMs.Values
	| Where-Object Name -in $script:collectedSkipVMs
	| ForEach-Object {

		$script:collectedSkipNICs += $_.NicNames
		$script:collectedSkipIPs  += $_.IpNames
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
		get-parameterRule
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
			get-parameterRule
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

	write-stepStart "DEPLOY TEMPLATE" -skipLF -startMeasurement

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

	if (!$skipExtensions -and $ignoreExtensionErrors) {
		write-logFileWarning "Deployment errors of VM extensions will be ignored" `
							"(can be changed by setting parameter ignoreExtensionErrors=`$false)"
	}

	# deploy
	New-AzResourceGroupDeployment @parameter
	| write-logFilePipe
	if (!$?) {
		write-logFile $myDeploymentError -ForegroundColor 'yellow'
		write-logFileError "Deployment '$DeploymentName' failed" `
							"Check the Azure Activity Log in resource group $targetRG"
	}

	if ($targetSubAllowNSP -and $targetSubInternal) {
		# create NSP (but not for disk deployment)
		if ($DeploymentPath -eq $exportPath) {
			foreach ($saNm in ($script:copySA.Values.newName | Sort-Object -Unique)) {
				write-logFile
				write-logFile 'Deploy Network Security Perimeter'
				# create and associate NSP, do not create any rule yet
				new-saAssociation $saNm $targetSubID $targetRG $targetLocation

				# Set-AzStorageAccount `
				# 	-ResourceGroupName $targetRG `
				# 	-Name $saNm `
				# 	-PublicNetworkAccess 'SecuredByPerimeter' `
				# 	-ErrorAction 'SilentlyContinue' | Out-Null
				# test-cmdlet 'Set-AzStorageAccount'  "Could not set property PublicNetworkAccess to SecuredByPerimeter"
				# write-logFileTab 'Modify SA' 'PublicNetworkAccess' 'SecuredByPerimeter'
			}
		}
	}

	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
function deploy-linuxDiagnostic {
#--------------------------------------------------------------
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
	write-stepStart "Deploy VM Azure Enhanced Monitoring Extension (VMAEME) for SAP" -startMeasurement

	#--------------------------------------------------------------
	# create script and parameters
	$scriptParameter =  "`$targetRG = '$targetRG';"

	$script = {

		$vmName = $_
		Write-Output "... deploying VMAEME on $vmName"

		$res = Set-AzVMAEMExtension `
			-ResourceGroupName 	$targetRG `
			-VMName 			$vmName `
			-InstallNewExtension `
			-WarningAction 'SilentlyContinue' `
			-ErrorAction 'SilentlyContinue'

		if (($res.IsSuccessStatusCode -ne $True) -or ($res.StatusCode -ne 'OK')) {
			Write-Output "---> $($error[0] -as [string])"
			throw "Deployment of VMAEME for SAP failed on $vmName"
		}

		Write-Output $vmName
	}

	#--------------------------------------------------------------
	# start script in parallel
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	write-logFile "Deploying SAP monitor..."

	$installExtensionsSapMonitor
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileWarning "Deployment of VMAEME for SAP failed"
	}

	write-stepEnd -endMeasurement
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
		$vmObjects
	)

	$rgType = get-rgType $resourceGroup
	write-stepStart "STOP VMs IN $rgType" $maxDOP -startMeasurement

	$vmNames = ($vmObjects | Where-Object PowerState -ne 'VM deallocated').Name
	if ($VmNames.count -eq 0) {
		write-logFile "All VMs are already stopped"
	}
	else {
		stop-parallelVMs $resourceGroup $vmNames
	}

	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
function stop-parallelVMs {
#--------------------------------------------------------------
	param (
		$resourceGroup,
		$vmNames,
		[switch] $skipMeasurement
	)

	$vmNames = $vmNames | Sort-Object -Unique

	$VMs = @()
	foreach ($name in $vmNames) {
		$VMs += @{
			Name = $name
			TotalMinutes = 0
		}
	}

	#--------------------------------------------------------------
	# create script and parameters
	$scriptParameter =  "`$resourceGroup = '$resourceGroup';"

	$script = {
		$startTime = get-date
		$vmName = $_.Name

		Write-Output "... $vmName"

		try {
			Stop-AzVM `
				-Force `
				-Name 				$vmName `
				-ResourceGroupName 	$resourceGroup `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop' | Out-Null
		}
		catch {
			Write-Output "---> $($error[0] -as [string])"
			throw "Could not stop VM $vmName"
		}

		$endTime = get-date
		$_.TotalMinutes = ($endTime - $startTime).TotalMinutes

		Write-Output $vmName
	}

	#--------------------------------------------------------------
	# start script in parallel
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	write-logFile "Stopping VM..."

	$VMs
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host

	if (!$?) {
		write-logFileError "Could not stop VMs in resource group $resourceGroup" `
							"Stop-AzVM failed"
	}

	if (!$skipMeasurement) {
		$VMs
		| ForEach-Object {
			$script:stepTotalObjects	+= 1
			$script:stepTotalTime		+= $_.TotalMinutes
		}
	}
}

#--------------------------------------------------------------
function start-parallelVMs {
#--------------------------------------------------------------
	param (
		$resourceGroup,
		$startVMs
	)

	$VmNames = (Get-AzVM `
					-ResourceGroupName $resourceGroup `
					-status `
					-WarningAction	'SilentlyContinue' `
					-ErrorAction 'SilentlyContinue' `
					| Where-Object Name -in $startVMs
					| Where-Object PowerState -ne 'VM running').Name
	test-cmdlet 'Get-AzVM'  "Could not get VMs of resource group $resourceGroup"
	$VmNames = $VmNames | Sort-Object

	if ($VmNames.Count -eq 0) {
		return
	}

	#--------------------------------------------------------------
	# create script and parameters
	$scriptParameter =  "`$resourceGroup = '$resourceGroup';"

	$script = {

		if ($_.length -ne 0) {
			Write-Output "... $($_)"

			try {
				Start-AzVM `
					-Name 				$_ `
					-ResourceGroupName 	$resourceGroup `
					-WarningAction 'SilentlyContinue' `
					-ErrorAction 'Stop' | Out-Null			
			}
			catch {
				Write-Output "---> $($error[0] -as [string])"
				throw "Could not start VM $($_)"
			}
			
			Write-Output "$($_)"
		}
	}

	#--------------------------------------------------------------
	# start script in parallel
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	write-logFile "Starting VM..."

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

	$rgType = get-rgType $resourceGroup
	write-stepStart "Start VMs in $rgType" $maxDOP

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
				start-parallelVMs $resourceGroup $currentVMs
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
		start-parallelVMs $resourceGroup $currentVMs
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
		[ref] $refPath,
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
	write-taskStart "Reading RGCOPY tags from VMs in resoure group '$resourceGroup'"

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
	| Out-String -Width $screenWidthLarge
	| write-logFilePipe

	if ($script:rgcopyTags.count -eq 0) {
		write-logFile "No RGCOPY tags found"
	}
	elseif ($ignoreTags) {
		write-logFileWarning "Tags ignored by RGCOPY"
	}
	else {
		write-logFile "Tags can be ignored using RGCOPY parameter switch 'ignoreTags'"
	}
	write-logFile
	write-logFile
}

#--------------------------------------------------------------
function remove-storageAccount {
#--------------------------------------------------------------
	param (
		$myRG,
		$mySA,
		$mySub,
		$mySubID
	)

	$rgType = get-rgType $myRG
	write-stepStart "REMOVE SA IN $rgType" -startMeasurement

	Get-AzStorageAccount `
		-ResourceGroupName 	$myRG `
		-Name 				$mySA `
		-ErrorAction 'SilentlyContinue' | Out-Null
	if ($?) {
		# remove existing storage account
		Remove-AzStorageAccount `
			-ResourceGroupName	$myRG `
			-AccountName		$mySA `
			-Force
		test-cmdlet 'Remove-AzStorageAccount'  "Could not delete storage account $mySA"
	
		write-logFileTab 'Storage Account' $mySA 'deleted'
	}

	$nsps = get-nsps $mySubID $myRG
	if ($nspName -in $nsps.name) {

		$nspAss = get-nspAssociations $nspName $mySubID $myRG
		$remainingSAs = $nspAss.name | Where-Object {$_ -ne $mySA}
		if ($remainingSAs.count -eq 0) {
			remove-nsp $mySubID $myRG $nspName 
			write-logFileTab 'NSP' $nspName "deleted in subscription $mySub"
		}
	}

	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
function new-storageAccount {
#--------------------------------------------------------------
# - storage account for COPY SNAPSHOTS TO BLOBS
# - storage account for file copy (switch fileStorage)
# - storage account for ARCHIVE mode (global parameter archiveMode)

	param (
		$mySub,
		$mySubID,
		$myRG,
		$mySA,
		$myLocation,
		[switch] $fileStorage
	)
	
	set-context $mySub # *** CHANGE SUBSCRIPTION **************
	#--------------------------------------------------------------
	# test if Storage Account already exists
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

	#--------------------------------------------------------------
	# Create Storage Account
	#--------------------------------------------------------------
	else {
		# check name availabilty
		$test = Get-AzStorageAccountNameAvailability $mySA
		if ($test.NameAvailable -eq $false) {

			if ($fileStorage) {
				$message = "Retry with by setting different name using parameter 'sourceSA'"
			}
			else {
				$message = "Retry with by setting different name using parameter 'targetSA'"
			}

			write-logFileError "Storage account name '$mySA' not available" `
								$test.Reason `
								$test.Message `
								$message
		}

		$param = @{
			ResourceGroupName		= $myRG
			Name					= $mySA
			Location				= $myLocation
			MinimumTlsVersion 		= 'TLS1_2'
			AllowBlobPublicAccess	= $false
			EnableHttpsTrafficOnly	= $true
			AllowSharedKeyAccess	= $false
			PublicNetworkAccess 	= 'Disabled'
			WarningAction			= 'SilentlyContinue'
			ErrorAction				= 'SilentlyContinue'
		}

		#--------------------------------------------------------------
		# storage account for ARCHIVE mode
		# This is a deprecated feature which is not documeneted anymore
		# ARCHIVE mode is NOT SUPPORTED/POSSIBLE in MS internal version
		if ($archiveMode) {
			$param.SkuName		= 'Standard_ZRS'
			$param.Kind			= 'StorageV2'
			$param.accessTier	= 'Cool'

			$param.AllowSharedKeyAccess	= $True
			$param.PublicNetworkAccess	= 'Enabled'
		}

		#--------------------------------------------------------------
		# storage account for NFS share (backup/restore)
		elseif ($fileStorage) {
			$param.SkuName			= 'Premium_LRS'
			$param.Kind				= 'FileStorage'
			$param.accessTier		= 'Hot'	

			$param.DnsEndpointType	= 'Standard'
			if ($nfsQuotaGiB -gt 5120) {
				$param.EnableLargeFileShare	= $True
			}
			# Secure transfer required must be turned off for NFS
			# https://learn.microsoft.com/en-us/troubleshoot/azure/azure-storage/files/security/files-troubleshoot-linux-nfs
			$param.EnableHttpsTrafficOnly = $False

			$param.PublicNetworkAccess 		= 'Enabled'
			$param.NetworkRuleSet 			= @{defaultAction	= 'Deny'}
		}

		#--------------------------------------------------------------
		# storage account for BLOB copy
		else {
			$param.SkuName		= 'Premium_LRS'
			$param.Kind			= 'StorageV2'
			$param.accessTier	= 'Hot'

			$param.PublicNetworkAccess 		= 'Enabled'
			$param.NetworkRuleSet 			= @{defaultAction	= 'Deny'}

			# allow SA keys
			if (!$targetNoSaKeys) {
				$param.AllowSharedKeyAccess	= $True
			}
		}

		#--------------------------------------------------------------
		# create new storage account
		write-logFileTab 'Storage Account' $mySA 'creating...'
		New-AzStorageAccount @param | Out-Null
		test-cmdlet 'New-AzStorageAccount'  "Creation of storage account $mySA failed" 
	}

	#--------------------------------------------------------------
	# Create Target Container
	#--------------------------------------------------------------
	if (!$fileStorage) {
		Get-AzRmStorageContainer `
			-ResourceGroupName	$myRG `
			-AccountName		$mySA `
			-ContainerName		$targetSaContainer `
			-ErrorAction 'SilentlyContinue' | Out-Null

		if ($?) {
			if ( ($archiveMode) `
			-and (!$archiveContainerOverwrite) `
			-and (!$waitRemoteCopy) ) {
				write-logFileError "Container '$targetSaContainer' already exists" `
									"Existing archive might be overwritten" `
									"Use RGCOPY switch 'archiveContainerOverwrite' for allowing this"
			}
			else {
				write-logFileTab 'Container' $targetSaContainer 'already exists'
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
	}

	#--------------------------------------------------------------
	# Create Source Share
	#--------------------------------------------------------------
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

	#--------------------------------------------------------------
	# Allow NW access for storage account
	#--------------------------------------------------------------
	# MS internal subscription -> NSP needed for policy

	# create NSP in source RG
	if ($fileStorage) {
		if ($sourceSubAllowNSP -and $sourceSubInternal) {
			# create and associate NSP in same resource group as SA
			# do not create any rule yet
			new-saAssociation $mySA $mySubID $myRG $myLocation	
		}	
	}

	# create NSP in target RG
	else {
		if ($targetSubAllowNSP -and $targetSubInternal) {
			# create and associate NSP in same resource group as SA
			# do not create any rule yet
			new-saAssociation $mySA $mySubID $myRG $myLocation	
		}
	}

	set-context -restore # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function remove-endpoint {
#--------------------------------------------------------------
	param (
		 $resourceGroupName		= $script:sourceRG
		,$storageAccountName	= $script:sourceSA
		,$type					= 'file'
	)

	$endpointName 			= "$storageAccountName-$type"
	$dnsZoneName			= "privatelink.$type.core.windows.net"

	write-logFile 'Remove Private Endpoint'
	write-logFileTab 'Resource Group' $resourceGroupName
	#--------------------------------------------------------------
	# get all DNS records
	$recordSets = Get-AzPrivateDnsRecordSet `
		-ResourceGroupName	$resourceGroupName `
		-ZoneName			$dnsZoneName `
		-RecordType			'A' `
		-ErrorAction		'SilentlyContinue'
	if ($null -eq $recordSets) {
		write-logFileWarning "No DNS Record found"
	}

	$rs = $recordSets | Where-Object Name -eq $storageAccountName
	if ($null -eq $rs) {
		write-logFileWarning "DNS Record '$storageAccountName' not found"
	}
	else {
		#--------------------------------------------------------------
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
			write-logFileWarning "DNS Record '$storageAccountName' deletion failed"
		}
	}

	$rs = $recordSets | Where-Object Name -ne $storageAccountName
	if ($null -ne $rs) {
		# other recordset found
		write-logFileWarning "Keeping DNS zone '$dnsZoneName'"
	}
	else {
		#--------------------------------------------------------------
		# remove ALL DNS links
		$dnsLinks = Get-AzPrivateDnsVirtualNetworkLink `
			-ResourceGroupName	$resourceGroupName `
			-ZoneName			$dnsZoneName `
			-ErrorAction		'SilentlyContinue'

		foreach ($name in $dnsLinks.Name) {
			Remove-AzPrivateDnsVirtualNetworkLink `
				-ResourceGroupName	$resourceGroupName `
				-ZoneName			$dnsZoneName `
				-Name				$name `
				-ErrorAction		'SilentlyContinue' | Out-Null
			if ($?) {
				write-logFileTab 'DNS link' $name 'deleted'
			}
			else {
				write-logFileWarning "Removing DNS link '$name' failed"
			}
		}

		#--------------------------------------------------------------
		# wait until DNS links have been deleted
		Start-Sleep -seconds 10

		#--------------------------------------------------------------
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
	}

	#--------------------------------------------------------------
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
		 $resourceGroupName		= $script:sourceRG
		,$subnetEndpoint		= $script:subnetEndpoint
		,$storageAccountName	= $script:sourceSA
		,$storageAccountSubId	= $script:sourceSubID
		,$storageAccountRG		= $script:sourceRG
		,$type                  = 'file'
		,[switch] $manualApproval
	)

	$endpointName 			= "$storageAccountName-$type"
	$privateLinkName		= "$storageAccountName-$type"
	$dnsLinkName			= "$storageAccountName-$type"
	$dnsZoneName			= "privatelink.$type.core.windows.net"
	$groupId				= $type
	$storageAccountId	= "/subscriptions/$storageAccountSubId/resourceGroups/$storageAccountRG/providers/Microsoft.Storage/storageAccounts/$storageAccountName"

	$vnetName, $subnetName = $subnetEndpoint -split '/'

	#--------------------------------------------------------------
	# get vnet
	$virtualNetwork = Get-AzVirtualNetwork `
						-ResourceGroupName	$resourceGroupName `
						-Name				$vnetName `
						-ErrorAction		'SilentlyContinue'
	test-cmdlet "'Get-AzVirtualNetwork' failed"

	# get subnet
	$subnet = $virtualNetwork
				| Select-Object -ExpandProperty Subnets
				| Where-Object Name -eq $subnetName
	if ($null -eq $subnet) {
		write-logFileError "Subnet '$subnetName' not found"
	}

	# check private endpoint network policies
	if ($subnet.PrivateEndpointNetworkPolicies -ne 'Disabled') {
		write-logFileError "Subnet '$subnetName' has enabled private endpoint network policies"
	}

	$location = $virtualNetwork.Location

	write-logFile
	write-logFile 'Create Private Endpoint'
	write-logFileTab 'Resource Group' $resourceGroupName

	# private endpoint
	$privateEndpoint = Get-AzPrivateEndpoint `
							-Name				$endpointName `
							-ResourceGroupName	$resourceGroupName `
							-ErrorAction		'SilentlyContinue'

	if ($Null -ne $privateEndpoint) {
		write-logFileTab 'private endpoint' $endpointName 'already exists'
	}
	else {
		write-logFileTab 'private endpoint' $endpointName 'creating...'
		# create private link
		$privateEndpointConnection = New-AzPrivateLinkServiceConnection `
										-Name					$privateLinkName `
										-PrivateLinkServiceId 	$storageAccountId `
										-GroupId 				$groupId `
										-ErrorAction			'SilentlyContinue'

		# create private endpoint
		$param = @{
			ResourceGroupName				= $resourceGroupName
			Name							= $endpointName
			Location						= $location
			Subnet							= $subnet
			PrivateLinkServiceConnection 	= $privateEndpointConnection
			ErrorAction						= 'SilentlyContinue'
		}

		if ($manualApproval) {
			$param.ByManualRequest = $true
		}

		$privateEndpoint = New-AzPrivateEndpoint @param				
		test-cmdlet "'New-AzPrivateEndpoint' failed"
	}

	#--------------------------------------------------------------
	if ($manualApproval) {
		set-context $sourceSub # *** CHANGE SUBSCRIPTION **************

		$connections = Get-AzPrivateEndpointConnection `
						-PrivateLinkResourceId	$storageAccountId `
						-ErrorAction			'SilentlyContinue'
		test-cmdlet "'Get-AzPrivateEndpointConnection' failed"

		$connections
		| Where-Object {$_.PrivateLinkServiceConnectionState.Status -eq 'Pending'}
		| ForEach-Object {

			Approve-AzPrivateEndpointConnection `
				-ResourceId		$_.Id `
				-Description	"Approved by RGCOPY" `
				-ErrorAction	'SilentlyContinue'
			test-cmdlet "'Approve-AzPrivateEndpointConnection' failed"
		}

		write-logFileTab 'private endpoint' $endpointName 'approved'

		set-context $targetSub # *** CHANGE SUBSCRIPTION **************
	}
	#--------------------------------------------------------------

	# DNS zone (shared between endpoints)
	$dnsZone = Get-AzPrivateDnsZone  `
					-ResourceGroupName	$resourceGroupName `
					-Name				$dnsZoneName `
					-ErrorAction		'SilentlyContinue'
	if ($Null -ne $dnsZone) {
		write-logFileTab 'DNS zone' $dnsZoneName 'already exists'
	}
	else {
		write-logFileTab 'DNS zone' $dnsZoneName 'creating...'
		# create DNS zone
		New-AzPrivateDnsZone `
			-ResourceGroupName	$resourceGroupName `
			-Name				$dnsZoneName `
			-ErrorAction		'SilentlyContinue' | Out-Null
		test-cmdlet "'New-AzPrivateDnsZone' failed"
	}


	# create DNS link (shared between endpoints)
	$dnsLinks = Get-AzPrivateDnsVirtualNetworkLink `
				-ResourceGroupName	$resourceGroupName `
				-ZoneName			$dnsZoneName `
				-ErrorAction		'SilentlyContinue'

	$dnsLink = $dnsLinks | Where-Object VirtualNetworkId -eq $virtualNetwork.Id

	if ($Null -ne $dnsLink) {
		write-logFileTab 'DNS link' $($dnsLink.Name) 'already exists'
	}
	else {
		write-logFileTab 'DNS link' $dnsLinkName 'creating...'

		New-AzPrivateDnsVirtualNetworkLink `
			-ResourceGroupName	$resourceGroupName `
			-ZoneName			$dnsZoneName `
			-Name				$dnsLinkName `
			-VirtualNetworkId	$virtualNetwork.Id `
			-ErrorAction		'SilentlyContinue' | Out-Null
		test-cmdlet "'New-AzPrivateDnsVirtualNetworkLink' failed"
	}


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
		write-logFileTab 'DNS Record' $storageAccountName 'creating...'

		# get endpoint IP
		$privateEndpointIP = $privateEndpoint `
							| Select-Object -ExpandProperty NetworkInterfaces `
							| Select-Object @{ Name = "NetworkInterfaces"; Expression = {
									Get-AzNetworkInterface `
										-ResourceId		$_.Id `
										-ErrorAction	'SilentlyContinue'
								}} `
							| Select-Object -ExpandProperty NetworkInterfaces `
							| Select-Object -ExpandProperty IpConfigurations `
							| Select-Object -ExpandProperty PrivateIpAddress
		test-cmdlet "'Get-AzNetworkInterface' failed"


		# create endpoint config
		$privateDnsRecordConfig = New-AzPrivateDnsRecordConfig `
									-IPv4Address	$privateEndpointIP `
									-ErrorAction	'SilentlyContinue'
		test-cmdlet "'New-AzPrivateDnsRecordConfig' failed"

		# create DNS record
		New-AzPrivateDnsRecordSet `
				-ResourceGroupName	$resourceGroupName `
				-Name				$storageAccountName `
				-RecordType			'A' `
				-ZoneName			$dnsZoneName `
				-Ttl				600 `
				-PrivateDnsRecords	$privateDnsRecordConfig `
				-ErrorAction 'SilentlyContinue' | Out-Null
		test-cmdlet "'New-AzPrivateDnsRecordSet' failed"
	}
}

#--------------------------------------------------------------
function new-resourceGroup {
#--------------------------------------------------------------
	$rgNeeded = $False

	# targetRG needed for deployment
	if (!$skipDeployment ) {
		$rgNeeded = $True
	}

	# targetRG needed for copy BLOBs/Snapshots
	if (($blobCopyNeeded -and !$skipRemoteCopy) `
	-or ($snapshotCopyNeeded -and !$skipRemoteCopy)) {
		$rgNeeded = $True
	}

	# targetRG needed for copy BLOBs/Snapshots/disks
	if (($justCopyBlobs.count -ne 0) `
	-or ($justCopySnapshots.count -ne 0) `
	-or ($justCopyDisks.count -ne 0)) {
		$rgNeeded = $True
	}

	if (!$rgNeeded -or $simulate) {
		return
	}

	#--------------------------------------------------------------
	write-stepStart "CREATE TARGET RG (AND SA)" -startMeasurement

	$currentRG = Get-AzResourceGroup `
					-Name 	$targetRG `
					-ErrorAction 'SilentlyContinue'

	# resource group already exists
	if ($?) {
		write-logFileTab 'Resource Group' $targetRG 'already exists'

		if (($currentRG.Location -ne $targetLocation) -and !$skipVmChecks) {
			write-logFileError "Resource Group '$targetRG' is not in region '$targetLocation'"
		}

		if ( !$allowExistingDisks `
		-and !$skipDeployment `
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

	# check if same disk does not already exists in target RG
	if ($justCopyDisks.count -ne 0) {
		test-disksTargetRG
	}
	
	# CREATE storage account
	if ($blobCopyNeeded) {
		write-logFile
		write-logFile 'Storage account for disk copy:' -ForegroundColor 'Green'
		new-storageAccount $targetSub $targetSubID $targetRG $targetSA $targetLocation
		if (!$skipRemoteCopy) {
			write-logFile 'Grant access:' -ForegroundColor 'Green'
			grant-saAccess4controlPlane 'blobCopy'
		}
	}

	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
function invoke-mountPoint {
#--------------------------------------------------------------
	param (
		$resourceGroup,
		$scriptVm,
		$scriptPath
	)

	# script parameters
	$parameter = @{
		ResourceGroupName 	= $resourceGroup
		VMName            	= $scriptVM
		CommandId         	= 'RunShellScript'
		scriptPath 			= $scriptPath
		ErrorAction			= 'SilentlyContinue'
	}

	# execute script
	Invoke-AzVMRunCommand @parameter
	| Tee-Object -Variable result
	| Out-Null

	# check results
	if ($result.Value[0].Message -like '*++ exit 1*') { 
		$status = 1
	}
	else {
		$status = 0
	}

	if ($status -eq 1) {
		write-logFileWarning $result.Value[0].Message
	}
	elseif ($verboseLog) {
		write-logFile        $result.Value[0].Message
	}

	return $status
}

#--------------------------------------------------------------
function wait-mountPoint {
#--------------------------------------------------------------
	param (
		$action
	)

	write-stepStart "$action JOBS COMPLETION" -startMeasurement

	write-logFile "Using credentials: $storageCredentialType"
	write-logFile

	# backup
	if ($action -eq 'backup') {
		if ($fileCopyVerify -eq 'compare') {
			$finishText = '>> Compare finished*'
		}
		elseif ($fileCopyVerify -eq'verify') {
			$finishText = '>> Verify finished*'
		}
		else {
			$finishText = '>> Backup finished*'
		}
	}

	# restore
	else {
		if ($fileCopyVerify -eq 'verify') {
			$finishText = '>> Verify finished*'
		}
		else {
			$finishText = '>> Restore finished*'
		}	
	}

	$script:waitCount = 0
	$allFiles = @()

	do {
		$done = $True

		foreach ($task in $script:runningTasks) {

			# get saved status
			$vmName 	= $task.vmName
			$mountpoint = $task.mountPoint
			$fileName 	= $task.logRemote
			$pathLocal 	= $task.logLocal
			$status		= $task.status

			# get status if not already finished
			if ($status -notlike $finishText) {
				# read file from VM
				$success = get-nfsFile $pathLocal $fileName "$vmName$mountpoint"	# $mountPoint starts with /
				$status = 'status unknown'
				if ($success) {
					if ($pathLocal -notin $script:logFiles) {
						$script:logFiles += $pathLocal
						$allFiles += $pathLocal
					}
					$text = $null
					$text = Get-Content -Path $pathLocal -ErrorAction 'SilentlyContinue'
					$lines = $text.count
					if ($lines -gt 0) {
						if ($lines -gt 10) {
							$lines = 10
						}
						for ($i = 1; $i -le $lines; $i++) {
							if ($text[-$i] -like ">*") {
								$status = $text[-$i]
								break
							}
						}
					}				
				}
				$task.status = $status
			}
			
			# display status
			$s1 = $vmName.PadRight(22).Substring(0,22)
			$s2 = $mountpoint.PadRight(20).Substring(0,20)

			# status: error
			if ($status -like '> ERROR*') {
				write-logFile "$s1 $s2 $status" -ForegroundColor 'red'
				$done = $true
				break
			}

			# status: finished
			elseif ($status -like $finishText) {
				write-logFile "$s1 $s2 $status" -ForegroundColor 'green'
				# $done not changed (dependent on other tasks)
			}

			# status: unknown
			elseif ($status -eq 'status unknown') {
				write-logFile "$s1 $s2 $status" -ForegroundColor 'red'
				$done = $false
			}

			# status: x%
			else {
				write-logFile "$s1 $s2 $status" -ForegroundColor 'yellow'
				$done = $false
			}
		}

		# at least one task still running
		if (!$done) { 
			get-waitTime
			write-logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz')   $action running   next wait time: $script:waitTime minutes" -ForegroundColor 'DarkGray'
			write-logFile
			if ($script:waitTime -eq 0) {
				Start-Sleep -seconds 10
			}
			else {
				Start-Sleep -seconds (60 * $script:waitTime)
			}
		}

	} while (!$done)
	write-logFile

	# all tasks done. Print log file
	$finishedAll = $true
	$returnCodeWrong = $false
	foreach ($file in $allFiles) {
		write-taskStart "Log file summary: $file"
		$text = $null
		$text = Get-Content -Path $file -ErrorAction 'SilentlyContinue'
		if (!$?) {
			write-logFileWarning "Could not read log file $file"
		}

		$finishedSingle = $false

		foreach ($line in $text) {
			if ($line -like '>>*') {
				write-logFile $line
			}

			if ($line -like '*return code:*') {
				if ($line -notlike '*return code: 0*') {
					$returnCodeWrong = $true
				}
			}

			if ($line -like $finishText) {
				$finishedSingle = $true
			}
		}

		if (!$finishedSingle) {
			$finishedAll = $false
		}
		write-logFile
	}

	# all tasks done. Print summary
	if ($returnCodeWrong) {
		write-stepEnd -endMeasurement
		write-logFileError "Error when running TAR: Return code is not 0"
	}

	elseif (!$finishedAll) {
		write-stepEnd -endMeasurement
		write-logFileError "At least one $action job failed"
	}

	else {
		write-logFile
		write-logFile "All $action jobs finished" -ForegroundColor Blue
		write-stepEnd -endMeasurement
	}
}

#--------------------------------------------------------------
function get-nfsFile {
#--------------------------------------------------------------
	param (
		 $pathLocal
		,$fileName			# 'backup.log'
		,$pathRemote		# 'martinme-anf1/hana/log'
		,$storageAccount 	= $sourceSA
		,$fileShare 		= $sourceSaShare
	)

	$token = $null
	if ($useAzureCLI) {
		try {
			$token = (az account get-access-token --resource https://storage.azure.com | ConvertFrom-Json).accessToken
		}
		catch {}
	}
	else {
		$token = get-azureToken -ResourceUrl "https://storage.azure.com"
	}

	if ($null -eq $token) {
		write-logFile "getting token of type $storageCredentialType failed"
		return $false
	}

	$uri = "https://$storageAccount.file.core.windows.net/$fileShare/$pathRemote/$fileName"
	$invokeParam = @{
		Uri				= $uri
		OutFile 		= $pathLocal
		Headers			= @{ 
			Authorization = "Bearer $token" 
			"x-ms-version" = '2025-05-05'
			"x-ms-file-request-intent" = "backup"

		}
		WarningAction 	= 'SilentlyContinue'
		ErrorAction		= 'Stop'
	}
	
	try {
		Invoke-WebRequest @invokeParam | Out-Null
		return $true
	}
	catch {
		# one re-try
		Start-Sleep -seconds 1
		try {
			Invoke-WebRequest @invokeParam | Out-Null
			return $true
		}
		catch {
			write-logFile "readding NFS file using Rest API and $storageCredentialType failed"
			if ($verboseLog) {
				write-logFile "`$uri = '$uri'"
				write-logFile "`$pathLocal = '$pathLocal'"
			}
			return $false
		}
	}
}

#--------------------------------------------------------------
function get-nfsSubnet {
#--------------------------------------------------------------
	$vnet = $null
	$subnet = $Null

	foreach ($net in $script:az_virtualNetworks) {
		foreach ($sub in $net.Subnets) {
			if ($sub.Delegations.count -eq 0) {
				if ($sub.Name -ne 'AzureBastionSubnet') {
					$vnet	= $net.Name
					$subnet = $sub.Name	
				}
			}
		}
	}
	
	return $vnet, $subnet
}

#--------------------------------------------------------------
function add-bashFile {
#--------------------------------------------------------------
	param (
		$file,
		[switch] $jobBegin,
		[switch] $jobBody,
		[switch] $jobEnd
	)

	if ($jobBegin -or $jobEnd) {
		# read file content line-by-line
		$array = Get-Content `
					-Path (Join-Path -Path $pwshPath -ChildPath $file) `
					-ErrorAction 'SilentlyContinue'
		test-cmdlet 'Get-Content'  "Reading file '$file' failed"

		$text = ''
		$found = $false
		foreach ($line in $array) {
			if ($line -like 'EOF_JOB*') {
				$found = $true
			}

			if ($jobBegin -and !$found) {
				$text += "$line`n"
			}

			if ($jobEnd -and $found) {
				$text += "$line`n"
			}
		}
	}
	
	else {
		# read file content complete
		$text = Get-Content `
				-Raw `
				-Path (Join-Path -Path $pwshPath -ChildPath $file) `
				-ErrorAction 'SilentlyContinue'
		test-cmdlet 'Get-Content'  "Reading file '$file' failed"
	}
	
	# general replacements (case sensitive)
	$text = $text `
		-creplace '\$BEGIN_FUNCTION_BACKUP',	'backup () {' `
		-creplace '\$BEGIN_FUNCTION_RESTORE',	'restore () {' `
		-creplace '\$END_FUNCTION',				'}'

	if ($jobBody) {
		# masking special characters not needed because using quoted 'heredoc'
		# $text = ($text 	-replace '\\', '\\' `
		# 					-replace '\$', '\$' `
		# 					-replace '`',  '\`' )

		# script files must not contain TEXT_EOF
		if ($text -match 'EOF_JOB') {
			write-logFileError "Invalid file $file`: 'EOF_JOB' not allowed"
		}
	}

	# add file content
	$script:bashFile +=  "$text`n"
}

#--------------------------------------------------------------
function backup-mountPoint {
#--------------------------------------------------------------
	$script:bashFile = ''
	add-bashFile 'bash\backup_header.sh'
	add-bashFile 'bash\mount-nfs.sh'
	add-bashFile 'bash\backup-loop.sh' -jobBegin
	# start backup job
		add-bashFile 'bash\backup-job.sh' -jobBody
	if ($fileCopyVerify -eq 'compare') {
		add-bashFile 'bash\compare-job.sh' -jobBody
	}
	if ($fileCopyVerify -eq 'verify') {
		add-bashFile 'bash\verify-job.sh' -jobBody
	}
	# end backup job
	add-bashFile 'bash\backup-loop.sh' -jobEnd

	$script:copyVMs.values
	| Where-Object {$_.MountPoints.count -ne 0}
	| Sort-Object Name
	| ForEach-Object {

		$vmName = $_.Name

		# create script text
		$scriptText = "$script:bashFile`n`nbackup $sourceSA $vmName $TAR_BLOCKSIZE_KB " + $_.MountPoints.Path
		$scriptPath = Join-Path $pathExportFolder -ChildPath "$logPrefixSource.backupMP.$vmName.txt"
		Write-Output $scriptText >$scriptPath
		$script:logFiles += $scriptPath

		# run shell script
		write-logFile
		write-taskStart "Backup volumes/disks of VM $vmName`:"
		wait-vmAgent $sourceRG $vmName

		$rc = invoke-mountPoint $sourceRG $vmName $scriptPath
		if ($rc -ne 0) {
			write-logFileError "Backup of mount points failed for resource group '$sourceRG'" `
								"File Backup failed in VM '$vmName'" `
								"Invoke-AzVMRunCommand failed"
		}

		write-logFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') -ForegroundColor 'DarkGray'
		foreach ($path in $_.MountPoints.Path) {
			write-logFile "Backup job started on VM $vmName for mount point $path" -ForegroundColor Blue
		}
	}
	write-stepEnd
}

#--------------------------------------------------------------
function restore-mountPoint {
#--------------------------------------------------------------
	$script:bashFile = ''
	add-bashFile 'bash\restore-header.sh'
	add-bashFile 'bash\mount-nfs.sh'
	if (!$continueRestore) {
		add-bashFile 'bash\format-disks.sh'
	}
	add-bashFile 'bash\restore-loop.sh' -jobBegin
	# start restore job
		add-bashFile 'bash\restore-job.sh' -jobBody
	if ($fileCopyVerify -eq 'verify') {
		add-bashFile 'bash\verify-job.sh' -jobBody
	}
	# end restore job
	add-bashFile 'bash\restore-loop.sh' -jobEnd

	# get volumes in target RG
	# ignore errors, because there might be no NetApp account in the target RG
	$volumes = Get-AzNetAppFilesVolume `
				-ResourceGroupName	$targetRG `
				-AccountName		$netAppAccountName `
				-PoolName			$netAppPoolName `
				-ErrorAction 		'SilentlyContinue'


	$script:copyVMs.values
	| Where-Object {$_.MountPoints.count -ne 0}
	| Sort-Object Name
	| ForEach-Object {

		$vmName = $_.Name

		$script = "restore $sourceSA $vmName $TAR_BLOCKSIZE_KB"

		foreach ($mp in $_.MountPoints) {
			$path 			= $mp.Path
			$lun 			= $mp.Lun
			$volumeName		= $mp.VolumeName

			# add parameter for disks
			if ($null -eq $volumeName) {
				$script += " $path null $lun"
			}

			# add parameter for volumes
			else {
				$ipAddress = $null
				foreach ($v in $volumes) {
					$x,$y,$z = $v.Name -split '/'
					if ($z -eq $volumeName) {
						$ipAddress = $v.MountTargets[0].IpAddress
						break
					}
				}

				if ($null -eq $ipAddress) {
					write-logFileError "Could not get IP address of NetApp volume $volumeName"
				}

				$nfs = "$ipAddress`:/$volumeName"
				$script += " $path $nfs -1"
			}	
		}

		# create script text
		$scriptText = "$script:bashFile`n`n$script"
		$scriptPath = Join-Path $pathExportFolder -ChildPath "$logPrefixTarget.restoreVm.$vmName.txt"
		Write-Output $scriptText >$scriptPath
		$script:logFiles += $scriptPath

		# run shell script
		write-logFile
		write-taskStart "Restore volumes/disks of VM $vmName`:"
		wait-vmAgent $targetRG $vmName

		$rc = invoke-mountPoint $targetRG $vmName $scriptPath
		if ($rc -ne 0) {
			write-logFileError "Mount point restore failed for resource group '$targetRG'" `
								"File restore failed in VM '$vmName'" `
								"Invoke-AzVMRunCommand failed"
		}

		write-logFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') -ForegroundColor 'DarkGray'
		foreach ($path in $_.MountPoints.Path) {
			write-logFile "Restore job started on VM $vmName for mount point $path" -ForegroundColor Blue
		}
	}
	write-stepEnd
}

#-------------------------------------------------------------
function get-subscriptionFeatures {
#-------------------------------------------------------------
	$script:tipEnabled = $False
	$script:ipTagEnabled = $False
	if ($msInternalVersion -ne $true) {
		return
	}

	if ('setIpTag' -notin $boundParameterNames) {
		$script:setIpTag = '/NonProd'
	}

	if (($setGroupTipSession.count -eq 0) -and ($setVmTipGroup.count -eq 0) -and ($setIpTag.length -eq 0)) {
		return
	}

	# try-catch around first Az cmdlet in this script
	# This will catch authentication issues
	try {
		$subProp = Get-AzProviderFeature -ListAvailable -ErrorAction 'Stop'
	}
	catch {
		test-cmdlet 'Get-AzProviderFeature'  'Getting subscription features failed' -always
	}


	# check TiP parameters
	$count= ($subProp
				| Where-Object FeatureName -in @('AvailabilitySetPinning', 'TiPNode')
				| Where-Object RegistrationState -eq 'Registered'
	).count

	if ($count -lt 2) {
		write-logFileWarning 'Target Subscription is not TiP enabled' -stopWhenForceVmChecks
	}
	else {
		$script:tipEnabled = $True
	}


	# check IP tag parameter
	$count= ($subProp
				| Where-Object FeatureName -in @('AllowBringYourOwnPublicIpAddress')
				| Where-Object RegistrationState -eq 'Registered'
	).count

	if ($count -lt 1) {
		write-logFileWarning 'Target Subscription is not enabled for IP tags' -stopWhenForceVmChecks
	}
	else {
		$script:ipTagEnabled = $True
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
		'useAzCopy'
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
		# 'pathExportFolder'
		# 'hostPlainText'
		# 'maxDOP'
# error handling		
		# 'forceVmChecks'
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
		# 'skipRemoteCopy'
		'skipDeployment'
			'skipRestore'
			'stopRestore'
			'continueRestore'
			'skipExtensions'
		'startWorkload'
		'stopVMsTargetRG'
		'deleteSnapshots'
		'deleteBackups'
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
		# 'allowExistingDisks'
# Update Mode
		'updateMode'
		'deleteSnapshotsAll'
		'createBastion'
		'deleteBastion'
# Patch Mode
		'patchMode'
		'patchVMs'
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
		'ignoreTags'
		# 'copyDetachedDisks'
		'jumpboxName'
		# 'defaultDiskZone'
		# 'defaultDiskName'
# BLOB copy
		# 'waitRemoteCopy'
		# 'justCopyBlobs'
		# 'justCopySnapshots'
		# 'justCopyDisks'
		'justStopCopyBlobs'
		# 'useBlobCopy'
		# 'useAzCopy'
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
		'subnetEndpoint'
		'subnetNetApp'
		'createDisksTier'
# get resources
		# 'allowRunningVMs'
# skip resources
		# 'skipVMs'
		# 'takeVMs'
		'skipSecurityRules'
		'keepTags'
		'skipVmssFlex'
		'skipAvailabilitySet'
		'skipProximityPlacementGroup'
		# 'skipBastion'		# needed for default parameter file
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
		# 'setDiskSku'		# needed for default parameter file
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
			'useAzCopy'
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
function test-waitRemoteCopy {
#--------------------------------------------------------------
	if (!$waitRemoteCopy) {
		return
	}

	# required steps:
	$script:skipSnapshots		= $True

	# forbidden parameters:
	write-logFileForbidden 'waitRemoteCopy' @(
		'skipRemoteCopy'
		'stopVMsSourceRG'
		'stopVMsTargetRG'
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
		$script:skipDeployment		= $True

		# forbidden parameters:
		write-logFileForbidden 'continueRestore' @(
			'stopRestore'
			'waitRemoteCopy'
			'justCopyBlobs'
			'justCopySnapshots'
			'justCopyDisks'
			'justStopCopyBlobs'
			)
	}
	# parameter stopRestore (skip everything after deployment)
	elseif ($stopRestore) {

		# forbidden parameters:
		write-logFileForbidden 'stopRestore' @(
			'continueRestore'
			'waitRemoteCopy'
			'justCopyBlobs'
			'justCopySnapshots'
			'justCopyDisks'
			'justStopCopyBlobs'
			'startWorkload'
			'deleteBackups'
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
# error handling		
		# 'forceVmChecks'
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
		  'skipRestore'
		    'stopRestore'
		    'continueRestore'
		  'skipExtensions'
		'startWorkload'
		'stopVMsTargetRG'
		# 'deleteSnapshots'
		'deleteBackups'
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
		# 'patchVMs'
		# 'patchAll'
		# 'prePatchCommand'
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
		'ignoreTags'
		'copyDetachedDisks'
		'jumpboxName'
		'defaultDiskZone'
		'defaultDiskName'
# BLOB copy
		'waitRemoteCopy'
		'justCopyBlobs'
		'justCopySnapshots'
		'justCopyDisks'
		'justStopCopyBlobs'
		# 'useBlobCopy'
		# 'useAzCopy'
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
		'subnetEndpoint'
		'subnetNetApp'
		'createDisksTier'
# get resources
		# 'allowRunningVMs'


# skip resources
		'skipVMs'
		'takeVMs'
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
# error handling		
		# 'forceVmChecks'
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
		  'skipRestore'
		    'stopRestore'
		    'continueRestore'
		  'skipExtensions'
		'startWorkload'
		'stopVMsTargetRG'
		# 'deleteSnapshots'
		'deleteBackups'
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
		# 'patchVMs'
		# 'patchAll'
		# 'prePatchCommand'
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
		'ignoreTags'
		'copyDetachedDisks'
		'jumpboxName'
		'defaultDiskZone'
		'defaultDiskName'
# BLOB copy
		'waitRemoteCopy'
		'justCopyBlobs'
		'justCopySnapshots'
		'justCopyDisks'
		'justStopCopyBlobs'
		'useBlobCopy'
		'useAzCopy'
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
		'subnetEndpoint'
		'subnetNetApp'
		'createDisksTier'
# get resources
		# 'allowRunningVMs'
# skip resources
		'skipVMs'
		'takeVMs'
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

	if ($targetSubInternal) {
		write-logFileError "Archive Mode not supported for MS internal subscriptions"
	}
	elseif ($msInternalVersion) {
		write-logFileError "Archive Mode not supported for MS internal verion of RGCPOPY"
	}
	else {
		write-logFileWarning "Archive Mode is a deprecated feature" `
							"It will not be available in future versions of RGCOPY"
	}

	if (('skipVMs' -notin $boundParameterNames) -and ('takeVMs' -notin $boundParameterNames)) {
		$script:copyDetachedDisks = $True
	}
	else {
		write-logFileWarning "parameters 'skipVMs' or 'takeVMs' are set" `
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
# error handling		
		# 'forceVmChecks'
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
		  'skipRestore'
		    'stopRestore'
		    'continueRestore'
		  'skipExtensions'
		'startWorkload'
		'stopVMsTargetRG'
		# 'deleteSnapshots'
		'deleteBackups'
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
		'ignoreTags'
		# 'copyDetachedDisks'
		'jumpboxName'
		'defaultDiskZone'
		'defaultDiskName'
# BLOB copy
		# 'waitRemoteCopy'
		# 'justCopyBlobs'
		'justCopySnapshots'
		'justCopyDisks'
		# 'justStopCopyBlobs'
		'useBlobCopy'
		'useAzCopy'
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
		'subnetEndpoint'
		'subnetNetApp'
		'createDisksTier'
# get resources
		# 'allowRunningVMs'
# skip resources
		# 'skipVMs'
		# 'takeVMs'
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

	write-logFileWarning "Update Mode is a deprecated feature" `
						"It will not be available in future versions of RGCOPY"

	$forbidden = @(
# general parameters
		# 'simulate'
		'pathExportFolder'
		# 'hostPlainText'
		'maxDOP'
# error handling		
		# 'forceVmChecks'
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
		  'skipRestore'
		    'stopRestore'
		    'continueRestore'
		  'skipExtensions'
		'startWorkload'
		'stopVMsTargetRG'
		# 'deleteSnapshots'
		'deleteBackups'
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
		'ignoreTags'
		'copyDetachedDisks'
		'jumpboxName'
		'defaultDiskZone'
		'defaultDiskName'
# BLOB copy
		'waitRemoteCopy'
		'justCopyBlobs'
		'justCopySnapshots'
		'justCopyDisks'
		'justStopCopyBlobs'
		'useBlobCopy'
		'useAzCopy'
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
		# 'subnetEndpoint'
		# 'subnetNetApp'
		'createDisksTier'
# get resources
		'allowRunningVMs'
# skip resources
		'skipVMs'
		'takeVMs'
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
# error handling		
		'forceVmChecks'
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
		'skipRestore'
		'stopRestore'
		'continueRestore'
		# 'skipExtensions'
		'startWorkload'
		'stopVMsTargetRG'
		'deleteSnapshots'
		'deleteBackups'
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
		'ignoreTags'
		'copyDetachedDisks'
		'jumpboxName'
		'defaultDiskZone'
		'defaultDiskName'
# BLOB copy
		'waitRemoteCopy'
		'justCopyBlobs'
		'justCopySnapshots'
		'justCopyDisks'
		'justStopCopyBlobs'
		'useBlobCopy'
		'useAzCopy'
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
		'subnetEndpoint'
		'subnetNetApp'
		'createDisksTier'
# get resources
		'allowRunningVMs'
# skip resources
		# 'skipVMs'
		# 'takeVMs'
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
# error handling		
		# 'forceVmChecks'
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
		#   'skipRestore'
		    # 'stopRestore'
		    # 'continueRestore'
		#   'skipExtensions'
		# 'startWorkload'
		# 'stopVMsTargetRG'
		# 'deleteSnapshots'
		# 'deleteBackups'
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
		# 'patchVMs'
		# 'patchAll'
		# 'prePatchCommand'
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
		# 'ignoreTags'
		# 'copyDetachedDisks'
		# 'jumpboxName'
		# 'defaultDiskZone'
		# 'defaultDiskName'
# BLOB copy
		# 'waitRemoteCopy'
		# 'justCopyBlobs'
		# 'justCopySnapshots'
		# 'justCopyDisks'
		# 'justStopCopyBlobs'
		# 'useBlobCopy'
		# 'useAzCopy'
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
		# 'subnetEndpoint'
		# 'subnetNetApp'
		# 'createDisksTier'
# get resources
		# 'allowRunningVMs'
# skip resources
		# 'skipVMs'
		# 'takeVMs'
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

		$script:bastionVnet, $subnetName, $script:bastionAddressPrefix = test-subnet 'createBastion' $createBastion $null 'AzureBastionSubnet' -create
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
		$newAcc = $script:copyNics[$nicName].EnableAcceleratedNetworking
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
# resources that are skipped when not referenced by other resources
$script:types2Filter = @(
	'publicIPPrefixes'
	'publicIPAddresses'
	'networkSecurityGroups'
	'applicationSecurityGroups'
)
# DO NOT FILTER RESOURCE TYPES THAT HAVE SUB-RESOURCES
# (code does not take care of this)
#--------------------------------------------------------------
function save-az_all {
#--------------------------------------------------------------
	param (
		[ref] $ref, # reference to resources, e.g. [ref] $script:az_networkInterfaces
		[switch] $noCount
	)

	$resources = @()
	foreach ($res in $ref.Value) {
		$type = ($res.type -split '/')[1]
		$name = $res.name

		# resource type not filtered
		if ($type -notin $script:types2Filter) {
			$resources += $res
		}

		# resource referenced
		elseif ($script:referencedResources["$type`_$name"] -eq $true) {
			$resources += $res
		}

		# resource not referenced
		else {
			if ($keepUnusedResources) {
				write-logFileWarning "Copied $type '$name' not used"
				$resources += $res
			}
			else {
				write-logFileWarning "Skip unused $type '$name'"
			}
		}
	}

	# remove unused resources from $script:az_xxx
	$ref.Value = $resources
	# save used resources in $script:az_all 
	$script:az_all += $resources

	if (!$noCount) {
		write-logFile "$($resources.count) found" -ForegroundColor 'DarkGray'
		write-logFile
	}
}

#--------------------------------------------------------------
function get-az_all {
#--------------------------------------------------------------
	param (
		[switch] $vmsOnly
	)

	$script:az_all = @()
	$script:azResults = @{}
	$script:referencedResources = @{}

	# snapshots (save snapshot names, only from source RG)
	write-logFile "Reading snapshots (RG $sourceRG)..."
	save-az_all ([ref] $script:sourceSnapshots)

	get-az_virtualMachines
	# after az_virtualMachines
	get-az_disks

	if (!$cloneOrMergeMode) {
		if ($script:copySA.Count -gt 0) {
			get-az_storageAccounts
		}
		get-az_privateEndpoints
		get-az_loadBalancers
	}
	
	# after: az_privateEndpoints
	# after: az_virtualMachines
	# after: az_loadBalancers
	get-az_networkInterfaces

	if (!$cloneOrMergeMode) {
		get-az_bastionHosts

		if ($copyDNS) {
			get-az_dnsZones
		}
		# after: az_privateEndpoints
		get-az_privateDnsZones
	}

	# after: az_networkInterfaces
	# after: az_loadBalancers
	# after: az_bastionHosts
	# after: az_dnsZones
	# after: az_privateDnsZones
	# after: az_privateEndpoints
	get-az_virtualNetworks

	if (!$cloneOrMergeMode) {
		# after:virtualNetworks
		get-az_natGateways

		# after:virtualNetworks
		get-az_routeTables
	}

	# after: az_networkInterfaces
	# after: az_natGateways
	# after: az_dnsZones
	# after: az_loadBalancers
	# after: az_bastionHosts
	get-az_publicIPAddresses

	# after: az_natGateways
	# after: az_dnsZones
	# after: az_loadBalancers
	# after: az_publicIPAddresses
	get-az_publicIPPrefixes

	if (!$cloneOrMergeMode) {
		# after: az_virtualNetworks
		# after: az_networkInterfaces
		get-az_networkSecurityGroups

		# after: az_networkSecurityGroups
		# after: az_privateEndpoints
		get-az_applicationSecurityGroups

		# after: az_virtualMachines
		get-az_availabilitySets

		# after: az_virtualMachines
		# after: az_availabilitySets
		get-az_proximityPlacementGroups

		# after: az_virtualMachines
		get-az_virtualMachineScaleSets
	}

	# create JSON
	write-logFile
	$text = $script:az_all | ConvertTo-Json -Depth 5 -WarningAction 'SilentlyContinue'
	Set-Content -Path $importPath -Value $text -ErrorAction 'SilentlyContinue'
	if (!$?) {
		write-logFileError "Could not save az json file" `
								"Failed writing file '$importPath'"
	}
	write-logFile -ForegroundColor 'Cyan' "Source az json file saved: $importPath"
	$script:logFiles += $importPath
	write-logFile
}

#--------------------------------------------------------------
function get-az_remote {
#--------------------------------------------------------------
	param (
		$id # MAIN-resource or SUB-resource (but always use MAIN-resource)
	)

	# nothing to do
	if ($Null -eq $id) {
		return
	}

	# parse Id (always get MAIN-resource, not SUB-resource)
	$r = get-resourceComponents $id
	$subscriptionID = $r.subscriptionID
	$rgName			= $r.resourceGroup
	$resourceArea	= $r.resourceArea
	$type			= $r.mainResourceType
	$name			= $r.mainResourceName

	$script:referencedResources["$type`_$name"] = $true
	
	$mainResourceId = (get-resourceString `
								$subscriptionID  $rgName `
								$resourceArea `
								$type  $name)

	switch ($type) {
		'networkInterfaces'			{ $ref = [ref] $script:az_networkInterfaces }
		'publicIPPrefixes'			{ $ref = [ref] $script:az_publicIPPrefixes }
		'virtualNetworks'			{ $ref = [ref] $script:az_virtualNetworks }
		'publicIPAddresses'			{ $ref = [ref] $script:az_publicIPAddresses }
		'networkSecurityGroups'		{ $ref = [ref] $script:az_networkSecurityGroups }
		'applicationSecurityGroups'	{ $ref = [ref] $script:az_applicationSecurityGroups }
		'natGateways'				{ $ref = [ref] $script:az_natGateways }
		'availabilitySets'			{ $ref = [ref] $script:az_availabilitySets }
		'proximityPlacementGroups'	{ $ref = [ref] $script:az_proximityPlacementGroups }
		'virtualMachineScaleSets'	{ $ref = [ref] $script:az_virtualMachineScaleSets }
		'privateDnsZones'			{ $ref = [ref] $script:az_privateDnsZones }
		'dnsZones'					{ $ref = [ref] $script:az_dnsZones }
		'routeTables'				{ $ref = [ref] $script:az_routeTables }
		Default	{ 
			write-logFileWarning "Reference to $type not processed"
			return
		}
	}

	# no resources from different subscriptions allowed
	if ($subscriptionID -ne $sourceSubID) {
		write-logFileError "Resource '$name' of type '$type' is in wrong subscription" `
							"Subscription ID is $subscriptionID" `
							"Subscription ID of source RG is $sourceSubID"
	}

	# resource is in same resource group: nothing to do
	if ($rgName -eq $sourceRG) {
		return
	}

	# check if same name already used in other RG
	$resource = $ref.Value | Where-Object {($_.Name -eq $name) -and ($_.ResourceGroupName -ne $rgName)}
	if ($Null -ne $resource) {
		write-logFileError "Resource type '$type' exists in two RGs using the same name: '$name'" `
							"RG1: $rgName" `
							"RG2: $($resource.ResourceGroupName)"
	}

	# check if remote resource already saved
	$resource = $ref.Value | Where-Object {($_.Name -eq $name) -and ($_.ResourceGroupName -eq $rgName)}
	if ($Null -ne $resource) {
		return
	}

	# all az-cmdlets below have parameter 'resourceGroupName'
	# not all of them have parameter 'ResourceId'
	$param = @{
		ResourceGroupName 	= $rgName
		WarningAction		= 'SilentlyContinue'
		ErrorAction 		= 'SilentlyContinue'
	}

	# check if resource group has not already been read
	if ($null -eq $script:azResults["$type_$rgName"]) {

		# read all resources (of same type) from remote RG at the same time
		write-logFileWarning "Reading $type '$name' from resource group '$rgName'..."

		switch ($type) {
			'networkInterfaces'			{ $script:azResults["$type_$rgName"] = Get-AzNetworkInterface @param }
			'publicIPPrefixes'			{ $script:azResults["$type_$rgName"] = Get-AzPublicIpPrefix @param }
			'virtualNetworks'			{ $script:azResults["$type_$rgName"] = Get-AzVirtualNetwork @param }
			'publicIPAddresses'			{ $script:azResults["$type_$rgName"] = Get-AzPublicIPAddress @param }
			'networkSecurityGroups'		{ $script:azResults["$type_$rgName"] = Get-AzNetworkSecurityGroup @param }
			'applicationSecurityGroups'	{ $script:azResults["$type_$rgName"] = Get-AzApplicationSecurityGroup @param }
			'natGateways'				{ $script:azResults["$type_$rgName"] = Get-AzNatGateway @param }
			'availabilitySets'			{ $script:azResults["$type_$rgName"] = Get-AzAvailabilitySet @param }
			'proximityPlacementGroups'	{ $script:azResults["$type_$rgName"] = Get-AzProximityPlacementGroup @param }
			'virtualMachineScaleSets'	{ $script:azResults["$type_$rgName"] = Get-AzVmss @param }
			'privateDnsZones'			{ $script:azResults["$type_$rgName"] = Get-AzPrivateDnsZone @param }
			'dnsZones'					{ $script:azResults["$type_$rgName"] = Get-AzDnsZone @param }
			'routeTables'				{ $script:azResults["$type_$rgName"] = Get-AzRouteTable @param }
			Default { 
				write-logFileError 'Internal error' 
			}
		}
		test-cmdlet 'Get-Az*' "Could not get $type '$name' of resource group '$rgName'"
	}

	# add remote resource
	$itemFound = $false
	foreach ($item in $script:azResults["$type_$rgName"]) {
		if ($item.Id -eq $mainResourceId) {
			$ref.Value += $item
			$itemFound = $true
		}
	}

	if (!$itemFound) {
		write-logFileWarning "Referenced Resource not found: $mainResourceId"
	}
}

#--------------------------------------------------------------
function get-az_virtualMachines {
#--------------------------------------------------------------
	write-logFile "Reading VMs (RG $sourceRG)..."

	$script:az_virtualMachines = @( 
		Get-AzVM `
			-ResourceGroupName $sourceRG `
			-WarningAction	'SilentlyContinue' `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzVM'  "Could not get VMs of resource group '$sourceRG'"

	save-az_all ([ref] $script:az_virtualMachines)
}

#--------------------------------------------------------------
function get-az_disks {
#--------------------------------------------------------------
	write-logFile "Reading disks (RG $sourceRG)..."

	# disks have already been read
	$script:az_disks = $script:sourceDisks

	foreach ($vm in $script:az_virtualMachines) {
		# make sure that all VM disks are in source RG
		test-az_local $vm.StorageProfile.OsDisk.ManagedDisk.Id
		foreach ($disk in $vm.StorageProfile.DataDisks) {
			# make sure that all VM disks are in source RG
			test-az_local $disk.Id
		}
	}

	save-az_all ([ref] $script:sourceDisks)
}

#--------------------------------------------------------------
function get-az_networkInterfaces {
#--------------------------------------------------------------
	write-logFile "Reading NICs (RG $sourceRG)..." -NoNewLine

	$script:az_networkInterfaces = @( 
		Get-AzNetworkInterface `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzNetworkInterface'  "Could not get NICs of resource group '$sourceRG'"

	# get NICs from other RGs
	write-logFile "Reading NICs (other RGs) referenced by VMs..."
	foreach ($vm in $script:az_virtualMachines) { 
		foreach ($nic in $vm.NetworkProfile.NetworkInterfaces) {
			get-az_remote $nic.Id
		}
	}

	write-logFile "Reading NICs (other RGs) referenced by Private Endpoints..."
	foreach ($ep in $script:az_privateEndpoints) {
		foreach ($id in $ep.NetworkInterfaces.Id) {
			get-az_remote $id
		}
	}

	write-logFile "Reading NICs (other RGs) referenced by Load Balancers..."
	foreach ($lb in $script:az_loadBalancers) { 
		foreach ($pool in $lb.BackendAddressPools) {
			foreach ($addr in $pool.LoadBalancerBackendAddresses) {
				get-az_remote $addr.NetworkInterfaceIpConfiguration.Id
			}
		}
	}

	save-az_all ([ref] $script:az_networkInterfaces)
}

#--------------------------------------------------------------
function get-az_loadBalancers {
#--------------------------------------------------------------
	write-logFile "Reading loadBalancers (RG $sourceRG)..."

	$script:az_loadBalancers = @( 
		Get-AzLoadBalancer `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzLoadBalancer'  "Could not get loadBalancers of resource group $sourceRG"

	save-az_all ([ref] $script:az_loadBalancers)
}

#--------------------------------------------------------------
function get-az_bastionHosts {
#--------------------------------------------------------------
	write-logFile "Reading Bastions (RG $sourceRG)..."

	$script:az_bastionHosts = @( 
		Get-AzBastion `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzBastion'  "Could not get Bastions of resource group $sourceRG"

	save-az_all ([ref] $script:az_bastionHosts)
}

#--------------------------------------------------------------
function get-az_dnsZones {
#--------------------------------------------------------------
	write-logFile "Reading DNS Zones (RG $sourceRG)..."

	$script:az_dnsZones = @( 
		Get-AzDnsZone `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzDnsZone'  "Could not get DNS Zones of resource group $sourceRG"

	#--------------------------------------------------------------
	$script:az_dnsRecordSets = @()
	foreach ($dnsZone in $script:az_dnsZones) {
		$zoneName = $dnsZone.Name
		$script:az_dnsRecordSets += `
			Get-AzDnsRecordSet `
				-Zone $dnsZone `
				-ErrorAction 'SilentlyContinue'
		test-cmdlet 'Get-AzDnsRecordSet'  "Could not get Record Set of DNS zone '$zoneName'"
	}

	save-az_all ([ref] $script:az_dnsZones)
	save-az_all ([ref] $script:az_dnsRecordSets) -noCount
}

#--------------------------------------------------------------
function get-az_privateDnsZones {
#--------------------------------------------------------------
	write-logFile "Reading Private DNS Zones (RG $sourceRG)..."

	$script:az_privateDnsZones = @( 
		Get-AzPrivateDnsZone `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzPrivateDnsZone'  "Could not get Private DNS Zones of resource group $sourceRG"

	# get DNS zones from other RGs
	write-logFile "Reading Private DNS Zones (other RGs) referenced by Private Endpoints..."
	foreach ($zg in $script:az_privateDnsZoneGroups) {
			get-az_remote $zg.PrivateDnsZoneId
	}

	#--------------------------------------------------------------
	$script:az_privateDnsVirtualNetworkLinks = @()
	foreach ($dnsZone in $script:az_privateDnsZones) {
		$zoneName = $dnsZone.Name
		$script:az_privateDnsVirtualNetworkLinks += `
			Get-AzPrivateDnsVirtualNetworkLink `
				-ResourceGroupName $sourceRG `
				-ZoneName $zoneName `
				-ErrorAction 'SilentlyContinue'
		test-cmdlet 'Get-AzPrivateDnsVirtualNetworkLink'  "Could not get Virtual Network Link of Private DNS zone '$zoneName'"
	}

	#--------------------------------------------------------------
	$script:az_privateDnsRecordSets = @()
	foreach ($dnsZone in $script:az_privateDnsZones) {
		$zoneName = $dnsZone.Name
		$script:az_privateDnsRecordSets += `
			Get-AzPrivateDnsRecordSet `
				-Zone $dnsZone `
				-ErrorAction 'SilentlyContinue'
		test-cmdlet 'Get-AzPrivateDnsRecordSet'  "Could not get Record Set of Private DNS zone '$zoneName'"
		
	}

	save-az_all ([ref] $script:az_privateDnsZones)
	save-az_all ([ref] $script:az_privateDnsVirtualNetworkLinks) -noCount
	save-az_all ([ref] $script:az_privateDnsRecordSets) -noCount
}

#--------------------------------------------------------------
function get-az_virtualNetworks {
#--------------------------------------------------------------
	write-logFile "Reading VNETs (RG $sourceRG)..."

	$script:az_virtualNetworks = @( 
		Get-AzVirtualNetwork `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzVirtualNetwork'  "Could not get VNETs of resource group $sourceRG"

	# get VNETs from other RGs
	write-logFile "Reading VNETs (other RGs) referenced by NICs..."
	foreach ($nic in $script:az_networkInterfaces) { 
		foreach ($conf in $nic.IpConfigurations) {
			get-az_remote $conf.Subnet.Id
		}
	}

	write-logFile "Reading VNETs (other RGs) referenced by Load Balancers..."
	foreach ($lb in $script:az_loadBalancers) { 
		foreach ($conf in $lb.FrontendIpConfigurations) {
			get-az_remote $conf.Subnet.Id
		}
		foreach ($pool in $lb.BackendAddressPools) {
			foreach ($addr in $pool.LoadBalancerBackendAddresses) {
				get-az_remote $addr.VirtualNetwork.Id
			}
		}
	}

	write-logFile "Reading VNETs (other RGs) referenced by Bastions..."
	foreach ($bastion in $script:az_bastionHosts) { 
		foreach ($conf in $bastion.IpConfigurations) {
			get-az_remote $conf.Subnet.Id
		}
	}
	
	if ($copyDNS) {
		write-logFile "Reading VNETs (other RGs) referenced by DNS Zones..."
		foreach ($zone in $script:az_dnsZones) { 
			foreach ($id in $zone.RegistrationVirtualNetworkIds) {
				get-az_remote $id
			}
			foreach ($id in $zone.ResolutionVirtualNetworkIds) {
				get-az_remote $id
			}
		}
	}

	write-logFile "Reading VNETs (other RGs) referenced by Private DNS Zones..."
	foreach ($zone in $script:az_privateDnsZones) { 
		get-az_remote $zone.VirtualNetworkId
	}

	write-logFile "Reading VNETs (other RGs) referenced by Private Endpoints..."
	foreach ($ep in $script:az_privateEndpoints) { 
		get-az_remote $ep.Subnet.Id
	}

	save-az_all ([ref] $script:az_virtualNetworks)
}

#--------------------------------------------------------------
function get-az_natGateways {
#--------------------------------------------------------------
	write-logFile "Reading NAT Gateways (RG $sourceRG)..."

	$script:az_natGateways = @( 
		Get-AzNatGateway `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzNatGateway'  "Could not get Gateways of resource group $sourceRG"

	write-logFile "Reading NAT Gateways (other RGs) referenced by VNETs..."
	foreach ($net in $script:az_virtualNetworks) {
		foreach ($subnet in $net.subnets) {
			get-az_remote $subnet.NatGateway.Id
		}
	}

	save-az_all ([ref] $script:az_natGateways)
}

#--------------------------------------------------------------
function get-az_routeTables {
#--------------------------------------------------------------
	write-logFile "Reading Route Tables (RG $sourceRG)..."

	$script:az_routeTables = @( 
		Get-AzRouteTable `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzRouteTable'  "Could not get Route Tables of resource group $sourceRG"

	write-logFile "Reading Route Tables (other RGs) referenced by VNETs..."
	foreach ($net in $script:az_virtualNetworks) {
		foreach ($subnet in $net.subnets) {
			get-az_remote $subnet.RouteTable.Id
		}
	}

	save-az_all ([ref] $script:az_routeTables)
}

#--------------------------------------------------------------
function get-az_publicIPPrefixes{
#--------------------------------------------------------------
	write-logFile "Reading Public IP Prefixes (RG $sourceRG)..."

	$script:az_publicIPPrefixes = @( 
		Get-AzPublicIpPrefix `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzPublicIpPrefix'  "Could not get Public IP Prefixes of resource group $sourceRG"

	write-logFile "Reading Public IP Prefixes (other RGs) referenced by NAT Gateways..."
	foreach ($gateway in $script:az_natGateways) { 
		foreach ($prefix in $gateway.PublicIpPrefixes) {
			get-az_remote $prefix.Id
		}
		foreach ($prefix in $gateway.PublicIpPrefixesV6) {
			get-az_remote $prefix.Id
		}
	}

	write-logFile "Reading Public IP Prefixes (other RGs) referenced by DNS entries..."
	foreach ($rec in $script:az_dnsRecordSets) { 
		get-az_remote $rec.TargetResourceId
	}

	write-logFile "Reading Public IP Prefixes (other RGs) referenced by Load Balancers..."
	foreach ($lb in $script:az_loadBalancers) { 
		foreach ($conf in $lb.FrontendIpConfigurations) {
			get-az_remote  $conf.PublicIPPrefix.Id
		}
	}

	write-logFile "Reading Public IP Prefixes (other RGs) referenced by Public IP Addresses..."
	foreach ($ip in $script:az_publicIPAddresses) { 
		get-az_remote $ip.PublicIpPrefix.Id
	}

	save-az_all ([ref] $script:az_publicIPPrefixes)
}

#--------------------------------------------------------------
function get-az_publicIPAddresses {
#--------------------------------------------------------------
	write-logFile "Reading Public IPs (RG $sourceRG)..."

	$script:az_publicIPAddresses = @( 
		Get-AzPublicIPAddress `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzPublicIPAddress'  "Could not get Public IP Addresses of resource group $sourceRG"

	# get PublicIPs from other RGs
	write-logFile "Reading Public IPs (other RGs) referenced by NICs..."
	foreach ($nic in $script:az_networkInterfaces) { 
		foreach ($conf in $nic.IpConfigurations) {
			get-az_remote $conf.PublicIpAddress.Id
		}
	}

	write-logFile "Reading Public IPs (other RGs) referenced by NAT Gateways..."
	foreach ($gateway in $script:az_natGateways) { 
		foreach ($ip in $gateway.PublicIpAddresses) {
			get-az_remote $ip.Id
		}
		foreach ($ip in $gateway.PublicIpAddressesV6) {
			get-az_remote $ip.Id
		}
	}

	write-logFile "Reading Public IPs (other RGs) referenced by DNS entries..."
	foreach ($rec in $script:az_dnsRecordSets) { 
		get-az_remote $rec.TargetResourceId
	}

	write-logFile "Reading Public IPs (other RGs) referenced by Load Balancers..."
	foreach ($lb in $script:az_loadBalancers) { 
		foreach ($conf in $lb.FrontendIpConfigurations) {
			get-az_remote $conf.PublicIpAddress.Id
		}
	}

		write-logFile "Reading Public IPs (other RGs) referenced by Bastions..."
	foreach ($bastion in $script:az_bastionHosts) { 
		foreach ($conf in $bastion.IpConfigurations) {
			get-az_remote $conf.PublicIpAddress.Id
		}
	}

	save-az_all ([ref] $script:az_publicIPAddresses)
}

#--------------------------------------------------------------
function get-az_networkSecurityGroups {
#--------------------------------------------------------------
	write-logFile "Reading NSGs (RG $sourceRG)..."

	$script:az_networkSecurityGroups = @( 
		Get-AzNetworkSecurityGroup `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzNetworkSecurityGroup'  "Could not get NSGs of resource group $sourceRG"

	# get NSGs from other RGs
	write-logFile "Reading NSGs (other RGs) referenced by VNETs..."
	foreach ($net in $script:az_virtualNetworks) {
		foreach ($subnet in $net.subnets) {
			get-az_remote $subnet.NetworkSecurityGroup.Id
		}
	}

	write-logFile "Reading NSGs (other RGs) referenced by NICs..."
	foreach ($nic in $script:az_networkInterfaces) {
		get-az_remote $nic.NetworkSecurityGroup.Id
	}

	save-az_all ([ref] $script:az_networkSecurityGroups)
}

#--------------------------------------------------------------
function get-az_applicationSecurityGroups {
#--------------------------------------------------------------
	write-logFile "Reading ASGs (RG $sourceRG)..."

	$script:az_applicationSecurityGroups = @( 
		Get-AzApplicationSecurityGroup `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzApplicationSecurityGroup'  "Could not get ASGs of resource group $sourceRG"

	# get ASGs from other RGs
	write-logFile "Reading ASGs (other RGs) referenced by NSGs..."
	foreach ($nsg in $script:az_networkSecurityGroups) {
		foreach ($rule in $nsg.SecurityRules) {
			foreach ($asg in $rule.SourceApplicationSecurityGroups) {
				get-az_remote $asg.Id
			}
			foreach ($asg in $rule.DestinationApplicationSecurityGroups) {
				get-az_remote $asg.Id
			}
		}
	}

	write-logFile "Reading ASGs (other RGs) referenced by NICs..."
	foreach ($nic in $script:az_networkInterfaces) {
		foreach ($conf in $nic.IpConfigurations) {
			foreach ($asg in $conf.ApplicationSecurityGroups) {
				get-az_remote $asg.Id
			}
		}
	}

	write-logFile "Reading ASGs (other RGs) referenced by PrivateEndpoints..."
	foreach ($ep in $script:az_privateEndpoints) {
		foreach ($asg in $ep.ApplicationSecurityGroups) {
			get-az_remote $asg.Id
		}
	}

	save-az_all ([ref] $script:az_applicationSecurityGroups)
}

#--------------------------------------------------------------
function get-az_availabilitySets {
#--------------------------------------------------------------
	write-logFile "Reading Availability Sets (RG $sourceRG)..."

	$script:az_availabilitySets = @( 
		Get-AzAvailabilitySet `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzAvailabilitySet'  "Could not get Availability Sets of resource group $sourceRG"

	write-logFile "Reading Availability Sets (other RGs) referenced by VMs..."
	foreach ($vm in $script:az_virtualMachines) { 
		get-az_remote $vm.AvailabilitySetReference.Id
	}

	save-az_all ([ref] $script:az_availabilitySets)
}

#--------------------------------------------------------------
function get-az_proximityPlacementGroups {
#--------------------------------------------------------------
	write-logFile "Reading PPGs (RG $sourceRG)..."

	$script:az_proximityPlacementGroups = @( 
		Get-AzProximityPlacementGroup `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzProximityPlacementGroup'  "Could not get PPG of resource group $sourceRG"

	write-logFile "Reading PPGs (other RGs) referenced by VMs..."
	foreach ($vm in $script:az_virtualMachines) { 
		get-az_remote $vm.ProximityPlacementGroup.Id
	}

	write-logFile "Reading PPGs (other RGs) referenced by Availability Sets..."
	foreach ($avset in $script:az_availabilitySets) { 
		get-az_remote $avset.ProximityPlacementGroup.Id
	}

	save-az_all ([ref] $script:az_proximityPlacementGroups)
}

#--------------------------------------------------------------
function get-az_virtualMachineScaleSets {
#--------------------------------------------------------------
	write-logFile "Reading VMSS (RG $sourceRG)..."

	$script:az_virtualMachineScaleSets = @( 
		Get-AzVmss `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue' `
			-WarningAction 'SilentlyContinue'
	)
	test-cmdlet 'az_virtualMachineScaleSets'  "Could not get VMSS of resource group $sourceRG"

	write-logFile "Reading VMSS (other RGs) referenced by VMs..."
	foreach ($vm in $script:az_virtualMachines) { 
		get-az_remote $vm.VirtualMachineScaleSet.Id
	}

	save-az_all ([ref] $script:az_virtualMachineScaleSets)
}

#--------------------------------------------------------------
function get-az_storageAccounts {
#--------------------------------------------------------------
	$script:az_storageAccounts = @()
	$script:az_storageAccountsFileService = @()
	$script:az_storageAccountsBlobService = @()
	$script:az_storageContainers = @()
	$script:az_storageShares = @()

	write-logFile "Reading Storage Accounts (RG $sourceRG)..."

	$storageAccounts = Get-AzStorageAccount `
						-ResourceGroupName $sourceRG `
						-ErrorAction 'SilentlyContinue' `
						-WarningAction 'SilentlyContinue'
	test-cmdlet 'Get-AzStorageAccount'  "Could not get Storage Accounts of resource group $sourceRG"

	foreach ($sa in $storageAccounts) {
		$sa = convertFrom-json (convertTo-json $sa -Depth 5 -EnumsAsStrings -WarningAction 'SilentlyContinue') -AsHashtable
		$sa.Context = $null
		$script:az_storageAccounts += $sa
	}

	foreach ($az_res in $script:az_storageAccounts) {
		$name = $az_res.StorageAccountName

		#--------------------------------------------------------------
		# get file storage properties
		$fileServices = Get-AzStorageFileServiceProperty `
							-ResourceGroupName $sourceRG `
							-StorageAccountName $name `
							-ErrorAction 'SilentlyContinue' `
							-WarningAction 'SilentlyContinue'
		if (!$?) {
			if ($error[0].ToString() -notlike '*not supported for the account*') {
				write-logFileWarning "Could not get File Service for storage account $name"
			}
		}

		foreach ($fs in $fileServices) {
			$script:az_storageAccountsFileService += $fs
		}

		#--------------------------------------------------------------
		# get blob storage properties
		$blobServices = Get-AzStorageBlobServiceProperty `
							-ResourceGroupName $sourceRG `
							-StorageAccountName $name `
							-ErrorAction 'SilentlyContinue' `
							-WarningAction 'SilentlyContinue'
		if (!$?) {
			if ($error[0].ToString() -notlike '*not supported for the account*') {
				# write-logFile "Could not get Blob Service for storage account $name" -ForegroundColor 'DarkGray'
			}
		}

		foreach ($bs in $blobServices) {
			$script:az_storageAccountsBlobService += $bs
		}
	}

	#--------------------------------------------------------------
	# get storage account container 
	# write-logFile "Reading Storage Account Containers (RG $sourceRG)..."
	foreach ($az_res in $script:az_storageAccountsBlobService) {

		$containers = Get-AzRmStorageContainer `
						-ResourceGroupName $sourceRG `
						-StorageAccountName $az_res.StorageAccountName `
						-ErrorAction 'SilentlyContinue' `
						-WarningAction 'SilentlyContinue'
		test-cmdlet 'Get-AzRmStorageContainer'  "Could not get containers of storage account $name"

		foreach ($container in $containers) {
			$script:az_storageContainers += $container
		}
	}

	#--------------------------------------------------------------
	# get storage account shares
	# write-logFile "Reading Storage Account Shares (RG $sourceRG)..."
	foreach ($az_res in $script:az_storageAccountsFileService) {

		$shares = Get-AzRmStorageShare `
					-ResourceGroupName $sourceRG `
					-StorageAccountName $az_res.StorageAccountName `
					-ErrorAction 'SilentlyContinue' `
					-WarningAction 'SilentlyContinue'
		test-cmdlet 'Get-AzRmStorageShare'  "Could not get shares of storage account $name"

		foreach ($share in $shares) {
			$script:az_storageShares += $share
		}
	}

	save-az_all ([ref] $script:az_storageAccounts)
	save-az_all ([ref] $script:az_storageAccountsFileService) -noCount
	save-az_all ([ref] $script:az_storageAccountsBlobService) -noCount
	save-az_all ([ref] $script:az_storageContainers) -noCount
	save-az_all ([ref] $script:az_storageShares) -noCount
}

#--------------------------------------------------------------
function get-az_privateEndpoints {
#--------------------------------------------------------------
	write-logFile "Reading Private Endpoints (RG $sourceRG)..."

	$script:az_privateEndpoints = @( 
		Get-AzPrivateEndpoint `
			-ResourceGroupName $sourceRG `
			-ErrorAction 'SilentlyContinue'
	)
	test-cmdlet 'Get-AzPrivateEndpoint'  "Could not get Private Endpoints of resource group '$sourceRG'"

	
	$script:az_privateDnsZoneGroups = @()
	foreach ($ep in $script:az_privateEndpoints) {

		$script:az_privateDnsZoneGroups += @(
			Get-AzPrivateDnsZoneGroup `
				-ResourceGroupName $sourceRG `
				-PrivateEndpointName $ep.Name `
				-ErrorAction 'SilentlyContinue'
		)
		test-cmdlet 'Get-AzPrivateDnsZoneGroup'  "Could not get DNS zones of Private Endpoint '$($ep.Name)'"
	}

	save-az_all ([ref] $script:az_privateEndpoints)
	save-az_all ([ref] $script:az_privateDnsZoneGroups) -noCount
}

#--------------------------------------------------------------
function remove-angleBrackets {
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
# replace type text (simplify BICEP names)
$script:shortTypeName = @{}
$script:shortTypeName['virtualMachines'] = 'vm'
$script:shortTypeName['extensions'] = 'vmext'
$script:shortTypeName['disks'] = 'disk'
$script:shortTypeName['virtualNetworks'] = 'nw'
$script:shortTypeName['networkSecurityGroups'] = 'nsg'
$script:shortTypeName['applicationSecurityGroups'] = 'asg'
$script:shortTypeName['networkInterfaces'] = 'nic'
$script:shortTypeName['publicIPAddresses'] = 'ipaddr'
$script:shortTypeName['publicIPPrefixes'] = 'ipprefix'
$script:shortTypeName['loadBalancers'] = 'lb'
$script:shortTypeName['natGateways'] = 'gw'
$script:shortTypeName['dnsZones'] = 'dns'
$script:shortTypeName['privateDnsZones'] = 'privdns'
$script:shortTypeName['virtualNetworkLinks'] = 'dnslink'
$script:shortTypeName['availabilitySets'] = 'avset'
$script:shortTypeName['proximityPlacementGroups'] = 'ppg'
$script:shortTypeName['virtualMachineScaleSets'] = 'vmss'
$script:shortTypeName['bastionHosts'] = 'bastion'
$script:shortTypeName['storageAccounts'] = 'sa'
$script:shortTypeName['fileServices'] = 'file'
$script:shortTypeName['blobServices'] = 'blob'
$script:shortTypeName['netAppAccounts'] = 'netapp'
$script:shortTypeName['capacityPools'] = 'pool'
$script:shortTypeName['volumes'] = 'volume'
$script:shortTypeName['routeTables'] = 'route'
#--------------------------------------------------------------
function get-bicepNameByType {
#--------------------------------------------------------------
	# get and create unique BICEP name
	# from full qualified resource type and name
	param (
		$type,	# multi-part type, e.g. 'Microsoft.Storage/storageAccounts/blobServices'
		$name,	# multi-part name. e.g. 'saName/srvName'
		[switch] $collectReferences
	)

	# single-part type and name
	$typeParts = $type -split '/'
	$nameParts = $name -split '/'
	if (($typeParts.count) -ne ($nameParts.count + 1)) {
		write-logFileError "Internal RGCOPY error in 'get-bicepNameByType'" `
							"type = $type" `
							"name = $name"
	}

	if ($typeParts.count -eq 2) {
		# MAIN resource
		$bicepNameMain = $null
	}
	else {
		# SUB resource (at least 3 type parts)
		$bicepNameMain = get-bicepNameByType ($typeParts[0..1] -join '/') ($nameParts[0])
	}

	# maximum length of bicep name: 128
	# -> 30 chars for each: type, partname1, partname2, partname3

	# clean part names
	for ($i = 0; $i -lt $nameParts.Count; $i++) {
		# remove: . - _
		# replace all special characters with _
		$nameParts[$i] = $nameParts[$i]  `
							-replace '\.', '' `
							-replace '-', '' `
							-replace '_', '' `
							-replace '[\W]', '_'
		# maximum length: 30 characters
		if ($nameParts[$i].Length -gt 30) {
			$nameParts[$i] = $nameParts[$i].Substring(0,30)
		}
	}
	$nameLong = $nameParts -join '_'

	# clean type name
	# only use sub-type
	$typeShort = $typeParts[-1]
	# shorten sub-type by given replacements
	if ($null -ne $script:shortTypeName[$typeShort]) {
		$typeShort = $script:shortTypeName[$typeShort]
	}
	# maximum length: 30 characters
	if ($typeShort.Length -gt 30) {
		$typeShort = $typeShort.Substring(0,30)
	}
	
	# make bicep name unique:
	# check if SAME BICEP name is already in use for DIFFERENT Azure name or type
	$count = $null
	do {
		$bicepName = "$typeShort$count`_$nameLong".ToLower()
		# ToLower(): woraround for Azure bug:
		# resource ID contained resource name in wrong case (upper case instead of lower case)
		$nameSaved = $script:bicepNamesAll[$bicepName].name
		$typeSaved = $script:bicepNamesAll[$bicepName].type

		if ($null -eq $count) {
			$count = 1
		}
		$count++	
	} until (
		($Null -eq $nameSaved) -or (($name -eq $nameSaved) -and ($type -eq $typeSaved))
	)

	# BICEP name is created at first usage 
	# (either during resource creation or when referenced by other resource)
	if ($Null -eq $nameSaved) {
		# save unique bicep name
		$script:bicepNamesAll[$bicepName] = @{
			bicepName	= $bicepName # calculated above
			type		= $type # multi-part type
			name		= $name # multi-part name
		} 
	}

	# collect references to other MAIN resources
	# collected bicep name might not exist in final bicep template
	if ($collectReferences) {
		if ($null -eq $bicepNameMain) {
			$bicepNameMain = $bicepName
		}

		if ($null -ne $script:bicepNamesReferenced) {
			$script:bicepNamesReferenced += $bicepNameMain
		}
	}

	return $bicepName
}

#--------------------------------------------------------------
function get-bicepNameById {
#--------------------------------------------------------------
	# get and create unique BICEP name
	# from given resource ID
	# When $useMainResource is set, the sub-resorce part if the ID is ignored
	param (
		$id, # id of main-resource or sub-resource
		[switch] $useMainResource,
		[switch] $collectReferences
	)

	# no reference to resource => nothing to add in BICEP template
	if ($Null -eq $id) {
		return $Null
	}

	# parase $id
	$r = get-resourceComponents $id

	# main-resource
	$type = $r.resourceArea + '/' + $r.mainResourceType 
	$name = $r.mainResourceName

	# sub-resource
	if ($null -ne $r.subResourceType) {
		if (!$useMainResource) {
			$type += "/$($r.subResourceType)"
			$name += "/$($r.subResourceName)"
		}
	}

	if ($collectReferences) {
		return (get-bicepNameByType $type $name -collectReferences)
	}
	else {
		return (get-bicepNameByType $type $name)
	}
}

#--------------------------------------------------------------
function get-bicepReference {
#--------------------------------------------------------------
	<#
		input: referenced resource ID
		output: struct { id = ...}

		Normal resources in the target RG:
				struct { id = bicepname.id }
		Sub-resources in the target RG:
				struct { id = resourceId( ... ) }
				in addition, main-resource is added to $dependsOn
		in cloneOrMergeMode:
				struct { id = '/subscriptions/../..'}
	#>

	param (
		$id,
		[ref] $depensOn,
		[switch] $allowSubresource
	)

	# referenced resource ID is Null
	if ($null -eq $id) {
		return $Null
	}

	# get main resource BICEP name
	# This always works because a name is generated even if resource is not found
	$bicepNameMain = get-bicepNameById $id -useMainResource
	$bicepName     = get-bicepNameById $id
	$r = get-resourceComponents $id

	if ($cloneOrMergeMode) {
		$rg = "'$($r.resourceGroup)', "
	}
	else {
		$rg = $Null
	}

	$bicepIdMain	= "<resourceId($rg'$($r.resourceArea)/$($r.mainResourceType)', '$($r.mainResourceName)')>"
	$bicepId		= "<resourceId($rg'$($r.resourceArea)/$($r.mainResourceType)/$($r.subResourceType)', '$($r.mainResourceName)', '$($r.subResourceName)')>"

	# collect references to other MAIN resources
	# collected bicep name might not exist in final bicep template
	if ($null -ne $script:bicepNamesReferenced) {
		$script:bicepNamesReferenced += $bicepNameMain
	}

	#--------------------------------------------------------------
	# main-resource
	if ($bicepName -eq $bicepNameMain) {

		# clone or merge mode:
		# referenced resource might not be contained in BICEP template, but it already exists
		if ($cloneOrMergeMode) {
			return @{
				id = $bicepIdMain
			}
		}

		# copy mode
		return @{
			id = "<$bicepNameMain`.id>"
		}
	}

	#--------------------------------------------------------------
	# # reference to a sub-resource, e.g. subnet
	if ($allowSubresource) {
		# return sub-resource ID
		# this is only allowed if sub-resource has been defined separately from main-resource
		return @{
			id = "<$bicepName`.id>"
		}
	}

	else {
		if ($Null -ne $depensOn) {
			# set dependency to main-resource, e.g. vnet
			$depensOn.Value += "<$bicepNameMain>"

			# dependency is not needed if sub-resource is referenced from main-resource
			# e.g. backend address pool referenced from load balancer
		}
		
		# return sub-resource using function resourceId()
		return @{
			id = $bicepId
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

	#--------------------------------------------------------------
	# sort keys
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

		# resource header
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

	#--------------------------------------------------------------
	# process keys
	if ($existing) {
		$textArray += $tabString * $tabCount + "name: '$($res.name)'"
	}

	else {

		# process all keys
		foreach ($key in $keysSorted) {

			$value = $res.$key

			#--------------------------------------------------------------
			# recursion level 1
			if ($tabCount -eq 1) {

				# isKeyOfATag
				if ($key -eq 'tags') {
					$script:isKeyOfATag = $True
				}
				else {
					$script:isKeyOfATag = $False
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

				# ignore the following keys:
				# 'if', 'bicepName', 'type', 'apiVersion': already processes in resource header
				# 'resourceGroupName':    internal property for RGCOPY
				# 'bicepNamesReferenced': internal property for RGCOPY
				if ($key -in @( 'if', 'type', 'apiVersion', 'resourceGroupName', 'bicepName', 'bicepNamesReferenced')) {
					continue
				}

				$script:allowEmptyValues = $False
			}

			#--------------------------------------------------------------
			# recursion level 2
			if ($tabCount -eq 2) {
				if ($key -eq 'userAssignedIdentities') {
					$script:allowEmptyValues = $True
					# identity: {
					# 	type: 'SystemAssigned, UserAssigned'
					# 	userAssignedIdentities: {
					# 	'/subscriptions/.../userAssignedIdentities/AzSecPack...': {}  <-- needed here
					# 	}
					# }
				}
				else {
					$script:allowEmptyValues = $False
				}
			}

			#--------------------------------------------------------------
			# process data types

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
				if (($textArraySubLevel.count -ne 0) -or $script:allowEmptyValues) {
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
								$item = remove-angleBrackets $item
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
						$value = remove-angleBrackets $value
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
		$resource,				# 1st. parameter
		$az_res,				# 2nd. parameter (optional)
		$resName,				# parameter name must be explicitly set
		$bicepResName,			# parameter name must be explicitly set
		[switch] $noRegion,
		[switch] $regionGlobal,
		[switch] $noZones
	)

	$resource.bicepNamesReferenced = @()

	#--------------------------------------------------------------
	# resource read by cmdlet (two parameters provided)
	if ($Null -ne $az_res) {

		# in functions add-az_*, references are collected in script variable $script:bicepNamesReferenced
		if ($null -ne $script:bicepNamesReferenced) {
			$resource.bicepNamesReferenced = $script:bicepNamesReferenced
		}

		$resource.name 				= $az_res.Name
		$resource.resourceGroupName	= $az_res.ResourceGroupName

		# overwrite resource name
		if ($Null -ne $resName) {
			$resource.name 			= $resName
		}

		# tags for most resources
		$tags = $az_res.Tags -as [hashtable]
		if ($tags.count -gt 0) {
			$resource.tags = $tags
		}
		# tags for some resources ('Tag' rather than 'Tags')
		else {
			$tags = $az_res.Tag -as [hashtable]
			if ($tags.count -gt 0) {
				$resource.tags = $tags
			}
		}
		
		# zones
		$zones = $az_res.Zones -as [array]
		if ($zones.count -gt 0) {
			if ($noZones) {
				# warning when Zones was set, but ignored by RGCOPY
				test-property 'zones' $az_res.Zones
			}
			else {
				$resource.zones = $zones
			}
		}

		# warning when extendedLocation or placement was set
		test-property 'extendedLocation' $az_res.ExtendedLocation
		test-property 'placement' $az_res.Placement
	}

	#--------------------------------------------------------------
	# resource manually added
	else {
		$resource.resourceGroupName = $sourceRG
	}
	#--------------------------------------------------------------

	# set region
	if (($az_res.Location -eq 'global') -or $regionGlobal) {
		$resource.location = 'global'
	}

	elseif (!$noRegion) {
		$resource.location = '<regionName>'
	}

	# add BICEP name
	if ($Null -eq $bicepResName) {
		$resource.bicepName = get-bicepNameByType $resource.type $resource.name
	}
	else {
		$resource.bicepName = get-bicepNameByType $resource.type $bicepResName
	}
	
	# save resource
	$script:resourcesALL += $resource
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
function split-az_singleMulti {
#--------------------------------------------------------------
	param (
		$list	# IList<String>
	)

	$single = $null
	$multi = @()

	if ($list.Count -eq 1) {
		$single = $list[0]	
	}

	if ($list.Count -gt 1) {
		$multi = $list -as [array]
	}

	return @{
		single = $single	# [string]
		multi  = $multi		# [array]
	}
}

#--------------------------------------------------------------
function get-az_ipTags {
#--------------------------------------------------------------
	param (
		$azTags
	)

	$ipTags = @()
	if ($ipTagEnabled) {
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
			foreach ($tag in $azTags) {
				if ($tag.Tag.Length -ne 0) {
					$ipTags += @{
						ipTagType	= $tag.IpTagType
						tag			= $tag.Tag
					}
				}
			}
		}
	}

	return ,$ipTags		# return [array] (forced by comma)
}

#--------------------------------------------------------------
function get-supportedZones {
#--------------------------------------------------------------
	param (
		$resType,
		$resName,
		$azZones
	)

	$currentZones = @($azZones| Sort-Object -Unique)
	if ($currentZones.Count -eq 0) {
		# no zone defined in source -> no zone in target
		return $null
	}

	# any zone defined in source -> all available zones in target
	$changeNeeded = $false
	if ($currentZones.Count -ne $script:allTargetZones.Count) {
		$changeNeeded = $true
	}
	else {
		for ($i = 0; $i -lt $script:allTargetZones.Count; $i++) {
			if ($script:allTargetZones[$i] -ne $currentZones[$i]) {
				$changeNeeded = $true
			}
		}
	}

	if ($changeNeeded) {
		write-logFileUpdates $resType $resName 'set Zones' ($script:allTargetZones -as [string]) -valueWarning
		return ,$script:allTargetZones # comma: do not convert [array] with 0 or 1 elements to scalar
	}
	else {
		write-logFileUpdates $resType $resName 'keep Zones' ($currentZones -as [string])
		return ,$currentZones # comma: do not convert [array] with 0 or 1 elements to scalar
	}
}

#--------------------------------------------------------------
function test-property {
#--------------------------------------------------------------
	param (
		$property,
		$value,
		$text,
		[switch] $unknownProperty,	# property not found in Get-AzXXX
		[switch] $displayProperty,	# property is not needed for deployment (e.g. current state)
		[switch] $uselessProperty	# property does not fit for RGCOPY (e.g. VM image)
	)

	if ($null -eq $text) {
		$text = 'skipped by RGCOPY'
	}

	# property not found in az-cmdlet: value is unknown
	# Therefore, it cannot be set by RGCOPY
	if ($unknownProperty) {
		# write-logFileWarning "Property '$property' of resoure: '$resType/$resName' unknown"
		return
	}
	
	# property is a display only property
	# value is known, but will not be used by RGCOPY
	if ($displayProperty -or $unneededProperty) {
		return
	}

	# value was not set
	if ($value.Count -eq 0) {
		return
	}

	# value set, but ignored by RGCOPY
	write-logFileUpdates $script:testResourceType $script:testResourceName -warning "property '$property' $text"
}

#--------------------------------------------------------------
function get-identity {
#--------------------------------------------------------------
	param (
		$az_res
	)

	if (!$patchMode) {
		return $null
	}

	# get resource type and name
	$r = get-resourceComponents $az_res.Id
	$resName = $r.mainResourceName
	$resType = $r.mainResourceType

	$identity = @{
		type = 'None'
		userAssignedIdentities = @{}
	}

	# always keep system assigned identity

	# check user assigned identies
	if ($az_res.Identity.Type -like '*UserAssigned*') {

		# check each identity seperately
		foreach ($id in $az_res.Identity.UserAssignedIdentities.Keys) {
			$name = ($id -split '/')[8]

			# remove identities when parameter skipIdentities is set
			if ($skipIdentities) {
				write-logFileUpdates $resName $resType "delete identity" "$name (skipIdentities)"
			}

			# remove identities from different tenants
			elseif ($sourceSubTenant -ne $targetSubTenant) {
				write-logFileUpdates $resName $resType "delete identity" "$name (different tenant)"
			}

			# remove azSecPack identity (will be re-created automatically)
			elseif (($name -like '*AzSecPackAutoConfigUA-*') -and !$keepIdentities) {
				# write-logFileUpdates $resName $resType "delete identity" "$name (AzSecPack)"
			}

			# keep identity
			else {
				# set identity: value is an empty hash table by definition!
				$identity.userAssignedIdentities.$id = @{}
			}
		}
	}

	# calculate type
	if ($identity.userAssignedIdentities.Count -gt 0) {
		if ($az_res.Identity.Type -like '*SystemAssigned*') {
			$identity.type = 'SystemAssigned,UserAssigned'
		}
		else {
			$identity.type = 'UserAssigned'
		}
	}
	elseif ($az_res.Identity.Type -like '*SystemAssigned*') {
		$identity.type = 'SystemAssigned'
	}
	else {
		$identity.type = 'None'
	}

	# return hash table
	return $identity
}

#--------------------------------------------------------------
function add-az_virtualMachines {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_virtualMachines) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'vm'
		$script:bicepNamesReferenced = @()
		#========================================

		#--------------------------------------------------------------
		# OS disk
		$disk = $az_res.StorageProfile.OsDisk
		$bicepName = get-bicepNameByType 'Microsoft.Compute/disks' $disk.Name -collectReferences

		$osDisk				= @{
			name					= $disk.Name
			osType					= convertTo-String $disk.OsType
			caching					= convertTo-String $disk.Caching
			writeAcceleratorEnabled	= convertTo-Boolean $disk.WriteAcceleratorEnabled
			createOption			= 'Attach'
			deleteOption			= convertTo-String $disk.DeleteOption
			managedDisk				= @{
				id = "<$bicepName`.id>"
			}
		}

		#--------------------------------------------------------------
		# data disks
		$dataDisks = @()
		foreach ($disk in $az_res.StorageProfile.DataDisks) {
			$bicepName = get-bicepNameByType 'Microsoft.Compute/disks' $disk.Name -collectReferences

			$dataDisks += @{
				name					= $disk.Name
				caching					= convertTo-String $disk.Caching
				writeAcceleratorEnabled	= convertTo-Boolean $disk.WriteAcceleratorEnabled
				createOption			= 'Attach'
				deleteOption			= convertTo-String $disk.DeleteOption
				lun						= $disk.Lun
				managedDisk				= @{
					id = "<$bicepName`.id>"
				}
			}
		}

		#--------------------------------------------------------------
		# storageProfile
		$storageProfile = @{
			# alignRegionalDisksToVMZone
			dataDisks			= $dataDisks
			diskControllerType	= convertTo-String $az_res.StorageProfile.DiskControllerType
			# imageReference
			osDisk				= $osDisk
		}
		test-property 'storageProfile.alignRegionalDisksToVMZone' $az_res.StorageProfile.AlignRegionalDisksToVMZone
		test-property 'storageProfile.imageReference' $az_res.StorageProfile.ImageReference


		#--------------------------------------------------------------
		# NetworkInterfaces
		$networkInterfaces = @()
		foreach ($nic in $az_res.NetworkProfile.NetworkInterfaces) {

			$networkInterfaces += @{
				properties = @{
					deleteOption	= convertTo-String $nic.DeleteOption
					primary			= convertTo-Boolean $nic.Primary
				}
				id = "<$(get-bicepNameById $nic.Id -collectReferences).id>"
			}
		}

		#--------------------------------------------------------------
		# additionalCapabilities
		if ($Null -eq $az_res.AdditionalCapabilities) {
			$additionalCapabilities = $Null
		}
		else {
			$additionalCapabilities = @{
				hibernationEnabled			= convertTo-Boolean $az_res.AdditionalCapabilities.HibernationEnabled
				ultraSSDEnabled				= convertTo-Boolean $az_res.AdditionalCapabilities.UltraSSDEnabled
				enableFips1403Encryption	= convertTo-Boolean $az_res.AdditionalCapabilities.EnableFips1403Encryption
			}
		}

		#--------------------------------------------------------------
		$securityProfile = @{
			encryptionAtHost	= convertTo-Boolean $az_res.SecurityProfile.EncryptionAtHost
			# encryptionIdentity
			# proxyAgentSettings
			securityType		= convertTo-String $az_res.SecurityProfile.SecurityType
			uefiSettings		= @{
				secureBootEnabled 	= convertTo-Boolean $az_res.SecurityProfile.UefiSettings.SecureBootEnabled
				vTpmEnabled			= convertTo-Boolean $az_res.SecurityProfile.UefiSettings.VTpmEnabled
			}
		}
		test-property 'securityProfile.encryptionIdentity' $az_res.SecurityProfile.EncryptionIdentity
		test-property 'securityProfile.proxyAgentSettings' $az_res.SecurityProfile.ProxyAgentSettings

		#--------------------------------------------------------------
		# properties
		$properties = @{
			additionalCapabilities	= $additionalCapabilities
			# applicationProfile
			availabilitySet			= get-bicepReference $az_res.AvailabilitySetReference.Id
			# billingProfile
			# capacityReservation
			diagnosticsProfile = @{
				bootDiagnostics 	= @{
					enabled			= convertTo-Boolean $az_res.DiagnosticsProfile.BootDiagnostics.Enabled
					storageUri		= convertTo-String $az_res.DiagnosticsProfile.BootDiagnostics.StorageUri
				}
			}
			evictionPolicy			= convertTo-String $az_res.EvictionPolicy
			# extensionsTimeBudget
			hardwareProfile = @{
				vmSize 				= convertTo-String $az_res.HardwareProfile.VmSize
				# vmSizeProperties	# still in preview
			}
			# host
			# hostGroup
			licenseType				= convertTo-String $az_res.LicenseType
			networkProfile = @{
				# networkApiVersion
				# networkInterfaceConfigurations
				networkInterfaces	= $networkInterfaces
			}
			# osProfile				# not used when using OS disk snapshot
			platformFaultDomain 	= $az_res.PlatformFaultDomain # [int]
			priority				= convertTo-String $az_res.Priority
			proximityPlacementGroup	= get-bicepReference $az_res.ProximityPlacementGroup.Id
			# scheduledEventsPolicy
			# scheduledEventsProfile
			securityProfile 		= $securityProfile
			storageProfile 			= $storageProfile
			userData				= convertTo-String $az_res.UserData
			virtualMachineScaleSet	= get-bicepReference $az_res.VirtualMachineScaleSet.Id
		}
		test-property -uselessProperty 'applicationProfile' $az_res.ApplicationProfile
		test-property 'billingProfile' $az_res.BillingProfile
		test-property 'capacityReservation' $az_res.CapacityReservation
		test-property -unknownProperty 'extensionsTimeBudget'
		test-property -uselessProperty 'hardwareProfile.vmSizeProperties' $az_res.HardwareProfile.VmSizeProperties
		test-property 'host' $az_res.Host
		test-property 'hostGroup' $az_res.HostGroup
		test-property 'networkProfile.networkApiVersion' $az_res.NetworkProfile.NetworkApiVersion
		test-property 'networkProfile.networkInterfaceConfigurations' $az_res.NetworkProfile.NetworkInterfaceConfigurations
		test-property 'osProfile' $az_res.OSProfile
		test-property -unknownProperty 'scheduledEventsPolicy'
		test-property -unknownProperty 'scheduledEventsProfile'

		#--------------------------------------------------------------
		# create resource
		$resource = @{
			type 		= 'Microsoft.Compute/virtualMachines'
			apiVersion	= '2025-04-01'
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			identity	= get-identity $az_res
			# plan		only used for marketplace images
			properties	= $properties
		}
		add-resourcesALL $resource $az_res

		test-property -uselessProperty 'plan' $az_res.Plan

		# test location
		$vmLocation = $az_res.Location
		if ($sourceLocation -ne $vmLocation) {
			write-logFileError "VM '$($az_res.Name)' is in different region" `
								"Source region: '$sourceLocation'" `
								"VM region: '$vmLocation'"
		}
	}
}

#--------------------------------------------------------------
function add-az_virtualNetworks {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_virtualNetworks) {

		#--------------------------------------------------------------
		# Subnets
		$subnets = @()
		foreach ($sub in $az_res.Subnets) {

			# delegations
			$delegations = @()
			foreach ($item in $sub.Delegations) {
				$del = @{
					name = convertTo-String $item.Name
					properties	= @{
						serviceName = convertTo-String $item.ServiceName
					}
					type = 'Microsoft.Network/virtualNetworks/subnets/delegations'
				}
				$delegations += $del
			}

			# exsisting serviceEndpoints
			$serviceEndpoints = @()
			foreach ($item in $sub.ServiceEndpoints) {
				$ep = @{
					# locations							just a display property?
					# networkIdentifier					sub resource ID, not needed?
					service								= convertTo-String $item.Service
				}
				$serviceEndpoints += $ep
			}

			# Subnet resource
			$subnet = @{
				name 									= $sub.Name
				properties = @{
					addressPrefix						= (split-az_singleMulti $sub.AddressPrefix).single
					addressPrefixes						= (split-az_singleMulti $sub.AddressPrefix).multi
					# applicationGatewayIPConfigurations
					defaultOutboundAccess				= convertTo-Boolean $sub.DefaultOutboundAccess
					delegations							= $delegations
					# ipAllocations
					# ipamPoolPrefixAllocations
					natGateway 							= get-bicepReference $sub.NatGateway.Id
					networkSecurityGroup				= get-bicepReference $sub.NetworkSecurityGroup.Id
					privateEndpointNetworkPolicies		= convertTo-String $sub.PrivateEndpointNetworkPolicies
					privateLinkServiceNetworkPolicies	= convertTo-String $sub.PrivateLinkServiceNetworkPolicies
					routeTable							= get-bicepReference $sub.RouteTable.Id
					# serviceEndpointPolicies
					serviceEndpoints					= $serviceEndpoints
					# serviceGateway
					# sharingScope
				}
			}

			if ($copyVMsOnly) {
				$subnet.properties.networkSecurityGroup = $null
			}

			$subnets += $subnet

			#========================================
			$script:testResourceName = $sub.Name
			$script:testResourceType = 'subnet'
			$script:bicepNamesReferenced = @()
			#========================================

			test-property -unknownProperty 'applicationGatewayIPConfigurations'
			test-property 'ipAllocations' $sub.IpAllocations
			test-property 'ipamPoolPrefixAllocations' $sub.IpamPoolPrefixAllocations
			test-property 'serviceEndpointPolicies' $sub.ServiceEndpointPolicies
			test-property -unknownProperty 'serviceGateway'
			test-property -unknownProperty 'sharingScope'
		}

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'vnet'
		$script:bicepNamesReferenced = @()
		#========================================

		# dhcpOptions
		$dhcpOptions = $null
		if ($az_res.DhcpOptions.DnsServers.Count -gt 0) {
			$dhcpOptions = @{
				dnsServers = @($az_res.DhcpOptions.DnsServers)
			}
		}

		# ddosProtectionPlan
		$ddosProtectionPlan = $null
		$enableDdosProtection = $null
		if ($null -ne $az_res.DdosProtectionPlan.Id) {
			if ($differentTenantOrUser) {
				test-property 'DdosProtectionPlan' $true 'ignored when copying with different tenant/user'
			}
			else {
				$enableDdosProtection = convertTo-Boolean $az_res.EnableDdosProtection
				$ddosProtectionPlan = @{
					id = $az_res.DdosProtectionPlan.Id	# use existing DDOS protection plan. Do not copy the plan
				}
			}
		}

		#--------------------------------------------------------------
		# create resource
		$resource = @{
			type 		= 'Microsoft.Network/virtualNetworks'
			apiVersion	= '2025-05-01'
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			properties	= @{
				addressSpace = @{
					addressPrefixes			= @($az_res.AddressSpace.AddressPrefixes)
					# ipamPoolPrefixAllocations
				}
				# bgpCommunities
				DdosProtectionPlan			= $ddosProtectionPlan
				dhcpOptions					= $dhcpOptions			
				enableDdosProtection 		= $enableDdosProtection
				# enableVmProtection
				encryption = @{
					enabled					= convertTo-Boolean $az_res.Encryption.Enabled
					enforcement				= convertTo-String $az_res.Encryption.Enforcement
				}
				flowTimeoutInMinutes		= $az_res.FlowTimeoutInMinutes # [int]
				# ipAllocations
				privateEndpointVNetPolicies	= convertTo-String $az_res.PrivateEndpointVNetPolicies
				subnets						= $subnets
				# virtualNetworkPeerings
			}
		}
		add-resourcesALL $resource $az_res

		test-property 'addressSpace.ipamPoolPrefixAllocations' $az_res.AddressSpace.IpamPoolPrefixAllocations
		test-property 'bgpCommunities' $az_res.BgpCommunities
		test-property -unknownProperty 'enableVmProtection'
		test-property 'ipAllocations' $az_res.IpAllocations
		test-property 'virtualNetworkPeerings' $az_res.VirtualNetworkPeerings
	}
}

#--------------------------------------------------------------
function add-az_networkInterfaces {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_networkInterfaces) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'nic'
		$script:bicepNamesReferenced = @()
		#========================================
		$ipConfigurations = @()
		$dependsOn = @()

		# ipConfigurations
		foreach ($conf in $az_res.IpConfigurations) {

			# loadBalancerBackendAddressPools
			$backendAddressPools = @()
			foreach ($item in $conf.LoadBalancerBackendAddressPools) {
				$backendAddressPools += get-bicepReference $item.Id ([ref] $dependsOn)
			}

			# loadBalancerInboundNatRules
			$inboundNatRules = @()
			foreach ($item in $conf.LoadBalancerInboundNatRules) {
				$inboundNatRules += get-bicepReference $item.Id ([ref] $dependsOn)
			}

			#applicationSecurityGroups
			$applicationSecurityGroups = @()
			if (!$copyVMsOnly) {
				foreach ($item in $conf.ApplicationSecurityGroups) {
					$applicationSecurityGroups += get-bicepReference $item.Id
				}
			}

			$ipConfig = @{
				name 								= $conf.Name
				properties 	= @{
					# applicationGatewayBackendAddressPools
					applicationSecurityGroups		= $applicationSecurityGroups
					# gatewayLoadBalancer
					loadBalancerBackendAddressPools	= $backendAddressPools
					loadBalancerInboundNatRules		= $inboundNatRules
					primary							= convertTo-Boolean $conf.Primary

				# always set allocation method static in RGCOPY
					privateIPAllocationMethod		= convertTo-String $conf.PrivateIpAllocationMethod
					privateIPAddress				= convertTo-String $conf.PrivateIpAddress
					privateIPAddressPrefixLength	= $conf.PrivateIpAddressPrefixLength	# [int]
					privateIPAddressVersion			= convertTo-String $conf.PrivateIpAddressVersion
					
					publicIPAddress					= get-bicepReference $conf.PublicIpAddress.Id
					subnet							= get-bicepReference $conf.Subnet.Id ([ref] $dependsOn)
					# virtualNetworkTaps
				}
			}
			$ipConfigurations += $ipConfig

			test-property 'applicationGatewayBackendAddressPools' $conf.ApplicationGatewayBackendAddressPools
			test-property 'gatewayLoadBalancer' $conf.GatewayLoadBalancer
			test-property 'virtualNetworkTaps' $conf.VirtualNetworkTaps
		}

		# dnsSettings
		$dnsSettings = @{
			dnsServers = @()
			internalDnsNameLabel = convertTo-String $az_res.InternalDnsNameLabel
		}
		foreach ($item in $az_res.DnsServers) {
			$dnsSettings.dnsServers += $item
		}
		if ($Null -eq $az_res.DnsSettings) {
			$dnsSettings = $Null
		}

		#--------------------------------------------------------------
		# create resource
		$resource = @{
			type 		= 'Microsoft.Network/networkInterfaces'
			apiVersion	= '2025-05-01'
			dependsOn 	= @($dependsOn | Sort-Object -Unique)
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			properties	= @{
				auxiliaryMode				= convertTo-String $az_res.AuxiliaryMode
				auxiliarySku				= convertTo-String $az_res.AuxiliarySku
				disableTcpStateTracking		= convertTo-Boolean $az_res.DisableTcpStateTracking
				dnsSettings					= $dnsSettings
				enableAcceleratedNetworking = convertTo-Boolean $az_res.EnableAcceleratedNetworking
				enableIPForwarding			= convertTo-Boolean $az_res.EnableIPForwarding
				ipConfigurations			= $ipConfigurations
				# migrationPhase			# Display property: 'Abort', 'Commit', 'Committed', 'None', 'Prepare'
				networkSecurityGroup		= get-bicepReference $az_res.NetworkSecurityGroup.Id
				# nicType					# 'Elastic', 'Standard'
				# privateLinkService		# used for Private Endpoints (NIC skipped by RGCOPY)
				# workloadType				# used for BareMetal resources
			}
		}

		if ($copyVMsOnly) {
			$resource.properties.networkSecurityGroup = $null
		}

		test-property -displayProperty 'migrationPhase'
		test-property -unknownProperty 'nicType'
		test-property -unknownProperty 'workloadType'

		# skip NICs of private endpoints
		if ($Null -eq $az_res.PrivateEndpoint.Id) {
			add-resourcesALL $resource $az_res
		}
	}
}

#--------------------------------------------------------------
function add-az_publicIPAddresses {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_publicIPAddresses) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'ipAddress'
		$script:bicepNamesReferenced = @()
		#========================================

		# ddosProtectionPlan
		$ddosSettings = $null
		if (($null -ne $az_res.DdosSettings) -and !$differentTenantOrUser) {
			# DOS Settings
			$ddosSettings = @{
				ddosProtectionPlan  	= $null
				protectionMode			= convertTo-String $az_res.DdosSettings.ProtectionMode
			}
			# use existing DDOS protection plan. Do not copy the plan
			if ($null -ne $az_res.DdosProtectionPlan.Id) {
				$ddosSettings.ddosProtectionPlan = @{
					id = $az_res.DdosProtectionPlan.Id
				}
			}
		}

		#--------------------------------------------------------------
		# create resource
		$resource = @{
			type 		= 'Microsoft.Network/publicIPAddresses'
			apiVersion	= '2025-05-01'
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			sku	= @{
				name 						= convertTo-String $az_res.Sku.Name
				tier 						= convertTo-String $az_res.Sku.Tier
			}

			zones = get-supportedZones 'ipAddress' $az_res.Name $az_res.Zones
			properties	= @{
				ddosSettings				= $ddosSettings
				# deleteOption
				# dnsSettings
				idleTimeoutInMinutes		= $az_res.IdleTimeoutInMinutes # [int]
				# ipAddress
				ipTags						= get-az_ipTags $az_res.IpTags
				# linkedPublicIPAddress
				# migrationPhase	
				# natGateway	
				publicIPAddressVersion		= convertTo-String $az_res.PublicIpAddressVersion
				publicIPAllocationMethod	= convertTo-String $az_res.PublicIpAllocationMethod
				publicIPPrefix				= get-bicepReference $az_res.PublicIpPrefix.Id
				# servicePublicIPAddress
			}
		}

		# no new 'Basic' SKU IP addresses supported  by Azure
		if ($resource.sku.name -eq 'Basic') {
			$resource.sku.name = 'Standard'
			write-logFileWarning "'Basic' publicIPAddresses not supported, changing to 'Standard'"
		}

		# no new dynamic public IP addresses supported  by Azure
		if ($resource.properties.publicIPAllocationMethod -eq 'Dynamic') {
			$resource.properties.publicIPAllocationMethod  = 'Static'
			write-logFileWarning "'Dynamic' publicIPAllocationMethod not supported, changing to 'Static'"
		}

		# CannotSpecifyBothTagsAndPublicIpPrefixForPublicIpAddress
		if ($null -ne $resource.properties.publicIPPrefix.Id) {
			$resource.properties.ipTags = $null
		}

		add-resourcesALL $resource $az_res

		test-property -unknownProperty 'deleteOption' # Belongs to VM
		test-property 'dnsSettings' $az_res.DnsSettings # CANNOT COPY DNS SETTINGS BECAUSE THEY MUST BE UNIQUE
		test-property -displayProperty 'ipAddress'	# same IP address cannot be re-used
		test-property -displayProperty 'linkedPublicIPAddress'		# ?
		test-property -displayProperty 'migrationPhase'
		test-property -displayProperty 'natGateway'					# ?
		test-property -displayProperty 'servicePublicIPAddress'		# ?
	}
}

#--------------------------------------------------------------
function add-az_publicIPPrefixes {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_publicIPPrefixes) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'ipPrefix'
		$script:bicepNamesReferenced = @()
		#========================================

		#--------------------------------------------------------------
		# create resource
		$resource = @{
			type 				= 'Microsoft.Network/publicIPPrefixes'
			apiVersion			= '2025-05-01'
			zones = get-supportedZones 'ipPrefix' $az_res.Name $az_res.Zones
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			sku					= @{
				name = $az_res.Sku.Name
				tier = $az_res.Sku.Tier
			}
			properties			= @{
				# customIPPrefix
				ipTags					= get-az_ipTags $az_res.IpTags
				# natGateway
				prefixLength			= $az_res.PrefixLength # [int]
				publicIPAddressVersion	= convertTo-String $az_res.PublicIpAddressVersion
			}
		}
		add-resourcesALL $resource $az_res

		test-property 'customIPPrefix' $az_res.CustomIpPrefix
		test-property -displayProperty 'natGateway'
	}
}

#--------------------------------------------------------------
function add-az_natGateways {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_natGateways) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'natGateway'
		$script:bicepNamesReferenced = @()
		#========================================

		$publicIpAddresses = @()
		foreach ($ip in $az_res.PublicIpAddresses) {
			$publicIpAddresses += get-bicepReference $ip.Id
		}

		$publicIpAddressesV6 = @()
		foreach ($ip in $az_res.PublicIpAddressesV6) {
			$publicIpAddressesV6 += get-bicepReference $ip.Id
		}

		$publicIpPrefixes = @()
		foreach ($prefix in $az_res.PublicIpPrefixes) {
			$publicIpPrefixes += get-bicepReference $prefix.Id
		}

		$publicIpPrefixesV6 = @()
		foreach ($prefix in $az_res.PublicIpPrefixesV6) {
			$publicIpPrefixesV6 += get-bicepReference $prefix.Id
		}

		#--------------------------------------------------------------
		# create resource
		$resource = @{
			type 				= 'Microsoft.Network/natGateways'
			apiVersion			= '2025-05-01'
			zones 				= get-supportedZones 'natGateway' $az_res.Name $az_res.Zones
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			sku					= @{
				name = $az_res.Sku.Name -as [string]
			}
			properties		= @{
				idleTimeoutInMinutes	= $az_res.IdleTimeoutInMinutes # [int]
				publicIpAddresses		= $publicIpAddresses
				publicIpAddressesV6		= $publicIpAddressesV6
				publicIpPrefixes		= $publicIpPrefixes
				publicIpPrefixesV6		= $publicIpPrefixesV6
				# serviceGateway
				# sourceVirtualNetwork
			}
		}
		add-resourcesALL $resource $az_res

		test-property -unknownProperty 'serviceGateway'
		test-property -displayProperty 'sourceVirtualNetwork'
	}
}

#--------------------------------------------------------------
function add-az_routeTables {
#--------------------------------------------------------------
	if ($copyVMsOnly) {
		return
	}

	foreach ($az_res in $script:az_routeTables) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'routeTable'
		$script:bicepNamesReferenced = @()
		#========================================

		$routes = @()
		foreach ($route in $az_res.Routes) {
			$routes += @{
				name = $route.Name
				properties = @{
					addressPrefix		= convertTo-String $route.AddressPrefix
					nextHopIpAddress	= convertTo-String $route.NextHopIpAddress
					nextHopType			= convertTo-String $route.NextHopType
				}
			}
		}

		# create resource
		$resource = @{
			type		= 'Microsoft.Network/routeTables'
			apiVersion	= '2025-05-01'
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			properties	= @{
				disableBgpRoutePropagation	= convertTo-Boolean $az_res.DisableBgpRoutePropagation
				routes						= $routes
			}
		}

		add-resourcesALL $resource $az_res
	}
}

#--------------------------------------------------------------
function add-az_applicationSecurityGroups {
#--------------------------------------------------------------
	if ($copyVMsOnly) {
		return
	}

	foreach ($az_res in $script:az_applicationSecurityGroups) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'appSecGroup'
		$script:bicepNamesReferenced = @()
		#========================================

		# create resource
		$resource = @{
			type		= 'Microsoft.Network/applicationSecurityGroups'
			apiVersion	= '2025-05-01'
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			properties	= @{}
		}

		add-resourcesALL $resource $az_res
	}
}

#--------------------------------------------------------------
function add-az_networkSecurityGroups {
#--------------------------------------------------------------
	if ($copyVMsOnly) {
		return
	}

	foreach ($az_res in $script:az_networkSecurityGroups) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'nwSecGroup'
		$script:bicepNamesReferenced = @()
		#========================================
		
		$securityRules = @()
		foreach ($rule in $az_res.SecurityRules) {

			$destASGs = @()
			foreach ($item in $rule.DestinationApplicationSecurityGroups) {
				$destASGs += get-bicepReference $item.Id
			}

			$sourceASGs = @()
			foreach ($item in $rule.SourceApplicationSecurityGroups) {
				$sourceASGs += get-bicepReference $item.Id
			}

			$securityRule = @{
				name				= $rule.Name
				properties			= @{
					access									= convertTo-String $rule.Access
					description								= remove-angleBrackets $rule.Description
					destinationAddressPrefix				= (split-az_singleMulti $rule.DestinationAddressPrefix).single
					destinationAddressPrefixes				= (split-az_singleMulti $rule.DestinationAddressPrefix).multi
					destinationApplicationSecurityGroups 	= $destASGs
					destinationPortRange					= (split-az_singleMulti $rule.DestinationPortRange).single
					destinationPortRanges					= (split-az_singleMulti $rule.DestinationPortRange).multi
					direction								= convertTo-String $rule.Direction
					priority								= $rule.Priority	# [int]
					protocol								= convertTo-String $rule.Protocol
					sourceAddressPrefix						= (split-az_singleMulti $rule.SourceAddressPrefix).single
					sourceAddressPrefixes					= (split-az_singleMulti $rule.SourceAddressPrefix).multi
					sourceApplicationSecurityGroups 		= $sourceASGs
					sourcePortRange							= (split-az_singleMulti $rule.SourcePortRange).single
					sourcePortRanges						= (split-az_singleMulti $rule.SourcePortRange).multi
				}
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

		#--------------------------------------------------------------
		# create resource
		$resource = @{
			type 		= 'Microsoft.Network/networkSecurityGroups'
			apiVersion	= '2025-05-01'
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			properties = @{
				flushConnection	= convertTo-Boolean $az_res.FlushConnection
				securityRules 	= $securityRules
			}
		}

		add-resourcesALL $resource $az_res
	}
}

#--------------------------------------------------------------
function add-az_bastionHosts {
#--------------------------------------------------------------
	if ($skipBastion -or $copyVMsOnly) {
		return
	}

	foreach ($az_res in $script:az_bastionHosts) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'bastion'
		$script:bicepNamesReferenced = @()
		#========================================

		$dependsOn = @()
		$ipConfigurations = @()
		foreach ($conf in $az_res.IpConfigurations) {

			$ipConfiguration = @{
				name		= $conf.Name
				properties = @{
					privateIPAllocationMethod	= convertTo-String $conf.PrivateIpAllocationMethod
					publicIPAddress 			= get-bicepReference $conf.PublicIpAddress.Id
					subnet						= get-bicepReference $conf.Subnet.Id ([ref] $dependsOn)
				}
			}

			$ipConfigurations += $ipConfiguration
		}

		#--------------------------------------------------------------
		# create resource
		$resource = @{
			type 			= 'Microsoft.Network/bastionHosts'
			apiVersion		= '2025-05-01'
			zones 			= get-supportedZones 'bastion' $az_res.Name $az_res.Zones
			dependsOn 		= $dependsOn 
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			sku					= @{
				name 		= convertTo-String $az_res.Sku.Name
			}
			properties = @{
				disableCopyPaste			= convertTo-Boolean $az_res.DisableCopyPaste
				# dnsName
				# enableFileCopy
				enableIpConnect				= convertTo-Boolean $az_res.EnableIpConnect
				enableKerberos				= convertTo-Boolean $az_res.EnableKerberos
				# enablePrivateOnlyBastion
				enableSessionRecording		= convertTo-Boolean $az_res.EnableSessionRecording
				enableShareableLink			= convertTo-Boolean $az_res.EnableShareableLink
				enableTunneling				= convertTo-Boolean $az_res.EnableTunneling
				ipConfigurations 			= $ipConfigurations
				# networkAcls
				scaleUnits					= $az_res.ScaleUnit # [int]
				# virtualNetwork			# for Developer Bastion Host only		
			}
		}
		add-resourcesALL $resource $az_res

		test-property -displayProperty 'dnsName'
		test-property -unknownProperty 'enableFileCopy'
		test-property -unknownProperty 'enablePrivateOnlyBastion'
		test-property -unknownProperty 'networkAcls'
		test-property -unknownProperty 'virtualNetwork'
	}
}

#--------------------------------------------------------------
function add-az_availabilitySets {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_availabilitySets) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'avSet'
		$script:bicepNamesReferenced = @()
		#========================================

		# create resource
		$resource =  @{
			type 		= 'Microsoft.Compute/availabilitySets'
			apiVersion	= '2025-04-01'
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			sku = @{
				name = convertTo-String $az_res.Sku 	# "$az_res.Sku", not "$az_res.Sku.Name" !
				# tier									# not available in Get-AzAvailabilitySet
			}
			properties	= @{
				platformFaultDomainCount	= $az_res.PlatformFaultDomainCount		# [int]
				platformUpdateDomainCount	= $az_res.PlatformUpdateDomainCount		# [int]
				proximityPlacementGroup		= get-bicepReference $az_res.ProximityPlacementGroup.Id
				# scheduledEventsPolicy
				# virtualMachines
			}
		}
		add-resourcesALL $resource $az_res

		test-property -unknownProperty 'scheduledEventsPolicy'
		test-property -displayProperty 'virtualMachines'
	}
}

#--------------------------------------------------------------
function add-az_proximityPlacementGroups {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_proximityPlacementGroups) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'ppg'
		$script:bicepNamesReferenced = @()
		#========================================	

		# create resource
		$resource = @{
			type 		= 'Microsoft.Compute/proximityPlacementGroups'
			apiVersion	= '2025-04-01'
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			properties	= @{
				# colocationStatus
				# intent
				proximityPlacementGroupType	= convertTo-String $az_res.ProximityPlacementGroupType
			}
		}
		add-resourcesALL $resource $az_res -noZones

		test-property -displayProperty 'colocationStatus'
		test-property 'intent' $az_res.Intent
	}
}

#--------------------------------------------------------------
function add-az_virtualMachineScaleSet {
#--------------------------------------------------------------
	# only support VMSS FLEX!
	foreach ($az_res in $script:az_virtualMachineScaleSets) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'vmss'
		$script:bicepNamesReferenced = @()
		#========================================
		$orchestrationMode = convertTo-String $az_res.OrchestrationMode 

		# create resource
		$resource = @{
			type 				= 'Microsoft.Compute/virtualMachineScaleSets'
			apiVersion			= '2025-04-01'
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			# identity
			# plan
			# sku

			properties			= @{
				# additionalCapabilities
				# automaticRepairsPolicy
				# constrainedMaximumCapacity
				# doNotRunExtensionsOnOverprovisionedVMs
				# highSpeedInterconnectPlacement
				# hostGroup
				orchestrationMode			= $orchestrationMode
				# overprovision
				platformFaultDomainCount	= $az_res.PlatformFaultDomainCount # [int]
				# priorityMixPolicy
				# proximityPlacementGroup
				# resiliencyPolicy
				# scaleInPolicy
				# scheduledEventsPolicy
				singlePlacementGroup		= convertTo-Boolean $az_res.SinglePlacementGroup
				# skuProfile
				# spotRestorePolicy
				# upgradePolicy
				# virtualMachineProfile
				# zonalPlatformFaultDomainAlignMode
				# zoneBalance
			}
		}
		add-resourcesALL $resource $az_res

		# resource will be removed later if orchestrationMode <> Flexible
		if ($orchestrationMode -eq 'Flexible') {
			test-property 'identity' $az_res.Identity
			test-property 'plan' $az_res.Plan
			test-property 'sku' $az_res.Sku

			if ($az_res.HighSpeedInterconnectPlacement -ne 'None') {
				test-property 'highSpeedInterconnectPlacement' $az_res.HighSpeedInterconnectPlacement
			}
	
			test-property 'additionalCapabilities' $az_res.AdditionalCapabilities
			test-property 'automaticRepairsPolicy' $az_res.AutomaticRepairsPolicy
			test-property -unknownProperty 'constrainedMaximumCapacity'
			test-property 'doNotRunExtensionsOnOverprovisionedVMs' $az_res.DoNotRunExtensionsOnOverprovisionedVMs
			test-property 'hostGroup' $az_res.HostGroup
			test-property 'overprovision' $az_res.Overprovision
			test-property 'priorityMixPolicy' $az_res.PriorityMixPolicy
			test-property 'proximityPlacementGroup' $az_res.ProximityPlacementGroup
			test-property 'resiliencyPolicy' $az_res.ResiliencyPolicy
			test-property 'scaleInPolicy' $az_res.ScaleInPolicy
			test-property -unknownProperty 'scheduledEventsPolicy' 
			test-property 'skuProfile' $az_res.SkuProfile
			test-property 'spotRestorePolicy' $az_res.SpotRestorePolicy
			test-property 'upgradePolicy' $az_res.UpgradePolicy
			test-property 'virtualMachineProfile' $az_res.VirtualMachineProfile
			test-property -unknownProperty 'zonalPlatformFaultDomainAlignMode'
			test-property 'zoneBalance' $az_res.ZoneBalance
		}
	}
}

#--------------------------------------------------------------
function add-az_loadBalancers {
#--------------------------------------------------------------
	foreach ($az_res in $script:az_loadBalancers) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'lb'
		$script:bicepNamesReferenced = @()
		#========================================

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

			$loadBalancerBackendAddresses = @()
			foreach ($item in $pool.LoadBalancerBackendAddresses) {

				# IP address given
				if ($item.IpAddress.length -gt 0) {
					$loadBalancerBackendAddresses += @{
						name = $item.Name
						properties = @{
							ipAddress 		= $item.IpAddress
							virtualNetwork	= get-bicepReference $item.VirtualNetwork.Id
						}
					}
					#--------------------------------------------------------------
					# IpAddress is set in BICEP templpate, deployment succeeds, but IpAddress is not deployed!??
					# give a warning here:
					test-property 'backendAddressPools.IpAddress' $item.IpAddress
					#--------------------------------------------------------------
				}
			}

			$addressPool = @{
				name = $pool.Name
				properties = @{
					# drainPeriodInSeconds
					loadBalancerBackendAddresses	= $loadBalancerBackendAddresses
					# location
					# syncMode
					# tunnelInterfaces
					# virtualNetwork
				}
			}
			test-property -unknownProperty 'drainPeriodInSeconds'
			test-property -unknownProperty 'location'
			test-property 'backendAddressPools.syncMode' $pool.SyncMode
			test-property 'backendAddressPools.tunnelInterfaces' $pool.TunnelInterfaces
			test-property -displayProperty 'virtualNetwork' # defined in loadBalancerBackendAddresses

			$backendAddressPools += $addressPool
		}

		#--------------------------------------------------------------
		# frontendIPConfigurations
		foreach ($conf in $az_res.FrontendIpConfigurations) {

			$ipConfig = @{
				name		= $conf.Name
				properties	= @{
					# gatewayLoadBalancer
					privateIPAddress			= convertTo-String $conf.PrivateIpAddress
					privateIPAddressVersion		= convertTo-String $conf.PrivateIpAddressVersion
					privateIPAllocationMethod	= convertTo-String $conf.PrivateIpAllocationMethod
					publicIPAddress				= get-bicepReference $conf.PublicIpAddress.Id
					publicIPPrefix				= get-bicepReference $conf.PublicIPPrefix.Id
					subnet						= get-bicepReference $conf.Subnet.Id ([ref] $dependsOn)
				}
			}
			test-property 'frontendIpConf.gatewayLoadBalancer' $conf.GatewayLoadBalancer

			# add zones
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
		# ONLY POSSIBLE FOR VMSS 
		foreach ($pool in $az_res.inboundNatPools) {
			$natpool = @{
				name		= $pool.Name
				properties	= @{
					backendPort					= $pool.BackendPort # [int]
					enableFloatingIP			= convertTo-Boolean $pool.EnableFloatingIP
					enableTcpReset				= convertTo-Boolean $pool.EnableTcpReset
					frontendIPConfiguration		= get-bicepReference $pool.FrontendIPConfiguration.Id
					frontendPortRangeEnd		= $pool.FrontendPortRangeEnd # [int]
					frontendPortRangeStart		= $pool.FrontendPortRangeStart # [int]
					idleTimeoutInMinutes		= $pool.IdleTimeoutInMinutes # [int]
					protocol					= convertTo-String $pool.Protocol
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
					backendAddressPool			= get-bicepReference $rule.BackendAddressPool.Id
					backendPort					= $rule.BackendPort # [int]
					enableFloatingIP			= convertTo-Boolean $rule.EnableFloatingIP
					enableTcpReset				= convertTo-Boolean $rule.EnableTcpReset
					frontendIPConfiguration		= get-bicepReference $rule.FrontendIPConfiguration.Id
					frontendPort				= $rule.FrontendPort # [int]
					frontendPortRangeEnd		= $rule.FrontendPortRangeEnd # [int]
					frontendPortRangeStart		= $rule.FrontendPortRangeStart # [int]
					idleTimeoutInMinutes		= $rule.IdleTimeoutInMinutes # [int]
					protocol					= convertTo-String $rule.Protocol
				}
			}
			$inboundNatRules += $natrule
		}

		#--------------------------------------------------------------
		# loadBalancingRules
		foreach ($rule in $az_res.LoadBalancingRules) {

			$pools = @()
			foreach ($pool in $rule.BackendAddressPools) {
				$pools += get-bicepReference $pool.Id
			}

			$lbRule = @{
				name = $rule.Name
				properties = @{
					backendAddressPool			= get-bicepReference $rule.BackendAddressPool.Id
					backendAddressPools			= $pools
					backendPort					= $rule.BackendPort # [int]
					disableOutboundSnat			= convertTo-Boolean $rule.DisableOutboundSNAT
					enableConnectionTracking	= convertTo-Boolean $rule.EnableConnectionTracking
					enableFloatingIP			= convertTo-Boolean $rule.EnableFloatingIP
					enableTcpReset				= convertTo-Boolean $rule.EnableTcpReset
					frontendIPConfiguration		= get-bicepReference $rule.FrontendIPConfiguration.Id
					frontendPort				= $rule.FrontendPort # [int]
					idleTimeoutInMinutes		= $rule.IdleTimeoutInMinutes # [int]
					loadDistribution			= convertTo-String $rule.LoadDistribution
					probe						= get-bicepReference $rule.Probe.Id
					protocol					= convertTo-String $rule.Protocol
				}
			}
			
			$loadBalancingRules += $lbRule
		}

		#--------------------------------------------------------------
		# outboundRules
		foreach ($rule in $az_res.OutboundRules) {

			$frontendConfigs = @()
			foreach ($frontendConfig in $rule.FrontendIPConfigurations) {
				$frontendConfigs += get-bicepReference $frontendConfig.Id	
			}

			$obrule = @{
				name = $rule.Name
				properties = @{
					allocatedOutboundPorts		= $rule.AllocatedOutboundPorts # [int]
					backendAddressPool			= get-bicepReference $rule.BackendAddressPool.Id
					enableTcpReset				= convertTo-Boolean $rule.EnableTcpReset
					frontendIPConfigurations	= $frontendConfigs
					idleTimeoutInMinutes		= $rule.IdleTimeoutInMinutes # [int]
					protocol					= convertTo-String $rule.Protocol
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
					intervalInSeconds			= $probe.IntervalInSeconds # [int]
					noHealthyBackendsBehavior	= convertTo-String $probe.NoHealthyBackendsBehavior
					numberOfProbes				= $probe.NumberOfProbes # [int]
					port						= $probe.Port # [int]
					probeThreshold				= $probe.ProbeThreshold # [int]
					protocol					= convertTo-String $probe.Protocol
					requestPath					= convertTo-String $probe.RequestPath
				}
			}

			$loadBalancingProbes += $lbProbe
		}

		#--------------------------------------------------------------
		# create resource
		$dependsOn = @($dependsOn | Sort-Object -Unique)

		$resource = @{
			type 				= 'Microsoft.Network/loadBalancers'
			apiVersion			= '2025-05-01'
			dependsOn 			= $dependsOn
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			sku	= @{
				name = convertTo-String $az_res.Sku.Name
				tier = convertTo-String $az_res.Sku.Tier
			}

			properties			=  @{
				backendAddressPools			= $backendAddressPools
				frontendIPConfigurations	= $frontendIPConfigurations
				inboundNatPools				= $inboundNatPools
				inboundNatRules				= $inboundNatRules
				loadBalancingRules			= $loadBalancingRules
				outboundRules				= $outboundRules
				probes						= $loadBalancingProbes
				# scope
			}
		}
		add-resourcesALL $resource $az_res

		test-property -unknownProperty 'scope' 
	}
}

#--------------------------------------------------------------
function add-az_storageAccounts {
#--------------------------------------------------------------
	if ($copyVMsOnly) {
		return
	}

	# parent resource
	foreach ($az_res in $script:az_storageAccounts) {

		#========================================
		$script:testResourceName = $az_res.StorageAccountName
		$script:testResourceType = 'sa'
		$script:bicepNamesReferenced = @()
		#========================================

		if ($skipSaNwRules) {
			write-logFileWarning "Skipped network rules for storage account $script:testResourceName (parameter 'skipSaNwRules')"
		}

		# calculate networkAcls
		$ipRules = @()
		if (!$skipSaNwRules) {
			foreach ($rule in $az_res.NetworkRuleSet.IpRules) {
				$ipRules += @{
					action	= 'Allow'
					value	= convertTo-String $rule.IPAddressOrRange
				}
			}
		}

		$resourceAccessRules = @()
		if (!$skipSaNwRules) {
			foreach ($rule in $az_res.NetworkRuleSet.ResourceAccessRules) {
				$resourceAccessRules += @{
					resourceId	= convertTo-String $rule.ResourceId
					tenantId	= convertTo-String $rule.TenantId
				}
			}
		}

		$virtualNetworkRules = @()
		if (!$skipSaNwRules) {
			if ($differentTenantOrUser) {
				write-logFileWarning "Skipped network acls for storage account $script:testResourceName (multi-tenant copy)"
			}

			# "code": "NetworkAclsValidationFailure",
			# "message": "Validation of network acls failure: ... Only resources in germanywestcentral, germanynorth 
			#             can be ACL-ed to virtual networks in germanywestcentral.."
			elseif ($sourceLocation -ne $targetLocation) {
				write-logFileWarning "Skipped network acls for storage account $script:testResourceName (cross-region copy)"
			}

			else {
				foreach ($rule in $az_res.NetworkRuleSet.VirtualNetworkRules) {
					$virtualNetworkRules += @{
						action	= 'Allow'
						id		= convertTo-String $rule.VirtualNetworkResourceId
					}
				}
			}
		}

		$networkAcls = @{
			bypass 						= convertTo-String $az_res.NetworkRuleSet.Bypass
			defaultAction 				= convertTo-String $az_res.NetworkRuleSet.DefaultAction
			ipRules						= $ipRules
			# ipv6Rules
			resourceAccessRules			= $resourceAccessRules
			virtualNetworkRules			= $virtualNetworkRules
		}
		test-property -unknownProperty 'ipv6Rules' 

		#--------------------------------------------------------------
		$azureFilesIdentityBasedAuthentication = @{
			# activeDirectoryProperties
			defaultSharePermission	= convertTo-String $az_res.AzureFilesIdentityBasedAuth.DefaultSharePermission
			directoryServiceOptions	= convertTo-String $az_res.AzureFilesIdentityBasedAuth.DirectoryServiceOptions
			smbOAuthSettings		= @{
				isSmbOAuthEnabled	= convertTo-Boolean $az_res.AzureFilesIdentityBasedAuth.SmbOAuthSettings.IsSmbOAuthEnabled
			}
		}
		test-property 'activeDirectoryProperties' $az_res.AzureFilesIdentityBasedAuth.ActiveDirectoryProperties

		#--------------------------------------------------------------
		# create resource
		$resource = @{
			type 				= 'Microsoft.Storage/storageAccounts'
			apiVersion			= '2026-04-01'
			placement			= convertTo-String $az_res.ZonePlacementPolicy
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			identity			= get-identity $az_res
			kind				= convertTo-String $az_res.Kind
			sku 				= @{ name = $az_res.Sku.Name }
			
			properties = @{
				accessTier						= convertTo-String $az_res.AccessTier
				allowBlobPublicAccess			= convertTo-Boolean $az_res.AllowBlobPublicAccess
				allowCrossTenantReplication		= convertTo-Boolean $az_res.AllowCrossTenantReplication
				allowedCopyScope				= convertTo-String $az_res.AllowedCopyScope
				allowSharedKeyAccess			= convertTo-Boolean $az_res.AllowSharedKeyAccess
				# allowSharedKeyAccessForServices
				azureFilesIdentityBasedAuthentication = $azureFilesIdentityBasedAuthentication
				# customDomain
				# dataCollaborationPolicyProperties
				# defaultToOAuthAuthentication
				dnsEndpointType					= convertTo-String $az_res.DnsEndpointType
				# dualStackEndpointPreference
				# enableExtendedGroups
				# encryption
				# geoPriorityReplicationStatus
				# immutableStorageWithVersioning
				isHnsEnabled					= convertTo-Boolean $az_res.EnableHierarchicalNamespace
				isLocalUserEnabled				= convertTo-Boolean $az_res.EnableLocalUser
				isNfsV3Enabled					= convertTo-Boolean $az_res.EnableNfsV3
				isSftpEnabled					= convertTo-Boolean $az_res.EnableSftp
				keyPolicy = @{
					keyExpirationPeriodInDays	= $az_res.KeyPolicy.KeyExpirationPeriodInDays # [int]
				}
				largeFileSharesState			= convertTo-String $az_res.LargeFileSharesState
				minimumTlsVersion				= convertTo-String $az_res.MinimumTlsVersion
				networkAcls 					= $networkAcls
				publicNetworkAccess				= convertTo-String $az_res.PublicNetworkAccess
				routingPreference = @{
					publishInternetEndpoints	= convertTo-Boolean $az_res.RoutingPreference.PublishInternetEndpoints
					publishMicrosoftEndpoints	= convertTo-Boolean $az_res.RoutingPreference.PublishMicrosoftEndpoints
					routingChoice				= convertTo-String $az_res.RoutingPreference.RoutingChoice
				}
				# sasPolicy
				supportsHttpsTrafficOnly		= convertTo-Boolean $az_res.EnableHttpsTrafficOnly
			}
		}
		add-resourcesALL $resource $az_res -resName $az_res.StorageAccountName

		test-property -unknownProperty 'allowSharedKeyAccessForServices'
		test-property 'customDomain' $az_res.CustomDomain
		test-property -unknownProperty 'dataCollaborationPolicyProperties'
		test-property -unknownProperty 'defaultToOAuthAuthentication'
		test-property -unknownProperty 'dualStackEndpointPreference'
		test-property -unknownProperty 'enableExtendedGroups'
		test-property 'encryption' $az_res.Encryption
		test-property -displayProperty 'geoPriorityReplicationStatus' $az_res.GeoPriorityReplicationStatus
		test-property 'immutableStorageWithVersioning' $az_res.ImmutableStorageWithVersioning
		test-property 'sasPolicy' $az_res.SasPolicy
	}

	#-------------------------------------------------------------
	# child resource fileServices
	foreach ($az_res in $script:az_storageAccountsFileService) {

		$parentName = $az_res.StorageAccountName
		#========================================
		$script:testResourceName = $parentName
		$script:testResourceType = 'saFileService'
		$script:bicepNamesReferenced = @()
		#========================================

		$resource = @{
			type 		= 'Microsoft.Storage/storageAccounts/fileServices'
			apiVersion	= '2026-04-01'
			parent 		= "<$(get-bicepNameByType 'Microsoft.Storage/storageAccounts' $parentName)>"
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			properties	= @{
				# cors
				protocolSettings = @{
					# nfs
					smb = @{
						authenticationMethods		= convertTo-String $az_res.ProtocolSettings.Smb.AuthenticationMethods -separator ';'
						channelEncryption			= convertTo-String $az_res.ProtocolSettings.Smb.ChannelEncryption -separator ';'
						# encryptionInTransit
						kerberosTicketEncryption	= convertTo-String $az_res.ProtocolSettings.Smb.KerberosTicketEncryption -separator ';'
						multichannel = @{
							enabled					= convertTo-Boolean $az_res.ProtocolSettings.Smb.Multichannel.Enabled
						}
						versions					= convertTo-String $az_res.ProtocolSettings.Smb.Versions -separator ';'
					}
				}
				shareDeleteRetentionPolicy = @{
					allowPermanentDelete			= convertTo-Boolean $az_res.ShareDeleteRetentionPolicy.AllowPermanentDelete
					days							= $az_res.ShareDeleteRetentionPolicy.Days # [int]
					enabled							= convertTo-Boolean $az_res.ShareDeleteRetentionPolicy.Enabled
				}
			}
		}

		# name of fileServices = name of storageAccounts for BICEP
		add-resourcesALL $resource $az_res -resName "$parentName/$($az_res.Name)" -noRegion

		test-property 'cors' $az_res.Cors
		test-property 'nfs' $az_res.ProtocolSettings.Nfs
		test-property 'smb.encryptionInTransit' $az_res.ProtocolSettings.Smb.EncryptionInTransit
	}

	#-------------------------------------------------------------
	# child resource blobServices
	foreach ($az_res in $script:az_storageAccountsBlobService) {

		$parentName = $az_res.StorageAccountName
		#========================================
		$script:testResourceName = $parentName
		$script:testResourceType = 'saBlobService'
		$script:bicepNamesReferenced = @()
		#========================================

		$resource = @{
			type 		= 'Microsoft.Storage/storageAccounts/blobServices'
			apiVersion	= '2026-04-01'
			parent 		= "<$(get-bicepNameByType 'Microsoft.Storage/storageAccounts' $parentName)>"
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			properties	= @{
				# automaticSnapshotPolicyEnabled 	# Deprecated 
				changeFeed = @{
					enabled							= convertTo-Boolean $az_res.ChangeFeed.Enabled
					retentionInDays					= $az_res.ChangeFeed.RetentionInDays # [int]
				}
				containerDeleteRetentionPolicy = @{
					allowPermanentDelete			= convertTo-Boolean $az_res.ContainerDeleteRetentionPolicy.AllowPermanentDelete
					days							= $az_res.ContainerDeleteRetentionPolicy.Days # [int]
					enabled							= convertTo-Boolean $az_res.ContainerDeleteRetentionPolicy.Enabled
				}
				# cors
				defaultServiceVersion				= convertTo-String $az_res.DefaultServiceVersion
				deleteRetentionPolicy = @{
					allowPermanentDelete			= convertTo-Boolean $az_res.DeleteRetentionPolicy.AllowPermanentDelete
					days							= $az_res.DeleteRetentionPolicy.Days # [int]
					enabled							= convertTo-Boolean $az_res.DeleteRetentionPolicy.Enabled
				}
				isVersioningEnabled					= convertTo-Boolean $az_res.IsVersioningEnabled
				lastAccessTimeTrackingPolicy = @{
					blobType						= convertTo-array $az_res.LastAccessTimeTrackingPolicy.BlobType
					enable							= convertTo-Boolean $az_res.LastAccessTimeTrackingPolicy.Enable
					name							= convertTo-String $az_res.LastAccessTimeTrackingPolicy.Name
					trackingGranularityInDays		= $az_res.LastAccessTimeTrackingPolicy.TrackingGranularityInDays # [int]
				}
				restorePolicy = @{
					days							= $az_res.RestorePolicy.Days # [int]
					enabled							= convertTo-Boolean $az_res.RestorePolicy.Enabled
				}
				# staticWebsite
			}
		}

		# name of blobServices = name of storageAccounts for BICEP
		add-resourcesALL $resource $az_res -resName "$parentName/$($az_res.Name)" -noRegion

		test-property 'cors' $az_res.Cors
		test-property -unknownProperty 'staticWebsite'
	}

	#-------------------------------------------------------------
	# child resource container
	foreach ($az_res in $script:az_storageContainers) {

		# container not copied
		if ($az_res.Deleted -eq $true) {
			continue
		}

		# get resource name of blobServices (only one blob service allowed per storage account)
		$parentName = ($script:bicepNamesAll.values
					| Where-Object type -eq 'Microsoft.Storage/storageAccounts/blobServices'
					| Where-Object name -like "$($az_res.StorageAccountName)/*").name

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'saBlobContainer'
		$script:bicepNamesReferenced = @()
		#========================================


		$resource = @{
			type 		= 'Microsoft.Storage/storageAccounts/blobServices/containers'
			apiVersion	= '2026-04-01'
			parent 		= "<$(get-bicepNameByType 'Microsoft.Storage/storageAccounts/blobServices' $parentName)>"
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			properties			= @{
				defaultEncryptionScope		= convertTo-String $az_res.DefaultEncryptionScope
				denyEncryptionScopeOverride	= convertTo-Boolean $az_res.DenyEncryptionScopeOverride
				enableNfsV3AllSquash		= convertTo-Boolean $az_res.EnableNfsV3AllSquash
				enableNfsV3RootSquash		= convertTo-Boolean $az_res.EnableNfsV3RootSquash
				immutableStorageWithVersioning = @{
					enabled					= convertTo-Boolean $az_res.ImmutableStorageWithVersioning.Enabled
				}
				# metadata
				publicAccess				= convertTo-String $az_res.PublicAccess
			}
		}
		add-resourcesALL $resource $az_res -resName "$parentName/$($az_res.Name)" -noRegion

		test-property 'metadata' $az_res.Metadata
	}

	#-------------------------------------------------------------
	# child resource share
	foreach ($az_res in $script:az_storageShares) {

		# do not copy snapshots
		if ($null -ne $az_res.SnapshotTime) {
			continue
		}

		# share not copied
		if ($az_res.Deleted -eq $true) {
			continue
		}

		# get resource name of blobServices (only one blob service allowed per storage account)
		$parentName = ($script:bicepNamesAll.values
					| Where-Object type -eq 'Microsoft.Storage/storageAccounts/fileServices'
					| Where-Object name -like "$($az_res.StorageAccountName)/*").name

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'saFileShare'
		$script:bicepNamesReferenced = @()
		#========================================	

		$resource = @{
			type 		= 'Microsoft.Storage/storageAccounts/fileServices/shares'
			apiVersion	= '2026-04-01'
			parent 		= "<$(get-bicepNameByType 'Microsoft.Storage/storageAccounts/fileServices' $parentName)>"
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			properties = @{
				accessTier					= convertTo-String $az_res.AccessTier
				enabledProtocols			= convertTo-String $az_res.EnabledProtocols
				fileSharePaidBursting	= @{
					paidBurstingEnabled				= convertTo-Boolean $az_res.FileSharePaidBursting.PaidBurstingEnabled
					paidBurstingMaxBandwidthMibps	= $az_res.FileSharePaidBursting.PaidBurstingMaxBandwidthMibps # [int]
					paidBurstingMaxIop				= $az_res.FileSharePaidBursting.PaidBurstingMaxIops # [int]
				}
				# metadata
				provisionedBandwidthMibps	= $az_res.ProvisionedBandwidthMibps # [int]
				provisionedIops				= $az_res.ProvisionedIops # [int]
				rootSquash					= convertTo-String $az_res.RootSquash
				shareQuota					= $az_res.QuotaGiB # [int]
				# signedIdentifiers
			}
		}
		add-resourcesALL $resource $az_res -resName "$parentName/$($az_res.Name)" -noRegion

		test-property 'metadata' $az_res.Metadata
		test-property -unknownProperty 'signedIdentifiers'
	}
}

#--------------------------------------------------------------
function add-az_privateEndpoints {
#--------------------------------------------------------------
	if ($copyVMsOnly) {
		return
	}

	foreach ($az_res in $script:az_privateEndpoints) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'endpoint'
		$script:bicepNamesReferenced = @()
		#========================================

		#--------------------------------------------------------------
		$applicationSecurityGroups = @()
		foreach ($item in $az_res.ApplicationSecurityGroups) {
			$applicationSecurityGroups += get-bicepReference $item.Id
		}

		#--------------------------------------------------------------
		$privateLinkServiceConnections = @()
		$testTenant = $false
		foreach ($item in $az_res.PrivateLinkServiceConnections) {

			# get service ID, e.g. /subscriptions/../storageAccounts/saNameOld
			$privateLinkServiceId = $item.PrivateLinkServiceId

			$r = get-resourceComponents $privateLinkServiceId
			# old bicep name for saNameNew
			$oldName = $script:copySA[$r.mainResourceName].oldName
			
			# replace service ID if it is a copied storage account
			if (($r.subscriptionID -eq $sourceSubID) `
			-and ($r.resourceGroup -eq $sourceRG) `
			-and ($r.mainResourceType -eq 'storageAccounts') `
			-and ($null -ne $oldName)) {
				$privateLinkServiceId = "<$(get-bicepNameByType 'Microsoft.Storage/storageAccounts' $oldName).id>"
			}
			# keep service ID
			else {
				$testTenant = $true
			}

			# get groupIds
			$groupIds = @()
			foreach ($groupID in $item.GroupIds) {
				$groupIds += $groupID
			}

			# add privateLinkServiceConnection
			$privateLinkServiceConnections += @{
				name = $item.Name
				properties = @{
					groupIds = $groupIds
					privateLinkServiceId = $privateLinkServiceId
				}
			}
		}

		#--------------------------------------------------------------
		$customDnsConfigs = @()
		foreach ($item in $az_res.CustomDnsConfigs) {

			# get fqdn
			$fqdn = $item.Fqdn
			if ($null -ne $item.Fqdn) {		
				$s = $fqdn -split '\.'
				$oldName = $s[0]

				# change fqdn
				$newName = $script:copySA[$oldName].newName
				if ($null -ne $newName) {
					$s[0] = $newName
					$fqdn = $s -join '.'
				}
			}

			# get IpAddresses
			$IpAddresses = @()
			foreach ($addr in $item.IpAddresses) {
				$IpAddresses += $addr
			}

			# add customDnsConfig
			$customDnsConfigs += @{
				fqdn		= $fqdn
				ipAddresses = $IpAddresses
			}
		}

		#--------------------------------------------------------------
		$ipConfigurations = @()
		# get first NIC
		$id = $az_res.NetworkInterfaces[0].Id
		$az_nic = $script:az_networkInterfaces | Where-Object Id -eq $id

		$i = 0
		foreach ($conf in $az_nic.IpConfigurations) {
			$i++
			$groupId 	= convertTo-String $conf.PrivateLinkConnectionProperties.GroupId
			$memberName = convertTo-String $conf.PrivateLinkConnectionProperties.RequiredMemberName

			# add ipConfiguration
			$ipConfigurations += @{
				name = "$memberName$i" # create new, unique name
				properties = @{
					privateIPAddress	= convertTo-String $conf.PrivateIpAddress
					memberName			= $groupId 
					groupId				= $groupId 
				}
			}
		}

		#--------------------------------------------------------------
		# subnet
		$dependsOn = @()
		$subnet = get-bicepReference $az_res.Subnet.Id ([ref] $dependsOn)
		
		#--------------------------------------------------------------
		# create resource
		$resource = @{
			type 		= 'Microsoft.Network/privateEndpoints'
			apiVersion	= '2025-05-01'
			dependsOn	= $dependsOn
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			properties	= @{
				applicationSecurityGroups		= $applicationSecurityGroups
				customDnsConfigs				= $customDnsConfigs
				customNetworkInterfaceName		= ('privateEndpoint.' + (New-Guid).Guid) # create new, unique name
				ipConfigurations				= $ipConfigurations
				ipVersionType					= convertTo-String $az_res.IpVersionType
				# manualPrivateLinkServiceConnections
				privateLinkServiceConnections	= $privateLinkServiceConnections
				subnet = $subnet
			}
		}

		# test subnet
		$sub = Get-AzVirtualNetworkSubnetConfig -ResourceId $az_res.Subnet.Id -ErrorAction 'SilentlyContinue'

		# do not copy private endpoint to different tenant
		if ($testTenant -and $differentTenantOrUser) {
			write-logFileWarning "Cannot copy Private Endpoint '$($az_res.Name)' with different tenant/user"
		}

		# do not copy private endpoints to non-existing/non-accessable subnets
		elseif ($null -eq $sub) {
			write-logFileWarning "Cannot copy Private Endpoint '$($az_res.Name)' because subnet not found:" `
									$az_res.Subnet.Id
		}

		else {
			test-property 'manualPrivateLinkServiceConnections' $az_res.ManualPrivateLinkServiceConnections
			add-resourcesALL $resource $az_res
	
			#--------------------------------------------------------------
			# sub-resource privateDnsZoneGroups
			$endpointId 			= $az_res.Id
			$privateDnsZoneGroups	= @( $script:az_privateDnsZoneGroups | Where-Object Id -like "$endpointId/*" )
	
			foreach ($az_resDnsGrp in $privateDnsZoneGroups) {

				$privateDnsZoneConfigs = @()
				foreach ($conf in $az_resDnsGrp.PrivateDnsZoneConfigs) {
					$privateDnsZoneConfigs += @{
						name		= $conf.Name
						properties	= @{
							privateDnsZoneId = "<$(get-bicepNameById $conf.PrivateDnsZoneId).id>"
						}
					}
				}
			
				# create resource
				$resource = @{
					type 		= 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
					apiVersion	= '2025-05-01'
					parent 		= "<$(get-bicepNameByType 'Microsoft.Network/privateEndpoints' $az_res.Name)>"
					# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL
	
					properties	= @{
						privateDnsZoneConfigs = $privateDnsZoneConfigs
					}
				}
		
				add-resourcesALL $resource $az_resDnsGrp -resName "$endPointName/$($az_resDnsGrp.Name)" -noRegion
			}
		}
	}
}

#--------------------------------------------------------------
function add-az_dnsZones {
#--------------------------------------------------------------
	if ($copyVMsOnly) {
		return
	}

	foreach ($az_res in $script:az_dnsZones) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'dnsZone'
		$script:bicepNamesReferenced = @()
		#========================================

		$registrationVirtualNetworks = @()
		foreach ($item in $az_res.RegistrationVirtualNetworkIds) {
			$registrationVirtualNetworks += get-bicepReference $item
		}
		
		$resolutionVirtualNetworks = @()
		foreach ($item in $az_res.ResolutionVirtualNetworkIds) {
			$resolutionVirtualNetworks += get-bicepReference $item
		}

		$resource = @{
			type		= 'Microsoft.Network/dnsZones'
			apiVersion	= '2018-05-01'
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			properties	= @{
				registrationVirtualNetworks = $registrationVirtualNetworks
				resolutionVirtualNetworks	= $resolutionVirtualNetworks
				zoneType					= convertTo-String $az_res.ZoneType
			}
		}
		add-resourcesALL $resource $az_res
	}

	#--------------------------------------------------------------
	# dnsRecordSets
	foreach ($az_res in $script:az_dnsRecordSets) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'dnsZoneRS'
		$script:bicepNamesReferenced = @()
		#========================================
		$recordType = convertTo-String $az_res.RecordType
		$parentName = convertTo-String $az_res.ZoneName
	
		# metadata
		$metadata = @{}
		foreach ($key in $az_res.Metadata.Keys) {
			$metadata.$key = remove-angleBrackets $az_res.Metadata.$key
		}

		$resource = @{
			type		= "Microsoft.Network/dnsZones/$recordType"
			apiVersion	= '2018-05-01'
			parent 		= "<$(get-bicepNameByType 'Microsoft.Network/dnsZones' $parentName)>"
			properties	= @{
				metadata			= $metadata
				TTL					= $az_res.Ttl	# [int]
				targetResource		= get-bicepReference $az_res.TargetResourceId -allowSubresource
				# ARecords		# set by add-az_dnsRecords
				# AAAARecords	# set by add-az_dnsRecords
				# caaRecords	# set by add-az_dnsRecords
				# CNAMERecord	# set by add-az_dnsRecords
				# dnssecConfigs
				# DS
				# MXRecords		# set by add-az_dnsRecords
				# NAPTRRecords
				# NSRecords		# set by add-az_dnsRecords
				# PTRRecords	# set by add-az_dnsRecords
				# SOARecord		# set by add-az_dnsRecords
				# SRVRecords	# set by add-az_dnsRecords
				# TLSA
				# TXTRecords	# set by add-az_dnsRecords
			}
		}

		# The provided nameservers in a record set of type 'NS' with name '@' cannot be modified or removed.
		if (($recordType -ne 'NS') -or ($az_res.Name -ne '@')) {

			$success = add-az_dnsRecords ([ref] $az_res.Records) $recordType $resource.properties
			if ($success) {
				add-resourcesALL $resource $az_res -bicepResName "$parentName/$($az_res.Name)" -noRegion
			}
		}
	}
}

#--------------------------------------------------------------
function add-az_dnsRecords {
#--------------------------------------------------------------
	param (
		[ref] $ref,			# ([ref] $az_res.Records)
		$recordType,
		$properties,		# $resource.properties (reference, since this is a hash table)
		[switch] $private
	)

	$records = @()
	switch ($recordType) {
		#--------------------------------------------------------------
		'A' {
			foreach ($item in $ref.Value) {
				$records += @{
					ipv4Address = $item.Ipv4Address
				}
			}
			if ($private) {
				$properties.aRecords = $records
			}
			else {
				$properties.ARecords = $records
			}
		}

		#--------------------------------------------------------------
		'AAAA' {
			foreach ($item in $ref.Value) {
				$records += @{
					ipv6Address = $item.Ipv6Address
				}
			}
			if ($private) {
				$properties.aaaaRecords = $records
			}
			else {
				$properties.AAAARecords = $records

			}	
		}

		#--------------------------------------------------------------
		'CAA' {
			foreach ($item in $ref.Value) {
				$records += @{
					flags = $item.Flags
					tag   = $item.Tag
					value = $item.Value
				}
			}
			if ($private) {
				# does not exist
				write-logFileWarning "DNS entry '$recordType' set in source RG but skipped by RGCOPY"
				return $false
			}
			else {
				$properties.caaRecords = $records
			}	
		}

		#--------------------------------------------------------------
		'CNAME' {
			$records = $ref.Value.Cname
			if ($private) {
				$properties.cnameRecord = @{
					cname = $records
				}
			}
			else {
				$properties.CNAMERecord = @{
					cname = $records
				}	
			}
		}

		#--------------------------------------------------------------
		'dnssecConfigs' {
			write-logFileWarning "DNS entry '$recordType' set in source RG but skipped by RGCOPY"
			return $false
		}

		#--------------------------------------------------------------
		'DS' {
			write-logFileWarning "DNS entry '$recordType' set in source RG but skipped by RGCOPY"
			return $false
		}

		#--------------------------------------------------------------
		'MX' {
			foreach ($item in $ref.Value) {
				$records += @{
					exchange 	= $item.Exchange
					preference	= $item.Preference
				}
			}
			if ($private) {
				$properties.mxRecords = $records
			}
			else {
				$properties.MXRecords = $records
			}
		}

		#--------------------------------------------------------------
		'NAPTR' {
			write-logFileWarning "DNS entry '$recordType' set in source RG but skipped by RGCOPY"
			return $false
		}

		#--------------------------------------------------------------
		'NS' {
			foreach ($item in $ref.Value) {
				$records += @{
					nsdname 	= $item.Nsdname
				}
			}
			if ($private) {
				# does not exist
				write-logFileWarning "DNS entry '$recordType' set in source RG but skipped by RGCOPY"
				return $false
			}
			else {
				$properties.NSRecords = $records
			}
		}

		#--------------------------------------------------------------
		'PTR' {
			foreach ($item in $ref.Value) {
				$records += @{
					ptrdname 	= $item.Ptrdname
				}
			}
			if ($private) {
				$properties.ptrRecords = $records
			}
			else {
				$properties.PTRRecords = $records
			}
		}

		#--------------------------------------------------------------
		'SOA' {
			$records = @{
				email			= $ref.Value.Email
				expireTime		= $ref.Value.ExpireTime
				host			= $ref.Value.Host
				minimumTtl		= $ref.Value.MinimumTtl
				refreshTime		= $ref.Value.RefreshTime
				retryTime		= $ref.Value.RetryTime
				serialNumber	= $ref.Value.SerialNumber
			}
			if ($private) {
				$properties.soaRecord = $records
			}
			else {
				$properties.SOARecord = $records
			}
		}

		#--------------------------------------------------------------
		'SRV' {
			foreach ($item in $ref.Value) {
				$records += @{
					port 		= $item.Port
					priority 	= $item.Priority
					target 		= $item.Target
					weight 		= $item.Weight
				}
			}
			if ($private) {
				$properties.srvRecords = $records
			}
			else {
				$properties.SRVRecords = $records
			}
		}

		#--------------------------------------------------------------
		'TLSA' {
			write-logFileWarning "DNS entry '$recordType' set in source RG but skipped by RGCOPY"
			return $false
		}

		#--------------------------------------------------------------
		'TXT' {
			foreach ($item in $ref.Value) {
				$strings = @()
				foreach ($string in $item.Value) {
					$strings += $string
				}
				$records += @{
					value 		= $strings
				}
			}
			if ($private) {
				$properties.txtRecords = $records
			}
			else {
				$properties.TXTRecords = $records
			}	
		}

		#--------------------------------------------------------------
		Default {
			write-logFileWarning "DNS entry '$recordType' set in source RG but skipped by RGCOPY"
			return $false
		}
	}
	return $true
}

#--------------------------------------------------------------
function add-az_privateDnsZones {
#--------------------------------------------------------------
	if ($copyVMsOnly) {
		return
	}

	# privateDnsZones
	foreach ($az_res in $script:az_privateDnsZones) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'privDnsZone'
		$script:bicepNamesReferenced = @()
		#========================================

		$resource = @{
			type		= 'Microsoft.Network/privateDnsZones'
			apiVersion	= '2024-06-01'
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			properties	= @{}
		}
		add-resourcesALL $resource $az_res -regionGlobal
	}

	#--------------------------------------------------------------
	# privateDnsRecordSets
	foreach ($az_res in $script:az_privateDnsRecordSets) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'privDnsZoneRS'
		$script:bicepNamesReferenced = @()
		#========================================
		$recordType = convertTo-String $az_res.RecordType
		$parentName = convertTo-String $az_res.ZoneName

		# metadata
		$metadata = @{}
		foreach ($key in $az_res.Metadata.Keys) {
			$metadata.$key = remove-angleBrackets $az_res.Metadata.$key
		}

		$resource = @{
			type		= "Microsoft.Network/privateDnsZones/$recordType"
			apiVersion	= '2024-06-01'
			parent 		= "<$(get-bicepNameByType 'Microsoft.Network/privateDnsZones' $parentName)>"
			properties	= @{
				metadata		= $metadata
				ttl				= $az_res.Ttl	# [int]
				# aRecords		# set by add-az_dnsRecords
				# aaaaRecords	# set by add-az_dnsRecords
				# cnameRecord	# set by add-az_dnsRecords
				# mxRecords		# set by add-az_dnsRecords
				# ptrRecords	# set by add-az_dnsRecords
				# soaRecord		# set by add-az_dnsRecords
				# srvRecords	# set by add-az_dnsRecords
				# txtRecords	# set by add-az_dnsRecords
			}
		}

		# The provided nameservers in a record set of type 'NS' with name '@' cannot be modified or removed.
		if (($recordType -ne 'NS') -or ($az_res.Name -ne '@')) {
			
			$success = add-az_dnsRecords ([ref] $az_res.Records) $recordType $resource.properties -private
			if ($success) {
				# check if DNS record was from a copied storage account
				if ($az_res.Name -eq $script:copySA[$az_res.Name].oldName) {
					$oldName = $script:copySA[$az_res.Name].oldName
					$newName = $script:copySA[$az_res.Name].newName
					write-logFileUpdates 'privDnsZone' $parentName -warning "Updating DNS record from '$oldName' to '$newName'"
					add-resourcesALL $resource $az_res -bicepResName "$parentName/$($az_res.Name)" -noRegion -resName $newName
				}

				else {
					add-resourcesALL $resource $az_res -bicepResName "$parentName/$($az_res.Name)" -noRegion
				}
			}
		}
	}

	#--------------------------------------------------------------
	# virtualNetworkLinks
	foreach ($az_res in $script:az_privateDnsVirtualNetworkLinks) {

		#========================================
		$script:testResourceName = $az_res.Name
		$script:testResourceType = 'privDnsZoneNwLink'
		$script:bicepNamesReferenced = @()
		#========================================
		$parentName = (get-resourceComponents $az_res.ResourceId).mainResourceName

		$resource = @{
			type		= 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
			apiVersion	= '2024-06-01'
			parent		= "<$(get-bicepNameByType 'Microsoft.Network/privateDnsZones' $parentName)>"
			# name, location, extendedLocation, placement, tags, zones:		set in add-resourcesALL

			properties	= @{
				registrationEnabled = convertTo-Boolean $az_res.RegistrationEnabled
				resolutionPolicy	= convertTo-String $az_res.ResolutionPolicy
				virtualNetwork 		= get-bicepReference $az_res.VirtualNetworkId # not VirtualNetwork.Id !
			}
		}
		add-resourcesALL $resource $az_res -bicepResName "$parentName/$($az_res.Name)" -regionGlobal
	}
}

#-------------------------------------------------------------
function step-prepareClone {
#--------------------------------------------------------------
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
function step-bicepTemplate {
#--------------------------------------------------------------
	if ($skipArmTemplate -and ($justCopyDisks.count -eq 0)) {
		return
	}

	# update parameters for justCopyDisks
	if ($justCopyDisks.count -ne 0) {
		write-stepStart "Updating disk SKU and Zone for 'justCopyDisks'"

		update-paramSetDiskSku
		update-diskZone
		update-paramSetDiskTier
		update-paramSetDiskBursting
		update-paramSetDiskMaxShares
		update-paramSetDiskIOps
		update-paramSetDiskMBps
		update-diskMBpsAndIOps

		write-logFile
		write-logFile
		compare-quota
		write-stepEnd
		return
	}

	# create template in all other cases
	write-stepStart "CREATE BICEP TEMPLATE" -startMeasurement

	get-az_all
	new-templateBicep
	write-logFile
	

	if ($setVmDeploymentOrder.count -ne 0) {
		#--------------------------------------------------------------
		write-taskStart "Deployment order of VMs"
		#--------------------------------------------------------------
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
		| Out-String -Width $screenWidthSmall
		| write-logFilePipe
	}

	show-targetVMs
	compare-quota
	get-requiredStorageAccounts

	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
function get-requiredStorageAccounts {
#--------------------------------------------------------------
	$script:networkAccess = @{}

	# storage account for COPY SNAPSHOTS TO BLOBS
	# ipRule, subnetRule, nspIpRule will be created when SA is created and when BLOB copy is resumed
	if ($blobCopyNeeded) {
		$script:networkAccess[$targetSA] = @{
			storageAccount 	= $targetSA
			location 		= 'targetRG'
			usage 			= 'blobCopy'
			controlPlane 	= 'saIpRule'
			dataPlane		= ''
		}

		if ($isAzure) {
			$script:networkAccess[$targetSA].controlPlane = 'subnetRule'
		}
		elseif ($targetSubAllowNSP) {
			$script:networkAccess[$targetSA].controlPlane = 'nspIpRule'
		}

		# storage account for ARCHIVE mode
		# deprecated, NOT FOR MS INTERNAL SUBSCRIPTIONS
		# public network access enabled
		if ($archiveMode) {
			$script:networkAccess[$targetSA].controlPlane = 'publicNetworkAccess'
		}
	}

	# storage account for file copy (ANF)
	# private endpoint will be created during backup/restore mount points
	if ($fileCopyNeeded) {
		$script:networkAccess[$sourceSA] = @{
			storageAccount 	= $sourceSA
			location 		= 'sourceRG'
			usage 			= 'fileCopy'
			controlPlane 	= 'saIpRule'
			dataPlane 		= 'privateEndpoint'
		}

		if ($isAzure) {
			$script:networkAccess[$sourceSA].controlPlane = 'subnetRule'
		}
		elseif ($sourceSubAllowNSP) {
			$script:networkAccess[$sourceSA].controlPlane = 'nspIpRule'
		}
	}

	# copied storage accounts (created in ARM template)
	if ($shareCopyNeeded) {
		$script:copySA.Values
		| Where-Object sourceRG -eq $true
		| ForEach-Object {
	
			$oldname = $_.oldName
			$newName = $_.newName
	
			$script:networkAccess[$oldName] = @{
				storageAccount 	= $oldName
				location 		= 'sourceRG'
				usage 			= 'azCopy'
				controlPlane 	= 'saIpRule'
				dataPlane		= ''
			}
	
			$script:networkAccess[$newName] = @{
				storageAccount 	= $newName
				location 		= 'targetRG'
				usage 			= 'azCopy'
				controlPlane 	= 'saIpRule'
				dataPlane		= ''
			}


			if ($isAzure) {
				$script:networkAccess[$oldName].controlPlane = 'subnetRule'
				$script:networkAccess[$newName].controlPlane = 'subnetRule'
			}
			else {
				if ($sourceSubAllowNSP) {
					$script:networkAccess[$oldName].controlPlane = 'nspIpRule'
				}
				if ($targetSubAllowNSP) {
					$script:networkAccess[$newName].controlPlane = 'nspIpRule'
				}
			}
		}
	}

	# display storage accounts
	if ($script:networkAccess.Values.Count -gt 0) {

		write-taskStart "Required storage accounts"

		$script:networkAccess.Values
		| Select-Object storageAccount, location, usage, controlPlane, dataPlane
		| Sort-Object usage, location
		| Format-Table
		| Out-String -Width $screenWidthLarge
		| write-logFilePipe
	}
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
			new-snapshotsVolumes
		}
	}

	elseif ($stopVMsSourceRG -and !$simulate) {
		stop-VMs $sourceRG $script:sourceVMs
	}

	show-snapshots
}

#--------------------------------------------------------------
function new-runningTasks {
#--------------------------------------------------------------
	param (
		$action	# 'backup' or 'restore'
	)

	$script:runningTasks = @()

	if ($action -eq 'backup') {
		$rg = $sourceRG
	}
	else {
		$rg = $targetRG
	}

	$script:copyVMs.values
	| Where-Object {$_.MountPoints.count -ne 0}
	| ForEach-Object {

		$vmName = $_.Name
		
		foreach ($mp in $_.MountPoints) {

			$pathClean = $mp.Path -replace '/', '-'
			$pathClean = $pathClean -replace '\.\-', '.'

			$script:runningTasks += @{
				vmName 		= $vmName 
				mountPoint	= $mp.Path
				action		= $action
				logRemote	= "$action.log"
				logLocal	= Join-Path -Path $pathExportFolder -ChildPath "$action.$rg.$vmName.$pathClean.txt"
			}
		}
	}
}

#--------------------------------------------------------------
function wait-restore {
#--------------------------------------------------------------
	if ($simulate -or $skipRestore -or ($script:mountPointsCount -eq 0)) {
		return
	}

	set-context $sourceSub -azCliContext # *** CHANGE SUBSCRIPTION **************
	wait-mountPoint 'RESTORE'

	set-context $targetSub # *** CHANGE SUBSCRIPTION **************
	remove-endpoint $targetRG
	write-logFile
}

#--------------------------------------------------------------
function wait-backup {
#--------------------------------------------------------------
	if ($simulate -or $skipBackups -or ($script:mountPointsCount -eq 0)) {
		return
	}

	set-context $sourceSub -azCliContext # *** CHANGE SUBSCRIPTION **************
	wait-mountPoint 'BACKUP'

	write-logFileWarning "Some VMs in source resource group '$sourceRG' are still running"
	write-logFile
	
}

#--------------------------------------------------------------
function start-restore {
#--------------------------------------------------------------
	if ($simulate -or $skipRestore -or ($script:mountPointsCount -eq 0)) {
		return
	}

	set-context $targetSub # *** CHANGE SUBSCRIPTION **************
	new-runningTasks 'restore'
	if ($waitRestore) {
		return
	}

	write-stepStart "START RESTORE FILES" -startMeasurement

	#--------------------------------------------------------------
	write-taskStart "grant network access to storage account"
	grant-saAccess4controlPlane 'fileCopy' $targetRG

	#--------------------------------------------------------------
	write-taskStart 'restore files from NFS share to volumes/disks'
	restore-mountPoint
	# this sets $skipRestore = $True if there is nothing to restore

	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
function start-backup {
#--------------------------------------------------------------
	if ($simulate -or $skipBackups -or ($script:mountPointsCount -eq 0)) {
		return
	}

	set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
	new-runningTasks 'backup'
	if ($waitBackup) {
		return
	}

	write-stepStart "START BACKUP FILES" -startMeasurement

	# collect not-running VMs
	$toBeStartedVMs = @()
	$script:sourceVMs = @( Get-AzVM `
								-ResourceGroupName $sourceRG `
								-status `
								-WarningAction	'SilentlyContinue' `
								-ErrorAction 'SilentlyContinue' )

	$script:copyVMs.values
	| Where-Object {$_.MountPoints.count -ne 0}
	| ForEach-Object {

		$vmName = $_.Name

		# get power state
		$powerState = ($script:sourceVMs | Where-Object Name -eq $vmName).PowerState

		if ($powerState -ne 'VM running') {
			$toBeStartedVMs += $vmName
		}
	}

	# start needed VMs (HANA and SAP must NOT auto-start)
	if ($toBeStartedVMs.count -ne 0) {
		#--------------------------------------------------------------
		write-taskStart "Start VMs before creating backup" $maxDOP
		start-parallelVMs $sourceRG $toBeStartedVMs
	}

	#--------------------------------------------------------------
	write-taskStart "Create storage account with NFS share"
	write-logFile "NFS Share for file backup/restore:"
	write-logFileTab 'Resource Group' $sourceRG
	new-storageAccount $sourceSub $sourceSubID $sourceRG $sourceSA $sourceLocation -fileStorage
	grant-saAccess4controlPlane 'fileCopy' $sourceRG

	#--------------------------------------------------------------
	write-taskStart 'Backup files from volumes/disks to NFS share'
	write-logFileWarning "Backups from volumes are using NetApp snapshot 'rgcopy', if exists"
	write-logFileWarning "Backups from disks are NOT using a snapshot"
	backup-mountPoint

	write-stepEnd -endMeasurement
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

	$text += "	#---
}
$PSCommandPath @param
"

	Set-Content -Path $restorePath -Value $text -ErrorAction 'SilentlyContinue'
	if (!$?) {
		write-logFileError "Could not save RGCOPY PowerShell template" `
							"Failed writing file '$restorePath'"
	}
	$script:logFiles += $restorePath
	write-zipFile
	if ($script:errorOccured) {
		write-logFileError "Could not save file to storage account BLOB" `
							"File name: '$zipPath2'" `
							"Storage account container: '$targetSaContainer'"
	}
}

#--------------------------------------------------------------
function remove-remoteBlobs {
#--------------------------------------------------------------
	if (!$blobCopyNeeded) {
		return
	}

	if ($keepRemoteSnapshotsBlobs) { 
		write-logFileWarning "Storage account '$targetSA' has not been deleted" `
							"because parameter 'keepRemoteSnapshotsBlobs' was set"
		return
	}

	# create disks before BICEP deployment
	if ($createDisksManually) {
		if ($skipDiskCreation) { 
			write-logFileWarning "Storage account '$targetSA' has not been deleted" `
								"because manual disk creation was skipped"
		}
		else {
			remove-storageAccount $targetRG $targetSA $targetSub $targetSubID
		}
	}

	# create disks during BICEP deployment
	else {
		if ($skipDeployment) { 
			write-logFileWarning "Storage account '$targetSA' has not been deleted" `
								"because BICEP deployment was skipped"
		}
		else {
			remove-storageAccount $targetRG $targetSA $targetSub $targetSubID
		}
	}
}

#--------------------------------------------------------------
function start-remoteBlobs {
#--------------------------------------------------------------
	if ($archiveMode) {
		save-archiveTemplate
	}

	if ($simulate) {
		return
	}

	if ($blobCopyNeeded) {
		# run BLOB copy using AzCopy
		if ($useAzCopy) {
			grant-copySnapshots2Blobs
			start-azCopyJobsBlobs
		}

		# start BLOB copy
		else {
			if (!$waitRemoteCopy) {
				grant-copySnapshots2Blobs
				start-copySnapshots2Blobs
			}
		}
	}
}

#--------------------------------------------------------------
function wait-remoteBlobs {
#--------------------------------------------------------------
	if ($simulate) {
		return
	}

	# wait for BLOB copy
	if ($blobCopyNeeded) {
		# run BLOB copy using AzCopy
		if ($useAzCopy) {
			wait-azCopyJobs
			revoke-copySnapshots2Blobs
		}

		else {
			if ($waitRemoteCopy) {
				grant-saAccess4controlPlane 'blobCopy'
				new-blobCopyToken
				write-logFile
			}
			wait-copySnapshots2Blobs
			revoke-copySnapshots2Blobs
		}
	}
}

#--------------------------------------------------------------
function start-remoteSnapshots {
#--------------------------------------------------------------
	if ($simulate) {
		return
	}

	# start and wait SNAPSHOT COPY
	if ($snapshotCopyNeeded) {
		if (!$waitRemoteCopy) {
			# remove-remoteSnapshots	# only needed if previous RGCOPY run fails
			copy-snapshots
		}
	}
}

#--------------------------------------------------------------
function wait-remoteSnapshots {
#--------------------------------------------------------------
	if ($simulate) {
		return
	}

	# start and wait SNAPSHOT COPY
	if ($snapshotCopyNeeded) {
		wait-copySnapshots
	}
}

#--------------------------------------------------------------
function remove-remoteSnapshots {
#--------------------------------------------------------------
	if (!$snapshotCopyNeeded) {
		return
	}

	if ($keepRemoteSnapshotsBlobs) { 
		write-logFileWarning "Copied Snapshots have not been deleted" `
							"because parameter 'keepRemoteSnapshotsBlobs' was set"
		return
	}

	$snapshotNames = ( $script:copyDisks.Values `
						| Where-Object { (($_.DiskSwapNew -eq $True) -or (($_.Skip -ne $True) -and ($_.DiskSwapOld -ne $True))) } `
						| Where-Object SnapshotCopy -eq $True ).SnapshotName

	if (($snapshotNames.count -gt 0) -and !$skipRemoteCopy) {
		remove-snapshots $targetRG $snapshotNames
	}
}

#--------------------------------------------------------------
function remove-localSnapshots {
#--------------------------------------------------------------
	$snapshotNames = ( $script:copyDisks.Values `
						| Where-Object { (($_.DiskSwapNew -eq $True) -or (($_.Skip -ne $True) -and ($_.DiskSwapOld -ne $True))) } `
						| Where-Object SnapshotSwap -ne $True ).SnapshotName

	if ($snapshotNames.count -gt 0) {
		
		if ($deleteSnapshots) {
			remove-snapshots $sourceRG $snapshotNames
		}
		else {
			write-logFileWarning "Parameter 'deleteSnapshots' was not supplied" `
								"Snapshots '*.rgcopy' in source RG '$sourceRG' have not been deleted"
		}
	}
}

#--------------------------------------------------------------
function step-deployment {
#--------------------------------------------------------------
	$script:sapAlreadyStarted = $False
	if ($justCopyDisks.count -ne 0) {
		if (!$simulate) {
			new-disks
		}
	}

	if ($skipDeployment) {
		return
	}

	#--------------------------------------------------------------
	# Deploy Virtual Machines

	# creating disks manually
	if ($createDisksManually -and !$skipDiskCreation) {
		new-disks
	}

	# deployment (with or without disks)
	deploy-templateTarget $exportPath "$sourceRG.$timestampSuffix"

	#--------------------------------------------------------------
	if (!$cloneOrMergeMode) {
		get-targetVMs
		if ($patchVMsTargetRG) {
			write-logFile
			write-logFile
			step-patchOS
		}
	}

	#--------------------------------------------------------------
	# Deploy various Extensions
	if (!$skipExtensions) {
		if ($installExtensionsSapMonitor.count -gt 0) {
			deploy-sapMonitor
		}
	
		if ($diagSettingsSA.length -gt 0) {
			if ($diagSettingsContainer.length -gt 0) {
				deploy-linuxDiagnostic
			}
		}
	
		if ($monitorRG.length -gt 0) {
			deploy-MonitorRules
		}
	}

	#--------------------------------------------------------------
	# run Post Deployment Script
	if ($pathPostDeploymentScript.length -ne 0) {
		start-sap $targetRG | Out-Null
		invoke-localScript $pathPostDeploymentScript 'pathPostDeploymentScript'
	}
}

#--------------------------------------------------------------
function grant-saAccess4controlPlane {
#--------------------------------------------------------------
	param (
		$type,
		$rg
	)

	$script:waitRequired = $false

	#--------------------------------------------------------------
	# storage account for BLOB copy
	if ($type -eq 'blobCopy') {
		if ($isAzure) {
			# allow subnet of control plane VM
			get-subnetIdControlPlane
			add-subnetRule $targetSA $targetRG $targetSub $subnetIdControlPlane
		}
		else {
			# set saRule or nspRule for control plane
			get-ipAddressControlPlane
			grant-ipAccess  $script:ipAddressControlPlane $targetSA $targetRG $targetSub $targetSubID
		}	
	}

	#--------------------------------------------------------------
	# storage account for file copy
	if ($type -eq 'fileCopy') {
		if ($isAzure) {
			# access to control plane VM
			get-subnetIdControlPlane
			add-subnetRule $sourceSA $sourceRG $sourceSub $subnetIdControlPlane
		}
		else {
			write-logFile
			write-logFile "Adding IP rules for the control plane (local PC):"

			# set saRule or nspRule for control plane
			get-ipAddressControlPlane
			grant-ipAccess  $script:ipAddressControlPlane $sourceSA $sourceRG $sourceSub $sourceSubID
		}

		# access to source RG (subnet rule does not work here)
		if ($rg -eq $sourceRG) {
			new-endpoint $sourceRG
		}
		
		# access to target RG (subnet rule does not work here)
		if ($rg -eq $targetRG) {

			if ($sourceSub -eq $targetSub) {
				new-endpoint $targetRG
			}
			else {
				new-endpoint $targetRG -manualApproval
			}
		}
	}

	#--------------------------------------------------------------
	# storage accounts for sa copy
	if ($type -eq 'saCopy') {
		if (!$isAzure) {
			write-logFile
			write-logFile "Adding IP rules for the control plane (local PC):"
			get-ipAddressControlPlane
		}
		else {
			get-subnetIdControlPlane
		}

		$script:copySA.values
		| Where-Object sourceRG -eq $true
		| Sort-Object oldName
		| ForEach-Object {
	
			$oldName = $_.oldName	# storage account name source
			$newName = $_.newName	# storage account name target
	
			$count = ($script:allShares 
						| Where-Object StorageAccount -eq $oldName 
						| Where-Object Skip -ne $true).count
			
			if ($count -gt 0) {
				if ($isAzure) {
					# allow subnet of control plane VM
					write-logFile "Grant access for copying storage account $oldName" -ForegroundColor 'green'
					add-subnetRule $oldName $sourceRG $sourceSub $subnetIdControlPlane
					add-subnetRule $newName $targetRG $targetSub $subnetIdControlPlane
					write-logFile
				}
				else {
					# # set saRule or nspRule for control plane
					grant-ipAccess  $script:ipAddressControlPlane $oldName $sourceRG $sourceSub $sourceSubID
					grant-ipAccess  $script:ipAddressControlPlane $newName $targetRG $targetSub $targetSubID
				}
			}
		}
	}

	if ($script:waitRequired) {
		# 10 seconds are often not enough
		write-logFile "Waiting $waitSeconds4nwRule seconds after granting access..."
		Start-Sleep -Seconds $waitSeconds4nwRule
	}
}

#--------------------------------------------------------------
function revoke-saAccess4controlPlane {
#--------------------------------------------------------------
	if (!$copySaRevokeCpAccess) {
		return
	}

	write-stepStart "Revoking network access from storage accounts"

	#--------------------------------------------------------------
	# storage account for BLOB copy
	# keep access

	#--------------------------------------------------------------
	# storage account for file copy
	# keep access

	#--------------------------------------------------------------
	# storage accounts for sa copy
	$script:copySA.values
	| Where-Object sourceRG -eq $true
	| Sort-Object oldName
	| ForEach-Object {

		$oldName = $_.oldName	# storage account name source
		$newName = $_.newName	# storage account name target

		$count = ($script:allShares 
					| Where-Object StorageAccount -eq $oldName 
					| Where-Object Skip -ne $true).count
		
		if ($count -gt 0) {
			if ($isAzure) {
				get-subnetIdControlPlane
				remove-subnetRule $oldName $sourceRG $sourceSub $subnetIdControlPlane
				remove-subnetRule $newName $targetRG $targetSub $subnetIdControlPlane
			}
			else {
				get-ipAddressControlPlane
				revoke-ipAccess  $script:ipAddressControlPlane $oldName $sourceRG $sourceSub $sourceSubID
				revoke-ipAccess  $script:ipAddressControlPlane $newName $targetRG $targetSub $targetSubID
			}
		}
	}
}

#--------------------------------------------------------------
function step-copySaContent {
#--------------------------------------------------------------
	if (!$shareCopyNeeded -or $simulate -or $waitRestore) {

		$script:copySA.values
		| Where-Object sourceRG -eq $true
		| ForEach-Object {
			write-logFileWarning "Content of storage account $($_.oldName) not copied to $($_.newName)"
		}

		write-logFile
		return
	}

	# test if connected to VPN
	if (!$isAzure -and $isWindows) {
		get-vpn
		test-VPN
	}

	write-stepStart "START COPY JOBS FOR SHARES" -startMeasurement
	get-controlPlaneStats
	$script:controlPlaneStatsStart = $script:controlPlaneStats.clone()

	write-taskStart "grant network access to storage accounts for sa-copy"
	grant-saAccess4controlPlane 'saCopy'

	# calculate current size of shares
	set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
	$script:allShares
	| ForEach-Object {
		if ($_.Type -ne 'BLOB') {
			$_.SizeGB = (get-shareSize $_.StorageAccount $_.Share $sourceRG) / 1GB
		}
		else {
			$_.SizeGB = (get-containerSize $_.StorageAccount $_.Share) / 1GB
		}
	}
	set-context -restore # *** CHANGE SUBSCRIPTION **************

	# show all shares
	$script:allShares
		| Select-Object StorageAccount, Type, Share, Snapshot, @{label="Skip"; expression={if($_.Skip -eq $true) {'X'} else{''}}}, Reason, NewName
		| Sort-Object StorageAccount, Type, Share
		| Format-Table
		| Out-String -Width $screenWidthLarge
		| write-logFilePipe

	# read SA properties if SAs had already been deployed earlier
	# (properties might have been changed manually before restarting RGCOPY)
	if ($skipDeployment) {

		set-context $targetSub # *** CHANGE SUBSCRIPTION **************
		$storageAccounts = Get-AzStorageAccount `
							-ResourceGroupName $targetRG `
							-ErrorAction 'SilentlyContinue' `
							-WarningAction 'SilentlyContinue'

		if (!$?) {
			write-logFileWarning "Did not find storage accounts in target RG"
		}
		else {
			$az_storageAccounts = @()
			foreach ($sa in $storageAccounts) {
				$az_res = convertFrom-json (convertTo-json $sa -Depth 5 -EnumsAsStrings -WarningAction 'SilentlyContinue') -AsHashtable
				$az_storageAccounts += $az_res
			}

			$script:copySA.Values
			| Where-Object sourceRG -eq $false
			| ForEach-Object {

				$saName = $_.newName
				$az_res = $az_storageAccounts | Where-Object StorageAccountName -eq $saName

				if ($null -eq $az_res) {
					write-logFileWarning "Storage account $saName not found in target RG"
				}
				else {
					$_.allowSharedKeyAccess = $az_res.AllowSharedKeyAccess
					$_.publicNetworkAccess = $az_res.PublicNetworkAccess
					$_.defaultAction = $az_res.NetworkRuleSet.DefaultAction
				}
			}
		}
		set-context -restore # *** CHANGE SUBSCRIPTION **************
	}

	write-taskStart "start copy jobs (one per share)"
	$script:AzCopyJobs = @()

	# start azcopy for each share separately
	$script:allShares
	| Where-Object Skip -ne $true
	| Sort-Object StorageAccount, Type, Share
	| ForEach-Object {

		$oldName = $_.StorageAccount
		$newName = $_.NewName
		$shareName = $_.Share
		$snapshotName = $_.Snapshot
		$sizeGB	= $_.SizeGB

		switch ($_.Type) {
			'BLOB' {
				start-azCopyJobsShares $oldName $newName 'blob' 'container' $shareName $sizeGB
			}
			'NFS' {
				start-azCopyJobsShares $oldName $newName 'file' 'nfs-share' $shareName $sizeGB $snapshotName
			}
			'SMB' {
				start-azCopyJobsShares $oldName $newName 'file' 'smb-share' $shareName $sizeGB $snapshotName
			}
		}
	}

	write-stepEnd -endMeasurement

	wait-azCopyJobs

	revoke-saAccess4controlPlane
}

#--------------------------------------------------------------
function step-workload {
#--------------------------------------------------------------
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
function stop-VMsTargetRG {
#--------------------------------------------------------------
	# stop VMs
	if ($stopVMsTargetRG) {
		if ($skipDeployment) {
			write-logFileWarning "parameter 'stopVMsTargetRG' ignored" `
								"The VMs have not been created during the current run of RGCOPY" `
								"Stop the VMs manually"
		}
		else {
			get-targetVMs
			stop-VMs $targetRG $script:targetVMs
		}
	}
}

#--------------------------------------------------------------
function get-azcopyVersion {
#--------------------------------------------------------------
	# windows
	if ($IsWindows) {
		$script:azcopyPath = '.\azcopy.exe'
	}

	# Linux/Mac
	else {
		$script:azcopyPath = './azcopy'
	}
	
	$string = "$azcopyPath --version"
	$script = [scriptblock]::create($string)
	try {
		$ver = $null
		$ver = (Invoke-Command -Script $script -ErrorAction 'Stop')
		if ($null -eq $ver ) {
			return $null
		}
	}
	catch {
		return $null
	}

	return ($ver -split ' version ')[1]
}

#--------------------------------------------------------------
function install-azcopy {
#--------------------------------------------------------------
	write-logFile "Trying to download AZCOPY..." -ForegroundColor DarkGray

	# Windows
	if ($isWindows) {
		try {
			$fullPath = "$pwshPath\azcopy.exe"
			# Fetch the latest ZIP file
			(New-Object Net.WebClient).DownloadFile("https://aka.ms/downloadazcopy-v10-windows", "$pwshPath\AzCopy.zip")

			# Extract
			Remove-Item 'AzCopyDownload' -Recurse -Force -ErrorAction 'SilentlyContinue'
			Expand-Archive 'AzCopy.zip' 'AzCopyDownload' -Force -ErrorAction 'Stop'

			# get file name
			$fileName = (Get-ChildItem 'AzCopyDownload' -Recurse -Filter 'azcopy.exe').fullName
			if ($fileName.Count -ne 1) {
				write-logFileError "Downloading AZCOPY failed"
			}

			# copy file
			Copy-Item $fileName . -Force -ErrorAction 'Stop'
		}
		catch {
			write-logFileError "Downloading AZCOPY failed"
		}
	}

	# Linux
	elseif ($IsLinux) {
		try {
			$fullPath = "$pwshPath/azcopy"
			# download
			curl -Lso AzCopy.tar.gz https://aka.ms/downloadazcopy-v10-linux
			if ((get-item AzCopy.tar.gz).Length -lt 99) {
				write-logFileError "Downloading AZCOPY failed"
			}

			# extract
			Remove-Item 'AzCopyDownload' -Recurse -Force -ErrorAction 'SilentlyContinue'
			mkdir -p AzCopyDownload
			tar -xvzf AzCopy.tar.gz -C AzCopyDownload | Out-Null

			# get file name
			$fileName = (Get-ChildItem 'AzCopyDownload' -Recurse -Filter 'azcopy').fullName
			if ($fileName.Count -ne 1) {
				write-logFileError "Downloading AZCOPY failed"
			}

			# copy file
			Copy-Item $fileName . -Force -ErrorAction 'Stop'
			chmod +x ./azcopy
		}
		catch {
			write-logFileError "Downloading AZCOPY failed"
		}
	}

	# Mac
	elseif ($IsMacOS) {
		write-logFileError "For MacOS, download AZCOPY manually"
	}

	write-logFile "Downloaded file $fullPath"
	write-logFile
}

#--------------------------------------------------------------
function get-bicepVersion {
#--------------------------------------------------------------
	$path = (get-command bicep -ErrorAction 'SilentlyContinue').Path
	$version = $Null

	try { 
		$version = (bicep --version | Out-String)  -replace '\n', '' 
	}
	catch {
		$version = $Null
	}

	return $version, $path
}

#--------------------------------------------------------------
function install-bicep {
#--------------------------------------------------------------
	write-logFile "Trying to install BICEP..." -ForegroundColor DarkGray

	if ($isWindows) {
		try {
			# Create the install folder
			$installPath = "$env:USERPROFILE\.bicep"
			$installDir = New-Item -ItemType Directory -Path $installPath -Force
			$installDir.Attributes += 'Hidden'
			$fullPath = "$installPath\bicep.exe"
			# Fetch the latest Bicep CLI binary
			(New-Object Net.WebClient).DownloadFile("https://github.com/Azure/bicep/releases/latest/download/bicep-win-x64.exe", $fullPath)
			# Add bicep to your PATH
			$currentPath = (Get-Item -path "HKCU:\Environment" ).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
			if (-not $currentPath.Contains("%USERPROFILE%\.bicep")) { setx PATH ($currentPath + ";%USERPROFILE%\.bicep") }
			if (-not $env:path.Contains($installPath)) { $env:path += ";$installPath" }
		}
		catch {
			write-logFileError "Installing bicep failed"
		}
	}

	elseif ($isLinux) {
		$fullPath = '/usr/local/bin/bicep'
		try {
			# download
			curl -Lso bicep https://github.com/Azure/bicep/releases/latest/download/bicep-linux-x64
			if ((get-item bicep).Length -lt 99) {
				write-logFileError "Installing bicep failed"
			}

			# move file
			chmod +x bicep
			sudo mv bicep $fullPath
		}
		catch {
			write-logFileError "Installing bicep failed"
		}
	}

	elseif ($IsMacOS) {
		write-logFileError "For MacOS, install BICEP manually"
	}

	write-logFile "Installed file $fullPath"
	write-logFile
}

#-------------------------------------------------------------
function show-vmExtensions {
#-------------------------------------------------------------
	write-taskStart "Installed extensions in resource group $sourceRG"

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
	| Out-String -Width $screenWidthLarge
	| write-logFilePipe
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
		$provisionAfter,
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

	if ($ignoreExtensionErrors) {
		$properties.suppressFailures = $true
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
		apiVersion	= '2025-04-01'
		parent 		= "<$(get-bicepNameByType 'Microsoft.Compute/virtualMachines' $vmName)>"
		name 		= $agentName
		location	= $targetLocation
		properties	= $properties
		dependsOn	= @()
	}

	# add dependency on other extensions 
	# This makes sure that only one extension is installed at the same time
	if ($null -ne $provisionAfter) {
		# get dependent BICEP name
		$script:bicepNamesAll.Values
		| Where-Object type -eq 'Microsoft.Compute/virtualMachines/extensions'
		| Where-Object name -eq "$vmName/$provisionAfter"
		| ForEach-Object {

			$res.dependsOn += "<$($_.bicepName)>"
		}
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

			new-vmExtension `
				-vmName	$vmName `
				-extensionType 'AzureMonitorLinuxAgent' `
				-extensionName 'AzureMonitorLinuxAgent' `
				-publisher 'Microsoft.Azure.Monitor' `
				-handlerVersion '1.41' `
				-settings @{ GCS_AUTO_CONFIG = $True } `
				-autoUpgradePossible
		}

		# WINDOWS
		else {

			new-vmExtension `
				-vmName	$vmName `
				-extensionType 'AzureMonitorWindowsAgent' `
				-extensionName 'AzureMonitorWindowsAgent' `
				-publisher 'Microsoft.Azure.Monitor' `
				-handlerVersion '1.42' `
				-settings @{ GCS_AUTO_CONFIG = $True } `
				-autoUpgradePossible
		}
	}
}

#-------------------------------------------------------------
function get-parameterFile {
#-------------------------------------------------------------
	param (
		$fileNames
	)

	$defaultParameterFileOnly = $false
	if ($fileNames.count -eq 0) {
		# do not use any parameter file if empty list is passed
		if ('parameterFile' -in $boundParameterNames) {
			return
		}
		# use default parameter file if none is specified
		$filenames = @('defaultParameter')
		$defaultParameterFileOnly = $true
	}

	foreach ($filename in $filenames) {
		# remove extension
		if ($fileName -like '*.json') {
			$fileName = $fileName.SubString(0, $fileName.Length - 5)
		}
	
		# 1st try: find parameter file in executable directory
		$path = "$pwshPath/$fileName.json"
		if (!(Test-Path -PathType Leaf $path)) {
	
			# 2nd try: find parameter file in subdirectory
			$path = "$pwshPath/parameterFiles/$fileName.json"
			if (!(Test-Path -PathType Leaf $path)) {
				if (!$defaultParameterFileOnly) {
					write-logFileError "Parameter file '$path' not found"
				}
			}
		}

		$hash = @{}
		if (Test-Path -PathType Leaf $path) {
			# read file
			$text = Get-Content `
				-Raw `
				-Path $path `
				-ErrorAction 'SilentlyContinue'
			test-cmdlet 'Get-Content'  "Parameter file '$path' not found"
		
			$hash = $text | ConvertFrom-Json -AsHashtable -ErrorAction 'SilentlyContinue'
			test-cmdlet 'ConvertFrom-Json'  "Invalid JSON file '$path'"
		}
	
		write-logFile ('-' * $starCount) -ForegroundColor 'DarkGray'
		write-logFile "Parameters from file '$path':" -ForegroundColor 'Yellow'
		$addedParams = @{}
		foreach ($key in $hash.keys) {
			$value = $hash.$key
			# you cannot add key 'parameterFile' in the parameter file
			if ($key -ne 'parameterFile') {

				# parameter pathExportFolder not allowed because it is already used before reading parameter file
				if ($key -eq 'pathExportFolder') {
					write-logFileError "Parameter 'pathExportFolder' not allowed in parameter file." `
										"Use environment variable 'rgcopyExportFolder' instead."
				}
				
				# ignore key when variable is already set
				if ($key -in $boundParameterNames) {
					# give warning if ignored value is different
					if ($value -ne $script:pwshParameters.$key) {
						write-logFile "Key '$key' in parameter file ignored because parameter is already set" -ForegroundColor 'DarkGray'
					}
				}
				else {
					# set key as parameter (global variable)
					Set-Variable $key -Value $value -Scope 'Script'
					$script:pwshParameters.$key = $value
					$script:boundParameterNames += $key
					$addedParams.$key = $value
				}
			}
		}
	
		# display parameters that have been added
		write-logFileHashTable $addedParams
	}
}

#--------------------------------------------------------------
function get-ipAddressControlPlane {
#--------------------------------------------------------------
	$ip = $Null

	# first try
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
	if ($ip -match '^\d+\.\d+\.\d+\.\d+$') {
		$script:ipAddressControlPlane = $ip
	}

	elseif ($null -eq $script:ipAddressControlPlane) {
		write-logFileError 'Getting public IP Address of local PC failed'
	}

	# else: keep existing $script:ipAddressControlPlane
}

#--------------------------------------------------------------
function get-ipRules {
#--------------------------------------------------------------
	param (
		$saName,
		$saResourceGroup,
		$saSubName
	)

	set-context $saSubName # *** CHANGE SUBSCRIPTION **************

	$ruleSet = Get-AzStorageAccountNetworkRuleSet `
				-ResourceGroupName 	$saResourceGroup `
				-Name				$saName `
				-ErrorAction		'SilentlyContinue'
	test-cmdlet 'Get-AzStorageAccountNetworkRuleSet'  "Could not read IP rules of storage account $saName"

	return ($ruleSet.IpRules | Sort-Object IPAddressOrRange -Unique)
}

#--------------------------------------------------------------
function add-ipRule {
#--------------------------------------------------------------
	param (
		$saName,
		$saResourceGroup,
		$saSubName,

		$ipAddress
	)
	
	set-context $saSubName # *** CHANGE SUBSCRIPTION **************

	$ipRules = get-ipRules $saNm $saRG $saSub
	$rule = $ipRules | Where-Object {($_.Action -eq 'Allow') -and ($_.IPAddressOrRange -eq $ipAddress)}

	# check if rule already exists
	if ($Null -ne $rule) {
		write-logFileTab 'SA IP rule' "$saNm/$ipAddress" 'already granted'
		return
	}

	write-logFileTab 'SA IP rule' "$saNm/$ipAddress" 'granting...'
	
	Add-AzStorageAccountNetworkRule `
		-ResourceGroupName	$saResourceGroup `
		-Name 				$saName `
		-IPAddressOrRange 	$ipAddress `
		-ErrorAction		'SilentlyContinue' | Out-Null
	if (!$?) {
		write-logFileWarning "Could not set IP rules for storage account $saName"
	}

	$script:waitRequired = $true
}

#--------------------------------------------------------------
function remove-ipRule {
#--------------------------------------------------------------
	param (
		$saName,
		$saResourceGroup,
		$saSubName,

		$ipAddress
	)

	set-context $saSubName # *** CHANGE SUBSCRIPTION **************
	write-logFile "Trying to remove IP rule $ipAddress for storage account $saName..."

	Remove-AzStorageAccountNetworkRule `
		-ResourceGroupName	$saResourceGroup `
		-Name 				$saName `
		-IPAddressOrRange 	$ipAddress `
		-ErrorAction		'SilentlyContinue' | Out-Null
	if (!$?) {
		write-logFileWarning "Could not remove IP rules for storage account $saName"
	}
}

#--------------------------------------------------------------
function get-rbacRoles {
#--------------------------------------------------------------
	param (
		$subID,
		$subUser,
		$saName,
		$rgName
	)

	$param = @{
		ErrorAction	= 'SilentlyContinue'
	}

	# get RBAC roles for storage account
	if ($null -ne $saName) {
		$param.Scope = "/subscriptions/$subID/resourcegroups/$rgName/providers/Microsoft.Storage/storageAccounts/$saName"
	}

	# managed identity
	if ($subUser -match "^[{]?[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}[}]?$") {
		$param.ApplicationId = $subUser
	}
	# user
	else {
		$param.SignInName = $subUser
	}

	$roles= Get-AzRoleAssignment @param
	if (!$?) {
		write-logFileWarning "Could not get RBAC Roles for user '$subUser'"
	}

	if ($null -eq $saName) {
		$roles = $roles | Where-object Scope -eq "/subscriptions/$subID"
	}

	return ($roles.RoleDefinitionName | Sort-Object)
}

#-------------------------------------------------------------
function receive-rest {
#-------------------------------------------------------------
	param (
		$resourceID,
		$apiVersion,
		$method = 'GET',
		[switch] $ignoreErrors
	)

	$token = get-azureToken
	$restUri = "https://management.azure.com$resourceID`?api-version=$apiVersion"

	$invokeParam = @{
		Uri				= $restUri
		Method			= $method
		ContentType		= 'application/json'
		Headers			= @{ Authorization = "Bearer $token" }
		WarningAction 	= 'SilentlyContinue'
		ErrorAction		= 'Stop'
	}
	
	try {
		# first REST call
		$response = Invoke-WebRequest @invokeParam
		$json = $response.Content | ConvertFrom-Json
		$return = @($json.value)

		# additional REST calls
		while ($json.nextLink.length -ne 0) {
			$invokeParam.Uri = $json.nextLink
			$response = Invoke-WebRequest @invokeParam
			$json = $response.Content | ConvertFrom-Json
			$return += @($json.value)
		}	

		return $return
	}
	catch {
		if ($ignoreErrors) {
			return @()
		}
		write-logFileError "Rest API $method failed for resource" $resourceID
	}
}

#-------------------------------------------------------------
function send-rest {
#-------------------------------------------------------------
	param (
		$resourceID,
		$apiVersion,
		$body,
		$method = 'PUT',
		$option
	)

	if ($null -eq $option) {
		$properties = "api-version=$apiVersion"
	}
	else {
		$properties = "$option&api-version=$apiVersion"
	}

	$token = get-azureToken
	$restUri = "https://management.azure.com$resourceID`?$properties"

	$invokeParam = @{
		Uri				= $restUri
		Method			= $method
		ContentType		= 'application/json'
		Headers			= @{ Authorization = "Bearer $token" }
		WarningAction 	= 'SilentlyContinue'
		ErrorAction		= 'Stop'
	}

	if ($null -ne $body) {
		$invokeParam.Body = ($body | ConvertTo-Json)
	}
	
	try {
		Invoke-WebRequest @invokeParam | Out-Null
	}
	catch {
		write-logFileError "Rest API $method failed for resource" $resourceID
	}
}

#-------------------------------------------------------------
function get-saNspConfig {
#-------------------------------------------------------------
	param (
		$saNm,
		$saSubId	= $sourceSubID,
		$saRG		= $sourceRG
	)
		
	$apiVersion = '2024-01-01'
	$resourceID = "/subscriptions/$saSubId/resourceGroups/$saRG/providers/Microsoft.Storage/storageAccounts/$saNm/networkSecurityPerimeterConfigurations"	
	return (receive-rest $resourceID $apiVersion 'GET')
}

#-------------------------------------------------------------
function get-nsps {
#-------------------------------------------------------------
	param (
		$nspSubID		= $targetSubID,
		$nspRG			= $targetRG
	)
		
	$apiVersion = $nspApiVersion
	$resourceID = "/subscriptions/$nspSubID/resourceGroups/$nspRG/providers/Microsoft.Network/networkSecurityPerimeters"	
	return (receive-rest $resourceID $apiVersion 'GET' -ignoreErrors)
}

#-------------------------------------------------------------
function remove-nsp {
#-------------------------------------------------------------
	param (
		$nspSubID	= $targetSubID,
		$nspRG		= $targetRG,
		$nspNm		= $nspName
	)

	$body = $null
	$option = 'forceDeletion=true'

	$apiVersion = $nspApiVersion
	$resourceID = "/subscriptions/$nspSubID/resourceGroups/$nspRG/providers/Microsoft.Network/networkSecurityPerimeters/$nspNm"	
	send-rest $resourceID $apiVersion $body 'DELETE' $option
}


#-------------------------------------------------------------
function new-nsp {
#-------------------------------------------------------------
	param (
		$nspSubID		= $targetSubID,
		$nspRG			= $targetRG,
		$nspLocation	= $targetLocation,
		$nspNn			= $nspName,
		$nspProfileName	= 'defaultProfile'
	)

	$body = @{
		location = $nspLocation
	}
	
	$apiVersion = $nspApiVersion
	$resourceID = "/subscriptions/$nspSubID/resourceGroups/$nspRG/providers/Microsoft.Network/networkSecurityPerimeters/$nspNm"	
	send-rest $resourceID $apiVersion $body 'PUT'

	$resourceID = "/subscriptions/$nspSubID/resourceGroups/$nspRG/providers/Microsoft.Network/networkSecurityPerimeters/$nspNm/profiles/$nspProfileName"	
	send-rest $resourceID $apiVersion $body 'PUT'
}

#-------------------------------------------------------------
function get-nspAssociations {
#-------------------------------------------------------------
	param (
		$nspNm,
		$nspSubID,
		$nspRG
	)

	$apiVersion = $nspApiVersion
	$resourceID = "/subscriptions/$nspSubID/resourceGroups/$nspRG/providers/Microsoft.Network/networkSecurityPerimeters/$nspNm/resourceAssociations"	
	return (receive-rest $resourceID $apiVersion 'GET')
}

#-------------------------------------------------------------
function new-nspAssociation {
#-------------------------------------------------------------
	param (
		$saNm,
		$saSubID,
		$saRG,

		$nspSubID,
		$nspRG,
		$nspNm			= $nspName,
		$nspProfileName	= 'defaultProfile',

		$accessMode		= 'Learning' # 'Enforced' #  
	)

	# BLOB copy currently does not work with enforced mode

	$associationName = $saNm

	$body = @{
		properties = @{
			privateLinkResource = @{
				id = "/subscriptions/$saSubID/resourceGroups/$saRG/providers/Microsoft.Storage/storageAccounts/$saNm"
			}
			profile = @{
				id = "/subscriptions/$nspSubID/resourceGroups/$nspRG/providers/Microsoft.Network/networkSecurityPerimeters/$nspNm/profiles/$nspProfileName"
			}
			accessMode = $accessMode
		}
	}

	$apiVersion = $nspApiVersion
	$resourceID = "/subscriptions/$nspSubID/resourceGroups/$nspRG/providers/Microsoft.Network/networkSecurityPerimeters/$nspNm/resourceAssociations/$associationName"	
	send-rest $resourceID $apiVersion $body 'PUT'
}

#--------------------------------------------------------------
function new-saAssociation {
#--------------------------------------------------------------
	param (
		$saNm,
		$saSubID,
		$saRG,
		$saLocation,

		$nspNm		= $nspName
	)

	$nsps = get-nsps $saSubID $saRG
	if ($nspNm -notin $nsps.name) {
		new-nsp $saSubID $saRG $saLocation
		write-logFileTab 'NSP' $nspNm "created in resource group $saRG"
	}
	else {
		write-logFileTab 'NSP' $nspNm 'already exists'
	}

	$nspAss = get-nspAssociations $nspNm $saSubID $saRG
	if ($saNm -notin $nspAss.name) {
		new-nspAssociation $saNm $saSubID $saRG $saSubID $saRG
		write-logFileTab 'NSP Association' $saNm 'created'
	}
	else {
		write-logFileTab 'NSP Association' $saNm 'already exists'
	}
}

#-------------------------------------------------------------
function get-nspRules {
#-------------------------------------------------------------
	param (
		$nspSubID		= $targetSubID,
		$nspRG			= $targetRG,
		$nspNm			= $nspName,
		$nspProfileName	= 'defaultProfile'
	)

	$apiVersion = $nspApiVersion
	$resourceID = "/subscriptions/$nspSubID/resourceGroups/$nspRG/providers/Microsoft.Network/networkSecurityPerimeters/$nspNm/profiles/$nspProfileName/accessRules"	
	return (receive-rest $resourceID $apiVersion 'GET')
}

#-------------------------------------------------------------
function add-nspRule {
#-------------------------------------------------------------
	param (
		$ipAddress, 

		$nspSubID		= $targetSubID,
		$nspRG			= $targetRG,
		$nspNm			= $nspName,
		$nspProfileName	= 'defaultProfile'
	)

	$body = @{
		properties = @{
			direction = 'Inbound'
			addressPrefixes = @( "$ipAddress/32" )
		}
	}

	$apiVersion = $nspApiVersion
	$resourceID = "/subscriptions/$nspSubID/resourceGroups/$nspRG/providers/Microsoft.Network/networkSecurityPerimeters/$nspNm/profiles/$nspProfileName/accessRules/$ipAddress"	
	send-rest $resourceID $apiVersion $body 'PUT'
}

#-------------------------------------------------------------
function remove-nspRule {
#-------------------------------------------------------------
	param (
		$ruleName, 

		$nspSubID		= $targetSubID,
		$nspRG			= $targetRG,
		$nspNm			= $nspName,
		$nspProfileName	= 'defaultProfile'
	)

	$body = $null
	$apiVersion = $nspApiVersion
	$resourceID = "/subscriptions/$nspSubID/resourceGroups/$nspRG/providers/Microsoft.Network/networkSecurityPerimeters/$nspNm/profiles/$nspProfileName/accessRules/$ruleName"	
	send-rest $resourceID $apiVersion $body 'DELETE'
}

#--------------------------------------------------------------
function new-blobCopyToken {
#--------------------------------------------------------------
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	if ($targetNoSaKeys) {
		write-logFile "Creating temporary delegation token for container '$targetSaContainer'..."
	
		$context = New-AzStorageContext `
					-StorageAccountName		$targetSA `
					-UseConnectedAccount `
					-ErrorAction			'SilentlyContinue'
	}

	else {
		write-logFile "Creating temporary token using SA-key for container '$targetSaContainer'..."

		# get saKey
		$saKey = (Get-AzStorageAccountKey `
					-ResourceGroupName $targetRG `
					-AccountName $targetSA `
					-WarningAction 'SilentlyContinue' `
					-ErrorAction 'SilentlyContinue' `
				| Where-Object KeyName -eq $copySaKeyName).Value

		# get SAS token
		$context = New-AzStorageContext `
					-StorageAccountName $targetSA `
					-StorageAccountKey $saKey `
					-WarningAction 'SilentlyContinue' `
					-ErrorAction 'SilentlyContinue'		
	}

	$StartTime = (Get-date).ToUniversalTime().AddHours(-2)
	$EndTime = $startTime.AddDays(6)

	$script:delegationToken = New-AzStorageContainerSASToken `
			-Name			$targetSaContainer `
			-Permission 	'crwdl' `
			-StartTime		$startTime `
			-ExpiryTime		$endTime `
			-context		$context `
			-ErrorAction	'SilentlyContinue'
	if (!$?) {

		if ($isAzure) {
			write-logFileError "Creating delegation token for storage account '$targetSA' failed." `
								"Make sure that you have RBAC Role 'Storage Blob Data Contributor' and that" `
								"Service Endpoint Microsoft.Storage.Global is enabled in control plane VM"
		}

		else {
			write-logFileError "Creating delegation token for storage account '$targetSA' failed." `
								"Make sure that you have RBAC Role 'Storage Blob Data Contributor'"
		}

	}

	# save token for each disk
	$script:copyDisks.values
	| ForEach-Object {
		$_.DelegationToken = $script:delegationToken
	}

	set-context -restore # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function get-sasDelegationToken {
#--------------------------------------------------------------
	param (
		$saName,
		$shareName,
		$type
	)

	# only possible if shareName is given:
	if ($null -eq $shareName) {
		return $null
	}

	$context = New-AzStorageContext `
				-StorageAccountName $saName `
				-UseConnectedAccount `
				-ErrorAction 'SilentlyContinue'

	$StartTime = (Get-date).ToUniversalTime().AddHours(-2)
	$EndTime = $startTime.AddDays(6)

	$maxRetries = 4
	$token = $null
	for ($retry = 1; $retry -le $maxRetries; $retry++) {

		if ($type -eq 'blob') {
			# using SAS token bound to specic IP address do not work with azcopy
			$token = New-AzStorageContainerSASToken `
						-Name $shareName `
						-Permission 'crwdl' `
						-StartTime $startTime `
						-ExpiryTime $endTime `
						-context $context `
						-ErrorAction 'SilentlyContinue'
		}

		else {
			# This does not work yet
			#--------------------------------------------------------------
			# ERROR: Create File service SAS only supported with SharedKey credential.
			#--------------------------------------------------------------
			$token = New-AzStorageShareSASToken `
						-ShareName		$shareName `
						-Permission 	'crwdl' `
						-StartTime		$startTime `
						-ExpiryTime		$endTime `
						-context		$context `
						-ErrorAction	'SilentlyContinue'
		}

		if ($null -ne $token) {
			break
		}

		if ($retry -lt $maxRetries) {
			$retryDelaySec = 10 * $retry
			write-logFile "Creating User delegation SAS token failed. Retrying in $retryDelaySec seconds..."
			Start-Sleep -Seconds $retryDelaySec
		}
	}

	return $token
}

#--------------------------------------------------------------
function get-sasTokenBySaKey {
#--------------------------------------------------------------
	param (
		$saName,
		$saResourceGroup
	)

	# get saKey
	$saKey = (Get-AzStorageAccountKey `
				-ResourceGroupName $saResourceGroup `
				-AccountName $saName `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'SilentlyContinue' `
			| Where-Object KeyName -eq $copySaKeyName).Value

	# get SAS token
	$context = New-AzStorageContext `
				-StorageAccountName $saName `
				-StorageAccountKey $saKey `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'SilentlyContinue'

	$StartTime = (Get-date).ToUniversalTime().AddHours(-2)
	$EndTime = $startTime.AddDays(6)

	# btw: New-AzStorageAccountSASToken does only work with storage account key. Error message:
	#      "Storage account SAS token must be secured with the storage account key. (Parameter 'Context') " 
	# btw: SAS tokens bound to specic IP address do not work with azcopy
	$token =  New-AzStorageAccountSASToken `
				-Service 'Blob,File' `
				-ResourceType 'Service,Container,Object' `
				-Permission 'racwdlup' `
				-StartTime $StartTime `
				-ExpiryTime $EndTime `
				-Context $context `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'SilentlyContinue'
	if (!$?) {
		$token = $null
	}

	return $token
}

#--------------------------------------------------------------
function step-snapshotsShares {
#--------------------------------------------------------------
	if (!$shareCopyNeeded -or !$copySaUsingSnapshots) {
		return
	}

	if ('skipSnapshots' -in $boundParameterNames) {
		write-stepStart "GET FILE SHARE SNAPSHOTS"
	}
	else {
		write-stepStart "SNAPSHOT FILE SHARES"
	}

	$script:saSnapshots = @()


	$script:allShares
	| Where-Object Skip -ne $true
	| Where-Object Type -ne 'BLOB'
	| ForEach-Object {

		$share = $_.Share
		$storageAccount = $_.StorageAccount

		if ('skipSnapshots' -in $boundParameterNames) {
			# show snapshot
			$snapshot = get-shareSnapshot $share $storageAccount $sourceRG $sourceSubID
			if ($null -eq $snapshot) {
				write-logFileWarning "RGCOPY snapshot of share '$share' not found" -stopCondition $True
			}
		}
		else {
			# create new snapshot (overwrite existing one)
			$snapshot = new-shareSnapshot $share $storageAccount $sourceRG $sourceSubID
		}

		$_.Snapshot = $snapshot

		$script:saSnapshots += @{
			StorageAccount	= $storageAccount
			Share			= $share
			TimeStamp		= $snapshot
		}
	}

	$script:saSnapshots
	| Select-Object StorageAccount, Share, TimeStamp
	| Format-Table
	| Out-String -Width $screenWidthSmall
	| write-logFilePipe
}

#--------------------------------------------------------------
function get-shareSnapshot {
#--------------------------------------------------------------
	param (
		 $shareName
		,$storageAccountName
		,$storageAccountRG
		,$storageAccountSubId
	)

	$saResourceID = "/subscriptions/$storageAccountSubId/resourceGroups/$storageAccountRG/providers/Microsoft.Storage/storageAccounts/$storageAccountName"
	$tagName = "rgcopySnapshot_$shareName" 
	$format = "yyyy'-'MM'-'dd'T'HH':'mm':'ssZ"

	# get snapshot tag
	$allTags = Get-AzTag `
				-ResourceId $saResourceID `
				-ErrorAction 'SilentlyContinue'
	test-cmdlet 'Get-AzTag'  "Reading tags failed for storage account '$storageAccountName'"	

	# get tag
	$tagValue = $allTags.Properties.TagsProperty.$tagName
	if ($null -eq $tagValue) {
		return $null
	}

	# test if tag is valid
	$SnapshotTime = $null
	try {
		$SnapshotTime = ([datetime]::parseexact($tagValue, $format ,$null)).ToUniversalTime()
	}
	catch {
	}
	if ($null -eq $SnapshotTime) {
		return $null
	}

	$snap = Get-AzRmStorageShare `
				-ResourceGroupName $storageAccountRG `
				-StorageAccountName $storageAccountName `
				-Name $shareName `
				-SnapshotTime $SnapshotTime `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'SilentlyContinue'
							
	if ($null -eq $snap) {
		return $null
	}
	else {
		return $tagValue
	}
}

#--------------------------------------------------------------
function new-shareSnapshot {
#--------------------------------------------------------------
	param (
		 $shareName
		,$storageAccountName
		,$storageAccountRG
		,$storageAccountSubId
	)

	$saResourceID = "/subscriptions/$storageAccountSubId/resourceGroups/$storageAccountRG/providers/Microsoft.Storage/storageAccounts/$storageAccountName"
	$tagName = "rgcopySnapshot_$shareName" 
	$format = "yyyy'-'MM'-'dd'T'HH':'mm':'ssZ"

	# get snapshot tag
	$allTags = Get-AzTag `
				-ResourceId $saResourceID `
				-ErrorAction 'SilentlyContinue'
	test-cmdlet 'Get-AzTag'  "Reading tags failed for storage account '$storageAccountName'"	

	$tagValue = $allTags.Properties.TagsProperty.$tagName

	# tag found
	if ($null -ne $tagValue) {

		$SnapshotTime = $null
		try {
			$SnapshotTime = ([datetime]::parseexact($tagValue, $format ,$null)).ToUniversalTime()
		}
		catch {
		}

		# tag valid
		if ($null -ne $SnapshotTime) {

			# get all shares and snapshots
			$allShares = Get-AzRmStorageShare `
							-ResourceGroupName $storageAccountRG `
							-StorageAccountName $storageAccountName `
							-IncludeSnapshot `
							-ErrorAction 'SilentlyContinue'
			test-cmdlet 'Get-AzRmStorageShare'  "Getting share snapshots failed for storage account '$storageAccountName'"	

			$snapOld = $allShares `
				| Where-Object Name -eq $shareName `
				| Where-Object SnapshotTime -eq $SnapshotTime
							
			# test if snapshot exists
			if ($null -ne $snapOld) {

				write-logFileTab 'snapshot' "$storageAccountName/$shareName/$tagValue" 'deleted'

				# delete snapshot
				Remove-AzRmStorageShare `
					-ResourceGroupName $storageAccountRG `
					-StorageAccountName $storageAccountName `
					-Name $shareName `
					-SnapshotTime $SnapshotTime `
					-Force `
					-ErrorAction 'SilentlyContinue'
				test-cmdlet 'Remove-AzRmStorageShare'  "Deleting share snapshot failed for storage account '$storageAccountName'"	
			}		

		}
	}

	# create snapshot
	$snapNew = New-AzRmStorageShare `
				-ResourceGroupName $storageAccountRG `
				-StorageAccountName $storageAccountName `
				-Name $shareName `
				-Snapshot `
				-ErrorAction 'SilentlyContinue'
	test-cmdlet 'New-AzRmStorageShare'  "Creating share snapshot failed for storage account '$storageAccountName'"

	$tagValue = $snapNew.SnapshotTime.ToUniversalTime().ToString($format)
	write-logFileTab 'snapshot' "$storageAccountName/$shareName/$tagValue" 'created'
	
	# update snashot tag
	Update-AzTag `
		-ResourceId $saResourceID `
		-Tag @{ $tagName = $tagValue } `
		-Operation 'Merge' `
		-ErrorAction 'SilentlyContinue' | Out-Null
	test-cmdlet 'Update-AzTag'  "Setting tag failed for storage account '$storageAccountName'"

	return $tagValue
}

#--------------------------------------------------------------
function get-VPN {
#--------------------------------------------------------------
	$script:connectedVPN = $null
	try {
		$rasdial = $(rasdial)
		if ($rasdial.count -gt 1) {
			if ($rasdial[0] -eq 'Connected to') {
				$script:connectedVPN = $rasdial[1]
			}
			elseif ($rasdial[0] -ne 'No connections') {
				write-logFileWarning "RASDIAL did not work properly"
			}
		}
		else {
			write-logFileWarning "RASDIAL did not work properly"
		}
	}
	catch {
		write-logFileWarning "RASDIAL did not work properly"
	}
}

#--------------------------------------------------------------
function test-VPN {
#--------------------------------------------------------------
	if (($null -ne $azVpnName) -and ($script:connectedVPN -eq $azVpnName)) {
		if ($useAzCopy) {
			write-logFileWarning "Cannot copy disks using AzCopy when connected to VPN $script:connectedVPN" `
									-stopCondition $true
		}
		if ($shareCopyNeeded) {
			write-logFileWarning "Cannot copy SA content when connected to VPN $script:connectedVPN" `
									-stopCondition $true
		}
		if ($script:mountPointsCount -ne 0) {
			write-logFileWarning "Cannot copy volumes when connected to VPN $script:connectedVPN" `
									-stopCondition $true
		}
	}
	elseif ($null -ne $script:connectedVPN) {
		write-logFileWarning "Connected to VPN $script:connectedVPN"
	}
}

#--------------------------------------------------------------
function get-shellScripts {
#--------------------------------------------------------------
	if ($prePatchCommand -like '*"*') {
		write-logFileError "Parameter 'prePatchCommand' must not contain double quotes"
	}

	if ($postPatchCommand -like '*"*') {
		write-logFileError "Parameter 'postPatchCommand' must not contain double quotes"
	}

	#--------------------------------------------------------------
	# Windows patches
	$file = 'powershell\windowsPatches.psm1'
	$script:WindowsPatchScript = Get-Content `
					-Path (Join-Path -Path $pwshPath -ChildPath $file) `
					-Raw `
					-ErrorAction 'SilentlyContinue'
	test-cmdlet 'Get-Content'  "Reading file '$file' failed"


	#--------------------------------------------------------------
	# Linux patches
	$script:LinuxPatchScript = @"
#!/bin/bash
patchAll='$("$patchAll".toLower())'
prePatchCommand="$prePatchCommand"
postPatchCommand="$postPatchCommand"
`n
"@
	# get file
	$file = 'bash\linuxPatches.sh'
	$script:LinuxPatchScript += Get-Content `
					-Path (Join-Path -Path $pwshPath -ChildPath $file) `
					-Raw `
					-ErrorAction 'SilentlyContinue'
	test-cmdlet 'Get-Content'  "Reading file '$file' failed"
}

#-------------------------------------------------------------
function step-patchOS {
#-------------------------------------------------------------
	write-stepStart "PATCH VMs (OS UPDATE)" -startMeasurement
	if ($ignorePatchErrors) {
		write-logFileWarning "Errors during VM patching will be ignored" `
							"(can be changed by setting parameter ignorePatchErrors=`$false)"
	}
	
	get-shellScripts

	# copyMode: set $script:patchVMs
	if (!$patchMode) {
		if ('patchVMs' -notin $boundParameterNames) {
			$script:patchVMs = convertTo-array ($script:copyVMs.Values | Where-Object Skip -eq $false).Name
		}
	}

	# nothing to do
	if ($patchVMs.count -eq 0) {
		write-logFileWarning "No VMs to patch"
		write-stepEnd
		return
	}

	# process $all VMs
	$script:shellJobs = @{}
	foreach ($vm in $patchVMs) {
		$vmName = $vm
		# get name of renamed VM
		if (!$SourceOnlyMode) {
			if ($script:copyVMs[$vm].Rename.length -ne 0) {
				$vmName = $script:copyVMs[$vm].Rename
			}
		}

		# choose script
		$osType = $script:copyVMs[$vm].OsDisk.OsType 
		if ($osType -eq 'Linux') {
			$scriptText = $script:LinuxPatchScript
			$scriptPath = Join-Path $pathExportFolder -ChildPath "$logPrefixTarget.patchLinux.$vmName.txt"
		}
		else {
			$scriptText = $script:WindowsPatchScript
			$scriptPath = Join-Path $pathExportFolder -ChildPath "$logPrefixTarget.patchWindows.$vmName.txt"
		}
		$script:logFiles += $scriptPath

		# start PS job that starts shell script in VM
		invoke-shellScriptAsJob `
			-scriptVm $vmName `
			-description "VM $vmName $osType Update" `
			-scriptText $scriptText `
			-scriptPath $scriptPath `
			-scriptType 'OsPatch' `
			-osType $osType `
			-jobIdOrigin $null `
			-ignoreErrors $ignorePatchErrors
	}

	# collect results from PS job
	# reboot VMs if needed
	# repeat OS update if needed (and reboot again)
	receive-jobs4shellScript

	write-stepEnd -endMeasurement
}

#--------------------------------------------------------------
function invoke-shellScriptAsJob {
#--------------------------------------------------------------
	# start local PS job that starts shell script in VM
	param (
		 $scriptVm			# VM name where the script is being executed
		,$description		# description of job
		,$scriptText		# code of running script
		,$scriptPath		# temporary file that contains scriptText
		,$scriptType		# 'OsPatch', 'Reboot', 'OsPatchRepeat'

		,$osType			# 'Windows', 'Linux'
		,$jobIdOrigin		# jobId of orign job (when repeating job)
		,$ignoreErrors		= $false

		,$subscriptionName	= $targetSub
		,$userName			= $targetSubUser
		,$userTenant		= $targetSubTenant
		,$rgName			= $targetRG
	)

	if ($scriptType -ne 'Reboot') {
		write-taskStart $description
	}

	# save script as file
	if ($null -ne $scriptText) {
		Set-Content `
			-Path $scriptPath `
			-Value $scriptText `
			-ErrorAction 'SilentlyContinue'
		test-cmdlet 'Set-Content'  "Writing file '$scriptPath' failed"
	}

	# read invoke script only once
	if ($null -eq $script:invokeScript) {
		$file = 'powershell\invoke.psm1'
		$script:invokeScript = Get-Content `
			-Raw `
			-Path (Join-Path -Path $pwshPath -ChildPath $file) `
			-ErrorAction 'SilentlyContinue'
		test-cmdlet 'Get-Content'  "Reading file '$file' failed"
	}

	switch ($scriptType) {
		#--------------------------------------------------------------
		'OsPatch' {
			wait-vmAgent $rgName $scriptVm

			if ($osType -ne 'Linux') {
				$commandId = 'RunPowerShellScript'
			}
			else {
				$commandId = 'RunShellScript'
			}

			# replace parameters in script
			$jobText = $script:invokeScript `
						-creplace '\$TEXT_INVOKE_SUB_NAME',		$subscriptionName `
						-creplace '\$TEXT_INVOKE_USER_NAME',	$userName `
						-creplace '\$TEXT_INVOKE_TENANT',		$userTenant `
						-creplace '\$TEXT_INVOKE_RG_NAME',		$rgName `
						-creplace '\$TEXT_INVOKE_VM_NAME', 		$scriptVM `
						-creplace '\$TEXT_INVOKE_COMMAND_ID', 	$commandId `
						-creplace '\$TEXT_INVOKE_SCRIPT_PATH', 	$scriptPath

			# convert string to script
			$jobBlock = [scriptblock]::create($jobText)

			$jobObject = Start-Job `
				-ScriptBlock $jobBlock `
				-ErrorAction 'SilentlyContinue'
			test-cmdlet 'Start-Job'  "Starting job failed"

			$jobIdOrigin = $jobObject.Id
		}

		#--------------------------------------------------------------
		'Reboot' {
			$jobText = $null

			$jobObject = Restart-AzVM `
				-ResourceGroupName $rgName `
				-Name $scriptVm `
				-AsJob `
				-ErrorAction 'SilentlyContinue'
			test-cmdlet 'Restart-AzVM'  "Restarting VM as job failed"
		}

		#--------------------------------------------------------------
		'OsPatchRepeat' {
			wait-vmAgent $rgName $scriptVm

			$jobText = $script:shellJobs[$jobIdOrigin].jobText
			$jobBlock = [scriptblock]::create($jobText)

			$jobObject = Start-Job `
				-ScriptBlock $jobBlock `
				-ErrorAction 'SilentlyContinue'
			test-cmdlet 'Start-Job'  "Starting job failed"
		}
	}

	# save status of running jobs
	$script:shellJobs[$jobObject.Id] = @{
		scriptVm		= $scriptVm
		description		= $description
		# scriptText		= $scriptText
		# scriptPath		= $scriptPath
		scriptType		= $scriptType	# 'OsPatch', 'Reboot', 'OsPatchRepeat'
		
		osType			= $osType
		jobIdOrigin		= $jobIdOrigin
		ignoreErrors	= $ignoreErrors

		jobText			= $jobText	# contains $scriptPath, which contains $scriptText
		job				= $jobObject
		jobId			= $jobObject.Id
		jobRepeatCount	= 0

		startTime			= get-date
		endTime				= $null
		duration			= $null
		durationInMinutes	= $null
		state				= $null
	}
	write-logFile
}

#--------------------------------------------------------------
function receive-jobs4shellScript {
#--------------------------------------------------------------
	# collect results from local PS job
	write-logFile

	$runningJobs = $script:shellJobs.Values | Where-Object {$null -eq $_.endTime} | Sort-Object jobId
	while ($runningJobs.count -gt 0) {

		foreach ($running in $runningJobs) {
			
			$vmName			= $running.scriptVm
			$description	= $running.description
			$scriptType		= $running.scriptType
			$osType 		= $running.osType
			$jobIdOrigin	= $running.jobIdOrigin
			$ignoreErrors	= $running.ignoreErrors	
			$state			= $running.job.State

			# save runtime
			if ($state -in @('Failed', 'Stopped', 'Completed')) {
				$running.endTime = Get-Date
				$running.duration = $running.endTime - $running.startTime
				$running.durationInMinutes = "{0:N2}" -f $running.duration.TotalMinutes
				$running.state = $state
			}

			#--------------------------------------------------------------
			# Powershell job states: Failed/Stopped
			if ($state -in @('Failed', 'Stopped')) {
				# 1st possible error: job failed
				write-logFileWarning "PowerShell job '$description' failed with state = $state" `
									-stopCondition !$ignoreErrors

				# reboot and retry
				$rebootRequired = 'true'
			}

			#--------------------------------------------------------------
			# Powershell job state: Completed
			elseif ($state -eq 'Completed') {		
				# run or repeat job finished
				if ($scriptType -in @('OsPatch', 'OsPatchRepeat')) {

					write-taskStart "RESULTS: $($running.description)"
					$messages = $running.job.ChildJobs.Information -join "`n"

					write-logFile $messages -ForegroundColor 'Cyan'
					$invokeStatus 		= get-variableFromText $messages 'INVOKE_STATUS'
					$rebootRequired 	= get-variableFromText $messages 'REBOOT_REQUIRED'

					# 2nd possible error: Invoke-AzVMRunCommand failed in job
					if ($invokeStatus -ne 'Succeeded') {
						write-logFileWarning "Invoking script for VM $vmName failed" `
											"INVOKE_STATUS='$invokeStatus'" `
											-stopCondition !$ignoreErrors
						# reboot and retry
						$rebootRequired = 'true'
						$running.state = 'InvokeFailed'
					}				
	
					# 3rd possible error: exception in script
					if ((($osType -eq 'Linux') -and ($messages -like '*++ exit 1*'))) {
						write-logFileWarning "Script in VM $vmName returned exit code 1" `
												-stopCondition !$ignoreErrors
						# reboot and retry
						$rebootRequired = 'true'
						$running.state = 'ExitCode1'
					}	
				}

				# reboot job finished
				else {
					$rebootRequired = 'false'
				}

				#--------------------------------------------------------------
				# Reboot if needed
				if ($rebootRequired -ne 'false') {

					invoke-shellScriptAsJob `
						-scriptVm $vmName `
						-description "VM $vmName Reboot" `
						-scriptType 'Reboot' `
						-osType $osType `
						-jobIdOrigin $jobIdOrigin `
						-ignoreErrors $ignoreErrors
				}

				#--------------------------------------------------------------
				# repeating job after Reboot or failure
				elseif ($scriptType	-eq 'Reboot') {

					# execute script not more than 3 times
					if ($script:shellJobs[$running.jobIdOrigin].jobRepeatCount -lt 3) {
						$script:shellJobs[$running.jobIdOrigin].jobRepeatCount += 1

						$jobRepeatCount = $script:shellJobs[$running.jobIdOrigin].jobRepeatCount
						switch ($jobRepeatCount) {
							1 {  
								$num = '1st'
							}

							2 {
								$num = '2nd'
							}

							3 {
								$num = '3rd'
							}

							Default {
								$num = "$jobRepeatCount" + "th"
							}
						}

						invoke-shellScriptAsJob `
							-scriptVm $vmName `
							-description "VM $vmName $osType Update ($num repeat)" `
							-scriptType 'OsPatchRepeat' `
							-osType $osType `
							-jobIdOrigin $jobIdOrigin `
							-ignoreErrors $ignorePatchErrors
					}
				}
				write-logFile
			}
		}

		# update runningJobs: job might have finished, new job might have been created
		$runningJobs = $script:shellJobs.Values | Where-Object {$null -eq $_.endTime} | Sort-Object jobId

		# wait for running jobs
		if ($runningJobs.count -gt 0) {
			# display running jobs
			write-logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') Running jobs:" -ForegroundColor 'DarkGray'
			foreach ($running in $runningJobs) {
				write-logFile "Job ID $($running.jobId): $($running.description)"
			}
			write-logFile

			# wait up to 5 minutes
			Wait-Job -Id $runningJobs.jobId -Any -TimeOut 300 | Out-Null
		}
	}

	$startTime	= ($script:shellJobs.Values.startTime | Measure-Object -Minimum).Minimum
	$endTime	= ($script:shellJobs.Values.startTime | Measure-Object -Maximum).Maximum
	$duration	= $endTime -$startTime
	$durationInMinutes = "{0:N2}" -f $duration.TotalMinutes

	write-logFile
	write-logFile "All jobs finished in $durationInMinutes minutes"
	$script:shellJobs.Values 
	| Select-Object jobId, description, durationInMinutes, state
	| Sort-Object jobId
	| Format-Table
	| write-logFilePipe
}

#--------------------------------------------------------------
function get-variableFromText {
#--------------------------------------------------------------
	param (
		$text,
		$variable,
		[switch] $decimal
	)

	# get first match with value in quotes
	if ($text -match "$variable='[^']*'") { 
		$result = ($matches.0 -split "'")[1]
	}
	# get first match with value in double quotes
	elseif ($text -match "$variable=`"[^`"]*`"") {
		$result = ($matches.0 -split '"')[1]
	}
	# no match
	else {
		$result =  $Null
	}

	if ($decimal) {
		$result = $result -as [decimal]
		if (!($result -gt 0)) {
			write-logFileError "Invalid measurement: $variable"
		}
	}

	return $result
}


#**************************************************************
# Main program
#**************************************************************
$pwshName = 'RGCOPY'
$pwshPath = Split-Path -Parent $PSCommandPath

# RGCOPY started from other script
if (($MyInvocation.ScriptName.Length -gt 0) -and ($MyInvocation.ScriptName -notlike '*rgcopy.ps1')) {
	$hostPlainText = $true
}

# Console settings
if ($hostPlainText) {
	$PsStyle.OutputRendering = 'PlainText'
}
else {
	[console]::ForegroundColor = 'Gray'
	[console]::BackgroundColor = 'Black'
	Clear-Host
}
$error.Clear()
$env = get-environment 'breakingChangeWarnings'
if ($env -ne 'True')	{
	$Env:SuppressAzurePowerShellBreakingChangeWarnings = 'true'
}

$script:rgcopyStatistics = @()
$script:rgcopyStatistics += @{
	step			= "RGCOPY START"
	timestamp		= get-date
	usedMinutes		= $null
	elapsedMinutes	= $null
	sizeGB			= $null
	objects			= $null
}

set-constants
set-mode 
set-paths
test-isAzure

# create logfile
New-Item $logPath -Force -ErrorAction 'SilentlyContinue' | Out-Null
$script:logFiles = @()

#**************************************************************
# Main TRY-CATCH
#**************************************************************
try {
	# get version
	$text = Get-Content -Path $PSCommandPath
	foreach ($line in $text) {
		if ($line -like 'version:*') {
			$v,$main,$mid,$minor = $line -split '\W+'
			$pwshVersion = "$main.$mid.$minor"
		}
		elseif ($line -like 'version date:*') {
			$v,$w,$month,$year = $line -split '\W+'
			$pwshVersionDate = "$month $year"
			break
		}
	}

	#--------------------------------------------------------------
	# show RGCOPY version
	#--------------------------------------------------------------
	$starCount = 70
	if ($msInternalVersion) {
		write-logFile ('*' * $starCount) -ForegroundColor 'DarkGray'
		write-logFile 'RGCOPY ' -NoNewLine 
		write-logFile '(MS internal) version ' -ForegroundColor 'DarkGray' -NoNewLine
		write-logFile "$pwshVersion " -NoNewLine
		write-logFile ("$pwshVersionDate" + (' ' * (20 - $rgcopyMode.length))) -ForegroundColor 'DarkGray' -NoNewLine
		write-logFile $rgcopyMode -ForegroundColor 'Yellow' -NoNewLine
		write-logFile ' mode' -ForegroundColor 'DarkGray'
		write-logFile ('*' * $starCount) -ForegroundColor 'DarkGray'
		write-logFile "Source code: $repository"  -ForegroundColor 'DarkGray' -NoNewLine
		write-logFile "/tree/development" -ForegroundColor 'yellow'
	}
	else {
		write-logFile ('*' * $starCount) -ForegroundColor 'DarkGray'
		write-logFile 'RGCOPY ' -NoNewLine 
		write-logFile '(Open Source) version ' -ForegroundColor 'DarkGray' -NoNewLine
		write-logFile "$pwshVersion " -NoNewLine
		write-logFile ("$pwshVersionDate" + (' ' * (20 - $rgcopyMode.length))) -ForegroundColor 'DarkGray' -NoNewLine
		write-logFile $rgcopyMode -ForegroundColor 'Yellow' -NoNewLine
		write-logFile ' mode' -ForegroundColor 'DarkGray'
		write-logFile ('*' * $starCount) -ForegroundColor 'DarkGray'
		write-logFile "Source code: https://github.com/Azure/RGCOPY"  -ForegroundColor 'DarkGray'
	}
	
	write-logFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') -ForegroundColor DarkGray
	if ($simulate) {
		write-logFile 'WARNING: running as simulation' -ForegroundColor 'Red'
	}
	write-logFile

	#--------------------------------------------------------------
	# show RGCOPY parameters
	#--------------------------------------------------------------
	$script:rgcopyParamOrig = $PSBoundParameters
	write-logFile "Parameters of RGCOPY:" -ForegroundColor 'yellow'
	write-logFileHashTable $PSBoundParameters
	get-parameterFile $parameterFile
	
	#--------------------------------------------------------------
	# show log file
	#--------------------------------------------------------------
	write-logFile -ForegroundColor 'Cyan' "Log file saved: $logPath"
	if ($pathExportFolderNotFound.length -ne 0) {
		write-logFileWarning "provided path '$pathExportFolderNotFound' of parameter 'pathExportFolder' not found"
	}
	write-logFile

	# save source code as rgcopy.txt
	Set-Content -Path $savedpwshPath -Value $text -ErrorAction 'SilentlyContinue'
	if (!$?) {
		write-logFileWarning "Could not save rgcopy backup '$savedpwshPath'" 
	}

	#--------------------------------------------------------------
	# AZCOPY
	#--------------------------------------------------------------
	$azCopyVersion  = get-azcopyVersion
	
	# test if content copy configured
	$shareCopyNeeded = $false
	if ($copySaShares -is [boolean]) {
		if ($copySaShares -eq $true) {
			$shareCopyNeeded = $true
		}
	}
	elseif ($copySaShares.count -gt 0) {
		$shareCopyNeeded = $true
	}

	if ($simulate) {
		$shareCopyNeeded = $false
	}

	# AZCOPY needed, but not found
	if (($shareCopyNeeded -or $useAzCopy) -and ($null -eq $azCopyVersion)) {
		write-logFileWarning "File $azcopyPath not found"
		install-azcopy
	}

	# parameter updateAzcopy set
	elseif ($updateAzcopy) {
		install-azcopy
	}

	$bicepVersion, $bicepPath = get-bicepVersion

	# BICEP not found
	if ($null -eq $bicepVersion) {
		write-logFileWarning "BICEP not found"
		install-bicep
	}

	# parameter updateBicep set
	elseif ($updateBicep) {
		install-bicep
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

	# versions of PowerShell, BICEP, AZCOPY
	$psVersionString = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch)"
	$bicepVersion, $bicepPath = get-bicepVersion
	$azCopyVersion  = get-azcopyVersion
	if ($useAzureCLI) {
		try {
			$azCliVersion = (az version | ConvertFrom-Json).'azure-cli'
		}
		catch {}
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
	write-logFile 'RGCOPY environment:' -ForegroundColor 'Green'
	write-logFileTab 'pwsh Process ID'		$pid								-darkGray
	write-logFileTab 'Powershell version'	$psVersionString					-noColor
	write-logFileTab 'Az cmdlet version'	$azVersion.version					-noColor
	if ($useAzureCLI) {
		write-logFileTab 'azure-cli version'	$azCliVersion					-darkGray
	}
	write-logFileTab 'Azcopy version'		$azCopyVersion						-darkGray
	write-logFileTab 'BICEP version'		$bicepVersion						-darkGray
	write-logFileTab 'BICEP path'			$bicepPath							-darkGray
	write-logFileTab 'OS version'			$PSVersionTable.OS					-darkGray
	write-logFileTab 'Az.NetAppFiles'		$azAnfVersionString					-darkGray
	test-hashes
	
	if ($isAzure) {
		write-logFileTab 'Azure VM' 		"VM '$azureVM' running in region '$azureRegion'" -darkGray
	}
	# VPN connections
	if ($isWindows) {
		get-VPN
		write-logFileTab 'VPN connection'	$script:connectedVPN -darkGray
		$script:mountPointsCount = 0
		test-VPN
	}
	write-logFile

	#--------------------------------------------------------------
	# check parameters
	#--------------------------------------------------------------
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

	# remove default values
	if (!$copyMode -or $justCopyDisks)  {
		$script:skipDefaultValues = $true
	}

	if ($skipDefaultValues) {
		if ('setDiskSku' -notin $boundParameterNames) {
			$script:setDiskSku = @()
		}
		if ('setAcceleratedNetworking' -notin $boundParameterNames) {
			$script:setAcceleratedNetworking = @()
		}
		if ('setVmZone' -notin $boundParameterNames) {
			$script:setVmZone = @()
		}
		if ('setPrivateIpAlloc' -notin $boundParameterNames) {
			$script:setPrivateIpAlloc = @()
		}
	}

	# update parameter maxDOP=0
	if (!$copyMode -and ($maxDOP -eq 0)) {
		$script:maxDOP = 16
		write-logFileWarning "Parameter maxDOP=0 is only allowed in copy mode" `
								"Keep default value maxDOP=16"
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
		$script:logFiles += $pathArmTemplate
	}
	
	#--------------------------------------------------------------
	# check user and subscription
	#--------------------------------------------------------------
	# if ONLY source or ONLY target is specified: use parameters for both (source AND target)
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

	# get all available contexts
	$script:availableContexts = Get-AzContext -ListAvailable

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
			}
		}
	
		# ensure that user is set
		if ($sourceSubUser.Length -eq 0) {
			$sourceSubUser = $myContext.Account.Id
			$targetSubUser = $myContext.Account.Id
		}
	
		# connect to Source Subscription
		test-context $sourceSub $sourceSubUser $sourceSubTenant 'Source Subscription'
		$sourceContext = Get-AzContext
	
		
		# only one subscription
		if ($sourceSub -eq $targetSub) {
			$targetContext 	= $sourceContext
			$currentSub		= $sourceSub

			# 2 different users not allowed for same subscription
			if (($sourceSubUser -ne $targetSubUser) -or ($sourceSubTenant -ne $targetSubTenant)) {
				write-logFileError "sourceSubUser must be targetSubUser" `
									"when source RG and target RG are in the same subscription"
			}
		}

		# two subscriptions
		else
		{
			# connect to Target Subscription
			test-context $targetSub $targetSubUser $targetSubTenant 'Target Subscription'
			$targetContext	= Get-AzContext
			$currentSub		= $targetSub
		}
	
		# tenant might not been provided as parameter
		$sourceSubTenant	= $sourceContext.Tenant.Id
		$targetSubTenant	= $targetContext.Tenant.Id
	}

	#--------------------------------------------------------------
	# context for control plane VM
	#--------------------------------------------------------------
	if ($isAzure) {
		# get meta data of control plane VM
		try {
			$cpMetaData = Invoke-RestMethod `
						-Headers @{"Metadata"="true"} `
						-Method GET `
						-NoProxy `
						-Uri "http://169.254.169.254/metadata/instance/?api-version=2025-04-07"
		}
		catch {
			$cpMetaData = $null
		}

		if ($null -eq $cpMetaData.compute.resourceId) {
			write-logFileWarning "Could not get meta data for control plane VM"
		}
		else {
			# get subscription ID of control plane VM
			$r = get-resourceComponents $cpMetaData.compute.resourceId

			# get context
			$controlPlaneContext = $script:availableContexts
									| Where-Object {$_.Subscription.Id -eq $r.subscriptionID}

			if ($controlPlaneContext.count -ne 1) {
				$controlPlaneContext = $null
				write-logFileWarning "Could not get Az-context for control plane VM"
			}
			else {
				$controlPlaneSub = $controlPlaneContext.Subscription.Name
			}
		}
	}

	#--------------------------------------------------------------
	# source resource group
	#--------------------------------------------------------------
	set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
	$script:currentAccountId = $sourceContext.Account.Id

	# Check Source Subscription
	$sourceSubProperies = Get-AzSubscription `
						-SubscriptionName $sourceSub `
						-ErrorAction 'SilentlyContinue' `
						-WarningAction 'SilentlyContinue'

	$sourceSubID = $sourceSubProperies.Id
	$sourceSubInternal = ($sourceSubProperies.SubscriptionPolicies.LocationPlacementId -like 'Internal*')
	if ($sourceSubInternal) {
		$script:sourceNoSaKeys = $true
	}
	$sourceSubAllowNSP = ((Get-AzProviderFeature `
									-FeatureName 'AllowNetworkSecurityPerimeter' `
									-ProviderNamespace 'Microsoft.Network' `
									-ErrorAction 'SilentlyContinue').RegistrationState -eq 'Registered')

	if ($Null -eq $sourceSubID) {
		write-logFileError "Source Subscription '$sourceSub' not found"
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
			write-logFileError "Source Resource Group '$sourceRG' not found"
		}
	}

	$sourceSubRoles = get-rbacRoles $sourceSubID $sourceSubUser

	write-logFile 'Source:' -ForegroundColor 'Green'
	write-logFileTab 'Resource Group'	$sourceRG $sourceRgNotFound		-noColor
	write-logFileTab 'Region'			$sourceLocation 				-darkGray
	write-logFileTab 'Subscription'		$sourceSub						-noColor
	write-logFileTab 'User'				$sourceSubUser					-noColor
	write-logFileTab 'Tenant'			$sourceSubTenant				-darkGray
	write-logFileTab 'sourceSubRoles'	$sourceSubRoles 				-darkGray
	write-logFileTab 'SubscriptionID'	$sourceSubID 					-darkGray
	write-logFileTab 'PlacementID'		$sourceSubProperies.SubscriptionPolicies.LocationPlacementId	-darkGray
	write-logFileTab 'QuotaID'			$sourceSubProperies.SubscriptionPolicies.QuotaId				-darkGray
	write-logFileTab 'SpendingLimit'	$sourceSubProperies.SubscriptionPolicies.SpendingLimit			-darkGray
	write-logFileTab 'AllowNSP'			$sourceSubAllowNSP				-darkGray
	write-logFile

	#--------------------------------------------------------------
	# source only mode
	#--------------------------------------------------------------
	if ($SourceOnlyMode) {
		$targetSub			= $sourceSub
		$targetSubID		= $sourceSubID
		$targetSubUser		= $sourceSubUser
		$targetSubTenant	= $sourceSubTenant
		$targetLocation		= $sourceLocation
		$targetRG			= $sourceRG
		$targetSubProperies	= $sourceSubProperies
		$targetSubInternal	= $sourceSubInternal
		$targetNoSaKeys 	= $sourceNoSaKeys
		$targetSubAllowNSP	= $sourceSubAllowNSP
		$targetSubRoles		= $sourceSubRoles
		if ($mergeMode) {
			write-logFileWarning "Using source RG as target RG in Merge Mode"
		}

		$targetSubEncryptionAtHost = ((Get-AzProviderFeature `
										-FeatureName 'EncryptionAtHost' `
										-ProviderNamespace 'Microsoft.Compute' `
										-ErrorAction 'SilentlyContinue').RegistrationState -eq 'Registered')
	}
	
	#--------------------------------------------------------------
	# target resource group
	#--------------------------------------------------------------
	else {
		set-context $targetSub # *** CHANGE SUBSCRIPTION **************

		$targetSubEncryptionAtHost = ((Get-AzProviderFeature `
										-FeatureName 'EncryptionAtHost' `
										-ProviderNamespace 'Microsoft.Compute' `
										-ErrorAction 'SilentlyContinue').RegistrationState -eq 'Registered')

		$targetSubProperies = Get-AzSubscription `
								-SubscriptionName $targetSub `
								-ErrorAction 'SilentlyContinue' `
								-WarningAction 'SilentlyContinue'

		$targetSubID = $targetSubProperies.Id
		$targetSubInternal = ($targetSubProperies.SubscriptionPolicies.LocationPlacementId -like 'Internal*')

		#--------------------------------------------------------------
		# defaults for MS-internal subscriptions
		if ($targetSubInternal) {
			$script:targetNoSaKeys = $true
		}

		#--------------------------------------------------------------
		# other defaults in copy mode
		if ('ignoreExtensionErrors' -notin $boundParameterNames) {
			$script:ignoreExtensionErrors = $true
		}
		if ('ignorePatchErrors' -notin $boundParameterNames) {
			$script:ignorePatchErrors = $true
		}

		$targetSubAllowNSP = ((Get-AzProviderFeature `
										-FeatureName 'AllowNetworkSecurityPerimeter' `
										-ProviderNamespace 'Microsoft.Network' `
										-ErrorAction 'SilentlyContinue').RegistrationState -eq 'Registered')

		if ($Null -eq $targetSubID) {
			write-logFileError "Target Subscription '$targetSub' not found"
		}

		get-subscriptionFeatures

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

		$targetSubRoles = get-rbacRoles $targetSubID $targetSubUser

		write-logFile 'Target:' -ForegroundColor 'Green'
		write-logFileTab 'Resource Group' 	$targetRG -noColor

		if ($sourceLocation -eq $targetLocation) {
			write-logFileTab 'Region' 			$targetLocation	-darkGray
		}
		else {
			write-logFileTab 'Region' 			"$targetLocation ($targetLocationDisplayName)"	-noColor
		}

		if ($targetSubID -eq $sourceSubID) {
			write-logFileTab 'Subscription'		'ditto'				-darkGray
			write-logFileTab 'User'				'ditto'				-darkGray
			write-logFileTab 'Tenant'			'ditto'				-darkGray
		}
		else {
			write-logFileTab 'Subscription' 	$targetSub			-noColor
			write-logFileTab 'User' 			$targetSubUser		-noColor
			write-logFileTab 'Tenant' 			$targetSubTenant	-darkGray
			write-logFileTab 'targetSubRoles'	$targetSubRoles 	-darkGray

		

			write-logFileTab 'SubscriptionID'	$targetSubID													-darkGray
			write-logFileTab 'PlacementID'		$targetSubProperies.SubscriptionPolicies.LocationPlacementId	-darkGray
			write-logFileTab 'QuotaID'			$targetSubProperies.SubscriptionPolicies.QuotaId				-darkGray
			write-logFileTab 'SpendingLimit'	$targetSubProperies.SubscriptionPolicies.SpendingLimit			-darkGray
			write-logFileTab 'AllowNSP'			$targetSubAllowNSP												-darkGray
		}

		# default for Owner Tag
		if ($setOwner -eq '*') {
			$setOwner = $targetSubUser
		}

		#--------------------------------------------------------------
		# Storage Account for disk creation
		if ($blobsRG.Length -eq 0) {
			$script:blobsRG = $targetRG
		}
		if ($blobsSA.Length -eq 0) {
			$script:blobsSA = $targetSA
		}
		if ($blobsSaContainer.Length -eq 0)	{
			$script:blobsSaContainer = $targetSaContainer
		}

		# output blobsRG
		if ($targetRG -ne $blobsRG) {
			Get-AzResourceGroup `
				-Name 	$blobsRG `
				-ErrorAction 'SilentlyContinue' | Out-Null
			if (!$?) {
				write-logFileError "Disk Resource Group '$blobsRG' not found"
			}
			write-logFileTab 'Disk Resource Group' $blobsRG -noColor
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
			write-logFileTab 'Disk Storage Account' $blobsSA  -noColor
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
			write-logFileTab 'Disk Storage Account Container' $blobsSaContainer -noColor
		}
		#--------------------------------------------------------------
		
		write-logFile
		set-context $sourceSub # *** CHANGE SUBSCRIPTION **************

		# check if source and target are identical
		if ( ($sourceSub -eq $targetSub) `
		-and ($sourceRG -eq $targetRG) ) {
	
			if (!$justCreateSnapshots -and !$justDeleteSnapshots) {
				write-logFileError "Source and Target Resource Group are identical"
			}
		}
	
		# target location not found
		if ($null -eq $targetLocationDisplayName) {
			if (!$justCreateSnapshots -and !$justDeleteSnapshots) {
				write-logFileError "Target Region '$targetLocation' not found"
			}
		}
	}

	# check if same user given
	if (($sourceSubUser   -ne $targetSubUser) `
	-or ($sourceSubTenant -ne $targetSubTenant)) {
		
		$script:differentTenantOrUser = $true
	}
	else {
		$script:differentTenantOrUser = $false
	}
	write-logFile

	#--------------------------------------------------------------
	# debug actions
	#--------------------------------------------------------------
	if ($patchMode -or $patchVMsTargetRG) {
		assert-hashes "For patching VMs, additional RGCOPY files are needed"
	}

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

	#--------------------------------------------------------------
	# parameter justCreateSnapshots
	# Caution: skipVMs and skipDisks are taken into account
	elseif ($justCreateSnapshots) {
		$script:copyDetachedDisks = $true
		get-sourceVMs
		assert-vmsStopped
		step-snapshots
		write-zipFile 0
	}

	#--------------------------------------------------------------
	# parameter justStopCopyBlobs
	# Caution: skipVMs and skipDisks are taken into account
	elseif ($justStopCopyBlobs) {
		if ($archiveMode) {
			$blobsSaContainer	= $archiveContainer
			$targetSaContainer	= $archiveContainer
		}
		get-sourceVMs
		grant-saAccess4controlPlane 'blobCopy'
		new-blobCopyToken
		stop-copySnapshots2Blobs
		write-zipFile 0
	}

	#--------------------------------------------------------------
	# UPDATE MODE
	elseif ($updateMode) {
		test-updateMode
		get-sourceVMs
		step-updateMode
		write-zipFile 0
	}

	#--------------------------------------------------------------
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
			start-parallelVMs $targetRG $patchVMs
			step-patchOS
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
			stop-parallelVMs $sourceRG $patchVMs -skipMeasurement
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
	test-waitRemoteCopy
	test-stopRestore			# skipRemoteCopy = $True
	test-givenArmTemplate		# skipRemoteCopy = $True

	# do not stop VMs when waiting for backups to finish
	if ($waitBackup) {
		$stopVMsSourceRG =	 $false
		$skipSnapshots 		= $true
	}
	if ($waitRestore) {
		$stopVMsSourceRG	= $false
		$skipSnapshots		= $true
		$skipBackups		= $True
		$skipRemoteCopy		= $True
		$skipDeployment		= $True
	}
	
	# some not needed steps:
	if (($createVolumes.count -eq 0) -and ($createDisks.count -eq 0)) {
		$skipBackups = $True
		$skipRestore = $True
		$useFileCopy = $false
	}
	else {
		$useFileCopy = $true
	}


	if ($simulate -or $deleteBackupsOnly -or $justCopySaShares) {
		$skipSnapshots	= $True
		$skipBackups	= $True
		$skipRemoteCopy	= $True
		$skipDeployment	= $True
		$skipRestore	= $true
		$skipCleanup	= $True
		$startWorkload	= $False
	}

	if ($deleteBackupsOnly) {
		$deleteBackups  = $true
		$skipCleanup	= $false
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

	# remote copy needed?
	if ($differentTenantOrUser) {
		$RemoteCopyNeeded = $True
	}

	if (!$RemoteCopyNeeded) {
		$skipRemoteCopy = $True
	}

	# skipDiskCreation
	if ($skipDiskCreation) {
		$createDisksManually = $true
		$allowExistingDisks = $true
		$skipSnapshots = $true
		$skipRemoteCopy = $true
		$deleteSnapshots = $false
	}

	# extensions
	if ($skipDeployment) {
		$skipExtensions = $true
	}
	
	#--------------------------------------------------------------
	# output of steps
	#--------------------------------------------------------------
	if ($skipBackups      ) {$doBackups         = '[ ]'} else {$doBackups         = '[X]'}
	if ($skipRestore      ) {$doRestore         = '[ ]'} else {$doRestore         = '[X]'}
	if ($deleteBackups    ) {$doDeleteBackups   = '[X]'} else {$doDeleteBackups   = '[ ]'}

	if ($skipArmTemplate  ) {$doArmTemplate     = '[ ]'} else {$doArmTemplate     = '[X]'}
	if ($skipSnapshots    ) {$doSnapshots       = '[ ]'} else {$doSnapshots       = '[X]'}
	if ($skipRemoteCopy   ) {$doRemoteCopy      = '[ ]'} else {$doRemoteCopy      = '[X]'}
	if ($skipDeployment   ) {$doDeployment      = '[ ]'} else {$doDeployment      = '[X]'}
	if ($skipExtensions   ) {$doExtensions      = '[ ]'} else {$doExtensions      = '[X]'}
	if ($startWorkload    ) {$doWorkload        = '[X]'} else {$doWorkload        = '[ ]'}
	if ($deleteSnapshots  ) {$doDeleteSnapshots = '[X]'} else {$doDeleteSnapshots = '[ ]'}
	if ($stopVMsTargetRG  ) {$doStopVMsTargetRG = '[X]'} else {$doStopVMsTargetRG = '[ ]'}
	if ($shareCopyNeeded  ) {$doCopySaShares    = '[X]'} else {$doCopySaShares    = '[ ]'}

	write-logFile 'Required steps:' -ForegroundColor 'Green'
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
		write-logFile		"  Prepare:"
		write-logFile		"    $doArmTemplate Create BICEP Template (referring to snapshots)"
		write-logFile		"    $doSnapshots Create snapshots (in source RG)"
		if ($useFileCopy) {
			write-logFile	"    $doBackups Create file backup (of disks and volumes to RGCOPY NFS Share in source RG)"
		}
		write-logFile		"    $doRemoteCopy Copy snapshots (into target RG)"

		# deployment
		write-logFile	"  Deploy:"
		write-logFile		"    $doDeployment Deploy Virtual Machines"
		if ($useFileCopy) {
			write-logFile	"    $doRestore Restore files (to disks and volumes from RGCOPY NFS Share)"
		}
		write-logFile 		"    $doExtensions Deploy Extensions"

		# workload
		write-logFile	"  Process:"
		write-logFile	"    $doCopySaShares Copy storage account content"
		write-logFile	"    $doWorkload Run workload"

		# cleanup
		write-logFile	"  Cleanup:"
		write-logFile		"    $doDeleteSnapshots Delete Snapshots (in source RG)"
		if ($useFileCopy -or $deleteBackupsOnly) {
			write-logFile	"    $doDeleteBackups Delete RGCOPY NFS Share in source RG)"
		}
		write-logFile		"    $doStopVMsTargetRG Stop VMs (in target RG)"
	}
	write-logFile
	write-logFile
	
	#--------------------------------------------------------------
	# run steps
	#--------------------------------------------------------------
	$script:sapAlreadyStarted = $False
	$script:vmStartWaitDone = $False
	
	if ($allowRunningVMs) {
		write-logFile
		write-logFileWarning 'Parameter allowRunningVMs is set. This could result in inconsistent disk copies.'
		write-logFile
	}
	
	# STEP "Get VMs and disks from source RG"
	if (!$skipArmTemplate `
	-or !$skipSnapshots `
	-or !$skipRemoteCopy `
	-or !$skipBackups `
	-or !$skipRestore `
	-or ($justCopyDisks.count -ne 0) ) {
	
		write-stepStart "READ SOURCE RG" -startMeasurement
		get-sourceVMs
		assert-vmsStopped
		write-stepEnd -endMeasurement
	}

	# STEP BICEP TEMPLATE
	step-bicepTemplate

	set-context $targetSub # *** CHANGE SUBSCRIPTION **************	
	new-resourceGroup

	set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
	if ($cloneMode) {
		step-prepareClone
	}

	step-snapshots
	step-snapshotsShares
	$script:nfsVnetName, $script:nfsSubnetName = get-nfsSubnet

	#--------------------------------------------------------------
	# reduce time where snapshot copy exists: delete snapshot copy early
	# allow running second instance of RGCOPY earlier
	if ($removeRemoteSnapshotsEarly) {
		set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
		if (!$skipRemoteCopy) {
			start-remoteBlobs
				start-remoteSnapshots
				wait-remoteSnapshots
			wait-remoteBlobs
		}
		
		set-context $targetSub # *** CHANGE SUBSCRIPTION **************
		step-deployment
		if (!$skipRemoteCopy) {
			remove-remoteSnapshots
			remove-remoteBlobs
		}

		set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
		start-backup
		wait-backup
	}
	#--------------------------------------------------------------
	# normal workflow: delete snapshot copy late
	# parallel running backups and snapshot copy
	else {
		set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
		start-backup
			if (!$skipRemoteCopy) {
				start-remoteBlobs
					start-remoteSnapshots
					wait-remoteSnapshots
				wait-remoteBlobs
			}
		wait-backup
		
		set-context $targetSub # *** CHANGE SUBSCRIPTION **************
		step-deployment
		if (!$skipRemoteCopy) {
			remove-remoteSnapshots
			remove-remoteBlobs
		}
	}
	#--------------------------------------------------------------

	if (!$stopRestore -and !$simulate) {
		start-restore
			step-copySaContent
			set-context $targetSub # *** CHANGE SUBSCRIPTION **************
		wait-restore
	
		set-context $targetSub # *** CHANGE SUBSCRIPTION **************
		if ($startWorkload) {
			step-workload
		}

		if (!$skipCleanup) {
			stop-VMsTargetRG
		}
		
		set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
		if (!$skipCleanup) {
			remove-localSnapshots
			if ($deleteBackups) {
				remove-endpoint $sourceRG
				remove-storageAccount $sourceRG $sourceSA $sourceSub $sourceSubID
			}
		}
	}
}

# catch all unhandled errors
catch {
	Write-Output $error[0]
	Write-Output $error[0] *>>$logPath
	write-logFileError "PowerShell exception caught" `
						$error[0]
}

write-zipFile 0
