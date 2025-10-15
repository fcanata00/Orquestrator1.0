#!/usr/bin/env bash
# ============================================================
#  Módulo 00-init.sh — Inicialização segura do ambiente LFS
# ============================================================
set -Eeuo pipefail
# ------------------------------------------------------------
#  Variáveis principais
# ------------------------------------------------------------
LFS_BUILDER_ROOT="/opt/lfs-builder"
LOGDIR="$LFS_BUILDER_ROOT/logs"
STATEDIR="$LFS_BUILDER_ROOT/state"
LOCKDIR="$STATEDIR/locks"
LOGFILE="$LOGDIR/init-$(date +'%F_%H-%M-%S').log"
SESSION_FILE="$STATEDIR/session.yml"
LOCKFILE="$LOCKDIR/init.lock"
CONFIG_FILE="$LFS_BUILDER_ROOT/config.env"
# ------------------------------------------------------------
#  Cores e formatação
# ------------------------------------------------------------
init_colors() {
  RED="\033[1;31m"
  GREEN="\033[1;32m"
  YELLOW="\033[1;33m"
  BLUE="\033[1;34m"
  RESET="\033[0m"
}
# ------------------------------------------------------------
#  Logging thread-safe com flock
# ------------------------------------------------------------
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date +"%F %T")

  local color prefix
  case "$level" in
    INFO)  color="$BLUE";   prefix="[INFO]" ;;
    WARN)  color="$YELLOW"; prefix="[WARN]" ;;
    ERROR) color="$RED";    prefix="[ERRO]" ;;
    OK)    color="$GREEN";  prefix="[ OK ]" ;;
    *)     color="$RESET";  prefix="[LOG]"  ;;
  esac

  (
    flock 9
    printf "%b%s%b %s\n" "$color" "$prefix" "$RESET" "$msg" | tee -a "$LOGFILE" >/dev/null
  ) 9>>"$LOGFILE"
}

info()    { log INFO  "$*"; }
warn()    { log WARN  "$*"; }
error()   { log ERROR "$*"; }
success() { log OK    "$*"; }
# ------------------------------------------------------------
#  Tratamento de erros centralizado
# ------------------------------------------------------------
error_handler() {
  local exit_code=$?
  local cmd="${BASH_COMMAND:-N/A}"
  local ts=$(date +"%F %T")

  echo -e "\n${RED}[ERRO FATAL]${RESET} $ts :: código $exit_code ao executar: $cmd" >&2
  {
    echo "[$ts] ERRO ($exit_code): $cmd"
    echo "[$ts] Diretório atual: $(pwd)"
    echo "[$ts] Usuário: $(whoami)"
    echo "[$ts] Encerrando módulo init..."
  } >>"$LOGFILE"

  update_session "failed"
  release_lock
  exit "$exit_code"
}
trap 'error_handler' ERR
# ------------------------------------------------------------
#  Lockfile — evita execução concorrente
# ------------------------------------------------------------
acquire_lock() {
  mkdir -p "$LOCKDIR"
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    echo -e "${RED}[LOCK]${RESET} Outro processo init está em execução."
    exit 1
  fi
}
release_lock() {
  flock -u 9 || true
  rm -f "$LOCKFILE" 2>/dev/null || true
}
# ------------------------------------------------------------
#  Configuração e variáveis
# ------------------------------------------------------------
load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    error "Arquivo de configuração não encontrado em $CONFIG_FILE"
    return 1
  fi
  set -a
  source "$CONFIG_FILE"
  set +a
  info "Configuração carregada de $CONFIG_FILE"
}
# ------------------------------------------------------------
#  Estrutura de diretórios
# ------------------------------------------------------------
prepare_directories() {
  for d in "$LOGDIR" "$STATEDIR" "$LOCKDIR" "$LFS" "$BUILDROOT" "$DESTDIR"; do
    mkdir -p "$d"
  done
  info "Diretórios base criados com sucesso."
}
# ------------------------------------------------------------
#  Dependências obrigatórias
# ------------------------------------------------------------
check_dependencies() {
  local deps=(bash yq wget tar gzip bzip2 xz fakeroot patch flock)
  local missing=()

  for dep in "${deps[@]}"; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
  done

  if ((${#missing[@]})); then
    error "Dependências ausentes: ${missing[*]}"
    return 1
  fi
  info "Todas as dependências obrigatórias estão presentes."
}
# ------------------------------------------------------------
#  Permissões e ambiente
# ------------------------------------------------------------
validate_permissions() {
  if [[ "$(id -u)" -eq 0 ]]; then
    warn "Executando como root — recomenda-se usar o usuário 'lfs'."
  fi
  if [[ -z "${LFS:-}" ]]; then
    error "Variável LFS não definida. Verifique config.env."
  fi
}
# ------------------------------------------------------------
#  Detecção de ambiente (chroot ou host)
# ------------------------------------------------------------
detect_environment() {
  if [[ -f /.dockerenv || -d /proc/1/root ]]; then
    info "Detectado ambiente possível de chroot ou container."
  fi
  if [[ -e /etc/lfs-release ]]; then
    info "Ambiente LFS já inicializado previamente."
  fi
}
# ------------------------------------------------------------
#  Registro da sessão
# ------------------------------------------------------------
register_session() {
  local session_id="init-$(date +'%F_%H-%M-%S')"
  mkdir -p "$(dirname "$SESSION_FILE")"

  cat >"$SESSION_FILE" <<YAML
session:
  id: "$session_id"
  start: "$(date +'%F %T')"
  user: "$(whoami)"
  host: "$(hostname)"
  mode: "init"
  status: "in-progress"
YAML

  info "Sessão registrada em $SESSION_FILE"
}

update_session() {
  local status="$1"
  sed -i "s/status:.*/status: \"$status\"/" "$SESSION_FILE" 2>/dev/null || true
  if [[ "$status" == "success" ]]; then
    echo "  end: \"$(date +'%F %T')\"" >>"$SESSION_FILE"
  fi
}
# ------------------------------------------------------------
#  Exporta variáveis globais a partir do config.env (com defaults)
# ------------------------------------------------------------
export_env() {
  # valores que o config.env pode fornecer; se não, aplicamos defaults seguros
  LFS="${LFS:-/mnt/lfs}"
  LFS_TGT="${LFS_TGT:-x86_64-lfs-linux-gnu}"
  MAKEFLAGS="${MAKEFLAGS:--j$(nproc)}"
  BUILDROOT="${BUILDROOT:-${LFS}/build}"
  DESTDIR="${DESTDIR:-${LFS}/destdir}"
  CHROOT_SHELL="${CHROOT_SHELL:-/bin/bash}"

  # Paths do builder
  LFS_BUILDER_ROOT="${LFS_BUILDER_ROOT:-/opt/lfs-builder}"
  LOGDIR="${LOGDIR:-${LFS_BUILDER_ROOT}/logs}"
  STATEDIR="${STATEDIR:-${LFS_BUILDER_ROOT}/state}"
  LOCKDIR="${LOCKDIR:-${STATEDIR}/locks}"
  LOGFILE="${LOGFILE:-$LOGDIR/init-$(date +'%F_%H-%M-%S').log}"
  SESSION_FILE="${SESSION_FILE:-${STATEDIR}/session.yml}"
  LOCKFILE="${LOCKFILE:-${LOCKDIR}/init.lock}"
  CONFIG_FILE="${CONFIG_FILE:-${LFS_BUILDER_ROOT}/config.env}"

  # Exporta para o ambiente atual
  export LFS LFS_TGT MAKEFLAGS BUILDROOT DESTDIR CHROOT_SHELL
  export LFS_BUILDER_ROOT LOGDIR STATEDIR LOCKDIR LOGFILE SESSION_FILE LOCKFILE CONFIG_FILE

  info "Variáveis de ambiente exportadas:"
  info "  LFS=${LFS}"
  info "  BUILDROOT=${BUILDROOT}"
  info "  DESTDIR=${DESTDIR}"
  info "  MAKEFLAGS='${MAKEFLAGS}'"
}
# ------------------------------------------------------------
#  Verifica se existem locks de outros módulos ativos
# ------------------------------------------------------------
check_other_locks() {
  mkdir -p "$LOCKDIR"
  local other
  other=$(find "$LOCKDIR" -mindepth 1 -maxdepth 1 -type f ! -name "$(basename "$LOCKFILE")" -name '*.lock' 2>/dev/null || true)
  if [[ -n "$other" ]]; then
    warn "Encontrados outros locks em $LOCKDIR:"
    echo "$other" | while read -r f; do warn "  - $f"; done
    warn "Continuando a inicialização pode conflitar com processos em execução."
  fi
}
# ------------------------------------------------------------
#  Limpeza e finalização ao sair
# ------------------------------------------------------------
cleanup_on_exit() {
  local code="${1:-$?}"
  # Se já chamado por error_handler (que já faz update_session e release_lock),
  # não duplicar operações; porém garantimos release_lock seguro.
  if [[ "$code" -eq 0 ]]; then
    update_session "success"
    success "Módulo init finalizado com status SUCCESS."
  else
    # já teremos log do erro via error_handler; apenas garantir status e summary
    update_session "failed"
    error "Módulo init finalizado com status FAILED (código $code)."
  fi
  # Resumo final
  {
    printf "\n[SUMMARY]\n"
    printf " LFS Path ......: %s\n" "$LFS"
    printf " Build Root .....: %s\n" "$BUILDROOT"
    printf " Destdir ........: %s\n" "$DESTDIR"
    printf " Makeflags ......: %s\n" "$MAKEFLAGS"
    printf " User ...........: %s\n" "$(whoami)"
    printf " Host ...........: %s\n" "$(hostname)"
    printf " Logfile ........: %s\n" "$LOGFILE"
    printf " Session file ...: %s\n" "$SESSION_FILE"
    printf " Lockfile .......: %s\n" "$LOCKFILE"
    printf " Status .........: %s\n" "$(yq '.session.status' "$SESSION_FILE" 2>/dev/null || echo 'unknown')"
    printf "\n"
  } >>"$LOGFILE"
  # garantir liberação do lock (idempotente)
  release_lock || true
  # se exit code não zero, propagar para o shell chamador
  if [[ "$code" -ne 0 ]]; then
    exit "$code"
  fi
}
# ------------------------------------------------------------
#  Validações extras de segurança (não sobrescrever raiz/dirs)
# ------------------------------------------------------------
safety_checks() {
  # não permita que LFS seja raiz do host por engano
  if [[ "$LFS" == "/" || "$LFS" == "" || "$LFS" == "/root" ]]; then
    error "Variável LFS aponta para um caminho inseguro: $LFS"
    return 1
  fi
  # Não permitir que BUILDROOT caia fora de LFS
  case "$BUILDROOT" in
    "$LFS"/*) ;; # ok
    *) warn "BUILDROOT ($BUILDROOT) não está dentro de LFS ($LFS). Isso é intencional?";;
  esac
}
# ------------------------------------------------------------
#  Entrada principal do módulo init
# ------------------------------------------------------------
main_init() {
  init_colors
  acquire_lock
  # garantir que, em qualquer saída (normal ou por erro), cleanup_on_exit roda
  trap 'cleanup_on_exit $?' EXIT

  info "==== Iniciando 00-init.sh ===="
  # carregar configuração (se existir) antes de export_env para que overrides funcionem
  if [[ -f "$CONFIG_FILE" ]]; then
    # Load config in a subshell-safe manner so variables are available for export_env
    set -a
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    set +a
    info "Config carregada temporariamente para avaliação."
  fi

  export_env

  check_other_locks
  check_dependencies
  safety_checks
  prepare_directories
  validate_permissions
  detect_environment
  register_session
  # última validação de escrita em logs (testa flock)
  touch "$LOGFILE" 2>/dev/null || {
    error "Não foi possível criar o logfile em $LOGFILE"
    return 1
  }

  info "Inicialização concluída — ambiente pronto para builds."
  success "00-init.sh completado com sucesso."
  # marcar sessão como sucesso agora que tudo concluiu
  update_session "success"
  # liberar lock e sair normalmente (cleanup_on_exit também será executado)
  release_lock
  trap - EXIT
  return 0
}
# ------------------------------------------------------------
#  Permite execução direta do script
# ------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Cria diretórios principais do builder se não existirem (modo seguro)
  mkdir -p "$LFS_BUILDER_ROOT" "$LOGDIR" "$STATEDIR" "$LOCKDIR"
  main_init
fi
