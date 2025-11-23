#!/usr/bin/env bash
# rotate_logs.sh - rotate netwatch logs if over max size (in bytes)
LOG="${HOME}/netwatch/logs/netwatch.log"
MAX_BYTES="${1:-10485760}" # default 10 MB
BACKUPS=5
if [[ ! -f "$LOG" ]]; then exit 0; fi
size=$(stat -c%s "$LOG")
if (( size < MAX_BYTES )); then exit 0; fi
# rotate
for ((i=BACKUPS-1;i>=1;i--)); do
  if [[ -f "${LOG}.${i}" ]]; then mv -f "${LOG}.${i}" "${LOG}.$((i+1))"; fi
done
mv -f "$LOG" "${LOG}.1"
: > "$LOG"
