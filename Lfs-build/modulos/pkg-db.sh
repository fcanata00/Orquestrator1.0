#!/usr/bin/env bash
# pkg-db.sh - Módulo de gerenciamento do DB para LFS builder
# Versão: 1.0
# Requisitos: bash, sqlite3, flock, awk, date, uuidgen (ou openssl), tput, df, free
# Uso: source this file or execute functions exported by it in your orchestration script.
#
# WARNING: Este é um módulo destinado a ser usado por outros scripts (orquestrador).
# Exemplo de uso (no orquestrador):
#   source modules/pkg-db.sh
#   pkgdb_load_config "/path/to/pkg-db.conf"
#   pkgdb_init_db
#   runid=$(pkgdb_init_run)
#   pkgid=$(pkgdb_register_package "glibc" "2.35" "sha256sum" "/recipes/glibc.recipe")
#   jid=$(pkgdb_start_job "$runid" "$pkgid" "worker-1" "/var/log/..")
#
set -euo pipefail

########## Defaults (overridable via pkg-db.conf) ##########
PKGDB_CONF="${PKGDB_CONF:-./conf/modules/pkg-db.conf}"
PKGDB_PATH_DEFAULT="/var/lfs/pkg-db.sqlite"
PKGDB_LOCKFILE_DEFAULT="/var/lock/lfs-pkg-db.lock"
PKGDB_LOG_DIR_DEFAULT="./build/logs"
PKGDB_BACKUP_DIR_DEFAULT="./build/db-backups"
PKGDB_WAL_DEFAULT="yes"
PKGDB_BUSY_TIMEOUT_DEFAULT=10000       # ms
PKGDB_RETRY_ATTEMPTS_DEFAULT=5
PKGDB_RETRY_BACKOFF_MS_DEFAULT=200     # initial backoff ms
PKGDB_MAX_BACKUPS_DEFAULT=10
PKGDB_SAMPLE_INTERVAL_DEFAULT=1        # seconds
PKGDB_ENABLE_RESOURCE_MONITOR_DEFAULT="yes"
PKGDB_PRAGMA_SETTINGS_DEFAULT="PRAGMA synchronous=NORMAL;"
QUIET_DEFAULT="no"

# Internal state
PKGDB_PATH="${PKGDB_PATH:-$PKGDB_PATH_DEFAULT}"
PKGDB_LOCKFILE="${PKGDB_LOCKFILE:-$PKGDB_LOCKFILE_DEFAULT}"
PKGDB_LOG_DIR="${PKGDB_LOG_DIR:-$PKGDB_LOG_DIR_DEFAULT}"
PKGDB_BACKUP_DIR="${PKGDB_BACKUP_DIR:-$PKGDB_BACKUP_DIR_DEFAULT}"
PKGDB_WAL="${PKGDB_WAL:-$PKGDB_WAL_DEFAULT}"
PKGDB_BUSY_TIMEOUT="${PKGDB_BUSY_TIMEOUT:-$PKGDB_BUSY_TIMEOUT_DEFAULT}"
PKGDB_RETRY_ATTEMPTS="${PKGDB_RETRY_ATTEMPTS:-$PKGDB_RETRY_ATTEMPTS_DEFAULT}"
PKGDB_RETRY_BACKOFF_MS="${PKGDB_RETRY_BACKOFF_MS:-$PKGDB_RETRY_BACKOFF_MS_DEFAULT}"
PKGDB_MAX_BACKUPS="${PKGDB_MAX_BACKUPS:-$PKGDB_MAX_BACKUPS_DEFAULT}"
PKGDB_SAMPLE_INTERVAL="${PKGDB_SAMPLE_INTERVAL:-$PKGDB_SAMPLE_INTERVAL_DEFAULT}"
PKGDB_ENABLE_RESOURCE_MONITOR="${PKGDB_ENABLE_RESOURCE_MONITOR:-$PKGDB_ENABLE_RESOURCE_MONITOR_DEFAULT}"
PKGDB_PRAGMA_SETTINGS="${PKGDB_PRAGMA_SETTINGS:-$PKGDB_PRAGMA_SETTINGS_DEFAULT}"
QUIET="${QUIET:-$QUIET_DEFAULT}"

# FD for flock
exec 200>/var/lock/lfs-pkg-db.flock 2>/dev/null || true

# Utility: ensure directories exist
_mkdirp() {
    local d="$1"
    if [ -n "$d" ] && [ ! -d "$d" ]; then
        mkdir -p "$d"
    fi
}

# Load config (shell format key=value)
pkgdb_load_config() {
    local cfg="${1:-$PKGDB_CONF}"
    if [ -f "$cfg" ]; then
        # shellcheck disable=SC1090
        source "$cfg"
    fi
    # apply defaults if missing
    : "${PKGDB_PATH:=$PKGDB_PATH_DEFAULT}"
    : "${PKGDB_LOCKFILE:=$PKGDB_LOCKFILE_DEFAULT}"
    : "${PKGDB_LOG_DIR:=$PKGDB_LOG_DIR_DEFAULT}"
    : "${PKGDB_BACKUP_DIR:=$PKGDB_BACKUP_DIR_DEFAULT}"
    : "${PKGDB_WAL:=$PKGDB_WAL_DEFAULT}"
    : "${PKGDB_BUSY_TIMEOUT:=$PKGDB_BUSY_TIMEOUT_DEFAULT}"
    : "${PKGDB_RETRY_ATTEMPTS:=$PKGDB_RETRY_ATTEMPTS_DEFAULT}"
    : "${PKGDB_RETRY_BACKOFF_MS:=$PKGDB_RETRY_BACKOFF_MS_DEFAULT}"
    : "${PKGDB_MAX_BACKUPS:=$PKGDB_MAX_BACKUPS_DEFAULT}"
    : "${PKGDB_SAMPLE_INTERVAL:=$PKGDB_SAMPLE_INTERVAL_DEFAULT}"
    : "${PKGDB_ENABLE_RESOURCE_MONITOR:=$PKGDB_ENABLE_RESOURCE_MONITOR_DEFAULT}"
    : "${PKGDB_PRAGMA_SETTINGS:=$PKGDB_PRAGMA_SETTINGS_DEFAULT}"
    : "${QUIET:=$QUIET_DEFAULT}"

    _mkdirp "$(dirname "$PKGDB_PATH")"
    _mkdirp "$PKGDB_LOG_DIR"
    _mkdirp "$PKGDB_BACKUP_DIR"
    _mkdirp "$(dirname "$PKGDB_LOCKFILE")"

    # Make lockfile exist
    : > "$PKGDB_LOCKFILE" || true
}

# Small uuid generator fallback
_pkgdb_gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        # fallback: timestamp + random hex
        printf '%s-%s\n' "$(date +%s)" "$(openssl rand -hex 8 2>/dev/null || od -vAn -N8 -tx1 /dev/urandom | tr -d ' \n')"
    fi
}

# Run sqlite with retries and flock for critical operations
_sqlite_exec() {
    local sql="$1"
    local tries=0
    local backoff_ms=$PKGDB_RETRY_BACKOFF_MS

    while :; do
        if [ "${PKGDB_WAL,,}" = "yes" ]; then
            # ensure WAL mode set once (best-effort)
            sqlite3 "$PKGDB_PATH" "PRAGMA journal_mode=WAL;" >/dev/null 2>&1 || true
        fi
        # set busy timeout and other pragmas per invocation
        if sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $PKGDB_PRAGMA_SETTINGS $sql"; then
            return 0
        else
            tries=$((tries + 1))
            if [ $tries -ge "$PKGDB_RETRY_ATTEMPTS" ]; then
                echo "pkg-db: sqlite failed after $tries attempts" >&2
                return 1
            fi
            # exponential backoff
            sleep_ms=$((backoff_ms * (2 ** (tries - 1))))
            # convert ms to s for sleep
            awk "BEGIN{printf \"%.3f\", $sleep_ms/1000}" | xargs sleep
        fi
    done
}

# Acquire exclusive lock (flock) for critical sections
_pkgdb_acquire_lock() {
    local lock="${PKGDB_LOCKFILE}"
    # open fd 201 for lock file to avoid interfering with global 200
    exec 201>"$lock"
    flock -x 201 || return 1
    return 0
}

# Release lock acquired by _pkgdb_acquire_lock
_pkgdb_release_lock() {
    flock -u 201 || true
    exec 201>&- || true
}

# Initialize DB schema (idempotent)
pkgdb_init_db() {
    _pkgdb_acquire_lock
    trap '_pkgdb_release_lock' RETURN

    if [ ! -f "$PKGDB_PATH" ]; then
        sqlite3 "$PKGDB_PATH" "PRAGMA journal_mode = WAL; PRAGMA busy_timeout = $PKGDB_BUSY_TIMEOUT; $PKGDB_PRAGMA_SETTINGS"
    fi

    read -r -d '' ddl <<'SQL' || true
BEGIN;
CREATE TABLE IF NOT EXISTS build_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_uuid TEXT UNIQUE NOT NULL,
  started_at DATETIME NOT NULL,
  finished_at DATETIME,
  user TEXT,
  host TEXT,
  chroot_path TEXT,
  status TEXT NOT NULL DEFAULT 'running',
  notes TEXT
);
CREATE INDEX IF NOT EXISTS idx_build_runs_run_uuid ON build_runs(run_uuid);
CREATE INDEX IF NOT EXISTS idx_build_runs_status ON build_runs(status);

CREATE TABLE IF NOT EXISTS packages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  version TEXT,
  source_hash TEXT,
  recipe_path TEXT,
  UNIQUE(name, version)
);
CREATE INDEX IF NOT EXISTS idx_packages_name_version ON packages(name, version);

CREATE TABLE IF NOT EXISTS build_jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id INTEGER REFERENCES build_runs(id) ON DELETE CASCADE,
  pkg_id INTEGER REFERENCES packages(id),
  started_at DATETIME NOT NULL,
  finished_at DATETIME,
  status TEXT NOT NULL DEFAULT 'running',
  worker TEXT,
  log_path TEXT,
  exit_code INTEGER,
  retries INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_build_jobs_run_pkg ON build_jobs(run_id, pkg_id);
CREATE INDEX IF NOT EXISTS idx_build_jobs_status ON build_jobs(status);

CREATE TABLE IF NOT EXISTS job_steps (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id INTEGER REFERENCES build_jobs(id) ON DELETE CASCADE,
  step_order INTEGER,
  step_name TEXT,
  started_at DATETIME,
  finished_at DATETIME,
  status TEXT DEFAULT 'pending',
  stdout_snippet TEXT,
  stderr_snippet TEXT,
  exit_code INTEGER
);
CREATE INDEX IF NOT EXISTS idx_job_steps_job ON job_steps(job_id);

CREATE TABLE IF NOT EXISTS resource_samples (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id INTEGER REFERENCES build_jobs(id) ON DELETE CASCADE,
  timestamp DATETIME,
  cpu_user_pct REAL,
  cpu_system_pct REAL,
  mem_used_kb INTEGER,
  mem_total_kb INTEGER,
  disk_used_kb INTEGER,
  disk_total_kb INTEGER,
  load_1 REAL,
  load_5 REAL,
  load_15 REAL
);
CREATE INDEX IF NOT EXISTS idx_resource_samples_job_ts ON resource_samples(job_id, timestamp);

CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id INTEGER,
  job_id INTEGER,
  timestamp DATETIME,
  level TEXT,
  message TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_run ON events(run_id);
CREATE INDEX IF NOT EXISTS idx_events_job ON events(job_id);

CREATE TABLE IF NOT EXISTS locks (
  name TEXT PRIMARY KEY,
  owner TEXT,
  acquired_at DATETIME
);
COMMIT;
SQL

    _sqlite_exec "$ddl" || return 1
    return 0
}

# Backup DB
pkgdb_backup() {
    _pkgdb_acquire_lock
    trap '_pkgdb_release_lock' RETURN

    _mkdirp "$PKGDB_BACKUP_DIR"
    local ts
    ts=$(date +%Y%m%dT%H%M%S)
    local target="$PKGDB_BACKUP_DIR/pkg-db.$ts.sqlite"
    cp -a "$PKGDB_PATH" "$target"
    # prune old backups
    (ls -1t "$PKGDB_BACKUP_DIR"/pkg-db.*.sqlite 2>/dev/null || true) | tail -n +"$((PKGDB_MAX_BACKUPS + 1))" | xargs -r rm -f --
    echo "$target"
}

# Integrity check
pkgdb_integrity_check() {
    sqlite3 "$PKGDB_PATH" "PRAGMA integrity_check;"
}

# -- API Functions --

# Start a run; returns run_id
pkgdb_init_run() {
    local run_uuid="${1:-$(_pkgdb_gen_uuid)}"
    local user="${2:-$(whoami 2>/dev/null || echo unknown)}"
    local host="${3:-$(hostname 2>/dev/null || echo unknown)}"
    local chroot_path="${4:-}"

    local sql="INSERT INTO build_runs(run_uuid, started_at, user, host, chroot_path) VALUES('$run_uuid', DATETIME('now'), '$user', '$host', '${chroot_path}'); SELECT last_insert_rowid();"
    _pkgdb_acquire_lock
    trap '_pkgdb_release_lock' RETURN
    local run_id
    run_id=$(sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql" | tail -n1)
    echo "$run_id"
}

# Register package (idempotent)
pkgdb_register_package() {
    local name="$1"
    local version="${2:-}"
    local source_hash="${3:-}"
    local recipe_path="${4:-}"

    local escaped_name
    escaped_name=$(printf '%q' "$name")
    local sql="BEGIN;
INSERT OR IGNORE INTO packages (name, version, source_hash, recipe_path) VALUES('$name', '$version', '$source_hash', '$recipe_path');
SELECT id FROM packages WHERE name='$name' AND version='$version';
COMMIT;"
    _pkgdb_acquire_lock
    trap '_pkgdb_release_lock' RETURN
    local pkg_id
    pkg_id=$(sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql" | tail -n1)
    echo "$pkg_id"
}

# Start a job, returns job_id
pkgdb_start_job() {
    local run_id="$1"
    local pkg_id="$2"
    local worker="${3:-}"
    local log_path="${4:-}"

    local started_at
    started_at=$(date '+%Y-%m-%d %H:%M:%S')
    local sql="INSERT INTO build_jobs (run_id, pkg_id, started_at, worker, log_path) VALUES($run_id, $pkg_id, '$started_at', '$worker', '$log_path'); SELECT last_insert_rowid();"
    _pkgdb_acquire_lock
    trap '_pkgdb_release_lock' RETURN
    local job_id
    job_id=$(sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql" | tail -n1)
    echo "$job_id"
}

# Start a step, returns step_id
pkgdb_start_step() {
    local job_id="$1"
    local step_name="$2"
    local step_order="${3:-0}"
    local started_at
    started_at=$(date '+%Y-%m-%d %H:%M:%S')
    local sql="INSERT INTO job_steps (job_id, step_order, step_name, started_at, status) VALUES($job_id, $step_order, '$step_name', '$started_at', 'running'); SELECT last_insert_rowid();"
    _pkgdb_acquire_lock
    trap '_pkgdb_release_lock' RETURN
    local step_id
    step_id=$(sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql" | tail -n1)
    echo "$step_id"
}

# Update a step (status, exit_code, snippets)
pkgdb_update_step() {
    local step_id="$1"
    local status="${2:-}"
    local exit_code="${3:-}"
    local stdout_snippet="${4:-}"
    local stderr_snippet="${5:-}"
    local finished_at
    finished_at=$(date '+%Y-%m-%d %H:%M:%S')

    # sanitize snippets to single-quoted SQL literals (very basic, avoid injection)
    stdout_snippet=$(printf '%s' "$stdout_snippet" | sed "s/'/''/g")
    stderr_snippet=$(printf '%s' "$stderr_snippet" | sed "s/'/''/g")

    local sql="UPDATE job_steps SET status='${status}', exit_code=${exit_code}, stdout_snippet='${stdout_snippet}', stderr_snippet='${stderr_snippet}', finished_at='${finished_at}' WHERE id=${step_id};"
    _pkgdb_acquire_lock
    trap '_pkgdb_release_lock' RETURN
    sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql"
}

# Finish job
pkgdb_finish_job() {
    local job_id="$1"
    local status="${2:-success}"
    local exit_code="${3:-0}"
    local finished_at
    finished_at=$(date '+%Y-%m-%d %H:%M:%S')
    local sql="UPDATE build_jobs SET status='${status}', exit_code=${exit_code}, finished_at='${finished_at}' WHERE id=${job_id};"
    _pkgdb_acquire_lock
    trap '_pkgdb_release_lock' RETURN
    sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql"
}

# Finish run
pkgdb_finish_run() {
    local run_id="$1"
    local status="${2:-success}"
    local finished_at
    finished_at=$(date '+%Y-%m-%d %H:%M:%S')
    local sql="UPDATE build_runs SET status='${status}', finished_at='${finished_at}' WHERE id=${run_id};"
    _pkgdb_acquire_lock
    trap '_pkgdb_release_lock' RETURN
    sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql"
}

# Record event
pkgdb_record_event() {
    local run_id="${1:-NULL}"
    local job_id="${2:-NULL}"
    local level="${3:-INFO}"
    local message="${4:-}"
    message=$(printf '%s' "$message" | sed "s/'/''/g")
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local sql="INSERT INTO events (run_id, job_id, timestamp, level, message) VALUES(${run_id}, ${job_id}, '${ts}', '${level}', '${message}');"
    _pkgdb_acquire_lock
    trap '_pkgdb_release_lock' RETURN
    sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql"
}

# Sample resource usage and insert into resource_samples
pkgdb_sample_resource() {
    local job_id="$1"
    local sample_time
    sample_time=$(date '+%Y-%m-%d %H:%M:%S')
    # CPU: compute deltas from /proc/stat between calls is complex; use top-level snapshot using awk
    # We'll compute simple approximations: cpu usage via top-like calculation
    # simplified: read /proc/stat first line
    local cpu_line
    cpu_line=$(awk '/^cpu / {print $0}' /proc/stat 2>/dev/null || echo "")
    # parse
    read -r _ user nice system idle iowait irq softirq steal guest gguest <<<"$cpu_line" || true
    local cpu_total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    # store user and system as percentage of total (approx; may be >100 on single-snapshot)
    local cpu_user_pct=0
    local cpu_system_pct=0
    if [ "$cpu_total" -gt 0 ]; then
        cpu_user_pct=$(awk "BEGIN{printf \"%.2f\", (${user} / ${cpu_total}) * 100}")
        cpu_system_pct=$(awk "BEGIN{printf \"%.2f\", (${system} / ${cpu_total}) * 100}")
    fi

    # mem
    local mem_total_kb mem_avail_kb mem_used_kb
    mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    mem_avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    if [ -n "$mem_total_kb" ] && [ -n "$mem_avail_kb" ]; then
        mem_used_kb=$((mem_total_kb - mem_avail_kb))
    else
        mem_used_kb=0
        mem_total_kb=0
    fi

    # disk stats for PKGDB_PATH fs
    local fs
    fs=$(df --block-size=1K --output=used,avail,target "$(dirname "$PKGDB_PATH")" 2>/dev/null | tail -n1 | awk '{print $1","$2","$3}')
    local disk_used_kb=0
    local disk_total_kb=0
    if [ -n "$fs" ]; then
        local used avail target
        IFS=, read -r used avail target <<<"$fs"
        # total = used + avail
        disk_used_kb=$((used))
        disk_total_kb=$((used + avail))
    fi

    # load averages
    local load1 load5 load15
    read -r load1 load5 load15 _ < /proc/loadavg

    # write to DB
    local sql="INSERT INTO resource_samples (job_id, timestamp, cpu_user_pct, cpu_system_pct, mem_used_kb, mem_total_kb, disk_used_kb, disk_total_kb, load_1, load_5, load_15) VALUES($job_id, '${sample_time}', ${cpu_user_pct}, ${cpu_system_pct}, ${mem_used_kb}, ${mem_total_kb}, ${disk_used_kb}, ${disk_total_kb}, ${load1}, ${load5}, ${load15});"
    # wrap lock around this small insert
    _pkgdb_acquire_lock
    trap '_pkgdb_release_lock' RETURN
    sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql" || true
}

# Simple helpers for logging with colors
_log_color() {
    local color="$1"; shift
    local msg="$*"
    if [ "${QUIET,,}" = "yes" ]; then
        # in quiet mode only print errors
        if [ "$color" = "red" ]; then
            printf '\e[31m%s\e[0m\n' "$msg" >&2
        fi
    else
        case "$color" in
            red)  printf '\e[31m%s\e[0m\n' "$msg" >&2 ;;
            green) printf '\e[32m%s\e[0m\n' "$msg" ;;
            yellow) printf '\e[33m%s\e[0m\n' "$msg" ;;
            blue) printf '\e[34m%s\e[0m\n' "$msg" ;;
            *) printf '%s\n' "$msg" ;;
        esac
    fi
}
log_info()  { _log_color blue "$@"; }
log_ok()    { _log_color green "$@"; }
log_warn()  { _log_color yellow "$@"; }
log_err()   { _log_color red "$@"; }

# UI: footer drawing (simple implementation)
_pkgdb_footer_clear() {
    tput sc
    tput cuu1
    tput el
    tput rc
}

_pkgdb_draw_footer() {
    # Accepts: global_pct current_job current_step elapsed_time cpu mem load1
    local global_pct="${1:-0}"
    local jobname="${2:-idle}"
    local step="${3:-}"
    local elapsed="${4:-0s}"
    local cpu="${5:-0.0}"
    local mem="${6:-0/0}"
    local load1="${7:-0.00}"

    # build bar (width adaptive)
    local width
    width=$(tput cols 2>/dev/null || echo 80)
    local bar_width=$((width - 45))
    if [ "$bar_width" -lt 10 ]; then bar_width=10; fi
    local filled=$(( (global_pct * bar_width) / 100 ))
    local bar=""
    local i
    for ((i=0;i<filled;i++)); do bar="${bar}#"; done
    for ((i=filled;i<bar_width;i++)); do bar="${bar}-"; done
    # render
    printf '\r[%3s%%] %s | %s | CPU:%5s%% MEM:%s LOAD:%s' "$global_pct" "$bar" "$jobname:$step" "$cpu" "$mem" "$load1"
}

# Sampler control (background process)
PKGDB_SAMPLER_PID_FILE="/tmp/pkgdb_sampler.pid"
pkgdb_sampler_start() {
    local job_id="$1"
    local interval="${2:-$PKGDB_SAMPLE_INTERVAL}"
    if [ -z "$job_id" ]; then
        return 1
    fi
    # ensure only one sampler per job on same host (simple approach)
    if [ -f "$PKGDB_SAMPLER_PID_FILE" ]; then
        local oldpid
        oldpid=$(cat "$PKGDB_SAMPLER_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
            return 0
        fi
    fi

    (
        # background loop
        while :; do
            pkgdb_sample_resource "$job_id" || true
            sleep "$interval"
        done
    ) &
    echo $! > "$PKGDB_SAMPLER_PID_FILE"
}

pkgdb_sampler_stop() {
    if [ -f "$PKGDB_SAMPLER_PID_FILE" ]; then
        local pid
        pid=$(cat "$PKGDB_SAMPLER_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 0.1
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PKGDB_SAMPLER_PID_FILE" 2>/dev/null || true
    fi
}

# Query helpers (basic)
pkgdb_get_run_summary() {
    local run_id="$1"
    sqlite3 -json "$PKGDB_PATH" "SELECT * FROM build_runs WHERE id=$run_id;"
}

pkgdb_list_running_jobs() {
    sqlite3 -json "$PKGDB_PATH" "SELECT * FROM build_jobs WHERE status='running';"
}

# Maintenance
pkgdb_vacuum() {
    _pkgdb_acquire_lock
    trap '_pkgdb_release_lock' RETURN
    sqlite3 "$PKGDB_PATH" "VACUUM;"
}

# Report: simple run summary print
pkgdb_report_run() {
    local run_id="$1"
    echo "Run summary for run id: $run_id"
    sqlite3 "$PKGDB_PATH" "SELECT id, run_uuid, started_at, finished_at, status FROM build_runs WHERE id=$run_id;"
    echo "Jobs:"
    sqlite3 "$PKGDB_PATH" "SELECT bj.id, p.name, p.version, bj.status, bj.started_at, bj.finished_at, bj.log_path FROM build_jobs bj JOIN packages p ON bj.pkg_id = p.id WHERE bj.run_id=$run_id;"
}

# Ensure logfile path for a job
pkgdb_prepare_job_logpath() {
    local name="$1"
    local version="$2"
    local run_uuid="$3"
    local filename
    filename="$(printf '%s-%s-%s.log' "$name" "$version" "$run_uuid" | sed 's/[^a-zA-Z0-9._-]/_/g')"
    _mkdirp "$PKGDB_LOG_DIR"
    echo "$PKGDB_LOG_DIR/$filename"
}

# Safe shutdown trap - to be called by orchestrator setup
pkgdb_setup_traps() {
    trap 'pkgdb_sampler_stop; exit 1' INT TERM
    trap 'pkgdb_sampler_stop; exit 0' EXIT
}

# Expose minimal exported API list (for introspection)
pkgdb_api_list() {
    cat <<'API'
Exported functions:
- pkgdb_load_config <config_path>
- pkgdb_init_db
- pkgdb_backup
- pkgdb_init_run [run_uuid] [user] [host] [chroot_path] -> prints run_id
- pkgdb_register_package <name> <version> <source_hash> <recipe_path> -> prints pkg_id
- pkgdb_start_job <run_id> <pkg_id> <worker> <log_path> -> prints job_id
- pkgdb_start_step <job_id> <step_name> <step_order> -> prints step_id
- pkgdb_update_step <step_id> <status> <exit_code> <stdout_snippet> <stderr_snippet>
- pkgdb_finish_job <job_id> [status] [exit_code]
- pkgdb_finish_run <run_id> [status]
- pkgdb_record_event <run_id> <job_id> <level> <message>
- pkgdb_sample_resource <job_id>
- pkgdb_sampler_start <job_id> [interval]
- pkgdb_sampler_stop
- pkgdb_get_run_summary <run_id>
- pkgdb_report_run <run_id>
- pkgdb_vacuum
API
}

# If script run directly (not sourced) - show usage/help
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "This script is a module. It's intended to be sourced by the orquestrator."
    echo
    pkgdb_api_list
    exit 0
fi
