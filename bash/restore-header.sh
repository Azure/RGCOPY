#!/bin/bash
# bash\restore-header.sh

# create symbolic link /mnt/waagent-download
ln -s /var/lib/waagent/run-command/download /mnt/waagent-download 2>/dev/null

$BEGIN_FUNCTION_RESTORE # restore () {

# parameters: storageAccount
storageAccount=$1
vmName=$2
blocksize_kb=$3

echo "parameter storageAccount  = $storageAccount"
echo "parameter vmName          = $vmName"
echo "parameter blocksize_kb    = $blocksize_kb"

if [ "$4" == '' ]; then 
	echo "not enough parameters"
	echo '++ exit 1'
	exit 1
fi
shift 3

# parameters mount points, nfsVolumes, luns
declare -a mountPoints
declare -a nfsVolumes
declare -a luns
declare -i i=0
while (( "$#" )); do
    mountPoints[$i]=$1;
    nfsVolumes[$i]=$2;
    luns[$i]=$3;

    echo "parameter mountPoints[$i] = $1"
    echo "parameter nfsVolumes[$i]  = $2"
    echo "parameter luns[$i]        = $3"

    if (( "$#" )); then shift; fi
    if (( "$#" )); then shift; fi
    if (( "$#" )); then shift; fi
    ((i++))
done

echo ' '
