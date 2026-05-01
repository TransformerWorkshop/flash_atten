#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C
export LANG=C

PROJECT_ROOT=/home/host/Desktop/flash_atten
TAG=20260501_a36424a_svfearly_memguard_analyze_points
TCL="$PROJECT_ROOT/synopsys/formality/flow/fm_analyze_points_20260501_a36424a_svfearly_memguard.tcl"
LOG="$PROJECT_ROOT/synopsys/formality/logs/${TAG}.log"
MEM_LOG="$PROJECT_ROOT/synopsys/formality/logs/${TAG}_mem.log"
STATUS="$PROJECT_ROOT/synopsys/run_${TAG}.status"

: > "$STATUS"
: > "$MEM_LOG"

mem_available_mib() { awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo; }
swap_used_mib() { awk '/SwapTotal:/ {t=$2} /SwapFree:/ {f=$2} END {print int((t-f)/1024)}' /proc/meminfo; }

log_mem_snapshot() {
  local tool_pid="$1"
  {
    echo "==== $(date '+%F %T') analyze pid=$tool_pid ===="
    free -m
    ps -eo pid,ppid,pgid,comm,%mem,rss,vsz,etime,args | awk -v root="$tool_pid" 'NR==1 || $1==root || $2==root || $3==root || $9 ~ /fm_shell|fm_shell_exec/ {print}'
  } >> "$MEM_LOG" 2>&1
}

cd "$PROJECT_ROOT" || exit 2
mkdir -p synopsys/formality/logs synopsys/formality/reports/FA_TOP_BASELINE synopsys/formality/results/FA_TOP_BASELINE
rm -f fm_shell_command.lck formality.lck

echo "[$(date '+%F %T')] START analyze_points" | tee -a "$STATUS"
setsid bash -lc "fm_shell -overwrite -file '$TCL'" > "$LOG" 2>&1 &
pid=$!
echo "$pid" > "$PROJECT_ROOT/synopsys/analyze_points_${TAG}.pid"
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')

while kill -0 "$pid" 2>/dev/null; do
  log_mem_snapshot "$pid"
  avail=$(mem_available_mib)
  swap=$(swap_used_mib)
  echo "[$(date '+%F %T')] analyze_points running pid=$pid pgid=$pgid avail_mib=$avail swap_used_mib=$swap" | tee -a "$STATUS"
  if [ "$avail" -lt 1024 ] || [ "$swap" -gt 4096 ]; then
    echo "[$(date '+%F %T')] analyze_points memory guard triggered: avail_mib=$avail swap_used_mib=$swap; terminating pgid=$pgid" | tee -a "$STATUS" "$MEM_LOG"
    kill -TERM -"$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    sleep 30
    kill -KILL -"$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null
    echo "[$(date '+%F %T')] END analyze_points rc=99" | tee -a "$STATUS"
    exit 99
  fi
  sleep 30
done

wait "$pid"
rc=$?
log_mem_snapshot "$pid"
echo "[$(date '+%F %T')] END analyze_points rc=$rc" | tee -a "$STATUS"
exit "$rc"
