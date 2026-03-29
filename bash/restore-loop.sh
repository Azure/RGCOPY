# bash\restore-loop.sh

# kill running older jobs
echo "kill running rgcopy-restore.sh"
pids=$(pgrep rgcopy-restore)
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

    backupLog=$backupDir/restore.log
    backupFile=$backupDir/backup.tar
    jobname="$backupDir/rgcopy-restore.sh"

    echo "mountPoint                = $mountPoint"
    echo "backupDir                 = $backupDir"
    echo "jobname                   = $jobname"

    # check mount point
    if [ ! -d $mountPoint ]; then 
        echo "mount point $mountPoint not found"
        echo '++ exit 1'
        exit 1
    fi

    cd $mountPoint

    # check backup file
    if [ ! -f $backupFile ]; then 
        echo "file $backupFile not found"
        echo '++ exit 1'
        exit 1
    fi


    # get open files, save names in array openfiles
    mapfile -t openFiles < <(lsof +D $mountPoint 2>/dev/null | awk '$5 == "REG" {print $9}')

    if (( ${#openFiles[@]} > 0 )); then
        echo "open files in $mountPoint:"
        printf '%s\n' "${openFiles[@]}"
        echo '++ exit 1'
        exit 1
    fi

    echo "using mount point:          $(pwd)"

    # remove old log file
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
