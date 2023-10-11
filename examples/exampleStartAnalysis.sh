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
# host that is running the script:
echo "vmName           = $vmName"
echo "vmType           = $vmType"
# array as string:
echo "rgcopyParameters = $rgcopyParameters"
