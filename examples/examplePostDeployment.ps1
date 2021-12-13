# sample PowerShell script for 
# - pathPreSnapshotScript
# - pathPostDeploymentScript
#
# do NOT use Write-Host, use Write-Output instead

# script parameters:
# do NOT use param()

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
# [array] parameter:
Write-Output "Array count: $($rgcopyParameters.count)"
Write-Output ($rgcopyParameters -as [string])
Write-Output ''
# [SecureString] parameter (if supplied):
if ($Null -ne $dbPassword) {
    Write-Output (ConvertFrom-SecureString -SecureString $dbPassword -AsPlainText)
}
