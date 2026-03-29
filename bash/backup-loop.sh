# bash\backup-loop.sh

# kill running older jobs
echo "kill running rgcopy-backup.sh"
pids=$(pgrep rgcopy-backup)
for pid in $pids; do
    pkill -P "$pid"
    kill -9 "$pid"
done
echo ' '

# process mount points
len=${#mountPoints[*]}
for ((n=0; n<len; n++)); do

    mountPoint=${mountPoints[$n]}
    backupDir=/mnt/rgcopy/$vmName$mountPoint
    mkdir -p $backupDir $mountPoint

    backupLog=$backupDir/backup.log
    backupFile=$backupDir/backup.tar
    jobname="$backupDir/rgcopy-backup.sh"

    echo "mountPoint                = $mountPoint"
    echo "backupDir                 = $backupDir"
    echo "jobname                   = $jobname"

    # check mount point
    if [ -d "$mountPoint/.snapshot/rgcopy" ]; then
        # backup from snapshot (for NetApp volumes)
        cd $mountPoint/.snapshot/rgcopy

    elif [ -d $mountPoint ]; then
        # backup from original directory (for disks)
        cd $mountPoint

        # get open files, save names in array openfiles
        mapfile -t openFiles < <(lsof +D $mountPoint 2>/dev/null | awk '$5 == "REG" {print $9}')

        if (( ${#openFiles[@]} > 0 )); then
            echo "open files in $mountPoint:"
            printf '%s\n' "${openFiles[@]}"
            echo '++ exit 1'
            exit 1
        fi

    else 
        echo "mount point $mountPoint does not exist"
        echo '++ exit 1'
        exit 1
    fi

    echo "using mount point:          $(pwd)"

    # check if nofail is set when mountPoint is in fstab
    if (cat /etc/fstab | grep $mountPoint | grep -q -v nofail); then 
        echo "/etc/fstab contains entry for mount point $mountPoint but option 'nofail' is missing"
        echo '++ exit 1'
        exit 1
    fi

    # remove old log file + backup file
    rm -f $backupFile
    rm -f $backupLog

    # create job
    echo '#!/bin/bash' >$jobname
    cat >>$jobname <<'EOF_JOB'

EOF_JOB
    chmod +x $jobname
    
    # start job
    echo "starting job $jobname"
    nohup $jobname $backupFile $backupLog $blocksize_kb 2>&1 </dev/null &
done

$END_FUNCTION # }
