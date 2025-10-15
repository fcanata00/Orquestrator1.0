#!/usr/bin/env bash
# ===================================================================
# 02-extract.sh
# Extrai fontes e aplica patches para LFS/BLFS
# Recursos:
#  - extração automática de vários formatos
#  - aplicação ordenada de patches
#  - hooks pre_extract/post_extract/post_patch
#  - locks por pacote, logs por pacote, estado YAML
#  - paralelismo controlado
# Requisitos: bash, yq (v4+), tar, unzip, xz, bzip2, file, patch, flock, timeout
# ===================================================================
set -Eeuo pipefail
IFS=$'\n\t'
# ---------------------------
# Configurações (podem ser sobrescritas por config.env)
# ---------------------------
LFS_BUILDER_ROOT="${LFS_BUILDER_ROOT:-/opt/lfs-builder}"
LOGDIR="${LOGDIR:-$LFS_BUILDER_ROOT/logs}"
STATEDIR="${STATEDIR:-$LFS_BUILDER_ROOT/state}"
LOCKDIR="${LOCKDIR:-$STATEDIR/locks}"
SOURCES_DIR="${SOURCES_DIR:-$LFS_BUILDER_ROOT/sources}"
METAFILES_DIR="${METAFILES_DIR:-$LFS_BUILDER_ROOT/metafiles}"
BUILDROOT="${BUILDROOT:-${LFS_BUILDER_ROOT}/build}"
EXTRACT_STATE_DIR="${STATEDIR}/extract.d"
GLOBAL_EXTRACT_STATE="${STATEDIR}/extract.yml"
CONCURRENCY="${CONCURRENCY:-$(nproc)}"
VERBOSITY="${VERBOSITY:-1}"
CONFIG_FILE="${CONFIG_FILE:-$LFS_BUILDER_ROOT/config.env}"
LOGFILE="${LOGDIR}/extract-$(date +'%F_%H-%M-%S').log"

mkdir -p "$LOGDIR" "$STATEDIR" "$LOCKDIR" "$SOURCES_DIR" "$METAFILES_DIR" "$BUILDROOT" "$EXTRACT_STATE_DIR"
# ---------------------------
# Colors and small logger (thread-safe using FD 9)
# ---------------------------
_init_colors() {
  RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'; BLUE=$'\e[1;34m'; CYAN=$'\e[1;36m'; RESET=$'\e[0m'
}
_init_colors

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
  { flock 9; printf "%s%s%s %s %s\n" "$color" "$prefix" "$RESET" "$ts" "$msg" | tee -a "$LOGFILE" >/dev/null; } 9>>"$LOGFILE"
}
log_info()  { _log INFO "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }
log_ok()    { _log OK "$@"; }
log_dbg()   { [ "${VERBOSITY:-1}" -ge 2 ] && _log DBG "$@"; }
# ---------------------------
# Error handler
# ---------------------------
handle_error() {
  local ec=$? lineno=${1:-N/A} cmd="${BASH_COMMAND:-N/A}"
  log_error "Erro (code=${ec}) linha=${lineno} cmd='${cmd}'"
  # do not exit here: per-package functions handle rollback and exit codes
}
trap 'handle_error ${LINENO}' ERR

# ---------------------------
# Helpers: filename and extension
# ---------------------------
filename_from_path() { local p="$1"; echo "${p##*/}"; }
extension_from_file() { local p="$1"; echo "${p##*.}"; }

# ---------------------------
# Lock helpers (per-package)
# ---------------------------
PKG_LOCK_FD=0
PKG_LOCK_PATH=""
acquire_pkg_lock() {
  local pkg="$1"
  PKG_LOCK_PATH="$LOCKDIR/extract-${pkg}.lock"
  mkdir -p "$(dirname "$PKG_LOCK_PATH")"
  exec {PKG_LOCK_FD}>"$PKG_LOCK_PATH"
  if ! flock -n "$PKG_LOCK_FD"; then
    log_warn "Lock ativo para pacote $pkg — outro processo está extraindo"
    return 1
  fi
  printf "%s\n" "$$ $(date +%s)" >&"${PKG_LOCK_FD}"
  return 0
}
release_pkg_lock() {
  if [[ -n "${PKG_LOCK_FD:-}" && "${PKG_LOCK_FD}" -ne 0 ]]; then
    flock -u "$PKG_LOCK_FD" || true
    eval "exec ${PKG_LOCK_FD}>&-"
    PKG_LOCK_FD=0
  fi
}

# ---------------------------
# Safe removal of partially extracted dirs
# ---------------------------
_safe_remove_dir() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    mkdir -p "$SOURCES_DIR/.corrupted"
    mv "$dir" "$SOURCES_DIR/.corrupted/$(basename "$dir").$(date +%s)" 2>/dev/null || rm -rf "$dir" || true
    log_warn "Diretório parcial movido/removido: $dir"
  fi
}

# ---------------------------
# extract_archive: detecta e extrai um arquivo em dest_dir
# Arguments: <archive_path> <dest_dir>
# Returns 0 on success
# ---------------------------
extract_archive() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  if [[ ! -f "$archive" ]]; then
    log_error "Arquivo não encontrado para extração: $archive"
    return 1
  fi

  # detect type via file(1) and ext fallback
  local ftype
  ftype=$(file -Lb "$archive" || true)
  log_dbg "file type: $ftype for $archive"

  case "$ftype" in
    *tar\ *gzip*|*gzip\ compressed*)
      tar -xzf "$archive" -C "$dest" || return 1
      ;;
    *XZ\ compressed*|*LZMA*|*XZ*)
      tar -xJf "$archive" -C "$dest" || return 1
      ;;
    *bzip2*|*bzip*)
      tar -xjf "$archive" -C "$dest" || return 1
      ;;
    *Zip*|*Zip\ archive*)
      unzip -q "$archive" -d "$dest" || return 1
      ;;
    *gzip*|*ASCII\ text*) # sometimes plain gz single file
      if [[ "${archive##*.}" == "gz" && "${archive##*.tar.gz}" == "$archive" ]]; then
        gunzip -c "$archive" > "$dest/$(basename "${archive%.gz}")" || return 1
      else
        tar -xzf "$archive" -C "$dest" || return 1
      fi
      ;;
    *)
      # fallback to try tar extraction by extension
      case "${archive##*.}" in
        xz|txz) tar -xJf "$archive" -C "$dest" || return 1 ;;
        tar) tar -xf "$archive" -C "$dest" || return 1 ;;
        tgz) tar -xzf "$archive" -C "$dest" || return 1 ;;
        tar.gz) tar -xzf "$archive" -C "$dest" || return 1 ;;
        gz) gunzip -c "$archive" > "$dest/$(basename "${archive%.gz}")" || return 1 ;;
        zip) unzip -q "$archive" -d "$dest" || return 1 ;;
        *)
          log_warn "Tipo não reconhecido para $archive (file says: $ftype). Tentando tar -xf ..."
          tar -xf "$archive" -C "$dest" || { log_error "Extração fallback falhou para $archive"; return 1; }
          ;;
      esac
      ;;
  esac

  return 0
}

# ---------------------------
# apply_patches: aplica lista de patches dentro src_dir
# Arguments: <pkg> <src_dir> <patch_dir_or_list>
# patch entries expected as full paths
# ---------------------------
apply_patches() {
  local pkg="$1"; local src_dir="$2"; shift 2
  local patches=("$@")
  if [[ "${#patches[@]}" -eq 0 ]]; then
    log_dbg "Nenhum patch para aplicar em $pkg"
    return 0
  fi

  pushd "$src_dir" >/dev/null || { log_error "src_dir inexistente: $src_dir"; return 1; }
  for p in "${patches[@]}"; do
    if [[ ! -f "$p" ]]; then
      log_error "Patch não encontrado: $p"
      popd >/dev/null
      return 1
    fi
    log_info "Aplicando patch $p em $pkg"
    # dry-run primeiro
    if patch --dry-run -Np1 -i "$p" >/dev/null 2>&1; then
      if ! patch -Np1 -i "$p" >>"$LOGFILE" 2>&1; then
        log_error "Falha aplicando patch $p (veja $LOGFILE)"
        popd >/dev/null
        return 1
      fi
      log_ok "Patch aplicado: $p"
    else
      log_warn "Patch $p não aplicável (dry-run falhou) — tentando -p0"
      if patch --dry-run -p0 -i "$p" >/dev/null 2>&1 && patch -p0 -i "$p" >>"$LOGFILE" 2>&1; then
        log_ok "Patch aplicado com -p0: $p"
      else
        log_error "Patch $p não pôde ser aplicado (p1/p0 falharam)"
        popd >/dev/null
        return 1
      fi
    fi
  done
  popd >/dev/null
  return 0
}

# ---------------------------
# run_hook: executes a hook command or script in context
# Arguments: <hook_cmd_or_script> <pkg> <src_dir> <build_dir>
# ---------------------------
run_hook() {
  local hook="$1"; local pkg="$2"; local src_dir="$3"; local build_dir="$4"
  if [[ -z "$hook" || "$hook" == "null" ]]; then return 0; fi
  log_info "Executando hook para $pkg: $hook"
  # export context vars for hook
  export PKG_NAME="$pkg" SRC_DIR="$src_dir" BUILD_DIR="$build_dir"
  # if script path exists (relative to builder root or src_dir), prefer that
  if [[ -f "$LFS_BUILDER_ROOT/hooks/$hook" ]]; then
    bash -e "$LFS_BUILDER_ROOT/hooks/$hook" >>"$LOGFILE" 2>&1 || { log_error "Hook $hook falhou (hooks dir)"; return 1; }
  elif [[ -f "$src_dir/$hook" ]]; then
    bash -e "$src_dir/$hook" >>"$LOGFILE" 2>&1 || { log_error "Hook $hook falhou (in src)"; return 1; }
  else
    # treat hook as inline shell command
    bash -c "$hook" >>"$LOGFILE" 2>&1 || { log_error "Hook command failed: $hook"; return 1; }
  fi
  log_ok "Hook concluído: $hook"
  return 0
}

# ---------------------------
# find_metafile_for_pkg (search metafiles dir)
# ---------------------------
find_metafile_for_pkg() {
  local pkg="$1"
  local files
  files=($(find "$METAFILES_DIR" -type f -name '*.yml' -o -name '*.yaml' 2>/dev/null))
  for f in "${files[@]}"; do
    if yq eval ".packages[]? | select(.name == \"$pkg\") | .name" "$f" >/dev/null 2>&1; then
      printf "%s" "$f"
      return 0
    fi
  done
  return 1
}

# ---------------------------
# process_package: extrai e aplica patches para um pacote
# ---------------------------
process_package() {
  local pkg="$1"
  local metafile
  local per_pkg_state="$EXTRACT_STATE_DIR/${pkg}.yml"
  local tmp_state="${per_pkg_state}.tmp"
  : >"$tmp_state"

  log_info "Iniciando extração para pacote: $pkg"

  if ! metafile=$(find_metafile_for_pkg "$pkg"); then
    log_error "metafile não encontrado para $pkg"
    {
      echo "package: \"$pkg\""
      echo "status: failed"
      echo "reason: metafile-not-found"
    } >>"$tmp_state"
    mv "$tmp_state" "$per_pkg_state"
    return 1
  fi

  if ! acquire_pkg_lock "$pkg"; then
    log_warn "Lock ativo; pulando $pkg"
    echo "package: \"$pkg\"" >"$tmp_state"
    echo "status: skipped" >>"$tmp_state"
    mv "$tmp_state" "$per_pkg_state"
    return 2
  fi

  local src_entries
  src_entries=$(yq eval ".packages[] | select(.name == \"$pkg\") | .sources[]" "$metafile" 2>/dev/null || true)

  # destination for extraction
  local dest_base="${BUILDROOT}/${pkg}"
  rm -rf "$dest_base" 2>/dev/null || true
  mkdir -p "$dest_base"

  # run pre_extract hook if present
  local pre_hook
  pre_hook=$(yq eval -r ".packages[] | select(.name == \"$pkg\") | .hooks.pre_extract // \"\"" "$metafile" 2>/dev/null || true)
  if [[ -n "$pre_hook" && "$pre_hook" != "null" ]]; then
    run_hook "$pre_hook" "$pkg" "$SOURCES_DIR/$pkg" "$dest_base" || { log_warn "pre_extract hook falhou para $pkg"; }
  fi

  # iterate source entries: find actual downloaded files in SOURCES_DIR
  local n
  n=$(yq eval "(.packages[] | select(.name == \"$pkg\") | .sources) | length" "$metafile" 2>/dev/null || echo 0)
  local applied_patches=()
  local extracted_any=false
  for idx in $(seq 0 $((n-1))); do
    # determine entry structure
    local entry_raw
    entry_raw=$(yq eval ".packages[] | select(.name == \"$pkg\") | .sources[$idx]" "$metafile" -o=json 2>/dev/null || echo "")
    if [[ -z "$entry_raw" ]]; then continue; fi

    # if it has git key => extracted by fetch as repo; copy or link repo to build dir
    local git_url
    git_url=$(yq eval -r ".packages[] | select(.name == \"$pkg\") | .sources[$idx].git // \"\"" "$metafile" 2>/dev/null || true)
    if [[ -n "$git_url" && "$git_url" != "null" ]]; then
      # determine repo name and dest - same convention as fetch: $SOURCES_DIR/<pkg>/<reponame>
      local repo_basename
      repo_basename="$(basename "${git_url%%.git}")"
      local repo_dir="$SOURCES_DIR/${pkg}/${repo_basename}"
      if [[ -d "$repo_dir" ]]; then
        log_info "Copiando repo $repo_dir para build dir $dest_base"
        # do a lightweight copy (rsync if available) or cp -a
        if command -v rsync >/dev/null 2>&1; then
          rsync -a --delete "$repo_dir/" "$dest_base/" >>"$LOGFILE" 2>&1 || cp -a "$repo_dir/." "$dest_base/" || true
        else
          cp -a "$repo_dir/." "$dest_base/" || true
        fi
        extracted_any=true
      else
        log_warn "Repo esperado não encontrado em $repo_dir"
      fi
      continue
    fi

    # else treat as URL/patch/extra: extract file path
    local url file_name src_file
    url=$(yq eval -r ".packages[] | select(.name == \"$pkg\") | .sources[$idx].url // \"\"" "$metafile" 2>/dev/null || true)
    if [[ -n "$url" && "$url" != "null" ]]; then
      file_name="$(filename_from_path "$url")"
      src_file="$SOURCES_DIR/$pkg/$file_name"
      if [[ ! -f "$src_file" ]]; then
        log_warn "Arquivo de fonte não encontrado (esperado): $src_file"
        continue
      fi
      # If file is patch (extension .patch or .diff), add to patches list
      case "${file_name##*.}" in
        patch|diff)
          applied_patches+=("$src_file")
          log_info "Patch detectado para $pkg: $src_file (será aplicado após extração)"
          continue
          ;;
      esac

      # Otherwise attempt extraction
      log_info "Extraindo $src_file -> $dest_base"
      if extract_archive "$src_file" "$dest_base"; then
        log_ok "Extração concluída: $file_name"
        extracted_any=true
      else
        log_error "Falha ao extrair $src_file para $pkg"
        _safe_remove_dir "$dest_base"
        echo "package: \"$pkg\"" >"$tmp_state"
        echo "status: failed" >>"$tmp_state"
        echo "reason: extract-failed" >>"$tmp_state"
        mv "$tmp_state" "$per_pkg_state"
        release_pkg_lock
        return 1
      fi
    else
      # entry could be inline string (legacy) - attempt to treat as filename in sources dir
      local inline
      inline=$(yq eval -r ".packages[] | select(.name == \"$pkg\") | .sources[$idx]" "$metafile" 2>/dev/null || true)
      if [[ -n "$inline" && "$inline" != "null" ]]; then
        file_name="$(filename_from_path "$inline")"
        src_file="$SOURCES_DIR/$pkg/$file_name"
        if [[ -f "$src_file" ]]; then
          log_info "Extraindo (inline) $src_file -> $dest_base"
          if extract_archive "$src_file" "$dest_base"; then
            extracted_any=true
          else
            log_error "Falha extraindo inline $src_file"
            _safe_remove_dir "$dest_base"
            echo "package: \"$pkg\"" >"$tmp_state"
            echo "status: failed" >>"$tmp_state"
            echo "reason: extract-failed-inline" >>"$tmp_state"
            mv "$tmp_state" "$per_pkg_state"
            release_pkg_lock
            return 1
          fi
        else
          log_warn "Fonte inline não encontrada: $src_file"
        fi
      fi
    fi
  done

  # apply patches (if any)
  if [[ "${#applied_patches[@]}" -gt 0 ]]; then
    log_info "Aplicando ${#applied_patches[@]} patches para $pkg"
    if ! apply_patches "$pkg" "$dest_base" "${applied_patches[@]}"; then
      log_error "Falha aplicando patches para $pkg"
      _safe_remove_dir "$dest_base"
      echo "package: \"$pkg\"" >"$tmp_state"
      echo "status: failed" >>"$tmp_state"
      echo "reason: patch-failed" >>"$tmp_state"
      mv "$tmp_state" "$per_pkg_state"
      release_pkg_lock
      return 1
    fi
  fi

  # run post_patch hook if present
  local post_patch_hook
  post_patch_hook=$(yq eval -r ".packages[] | select(.name == \"$pkg\") | .hooks.post_patch // \"\"" "$metafile" 2>/dev/null || true)
  if [[ -n "$post_patch_hook" && "$post_patch_hook" != "null" ]]; then
    if ! run_hook "$post_patch_hook" "$pkg" "$SOURCES_DIR/$pkg" "$dest_base"; then
      log_warn "post_patch hook falhou para $pkg (continua)"
    fi
  fi

  # run post_extract hook
  local post_hook
  post_hook=$(yq eval -r ".packages[] | select(.name == \"$pkg\") | .hooks.post_extract // \"\"" "$metafile" 2>/dev/null || true)
  if [[ -n "$post_hook" && "$post_hook" != "null" ]]; then
    if ! run_hook "$post_hook" "$pkg" "$SOURCES_DIR/$pkg" "$dest_base"; then
      log_warn "post_extract hook falhou para $pkg (continua)"
    fi
  fi

  # finalize state
  echo "package: \"$pkg\"" >>"$tmp_state"
  if [[ "$extracted_any" == true ]]; then
    echo "status: ok" >>"$tmp_state"
    echo "dest: \"$dest_base\"" >>"$tmp_state"
  else
    echo "status: skipped" >>"$tmp_state"
    echo "reason: no-sources-found" >>"$tmp_state"
  fi
  echo "timestamp: \"$(date --iso-8601=seconds)\"" >>"$tmp_state"

  mv "$tmp_state" "$per_pkg_state" || log_warn "Não foi possível mover estado temporário para $per_pkg_state"

  release_pkg_lock
  log_ok "Extração finalizada para $pkg"
  return 0
}

# ---------------------------
# Job runner with limited concurrency
# ---------------------------
run_jobs() {
  local -n arr=$1
  local pids=()
  for pkg in "${arr[@]}"; do
    # wait for free slot
    while (( $(jobs -rp | wc -l) >= CONCURRENCY )); do sleep 0.5; done
    process_package "$pkg" &
    pids+=("$!")
  done
  local rc=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then rc=1; fi
  done
  return $rc
}

# ---------------------------
# List packages helper (reads metafiles)
# ---------------------------
list_all_packages() {
  local files
  files=($(find "$METAFILES_DIR" -type f -name '*.yml' -o -name '*.yaml' 2>/dev/null))
  local out=()
  for f in "${files[@]}"; do
    mapfile -t names < <(yq eval '.packages[]?.name' "$f" 2>/dev/null || true)
    for n in "${names[@]}"; do out+=("$n"); done
  done
  # dedupe
  printf "%s\n" "$(printf "%s\n" "${out[@]}" | awk '!x[$0]++')"
}

# ---------------------------
# Merge per-package extract state to GLOBAL_EXTRACT_STATE
# ---------------------------
merge_extract_states() {
  local out="${GLOBAL_EXTRACT_STATE}"
  echo "extract:" >"${out}.tmp"
  for f in "$EXTRACT_STATE_DIR"/*.yml; do
    [[ -f "$f" ]] || continue
    local pkg; pkg="$(basename "$f" .yml)"
    echo "  $pkg:" >>"${out}.tmp"
    sed -e 's/^/    /' "$f" >>"${out}.tmp"
  done
  mv "${out}.tmp" "$out"
  log_info "Estado global de extração gravado em $out"
}

# ---------------------------
# main_extract: entrypoint
# ---------------------------
main_extract() {
  log_info "==== Iniciando 02-extract (concurrency=${CONCURRENCY}) ===="

  # optionally load config.env if present
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    set -a
    source "$CONFIG_FILE"
    set +a
  fi

  # build package list
  mapfile -t pkg_list < <(list_all_packages)
  if [[ "${#pkg_list[@]}" -eq 0 ]]; then
    log_warn "Nenhum pacote definido nos metafiles em $METAFILES_DIR"
    return 0
  fi
  log_info "Pacotes para extrair: ${#pkg_list[@]}"

  run_jobs pkg_list || log_warn "Algumas extrações falharam (ver estados por pacote em $EXTRACT_STATE_DIR)"

  merge_extract_states

  # summary
  local total succeeded failed skipped
  total=${#pkg_list[@]}
  succeeded=$(grep -c "status: ok" "$EXTRACT_STATE_DIR"/*.yml 2>/dev/null || true)
  failed=$(grep -c "status: failed" "$EXTRACT_STATE_DIR"/*.yml 2>/dev/null || true)
  skipped=$(grep -c "status: skipped" "$EXTRACT_STATE_DIR"/*.yml 2>/dev/null || true)

  log_info "Extract summary: total=$total ok=$succeeded failed=$failed skipped=$skipped"

  if (( failed > 0 )); then
    log_error "Existem pacotes com falha na extração. Verifique $EXTRACT_STATE_DIR para detalhes."
    return 1
  fi

  log_ok "02-extract concluído com sucesso."
  return 0
}

# ---------------------------
# Execute if run directly
# ---------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_extract "$@"
fi
