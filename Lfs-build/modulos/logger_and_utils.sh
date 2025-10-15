#!/usr/bin/env bash
# logger_and_utils.sh
# Combined module: logger.sh + utils.sh
# Place this file in your lfs-build/scripts/ directory and source it from your other scripts:
#   source ./scripts/logger_and_utils.sh
# It exposes two logical groups of functions:
#  - Logger: init_logger, log, info, warn, error, debug, dump_logs
#  - Utils: run_cmd, run_and_capture, retry_cmd, timeout_cmd, check_file_exists,
#           check_sha256, check_ldd_all, check_version, safe_mkdir, atomic_mv
#
# Design goals:
#  - Robust logging to files and colored terminal output (safe for non-TTY)
#  - Each command run via run_cmd/write separate per-step logs in logs/ directory
#  - Detection of "silent failures" via post-check functions
#  - Reasonable defaults, but configurable via exported variables
#
# NOTE: This file is intended to be sourced, not executed directly.

# --------------------------
# Basic safety and options
# --------------------------
set -o pipefail
# Do not enable 'set -e' here to avoid surprising callers; each wrapper checks exit codes explicitly.

# Default configuration (can be overridden by exporting before sourcing)
: "${LFS_BUILD_ROOT:=\$PWD}"
: "${LFS_LOG_DIR:=$LFS_BUILD_ROOT/logs}"
: "${LFS_WORK_DIR:=$LFS_BUILD_ROOT/work}"
: "${LFS_ARTIFACTS_DIR:=$LFS_BUILD_ROOT/artifacts}"
: "${LFS_STATE_DIR:=$LFS_BUILD_ROOT/state}"
: "${LOGGER_LEVEL:=INFO}"        # TRACE, DEBUG, INFO, WARN, ERROR
: "${LOGGER_COLOR:=auto}"
: "${DEFAULT_TIMEOUT:=1200}"     # seconds for long-running commands (20 minutes)
: "${RETRY_COUNT:=3}"
: "${RETRY_BACKOFF:=2}"

# Ensure directories exist
_safe_mkdir_internal() {
  mkdir -p "$1"
}
_safe_mkdir_internal "$LFS_LOG_DIR"
_safe_mkdir_internal "$LFS_WORK_DIR"
_safe_mkdir_internal "$LFS_ARTIFACTS_DIR"
_safe_mkdir_internal "$LFS_STATE_DIR"

# --------------------------
# Logger implementation
# --------------------------
# Determine if we can print colors
_logger_is_tty() {
  [[ "$LOGGER_COLOR" == "always" ]] && return 0
  [[ "$LOGGER_COLOR" == "never" ]] && return 1
  [[ -t 1 ]] || return 1
  return 0
}

# Basic color escapes (fall back to empty strings on non-tty)
if _logger_is_tty; then
  _C_RED="\033[31m"
  _C_GREEN="\033[32m"
  _C_YELLOW="\033[33m"
  _C_BLUE="\033[34m"
  _C_BOLD="\033[1m"
  _C_RESET="\033[0m"
else
  _C_RED=""
  _C_GREEN=""
  _C_YELLOW=""
  _C_BLUE=""
  _C_BOLD=""
  _C_RESET=""
fi

# Map levels to numeric severity
_logger_level_value() {
  case "$1" in
    TRACE) echo 10 ;;
    DEBUG) echo 20 ;;
    INFO)  echo 30 ;;
    WARN)  echo 40 ;;
    ERROR) echo 50 ;;
    *) echo 30 ;;
  esac
}

# Default logfile for current build (timestamped)
_logger_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}
: "${LOGGER_FILE:=$LFS_LOG_DIR/build-$(date -u +%Y%m%dT%H%M%SZ).log}"

# Public: initialize logger explicitly (optional)
# Usage: init_logger /path/to/logfile
init_logger() {
  if [[ -n "$1" ]]; then
    LOGGER_FILE="$1"
  fi
  _safe_mkdir_internal "$(dirname "$LOGGER_FILE")"
  : >"$LOGGER_FILE" || true
  info "Logger initialized, writing to $LOGGER_FILE"
}

# Internal: write message to logfile without colors
_logger_write_file() {
  local ts level comp msg
  ts="$(_logger_timestamp)"
  level="$1"; comp="$2"; msg="$3"
  printf "%s [%s] [%s] %s\n" "$ts" "$level" "$comp" "$msg" >>"$LOGGER_FILE"
}

# Public: main logging function
# Usage: log LEVEL COMPONENT "message"
log() {
  local level comp msg lvlval curval outprefix colorstart colorend
  level="$1"; comp="$2"; shift 2
  msg="$*"
  lvlval=$(_logger_level_value "$level")
  curval=$(_logger_level_value "$LOGGER_LEVEL")

  # write to file always
  _logger_write_file "$level" "$comp" "$msg"

  # decide whether to print to terminal
  if (( lvlval >= curval )); then
    case "$level" in
      ERROR) colorstart="${_C_RED}${_C_BOLD}";;
      WARN)  colorstart="${_C_YELLOW}${_C_BOLD}";;
      INFO)  colorstart="${_C_GREEN}";;
      DEBUG) colorstart="${_C_BLUE}";;
      *) colorstart="";;
    esac
    colorend="${_C_RESET}"
    printf "%s[%s] [%s] %s%s\n" "$colorstart" "$level" "$comp" "$msg" "$colorend"
  fi
}

# Helper convenience wrappers
info()  { log INFO "$1" "${*:2}"; }
warn()  { log WARN "$1" "${*:2}"; }
error() { log ERROR "$1" "${*:2}"; }
debug() { log DEBUG "$1" "${*:2}"; }
trace() { log TRACE "$1" "${*:2}"; }

# Dump a log file or tail the main logger file
dump_logs() {
  local file=${1:-$LOGGER_FILE}
  if [[ -f "$file" ]]; then
    echo "---- BEGIN LOG: $file ----"
    sed -n '1,200p' "$file"
    echo "---- END LOG: $file ----"
  else
    echo "No log at $file"
  fi
}

# --------------------------
# Utils: command runners and checks
# --------------------------
# Create per-step log file naming helper
_step_logfile() {
  local name timestamp
  name="$1"
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  printf "%s/%s-%s.log" "$LFS_LOG_DIR" "$timestamp"-"$name"
}

# run_cmd: run a shell command safely, capture stdout/stderr and log metadata
# Usage: run_cmd "pkgname" timeout_seconds -- command args...
# Example: run_cmd gcc 600 -- make -j4
run_cmd() {
  local pkgname timeout_sec cmd logfile out err rc start end elapsed
  if [[ "$#" -lt 3 ]]; then
    error run_cmd "usage: run_cmd <pkgname> <timeout_sec> -- <cmd> [args...]"; return 2
  fi
  pkgname="$1"; shift
  timeout_sec="$1"; shift
  if [[ "$1" != "--" ]]; then
    error run_cmd "missing -- separator"; return 3
  fi
  shift
  cmd=("$@")

  logfile=$(_step_logfile "$pkgname")
  # ensure logfile dir
  _safe_mkdir_internal "$(dirname "$logfile")"
  # metadata header
  start=$(date -u +%s)
  info "$pkgname" "START: ${cmd[*]} (timeout=${timeout_sec}s) -> logfile=$logfile"
  printf "START %s %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${cmd[*]}" >"$logfile"

  # run with timeout if available
  if command -v timeout >/dev/null 2>&1; then
    if [[ "$timeout_sec" -gt 0 ]]; then
      timeout "$timeout_sec" "${cmd[@]}" >"${logfile}.out" 2>"${logfile}.err" || rc=$?
    else
      "${cmd[@]}" >"${logfile}.out" 2>"${logfile}.err" || rc=$?
    fi
  else
    "${cmd[@]}" >"${logfile}.out" 2>"${logfile}.err" || rc=$?
  fi
  rc=${rc:-0}
  end=$(date -u +%s)
  elapsed=$((end-start))

  # append metadata and combine logs into the main logfile
  printf "END %s rc=%d elapsed=%ds\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$elapsed" >>"$logfile"
  # append captured stdout/stderr
  echo "--- STDOUT ---" >>"$logfile"
  cat "${logfile}.out" >>"$logfile" 2>/dev/null || true
  echo "--- STDERR ---" >>"$logfile"
  cat "${logfile}.err" >>"$logfile" 2>/dev/null || true

  # also append a one-line pointer to the global logger file
  if [[ $rc -eq 0 ]]; then
    info "$pkgname" "OK (${elapsed}s) -> $logfile"
  else
    error "$pkgname" "FAILED rc=$rc (${elapsed}s) -> $logfile"
  fi

  # return code
  return $rc
}

# run_and_capture: wrapper that returns stdout via a file and logs details
# Usage: run_and_capture "pkg" 300 out_file -- cmd args...
run_and_capture() {
  local pkgname timeout_sec out_file rc
  pkgname="$1"; timeout_sec="$2"; out_file="$3"; shift 3
  if [[ "$1" != "--" ]]; then
    error run_and_capture "missing -- separator"; return 3
  fi
  shift
  # execute and capture
  run_cmd "$pkgname" "$timeout_sec" -- "$@"
  rc=$?
  # copy stdout portion to out_file if exists
  # find most recent pkg log
  local logfile
  logfile=$(ls -1t "$LFS_LOG_DIR"/*"-$pkgname.log" 2>/dev/null | head -n1 || true)
  if [[ -n "$logfile" ]]; then
    # extract stdout
    awk '/^--- STDOUT ---/{p=1; next} /^--- STDERR ---/{p=0} p{print}' "$logfile" >"$out_file" 2>/dev/null || true
  fi
  return $rc
}

# retry_cmd: retry a command a number of times with exponential backoff
# Usage: retry_cmd attempts backoff_seconds "pkg" timeout -- cmd args...
retry_cmd() {
  local attempts backoff pkg timeout rc i
  attempts="$1"; backoff="$2"; pkg="$3"; timeout="$4"; shift 4
  if [[ "$1" != "--" ]]; then
    error retry_cmd "missing --"; return 2
  fi
  shift
  rc=1
  for ((i=1;i<=attempts;i++)); do
    info "$pkg" "Attempt $i/$attempts: ${*}"
    run_cmd "$pkg" "$timeout" -- "$@"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      return 0
    fi
    sleep $((backoff*(i)))
  done
  return $rc
}

# timeout_cmd: run a command with a shell fallback if 'timeout' not available
timeout_cmd() {
  local t=0
  if [[ $# -lt 2 ]]; then
    error timeout_cmd "usage: timeout_cmd seconds -- cmd args..."; return 2
  fi
  t="$1"; shift
  if [[ "$1" != "--" ]]; then
    error timeout_cmd "missing --"; return 3
  fi
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$t" "$@"
    return $?
  fi
  # naive fallback: run in background and kill after t seconds
  ("$@") &
  local pid=$!
  ( sleep "$t" && kill -TERM "$pid" 2>/dev/null ) &
  local killer=$!
  wait "$pid" 2>/dev/null || true
  kill -9 "$killer" 2>/dev/null || true
  return 0
}

# check helpers
check_file_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    info check "exists: $path"
    return 0
  else
    error check "missing: $path"
    return 2
  fi
}

check_sha256() {
  local file="$1" expected="$2"
  if [[ ! -f "$file" ]]; then
    error check "sha256: file not found: $file"; return 2
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    local sum
    sum=$(sha256sum "$file" | awk '{print $1}')
    if [[ "$sum" == "$expected" ]]; then
      info check "sha256 ok: $file"
      return 0
    else
      error check "sha256 mismatch for $file (got $sum, expected $expected)"
      return 3
    fi
  else
    warn check "sha256sum not available, skipping check for $file"
    return 1
  fi
}

# check_ldd_all: run ldd on given binary and ensure no 'not found'
check_ldd_all() {
  local bin="$1"
  if ! command -v ldd >/dev/null 2>&1; then
    warn check "ldd not found; skipping ldd check for $bin"; return 1
  fi
  if [[ ! -x "$bin" ]]; then
    error check "ldd: binary not executable: $bin"; return 2
  fi
  local out
  out=$(ldd "$bin" 2>&1) || true
  if echo "$out" | grep -q "not found"; then
    error check "ldd: unresolved dependencies for $bin:\n$out"
    return 3
  else
    info check "ldd OK: $bin"
    return 0
  fi
}

# check_version: run command --version or custom and assert matches regex
check_version() {
  local cmd_and_args expected_regex out
  cmd_and_args=("$1")
  expected_regex="$2"
  out=$(${cmd_and_args[@]} 2>&1) || true
  if echo "$out" | grep -Eq "$expected_regex"; then
    info check "version match for: ${cmd_and_args[*]}"
    return 0
  else
    error check "version mismatch for: ${cmd_and_args[*]} - output: $out"
    return 2
  fi
}

# safe_mkdir: wrapper that logs and creates
safe_mkdir() {
  local dir="$1"
  if [[ -z "$dir" ]]; then
    error safe_mkdir "no dir provided"; return 2
  fi
  if [[ -d "$dir" ]]; then
    info safe_mkdir "exists: $dir"
    return 0
  fi
  mkdir -p "$dir" || { error safe_mkdir "failed to create $dir"; return 3; }
  info safe_mkdir "created $dir"
  return 0
}

# atomic_mv: move file with temporary rename then mv to reduce race conditions
atomic_mv() {
  local src="$1" dst="$2"
  if [[ ! -e "$src" ]]; then
    error atomic_mv "src missing: $src"; return 2
  fi
  local tmp="${dst}.$$.$RANDOM"
  mv "$src" "$tmp" || { error atomic_mv "mv to tmp failed"; return 3; }
  mv "$tmp" "$dst" || { error atomic_mv "final mv failed"; return 4; }
  info atomic_mv "moved $src -> $dst"
  return 0
}

# sha256 file writer: compute and write sha256 for a file
write_sha256() {
  local file="$1" out="$2"
  if [[ -z "$file" || -z "$out" ]]; then
    error write_sha256 "usage: write_sha256 file outfile"; return 2
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1 "  " $2}' >"$out" || return 3
    info write_sha256 "wrote sha256 to $out"
    return 0
  else
    error write_sha256 "sha256sum not available"; return 4
  fi
}

# small helper to join paths
path_join() {
  local a="$1" b="$2"
  if [[ -z "$a" ]]; then echo "$b"; return; fi
  if [[ -z "$b" ]]; then echo "$a"; return; fi
  printf "%s/%s" "${a%/}" "${b#/}"
}

# End of module
# Export selected functions for easier use (in bash this is just making them available via sourcing)
# Usage example (from your other scripts):
#   source "./scripts/logger_and_utils.sh"
#   init_logger "./logs/build.log"
#   run_cmd "busybox" 600 -- make -j4
#   run_and_capture "pkg" 120 /tmp/out -- ./configure --prefix=/usr
#   retry_cmd 3 2 "downloader" 120 -- wget http://example.com/pkg.tar.xz

# EOF
