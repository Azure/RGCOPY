# bash\mount-nfs.sh

# install NFS client if needed
suse=`cat /etc/os-release | grep -i suse | wc -l`
redHat=`cat /etc/os-release | grep -i 'Red Hat' | wc -l`

# SUSE
if [ $suse -gt 0 ]; then
    if [ `zypper search -i | grep nfs-client | wc -l` -eq 0 ]; then
        echo 'zypper -n -q install nfs-client'
              zypper -n -q install nfs-client
    fi 

# RED HAT
elif [ $redHat -gt 0 ]; then
    if [ `yum list installed | grep nfs-utils | wc -l` -eq 0 ]; then
        echo 'yum -q -y install nfs-utils'
              yum -q -y install nfs-utils
    fi 

# UBUNTU
else
    if [ `apt list --installed 2>/dev/null | grep nfs-common | wc -l` -eq 0 ]; then
        echo 'apt-get install nfs-common -y 2>/dev/null'
              apt-get install nfs-common -y 2>/dev/null
    fi 
fi

# save mount command /mnt/mntrgcopy.sh
echo 'create mount file /mnt/mntrgcopy.sh'
mkdir -p /mnt/rgcopy
printf "#%c/bin/bash \nmount -t nfs $storageAccount.file.core.windows.net:/$storageAccount/rgcopy /mnt/rgcopy -o vers=4,minorversion=1,sec=sys,nconnect=4\n" ! >/mnt/mntrgcopy.sh
chmod +x /mnt/mntrgcopy.sh

# mount share /mnt/rgcopy
# not allowed running multiple RGCOPY instances (backup or restore) against same VM at the same time
umount -q /mnt/rgcopy/
/mnt/mntrgcopy.sh

# double check
if [ $(cat /etc/mtab | grep "^\S\S*\s\s*/mnt/rgcopy\s" | wc -l) -lt 1 ]; then 
    echo "share not mounted"
    echo '++ exit 1'
    exit 1
fi
echo ' '
