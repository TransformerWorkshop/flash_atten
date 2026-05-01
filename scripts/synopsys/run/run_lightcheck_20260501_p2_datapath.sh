#!/usr/bin/env bash
set -uo pipefail

export LC_ALL=C
export LANG=C

PROJECT_ROOT=/home/host/Desktop/flash_atten
TAG=20260501_p2_datapath_lightcheck
DC_TCL="$PROJECT_ROOT/synopsys/dc/flow/fa_top_baseline_lightcheck_20260501_p2_datapath.tcl"
DC_LOG="$PROJECT_ROOT/synopsys/dc/logs/fa_top_baseline_${TAG}.log"
DC_MEM_LOG="$PROJECT_ROOT/synopsys/dc/logs/fa_top_baseline_${TAG}_mem.log"
STATUS="$PROJECT_ROOT/synopsys/run_${TAG}.status"

mem_available_mib() { awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo; }
swap_used_mib() { awk '/SwapTotal:/ {t=$2} /SwapFree:/ {f=$2} END {print int((t-f)/1024)}' /proc/meminfo; }

log_mem_snapshot() {
  local logfile="$1"
  local tool_pid="$2"
  local label="$3"
  {
    echo "==== $(date '+%F %T') $label pid=$tool_pid ===="
    free -m
    ps -eo pid,ppid,pgid,comm,%mem,rss,vsz,etime,args | awk -v root="$tool_pid" 'NR==1 || $1==root || $2==root || $3==root || $9 ~ /dc_shell/ {print}'
  } >> "$logfile" 2>&1
}

run_with_guard() {
  local name="$1"; shift
  local logfile="$1"; shift
  local memlog="$1"; shift
  local cmd="$*"

  echo "[$(date '+%F %T')] START $name" | tee -a "$STATUS"
  : > "$memlog"
  setsid bash -lc "$cmd" > "$logfile" 2>&1 &
  local pid=$!
  echo "$pid" > "$PROJECT_ROOT/synopsys/${name}_${TAG}.pid"
  local pgid
  pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')

  while kill -0 "$pid" 2>/dev/null; do
    log_mem_snapshot "$memlog" "$pid" "$name"
    local avail swap
    avail=$(mem_available_mib)
    swap=$(swap_used_mib)
    echo "[$(date '+%F %T')] $name running pid=$pid pgid=$pgid avail_mib=$avail swap_used_mib=$swap" | tee -a "$STATUS"
    if [ "$avail" -lt 1024 ] || [ "$swap" -gt 4096 ]; then
      echo "[$(date '+%F %T')] $name memory guard triggered: avail_mib=$avail swap_used_mib=$swap; terminating pgid=$pgid" | tee -a "$STATUS" "$memlog"
      kill -TERM "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 10
      kill -KILL "-$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null
      return 99
    fi
    sleep 15
  done

  wait "$pid"
  local rc=$?
  log_mem_snapshot "$memlog" "$pid" "${name}_done"
  echo "[$(date '+%F %T')] END $name rc=$rc" | tee -a "$STATUS"
  return "$rc"
}

cd "$PROJECT_ROOT" || exit 2
mkdir -p synopsys/dc/logs synopsys/dc/reports/FA_TOP_BASELINE synopsys/dc/results/FA_TOP_BASELINE
: > "$STATUS"

if [ -d "$PROJECT_ROOT/synopsys/rtl" ]; then
  echo "[$(date '+%F %T')] stale synopsys/rtl exists; refusing to run" | tee -a "$STATUS"
  exit 3
fi

if ! grep -q '^set RTL_SUBDIR rtl$' "$PROJECT_ROOT/synopsys/common/config/design.tcl"; then
  echo "[$(date '+%F %T')] RTL_SUBDIR is not rtl; refusing to run" | tee -a "$STATUS"
  exit 4
fi

run_with_guard dc_light "$DC_LOG" "$DC_MEM_LOG" "dc_shell -f '$DC_TCL'"
dc_rc=$?
if [ "$dc_rc" -ne 0 ]; then
  echo "[$(date '+%F %T')] STOP after DC light failure rc=$dc_rc" | tee -a "$STATUS"
  exit "$dc_rc"
fi

echo "[$(date '+%F %T')] ALL_DONE" | tee -a "$STATUS"
