#!/usr/bin/env bash
# ===================================================================
# Download robusto de fontes (HTTP/FTP) e repositórios Git
# Recursos: locks por pacote/fonte, retry com backoff, checksum verify
# Requisitos: bash, wget (ou curl), git, yq, sha256sum, flock, timeout
# ===================================================================
set -Eeuo pipefail
IFS=$'\n\t'
# ---------------------------
# Paths (padrões, sobrescritos por config.env)
# ---------------------------
LFS_BUILDER_ROOT="${LFS_BUILDER_ROOT:-/opt/lfs-builder}"
LOGDIR="${LOGDIR:-$LFS_BUILDER_ROOT/logs}"
STATEDIR="${STATEDIR:-$LFS_BUILDER_ROOT/state}"
LOCKDIR="${LOCKDIR:-$STATEDIR/locks}"
SOURCES_DIR="${SOURCES_DIR:-$LFS_BUILDER_ROOT/sources}"
METAFILES_DIR="${METAFILES_DIR:-$LFS_BUILDER_ROOT/metafiles}"
FETCH_STATE_FILE="${FETCH_STATE_FILE:-$STATEDIR/fetch.yml}"
CONFIG_FILE="${CONFIG_FILE:-$LFS_BUILDER_ROOT/config.env}"
CONCURRENCY="${CONCURRENCY:-$(nproc)}"
VERBOSITY="${VERBOSITY:-1}"
# ---------------------------
# Inicialização mínima de diretórios
# ---------------------------
mkdir -p "$LOGDIR" "$STATEDIR" "$LOCKDIR" "$SOURCES_DIR" "$METAFILES_DIR"
# ---------------------------
# Cores
# ---------------------------
_init_colors() {
  RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'; BLUE=$'\e[1;34m'; CYAN=$'\e[1;36m'; RESET=$'\e[0m'
}
_init_colors
# ---------------------------
# Logging thread-safe via flock (usando FD 9)
# ---------------------------
_log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date +"%F %T")
  local prefix color
  case "$level" in
    INFO) prefix="[INFO]"; color="$BLUE" ;;
    WARN) prefix="[WARN]"; color="$YELLOW" ;;
    ERROR) prefix="[ERRO]"; color="$RED" ;;
    OK) prefix="[ OK ]"; color="$GREEN" ;;
    DEBUG) prefix="[DBG]"; color="$CYAN" ;;
    *) prefix="[LOG]"; color="$RESET" ;;
  esac
  # write to stdout (colored) and append to logfile atomically
  {
    flock 9
    printf "%s%s%s %s %s\n" "$color" "$prefix" "$RESET" "$ts" "$msg" | tee -a "$LOGFILE" >/dev/null
  } 9>>"$LOGFILE"
}

log_info()  { _log INFO "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }
log_ok()    { _log OK "$@"; }
log_dbg()   { [ "${VERBOSITY:-1}" -ge 2 ] && _log DEBUG "$@"; }
# ---------------------------
# Error handling
# ---------------------------
handle_error() {
  local code=$? line=${1:-'N/A'} cmd="${BASH_COMMAND:-N/A}"
  log_error "Erro (code=${code}) linha=${line} cmd='${cmd}'"
  # no rollback aqui; caller decides per-operation rollback
}
trap 'handle_error ${LINENO}' ERR
# ---------------------------
# Retry wrapper (exponential backoff)
# Usage: retry <max_tries> <cmd...>
# ---------------------------
retry() {
  local max="${1:-3}"; shift
  local attempt=1
  local delay=5
  until "$@"; do
    local rc=$?
    if (( attempt >= max )); then
      log_error "Comando falhou após ${attempt} tentativas: $* (rc=${rc})"
      return $rc
    fi
    log_warn "Tentativa ${attempt} falhou para: $* — aguardando ${delay}s antes da próxima..."
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
  return 0
}
# ---------------------------
# Acquire per-package lock
# Creates: $LOCKDIR/fetch-<pkg>.lock and returns FD in var LOCK_FD
# Usage: acquire_pkg_lock "gcc"
#        release_pkg_lock
# ---------------------------
LOCK_FD=0
PKG_LOCK_PATH=""
acquire_pkg_lock() {
  local pkg="$1"
  PKG_LOCK_PATH="$LOCKDIR/fetch-${pkg}.lock"
  mkdir -p "$(dirname "$PKG_LOCK_PATH")"
  exec {LOCK_FD}>"$PKG_LOCK_PATH"
  if ! flock -n "$LOCK_FD"; then
    log_warn "Outro processo está trabalhando no pacote '$pkg' (lock: $PKG_LOCK_PATH)"
    return 1
  fi
  # annotate lock
  printf "%s\n" "$$ $(date +%s)" >&"${LOCK_FD}"
  return 0
}
release_pkg_lock() {
  if [[ -n "${LOCK_FD:-}" && "${LOCK_FD}" -ne 0 ]]; then
    flock -u "$LOCK_FD" || true
    eval "exec ${LOCK_FD}>&-"
    LOCK_FD=0
  fi
}
# ---------------------------
# Verify checksum (supports sha256 and md5)
# Arguments: <file> <sha256|md5 value or empty>
# Returns 0 if ok, 1 otherwise
# ---------------------------
verify_checksum() {
  local file="$1" sum="$2"
  if [[ -z "$sum" || ! -f "$file" ]]; then
    return 1
  fi
  # assume sha256 if length >= 64, md5 if length == 32
  if [[ ${#sum} -ge 64 ]]; then
    echo "${sum}  ${file}" | sha256sum -c - &>/dev/null
    return $?
  elif [[ ${#sum} -eq 32 ]]; then
    echo "${sum}  ${file}" | md5sum -c - &>/dev/null
    return $?
  else
    # unknown; fail safe
    log_warn "Checksum de formato desconhecido para $file: $sum"
    return 1
  fi
}
# ---------------------------
# Helpers: filename from url
# ---------------------------
filename_from_url() {
  local url="$1"
  # strip query params
  local path="${url%%\?*}"
  echo "${path##*/}"
}
# ---------------------------
# download_url: baixa um URL HTTP/FTP para destino (com retries)
# Arguments: <url> <dest_dir> <expected_sum_or_empty> <mirror_list_comma_separated_or_empty>
# ---------------------------
download_url() {
  local url="$1"; local dest_dir="$2"; local expected_sum="${3:-}"; local mirrors="${4:-}"
  mkdir -p "$dest_dir"
  local fname
  fname="$(filename_from_url "$url")"
  local dest="$dest_dir/$fname"
  # if exists and checksum ok, skip
  if [[ -f "$dest" && -n "$expected_sum" ]]; then
    if verify_checksum "$dest" "$expected_sum"; then
      log_ok "Fonte já presente e checksum OK: $dest"
      return 0
    else
      log_warn "Arquivo existente com checksum inválido; removendo: $dest"
      rm -f "$dest"
    fi
  elif [[ -f "$dest" && -z "$expected_sum" ]]; then
    log_ok "Arquivo já presente (sem checksum definido): $dest"
    return 0
  fi
  # attempt primary URL then mirrors
  local tried=0
  local url_list=("$url")
  IFS=',' read -r -a extra_mirrors <<< "$mirrors"
  for m in "${extra_mirrors[@]}"; do
    [[ -n "$m" ]] && url_list+=("$m")
  done

  for candidate in "${url_list[@]}"; do
    tried=$((tried+1))
    log_info "Baixando (tentar $tried/${#url_list[@]}): $candidate -> $dest"
    # prefer wget; fallback curl
    if command -v wget >/dev/null 2>&1; then
      retry 3 wget -c --retry-connrefused --timeout=20 --tries=3 -O "$dest" "$candidate" || {
        log_warn "wget falhou para $candidate"
        rm -f "$dest" || true
        continue
      }
    elif command -v curl >/dev/null 2>&1; then
      retry 3 curl -fL --retry 3 -o "$dest" "$candidate" || {
        log_warn "curl falhou para $candidate"
        rm -f "$dest" || true
        continue
      }
    else
      log_error "Nem wget nem curl disponíveis"
      return 2
    fi
    # verify if expected_sum provided
    if [[ -n "$expected_sum" ]]; then
      if verify_checksum "$dest" "$expected_sum"; then
        log_ok "Checksum verificado: $dest"
        return 0
      else
        log_warn "Checksum inválido para $dest; removendo e tentando próximo mirror..."
        mv "$dest" "${dest}.corrupted.$(date +%s)" 2>/dev/null || rm -f "$dest" || true
        continue
      fi
    else
      log_ok "Baixado (sem checksum): $dest"
      return 0
    fi
  done

  log_error "Falha ao baixar $url (todas as mirrors falharam)"
  return 1
}
# ---------------------------
# fetch_git: clone/update um repositório Git
# Arguments: <git_url> <dest_dir> <branch_or_ref or empty> <depth or empty> <submodules true|false>
# On success writes commit hash to stdout
# ---------------------------
fetch_git() {
  local repo="$1"; local dest_dir="$2"; local ref="${3:-}"; local depth="${4:-}"; local submodules="${5:-false}"

  mkdir -p "$dest_dir"
  if [[ -d "$dest_dir/.git" ]]; then
    # existing repo: fetch & attempt update
    log_info "Repositório já existe, atualizando em $dest_dir"
    pushd "$dest_dir" >/dev/null
    # fetch all
    retry 3 git remote update --prune --quiet || {
      log_warn "git remote update falhou em $dest_dir; tentando git fetch origin"
      git fetch --all --tags --prune --quiet || true
    }
    # checkout desired ref if provided
    if [[ -n "$ref" ]]; then
      # try to checkout branch/ref
      if ! git rev-parse --verify "$ref" >/dev/null 2>&1; then
        # try fetch remote branches
        git fetch --all --tags --prune --quiet || true
      fi
      git checkout --force "$ref" >/dev/null 2>&1 || {
        log_warn "Não foi possível checkout para $ref em $dest_dir; tentando reset hard origin/$ref"
        git fetch --all --quiet || true
        git reset --hard "origin/$ref" >/dev/null 2>&1 || true
      }
    else
      # checkout default branch
      git checkout --force "$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's@origin/@@')" >/dev/null 2>&1 || true
    fi
    # pull latest
    git pull --ff-only --quiet || true
    if [[ "$submodules" == "true" ]]; then
      git submodule update --init --recursive --quiet || true
    fi
    local commit
    commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    popd >/dev/null
    log_ok "Repositório atualizado: $repo @ $commit"
    printf "%s" "$commit"
    return 0
  else
    # fresh clone
    log_info "Clonando repositório $repo para $dest_dir (depth=${depth:-full})"
    if [[ -n "$depth" && "$depth" -gt 0 ]]; then
      retry 3 git clone --branch "${ref:-}" --depth "$depth" --quiet "$repo" "$dest_dir" || {
        log_error "git clone falhou para $repo"
        rm -rf "$dest_dir" || true
        return 1
      }
    else
      retry 3 git clone --quiet "$repo" "$dest_dir" || {
        log_error "git clone falhou para $repo"
        rm -rf "$dest_dir" || true
        return 1
      }
      if [[ -n "$ref" ]]; then
        pushd "$dest_dir" >/dev/null
        git checkout --force "$ref" >/dev/null 2>&1 || true
        popd >/dev/null
      fi
    fi
    if [[ "$submodules" == "true" ]]; then
      pushd "$dest_dir" >/dev/null
      git submodule update --init --recursive --quiet || true
      popd >/dev/null
    fi
    local commit
    commit=$(git -C "$dest_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    log_ok "Clone concluído: $repo @ $commit"
    printf "%s" "$commit"
    return 0
  fi
}
# ---------------------------
# process_source_entry: processa um item sources[] do YAML
# Arguments: <pkg> <entry_yaml_path> (yaml path is used by yq in caller to extract fields)
# Expected to be called by higher-level YAML parser in part 2
# ---------------------------
process_source_entry() {
  local pkg="$1"
  local entry_type="$2"   # "url" or "git" or "patch" etc.
  shift 2
  # args: associative-like list of key=val pairs
  # but to keep compatibility we'll accept:
  #   url dest_dir expected_sum mirrors
  #   git repo dest_dir ref depth submodules
  if [[ "$entry_type" == "url" || "$entry_type" == "patch" || "$entry_type" == "extra" ]]; then
    local url="$1"; local dest_subdir="${2:-$pkg}"; local expected_sum="${3:-}"; local mirrors="${4:-}"
    local dest_dir="$SOURCES_DIR/$dest_subdir"
    if download_url "$url" "$dest_dir" "$expected_sum" "$mirrors"; then
      log_ok "Fonte processada para $pkg : $(filename_from_url "$url")"
      return 0
    else
      log_error "Falha ao processar fonte URL para $pkg : $url"
      return 1
    fi
  elif [[ "$entry_type" == "git" ]]; then
    local repo="$1"; local dest_subdir="${2:-$pkg}"; local ref="${3:-}"; local depth="${4:-}"; local submodules="${5:-false}"
    local dest_dir="$SOURCES_DIR/$dest_subdir"
    local commit
    if commit=$(fetch_git "$repo" "$dest_dir" "$ref" "$depth" "$submodules"); then
      log_ok "Repo processado para $pkg : $repo @ $commit"
      return 0
    else
      log_error "Falha ao processar repo git para $pkg : $repo"
      return 1
    fi
  else
    log_warn "Tipo de fonte desconhecido para $pkg: $entry_type"
    return 2
  fi
}
# ---------------------------
# small helper: safe rm partial artifacts
# ---------------------------
_safe_remove_partial() {
  local path="$1"
  if [[ -e "$path" ]]; then
    mkdir -p "$SOURCES_DIR/.corrupted"
    mv "$path" "$SOURCES_DIR/.corrupted/$(basename "$path").$(date +%s)" 2>/dev/null || rm -rf "$path" || true
    log_warn "Artefato parcial movido/removido: $path"
  fi
}
# ---------------------------
# CLI parsing (simple)
# ---------------------------
FETCH_MODE="all"   # all or single pkg
FORCE_UPDATE=false
GIT_UPDATE=false
REMOVE_CACHE=false
declare -a ARGS_PKGS=()

while (( "$#" )); do
  case "$1" in
    --all) FETCH_MODE="all"; shift ;;
    --update) FORCE_UPDATE=true; shift ;;
    --git-update) GIT_UPDATE=true; shift ;;
    --remove-cache) REMOVE_CACHE=true; shift ;;
    --jobs|-j) CONCURRENCY="${2:-$CONCURRENCY}"; shift 2 ;;
    --pkg) ARGS_PKGS+=("${2:-}"); shift 2 ;;
    --help|-h) echo "Usage: fetch.sh [--all|--pkg <name>] [--update] [--git-update] [--remove-cache] [--jobs N]"; exit 0 ;;
    *) ARGS_PKGS+=("$1"); shift ;;
  esac
done
# ---------------------------
# sanity: ensure yq exists
# ---------------------------
if ! command -v yq >/dev/null 2>&1; then
  log_error "yq (v4+) não encontrado. Instale yq para parsing YAML."
  exit 2
fi
# ---------------------------
# Helper: list all packages from metafiles
# ---------------------------
list_all_packages() {
  # find all YAML metafiles and extract .packages[].name
  local files
  files=($(find "$PKG_METAFILES_DIR" -type f -name '*.yml' -o -name '*.yaml' 2>/dev/null))
  local out=()
  for f in "${files[@]}"; do
    # safe: skip if empty
    if [[ ! -s "$f" ]]; then continue; fi
    mapfile -t names < <(yq eval '.packages[]?.name' "$f" 2>/dev/null || true)
    for n in "${names[@]}"; do out+=("$n:$f"); done
  done
  # prints lines "pkg:metafile"
  printf "%s\n" "${out[@]}"
}
# ---------------------------
# Helper: find metafile and package node for a given package name
# returns: metafile path (stdout) and sets PACKAGE_INDEX variable (not strictly needed)
# ---------------------------
find_metafile_for_pkg() {
  local pkg="$1"
  # search files
  local files
  files=($(find "$PKG_METAFILES_DIR" -type f -name '*.yml' -o -name '*.yaml' 2>/dev/null))
  for f in "${files[@]}"; do
    if yq eval ".packages[] | select(.name == \"$pkg\") | .name" "$f" >/dev/null 2>&1; then
      printf "%s" "$f"
      return 0
    fi
  done
  return 1
}
# ---------------------------
# process_package: main worker for one package
# Writes state to $PER_PKG_STATE_DIR/<pkg>.yml
# ---------------------------
process_package() {
  local pkg="$1"
  local metafile
  local pkg_state_file="$PER_PKG_STATE_DIR/${pkg}.yml"
  local tmp_state="${pkg_state_file}.tmp"
  : >"$tmp_state"

  log_info "Iniciando fetch para pacote: $pkg"
  # find metafile and package node
  if ! metafile=$(find_metafile_for_pkg "$pkg"); then
    log_error "Metafile não encontrado para pacote: $pkg"
    printf "status: failed\nreason: metafile-not-found\n" >"$tmp_state"
    mv "$tmp_state" "$pkg_state_file"
    return 1
  fi
  # Acquire per-package lock (non-blocking)
  if ! acquire_pkg_lock "$pkg"; then
    log_warn "Não foi possível adquirir lock para $pkg — pulando."
    printf "status: skipped\nreason: locked\n" >"$tmp_state"
    mv "$tmp_state" "$pkg_state_file"
    return 2
  fi

  local pkg_status="success"
  local pkg_msg="ok"
  local -a source_count
  local timestamp
  timestamp="$(date --iso-8601=seconds)"
  # iterate over sources[] entries (supports url, git, patch, extra)
  # We'll index entries and for each extract fields using yq
  # get number of entries
  local n
  n=$(yq eval "(.packages[] | select(.name == \"$pkg\") | .sources) | length" "$metafile" 2>/dev/null || echo 0)
  if [[ "$n" == "0" ]]; then
    log_warn "Nenhuma fonte definida para $pkg no $metafile"
  fi
  # process each source entry
  for idx in $(seq 0 $((n-1))); do
    # determine entry type
    local entry_type
    entry_type=$(yq eval ".packages[] | select(.name == \"$pkg\") | .sources[$idx] | keys | .[0]" "$metafile" 2>/dev/null || true)
    # yq returns key names like "url" or "git" or "patch" depending on structure
    # handle url case where entry is a mapping with url+sha256 etc
    if [[ "$entry_type" == "null" || -z "$entry_type" ]]; then
      # It might be that the entry is directly an url string
      entry_type="url"
      local url
      url=$(yq eval ".packages[] | select(.name == \"$pkg\") | .sources[$idx]" "$metafile" 2>/dev/null || true)
      # normalize: we will treat it as url with no checksum
      if ! process_and_record_url "$pkg" "$url" "" ""; then
        pkg_status="failed"
        pkg_msg="one or more sources failed"
      fi
      continue
    fi

    case "$entry_type" in
      url|patch|extra)
        {
          local url expected_sum mirrors
          url=$(yq eval -r ".packages[] | select(.name == \"$pkg\") | .sources[$idx].url // .sources[$idx]" "$metafile")
          expected_sum=$(yq eval -r ".packages[] | select(.name == \"$pkg\") | .sources[$idx].sha256 // \"\"" "$metafile")
          mirrors=$(yq eval -r ".packages[] | select(.name == \"$pkg\") | .sources[$idx].mirrors // \"\"" "$metafile")
          if [[ "$url" == "null" || -z "$url" ]]; then
            log_warn "Entry vazio encontrado para $pkg index $idx"
            continue
          fi
          if ! process_and_record_url "$pkg" "$url" "$expected_sum" "$mirrors"; then
            pkg_status="failed"
            pkg_msg="source failed"
          fi
        }
        ;;
      git)
        {
          local repo ref depth submodules
          repo=$(yq eval -r ".packages[] | select(.name == \"$pkg\") | .sources[$idx].git" "$metafile")
          ref=$(yq eval -r ".packages[] | select(.name == \"$pkg\") | .sources[$idx].ref // \"\"" "$metafile")
          depth=$(yq eval -r ".packages[] | select(.name == \"$pkg\") | .sources[$idx].depth // \"\"" "$metafile")
          submodules=$(yq eval -r ".packages[] | select(.name == \"$pkg\") | .sources[$idx].submodules // false" "$metafile")
          if [[ "$repo" == "null" || -z "$repo" ]]; then
            log_warn "Git entry vazio para $pkg index $idx"
            continue
          fi
          # dest subdir defaults to package name plus repo basename
          local repo_basename
          repo_basename="$(basename "${repo%%.git}")"
          local dest_subdir="${pkg}/${repo_basename}"
          local dest_dir="$SOURCES_DIR/$dest_subdir"
          if [[ "$GIT_UPDATE" == "true" ]]; then
            log_info "Forçando atualização git para $pkg : $repo"
          fi
          if ! commit=$(fetch_git "$repo" "$dest_dir" "$ref" "$depth" "$submodules"); then
            log_error "Git fetch failed for $pkg repo $repo"
            pkg_status="failed"
            pkg_msg="git failed"
          else
            # write per-source entry to temp state
            {
              echo "- type: git"
              echo "  repo: \"$repo\""
              echo "  dest: \"$dest_dir\""
              echo "  commit: \"$commit\""
              echo "  updated: true"
            } >>"$tmp_state.sources.tmp"
          fi
        }
        ;;
      *)
        log_warn "Tipo desconhecido ($entry_type) para $pkg index $idx — pulando"
        ;;
    esac
  done
  # post processing: merge tmp source entries into final pkg state YAML
  {
    echo "package: \"$pkg\""
    echo "metafile: \"$metafile\""
    echo "timestamp: \"$timestamp\""
    echo "status: \"$pkg_status\""
    echo "message: \"$pkg_msg\""
    echo "sources:"
    if [[ -f "$tmp_state.sources.tmp" ]]; then
      sed 's/^/  /' "$tmp_state.sources.tmp"
      rm -f "$tmp_state.sources.tmp"
    fi
  } >>"$tmp_state"

  mv "$tmp_state" "$pkg_state_file" || {
    log_warn "Não foi possível escrever estado para $pkg em $pkg_state_file"
  }
  # release lock
  release_pkg_lock

  if [[ "$pkg_status" == "success" ]]; then
    log_ok "Fetch completo para $pkg"
    return 0
  else
    log_error "Fetch apresentou erros para $pkg (status=${pkg_status})"
    return 1
  fi
}
# ---------------------------
# process_and_record_url: wrapper that downloads a URL and appends to tmp state
# ---------------------------
process_and_record_url() {
  local pkg="$1"; local url="$2"; local expected_sum="$3"; local mirrors="$4"
  local fname
  fname="$(filename_from_url "$url")"
  local dest_subdir="${pkg}"
  local dest_dir="$SOURCES_DIR/$dest_subdir"
  if download_url "$url" "$dest_dir" "$expected_sum" "$mirrors"; then
    # record to tmp file for this package
    {
      echo "- type: url"
      echo "  file: \"$dest_dir/$fname\""
      echo "  source: \"$url\""
      if [[ -n "$expected_sum" && "$expected_sum" != "null" ]]; then
        echo "  sha256: \"$expected_sum\""
        echo "  verified: true"
      else
        echo "  verified: unknown"
      fi
    } >>"$tmp_state.sources.tmp"
    return 0
  else
    log_error "download_url falhou para $pkg -> $url"
    _safe_remove_partial "$dest_dir/$fname"
    return 1
  fi
}
# ---------------------------
# orchestrator: run jobs with limited concurrency
# ---------------------------
run_jobs() {
  local -n jobs_ref=$1  # array of package names
  local running=0
  local pids=()
  local index=0
  local total=${#jobs_ref[@]}

  for pkg in "${jobs_ref[@]}"; do
    while true; do
      # count running background jobs
      running=$(jobs -rp | wc -l)
      if (( running < CONCURRENCY )); then
        log_info "Iniciando worker para pacote: $pkg (jobs_running=$running)"
        process_package "$pkg" &
        pids+=("$!")
        break
      else
        sleep 0.5
      fi
    done
  done
  # wait for all pids
  local rc=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then rc=1; fi
  done
  return $rc
}
# ---------------------------
# build global package list according to CLI args
# ---------------------------
build_target_package_list() {
  local list=()
  if [[ "${#ARGS_PKGS[@]}" -gt 0 ]]; then
    for p in "${ARGS_PKGS[@]}"; do list+=("$p";); done
  elif [[ "$FETCH_MODE" == "all" ]]; then
    # parse metafiles
    mapfile -t entries < <(list_all_packages)
    # entries like "pkg:/path/to/file"
    for e in "${entries[@]}"; do
      pkg="${e%%:*}"
      list+=("$pkg")
    done
  fi
  # dedupe while preserving order
  local seen=()
  local out=()
  for p in "${list[@]}"; do
    if [[ -z "${seen[$p]:-}" ]]; then
      seen[$p]=1
      out+=("$p")
    fi
  done
  printf "%s\n" "${out[@]}"
}
# ---------------------------
# merge per-package state files into GLOBAL_FETCH_STATE
# ---------------------------
merge_states() {
  local out="$GLOBAL_FETCH_STATE"
  echo "fetch:" > "$out.tmp"
  for f in "$PER_PKG_STATE_DIR"/*.yml; do
    [[ -f "$f" ]] || continue
    local pkg
    pkg="$(basename "$f" .yml)"
    echo "  $pkg:" >>"$out.tmp"
    # indent file contents by two spaces, but skip top-level 'package:' and 'metafile:' duplicates
    sed -e 's/^/    /' "$f" >> "$out.tmp"
  done
  mv "$out.tmp" "$out"
  log_info "Estado global gravado em $out"
}
# ---------------------------
# main_fetch: entrypoint
# ---------------------------
main_fetch() {
  log_info "==== Iniciando 01-fetch (concurrency=${CONCURRENCY}) ===="
  # build package list
  mapfile -t pkg_list < <(build_target_package_list)
  if [[ "${#pkg_list[@]}" -eq 0 ]]; then
    log_warn "Nenhum pacote alvo encontrado para fetch."
    return 0
  fi
  log_info "Pacotes a processar: ${#pkg_list[@]}"
  # optional: if REMOVE_CACHE true -> remove sources dir (with prompt)
  if [[ "$REMOVE_CACHE" == "true" ]]; then
    log_warn "REMOVE_CACHE ativo: removendo diretório $SOURCES_DIR (será recriado)"
    rm -rf "$SOURCES_DIR"
    mkdir -p "$SOURCES_DIR"
  fi
  # run jobs
  if ! run_jobs pkg_list; then
    log_warn "Alguns fetches falharam; ver logs por pacote em $PER_PKG_STATE_DIR e $LOGDIR"
  fi
  # merge states
  merge_states
  # generate summary
  local total succeeded failed skipped
  total=${#pkg_list[@]}
  succeeded=$(grep -c "status: success" "$PER_PKG_STATE_DIR"/*.yml 2>/dev/null || true)
  failed=$(grep -c "status: failed" "$PER_PKG_STATE_DIR"/*.yml 2>/dev/null || true)
  skipped=$(grep -c "status: skipped" "$PER_PKG_STATE_DIR"/*.yml 2>/dev/null || true)

  log_info "Fetch summary: total=$total succeeded=$succeeded failed=$failed skipped=$skipped"
  if (( failed > 0 )); then
    log_error "Existem pacotes com falhas. Consulte $PER_PKG_STATE_DIR para detalhes."
    return 1
  fi

  log_ok "01-fetch concluído com sucesso."
  return 0
}
# ---------------------------
# If invoked directly, run main_fetch
# ---------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_fetch "$@"
fi
