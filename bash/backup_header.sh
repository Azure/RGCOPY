#!/bin/bash
# bash\backup_header.sh

# create symbolic link /mnt/waagent-download
ln -s /var/lib/waagent/run-command/download /mnt/waagent-download 2>/dev/null

$BEGIN_FUNCTION_BACKUP # backup () {

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

# parameters mount points
declare -a mountPoints
declare -i i=0
while (( "$#" )); do
	mountPoints[$i]=$1
	echo "parameter mountPoints[$i] = $1"
	shift
	((i++))
done

echo ' '
