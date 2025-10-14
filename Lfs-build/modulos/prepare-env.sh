#!/usr/bin/env bash
# prepare-env.sh - prepara o ambiente LFS/BLFS conforme Capítulos 4 & 7 do LFS book
# Versão: 1.0
# Uso: source modules/prepare-env.sh ; env_load_config [path] ; env_init [--no-user] [--quiet]
# Requisitos: executado como root para operações que mudam proprietário / adicionam usuário / montam fs.
set -euo pipefail

##############################################################################
# Default config (overridable by conf/prepare-env.conf)
: "${PREP_CONF:=./conf/modules/prepare-env.conf}"
: "${LFS:=/mnt/lfs}"
: "${LFS_USER:=lfs}"
: "${LFS_GROUP:=lfs}"
: "${LFS_TOOLS:=$LFS/tools}"
: "${LFS_SOURCES:=$LFS/sources}"
: "${LFS_BUILD:=$LFS/build}"
: "${LFS_LOGS:=$LFS/logs}"
: "${LFS_CACHE:=$LFS/cache}"
: "${ENABLE_CHROOT:=yes}"
: "${CREATE_USER:=yes}"   # set to 'no' to skip automatic user creation
: "${QUIET:=no}"
: "${PKG_DB_MODULE_PATH:=./modules/pkg-db.sh}"  # path to pkg-db module (optional)
: "${REQUIRED_CMDS:=bash chown chmod mkdir mount umount useradd groupadd ln sed awk hostname uname id sed tar gzip sqlite3}"


# Internal state
_env_called_from=""

# Helper: color output (no color in quiet)
_color() {
    local c="$1"; shift
    local s="$*"
    if [ "${QUIET,,}" = "yes" ]; then
        printf '%s\n' "$s"
        return
    fi
    case "$c" in
        red) printf '\033[31m%s\033[0m\n' "$s" ;;
        green) printf '\033[32m%s\033[0m\n' "$s" ;;
        yellow) printf '\033[33m%s\033[0m\n' "$s" ;;
        blue) printf '\033[34m%s\033[0m\n' ;;
        bold) printf '\033[1m%s\033[0m\n' "$s" ;;
        *) printf '%s\n' "$s" ;;
    esac
}

log_info()  { _color blue "INFO: $*"; }
log_ok()    { _color green "OK: $*"; }
log_warn()  { _color yellow "WARN: $*"; }
log_err()   { _color red "ERROR: $*"; }

# Try to source pkg-db if available (best-effort)
_pkgdb_sourced=0
if [ -f "$PKG_DB_MODULE_PATH" ]; then
    # shellcheck disable=SC1091
    source "$PKG_DB_MODULE_PATH" || true
    _pkgdb_sourced=1
fi

pkgdb_record_safe() {
    # if pkg-db module present, use its record function, otherwise just echo.
    if [ "$_pkgdb_sourced" -eq 1 ] && command -v pkgdb_record_event >/dev/null 2>&1; then
        pkgdb_record_event "${1:-NULL}" "${2:-NULL}" "${3:-INFO}" "${4:-}"
    else
        # fallback local log
        log_info "[pkgdb-fallback] $3: $4"
    fi
}

# Load config (overrides defaults)
env_load_config() {
    local cfg="${1:-$PREP_CONF}"
    if [ -f "$cfg" ]; then
        # shellcheck disable=SC1090
        source "$cfg"
        log_info "Loaded config: $cfg"
    else
        log_warn "Config $cfg not found; using defaults"
    fi

    # ensure paths absolute
    LFS=$(readlink -f "$LFS")
    LFS_TOOLS=$(readlink -f "$LFS_TOOLS")
    LFS_SOURCES=$(readlink -f "$LFS_SOURCES")
    LFS_BUILD=$(readlink -f "$LFS_BUILD")
    LFS_LOGS=$(readlink -f "$LFS_LOGS")
    LFS_CACHE=$(readlink -f "$LFS_CACHE")
}

# Check that required commands exist (warn/fail)
env_check_prereqs() {
    local missing=()
    for cmd in $REQUIRED_CMDS; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if [ "${#missing[@]}" -ne 0 ]; then
        log_err "Missing required commands: ${missing[*]}"
        pkgdb_record_safe NULL NULL ERROR "prepare-env: missing required commands: ${missing[*]}"
        return 1
    fi
    log_ok "Prerequisites present"
    return 0
}

# Create directory if not exists, set mode/owner optional
_env_mkdir() {
    local dir="$1"; local mode="${2:-}"; local owner="${3:-}"
    if [ -z "$dir" ]; then return 1; fi
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        log_info "Created $dir"
    fi
    if [ -n "$mode" ]; then chmod "$mode" "$dir" || true; fi
    if [ -n "$owner" ]; then chown -R "$owner" "$dir" || true; fi
}

# Create the minimal LFS layout (chapter 4.2 and base)
env_create_layout_minimum() {
    log_info "Creating minimal LFS layout at $LFS"
    # base parent
    _env_mkdir "$LFS" 0755 root:root
    _env_mkdir "$LFS/tools" 0755 root:root
    _env_mkdir "$LFS/sources" 0755 root:root
    _env_mkdir "$LFS/build" 0755 root:root
    _env_mkdir "$LFS/logs" 0755 root:root
    _env_mkdir "$LFS/cache" 0755 root:root

    # typical minimal dirs
    _env_mkdir "$LFS/bin" 0755 root:root
    _env_mkdir "$LFS/lib" 0755 root:root
    _env_mkdir "$LFS/usr" 0755 root:root
    _env_mkdir "$LFS/usr/bin" 0755 root:root
    _env_mkdir "$LFS/usr/lib" 0755 root:root
    _env_mkdir "$LFS/usr/sbin" 0755 root:root
    _env_mkdir "$LFS/usr/share" 0755 root:root
    # lib64 for 64-bit platforms where needed
    if [ "$(uname -m)" = "x86_64" ] || [ "$(uname -m)" = "aarch64" ]; then
        _env_mkdir "$LFS/lib64" 0755 root:root
    fi

    # create symlinks: bin -> usr/bin, lib -> usr/lib, sbin -> usr/sbin (idempotent)
    # symlink only inside LFS (do not replace host /usr)
    (
        cd "$LFS" || return
        ln -sfv usr/bin bin 2>/dev/null || true
        ln -sfv usr/lib lib 2>/dev/null || true
        ln -sfv usr/sbin sbin 2>/dev/null || true
    )
    log_ok "Minimal layout created"
    pkgdb_record_safe NULL NULL INFO "create-layout-minimum" "Created minimal layout in $LFS"
}

# Expand directories as in chapter 7.5
env_create_expanded_dirs() {
    log_info "Creating full directory hierarchy (per LFS ch07)"
    # top-level extras
    for d in boot home mnt opt srv; do _env_mkdir "$LFS/$d" 0755 root:root; done
    _env_mkdir "$LFS/etc/opt" 0755 root:root
    _env_mkdir "$LFS/etc/sysconfig" 0755 root:root
    _env_mkdir "$LFS/lib/firmware" 0755 root:root
    _env_mkdir "$LFS/media/floppy" 0755 root:root
    _env_mkdir "$LFS/media/cdrom" 0755 root:root

    # /usr and local structure
    for p in "" "local"; do
        _env_mkdir "$LFS/usr/$p/include" 0755 root:root
        _env_mkdir "$LFS/usr/$p/src" 0755 root:root
        _env_mkdir "$LFS/usr/$p/share/man/man1" 0755 root:root
        _env_mkdir "$LFS/usr/$p/share/man/man2" 0755 root:root
        _env_mkdir "$LFS/usr/$p/share/man/man3" 0755 root:root
        _env_mkdir "$LFS/usr/$p/share/man/man4" 0755 root:root
        _env_mkdir "$LFS/usr/$p/share/man/man5" 0755 root:root
        _env_mkdir "$LFS/usr/$p/share/man/man6" 0755 root:root
        _env_mkdir "$LFS/usr/$p/share/man/man7" 0755 root:root
        _env_mkdir "$LFS/usr/$p/share/man/man8" 0755 root:root
    done

    # var subdirs
    for d in cache local log mail opt spool; do _env_mkdir "$LFS/var/$d" 0755 root:root; done
    _env_mkdir "$LFS/var/lib/color" 0755 root:root
    _env_mkdir "$LFS/var/lib/misc" 0755 root:root
    _env_mkdir "$LFS/var/lib/locate" 0755 root:root

    # special perms
    _env_mkdir "$LFS/root" 0750 root:root
    _env_mkdir "$LFS/tmp" 1777 root:root
    _env_mkdir "$LFS/var/tmp" 1777 root:root

    # run & lock symlinks inside LFS
    if [ ! -e "$LFS/var/run" ]; then
        ln -sfv /run "$LFS/var/run" || true
    fi
    if [ ! -e "$LFS/var/lock" ]; then
        ln -sfv /run/lock "$LFS/var/lock" || true
    fi

    log_ok "Expanded directories created"
    pkgdb_record_safe NULL NULL INFO "create-expanded-dirs" "Created expanded dir hierarchy under $LFS"
}

# Create essential files & symlink mtab -> /proc/self/mounts (ch07.6)
env_create_essential_files() {
    log_info "Creating essential files and symlinks inside $LFS"

    # /etc/mtab -> /proc/self/mounts
    local mtab="$LFS/etc/mtab"
    _env_mkdir "$LFS/etc" 0755 root:root
    if [ -e "$mtab" ]; then
        log_info "mtab exists, skipping: $mtab"
    else
        ln -sfv /proc/self/mounts "$mtab" || true
        log_info "Created symlink $mtab -> /proc/self/mounts"
    fi

    # /etc/hosts
    local hosts="$LFS/etc/hosts"
    if [ ! -f "$hosts" ]; then
        cat > "$hosts" <<EOF
127.0.0.1   localhost $(hostname -s)
::1         localhost
EOF
        chmod 644 "$hosts" || true
        log_info "Created $hosts"
    fi

    # /etc/passwd (minimal)
    local passwdf="$LFS/etc/passwd"
    if [ ! -f "$passwdf" ]; then
        cat > "$passwdf" <<'EOF'
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon:/run/dbus:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF
        chmod 644 "$passwdf" || true
        log_info "Created minimal $passwdf"
    fi

    # /etc/group (minimal)
    local groupf="$LFS/etc/group"
    if [ ! -f "$groupf" ]; then
        cat > "$groupf" <<'EOF'
root:x:0:
bin:x:1:
daemon:x:6:
sys:x:3:
adm:x:4:
tty:x:5:
disk:x:6:
wheel:x:10:
nogroup:x:65534:
EOF
        chmod 644 "$groupf" || true
        log_info "Created minimal $groupf"
    fi

    # /var/log files
    _env_mkdir "$LFS/var/log" 0755 root:root
    for f in btmp lastlog faillog wtmp; do
        : > "$LFS/var/log/$f" 2>/dev/null || true
    done
    chmod 600 "$LFS/var/log/btmp" 2>/dev/null || true
    chmod 664 "$LFS/var/log/lastlog" 2>/dev/null || true

    log_ok "Essential files created"
    pkgdb_record_safe NULL NULL INFO "create-essential-files" "Created essential files under $LFS"
}

# Add lfs user & group (chapter 4.3) - idempotent
env_create_user() {
    if [ "${CREATE_USER,,}" = "no" ]; then
        log_info "CREATE_USER=no: skipping user creation"
        return 0
    fi

    # require root to add user
    if [ "$(id -u)" -ne 0 ]; then
        log_err "env_create_user: must be run as root to add user"
        return 1
    fi

    # create group if missing
    if ! getent group "$LFS_GROUP" >/dev/null 2>&1; then
        groupadd "$LFS_GROUP" || true
        log_info "Created group $LFS_GROUP"
    else
        log_info "Group $LFS_GROUP already exists"
    fi

    # create user if missing
    if ! id -u "$LFS_USER" >/dev/null 2>&1; then
        # create home minimal; -k /dev/null to not copy skel files
        useradd -s /bin/bash -g "$LFS_GROUP" -m -k /dev/null "$LFS_USER" || true
        log_info "Created user $LFS_USER"
    else
        log_info "User $LFS_USER already exists"
    fi

    # create home if not present
    local lfs_home
    lfs_home=$(getent passwd "$LFS_USER" | cut -d: -f6 || echo "/home/$LFS_USER")
    if [ ! -d "$lfs_home" ]; then
        mkdir -p "$lfs_home"
        chown "$LFS_USER":"$LFS_GROUP" "$lfs_home" || true
    fi

    # chown LFS dirs to lfs where appropriate
    chown -R "$LFS_USER":"$LFS_GROUP" "$LFS_TOOLS" "$LFS_SOURCES" "$LFS_BUILD" "$LFS_LOGS" "$LFS_CACHE" 2>/dev/null || true
    log_ok "User and group ready; ownership configured"
    pkgdb_record_safe NULL NULL INFO "create-user" "Added user $LFS_USER and set ownership"
}

# Create user shell files (~lfs/.bash_profile and .bashrc) per chapter 4.4
env_setup_lfs_user_env() {
    local lfs_home
    lfs_home=$(getent passwd "$LFS_USER" | cut -d: -f6 || echo "/home/$LFS_USER")
    if [ ! -d "$lfs_home" ]; then
        log_warn "LFS home $lfs_home not found; skipping .bash setup"
        return 0
    fi

    local bash_profile="$lfs_home/.bash_profile"
    local bashrc="$lfs_home/.bashrc"

    if [ ! -f "$bash_profile" ]; then
        cat > "$bash_profile" <<'EOF'
exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash
EOF
        chown "$LFS_USER":"$LFS_GROUP" "$bash_profile" || true
        chmod 644 "$bash_profile" || true
        log_info "Created $bash_profile"
    else
        log_info "$bash_profile exists - skipping"
    fi

    if [ ! -f "$bashrc" ]; then
        cat > "$bashrc" <<'EOF'
set +h
umask 022
LFS=/mnt/lfs
LC_ALL=POSIX
LFS_TGT="$(uname -m)-lfs-linux-gnu"
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
PATH=$LFS/tools/bin:$PATH
CONFIG_SITE=$LFS/usr/share/config.site
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
EOF
        chown "$LFS_USER":"$LFS_GROUP" "$bashrc" || true
        chmod 644 "$bashrc" || true
        log_info "Created $bashrc"
    else
        log_info "$bashrc exists - skipping"
    fi

    log_ok "LFS user shell environment set"
    pkgdb_record_safe NULL NULL INFO "setup-lfs-user-env" "Configured .bash_profile and .bashrc for $LFS_USER"
}

# chown tools to root:root (chapter 7 changing owner)
env_chown_tools_root() {
    if [ -d "$LFS_TOOLS" ]; then
        chown -R root:root "$LFS_TOOLS" || true
        log_ok "Set $LFS_TOOLS owner to root:root"
        pkgdb_record_safe NULL NULL INFO "chown-tools" "Changed owner of $LFS_TOOLS to root:root"
    else
        log_warn "$LFS_TOOLS does not exist; skipping chown to root"
    fi
}

# Mount virtual kernel filesystems into $LFS (chapter 7 kernfs)
env_mount_virtual_fs() {
    if [ "${ENABLE_CHROOT,,}" != "yes" ]; then
        log_info "ENABLE_CHROOT not 'yes' - skipping virtual fs mount"
        return 0
    fi

    # need root for mounting
    if [ "$(id -u)" -ne 0 ]; then
        log_err "Mounting virtual filesystems requires root"
        return 1
    fi

    log_info "Mounting pseudo-filesystems into $LFS"

    # create mount points
    _env_mkdir "$LFS/dev" 0755 root:root
    _env_mkdir "$LFS/dev/pts" 0755 root:root
    _env_mkdir "$LFS/proc" 0555 root:root
    _env_mkdir "$LFS/sys" 0555 root:root
    _env_mkdir "$LFS/run" 0755 root:root

    # bind mounts and kernel fss
    mount --bind /dev "$LFS/dev" || true
    mount --bind /dev/pts "$LFS/dev/pts" || true
    mount -t proc proc "$LFS/proc" || true
    mount -t sysfs sysfs "$LFS/sys" || true
    mount -t tmpfs tmpfs "$LFS/run" || true

    # make propagation safe
    mount --make-rslave "$LFS/dev" 2>/dev/null || true

    log_ok "Pseudo-filesystems mounted into $LFS"
    pkgdb_record_safe NULL NULL INFO "mount-virtfs" "Mounted /dev /dev/pts /proc /sys /run into $LFS"
}

# Unmount kernel fs reverse order (safe unmount)
env_umount_virtual_fs() {
    log_info "Unmounting pseudo-filesystems from $LFS (attempting safe order)"
    set +e
    # order: dev/pts, dev, proc, sys, run
    umount -lf "$LFS/dev/pts" 2>/dev/null || true
    umount -lf "$LFS/dev" 2>/dev/null || true
    umount -lf "$LFS/proc" 2>/dev/null || true
    umount -lf "$LFS/sys" 2>/dev/null || true
    umount -lf "$LFS/run" 2>/dev/null || true
    set -e
    log_ok "Pseudo-filesystems unmounted"
    pkgdb_record_safe NULL NULL INFO "umount-virtfs" "Unmounted virtual filesystems from $LFS"
}

# Enter chroot (chapter 7 chroot)
env_enter_chroot() {
    if [ "${ENABLE_CHROOT,,}" != "yes" ]; then
        log_info "ENABLE_CHROOT not 'yes' - skipping chroot enter"
        return 0
    fi
    if [ "$(id -u)" -ne 0 ]; then
        log_err "env_enter_chroot: must be run as root"
        return 1
    fi

    # Ensure /tools ownership corrected before chroot stage (recommended)
    env_chown_tools_root || true

    # Prepare environment variables per book
    local term="${TERM:-xterm}"
    local ps1="(lfs chroot) \u:\w\$ "
    local makeflags
    if command -v nproc >/dev/null 2>&1; then
        makeflags="-j$(nproc)"
    else
        makeflags=""
    fi

    log_info "About to chroot into $LFS. Use Ctrl-D to exit chroot (or logout)."

    # Record event
    pkgdb_record_safe NULL NULL INFO "enter-chroot" "Entering chroot $LFS"

    # run chroot with clean env
    chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$term" PS1="$ps1" PATH=/usr/bin:/usr/sbin MAKEFLAGS="$makeflags" /bin/bash --login
}

# Top-level init orchestration
env_init() {
    # parse simple args: --no-user, --quiet
    local no_user="no"
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-user) no_user="yes"; shift ;;
            --quiet) QUIET="yes"; shift ;;
            *) shift ;;
        esac
    done

    if [ "$no_user" = "yes" ]; then CREATE_USER="no"; fi

    _env_called_from=$(pwd)

    log_info "Starting environment preparation for LFS at $LFS"
    pkgdb_record_safe NULL NULL INFO "prepare-start" "Preparing environment at $LFS"

    # check prereqs
    if ! env_check_prereqs; then
        log_err "Prereqs missing; aborting prepare"
        return 1
    fi

    # create minimal layout
    env_create_layout_minimum

    # expanded directories & special perms
    env_create_expanded_dirs

    # essential files
    env_create_essential_files

    # create user (if allowed)
    if [ "${CREATE_USER,,}" = "yes" ]; then
        env_create_user
        env_setup_lfs_user_env
    else
        log_info "Skipping create_user as configured"
    fi

    # chown tools to root after bootstrap stage (book recommends later; we provide utility)
    # but no enforcement here - orchestration should call after building tools
    # We'll still create the dir if missing and leave ownership as configured
    _env_mkdir "$LFS_TOOLS" 0755 root:root

    log_ok "Environment directory structure and essentials are ready"

    # Mount virtual fs if asked
    if [ "${ENABLE_CHROOT,,}" = "yes" ]; then
        env_mount_virtual_fs
    fi

    pkgdb_record_safe NULL NULL INFO "prepare-done" "Environment prepared at $LFS"

    log_ok "prepare-env completed successfully"
}

# Simple CLI when script executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    # allow quick usage: ./prepare-env.sh --no-user --quiet
    env_load_config "${PREP_CONF}"
    env_init "$@"
    exit 0
fi

# End of prepare-env.sh
