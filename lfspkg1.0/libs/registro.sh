#!/usr/bin/env bash
#
# lib/registro.sh
# Logger robusto para LFS automation (produção)
# - Logs em texto + JSON (linha por linha)
# - Rotação por tamanho com compressão gzip
# - Barra de progresso textual, ETA, footer dinâmico
# - Escrita atômica via flock (fallback seguro)
# - Paralelismo: identifique jobs com JOB_ID
# - Dry-run, quiet-mode, no-colors
#
# Uso (exemplo mínimo):
#   source lib/registro.sh
#   registro_init --log-dir /mnt/lfs/logs --job-id main --json
#   registro_start_step "build-toolchain" 100
#   registro_progress "build-toolchain" 10 "compilando..."
#   registro_end_step "build-toolchain" OK
#
set -euo pipefail

# --------------------
# Defaults (override in registro.conf)
# --------------------
: "${REG_LOG_DIR:=/mnt/lfs/logs}"
: "${REG_LOG_FILE:=lfs-build.log}"
: "${REG_MAX_LOG_SIZE:=15728640}"   # 15 MB
: "${REG_KEEP_ROTATED:=7}"
: "${REG_SHOW_COLORS:=1}"
: "${REG_QUIET:=0}"
: "${REG_JSON_MODE:=1}"             # you selected JSON logs
: "${REG_PROGRESS_BAR:=1}"
: "${REG_FOOTER_INTERVAL:=1}"       # seconds
: "${REG_LOCKFILE:=/var/lock/lfs-logger.lock}"
: "${REG_CPU_SAMPLE_INTERVAL:=0.12}"
: "${REG_JOB_ID:=}"                 # set externally for parallel jobs
: "${REG_DRY_RUN:=0}"
: "${REG_PROGRESS_WIDTH:=30}"       # chars in textual bar
: "${REG_ETC_LOG_ROTATE_CMD:=gzip}" # command to compress rotated logs (gzip recommended)

# Locate script dir & optionally source registro.conf
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/registro.conf" ]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/registro.conf"
fi

# Internal arrays and state
declare -A _REG_STEP_START_TS
declare -A _REG_STEP_TOTAL
declare -A _REG_STEP_CURRENT
declare -A _REG_STEP_STATUS
declare -A _REG_STEP_MSG

_reg_footer_pid=0
_reg_footer_interval="${REG_FOOTER_INTERVAL}"
_reg_footer_current=""
_reg_lock_fd_var="_reg_lock_fd"

# --------------------
# Helper: ensure directories
# --------------------
registro_ensure_dirs() {
  if [ ! -d "${REG_LOG_DIR}" ]; then
    mkdir -p -- "${REG_LOG_DIR}"
    chmod 750 "${REG_LOG_DIR}" 2>/dev/null || true
  fi
}

# --------------------
# Locking helpers (flock preferred)
# --------------------
registro_lock_open() {
  # create lockfile if not exists
  : > "${REG_LOCKFILE}" 2>/dev/null || true
  # open FD in variable _reg_lock_fd
  if ! eval "exec {${_reg_lock_fd_var}}>\"${REG_LOCKFILE}\""; then
    # fallback: create file
    : > "${REG_LOCKFILE}" 2>/dev/null || true
    eval "exec {${_reg_lock_fd_var}}>\"${REG_LOCKFILE}\""
  fi
}

registro_lock() {
  registro_lock_open
  # retrieve FD number
  local fd
  fd="$(eval "printf '%s' \"\${${_reg_lock_fd_var}}\"")"
  if command -v flock >/dev/null 2>&1; then
    flock -n "${fd}" || flock "${fd}"
  else
    # fallback: naive spinlock using mkdir-based lock
    local tries=0
    while ! mkdir "${REG_LOCKFILE}.lck" 2>/dev/null; do
      sleep 0.05
      tries=$((tries+1))
      if [ "${tries}" -gt 600 ]; then
        printf "registro_lock: timeout acquiring lock\n" >&2
        break
      fi
    done
  fi
}

registro_unlock() {
  local fd
  fd="$(eval "printf '%s' \"\${${_reg_lock_fd_var}}\"")" || fd=""
  if [ -n "${fd}" ]; then
    if command -v flock >/dev/null 2>&1; then
      flock -u "${fd}" 2>/dev/null || true
      eval "exec ${fd}>&-"
    else
      rmdir "${REG_LOCKFILE}.lck" 2>/dev/null || true
    fi
  fi
}

# --------------------
# Log rotation with compression (gzip)
# --------------------
registro_rotate_if_needed() {
  local logfile="${REG_LOG_DIR%/}/${REG_LOG_FILE}"
  if [ -f "${logfile}" ]; then
    local size
    size=$(stat -c%s -- "${logfile}" 2>/dev/null || echo 0)
    if [ "${size}" -ge "${REG_MAX_LOG_SIZE}" ]; then
      registro_lock
      # rotate upward
      for ((i=REG_KEEP_ROTATED-1;i>=1;i--)); do
        if [ -f "${logfile}.$i.gz" ]; then
          mv -f "${logfile}.$i.gz" "${logfile}.$((i+1)).gz" 2>/dev/null || true
        elif [ -f "${logfile}.$i" ]; then
          mv -f "${logfile}.$i" "${logfile}.$((i+1))" 2>/dev/null || true
        fi
      done
      if [ -f "${logfile}" ]; then
        mv -f "${logfile}" "${logfile}.1"
        # compress rotated file
        if command -v "${REG_ETC_LOG_ROTATE_CMD}" >/dev/null 2>&1; then
          "${REG_ETC_LOG_ROTATE_CMD}" -f "${logfile}.1" 2>/dev/null || true
        else
          gzip -f "${logfile}.1" 2>/dev/null || true
        fi
      fi
      # remove oldest
      if [ -f "${logfile}.$((REG_KEEP_ROTATED)).gz" ]; then
        rm -f "${logfile}.$((REG_KEEP_ROTATED)).gz" 2>/dev/null || true
      fi
      registro_unlock
    fi
  fi
}

# --------------------
# Color helpers
# --------------------
_reg_color_reset() { printf '\033[0m'; }
_reg_color() {
  if [ "${REG_SHOW_COLORS}" -eq 1 ] && [ -t 1 ]; then
    case "$1" in
      red) printf '\033[1;31m' ;;
      green) printf '\033[1;32m' ;;
      yellow) printf '\033[1;33m' ;;
      blue) printf '\033[1;34m' ;;
      cyan) printf '\033[1;36m' ;;
      magenta) printf '\033[1;35m' ;;
      *) printf '' ;;
    esac
  fi
}

# --------------------
# Timestamp (ISO 8601, UTC)
# --------------------
_reg_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# --------------------
# Build log line (text and JSON)
# --------------------
_reg_escape_json() {
  # escape newlines and quotes minimally
  printf '%s' "$1" | awk 'BEGIN{ORS="";} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\r/,"\\r"); gsub(/\n/,"\\n"); print $0;}'
}

_reg_build_text_line() {
  local level="$1"; shift
  local msg="$*"
  local ts pid job
  ts="$(_reg_ts)"
  pid="$$"
  job="${REG_JOB_ID:-}"
  printf '%s [%5s] PID=%s JOB=%s %s' "${ts}" "${level}" "${pid}" "${job}" "${msg}"
}

_reg_build_json_line() {
  local level="$1"; shift
  local msg
  msg="$(_reg_escape_json "$*")"
  local ts pid job
  ts="$(_reg_ts)"
  pid="$$"
  job="${REG_JOB_ID:-}"
  printf '{"ts":"%s","level":"%s","pid":%s,"job":"%s","msg":"%s"}' "${ts}" "${level}" "${pid}" "${job}" "${msg}"
}

# --------------------
# Core log writer (atomic)
# --------------------
registro_write_line_to_file() {
  local line="$1"
  local logfile="${REG_LOG_DIR%/}/${REG_LOG_FILE}"
  registro_lock
  # append line with newline
  printf '%s\n' "${line}" >> "${logfile}"
  registro_unlock
}

registro_log() {
  local level="$1"; shift
  local msg="$*"

  if [ "${REG_DRY_RUN}" -eq 1 ]; then
    msg="DRY-RUN: ${msg}"
  fi

  registro_ensure_dirs
  registro_rotate_if_needed

  local text_line json_line
  text_line="$(_reg_build_text_line "${level}" "${msg}")"
  json_line="$(_reg_build_json_line "${level}" "${msg}")"

  # Write textual line to main logfile (always)
  registro_write_line_to_file "${text_line}"

  # If JSON mode enabled, write JSON to parallel .jsonl file (same base name)
  if [ "${REG_JSON_MODE}" -eq 1 ]; then
    local jsonfile="${REG_LOG_DIR%/}/${REG_LOG_FILE}.jsonl"
    registro_lock
    printf '%s\n' "${json_line}" >> "${jsonfile}"
    registro_unlock
  fi

  # Print to terminal unless quiet
  if [ "${REG_QUIET}" -eq 0 ]; then
    if [ "${REG_JSON_MODE}" -eq 1 ]; then
      # Print text_line (human) even if JSON mode ON
      local color reset
      case "${level}" in
        INFO) color=$(_reg_color green) ;;
        WARN) color=$(_reg_color yellow) ;;
        ERROR|FATAL) color=$(_reg_color red) ;;
        STEP) color=$(_reg_color cyan) ;;
        PROG) color=$(_reg_color blue) ;;
        *) color=$(_reg_color) ;;
      esac
      reset=$(_reg_color_reset)
      printf '%b%s%b\n' "${color}" "${text_line}" "${reset}"
    else
      printf '%s\n' "${text_line}"
    fi
  fi
}

# level aliases
registro_info()  { registro_log INFO "$*"; }
registro_warn()  { registro_log WARN "$*"; }
registro_error() { registro_log ERROR "$*"; }
registro_debug() { registro_log DEBUG "$*"; }

# Fatal: log stack and cleanup then exit
registro_fatal() {
  local msg="$*"
  registro_log FATAL "${msg}"
  registro_log FATAL "Stack trace (most recent call first):"
  local i=0
  while caller "$i" >/dev/null 2>&1; do
    registro_log FATAL "$(caller "$i")"
    i=$((i+1))
  done
  registro_cleanup
  exit 1
}

# --------------------
# System metrics helpers
# --------------------
registro_get_loadavg() {
  awk '{printf "%s %s %s", $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "0.00 0.00 0.00"
}

registro_get_mem() {
  local total avail
  total=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  printf "%sMB/%sMB" "${avail}" "${total}"
}

registro_get_disk_available() {
  df --output=avail -m "${REG_LOG_DIR%/}" 2>/dev/null | awk 'NR==2{print $1"MB"}' || echo "N/A"
}

# CPU util sampling (better precision)
registro_get_cpu_util() {
  # read first line of /proc/stat
  read -r cpu user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1 guest1 guest_nice1 < /proc/stat
  total1=$((user1 + nice1 + system1 + idle1 + iowait1 + irq1 + softirq1 + steal1))
  sleep "${REG_CPU_SAMPLE_INTERVAL}"
  read -r cpu user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 guest2 guest_nice2 < /proc/stat
  total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2 + steal2))
  local diff_idle=$((idle2 - idle1))
  local diff_total=$((total2 - total1))
  if [ "${diff_total}" -le 0 ]; then
    echo "0.0%"
    return
  fi
  awk "BEGIN{printf \"%.1f%\", (1 - ${diff_idle}/${diff_total})*100}"
}

# --------------------
# Progress bar functions
# --------------------
_reg_progress_bar_text() {
  local cur="$1"
  local tot="$2"
  local width="${REG_PROGRESS_WIDTH}"
  if [ -z "${tot}" ] || [ "${tot}" -le 0 ]; then
    printf "[no-total]"
    return
  fi
  # percent to 1 decimal
  local pct
  pct=$(awk "BEGIN{printf \"%.1f\", (${cur}/${tot})*100}")
  # filled chars
  local filled
  filled=$(awk "BEGIN{printf \"%d\", (${cur}/${tot})*${width}}")
  [ "${filled}" -gt "${width}" ] && filled="${width}"
  local bar
  if [ "${filled}" -gt 0 ]; then
    bar="$(printf '%0.s#' $(seq 1 "${filled}"))"
  else
    bar=""
  fi
  local empty=$((width - filled))
  if [ "${empty}" -gt 0 ]; then
    bar="${bar}$(printf '%0.s.' $(seq 1 "${empty}"))"
  fi
  printf "[%s] %s%%" "${bar}" "${pct}"
}

# compute ETA given current and total and start time
_reg_compute_eta() {
  local cur="$1"
  local tot="$2"
  local start_ts="$3"
  if [ -z "${tot}" ] || [ "${tot}" -le 0 ] || [ -z "${start_ts}" ]; then
    printf "N/A"
    return
  fi
  # now - start
  local now
  now=$(date +%s)
  local elapsed=$((now - start_ts))
  if [ "${cur}" -le 0 ]; then
    printf "N/A"
    return
  fi
  local rate_sec_per_item
  rate_sec_per_item=$(awk "BEGIN{printf \"%.3f\", ${elapsed}/${cur}}")
  local remain_items=$((tot - cur))
  local eta_sec
  eta_sec=$(awk "BEGIN{printf \"%d\", ${rate_sec_per_item}*${remain_items}}")
  # format HH:MM:SS
  printf '%02d:%02d:%02d' $((eta_sec/3600)) $(((eta_sec%3600)/60)) $((eta_sec%60))
}

# --------------------
# Step management: start, progress, end
# --------------------
registro_start_step() {
  local name="$1"
  local total="${2:-0}"
  if [ -z "${name}" ]; then
    registro_log ERROR "registro_start_step chamado sem nome"
    return 1
  fi
  _REG_STEP_START_TS["$name"]="$(date +%s)"
  _REG_STEP_TOTAL["$name"]="${total}"
  _REG_STEP_CURRENT["$name"]=0
  _REG_STEP_STATUS["$name"]="RUNNING"
  _REG_STEP_MSG["$name"]=""
  registro_log STEP "START ${name} TOTAL=${total}"
  registro_footer_set_current "${name}"
}

registro_progress() {
  local name="$1"
  local cur="${2:-}"
  local msg="${3:-}"
  if [ -z "${name}" ]; then
    registro_log WARN "registro_progress sem nome"
    return 1
  fi
  if [ -z "${cur}" ]; then
    registro_log WARN "registro_progress sem valor atual para ${name}"
    return 1
  fi
  _REG_STEP_CURRENT["$name"]="${cur}"
  _REG_STEP_MSG["$name"]="${msg}"
  registro_log PROG "PROGRESS ${name} ${cur}/${_REG_STEP_TOTAL[$name]} ${msg}"
  registro_footer_set_current "${name}"
}

registro_end_step() {
  local name="$1"
  local status="${2:-OK}"
  if [ -z "${name}" ]; then
    registro_log WARN "registro_end_step sem nome"
    return 1
  fi
  local start="${_REG_STEP_START_TS[$name]:-}"
  if [ -z "${start}" ]; then
    registro_log WARN "registro_end_step: etapa ${name} nao iniciada"
    _REG_STEP_STATUS["$name"]="${status}"
    return 1
  fi
  local now elapsed
  now=$(date +%s)
  elapsed=$((now - start))
  _REG_STEP_STATUS["$name"]="${status}"
  registro_log STEP "END ${name} STATUS=${status} TIME=${elapsed}s CURRENT=${_REG_STEP_CURRENT[$name]}/${_REG_STEP_TOTAL[$name]}"
  registro_footer_clear_current
}

# --------------------
# Footer (one-line dynamic status)
# --------------------
registro_footer_set_current() {
  _reg_footer_current="$1"
  registro_print_footer
}

registro_footer_clear_current() {
  _reg_footer_current=""
  registro_print_footer
}

registro_print_footer() {
  local step="${_reg_footer_current:-idle}"
  local cpu mem disk load elapsed bar eta cur tot msg
  cpu="$(registro_get_cpu_util 2>/dev/null || echo "0.0%")"
  mem="$(registro_get_mem 2>/dev/null || echo "N/A")"
  disk="$(registro_get_disk_available 2>/dev/null || echo "N/A")"
  load="$(registro_get_loadavg 2>/dev/null || echo "0.00 0.00 0.00")"
  elapsed=""
  bar=""
  eta="N/A"
  msg=""
  if [ -n "${_reg_footer_current}" ]; then
    local start="${_REG_STEP_START_TS[${_reg_footer_current}]:-}"
    cur="${_REG_STEP_CURRENT[${_reg_footer_current}]:-0}"
    tot="${_REG_STEP_TOTAL[${_reg_footer_current}]:-0}"
    msg="${_REG_STEP_MSG[${_reg_footer_current}]:-}"
    if [ -n "${start}" ]; then
      local now
      now=$(date +%s)
      elapsed=$((now - start))
      eta="$(_reg_compute_eta "${cur}" "${tot}" "${start}")"
    fi
    if [ "${REG_PROGRESS_BAR}" -eq 1 ]; then
      bar="$(_reg_progress_bar_text "${cur}" "${tot}")"
    fi
  fi

  if [ "${REG_QUIET}" -eq 1 ]; then
    # minimal
    if [ -t 1 ]; then
      printf "\r\033[KETAPA=%s %s" "${step}" "${bar}"
    fi
  else
    if [ -t 1 ]; then
      printf "\r\033[KETAPA=%s | %s | CPU=%s | MEM=%s | DISK=%s | LOAD=%s | ETA=%s | ELAPSED=%ss %s" \
        "${step}" "${bar}" "${cpu}" "${mem}" "${disk}" "${load}" "${eta}" "${elapsed}" "${msg}"
    else
      # non-tty: print newline
      printf "ETAPA=%s | %s | CPU=%s | MEM=%s | DISK=%s | LOAD=%s | ETA=%s | ELAPSED=%ss %s\n" \
        "${step}" "${bar}" "${cpu}" "${mem}" "${disk}" "${load}" "${eta}" "${elapsed}" "${msg}"
    fi
  fi
}

# background updater
registro_footer_start_updater() {
  if [ "${_reg_footer_pid}" -ne 0 ] 2>/dev/null; then
    return
  fi
  (
    while :; do
      registro_print_footer
      sleep "${_reg_footer_interval}"
    done
  ) &
  _reg_footer_pid=$!
  # ensure child killed on exit
  trap 'registro_footer_stop_updater; registro_unlock; exit' EXIT INT TERM
}

registro_footer_stop_updater() {
  if [ "${_reg_footer_pid}" -ne 0 ] 2>/dev/null; then
    kill "${_reg_footer_pid}" 2>/dev/null || true
    wait "${_reg_footer_pid}" 2>/dev/null || true
    _reg_footer_pid=0
  fi
  if [ -t 1 ]; then
    printf "\r\033[K"
  fi
}

# --------------------
# init, cleanup
# --------------------
registro_init() {
  # parse args
  while (( $# )); do
    case "$1" in
      --quiet) REG_QUIET=1; shift ;;
      --no-colors) REG_SHOW_COLORS=0; shift ;;
      --log-dir) shift; REG_LOG_DIR="$1"; shift ;;
      --json) REG_JSON_MODE=1; shift ;;
      --dry-run) REG_DRY_RUN=1; shift ;;
      --job-id) shift; REG_JOB_ID="$1"; shift ;;
      *) shift ;;
    esac
  done

  registro_ensure_dirs
  registro_rotate_if_needed

  # create or touch log files
  : > "${REG_LOG_DIR%/}/${REG_LOG_FILE}" 2>/dev/null || {
    mkdir -p "${REG_LOG_DIR%/}" 2>/dev/null || registro_fatal "Falha ao criar diretório de logs ${REG_LOG_DIR}"
    : > "${REG_LOG_DIR%/}/${REG_LOG_FILE}" 2>/dev/null || registro_fatal "Falha ao criar log ${REG_LOG_DIR%/}/${REG_LOG_FILE}"
  }
  if [ "${REG_JSON_MODE}" -eq 1 ]; then
    : > "${REG_LOG_DIR%/}/${REG_LOG_FILE}.jsonl" 2>/dev/null || true
  fi

  registro_log INFO "Logger iniciado. LOG=${REG_LOG_DIR%/}/${REG_LOG_FILE} JSON=${REG_JSON_MODE} DRY_RUN=${REG_DRY_RUN} JOB=${REG_JOB_ID}"
  registro_footer_start_updater
}

registro_cleanup() {
  registro_footer_stop_updater
  registro_unlock
}

# --------------------
# auxiliary: merge logs (if using per-job logs externally)
# --------------------
registro_merge_logs() {
  local src_dir="${1:-${REG_LOG_DIR}}"
  registro_log INFO "Merge logs from ${src_dir}"
  for f in "${src_dir}"/*.job.log 2>/dev/null; do
    [ -f "${f}" ] || continue
    registro_lock
    cat "${f}" >> "${REG_LOG_DIR%/}/${REG_LOG_FILE}"
    registro_unlock
  done
}

# --------------------
# If this script executed directly, demo usage (no-destructive)
# --------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # demo run
  registro_init --log-dir /tmp/lfs-logs-demo --job-id demo --json
  registro_start_step "demo-step" 20
  for i in $(seq 1 20); do
    registro_progress "demo-step" "${i}" "processando ${i}"
    sleep 0.15
  done
  registro_end_step "demo-step" OK
  registro_cleanup
  exit 0
fi

# Export key functions for other libs
export -f registro_init registro_log registro_info registro_warn registro_error registro_debug registro_fatal
export -f registro_start_step registro_progress registro_end_step
export -f registro_footer_set_current registro_footer_clear_current registro_cleanup
