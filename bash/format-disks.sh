# process mount points
len=${#mountPoints[*]}
for ((n=0; n<len; n++)); do

	nfsVolume=${nfsVolumes[$n]}
	lunNum=${luns[$n]}
	mountPoint=${mountPoints[$n]}
    mkdir -p $mountPoint

    #-----------------------------------------------
    # new disk used for mount point
    if [[ $nfsVolume == 'null' ]]; then
        lun="lun$lunNum"

        #-----------------------------------------------
        # execute only if disk is NOT partitioned yet
        if [ "$(ls /dev/disk/azure/scsi1/$lun-part1)" == "" ]; then

            # unmount mount point
            umount -f $mountPoint

            # remove mount point from fstab
            sed -i "/^\S\S*\s\s*${mountPoint//[\/]/\\\/}\s/d" /etc/fstab
            echo systemctl daemon-reload
            systemctl daemon-reload

            # partition disk
            echo "partition disk /dev/disk/azure/scsi1/$lun"
            parted    /dev/disk/azure/scsi1/$lun --script mklabel gpt mkpart xfspart xfs 0% 100%
            sleep 1
            mkfs.xfs  /dev/disk/azure/scsi1/$lun-part1
            partprobe /dev/disk/azure/scsi1/$lun-part1

            # mount Disks
            echo "mount /dev/disk/azure/scsi1/$lun-part1 $mountPoint"
                mount /dev/disk/azure/scsi1/$lun-part1 $mountPoint
            if [ $(cat /etc/mtab | grep "^\S\S*\s\s*$mountPoint\s" | wc -l) -lt 1 ]; then 
                echo "disk not mounted at $mountPoint"
                echo '++ exit 1'
                exit 1
            fi

            # add disk to fstab
            echo "/dev/disk/azure/scsi1/$lun-part1 $mountPoint xfs defaults,nofail 0 2" >> /etc/fstab
        fi

    #-----------------------------------------------
    # new NetApp volume used for mount point
    else

        # unmount mount point
        umount -f $mountPoint

        # remove mount point from fstab
        sed -i "/^\S\S*\s\s*${mountPoint//[\/]/\\\/}\s/d" /etc/fstab
        echo systemctl daemon-reload
        systemctl daemon-reload

        # mount NFS
        echo "mount -t nfs -o rw,hard,rsize=1048576,wsize=1048576,sec=sys,vers=4.1,tcp $nfsVolume $mountPoint"
            mount -t nfs -o rw,hard,rsize=1048576,wsize=1048576,sec=sys,vers=4.1,tcp $nfsVolume $mountPoint
        
        # double check if mounted
        if [ $(cat /etc/mtab | grep "^\S\S*\s\s*$mountPoint\s" | wc -l) -lt 1 ]; then 
            echo "NFS not mounted"
            echo '++ exit 1'
            exit 1
        fi

        # add NFS to fstab
        echo "$nfsVolume $mountPoint nfs4 rw,hard,rsize=1048576,wsize=1048576,sec=sys,vers=4.1,tcp,nofail 0 0" >>/etc/fstab

    fi
    echo ' '
done
