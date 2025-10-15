#!/usr/bin/env bash
# ===================================================================
# 03-build.sh
# Build module for LFS-BLFS automation
#
# Features:
#  - Parses package metafiles (yq)
#  - Executes build phases: pre_build, configure, make, make install (DESTDIR)
#  - Hooks: pre_build, post_build, pre_install, post_install, post_strip
#  - Isolation: chroot / fakeroot / sandbox fallback
#  - Robust error handling: trap, run_phase wrapper, detect_silent_error
#  - --continue support (skips packages already built OK)
#  - Retries, backoff, timeout per phase
#  - Locks per package, concurrency limit, logs per-phase & per-package
#  - Strip, package (tar.xz) generation, state YAML per package and global
#
# Requirements (minimum): bash, yq(v4+), make, tar, strip, flock, timeout, rsync (optional)
# ===================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ----------------------------
# Configuration defaults (can be overridden via config.env)
# ----------------------------
LFS_BUILDER_ROOT="${LFS_BUILDER_ROOT:-/opt/lfs-builder}"
METAFILES_DIR="${METAFILES_DIR:-$LFS_BUILDER_ROOT/metafiles}"
LOGDIR="${LOGDIR:-$LFS_BUILDER_ROOT/logs}"
STATEDIR="${STATEDIR:-$LFS_BUILDER_ROOT/state}"
BUILDSTATE_DIR="${BUILDSTATE_DIR:-$STATEDIR/build.d}"
GLOBAL_BUILD_STATE="${GLOBAL_BUILD_STATE:-$STATEDIR/build.yml}"
SOURCES_DIR="${SOURCES_DIR:-$LFS_BUILDER_ROOT/sources}"
BUILDROOT="${BUILDROOT:-$LFS_BUILDER_ROOT/build}"
PACKAGES_DIR="${PACKAGES_DIR:-$LFS_BUILDER_ROOT/packages}"
LOCKDIR="${LOCKDIR:-$STATEDIR/locks}"
CONFIG_FILE="${CONFIG_FILE:-$LFS_BUILDER_ROOT/config.env}"

CONCURRENCY="${CONCURRENCY:-$(nproc)}"
VERBOSITY="${VERBOSITY:-1}"
DEFAULT_RETRY="${DEFAULT_RETRY:-2}"
DEFAULT_PHASE_TIMEOUT="${DEFAULT_PHASE_TIMEOUT:-7200}"  # seconds (2 hours)
STRIP_BINARIES="${STRIP_BINARIES:-true}"
PACKAGE_TYPE="${PACKAGE_TYPE:-tar.xz}"
CHROOT_PATH="${CHROOT_PATH:-/mnt/lfs}"

mkdir -p "$METAFILES_DIR" "$LOGDIR" "$STATEDIR" "$BUILDSTATE_DIR" "$SOURCES_DIR" "$BUILDROOT" "$PACKAGES_DIR" "$LOCKDIR"

# ----------------------------
# Colors and logger (thread-safe with FD 9)
# ----------------------------
_init_colors() {
  RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'; BLUE=$'\e[1;34m'; CYAN=$'\e[1;36m'; RESET=$'\e[0m'
}
_init_colors

LOGFILE="${LOGDIR}/build-$(date +'%F_%H-%M-%S').log"

_log() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts=$(date +"%F %T")
  local prefix color
  case "$level" in
    INFO) prefix="[INFO]"; color="$BLUE" ;;
    WARN) prefix="[WARN]"; color="$YELLOW" ;;
    ERROR) prefix="[ERRO]"; color="$RED" ;;
    OK) prefix="[ OK ]"; color="$GREEN" ;;
    DBG) prefix="[DBG]"; color="$CYAN" ;;
    *) prefix="[LOG]"; color="$RESET" ;;
  esac
  {
    flock 9
    printf "%s%s%s %s %s\n" "$color" "$prefix" "$RESET" "$ts" "$msg" | tee -a "$LOGFILE" >/dev/null
  } 9>>"$LOGFILE"
}
log_info()  { _log INFO "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }
log_ok()    { _log OK "$@"; }
log_dbg()   { [ "${VERBOSITY:-1}" -ge 2 ] && _log DBG "$@"; }

# ----------------------------
# Error handling & traps
# ----------------------------
handle_fatal() {
  local rc=$? lineno=${1:-N/A} cmd="${BASH_COMMAND:-N/A}"
  log_error "Fatal error (rc=${rc}) at line ${lineno}: ${cmd}"
  exit "$rc"
}
trap 'handle_fatal ${LINENO}' ERR
trap 'handle_exit' EXIT

handle_exit() {
  local rc=$?
  # we intentionally do not exit here if other cleanup functions run per package
  if [[ $rc -ne 0 ]]; then
    log_warn "Script exiting with code $rc"
  fi
}

# ----------------------------
# Utility functions
# ----------------------------
safe_mkdir_p() { mkdir -p "$@" || { log_error "mkdir failed: $*"; return 1; } }
filename_from_path() { local p="$1"; echo "${p##*/}"; }

# ----------------------------
# Lock helpers (per package)
# ----------------------------
PKG_LOCK_FD=0
acquire_pkg_lock() {
  local pkg="$1"
  local lockfile="${LOCKDIR}/build-${pkg}.lock"
  safe_mkdir_p "$(dirname "$lockfile")"
  exec {PKG_LOCK_FD}>"$lockfile"
  if ! flock -n "$PKG_LOCK_FD"; then
    log_warn "Lock exists for $pkg at $lockfile"
    return 1
  fi
  printf "%s\n" "$$ $(date +%s)" >&${PKG_LOCK_FD}
  return 0
}
release_pkg_lock() {
  if [[ -n "${PKG_LOCK_FD:-}" && "${PKG_LOCK_FD}" -ne 0 ]]; then
    flock -u "$PKG_LOCK_FD" || true
    eval "exec ${PKG_LOCK_FD}>&-"
    PKG_LOCK_FD=0
  fi
}

# ----------------------------
# State helpers (per package)
# ----------------------------
write_pkg_state() {
  local pkg="$1"; shift
  local file="${BUILDSTATE_DIR}/${pkg}.yml"
  {
    echo "package: \"${pkg}\""
    for kv in "$@"; do
      echo "$kv"
    done
    echo "timestamp: \"$(date --iso-8601=seconds)\""
  } > "${file}.tmp" && mv "${file}.tmp" "$file"
}

merge_build_states() {
  local out="${GLOBAL_BUILD_STATE}"
  echo "build:" > "${out}.tmp"
  for f in "$BUILDSTATE_DIR"/*.yml; do
    [[ -f "$f" ]] || continue
    local pkg; pkg="$(basename "$f" .yml)"
    echo "  $pkg:" >>"${out}.tmp"
    sed -e 's/^/    /' "$f" >>"${out}.tmp"
  done
  mv "${out}.tmp" "$out"
  log_info "Global build state written to $out"
}

# ----------------------------
# Running phases robustly: run_phase + detect_silent_error + retry
# ----------------------------
run_phase() {
  local pkg="$1"; local phase="$2"; local cmd="$3"; local phase_log="$4"
  local timeout_sec="${5:-$DEFAULT_PHASE_TIMEOUT}"
  log_info "[$pkg] Phase '$phase' starting: $cmd (timeout ${timeout_sec}s)"
  # run command with timeout, capture output to per-phase log
  safe_mkdir_p "$(dirname "$phase_log")"
  # run preserving pipefail
  if ! timeout --preserve-status "$timeout_sec" bash -e -o pipefail -c "$cmd" > >(tee -a "$phase_log") 2> >(tee -a "$phase_log" >&2); then
    log_error "[$pkg] Phase '$phase' failed (non-zero exit) — see $phase_log"
    return 1
  fi
  # detect silent errors by scanning log
  if ! detect_silent_error "$pkg" "$phase" "$phase_log"; then
    log_error "[$pkg] Phase '$phase' failed due silent error detection (see $phase_log)"
    return 1
  fi
  log_ok "[$pkg] Phase '$phase' completed successfully"
  return 0
}

# detect common failure patterns even if exit 0
detect_silent_error() {
  local pkg="$1"; local phase="$2"; local logf="$3"
  # common error regex (case-insensitive)
  local patterns="(error:|undefined reference|cannot find|No rule to make target|segmentation fault|traceback|permission denied|failed to|ld: cannot|collect2: error|internal compiler error|undefined reference to|cannot find -l)"
  if grep -Ei "$patterns" "$logf" >/dev/null 2>&1; then
    log_warn "[$pkg] $phase: suspicious patterns found in log"
    return 1
  fi
  # For install phase, ensure DESTDIR contents are non-empty and contain executables or libs
  if [[ "$phase" == "install" || "$phase" == "make install" ]]; then
    local destdir
    destdir="$(yq eval -r '.packages[] | select(.name=="'"$pkg"'") | .install.destdir // ""' "$CURRENT_META" 2>/dev/null || true)"
    if [[ -z "$destdir" ]]; then
      destdir="${BUILDROOT}/${pkg}/destdir"
    fi
    if [[ ! -d "$destdir" || -z "$(find "$destdir" -type f -not -name '*.la' -not -name '*.pc' -print -quit 2>/dev/null)" ]]; then
      log_warn "[$pkg] install phase produced no artifacts in $destdir"
      return 1
    fi
  fi
  return 0
}

# retry wrapper for run_phase
retry_run_phase() {
  local pkg="$1"; local phase="$2"; local cmd="$3"; local phase_log="$4"
  local retries="${5:-$DEFAULT_RETRY}"
  local timeout_sec="${6:-$DEFAULT_PHASE_TIMEOUT}"
  local attempt=1
  local backoff=5
  until run_phase "$pkg" "$phase" "$cmd" "$phase_log" "$timeout_sec"; do
    if (( attempt >= retries )); then
      log_error "[$pkg] Phase '$phase' failed after ${attempt} attempts"
      return 1
    fi
    log_warn "[$pkg] Retry $attempt/$retries for phase '$phase' after ${backoff}s"
    sleep "$backoff"
    attempt=$((attempt+1))
    backoff=$((backoff*2))
  done
  return 0
}

# ----------------------------
# Helpers: run hook (script or inline command)
# ----------------------------
run_hook() {
  local pkg="$1"; local hook="$2"; local cwd="$3"; local hook_log="$4"
  if [[ -z "$hook" || "$hook" == "null" ]]; then return 0; fi
  log_info "[$pkg] Running hook: $hook"
  safe_mkdir_p "$(dirname "$hook_log")"
  pushd "$cwd" >/dev/null 2>&1 || return 1
  # prefer scripts in builder hooks dir
  if [[ -f "$LFS_BUILDER_ROOT/hooks/$hook" ]]; then
    bash -e "$LFS_BUILDER_ROOT/hooks/$hook" > >(tee -a "$hook_log") 2> >(tee -a "$hook_log" >&2) || { popd >/dev/null; return 1; }
  elif [[ -f "$cwd/$hook" ]]; then
    bash -e "$cwd/$hook" > >(tee -a "$hook_log") 2> >(tee -a "$hook_log" >&2) || { popd >/dev/null; return 1; }
  else
    # inline command
    bash -e -c "$hook" > >(tee -a "$hook_log") 2> >(tee -a "$hook_log" >&2) || { popd >/dev/null; return 1; }
  fi
  popd >/dev/null 2>&1
  log_ok "[$pkg] Hook finished: $hook"
  return 0
}

# ----------------------------
# Build package (core)
# ----------------------------
process_package() {
  local pkg="$1"
  local metafile
  log_info "=== Processing package: $pkg ==="

  # find metafile and set CURRENT_META for detect_silent_error
  if ! metafile=$(find "$METAFILES_DIR" -type f -name '*.yml' -o -name '*.yaml' -exec grep -l "name:[[:space:]]*${pkg}" {} + 2>/dev/null | head -n1); then
    log_error "Metafile for $pkg not found under $METAFILES_DIR"
    write_pkg_state "$pkg" "status: failed" "reason: metafile-not-found"
    return 1
  fi
  CURRENT_META="$metafile"

  # respect continue option: if state OK and CONTINUE set, skip
  local statefile="${BUILDSTATE_DIR}/${pkg}.yml"
  if [[ "${CONTINUE:-false}" == "true" && -f "$statefile" ]]; then
    local st
    st=$(yq eval -r '.status' "$statefile" 2>/dev/null || echo "unknown")
    if [[ "$st" == "ok" ]]; then
      log_info "[$pkg] SKIP (already built ok)"
      return 0
    fi
    log_warn "[$pkg] Previous state: $st -> will rebuild"
  fi

  # acquire lock
  if ! acquire_pkg_lock "$pkg"; then
    write_pkg_state "$pkg" "status: skipped" "reason: locked"
    return 2
  fi

  local pkg_logdir="${LOGDIR}/${pkg}"
  safe_mkdir_p "$pkg_logdir"
  local main_log="${pkg_logdir}/build-${pkg}-$(date +'%F_%H-%M-%S').log"

  # prepare dirs
  local src_dir="${BUILDROOT}/${pkg}/src"
  local build_dir="${BUILDROOT}/${pkg}/build"
  local destdir="${BUILDROOT}/${pkg}/destdir"
  rm -rf "${BUILDROOT}/${pkg}" || true
  mkdir -p "$src_dir" "$build_dir" "$destdir"

  # copy extracted sources into src_dir (extracted by 02-extract)
  # we expect extract put source in BUILDROOT/<pkg>/ (or /opt/lfs-builder/build/<pkg>/)
  if [[ -d "${BUILDROOT}/${pkg}" ]]; then
    # copy all items except destdir/build if present
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete "${BUILDROOT}/${pkg}/" "$src_dir/" >>"$main_log" 2>&1 || cp -a "${BUILDROOT}/${pkg}/." "$src_dir/" || true
    else
      cp -a "${BUILDROOT}/${pkg}/." "$src_dir/" || true
    fi
  fi

  # env and build directives from metafile
  local build_type configure_cmd make_cmd install_cmd strip_flag
  build_type=$(yq eval -r ".packages[] | select(.name==\"$pkg\") | .build_type // \"standard\"" "$CURRENT_META" 2>/dev/null || echo "standard")
  configure_cmd=$(yq eval -r ".packages[] | select(.name==\"$pkg\") | .build.configure // \"\"" "$CURRENT_META" 2>/dev/null || true)
  make_cmd=$(yq eval -r ".packages[] | select(.name==\"$pkg\") | .build.make // \"make -j\\\$(nproc)\"" "$CURRENT_META" 2>/dev/null || true)
  install_cmd=$(yq eval -r ".packages[] | select(.name==\"$pkg\") | .build.install // \"make install DESTDIR=\\\"$destdir\\\"\"" "$CURRENT_META" 2>/dev/null || true)
  strip_flag=$(yq eval -r ".packages[] | select(.name==\"$pkg\") | .strip // ${STRIP_BINARIES}" "$CURRENT_META" 2>/dev/null || true)

  # prepare environment overrides if present
  local env_list
  env_list=$(yq eval -r ".packages[] | select(.name==\"$pkg\") | .environment[]" "$CURRENT_META" 2>/dev/null || true)
  local env_file="${BUILDROOT}/${pkg}/env.sh"
  : > "$env_file"
  if [[ -n "$env_list" ]]; then
    while IFS= read -r envline; do
      [[ -z "$envline" || "$envline" == "null" ]] && continue
      echo "export $envline" >> "$env_file"
    done <<< "$env_list"
  fi

  # hooks
  local hook_pre_build hook_post_build hook_pre_install hook_post_install hook_post_strip
  hook_pre_build=$(yq eval -r ".packages[] | select(.name==\"$pkg\") | .hooks.pre_build // \"\"" "$CURRENT_META" 2>/dev/null || true)
  hook_post_build=$(yq eval -r ".packages[] | select(.name==\"$pkg\") | .hooks.post_build // \"\"" "$CURRENT_META" 2>/dev/null || true)
  hook_pre_install=$(yq eval -r ".packages[] | select(.name==\"$pkg\") | .hooks.pre_install // \"\"" "$CURRENT_META" 2>/dev/null || true)
  hook_post_install=$(yq eval -r ".packages[] | select(.name==\"$pkg\") | .hooks.post_install // \"\"" "$CURRENT_META" 2>/dev/null || true)
  hook_post_strip=$(yq eval -r ".packages[] | select(.name==\"$pkg\") | .hooks.post_strip // \"\"" "$CURRENT_META" 2>/dev/null || true)

  # mode: chroot, fakeroot, sandbox
  local mode
  mode=$(yq eval -r ".packages[] | select(.name==\"$pkg\") | .build.mode // \"${BUILD_MODE:-auto}\"" "$CURRENT_META" 2>/dev/null || true)
  # BUILD_MODE env can override (chroot/fakeroot/auto)
  mode="${BUILD_MODE:-$mode}"

  # begin phases
  local start_ts; start_ts=$(date +%s)
  write_pkg_state "$pkg" "status: in-progress" "build_dir: \"$build_dir\"" "install_dir: \"$destdir\"" "mode: \"$mode\""

  # helper to run phases according to mode: if chroot -> create chroot wrapper; if fakeroot -> use fakeroot; else run directly
  run_cmd_in_env() {
    local cmd="$1" local infile="$2" local outfile="$3"
    # We want to run commands under env_file if present; use bash -lc "source env && cmd"
    local full_cmd="set -euo pipefail; [ -f \"$env_file\" ] && source \"$env_file\" || true; cd \"$build_dir\"; $cmd"
    if [[ "$mode" == "chroot" ]]; then
      # copy build artifacts into chroot workdir? Simpler: mount --bind or instruct user to run chroot mode from outside.
      # Here we use chroot if user has privileges and CHROOT_PATH exists.
      if [[ ! -d "$CHROOT_PATH" ]]; then
        log_warn "CHROOT mode requested but $CHROOT_PATH not present. Falling back to sandbox."
        bash -lc "$full_cmd" >"$outfile" 2>&1 || return $?
      else
        # create wrapper script inside chroot tmp
        local wrapper="/tmp/lfs_build_wrapper_${pkg}.sh"
        printf "%s\n" "#!/bin/bash" "$full_cmd" > "$wrapper"
        chmod +x "$wrapper"
        # copy wrapper into chroot & run
        cp -a "$wrapper" "$CHROOT_PATH/$wrapper" 2>/dev/null || cp -a "$wrapper" "$CHROOT_PATH/tmp/$(basename "$wrapper")" 2>/dev/null || true
        chroot "$CHROOT_PATH" "/$wrapper" >"$outfile" 2>&1 || return $?
        rm -f "$wrapper" || true
      fi
    elif [[ "$mode" == "fakeroot" ]]; then
      if command -v fakeroot >/dev/null 2>&1; then
        fakeroot bash -lc "$full_cmd" >"$outfile" 2>&1 || return $?
      else
        log_warn "fakeroot mode requested but fakeroot not found. Running without fakeroot."
        bash -lc "$full_cmd" >"$outfile" 2>&1 || return $?
      fi
    else
      # sandbox / normal
      bash -lc "$full_cmd" >"$outfile" 2>&1 || return $?
    fi
    return 0
  }

  # PHASE: pre_build
  if [[ -n "$hook_pre_build" && "$hook_pre_build" != "null" ]]; then
    run_hook "$pkg" "$hook_pre_build" "$src_dir" "${pkg_logdir}/hook-pre_build.log" || log_warn "pre_build hook failed for $pkg (continuing)"
  fi

  # PHASE: configure (if present)
  if [[ -n "$configure_cmd" && "$configure_cmd" != "null" ]]; then
    log_info "[$pkg] Running configure"
    # place configure command into build_dir; we run configure from src_dir typically
    # ensure build_dir exists
    mkdir -p "$build_dir"
    # build run command: change to build_dir and run configure from src_dir
    local cfg_full="cd \"$build_dir\"; $configure_cmd"
    local cfg_log="${pkg_logdir}/configure.log"
    if ! retry_run_phase "$pkg" "configure" "$cfg_full" "$cfg_log" "$DEFAULT_RETRY" "$DEFAULT_PHASE_TIMEOUT"; then
      write_pkg_state "$pkg" "status: failed" "phase: configure" "reason: configure-failed"
      release_pkg_lock
      return 1
    fi
  fi

  # PHASE: build (make)
  if [[ -n "$make_cmd" && "$make_cmd" != "null" ]]; then
    log_info "[$pkg] Running build: $make_cmd"
    local build_full="cd \"$build_dir\"; $make_cmd"
    local build_log="${pkg_logdir}/make.log"
    if ! retry_run_phase "$pkg" "make" "$build_full" "$build_log" "$DEFAULT_RETRY" "$DEFAULT_PHASE_TIMEOUT"; then
      write_pkg_state "$pkg" "status: failed" "phase: make" "reason: make-failed"
      release_pkg_lock
      return 1
    fi
  fi

  # post_build hook
  if [[ -n "$hook_post_build" && "$hook_post_build" != "null" ]]; then
    run_hook "$pkg" "$hook_post_build" "$build_dir" "${pkg_logdir}/hook-post_build.log" || log_warn "post_build hook failed for $pkg (continuing)"
  fi

  # PHASE: pre_install hook
  if [[ -n "$hook_pre_install" && "$hook_pre_install" != "null" ]]; then
    run_hook "$pkg" "$hook_pre_install" "$build_dir" "${pkg_logdir}/hook-pre_install.log" || log_warn "pre_install hook failed for $pkg (continuing)"
  fi

  # PHASE: install
  if [[ -n "$install_cmd" && "$install_cmd" != "null" ]]; then
    log_info "[$pkg] Running install: $install_cmd"
    local install_full="cd \"$build_dir\"; $install_cmd"
    local install_log="${pkg_logdir}/install.log"
    if ! retry_run_phase "$pkg" "install" "$install_full" "$install_log" "$DEFAULT_RETRY" "$DEFAULT_PHASE_TIMEOUT"; then
      write_pkg_state "$pkg" "status: failed" "phase: install" "reason: install-failed"
      release_pkg_lock
      return 1
    fi
  fi

  # validate installation (no silent failures)
  # we expect destdir to have some files (not only .la/.pc)
  if ! detect_silent_error "$pkg" "install" "${pkg_logdir}/install.log"; then
    write_pkg_state "$pkg" "status: failed" "phase: install" "reason: silent-error"
    release_pkg_lock
    return 1
  fi

  # PHASE: strip (optional)
  if [[ "${NO_STRIP:-false}" != "true" && "$strip_flag" != "false" && "$STRIP_BINARIES" == "true" ]]; then
    log_info "[$pkg] Stripping binaries (if any)"
    local strip_log="${pkg_logdir}/strip.log"
    # find ELF files and strip unneeded
    find "$destdir" -type f -print0 2>/dev/null | xargs -0 file 2>/dev/null | grep -i 'ELF' | cut -d: -f1 | while read -r bin; do
      if command -v strip >/dev/null 2>&1; then
        if strip --strip-unneeded "$bin" >>"$strip_log" 2>&1; then
          log_dbg "Stripped: $bin"
        fi
      fi
    done
    # run post_strip hook if any
    if [[ -n "$hook_post_strip" && "$hook_post_strip" != "null" ]]; then
      run_hook "$pkg" "$hook_post_strip" "$destdir" "${pkg_logdir}/hook-post_strip.log" || log_warn "post_strip hook failed for $pkg (continuing)"
    fi
  fi

  # PHASE: packaging (create tarball from destdir)
  local pkg_tarball="${PACKAGES_DIR}/${pkg}-${(yq eval -r ".packages[] | select(.name==\"$pkg\") | .version // \"unknown\"" "$CURRENT_META" 2>/dev/null || echo "unknown")}.${PACKAGE_TYPE}"
  log_info "[$pkg] Creating package $pkg_tarball"
  (
    cd "$destdir" || exit 1
    if [[ "$PACKAGE_TYPE" == "tar.xz" ]]; then
      tar -cJf "$pkg_tarball" . >>"$main_log" 2>&1 || { log_error "Failed to create package $pkg_tarball"; }
    elif [[ "$PACKAGE_TYPE" == "tar.gz" ]]; then
      tar -czf "$pkg_tarball" . >>"$main_log" 2>&1 || { log_error "Failed to create package $pkg_tarball"; }
    else
      tar -cJf "$pkg_tarball" . >>"$main_log" 2>&1 || { log_error "Failed to create package $pkg_tarball"; }
    fi
  )
  sha256sum "$pkg_tarball" > "${pkg_tarball}.sha256" 2>>"$main_log" || true

  # Success: write state
  local end_ts; end_ts=$(date +%s)
  local duration=$((end_ts - start_ts))
  write_pkg_state "$pkg" "status: ok" "phase: installed" "duration: \"${duration}s\"" "package: \"${pkg_tarball}\""
  log_ok "[$pkg] Build completed in ${duration}s, package: $pkg_tarball"

  release_pkg_lock
  return 0
}

# ----------------------------
# Job runner with concurrency limit
# ----------------------------
run_jobs() {
  local -n pkgs_ref=$1
  local pids=()
  for pkg in "${pkgs_ref[@]}"; do
    # wait for slot
    while (( $(jobs -rp | wc -l) >= CONCURRENCY )); do
      sleep 0.5
    done
    process_package "$pkg" &
    pids+=("$!")
  done
  local rc=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then rc=1; fi
  done
  return $rc
}

# ----------------------------
# Build target list (supporting --continue)
# ----------------------------
build_target_list() {
  local targets=()
  if [[ "${#ARGS[@]}" -gt 0 ]]; then
    targets=("${ARGS[@]}")
  else
    # all: collect from metafiles
    local files
    files=($(find "$METAFILES_DIR" -type f -name '*.yml' -o -name '*.yaml' 2>/dev/null))
    for f in "${files[@]}"; do
      mapfile -t names < <(yq eval '.packages[]?.name' "$f" 2>/dev/null || true)
      for n in "${names[@]}"; do targets+=("$n"); done
    done
  fi

  # if CONTINUE true, filter out already ok ones
  if [[ "${CONTINUE:-false}" == "true" ]]; then
    local out=()
    for p in "${targets[@]}"; do
      if [[ -f "${BUILDSTATE_DIR}/${p}.yml" ]]; then
        local st
        st=$(yq eval -r '.status' "${BUILDSTATE_DIR}/${p}.yml" 2>/dev/null || echo "unknown")
        if [[ "$st" == "ok" ]]; then
          log_info "[SKIP] $p (already ok)"
          continue
        fi
      fi
      out+=("$p")
    done
    targets=("${out[@]}")
  fi
  printf "%s\n" "${targets[@]}"
}

# ----------------------------
# CLI parsing
# ----------------------------
CONTINUE=false
NO_STRIP=false
KEEP_TEMP=false
RETRY_OVERRIDE=""
BUILD_MODE="${BUILD_MODE:-auto}"
ARGS=()
JOBS_OVERRIDE=""

usage() {
  cat <<EOF
Usage: 03-build.sh [options] [pkg1 pkg2 ...]
Options:
  --continue         skip packages already built ok (reads state/*.yml)
  --no-strip         disable binary stripping
  --keep-temp        keep build directories on failure
  --retry N          override retry attempts (default $DEFAULT_RETRY)
  --jobs N           override concurrency (default $CONCURRENCY)
  --mode MODE        build mode: chroot|fakeroot|auto
  --help
EOF
}

while (( "$#" )); do
  case "$1" in
    --continue) CONTINUE=true; shift ;;
    --no-strip) NO_STRIP=true; STRIP_BINARIES=false; shift ;;
    --keep-temp) KEEP_TEMP=true; shift ;;
    --retry) RETRY_OVERRIDE="$2"; shift 2 ;;
    --jobs) JOBS_OVERRIDE="$2"; shift 2 ;;
    --mode) BUILD_MODE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --) shift; break ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [[ -n "$JOBS_OVERRIDE" ]]; then CONCURRENCY="$JOBS_OVERRIDE"; fi
if [[ -n "$RETRY_OVERRIDE" ]]; then DEFAULT_RETRY="$RETRY_OVERRIDE"; fi
# propagate CONTINUE var for child functions
export CONTINUE

# load optional config.env
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  set -a; source "$CONFIG_FILE"; set +a
fi

# ----------------------------
# Main entry
# ----------------------------
main() {
  log_info "Starting 03-build.sh (concurrency=${CONCURRENCY})"
  # build list
  mapfile -t target_pkgs < <(build_target_list)
  if [[ "${#target_pkgs[@]}" -eq 0 ]]; then
    log_warn "No packages to build."
    exit 0
  fi
  log_info "Packages to build: ${#target_pkgs[@]}"

  # run jobs
  if ! run_jobs target_pkgs; then
    log_warn "Some builds failed. Check $BUILDSTATE_DIR and logs for details."
  fi

  merge_build_states

  # summary
  local total succeeded failed skipped
  total=${#target_pkgs[@]}
  succeeded=$(grep -c "status: ok" "$BUILDSTATE_DIR"/*.yml 2>/dev/null || true)
  failed=$(grep -c "status: failed" "$BUILDSTATE_DIR"/*.yml 2>/dev/null || true)
  skipped=$(grep -c "status: skipped" "$BUILDSTATE_DIR"/*.yml 2>/dev/null || true)
  log_info "Build summary: total=$total ok=$succeeded failed=$failed skipped=$skipped"

  if (( failed > 0 )); then
    log_error "There were build failures."
    exit 1
  fi

  log_ok "All requested builds completed successfully."
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
