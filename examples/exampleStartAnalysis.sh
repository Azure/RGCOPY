#!/bin/bash

# sample shell script for 
# - scriptStartSapPath
# - scriptStartLoadPath
# - scriptStartAnalysisPath

echo "sourceSub        = $sourceSub"
echo "sourceRG         = $sourceRG"
echo "sourceLocation   = $sourceLocation"
echo "targetSub        = $targetSub"
echo "targetRG         = $targetRG"
echo "targetLocation   = $targetLocation"
# non-existing parameter:
echo "dummy            = $dummy"
# hostname of scrit that is running the VM:
echo "vmName           = $vmName"
# array as string:
echo "rgcopyParameters = $rgcopyParameters"
