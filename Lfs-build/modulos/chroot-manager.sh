
#!/usr/bin/env bash
# chroot-manager.sh - robust chroot lifecycle manager for LFS builds
# Version: 1.0
# Responsibilities:
#  - create required directories idempotently
#  - mount/unmount virtual kernel filesystems into LFS safely with retries
#  - provide safe interactive chroot entry and non-interactive command/script execution
#  - support optional namespace isolation (unshare)
#  - session-level locking and global lock to avoid races / concurrent destructive operations
#  - session logging, heartbeat, timeout, sandboxed script execution
#  - integrate with pkg-db.sh if available (best-effort)
#
# Reqs: bash, mount, umount, chroot, unshare (optional), flock, timeout, fuser, lsof (optional)
# Usage (direct execution): ./chroot-manager.sh --enter
# Usage (sourced): source modules/chroot-manager.sh; chroot_load_config; chroot_mount_all; chroot_run_command "ls -la /"
set -euo pipefail

# ---------------------------
# Defaults (overridable by conf file)
# ---------------------------
: "${CHROOT_CONF:=./conf/modules/chroot-manager.conf}"
: "${LFS:=/mnt/lfs}"
: "${CHROOT_LOG_DIR:=/var/log/lfs/chroot}"
: "${CHROOT_LOCK:=/var/lock/lfs-chroot.lock}"
: "${MAX_CONCURRENT_CHROOTS:=2}"
: "${FORCE_UNMOUNT:=no}"
: "${ENABLE_NAMESPACE_ISOLATION:=yes}"
: "${CHROOT_TMPDIR:=/var/tmp/lfs-chroot}"
: "${CHROOT_TIMEOUT_DEFAULT:=3600}"   # default timeout seconds for commands
: "${UMOUNT_RETRY_COUNT:=3}"
: "${MOUNT_RETRY_COUNT:=3}"
: "${ALLOW_ROOT_IN_CHROOT:=no}"       # recommend no; prefer running commands as 'lfs'
: "${CHROOT_OWNER_UID:=0}"
: "${CHROOT_OWNER_GID:=0}"
: "${CHROOT_SESSION_DIR:=$LFS/var/lib/chroot-sessions}"
: "${CHROOT_STATE_DB:=$LFS/var/lib/chroot-state.sqlite}" # optional state DB path
: "${PKG_DB_MODULE:=./modules/pkg-db.sh}" # best-effort integration
: "${QUIET:=no}"

# Environment for chroot as per LFS recommendations
: "${CHROOT_PROMPT:='(lfs chroot) \\u:\\w\\$ '}"
: "${CHROOT_ENV_VARS:='HOME=/root TERM=${TERM:-xterm} PATH=/usr/bin:/usr/sbin MAKEFLAGS=-j$(nproc)'}"

# Internal
_CHROOT_SESSION_UUID=""
_CHROOT_SESSION_LOCKFD=0
_CHROOT_MOUNTS_MADE=()    # tracks mounts we performed for safe unmount
_CHROOT_LOGFILE=""
_pkgdb_sourced=0

# helper: print if not quiet
_chroot_log() {
    local level="$1"; shift
    local msg="$*"
    if [ "${QUIET,,}" = "yes" ]; then
        if [ "$level" = "ERROR" ]; then
            printf '\033[31mERROR:\033[0m %s\n' "$msg" >&2
        fi
    else
        case "$level" in
            INFO) printf '\033[34mINFO:\033[0m %s\n' "$msg" ;;
            OK)   printf '\033[32mOK:\033[0m %s\n' "$msg" ;;
            WARN) printf '\033[33mWARN:\033[0m %s\n' "$msg" ;;
            ERROR) printf '\033[31mERROR:\033[0m %s\n' "$msg" >&2 ;;
            *) printf '%s\n' "$msg" ;;
        esac
    fi
    # write to session log if exists
    if [ -n "$_CHROOT_LOGFILE" ] && [ -w "$(dirname "$_CHROOT_LOGFILE")" ]; then
        printf '[%s] %s: %s\n' "$(date --iso-8601=seconds)" "$level" "$msg" >> "$_CHROOT_LOGFILE" 2>/dev/null || true
    fi
}

# Try to source pkg-db if available to record events (non-fatal)
if [ -f "$PKG_DB_MODULE" ]; then
    # shellcheck disable=SC1091
    source "$PKG_DB_MODULE" >/dev/null 2>&1 || true
    if command -v pkgdb_record_event >/dev/null 2>&1; then
        _pkgdb_sourced=1
    fi
fi

_chroot_pkgdb_record() {
    local run_id="${1:-NULL}"
    local job_id="${2:-NULL}"
    local level="${3:-INFO}"
    local message="${4:-}"
    if [ "$_pkgdb_sourced" -eq 1 ]; then
        pkgdb_record_event "$run_id" "$job_id" "$level" "$message" || true
    else
        _chroot_log INFO "[pkgdb-missing] $message"
    fi
}

# ---------------------------
# Config loader
# ---------------------------
chroot_load_config() {
    local cfg="${1:-$CHROOT_CONF}"
    if [ -f "$cfg" ]; then
        # shellcheck disable=SC1090
        source "$cfg"
        _chroot_log INFO "Loaded chroot config $cfg"
    else
        _chroot_log WARN "Chroot config $cfg not found; using defaults"
    fi
    # sanitize LFS absolute path
    LFS=$(readlink -f "$LFS" 2>/dev/null || printf '%s' "$LFS")
    CHROOT_SESSION_DIR="${CHROOT_SESSION_DIR:-$LFS/var/lib/chroot-sessions}"
    CHROOT_STATE_DB="${CHROOT_STATE_DB:-$LFS/var/lib/chroot-state.sqlite}"
    CHROOT_LOG_DIR="${CHROOT_LOG_DIR:-/var/log/lfs/chroot}"
}

# ---------------------------
# Ensure required directories exist and are secure (idempotent)
# ---------------------------
chroot_ensure_dirs() {
    local dirs=( "$LFS" "$LFS/dev" "$LFS/dev/pts" "$LFS/proc" "$LFS/sys" "$LFS/run" \
                 "$CHROOT_LOG_DIR" "$CHROOT_TMPDIR" "$(dirname "$CHROOT_LOCK")" \
                 "$CHROOT_SESSION_DIR" "$LFS/var/lock" "$LFS/tmp" "$LFS/var/tmp" "$LFS/tools" "$LFS/var/lib" )
    for d in "${dirs[@]}"; do
        if [ -n "$d" ] && [ ! -d "$d" ]; then
            mkdir -p "$d"
            _chroot_log INFO "Created dir $d"
        fi
    done
    # set conservative permissions
    chmod 0755 "$CHROOT_LOG_DIR" 2>/dev/null || true
    chmod 0755 "$CHROOT_TMPDIR" 2>/dev/null || true
    mkdir -p "$(dirname "$CHROOT_LOCK")" 2>/dev/null || true
}

# ---------------------------
# Requirement checks
# ---------------------------
chroot_check_requirements() {
    local missing=()
    local reqs=(mount umount chroot flock)
    for cmd in "${reqs[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if [ "${#missing[@]}" -ne 0 ]; then
        _chroot_log ERROR "Missing required commands: ${missing[*]}"
        return 1
    fi
    # unshare is optional but recommended
    if [ "${ENABLE_NAMESPACE_ISOLATION,,}" = "yes" ] && ! command -v unshare >/dev/null 2>&1; then
        _chroot_log WARN "unshare not found; namespace isolation disabled"
        ENABLE_NAMESPACE_ISOLATION="no"
    fi
    # timeout optional
    if ! command -v timeout >/dev/null 2>&1; then
        _chroot_log WARN "timeout utility not found; timeouts will be best-effort via background kill"
    fi
    return 0
}

# ---------------------------
# Lock helpers (global and session)
# ---------------------------
_chroot_acquire_global_lock() {
    local fd="${1:-210}"
    mkdir -p "$(dirname "$CHROOT_LOCK")" 2>/dev/null || true
    : > "$CHROOT_LOCK"
    # open descriptor
    eval "exec ${fd}>\"$CHROOT_LOCK\""
    flock -x "$fd"
    # return fd number via echo for caller to store
    printf '%s' "$fd"
}

_chroot_release_global_lock() {
    local fd="${1:-210}"
    flock -u "$fd" 2>/dev/null || true
    eval "exec ${fd}>&- || true"
}

_chroot_acquire_session_lock() {
    local session_lock="$1"
    local fd="${2:-211}"
    : > "$session_lock"
    eval "exec ${fd}>\"$session_lock\""
    flock -x "$fd"
    printf '%s' "$fd"
}

_chroot_release_session_lock() {
    local fd="${1:-211}"
    flock -u "$fd" 2>/dev/null || true
    eval "exec ${fd}>&- || true"
}

# ---------------------------
# Mount helpers with retries and safe flags
# ---------------------------
_chroot_is_mounted() {
    local target="$1"
    mountpoint -q "$target" 2>/dev/null
}

_chroot_mount_one() {
    # args: src dest type opts
    local src="$1" dest="$2" fstype="$3" opts="$4"
    local tries=0
    while [ $tries -lt "$MOUNT_RETRY_COUNT" ]; do
        tries=$((tries+1))
        if _chroot_is_mounted "$dest"; then
            _chroot_log INFO "Mount already present: $dest"
            return 0
        fi
        set +e
        if [ -z "$fstype" ] || [ "$fstype" = "--bind" ]; then
            mount --bind "$src" "$dest" 2>/dev/null
            rc=$?
            # remount with flags if opts provided
            if [ "$rc" -eq 0 ] && [ -n "$opts" ]; then
                mount -o remount,"$opts" "$dest" 2>/dev/null || true
            fi
        else
            mount -t "$fstype" $opts "$src" "$dest" 2>/dev/null
            rc=$?
        fi
        set -e
        if [ "$rc" -eq 0 ]; then
            _chroot_log OK "Mounted $src -> $dest (type: ${fstype:-bind})"
            # record mount for unmount ordering (push)
            _CHROOT_MOUNTS_MADE+=("$dest")
            return 0
        else
            _chroot_log WARN "Mount attempt $tries failed for $dest; retrying..."
            sleep $((tries * 1))
        fi
    done
    _chroot_log ERROR "Failed mounting $dest after $MOUNT_RETRY_COUNT attempts"
    return 1
}

# Unmount safe with fuser checks and graceful fallbacks
_chroot_umount_one() {
    local target="$1"
    local force="${2:-no}"
    if ! _chroot_is_mounted "$target"; then
        _chroot_log INFO "Not mounted: $target"
        return 0
    fi
    # check processes using mount
    local pids
    if command -v fuser >/dev/null 2>&1; then
        pids=$(fuser -m "$target" 2>/dev/null || true)
    fi
    if [ -n "$pids" ] && [ "${force,,}" != "yes" ]; then
        _chroot_log WARN "Processes using $target: $pids; not unmounting (force not allowed)"
        return 2
    fi
    set +e
    umount "$target" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
        _chroot_log WARN "umount $target failed; trying lazy umount"
        umount -l "$target" 2>/dev/null || true
    fi
    set -e
    if ! _chroot_is_mounted "$target"; then
        _chroot_log OK "Unmounted $target"
        return 0
    else
        _chroot_log ERROR "Failed to unmount $target"
        return 1
    fi
}

# Mount all virtual FS into LFS (idempotent)
chroot_mount_all() {
    chroot_load_config
    chroot_ensure_dirs
    chroot_check_requirements

    # Acquire a global lock to avoid concurrent destructive mounts
    local glfd
    glfd=$(_chroot_acquire_global_lock 220)
    _chroot_log INFO "Acquired global chroot lock (fd $glfd)"

    # Ensure session data
    _CHROOT_SESSION_UUID=$(uuidgen 2>/dev/null || printf '%s' "$(date +%s)-$RANDOM")
    mkdir -p "$CHROOT_LOG_DIR"
    _CHROOT_LOGFILE="$CHROOT_LOG_DIR/session-${_CHROOT_SESSION_UUID}.log"
    touch "$_CHROOT_LOGFILE"
    _chroot_log INFO "Session UUID: ${_CHROOT_SESSION_UUID}; logging to $_CHROOT_LOGFILE"

    # Acquire a session lock file to coordinate per-session operations
    local session_lock="$CHROOT_SESSION_DIR/session-${_CHROOT_SESSION_UUID}.lock"
    mkdir -p "$CHROOT_SESSION_DIR"
    local sfd
    sfd=$(_chroot_acquire_session_lock "$session_lock" 221)
    _chroot_log INFO "Acquired session lock (fd $sfd)"

    # prepare mount points
    _chroot_mount_one "/dev" "$LFS/dev" "" "nosuid,nodev"
    _chroot_mount_one "/dev/pts" "$LFS/dev/pts" "" "nosuid,noexec"
    _chroot_mount_one "proc" "$LFS/proc" "proc" ""
    _chroot_mount_one "sysfs" "$LFS/sys" "sysfs" ""
    _chroot_mount_one "tmpfs" "$LFS/run" "tmpfs" "mode=0755"

    # mark mounts made recorded in _CHROOT_MOUNTS_MADE array (already done in _chroot_mount_one)
    _chroot_log OK "Mounted virtual filesystems into $LFS"

    # release global lock (we keep session lock until session ends)
    _chroot_release_global_lock "$glfd"
    _chroot_log INFO "Released global chroot lock (fd $glfd)"

    # write state file (for external monitoring)
    mkdir -p "$(dirname "$CHROOT_STATE_DB")" 2>/dev/null || true
    echo "{\"session\":\"${_CHROOT_SESSION_UUID}\",\"started\":\"$(date --iso-8601=seconds)\",\"mounts\":$(printf '%s\n' "${_CHROOT_MOUNTS_MADE[@]}" | jq -R -s -c 'split("\n")[:-1]')}" > "$CHROOT_SESSION_DIR/session-${_CHROOT_SESSION_UUID}.json" 2>/dev/null || true

    # record in pkg-db if available
    _chroot_pkgdb_record NULL NULL INFO "mount-all" "Mounted virtual FS into $LFS (session ${_CHROOT_SESSION_UUID})"

    # store session lock fd globally for use by other functions
    _CHROOT_SESSION_LOCKFD="$sfd"
    return 0
}

# Unmount all virtual fs in reverse order of mount
chroot_unmount_all() {
    local force="${1:-no}"
    chroot_load_config
    chroot_ensure_dirs

    _chroot_log INFO "Unmounting chroot mounts for session ${_CHROOT_SESSION_UUID:-unknown}"

    # Acquire global lock for unmount operations
    local glfd
    glfd=$(_chroot_acquire_global_lock 222)

    # unmount in reverse order of _CHROOT_MOUNTS_MADE
    local i
    for ((i=${#_CHROOT_MOUNTS_MADE[@]}-1; i>=0; i--)); do
        local m="${_CHROOT_MOUNTS_MADE[$i]}"
        _chroot_log INFO "Attempting to unmount $m"
        # attempt unmount with force option if configured
        _chroot_umount_one "$m" "$force" || {
            _chroot_log WARN "Unmount of $m returned non-zero"
        }
    done

    # Clear mounts array
    _CHROOT_MOUNTS_MADE=()

    # release session lock if held
    if [ -n "${_CHROOT_SESSION_LOCKFD:-}" ] && [ "${_CHROOT_SESSION_LOCKFD}" -ne 0 ]; then
        _chroot_release_session_lock "$_CHROOT_SESSION_LOCKFD"
        _chroot_log INFO "Released session lock (fd ${_CHROOT_SESSION_LOCKFD})"
    fi

    # release global lock
    _chroot_release_global_lock "$glfd"
    _chroot_log INFO "Released global unmount lock (fd $glfd)"

    # remove session state file
    if [ -n "${_CHROOT_SESSION_UUID:-}" ]; then
        rm -f "$CHROOT_SESSION_DIR/session-${_CHROOT_SESSION_UUID}.json" 2>/dev/null || true
    fi

    _chroot_pkgdb_record NULL NULL INFO "unmount-all" "Unmounted virtual FS for session ${_CHROOT_SESSION_UUID:-unknown}"

    return 0
}

# ---------------------------
# Helper: copy script into chroot tmp as sandbox
# ---------------------------
_chroot_prepare_script() {
    local script_path="$1"
    if [ ! -f "$script_path" ]; then
        _chroot_log ERROR "Script $script_path not found"
        return 1
    fi
    local dest="${LFS}/tmp/chroot-run-${_CHROOT_SESSION_UUID}.sh"
    mkdir -p "$(dirname "$dest")"
    cp -a "$script_path" "$dest"
    chmod 700 "$dest"
    chown "${CHROOT_OWNER_UID}:${CHROOT_OWNER_GID}" "$dest" 2>/dev/null || true
    echo "$dest"
}

# ---------------------------
# Run a command inside chroot (safe)
#   Options:
#     --user <username> : run as that user inside chroot (recommended)
#     --timeout <sec>   : limit execution (default CHROOT_TIMEOUT_DEFAULT)
#     --job-id <id>     : for pkg-db/job registrations (best-effort)
# ---------------------------
chroot_run_command() {
    local cmd=""
    local user=""
    local timeout_s="$CHROOT_TIMEOUT_DEFAULT"
    local job_id=""
    # parse args
    while [ $# -gt 0 ]; do
        case "$1" in
            --user) user="$2"; shift 2 ;;
            --timeout) timeout_s="$2"; shift 2 ;;
            --job-id) job_id="$2"; shift 2 ;;
            --) shift; cmd="$*"; break ;;
            *) 
                # if cmd not set yet, accumulate
                if [ -z "$cmd" ]; then cmd="$1"; else cmd="$cmd $1"; fi
                shift
                ;;
        esac
    done
    if [ -z "$cmd" ]; then
        _chroot_log ERROR "No command provided to chroot_run_command"
        return 1
    fi

    # ensure mounts up
    if ! _chroot_is_mounted "$LFS/proc"; then
        _chroot_log WARN "Virtual fs not mounted - mounting now"
        chroot_mount_all || true
    fi

    # create session uuid/lock/log if not created
    if [ -z "$_CHROOT_SESSION_UUID" ]; then
        _CHROOT_SESSION_UUID=$(uuidgen 2>/dev/null || printf '%s' "$(date +%s)-$RANDOM")
        mkdir -p "$CHROOT_LOG_DIR"
        _CHROOT_LOGFILE="$CHROOT_LOG_DIR/session-${_CHROOT_SESSION_UUID}.log"
        touch "$_CHROOT_LOGFILE"
    fi

    _chroot_log INFO "Running in chroot (session ${_CHROOT_SESSION_UUID}): $cmd"

    # create wrapper for env -i
    local envargs="HOME=/root TERM=${TERM:-xterm} PS1=${CHROOT_PROMPT} PATH=/usr/bin:/usr/sbin"
    if [ -n "$user" ]; then
        # run via su - user -c '...'
        if [ "${ENABLE_NAMESPACE_ISOLATION,,}" = "yes" ] && command -v unshare >/dev/null 2>&1; then
            # run inside namespaces
            if [ -n "$timeout_s" ] && command -v timeout >/dev/null 2>&1; then
                timeout --preserve-status "$timeout_s" \
                    unshare --map-root-user --mount --pid --fork -- /usr/sbin/chroot "$LFS" /usr/bin/env -i $envargs su -s /bin/bash - "$user" -c "$cmd"
            else
                unshare --map-root-user --mount --pid --fork -- /usr/sbin/chroot "$LFS" /usr/bin/env -i $envargs su -s /bin/bash - "$user" -c "$cmd"
            fi
            rc=$?
        else
            if [ -n "$timeout_s" ] && command -v timeout >/dev/null 2>&1; then
                timeout --preserve-status "$timeout_s" /usr/sbin/chroot "$LFS" /usr/bin/env -i $envargs su -s /bin/bash - "$user" -c "$cmd"
            else
                /usr/sbin/chroot "$LFS" /usr/bin/env -i $envargs su -s /bin/bash - "$user" -c "$cmd"
            fi
            rc=$?
        fi
    else
        # running as root in chroot (not recommended)
        if [ "${ALLOW_ROOT_IN_CHROOT,,}" != "yes" ]; then
            _chroot_log WARN "Running as root inside chroot is discouraged. Set ALLOW_ROOT_IN_CHROOT=yes to allow."
        fi
        if [ "${ENABLE_NAMESPACE_ISOLATION,,}" = "yes" ] && command -v unshare >/dev/null 2>&1; then
            if [ -n "$timeout_s" ] && command -v timeout >/dev/null 2>&1; then
                timeout --preserve-status "$timeout_s" \
                    unshare --map-root-user --mount --pid --fork -- /usr/sbin/chroot "$LFS" /usr/bin/env -i $envargs /bin/bash -lc "$cmd"
            else
                unshare --map-root-user --mount --pid --fork -- /usr/sbin/chroot "$LFS" /usr/bin/env -i $envargs /bin/bash -lc "$cmd"
            fi
            rc=$?
        else
            if [ -n "$timeout_s" ] && command -v timeout >/dev/null 2>&1; then
                timeout --preserve-status "$timeout_s" /usr/sbin/chroot "$LFS" /usr/bin/env -i $envargs /bin/bash -lc "$cmd"
            else
                /usr/sbin/chroot "$LFS" /usr/bin/env -i $envargs /bin/bash -lc "$cmd"
            fi
            rc=$?
        fi
    fi

    # record event and return
    if [ "$rc" -eq 0 ]; then
        _chroot_log OK "Command succeeded in chroot (rc=0)"
        _chroot_pkgdb_record NULL "$job_id" INFO "chroot-run-success" "Command executed: $cmd"
    else
        _chroot_log ERROR "Command failed in chroot (rc=$rc)"
        _chroot_pkgdb_record NULL "$job_id" ERROR "chroot-run-fail" "Command failed (rc=$rc): $cmd"
    fi
    return "$rc"
}

# Execute a script file inside chroot in sandboxed manner
chroot_exec_script() {
    local script_path="$1"
    local user="${2:-lfs}"
    local timeout_s="${3:-$CHROOT_TIMEOUT_DEFAULT}"
    if [ -z "$script_path" ]; then
        _chroot_log ERROR "No script given to chroot_exec_script"
        return 1
    fi
    if [ ! -f "$script_path" ]; then
        _chroot_log ERROR "Script not found: $script_path"
        return 1
    fi

    # copy script into chroot tmp
    local dest
    dest=$(_chroot_prepare_script "$script_path") || return 1

    # run it inside chroot as user
    chroot_run_command --user "$user" --timeout "$timeout_s" -- "$dest"
    local rc=$?

    # cleanup script inside chroot
    if [ -e "$dest" ]; then
        rm -f "$dest" 2>/dev/null || true
    fi
    return "$rc"
}

# Status: show mounts, locks, session info
chroot_status() {
    printf 'Session: %s\n' "${_CHROOT_SESSION_UUID:-none}"
    printf 'Log: %s\n' "${_CHROOT_LOGFILE:-none}"
    printf 'Mounts made:\n'
    local m
    for m in "${_CHROOT_MOUNTS_MADE[@]}"; do printf ' - %s\n' "$m"; done
    printf 'Mounted points under LFS:\n'
    mount | awk -v LFS="$LFS" '$3 ~ "^" LFS {print $0}'
    if [ -f "${CHROOT_SESSION_DIR}/session-${_CHROOT_SESSION_UUID}.json" ]; then
        printf 'State file: %s\n' "${CHROOT_SESSION_DIR}/session-${_CHROOT_SESSION_UUID}.json"
    fi
}

# Cleanup on error or exit (unmount lazy if needed, release locks)
_chroot_cleanup_on_exit() {
    local rc=$?
    _chroot_log INFO "Cleanup on exit (rc=$rc) for session ${_CHROOT_SESSION_UUID:-unknown}"
    # attempt to unmount only if mounts made
    if [ "${#_CHROOT_MOUNTS_MADE[@]}" -gt 0 ]; then
        chroot_unmount_all "${FORCE_UNMOUNT:-no}" || true
    fi
    # release session lock if open
    if [ -n "${_CHROOT_SESSION_LOCKFD:-}" ] && [ "${_CHROOT_SESSION_LOCKFD}" -ne 0 ]; then
        _chroot_release_session_lock "$_CHROOT_SESSION_LOCKFD" || true
        _chroot_log INFO "Released session lock fd $_CHROOT_SESSION_LOCKFD"
    fi
    # no need to release global lock here; mount/unmount functions release it
    exit "$rc"
}

# register trap for safe cleanup
trap '_chroot_cleanup_on_exit' EXIT INT TERM

# ---------------------------
# CLI when run directly
# ---------------------------
_chroot_usage() {
    cat <<'USG'
chroot-manager.sh usage:
  --enter                 : interactive chroot (mounts if needed)
  --umount [--force]      : unmount virtual filesystems
  --run "<cmd>" [--user u] [--timeout s] [--job-id id] : run command in chroot
  --exec /path/script [--user u] [--timeout s] : execute local script inside chroot (sandboxed)
  --status                : print chroot session status
  --help                  : show this help
Examples:
  ./chroot-manager.sh --enter
  ./chroot-manager.sh --run "ls /usr" --user lfs --timeout 600
  ./chroot-manager.sh --exec ./scripts/build-bash.sh --user lfs --timeout 3600
USG
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    # running as script
    chroot_load_config "${CHROOT_CONF}"
    chroot_ensure_dirs
    chroot_check_requirements

    # parse args minimal
    if [ $# -eq 0 ]; then
        _chroot_usage
        exit 0
    fi
    cmd="$1"; shift
    case "$cmd" in
        --enter)
            chroot_mount_all
            _chroot_log INFO "Entering interactive chroot session ${_CHROOT_SESSION_UUID}"
            # interactive: prefer namespace if available
            if [ "${ENABLE_NAMESPACE_ISOLATION,,}" = "yes" ] && command -v unshare >/dev/null 2>&1; then
                unshare --map-root-user --mount --pid --fork -- /usr/sbin/chroot "$LFS" /usr/bin/env -i HOME=/root TERM="${TERM:-xterm}" PS1="${CHROOT_PROMPT}" PATH=/usr/bin:/usr/sbin /bin/bash --login
            else
                /usr/sbin/chroot "$LFS" /usr/bin/env -i HOME=/root TERM="${TERM:-xterm}" PS1="${CHROOT_PROMPT}" PATH=/usr/bin:/usr/sbin /bin/bash --login
            fi
            # after exit, unmount if configured
            if [ "${AUTO_UMOUNT,,}" = "yes" ]; then
                chroot_unmount_all "${FORCE_UNMOUNT:-no}"
            fi
            ;;
        --umount)
            local force="no"
            if [ "${1:-}" = "--force" ]; then force="yes"; fi
            chroot_unmount_all "$force"
            ;;
        --run)
            if [ $# -lt 1 ]; then _chroot_usage; exit 1; fi
            local run_cmd="$1"; shift
            local run_user="lfs"; local run_timeout="$CHROOT_TIMEOUT_DEFAULT"; local run_jobid=""
            # parse optional flags
            while [ $# -gt 0 ]; do
                case "$1" in
                    --user) run_user="$2"; shift 2 ;;
                    --timeout) run_timeout="$2"; shift 2 ;;
                    --job-id) run_jobid="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            chroot_mount_all
            chroot_run_command --user "$run_user" --timeout "$run_timeout" --job-id "$run_jobid" -- "$run_cmd"
            ;;
        --exec)
            if [ $# -lt 1 ]; then _chroot_usage; exit 1; fi
            local script="$1"; shift
            local ex_user="lfs"; local ex_timeout="$CHROOT_TIMEOUT_DEFAULT"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --user) ex_user="$2"; shift 2 ;;
                    --timeout) ex_timeout="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            chroot_mount_all
            chroot_exec_script "$script" "$ex_user" "$ex_timeout"
            ;;
        --status)
            chroot_status
            ;;
        --help)
            _chroot_usage
            ;;
        *)
            _chroot_usage
            exit 1
            ;;
    esac
    exit 0
fi

# End of module for sourcing
# exported functions: chroot_load_config, chroot_ensure_dirs, chroot_check_requirements,
# chroot_mount_all, chroot_unmount_all, chroot_run_command, chroot_exec_script, chroot_status
