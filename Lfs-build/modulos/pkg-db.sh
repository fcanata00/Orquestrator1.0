#!/usr/bin/env bash
# pkg-db.sh - Módulo pkg-db para LFS Builder
# Versão: 1.1
# Objetivo: gerenciar SQLite DB, logs, métricas e UI para builds LFS/BLFS.
# Requisitos: bash, sqlite3, flock, awk, df, cut, date, tput, uuidgen (ou openssl/od), gzip
# Uso típico (orquestrador): source modules/pkg-db.sh; pkgdb_load_config /path/to/pkg-db.conf; pkgdb_init_env; ...
set -euo pipefail

########################################################################
# NOTE (importante):
# - Este arquivo é um módulo pensado para ser SOURCED por um orquestrador.
# - Ele é idempotente: pkgdb_init_env() cria diretórios, arquivos e DB se necessário.
# - Ajuste PKGDB_CONF antes de source se quiser usar um caminho alternativo.
########################################################################

# Caminho padrão para o arquivo de configuração (pode ser sobrescrito antes do source)
: "${PKGDB_CONF:=./conf/modules/pkg-db.conf}"

########## Defaults (podem ser sobrescritos no pkg-db.conf) ##########
: "${PKGDB_PATH:=/var/lfs/pkg-db.sqlite}"
: "${PKGDB_LOCKFILE:=/var/lock/lfs-pkg-db.lock}"
: "${PKGDB_LOG_DIR:=./build/logs}"
: "${PKGDB_BACKUP_DIR:=./build/db-backups}"
: "${PKGDB_WAL:=yes}"
: "${PKGDB_BUSY_TIMEOUT:=10000}"          # ms
: "${PKGDB_RETRY_ATTEMPTS:=5}"
: "${PKGDB_RETRY_BACKOFF_MS:=200}"       # ms base
: "${PKGDB_MAX_BACKUPS:=10}"
: "${PKGDB_SAMPLE_INTERVAL:=1}"          # seconds
: "${PKGDB_ENABLE_RESOURCE_MONITOR:=yes}"
: "${PKGDB_PRAGMA_SETTINGS:=PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-8000;}"
: "${QUIET:=no}"
: "${PKGDB_USER:=lfs}"
: "${PKGDB_GROUP:=lfs}"
: "${PKGDB_ENV_CHROOT_PATH:=/mnt/lfs}"
: "${PKGDB_VALIDATE_SCHEMA:=yes}"
: "${PKGDB_DEBUG:=no}"

# Internal fd for flock operations (fallback if needed)
# we'll use dynamic open per lock call to avoid collisions
# Utilities

_mkdirp() {
    local d="$1"
    [ -z "$d" ] && return 0
    if [ ! -d "$d" ]; then
        mkdir -p "$d"
    fi
}

# Load configuration file (shell compatible key=value)
pkgdb_load_config() {
    local cfg="${1:-$PKGDB_CONF}"
    if [ -f "$cfg" ]; then
        # shellcheck disable=SC1090
        source "$cfg"
    fi
    # ensure directories exist variables reflect config
    : "${PKGDB_PATH:=$PKGDB_PATH}"
    : "${PKGDB_LOCKFILE:=$PKGDB_LOCKFILE}"
    : "${PKGDB_LOG_DIR:=$PKGDB_LOG_DIR}"
    : "${PKGDB_BACKUP_DIR:=$PKGDB_BACKUP_DIR}"
    : "${PKGDB_WAL:=$PKGDB_WAL}"
    : "${PKGDB_BUSY_TIMEOUT:=$PKGDB_BUSY_TIMEOUT}"
    : "${PKGDB_RETRY_ATTEMPTS:=$PKGDB_RETRY_ATTEMPTS}"
    : "${PKGDB_RETRY_BACKOFF_MS:=$PKGDB_RETRY_BACKOFF_MS}"
    : "${PKGDB_MAX_BACKUPS:=$PKGDB_MAX_BACKUPS}"
    : "${PKGDB_SAMPLE_INTERVAL:=$PKGDB_SAMPLE_INTERVAL}"
    : "${PKGDB_ENABLE_RESOURCE_MONITOR:=$PKGDB_ENABLE_RESOURCE_MONITOR}"
    : "${PKGDB_PRAGMA_SETTINGS:=$PKGDB_PRAGMA_SETTINGS}"
    : "${QUIET:=$QUIET}"
    : "${PKGDB_USER:=$PKGDB_USER}"
    : "${PKGDB_GROUP:=$PKGDB_GROUP}"
    : "${PKGDB_ENV_CHROOT_PATH:=$PKGDB_ENV_CHROOT_PATH}"
    : "${PKGDB_VALIDATE_SCHEMA:=$PKGDB_VALIDATE_SCHEMA}"
    : "${PKGDB_DEBUG:=$PKGDB_DEBUG}"

    # create base dirs if needed
    _mkdirp "$(dirname "$PKGDB_PATH")"
    _mkdirp "$PKGDB_LOG_DIR"
    _mkdirp "$PKGDB_BACKUP_DIR"
    _mkdirp "$(dirname "$PKGDB_LOCKFILE")"

    # ensure lockfile exists
    : > "$PKGDB_LOCKFILE" 2>/dev/null || true
}

# Small uuid generator fallback
_pkgdb_gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    elif command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 12
    else
        # fallback: timestamp + random from /dev/urandom
        printf '%s-%s\n' "$(date +%s)" "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
    fi
}

# Internal: perform sqlite operation with retries
_sqlite_exec() {
    local sql="$1"
    local tries=0
    local backoff_ms=$PKGDB_RETRY_BACKOFF_MS

    while :; do
        if [ "${PKGDB_WAL,,}" = "yes" ]; then
            # ensure WAL mode set (best-effort)
            sqlite3 "$PKGDB_PATH" "PRAGMA journal_mode=WAL;" >/dev/null 2>&1 || true
        fi

        if sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $PKGDB_PRAGMA_SETTINGS $sql"; then
            return 0
        else
            tries=$((tries + 1))
            if [ "$tries" -ge "$PKGDB_RETRY_ATTEMPTS" ]; then
                echo "pkg-db: sqlite failed after $tries attempts" >&2
                return 1
            fi
            # exponential backoff
            local sleep_s
            sleep_s=$(awk "BEGIN{printf \"%.3f\", ($backoff_ms * (2 ^ ($tries - 1))) / 1000}")
            sleep "$sleep_s"
        fi
    done
}

# Acquire a POSIX flock on the configured lockfile for critical sections
_pkgdb_acquire_lock() {
    local lockfile="$PKGDB_LOCKFILE"
    local fd="${1:-201}"
    # ensure file exists
    : > "$lockfile"
    # open fd
    eval "exec ${fd}>\"$lockfile\""
    flock -x "$fd"
    # export fd number so release knows it
    echo "$fd"
}

_pkgdb_release_lock() {
    local fd="${1:-201}"
    # release and close
    flock -u "$fd" 2>/dev/null || true
    eval "exec ${fd}>&- || true"
}

# Initialize DB schema (idempotent)
pkgdb_init_db_schema() {
    local ddl
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

    _sqlite_exec "$ddl"
}

# Initialize environment: create dirs, set permissions, create DB file and schema
pkgdb_init_env() {
    # Ensure config loaded
    if [ -z "${PKGDB_PATH:-}" ]; then
        echo "pkg-db: PKGDB_PATH not set. Call pkgdb_load_config first." >&2
        return 1
    fi

    _mkdirp "$(dirname "$PKGDB_PATH")"
    _mkdirp "$PKGDB_LOG_DIR"
    _mkdirp "$PKGDB_BACKUP_DIR"
    _mkdirp "$(dirname "$PKGDB_LOCKFILE")"

    # Set owner if user/group exist
    if id -u "$PKGDB_USER" >/dev/null 2>&1; then
        chown -R "$PKGDB_USER":"$PKGDB_GROUP" "$(dirname "$PKGDB_PATH")" 2>/dev/null || true
        chown -R "$PKGDB_USER":"$PKGDB_GROUP" "$PKGDB_LOG_DIR" 2>/dev/null || true
        chown -R "$PKGDB_USER":"$PKGDB_GROUP" "$PKGDB_BACKUP_DIR" 2>/dev/null || true
    fi

    # Ensure lockfile exists
    : > "$PKGDB_LOCKFILE" 2>/dev/null || true

    # If DB does not exist, create and initialize schema
    if [ ! -f "$PKGDB_PATH" ]; then
        # create file and set mode
        sqlite3 "$PKGDB_PATH" "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $PKGDB_PRAGMA_SETTINGS;" 2>/dev/null || true
        pkgdb_init_db_schema
    else
        # ensure pragmas applied
        sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $PKGDB_PRAGMA_SETTINGS;" 2>/dev/null || true
        if [ "${PKGDB_VALIDATE_SCHEMA,,}" = "yes" ]; then
            local result
            result=$(sqlite3 "$PKGDB_PATH" "PRAGMA integrity_check;" 2>/dev/null || echo "corrupt")
            if [ "$result" != "ok" ]; then
                echo "pkg-db: integrity_check failed: $result" >&2
                echo "pkg-db: creating backup and attempting to reinitialize schema" >&2
                pkgdb_backup || true
                pkgdb_init_db_schema || true
            fi
        fi
    fi

    # Set permissions on DB file
    if id -u "$PKGDB_USER" >/dev/null 2>&1; then
        chown "$PKGDB_USER":"$PKGDB_GROUP" "$PKGDB_PATH" 2>/dev/null || true
    fi

    return 0
}

# Backup DB file with rotation
pkgdb_backup() {
    _mkdirp "$PKGDB_BACKUP_DIR"
    local ts backup
    ts=$(date +%Y%m%dT%H%M%S)
    backup="$PKGDB_BACKUP_DIR/pkg-db.$ts.sqlite"
    cp -a "$PKGDB_PATH" "$backup"
    # rotate
    local to_delete
    to_delete=$(ls -1t "$PKGDB_BACKUP_DIR"/pkg-db.*.sqlite 2>/dev/null | tail -n +"$((PKGDB_MAX_BACKUPS + 1))" || true)
    if [ -n "$to_delete" ]; then
        echo "$to_delete" | xargs -r rm -f --
    fi
    echo "$backup"
}

# Basic integrity check wrapper
pkgdb_integrity_check() {
    sqlite3 "$PKGDB_PATH" "PRAGMA integrity_check;"
}

# -------------------------
# API functions (DB ops)
# -------------------------

# Start a run; prints run_id
pkgdb_init_run() {
    local run_uuid="${1:-$(_pkgdb_gen_uuid)}"
    local user="${2:-$(whoami 2>/dev/null || echo unknown)}"
    local host="${3:-$(hostname 2>/dev/null || echo unknown)}"
    local chroot_path="${4:-}"
    local fd
    fd=$(_pkgdb_acquire_lock 201)
    # insert run
    local sql
    sql="INSERT INTO build_runs (run_uuid, started_at, user, host, chroot_path) VALUES('$run_uuid', DATETIME('now'), '$user', '$host', '$chroot_path'); SELECT last_insert_rowid();"
    local run_id
    run_id=$(sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql" | tail -n1)
    _pkgdb_release_lock "$fd"
    echo "$run_id"
}

# Register package (idempotent) -> prints pkg_id
pkgdb_register_package() {
    local name="$1"
    local version="${2:-}"
    local source_hash="${3:-}"
    local recipe_path="${4:-}"
    local fd
    fd=$(_pkgdb_acquire_lock 202)
    local sql
    # basic sanitization of single quotes
    local sname sver shash srec
    sname=$(printf "%s" "$name" | sed "s/'/''/g")
    sver=$(printf "%s" "$version" | sed "s/'/''/g")
    shash=$(printf "%s" "$source_hash" | sed "s/'/''/g")
    srec=$(printf "%s" "$recipe_path" | sed "s/'/''/g")
    sql="BEGIN;
INSERT OR IGNORE INTO packages (name, version, source_hash, recipe_path) VALUES('$sname', '$sver', '$shash', '$srec');
SELECT id FROM packages WHERE name='$sname' AND version='$sver';
COMMIT;"
    local pkg_id
    pkg_id=$(sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql" | tail -n1)
    _pkgdb_release_lock "$fd"
    echo "$pkg_id"
}

# Start job -> prints job_id
pkgdb_start_job() {
    local run_id="$1"
    local pkg_id="$2"
    local worker="${3:-}"
    local log_path="${4:-}"
    local started_at
    started_at=$(date '+%Y-%m-%d %H:%M:%S')
    local fd
    fd=$(_pkgdb_acquire_lock 203)
    local sql
    sql="INSERT INTO build_jobs (run_id, pkg_id, started_at, worker, log_path) VALUES($run_id, $pkg_id, '$started_at', '$worker', '$log_path'); SELECT last_insert_rowid();"
    local job_id
    job_id=$(sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql" | tail -n1)
    _pkgdb_release_lock "$fd"
    echo "$job_id"
}

# Start step -> prints step_id
pkgdb_start_step() {
    local job_id="$1"
    local step_name="$2"
    local step_order="${3:-0}"
    local started_at
    started_at=$(date '+%Y-%m-%d %H:%M:%S')
    local fd
    fd=$(_pkgdb_acquire_lock 204)
    local sname
    sname=$(printf "%s" "$step_name" | sed "s/'/''/g")
    local sql
    sql="INSERT INTO job_steps (job_id, step_order, step_name, started_at, status) VALUES($job_id, $step_order, '$sname', '$started_at', 'running'); SELECT last_insert_rowid();"
    local step_id
    step_id=$(sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql" | tail -n1)
    _pkgdb_release_lock "$fd"
    echo "$step_id"
}

# Update step (status, exit_code, stdout_snippet, stderr_snippet)
pkgdb_update_step() {
    local step_id="$1"
    local status="${2:-}"
    local exit_code="${3:-0}"
    local stdout_snippet="${4:-}"
    local stderr_snippet="${5:-}"
    local finished_at
    finished_at=$(date '+%Y-%m-%d %H:%M:%S')
    stdout_snippet=$(printf "%s" "$stdout_snippet" | sed "s/'/''/g" | cut -c1-4000)
    stderr_snippet=$(printf "%s" "$stderr_snippet" | sed "s/'/''/g" | cut -c1-4000)
    local fd
    fd=$(_pkgdb_acquire_lock 205)
    local sql
    sql="UPDATE job_steps SET status='${status}', exit_code=${exit_code}, stdout_snippet='${stdout_snippet}', stderr_snippet='${stderr_snippet}', finished_at='${finished_at}' WHERE id=${step_id};"
    sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql"
    _pkgdb_release_lock "$fd"
}

# Finish job
pkgdb_finish_job() {
    local job_id="$1"
    local status="${2:-success}"
    local exit_code="${3:-0}"
    local finished_at
    finished_at=$(date '+%Y-%m-%d %H:%M:%S')
    local fd
    fd=$(_pkgdb_acquire_lock 206)
    local sql
    sql="UPDATE build_jobs SET status='${status}', exit_code=${exit_code}, finished_at='${finished_at}' WHERE id=${job_id};"
    sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql"
    _pkgdb_release_lock "$fd"
}

# Finish run
pkgdb_finish_run() {
    local run_id="$1"
    local status="${2:-success}"
    local finished_at
    finished_at=$(date '+%Y-%m-%d %H:%M:%S')
    local fd
    fd=$(_pkgdb_acquire_lock 207)
    local sql
    sql="UPDATE build_runs SET status='${status}', finished_at='${finished_at}' WHERE id=${run_id};"
    sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql"
    _pkgdb_release_lock "$fd"
}

# Record event
pkgdb_record_event() {
    local run_id="${1:-NULL}"
    local job_id="${2:-NULL}"
    local level="${3:-INFO}"
    local message="${4:-}"
    message=$(printf "%s" "$message" | sed "s/'/''/g")
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local fd
    fd=$(_pkgdb_acquire_lock 208)
    local sql
    sql="INSERT INTO events (run_id, job_id, timestamp, level, message) VALUES(${run_id}, ${job_id}, '${ts}', '${level}', '${message}');"
    sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql"
    _pkgdb_release_lock "$fd"
}

# Insert resource sample (called by sampler)
pkgdb_sample_resource() {
    local job_id="$1"
    local sample_time
    sample_time=$(date '+%Y-%m-%d %H:%M:%S')

    # Get CPU snapshot (basic single-sample approximation)
    local cpu_line
    cpu_line=$(awk '/^cpu /{print $0}' /proc/stat 2>/dev/null || echo "")
    read -r _ user nice system idle iowait irq softirq steal guest guest_n <<<"$cpu_line" || true
    local cpu_total=0
    cpu_total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    local cpu_user_pct=0.0
    local cpu_system_pct=0.0
    if [ "$cpu_total" -gt 0 ]; then
        cpu_user_pct=$(awk "BEGIN{printf \"%.2f\", (${user}/${cpu_total})*100}")
        cpu_system_pct=$(awk "BEGIN{printf \"%.2f\", (${system}/${cpu_total})*100}")
    fi

    # Memory
    local mem_total_kb mem_avail_kb mem_used_kb
    mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo || echo 0)
    mem_avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo || echo 0)
    if [ -n "$mem_total_kb" ] && [ -n "$mem_avail_kb" ]; then
        mem_used_kb=$((mem_total_kb - mem_avail_kb))
    else
        mem_used_kb=0
        mem_total_kb=0
    fi

    # Disk for PKGDB_PATH mount point
    local dfline
    dfline=$(df --block-size=1K --output=used,avail "$(dirname "$PKGDB_PATH")" 2>/dev/null | tail -n1 || true)
    local used_kb=0 total_kb=0
    if [ -n "$dfline" ]; then
        used_kb=$(awk '{print $1}' <<<"$dfline" || echo 0)
        local avail_kb
        avail_kb=$(awk '{print $2}' <<<"$dfline" || echo 0)
        total_kb=$((used_kb + (avail_kb)))
    fi

    # loadavg
    local load1 load5 load15
    read -r load1 load5 load15 _ < /proc/loadavg

    # Insert
    local fd
    fd=$(_pkgdb_acquire_lock 209)
    local sql
    sql="INSERT INTO resource_samples (job_id, timestamp, cpu_user_pct, cpu_system_pct, mem_used_kb, mem_total_kb, disk_used_kb, disk_total_kb, load_1, load_5, load_15) VALUES($job_id, '$sample_time', $cpu_user_pct, $cpu_system_pct, $mem_used_kb, $mem_total_kb, $used_kb, $total_kb, $load1, $load5, $load15);"
    sqlite3 "$PKGDB_PATH" "PRAGMA busy_timeout=$PKGDB_BUSY_TIMEOUT; $sql" || true
    _pkgdb_release_lock "$fd"
}

# -------------------------
# Logging / UI helpers
# -------------------------
# Color helper
_color() {
    case "$1" in
        red) printf '\033[31m%s\033[0m' "$2";;
        green) printf '\033[32m%s\033[0m' "$2";;
        yellow) printf '\033[33m%s\033[0m' "$2";;
        blue) printf '\033[34m%s\033[0m' "$2";;
        bold) printf '\033[1m%s\033[0m' "$2";;
        *) printf '%s' "$2";;
    esac
}

_log() {
    local level="$1"; shift
    local msg="$*"
    if [ "${QUIET,,}" = "yes" ]; then
        # quiet: only errors go to stderr
        if [ "$level" = "ERROR" ]; then
            printf '%s\n' "$( _color red "ERROR:" ) $msg" >&2
        fi
    else
        case "$level" in
            INFO) printf '%s\n' "$( _color blue "INFO:" ) $msg" ;;
            OK)   printf '%s\n' "$( _color green "OK:" ) $msg" ;;
            WARN) printf '%s\n' "$( _color yellow "WARN:" ) $msg" ;;
            ERROR) printf '%s\n' "$( _color red "ERROR:" ) $msg" >&2 ;;
            *) printf '%s\n' "$msg" ;;
        esac
    fi
}

log_info()  { _log INFO "$*"; }
log_ok()    { _log OK "$*"; }
log_warn()  { _log WARN "$*"; }
log_err()   { _log ERROR "$*"; }

# Progress/footer drawer (simple, single-line)
_pkgdb_draw_footer() {
    local percent="${1:-0}"
    local job="${2:-idle}"
    local step="${3:-}"
    local elapsed="${4:-0s}"
    local cpu="${5:-0.0}"
    local mem="${6:-0/0}"
    local load1="${7:-0.00}"

    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    local bar_w=$((cols - 60))
    [ "$bar_w" -lt 10 ] && bar_w=10
    local filled=$(( (percent * bar_w) / 100 ))
    local bar=""
    printf -v bar "%*s" "$filled" ""
    bar=${bar// /#}
    local rest=""
    printf -v rest "%*s" "$((bar_w - filled))" ""
    rest=${rest// /-}
    printf '\r[%3s%%] %s%s | %s | CPU:%5s%% MEM:%s LOAD:%s' "$percent" "$bar" "$rest" "$job:$step" "$cpu" "$mem" "$load1"
}

# Sampler background PID file (per job)
PKGDB_SAMPLER_PIDFILE="/tmp/pkgdb_sampler.pid"

pkgdb_sampler_start() {
    local job_id="$1"
    local interval="${2:-$PKGDB_SAMPLE_INTERVAL}"
    if [ -z "$job_id" ]; then return 1; fi
    # start background sampler
    (
        while :; do
            pkgdb_sample_resource "$job_id" || true
            sleep "$interval"
        done
    ) &
    echo $! > "$PKGDB_SAMPLER_PIDFILE"
}

pkgdb_sampler_stop() {
    if [ -f "$PKGDB_SAMPLER_PIDFILE" ]; then
        local pid
        pid=$(cat "$PKGDB_SAMPLER_PIDFILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 0.05
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PKGDB_SAMPLER_PIDFILE" 2>/dev/null || true
    fi
}

# Prepare log path for job
pkgdb_prepare_job_logpath() {
    local name="$1"
    local version="$2"
    local run_uuid="$3"
    local fname
    fname=$(printf '%s-%s-%s.log' "$name" "$version" "$run_uuid" | sed 's/[^a-zA-Z0-9._-]/_/g')
    _mkdirp "$PKGDB_LOG_DIR"
    echo "$PKGDB_LOG_DIR/$fname"
}

# -------------------------
# Maintenance & Reports
# -------------------------
pkgdb_vacuum() {
    local fd
    fd=$(_pkgdb_acquire_lock 210)
    sqlite3 "$PKGDB_PATH" "VACUUM;"
    _pkgdb_release_lock "$fd"
}

pkgdb_report_run() {
    local run_id="$1"
    sqlite3 -json "$PKGDB_PATH" "SELECT * FROM build_runs WHERE id=$run_id;"
}

pkgdb_list_running_jobs() {
    sqlite3 -json "$PKGDB_PATH" "SELECT * FROM build_jobs WHERE status='running';"
}

# Cleanup function to be used by orchestrator traps
pkgdb_cleanup() {
    pkgdb_sampler_stop || true
    # nothing else forced here; locks are released by functions
}

# Exported API list (for help)
pkgdb_api_list() {
    cat <<'API'
pkg-db module functions (to be sourced):
- pkgdb_load_config [path]
- pkgdb_init_env
- pkgdb_init_db_schema
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
- pkgdb_prepare_job_logpath <name> <version> <run_uuid> -> prints path
- pkgdb_backup
- pkgdb_integrity_check
- pkgdb_vacuum
- pkgdb_report_run <run_id>
- pkgdb_list_running_jobs
API
}

# If executed directly, print help
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "pkg-db.sh is a module, intended to be sourced by the orchestrator."
    echo
    pkgdb_api_list
    exit 0
fi

# End of module
