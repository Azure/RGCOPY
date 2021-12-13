# sample PowerShell script for 
# - scriptStartSapPath
# - scriptStartLoadPath
# - scriptStartAnalysisPath

# do NOT use Write-Host, use Write-Output instead

# script parameters (MANDATORY):
param(
    $sourceSub,
    $sourceRG,
    $sourceLocation,
    $targetSub,
    $targetRG,
    $targetLocation,
    $dummy,
    $vmName,
    $rgcopyParameters
)

# script body:
Write-Output "sourceSub        = $sourceSub"
Write-Output "sourceRG         = $sourceRG"
Write-Output "sourceLocation   = $sourceLocation"
Write-Output "targetSub        = $targetSub"
Write-Output "targetRG         = $targetRG"
Write-Output "targetLocation   = $targetLocation"
# non-existing parameter:
Write-Output "dummy            = $dummy"
# hostname of scrit that is running the VM:
Write-Output "vmName           = $vmName"
Write-Output ''
# array as string:
Write-Output "rgcopyParameters = $rgcopyParameters"
