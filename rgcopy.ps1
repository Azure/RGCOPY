<#
rgcopy.ps1:       Copy Azure Resource Group
version:          0.9.34
version date:     April 2022
Author:           Martin Merdes
Public Github:    https://github.com/Azure/RGCOPY
Microsoft intern: https://github.com/Azure/RGCOPY-MS-intern

//
// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.
//

#>
#Requires -Version 7.1
#Requires -Modules 'Az.Accounts'
#Requires -Modules 'Az.Compute'
#Requires -Modules 'Az.Storage'
#Requires -Modules 'Az.Network'
#Requires -Modules 'Az.Resources'

# by default, Parameter Set 'copyMode' is used
[CmdletBinding(	DefaultParameterSetName='copyMode',
				HelpURI="https://github.com/Azure/RGCOPY/blob/main/rgcopy-docu.md")]
param (
	#--------------------------------------------------------------
	# essential parameters
	#--------------------------------------------------------------
	# parameter is always mandatory
	 [Parameter(Mandatory=$True)]
	 [string] $sourceRG										# Source Resource Group

	# parameter is mandatory, dependent on used Parameter Set
	,[Parameter(Mandatory=$False,ParameterSetName='updateMode')]
	 [Parameter(Mandatory=$True, ParameterSetName='copyMode')]
	 [string] $targetRG										# Target Resource Group (will be created)
	,[switch] $allowExistingDisks							# do not check whether the targetRG already contains disks

	# parameter is mandatory, dependent on used Parameter Set
	,[Parameter(Mandatory=$False,ParameterSetName='updateMode')]
	 [Parameter(Mandatory=$True, ParameterSetName='copyMode')]
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
	,[switch] $skipBlobs									# skip BLOB creation (in targetRG)
	,[switch] $skipDeployment								# skip deployment (in targetRG)
	,[switch]   $skipDeploymentVMs							# skip part step: deploy Virtual Machines
	,[switch]   $skipRestore								# skip part step: restore files
	,[switch]      $stopRestore								# run all steps until (excluding) Restore
	,[switch]      $continueRestore							# run Restore and all later steps
	,[switch]   $skipExtensions								# skip part step: install VM extensions
	,[switch] $startWorkload								# start workload
	,[switch] $stopVMsTargetRG 								# stop VMs in the target RG after deployment
	,[switch] $deleteSnapshots								# delete snapshots after deployment
	,[switch] $deleteSourceSA								# delete storage account in the source RG after deployment
	,[switch] $deleteTargetSA								# delete storage account in the target RG after deployment
	# simulating
	,[switch] $simulate										# just create ARM template

	# BLOB switches
	,[switch] $useBlobs										# always (even in same region) copy snapshots to BLOB
	,[switch] $useBlobsFromDisk								# always (even in same region) copy disks to BLOB
	# only if $skipBlobs -eq $True:
	,[string] $blobsSA										# Storage Account of BLOBs
	,[string] $blobsRG										# Resource Group of BLOBs
	,[string] $blobsSaContainer								# Container of BLOBs

	#--------------------------------------------------------------
	# parameters for Archive Mode
	#--------------------------------------------------------------
	,[switch] $archiveMode									# create backup of source RG to BLOB, no deployment
	,[string] $archiveContainer								# container in storage account that is used for backups
	,[switch] $archiveContainerOverwrite					# allow overwriting existing archive container

	#--------------------------------------------------------------
	# parameters for Update Mode
	#--------------------------------------------------------------
	# used Parameter Set is 'updateMode' when switch updateMode is set
	,[Parameter(ParameterSetName='updateMode')]
	 [switch] $updateMode									# change properties in source RG
	# ,[switch] $simulate									# just simulate Updates
	# ,[switch] $stopVMsSourceRG 							# parameter also available in Copy Mode, see above
	# ,$setVmSize	= @()									# parameter also available in Copy Mode, see below
	# ,$setDiskSize = @()									# parameter also available in Copy Mode, see below
	# ,$setDiskTier = @()									# parameter also available in Copy Mode, see below
	# ,$setDiskBursting = @()								# parameter also available in Copy Mode, see below
	# ,$setDiskCaching = @()								# parameter also available in Copy Mode, see below
	# ,$setDiskSku = @()									# parameter also available in Copy Mode, see below
	# ,$setAcceleratedNetworking = @()						# parameter also available in Copy Mode, see below
	# ,[switch] $deleteSnapshots							# parameter also available in Copy Mode, see below
	,[switch] $deleteSnapshotsAll							# delete all snapshots
	,[string] $createBastion								# create bastion. Parameter format: <addressPrefix>@<vnet>
	,[switch] $deleteBastion								# delete bastion

	#--------------------------------------------------------------
	# file locations
	#--------------------------------------------------------------
	,[string] $pathArmTemplate								# given ARM template file
	,[string] $pathArmTemplateAms							# given ARM template file for AMS deployment
	,[string] $pathExportFolder	 = '~'						# default folder for all output files (log-, config-, ARM template-files)
	,[string] $pathPreSnapshotScript						# running before ARM template creation on sourceRG (after starting VMs and SAP)
	,[string] $pathPostDeploymentScript						# running after deployment on targetRG

	#--------------------------------------------------------------
	# AMS and script parameter
	#--------------------------------------------------------------
	# AMS (Azure Monitoring for SAP) parameters
	,[switch] $createArmTemplateAms							# create AMS ARM template and deploy AMS
	,[string] $amsInstanceName								# Name of AMS instance to be created in the target RG
	,[string] $amsWsName									# Name of existing Log Analytics workspace for AMS
	,[string] $amsWsRG										# Resource Group of existing Log Analytics workspace for AMS
	,[switch] $amsWsKeep									# Keep existing Log Analytics workspace of sourceRG
	,[switch] $amsShareAnalytics							# Sharing Customer Analytics Data with Microsoft
	,[SecureString] $dbPassword			# = (ConvertTo-SecureString -String 'secure-password' -AsPlainText -Force)
	,[boolean] $amsUsePowerShell = $True					# use PowerShell cmdlets rather than ARM template for AMS deployment

	# script location of shell scripts inside the VM
	,[string] $scriptStartSapPath							# if not set, then calculated from vm tag rgcopy.ScriptStartSap
	,[string] $scriptStartLoadPath							# if not set, then calculated from vm tag rgcopy.ScriptStartLoad
	,[string] $scriptStartAnalysisPath						# if not set, then calculated from vm tag rgcopy.ScriptAnalyzeLoad

	# VM extensions
	,$installExtensionsSapMonitor	= @()					# Array of VMs where SAP extension should be installed
	,$installExtensionsAzureMonitor	= @()					# Array of VMs where VM extension should be installed

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
	,[string] $smbTier				= 'Premium_LRS'			# Tier of SMB share for converting NetApp or disks: 'Premium_LRS', 'Standard_LRS'

	#--------------------------------------------------------------
	# default values
	#--------------------------------------------------------------	
	,[int] $grantTokenTimeSec		= 3 * 24 * 60 * 60		# grant access to source disks for 3 days
	,[int] $waitBlobsTimeSec		= 5 * 60				# wait time between status messages of BLOB copy (or backup/restore)
	,[int] $vmStartWaitSec			= 5 * 60				# wait time after VM start before using the VMs (before trying to run any script)
	,[int] $preSnapshotWaitSec		= 5 * 60				# wait time after running pre-snapshot script
	,[int] $vmAgentWaitMinutes		= 30					# maximum wait time until VM Agent is ready
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
	#  0 means: remove Fault Domain configuration from the VM

	,$createVmssFlex = @()
	# usage: $createVmssFlex = @("$vmss/$fault$/$zones@$vm1,$vm2,...", ...)
	#	with $vmss:  name of VM Scale Set Flexible
	#        $zones: Allowed Zones in {none, 1+2, 1+3, 2+3, 1+2+3}
	#        $fault: Fault domain count in in {none, 2, 3, max}

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

	,$setVmMerge = @()
	# usage: $setVmMerge = @("$net/$subnet@$vm1,$vm2,...", ...)
	#	with $net as virtual network name, $subnet as subnet name in target resource group
	# merge VM jumpbox into target RG:					@("vnet/default@jumpbox")

	,$setLoadBalancerSku = 'Standard'				# default value in COPY MODE
	# usage: $setLoadBalancerSku = @("$sku@$loadBalancer1,$loadBalancer12,...", ...)
	#	with $sku -in @('Basic', 'Standard')

	,$setPublicIpSku = @()
	#usage: $setPublicIpSku = @("$sku@$ipName1,$ipName12,...", ...)
	#	with $sku -in @('Basic', 'Standard')

	,$setPublicIpAlloc = @()
	# usage: $setPublicIpAlloc = @("$allocation@$ipName1,$ipName12,...", ...)
	#	with $allocation -in @('Dynamic', 'Static')

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

	,[switch] $renameDisks	# rename all disks using their VM name

	#--------------------------------------------------------------
	# parameters for cleaning an incomplete RGCOPY run
	#--------------------------------------------------------------
	,[switch] $restartBlobs					# restart a failed BLOB Copy
	,[array]  $justCopyBlobs 				# only copy these disks to BLOB
	,[switch] $justStopCopyBlobs
	# use Parameter Set updateMode when switch justCreateSnapshots is set
	,[Parameter(ParameterSetName='updateMode')]
	 [switch] $justCreateSnapshots
	# use Parameter Set updateMode when switch justDeleteSnapshots is set
	,[Parameter(ParameterSetName='updateMode')]
	 [switch] $justDeleteSnapshots

	#--------------------------------------------------------------
	# experimental parameters: DO NOT USE!
	#--------------------------------------------------------------
	# use Parameter Set updateMode when switch justRedeployAms is set
	,[Parameter(ParameterSetName='updateMode')]
	 [switch] $justRedeployAms
	,$setVmTipGroup			= @()
	,$setGroupTipSession	= @()
	,[switch] $allowRunningVMs
	,[switch] $skipGreenlist
	,[switch] $skipStartSAP
	,$generalizedVMs		= @()
	,$generalizedUser		= @()
	,$generalizedPasswd		= @() # will be checked below for data type [SecureString] or [SecureString[]]
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

$variableTypeParameters = @(
	'snapshotVolumes',
	'createVolumes',
	'createDisks',
	'setVmDeploymentOrder',
	'setVmTipGroup',
	'setVmName',
	'setVmMerge',
	'setVmSize',
	'setVmZone',
	'setDiskSku',
	'setDiskSize',
	'setDiskMaxShares',
	'setDiskTier',
	'setDiskBursting',
	'setDiskCaching',
	'setAcceleratedNetworking',
	'setLoadBalancerSku',
	'setPublicIpSku',
	'setPublicIpAlloc',
	'setPrivateIpAlloc',
	'removeFQDN',
	'createProximityPlacementGroup',
	'createAvailabilitySet',
	'setGroupTipSession',
	'setVmFaultDomain',
	'createVmssFlex'
)

$workflowParameters = @(
	'updateMode',
	'archiveMode',
	'skipArmTemplate',
	'skipSnapshots',
	'stopVMsSourceRG',
	'skipBackups',
	'skipBlobs',
	'skipDeployment',
	'skipDeploymentVMs',
	'skipRestore',
	'stopRestore',
	'continueRestore',
	'skipExtensions',
	'startWorkload',
	'stopVMsTargetRG',
	'deleteSnapshots',
	'deleteSourceSA',
	'deleteTargetSA',
	'simulate',
	'restartBlobs',
	'justCopyBlobs',
	'justStopCopyBlobs',
	'justCreateSnapshots',
	'justDeleteSnapshots',
	'justRedeployAms',
	'skipStartSAP'
)

# Update Mode
if ($updateMode) {
	$copyMode		= $False
	$archiveMode	= $False
	$rgcopyMode = 'Update Mode'
}
# Archive Mode
elseif ($archiveMode) {
	$copyMode		= $False
	$rgcopyMode = 'Archive Mode'
}
# Copy Mode
else {
	$copyMode		= $True
	$rgcopyMode = 'Copy Mode'
}

# process only sourceRG ?
if ($updateMode -or $justCreateSnapshots -or $justDeleteSnapshots -or $justRedeployAms) {
	$targetRG = $sourceRG
	$enableSourceRgMode = $True
	$rgcopyMode = 'Update Mode'
}
else {
	$enableSourceRgMode = $False
}

# constants
$snapshotExtension	= 'rgcopy'
$netAppSnapshotName	= 'rgcopy'
$targetSaContainer	= 'rgcopy'
$sourceSaShare		= 'rgcopy'
$netAppPoolSizeMinimum = 4 * 1024 * 1024 * 1024 * 1024

# azure tags
$azTagTipGroup 				= 'rgcopy.TipGroup'
$azTagDeploymentOrder 		= 'rgcopy.DeploymentOrder'
$azTagSapMonitor 			= 'rgcopy.Extension.SapMonitor'
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

# file names and location
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
$exportPathAms 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.AMS.json"
$logPath			= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.TARGET.log"

$timestampSuffix 	= (Get-Date -Format 'yyyy-MM-dd__HH-mm-ss')
# fixed file paths
$tempPathText 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.TEMP.txt"
$zipPath 			= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG2.$timestampSuffix.zip"
$zipPath2 			= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.arm-templates.zip"
$savedRgcopyPath	= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.txt"
$restorePath 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.RESTORE.ps1.txt"

# file names for source RG processing
if ($enableSourceRgMode) {
	$logPath		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.SOURCE.log"
	$zipPath 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.$timestampSuffix.zip"
}

# file names for backup RG
if ($archiveMode) {
	$exportPath 	= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.TARGET.json"
	$exportPathAms 	= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG2.AMS.json"
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

	if ($value -notmatch $match) {
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
	test-values 'smbTier' $smbTier @('Premium_LRS', 'Standard_LRS')
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

		$script:sourceSA = 'smb' + $name.SubString(0,$len)
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
	# amsInstanceName
	# Can include alphanumeric (,underscore, hyphen)
	# length: 6-30
	$match = '^[a-zA-Z0-9_\-]{6,30}$'

	if ($script:amsInstanceName.Length -eq 0) {
		$name = $script:targetRG -replace '[_\.\-\(\)]', '-'  -replace '\-+', '-' `

		# truncate name
		$len = (30, $name.Length | Measure-Object -Minimum).Minimum
		$name = $name.SubString(0,$len)

		# name too short
		if ($len -lt 6) {
			$name += '-ams-inst'
		}

		$script:amsInstanceName = $name
	}
	else {
		test-match 'amsInstanceName' $script:amsInstanceName $match
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
function write-logFile {
#--------------------------------------------------------------
	param (
		$print,
		$ForegroundColor,
		[switch] $NoNewLine
	)

	if ($Null -eq $print) {
		$print = ' '
	}
	[string] $script:LogFileLine += $print

	$par = @{ Object = $print }
	if ($NoNewLine) {
		$par.Add('NoNewLine', $True)
	}
	if ($Null -ne $ForegroundColor) {
		$par.Add('ForegroundColor', $ForegroundColor)
	}

	Write-Host @par
	if (!$NoNewLine) {
		Write-Host $script:LogFileLine *>>$logPath
		[string] $script:LogFileLine = ''
	}
}

#--------------------------------------------------------------
function write-LogFilePipe {
#--------------------------------------------------------------
	[CmdletBinding()]
	Param (
		[Parameter(Position=0, Mandatory=$true, ValueFromPipeline=$true)]
		$InputObject
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
		[switch] $stopAtWarning
	)

	if (($stopAtWarning -and $forceVmChecks) `
	-or ($stopCondition -eq $True)) {
		write-logFileError $myWarning $param2 $param3 $param4
	}

	write-logFile "WARNING: $myWarning" -ForegroundColor 'yellow'

	if ($param2.length -ne 0) { write-logFile $param2 }
	if ($param3.length -ne 0) { write-logFile $param3 }
	if ($param4.length -ne 0) { write-logFile $param4 }
	if ($param2.length -ne 0) { write-logFile }
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
		write-logFile "RGCOPY EXIT CODE:  $exitCode" -ForegroundColor 'DarkGray'
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
			$sa = Get-AzStorageAccount `
				-ResourceGroupName 	$targetRG `
				-Name 				$targetSA `
				-ErrorAction 'Stop'
			if ($?) {
				# save ARM template as BLOB
				Set-AzStorageBlobContent `
					-Container	$targetSaContainer `
					-File		$destinationPath `
					-Context	$sa.Context `
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
		[console]::ResetColor()
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
		$param4,
		[switch] $lastError
	)

	if ($lastError) {
		write-logFile
		write-logFile $error[0] -ForegroundColor 'Red'
	}
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
	write-logFile "ERROR MESSAGE: $param1"
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
			$resource = $resource.PadRight($resourceLength,' ').Substring(0,$resourceLength)
	
			Write-logFile $resourceType -NoNewline -ForegroundColor 'DarkGray'
			write-logFile $resource -NoNewline -ForegroundColor $colorResource
		}
	}

	# colors for creation/deletion
	if (($action -like 'delete*') -or ($action -like 'disable*')) {
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
function write-logFileForbidden {
#--------------------------------------------------------------
	param (	
		$parameter,
		$array
	)

	if ($parameter -in $boundParameterNames) {
		foreach ($boundParam in $array) {
			if ($boundParam -in $boundParameterNames) {
				write-logFileError "Invalid parameter '$boundParam'" `
									"Parameter is not allowed when '$parameter' is supplied"
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
				elseif (($_.Parameter -replace '\[\d+\]$', '') -in $variableTypeParameters) {
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

	if (($value -is [securestring]) -or ($key -like '*passw*') -or ($key -like '*credential*')) {
		$protectedValue = '*****'
	}
	else {
		$protectedValue = $value
	}

	$script:hashTableOutput += New-Object psobject -Property @{
		Parameter	= $key
		Value		= $protectedValue
	}
}

#--------------------------------------------------------------
function test-azResult {
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
function write-stepStart {
#--------------------------------------------------------------
	param (
		$text,
		$maxDegree
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
	write-logFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') -ForegroundColor DarkGray
	write-logFile
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
	if ($script:paramRules.count -le $script:paramIndex) { return }

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
							'Invalid data type, the rule is not a string'
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
		if ($script:paramName -like 'setVm*') {
			$notFound = convertTo-array ($script:paramResources | Where-Object {$_ -notin $script:paramVMs})
			if ($notFound.count -ne 0) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"Rule: '$currentRule'" `
									"VM '$($notFound[0])' not found"
			}
		}
		if ($script:paramName -like 'setDisk*') {
			$notFound = convertTo-array ($script:paramResources | Where-Object {$_ -notin $script:paramDisks})
			if ($notFound.count -ne 0) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"Rule: '$currentRule'" `
									"Disk '$($notFound[0])' not found"
			}
		}
		if ($script:paramName -eq 'setAcceleratedNetworking') {
			$notFound = convertTo-array ($script:paramResources | Where-Object {$_ -notin $script:paramNICs})
			if ($notFound.count -ne 0) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"Rule: '$currentRule'" `
									"NIC '$($notFound[0])' not found"
			}
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
			$myResources = $resourceNames
		}
		else {
			$myResources = $script:paramResources
			# check existence
			if (!$ignoreMissingResources) {
				$notFound = convertTo-array ($script:paramResources | Where-Object {$_ -notin $resourceNames})
				if ($notFound.count -ne 0) {
					write-logFileError "Invalid parameter '$script:paramName'" `
										"Resource '$($notFound[0])' not found"
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
		return @{ Process = $scriptBlock }
	}
	else {
		$scriptReturn = [Scriptblock]::Create($scriptParameter + $scriptBlock.toString())
		return @{ ThrottleLimit = $myMaxDOP; Parallel = $scriptReturn }
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

	$resFunction = "[resourceId('$resourceArea/$mainResourceType"
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
	$resFunction += ")]"

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
	if ($condensedString[0] -eq '[') {

		# remove square brackets
		if ($condensedString[-1] -ne ']') {
			write-logFileError "Error parsing ARM resource:" `
								"$inputString"
		}
		if ($condensedString.length -le 2) {
			write-logFileError "Error parsing ARM resource:" `
								"$inputString"
		}
		$str = $condensedString.Substring(1,$condensedString.length -2)

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

		$resourceType,$mainResourceName,$subResourceName = $str -split ','
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
	elseif ($condensedString[0] -eq '/') {
		$resID = $inputString
		$x,$s,$subscriptionID,$r,$resourceGroup,$p,$resourceArea,$mainResourceType,$mainResourceName,$subResourceType,$subResourceName = $resId -split '/'
		if ($subResourceName.count -gt 1) {
			write-logFileError "Error parsing ARM resource:" `
								"$inputString"
		}
	}
	else {
		write-logFileError "Error parsing ARM resource:" `
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
	set-AzContext -Context $myContext[0] -ErrorAction 'SilentlyContinue' | Out-Null
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

	if ($mySubscription -eq $script:currentSub) { return}

	write-logFile "--- set subscription context $mySubscription ---" -ForegroundColor DarkGray

	if ($mySubscription -eq $sourceSub) {
		Set-AzContext -Context $sourceContext -ErrorAction 'SilentlyContinue' | Out-Null
		test-azResult 'Set-AzContext'  "Could not connect to Subscription '$mySubscription'"

	} elseif ($mySubscription -eq $targetSub) {
		Set-AzContext -Context $targetContext -ErrorAction 'SilentlyContinue' | Out-Null
		test-azResult 'Set-AzContext'  "Could not connect to Subscription '$mySubscription'"

	} else {
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
			MemoryGB						= 0
			MaxDataDiskCount                = 9999
			PremiumIO                       = $True
			MaxWriteAcceleratorDisksAllowed = 9999
			MaxNetworkInterfaces            = 9999
			AcceleratedNetworkingEnabled    = $True
			HyperVGenerations               = 'V1,V2'
			CpuArchitectureType             = 'x64'
		}
	}
}

#--------------------------------------------------------------
function save-skuProperties {
#--------------------------------------------------------------
# save properties of each VM size
	$script:vmFamilies = @{}
	$script:vmSkus = @{}
	$script:diskSkuInRegion = @{}

	if ($skipVmChecks) { return }

	$savedSub = $script:currentSub
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	# get SKUs for all VM sizes in target
	$allSKUs = Get-AzComputeResourceSku `
				-Location		$targetLocation `
				-ErrorAction	'SilentlyContinue' 
	test-azResult 'Get-AzComputeResourceSku'  "Could not get SKU properties for region '$targetLocation'" `
					"You can skip this step using RGCOPY parameter switch 'skipVmChecks'"

	# max fault domain count
	$allSKUs
	| Where-Object ResourceType -eq 'availabilitySets'
	| Where-Object Name -eq 'Aligned'
	| ForEach-Object {

		$script:MaxRegionFaultDomains = `
			($_.Capabilities | Where-Object Name -eq 'MaximumPlatformFaultDomainCount').Value -as [int]
	}
	if ($script:MaxRegionFaultDomains -eq 0) {
		write-logFileWarning "Could not get MaximumPlatformFaultDomainCount for region '$targetLocation'"
		$script:MaxRegionFaultDomains = 2
	}

	# disk SKUs
	$allSKUs
	| Where-Object ResourceType -eq 'disks'
	| ForEach-Object {

		$script:diskSkuInRegion[$_.Name] = $True
	}

	# VM SKUs
	$allSKUs
	| Where-Object ResourceType -eq 'virtualMachines'
	| ForEach-Object {

		$vmSize   = $_.Name
		$vmFamily = $_.Family
		$vmTier   = $_.Tier

		# store VM sizes
		$script:vmFamilies[$vmSize] = $vmFamily

		# default SKU properties
		$vCPUs                           = 1
		$MemoryGB                        = 0
		$MaxDataDiskCount                = 9999
		$PremiumIO                       = $True
		$MaxWriteAcceleratorDisksAllowed = 0			# this property is not maintained in all SKUs
		$MaxNetworkInterfaces            = 9999
		$AcceleratedNetworkingEnabled    = $True
		$HyperVGenerations               = 'V1,V2'		# 'V1, 'V2', 'V1,V2'
		$CpuArchitectureType             = 'x64'		# 'x64', 'Arm64'


		# get SKU properties
		foreach($cap in $_.Capabilities) {
			switch ($cap.Name) {
				'vCPUs'                             {$vCPUs                           = $cap.Value -as [int]; break}
				'MaxDataDiskCount'                  {$MaxDataDiskCount                = $cap.Value -as [int]; break}
				'MemoryGB'                          {$MemoryGB                        = $cap.Value -as [int]; break}
				'PremiumIO'                         {$PremiumIO                       = $cap.Value; break}
				'MaxWriteAcceleratorDisksAllowed'   {$MaxWriteAcceleratorDisksAllowed = $cap.Value -as [int]; break}
				'MaxNetworkInterfaces'              {$MaxNetworkInterfaces            = $cap.Value -as [int]; break}
				'AcceleratedNetworkingEnabled'      {$AcceleratedNetworkingEnabled    = $cap.Value; break}
				'HyperVGenerations'                 {$HyperVGenerations               = $cap.Value; break}
				'CpuArchitectureType'               {$CpuArchitectureType             = $cap.Value; break}
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
			HyperVGenerations               = $HyperVGenerations
			CpuArchitectureType             = $CpuArchitectureType
		}
	}

	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function compare-quota {
#--------------------------------------------------------------
# check quotas in target region for each VM Family
	if ($skipVmChecks) { return }

	$savedSub = $script:currentSub
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	# get quotas
	$script:cpuUsage = Get-AzVMUsage -Location $targetLocation
	test-azResult 'Get-AzVMUsage'  "Could not get quotas for region '$targetLocation'" `
					"You can skip this step using RGCOPY parameter switch 'skipVmChecks'"

	# sum required CPUs per family
	$requiredCPUs = @{}

	$script:copyVMs.values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$vmFamily = $script:vmFamilies[$_.vmSize]
		if ($updateMode -and ($_.vmSizeOld -eq $_.vmSize)) {
			$vmFamily = $Null
		}

		if ($Null -ne $vmFamily) {

			$vCPUs = $script:vmSkus[$_.vmSize].vCPUs -as [int]
			if ($Null -eq $requiredCPUs[$vmFamily]) {
				$requiredCPUs[$vmFamily] = @{
					vmFamily	= $vmFamily
					neededCPUs	= $vCPUs
					usedCPUs	= -1
					limitCPUs	= -1
					usage		= 101
				}
			}
			else {
				$requiredCPUs[$vmFamily].neededCPUs += $vCPUs
			}
		}
	}

	# get quotas
	$requiredCPUs.Values
	| ForEach-Object {

		$vmFamily = $_.vmFamily
		$quota = $script:cpuUsage | Where-Object {($_.Unit -eq 'Count') -and ($_.Name.Value -eq $vmFamily)}
		if ($Null -ne $quota) {
			$_.usedCPUs		= $quota.CurrentValue -as [int]
			$_.limitCPUs	= $quota.Limit -as [int]
			if ($_.limitCPUs -eq 0) {
				$_.usage = 101
			}
			else {
				[int] $_.usage = ($_.usedCPUs + $_.neededCPUs) * 100 / $_.limitCPUs
			}
		}
	}

	# output of quota
	$requiredCPUs.Values
	| Sort-Object vmFamily
	| Select-Object `
		@{label="VM family";  expression={$_.vmFamily}}, `
		@{label="CPUs used";  expression={ 
			if ($_.usedCPUs -ne -1) {
				$_.usedCPUs
			}
			else{
				''
			}
		}}, `
		@{label="CPUs quota"; expression={
			if ($_.limitCPUs -ne -1) {
				$_.limitCPUs
			}
			else {
				''
			}
		}}, `
		@{label="required for deployment";  expression={$_.neededCPUs}}, `
		@{label="usage after deployment";   expression={"$($_.usage)%"}}
	| Format-Table
	| write-LogFilePipe

	# check quota
	$requiredCPUs.Values
	| ForEach-Object {

		$vmFamily = $_.vmFamily
		if ($_.limitCPUs -eq -1) {
			write-logFileError "VM Consistency check failed" `
								"No quota available for VM family '$vmFamily' in region '$targetLocation'" `
								"You can skip this check using RGCOPY parameter switch 'skipVmChecks'"
		}
		if ($_.usage -gt 100) {
			if ($skipDeployment -and !$updateMode) {
				write-logFileWarning "Quota exceeded for VM family '$vmFamily' in region '$targetLocation'"
			}
			else {
				write-logFileError "VM Consistency check failed" `
									"Quota exceeded for VM family '$vmFamily' in region '$targetLocation'" `
									"You can skip this check using RGCOPY parameter switch 'skipVmChecks'"
			}
		}
		elseif ($_.usage -gt 90) {
			write-logFileWarning "CPU usage over 90% for VM family '$vmFamily' in region '$targetLocation'"
			}
	}

	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function assert-vmsStopped {
#--------------------------------------------------------------
	if ($stopVMsSourceRG) { return }

	# check for running VM with more than one data disk or volume
	if ( !$allowRunningVMs `
	-and !$skipSnapshots `
	-and ($pathPreSnapshotScript.length -eq 0) `
	-and $script:VMsRunning ) {
		write-logFileError "Trying to copy non-deallocated VM with more than one data disk or volume" `
							"Asynchronous snapshots could result in data corruption in the target VM" `
							"Stop these VMs manually or use RGCOPY switch 'stopVMsSourceRG' for stopping ALL VMs"
	}

	# check for running VM while parameter useBlobsFromDisk is set
	$script:copyVMs.Values
	| ForEach-Object {

		if ($useBlobsFromDisk -and !$allowRunningVMs -and ($_.VmStatus -ne 'VM deallocated')) {
			write-logFileError "VM '$($_.Name)' is not deallocated" `
								"VMs must be deallocated if parameter 'useBlobsFromDisk' is set" `
								"Stop VMs manually or use RGCOPY switch 'stopVMsSourceRG' for stopping ALL VMs"
		}
	}

	# check for running VM with WA
	$script:copyVMs.Values
	| ForEach-Object {

		if ( (!$allowRunningVMs -and !$skipSnapshots) `
		-and ($pathPreSnapshotScript -eq 0) `
		-and ($_.VmStatus -ne 'VM deallocated') `
		-and ($_.hasWA -eq $True)) {

			write-logFileError "Trying to copy non-deallocated VM with Write Accelerator enabled" `
								"snapshots might be incomplete and could result in data corruption in the target VM" `
								"Stop these VMs manually or use RGCOPY switch 'stopVMsSourceRG' for stopping ALL VMs"
		}
	}
}

#--------------------------------------------------------------
function show-snapshots {
#--------------------------------------------------------------
	write-stepStart "Display RGCOPY-snapshots in resource group '$sourceRG'"

	$snapshots = Get-AzSnapshot -ResourceGroupName $sourceRG
	test-azResult 'Get-AzSnapshot'  "Could not get snapshots of resource group $sourceRG"

	$snapshots
	| Where-Object Name -like '*.rgcopy'
	| Sort-Object TimeCreated
	| Select-Object `
		@{label="TimeCreated"; expression={
			'{0:yyyy-MM-dd HH:mm:ss \U\T\Cz}' -f ($_.TimeCreated).ToLocalTime()
		}}, `
		DiskSizeGB, `
		Name
	| Format-Table
	| write-LogFilePipe

	write-stepEnd
}

#--------------------------------------------------------------
function show-sourceVMs {
#--------------------------------------------------------------
	$script:copyVMs.Values
	| Sort-Object Name
	| Select-Object `
		@{label="VM name";     expression={$_.Name}}, `
		@{label="VM size";     expression={$_.VmSize}}, `
		@{label="DataDisks";   expression={$_.DataDisks.count}}, `
		@{label="MountPoints"; expression={$_.MountPoints.count}}, `
		@{label="NICs";        expression={$_.NicCount}}, `
		@{label="Status";      expression={$_.VmStatus}}
	| Format-Table
	| write-LogFilePipe

	$script:copyDisks.Values
	| Sort-Object Name
	| Select-Object `
		@{label="Disk Name"; expression={
			if ($_.Name.length -gt 30) {
				$_.Name.Substring(0,30) + '..'
			}
			else {
				$_.Name
			}
		}}, `
		@{label="VM Name"; expression={
			$VM = $_.ManagedBy -as [string]
			if ($_.ManagedBy.count -gt 1) {
				$VM = '{' + $VM + '}'
			}
			if ($VM.length -eq 0) {
				'-'
			}
			elseif ($VM.length -gt 20) {
				$VM.Substring(0,20) + '..'
			}
			else {
				$VM
			}
		}}, `
		@{label="Cache/WriteAccel"; expression={
			if ($_.VM.length -eq 0) {
				' ' * 16
			}
			elseif ($_.writeAcceleratorEnabled -eq $True) {
				(([string]($_.Caching)).Replace('None','-') + ' / True').PadLeft(16)
			}
			else {
				(([string]($_.Caching)).Replace('None','-') + ' / -').PadLeft(16)
			}
		}}, `
		SizeGB, `
		@{label="Size"; expression={
			$_.SizeTierName
		}}, `
		@{label="Tier"; expression={
			if (($_.performanceTierName.length -eq 0) -or ($_.performanceTierName -eq $_.SizeTierName)) {
				'-'
			} 
			else {
				$_.performanceTierName
			}
		}}, `
		@{label="Burst"; expression={
			if ($_.BurstingEnabled -ne $True) {
				'-'
			} 
			else {
				'True'
			}
		}}, `
		@{label="ZRS"; expression={
			if ($_.SkuName -like '*ZRS') {
				'ZRS'
			} 
			else {
				'-'
			}
		}}, `
		@{label="Shares"; expression={
			([string]($_.MaxShares)).Replace('1','-')
		}}, `
		@{label="Skip"; expression={
			([string]($_.Skip)).Replace('False','-')
		}}
	| Format-Table
	| write-LogFilePipe
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
			if ($_.Rename.length -eq 0) {
				$_.Name
			}
			else {
				"$($_.Rename) ($($_.Name))"
			}
		}}, `
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
				if ($_.Name.length -gt 30) {
					$_.Name.Substring(0,30) + '..'
				}
				else {
					$_.Name
				}
			}
			else {
				if ($_.Rename.length -gt 30) {
					$_.Rename.Substring(0,30) + '..'
				}
				else {
					$_.Rename
				}
			}
		}}, `
		@{label="VM Name"; expression={
			$VM = $_.ManagedBy -as [string]
			if ($_.ManagedBy.count -gt 1) {
				$VM = '{' + $VM + '}'
			}
			if ($VM.length -eq 0) {
				'-'
			}
			elseif ($VM.length -gt 20) {
				$VM.Substring(0,20) + '..'
			}
			else {
				$VM
			}
		}}, `
		@{label="Cache/WriteAccel"; expression={
			if ($_.VM.length -eq 0) {
				' ' * 16
			}
			elseif ($_.writeAcceleratorEnabled -eq $True) {
				(([string]($_.Caching)).Replace('None','-') + ' / True').PadLeft(16)
			}
			else {
				(([string]($_.Caching)).Replace('None','-') + ' / -').PadLeft(16)
			}
		}}, `
		SizeGB, `
		@{label="Size"; expression={
			$_.SizeTierName
		}}, `
		@{label="PerfTier"; expression={
			if (($_.performanceTierName.length -eq 0) -or ($_.performanceTierName -eq $_.SizeTierName)) {
				'-'
			} 
			else {
				$_.performanceTierName
			}
		}}, `
		@{label="Burst"; expression={
			if ($_.BurstingEnabled -ne $True) {
				'-'
			} 
			else {
				'True'
			}
		}}, `
		@{label="ZRS"; expression={
			if ($_.SkuName -like '*ZRS') {
				'ZRS'
			} 
			else {
				'-'
			}
		}}, `
		@{label="Shares"; expression={
			([string]($_.MaxShares)).Replace('1','-')
		}}
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
									"VNET '$vnet' of NIC '$nicName' is in subscription '$subID'"
			}

			# return $vnetId only for remote RGs
			if ($rgName -ne $sourceRG) {
				write-logFileWarning "VNET '$vnet' of NIC '$nicName' is in resource group '$rgName'"

				$vnetId = get-resourceString `
							$subID				$rgName `
							'Microsoft.Network' `
							'virtualNetworks'	$vnet
			}

			# always return $vnetRG, $vnetName
			$vnetRG = $rgName
			$vnetName = $vnet
		}
	}

	return $vnetRG, $vnetName, $vnetId
}

#--------------------------------------------------------------
function update-NICsFromVM {
#--------------------------------------------------------------
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
				write-logFileWarning "NIC '$nicName' of VM '$vmName' is in resource group '$nicRG'"

				# get NIC from different resource group
				$remoteNIC = Get-AzNetworkInterface `
								-Name $nicName `
								-ResourceGroupName $nicRG `
								-ErrorAction 'SilentlyContinue'
				test-azResult 'Get-AzNetworkInterface'  "Could not get NIC '$nicName' of resource group '$nicRG'"

				# add NIC to $script:sourceNICs
				$script:sourceNICs += $remoteNIC

				$acceleratedNW = $remoteNIC.EnableAcceleratedNetworking
				if ($Null -eq $acceleratedNW) {
					$acceleratedNW = $False 
				}

				$nicNameNew = get-newRemoteName 'networkInterfaces' $nicRG $nicName

				$vnetRG, $vnetName, $vnetId = get-remoteSubnets $nicName $remoteNIC.IpConfigurations
				$vnetNameNew = get-newRemoteName 'virtualNetworks' $vnetRG $vnetName

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
				}
			}
		}
	}

	# update-VMsFromNIC
	foreach ($nic in $script:copyNICs.Values) {
		$vmName = $nic.VmName
		if (($Null -ne $vmName) -and ($nic.EnableAcceleratedNetworking -eq $True)) {
			$script:copyVMs[$vmName].NicCountAccNw++
		}
	}
}

#--------------------------------------------------------------
function update-disksFromVM {
#--------------------------------------------------------------
	$script:copyVMs.Values
	| ForEach-Object {

		$vmName = $_.Name

		# update OS disk
		$diskName = $_.OsDisk.Name
		if ($Null -ne $script:copyDisks[$diskName]) {

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
			if ($Null -ne $script:copyDisks[$diskName]) {

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
function save-VMs {
#--------------------------------------------------------------
	$script:copyDisks = @{}
	foreach ($disk in $script:sourceDisks) {

		# get SKU
		$sku = $disk.Sku.Name
		if ($sku -notin @('Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS', 'UltraSSD_LRS', 'Premium_ZRS', 'StandardSSD_ZRS')) {
			write-logFileError "Invalid disk SKU '$sku'"
		}

		# get bursting
		$burstingEnabled = $disk.BurstingEnabled
		if ($Null -eq $burstingEnabled) {
			$burstingEnabled = $False
		}

		# calculate Tier
		$SizeGB					= $disk.DiskSizeGB
		$SizeTierName			= get-diskTier $SizeGB $sku
		$SizeTierGB				= get-diskSize $SizeTierName
		$performanceTierName	= $disk.Tier
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

		# save source disk
		$script:copyDisks[$disk.Name] = @{
			Name        			= $disk.Name
			Rename					= ''
			VM						= '' 		# will be updated below by VM info
			ManagedBy				= $ManagedBy
			MaxShares				= $maxShares
			Skip					= $False 	# will be updated below by VM info
			image					= $False 	# will be updated below by VM info
			Caching					= 'None'	# will be updated below by VM info
			WriteAcceleratorEnabled	= $False 	# will be updated below by VM info
			AbsoluteUri 			= ''		# access token for copy to BLOB
			SkuName     			= $sku
			VmRestrictions			= $False	# will be updated later
			DiskIOPSReadWrite		= $disk.DiskIOPSReadWrite #e.g. 1024
			DiskMBpsReadWrite		= $disk.DiskMBpsReadWrite #e.g. 4
			BurstingEnabled			= $burstingEnabled
			SizeGB      			= $SizeGB					#e.g. 127
			SizeTierName			= $SizeTierName				#e.g. P10
			SizeTierGB				= $SizeTierGB				#e.g. 128	# maximum disk size for current tier
			performanceTierName		= $performanceTierName		#e.g. P15	# configured performance tier
			performanceTierGB		= $performanceTierGB		#e.g. 256	# size of configured performance tier
			OsType      			= $disk.OsType
			HyperVGeneration		= $disk.HyperVGeneration
			Id          			= $disk.Id
			Location    			= $disk.Location # source location needed to check: are all disks in same region?
			Tags					= $disk.Tags
		}
	}

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
				Caching 				= $disk.Caching					# Disks will be updated later using this info
				WriteAcceleratorEnabled = $disk.WriteAcceleratorEnabled # Disks will be updated later using this info
				Lun						= $disk.Lun
			}
			if ($disk.WriteAcceleratorEnabled -eq $True) { $hasWA = $True }
		}

		# get OS disk
		$disk = $vm.StorageProfile.OsDisk
		$OsDisk = @{
			Name 						= $disk.Name
			Caching						= $disk.Caching					# Disks will be updated later using this info
			WriteAcceleratorEnabled		= $disk.WriteAcceleratorEnabled # Disks will be updated later using this info
			OsType						= '' # will be updated later using disk info
			HyperVGeneration			= '' # will be updated later using disk info
		}
		if ($disk.WriteAcceleratorEnabled -eq $True) { $hasWA = $True }

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
			VmSize					= $vm.HardwareProfile.VmSize
			VmZone					= $vmZone # -in @(0,1,2,3)
			OsDisk					= $OsDisk
			DataDisks				= $DataDisks
			NewDataDiskCount		= $DataDisks.count
			NicCount				= $vm.NetworkProfile.NetworkInterfaces.count
			NicCountAccNw			= 0 # will be updated later
			VmPriority				= 2147483647 # default: highest INT number = lowest priority
			VmStatus				= $vm.PowerState
			MergeNetSubnet			= $Null
			hasWA					= $hasWA
			Tags 					= $vm.Tags
			MountPoints				= @()
			VmssName				= $Null
			AvsetName 				= $Null
			Ppgname					= $Null
			PlatformFaultDomain 	= $platformFaultDomain
		}
	}

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

		$vnetRG, $vnetName, $vnetId = get-remoteSubnets $nicName $nic.IpConfigurations
		$vnetNameNew = get-newRemoteName 'virtualNetworks' $vnetRG $vnetName

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
	if ($Null -ne $script:targetVMs) { return }

	$script:targetVMs = convertTo-array ( Get-AzVM `
											-ResourceGroupName $targetRG `
											-status `
											-ErrorAction 'SilentlyContinue' ) -saveError
	test-azResult 'Get-AzVM'  "Could not get VMs of resource group $targetRG"
	get-allFromTags $script:targetVMs $targetRG
}

#--------------------------------------------------------------
function get-sourceVMs {
#--------------------------------------------------------------
	write-stepStart "Current VMs/disks in Source Resource Group $sourceRG"

	# Get source vms
	$script:sourceVMs = convertTo-array ( Get-AzVM `
											-ResourceGroupName $sourceRG `
											-status `
											-ErrorAction 'SilentlyContinue' ) -saveError
	test-azResult 'Get-AzVM'  "Could not get VMs of resource group $sourceRG"

	# Get source disks
	$script:sourceDisks = convertTo-array ( Get-AzDisk `
											-ResourceGroupName $sourceRG `
											-ErrorAction 'SilentlyContinue' ) -saveError
	test-azResult 'Get-AzDisk'  "Could not get disks of resource group $sourceRG"

	# Get source NICs
	$script:collectedSubnets = @{}
	$script:remoteRGs = @()
	$script:sourceNICs = convertTo-array ( Get-AzNetworkInterface `
											-ResourceGroupName $sourceRG `
											-ErrorAction 'SilentlyContinue' ) -saveError
	test-azResult 'Get-AzNetworkInterface'  "Could not get NICs of resource group $sourceRG"

	# Get source VNETs
	$script:sourceVNETs = convertTo-array ( Get-AzVirtualNetwork `
											-ResourceGroupName $sourceRG `
											-ErrorAction 'SilentlyContinue' ) -saveError
	test-azResult 'Get-AzVirtualNetwork'  "Could not get VNETs of resource group $sourceRG"

	# get bastion
	$script:sourceBastion = Get-AzBastion `
								-ResourceGroupName	$sourceRG `
								-ErrorAction		'SilentlyContinue'
	test-azResult 'Get-AzBastion'  "Could not get Bastion of resource group '$sourceRG'"

	save-VMs
	update-NICsFromVM

	update-paramSetVmMerge
	update-paramSkipVMs
	update-paramGeneralizedVMs
	update-disksFromVM

	$script:installExtensionsSapMonitor   = convertTo-array ( `
		test-vmParameter 'installExtensionsSapMonitor'   $script:installExtensionsSapMonitor)

	$script:installExtensionsAzureMonitor = convertTo-array ( `
		test-vmParameter 'installExtensionsAzureMonitor' $script:installExtensionsAzureMonitor)

	update-paramSnapshotVolumes
	update-paramCreateVolumes
	update-paramCreateDisks
	update-paramSetVmDeploymentOrder
	update-paramSetVmTipGroup
	update-paramSetVmName
	
	save-skuProperties

	update-paramSkipDisks
	show-sourceVMs
	get-allFromTags $script:sourceVMs $sourceRG

	write-stepEnd
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
			}
		}
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

		if ($vmNameNew.length -le 1) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Invalid VM name '$vmNameNew'" `
								"VM name with length 1 is not supported by RGCOPY"
		}

		$match = '^[a-zA-Z0-9][a-zA-Z0-9\-]{0,62}[a-zA-Z0-9]$'
		test-match 'setVmName' $vmNameNew $match
		$script:copyVMs[$vmNameOld].Rename = $vmNameNew

		get-ParameterRule
	}
}

#--------------------------------------------------------------
function update-paramSetVmMerge {
#--------------------------------------------------------------
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
}

#--------------------------------------------------------------
function update-paramGeneralizedVMs {
#--------------------------------------------------------------
	# check VM parameters
	[array] $script:generalizedVMs = test-vmParameter 'generalizedVMs' $script:generalizedVMs

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
	if ($useBlobs -and ($generalizedVMs.Count -ne 0)) {
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
	# check for invalid VM names in parameter
	test-vmParameter 'skipVMs' $script:skipVMs | Out-Null

	# skipped VMs have already be marked when creating $script:copyVMs
	$script:skipVMs = @()
	$script:VMsRunning = $False

	$script:copyVMs.Values
	| ForEach-Object {

		# skip all other VMs if some VMs are merged
		if (($setVmMerge.count -ne 0) -and ($_.MergeNetSubnet.length -eq 0)) {
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
	if ($updateMode) { return }

	# skip disks when parameter is set
	foreach ($diskName in $skipDisks) {
		if ($Null -eq $script:copyDisks[$diskName]) {
			write-logFileError "Invalid parameter 'skipDisks'" `
								"Disk '$diskName' not found"
		}
		if ($Null -ne $script:copyDisks[$diskName].OsType) {
			write-logFileError "Invalid parameter 'skipDisks'" `
								"Disk '$diskName' is an OS disk"
		}
		$script:copyDisks[$diskName].Skip = $True

		# update number of data disks
		$vmName = $script:copyDisks[$diskName].VM
		if ($Null -ne $vmName) {
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
		$script:copyDisks.values
		| ForEach-Object {

			if ($_.VM.length -eq 0) {
				$_.Skip = $True
			}
		}
	}

	# non-skipped disks must not be UltraSSD_LRS
	# you cannot export or snapshot Ultra SSD disks
	# however, you can convert them to NetApp volumes or Premium_LRS
	$script:copyDisks.values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		if ($_.SkuName -eq 'UltraSSD_LRS') {
			write-logFileError "Disk '$($_.Name)' is an Ultra SSD disk" `
								"Ultra SSD disks cannot be copied" `
								"Use parameter 'skipDisks' for skipping disk '$($_.Name)'"
		}
	}

	# skip disks when justCopyBlobs is set (when BLOB copy originally failed only for a few VMs)
	if ($justCopyBlobs.count -ne 0) {

		# skip all disks
		$script:copyDisks.Values
		| ForEach-Object {

			$_.Skip = $True
		}

		# unskip configured disks
		foreach ($diskName in $justCopyBlobs) {
			if ($Null -eq $script:copyDisks[$diskName]) {
				write-logFileError "Invalid parameter 'justCopyBlobs'" `
									"Disk '$diskName' not found"
			}
			$script:copyDisks[$diskName].Skip = $False
		}
	}
}

#--------------------------------------------------------------
function test-vmParameter {
#--------------------------------------------------------------
	param (
		$paramName,
		$paramValue
	)

	# check data type
	if ($paramValue -is [string]) {
		$paramValue = @($paramValue)
	}
	if ($paramValue -isnot [array]) {
		write-logFileError "Invalid parameter '$paramName'" `
							"Invalid data type"
	}
	foreach ($item in $paramValue) {
		if ($item -isnot [string]) {
			write-logFileError "Invalid parameter '$paramName'" `
								"Invalid data type"
		}
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

	# check if VM exists
	foreach ($vmName in $paramValue) {
		if ($vmName -notin $allowedVMs) {
			write-logFileError "Invalid parameter '$paramName'" `
								"Vm '$vmName' not found or skipped"
		}
	}
	return $paramValue
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
	}

	# output of ALL issues
	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$vmName = $_.Name
		$vmSize = $_.VmSize
		
		if ($skipVmChecks) {
			save-skuDefaultValue $vmSize
		}
		else {
			# check VM family
			if ($Null -eq $script:vmSkus[$vmSize]) {
				write-logFileWarning "Size '$vmSize' of VM '$vmName' is not available in region '$targetLocation'" 
			}
			else {
				# check data disk count
				$diskCount = $_.NewDataDiskCount
				$diskCountMax = $script:vmSkus[$vmSize].MaxDataDiskCount
				if ($diskCount -gt $diskCountMax) {
					write-logFileWarning "Size '$vmSize' of VM '$vmName' only supports $diskCountMax data disk(s)"
				}
	
				# check NIC count
				$nicCount = $_.NicCount
				$nicCountMax = $script:vmSkus[$vmSize].MaxNetworkInterfaces
				if ($nicCount -gt $nicCountMax) {
					write-logFileWarning "Size '$vmSize' of VM '$vmName' only supports $nicCountMax network interface(s)"
				}
			}
		}
	}

	# output of changes
	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$vmName = $_.Name
		$vmSize = $_.VmSize

		# check VM family
		if ($Null -eq $script:vmSkus[$vmSize]) {
			write-logFileError "VM consistency check failed" `
								"Size '$vmSize' of VM '$vmName' is not available in region '$targetLocation'" `
								"You can skip this check using RGCOPY parameter switch 'skipVmChecks'"
		}

		# check data disk count
		$diskCount = $_.NewDataDiskCount
		$diskCountMax = $script:vmSkus[$vmSize].MaxDataDiskCount
		if ($diskCount -gt $diskCountMax) {
			write-logFileError "VM consistency check failed" `
								"Size '$vmSize' of VM '$vmName' only supports $diskCountMax data disk(s)" `
								"You can skip this check using RGCOPY parameter switch 'skipVmChecks'"
		}

		# check NIC count
		$nicCount = $_.NicCount
		$nicCountMax = $script:vmSkus[$vmSize].MaxNetworkInterfaces
		if ($nicCount -gt $nicCountMax) {
			write-logFileError "VM consistency check failed" `
								"Size '$vmSize' of VM '$vmName' only supports $nicCountMax network interface(s)" `
								"You can skip this check using RGCOPY parameter switch 'skipVmChecks'"
		}

		# check HyperVGeneration
		$hvGen = $_.OsDisk.HyperVGeneration
		if ($hvGen.length -eq 0) { 
			$hvGen = 'V1'
		}
		$hvGenAllowed = $script:vmSkus[$vmSize].HyperVGenerations
		if ($hvGenAllowed -notlike "*$hvGen*") {
			write-logFileError "VM consistency check failed" `
								"HyperVGeneration '$hvGen' of VM '$vmName' not supported by VM size '$vmSize'" `
								"You can skip this check using RGCOPY parameter switch 'skipVmChecks'"
		}

		# check CpuArchitectureType: 'x64', 'Arm64'
		if (!$skipVmChecks) {
			$cpuTypeOld = $script:vmSkus[$_.VmSizeOld].CpuArchitectureType
			# old VM size might not be available in target region
			if ($Null -ne $cpuTypeOld) {
				$cpuTypeNew = $script:vmSkus[$_.VmSize].CpuArchitectureType
				if ($cpuTypeOld -ne $cpuTypeNew) {
					write-logFileError "Cannot change from CPU architecture '$cpuTypeOld' (VM size '$($_.VmSizeOld)')" `
										"to CPU architecture '$cpuTypeNew' (VM size '$vmSize')" `
										"You can skip this check using RGCOPY parameter switch 'skipVmChecks'"
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
		test-values 'setDiskSku' $sku @('Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS', 'Premium_ZRS', 'StandardSSD_ZRS') 'sku'

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			$_.SkuNameNew = $sku
		}
		get-ParameterRule
	}

	# output of changes
	$script:copyDisks.values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$diskName	= $_.Name
		$vmName		= $_.VM
		$current	= $_.SkuName
		$wanted		= $_.SkuNameNew

		# check for UltraSSD_LRS
		if (($current -eq 'UltraSSD_LRS') -and ($Null -ne $wanted)) {
			write-logFileWarning "Disk SKU 'UltraSSD_LRS' of disk '$diskName' cannot be changed'" -stopAtWarning
			$wanted = $current
		}

		if ($Null -eq $wanted) {
			$wanted = $current
		}

		# check if premiumIO is allowed
		if ($vmName.length -eq 0) {
			write-logFileWarning "Disk '$diskName' not attached to a VM"
			$vmSize				= $Null
			$allowedPremiumIO	= $True
		}
		else {
			foreach ($vmName in $_.ManagedBy) {
				$vmSize				= $script:copyVMs[$vmName].VmSize
				$allowedPremiumIO	= $script:vmSkus[$vmSize].PremiumIO
	
				if ($allowedPremiumIO -ne $True) {
					$_.VmRestrictions = $True # disks must be updated BEFORE updating VM size
					break
				}
			}
		}

		# do not allow changing shared disks to standard_LRS
		if (($_.ManagedBy.count -gt 1) -and ($wanted -eq 'Standard_LRS') -and ($current -ne 'Standard_LRS')) {
			write-logFileWarning "Cannot changed disk SKU to 'Standard_LRS' because disk is attached to 2+ VMs" -stopAtWarning
			$wanted = $current
		}

		# ZRS available in region?
		if (($Null -eq $script:diskSkuInRegion[$wanted]) -and !$skipVMChecks) {
			if ($wanted -eq 'Premium_ZRS') {
				write-logFileWarning "Disk SKU '$wanted' is not available in region '$targetLocation'" -stopAtWarning
				$wanted = 'Premium_LRS'
			}
			elseif ($wanted -eq 'StandardSSD_ZRS') {
				write-logFileWarning "Disk SKU '$wanted' is not available in region '$targetLocation'" -stopAtWarning
				$wanted = 'StandardSSD_LRS'
			}
			else {
				write-logFileError "Disk SKU '$wanted' is not available in region '$targetLocation'"
			}
		}

		# premium IO supported for VM?
		if (($allowedPremiumIO -eq $False) -and ($wanted -eq 'UltraSSD_LRS')) {
			write-logFileError "Size '$vmSize' of VM '$vmName' does not support Premium IO" `
								"However, disk '$diskName' has SKU 'UltraSSD_LRS'"
		}
		elseif (($allowedPremiumIO -eq $False) -and ($wanted -eq 'Premium_ZRS')) {
			write-logFileWarning "Size '$vmSize' of VM '$vmName' does not support Premium IO" -stopAtWarning
			$wanted = 'StandardSSD_ZRS'
		}
		elseif (($allowedPremiumIO -eq $False) -and ($wanted -eq 'Premium_LRS')) {
			write-logFileWarning "Size '$vmSize' of VM '$vmName' does not support Premium IO" -stopAtWarning
			$wanted = 'StandardSSD_LRS'
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

	update-paramSetDiskTier
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
			$maxWanted = 5
		}
		else {
			$maxWanted = 1
		}
		if ($wanted -gt $maxWanted) {
			write-logFileWarning "Disk size '$sizeTierName' only supports up to $maxWanted shares" -stopAtWarning
			$wanted = $maxWanted
		}

		# check if it is a DATA disk
		if (($_.OsType.length -ne 0) -and ($wanted -gt 1)) {
			write-logFileWarning "Shared disks are only supported for data disks" -stopAtWarning
			$wanted = 1
			$maxWanted = 1
		}

		# check disk SKU
		if (($_.SkuName -notlike 'Premium_?RS') -and ($_.SkuName -notlike '*SSD*') -and ($wanted -gt 1)) {
			write-logFileWarning "Shared disks are not supported for SKU '$($_.SkuName)'" -stopAtWarning
			$wanted = 1
			$maxWanted = 1
		}

		# check if disk is detached
		if (($_.ManagedBy.count -ne 0) -and $updateMode -and ($wanted -ne $current)) {
			if ($current -le $maxWanted) {
				write-logFileWarning "Cannot change Disk Max Shares for an attached disk" -stopAtWarning
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
			write-logFileWarning "Bursting is not supported for shared disks" -stopAtWarning
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
		$burstingConfig = $script:paramConfig -as [boolean]

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
		if (($_.SkuName -notlike 'Premium_?RS') -and ($wanted -eq $True)) {
			write-logFileWarning "Disk '$($_.Name)': Bursting is not supported for SKU '$($_.SkuName)'" -stopAtWarning
			$wanted = $False
		}

		# check for minimum size
		if (($_.SizeGB -le 512) -and ($wanted -eq $True)) {
			write-logFileWarning "Disk '$($_.Name)': Bursting is only supported for disks larger than 512 GiB'" -stopAtWarning
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
			$waEnabledConfig = $waEnabledConfig -as [boolean]
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
		if (($_.SkuName -eq 'UltraSSD_LRS') -and ($wanted -ne 'None')) {
			write-logFileWarning "Caching '$wanted' not supported for disk SKU '$($_.SkuName)'" -stopAtWarning
			$wanted = 'None'
		}

		# ReadOnly caching not allowed for shared disks
		if (($_.MaxShares -gt 1) -and ($wanted -eq 'ReadOnly')) {
			write-logFileWarning "Caching '$wanted' not supported for shared disks" -stopAtWarning
			$wanted = 'None'
		}

		# WA only supported for premium disks
		if (($wantedWA -eq $True) -and ($_.SkuName -notin @('Premium_LRS', 'Premium_ZRS', 'UltraSSD_LRS'))) {
			write-logFileWarning "Write accelerator not supported for disk SKU '$($_.SkuName)'" -stopAtWarning
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
					write-logFileWarning "Size '$vmSize' of VM '$vmName' only supports $waMax write-acceleratored disk(s)" -stopAtWarning
				}
				else {
					write-logFileWarning "Size '$vmSize' of VM '$vmName' does not support Write Accelerator" -stopAtWarning
				}
				$wantedWA = $False
			}
		}

		# correct disk caching for WA
		if (($wantedWA -eq $True) -and ($wanted -eq 'ReadWrite')) {
			write-logFileWarning "Caching '$wanted' not supported when write accelerator is enabled" -stopAtWarning
			$wanted = 'ReadOnly'
		}
		
		# shared disks: disable chaching because current RGCOPY data structures do not support this
		if ($_.ManagedBy.count -gt 1) {
			if ($wanted -ne 'None') {
				$wanted = 'None'
				write-logFileWarning "RCOPY does not support caching of disks that are attached to more than one VM" -stopAtWarning
			}
			if ($wantedWA -ne $False) {
				$wantedWA = $False
				write-logFileWarning "RCOPY does not support write accelerator of disks that are attached to more than one VM" -stopAtWarning
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
		$acceleratedNW = $script:paramConfig -as [boolean]

		$script:copyNICs.values
		| Where-Object {$_.NicNameNew -in $script:paramNICs}
		| ForEach-Object {

			$_.EnableAcceleratedNetworkingNew = $acceleratedNW
		}
		get-ParameterRule
	}

	# save maximum number of acc NICs per VM
	$script:copyVMs.Values
	| Where-Object Skip -ne $True
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
			write-logFileWarning "NIC '$nicName' not attached to a VM"
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
						write-logFileWarning "Size '$vmSize' of VM '$vmName' only supports $accNwMax NICs with Accelerated Networking" -stopAtWarning
					}
					else {
						write-logFileWarning "Size '$vmSize' of VM '$vmName' does not support Accelerated Networking" -stopAtWarning
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
	if ($script:snapshotList.count -eq 0) { return }
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
	$scriptParameter =  "`$snapshotExtension = '$snapshotExtension';"
	$scriptParameter += "`$sourceRG = '$sourceRG';"

	# parallel running script
	$script = {

		$SnapshotName = "$($_.Name).$($snapshotExtension)"
		Write-Output "... creating $SnapshotName"

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
		if ($_.OsType.count -ne 0) { $parameter.Add('OsType', $_.OsType) }

		$conf = New-AzSnapshotConfig @parameter
		if (!$?) {throw "Creation of snapshot $SnapshotName failed"}

		# create snapshot
		New-AzSnapshot `
			-Snapshot           $conf `
			-SnapshotName       $SnapshotName `
			-ResourceGroupName  $sourceRG `
			-WarningAction 'SilentlyContinue' `
			-ErrorAction 'Stop' | Out-Null
		if (!$?) {throw "Creation of snapshot $SnapshotName failed"}

		Write-Output "$SnapshotName created"
	}

	# start execution
	write-stepStart "CREATE SNAPSHOTS" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Creation of snapshots failed"
	}
	else {
		# calculate total size of created snapshots
		$script:totalSnapshotSize = 0
		$script:copyDisks.Values
		| Where-Object Skip -ne $True
		| ForEach-Object {
			$script:totalSnapshotSize += $_.SizeTierGB
		}
	}
	write-stepEnd
}

#--------------------------------------------------------------
function remove-snapshots {
#--------------------------------------------------------------
	param (
		$snapshots
	)

	# using parameters for parallel execution
	$scriptParameter = "`$sourceRG = '$sourceRG';"

	if ($snapshots.count -eq 0) {
		$scriptParameter +=  "`$snapshotExtension = '.$snapshotExtension';"
		$snapshots = $script:copyDisks.Values | Where-Object Skip -ne $True
	}

	# parallel running script
	$script = {
		$SnapshotName 	= "$($_.Name)$($snapshotExtension)"
		Write-Output "... removing $SnapshotName"
		try {
			Revoke-AzSnapshotAccess `
				-ResourceGroupName  $sourceRG `
				-SnapshotName       $SnapshotName `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop' | Out-Null
		}
		catch [Microsoft.Azure.Commands.Compute.Common.ComputeCloudException] { <# snapshot not found #> }

		Remove-AzSnapshot `
			-ResourceGroupName  $sourceRG `
			-SnapshotName      	$SnapshotName `
			-Force `
			-WarningAction 'SilentlyContinue' `
			-ErrorAction 'Stop' | Out-Null

		Write-Output "$SnapshotName removed"
	}

	# start execution
	write-stepStart "DELETE SNAPSHOTS" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	$snapshots
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Deletion of snapshot failed"
	}
	else {
		$script:totalSnapshotSize = 0
	}
	write-stepEnd
}

#--------------------------------------------------------------
function grant-access {
#--------------------------------------------------------------
	# get access token for snapshots
	if (!$useBlobsFromDisk) {

		# using parameters for parallel execution
		$scriptParameter =  "`$snapshotExtension = '$snapshotExtension';"
		$scriptParameter += "`$sourceRG = '$sourceRG';"
		$scriptParameter += "`$grantTokenTimeSec = $grantTokenTimeSec;"

		# parallel running script
		$script = {
			$SnapshotName = "$($_.Name).$($snapshotExtension)"
			Write-Output "... granting $SnapshotName"

			$sas = Grant-AzSnapshotAccess `
				-ResourceGroupName  $sourceRG `
				-SnapshotName       $SnapshotName `
				-Access             'Read' `
				-DurationInSecond   $grantTokenTimeSec `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop'
			if (!$?) {throw "Grant Access to snapshot $SnapshotName failed"}

			Write-Output "$SnapshotName granted"
			$_.AbsoluteUri = $sas.AccessSAS
		}

		# start execution
		write-stepStart "GRANT ACCESS TO SNAPSHOTS" $maxDOP
		$param = get-scriptBlockParam $scriptParameter $script $maxDOP
		$script:copyDisks.Values
		| Where-Object Skip -ne $True
		| ForEach-Object @param
		| Tee-Object -FilePath $logPath -append
		| Out-Host
		if (!$?) {
			write-logFileError "Grant Access to snapshot failed"
		}
		write-stepEnd
	}

	# get access token for disks
	else {

		# using parameters for parallel execution
		$scriptParameter =  "`$sourceRG = '$sourceRG';"
		$scriptParameter += "`$grantTokenTimeSec = $grantTokenTimeSec;"

		# parallel running script
		$script = {
			Write-Output "... granting $($_.Name)"

			$sas = Grant-AzDiskAccess `
				-ResourceGroupName  $sourceRG `
				-DiskName           $_.Name `
				-Access             'Read' `
				-DurationInSecond   $grantTokenTimeSec `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop'
			if (!$?) {throw "Grant Access to disk $($_.Name) failed"}

			Write-Output "$($_.Name) granted"
			$_.AbsoluteUri = $sas.AccessSAS
		}

		# start execution
		write-stepStart "GRANT ACCESS TO DISKS" $maxDOP
		$param = get-scriptBlockParam $scriptParameter $script $maxDOP
		$script:copyDisks.Values
		| Where-Object Skip -ne $True
		| ForEach-Object @param
		| Tee-Object -FilePath $logPath -append
		| Out-Host
		if (!$?) {
			write-logFileError "Grant Access to disk failed"
		}
		write-stepEnd
	}
}

#--------------------------------------------------------------
function revoke-access {
#--------------------------------------------------------------
	# using parameters for parallel execution
	$scriptParameter =  "`$sourceRG = '$sourceRG';"

	# parallel running script
	$script = {
		Write-Output "... revoking $($_.Name)"

		Revoke-AzDiskAccess `
			-ResourceGroupName  $sourceRG `
			-DiskName           $_.Name `
			-WarningAction 'SilentlyContinue' `
			-ErrorAction 'Stop' | Out-Null
		if (!$?) {throw "Revoke of disk access to $_.Name failed"}

		Write-Output "$($_.Name) revoked"
	}

	# start execution
	write-stepStart "REVOKE ACCESS FROM DISKS" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	try {
		$script:copyDisks.Values
		| Where-Object Skip -ne $True
		| ForEach-Object @param
		| Tee-Object -FilePath $logPath -append
		| Out-Host
		if (!$?) {
			write-logFileError "Revoke of disk access failed"
		}
	}
	catch {
		write-logFileError "Revoke-AzDiskAccess failed" `
							"If Azure credentials have expired then run Connect-AzAccount" `
							"and restart RGCOPY with ADDITIONAL parameter 'restartBlobs'" `
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

	$savedSub = $script:currentSub
	set-context $mySub # *** CHANGE SUBSCRIPTION **************

	# Get Storage Account KEY
	$mySaKey = (Get-AzStorageAccountKey `
						-ResourceGroupName	$myRG `
						-AccountName 		$mySA `
						-ErrorAction 'SilentlyContinue' | Where-Object KeyName -eq 'key1').Value
	test-azResult 'Get-AzStorageAccountKey'  "Could not get key for Storage Account '$mySA'"

	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
	return $mySaKey
}

#--------------------------------------------------------------
function start-copyBlobs {
#--------------------------------------------------------------
	$script:targetSaKey = get-saKey $targetSub $targetRG $targetSA

	# using parameters for parallel execution
	$scriptParameter =  "`$targetSaContainer = '$targetSaContainer';"
	$scriptParameter += "`$targetSA = '$targetSA';"
	$scriptParameter += "`$targetSaKey = '$($script:targetSaKey -replace '''', '''''')';"

	# parallel running script
	$script = {
		Write-Output "... starting BLOB copy $($_.Name).vhd"

		$destinationContext = New-AzStorageContext `
								-StorageAccountName   $targetSA `
								-StorageAccountKey    $targetSaKey `
								-ErrorAction 'SilentlyContinue'

		Start-AzStorageBlobCopy `
			-DestContainer    $targetSaContainer `
			-DestContext      $destinationContext `
			-DestBlob         "$($_.Name).vhd" `
			-AbsoluteUri      $_.AbsoluteUri `
			-Force `
			-WarningAction 'SilentlyContinue' `
			-ErrorAction 'Stop' | Out-Null
		# StandardBlobTier = 'Cool' cannot be set to PageBlob
		if (!$?) {throw "Creation of Storage Account BLOB $($_.Name).vhd failed"}

		Write-Output "$($_.Name).vhd"
	}

	# start execution
	write-stepStart "START COPY TO BLOB" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
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
	if ($Null -eq $script:targetSaKey) {
		$script:targetSaKey = get-saKey $targetSub $targetRG $targetSA
	}

	# using parameters for parallel execution
	$scriptParameter =  "`$targetSaContainer = '$targetSaContainer';"
	$scriptParameter += "`$targetSA = '$targetSA';"
	$scriptParameter += "`$targetSaKey = '$($script:targetSaKey -replace '''', '''''')';"

	# parallel running script
	$script = {
		Write-Output "... stopping BLOB copy $($_.Name).vhd"
		try {
			$destinationContext = New-AzStorageContext `
									-StorageAccountName   $targetSA `
									-StorageAccountKey    $targetSaKey `
									-ErrorAction 'SilentlyContinue'

			Stop-AzStorageBlobCopy `
				-Container    $targetSaContainer `
				-Context      $destinationContext `
				-Blob         "$($_.Name).vhd" `
				-Force `
				-WarningAction 'SilentlyContinue' `
				-ErrorAction 'Stop' | Out-Null
		}
		catch [Microsoft.Azure.Storage.StorageException] { <# There is currently no pending copy operation #> }

		Write-Output "$($_.Name).vhd"
	}

	# start execution
	write-stepStart "STOP COPY TO BLOB" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
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
	write-stepStart "CHECK BLOB COPY STATUS (every $waitBlobsTimeSec seconds)"

	if ($Null -eq $script:targetSaKey) {
		$script:targetSaKey = get-saKey $targetSub $targetRG $targetSA
	}

	$destinationContext = New-AzStorageContext `
		-StorageAccountName   $targetSA `
		-StorageAccountKey    $script:targetSaKey `
		-ErrorAction 'SilentlyContinue'
	test-azResult 'New-AzStorageContext'  "Could not get context for Storage Account '$targetSA'"

	# create tasks
	$runningBlobTasks = @()
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$runningBlobTasks += @{
			blob		= "$($_.Name).vhd"
			finished	= $False
			progress	= ''
		}
	}

	do {
		Write-logFile
		write-logFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz')
		$done = $True
		foreach ($task in $runningBlobTasks) {

			if ($task.finished) {
				Write-logFile $task.progress -ForegroundColor 'Green'
			}
			else {

				try {
					$state = Get-AzStorageBlob `
						-Blob       $task.blob `
						-Container  $targetSaContainer `
						-Context    $destinationContext `
						-ErrorAction 'Stop' `
					| Get-AzStorageBlobCopyState
				}
				catch {
					write-logFileError "Get-AzStorageBlob failed" `
										"If Azure credentials have expired then run Connect-AzAccount" `
										"and restart RGCOPY with ADDITIONAL parameter 'restartBlobs'" `
										-lastError
				}

				[int] $GB_copied = $state.BytesCopied / 1024 / 1024 / 1024
				[int] $GB_total  = $state.TotalBytes  / 1024 / 1024 / 1024
				[int] $percent   = $GB_copied * 100 / $GB_total
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

		if (!$done) { Start-Sleep -seconds $waitBlobsTimeSec }
	} while (!$done)
	if (!$archiveMode) {
		# calculate total size of copied BLOBs
		$script:totalBlobSize = 0
		$script:copyDisks.Values
		| Where-Object Skip -ne $True
		| ForEach-Object {
			$script:totalBlobSize += $_.SizeGB
		}
	}
	write-stepEnd
}

#--------------------------------------------------------------
function update-subnets {
#--------------------------------------------------------------
	# remove NICs in delegated subnets (NIC has to be created by delegation service)
	$collected = @()
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks/subnets'
	| ForEach-Object -Process {

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
				| ForEach-Object -Process {

					foreach ($d in $_.dependsOn) {
						if ($True -eq (compare-resources $d $dependsSubnet)) {
							$collected += $_.name
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
function update-networkPeerings {
#--------------------------------------------------------------
	# get remote virtualNetworkPeerings
	$remotePeerings = @()
	foreach ($res in $script:resourcesALL) {
		if ($res.type -eq 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings' ) {
			if ($res.properties.remoteVirtualNetwork.id[0] -eq '/') {
				$remotePeerings += $res.name
			}
		}
	}

	# remove virtualNetworkPeerings to other resource groups
	$i = 0
	foreach ($peer in $remotePeerings) {
		write-logFileUpdates 'virtualNetworkPeerings' $peer 'delete'
		$i++
	}
	if ($i -ne 0) {
		write-logFileWarning 'Peered Networks are supported by RGCOPY only within the same resource group'
	}
	remove-resources 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings' $remotePeerings

	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks'
	| Where-Object {$_.properties.virtualNetworkPeerings.count -ne 0}
	| ForEach-Object {

		$_.properties.virtualNetworkPeerings = convertTo-array ($_.properties.virtualNetworkPeerings `
																| Where-Object name -notin $remotePeerings)
	}

	# save names of remaining peered networks
	$script:peeredVnets = @()
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks'
	| Where-Object {$_.properties.virtualNetworkPeerings.count -ne 0}
	| ForEach-Object {

		$script:peeredVnets += $_.name
	}
}

#--------------------------------------------------------------
function update-NICs {
#--------------------------------------------------------------
	# process existing NICs
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
	| ForEach-Object -Process {

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
	set-parameter 'setLoadBalancerSku' $setLoadBalancerSku 'Microsoft.Network/loadBalancers'
	# process loadBalancers
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/loadBalancers'
	| ForEach-Object -Process {

		$value = $script:paramValues[$_.name]
		if ($Null -ne $value) {
			test-values 'setLoadBalancerSku' $value @('Basic', 'Standard') 'sku'

			$old = $Null
			if ($Null -ne $_.sku) {
				$old = $_.sku.name
			}

			if ($old -ne $value) {
				write-logFileUpdates 'loadBalancers' $_.name 'set SKU' $value
				$_.sku = @{ name = $value }
				$script:countLoadBalancerSku++
			}
			else {
				write-logFileUpdates 'loadBalancers' $_.name 'keep SKU' $value
			}
		}
	}

	set-parameter 'setPublicIpSku' $setPublicIpSku 'Microsoft.Network/publicIPAddresses'
	# process publicIPAddresses
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/publicIPAddresses'
	| ForEach-Object -Process {

		$value = $script:paramValues[$_.name]
		if ($Null -ne $value) {
			test-values 'setPublicIpSku' $value @('Basic', 'Standard') 'sku'

			$old = $Null
			if ($Null -ne $_.sku) {
				$old = $_.sku.name
			}

			if ($old -ne $value) {
				write-logFileUpdates 'publicIPAddresses' $_.name 'set SKU' $value
				$_.sku = @{ name = $value }
			}
			else {
				write-logFileUpdates 'publicIPAddresses' $_.name 'keep SKU' $value
			}
		}
	}

	# remove SKU from bastionHosts
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/bastionHosts'
	| ForEach-Object -Process {

		if ($_.sku.count -ne 0) {
			$_.sku = $Null
			write-logFileUpdates 'bastionHosts' $_.name 'delete Sku' '' '' '(SKU not supported in all regions)'
		}
	}
}

#--------------------------------------------------------------
function update-IpAllocationMethod {
#--------------------------------------------------------------
	set-parameter 'setPublicIpAlloc' $setPublicIpAlloc 'Microsoft.Network/publicIPAddresses'
	# process publicIPAddresses
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/publicIPAddresses'
	| ForEach-Object -Process {

		$value = $script:paramValues[$_.name]
		if ($Null -ne $value) {
			test-values 'setPublicIpAlloc' $value @('Dynamic', 'Static') 'allocation type'

			if ($_.properties.publicIPAllocationMethod -ne $value) {
				$_.properties.publicIPAllocationMethod = $value
				write-logFileUpdates 'publicIPAddresses' $_.name 'set Allocation Method' $value
			}
			else {
				write-logFileUpdates 'publicIPAddresses' $_.name 'keep Allocation Method' $value
			}
		}

		# remove IP Address VALUE (for Static AND Dynamic)
		if ($_.properties.ContainsKey('ipAddress')) {
			write-logFileUpdates 'publicIPAddresses' $_.name 'delete old ipAddress' '' '' $_.properties.ipAddress
			$_.properties.Remove('ipAddress')
		}
	}

	set-parameter 'setPrivateIpAlloc' $setPrivateIpAlloc 'Microsoft.Network/networkInterfaces'
	# process networkInterfaces
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
	| ForEach-Object -Process {

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

		# # remove IP for dynamic allocation method
		# for ($i = 0; $i -lt $_.properties.ipConfigurations.count; $i++) {
		# 	if ($_.properties.ipConfigurations[$i].properties.privateIPAllocationMethod -eq 'Dynamic') {
		# 		$_.properties.ipConfigurations[$i].properties.privateIPAddress = $Null
		# 	}
		# }
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
	| ForEach-Object -Process {

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
	| ForEach-Object -Process {

		$_.properties.securityRules = convertTo-array ($_.properties.securityRules `
														| Where-Object name -notin $deletedRules)
	}
}

#--------------------------------------------------------------
function update-dependenciesAS {
#--------------------------------------------------------------
# Circular dependency with availabilitySets:
#   Create resources in this order:
#   1. availabilitySets
#   2. virtualMachines

# process availabilitySets
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/availabilitySets'
	| ForEach-Object -Process {

		$_.properties.virtualMachines = $Null

		$_.dependsOn = remove-dependencies $_.dependsOn -keep 'Microsoft.Compute/proximityPlacementGroups'
	}
	
}

#--------------------------------------------------------------
function update-dependenciesVNET {
#--------------------------------------------------------------
	$subnetsAll = @()
	
	# workaround for following sporadic issue when deploying subnets:
	#  "code": "Another operation on this or dependent resource is in progress.""
	#  "message": "Cannot proceed with operation because resource <vnet> ... is not in Succeeded state."
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks'
	| ForEach-Object -Process {

		# remove virtualNetworkPeerings from VNET
		$_.properties.virtualNetworkPeerings = $Null

		# for virtualNetworkPeerings, there is a Circular dependency between VNETs
		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/virtualNetworks'

		# get subnets per vnet
		$vnet = $_.name
		$subnetsDependent = @()

		foreach ($s in $_.properties.subnets) {

			$subnet = $s.name

			# create dependency chain for subnets (do not deploy 2 subnets at the same time)
			$script:resourcesALL
			| Where-Object type -eq 'Microsoft.Network/virtualNetworks/subnets'
			| Where-Object name -eq "$vnet/$subnet"
			| ForEach-Object -Process {

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

	# workaround for following sporadic issue when deploying virtualNetworkPeerings:
	#  "code": "ReferencedResourceNotProvisioned"
	#  "message": "Cannot proceed with operation because resource <vnet> ... is not in Succeeded state."
	#  "Resource is in Updating state and the last operation that updated/is updating the resource is PutSubnetOperation."
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings'
	| ForEach-Object -Process {

		[array] $_.dependsOn += $subnetsAll
	}
}

#--------------------------------------------------------------
function update-dependenciesLB {
#--------------------------------------------------------------
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
	| ForEach-Object -Process {

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
	| ForEach-Object -Process {

		# save LB (deep copy)
		$LB = $_ | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20 -AsHashtable

		# modify dependencies
		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/loadBalancers/backendAddressPools'
		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/loadBalancers/inboundNatRules'
		$dependsVMs = @()

		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
		| ForEach-Object -Process {

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
function update-reDeployment {
#--------------------------------------------------------------
# re-deploy networkInterfaces & loadBalancers
	$resourcesRedeploy = @()

	# get saved NIC resources
	$script:resourcesNic
	| ForEach-Object -Process {

		$_.dependsOn = @()
		$resourcesRedeploy += $_
	}

	# get saved LB resources
	$script:resourcesLB
	| ForEach-Object -Process {

		$_.dependsOn = @()
		$resourcesRedeploy += $_
	}

	$dependsOn = @()
	# get dependencies of Redeployment
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object -Process {

		$dependsOn += get-resourceFunction `
			'Microsoft.Compute' `
			'virtualMachines'	$_.name
	}
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/loadBalancers/inboundNatRules'
	| ForEach-Object -Process {

		$main,$sub = $_.name -split '/'

		$dependsOn += get-resourceFunction `
			'Microsoft.Network' `
			'loadBalancers'		$main `
			'inboundNatRules' 	$sub
	}
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/loadBalancers'
	| ForEach-Object -Process {

		$dependsOn += get-resourceFunction `
			'Microsoft.Network' `
			'loadBalancers'		$_.name
	}
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
	| ForEach-Object -Process {

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
		write-logFileUpdates 'deployments' 'NIC_Redeployment' 'create'
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
		| ForEach-Object -Process {

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
		| ForEach-Object -Process {

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
	| ForEach-Object -Process {

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
function new-vmssFlex {
#--------------------------------------------------------------
	# fill [hashtable] $script:paramValues
	set-parameter 'createVmssFlex ' $createVmssFlex 'Microsoft.Compute/virtualMachines'
	$script:vmssProperties = @{}
	$deleted = @()
	$remaining = @()
	$created = @()
	$max = $script:MaxRegionFaultDomains

	#--------------------------------------------------------------
	# remove vmss
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachineScaleSets'
	| ForEach-Object {

		if ($skipVmssFlex -or ($_.properties.orchestrationMode -ne 'Flexible')) {
			write-logFileUpdates 'vmScaleSets' $_.name 'delete'
			$deleted += $_.name
		}
		else {
			$remaining += $_.name
		}
	}

	if (($remaining.count -ne 0) -and ('setVmZone' -notin $boundParameterNames)) {
		write-logFileWarning "VM Scale Sets exists and parameter 'setVmZone' is not set" `
							"Default value 'none' of parameter 'setVmZone' is not used"
		$script:setVmZone = @()
	}

	# delete resource
	foreach ($vmss in $deleted) {
		remove-resources 'Microsoft.Compute/virtualMachineScaleSets' $vmss
	}
	# vmss FLEX does not have this subresource (although it is exported from source RG)
	remove-resources 'Microsoft.Compute/virtualMachineScaleSets/virtualMachines'

	# update VMs (remove vmss)
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$id = $_.properties.virtualMachineScaleSet.id
		if ($Null -ne $id) {
			$vmss = (get-resourceComponents $id).mainResourceName
			if ($vmss -in $deleted) {

				write-logFileUpdates 'virtualMachines' $_.name 'remove vmScaleSet'
				$_.properties.virtualMachineScaleSet = $Null
				$_.properties.platformFaultDomain = $Null
				$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Compute/virtualMachineScaleSets'
			}
		}
	}

	#--------------------------------------------------------------
	# create new vmssFlex
	foreach ($config in $script:paramAllConfigs) {

		$vmssName		= $config.paramConfig1
		$faultDomains	= $config.paramConfig2
		$zoneList		= $config.paramConfig3

		# test vmssName: 1 to 64 characters
		$match = '^[a-zA-Z0-9][a-zA-Z0-9\-]{0,62}[a-zA-Z0-9]$|^[a-zA-Z]$'
		test-match 'createVmssFlex' $vmssName $match 'vmssName' 'vmssName/faultDomains/zones@VMs'
		test-values 'createVmssFlex' $zoneList @('none', '1+2', '1+3', '2+3', '1+2+3') 'zones' 'vmssName/faultDomains/zones@VMs'
		test-values 'createVmssFlex' $faultDomains @('none', '2', '3', 'max') 'faultDomains' 'vmssName/faultDomains/zones@VMs'

		# provide either or
		if ((($zoneList -eq 'none') -and ($faultDomains -eq 'none')) `
		-or (($zoneList -ne 'none') -and ($faultDomains -ne 'none'))) {

			write-logFileError "Invalid parameter 'createVmssFlex'" `
					"The syntax is: 'vmssName/faultDomains/zones@VMs'" `
					"Value of 'zones' is '$zoneList', Value of 'faultDomains' is '$faultDomains'" `
					"Exactly one of these two must have the value 'none'"
		}

		# correct values
		if ($faultDomains -eq 'none') {
			$numDomains = 1
		}
		elseif ($faultDomains -eq 'max') {
			$numDomains = $max
		}
		else {
			$numDomains = $faultDomains -as [int]
		}

		if ($numDomains -gt $max) {
			write-logFileWarning "Region '$targetLocation' only supports $max fault domains"
			$numDomains = $max
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

		# save properties for setMergeVMs
		$script:vmssProperties[$vmssName] = @{
			faultDomainCount	= $numDomains
			zones				= $zoneArray
		}

		# VMSS has not been already created
		# (the same name might occur 2 times in the RGCOPY array-parameter)
		if (($vmssName -notin $created) -and ($setVmMerge.count -eq 0)) {
			$created += $vmssName
			write-logFileUpdates 'vmScaleSets' $vmssName 'create'
			[array] $script:resourcesALL += $res
		}
	}

	#--------------------------------------------------------------
	# update VMs with new vmss
	#   zone will be set by parameter setVmZone
	#   platformFaultDomain will be set by parameter setVmFaultDomain
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$vmName = $_.name
		$vmssName, $x = $script:paramValues[$vmName] -split '/'

		if ($vmssName.length -ne 0) {

			# get ID function
			$vmssID = get-resourceFunction `
						'Microsoft.Compute' `
						'virtualMachineScaleSets'	$vmssName

			# set property
			$_.properties.virtualMachineScaleSet = @{ id = $vmssID }
			write-logFileUpdates 'virtualMachines' $vmName 'set vmScaleSet' $vmssName

			# add new dependency
			[array] $_.dependsOn += $vmssID
		}
	}

	#--------------------------------------------------------------
	# update fault domain count (of new and existing VMSS)
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachineScaleSets'
	| ForEach-Object -Process {

		# check fault domain count
		if ($_.properties.platformFaultDomainCount -gt $max ) {
			write-logFileWarning "The maximum fault domain count in region '$targetLocation' is $max" -stopAtWarning
			write-logFileUpdates 'vmScaleSets' $_.name 'set faultDomainCount' $max
			$_.properties.platformFaultDomainCount = $max
		}

		# save properties
		$script:vmssProperties[$_.name] = @{
			faultDomainCount	= $_.properties.platformFaultDomainCount
			zones				= $_.zones
		}
	}

	# update fault domain in VMs
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$vmName  = $_.name
		$current = $_.properties.platformFaultDomain
		if ($Null -eq $current) {
			$current = -1
		}
		$current = $current -as [int]

		# check fault domain count
		if ($current -ge $max) {
			write-logFileWarning "Region '$targetLocation' only supports $max Fault Domains"
			write-logFileUpdates 'virtualMachines' $vmName "$action fault domain" 'none' -defaultValue
			$_.properties.platformFaultDomain = $Null
			$script:copyVMs[$vmName].PlatformFaultDomain = -1
		}
		if (($current -ge 0) -and ($Null -eq $_.properties.virtualMachineScaleSet.id)){
			write-logFileWarning "VM '$vmName' is not member of a VM Scale Set"
			write-logFileUpdates 'virtualMachines' $vmName "$action fault domain" 'none' -defaultValue
			$_.properties.platformFaultDomain = $Null
			$script:copyVMs[$vmName].PlatformFaultDomain = -1
		}

		# save vmss name
		if ($Null -ne $_.properties.virtualMachineScaleSet.id) {
			$vmssName = (get-resourceComponents $_.properties.virtualMachineScaleSet.id).mainResourceName
			$script:copyVMs[$vmName].VmssName = $vmssName
		}
	}
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
	$created = @()

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
		if (($ppgName -notin $created) -and ($setVmMerge.count -eq 0)) {
			$created += $ppgName
			write-logFileUpdates 'proximityPlacementGroups' $ppgName 'create'
			[array] $script:resourcesALL += $res
		}
	}
}

#--------------------------------------------------------------
function new-availabilitySet {
#--------------------------------------------------------------
	# fill [hashtable] $script:paramValues
	set-parameter 'createAvailabilitySet' $createAvailabilitySet 'Microsoft.Compute/virtualMachines'
	$deleted = @()
	$created = @()

	#--------------------------------------------------------------
	# remove avsets
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/availabilitySets'
	| ForEach-Object {

		if ($skipAvailabilitySet -or ($_.name -like 'rgcopy.tipGroup*')) {
			write-logFileUpdates 'availabilitySets' $_.name 'delete'
			$deleted += $_.name
		}
	}

	# delete resource
	foreach ($asName in $deleted) {
		remove-resources 'Microsoft.Compute/availabilitySets' $asName
	}

	# update VMs
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$id = $_.properties.availabilitySet.id
		if ($Null -ne $id) {
			$asName = (get-resourceComponents $id).mainResourceName
			if ($asName -in $deleted) {

				write-logFileUpdates 'virtualMachines' $_.name 'remove availabilitySet'
				$_.properties.availabilitySet = $Null
				$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Compute/availabilitySets'
			}
		}
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
		if (($asName -notin $created) -and ($setVmMerge.count -eq 0)) {
			$created += $asName
			write-logFileUpdates 'availabilitySets' $asName 'create'
			[array] $script:resourcesALL += $res
		}
	}

	#--------------------------------------------------------------
	# update fault domain count
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/availabilitySets'
	| ForEach-Object {

		# check fault domain count
		$max = $script:MaxRegionFaultDomains
		if ($_.properties.platformFaultDomainCount -gt $max ) {
			write-logFileWarning "The maximum fault domain count in region '$targetLocation' is $max" -stopAtWarning
			write-logFileUpdates 'availabilitySets' $_.name 'set faultDomainCount' $max
			$_.properties.platformFaultDomainCount = $max
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

			# get ID function
			$asID = get-resourceFunction `
						'Microsoft.Compute' `
						'availabilitySets'	$asName

			# set property
			$_.properties.availabilitySet = @{ id = $asID }
			write-logFileUpdates 'virtualMachines' $vmName 'set availabilitySet' $asName

			# add new dependency
			[array] $_.dependsOn += $asID

			# for each VM in AvSet: add PPG if AvSet is part of the PPG
			if ($ppgName.length -ne 0) {

				# get ID function
				$ppgID = get-resourceFunction `
							'Microsoft.Compute' `
							'proximityPlacementGroups'	$ppgName

				# set property
				$_.properties.proximityPlacementGroup = @{ id = $ppgID }
				write-logFileUpdates 'virtualMachines' $vmName 'set proximityPlacementGroup' $ppgName
				
				# add new dependency
				[array] $_.dependsOn += $ppgID
			}
		}

		# save availabilitySet name
		if ($Null -ne $_.properties.availabilitySet.id) {
			$avsetName = (get-resourceComponents $_.properties.availabilitySet.id).mainResourceName
			$script:copyVMs[$_.name].AvsetName = $avsetName
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

			$id = get-resourceFunction `
					'Microsoft.Compute' `
					'proximityPlacementGroups'	$ppgName

			$_.properties.proximityPlacementGroup = @{id = $id}
			[array] $_.dependsOn += $id
		}
	}

	# save PPG names
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		if ($Null -ne $_.properties.proximityPlacementGroup.id) {
			$ppgName = (get-resourceComponents $_.properties.proximityPlacementGroup.id).mainResourceName
			$script:copyVMs[$_.name].Ppgname = $ppgName
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
			$stopCondition = ('setVmDeploymentOrder' -notin $boundParameterNames)

			write-logFileWarning "Some VMs of proximity placement group '$($ppg.name)' are using zones, some not" `
									"Use RGCOPY parameter 'setVmDeploymentOrder' to:" `
									" firstly,  create VMs: $($ppg.vmsZone)" `
									" secondly, create VMs: $($ppg.vmsOther)" `
									$stopCondition
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

		# check for vmss
		if (($Null -eq $vmssName) -and ($wanted -ne -1)) {
			write-logFileWarning "VM '$vmName' is not part of a VM Scale Set"
			$wanted = -1
		}

		if ($Null -ne $vmssName) {
			# check for maximum value
			$max = $script:vmssProperties[$vmssName].faultDomainCount

			if ($wanted -ge $max) {
				write-logFileWarning "VM Scale Set '$vmssName' only supports $max fault domains"
				$wanted = -1
			}
			elseif (($max -eq 1) -and ($wanted -ne -1)) {
				write-logFileWarning "VM Scale Set '$vmssName' does not support fault domains"
				$wanted = -1
			}
		}

		# update
		if ($current -ne $wanted) {
			$_.PlatformFaultDomain = $wanted
			$action = 'set'
		}
		else {
			$action = 'keep'
		}
		# output
		if ($_.PlatformFaultDomain -eq -1) {
			write-logFileUpdates 'virtualMachines' $vmName "$action fault domain" 'none' -defaultValue
		}
		else {
			write-logFileUpdates 'virtualMachines' $vmName "$action fault domain" $_.PlatformFaultDomain
		}
	}

	# update virtualMachines
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$vmName = $_.name
		$platformFaultDomain = $script:copyVMs[$vmName].PlatformFaultDomain

		if ($platformFaultDomain -eq -1) {
			$_.properties.platformFaultDomain = $Null
		}
		else{
			$_.properties.platformFaultDomain = $platformFaultDomain
		}
	}
}

#--------------------------------------------------------------
function update-vmZone {
#--------------------------------------------------------------
	# process RGCOPY parameter
	set-parameter 'setVmZone' $setVmZone
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$vmZone = $script:paramConfig
		# convert old syntax to new syntax to be compatible
		if ($vmZone -eq '0') {
			$vmZone = 'none'
		}

		test-values 'setVmZone' $vmZone @('none','1','2','3') 'zone'
		# convert to internal syntax
		if ($vmZone -eq 'none') {
			$vmZone = 0
		}
		$vmZone = $vmZone -as [int]

		$script:copyVMs.values
		| Where-Object Name -in $script:paramVMs
		| ForEach-Object {

			$_.VmZoneNew = $vmZone
		}
		get-ParameterRule
	}

	# output of changes
	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| ForEach-Object {

		$vmName 	= $_.Name
		$vmssName	= $_.VmssName
		$avsetName	= $_.AvsetName

		$current	= $_.VmZone
		$wanted		= $_.VmZoneNew
		if ($Null -eq $wanted) {
			$wanted = $current
		}

		# check for vmss
		if (($Null -ne $vmssName) -and ($wanted -ne 0)) {
			$allowedZones = $script:vmssProperties[$vmssName].zones
			if ("$wanted" -notin $allowedZones) {
				write-logFileWarning "VMSS '$vmssName' of VM '$vmName' does not support zone $wanted"
				$wanted = 0
			}
		}

		# check for avset
		if (($Null -ne $avsetName) -and ($wanted -ne 0)) {
			write-logFileWarning "VM '$vmName' is part of an Availability Set. It does not support zones"
			$wanted = 0
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
function update-vmTipGroup {
#--------------------------------------------------------------
# all VMs of a VM Group are placed into an own, new AS
	if ($script:tipVMs.count -eq 0) { return }

	# create availabilitySets
	$tipGroups = $script:copyVMs.values.Group
				| Where-Object {$_ -gt 0}
				| Sort-Object -Unique

	foreach ($group in $tipGroups) {

		# TiP parameter names
		$TipSku 	= @{ name = 'Aligned' }
		$TipTags 	= @{ 'TipNode.SessionId' = "[parameters('tipSessionID$group')]" }
		$TipData 	= @{ pinnedFabricCluster = "[parameters('tipClusterName$group')]" }

		$properties = @{
			platformUpdateDomainCount	= 1
			platformFaultDomainCount	= 1
			internalData				= $TipData
		}

		$res = @{
			type 			= 'Microsoft.Compute/availabilitySets'
			apiVersion		= '2019-07-01'
			name 			= "rgcopy.tipGroup$group"
			location		= $targetLocation
			sku				= $TipSku
			tags			= $TipTags
			properties		= $properties
		}
		write-logFileUpdates 'availabilitySets' "rgcopy.tipGroup$group" 'create'
		[array] $script:resourcesALL += $res
	}

	# modify VM for TiP
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| Where-Object name -in $script:tipVMs
	| ForEach-Object -Process {

		$group = $script:copyVMs[$_.name].Group

		$id = get-resourceFunction `
				'Microsoft.Compute' `
				'availabilitySets'	"rgcopy.tipGroup$group"

		$idx = $id	-replace '\[', '' `
					-replace '\]', ''

		# set dependencies
		[array] $_.dependsOn += $id

		# set availabilitySet
		$as = "[if(empty(parameters('tipSessionID$group')), json('null'), json(concat('{""id"": ""', $idx, '""}')))]"
		$_.properties.availabilitySet = $as
		write-logFileUpdates 'virtualMachines' $_.name 'set availabilitySet' "rgcopy.tipGroup$group"

		$_.zones = @()
	}
}

#--------------------------------------------------------------
function update-vmSize {
#--------------------------------------------------------------
	$script:templateVariables = @{}

	# change VM size
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object -Process {

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
	| ForEach-Object -Process {

		# remove image reference, osProfile
		if ($Null -ne $_.properties.storageProfile.imageReference) {
			$_.properties.storageProfile.imageReference = $null
		}
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
		$_.properties.storageProfile.osDisk.managedDisk.storageAccountType = $Null
		$_.properties.storageProfile.osDisk.caching = $script:copyDisks[$diskName].Caching
		$_.properties.storageProfile.osDisk.writeAcceleratorEnabled = $script:copyDisks[$diskName].WriteAcceleratorEnabled
		$r = get-resourceComponents $_.properties.storageProfile.osDisk.managedDisk.id
		$id = get-resourceFunction `
				'Microsoft.Compute' `
				'disks'	$r.mainResourceName
		$_.properties.storageProfile.osDisk.managedDisk.id = $id
		[array] $_.dependsOn += $id

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
			else {
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

		# remove ultraSSDEnabled
		if ($_.properties.additionalCapabilities.ultraSSDEnabled -eq $True) {
			$_.properties.additionalCapabilities.ultraSSDEnabled = $False
			write-logFileUpdates 'virtualMachines' $_.name 'delete Ultra SSD support'
		}
	}
}

#--------------------------------------------------------------
function update-vmBootDiagnostics {
#--------------------------------------------------------------
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object -Process {

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
			[array] $currentDependentVMs		= $nextDependentVMs
			[array] $nextDependentVMs		= @()
		}

		$currentPriority = $vmPriority

		$nextDependentVMs += get-resourceFunction `
								'Microsoft.Compute' `
								'virtualMachines'	$vmName

		# update (exactly one) VM
		if ($vmPriority -ne $firstPriority) {
			$script:resourcesALL
			| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
			| Where-Object name -eq $vmName
			| ForEach-Object -Process {

				[array] $_.dependsOn += $dependentVMs
			}
		}
	}
}

#--------------------------------------------------------------
function update-vmExtensions {
#--------------------------------------------------------------
	if ($skipExtensions) { return }

	$script:copyVMs.values
	| Where-Object Skip -ne $True
	| Where-Object Name -in $installExtensionsAzureMonitor
	| ForEach-Object {

		[array] $depends = get-resourceFunction `
								'Microsoft.Compute' `
								'virtualMachines'	$_.Name
		$res = @{
			type = 'Microsoft.Compute/virtualMachines/extensions'
			location = $targetLocation
			apiVersion = '2020-06-01'
			properties = @{
				publisher = 'Microsoft.Azure.Monitor'
				autoUpgradeMinorVersion = $True
				# enableAutomaticUpgrade = $True
			}
			dependsOn = $depends
		}

		if ($_.OsDisk.OsType -eq 'linux') {
			$agentName = "$($_.Name)/AzureMonitorLinuxAgent"
			$res.properties.type  = 'AzureMonitorLinuxAgent'
			$res.properties.typeHandlerVersion = '1.5'
		}
		else {
			$agentName = "$($_.Name)/AzureMonitorWindowsAgent"
			$res.properties.type  = 'AzureMonitorWindowsAgent'
			$res.properties.typeHandlerVersion = '1.0'
		}
		$res.name = $agentName

		write-logFileUpdates 'extensions' $agentName 'create'
		[array] $script:resourcesALL += $res
	}
}

#--------------------------------------------------------------
function update-newDisks {
#--------------------------------------------------------------
	$script:copyDisksNew = @{}

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
		| ForEach-Object -Process {
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
				$script:copyDisksNew[$diskName] = @{
					name					= "$diskName (NEW)"
					VM						= $vmName
					Skip					= $False
					Caching					= 'None'
					WriteAcceleratorEnabled	= $False
					SizeGB					= $diskSize
					SizeTierName			= $SizeTierName
					performanceTierName		= $performanceTierName
				}

				# create disk
				$disk = @{
					type 			= 'Microsoft.Compute/disks'
					apiVersion		= '2021-08-01'
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
				if ($vmZone -gt 0) {
					$disk.Add('zones', @($vmZone) )
				}

				# add disk
				[array] $script:resourcesALL += $disk
				write-logFileUpdates 'disks' $diskName 'create empty disk' '' '' $info

				# update a single vm
				$script:resourcesALL
				| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
				| Where-Object name -eq $vmName
				| ForEach-Object -Process {

					$diskId = get-resourceFunction `
								'Microsoft.Compute' `
								'disks'	$diskName

					$dataDisk = @{
						lun						= $diskLun
						name					= $diskName
						createOption			= 'Attach'
						caching					= 'None'
						writeAcceleratorEnabled	= $False
						managedDisk				= @{ id = $diskId }
						toBeDetached			= $False
					}

					# add ultraSSDEnabled
					if ($iops -gt 0) {
						$_.properties.additionalCapabilities = @{ultraSSDEnabled = $True}
						write-logFileUpdates 'virtualMachines' $_.name 'add Ultra SSD support'
					}

					# add disk
					[array] $_.properties.storageProfile.dataDisks += $dataDisk
					[array] $_.dependsOn += $diskId
				}
			}
		}
	}
}

#--------------------------------------------------------------
function update-disks {
#--------------------------------------------------------------
	# create disks
	$script:copyDisks.Values
	| ForEach-Object {

		$diskName = $_.Name

		if ($_.Skip -eq $True) {
			write-logFileUpdates 'disks' $diskName 'delete' '' '' 'skipped disk'
		}
		elseif ($_.VM -in $generalizedVMs) {
			# nothing to do here
		}
		else {
			# creation from snapshot
			if (!$useBlobs) {
				$from = 'snapshot'
				$snapshotName = "$diskName.$snapshotExtension"
				if ( $skipSnapshots -and !$justRedeployAms -and ($snapshotName -notin $script:snapshotNames)) {
					write-logFileError "Snapshot '$snapshotName' not found" `
										"Remove parameter 'skipSnapshots'"
				}
				$snapshotId = get-resourceString `
								$sourceSubID		$sourceRG `
								'Microsoft.Compute' `
								'snapshots'			$snapshotName

				$creationData = @{
					createOption 		= 'Copy'
					sourceResourceId 	= $snapshotId
				}
			}
			# creation from BLOB
			else {
				$from = 'BLOB'
				$sourceUri = "https://$blobsSA.blob.core.windows.net/$blobsSaContainer/$diskName.vhd"

				$blobsSaID = get-resourceString `
								$targetSubID		$blobsRG `
								'Microsoft.Storage' `
								'storageAccounts'	$blobsSA

				$creationData = @{
					createOption 		= 'Import'
					storageAccountId 	= $blobsSaID
					sourceUri 			= $sourceUri
				}
			}

			# disk properties
			$properties = @{
				diskSizeGB 		= $_.SizeGB
				creationData	= $creationData
			}
			if ($_.performanceTierName.length -ne 0)	{ $properties.Add('tier', $_.performanceTierName) }
			if ($_.OsType.count -ne 0)					{ $properties.Add('osType', $_.OsType) }
			if ($_.HyperVGeneration.length -ne 0)		{ $properties.Add('hyperVGeneration', $_.HyperVGeneration) }
			if ($_.BurstingEnabled -eq $True)			{ $properties.Add('burstingEnabled', $True) }
			if ($_.MaxShares -gt 1)						{ $properties.Add('maxShares', $_.MaxShares) }

			# disk object
			$sku = @{ name = $_.SkuName }
			$disk = @{
				type 			= 'Microsoft.Compute/disks'
				apiVersion		= '2021-08-01'
				name 			= $diskName
				location		= $targetLocation
				sku				= $sku
				properties		= $properties
			}

			if ($_.Tags.count -ne 0) { $disk.Add('tags',  $_.Tags) }

			# set disk zone
			if ($Null -ne $script:copyVMs[$_.VM]) {
				if ($script:copyVMs[$_.VM].VmZone -in @(1,2,3)) {
					$disk.Add('zones', @($script:copyVMs[$_.VM].VmZone) )
				}
			}

			# add disk
			[array] $script:resourcesALL += $disk
			write-logFileUpdates 'disks' $diskName "create from $from" '' '' "$($_.SizeGB) GiB"

			# update VM dependency already done in function update-vmDisks
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

		# add OS disk to image
		$diskName = $_.OsDisk.Name
		$diskObject = $script:copyDisks[$diskName]
		$snapshotId = get-resourceString `
						$sourceSubID		$sourceRG `
						'Microsoft.Compute' `
						'snapshots'			"$diskName.$snapshotExtension"

		$ImageOsDisk = @{
			snapshot			= @{ id = $snapshotId }
			diskSizeGB			= $diskObject.SizeGB
			storageAccountType	= $diskObject.SkuName
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
			$diskObject = $script:copyDisks[$diskName]
			$snapshotId = get-resourceString `
							$sourceSubID		$sourceRG `
							'Microsoft.Compute' `
							'snapshots'			"$diskName.$snapshotExtension"

			$imageDisk = @{
				snapshot			= @{ id = $snapshotId }
				diskSizeGB			= $diskObject.SizeGB
				storageAccountType	= $diskObject.SkuName
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
			name 			= "$($_.Name).$snapshotExtension"
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
		[array] $script:resourcesALL += $image
	}

	#--------------------------------------------------------------
	# create VM from image
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| Where-Object name -in $generalizedVMs
	| ForEach-Object -Process {

		# image
		$imageId = get-resourceFunction `
						'Microsoft.Compute' `
						'images'	"$($_.name).$snapshotExtension"

		$_.properties.storageProfile.imageReference = @{ id = $imageId }

		# remove dependencies of disks
		$_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Compute/disks'
		# add dependency of image
		[array] $_.dependsOn += $imageId

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
				| ForEach-Object  {

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
	if ($script:mountPointsVolumesGB -eq 0) { return }

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
	[array] $script:resourcesALL += $res
	[array] $dependsOn = get-resourceFunction `
							'Microsoft.NetApp' `
							'netAppAccounts'	$netAppAccountName

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
		dependsOn = $dependsOn
	}
	write-logFileUpdates 'capacityPools' $netAppPoolName 'create'
	[array] $script:resourcesALL += $res

	#--------------------------------------------------------------
	# get subnetID
	$vnet = $Null
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks/subnets'
	| ForEach-Object  {

		if ($Null -ne $_.properties.delegations) {
			if ($Null -ne $_.properties.delegations.properties) {
				if ($_.properties.delegations.properties.serviceName -eq 'Microsoft.NetApp/volumes') {
					$vnet,$subnet = $_.name -split '/'
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

	$dependsOn += $subnetId
	$dependsOn += get-resourceFunction `
					'Microsoft.NetApp' `
					'netAppAccounts'	$netAppAccountName `
					'capacityPools'		$netAppPoolName

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
		# add subnet
		$res = @{
			type 		= 'Microsoft.Network/virtualNetworks/subnets'
			apiVersion	= $apiVersion
			name 		= "$vnet/$subnet"
			location	= $targetLocation
			dependsOn	= @( $vnetId )
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
		write-logFileUpdates 'subnet' $subnet 'create'
		[array] $script:resourcesALL += $res
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
					subnetId					= $subnetId
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
				dependsOn = $dependsOn
			}
			write-logFileUpdates 'volumes' $volumeName 'create' '' '' "$volumeSizeGB GiB"
			[array] $script:resourcesALL += $res
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

	# rename resource
	$script:resourcesALL
	| Where-Object name -eq $nameOld
	| Where-Object type -eq $type
	| ForEach-Object  {

		$_.name = $nameNew
	}

	# rename dependencies
	$script:resourcesALL
	| ForEach-Object  {

		for ($i = 0; $i -lt $_.dependsOn.count; $i++) {
			if ($True -eq (compare-resources $_.dependsOn[$i]   $resourceOld)) {
				$_.dependsOn[$i] = $resourceNew
			}
		}
	}

	return @($resourceOld, $resourceNew)
}

#--------------------------------------------------------------
function rename-VMs {
#--------------------------------------------------------------
	$script:copyVMs.Values
	| Where-Object {$_.Rename.length -ne 0}
	| ForEach-Object {

		$nameOld 	= $_.Name
		$nameNew	= $_.Rename

		write-logFileUpdates 'virtualMachines' $nameOld 'rename to' $nameNew
		$resFunctionOld, $resFunctionNew = rename-any $nameOld $nameNew 'Microsoft.Compute' 'virtualMachines'

		# process availabilitySets not needed, because these AvSet properties will be deleted later anyway:
		# -  $_.properties.virtualMachines
		# -  $_.dependsOn
	}
}

#--------------------------------------------------------------
function rename-disks {
#--------------------------------------------------------------
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object  {

# rename VM OS Disk
		$len = (71, $_.name.Length | Measure-Object -Minimum).Minimum
		$vmName = $_.name.SubString(0,$len)

		$nameOld = $_.properties.storageProfile.osDisk.name
		$nameNew = "$vmName`__disk_os" #max length 80

		write-logFileUpdates 'disks' $nameOld 'rename to' $nameNew
		$resFunctionOld, $resFunctionNew = rename-any $nameOld $nameNew 'Microsoft.Compute' 'disks'
		$script:copyDisks[$nameOld].Rename = $nameNew

		$_.properties.storageProfile.osDisk.name 			= $nameNew
		$_.properties.storageProfile.osDisk.managedDisk.id	= $resFunctionNew

# rename VM Data Disks
		$len = (67, $_.name.Length | Measure-Object -Minimum).Minimum
		$vmName = $_.name.SubString(0,$len)

		foreach ($disk in $_.properties.storageProfile.dataDisks) {

			$nameOld = $disk.name
			$nameNew = "$vmName`__disk_lun_$($disk.lun)" #max length 80

			write-logFileUpdates 'disks' $nameOld 'rename to' $nameNew
			$resFunctionOld, $resFunctionNew = rename-any $nameOld $nameNew 'Microsoft.Compute' 'disks'
			$script:copyDisks[$nameOld].Rename = $nameNew

			$disk.name 				= $nameNew
			$disk.managedDisk.id	= $resFunctionNew
		}
	}
}

#--------------------------------------------------------------
function update-mergeIPs {
#--------------------------------------------------------------
	$script:mergeVMwithIP = @()

	$script:resourcesALL 
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| Where-Object name -in $script:mergeVMs
	| ForEach-Object {

		$script:hasIP = $False

		# get all NICs from VM
		$nicIDs = $_.dependsOn | Where-Object {$_ -like "*'Microsoft.Network/networkInterfaces'*"}
		foreach ($nicID in $nicIDs) {
			$nicName = (get-resourceComponents $nicID).mainResourceName

			# check if at least one NIC has publicIPAddress
			$script:resourcesALL 
			| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
			| Where-Object name -eq $nicName
			| ForEach-Object {

				$ipIDs = $_.dependsOn | Where-Object {$_ -like "*'Microsoft.Network/publicIPAddresses'*"}
				if ($Null -ne $ipIDs) {
					$script:hasIP = $True
				}
			}
		}

		# save VMs with IP
		if ($script:hasIP) {
			$script:mergeVMwithIP += $_.name
		}
	}
}

#--------------------------------------------------------------
function update-mergeAvailability {
#--------------------------------------------------------------
	param (
		$vm,
		$type,
		$name
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
		$vm.properties.$type = @{ id = $id }

		Write-Output -NoEnumerate $name
	}
}

#--------------------------------------------------------------
function update-merge {
#--------------------------------------------------------------
	# merge VMs into subnet of existing resource group (target RG)
	if ($script:mergeVMs.count -eq 0) { return }
	# $script:mergeVMs contains original VM names before rename

	# all resources except VMs to merge are deleted in new-templateTarget
	# disks resources are created in update-disks (new-templateTarget)
	# VMs are renamed in rename-VMs (new-templateTarget)
	# always rename disks when using MERGE
	rename-disks

	$mergeVmNames    = @()
	$mergeDiskNames  = @()
	$mergeNicNames   = @()
	$mergeNetSubnets = @()
	$mergeVmssNames  = @()
	$mergeAvSetNames = @()
	$mergePpgNames   = @()
	$mergeIPNames    = @()

	$script:copyVMs.values
	| Where-Object {$Null -ne $_.MergeNetSubnet}
	| ForEach-Object {

		# new VM name
		$vmNameOld = $_.Name
		if ($_.Rename.length -ne 0) {
			$vmName = $_.Rename
		}
		else {
			$vmName = $_.Name
		}

		# resources for new VM
		$avSetName		= $_.AvsetName
		$ppgName		= $_.Ppgname
		$vmssName		= $_.VmssName
		$netSubnet		= $_.MergeNetSubnet
		$net, $subnet 	= $netSubnet -split '/'
		$nicName		= "$vmName-nic"
		$ipName			= "$vmName-ip"
		$nicID 			= get-resourceFunction `
							'Microsoft.Network' `
							'networkInterfaces'	$nicName

		$nicIdElement	= @{ id = $nicID }

		$subnetID		= get-resourceString `
							$targetSubID		$targetRG `
							'Microsoft.Network' `
							'virtualNetworks'	$net `
							'subnets' 			$subnet

		$subnetIdElement = @{ id = $subnetID }

		# check if accelerated networking is enabled
		$vmSize = $_.VmSize
		$enableAccNW = $script:vmSkus[$vmSize].AcceleratedNetworkingEnabled

		#--------------------------------------------------------------
		# update VM
		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
		| Where-Object name -eq $vmName
		| ForEach-Object -Process {

			# collect (renamed) VM and DISK names
			$mergeVmNames    += $vmName
			$mergeNicNames   += $nicName
			$mergeNetSubnets += $netSubnet
			$mergeNets       += $net
			$mergeDiskNames  += $_.properties.storageProfile.osDisk.name
			foreach ($disk in $_.properties.storageProfile.dataDisks) {
				$mergeDiskNames += $disk.name
			}

			# disable some options
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
			$_.properties.platformFaultDomain = $Null
			$mergeVmssNames  += (update-mergeAvailability $_ 'virtualMachineScaleSet'  $vmssName)
			$mergeAvSetNames += (update-mergeAvailability $_ 'availabilitySet'         $avSetName)
			$mergePpgNames   += (update-mergeAvailability $_ 'proximityPlacementGroup' $ppgName)

			# keep dependency of disks
			$_.dependsOn = remove-dependencies $_.dependsOn -keep 'Microsoft.Compute/disks'
			# add dependency of new NIC
			[array] $_.dependsOn += $nicID

			# add NIC to VM
			$_.properties.networkProfile = @{
				networkInterfaces = @( $nicIdElement )
			}
		}

		#--------------------------------------------------------------
		# create NIC
		$nicRes = @{
			type		= 'Microsoft.Network/networkInterfaces'
			apiVersion	= '2020-11-01'
			name		= $nicName
			location	= $targetLocation
			properties	= @{
				ipConfigurations = @( 
					@{
						name		= 'ipconfig1'
						properties	= @{
							privateIPAllocationMethod	= 'Dynamic'
							subnet						= $subnetIdElement
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
		if ($vmNameOld -in $script:mergeVMwithIP) {

			[array] $nicRes.dependsOn = get-resourceFunction `
									'Microsoft.Network' `
									'publicIPAddresses'	$ipName
			$mergeIPNames += $ipName

			$ipRes = @{
				type		= 'Microsoft.Network/publicIPAddresses'
				apiVersion	= '2020-11-01'
				name		= $ipName
				location	= $targetLocation
				properties	= @{
					publicIPAddressVersion		= 'IPv4'
					publicIPAllocationMethod	= 'Dynamic'
				}
			}
			write-logFileUpdates 'publicIPAddresses' $ipName 'create'
			[array] $script:resourcesALL += $ipRes
		}

		# add NIC
		write-logFileUpdates 'networkInterfaces' $nicName 'create'
		[array] $script:resourcesALL += $nicRes
	}

	#--------------------------------------------------------------
	# check if resources already exist in target RG

	$savedSub = $script:currentSub
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	# make sure that merged resources DO NOT already exist
	$res = test-resourceInTargetRG 'VM'                        'Get-AzVM'                      $mergeVmNames
	$res = test-resourceInTargetRG 'Disk'                      'Get-AzDisk'                    $mergeDiskNames
	$res = test-resourceInTargetRG 'Network Interface'         'Get-AzNetworkInterface'        $mergeNicNames
	$res = test-resourceInTargetRG 'Public IP Address'         'Get-AzPublicIpAddress'         $mergeIPNames

	# make sure that referenced resources DO already exist
	$res = test-resourceInTargetRG 'Virtual Machine Scale Set' 'Get-AzVmss'                    $mergeVmssNames   $True
	$res = test-resourceInTargetRG 'Availability Set'          'Get-AzAvailabilitySet'         $mergeAvSetNames  $True
	$res = test-resourceInTargetRG 'Proximity Placement Group' 'Get-AzProximityPlacementGroup' $mergePpgNames    $True
	$res = test-resourceInTargetRG 'Virtual Network'           'Get-AzVirtualNetwork'          $mergeNets        $True

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

	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function test-resourceInTargetRG {
#--------------------------------------------------------------
	param (
		$resType,
		$resFunction,
		$resNames,
		$mustExist
	)

	$param = @{
		ResourceGroupName	= $targetRG
		ErrorAction 		= 'SilentlyContinue'
	}
	$resTypeName = "$resType`s"

	switch ($resType) {
		'VM' {
			$targetResources = Get-AzVM @param
		}
		'Disk' {
			$targetResources = Get-AzDisk @param
		}
		'Network Interface' {
			$targetResources = Get-AzNetworkInterface @param
		}
		'Public IP Address' {
			$resTypeName = "$resType`es"
			$targetResources = Get-AzPublicIpAddress @param
		}
		'Virtual Machine Scale Set' {
			$paramName = "and 'createVmssFlex'"
			$targetResources = Get-AzVmss @param
		}
		'Availability Set' {
			$paramName = "and 'createAvailabilitySet'"
			$targetResources = Get-AzAvailabilitySet @param
		}
		'Proximity Placement Group' {
			$paramName = "and 'createProximityPlacementGroup'"
			$targetResources = Get-AzProximityPlacementGroup @param
		}
		'Virtual Network' {
			$targetResources = Get-AzVirtualNetwork @param
		}
	}
	test-azResult $resFunction  "Could not get $resTypeName of resource group '$targetRG'"
		
	foreach ($resName in $resNames) {
		if ($mustExist) {
			if ($resName -notin $targetResources.Name) {
				write-logFileError "Invalid parameters 'setVmMerge' $paramName" `
									"$resType '$resName' does not exist in resource group '$targetRG'"
				}	
		}
		else {
			if ($resName -in $targetResources.Name) {
			write-logFileError "Invalid parameter 'setVmMerge'" `
								"$resType '$resName' already exists in resource group '$targetRG'"
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

	add-greenlist 'Microsoft.HanaOnAzure/sapMonitors/providerInstances' '*'
	add-greenlist 'Microsoft.HanaOnAzure/sapMonitors' '*'

	add-greenlist 'Microsoft.Compute/disks' '*'
	add-greenlist 'Microsoft.Compute/snapshots' '*'
	add-greenlist 'Microsoft.Compute/virtualMachines'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'additionalCapabilities'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'additionalCapabilities' 'ultraSSDEnabled'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'hardwareProfile'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'hardwareProfile' 'vmSize'

	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'imageReference'

	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'osType'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'encryptionSettings'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'name'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'vhd'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'image'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'caching'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'writeAcceleratorEnabled'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'diffDiskSettings'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'createOption'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'diskSizeGB'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'managedDisk'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'managedDisk' 'id'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'managedDisk' 'storageAccountType'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'osDisk' 'managedDisk' 'diskEncryptionSet'

	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'lun'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'name'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'vhd'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'image'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'caching'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'writeAcceleratorEnabled'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'createOption'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'diskSizeGB'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'managedDisk'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'managedDisk' 'id'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'managedDisk' 'storageAccountType'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'managedDisk' 'diskEncryptionSet'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'dataDisks' 'toBeDetached'

	add-greenlist 'Microsoft.Compute/virtualMachines' 'osProfile'

	add-greenlist 'Microsoft.Compute/virtualMachines' 'networkProfile'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'networkProfile' 'networkInterfaces'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'networkProfile' 'networkInterfaces' 'id'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'networkProfile' 'networkInterfaces' 'properties'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'networkProfile' 'networkInterfaces' 'properties' 'primary'

	# add-greenlist 'Microsoft.Compute/virtualMachines' 'diagnosticsProfile'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'diagnosticsProfile' 'bootDiagnostics'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'diagnosticsProfile' 'bootDiagnostics' 'enabled'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'diagnosticsProfile' 'bootDiagnostics' 'storageUri'

	add-greenlist 'Microsoft.Compute/virtualMachines' 'availabilitySet'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'availabilitySet' 'id'

	add-greenlist 'Microsoft.Compute/virtualMachines' 'proximityPlacementGroup'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'proximityPlacementGroup'	'id'

	# add-greenlist 'Microsoft.Compute/virtualMachines' 'priority'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'evictionPolicy'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'billingProfile'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'host'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'licenseType'

	# add-greenlist 'Microsoft.Compute.virtualMachines/extensions' '*'

	
	add-greenlist 'Microsoft.Compute/virtualMachines' 'virtualMachineScaleSet'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'virtualMachineScaleSet' 'id'

	add-greenlist 'Microsoft.Compute/virtualMachineScaleSets'
	add-greenlist 'Microsoft.Compute/virtualMachineScaleSets' 'orchestrationMode'
	add-greenlist 'Microsoft.Compute/virtualMachineScaleSets' 'platformFaultDomainCount'

	add-greenlist 'Microsoft.Compute/virtualMachineScaleSets/virtualMachines'

	add-greenlist 'Microsoft.Compute/availabilitySets'
	add-greenlist 'Microsoft.Compute/availabilitySets' 'platformUpdateDomainCount'
	add-greenlist 'Microsoft.Compute/availabilitySets' 'platformFaultDomainCount'
	add-greenlist 'Microsoft.Compute/availabilitySets' 'virtualMachines'
	add-greenlist 'Microsoft.Compute/availabilitySets' 'virtualMachines' 'id'
	add-greenlist 'Microsoft.Compute/availabilitySets' 'proximityPlacementGroup'
	add-greenlist 'Microsoft.Compute/availabilitySets' 'proximityPlacementGroup' 'id'

	add-greenlist 'Microsoft.Compute/proximityPlacementGroups'
	add-greenlist 'Microsoft.Compute/proximityPlacementGroups' 'proximityPlacementGroupType'
	# add-greenlist 'Microsoft.Compute/proximityPlacementGroups' 'colocationStatus'

	add-greenlist 'Microsoft.Network/virtualNetworks'
	add-greenlist 'Microsoft.Network/virtualNetworks' 'addressSpace'
	add-greenlist 'Microsoft.Network/virtualNetworks' 'addressSpace' 'addressPrefixes'
	add-greenlist 'Microsoft.Network/virtualNetworks' 'dhcpOptions'
	add-greenlist 'Microsoft.Network/virtualNetworks' 'subnets'
	add-greenlist 'Microsoft.Network/virtualNetworks' 'subnets'	'id'
	add-greenlist 'Microsoft.Network/virtualNetworks' 'subnets'	'name'
	add-greenlist 'Microsoft.Network/virtualNetworks' 'subnets'	'properties' '*'
	add-greenlist 'Microsoft.Network/virtualNetworks' 'virtualNetworkPeerings' '*'
	# add-greenlist 'Microsoft.Network/virtualNetworks' 'enableDdosProtection'
	# add-greenlist 'Microsoft.Network/virtualNetworks' 'enableVmProtection'
	# add-greenlist 'Microsoft.Network/virtualNetworks' 'ddosProtectionPlan'
	# add-greenlist 'Microsoft.Network/virtualNetworks' 'bgpCommunities'
	# add-greenlist 'Microsoft.Network/virtualNetworks' 'ipAllocations'

	add-greenlist "Microsoft.Network/virtualNetworks/virtualNetworkPeerings"
	add-greenlist "Microsoft.Network/virtualNetworks/virtualNetworkPeerings" 'allowVirtualNetworkAccess'
	add-greenlist "Microsoft.Network/virtualNetworks/virtualNetworkPeerings" 'allowForwardedTraffic'
	add-greenlist "Microsoft.Network/virtualNetworks/virtualNetworkPeerings" 'allowGatewayTransit'
	add-greenlist "Microsoft.Network/virtualNetworks/virtualNetworkPeerings" 'useRemoteGateways'
	add-greenlist "Microsoft.Network/virtualNetworks/virtualNetworkPeerings" 'remoteVirtualNetwork' '*'
	add-greenlist "Microsoft.Network/virtualNetworks/virtualNetworkPeerings" 'remoteAddressSpace' '*'

	add-greenlist 'Microsoft.Network/virtualNetworks/subnets'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'addressPrefix'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'addressPrefixes'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'networkSecurityGroup'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'networkSecurityGroup' 'id'  # always id provided!?
	# add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'networkSecurityGroup' 'location'
	# add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'networkSecurityGroup' 'tags' '*'
	# add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'networkSecurityGroup' 'properties' '*'

	# add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'routeTable'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'natGateway' '*'
	# add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'serviceEndpoints'
	# add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'serviceEndpoints' 'service'
	# add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'serviceEndpoints' 'locations'
	# add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'serviceEndpointPolicies'
	# add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'serviceEndpointPolicies' 'id'
	# add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'serviceEndpointPolicies' 'location'
	# add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'serviceEndpointPolicies' 'tags' '*'
	# add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'serviceEndpointPolicies' 'properties' '*'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'ipAllocations'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'delegations'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'delegations' 'id'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'delegations' 'name'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'delegations' 'properties'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'delegations' 'properties' 'serviceName' #e.g. "Microsoft.NetApp/volumes"
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'privateEndpointNetworkPolicies'
	add-greenlist 'Microsoft.Network/virtualNetworks/subnets' 'privateLinkServiceNetworkPolicies'

	# add-greenlist 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings' '*'

	add-greenlist 'Microsoft.Network/bastionHosts' '*'

	add-greenlist 'Microsoft.Network/networkInterfaces'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'networkSecurityGroup' '*'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'id'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'name'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties'
	# add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'virtualNetworkTaps'
	# add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'applicationGatewayBackendAddressPools'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'loadBalancerBackendAddressPools'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'loadBalancerBackendAddressPools' 'id'  # always id provided!?
	# add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'loadBalancerBackendAddressPools' 'properties'
	# add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'loadBalancerBackendAddressPools' 'name'

	# add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'loadBalancerInboundNatRules'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'privateIPAddress'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'privateIPAllocationMethod'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'privateIPAddressVersion'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'subnet'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'subnet' 'id'  # always id provided!?
	# add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'subnet' 'properties'
	# add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'subnet' 'name'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'primary'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'publicIPAddress'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'publicIPAddress' 'id' # always id provided!?
	# add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'publicIPAddress' 'location'
	# add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'publicIPAddress' 'tags'
	# add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'publicIPAddress' 'sku'
	# add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'publicIPAddress' 'properties'
	# add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'publicIPAddress' 'zones'

	# add-greenlist 'Microsoft.Network/networkInterfaces' 'ipConfigurations' 'properties' 'applicationSecurityGroups'

	add-greenlist 'Microsoft.Network/networkInterfaces' 'dnsSettings'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'dnsSettings' 'internalDnsNameLabel'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'dnsSettings' 'dnsServers'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'enableAcceleratedNetworking'
	add-greenlist 'Microsoft.Network/networkInterfaces' 'enableIPForwarding'

	add-greenlist 'Microsoft.Network/publicIPAddresses'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'publicIPAllocationMethod'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'publicIPAddressVersion'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'dnsSettings'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'dnsSettings' 'domainNameLabel'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'dnsSettings' 'fqdn'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'dnsSettings' 'reverseFqdn'
	# add-greenlist 'Microsoft.Network/publicIPAddresses' 'ddosSettings'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'ipTags'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'ipTags' 'ipTagType'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'ipTags' 'tag'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'ipAddress'
	# add-greenlist 'Microsoft.Network/publicIPAddresses' 'publicIPPrefix'
	# add-greenlist 'Microsoft.Network/publicIPAddresses' 'publicIPPrefix' 'id'
	add-greenlist 'Microsoft.Network/publicIPAddresses' 'idleTimeoutInMinutes'

	add-greenlist 'Microsoft.Network/publicIPPrefixes' '*'
	add-greenlist 'Microsoft.Network/natGateways' '*'

	add-greenlist 'Microsoft.Network/loadBalancers'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'id'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'privateIPAddress'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'privateIPAllocationMethod'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'privateIPAddressVersion'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'subnet'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'subnet' 'id'  # always id provided!?
	# add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'subnet' 'properties'
	# add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'subnet' 'name'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'publicIPAddress'
	add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'publicIPAddress' 'id'  # always id provided!?
	# add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'publicIPAddress' 'location'
	# add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'publicIPAddress' 'tags'
	# add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'publicIPAddress' 'sku'
	# add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'publicIPAddress' 'properties'
	# add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'publicIPAddress' 'zones'

	# add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'publicIPPrefix'
	# add-greenlist 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations' 'properties' 'publicIPPrefix' 'id'
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

	add-greenlist 'Microsoft.Network/loadBalancers/backendAddressPools'
	add-greenlist 'Microsoft.Network/loadBalancers/backendAddressPools' 'loadBalancerBackendAddresses'
	add-greenlist 'Microsoft.Network/loadBalancers/backendAddressPools' 'loadBalancerBackendAddresses' 'name'
	add-greenlist 'Microsoft.Network/loadBalancers/backendAddressPools' 'loadBalancerBackendAddresses' 'properties'
	add-greenlist 'Microsoft.Network/loadBalancers/backendAddressPools' 'loadBalancerBackendAddresses' 'properties' 'ipAddress'
	add-greenlist 'Microsoft.Network/loadBalancers/backendAddressPools' 'loadBalancerBackendAddresses' 'properties' 'virtualNetwork'
	add-greenlist 'Microsoft.Network/loadBalancers/backendAddressPools' 'loadBalancerBackendAddresses' 'properties' 'virtualNetwork' 'id'

	add-greenlist 'Microsoft.Network/networkSecurityGroups' '*'
	add-greenlist 'Microsoft.Network/networkSecurityGroups/securityRules' '*'
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

	} else {

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
	if ($skipGreenlist) { return }

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
	[console]::ForegroundColor = 'DarkGray'
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
	[console]::ForegroundColor = 'Gray'
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

	# local machine Name
	$script:rgcopyParamOrig.vmName = [Environment]::MachineName

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
	test-azResult 'Invoke-Command'  "Local PowerShell script '$pathScript' failed"

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
				-ErrorAction 'SilentlyContinue'

		$status  = $vm.VMAgent.Statuses.DisplayStatus
		$version = $vm.VMAgent.VmAgentVersion

		# status unknown
		if ($Null -eq $status) {
			test-azResult 'Get-AzVM'  "VM '$scriptServer' not found in resource group '$resourceGroup'"  -always
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
			test-azResult 'Invoke-AzVMRunCommand'  "Executing script in VM '$vm' failed" `
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
function update-remoteSubnets {
#--------------------------------------------------------------
	param (
		$resourceGroup
	)

	$script:remoteResources
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks/subnets'
	| ForEach-Object -Process {
		
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
	param (
		$resourceGroup
	)

	$remainingSubnetNames = @()

	$script:remoteResources
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks'
	| ForEach-Object -Process {

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
	param (
		$resourceGroup
	)

	$script:remoteResources
	| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
	| ForEach-Object -Process {
		
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
	param (
		$resourceType,
		$configName
	)

	# networkInterfaces / loadBalancers / bastionHosts
	$script:resourcesALL
	| Where-Object type -eq $resourceType
	| ForEach-Object -Process {

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
	if ($script:remoteRGs.count -eq 0) { return }

	# virtualMachines
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object -Process {

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

	# sapMonitors
	$script:resourcesAMS
	| Where-Object type -eq 'Microsoft.HanaOnAzure/sapMonitors'
	| ForEach-Object -Process {

		if ($_.properties.monitorSubnet -like '/*') {

			# convert resource ID to to resource function
			$r = get-resourceComponents $_.properties.monitorSubnet

			# convert name
			$resKey = "virtualNetworks/$($r.resourceGroup)/$($r.mainResourceName)"
			$vnetName = $script:remoteNames[$resKey].newName
			$resFunction = get-resourceFunction `
							'Microsoft.Network' `
							'virtualNetworks'	$vnetName `
							'subnets'			$r.subResourceName

			# set ID and dependency
			$_.properties.monitorSubnet = $resFunction
			[array] $_.dependsOn += $resFunction
		}
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
	test-azResult 'Export-AzResourceGroup'  "Could not create JSON template from source RG"
	
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
		test-azResult 'Export-AzResourceGroup'  "Could not create JSON template from resource group $rg"
		
		write-logFile -ForegroundColor 'Cyan' "Source template saved: $importPathExtern"
		$script:armTemplateFilePaths += $importPathExtern
		$text = Get-Content -Path $importPathExtern

		# convert ARM template to hash table
		$remoteTemplate = $text | ConvertFrom-Json -Depth 20 -AsHashtable
		$script:remoteResources = convertTo-array $remoteTemplate.resources

		# remove all dependencies
		$script:remoteResources
		| ForEach-Object -Process {
			$_.dependsOn = @()
		}

		update-remoteNICs $rg
		update-remoteVNETs $rg

		# add to all resources
		$script:resourcesALL += $script:remoteResources
	}
	update-remoteSourceRG
}

#--------------------------------------------------------------
function new-templateTarget {
#--------------------------------------------------------------
	# count parameter changes caused by default values:
	$script:countDiskSku				= 0
	$script:countVmZone					= 0
	$script:countLoadBalancerSku		= 0
	$script:countPrivateIpAlloc			= 0
	$script:countAcceleratedNetworking	= 0
	# do not count modifications if parameter was supplied explicitly
	if ('setDiskSku'				-in $boundParameterNames) { $script:countDiskSku				= -999999}
	if ('setVmZone'					-in $boundParameterNames) { $script:countVmZone					= -999999}
	if ('setLoadBalancerSku'		-in $boundParameterNames) { $script:countLoadBalancerSku		= -999999}
	if ('setPrivateIpAlloc'			-in $boundParameterNames) { $script:countPrivateIpAlloc			= -999999}
	if ('setAcceleratedNetworking'	-in $boundParameterNames) { $script:countAcceleratedNetworking	= -999999}

	# filter greenlist
	compare-greenlist

	# start output resource changes
	Write-logFile 'Resource                                  Changes by RGCOPY' -ForegroundColor 'Green'
	Write-logFile '--------                                  -----------------' -ForegroundColor 'Green'
	write-logFileUpdates '*' '*' 'set location' $targetLocation '' ' (for all resources except sapMonitors)'
	write-logFileUpdates 'storageAccounts' '*' 'delete'
	write-logFileUpdates 'snapshots'       '*' 'delete'
	write-logFileUpdates 'disks'           '*' 'delete'
	write-logFileUpdates 'images'          '*' 'delete'
	write-logFileUpdates 'extensions'      '*' 'delete'

	# process resource parameters
	# required order:
	# 1. setVmSize
	# 2. setDiskSku
	# 3. setDiskSize (and setDiskTier)
	# 4. setDiskCaching
	# 5. setAcceleratedNetworking

	update-paramSetVmSize
	update-paramSetDiskSku
	update-paramSetDiskSize
	update-paramSetDiskBursting
	update-paramSetDiskMaxShares
	update-paramSetDiskCaching
	update-paramSetAcceleratedNetworking

	# change LOCATION
	$script:resourcesALL
	| Where-Object type -ne 'Microsoft.HanaOnAzure/sapMonitors'
	| ForEach-Object -Process {
		if ($_.location.length -ne 0) {
			$_.location = $targetLocation
		}
	}

	# remove identity
	$script:resourcesALL
	| ForEach-Object -Process {

		$type = ($_.type -split '/')[1]
		if ($_.identity.count -ne 0) {
			write-logFileUpdates $type $_.name 'delete Identity'
			$_.identity = $Null
		}
	}

	# remove zones
	$script:resourcesALL
	| ForEach-Object -Process {

		$type = ($_.type -split '/')[1]
		if ( ($Null -ne $_.zones) `
		-and ($_.type -ne 'Microsoft.Compute/virtualMachines') `
		-and ($_.type -notlike 'Microsoft.Compute/virtualMachineScaleSets*' )) {
			write-logFileUpdates $type $_.name 'delete Zones'
			$_.zones = $Null
		}
	}

	# remove tags
	$script:resourcesALL
	| ForEach-Object -Process {

		$type = ($_.type -split '/')[1]
		$tagsOld = $_.tags
		$tagsNew = @{}
		# do not change tags of networkSecurityGroups
		if (($tagsOld.count -ne 0) -and ($type -ne 'networkSecurityGroups')) {
			foreach ($key in $tagsOld.keys) {
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

	# save snapshot Names
	$script:snapshotNames = convertTo-array (($script:resourcesALL | Where-Object `
		type -eq 'Microsoft.Compute/snapshots').name)

	# save AMS
	$script:supportedProviders = @('SapHana', 'MsSqlServer', 'PrometheusOS', 'PrometheusHaCluster') # 'SapNetweaver' not supported yet
	$script:resourcesAMS = convertTo-array (($script:resourcesALL | Where-Object { `
			 ($_.type -eq 'Microsoft.HanaOnAzure/sapMonitors') `
		-or (($_.type -eq 'Microsoft.HanaOnAzure/sapMonitors/providerInstances') -and ($_.properties.type -in $script:supportedProviders)) `
	}))

	update-skipVMs
	remove-resources 'Microsoft.Storage/storageAccounts*'
	remove-resources 'Microsoft.Compute/snapshots'
	remove-resources 'Microsoft.Compute/disks'
	remove-resources 'Microsoft.Compute/images*'
	remove-resources 'Microsoft.HanaOnAzure/sapMonitors*'
	remove-resources 'Microsoft.Compute/virtualMachines/extensions'
	remove-resources 'Microsoft.Network/loadBalancers/backendAddressPools'
	remove-resources 'Microsoft.Compute/virtualMachines' $script:skipVMs
	remove-resources 'Microsoft.Network/networkInterfaces' $script:skipNICs
	remove-resources 'Microsoft.Network/publicIPAddresses' $script:skipIPs

	# filter resources when VM Merge is used
	if ($script:mergeVMs.count -ne 0) {

		update-mergeIPs

		write-LogFile
		write-logFileUpdates '*' '*' 'delete all' " (except VMs: $script:mergeVMs)"

		$script:resourcesALL = convertTo-array ($script:resourcesALL | Where-Object { `
				 ($_.type -eq 'Microsoft.Compute/virtualMachines') `
			-and ($_.name -in $script:mergeVMs) })

		$script:resourcesAMS = @()
	}

	update-netApp

	if ($script:MaxRegionFaultDomains -eq 1) {
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
	new-vmssFlex
	new-availabilitySet
	update-proximityPlacementGroup
	update-vmZone
	update-vmFaultDomain
	update-vmTipGroup

	update-vmSize
	update-vmDisks
	update-vmBootDiagnostics
	update-vmPriority
	update-vmExtensions

	update-NICs
	update-subnets
	update-networkPeerings

	# when creating targetAms template, the target template will be changed, too (region of vnet)
	new-templateTargetAms

	update-SKUs
	update-IpAllocationMethod
	update-securityRules
	update-FQDN

	# save NICs and LBs for redeployment
	$script:resourcesNic = @()
	$script:resourcesLB = @()
	update-dependenciesAS
	update-dependenciesVNET
	update-dependenciesLB
	# Redeploy using saved NICS and LBs
	update-reDeployment

	update-disks
	update-newDisks
	update-images

	update-bastion

	rename-VMs
	if ($renameDisks) {
		rename-disks
	}
	# merge VMs AFTER renaming
	update-merge

	# commit modifications
	$script:sourceTemplate.resources = $script:resourcesALL

	# set parameters
	$templateParameters = @{}
	$tipGroups = $script:copyVMs.values.Group | Where-Object {$_ -gt 0} | Sort-Object -Unique
	foreach ($group in $tipGroups) {
		$templateParameters.Add("tipSessionID$group",   @{type='String'; defaultValue=''})
		$templateParameters.Add("tipClusterName$group", @{type='String'; defaultValue=''})
		write-logFileUpdates 'template parameter' "<tipSessionID$group>" 'create'
		write-logFileUpdates 'template parameter' "<tipClusterName$group>" 'create'
	}
	if ($tipGroups.count -ne 0) {
		$script:sourceTemplate.parameters = $templateParameters
	}
	$script:sourceTemplate.variables  = $script:templateVariables

	# changes caused by default value
	if ($copyMode) {
		if ($script:countDiskSku				-gt 0) { write-changedByDefault "setDiskSku = $setDiskSku" }
		if ($script:countVmZone					-gt 0) { write-changedByDefault "setVmZone = $setVmZone" }
		if ($script:countLoadBalancerSku		-gt 0) { write-changedByDefault "setLoadBalancerSku = $setLoadBalancerSku" }
		if ($script:countPrivateIpAlloc			-gt 0) { write-changedByDefault "setPrivateIpAlloc = $setPrivateIpAlloc" }
		if ($script:countAcceleratedNetworking	-gt 0) { write-changedByDefault "setAcceleratedNetworking = $setAcceleratedNetworking" }
		write-logFile
	}

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

	# output of priority
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
function update-skipVMs {
#--------------------------------------------------------------
	$script:vmOfNic  = @{}
	$skipCanidates   = @()
	$script:skipIPs  = @()
	$script:skipNICs = @()

	# output of skipped VMs
	foreach ($vm in $script:skipVMs) {
		write-logFileUpdates 'virtualMachines' $vm 'delete' '' '' 'skipped VM'
	}

	# save possible (candidate) NICs to skip
	# process ALL VMs (including non-skipped) to save $vmOfNic[$nicName]
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object -Process {

		$vmName = $_.name
		foreach ($nic in $_.properties.networkProfile.networkInterfaces) {
			if ($Null -ne $nic.id) {
				$nicName = (get-resourceComponents $nic.id).mainResourceName
				if ($Null -ne $nicName) {

					# save VMs for all NICs
					$script:vmOfNic[$nicName] = $vmName

					# save possible NICs to skip (NICs that are part of a skipped VM)
					if ($vmName -in $script:skipVMs) {
						$skipCanidates += $nicName
					}
				}
			}
		}
	}

	# save NICs and public IPs to skip
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
	| Where-Object name -in $skipCanidates
	| ForEach-Object -Process {

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
			write-logFileUpdates 'networkInterfaces' $nicName 'delete' '' '' 'NIC from skipped VM'

			# collect IPs to delete
			foreach ($conf in $_.properties.ipConfigurations) {
				if ($Null -ne $conf.properties.publicIPAddress.id) {
					$ipName = (get-resourceComponents $conf.properties.publicIPAddress.id).mainResourceName
					if ($Null -ne $ipName) {

						# Public IP of a skipped NIC
						$script:skipIPs += $ipName
						write-logFileUpdates 'publicIPAddresses' $ipName 'delete' '' '' 'IP address from skipped VM'
					}
				}
			}
		}
	}

	# process availabilitySets not needed, because these AvSet properties will be deleted later anyway:
	# -  $_.properties.virtualMachines
	# -  $_.dependsOn
}

#--------------------------------------------------------------
function get-amsProviderProperty {
#--------------------------------------------------------------
	param (
		[string] $string
	)

	$property = @{}
	if ($string.length -eq 0) {
		return $property
	}

	$all = $string -split '"'
	$i = 1
	while ($i -lt $all.Count) {
		# get key
		$key = $all[$i]
		$i++
		if ($i -ge $all.Count) { break }

		# value is string
		if (($all[$i] -replace '\s', '') -eq ':') {
			$i++
			if ($i -ge $all.Count) { break }
			$value = $all[$i]
			$property.$key = $value
			$i += 2
		}
		# value is numeric
		else {
			$value = $all[$i] -replace '\D', ''
			$property.$key = $value -as [int32]
			$i++
		}
	}

	return $property
}

#--------------------------------------------------------------
function set-amsProviderProperty {
#--------------------------------------------------------------
	param (
		[hashtable] $hash
	)

	[string] $string = ''
	$sep = ''

	$hash.GetEnumerator()
	| ForEach-Object {

		$string += $sep
		$sep = ','
		$string += "`"$($_.Key)`":"
		if ($_.Value -is [string]) {
			$string += "`"$($_.Value)`""
		}
		else {
			$string += "$($_.Value)"
		}
	}
	return "{$string}"
}

#--------------------------------------------------------------
function update-vnetLocation {
#--------------------------------------------------------------
	param (
		$vnet,
		$location
	)

	$subnetIDs = @()
	$nsgNames = @()

	# update VNET
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks'
	| Where-Object name -eq $vnet
	| ForEach-Object {

		# update location
		$_.location = $location
		write-logFileUpdates 'virtualNetworks' $_.name 'set location' $location

		# collect subnets and NSGs
		foreach ($subnet in $_.properties.subnets) {
			$subnetIDs += get-resourceFunction `
							'Microsoft.Network' `
							'virtualNetworks'	$_.name `
							'subnets'			$subnet.name

			if ($Null -ne $subnet.properties.networkSecurityGroup.id) {
				$nsgNames += (get-resourceComponents $subnet.properties.networkSecurityGroup.id).mainResourceName
			}
		}
	}

	# change location of NSG
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/networkSecurityGroups'
	| Where-Object name -in $nsgNames
	| ForEach-Object {

		$_.location = $location
		write-logFileUpdates 'networkSecurityGroups' $_.name 'set location' $location
	}

	# double check that there is no other NIC connected to the peered VNET
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
	| ForEach-Object {

		foreach ($config in $_.properties.ipConfigurations) {
			$nicSubnetID = $config.properties.subnet.id
			foreach ($subnetID in $subnetIDs) {
				if ($True -eq (compare-resources $subnetID $nicSubnetID)) {
					write-logFileError "Peered Network '$vnet' with AMS provider must not contain additional NICs" `
										"RGCOPY can copy an AMS provider in a different region by using a peered network" 
				}
			}
		}
	}
}

#--------------------------------------------------------------
function new-templateTargetAms {
#--------------------------------------------------------------
	if (!$createArmTemplateAms) {
		$script:resourcesAMS = @()
		return
	}
	$locationsAMS = @('East US 2', 'West US 2', 'East US', 'West Europe')

	# Rename needed because of the following deployment error:
	#   keyvault.VaultsClient#CreateOrUpdate: Failure sending request
	#   "Exist soft deleted vault with the same name."

	# process AMS instance
	$i = 0
	$script:resourcesAMS
	| Where-Object type -eq 'Microsoft.HanaOnAzure/sapMonitors'
	| ForEach-Object {

		if ($i++ -gt 0) {
			write-logFileError 'Only one AMS Instance per resource group supported by RGCOPY'
		}

		# rename AMS instance
		write-logFileUpdates 'sapMonitors' $_.name 'rename to' '' '<amsInstanceName>' ' (in AMS template)'
		$_.name = "[parameters('amsInstanceName')]"

		# remove dependencies
		$_.dependsOn = @()

		# use existing WS defined by parameters
		if ( ($amsWsName.length -ne 0) `
		-and ($amsWsRG.length -ne 0) ) ` {

			$wsId = "/subscriptions/$targetSubID/resourceGroups/$amsWsRG/providers/Microsoft.OperationalInsights/workspaces/$amsWsName"
			$_.properties.logAnalyticsWorkspaceArmId = $wsId
		}
		# create new WS in Managed Resource Group
		elseif (!$amsWsKeep) {
			$_.properties.logAnalyticsWorkspaceArmId = $Null
		}
		# keep existing WS
		else {
			if ($sourceSub -ne $targetSub) {
				write-logFileWarning "Cannot keep AMS Analytical Workspace when copying to different subscription"
				$_.properties.logAnalyticsWorkspaceArmId = $Null
			}
		}

		# https://docs.microsoft.com/en-us/azure/virtual-machines/workloads/sap/azure-monitor-overview
		if ($amsShareAnalytics) {
			$_.properties.enableCustomerAnalytics = $True
			write-logFileWarning 'Sharing AMS Customer Analytics Data with Microsoft'
		}
		else {
			$_.properties.enableCustomerAnalytics = $False
		}

		# set AMS location
		$amsLocationOld = $_.location
		$monitorVnet = (get-resourceComponents $_.properties.monitorSubnet).mainResourceName

		# AMS vnet is peered
		if ($monitorVnet -in $script:peeredVnets) {
			# change VNET location
			write-logFileUpdates 'sapMonitors' '<amsInstanceName>' 'set location' $amsLocationOld
			update-vnetLocation $monitorVnet $amsLocationOld
		}

		# AMS vnet is not peered
		else {
			# change AMS location
			write-logFileUpdates 'sapMonitors' '<amsInstanceName>' 'set location' $targetLocation
			$_.location = $targetLocation
		}

		$script:amsLocationNew = $_.location
	}

	# no AMS instance found
	if ($i -eq 0) {
		$script:resourcesAMS = @()
		return
	}

	# Module installed?
	if ($amsUsePowerShell) {
		$azHoaVersion = (Get-InstalledModule Az.HanaOnAzure -MinimumVersion 0.3 -ErrorAction 'SilentlyContinue')
		if ($azHoaVersion.count -eq 0) {
			write-logFileError 'Minimum required version of module Az.HanaOnAzure is 0.3' `
								'Run "Install-Module -Name Az.HanaOnAzure -AllowClobber" to install or update'
		}
	}

	# AMS not supported in region
	$amsLocationDisplayName = (Get-AzLocation | Where-Object Location -eq $script:amsLocationNew).DisplayName
	if ($amsLocationDisplayName -notin $locationsAMS) {
		write-logFileWarning "AMS not supported in region $script:amsLocationNew ($amsLocationDisplayName)"
		write-logFileWarning "Update source RG $sourceRG`: Use Network Peering and locate AMS in a peered, supported region"
		$script:resourcesAMS = @()
		return
	}

	# rename AMS providers
	$script:resourcesAMS
	| Where-Object type -eq 'Microsoft.HanaOnAzure/sapMonitors/providerInstances'
	| ForEach-Object  {

		$x, $providerName = $_.name -split '/'
		$_.name = "[concat(parameters('amsInstanceName'),'/$providerName')]"

		[array] $_.dependsOn = get-resourceFunction `
								'Microsoft.HanaOnAzure' `
								'sapMonitors'	"parameters('amsInstanceName')"
	}

	# set HANA/SQL password
	$script:resourcesAMS
	| Where-Object type -eq 'Microsoft.HanaOnAzure/sapMonitors/providerInstances'
	| Where-Object {$_.properties.type -in ('SapHana','MsSqlServer')}
	| ForEach-Object  {

		if ($amsUsePowerShell) {
			$dbPass = ''
		}
		elseif ($dbPassword.Length -eq 0) {
			write-logFileWarning "RGCOPY parameter 'dbPassword' missing for AMS provider type $($_.properties.type)"
			$dbPass = ''
		}
		else {
			write-logFileWarning "RGCOPY parameter 'dbPassword' stored as plain text in ARM template"
			$dbPass = ConvertFrom-SecureString -SecureString $dbPassword -AsPlainText
		}

		if ($dbPass -like '*"*') {
			write-logFileWarning "RGCOPY parameter 'dbPassword' must not contain double quotes (`")"
			$dbPass = ''
		}

		$instanceProperty = get-amsProviderProperty $_.properties.properties
		if ($_.properties.type -eq 'SapHana')		{$instanceProperty.hanaDbPassword = $dbPass}
		if ($_.properties.type -eq 'MsSqlServer')	{$instanceProperty.sqlPassword = $dbPass}
		$_.properties.properties = set-amsProviderProperty $instanceProperty

		$metadata = get-amsProviderProperty $_.properties.metadata
		if ($metadata.count -ne 0)					{$_.properties.metadata = set-amsProviderProperty $metadata}
	}

	# set parameters
	$templateParameters = @{
		amsInstanceName = @{
			defaultValue	= "[concat('ams-',toLower(take(concat(replace(replace(replace(replace(replace(resourceGroup().name,'_',''),'-',''),'.',''),'(',''),')',''),'4rgcopy'),24)))]"
			type			= 'String'
		}
	}
	write-logFileUpdates 'template parameter' '<amsInstanceName>' 'create' '' '' '(in AMS template)'

	# create template
	$script:amsTemplate = @{
		contentVersion	= '1.0.0.0'
		parameters		= $templateParameters
		resources		= $script:resourcesAMS
	}
	$script:amsTemplate.Add('$schema', "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#")
}

#--------------------------------------------------------------
function new-amsProviders {
#--------------------------------------------------------------
	# get providers from AMS template
	$script:resourcesAMS
	| Where-Object type -eq 'Microsoft.HanaOnAzure/sapMonitors/providerInstances'
	| ForEach-Object  {

		$providerType = $_.properties.type
		$providerName = $_.name

		if ($providerType -in $script:supportedProviders) {

			# provider name using ARM template variable
			if ($providerName[0] -eq '[') {

				[array] $a = $providerName -split '\)'
				if ($a.count -gt 1) {
					[array] $b = $a[1] -split "'"
					if ($b.count -gt 1) {
						[array] $c = $b[1] -split '/'
						if ($c.count -gt 1) {
							$providerName = $c[1]
						}
						else {
							write-logFileError "Invalid ARM template for AMS provider" `
												"Invalid provider name '$providerName'" 
						}
					}
				}
			}
			# provider name as plain text: <instanceName>/<providerName>
			else {
				[array] $a = $providerName -split '/'
				if ($a.count -gt 1) {
					$providerName = $a[1]
				}
				else {
					write-logFileError "Invalid ARM template for AMS provider" `
										"Invalid provider name '$providerName'"
				}
			}

			$parameter = @{
				ResourceGroupName	= $targetRG
				SapMonitorName 		= $amsInstanceName
				Name				= $providerName
				ProviderType		= $providerType
			}

			# get instance properties
			$instanceProperty = get-amsProviderProperty $_.properties.properties
			if ($providerType -in ('SapHana','MsSqlServer')) {
				if ($dbPassword.Length -eq 0) {
					write-logFileWarning "Resource Group contains AMS provider type $providerType, but RGCOPY parameter 'dbPassword' is misssing"
					$dbPass = ''
				}
				else {
					$dbPass = ConvertFrom-SecureString -SecureString $dbPassword -AsPlainText
				}
				if ($providerType -eq 'SapHana') {
					$instanceProperty.hanaDbPassword = $dbPass
				}
				if ($providerType -eq 'MsSqlServer') {
					$instanceProperty.sqlPassword = $dbPass
				}
			}
			$parameter.Add('InstanceProperty', $instanceProperty)

			# get instance meta data
			$metadata = get-amsProviderProperty $_.properties.metadata
			if ($metadata.count -ne 0) {
				$parameter.Add('Metadata', $metadata)
			}

			Write-Output  "Creating AMS Provider '$providerName' ..."
			write-logFileHashTable $parameter

			# create AMS Provider
			$res = New-AzSapMonitorProviderInstance @parameter
			if ($res.ProvisioningState -ne 'Succeeded') {
				write-logFileError "Creation of AMS Provider '$providerName' failed" `
									"Check the Azure Activity Log in resource group $targetRG"
			}
		}
	}
}

#--------------------------------------------------------------
function new-amsInstance {
#--------------------------------------------------------------
	$parameter = @{
		ResourceGroupName		= $targetRG
		Name 					= $amsInstanceName
		ErrorAction				= 'SilentlyContinue'
		ErrorVariable			= '+myDeploymentError'
	}

	# get parameters from AMS template (single AMS instance)
	$script:resourcesAMS
	| Where-Object type -eq 'Microsoft.HanaOnAzure/sapMonitors'
	| ForEach-Object {

		if ($_.properties.enableCustomerAnalytics -eq $True) {
			$parameter.EnableCustomerAnalytic = $True
		}

		$parameter.Location = $_.location

		$r = get-resourceComponents $_.properties.monitorSubnet
		$parameter.MonitorSubnet = get-resourceString `
										$targetSubID		$targetRG `
										'Microsoft.Network' `
										'virtualNetworks'	$r.mainResourceName `
										'subnets'			$r.subResourceName

		$wsID = $_.properties.logAnalyticsWorkspaceArmId
		if ($Null -ne $wsID) {

			$r = get-resourceComponents $wsID
			$wsName = $r.mainResourceName
			$wsRG	= $r.resourceGroup

			$ws = Get-AzOperationalInsightsWorkspace `
					-ResourceGroupName $wsRG `
					-Name $wsName

			$wsKey = Get-AzOperationalInsightsWorkspaceSharedKey `
						-ResourceGroupName $wsRG `
						-Name $wsName

			$parameter.Add('LogAnalyticsWorkspaceSharedKey',	$wsKey.PrimarySharedKey)
			$parameter.Add('LogAnalyticsWorkspaceId', 			$ws.CustomerId)
			$parameter.Add('LogAnalyticsWorkspaceResourceId',	$ws.ResourceId)
		}
	}

	write-logFile  "Creating AMS Instance '$amsInstanceName' ..."
	write-logFileHashTable $parameter

	# create AMS Instance
	$res = New-AzSapMonitor @parameter
	if ($res.ProvisioningState -ne 'Succeeded') {

		$NewName = get-NewName $amsInstanceName 30
		write-logFile $myDeploymentError -ForegroundColor 'Yellow'
		write-logFile
		write-logFile "Repeat failed deployment using AMS instance name '$NewName'..."
		write-logFile

		# repeat deployment
		$parameter.Name			= $NewName
		$script:amsInstanceName = $NewName
		$res = New-AzSapMonitor @parameter
		if ($res.ProvisioningState -ne 'Succeeded') {
			write-logFile $myDeploymentError -ForegroundColor 'Yellow'
			write-logFile
			write-logFileError "Creation of AMS Instance '$amsInstanceName' failed" `
								"Check the Azure Activity Log in resource group $targetRG"
		}
	}
}

#--------------------------------------------------------------
function get-NewName {
#--------------------------------------------------------------
	param (
		$name,
		$maxLength
	)

	# just add "2" if length is sufficient
	if ($name.length -lt $maxLength) {
		return "$name`2"
	}

	# left string with length $maxLength - 1
	$len = (($maxLength - 1), $name.Length | Measure-Object -Minimum).Minimum
	$partName = $name.SubString(0,$len)

	# add  "2"
	if ("$partName`2" -ne $name) {
		return "$partName`2"
	}
	# replace last char: "2" with "3" if adding is not possible
	else {
		return "$partName`3"
	}
}

#--------------------------------------------------------------
function remove-amsInstance {
#--------------------------------------------------------------
	param (
		$resourceGroup
	)

	$ams = Get-AzSapMonitor -ErrorAction 'SilentlyContinue'
	test-azResult 'Get-AzSapMonitor'  "Could not get AMS instances"
	
	$ams | ForEach-Object {
		$amsName = $_.Name
		$ids = $_.Id -split '/'
		if ($ids.count -gt 4) {
			$amsRG = $ids[4]
			if ($amsRG -eq $resourceGroup) {
				write-logFile "Removing AMS instance '$amsName'..."

				Remove-AzSapMonitor `
					-Name 				$amsName `
					-ResourceGroupName	$amsRG `
					-ErrorAction		'SilentlyContinue'
				test-azResult 'Remove-AzSapMonitor'  "Could not delete AMS instance '$amsName'" 
			}
		}
	}
	write-logFile
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
			write-logFileError 	"Invalid ARM template: '$pathArmTemplate'" `
								"ARM template parameter '$paramName' is missing" `
								"Remove parameter 'setGroupTipSession' or use an ARM template that contains TiP group $group"
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

	write-stepStart "Deploy ARM template $DeploymentPath"

	$parameter = @{
		ResourceGroupName	= $targetRG
		Name				= $DeploymentName
		TemplateFile		= $DeploymentPath
		ErrorAction			= 'SilentlyContinue'
		ErrorVariable		= '+myDeploymentError'
	}

	# save ARM template parameters
	$armTemplate = (Get-Content -Path $DeploymentPath) | ConvertFrom-Json -Depth 20 -AsHashtable
	$script:availableParameters = @()
	if ($Null -ne $armTemplate.parameters) {
		[array] $script:availableParameters = $armTemplate.parameters.GetEnumerator().Name
	}
	# save variables
	$script:templateVariables = $armTemplate.variables

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
function deploy-templateTargetAms {
#--------------------------------------------------------------
	param (
		$DeploymentPath,
		$DeploymentName
	)

	# deploy using ARM template
	write-logFile "Deploying ARM template '$DeploymentPath'..."

	$parameter = @{
		ResourceGroupName	= $targetRG
		Name				= $DeploymentName
		TemplateFile		= $DeploymentPath
		ErrorAction			= 'SilentlyContinue'
		ErrorVariable		= '+myDeploymentError'
	}
	# add template parameter
	$parameter.TemplateParameterObject = @{ amsInstanceName = $amsInstanceName }

	# display ARM deployment parameters
	write-logFileHashTable $parameter

	# deploy
	New-AzResourceGroupDeployment @parameter
	| write-LogFilePipe
	if (!$?) {
		$NewName = get-NewName $amsInstanceName 30
		write-logFile $myDeploymentError -ForegroundColor 'Yellow'
		write-logFile
		write-logFile "Repeating failed deployment using AMS instance name '$NewName'..."
		write-logFile

		# repeat deployment
		$parameter.TemplateParameterObject 	=  @{ amsInstanceName = $NewName }
		$parameter.name 					= "$DeploymentName`2"
		New-AzResourceGroupDeployment @parameter
		| write-LogFilePipe
		if (!$?) {
			write-logFile $myDeploymentError -ForegroundColor 'yellow'
			write-logFileError "AMS deployment '$DeploymentName' failed" `
								"Check the Azure Activity Log in resource group $targetRG"
		}
	}
}

#--------------------------------------------------------------
function deploy-sapMonitor {
#--------------------------------------------------------------
	if ($installExtensionsSapMonitor.count -eq 0) { return }

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
		$VMs
	)

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
	$VMs
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
function get-pathFromTags {
#--------------------------------------------------------------
	param (
		$vmName,
		$tagName,
		$tagValue, 
		[ref] $refPath,
		$paramName
	)

	if ($tagValue.length -ne 0) {
		if (($refPath.Value.length -eq 0) -and !$ignoreTags) {
			$refPath.Value = $tagValue
		}
		else {
			$paramName = ''
		}

		$script:rgcopyTags += @{
			vmName		= $vmName
			tagName		= $tagName
			paramName	= $paramName
			value		= $tagValue
		}
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

		# updates variables from tags
		get-pathFromTags $vmName $azTagScriptStartSap      $tags.$azTagScriptStartSap      ([ref] $script:scriptStartSapPath)      'scriptStartSapPath'
		get-pathFromTags $vmName $azTagScriptStartLoad     $tags.$azTagScriptStartLoad     ([ref] $script:scriptStartLoadPath)     'scriptStartLoadPath'
		get-pathFromTags $vmName $azTagScriptStartAnalysis $tags.$azTagScriptStartAnalysis ([ref] $script:scriptStartAnalysisPath) 'scriptStartAnalysisPath'

		# tag azTagSapMonitor
		if ($tags.$azTagSapMonitor.length -ne 0) {
			if (($tags.$azTagSapMonitor -eq 'true') `
			-and ($script:installExtensionsSapMonitor.count -eq 0) `
			-and !$ignoreTags ) {
				$paramName = 'installExtensionsSapMonitor'
			}
			else {
				$paramName = ''
			}

			$vmsFromTag += $vmName

			$script:rgcopyTags += @{
				vmName		= $vmName
				tagName		= $azTagSapMonitor
				paramName	= $paramName
				value		= 'true'
			}
		}

		# tag azTagTipGroup
		$tipGroup = $tags.$azTagTipGroup -as [int]
		if ($tipGroup -gt 0) {
			if (($setVmTipGroup.count -eq 0) -and !$ignoreTags ) {
				$paramName = 'setVmTipGroup'
			}
			else {
				$paramName = ''
			}

			$script:rgcopyTags += @{
				vmName		= $vmName
				tagName		= $azTagTipGroup
				paramName	= $paramName
				value		= $tipGroup
			}
		}

		# tag azTagDeploymentOrder
		$priority = $tags.$azTagDeploymentOrder -as [int]
		if ($priority -gt 0) {
			if (($setVmDeploymentOrder.count -eq 0) -and !$ignoreTags ) {
				$paramName = 'setVmDeploymentOrder'
			}
			else {
				$paramName = ''
			}

			$script:rgcopyTags += @{
				vmName		= $vmName
				tagName		= $azTagDeploymentOrder
				paramName	= $paramName
				value		= $priority
			}
		}
	}

	if ($script:installExtensionsSapMonitor.count -eq 0) {
		$script:installExtensionsSapMonitor = $vmsFromTag
	}

	$script:rgcopyTags
	| Sort-Object vmName, tagName
	| Select-Object vmName, tagName, paramName, value
	| Format-Table
	| write-LogFilePipe

	if ($script:rgcopyTags.count -eq 0) {
		write-logFile "No RGCOPY tags found"
	}
	elseif ($ignoreTags) {
		write-logFileWarning "Tags ignored because parameter 'ignoreTags' or 'setVmMerge' was set"
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
		write-logFile "Storage Account '$mySA' in Resource Group '$myRG' does not exist"
		write-logFile
		return
	}

	Remove-AzStorageAccount `
		-ResourceGroupName	$myRG `
		-AccountName		$mySA `
		-Force
	test-azResult 'Remove-AzStorageAccount'  "Could not delete storage account $mySA"

	write-logFileWarning "Storage Account '$mySA' in Resource Group '$myRG' deleted"
	write-logFile
}

#--------------------------------------------------------------
function new-storageAccount {
#--------------------------------------------------------------
	param (
		$mySub,
		$myRG,
		$mySA,
		$myLocation
	)

	# Backups are stored zone redundant, as cheap as possibe
	# Cool for backups does not really help: PageBlob must be Hot
	if ($archiveMode) {
		$SkuName	= 'Standard_ZRS'
		$Kind		= 'StorageV2'
		$accessTier = 'Cool'
	}
	# SMB Share as fast Premium
	# locally redundant should be sufficient for temporary data
	elseif (($smbTier -eq 'Premium_LRS') -and ($mySA -eq $sourceSA)) {
		$SkuName	= 'Premium_LRS'
		$Kind		= 'FileStorage'
		$accessTier	= 'Hot'
	}
	# BLOB is almost always remote: Standard should be sufficient
	# locally redundant should be sufficient for temporary data
	else {
		$SkuName	= 'Standard_LRS'
		$Kind		= 'StorageV2'
		$accessTier = 'Hot'
	}
	
	$savedSub = $script:currentSub
	set-context $mySub # *** CHANGE SUBSCRIPTION **************

	# Create Storage Account
	Get-AzStorageAccount `
		-ResourceGroupName 	$myRG `
		-Name 				$mySA `
		-ErrorAction 'SilentlyContinue' | Out-Null
	if ($?) {
		write-logFileTab 'Storage Account' $mySA 'already exists'
	}
	else {
		New-AzStorageAccount `
			-ResourceGroupName	$myRG `
			-Name				$mySA `
			-Location			$myLocation `
			-SkuName 			$SkuName `
			-Kind				$Kind `
			-AccessTier			$accessTier `
			-ErrorAction 'SilentlyContinue' | Out-Null
		test-azResult 'New-AzStorageAccount'  "The storage account name must be unique in whole Azure" `
						"Retry with other values of parameter 'targetRG' or 'targetSA'"

		write-logFileTab 'Storage Account' $mySA 'created'
	}

	# Create Target Container
	if ($mySA -eq $targetSA) {
		Get-AzRmStorageContainer `
			-ResourceGroupName	$myRG `
			-AccountName		$mySA `
			-ContainerName		$targetSaContainer `
			-ErrorAction 'SilentlyContinue' | Out-Null
		if ($?) {
			if ( ($archiveMode) `
			-and (!$archiveContainerOverwrite) `
			-and (!$restartBlobs) `
			-and (!$justCopyBlobs) ) {
				write-logFileError "Container '$targetSaContainer' already exists" `
									"Existing archive might be overwritten" `
									"Use RGCOPY switch 'archiveContainerOverwrite' for allowing this"
			}
			else {
				write-logFileTab 'Container' $targetSaContainer 'already exists'
			}
		}
		else {
			New-AzRmStorageContainer `
				-ResourceGroupName	$myRG `
				-AccountName		$mySA `
				-ContainerName		$targetSaContainer `
				-ErrorAction 'SilentlyContinue' | Out-Null
			test-azResult 'New-AzRmStorageContainer'  "Could not create container $targetSaContainer"

			write-logFileTab 'Container' $targetSaContainer 'created'
		}
	}

	# Create Source Share
	if ($mySA -eq $sourceSA) {
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
				-QuotaGiB			5120 `
				-ErrorAction 'SilentlyContinue' | Out-Null
			test-azResult 'New-AzRmStorageShare'  "Could not create share $sourceSaShare"

			write-logFileTab 'Share' $sourceSaShare 'created'
		}
	}
	write-logFile
	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function new-resourceGroup {
#--------------------------------------------------------------
	if (!$skipDeployment -or !$skipBlobs) {

		$savedSub = $script:currentSub
		set-context $targetSub # *** CHANGE SUBSCRIPTION **************
		Get-AzResourceGroup `
			-Name 	$targetRG `
			-ErrorAction 'SilentlyContinue' | Out-Null
		if ($?) {
			write-logFileTab 'Resource Group' $targetRG 'already exists'
			if ( !$allowExistingDisks `
			-and ($setVmMerge.count -eq 0) `
			-and !$skipDeploymentVMs `
			-and !$archiveMode `
			-and !$enableSourceRgMode ) {

				# Get target disks
				$disksTarget = Get-AzDisk `
									-ResourceGroupName $targetRG `
									-ErrorAction 'SilentlyContinue'
				test-azResult 'Get-AzDisk'  "Could not get disks of resource group '$targetRG'" 
	
				# check if targetRG already contains disks
				if ($disksTarget.count -ne 0) {
					write-logFileError "Target resource group '$targetRG' already contains resources (disks)" `
										"This is only allowed when parameter 'setVmMerge' is used" `
										"You can skip this check using RGCOPY parameter switch 'allowExistingDisks'"
				}
			}
		}
		elseif ($setVmMerge.count -ne 0) {
			write-logFileError "Invalid parameter 'setVmMerge'" `
								"This parameter can only be used for merging into an existing resource group" `
								"Target resource group '$targetRG' does not exist"
		}
		else {
			$tag = @{ Created_by = 'rgcopy.ps1' }
			if ($Null -ne $setOwner)	{ $tag.Add('Owner', $setOwner) }

			New-AzResourceGroup `
				-Name 		$targetRG `
				-Location	$targetLocation `
				-Tag 		$tag `
				-ErrorAction 'SilentlyContinue' | Out-Null
			test-azResult 'New-AzResourceGroup'  "Could not create resource Group $targetRG"

			write-logFileTab 'Resource Group' $targetRG 'created'
		}
		set-context $savedSub # *** CHANGE SUBSCRIPTION **************
	}

	if (!$skipBlobs) {
		new-storageAccount $targetSub $targetRG $targetSA $targetLocation
	}
}

#--------------------------------------------------------------
function invoke-mountPoint {
#--------------------------------------------------------------
	param (
		$resourceGroup,
		$scriptVm,
		$scriptName,
		$scriptParam
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
	if ($scriptParam.length -ne 0) {
		$parameter.Add('Parameter', @{arg1 = $scriptParam})
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

	write-stepStart "CHECK STATUS OF BACKGROUND JOBS (every $waitBlobsTimeSec seconds)"
	$firstLoop = $True
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

		if (!$done) { Start-Sleep -seconds $waitBlobsTimeSec }
	} while (!$done)
	write-stepEnd
}

#--------------------------------------------------------------
function backup-mountPoint {
#--------------------------------------------------------------
$scriptFunction = @'
#!/bin/bash
storageAccountKey=$1

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

	# mount share /mnt/rgcopy
	mkdir -p /mnt/rgcopy
	echo umount -f /mnt/rgcopy
	umount -f /mnt/rgcopy
	echo mount -t cifs "//$storageAccount.file.core.windows.net/rgcopy" /mnt/rgcopy -o "vers=3.0,username=$storageAccount,password=xxx,dir_mode=0777,file_mode=0777,serverino"
	mount -t cifs "//$storageAccount.file.core.windows.net/rgcopy" /mnt/rgcopy -o "vers=3.0,username=$storageAccount,password=$storageAccountKey,dir_mode=0777,file_mode=0777,serverino"
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

	write-stepStart "BACKUP VOLUMES/DISKS to SMB share"
	write-logFile "SMB Share for volume backups:"
	write-logFileTab 'Resource Group' $sourceRG
	new-storageAccount $sourceSub $sourceRG $sourceSA $sourceLocation
	$script:sourceSaKey = get-saKey $sourceSub $sourceRG $sourceSA

	$script:runningTasks = @()
	$script:copyVMs.values
	| Where-Object {$_.MountPoints.count -ne 0}
	| ForEach-Object {

		$vmName = $_.Name
		write-logFile
		write-logFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz')
		write-logFile "Backup volumes/disks of VM $vmName`:"
		wait-vmAgent $sourceRG $vmName 'BACKUP VOLUMES/DISKS to SMB share'

		# save running Tasks
		$script:runningTasks += @{
			vmName 		= $vmName
			mountPoints	= $_.MountPoints.Path
			action		= 'backup'
			finished 	= $False
		}

		# run shell script
		$script = $scriptFunction + "backup $sourceSA $vmName " + $_.MountPoints.Path
		$rc = invoke-mountPoint $sourceRG $vmName $script $sourceSaKey
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
	$script:sourceSaKey = get-saKey $Sub $RG $SA

$script1 = @'
#!/bin/bash
storageAccountKey=$1

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

	# mount share /mnt/rgcopy
	mkdir -p /mnt/rgcopy
	echo umount -f /mnt/rgcopy
	umount -f /mnt/rgcopy
	echo mount -t cifs "//$storageAccount.file.core.windows.net/rgcopy" /mnt/rgcopy -o "vers=3.0,username=$storageAccount,password=xxx,dir_mode=0777,file_mode=0777,serverino"
	mount -t cifs "//$storageAccount.file.core.windows.net/rgcopy" /mnt/rgcopy -o "vers=3.0,username=$storageAccount,password=$storageAccountKey,dir_mode=0777,file_mode=0777,serverino"
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
			echo $nfsVolume $mountPoint nfs4 rw,hard,rsize=1048576,wsize=1048576,sec=sys,vers=4.1,tcp 0 0 >>/etc/fstab
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

	write-stepStart 'RESTORE VOLUMES/DISKS from SMB share'
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
		wait-vmAgent $targetRG $vmName 'RESTORE VOLUMES/DISKS from SMB share'

		$rc = invoke-mountPoint $targetRG $vmName $script $sourceSaKey
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
		test-azResult 'Get-AzProviderFeature'  'Getting subscription features failed' -always
	}

	# check TiP parameters
	if ($subProp -lt 2) {
		if (($setGroupTipSession.count -ne 0) -or ($setVmTipGroup.count -ne 0)) {
			write-logFileWarning 'Target Subscription is not TiP enabled' -stopAtWarning
		}
		$script:tipEnabled = $False
	}
	else {
		$script:tipEnabled = $True
	}
}

#--------------------------------------------------------------
function test-justRedeployAms {
#--------------------------------------------------------------
	if (!$justRedeployAms) { return }

	# required steps:
	$script:skipSnapshots		= $True
	$script:skipBlobs			= $True
	$script:skipDeploymentVMs	= $True
	$script:skipExtensions		= $True
	$script:createArmTemplateAms = $True
	$script:skipArmTemplate 	= $False

	# forbidden parameters:
	write-logFileForbidden 'justRedeployAms' @(
		'amsWsKeep', 'amsWsName', 'amsWsRG',
		'skipDeployment',
		'updateMode', 'archiveMode',
		'justCreateSnapshots', 'justDeleteSnapshots',
		'skipArmTemplate',
		'createVolumes', 'createDisks','stopRestore', 'continueRestore',
		'startWorkload', 'deleteTargetSA', 'deleteSourceSA')


	# DB password needed for HANA and SQL Server AMS provider
	if ($dbPassword.Length -eq 0) {
		write-logFileWarning "parameter 'dbPassword' missing. It might be needed for AMS"
		write-logFile
	}
}

#-------------------------------------------------------------
function test-archiveMode {
#-------------------------------------------------------------
	if (!$archiveMode) { return }

	if ($skipVMs.count -eq 0) {
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
	$script:useBlobs			= $True
	$script:blobsRG				= $targetRG
	$script:blobsSA				= $targetSA
	$script:blobsSaContainer	= $archiveContainer
	$script:targetSaContainer	= $archiveContainer
	$script:copyDetachedDisks	= $True

	# forbidden parameters:
	write-logFileForbidden 'archiveMode' @(
		'updateMode', 
		'justCreateSnapshots', 'justDeleteSnapshots', 'justRedeployAms',
		'pathArmTemplate', 'skipArmTemplate',
		'createVolumes', 'createDisks','stopRestore', 'continueRestore',
		'startWorkload', 'deleteTargetSA', 'deleteSourceSA', 'stopVMsTargetRG',
		'skipDisks', 'setVmMerge', 'setVmName')
	
	if (('skipBlobs' -in $boundParameterNames) -or ('skipSnapshots' -in $boundParameterNames)) {
		write-logFileWarning "parameters 'skipBlobs' or 'skipSnapshots' are set" `
								"You might not be able to restore the archived resource group"

	}
}

#-------------------------------------------------------------
function test-justCopyBlobs {
#-------------------------------------------------------------
	if ($justCopyBlobs.count -eq 0) { return }

	# required steps:
	$script:skipArmTemplate		= $True
	$script:skipSnapshots		= $True
	$script:skipDeployment 		= $True

	# required settings:
	$script:useBlobs			= $True

	# forbidden parameters:
	write-logFileForbidden 'justCopyBlobs' @(
		'updateMode', 
		'justCreateSnapshots', 'justDeleteSnapshots', 'justRedeployAms',
		'pathArmTemplate',
		'createVolumes', 'createDisks','stopRestore', 'continueRestore',
		'stopVMsTargetRG', 'stopVMsSourceRG', 'deleteSnapshots',
		'startWorkload','deleteTargetSA', 'deleteSourceSA',
		'skipBlobs')
}

#--------------------------------------------------------------
function test-restartBlobs {
#--------------------------------------------------------------
	if (!$restartBlobs) { return }

	# required steps:
	$script:skipArmTemplate		= $True
	$script:skipSnapshots		= $True

	# required settings:
	$script:useBlobs			= $True

	# forbidden parameters:
	write-logFileForbidden 'restartBlobs' @(
		'updateMode', 
		'justCreateSnapshots', 'justDeleteSnapshots', 'justRedeployAms',
		'pathArmTemplate',
		'skipBlobs')
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
		$script:skipBlobs			= $True
		$script:skipDeploymentVMs	= $True

		# forbidden parameters:
		write-logFileForbidden 'continueRestore' @(
			'updateMode', 'archiveMode',
			'justCreateSnapshots', 'justDeleteSnapshots', 'justRedeployAms',
			'restartBlobs', 'justCopyBlobs', 'justStopCopyBlobs',
			'stopRestore')
	}
	# parameter stopRestore (skip everything after deployment)
	elseif ($stopRestore) {

		# required steps:
		$script:skipRestore			= $True
		$script:skipExtensions		= $True
		$script:skipCleanup			= $True

		# forbidden parameters:
		write-logFileForbidden 'stopRestore' @(
			'updateMode', 'archiveMode',
			'justCreateSnapshots', 'justDeleteSnapshots', 'justRedeployAms',
			'restartBlobs', 'justCopyBlobs', 'justStopCopyBlobs',
			'continueRestore', 'startWorkload',
			'deleteSourceSA')
	}
}

#--------------------------------------------------------------
function test-setVmMerge {
#--------------------------------------------------------------
	if ($script:setVmMerge.count -eq 0) { return }

	# required settings:
	$script:ignoreTags 				= $True

	# forbidden parameters:
	write-logFileForbidden 'setVmMerge' @(
		'pathArmTemplate', 'pathArmTemplateAms', 'createArmTemplateAms', 'skipArmTemplate',
		'startWorkload',
		'skipVMs', 'skipDisks','stopVMsTargetRG')
}

#-------------------------------------------------------------
function update-paramDeleteSnapshots {
#-------------------------------------------------------------
	$snapshotsAll = Get-AzSnapshot `
						-ResourceGroupName $sourceRG `
						-ErrorAction 'SilentlyContinue'
	test-azResult 'Get-AzSnapshot'  "Could not get snapshots of resource group $sourceRG" 

	if ($deleteSnapshotsAll) {
		$script:snapshots2remove = $snapshotsAll
	}
	elseif ($deleteSnapshots) {
		$script:snapshots2remove = $snapshotsAll | Where-Object Name -like "*.$snapshotExtension"
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
	test-azResult 'Get-AzNetAppFilesAccount'  "Could not get NetApp Accounts of resource group '$sourceRG'"

	foreach ($account in $allAccounts) {
		$accountName = $account.Name

		# collect all pool (names)
		$pools = Get-AzNetAppFilesPool `
					-ResourceGroupName	$sourceRG `
					-AccountName		$accountName `
					-ErrorAction 		'SilentlyContinue'
		test-azResult 'Get-AzNetAppFilesPool'  "Could not get NetApp Pools of account '$accountName'"

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
			test-azResult 'Get-AzNetAppFilesVolume'  "Could not get NetApp Volumes of pool '$poolName'"
			
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
	# forbidden parameters:
	write-logFileForbidden 'updateMode' @(
		'setVmMerge', 'GeneralizedVMs',
		'SnapshotVolumes', 'CreateVolumes', 'CreateDisks',
		'SetVmDeploymentOrder', 'SetVmTipGroup', 'SetVmName',
		'skipDisks', 'skipVMs')

	write-stepStart "Expected changes in resource group '$sourceRG'"
	# required order:
	# 1. setVmSize
	update-paramSetVmSize

	# 2. setDiskSku
	update-paramSetDiskSku

	# 3. setDiskSize (and setDiskTier)
	update-paramSetDiskSize
	update-paramSetDiskBursting
	update-paramSetDiskMaxShares

	# 4. setDiskCaching
	update-paramSetDiskCaching

	# 5. setAcceleratedNetworking
	update-paramSetAcceleratedNetworking

	# 6. rest
	update-paramCreateBastion
	update-paramDeleteSnapshots
	update-parameterNetAppServiceLevel
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
		-or ('setNetAppServiceLevel' -in $boundParameterNames) `
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

		write-logFile "Steps before updating VMs:"
		update-sourceDisks -beforeVmUpdate
		update-sourceNICs -beforeVmUpdate

		write-logFile
		write-logFile "Updating VMs:"
		update-sourceVMs

		write-logFile
		write-logFile "Steps after updating VMs:"
		update-sourceDisks
		update-sourceNICs

		write-logFile
		update-sourceBastion
		write-logFile

		update-netAppServiceLevel
		write-stepEnd
	
		# remove snapshots
		if ($script:snapshots2remove.count -ne 0) {
			remove-snapshots $script:snapshots2remove
		}
	}
}

#-------------------------------------------------------------
function update-netAppServiceLevel {
#-------------------------------------------------------------
	if ($script:allMoves.Values.count -eq 0) {
		write-logFile 'No update of any NetApp volume needed'
		return
	}

	$script:allMoves.Values
	| Sort-Object size
	| ForEach-Object {

		$newPoolName = $_.newPoolName

		# create pool
		write-logFile "Creating NetApp Pool '$newPoolName'..."
		$newPool = New-AzNetAppFilesPool `
					-ResourceGroupName	$sourceRG `
					-AccountName		$_.accountName `
					-Name				$newPoolName `
					-Location			$_.location `
					-ServiceLevel		$_.serviceLevel `
					-PoolSize			$_.size `
					-ErrorAction		'SilentlyContinue'
		test-azResult 'New-AzNetAppFilesPool'  "Could not create NetApp Pool '$newPoolName'"
		$poolID = $newPool.Id

		# move volumes
		foreach ($volumeNameLong in $_.volumes) {
			$accountName, $poolName, $volumeName = $volumeNameLong -split '/'
			write-logFile "Moving NetApp Voulume '$volumeName' to Pool '$newPoolName'..."
			Set-AzNetAppFilesVolumePool `
				-ResourceGroupName	$sourceRG `
				-AccountName		$accountName `
				-PoolName			$poolName `
				-Name				$volumeName `
				-NewPoolResourceId	$poolID `
				-ErrorAction		'SilentlyContinue' | Out-Null
			test-azResult 'Set-AzNetAppFilesVolumePool'  "Could not move NetApp Volume '$volumeName'"
		}

		# delete old pool
		if ($_.deleteOldPool -eq $True) {
			$poolName = $_.oldPoolName
			write-logFile "Deleting NetApp Pool '$poolName'..."
			Remove-AzNetAppFilesPool `
				-ResourceGroupName	$sourceRG `
				-AccountName		$_.accountName `
				-Name				$poolName `
				-ErrorAction		'SilentlyContinue' | Out-Null
			test-azResult 'Remove-AzNetAppFilesPool'  "Could not delete NetApp Pool '$poolName'"
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
			test-azResult 'Set-AzVMOsDisk'  "Colud not update VM '$vmName'"

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
				test-azResult 'Set-AzVMDataDisk'  "Colud not update VM '$vmName'"

				$updated = $True
			}
		}

		# perform update
		if ($updated) {
			$updatedAny = $True
			write-logFile "  Changing VM '$vmName' properties: $properties..."
			Update-AzVM -ResourceGroupName $sourceRG -VM $vm -ErrorAction 'SilentlyContinue' | Out-Null
			test-azResult 'Update-AzVM'  "Colud not update VM '$vmName'"
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
				test-azResult 'Update-AzDisk'  "Colud not update disk '$diskName'"
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
			$properties += 'performanceTier'
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
			test-azResult 'Update-AzDisk'  "Colud not update disk '$diskName'"

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
				test-azResult 'Update-AzDisk'  "Colud not update disk '$diskName'"  -always
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
				write-logFile "  Changing NIC '$nicName' $inRG property: Turning off Accelerated Networking"
				Set-AzNetworkInterface -NetworkInterface $nic -ErrorAction 'SilentlyContinue' | Out-Null
				test-azResult 'Set-AzNetworkInterface'  "Colud not update network interface '$nicName'" 
			}
			if (($newAcc -eq $True) -and !$beforeVmUpdate) {
				$nic.EnableAcceleratedNetworking = $newAcc
				$updatedAny = $True
				write-logFile "  Changing NIC '$nicName' $inRG property: Turning on Accelerated Networking"
				Set-AzNetworkInterface -NetworkInterface $nic -ErrorAction 'SilentlyContinue' | Out-Null
				test-azResult 'Set-AzNetworkInterface'  "Colud not update network interface '$nicName'" 
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

		# get vnet
		$vnet = Get-AzVirtualNetwork `
					-ResourceGroupName	$sourceRG `
					-Name				$script:bastionVnet `
					-ErrorAction		'SilentlyContinue'
		test-azResult 'Get-AzVirtualNetwork'  "Could not get VNET '$script:bastionVnet' of resource group '$sourceRG'"

		if ('AzureBastionSubnet' -in $vnet.Subnets.Name) {
			write-logFile "Subnet 'AzureBastionSubnet' already exists"
		}
		else {
			# add subnet
			write-logFile "Creating Subnet 'AzureBastionSubnet'..."
			Add-AzVirtualNetworkSubnetConfig `
				-Name 'AzureBastionSubnet' `
				-VirtualNetwork		$vnet `
				-AddressPrefix		$script:bastionAddressPrefix `
				-ErrorAction		'SilentlyContinue' | Out-Null
			test-azResult 'Add-AzVirtualNetworkSubnetConfig'  "Could not create subnet 'AzureBastionSubnet'"

			# save subnet
			$vnet | Set-AzVirtualNetwork -ErrorAction 'SilentlyContinue' | Out-Null
			test-azResult 'Set-AzVirtualNetwork'  "Could not create subnet 'AzureBastionSubnet' with prefix '$script:bastionAddressPrefix'"
		}

		$publicIP = Get-AzPublicIpAddress `
			-ResourceGroupName	$sourceRG `
			-name				'AzureBastionIP' `
			-ErrorAction		'SilentlyContinue'
		if ($?) {
			write-logFile "Public IP Address 'AzureBastionIP' already exists"
		}
		else {
			# create PublicIpAddress
			write-logFile "Creating Public IP Address 'AzureBastionIP'..."
			$publicIP = New-AzPublicIpAddress `
							-ResourceGroupName	$sourceRG `
							-name				'AzureBastionIP' `
							-location			$sourceLocation `
							-AllocationMethod	'Static' `
							-Sku				'Standard' `
							-ErrorAction		'SilentlyContinue'
			test-azResult 'New-AzPublicIpAddress'  "Could not create Public IP Address 'AzureBastionIP'"
		}

		# get vnet again (workaround for Bad Request issue)
		$vnet = Get-AzVirtualNetwork `
					-ResourceGroupName	$sourceRG `
					-Name				$script:bastionVnet `
					-ErrorAction		'SilentlyContinue'
		test-azResult 'Get-AzVirtualNetwork'  "Could not get VNET '$script:bastionVnet' of resource group '$sourceRG'"

		# create bastion
		write-logFile "Creating Bastion 'AzureBastion'..."
		New-AzBastion `
			-ResourceGroupName	$sourceRG `
			-Name				'AzureBastion' `
			-PublicIpAddress	$publicIP `
			-VirtualNetwork		$vnet `
			-Sku				'Basic' `
			-ErrorAction		'SilentlyContinue' | Out-Null
		test-azResult 'New-AzBastion'  "Could not create Bastion 'AzureBastion'"

	}
	# delete bastion
	elseif ($deleteBastion) {

		if ($Null -eq $script:sourceBastion.IpConfigurations) {
			write-logFile "There is no bastion to be deleted"
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
		write-logFile "Deleting Bastion '$bastionName'..."
		Remove-AzBastion `
			-ResourceGroupName	$sourceRG `
			-Name				$bastionName `
			-Force `
			-ErrorAction		'SilentlyContinue'
		test-azResult 'Remove-AzBastion'  "Could not delete Bastion '$bastionName' of resource group '$sourceRG'"

		# delete PublicIP
		write-logFile "Deleting Public IP Address '$bastionPublicIP'..."
		Remove-AzPublicIpAddress `
			-ResourceGroupName	$bastionPublicIpRG `
			-Name				$bastionPublicIP `
			-Force `
			-ErrorAction		'SilentlyContinue'
		test-azResult 'Remove-AzPublicIpAddress'  "Could not delete Public IP Address '$bastionPublicIP' of Bastion '$bastionName'"

		# get vnet
		write-logFile "Deleting Subnet 'AzureBastionSubnet'..."
		$vnet = Get-AzVirtualNetwork `
			-ResourceGroupName	$bastionVnetRG `
			-Name				$bastionVnet `
			-ErrorAction		'SilentlyContinue'
		test-azResult 'Get-AzVirtualNetwork'  "Could not get Bastion virtual network '$bastionVnet'"

		# remove subnet
		Remove-AzVirtualNetworkSubnetConfig `
			-Name 				'AzureBastionSubnet' `
			-VirtualNetwork		$vnet `
			-ErrorAction 		'SilentlyContinue'| Out-Null
		test-azResult 'Remove-AzVirtualNetworkSubnetConfig'  "Could not remove subnet 'AzureBastionSubnet'"

		# update vnet
		Set-AzVirtualNetwork `
			-VirtualNetwork		$vnet `
			-ErrorAction 		'SilentlyContinue'| Out-Null
		test-azResult 'Set-AzVirtualNetwork'  "Could not remove Subnet 'AzureBastionSubnet'"
	}
}

#-------------------------------------------------------------
function step-prepare {
#--------------------------------------------------------------
	if (!$justCreateSnapshots -and !$simulate) {
		new-resourceGroup
		write-logFile
	}

	if ($allowRunningVMs) {
		write-logFileWarning 'Parameter allowRunningVMs is set. This could result in inconsistent disk copies.'
		write-logFile
	}

	# get source VMs/Disks
	if (!$skipArmTemplate `
	-or !$skipSnapshots `
	-or ($useBlobs -and !$skipBlobs) ) {

		get-sourceVMs
		assert-vmsStopped
	}
}

#--------------------------------------------------------------
function step-armTemplate {
#--------------------------------------------------------------
	if ($skipArmTemplate) { return }

	#--------------------------------------------------------------
	write-stepStart "Create ARM templates"
	# create JSON template
	new-templateSource
	new-templateTarget # includes new-templateTargetAms
	write-logFile

	# write target ARM template to local file
	$text = $script:sourceTemplate | ConvertTo-Json -Depth 20
	Set-Content -Path $exportPath -Value $text -ErrorAction 'SilentlyContinue'
	if (!$?) {
		write-logFileError "Could not save Target ARM template" `
								"Failed writing file '$exportPath'"
	}
	write-logFile -ForegroundColor 'Cyan' "Target ARM template saved: $exportPath"
	$script:armTemplateFilePaths += $exportPath

	# special case: Redeployment of AMS with existing AMS template ($exportPathAms = $pathArmTemplateAms)
	if ($justRedeployAms -and ($pathArmTemplateAms.length -ne 0)) {
		write-logFile -ForegroundColor 'yellow' "Using given Azure Monitoring for SAP template: $exportPathAms"
	}
	# special case: Redeployment of AMS
	elseif ($justRedeployAms -and ($script:resourcesAMS.count -eq 0)) {
		write-logFileError "Invalid parameter 'justRedeployAms'" `
							"Resource group '$sourceRG' does not contain an AMS instance" `
							"You might use parameter 'pathArmTemplateAms' for supplying a given AMS template"
	}

	# write AMS template to local file
	elseif ($script:resourcesAMS.count -ne 0) {
		$text = $script:amsTemplate | ConvertTo-Json -Depth 20
		Set-Content -Path $exportPathAms -Value $text -ErrorAction 'SilentlyContinue'
		if (!$?) {
			write-logFileError "Could not save Azure Monitoring for SAP template" `
								"Failed writing file '$exportPathAms'"
		}
		write-logFile -ForegroundColor 'Cyan' "Azure Monitoring for SAP template saved: $exportPathAms"
		$script:armTemplateFilePaths += $exportPathAms
	}
	write-stepEnd

	#--------------------------------------------------------------
	if (!$justRedeployAms) {
		write-stepStart "Configured VMs/disks for Target Resource Group $targetRG"
		show-targetVMs
		compare-quota
		write-stepEnd
	}
}

#--------------------------------------------------------------
function step-snapshots {
#--------------------------------------------------------------
	write-logFileForbidden 'pathPreSnapshotScript' @('useBlobsFromDisk')	

	if (!$skipSnapshots) {
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

			# stop VMs
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
	elseif ($stopVMsSourceRG) {
		stop-VMs $sourceRG $script:sourceVMs
	}

	if (!$skipDeploymentVMs -or !$skipSnapshots) {
		show-snapshots
	}
}

#--------------------------------------------------------------
function step-backups {
#--------------------------------------------------------------
	if ($skipBackups -or ($script:mountPointsCount -eq 0)) { return }

	# simulate running Tasks for restartBlobs
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
	# simulate running Tasks for restartBlobs
	if ($restartBlobs) { return }
	$script:runningTasks = @()
	
	# start needed VMs (HANA and SAP must NOT auto-start)
	if ($script:toBeStartedVMs.count -ne 0) {
		write-stepStart "Start VMs before backup in Resource Group $sourceRG" $maxDOP
		start-VMsParallel $sourceRG $script:toBeStartedVMs
		write-stepEnd
	}

	# backup
	backup-mountPoint

	# wait for backup finished (if this is not done in step-blobs)
	if (!$useBlobs -or $skipBlobs) {
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
function step-blobs {
#--------------------------------------------------------------
	if (!$useBlobs -or $skipBlobs) { return }

	if (!$restartBlobs) {
		if ($archiveMode) { 
			# save RGCOPY PowerShell template
			$text = "# generated script by RGCOPY for restoring
`$param = @{
	sourceSubUser       = '$targetSubUser'
	
	# do not change:
	sourceSub           = '$targetSub'
	sourceRG            = '$targetRG'
	targetLocation      = '$targetLocation'

	# set targetRG:
	targetRG            = '$sourceRG'
	
	# set pathArmTemplate:
	pathArmTemplate     = '$exportPath'
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
		grant-access
		start-copyBlobs
	}
	wait-copyBlobs
	revoke-access

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
	if ($skipDeployment) { return }

	#--------------------------------------------------------------
	# Deploy Virtual Machines
	if (!$skipDeploymentVMs) {
		deploy-templateTarget $exportPath "$sourceRG.$timestampSuffix"
	}

	#--------------------------------------------------------------
	# Restore files
	if (!$skipRestore) { 
		restore-mountPoint
		# this sets $skipRestore = $True if there is nothing to restore
	}
	if (!$skipRestore) {
		wait-mountPoint
	}

	#--------------------------------------------------------------
	# Deploy Azure Monitor for SAP
	if ($exportPathAms -in $script:armTemplateFilePaths) {

		get-targetVMs
		#--------------------------------------------------------------
		# just re-deploy AMS (in source RG)
		if ($justRedeployAms) {

			# start VMs in the source RG
			if (!$skipStartSAP) {
				start-VMs $sourceRG
			}
			# start SAP in the source RG
			$done = start-sap $sourceRG
			if (!$done) {
				write-logFileError "Azure Monitor for SAP (AMS) could not be re-deployed because SAP is not running"
			}

			write-stepStart "Re-deploy AMS instance"
			# delete all AMS instances of source RG
			remove-amsInstance $sourceRG

			# rename AMS instance if parameter amsInstanceName was not supplied
			# avoid error: A vault with the same name already exists in deleted state.
			if ('amsInstanceName' -notin $boundParameterNames) {
				$script:amsInstanceName = get-NewName $script:amsInstanceName 30
			}
		}

		#--------------------------------------------------------------
		# normal AMS deployment (in target RG)
		else {

			# VMs already started in the target RG
			# start SAP in the target RG
			$done = start-sap $targetRG
			if (!$done) {
				write-logFileError "Azure Monitor for SAP (AMS) could not be deployed because SAP is not running"
			}
			write-stepStart "Deploy AMS instance"
		}

		#--------------------------------------------------------------
		# deploy using ARM template
		if (!$amsUsePowerShell) {
			deploy-templateTargetAms $exportPathAms "$sourceRG`-AMS.$timestampSuffix"
		}
		# deploy using cmdlets
		else {
			
			$text = Get-Content -Path $exportPathAms -ErrorAction 'SilentlyContinue'
			if (!$?) {
				write-logFileError "Could not read file '$DeploymentPath'"
			}
			$json = $text | ConvertFrom-Json -AsHashtable -Depth 20
			$script:resourcesAMS = $json.resources
			new-amsInstance
			new-amsProviders
		}
		# finish AMS deployment
		if ($justRedeployAms) {
			write-logFileWarning "All VMs in source resource group '$sourceRG' are still running"
		}
		write-stepEnd
	}

	#--------------------------------------------------------------
	# Deploy Extensions
	if (!$skipExtensions) {
		get-targetVMs
		deploy-sapMonitor
	}

	#--------------------------------------------------------------
	# run Post Deployment Script
	if ($pathPostDeploymentScript.length -ne 0) {
		get-targetVMs
		start-sap $targetRG | Out-Null
		invoke-localScript $pathPostDeploymentScript 'pathPostDeploymentScript'
	}
}

#--------------------------------------------------------------
function step-workload {
#--------------------------------------------------------------
	if (!$startWorkload) { return }

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
	if ($skipCleanup) { return }

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

	# delete snapshots in source RG
	if ($deleteSnapshots) {
		if ($skipSnapshots) {
			write-logFileWarning "parameter 'deleteSnapshots' ignored" `
								"The snapshots have not been created during the current run of RGCOPY" `
								"Re-run RGCOPY with parameter 'justDeleteSnapshots'"
		}
		else {
			set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
			remove-snapshots
		}
	}

	# delete storage account in source RG
	if ($deleteSourceSA) {
		if ($skipRestore) {
			write-logFileWarning "parameter 'deleteSourceSA' ignored" `
								"Storage account '$sourceSA' has not been used during the current run of RGCOPY" `
								"Delete the storage account manually'"
		}
		else {
			set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
			remove-storageAccount $sourceRG $sourceSA
		}
	}

	# delete storage account in target RG
	if ($deleteTargetSA) {
		if ($skipBlobs -or $skipDeployment -or $skipDeploymentVMs) {
			write-logFileWarning "parameter 'deleteTargetSA' ignored" `
								"Storage account '$targetSA' has not been used during the current run of RGCOPY" `
								"Delete the storage account manually'"
		}
		else {
			set-context $targetSub # *** CHANGE SUBSCRIPTION **************
			remove-storageAccount $targetRG $targetSA
			$script:totalBlobSize = 0
		}
	}
}

#**************************************************************
# Main program
#**************************************************************
[console]::ForegroundColor = 'Gray'
[console]::BackgroundColor = 'Black'
Clear-Host
$error.Clear()
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"
# clear log file
$Null *>$logPath
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

	$starCount = 70
	write-logFile ('*' * $starCount) -ForegroundColor DarkGray
	write-logFile 'https://github.com/Azure/RGCOPY ' -NoNewLine 
	write-logFile 'version ' -ForegroundColor DarkGray -NoNewLine
	write-logFile $rgcopyVersion -NoNewLine
	write-logFile $rgcopyMode.PadLeft($starCount - 40 - $rgcopyVersion.length) -ForegroundColor 'Yellow'
	write-logFile ('*' * $starCount) -ForegroundColor DarkGray
	write-logFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz') -ForegroundColor DarkGray
	$script:rgcopyParamOrig = $PSBoundParameters
	write-logFileHashTable $PSBoundParameters -rgcopyParam
	
	write-logFile -ForegroundColor 'Cyan' "Log file saved: $logPath"
	write-LogFile "For getting help, run:" -ForegroundColor DarkGray
	write-LogFile "Get-Help '$PSCommandPath' -Online" -ForegroundColor DarkGray
	if ($pathExportFolderNotFound.length -ne 0) {
		write-logFileWarning "provided path '$pathExportFolderNotFound' of parameter 'pathExportFolder' not found"
	}
	write-logFile

	Set-Content -Path $savedRgcopyPath -Value $text -ErrorAction 'SilentlyContinue'
	if (!$?) {
		write-logFileWarning "Could not save rgcopy backup '$savedRgcopyPath'" 
	}

	# processing only source RG
	write-logFileForbidden 'updateMode'				@('targetRG', 'targetLocation')
	write-logFileForbidden 'justCreateSnapshots'	@('targetRG', 'targetLocation')
	write-logFileForbidden 'justDeleteSnapshots'	@('targetRG', 'targetLocation')
	write-logFileForbidden 'justRedeployAms'		@('targetRG', 'targetLocation')

	# check name-parameter values
	test-names

	# Storage Account for disk creation
	if ($blobsRG.Length -eq 0)			{ $blobsRG = $targetRG }
	if ($blobsSA.Length -eq 0)			{ $blobsSA = $targetSA }
	if ($blobsSaContainer.Length -eq 0)	{ $blobsSaContainer = $targetSaContainer }
	
	if (!$skipBlobs) {
		$blobsRG = $targetRG
		$blobsSA = $targetSA
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
	}
	
	# given AMS ARM tempalte
	if ($pathArmTemplateAms.length -ne 0) {
	
		if ($(Test-Path -Path $pathArmTemplateAms) -ne $True) {
			write-logFileError "Invalid parameter 'pathArmTemplateAms'" `
								"File not found: '$pathArmTemplateAms'"
		}
		$exportPathAms = $pathArmTemplateAms
		$script:armTemplateFilePaths += $pathArmTemplateAms

		if ( ($pathArmTemplate.length -eq 0) `
		-and !$skipDeployment -and !$skipDeploymentVMs -and !$justRedeployAms ) {
			write-logFileError "Invalid parameter 'pathArmTemplateAms'" `
								"Parameter 'pathArmTemplate' must also be supplied"
		}
	}
	
	#--------------------------------------------------------------
	# check software version
	#--------------------------------------------------------------
	# check PowerShell version, alt least version 7.1.2
	if ( ($PSVersionTable.PSVersion.Major -lt 7) `
	-or (($PSVersionTable.PSVersion.Major -eq 7) -and ($PSVersionTable.PSVersion.Minor -lt 1)) `
	-or (($PSVersionTable.PSVersion.Major -eq 7) -and ($PSVersionTable.PSVersion.Minor -eq 1) -and ($PSVersionTable.PSVersion.Patch -lt 2)) ) {
		write-logFileError 'PowerShell version 7.1.2 or higher required'
	}
	
	# check Az version, at least version 6.0
	$azVersion = (Get-InstalledModule Az -MinimumVersion 6.0 -ErrorAction 'SilentlyContinue')
	if ($azVersion.count -eq 0) {
		write-logFileError 'Minimum required version of module Az is 6.0' `
							'Run "Install-Module -Name Az -AllowClobber" to install or update'
	}
	
	# display Az.NetAppFiles version
	$azAnfVersion = (Get-InstalledModule Az.NetAppFiles -ErrorAction 'SilentlyContinue')
	if ($azAnfVersion.count -ne 0) {
		$azAnfVersionString = $azAnfVersion.version
	}
	elseif (($createVolumes.count -ne 0) -or ($snapshotVolumes.count -ne 0)) {
	# check Az.NetAppFiles version
		$azAnfVersion = (Get-InstalledModule Az.NetAppFiles -MinimumVersion 0.7 -ErrorAction 'SilentlyContinue')
		if ($azAnfVersion.count -eq 0) {
			write-logFileError 'Minimum required version of module Az.NetAppFiles is 0.7' `
								'Run "Install-Module -Name Az.NetAppFiles -AllowClobber" to install or update'
		}
	}
	
	# display Az.HanaOnAzure version
	$azHoaVersion = (Get-InstalledModule Az.HanaOnAzure -ErrorAction 'SilentlyContinue')
	if ($azHoaVersion.count -ne 0) {
		$azHoaVersionString = $azHoaVersion.version
	}
	# check Az.HanaOnAzure version (minimum 0.3) in function new-templateTargetAms if AMS resource exists
	
	# check for running in Azure Cloud Shell
	if (($env:ACC_LOCATION).length -ne 0) {
		write-logFile 'RGCOPY running on Azure Cloud Shell:' -ForegroundColor 'yellow'
	}
	else {
		write-logFile 'RGCOPY environment:'
	}
	# output of sofware versions
	$psVersionString = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch)"
	write-logFileTab 'Powershell version'	$psVersionString -noColor
	write-logFileTab 'Az version'			$azVersion.version -noColor
	write-logFileTab 'Az.NetAppFiles'		$azAnfVersionString -noColor
	write-logFileTab 'Az.HanaOnAzure'		$azHoaVersionString -noColor
	write-logFileTab 'OS version'			$PSVersionTable.OS -noColor
	write-logFile
	
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

	# Check Source Subscription
	$sourceSubID = (Get-AzSubscription -SubscriptionName $sourceSub -ErrorAction 'SilentlyContinue').Id
	if ($Null -eq $sourceSubID) {
		write-logFileError "Source Subscription '$sourceSub' not found" -lastError
	}
	# Check Source Resource Group
	$sourceLocation = (Get-AzResourceGroup -Name $sourceRG -ErrorAction 'SilentlyContinue').Location
	if ($Null -eq $sourceLocation) {
		write-logFileError "Source Resource Group '$sourceRG' not found" -lastError
	}
	write-logFile 'Source:'
	write-logFileTab 'Subscription'		$sourceSub
	write-logFileTab 'User'				$sourceSubUser
	write-logFileTab 'Tenant'			$sourceSubTenant -noColor
	write-logFileTab 'Region'			$sourceLocation -noColor
	write-logFileTab 'Resource Group'	$sourceRG
	write-logFile

	#--------------------------------------------------------------
	# target resource group
	#--------------------------------------------------------------
	if ($enableSourceRgMode) {
		$targetSub			= $sourceSub
		$targetSubID		= $sourceSubID
		$targetSubUser		= $sourceSubUser
		$targetSubTenant	= $sourceSubTenant
		$targetLocation		= $sourceLocation
		$targetRG			= $sourceRG
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
		}
		else {
			write-logFileTab 'Subscription' $targetSub
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
		-and (($setVmMerge.count -eq 0) -or ($setVmName.count -eq 0)) ) {
			
			write-logFileError "Source and Target Resource Group are identical" `
								"This is only allowed when parameters 'setVmMerge' and 'setVmName' are used"
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
		if ('setLoadBalancerSku' -notin $boundParameterNames) {
			$setLoadBalancerSku = @()
		}
		if ('setPrivateIpAlloc' -notin $boundParameterNames) {
			$setPrivateIpAlloc = @()
		}
	}
	
	#--------------------------------------------------------------
	# debug actions
	#--------------------------------------------------------------
	if ($justDeleteSnapshots) {
		get-sourceVMs
		remove-snapshots
		write-zipFile 0
	}
	elseif ($justCreateSnapshots) {
		write-logFileForbidden 'justCreateSnapshots' @(
			'skipSnapshots', 'allowRunningVMs')
		step-prepare
		step-snapshots
		write-zipFile 0
	}
	elseif ($justStopCopyBlobs) {
		if ($archiveMode) {
			$blobsSaContainer	= $archiveContainer
			$targetSaContainer	= $archiveContainer
		}
		get-sourceVMs
		stop-copyBlobs
		write-zipFile 0
	}
	elseif ($updateMode) {
		get-sourceVMs
		step-updateMode
		write-zipFile 0
	}
	
	#--------------------------------------------------------------
	# get RGCOPY steps
	#--------------------------------------------------------------
	# cleanup
	if ($stopVMsTargetRG -or $deleteSnapshots -or $deleteSourceSA -or $deleteTargetSA) {
		$skipCleanup = $False
	}
	else {
		$skipCleanup = $True
	}

	# useBlobsFromDisk requires useBlobs
	if ($useBlobsFromDisk) {
		$useBlobs = $True
		$skipSnapshots = $True
	}
	# different regions require BLOB copy
	if ($sourceLocation -ne $targetLocation ) {
		$useBlobs = $True 
	}
	# different tenants require BLOB copy, even in same region
	if ($sourceSubTenant -ne $targetSubTenant ) {
		$useBlobs = $True
	}

	# given templates
	if (($pathArmTemplate.length -ne 0) -or ($pathArmTemplateAms.length -ne 0)) {
		$skipArmTemplate 	= $True
		$skipSnapshots 		= $True
		$skipBlobs 			= $True
	}

	# special cases:
	test-justRedeployAms
	test-archiveMode
	test-justCopyBlobs
	test-restartBlobs
	test-stopRestore
	test-setVmMerge
	write-logFileForbidden 'pathArmTemplate' @('createVolumes', 'createDisks')
	
	# when BLOBs are not needed for ARM template, then we do not need to copy them
	if (!$useBlobs) {
		$skipBlobs = $True
	}
	
	# when BLOBs are needed but not copied (because they already exist in target RG), then we do not need snapshots
	if ($useBlobs -and $skipBlobs) {
		$skipSnapshots = $True
	}
	
	# some not needed steps:
	if (($installExtensionsSapMonitor.count -eq 0) -and ($installExtensionsAzureMonitor.count -eq 0)) {
		$skipExtensions = $True
	}
	if (($createVolumes.count -eq 0) -and ($createDisks.count -eq 0)) {
		$skipBackups = $True
		$skipRestore = $True
	}

	if ($simulate) {
		$skipSnapshots	= $True
		$skipBackups	= $True
		$skipBlobs		= $True
		$skipDeployment	= $True
		$skipCleanup	= $True
		$startWorkload	= $False
	}

	if ($skipDeployment) {
		$skipDeploymentVMs = $True
	}

	# output of steps
	if ($skipArmTemplate  ) {$doArmTemplate     = '[ ]'} else {$doArmTemplate     = '[X]'}
	if ($skipSnapshots    ) {$doSnapshots       = '[ ]'} else {$doSnapshots       = '[X]'}
	if ($skipBackups      ) {$doBackups         = '[ ]'} else {$doBackups         = '[X]'}
	if ($skipBlobs        ) {$doBlobs           = '[ ]'} else {$doBlobs           = '[X]'}
	if ($skipDeploymentVMs) {$doDeploymentVMs   = '[ ]'} else {$doDeploymentVMs   = '[X]'}
	if ($skipRestore      ) {$doRestore         = '[ ]'} else {$doRestore         = '[X]'}
	if ($skipExtensions   ) {$doExtensions      = '[ ]'} else {$doExtensions      = '[X]'}
	if ($startWorkload    ) {$doWorkload        = '[X]'} else {$doWorkload        = '[ ]'}
	if ($deleteSnapshots  ) {$doDeleteSnapshots = '[X]'} else {$doDeleteSnapshots = '[ ]'}
	if ($deleteSourceSA   ) {$doDeleteSourceSA  = '[X]'} else {$doDeleteSourceSA  = '[ ]'}
	if ($deleteTargetSA   ) {$doDeleteTargetSA  = '[X]'} else {$doDeleteTargetSA  = '[ ]'}
	if ($stopVMsTargetRG  ) {$doStopVMsTargetRG = '[X]'} else {$doStopVMsTargetRG = '[ ]'}

	if ($justRedeployAms -or $createArmTemplateAms -or ('pathArmTemplateAms' -in $boundParameterNames)) {
		$doDeploymentAms   = '[X]'
	}
	else {
		$doDeploymentAms   = '[ ]'
	}

	write-logFile 'Required steps:'
	write-logFile "  $doArmTemplate Create ARM Template (refering to snapshots or BLOBs)"
	write-logFile   "  $doSnapshots Create snapshots (of disks and volumes in source RG)"
	write-logFile     "  $doBackups Create file backup (of disks and volumes in source RG SMB Share)"
	write-logFile       "  $doBlobs Create BLOBs (in target RG container)"
	if ($skipDeployment) {
		write-logFile            "  [ ] Deployment"
	}
	else {
		write-logFile            "      Deployment: $doDeploymentVMs Deploy Virtual Machines"
		write-logFile            "                  $doRestore Restore files"
		write-logFile            "                  $doDeploymentAms Deploy Azure Monitor for SAP"
		write-logFile            "                  $doExtensions Deploy Extensions"
	}
	write-logFile    "  $doWorkload Workload and Analysis"
	if ($skipCleanup) {
		write-logFile            "  [ ] Cleanup"
	}
	else {
		write-logFile            "      Cleanup:    $doDeleteSnapshots Delete Snapshots"
		write-logFile            "                  $doDeleteSourceSA Delete Storage Account in source RG"
		write-logFile            "                  $doDeleteTargetSA Delete Storage Account in target RG"
		write-logFile            "                  $doStopVMsTargetRG Stop VMs in target RG"
	}
	write-logFile
	
	#--------------------------------------------------------------
	# run steps
	#--------------------------------------------------------------
	$script:sapAlreadyStarted = $False
	$script:vmStartWaitDone = $False
	step-prepare
	step-armTemplate
	step-snapshots
	step-backups
	step-blobs
	
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************
	$script:sapAlreadyStarted = $False
	step-deployment
	step-workload
	step-cleanup
	set-context $sourceSub # *** CHANGE SUBSCRIPTION **************

	if ($script:totalSnapshotSize -gt 0) {
		write-logFileWarning "Parameter 'deleteSnapshots' was not supplied" `
							"RGCOPY created snapshots in source RG '$sourceRG' but did not delete them" `
							"The total size of the snapshots is $($script:totalSnapshotSize) GiB"
	}
	if ($script:totalBlobSize -gt 0) {
		write-logFileWarning "Parameter 'deleteTargetSA' was not supplied" `
							"RGCOPY created BLOBs in target RG '$targetRG' but did not delete them" `
							"The total size of the BLOBs is $($script:totalBlobSize) GiB"
	}
}
catch {
	Write-Output $error[0]
	Write-Output $error[0] *>>$logPath
	write-logFileError "PowerShell exception caught" `
						$error[0]
}

write-zipFile 0
