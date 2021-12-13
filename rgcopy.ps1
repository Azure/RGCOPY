<#
rgcopy.ps1:       Copy Azure Resource Group
version:          0.9.26
version date:     December 2021
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
param (
	#--------------------------------------------------------------
	# essential parameters
	#--------------------------------------------------------------
	# resource groups
	 [Parameter(Mandatory=$True)] [string] $sourceRG		# Source Resource Group
	,[Parameter(Mandatory=$True)] [string] $targetRG		# Target Resource Group (will be created)
	,[Parameter(Mandatory=$True)] [string] $targetLocation	# Target Region

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

	# operation switches
	,[switch] $skipArmTemplate								# skip ARM template creation
	,[switch] $skipSnapshots								# skip snapshot creation of disks and volumes (in sourceRG)
	,[switch] $skipBackups									# skip backup of files (in sourceRG)
	,[switch] $skipBlobs									# skip BLOB creation (in targetRG)
	,[switch] $skipDeployment								# skip deployment (in targetRG)
	,[switch]   $skipDeploymentVMs							# skip part step: deploy Virtual Machines
	,[switch]   $skipRestore								# skip part step: restore files
	,[switch]   $skipDeploymentAms							# skip part step: deploy AMS
	,[switch]   $skipExtensions								# skip part step: install VM extensions
	,[switch] $startWorkload								# start workload (script $scriptStartLoadPath on VM $scriptVm)
	,[switch] $stopRestore									# run all steps until (excluding) Restore
	,[switch] $continueRestore								# run Restore and all later steps
	,[switch] $stopVMs 										# stop VMs after deployment

	# BLOB switches
	,[switch] $useBlobs										# always (even in same region) copy snapshots to BLOB
	,[switch] $useBlobsFromDisk								# always (even in same region) copy disks to BLOB
	# only if $skipBlobs -eq $True:
	,[string] $blobsSA										# Storage Account of BLOBs
	,[string] $blobsRG										# Resource Group of BLOBs
	,[string] $blobsSaContainer								# Container of BLOBs

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
	,[string] $amsInstanceName								# Name of AMS instance to be created in the target RG
	,[string] $amsWsName									# Name of existing Log Analytics workspace for AMS
	,[string] $amsWsRG										# Resource Group of existing Log Analytics workspace for AMS
	,[switch] $amsWsKeep									# Keep existing Log Analytics workspace of sourceRG
	,[switch] $amsShareAnalytics							# Sharing Customer Analytics Data with Microsoft
	,[SecureString] $dbPassword			# = (ConvertTo-SecureString -String 'secure-password' -AsPlainText -Force)
	,[boolean] $amsUsePowerShell = $True					# use PowerShell cmdlets rather than ARM template for AMS deployment

	# script location of shell scripts inside the VM
	,[string] $scriptVm										# if not set, then calculated from vm tag rgcopy.ScriptStartSap
	,[string] $scriptStartSapPath							# if not set, then calculated from vm tag rgcopy.ScriptStartSap
	,[string] $scriptStartLoadPath							# if not set, then calculated from vm tag rgcopy.ScriptStartLoad
	,[string] $scriptStartAnalysisPath						# if not set, then calculated from vm tag rgcopy.ScriptAnalyzeLoad

	# VM extensions
	,$installExtensionsSapMonitor	= @()					# Array of VMs where SAP extension should be installed
	,$installExtensionsAzureMonitor	= @()					# Array of VMs where VM extension should be installed

	#--------------------------------------------------------------
	# default values
	#--------------------------------------------------------------
	,[int] $capacityPoolGB		= 4 * 1024					# default size of NetApp Capacity Pool in GB
	,[int] $grantTokenTimeSec	= 3 * 24 *3600				# 3 days: grant access to source disks
	,[int] $waitBlobsTimeSec	= 5 * 60					# 5 minutes: wait time between BLOB copy (or backup/restore) status messages
	,[int] $maxDOP				= 16 						# max degree of parallelism for FOREACH-OBJECT
	,[string] $setOwner 		= '*'						# Owner-Tag of Resource Group; default: $targetSubUser
	,[string] $jumpboxName		= ''						# create FQDN for public IP of jumpbox
	,[string] $createDisksTier	= 'P20'						# minimum disk tier for disks created using parameter createDisks
	,[switch] $smbTierStandard								# use Standard_GRS rather than Premium_LRS for SMB share
	,[switch] $ignoreTags									# ignore rgcopy*-tags for target RG CONFIGURATION
	,[switch] $verboseLog									# detailed output for backup/restore files
	,[switch] $copyDetachedDisks							# copy disks that are not attached to any VM
	,[switch] $skipVmChecks									# do not double check whether VMs can be deployed in target region
	,[switch] $skipDiskChecks								# do not check whether the targetRG already contains disks

	#--------------------------------------------------------------
	# skip resources from sourceRG
	#--------------------------------------------------------------
	,$skipVMs 				= @()							# Names of VMs that will not be copied
	,$skipDisks				= @()							# Names of DATA disks that will not be copied
	,$skipSecurityRules		= @('SecurityCenter-JITRule*')	# Name patterns of rules that will not be copied
	,$keepTags				= @('rgcopy*')					# Name patterns of tags that will be copied, all others will not be copied
	,[switch] $skipAms										# do not copy Azure Monioring for SAP
	,[switch] $skipAvailabilitySet							# do not copy Availability Sets
	,[switch] $skipProximityPlacementGroup					# do not copy Proximity Placement Groups
	,[switch] $skipBastion									# do not copy Bastion
	,[switch] $skipBootDiagnostics							# no BootDiagnostics, no StorageAccount in targetRG

	#--------------------------------------------------------------
	# resource configuration parameters
	#--------------------------------------------------------------
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

	,$setDiskCaching = @()
	# usage: $setDiskCaching = @("$caching/$writeAccelerator@$disk1,$disk1...", ...)
	#  with $caching -in @('ReadOnly','ReadWrite','None')
	#        $writeAccelerator -in ('True','False')
	# turn off writeAccelerator for all disks:			@("/False")
	# turn off all caches for all disks:				@("None/False")
	# set caching for 2 disks:							@("ReadOnly/True@hana1data1", "None/False@hana1os",)
	# turn on WA for one disk and off for all others: 	@("ReadOnly/True@hana1data1", "None/False")

	,$setDiskSku = @('Premium_LRS')
	# usage: $setDiskSku = @("$sku@$disk1,$disk1,...", ...)
	#  with $sku -in ('Premium_LRS','StandardSSD_LRS','Standard_LRS')

	,$setVmZone	= @('0')
	# usage: $setVmZone = @("$zone@$vm1,$vm2,...", ...)
	#  with $zone -in (0,1,2,3)
	#  0 means: remove zone
	# remove zone from all VMs							@("0")
	# set zone 1 for 2 VMs (hana 1 and hana2)			@("1@hana1,hana2")

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

	,$setVmMerge = @() # EXPERIMENTAL FEATURE: not supported
	# usage: $setVmMerge = @("$net/$subnet@$vm1,$vm2,...", ...)
	#	with $net as virtual network name, $subnet as subnet name in target resource group
	# merge VM jumpbox into target RG:					@("vnet/default@jumpbox")

	,$setLoadBalancerSku = @('Standard')
	# usage: $setLoadBalancerSku = @("$sku@$loadBalancer1,$loadBalancer12,...", ...)
	#	with $sku -in @('Basic', 'Standard')

	,$setPublicIpSku = @('Standard')
	#usage: $setPublicIpSku = @("$sku@$ipName1,$ipName12,...", ...)
	#	with $sku -in @('Basic', 'Standard')

	,$setPublicIpAlloc = @('Static')
	# usage: $setPublicIpAlloc = @("$allocation@$ipName1,$ipName12,...", ...)
	#	with $allocation -in @('Dynamic', 'Static')

	,$setPrivateIpAlloc	= @('Static')
	# usage: $setPrivateIpAlloc = @("$allocation@$ipName1,$ipName12,...", ...)
	#	with $allocation -in @('Dynamic', 'Static')

	,$removeFQDN = @('True')
	# removes Full Qualified Domain Name from public IP address
	# usage: $removeFQDN = @("bool@$ipName1,$ipName12,...", ...)
	#	with $bool -in @('True')

	,$setAcceleratedNetworking = @('True')
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
	,[switch] $justCreateSnapshots
	,[switch] $justDeleteSnapshots

	#--------------------------------------------------------------
	# experimental parameters: DO NOT USE!
	#--------------------------------------------------------------
	,$setVmTipGroup			= @()
	,$setGroupTipSession	= @()
	,[switch] $allowRunningVMs
	,[switch] $skipGreenlist
	,[switch] $skipStartSAP
	,$generalizedVMs		= @()
	,$generalizedUser		= @()
	,$generalizedPasswd		= @() # will be checked below for data type [SecureString] or [SecureString[]]
)

$ErrorActionPreference = 'Stop'

# constants
$snapshotExtension	= 'rgcopy'
$netAppSnapshotName	= 'rgcopy'
$targetSaContainer	= 'rgcopy'
$sourceSaShare		= 'rgcopy'
$targetNetAppPool	= 'rgcopy'

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

# Storage Account in targetRG (between 3 and 24 characters)
if ($targetSA.Length -eq 0) {
	$targetSA = ($targetRG -replace '[_\.\-\(\)]', '').ToLower()
	$len = (24, $targetSA.Length | Measure-Object -Minimum).Minimum
	if ($len -lt 3) { $targetSA += 'blob'; $len += 4}
	$targetSA = $targetSA.SubString(0,$len)
}
# Storage Account in sourceRG
if ($sourceSA.Length -eq 0) {
	$sourceSA = ($sourceRG -replace '[_\.\-\(\)]', '').ToLower()
	$len = (21, $sourceSA.Length | Measure-Object -Minimum).Minimum
	$sourceSA = 'smb' + $sourceSA.SubString(0,$len)
}
# Azure NetApp Files Account
#$targetAnfAccount = $targetSA


# AMS Name (between 6 and 30 characters)
if ($amsInstanceName.Length -eq 0)	{ $amsInstanceName = $targetSA }

# Storage Account for disk creation
if ($blobsRG.Length -eq 0)			{ $blobsRG = $targetRG }
if ($blobsSA.Length -eq 0)			{ $blobsSA = $targetSA }
if ($blobsSaContainer.Length -eq 0)	{ $blobsSaContainer = $targetSaContainer }

if ($skipBlobs -ne $True) {
	$blobsRG = $targetRG
	$blobsSA = $targetSA
	$blobsSaContainer = $targetSaContainer
}

# file names and location
if ($(Test-Path $pathExportFolder) -eq $False) {
	$pathExportFolderNotFound = $pathExportFolder
	$pathExportFolder = '~'

}
$pathExportFolder = Resolve-Path $pathExportFolder

# default file paths
$importPath 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$sourceRG.SOURCE.json"
$exportPath 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG.TARGET.json"
$exportPathAms 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG.AMS.json"
$logPath			= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG.TARGET.log"

$timestampSuffix 	= (Get-Date -Format 'yyyy-MM-dd__HH-mm-ss')
# fixed file paths
$tempPathText 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG.TEMP.txt"
$tempPathJson 		= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG.TEMP.json"
$zipPath 			= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.$targetRG.$timestampSuffix.zip"
$savedRgcopyPath	= Join-Path -Path $pathExportFolder -ChildPath "rgcopy.txt"

#--------------------------------------------------------------
function write-logFile {
#--------------------------------------------------------------
	param (	[Parameter(Position=0)] $print,
			[switch] $NoNewLine,
			$ForegroundColor )

	if ($Null -eq $print) { $print = ' ' }
	[string] $script:LogFileLine += $print

	$par = @{ Object = $print }
	if ($NoNewLine)					{ $par.Add('NoNewLine', $True) }
	if ($Null -ne $ForegroundColor)	{ $par.Add('ForegroundColor', $ForegroundColor) }

	Write-Host @par
	if (!$NoNewLine) {
		Write-Host $script:LogFileLine *>>$logPath
		[string] $script:LogFileLine = ''
	}
}

#--------------------------------------------------------------
function write-logFileWarning {
#--------------------------------------------------------------
	param ( $myWarning )

	write-logFile "WARNING: $myWarning" -ForegroundColor 'yellow'
}

#--------------------------------------------------------------
function write-zipFile {
#--------------------------------------------------------------
	param (	$exitCode)

	write-logFile -ForegroundColor 'Cyan' "All files saved in zip file: $zipPath"
	write-logFile "RGCOPY EXIT CODE:  $exitCode"
	write-logFile

	[array] $files = @($logPath)

	if ($skipArmTemplate -ne $True) {
		if ($(Test-Path -Path $importPath) -eq $True)	{$files += $importPath}
	}
	if ($(Test-Path -Path $savedRgcopyPath) -eq $True)	{$files += $savedRgcopyPath}
	if ($(Test-Path -Path $exportPath) -eq $True)		{$files += $exportPath}
	if ($(Test-Path -Path $exportPathAms) -eq $True)	{$files += $exportPathAms}

	$parameter = @{	LiteralPath		= $files
					DestinationPath = $zipPath }
	Compress-Archive @parameter

	[console]::ResetColor()
	$ErrorActionPreference = 'Stop'
	exit $exitCode
}

#--------------------------------------------------------------
function write-logFileError {
#--------------------------------------------------------------
	param (	$param1,
			$param2,
			$param3,
			$lastError)

	if ($lastError.length -ne 0) {
		write-logFile
		write-logFile $lastError -ForegroundColor 'yellow'
	}
	write-logFile
	write-logFile ('=' * 60) -ForegroundColor 'red'
	write-logFile $param1 -ForegroundColor 'yellow'
	if ($param2.length -ne 0) {
		write-logFile $param2 -ForegroundColor 'yellow'
	}
	if ($param3.length -ne 0) {
		write-logFile $param3 -ForegroundColor 'yellow'
	}
	write-logFile ('=' * 60) -ForegroundColor 'red'
	write-logFile

	$stack = Get-PSCallStack
	write-logFile "RGCOPY TERMINATED: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz')" -ForegroundColor 'red'
	write-logFile "CALL STACK:        $($stack[-2].ScriptLineNumber) $($stack[-2].Command)"
	for ($i = $stack.count-3; $i -ge 2; $i--) {
		write-logFile "                   $($stack[$i].ScriptLineNumber) $($stack[$i].Command)"
	}
	write-logFile "ERROR LINE:        $($stack[1].ScriptLineNumber) $($stack[1].Command)"
	write-logFile "ERROR MESSAGE:     $param1"
	write-zipFile 1
}

#--------------------------------------------------------------
function write-logFileUpdates {
#--------------------------------------------------------------
	param (	[Parameter(Position=0)] [string] $resourceType,
			[Parameter(Position=1)] [string] $resource,
			[Parameter(Position=2)] [string] $action,
			[Parameter(Position=3)] [string] $value,
			[Parameter(Position=4)] [string] $comment1,
			[Parameter(Position=5)] [string] $comment2)

	if ($action -like 'delete*')	{$colorAction = 'Blue'}
	elseif ($action -like 'keep*')	{$colorAction = 'DarkGray'}
	else							{$colorAction = 'Green'}

	if ($resource -like '<*')		{$colorResource = 'Cyan'}
	else							{$colorREsource = 'Gray'}

	if (($value.length -ne 0) -and ($comment1.length -eq 0) -and ($value -notin @('True','False'))) {$value = "'$value'"}

	$spaces = ''
	$numSpace = 40 - $resourceType.length - $resource.length
	if ($numSpace -gt 0) {$spaces = ' '*$numSpace}

	Write-logFile "$resourceType "		-NoNewline -ForegroundColor 'DarkGray'
	write-logFile "$resource $spaces"   -NoNewline -ForegroundColor $colorResource
	Write-logFile "$action "			-NoNewline -ForegroundColor $colorAction
	Write-logFile $value				-NoNewline
	Write-logFile $comment1				-NoNewline -ForegroundColor 'Cyan'
	Write-logFile $comment2
}

#--------------------------------------------------------------
function write-logFileTab {
#--------------------------------------------------------------
	param (	[Parameter(Position=0)] [string] $resourceType,
			[Parameter(Position=1)] [string] $resource,
			[Parameter(Position=2)] [string] $info,
			[switch] $noColor)

	if ($noColor)	{$resourceColor = 'Gray'}
	else			{$resourceColor = 'Green'}

	Write-logFile "  $(($resourceType + (' '*20)).Substring(0,20))" -NoNewline
	write-logFile "$resource " -NoNewline -ForegroundColor $resourceColor
	Write-logFile "$info"
}

#--------------------------------------------------------------
function protect-secureString {
#--------------------------------------------------------------
	param (	$key, $value)

	if (($value -is [securestring]) -or ($key -like '*passw*') -or ($key -like '*credential*')) {
		return '*****'
	}
	return $value
}

#--------------------------------------------------------------
function write-hashTableOutput {
#--------------------------------------------------------------
	param (	$key, $value)

	$protectedValue = protect-secureString $key $value

	$script:hashTableOutput += New-Object psobject -Property @{
		Parameter	= $key
		Value		= $protectedValue
	}
}

#--------------------------------------------------------------
function write-logFileHashTable {
#--------------------------------------------------------------
	param (	$paramHashTable)

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

	$script:hashTableOutput
	| Select-Object Parameter, Value
	| Sort-Object Parameter
	| Format-Table
	| Tee-Object -FilePath $logPath -append
	| Out-Host
}

#--------------------------------------------------------------
function write-actionStart {
#--------------------------------------------------------------
	param ( 	$text, $maxDegree)

	if ($null -ne $maxDegree) {
		if ($maxDegree -gt 1) {
			$text = $text + " (max degree of parallelism: $maxDegree)"
		}
	}
	write-logFile ('*' * 63) -ForegroundColor DarkGray
	write-logFile $text
	write-logFile ('>>>' + ('-' * 60)) -ForegroundColor DarkGray
	write-logFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz')
	write-logFile
}

#--------------------------------------------------------------
function write-actionEnd {
#--------------------------------------------------------------
	write-logFile
	write-logFile ('<<<' + ('-' * 60)) -ForegroundColor DarkGray
	write-logFile
	write-logFile
}

#--------------------------------------------------------------
function get-ParameterConfiguration {
#--------------------------------------------------------------
	param (	$config)

	# split configuration
	$script:paramConfig1,$script:paramConfig2,$script:paramConfig3,$script:paramConfig4 = $config -split '/'

	# a maximum of 4 configuration parts:
	if ($script:paramConfig4.count -gt 1) {
		write-logFileError "Invalid parameter '$script:paramName'" `
							"Configuration: '$config'" `
							"The configuration contains more than three '/'"
	}
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

	# no rule exists or last rule reached
	if ($script:paramRules.count -le $script:paramIndex) { return }

	# get current rule
	$currentRule = $script:paramRules[$script:paramIndex++]

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
	if ($resources.length -eq 0)	{ [array] $script:paramResources = @() }
	else 							{ [array] $script:paramResources = $resources -split ',' }
	# remove empty resources (double commas)
	[array] $script:paramResources = $script:paramResources | Where-Object {$_.length -ne 0}

	# get resource types: VMs and disks
	if ($script:paramResources.count -eq 0) {
		[array] $script:paramVMs   = $script:copyVMs.keys
		[array] $script:paramDisks = $script:copyDisks.keys
	}
	else {
		[array] $script:paramVMs   = $script:copyVMs.keys   | Where-Object {$_ -in $script:paramResources}
		[array] $script:paramDisks = $script:copyDisks.keys | Where-Object {$_ -in $script:paramResources}

		# check existence
		if ($script:paramName -like 'setVm*') {
			[array] $notFound = $script:paramResources | Where-Object {$_ -notin $script:paramVMs}
			if ($notFound.count -ne 0) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"Rule: '$currentRule'" `
									"VM '$($notFound[0])' not found"
			}
		}
		if ($script:paramName -like 'setDisk*') {
			[array] $notFound = $script:paramResources | Where-Object {$_ -notin $script:paramDisks}
			if ($notFound.count -ne 0) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"Rule: '$currentRule'" `
									"Disk '$($notFound[0])' not found"
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
	param (	$parameterName, $parameter, $type, $type2)

	$script:paramName = $parameterName

	if (($parameter -isnot [array]) -and ($parameter -isnot [string])) {
		write-logFileError "Invalid parameter '$script:paramName'" `
							"invalid data type"
	}

	# paramRules as array
	if ($parameter.count -eq 0)	{ [array] $script:paramRules = @() }
	else						{ [array] $script:paramRules = $parameter }

	# set script variable for index of rules (current rule)
	[int] $script:paramIndex = 0
	$script:paramValues = @{}

	if ($script:paramRules.count -gt 1) {
		# process first rule last -> first rule wins
		[array]::Reverse($script:paramRules)

		# process global rules (no @) first
		[array] $head = $script:paramRules | Where-Object {$_ -notlike '*@*'}
		[array] $tail = $script:paramRules | Where-Object {$_ -like '*@*'}
		[array] $script:paramRules = $head + $tail
	}

	#--------------------------------------------------------------
	# get all resource names from ARM template
	if ($Null -ne $type) {
		[array] $resourceNames = ($script:resourcesALL | Where-Object type -eq $type).name
	}
	else {
		return # no ARM resource types supplied
	}
	if ($Null -ne $type2) {
		[array] $resourceNames += ($script:resourcesALL | Where-Object type -eq $type2).name
	}

	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		if ($script:paramResources.count -eq 0)	{
			[array] $myResources = $resourceNames
		}
		else {
			[array] $myResources = $script:paramResources
			# check existence
			[array] $notFound = $script:paramResources | Where-Object {$_ -notin $resourceNames}
			if ($notFound.count -ne 0) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"Resource '$($notFound[0])' not found"
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
	param (	$scriptParameter, $scriptBlock, $myMaxDOP)

	if ($myMaxDOP -eq 1) {
		return @{ Process = $scriptBlock }
	}
	else {
		$scriptReturn = [Scriptblock]::Create($scriptParameter + $scriptBlock.toString())
		return @{ ThrottleLimit = $myMaxDOP; Parallel = $scriptReturn }
	}
}

#--------------------------------------------------------------
function compare-resources{
#--------------------------------------------------------------
	param (	$res1, $res2)

	return (($res1 -replace '\s+', '') -eq ($res2 -replace '\s+', ''))
}

#--------------------------------------------------------------
function get-resourceString {
#--------------------------------------------------------------
	# assembles string for Azure Resource ID
	param (	$subscriptionID,	$resourceGroup,
			$resourceArea,
			$mainResourceType,	$mainResourceName,
			$subResourceType,	$subResourceName)

	$resID = "/subscriptions/$subscriptionID/resourceGroups/$resourceGroup/providers/$resourceArea/$mainResourceType/$mainResourceName"
	if ($Null -ne $subResourceType) { $resID += "/$subResourceType/$subResourceName" }
	return $resID
}

#--------------------------------------------------------------
function get-resourceFunction {
#--------------------------------------------------------------
	# assembles string for Azure Resource ID using function resourceId()
	param (	$resourceArea,
			$mainResourceType, $mainResourceName,
			$subResourceType,  $subResourceName)

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
function get-functionBody {
#--------------------------------------------------------------
	param ( 	$str, $inputString)

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
	param (	$dependsOn,
			$remove,
			$keep)

	if ($keep.length -ne 0) {
		[array] $return = $dependsOn | Where-Object { $_ -like "*'$keep'*" }
	}
	elseif ($remove.length -ne 0) {
		[array] $return = $dependsOn | Where-Object { $_ -notlike "*'$remove'*" }
	}

	if ($return.count -eq 0) {
		$return = @()
	}

	return $return
}

#--------------------------------------------------------------
function remove-resources {
#--------------------------------------------------------------
	param (	$type,
			$names)

	if ('names' -notin $PSBoundParameters.Keys) {
		[array] $script:resourcesALL = $script:resourcesALL | Where-Object type -notlike $type
	}
	else {
		[array] $script:resourcesALL = $script:resourcesALL | Where-Object {($_.type -ne $type) -or ($_.name -notin $names)}
	}
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
	param (	$inputString,
			$subscriptionID,
			$resourceGroup)

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
	param (	$mySub, $mySubUser, $mySubTenant, $myType)

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
		| Select-Object @{label="AccountId"; expression={$_.Account.Id}}, `
						@{label="SubscriptionName"; expression={$_.Subscription.Name}}, `
						@{label="TenantId"; expression={$_.Tenant.Id}}
		| Tee-Object -FilePath $logPath -append
		| Out-Host

		write-logFileWarning "Run Connect-AzAccount before starting RGCOPY"
		write-logFile

		write-logFileError "Get-AzContext failed for user: $mySubUser" `
							"Subscription:                  $mySub" `
							"Tenant:                        $mySubTenant"
	}

	# set context
	set-AzContext -Context $myContext[0] -ErrorAction 'SilentlyContinue' | Out-Null
	if (!$?) {
		# This should never happen because Get-AzContext already worked:
		write-logFileError "Set-AzContext failed for user: $mySubUser" `
							"Subscription:                  $mySub" `
							"Tenant:                        $mySubTenant" `
							$error[0]
	}
}

#--------------------------------------------------------------
function set-context {
#--------------------------------------------------------------
	param (	$mySubscription)

	if ($mySubscription -eq $script:currentSub) { return}

	write-logFile "--- set subscription context $mySubscription ---" -ForegroundColor DarkGray

	if ($mySubscription -eq $sourceSub) {
		Set-AzContext -Context $sourceContext -ErrorAction 'SilentlyContinue' | Out-Null
		if (!$?) {
			# This should never happen because test-context() already worked:
			write-logFileError "Could not connect to Subscription '$mySubscription'" `
								"Set-AzContext failed" `
								'' $error[0]
		}

	} elseif ($mySubscription -eq $targetSub) {
		Set-AzContext -Context $targetContext -ErrorAction 'SilentlyContinue' | Out-Null
		if (!$?) {
			# This should never happen because test-context() already worked:
			write-logFileError "Could not connect to Subscription '$mySubscription'" `
								"Set-AzContext failed" `
								'' $error[0]
		}

	} else {
		# This should never happen because test-context() already worked:
		write-logFileError "Invalid Subscription '$mySubscription'"
	}

	$script:currentSub = $mySubscription
}

#--------------------------------------------------------------
function get-partTemplate {
#--------------------------------------------------------------
	param (	[array] $resIDs,
			[string] $resGroup,
			[string] $resType)

	# get ARM template just for these IDs
	$parameter = @{
		Resource				= $resIDs
		Path					= $tempPathJson
		ResourceGroupName		= $resGroup
		SkipAllParameterization	= $True
		force					= $True
		ErrorAction				= 'SilentlyContinue'
	}

	Export-AzResourceGroup @parameter | Out-Null
	if (!$?) {
		write-logFileError "Could not create JSON template for $resType" `
							'Export-AzResourceGroup failed' `
							'' $error[0]
	}

	$text = Get-Content -Path $tempPathJson
	$template = $text | ConvertFrom-Json -Depth 20 -AsHashtable
	Remove-Item -Path $tempPathJson
	return $template
}

#--------------------------------------------------------------
function update-diskTier {
#--------------------------------------------------------------
	$script:copyDisks.values
	| ForEach-Object {

		$_.SizeTierName	= get-diskTier $_.SizeGB $_.SkuName
		$_.SizeTierGB	= get-diskSize $_.SizeTierName
	}
}

#--------------------------------------------------------------
function update-PerformanceTier {
#--------------------------------------------------------------
	$script:copyDisks.values
	| ForEach-Object {

		$_.performanceTierGB = get-diskSize $_.performanceTierName
		if ($_.performanceTierGB -gt 0) {

			# max performance tier is P50 for P1 .. P50
			if (($_.performanceTierGB -gt 4096) -and ($_.SizeTierGB -le 4096)) {
				$_.performanceTierGB = 4096
				$_.performanceTierName = 'P50'
			}

			# only higher performance tiers can be configured
			if ($_.performanceTierGB -le $_.SizeTierGB) {
				$_.performanceTierGB = 0
				$_.performanceTierName = $Null
			}
		}
		# unknown performance tier
		else {
			$_.performanceTierGB = 0
			$_.performanceTierName = $Null
		}

		# not Premium_LRS
		if ($_.SkuName -ne 'Premium_LRS') {
			$_.performanceTierGB = 0
			$_.performanceTierName = $Null
		}
	}
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
	param (	$sizeGB, $SkuName)

	switch ($SkuName) {
		'Premium_LRS' {
			for ($i = 0; $i -lt $sizesSortedSSD.Count; $i++) {
				if ($sizeGB -le $sizesSortedSSD[$i]) {
					return $tierPremiumSSD[$i]
				}
			}
		}
		'StandardSSD_LRS' {
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
	param (	$tier)

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
function sync-skuProperties {
#--------------------------------------------------------------
# make sure that an entry exists in hashtable $script:vmSkus for each VM size
# needed to avoid script errors when accessing the hashtable
	param (	$vmSize)

	if ($Null -eq $script:vmSkus[$vmSize]) {
		$script:vmSkus[$vmSize] = New-Object psobject -Property @{
			Name                            = $vmSize
			Family                          = 'unknown'
			Tier                            = 'unknown'
			vCPUs                           = 1
			MaxDataDiskCount                = 0
			PremiumIO                       = $Null
			MaxWriteAcceleratorDisksAllowed = 0
			MaxNetworkInterfaces            = 0
			AcceleratedNetworkingEnabled    = $Null
			RdmaEnabled                     = $Null
		}
	}
}

#--------------------------------------------------------------
function save-skuProperties {
#--------------------------------------------------------------
# save properties of each VM size
	if ($skipVmChecks -eq $True) { return }

	$savedSub = $script:currentSub
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	$script:vmFamilies = @{}
	$script:vmSkus = @{}

	# get SKUs for all VM sizes in target
	try {
		$allSVMs = Get-AzComputeResourceSku -Location $targetLocation | Where-Object ResourceType -eq "virtualMachines"

		$allSVMs
		| ForEach-Object {
	
			$vmSize   = $_.Name
			$vmFamily = $_.Family
			$vmTier   = $_.Tier
	
			# store VM sizes
			$script:vmFamilies[$vmSize] = $vmFamily
	
			# default SKU properties
			$vCPUs                           = 1
			$MaxDataDiskCount                = 0
			$PremiumIO                       = $Null
			$MaxWriteAcceleratorDisksAllowed = 0
			$MaxNetworkInterfaces            = 0
			$AcceleratedNetworkingEnabled    = $Null
			$RdmaEnabled                     = $Null

			# get SKU properties
			foreach($cap in $_.Capabilities) {
				switch ($cap.Name) {
					'vCPUs'                             {$vCPUs                           = $cap.Value -as [int]; break}
					'MaxDataDiskCount'                  {$MaxDataDiskCount                = $cap.Value -as [int]; break}
					'PremiumIO'                         {$PremiumIO                       = $cap.Value; break}
					'MaxWriteAcceleratorDisksAllowed'   {$MaxWriteAcceleratorDisksAllowed = $cap.Value -as [int]; break}
					'MaxNetworkInterfaces'              {$MaxNetworkInterfaces            = $cap.Value -as [int]; break}
					'AcceleratedNetworkingEnabled'      {$AcceleratedNetworkingEnabled    = $cap.Value; break}
					'RdmaEnabled'                       {$RdmaEnabled                     = $cap.Value; break}
				}
			}

			# store SKU properties
			$script:vmSkus[$vmSize] = New-Object psobject -Property @{
				Name                            = $vmSize
				Family                          = $vmFamily
				Tier                            = $vmTier
				vCPUs                           = $vCPUs
				MaxDataDiskCount                = $MaxDataDiskCount
				PremiumIO                       = $PremiumIO
				MaxWriteAcceleratorDisksAllowed = $MaxWriteAcceleratorDisksAllowed
				MaxNetworkInterfaces            = $MaxNetworkInterfaces
				AcceleratedNetworkingEnabled    = $AcceleratedNetworkingEnabled
				RdmaEnabled                     = $RdmaEnabled
			}
		}
	}
	catch {
		write-logFileError "Could not get VM SKUs for region '$targetLocation'" `
							"Get-AzComputeResourceSku failed" `
							"You can skip this step using RGCOPY parameter switch 'skipVmChecks'" `
							error[0]
	}

	# add SKUs for additional VM sizes in source
	$script:copyVMs.Values 
	| ForEach-Object {

		sync-skuProperties $_.VmSize
	}

	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function compare-quota {
#--------------------------------------------------------------
# check quotas in target region for each VM Family
	if ($skipVmChecks -eq $True) { return }

	$savedSub = $script:currentSub
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	# get quotas
	$script:cpuUsage = Get-AzVMUsage -Location $targetLocation
	if (!$?) {
		write-logFileError "Could not get quotas for region '$targetLocation'" `
							"Get-AzVMUsage failed" `
							"You can skip this step using RGCOPY parameter switch 'skipVmChecks'"
							$error[0]
	}

	# sum required CPUs per family
	$requiredCPUs = @{}

	$script:copyVMs.values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$vmFamily = $script:vmFamilies[$_.vmSize]
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
			$_.usedCPUs		= $quota.CurrentValue
			$_.limitCPUs	= $quota.Limit
			[int] $_.usage = ($_.usedCPUs + $_.neededCPUs) * 100 / $_.limitCPUs
		}
	}

	# output of quota
	$requiredCPUs.Values
	| Sort-Object vmFamily
	| Select-Object @{label="VM family";   expression={$_.vmFamily}}, `
					@{label="CPUs used";   expression={ if ($_.usedCPUs -ne -1){$_.usedCPUs}else{''}} }, `
					@{label="CPUs quota";  expression={ if ($_.limitCPUs -ne -1){$_.limitCPUs}else{''}} }, `
					@{label="required for deployment";   expression={$_.neededCPUs}}, `
					@{label="usage after deployment";expression={"$($_.usage)%"}}
	| Format-Table
	| Tee-Object -FilePath $logPath -append
	| Out-Host

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
			if ($skipDeployment -eq $True) {
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
	# check for running VM with more than one data disk or volume
	if ( ($allowRunningVMs -eq $False) `
	-and ($skipSnapshots -eq $False) `
	-and ($pathPreSnapshotScript.length -eq 0) `
	-and ($script:runningVMs -eq $True)) {
		write-logFileError "Trying to copy non-deallocated VM with more than one data disk or volume" `
							"Asynchronous snapshots could result in data corruption in the target VM" `
							'VMs with more than one data disk or volume must be deallocated when running RGCOPY'
	}

	# check for running VM while parameter useBlobsFromDisk is set
	$script:copyVMs.Values
	| ForEach-Object {

		if ( ($allowRunningVMs -eq $False) `
		-and ($_.VmStatus -ne 'VM deallocated') `
		-and ($useBlobsFromDisk -eq $True)) {

			write-logFileError "VM '$($_.Name)' must be deallocated if parameter 'useBlobsFromDisk' is set"
		}
	}

	# check for running VM with WA
	$script:copyVMs.Values
	| ForEach-Object {

		if ( ($allowRunningVMs -eq $False) `
		-and ($_.VmStatus -ne 'VM deallocated') `
		-and ($skipSnapshots -eq $False) `
		-and ($pathPreSnapshotScript -eq 0) `
		-and ($_.hasWA -eq $True)) {

			write-logFileError "Trying to copy non-deallocated VM with Write Accelerator enabled" `
								"snapshots might be incomplete and could result in data corruption in the target VM" `
								'VMs with Write Accelerator enabled must be deallocated'
		}
	}
}

#--------------------------------------------------------------
function show-sourceVMs {
#--------------------------------------------------------------
	$script:copyVMs.Values
	| Sort-Object Name
	| Select-Object @{label="VM name";   expression={$_.Name}}, `
					@{label="VM size";   expression={$_.VmSize}}, `
					@{label="DataDisks"; expression={$_.DataDisks.count}}, `
					@{label="Volumes";   expression={$_.MountPoints.count}}, `
					@{label="Status";    expression={$_.VmStatus}}
	| Format-Table
	| Tee-Object -FilePath $logPath -append
	| Out-Host

	$script:copyDisks.Values
	| Sort-Object Name
	| Select-Object `
		@{label="DiskName";  expression={$_.Name}}, `
		VM, `
		@{label="waEnabled"; expression={([string]($_.writeAcceleratorEnabled)).Replace('False','-')}}, `
		@{label="Caching";   expression={([string]($_.Caching)).Replace('None','-')}}, `
		SizeGB, `
		@{label="Size";      expression={$_.SizeTierName}}, `
		@{label="PerfTier";  expression={if($_.performanceTierName.length -eq 0) {'-'} else {$_.performanceTierName}}}, `
		@{label="Skip";      expression={([string]($_.Skip)).Replace('False','-')}}, `
		@{label="Image";     expression={([string]($_.Image)).Replace('False','-')}}
	| Format-Table
	| Tee-Object -FilePath $logPath -append
	| Out-Host
}

#--------------------------------------------------------------
function show-targetVMs {
#--------------------------------------------------------------
	# output of VMs
	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| Sort-Object Name
	| Select-Object @{label="VM name";   expression={if($_.Rename.length -eq 0){$_.Name}else{"$($_.Rename) ($($_.Name))"}}}, `
					@{label="VM size";   expression={$_.VmSize}}
	| Format-Table
	| Tee-Object -FilePath $logPath -append
	| Out-Host

	# oupput of disks
	[array] $allDisks = $script:copyDisks.Values
	[array] $allDisks += $script:copyDisksNew.Values

	$allDisks
	| Sort-Object Name
	| Where-Object Skip -ne $True
	| Select-Object `
		@{label="Disk name";  expression={if($_.Rename.length -eq 0){$_.Name}else{"$($_.Rename) ($($_.Name))"}}}, `
		VM, `
		@{label="WA enabled"; expression={([string]($_.writeAcceleratorEnabled)).Replace('False','-')}}, `
		@{label="Caching";    expression={([string]($_.Caching)).Replace('None','-')}}, `
		SizeGB, `
		@{label="Size";       expression={$_.SizeTierName}}, `
		@{label="PerfTier";   expression={if($_.performanceTierName.length -eq 0) {'-'} else {$_.performanceTierName}}}
	| Format-Table
	| Tee-Object -FilePath $logPath -append
	| Out-Host
}

#--------------------------------------------------------------
function save-VMs {
#--------------------------------------------------------------
	$script:copyDisks = @{}
	foreach ($disk in $script:sourceDisks) {

		$sku = $disk.Sku.Name
		if ($sku -notin @('Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS', 'UltraSSD_LRS')) {
			$sku = 'Premium_LRS'
		}

		# save source disk
		$script:copyDisks[$disk.Name] = @{
			Name        			= $disk.Name
			Rename					= ''
			VM						= '' 		# will be updated below by VM info
			Skip					= $False 	# will be updated below by VM info
			image					= $False 	# will be updated below by VM info
			Caching					= $Null 	# will be updated below by VM info
			WriteAcceleratorEnabled	= $False 	# will be updated below by VM info
			AbsoluteUri 			= ''		# access token for copy to BLOB
			SkuName     			= $sku
			DiskIOPSReadWrite		= $disk.DiskIOPSReadWrite #e.g. 1024
			DiskMBpsReadWrite		= $disk.DiskMBpsReadWrite #e.g. 4
			SizeGB      			= $disk.DiskSizeGB        #e.g. 1024
			SizeTierName			= ''				# disk tier
			SizeTierGB				= 0					# maximum disk size for current tier
			performanceTierName		= $disk.Tier		# configured performance tier
			performanceTierGB		= 0					# size of configured performance tier
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

		if ($vm.Zones.count -ne 0) 		{ $vmZone = $vm.Zones[0] }	else { $vmZone = 0 }
		if ($vmZone -notin @(1,2,3))	{ $vmZone = 0 }

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
			VmPriority				= 2147483647 # default: highest INT number = lowest priority
			VmStatus				= $vm.PowerState
			MergeNetSubnet			= $Null
			hasWA					= $hasWA
			Tags 					= $vm.Tags
			MountPoints				= @()
			proximityPlacementGroup = ''
			availabilitySet			= ''
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
			if ($Null -ne $script:copyDisks[$diskName].OsType) {
				$_.OsDisk.OsType = $script:copyDisks[$diskName].OsType
			}
			# update Hyper-V generation
			if ($Null -ne $script:copyDisks[$diskName].HyperVGeneration) {
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
}

#--------------------------------------------------------------
function get-sourceVMs {
#--------------------------------------------------------------
	write-actionStart "Current VMs/disks in Source Resource Group $sourceRG"

	# Get source vms
	$script:sourceVMs = Get-AzVM `
						-ResourceGroupName $sourceRG `
						-status `
						-ErrorAction 'SilentlyContinue'
	if (!$?) {
		write-logFileError "Could not get VMs of resource group $sourceRG" `
							'Get-AzVM failed' `
							'' $error[0]
	}

	# Get source disks
	$script:sourceDisks = Get-AzDisk `
						-ResourceGroupName $sourceRG `
						-ErrorAction 'SilentlyContinue'
	if (!$?) {
		write-logFileError "Could not get disks of resource group $sourceRG" `
							'Get-AzDisk failed' `
							'' $error[0]
	}

	save-VMs

	update-paramSetVmMerge
	update-paramSkipVMs
	update-paramGeneralizedVMs
	update-disksFromVM
	[array] $script:installExtensionsSapMonitor   = test-vmParameter 'installExtensionsSapMonitor'   $script:installExtensionsSapMonitor
	[array] $script:installExtensionsAzureMonitor = test-vmParameter 'installExtensionsAzureMonitor' $script:installExtensionsAzureMonitor

	update-paramSnapshotVolumes
	update-paramCreateVolumes
	update-paramCreateDisks
	update-paramSetVmDeploymentOrder
	update-paramSetVmTipGroup
	update-paramSetVmName
	
	save-skuProperties
	update-diskTier
	update-PerformanceTier

	update-paramSkipDisks
	show-sourceVMs

	write-actionEnd
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
					-PoolName			$anfPool
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
			[array] $array = $paramResource -split '/'
			[array] $array = $array | Where-Object {$_.length -ne 0}
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
			[array] $array = $paramResource -split '/'
			[array] $array = $array | Where-Object {$_.length -ne 0}
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
		write-logFile "Is there a snapshot configured for all NetApp volumes (parameter 'snapshotVolumes')?"
		write-logFile "- number of snapshots (snapshotVolumes): $($script:snapshotList.count)"
		write-logFile "- number of mount points (createVolumes, createDisks): $script:mountPointsCount"
		write-logFileWarning "Wrong/missing parameter 'snapshotVolumes' could result in data loss"
		write-logFile
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
	if (($setVmDeploymentOrder.count -eq 0) -and ($ignoreTags -ne $True)) {

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
			if ($script:tipEnabled -ne $True) {
				write-logFileError "Parameter 'setVmTipGroup' not allowed" `
									"Subscription is not TiP-enabled"
			}
		}

		get-ParameterRule
	}

	# update from tag (if parameter setVmTipGroup was NOT used)
	if (($setVmTipGroup.count -eq 0) `
	-and ($createAvailabilitySet.count -eq 0) `
	-and ($createProximityPlacementGroup.count -eq 0) `
	-and ($ignoreTags -ne $True) `
	-and ($script:tipEnabled -eq $True)) {

		$script:copyVMs.values
		| ForEach-Object {

			$tipGroup = $_.Tags.$azTagTipGroup -as [int]
			if ($tipGroup -gt 0) {
				$_.Group = $tipGroup
			}
		}
	}

	$script:tipVMs = ($script:copyVMs.values | Where-Object Group -gt 0).Name
	if ($script:tipVMs.count -ne 0) {
		$script:skipProximityPlacementGroup	= $True
		$script:skipAvailabilitySet 		= $True
		$script:createProximityPlacementGroup 	= @()
		$script:createAvailabilitySet 		= @()
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
								"Syntax must be: <newName>@<oldName>"
		}
		$vmNameOld = $script:paramVMs[0]

		$vmNameNew = $script:paramConfig
		if ($Null -eq $vmNameNew) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Syntax must be: <newName>@<oldName>"
		}

		if ($vmNameNew.length -le 1) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Invalid VM name '$vmNameNew'" `
								"VM name with length 1 is not supported by RGCOPY"
		}
		if (($vmNameNew.length -gt 64) `
		-or ($vmNameNew -notmatch '^[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9]$')) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Invalid VM name '$vmNameNew'" `
								'Name must match ^[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9]$ and not longer than 64 characters'
		}

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
	if (($generalizedVMs.Count -ne 0) -and ($useBlobs -eq $True)) {
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
	$script:runningVMs = $False

	$script:copyVMs.Values
	| ForEach-Object {

		# skip all other VMs if some VMs are merged
		if (($setVmMerge.count -ne 0) -and ($_.MergeNetSubnet.length -eq 0)) {
			$_.Skip = $True
		}

		# correct status and get $script:skipVMs
		if ($_.Skip -eq $True) {
			$_.vmStatus = "skipped (will not be copied)"
			$script:skipVMs += $_.Name
		}
		# check for running VM with more than one disk/volume
		elseif ($_.vmStatus -ne 'VM deallocated') {
			if (($_.DataDisks.count + $_.MountPoints.count) -gt 1) {
				$script:runningVMs = $True
			}
		}
	}
}

#--------------------------------------------------------------
function update-paramSkipDisks {
#--------------------------------------------------------------
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
		write-logFile "Parameter 'skipDisks' requires specific settings in /etc/fstab:"
		write-logFile "- use UUID or /dev/disk/azure/scsi1/lun*-part*"
		write-logFile "- use option 'nofail' for each disk"
		write-logFileWarning "For LINUX VMs, double check /etc/fstab"
		write-logFile
	}

	# skip disks that are not attached to any VM
	if ($copyDetachedDisks -ne $True) {
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
			write-logFileError "Disk '$($_.Name)'' is an Ultra SSD disk" `
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
	param (	$paramName, $paramValue)

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
		[array] $allowedVMs = $script:copyVMs.Values.Name
	}
	else {
		[array] $allowedVMs = ($script:copyVMs.Values | Where-Object Skip -ne $True).Name
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
	set-parameter 'setVmSize' $setVmSize
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$vmSize = $script:paramConfig
		$script:copyVMs.values
		| Where-Object Name -in $script:paramVMs
		| ForEach-Object {

			if ($_.VmSize -ne $vmSize) {

				$_.VmSize = $vmSize
				write-logFileUpdates 'virtualMachines' $_.Name 'set size' $_.VmSize
			}
			else {
				write-logFileUpdates 'virtualMachines' $_.Name 'keep size' $_.VmSize
			}
		}

		get-ParameterRule
	}
}

#--------------------------------------------------------------
function test-vmSize {
#--------------------------------------------------------------
	if ($skipVmChecks -eq $True) { return }

	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$vmName = $_.Name
		$vmSize = $_.VmSize

		if ($Null -eq $script:vmFamilies[$vmSize]) {
			write-logFileError "VM consistency check failed" `
								"Size '$vmSize' of VM '$vmName' is not available in region '$targetLocation'" `
								"You can skip this check using RGCOPY parameter switch 'skipVmChecks'"
		}
	}
}

#--------------------------------------------------------------
function update-paramSetVmZone {
#--------------------------------------------------------------
	set-parameter 'setVmZone' $setVmZone
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$vmZone = $script:paramConfig
		if ($vmZone -notin @('0','1','2','3')) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"value: '$vmZone', allowed: {'0', '1', '2', '3'}"
		}
		$zoneName = $VmZone
		if ($zoneName -eq '0') { $zoneName = '0 (no zone configured)' }
		$vmZone = $vmZone -as [int]

		$script:copyVMs.values
		| Where-Object Name -in $script:paramVMs
		| ForEach-Object {

			if ($_.vmZone -ne $VmZone) {

				$_.vmZone = $VmZone
				write-logFileUpdates 'virtualMachines' $_.Name 'set zone' '' '' $zoneName
				$script:countVmZone++
			}
			else {
				write-logFileUpdates 'virtualMachines' $_.Name 'keep zone' '' '' $zoneName
			}
		}

		get-ParameterRule
	}
}

#--------------------------------------------------------------
function update-paramSetDiskSku {
#--------------------------------------------------------------
	set-parameter 'setDiskSku' $setDiskSku
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$sku = $script:paramConfig
		if ($sku -notin @('Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS')) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"value: '$vmZone', allowed: {'Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS'}"
		}

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			if (($_.SkuName -ne $sku) -and ($_.SkuName -ne 'UltraSSD_LRS')) {

				$_.SkuName = $sku
				write-logFileUpdates 'disks' $_.Name 'set SKU' $_.SkuName
				$script:countDiskSku++
			}
			else {
				write-logFileUpdates 'disks' $_.Name 'keep SKU' $_.SkuName
			}
		}

		get-ParameterRule
	}
}

#--------------------------------------------------------------
function test-diskSku {
#--------------------------------------------------------------
	if ($skipVmChecks -eq $True) { return }

	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$vmName = $_.Name
		$vmSize = $_.VmSize
		if ($Null -eq $script:vmSkus[$vmSize].PremiumIO) {
			write-logFileWarning "Could not get property 'PremiumIO' of VM size '$vmSize'"
		}
		elseif ($script:vmSkus[$vmSize].PremiumIO -ne $True) {
			
			foreach ($disk in $script:copyDisks.Values) {
				if ( ($disk.VM -eq $vmName) `
				-and ($disk.SkuName -in @('Premium_LRS', 'UltraSSD_LRS')) `
				-and ($disk.Skip -ne $True)) {

					# default value of parameter setDiskSku
					if ('setDiskSku' -notin $script:boundParameterNames) {
						write-logFileWarning "Size '$vmSize' of VM '$vmName' does not support Premium IO"
						$disk.SkuName = 'StandardSSD_LRS'
						write-logFileUpdates 'disks' $disk.Name 'set SKU' 'StandardSSD_LRS'
					}
					# parameter setDiskSku was explicitly set
					else {
						write-logFileError "VM consistency check failed" `
											"Size '$vmSize' of VM '$vmName' does not support Premium IO" `
											"You can skip this check using RGCOPY parameter switch 'skipVmChecks'"
					}
				}
			}
		}
	}
}

#--------------------------------------------------------------
function update-paramSetDiskSize {
#--------------------------------------------------------------
	set-parameter 'setDiskSize' $setDiskSize
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$diskSize_min = 32
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

			if ($_.SizeGB -gt $sizeGB) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"New size: $sizeGB GiB, current size: $($_.SizeGB) GiB" `
									"Cannot decrease disk size of disk '$($_.Name)'"
			}
			elseif ($_.SizeGB -lt $sizeGB) {

				$_.SizeGB = $sizeGB
				write-logFileUpdates 'disks' $_.Name 'set size' '' '' "$($_.SizeGB) GiB"
			}
			else {
				write-logFileUpdates 'disks' $_.Name 'keep size' '' '' "$($_.SizeGB) GiB"
			}
		}

		get-ParameterRule
	}
}

#--------------------------------------------------------------
function update-paramSetDiskTier {
#--------------------------------------------------------------
	# calculate tier of configured disk size
	update-diskTier

	set-parameter 'setDiskTier' $setDiskTier
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$tierName = $script:paramConfig.ToUpper()
		if ($tierName -notin @( 'P0', 'P1', 'P2', 'P3', 'P4', 'P6', 'P10', 'P15', 'P20', 'P30', 'P40', 'P50', 'P60', 'P70', 'P80')) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"value: '$tierName', allowed: {'P0','P1','P2','P3','P4','P6','P10','P15','P20','P30','P40','P50','P60','P70','P80'}"
		}
		$tierSizeGB = get-diskSize $tierName

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			# max performance tier is P50 for P1 .. P50
			$tierName2   = $tierName
			$tierSizeGB2 = $tierSizeGB
			if (($tierSizeGB -gt 4096) -and ($_.SizeTierGB -le 4096)) {
				$tierName2 = 'P50'
				$tierSizeGB2 = 4096
			}

			if (($tierName2 -eq 'P0') `
			-or ($_.SkuName -ne 'Premium_LRS') `
			-or ($_.SizeTierGB -ge $tierSizeGB2)) {

				$_.performanceTierName = $Null
				write-logFileUpdates 'disks' $_.Name 'delete performance tier'

			}
			elseif ($tierName2 -eq $_.performanceTierName) {
				write-logFileUpdates 'disks' $_.Name 'keep performance tier' $tierName2
			}
			else {
				$_.performanceTierName = $tierName2
				write-logFileUpdates 'disks' $_.Name 'set performance tier' $tierName2
			}
		}

		get-ParameterRule
	}

	# remove invalid performance tiers
	update-PerformanceTier

	#--------------------------------------------------------------
	# check parameter createDisksTier (higher tier for newly created disk by parameter createDisks)
	if ($createDisksTier -notin @('P2', 'P3', 'P4', 'P6', 'P10', 'P15', 'P20', 'P30', 'P40', 'P50')) {
		write-logFileError "Invalid parameter '$script:paramName'" `
							"value: '$createDisksTier', allowed: {'P2','P3','P4','P6','P10','P15','P20','P30','P40','P50'}"
	}
}

#--------------------------------------------------------------
function update-paramSetDiskCaching {
#--------------------------------------------------------------
	set-parameter 'setDiskCaching' $setDiskCaching
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$caching	= $script:paramConfig1
		$wa			= $script:paramConfig2

		if ($wa -eq 'True')			{ $waEnabled = $True }
		elseif ($wa -eq 'False')	{ $waEnabled = $False }
		elseif ($wa.length -eq 0)	{ $waEnabled = $Null }
		else {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"value: WriteAcceleratorEnabled = '$wa', allowed: {'True', 'False'}"
		}

		if (($caching -notin @('ReadOnly','ReadWrite','None', $Null))) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"value: Caching = '$caching', allowed: {'ReadOnly', 'ReadWrite', 'None'}"
		}

		$script:copyDisks.values
		| Where-Object {$_.Name -in $script:paramDisks}
		| ForEach-Object {

			# update from part caching
			if ($Null -ne $caching) {
				if ($_.Caching -ne $caching) {
					
					$_.Caching = $caching
					write-logFileUpdates 'disks' $_.Name 'set caching' $_.Caching
				}
				else {
					write-logFileUpdates 'disks' $_.Name 'keep caching' $_.Caching
				}
			}

			# update from part waEnabled
			if ($Null -ne $waEnabled) {
				if ($_.WriteAcceleratorEnabled -ne $waEnabled) {

					$_.WriteAcceleratorEnabled = $waEnabled
					write-logFileUpdates 'disks' $_.Name 'set write accelerator' $_.WriteAcceleratorEnabled
				}
				else {
					write-logFileUpdates 'disks' $_.Name 'keep write accelerator' $_.WriteAcceleratorEnabled
				}
			}
		}

		get-ParameterRule
	}
}

#--------------------------------------------------------------
function test-diskCaching {
#--------------------------------------------------------------
	if ($skipVmChecks -eq $True) { return }

	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$vmName = $_.Name
		$vmSize = $_.VmSize
		$waMax = $script:vmSkus[$vmSize].MaxWriteAcceleratorDisksAllowed
		$waCount = 0

		# get number of wa disks
		foreach ($disk in $script:copyDisks.Values) {
			if ( ($disk.VM -eq $vmName) `
			-and ($disk.WriteAcceleratorEnabled -eq $True) `
			-and ($disk.Skip -ne $True)) {

				$waCount++
			}
		}

		# check if number of wa disks does not exceed maximum
		if ($waCount -gt $waMax) {

				# default value of parameter setDiskCaching
				if ('setDiskCaching' -notin $script:boundParameterNames) {

					write-logFileWarning "Size '$vmSize' of VM '$vmName' only supports $waMax write-acceleratored disk(s)"
					# remove write accelerator on all disks
					foreach ($disk in $script:copyDisks.Values) {
						if ( ($disk.VM -eq $vmName) `
						-and ($disk.WriteAcceleratorEnabled -eq $True) `
						-and ($disk.Skip -ne $True)) {

							$disk.WriteAcceleratorEnabled = $False
							write-logFileUpdates 'disks' $disk.Name 'set write accelerator' $False
						}
					}
				}
				# parameter setDiskCaching was explicitly set
				else {
					write-logFileError "VM consistency check failed" `
										"Size '$vmSize' of VM '$vmName' only supports $waMax write-acceleratored disk(s)" `
										"You can skip this check using RGCOPY parameter switch 'skipVmChecks'"
				}
		}

		# correct disk SKU when wa is allowed
		foreach ($disk in $script:copyDisks.Values) {
			if ( ($disk.VM -eq $vmName) `
			-and ($disk.WriteAcceleratorEnabled -eq $True) `
			-and ($disk.Skip -ne $True)) {

				# correct disk SKU
				if ($disk.SkuName -notin @('Premium_LRS', 'UltraSSD_LRS')) {
					$disk.SkuName = 'Premium_LRS'
					write-logFileUpdates 'disks' $disk.Name 'set SKU' 'Premium_LRS (caused by Write Accelerator)'
				}
				# correct disk caching
				if ($disk.Caching -notin @('ReadOnly', 'None')) {
					$disk.Caching = 'ReadOnly'
					write-logFileUpdates 'disks' $disk.Name 'set caching' 'ReadOnly (caused by Write Accelerator)'
				}
			}
		}
	}
}

#--------------------------------------------------------------
function test-dataDisksCount {
#--------------------------------------------------------------
	if ($skipVmChecks -eq $True) { return }

	$script:copyVMs.Values
	| Where-Object Skip -ne $True
	| ForEach-Object {

		$vmName = $_.Name
		$vmSize = $_.VmSize
		$diskCount = $_.NewDataDiskCount
		$diskCountMax = $script:vmSkus[$vmSize].MaxDataDiskCount

		# VM consistency check
		if ($diskCountMax -le 0) {
			write-logFileWarning "Could not get property 'MaxDataDiskCount' of VM size '$vmSize'"
		}
		elseif ($diskCount -gt $diskCountMax) {
			write-logFileError "VM consistency check failed" `
								"Size '$vmSize' of VM '$vmName' only supports $diskCountMax data disk(s)" `
								"You can skip this check using RGCOPY parameter switch 'skipVmChecks'"
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
	write-actionStart "CREATE NetApp SNAPSHOTS" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	$script:snapshotList.Values
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Creation of NetApp snapshots failed"
	}
	write-actionEnd
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
	write-actionStart "CREATE SNAPSHOTS" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Creation of snapshots failed"
	}
	write-actionEnd
}

#--------------------------------------------------------------
function remove-snapshots {
#--------------------------------------------------------------
	# using parameters for parallel execution
	$scriptParameter =  "`$snapshotExtension = '$snapshotExtension';"
	$scriptParameter += "`$sourceRG = '$sourceRG';"

	# parallel running script
	$script = {
		$SnapshotName 	= "$($_.Name).$($snapshotExtension)"
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
	write-actionStart "DELETE SNAPSHOTS" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Deletion of snapshot failed"
	}
	write-actionEnd
}

#--------------------------------------------------------------
function grant-access {
#--------------------------------------------------------------
	# get access token for snapshots
	if ($useBlobsFromDisk -eq $False) {

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
		write-actionStart "GRANT ACCESS TO SNAPSHOTS" $maxDOP
		$param = get-scriptBlockParam $scriptParameter $script $maxDOP
		$script:copyDisks.Values
		| Where-Object Skip -ne $True
		| ForEach-Object @param
		| Tee-Object -FilePath $logPath -append
		| Out-Host
		if (!$?) {
			write-logFileError "Grant Access to snapshot failed"
		}
		write-actionEnd
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
		write-actionStart "GRANT ACCESS TO DISKS" $maxDOP
		$param = get-scriptBlockParam $scriptParameter $script $maxDOP
		$script:copyDisks.Values
		| Where-Object Skip -ne $True
		| ForEach-Object @param
		| Tee-Object -FilePath $logPath -append
		| Out-Host
		if (!$?) {
			write-logFileError "Grant Access to disk failed"
		}
		write-actionEnd
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
	write-actionStart "REVOKE ACCESS FROM DISKS" $maxDOP
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
							$error[0]
	}
	write-actionEnd
}

#--------------------------------------------------------------
function get-saKey {
#--------------------------------------------------------------
	param (	$mySub, $myRG, $mySA)

	$savedSub = $script:currentSub
	set-context $mySub # *** CHANGE SUBSCRIPTION **************

	# Get Storage Account KEY
	$mySaKey = (Get-AzStorageAccountKey `
						-ResourceGroupName	$myRG `
						-AccountName 		$mySA `
						-ErrorAction 'SilentlyContinue' | Where-Object KeyName -eq 'key1').Value
	if (!$?) {
		write-logFileError "Could not get key for Storage Account '$mySA'" `
							"Get-AzStorageAccountKey failed" `
							'' $error[0]
	}

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
		if (!$?) {throw "Creation of Storage Account BLOB $($_.Name).vhd failed"}

		Write-Output "$($_.Name).vhd"
	}

	# start execution
	write-actionStart "START COPY TO BLOB" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Creation of Storage Account BLOB failed"
	}
	write-actionEnd
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
	write-actionStart "STOP COPY TO BLOB" $maxDOP
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	$script:copyDisks.Values
	| Where-Object Skip -ne $True
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Stop Copy Disk failed"
	}
	write-actionEnd
}

#--------------------------------------------------------------
function wait-copyBlobs {
#--------------------------------------------------------------
	write-actionStart "CHECK BLOB COPY STATUS (every $waitBlobsTimeSec seconds)"

	if ($Null -eq $script:targetSaKey) {
		$script:targetSaKey = get-saKey $targetSub $targetRG $targetSA
	}

	$destinationContext = New-AzStorageContext `
		-StorageAccountName   $targetSA `
		-StorageAccountKey    $script:targetSaKey `
		-ErrorAction 'SilentlyContinue'
	if (!$?) {
		write-logFileError "Could not get context for Storage Account '$targetSA'" `
							"New-AzStorageContext failed" `
							'' $error[0]
	}

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
										$error[0]
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
	write-actionEnd
}

#--------------------------------------------------------------
function get-subnetsFunction {
#--------------------------------------------------------------
	param (	$subnetID)
	# convert resourceString to resourceFunction
	# change vnet name for remote networks
	# collect remote vnets/subnets in $script:subnetIDs

	$r = get-resourceComponents $subnetID
	$vnetRG  = $r.resourceGroup
	$subnet  = $r.subResourceName
	$vnetOld = $r.mainResourceName
	$vnetNew = $vnetOld

	# already resourceFunction supplied
	if ($Null -eq $vnetRG) { return $subnetID, $vnetNew }

	# resource NOT in same subscription
	if ($r.subscriptionID -ne $sourceSubID) {
		write-logFileError "Reference to different subscription $($r.subscriptionID) not allowed"
	}

	# resource MOT in sourceRG
	if ($vnetRG -ne $sourceRG) {

		$vnetNew = $vnetOld + '_' + $vnetRG
		$vnetNew = $vnetNew -replace '[\.\-\(\)]', ''
		$len = (80, $vnetNew.Length | Measure-Object -Minimum).Minimum
		$vnetNew = $vnetNew.SubString(0,$len)

		$vnetID = get-resourceString `
					$sourceSubID		$vnetRG `
					'Microsoft.Network' `
					'virtualNetworks'	$vnetOld

		$resFunc = get-resourceFunction `
					'Microsoft.Network' `
					'virtualNetworks'	$vnetNew `
					'subnets' 			$subnet

		# collect resource groups
		$script:vnetRGs[$vnetRG] = @{
			resourceGroup 	= $vnetRG
		}
		# collect subnets
		$script:subnetIDs[$subnetID] = @{
			subnetID 		= $subnetID
			resourceGroup	= $vnetRG
		}
		# collect vnets (in subnetIDs)
		$script:subnetIDs[$vnetID] = @{
			subnetID 		= $vnetID
			resourceGroup	= $vnetRG
		}
	}
	# resource in sourceRG
	else {
		$resFunc = get-resourceFunction `
					'Microsoft.Network' `
					'virtualNetworks'	$vnetOld `
					'subnets'			$subnet
	}
	# return resourceFunction
	return $resFunc, $vnetNew
}

#--------------------------------------------------------------
function update-subnetsRemote {
#--------------------------------------------------------------
	param (	$resourceType,
			$configName)
	# Update references to subnet to local resource functions

	# process AMS
	if ($configName -eq 'monitorSubnet') {

		$script:resourcesAMS
		| Where-Object type -eq 'Microsoft.HanaOnAzure/sapMonitors'
		| ForEach-Object -Process {

			$resFuncNew, $vnetNew = get-subnetsFunction $_.properties.monitorSubnet
			if ($True -ne (compare-resources $_.properties.monitorSubnet   $resFuncNew)) {
				$_.properties.monitorSubnet = $resFuncNew
				write-logFileUpdates 'sapMonitors' $_.name 'set vnet' $vnetNew
			}
		}
	}

	# process NIC/LB/Bastion
	else {
		$x,$type = $resourceType -split '/'

		$script:resourcesALL
		| Where-Object type -eq $resourceType
		| ForEach-Object -Process {

			foreach($conf in $_.properties.$configName) {

				$resFuncOld = $conf.properties.subnet.id
				$resFuncNew, $vnetNew = get-subnetsFunction $resFuncOld

				if ($True -ne (compare-resources $resFuncOld $resFuncNew)) {
					$conf.properties.subnet.id = $resFuncNew
					write-logFileUpdates $type $_.name 'set vnet' $vnetNew
				}

				# update dependencies
				if ($resFuncOld[0] -eq '/') {
					[array] $_.dependsOn += $resFuncNew
				}
			}
		}
	}
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

	# find subnets in different resource groups
	$script:vnetRGs = @{}
	$script:subnetIDs = @{}
	update-subnetsRemote 'Microsoft.Network/networkInterfaces' 'ipConfigurations'
	update-subnetsRemote 'Microsoft.Network/loadBalancers' 'frontendIPConfigurations'
	update-subnetsRemote 'Microsoft.Network/bastionHosts' 'ipConfigurations'
	update-subnetsRemote 'Microsoft.HanaOnAzure/sapMonitors' 'monitorSubnet'

	if ($script:vnetRGs.Values.count -ne 0) {
		write-logFileWarning 'Virtual Network from other resource group used'
	}

	# get templates from different resource groups
	$script:vnetRGs.Values
	| ForEach-Object {

		# get template for vnet and subnet
		$vnetRG = $_.resourceGroup
		[array] $myIds = ($script:subnetIDs.Values | Where-Object resourceGroup -eq $vnetRG).subnetID
		$vnetTemplate = get-partTemplate $myIds $vnetRG 'VNETs'

		# create VNET that refers to different subscription
		# minimal VNET: no networkSecurityGroups etc.
		$vnetTemplate.resources
		| Where-Object type -eq 'Microsoft.Network/virtualNetworks'
		| ForEach-Object -Process {

			# new VNET name
			$vnetOld = $_.name
			$vnetNew = $vnetOld + '_' + $vnetRG
			$vnetNew = $vnetNew -replace '[\.\-\(\)]', ''
			$len = (80, $vnetNew.Length | Measure-Object -Minimum).Minimum
			$vnetNew = $vnetNew.SubString(0,$len)

			write-logFileWarning "provisional virtual network $vnetNew created"

			# new VNET resource function
			$resFunction =get-resourceFunction `
				'Microsoft.Network' `
				'virtualNetworks'	$vnetNew

			# get subnets
			$subnets = @()
			foreach ($subnet in $_.properties.subnets) {

				$subnet = @{
					name 		= $subnet.name
					properties 	= @{
						addressPrefix = $subnet.properties.addressPrefix
					}
				}
				[array] $subnets += $subnet

				$subnetNameOld = "$vnetOld/$($subnet.name)"
				$subnetNameNew = "$vnetNew/$($subnet.name)"

				# get single subnet
				$vnetTemplate.resources
				| Where-Object type -eq 'Microsoft.Network/virtualNetworks/subnets'
				| Where-Object name -eq $subnetNameOld
				| ForEach-Object -Process {

					$subnetProp = @{
						addressPrefix = $_.properties.addressPrefix
					}
					$subnetRes = @{
						name 		= $subnetNameNew
						type 		= 'Microsoft.Network/virtualNetworks/subnets'
						apiVersion 	= $_.apiVersion
						dependsOn	= @( $resFunction )
						properties	= $subnetProp
					}
					write-logFileUpdates 'subnets' $subnetNameNew 'create' "as copy from $subnetNameOld"
					$script:resourcesALL += $subnetRes
				}
			}

			$vnetProp = @{
				subnets 		= $subnets
				addressSpace 	= $_.properties.addressSpace
			}
			$vnetRes = @{
				name		= $vnetNew
				type 		= 'Microsoft.Network/virtualNetworks'
				apiVersion 	= $_.apiVersion
				location	= $targetLocation
				dependsOn	= @()
				properties	= $vnetProp
			}
			write-logFileUpdates 'virtualNetworks' $vnetNew 'create' "as copy from $vnetOld"
			$script:resourcesALL += $vnetRes
		}
	}
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

			$_.properties.virtualNetworkPeerings = 	$_.properties.virtualNetworkPeerings `
													| Where-Object name -notin $remotePeerings
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
function update-acceleratedNetworking {
#--------------------------------------------------------------
	set-parameter 'setAcceleratedNetworking' $setAcceleratedNetworking 'Microsoft.Network/networkInterfaces'
	# process networkInterfaces
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/networkInterfaces'
	| ForEach-Object -Process {

		$nicName = $_.name

		# set parameter
		$value = $script:paramValues[$nicName]
		if ($Null -ne $value) {
			# make sure that property exists
			if ($Null -eq $_.properties.enableAcceleratedNetworking) {
				$_.properties.enableAcceleratedNetworking = $False
			}
			# property should be set
			if ($value -eq 'True') {
				if ($_.properties.enableAcceleratedNetworking -ne $True) {
					$_.properties.enableAcceleratedNetworking = $True
					write-logFileUpdates 'networkInterfaces' $nicName 'set Accelerated Networking' '' '' $True
					$script:countAcceleratedNetworking++
				}
				else {
					write-logFileUpdates 'networkInterfaces' $nicName 'keep Accelerated Networking' '' '' $True
				}
			}
			# property should be set to FALSE
			elseif ($value -eq 'False') {
				if ($_.properties.enableAcceleratedNetworking -ne $False) {
					$_.properties.enableAcceleratedNetworking = $False
					write-logFileUpdates 'networkInterfaces' $nicName 'set Accelerated Networking' '' '' $False
					$script:countAcceleratedNetworking++
				}
				else {
					write-logFileUpdates 'networkInterfaces' $nicName 'keep Accelerated Networking' '' '' $False
				}
			}
			else {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"value: '$value', allowed: {'True', 'False'}"
			}
		}

		# VM consistency check
		if ($skipVmChecks -ne $True) {
			if ($_.properties.enableAcceleratedNetworking -ne $False) {
				$vmName = $script:vmOfNic[$nicName]
				if ($Null -ne $vmName) {
					# NIC connected to a VM
					$vmSize = $script:copyVMs[$vmName].VmSize
					if ($Null -eq $script:vmSkus[$vmSize].AcceleratedNetworkingEnabled) {
						write-logFileWarning "Could not get property 'AcceleratedNetworkingEnabled' of VM size '$vmSize'"
					}
					elseif ($script:vmSkus[$vmSize].AcceleratedNetworkingEnabled -ne $True) {
						# default value of parameter setAcceleratedNetworking
						if ('setAcceleratedNetworking' -notin $script:boundParameterNames) {
							write-logFileWarning "Size '$vmSize' of VM '$vmName' does not support Accelerated Networking"
							$_.properties.enableAcceleratedNetworking = $False
							write-logFileUpdates 'networkInterfaces' $nicName 'set Accelerated Networking' '' '' $False
						}
						# parameter setAcceleratedNetworking was explicitly set
						else {
							write-logFileError "VM consistency check failed" `
												"Size '$vmSize' of VM '$vmName' does not support Accelerated Networking" `
												"You can skip this check using RGCOPY parameter switch 'skipVmChecks'"
						}
					}
				}
			}
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
			if ($value -notin @('Basic', 'Standard')) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"value: '$value', allowed: {'Basic', 'Standard'}"
			}

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
			if ($value -notin @('Basic', 'Standard')) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"value: '$value', allowed: {'Basic', 'Standard'}"
			}

			$old = $Null
			if ($Null -ne $_.sku) {
				$old = $_.sku.name
			}

			if ($old -ne $value) {
				write-logFileUpdates 'publicIPAddresses' $_.name 'set SKU' $value
				$_.sku = @{ name = $value }
				$script:countPublicIpSku++
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
			if ($value -notin @('Dynamic', 'Static')) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"value: '$value', allowed: {'Dynamic', 'Static'}"
			}

			if ($_.properties.publicIPAllocationMethod -ne $value) {
				$_.properties.publicIPAllocationMethod = $value
				write-logFileUpdates 'publicIPAddresses' $_.name 'set Allocation Method' $value
				$script:countPublicIpAlloc++
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
			if ($value -notin @('Dynamic', 'Static')) {
				write-logFileError "Invalid parameter '$script:paramName'" `
									"value: '$value', allowed: {'Dynamic', 'Static'}"
			}

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

		[array] $_.properties.securityRules = $_.properties.securityRules | Where-Object name -notin $deletedRules
		if ($_.properties.securityRules.count -eq 0) {
			$_.properties.securityRules = @()
		}
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

		[array] $_.dependsOn = remove-dependencies $_.dependsOn -keep 'Microsoft.Compute/proximityPlacementGroups'
	}
	
}

#--------------------------------------------------------------
function update-dependenciesVNET {
#--------------------------------------------------------------
	# remove virtualNetworkPeerings from VNET
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks'
	| ForEach-Object -Process {

		$_.properties.virtualNetworkPeerings = $Null

		# for virtualNetworkPeerings, there is a Circular dependency between VNETs
		[array] $_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/virtualNetworks'
	}

	# update virtualNetworkPeerings:
	#  originally, it is only dependent on vnets
	#  add dependency on all subnets
	$subnetIDs = @()
	# get all subnets
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks/subnets'
	| ForEach-Object -Process {

		$net, $subnet = $_.name -split '/'

		$subnetIDs += get-resourceFunction `
						'Microsoft.Network' `
						'virtualNetworks'	$net `
						'subnets'			$subnet
	}

	# workaround for following sporadic issue when deploying virtualNetworkPeerings:
	#  "code": "ReferencedResourceNotProvisioned"
	#  "message": "Cannot proceed with operation because resource <vnet> ... is not in Succeeded state."
	#  "Resource is in Updating state and the last operation that updated/is updating the resource is PutSubnetOperation."
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings'
	| ForEach-Object -Process {

		[array] $_.dependsOn += $subnetIDs
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
		[array] $_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/loadBalancers*'

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
		if ($changed -eq $True) {
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
		[array] $_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/loadBalancers/backendAddressPools'
		[array] $_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Network/loadBalancers/inboundNatRules'
		$dependsVMs = @()

		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
		| ForEach-Object -Process {

			$dependsVMs += get-resourceFunction `
							'Microsoft.Compute' `
							'virtualMachines'	$_.name
		}
		$_.dependsOn += $dependsVMs

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
		if ($changed -eq $True) {
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
		$script:resourcesALL += $deployment
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
function new-proximityPlacementGroup {
#--------------------------------------------------------------
	if (($createAvailabilitySet.count -ne 0) `
	-or ($createProximityPlacementGroup.count -ne 0) `
	-or ($setVmMerge.count -ne 0)) {

		$script:skipProximityPlacementGroup = $True
		$script:skipAvailabilitySet = $True
		write-logFileWarning "Existing Availability Sets and Proximity Placement Groups are removed"
	}

	# remove all ProximityPlacementGroups
	if ($skipProximityPlacementGroup -eq $True) {

		# remove PPGs
		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Compute/proximityPlacementGroups'
		| ForEach-Object {

			write-logFileUpdates 'proximityPlacementGroups' $_.name 'delete'
		}
		remove-resources 'Microsoft.Compute/proximityPlacementGroups'

		# update VMs
		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
		| ForEach-Object {

			if ($null -ne $_.properties.proximityPlacementGroup) {
				write-logFileUpdates 'virtualMachines' $_.name 'remove proximityPlacementGroup' 
				$_.properties.proximityPlacementGroup = $Null
				[array] $_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Compute/proximityPlacementGroups'
			}
		}

		# update AvSets
		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Compute/availabilitySets'
		| ForEach-Object {

			if ($null -ne $_.properties.proximityPlacementGroup) {
				write-logFileUpdates 'availabilitySets' $_.name 'remove proximityPlacementGroup'
				$_.properties.proximityPlacementGroup = $Null
				[array] $_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Compute/proximityPlacementGroups'
			}
		}
	}

	# create new ProximityPlacementGroup
	$script:ppgOfAvset = @{}
	$newPPGs = @()
	set-parameter 'createProximityPlacementGroup' $createProximityPlacementGroup
	get-ParameterRule
	while ($Null -ne $script:paramConfig) {

		$ppgName = $script:paramConfig
		# Name must be less than 80 characters
		# and start and end with a letter or number. You can use characters '-', '.', '_'.
		if ($ppgName.length -le 1) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Invalid Proximity Placement Group name '$ppgName'" `
								"Proximity Placement Group name with length 1 is not supported by RGCOPY"
		}
		if (($ppgName.length -gt 80) `
		-or ($ppgName -notmatch '^[a-zA-Z0-9][a-zA-Z_0-9\.\-]*[a-zA-Z0-9]+$')) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Invalid Proximity Placement Group name '$ppgName'" `
								'Name must match ^[a-zA-Z0-9][a-zA-Z_0-9\.\-]*[a-zA-Z0-9]+$ and not longer than 80 characters'
		}

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

		# PPG has not been recently created
		if (($ppgName -notin $newPPGs) -and ($setVmMerge.count -eq 0)) {
			$newPPGs += $ppgName
			write-logFileUpdates 'proximityPlacementGroups' $ppgName 'create'
			$script:resourcesALL += $res
		}

		get-ParameterRule
	}
}

#--------------------------------------------------------------
function new-availabilitySet {
#--------------------------------------------------------------

	#--------------------------------------------------------------
	# remove all availabilitySets
	if ($skipAvailabilitySet -eq $True) {
		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Compute/availabilitySets'
		| ForEach-Object {

			write-logFileUpdates 'availabilitySets' $_.name 'delete'
		}
		remove-resources 'Microsoft.Compute/availabilitySets'
	}
	#--------------------------------------------------------------
	# remove availabilitySets for TiP Groups
	else {
		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Compute/availabilitySets'
		| Where-Object name -like 'rgcopy.tipGroup*'
		| ForEach-Object {

			write-logFileUpdates 'availabilitySets' $_.name 'delete'
		}
		remove-resources 'Microsoft.Compute/availabilitySets' 'rgcopy.tipGroup*'
	}

	# update VMs
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object {

		$asID = $_.properties.availabilitySet.id
		if ($Null -ne $asID) {
			$asName = (get-resourceComponents $asID).mainResourceName

			if (($asName -like 'rgcopy.tipGroup*') `
			-or ($createAvailabilitySet.count -ne 0) `
			-or ($skipAvailabilitySet -eq $True)) {

				write-logFileUpdates 'virtualMachines' $_.name 'remove availabilitySet'
				$_.properties.availabilitySet = $Null
				[array] $_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Compute/availabilitySets'
			}
		}
	}

	#--------------------------------------------------------------
	# create new availabilitySets
	# fill [hashtable] $script:paramValues
	set-parameter 'createAvailabilitySet' $createAvailabilitySet 'Microsoft.Compute/virtualMachines'
	
	# create AvSets
	$newAvSets = @()
	$script:paramValues.values
	| ForEach-Object {

		# split configuration
		$asName, $faultDomain, $updateDomain = $_ -split '/'

		# check faultDomainCount
		$faultDomainCount = $faultDomain -as [int]
		if ($faultDomainCount -le 0) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Syntax must be: AVsetName/faultDomainCount/updateDomainCount@VMs" `
								"faultDomainCount must be 1 or higher"
		}

		# check updateDomainCount
		$updateDomainCount = $updateDomain -as [int]
		if ($updateDomainCount -le 0) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Syntax must be: AVsetName/faultDomainCount/updateDomainCount@VMs" `
								"updateDomainCount must be 1 or higher"
		}

		# check name of AvailabilitySet
		# The length must be between 1 and 80 characters.
		# The first character must be a letter or number.
		# The last character must be a letter, number, or underscore.
		# The remaining characters must be letters, numbers, periods, underscores, or dashes
		if ($asName.length -le 1) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Syntax must be: AVsetName/faultDomainCount/updateDomainCount@VMs" `
								"AVsetName with length 1 is not supported by RGCOPY"
		}

		if (($asName.length -gt 80) `
		-or ($asName -like 'rgcopy.tipGroup*') `
		-or ($asName -notmatch '^[a-zA-Z0-9][a-zA-Z_0-9\.\-]*[a-zA-Z_0-9]+$')) {
			write-logFileError "Invalid parameter '$script:paramName'" `
								"Syntax must be: AVsetName/faultDomainCount/updateDomainCount@VMs" `
								'AVsetName must match ^[a-zA-Z0-9][a-zA-Z_0-9\.\-]*[a-zA-Z_0-9]+$ and not longer than 80 characters'
		}

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

		# AvSet has not been recently created
		if (($asName -notin $newAvSets) -and ($setVmMerge.count -eq 0)) {
			$newAvSets += $asName
			write-logFileUpdates 'availabilitySets' $asName 'create'
			$script:resourcesALL += $res
		}
	}
}

#--------------------------------------------------------------
function update-availabilitySet {
#--------------------------------------------------------------
	# fill [hashtable] $script:paramValues
	set-parameter 'createAvailabilitySet' $createAvailabilitySet 'Microsoft.Compute/virtualMachines'

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
			$script:copyVMs[$vmName].availabilitySet = $asName

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
				$script:copyVMs[$vmName].proximityPlacementGroup = $ppgName
				
				# add new dependency
				[array] $_.dependsOn += $ppgID
			}
		}
	}

	#--------------------------------------------------------------
	# fault domain count
	if ($skipVmChecks -ne $True) {
		# get maximun
		$script:setFaultDomainCount = 2
		$sku = (Get-AzComputeResourceSku `
					-Location $targetLocation `
					-ErrorAction 'SilentlyContinue'
				| Where-Object ResourceType -eq 'availabilitySets'
				| Where-Object Name -eq 'Aligned')

		foreach($cap in $sku.Capabilities) {
			if ($cap.Name -eq 'MaximumPlatformFaultDomainCount') {
				$script:setFaultDomainCount = $cap.Value -as [int]
			}
		}

		# corrcet fault domain count
		$valueInt = $script:setFaultDomainCount 
		if ($valueInt -lt 2) {
			$valueInt = 2
		}
		$script:resourcesALL
		| Where-Object type -eq 'Microsoft.Compute/availabilitySets'
		| ForEach-Object -Process {

			if ($_.properties.platformFaultDomainCount -gt $valueInt ) {
				write-logFileWarning "The maximum fault domain count of availability sets in region '$targetLocation' is $valueInt"
				$_.properties.platformFaultDomainCount = $valueInt
				write-logFileUpdates 'availabilitySets' $_.name 'set faultDomainCount' $valueInt
			}
		}
	}
}

#--------------------------------------------------------------
function update-proximityPlacementGroup {
#--------------------------------------------------------------
	set-parameter 'createProximityPlacementGroup' $createProximityPlacementGroup 'Microsoft.Compute/virtualMachines' 'Microsoft.Compute/availabilitySets'
	
	# update VMs and AvSets
	$script:resourcesALL
	| Where-Object type -in @('Microsoft.Compute/virtualMachines','Microsoft.Compute/availabilitySets')
	| ForEach-Object {

		$ppgName = $script:paramValues[$_.name]
		if ($null -ne $ppgName) {

			$x, $type = $_.type -split '/'
			write-logFileUpdates $type $_.name 'set proximityPlacementGroup' $ppgName
			if ($type -eq 'virtualMachines') {
				$script:copyVMs[$_.name].proximityPlacementGroup = $ppgName
			}

			$id = get-resourceFunction `
					'Microsoft.Compute' `
					'proximityPlacementGroups'	$ppgName

			$_.properties.proximityPlacementGroup = @{id = $id}
			[array] $_.dependsOn += $id
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

	# warning
	foreach ($ppg in $allPPGs.Values) {
		if (($ppg.vmsZone.count -ne 0) -and ($ppg.vmsOther.count -ne 0)) {
			write-logFileWarning "Some VMs of proximity placement group '$($ppg.name)' are using zones, some not"
			write-logFile "Use RGCOPY parameter 'setVmDeploymentOrder' to:"
			write-logFile " firstly,  create VMs: $($ppg.vmsZone)"
			write-logFile " secondly, create VMs: $($ppg.vmsOther)"
		}
	}
}

#--------------------------------------------------------------
function update-availibilityZone {
#--------------------------------------------------------------
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object -Process {

		$vmName = $_.name
		$zone = $script:copyVMs[$vmName].VmZone

		if ($zone -notin @(1,2,3)) {
			$_.zones = @()
		}
		else{
			$_.zones = @($zone)

			# check for availabilitySet:
			if ($_.properties.availabilitySet.id.length -gt 0) {

				$_.zones = @()
				$script:copyVMs[$vmName].VmZone = 0
				write-logFileUpdates 'virtualMachines' $vmName 'set zone' '' '' '0 (no zone configured)'
				write-logFileWarning "Remove Availability Zone for VM $vmName because Availability Set is used"
			}
		}
	}
}

#--------------------------------------------------------------
function update-tipSession {
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
		$script:resourcesALL += $res
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
	# change VM size
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object -Process {

		$_.properties.hardwareProfile.vmSize = $script:copyVMs[$_.name].VmSize
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
		[array] $_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Storage/StorageAccounts*'
		[array] $_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Compute/disks'

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
		[array] $dataDisks = $_.properties.storageProfile.dataDisks | Where-Object name -notin $skipDisks
		if ($dataDisks.count -eq 0) {
			$dataDisks = @()
		}
		$_.properties.storageProfile.dataDisks = $dataDisks

		# add dependency of created target storage account
		if ($useBlobs -eq $False) {
			[array] $_.dependsOn += get-resourceFunction `
										'Microsoft.Storage' `
										'storageAccounts'	"parameters('storageAccountName')" `
										'blobServices'		'default'
		}
	}
}

#--------------------------------------------------------------
function update-vmMiscellaneous {
#--------------------------------------------------------------
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Compute/virtualMachines'
	| ForEach-Object -Process {

		$vmName = $_.name
		$vmSize = $script:copyVMs[$vmName].VmSize

		#--------------------------------------------------------------
		# bootDiagnostics
		[array] $_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Storage/StorageAccounts*'

		if ($skipBootDiagnostics -eq $True) {
			# delete bootDiagnostics
			if ($Null -ne $_.properties.diagnosticsProfile) {
				write-logFileUpdates 'virtualMachines' $vmName 'delete bootDiagnostics'
				$_.properties.diagnosticsProfile = $Null
			}
		}
		else {
			# set Boot Diagnostic URI
			$_.properties.diagnosticsProfile = @{
				bootDiagnostics = @{
					storageUri = "[concat('https://', parameters('storageAccountName'), '.blob.core.windows.net/' )]"
				}
			}
			write-logFileUpdates 'virtualMachines' $vmName 'set bootDiagnostics URI' 'https://' '<storageAccountName>' '.blob.core.windows.net'
			[array] $_.dependsOn += get-resourceFunction `
										'Microsoft.Storage' `
										'storageAccounts'	"parameters('storageAccountName')"
		}

		#--------------------------------------------------------------
		# remove ultraSSDEnabled
		if ($_.properties.additionalCapabilities.ultraSSDEnabled -eq $True) {
			$_.properties.additionalCapabilities.ultraSSDEnabled = $False
			write-logFileUpdates 'virtualMachines' $vmName 'delete Ultra SSD support'
		}

		#--------------------------------------------------------------
		# VM consistency check
		if ($skipVmChecks -ne $True) {
			$nicCount = $_.properties.networkProfile.networkInterfaces.count
			$nicCountMax = $script:vmSkus[$vmSize].MaxNetworkInterfaces
			if ($nicCountMax -le 0) {
				write-logFileWarning "Could not get property 'MaxNetworkInterfaces' of VM size '$vmSize'"
			}
			elseif ($nicCount -gt $nicCountMax) {
				write-logFileError "VM consistency check failed" `
									"Size '$vmSize' of VM '$vmName' only supports $nicCountMax Network Interface(s)" `
									"You can skip this check using RGCOPY parameter switch 'skipVmChecks'"
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

				$_.dependsOn += $dependentVMs
			}
		}
	}
}

#--------------------------------------------------------------
function update-vmExtensions {
#--------------------------------------------------------------
	if ($skipExtensions -eq $True) { return }

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
		$script:resourcesALL += $res
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
					apiVersion		= '2020-09-30'
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
				$script:resourcesALL += $disk
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
			if ($useBlobs -ne $True) {
				$from = 'snapshot'
				$snapshotName = "$diskName.$snapshotExtension"
				if (($skipSnapshots -eq $True) -and ($snapshotName -notin $script:snapshotNames)) {
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
			if ($_.HyperVGeneration.count -ne 0)		{ $properties.Add('hyperVGeneration', $_.HyperVGeneration) }

			# disk object
			$sku = @{ name = $_.SkuName }
			$disk = @{
				type 			= 'Microsoft.Compute/disks'
				apiVersion		= '2020-09-30'
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
			$script:resourcesALL += $disk
			write-logFileUpdates 'disks' $diskName "create from $from" '' '' "$($_.SizeGB) GiB"

			# update VM dependency already done in function update-vmDisks
		}
	}
}

#--------------------------------------------------------------
function update-storageAccount {
#--------------------------------------------------------------
	if ($skipBootDiagnostics -eq $True) { return }

	[array] $dependsSa = get-resourceFunction `
							'Microsoft.Storage' `
							'storageAccounts'	"parameters('storageAccountName')"

	#--------------------------------------------------------------
	# add storage account
	$res = @{
		type 		= 'Microsoft.Storage/storageAccounts'
		apiVersion	= '2019-06-01'
		name 		= "[parameters('storageAccountName')]"
		location	= $targetLocation
		sku			= @{ name = 'Standard_GRS' }
		kind		= 'StorageV2'
		properties	= @{
			networkAcls = @{
				bypass			= 'AzureServices'
				defaultAction	= 'Allow'
			}
			supportsHttpsTrafficOnly	= $true
			accessTier					= 'Hot'
		}
	}
	$script:resourcesALL += $res
	write-logFileUpdates 'storageAccounts' '<storageAccountName>' 'create'

	#--------------------------------------------------------------
	# add BLOB services
	$res = @{
		type 		= 'Microsoft.Storage/storageAccounts/blobServices'
		apiVersion	= '2019-06-01'
		name 		= "[concat(parameters('storageAccountName'), '/default')]"
		sku			= @{ name = 'Standard_GRS' }
		dependsOn	= $dependsSa
		properties	= @{
			deleteRetentionPolicy = @{
				enabled = $false
			}
		}
	}
	$script:resourcesALL += $res
	write-logFileUpdates 'blobServices' 'default' 'create'

	#--------------------------------------------------------------
	# add FILE services
	$res = @{
		type 		= 'Microsoft.Storage/storageAccounts/fileServices'
		apiVersion	= '2019-06-01'
		name 		= "[concat(parameters('storageAccountName'), '/default')]"
		sku			= @{ name = 'Standard_GRS' }
		dependsOn	= $dependsSa
		properties	= @{ }
	}
	$script:resourcesALL += $res
	write-logFileUpdates 'fileServices' 'default' 'create'

	#--------------------------------------------------------------
	# add share
	[array] $depends = get-resourceFunction `
							'Microsoft.Storage' `
							'storageAccounts'	"parameters('storageAccountName')" `
							'fileServices'		'default'
	$depends += $dependsSa

	$res = @{
		type 		= 'Microsoft.Storage/storageAccounts/fileServices/shares'
		apiVersion	= '2021-02-01'
		name 		= "[concat(parameters('storageAccountName'), '/default/$targetSaContainer')]"
		dependsOn	= $depends
		properties	= @{
			shareQuota			= 5120
			enabledProtocols	= 'SMB'
			accessTier			= 'TransactionOptimized'
		}
	}
	$script:resourcesALL += $res
	write-logFileUpdates 'shares' $targetSaContainer 'create'

	#--------------------------------------------------------------
	# add container
	[array] $depends = get-resourceFunction `
							'Microsoft.Storage' `
							'storageAccounts'	"parameters('storageAccountName')" `
							'blobServices'		'default'
	$depends += $dependsSa

	$res = @{
		type 		= 'Microsoft.Storage/storageAccounts/blobServices/containers'
		apiVersion	= '2019-06-01'
		name 		= "[concat(parameters('storageAccountName'), '/default/$targetSaContainer')]"
		dependsOn	= $depends
		properties	= @{ publicAccess = 'None' }
	}
	$script:resourcesALL += $res
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
		$script:resourcesALL += $image
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
		[array] $_.dependsOn = remove-dependencies $_.dependsOn 'Microsoft.Compute/disks'
		# add dependency of image
		$_.dependsOn = $_.dependsOn + $imageId

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
	if (($skipBastion -ne $True) -and ($targetLocationDisplayName -ne 'Canary' )) {
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

	if ($script:capacityPoolGB -lt $script:mountPointsVolumesGB) {
		$script:capacityPoolGB = $script:mountPointsVolumesGB
	}

	#--------------------------------------------------------------
	# add netAppAccount
	$res = @{
		type 		= 'Microsoft.NetApp/netAppAccounts'
		apiVersion	= '2021-04-01'
		name 		= "[parameters('storageAccountName')]"
		location	= $targetLocation
		properties	= @{
			encryption = @{
				keySource = 'Microsoft.NetApp'
			}
		}
	}
	write-logFileUpdates 'netAppAccounts' '<storageAccountName>' 'create'
	$script:resourcesALL += $res
	[array] $dependsOn = get-resourceFunction `
							'Microsoft.NetApp' `
							'netAppAccounts'	"parameters('storageAccountName')"

	#--------------------------------------------------------------
	# add capacityPool
	$res = @{
		type 		= 'Microsoft.NetApp/netAppAccounts/capacityPools'
		apiVersion	= '2021-04-01'
		name 		= "[concat(parameters('storageAccountName'),'/$targetNetAppPool')]"
		location	= $targetLocation
		properties	= @{
			serviceLevel	= 'Premium'
			size			= $script:capacityPoolGB * 1024 * 1024 * 1024
			qosType			= 'Auto'
			coolAccess		= $False
		}
		dependsOn = $dependsOn
	}
	write-logFileUpdates 'capacityPools' $targetNetAppPool 'create'
	$script:resourcesALL += $res

	#--------------------------------------------------------------
	# get subnetID
	$i = 0
	$script:resourcesALL
	| Where-Object type -eq 'Microsoft.Network/virtualNetworks/subnets'
	| ForEach-Object  {

		if ($Null -ne $_.properties.delegations) {
			if ($Null -ne $_.properties.delegations.properties) {
				if ($_.properties.delegations.properties.serviceName -eq 'Microsoft.NetApp/volumes') {
					$i++
					$vnet,$subnet = $_.name -split '/'
				}
			}
		}
	}
	if ($i -eq 0) {
		write-logFileError "Invalid parameter 'createVolumes'" `
							"RGCOPY does not create a subnet for NetApp Delegation" `
							"Therefore, it must already exist in source RG"
	}

	$subnetId = get-resourceFunction `
					'Microsoft.Network' `
					'virtualNetworks'	$vnet `
					'subnets'			$subnet

	$dependsOn += $subnetId
	$dependsOn += get-resourceFunction `
					'Microsoft.NetApp' `
					'netAppAccounts'	"parameters('storageAccountName')" `
					'capacityPools'		$targetNetAppPool

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

		$_.MountPoints | Where-Object Type -eq 'NetApp' | ForEach-Object {

			$path = $_.Path
			$volumeSizeGB = $_.Size
			$volumeName = "$vmName$($path -replace '/', '-')"

			$res = @{
				type 		= 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes'
				apiVersion	= '2021-04-01'
				name 		= "[concat(parameters('storageAccountName'),'/$targetNetAppPool/$volumeName')]"
				location	= $targetLocation
				properties	= @{
					# throughputMibps				= 65536
					coolAccess					= $False
					serviceLevel				= 'Premium'
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
			$script:resourcesALL += $res
		}
	}
}

#--------------------------------------------------------------
function rename-any {
#--------------------------------------------------------------
	param (	$nameOld,
			$nameNew,
			$resourceArea,
			$mainResourceType,
			$subResourceType)

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

		$hasIP = $False

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
					$hasIP = $True
				}
			}
		}

		# save VMs with IP
		if ($hasIP -eq $True) {
			$script:mergeVMwithIP += $_.name
		}
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
		$avSetName		= $_.availabilitySet
		$ppgName		= $_.proximityPlacementGroup
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
		$enableAccNW = $True
		if ($Null -eq $script:vmSkus[$vmSize]) {
			write-logFileError "Error checking VM SKU '$vmSize'"
		}
		elseif ($script:vmSkus[$vmSize].AcceleratedNetworkingEnabled -eq $False) {
			$enableAccNW = $False
		}

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
			$_.properties.diagnosticsProfile 		= $Null
			$_.properties.availabilitySet 			= $Null
			$_.properties.proximityPlacementGroup	= $Null

			# parameter createAvailabilitySet was explicitly set
			if ($avSetName.length -ne 0) {
				$mergeAvSetNames += $avSetName
				$avSetID	= get-resourceString `
								$targetSubID		$targetRG `
								'Microsoft.Compute' `
								'availabilitySets'	$avSetName
				
				$_.properties.availabilitySet = @{ id = $avSetID }
			}

			# parameter createProximityPlacementGroup was explicitly set
			if ($ppgName.length -ne 0) {
				$mergePpgNames += $ppgName
				$ppgID		= get-resourceString `
								$targetSubID		$targetRG `
								'Microsoft.Compute' `
								'proximityPlacementGroups'	$ppgName
				
				$_.properties.proximityPlacementGroup = @{ id = $ppgID }
			}

			# keep dependency of disks
			[array] $_.dependsOn = remove-dependencies $_.dependsOn -keep 'Microsoft.Compute/disks'
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

			$nicRes.dependsOn = get-resourceFunction `
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
			$script:resourcesALL += $ipRes
		}

		# add NIC
		write-logFileUpdates 'networkInterfaces' $nicName 'create'
		$script:resourcesALL += $nicRes
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
	$res = test-resourceInTargetRG 'Availability Set'          'Get-AzAvailabilitySet'         $mergeAvSetNames  $True
	$res = test-resourceInTargetRG 'Proximity Placement Group' 'Get-AzProximityPlacementGroup' $mergePpgNames    $True
	$res = test-resourceInTargetRG 'Virtual Network'           'Get-AzVirtualNetwork'          $mergeNets        $True

	# make sure that subnet already exist
	foreach ($netSubnet in $mergeNetSubnets) {
		$net, $subnet = $netSubnet -split '/'

		[array] $currentVnet = $res | Where-Object Name -eq $net
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
	param (	$resType,
			$resFunction,
			$resNames,
			$mustExist)


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

	if (!$?) {
		write-logFileError "Could not get $resTypeName of resource group '$targetRG'" `
						"$resFunction failed" `
						'' $error[0]
	}
		
	foreach ($resName in $resNames) {
		if ($mustExist -eq $True) {
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
	param (	$level1, $level2, $level3, $level4, $level5, $level6)

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

	add-greenlist 'Microsoft.Compute/virtualMachines'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'additionalCapabilities'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'additionalCapabilities' 'ultraSSDEnabled'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'hardwareProfile'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'hardwareProfile' 'vmSize'

	add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'storageProfile' 'imageReference'

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

	# add-greenlist 'Microsoft.Compute/virtualMachines' 'osProfile'

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

	# add-greenlist 'Microsoft.Compute/virtualMachines' 'virtualMachineScaleSet' '*'

	add-greenlist 'Microsoft.Compute/virtualMachines' 'proximityPlacementGroup'
	add-greenlist 'Microsoft.Compute/virtualMachines' 'proximityPlacementGroup'	'id'

	# add-greenlist 'Microsoft.Compute/virtualMachines' 'priority'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'evictionPolicy'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'billingProfile'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'host'
	# add-greenlist 'Microsoft.Compute/virtualMachines' 'licenseType'

	# add-greenlist 'Microsoft.Compute.virtualMachines/extensions' '*'

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
	param (	[array] $level)

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
	param (	[ref] $reference,
			[string] $objectKey,
			[array] $level)

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
			[array] $reference.Value.$objectKey = $reference.Value.$objectKey | Where-Object {$_.count -ne 0}

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
			[array] $reference.Value = $reference.Value | Where-Object {$_.count -ne 0}

		# array member is string
		} else {
			# nothing to do
		}
	}
}

#--------------------------------------------------------------
function compare-greenlist {
#--------------------------------------------------------------
	if ($skipGreenlist -eq $True) { return }

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
	[array] $script:resourcesALL = $script:resourcesALL | Where-Object { (test-greenlistSingle -level $_.type) }

	# output of removed properties
	[console]::ForegroundColor = 'DarkGray'
	$script:deniedProperties.GetEnumerator()
	| Sort-Object Key
	| Select-Object @{label="Excluded resource properties (ignored by RGCOPY)"; expression={$_.Key}}
	| Format-Table
	| Tee-Object -FilePath $logPath -append
	| Out-Host

	# outout of kept properties
	$script:allowedProperties.GetEnumerator()
	| Sort-Object Key
	| Select-Object @{label="Included resources (processed by RGCOPY)"; expression={$_.Key}}
	| Format-Table
	| Tee-Object -FilePath $logPath -append
	| Out-Host

	# restore colors
	[console]::ForegroundColor = 'Gray'
}

#--------------------------------------------------------------
function remove-rgcopySpaces {
#--------------------------------------------------------------
	param ( 	$key,
			$value)

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
	$script:rgcopyParamOrig.scriptVm		= $scriptVm

	# add deploy Parameters
	get-deployParameters
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
	[array] $names = $script:rgcopyParamOrig.keys | Where-Object {$_ -ne 'rgcopyParameters'}
	[array] $names += 'rgcopyParameters'
	[array] $names = $names | Sort-Object
	$script:rgcopyParamOrig.rgcopyParameters = $names

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
	param (	$pathScript,
			$variableScript)

	write-actionStart "Run Script from `$$variableScript"

	if ($(Test-Path -Path $pathScript) -eq $False) {
		write-logFileWarning  "File not found. Script '$pathScript' not executed"
		write-actionEnd
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

	write-logFile "Script Path:         $pathScript" -ForegroundColor DarkGray
	write-logFile "Script Parameters:   $($script:rgcopyParamFlat.rgcopyParameters)" -ForegroundColor DarkGray
	write-logFile

	# invoke script with position parameters
	Invoke-Command -Script $script -ErrorAction 'SilentlyContinue' -ArgumentList $values
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Local PowerShell script failed" `
							"Script path: '$pathScript'" `
							'' $error[0]
	}

	write-actionEnd
}

#--------------------------------------------------------------
function invoke-vmScript {
#--------------------------------------------------------------
# execute script (either path to file on VM or OS command)
	param (	$pathScript,
			$variableScript,
			$resourceGroup)

	write-actionStart "Run Script from `$$variableScript"

	# prefix command: needed if command contains an @
	# in this case, you cannot specify a server name
	if ($pathScript -like 'command:*') {
		$scriptName   = $pathScript.Substring(8,$pathScript.length -8)
		$scriptServer = $scriptVM
	}
	# postfix @server
	else {
		$scriptName, $scriptServer = $pathScript -split '@'
		if ($scriptServer.count -ne 1) {
			$scriptServer = $scriptVm
		}
	}

	# script parameters
	set-rgcopyParam
	$script:rgcopyParamOrig.vmName   = $scriptServer
	$script:rgcopyParamFlat.vmName   = $scriptServer
	$script:rgcopyParamQuoted.vmName = "'$scriptServer'"

	# check VM name
	if ($resourceGroup -eq $sourceRG) {
		$vms = $script:sourceVMs
	}
	else {
		$vms = $script:targetVMs
	}

	if ($scriptServer -notin $vms.Name) {
		write-logFileError "Invalid parameter '$variableScript' or 'scriptVM'" `
							"VM '$scriptServer' not found"
	}
	# VM running?
	$powerState = ($vms | Where-Object Name -eq $scriptServer).PowerState
	if ($powerState -ne 'VM running') {
		write-logFileError "Invalid parameter '$variableScript'" `
							"VM '$scriptServer' not running"
	}
	# Windows or Linux?
	$osType = ($vms | Where-Object Name -eq $scriptServer).StorageProfile.OsDisk.OsType
	if ($osType -eq 'Linux') {
		$CommandId   = 'RunShellScript'
		$scriptParam = $script:rgcopyParamQuoted
	}
	else {
		$CommandId   = 'RunPowerShellScript'
		$scriptParam = $script:rgcopyParamFlat
	}

	if ($verboseLog) { write-logFileHashTable $scriptParam }

	# local or remote location of script?
	if ($scriptName -like 'local:*') {
		$localScriptName = $scriptName.Substring(6,$scriptName.length -6)
		if ($(Test-Path -Path $localScriptName) -eq $False) {
			write-logFileError "Invalid parameter '$variableScript'" `
								"Local script not found: '$localScriptName'"
		}
		Copy-Item $localScriptName -Destination $tempPathText
	}
	else {
		Write-Output $scriptName >$tempPathText
	}

	# script parameters
	$parameter = @{
		ResourceGroupName 	= $resourceGroup
		VMName				= $scriptServer
		CommandId			= $CommandId
		ScriptPath 			= $tempPathText
		Parameter			= $scriptParam
	}

	write-logFile -ForegroundColor DarkGray "Resource Group:      $resourceGroup"
	write-logFile -ForegroundColor DarkGray "Virtual Machine:     $scriptServer ($osType)"
	write-logFile -ForegroundColor DarkGray "Script Path:         $pathScript"
	write-logFile -ForegroundColor DarkGray "Script Parameters:   $($script:rgcopyParamFlat.rgcopyParameters)"
	write-logFile

	# execute script
	Invoke-AzVMRunCommand @parameter
	| Tee-Object -Variable result
	| Out-Null
	if ($result.Status -ne 'Succeeded') {
		write-logFileError "Executing script in VM '$scriptServer' failed" `
							"Script path: '$pathScript'" `
							'' $error[0]
	}
	else {
		write-logFile $result.Value[0].Message
		if ($result.Value[0].Message -like '*++ exit 1*') {
			write-logFileError "Script in VM '$scriptServer' returned exit code 1" `
								"Script path: '$pathScript'"
		}
	}

	Remove-Item -Path $tempPathText
	write-actionEnd
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
	}

	Export-AzResourceGroup @parameter | Out-Null
	if (!$?) {
		write-logFileError "Could not create JSON template from source RG" `
							'Error when running Export-AzResourceGroup' `
							$error[0]
	}
	write-logFile -ForegroundColor 'Cyan' "Source template saved: $importPath"
}

#--------------------------------------------------------------
function new-templateTarget {
#--------------------------------------------------------------
	# read source ARM template
	$text = Get-Content -Path $importPath

	# convert ARM template to hash table
	$script:sourceTemplate = $text | ConvertFrom-Json -Depth 20 -AsHashtable
	[array] $script:resourcesALL = $script:sourceTemplate.resources

	# count parameter changes caused by default values:
	$script:countDiskSku				= 0
	$script:countVmZone					= 0
	$script:countLoadBalancerSku		= 0
	$script:countPublicIpSku			= 0
	$script:countPublicIpAlloc			= 0
	$script:countPrivateIpAlloc			= 0
	$script:countAcceleratedNetworking	= 0
	# do not count modifications if parameter was supplied explicitly
	if('setDiskSku'					-in $script:boundParameterNames) { $countDiskSku				= -999999}
	if('setVmZone'					-in $script:boundParameterNames) { $countVmZone					= -999999}
	if('setLoadBalancerSku'			-in $script:boundParameterNames) { $countLoadBalancerSku		= -999999}
	if('setPublicIpSku'				-in $script:boundParameterNames) { $countPublicIpSku			= -999999}
	if('setPublicIpAlloc'			-in $script:boundParameterNames) { $countPublicIpAlloc			= -999999}
	if('setPrivateIpAlloc'			-in $script:boundParameterNames) { $countPrivateIpAlloc			= -999999}
	if('setAcceleratedNetworking'	-in $script:boundParameterNames) { $countAcceleratedNetworking	= -999999}

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
	update-paramSetVmSize
	test-vmSize

	update-paramSetVmZone

	update-paramSetDiskSku
	test-diskSku

	update-paramSetDiskSize
	update-paramSetDiskTier
	update-paramSetDiskCaching
	test-diskCaching

	test-dataDisksCount

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
		if (($Null -ne $_.zones) -and ($_.type -ne 'Microsoft.Compute/virtualMachines')) {
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
	$script:snapshotNames = ($script:resourcesALL | Where-Object `
		type -eq 'Microsoft.Compute/snapshots').name

	# save backendAddressPools
	$script:resourcesBAP = ($script:resourcesALL | Where-Object `
		type -eq 'Microsoft.Network/loadBalancers/backendAddressPools')

	# save AMS
	$supportedProviders = @('SapHana', 'MsSqlServer', 'PrometheusOS', 'PrometheusHaCluster') # 'SapNetweaver' not supported yet
	[array] $script:resourcesAMS = ($script:resourcesALL | Where-Object { `
			 ($_.type -eq 'Microsoft.HanaOnAzure/sapMonitors') `
		-or (($_.type -eq 'Microsoft.HanaOnAzure/sapMonitors/providerInstances') -and ($_.properties.type -in $supportedProviders)) `
	})

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

		write-logFileUpdates '*' '*' 'delete all' " (except VMs: $script:mergeVMs)"

		[array] $script:resourcesALL = $script:resourcesALL | Where-Object { `
				 ($_.type -eq 'Microsoft.Compute/virtualMachines') `
			-and ($_.name -in $script:mergeVMs) `
		}

		$script:resourcesBAP = $Null
		$script:resourcesAMS = $Null
	}

	update-storageAccount
	update-netApp

	# create PPG befor AvSet
	new-proximityPlacementGroup
	new-availabilitySet
	update-availabilitySet
	update-proximityPlacementGroup
	update-availibilityZone
	update-tipSession

	update-vmSize
	update-vmDisks
	update-vmMiscellaneous
	update-vmPriority
	update-vmExtensions

	update-acceleratedNetworking
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
	if ($renameDisks -eq $True) {
		rename-disks
	}
	# merge VMs AFTER renaming
	update-merge

	# commit modifications
	$script:sourceTemplate.resources = $script:resourcesALL

	# set parameters
	$templateParameters = @{}
	$templateParameters.Add('storageAccountName', @{type='String'; defaultValue= `
		"[toLower(take(concat(replace(replace(replace(replace(replace(resourceGroup().name,'_',''),'-',''),'.',''),'(',''),')',''),'sa'),24))]"})
	write-logFileUpdates 'ARM template parameter' '<storageAccountName>' 'create'

	$tipGroups = $script:copyVMs.values.Group | Where-Object {$_ -gt 0} | Sort-Object -Unique
	foreach ($group in $tipGroups) {
		$templateParameters.Add("tipSessionID$group",   @{type='String'; defaultValue=''})
		$templateParameters.Add("tipClusterName$group", @{type='String'; defaultValue=''})
		write-logFileUpdates 'ARM template parameter' "<tipSessionID$group>" 'create'
		write-logFileUpdates 'ARM template parameter' "<tipClusterName$group>" 'create'
	}
	$script:sourceTemplate.parameters = $templateParameters

	# changes cause by default value
	if($script:countDiskSku					-gt 0) { write-logFileWarning "Resources changed by default value: setDiskSku = $setDiskSku" }
	if($script:countVmZone					-gt 0) { write-logFileWarning "Resources changed by value: setVmZone = $setVmZone" }
	if($script:countLoadBalancerSku			-gt 0) { write-logFileWarning "Resources changed by default value: setLoadBalancerSku = $setLoadBalancerSku" }
	if($script:countPublicIpSku				-gt 0) { write-logFileWarning "Resources changed by default value: setPublicIpSku = $setPublicIpSku" }
	if($script:countPublicIpAlloc			-gt 0) { write-logFileWarning "Resources changed by default value: setPublicIpAlloc = $setPublicIpAlloc" }
	if($script:countPrivateIpAlloc			-gt 0) { write-logFileWarning "Resources changed by default value: setPrivateIpAlloc = $setPrivateIpAlloc" }
	if($script:countAcceleratedNetworking	-gt 0) { write-logFileWarning "Resources changed by default value: setAcceleratedNetworking = $setAcceleratedNetworking" }

	# output of priority
	if ($setVmDeploymentOrder.count -ne 0) {

		$script:copyVMs.Values
		| Sort-Object VmPriority,Name
		| Select-Object @{label="Deployment Order"; expression={if($_.VmPriority -ne 2147483647){$_.VmPriority}else{''}}},Name
		| Format-Table
		| Tee-Object -FilePath $logPath -append
		| Out-Host
	}
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
	param (	[string] $string)

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
	param (	[hashtable] $hash)

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
	param (	$vnet,
			$location )

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
										"RGCOPY can copy an AMS provider in a different region by using a peered network" `
										"Set RGCOPY parameter 'skipAMS' for copying all resources (except AMS) to the Target Region"
				}
			}
		}
	}
}

#--------------------------------------------------------------
function new-templateTargetAms {
#--------------------------------------------------------------
	if ($skipAms -eq $True) {
		$script:resourcesAMS = $Null
		return
	}
	$locationsAMS = @('East US 2', 'West US 2', 'East US', 'West Europe')

	# Rename needed because of the following deployment error:
	#   keyvault.VaultsClient#CreateOrUpdate: Failure sending request
	#   "Exist soft deleted vault with the same name."

	# process AMS instance
	$i = 0
	$script:resourcesAMS
	| Where-Object type -eq 'Microsoft.HanaOnAzure/sapMonitors'
	| ForEach-Object {

		if ($i++ -gt 0) {
			write-logFileError 'Only one AMS Instance per resource group supported by RGCOPY' `
								'restart RGCOPY with ADDITIONAL parameter "skipAms"'
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
		elseif ($amsWsKeep -ne $True) {
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
		if ($amsShareAnalytics -eq $True) {
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
		$script:resourcesAMS = $Null
		return
	}

	# Module installed?
	if ($amsUsePowerShell -eq $True) {
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
		$script:resourcesAMS = $Null
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

		if ($amsUsePowerShell -eq $True) {
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
	write-logFileUpdates 'ARM template parameter' '<amsInstanceName>' 'create' '' '' '(in AMS template)'

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

		[string] $providerName = $_.name
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
											"Invalid provider name '$providerName'" `
											"Use RGCOPY switch parameter 'skipAms'"
					}
				}
			}
		}
		else {
			[array] $a = $providerName -split '/'
			if ($a.count -gt 1) {
				$providerName = $a[1]
			}
			else {
				write-logFileError "Invalid ARM template for AMS provider" `
									"Invalid provider name '$providerName'" `
									"Use RGCOPY switch parameter 'skipAms'"
			}
		}

		$providerType = $_.properties.type

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

		Write-Output  "Create AMS Provider $providerName ..."
		write-logFileHashTable $parameter

		# create AMS Provider
		$res = New-AzSapMonitorProviderInstance @parameter
		if ($res.ProvisioningState -ne 'Succeeded') {
			write-logFileError "Creation of AMS Provider '$providerName' failed" `
								"This is not an issue of RGCOPY" `
								"Check the Azure Activity Log in resource group $targetRG"
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

	write-logFile  "Create AMS Instance $amsInstanceName ..."
	write-logFileHashTable $parameter

	# create AMS Instance
	$res = New-AzSapMonitor @parameter
	if ($res.ProvisioningState -ne 'Succeeded') {
		write-logFile $myDeploymentError -ForegroundColor 'Yellow'
		write-logFile
		write-logFile 'Repeat failed deployment ...'

		# repeat deployment
		$parameter.Name = "$amsInstanceName`2"
		$script:amsInstanceName = "$amsInstanceName`2"
		$res = New-AzSapMonitor @parameter
		if ($res.ProvisioningState -ne 'Succeeded') {
			write-logFile $myDeploymentError -ForegroundColor 'Yellow'
			write-logFile
			write-logFileError "Creation of AMS Instance '$amsInstanceName' failed" `
								"This is not an issue of RGCOPY" `
								"Check the Azure Activity Log in resource group $targetRG"
		}
	}
}

#--------------------------------------------------------------
function set-deploymentParameter {
#--------------------------------------------------------------
	param (	$paramName,
			$paramValue,
			$check )

	if (($check) -and ($paramName -notin $script:availableParameters)) {
		write-logFileError "Invalid parameter 'pathArmTemplate'" `
							"ARM template is not valid: '$DeploymentPath'" `
							"ARM template parameter '$paramName' is missing"
	}
	$script:deployParameters.$paramName = $paramValue
}

#--------------------------------------------------------------
function get-deployParameters {
#--------------------------------------------------------------
	param (	$check)

	$script:deployParameters = @{}
	if ($script:tipEnabled -eq $True) {
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
					set-deploymentParameter "tipSessionID$group"   $script:paramConfig1 $check
					set-deploymentParameter "tipClusterName$group" $script:paramConfig2 $check
					$script:lastTipSessionID   = $script:paramConfig1
					$script:lastTipClusterName = $script:paramConfig2
				}
			}
			get-ParameterRule
		}
	}

	# set template parameter for storage account
	set-deploymentParameter 'storageAccountName' $targetSA $check
}

#--------------------------------------------------------------
function deploy-templateTarget {
#--------------------------------------------------------------
	param (	$DeploymentPath,
			$DeploymentName)

	write-actionStart "Deploy ARM template $DeploymentPath"

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

	# get ARM deployment parameters
	get-deployParameters $True
	$parameter.TemplateParameterObject = $script:deployParameters
	write-logFileHashTable $parameter

	# deploy
	New-AzResourceGroupDeployment @parameter
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFile $myDeploymentError -ForegroundColor 'yellow'
		write-logFileError "Deployment '$DeploymentName' failed" `
							"Check the Azure Activity Log in resource group $targetRG"
	}

	write-actionEnd
}

#--------------------------------------------------------------
function deploy-templateTargetAms {
#--------------------------------------------------------------
	param (	$DeploymentPath,
			$DeploymentName)

	# deploy using ARM template
	write-actionStart "Deploy ARM template $DeploymentPath"

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
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFile $myDeploymentError -ForegroundColor 'Yellow'
		write-logFile
		write-logFile 'Repeat failed deployment ...'
		write-logFile

		# repeat deployment
		$parameter.TemplateParameterObject 	=  @{ amsInstanceName = "$amsInstanceName`2" }
		$parameter.name 					= "$DeploymentName`2"
		New-AzResourceGroupDeployment @parameter
		| Tee-Object -FilePath $logPath -append
		| Out-Host
		if (!$?) {
			write-logFile $myDeploymentError -ForegroundColor 'yellow'
			write-logFileError "AMS deployment '$DeploymentName' failed" `
								"Check the Azure Activity Log in resource group $targetRG"
		}
	}

	write-actionEnd
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

	write-actionStart "Deploy VM Azure Enhanced Monitoring Extension (VMAEME) for SAP"
	$param = get-scriptBlockParam $scriptParameter $script $maxDOP
	$installExtensionsSapMonitor
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {write-logFileWarning "Deployment of VMAEME for SAP failed"}

	write-actionEnd
}

#--------------------------------------------------------------
function stop-VMs {
#--------------------------------------------------------------
	param (	$resourceGroup)

	if ($script:mergeVMs.count -ne 0) {
		write-actionStart "Stop ONLY MERGED VMs in Resource Group $resourceGroup" $maxDOP
		$VMs = $script:mergeVMs
	}
	else {
		write-actionStart "Stop VMs in Resource Group $resourceGroup" $maxDOP
		$VMs = (Get-AzVM -ResourceGroupName $resourceGroup -ErrorAction 'SilentlyContinue').Name
		if (!$?) {
			write-logFileError "Could not get VM names in resource group $resourceGroup" `
								"Get-AzVM failed"
		}
	}

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
	$VMs
	| ForEach-Object @param
	| Tee-Object -FilePath $logPath -append
	| Out-Host
	if (!$?) {
		write-logFileError "Could not stop VMs in resource group $resourceGroup" `
							"Stop-AzVM failed"
	}

	write-actionEnd
}

#--------------------------------------------------------------
function start-VMsParallel {
#--------------------------------------------------------------
	param (	[array] $VMs)

	# using parameters for parallel execution
	$scriptParameter =  "`$sourceRG = '$sourceRG';"

	# parallel running script
	$script = {

		if ($_.length -ne 0) {
			Write-Output "... starting $($_)"

			Start-AzVM `
			-Name 				$_ `
			-ResourceGroupName 	$sourceRG `
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
		write-logFileError "Could not start VMs in resource group $sourceRG" `
							"Start-AzVM failed"
	}
}

#--------------------------------------------------------------
function start-VMs{
#--------------------------------------------------------------
	write-actionStart "Start VMs in Resource Group $sourceRG" $maxDOP
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
				start-VMsParallel $currentVMs
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
		start-VMsParallel $currentVMs
	}
	$script:vmsAlreadyStarted = $True
	write-actionEnd
}

#--------------------------------------------------------------
function start-sap {
#--------------------------------------------------------------
	param (	$resourceGroup)

	if (($skipStartSAP -eq $True) -or ($script:sapAlreadyStarted -eq $True)) {
		return $True
	}

	if (($scriptVm.length -eq 0) -and ($scriptStartSapPath -notlike '*@*')) {
		write-logFileWarning "RGCOPY parameter 'scriptVm' not set. SAP not started."
		return $False
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
	param (	$vmName,
			$tagName,
			$tagValue, 
			[ref] $refPath )

	if ($Null -ne $tag) {
		if ($refPath.Value.length -eq 0) {
			$refPath.Value = $tagValue
			write-logFile "Using Tag of VM '$vmName': $tagName = '$tagValue'"
		}
		if ($script:scriptVm.length -eq 0) {
			$script:scriptVm = $vmName
		}
	}
}`



#--------------------------------------------------------------
function get-allFromTags {
#--------------------------------------------------------------
	param (	[array] $vms)

	if (($ignoreTags -eq $True) -or ($script:tagsAlreadyRead -eq $True)) {
		return
	}
	$script:tagsAlreadyRead = $True

	$vmsFromTag = @()
	foreach ($vm in $vms) {
		[hashtable] $tags = $vm.Tags
		$vmName = $vm.Name

		# updates variables from tags
		get-pathFromTags $vmName $azTagScriptStartSap      $tags.$azTagScriptStartSap      ([ref] $script:scriptStartSapPath)
		get-pathFromTags $vmName $azTagScriptStartLoad     $tags.$azTagScriptStartLoad     ([ref] $script:scriptStartLoadPath)
		get-pathFromTags $vmName $azTagScriptStartAnalysis $tags.$azTagScriptStartAnalysis ([ref] $script:scriptStartAnalysisPath)

		# tag azTagSapMonitor
		if (($tags.$azTagSapMonitor -eq 'true') -and ($script:installExtensionsSapMonitor.count -eq 0)) {
			$vmsFromTag += $vmName
			write-logFile "Using Tag of VM '$vmName': $azTagSapMonitor = 'true'"
		}

		# tag azTagTipGroup
		$tipGroup = $tags.$azTagTipGroup -as [int]
		if (($tipGroup -gt 0) -and ($setVmTipGroup.count -eq 0)) {
			write-logFile "Using Tag of VM '$vmName': $azTagTipGroup = $tipGroup"
		}

		# tag azTagDeploymentOrder
		$priority = $tags.$azTagDeploymentOrder -as [int]
		if (($priority -gt 0) -and ($setVmDeploymentOrder.count -eq 0)) {
			write-logFile "Using Tag of VM '$vmName': $azTagDeploymentOrder = $priority"
		}
	}

	if ($script:installExtensionsSapMonitor.count -eq 0) {
		$script:installExtensionsSapMonitor = $vmsFromTag
	}
	write-logFile
}

#--------------------------------------------------------------
function new-storageAccount {
#--------------------------------------------------------------
param (	$mySub, $myRG, $mySA, $myLocation)

	if (($smbTierStandard -ne $True) -and ($mySA -eq $sourceSA)) {
		$SkuName = 'Premium_LRS'
		$Kind    = 'FileStorage'
	}
	else {
		$SkuName = 'Standard_GRS' # use 'Standard_LRS' instead?
		$Kind    = 'StorageV2'
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
			-ErrorAction 'SilentlyContinue' | Out-Null
		if (!$?) {
			write-logFileError "Could not create storage account $mySA" `
								"The storage account name must be unique in whole Azure" `
								"Retry with other values of parameter 'targetRG' or 'targetSA'" `
								$error[0]
		}
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
			write-logFileTab 'Container' $targetSaContainer 'already exists'
		}
		else {
			New-AzRmStorageContainer `
				-ResourceGroupName	$myRG `
				-AccountName		$mySA `
				-ContainerName		$targetSaContainer `
				-ErrorAction 'SilentlyContinue' | Out-Null
			if (!$?) {
				write-logFileError "Could not create container $targetSaContainer" `
									"New-AzRmStorageContainer failed" `
									'' $error[0]
			}
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
			if (!$?) {
				write-logFileError "Could not create share $sourceSaShare" `
									"New-AzRmStorageShare failed" `
									'' $error[0]
			}
			write-logFileTab 'Share' $sourceSaShare 'created'
		}
	}
	write-logFile
	set-context $savedSub # *** CHANGE SUBSCRIPTION **************
}

#--------------------------------------------------------------
function new-resourceGroup {
#--------------------------------------------------------------
	if (($skipDeployment -ne $True) -or ($skipBlobs -ne $True)) {

		$savedSub = $script:currentSub
		set-context $targetSub # *** CHANGE SUBSCRIPTION **************
		Get-AzResourceGroup `
			-Name 	$targetRG `
			-ErrorAction 'SilentlyContinue' | Out-Null
		if ($?) {
			write-logFileTab 'Resource Group' $targetRG 'already exists'
			if ($skipDiskChecks -ne $True) {

				# Get target disks
				$disksTarget = Get-AzDisk `
									-ResourceGroupName $targetRG `
									-ErrorAction 'SilentlyContinue'
				if (!$?) {
					write-logFileError "Could not get disks of resource group '$targetRG'" `
										'Get-AzDisk failed' `
										'' $error[0]
				}
	
				# check if targetRG already contains disks
				if (($disksTarget.count -ne 0) -and ($setVmMerge.count -eq 0)) {
					
					write-logFileError "Target resource group '$targetRG' already contains resources (disks)" `
										"This is only allowed when parameters 'setVmMerge' is used" `
										"You can skip this check using RGCOPY parameter switch 'skipDiskChecks'"
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
			if (!$?) {
				write-logFileError "Could not create resource Group $targetRG" `
									"New-AzResourceGroup failed" `
									'' $error[0]
			}
			write-logFileTab 'Resource Group' $targetRG 'created'
		}
		set-context $savedSub # *** CHANGE SUBSCRIPTION **************
	}

	if ($skipBlobs -ne $True) {
		new-storageAccount $targetSub $targetRG $targetSA $targetLocation
	}
}

#--------------------------------------------------------------
function invoke-mountPoint {
#--------------------------------------------------------------
	param (	$resourceGroup, $scriptVm, $scriptName, $scriptParam)

	Write-Output $scriptName >$tempPathText
	$parameter = @{
		ResourceGroupName 	= $resourceGroup
		VMName            	= $scriptVM
		CommandId         	= 'RunShellScript'
		scriptPath 			= $tempPathText
	}
	if ($scriptParam.length -ne 0) {
		$parameter.Add('Parameter', @{arg1 = $scriptParam})
	}
	Invoke-AzVMRunCommand @parameter | Tee-Object -Variable result | Out-Null

	if     ($result.Value[0].Message -like '*++ exit 0*')	{ $status = 0 }
	elseif ($result.Value[0].Message -like '*++ exit 2*')	{ $status = 2 }
	else 													{ $status = 1 }

	if ($status -eq 1)			{ write-logFileWarning $result.Value[0].Message }
	elseif ($verboseLog -eq $True) { write-logFile        $result.Value[0].Message }

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

	write-actionStart "CHECK STATUS OF BACKGROUND JOBS (every $waitBlobsTimeSec seconds)"
	do {
		Write-logFile
		write-logFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz')
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
	write-actionEnd
}

#--------------------------------------------------------------
function backup-mountPoint {
#--------------------------------------------------------------
param (	$simulate)

if ($simulate -eq $True) {

	$script:runningTasks = @()
	$script:copyVMs.values
	| Where-Object {$_.MountPoints.count -ne 0}
	| ForEach-Object {

		$script:runningTasks += @{
			vmName 		= $_.Name
			mountPoints	= $_.MountPoints.Path
			action		= 'backup'
			finished 	= $False
		}
	}
	return
}

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

	write-actionStart "BACKUP VOLUMES/DISKS to SMB share"
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
	write-actionEnd
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
	try {
		$volumes = Get-AzNetAppFilesVolume `
					-ResourceGroupName	$targetRG `
					-AccountName		$targetSA `
					-PoolName			$targetNetAppPool `
					-ErrorAction		'Stop'
	}
	catch { $volumes = $Null }

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

	if ($continueRestore -eq $True)	{ $scriptFunction = $script1 +            $script3 }
	else							{ $scriptFunction = $script1 + $script2 + $script3 }

	write-actionStart 'RESTORE VOLUMES/DISKS from SMB share'
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
	write-actionEnd
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
		write-logFileError $error[0]
	}

	# check TiP parameters
	if ($subProp -lt 2) {
		if (($setGroupTipSession.count -ne 0) -or ($setVmTipGroup.count -ne 0)) {
			write-logFileWarning 'Target Subscription is not TiP enabled'
		}
		$script:tipEnabled = $False
	}
	else {
		$script:tipEnabled = $True
	}
}

#-------------------------------------------------------------
function step-prepare {
#--------------------------------------------------------------
	new-resourceGroup
	write-logFile

	if ($allowRunningVMs -eq $True) {
		write-logFileWarning 'Parameter allowRunningVMs is set. This could result in inconsistent disk copies.'
		write-logFile
	}

	# get source VMs/Disks
	if (($skipArmTemplate -eq $False) `
	-or ($skipSnapshots -eq $False) `
	-or (($useBlobs -eq $True) -and ($skipBlobs -eq $False)) ) {

		get-sourceVMs
		assert-vmsStopped

		get-allFromTags $script:sourceVMs
	}
}

#--------------------------------------------------------------
function step-snapshots {
#--------------------------------------------------------------
	if ($skipSnapshots -eq $True) { return }

	# run PreSnapshotScript
	if ($pathPreSnapshotScript.length -ne 0) {
		if ($useBlobsFromDisk -eq $True) {
			write-logFileError "Invalid parameter 'pathPreSnapshotScript'" `
								"Parameter not allowed together with 'useBlobsFromDisk'"
		}

		start-VMs
		start-sap $sourceRG | Out-Null
		invoke-localScript $pathPreSnapshotScript 'pathPreSnapshotScript'
		stop-VMs $sourceRG
	}

	# create snapshots
	new-snapshots
	new-SnapshotsVolumes
}

#--------------------------------------------------------------
function step-backups {
#--------------------------------------------------------------
	if (($script:mountPointsCount -eq 0) -or ($skipBackups -eq $True)) { return }

	if ($restartBlobs -eq $True) {
		backup-mountPoint $True # simulate for filling $script:runningTask
		return
	}

	start-VMs # HANA and SAP must NOT auto-start
	backup-mountPoint

	# wait for backup finished (if this is not done in step-blobs)
	if (($useBlobs -eq $False) -or ($skipBlobs -eq $True)) {
		wait-mountPoint
	}
}

#--------------------------------------------------------------
function step-armTemplate {
#--------------------------------------------------------------
	if ($skipArmTemplate -eq $True) { return }

	#--------------------------------------------------------------
	write-actionStart "Create ARM templates"
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

	# write AMS template to local file
	if ($script:resourcesAMS.count -ne 0) {
		$text = $script:amsTemplate | ConvertTo-Json -Depth 20
		Set-Content -Path $exportPathAms -Value $text -ErrorAction 'SilentlyContinue'
		if (!$?) {
			write-logFileError "Could not save Azure Monitoring for SAP template" `
								"Failed writing file '$exportPathAms'"
		}
		write-logFile -ForegroundColor 'Cyan' "Azure Monitoring for SAP template: $exportPathAms"
	}
	else {
		Remove-Item $exportPathAms -ErrorAction 'SilentlyContinue'
		write-logFile "Delete file if exists: $exportPathAms"
	}
	write-actionEnd

	#--------------------------------------------------------------
	write-actionStart "Configured VMs/disks for Target Resource Group $targetRG"
	show-targetVMs
	compare-quota
	write-actionEnd
}

#--------------------------------------------------------------
function step-blobs {
#--------------------------------------------------------------
	if (($useBlobs -eq $False) -or ($skipBlobs -eq $True)) { return }

	if ($restartBlobs -ne $True) {
		grant-access
		start-copyBlobs
	}
	wait-copyBlobs
	revoke-access

	if ($script:runningTasks.count -ne 0) {
		wait-mountPoint
	}
}

#--------------------------------------------------------------
function step-deployment {
#--------------------------------------------------------------
	if ($skipDeployment -eq $True) { return }

	#--------------------------------------------------------------
	# Deploy Virtual Machines
	if ($skipDeploymentVMs -ne $True) {
		deploy-templateTarget $exportPath "$sourceRG.$timestampSuffix"
	}

	# get VMs and tags of targetRG
	[array] $script:targetVMs = Get-AzVM `
								-ResourceGroupName $targetRG `
								-status `
								-ErrorAction 'SilentlyContinue'
	if ($script:targetVMs.count -eq 0) {
		write-logFileError "No VM found in targetRG '$targetRG'" `
							"Get-AzVM failed" `
							'' $error[0]
	}
	get-allFromTags $script:targetVMs

	#--------------------------------------------------------------
	# Restore files
	if ($skipRestore -ne $True) { restore-mountPoint }
	if ($skipRestore -ne $True) { wait-mountPoint }

	#--------------------------------------------------------------
	# Deploy Azure Monitor for SAP
	if (($skipDeploymentAms -ne $True) -and ($(Test-Path -Path $exportPathAms) -eq $True)) {

		$done = start-sap $targetRG
		if ($done -eq $False) {
			write-logFileWarning "Azure Monitor for SAP (AMS) could not be deployed because SAP is not running"
		}
		else {
			# deploy using ARM template
			if ($amsUsePowerShell -ne $True) {
				deploy-templateTargetAms $exportPathAms "$sourceRG`-AMS.$timestampSuffix"
			}
			# deploy using cmdlets
			else {
				write-actionStart "Deploy AMS instance"
				$text = Get-Content -Path $exportPathAms -ErrorAction 'SilentlyContinue'
				if (!$?) {
					write-logFileError "Could not read file '$DeploymentPath'"
				}
				$json = $text | ConvertFrom-Json -AsHashtable -Depth 20
				$script:resourcesAMS = $json.resources
				new-amsInstance
				new-amsProviders
				write-actionEnd
			}
		}
	}

	#--------------------------------------------------------------
	# Deploy Extensions
	if ($skipExtensions -ne $True) {
		deploy-sapMonitor
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
	if ($startWorkload -ne $True) { return }

	# get VMs and tags of targetRG
	if ($script:targetVMs.count -eq 0) {
		[array] $script:targetVMs = Get-AzVM `
									-ResourceGroupName $targetRG `
									-status `
									-ErrorAction 'SilentlyContinue'
		if ($script:targetVMs.count -eq 0) {
			write-logFileError "No VM found in targetRG '$targetRG'" `
								"Get-AzVM failed" `
								'' $error[0]
		}
		get-allFromTags $script:targetVMs
	}

	# start workload
	$done = start-sap $targetRG
	if ($done -eq $False) {
		write-logFileError "Workload could not be started because SAP is not running"
	}
	else {
		if ($scriptStartLoadPath.length -eq 0) {
			write-logFileWarning 'RGCOPY parameter "scriptStartLoadPath" not set. Workload not started.'
		}
		else {
			invoke-vmScript $scriptStartLoadPath 'scriptStartLoadPath' $targetRG
		}

		# start analysis
		if ($scriptStartAnalysisPath.length -eq 0) {
			write-logFileWarning 'RGCOPY parameter "scriptStartAnalysisPath" not set. Workload Analysis not started.'
		}
		else {
			invoke-vmScript $scriptStartAnalysisPath 'scriptStartAnalysisPath' $targetRG
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
# clear log file
$Null *>$logPath

try {
	# save source code as rgcopy.txt
	$text = Get-Content -Path $PSCommandPath
	Set-Content -Path $savedRgcopyPath -Value $text -ErrorAction 'SilentlyContinue'
	if (!$?) {
		write-logFileError "Could not save rgcopy backup" `
							"Failed writing file '$savedRgcopyPath'"
	}

	# get version
	foreach ($line in $text) {
		if ($line -like 'version*') {
			$main,$mid,$minor = $line -split '\.'
			$rgcopyVersion = "0.$mid.$minor"
			break
		}
	}

	$starCount = $rgcopyVersion.length + 15
	write-logFile ('*' * $starCount) -ForegroundColor DarkGray
	write-logFile "RGCOPY version $rgcopyVersion"
	write-logFile ('*' * $starCount) -ForegroundColor DarkGray
	$script:boundParameterNames = $PSBoundParameters.keys
	$script:rgcopyParamOrig = $PSBoundParameters
	write-logFileHashTable $PSBoundParameters
	
	write-logFile -ForegroundColor 'Cyan' "Log file saved: $logPath"
	if ($pathExportFolderNotFound.length -ne 0) {
		write-logFileWarning "provided path '$pathExportFolderNotFound' of parameter 'pathExportFolder' not found"
	}
	write-logFile
	write-logFile "RGCOPY STARTED: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz')"
	write-logFile
	
	#--------------------------------------------------------------
	# check files
	#--------------------------------------------------------------
	if ($pathArmTemplate.length -ne 0) {
		$skipSnapshots 		= $True
		$skipBlobs 			= $True
		$skipArmTemplate 	= $True
	
		if ($(Test-Path -Path $pathArmTemplate) -eq $False) {
			write-logFileError "Invalid parameter 'pathArmTemplate'" `
								"File not found: '$pathArmTemplate'"
		}
		$exportPath = $pathArmTemplate
	}
	
	if ($pathArmTemplateAms.length -ne 0) {
		$skipSnapshots 		= $True
		$skipBlobs 			= $True
		$skipArmTemplate 	= $True
	
		if ($(Test-Path -Path $pathArmTemplateAms) -eq $False) {
			write-logFileError "Invalid parameter 'pathArmTemplateAms'" `
								"File not found: '$pathArmTemplateAms'"
		}
		$exportPathAms = $pathArmTemplateAms
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
	
	# check Az version, at least version 5.5
	$azVersion = (Get-InstalledModule Az -MinimumVersion 5.5 -ErrorAction 'SilentlyContinue')
	if ($azVersion.count -eq 0) {
		write-logFileError 'Minimum required version of module Az is 5.5' `
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
		write-logFile "Using current Az-Context:"
		write-logFile "Subscription: $sourceSub"		-ForegroundColor 'Yellow'
		write-logFile "User:         $sourceSubUser"	-ForegroundColor 'Yellow'
		write-logFile "Tenant:       $sourceSubTenant"
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
				write-logFileWarning "using current Az-Context Subscription: $sourceSub"
				write-logFile
			}
		}
	
		# ensure that user is set
		if ($sourceSubUser.Length -eq 0) {
			$sourceSubUser = $myContext.Account.Id
			$targetSubUser = $myContext.Account.Id
			write-logFileWarning "using current Az-Context User: $sourceSubUser"
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
		write-logFileError "Source Subscription '$sourceSub' not found"
	}
	# Check Source Resource Group
	$sourceLocation = (Get-AzResourceGroup -Name $sourceRG -ErrorAction 'SilentlyContinue').Location
	if ($Null -eq $sourceLocation) {
		write-logFileError "Source Resource Group '$sourceRG' not found"
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
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************

	# check targetRG name
	if ($targetRG -notmatch '^[a-zA-Z_0-9\.\-\(\)]*[a-zA-Z_0-9\-\(\)]+$') {
		write-logFileError "Invalid parameter 'targetRG'" `
							'Name only allows alphanumeric characters, periods, underscores, hyphens and parenthesis and cannot end in a period.'
	}
	if ($targetRG.Length -gt 90) {
		write-logFileError "Invalid parameter 'targetRG'" `
							'Name only allows 90 characters.'
	}
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
	
	#--------------------------------------------------------------
	# debug actions
	#--------------------------------------------------------------
	if ($justDeleteSnapshots -eq $True) {
		get-sourceVMs
		remove-snapshots
		return
	
	} elseif ($justCopyBlobs.count -ne 0) {
		new-resourceGroup
		get-sourceVMs
		grant-access
		start-copyBlobs
		wait-copyBlobs
		revoke-access
		return
	
	} elseif ($justStopCopyBlobs -eq $True) {
		get-sourceVMs
		stop-copyBlobs
		return
	}
	
	#--------------------------------------------------------------
	# get RGCOPY steps
	#--------------------------------------------------------------
	# special case: justCreateSnapshots
	if ($justCreateSnapshots -eq $True) {
		$skipSnapshots		= $False
		$skipBlobs			= $True
		$skipArmTemplate	= $True
		$skipDeployment		= $True
	}
	
	# useBlobsFromDisk requires useBlobs
	if ($useBlobsFromDisk -eq $True) {
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
	
	# when BLOBs are not needed for ARM template, then we do not need to copy them
	if ($useBlobs -ne $True) {
		$skipBlobs = $True
	}
	
	# when BLOBs are needed but not copied (because they already exist in target RG), then we do not need snapshots
	if (($useBlobs -eq $True) -and ($skipBlobs -eq $True)) {
		$skipSnapshots = $True
	}
	
	# parameter restartBlobs
	if ($restartBlobs -eq $True) {
		# parameter makes no sense here
		if (($useBlobs -ne $True) -or ($skipBlobs -ne $False)) {
			write-logFileWarning 'RGCOPY parameter "restartBlobs" ignored'
			$restartBlobs = $False
		}
		# parameter is used
		else {
			$skipSnapshots = $True
			$skipArmTemplate = $True
		}
	}
	
	# special case: merge VMs
	if ($setVmMerge.count -ne 0) {
		$skipBackups		= $True
		$skipRestore		= $True
		$skipDeploymentAms	= $True
		$skipExtensions		= $True
		$startWorkload		= $False
		$skipBootDiagnostics = $True
		$ignoreTags 		= $True
	}
	
	# backup volumes not needed
	if (($createVolumes.count -eq 0) -and ($createDisks.count -eq 0)) {
		$skipBackups = $True
	}
	
	# special case: manually format and configure disks in target RG using:
	# - parameter continueRestore
	if ($continueRestore -eq $True) {
		$skipArmTemplate	= $True
		$skipSnapshots		= $True
		$skipBlobs			= $True
		$skipBackups		= $True
		$skipDeploymentVMs	= $True
	}
	# - parameter stopRestore
	elseif ($stopRestore -eq $True) {
		$skipRestore		= $True
		$skipDeploymentAms	= $True
		$skipExtensions		= $True
		$startWorkload		= $False
	}
	
	# some not needed steps:
	if (($installExtensionsSapMonitor.count -eq 0) -and ($installExtensionsAzureMonitor.count -eq 0)) {
		$skipExtensions = $True
	}
	if (($pathArmTemplateAms.Length -eq 0) -and ($skipAms -eq $True)) {
		$skipDeploymentAms = $True
	}
	if (($pathArmTemplate.Length -eq 0) -and ($createVolumes.count -eq 0) -and ($createDisks.count -eq 0)) {
		$skipRestore = $True
	}
	
	# output of steps
	if ($skipArmTemplate   -eq $True) {$doArmTemplate   = '[ ]'} else {$doArmTemplate   = '[X]'}
	if ($skipSnapshots     -eq $True) {$doSnapshots     = '[ ]'} else {$doSnapshots     = '[X]'}
	if ($skipBackups       -eq $True) {$doBackups       = '[ ]'} else {$doBackups       = '[X]'}
	if ($skipBlobs         -eq $True) {$doBlobs         = '[ ]'} else {$doBlobs         = '[X]'}
	if ($skipDeployment    -eq $True) {$doDeployment    = '[ ]'} else {$doDeployment    = '[X]'}
	if ($skipDeploymentVMs -eq $True) {$doDeploymentVMs = '[ ]'} else {$doDeploymentVMs = '[X]'}
	if ($skipRestore       -eq $True) {$doRestore       = '[ ]'} else {$doRestore       = '[?]'}
	if ($skipDeploymentAms -eq $True) {$doDeploymentAms = '[ ]'} else {$doDeploymentAms = '[?]'}
	if ($skipExtensions    -eq $True) {$doExtensions    = '[ ]'} else {$doExtensions    = '[X]'}
	
	if ($skipDeployment -eq $True) {
		$doDeploymentVMs = '[ ]'
		$doRestore       = '[ ]'
		$doDeploymentAms = '[ ]'
		$doExtensions    = '[ ]'
	}
	
	write-logFile 'Required steps:'
	write-logFile "  $doArmTemplate Create ARM Template (refering to snapshots or BLOBs)"
	write-logFile   "  $doSnapshots Create snapshots (of disks and volumes in source RG)"
	write-logFile     "  $doBackups Create file backup (of disks and volumes in source RG SMB Share)"
	write-logFile       "  $doBlobs Create BLOBs (in target RG container)"
	write-logFile  "  $doDeployment Deployment: $doDeploymentVMs Deploy Virtual Machines"
	write-logFile            "                  $doRestore Restore files"
	write-logFile            "                  $doDeploymentAms Deploy Azure Monitor for SAP"
	write-logFile            "                  $doExtensions Deploy Extensions"
	if ($startWorkload -eq $True) {
		write-logFile "  [X] Start workload and analysis"
	}
	write-logFile
	
	#--------------------------------------------------------------
	# run steps
	#--------------------------------------------------------------
	$script:sapAlreadyStarted = $False
	step-prepare
	step-armTemplate
	step-snapshots
	step-backups
	step-blobs
	
	set-context $targetSub # *** CHANGE SUBSCRIPTION **************
	$script:sapAlreadyStarted = $False
	step-deployment
	step-workload
	
	# stop VMs (not recommended)
	if (($stopVMs -eq $True) -and ($skipDeployment -ne $True)) {
		stop-VMs $targetRG
	}
	set-context $sourceSub # *** CHANGE SUBSCRIPTION **************
}
catch {
	Write-Output $error[0]
	Write-Output $error[0] *>>$logPath
	write-logFileError "Internal RGCOPY error" `
						$error[0]
}

write-logFile "RGCOPY ENDED: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss \U\T\Cz')" -ForegroundColor 'green'
write-zipFile 0
