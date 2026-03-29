# bash\restore-job.sh
backupFile=$1
backupLog=$2
blocksize_kb=$3

#---------------------------------
# calculate sizes
totalsize_kb=$(du --apparent-size --block-size=1024 $backupFile | cut -f1)
totalsize_gb=$(echo "scale=3; $totalsize_kb / 1024 / 1024" | bc )

block_count=$(echo "scale=3; $totalsize_kb / $blocksize_kb" | bc)
# execute 100 checkpoints (progress = 1%)
blocks_per_checkpoint=$(echo "$block_count / 100" | bc)
if [[ $blocks_per_checkpoint -lt 10 ]]; then 
    blocks_per_checkpoint=10
fi

echo ">> Backup volume size: $totalsize_gb Gib" >$backupLog
# $TAR_CHECKPOINT: number of blocks already written (not checkpoint number!)
echo ">> Block count: $block_count" >>$backupLog
echo ">> Blocks per checkpoint: $blocks_per_checkpoint" >>$backupLog

#---------------------------------
# get tar checkpoint command
action=$(cat <<'EOF_VAR'
exec='percent=`echo "$(echo "scale=6; $TAR_CHECKPOINT / block_count * 100" | bc) / 1" | bc`;
timestamp=$(date -u +"%H:%M:%S");
printf " Restore %d%% - $timestamp \n" $percent'
EOF_VAR
)
# replace 'block_count' with value of $block_count
action=${action/block_count/$block_count}

#---------------------------------
# Restore
echo ">> Restore started - $(date -u +"%H:%M:%S")" >>$backupLog
tar -xf $backupFile . \
    --record-size=$blocksize_kb\K \
    --checkpoint=$blocks_per_checkpoint \
    --checkpoint-action="$action" 2>&1 >>$backupLog
rc=$?
if [ $rc -ne 0 ]; then 
    echo "ERROR: tar return code: $rc" >>$backupLog
    echo '++ exit 1'
    exit 1
else 
    echo ">> tar return code: $rc" >>$backupLog
fi
echo ">> Restore finished - $(date -u +"%H:%M:%S")" >>$backupLog

#---------------------------------
# replace text Restore->Verify
action=${action/Restore/Verify}

# Verify
echo ">> Verify started - $(date -u +"%H:%M:%S")" >>$backupLog
tar -df $backupFile . \
    --record-size=$blocksize_kb\K \
    --checkpoint=$blocks_per_checkpoint \
    --checkpoint-action="$action" 2>&1 >>$backupLog
rc=$?
if [ $rc -ne 0 ]; then 
    echo "ERROR: tar return code: $rc" >>$backupLog
    echo '++ exit 1'
    exit 1
else 
    echo ">> tar return code: $rc" >>$backupLog; 
fi
echo ">> Verify finished - $(date -u +"%H:%M:%S")" >>$backupLog
