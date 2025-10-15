#!/usr/bin/env bash
#===============================================================================
# 04-install.sh - Instala pacotes construídos no sistema destino
#===============================================================================
set -Eeuo pipefail

#------------------------------------------
# Configuração inicial
#------------------------------------------
LFS_ROOT="${LFS_ROOT:-/opt/lfs-builder}"
INSTALL_ROOT="${INSTALL_ROOT:-/mnt/lfs}"
PACKAGES_DIR="${PACKAGES_DIR:-$LFS_ROOT/packages}"
LOGDIR="${LOGDIR:-$LFS_ROOT/logs}"
STATEDIR="${STATEDIR:-$LFS_ROOT/state}"
LOCKDIR="${LOCKDIR:-$LFS_ROOT/state/locks}"
CONCURRENCY="${CONCURRENCY:-2}"
MAX_TIMEOUT="${MAX_TIMEOUT:-1800}" # 30min por pacote

mkdir -p "$LOGDIR" "$STATEDIR/install.d" "$LOCKDIR" "$PACKAGES_DIR"

#------------------------------------------
# Utilitários de log com cores
#------------------------------------------
log()   { printf "\033[0;37m[%s]\033[0m %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$LOGDIR/install-global.log"; }
info()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*" | tee -a "$LOGDIR/install-global.log"; }
ok()    { printf "\033[1;32m[ OK ]\033[0m %s\n" "$*" | tee -a "$LOGDIR/install-global.log"; }
warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$*" | tee -a "$LOGDIR/install-global.log"; }
error() { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" | tee -a "$LOGDIR/install-global.log" >&2; }

#------------------------------------------
# Tratamento de erros globais
#------------------------------------------
on_error() {
    local lineno=$1 cmd=$2
    error "Erro na linha $lineno: comando '$cmd'"
    echo "status: failed" >> "$STATEDIR/install.yml"
    exit 1
}
trap 'on_error ${LINENO} "${BASH_COMMAND}"' ERR

#------------------------------------------
# Execução com verificação de erro silencioso
#------------------------------------------
run_phase() {
    local phase="$1" cmd="$2" logfile="$3"
    info "Executando fase [$phase]"
    local start_ts=$(date +%s)
    if ! timeout "$MAX_TIMEOUT" bash -c "$cmd" &>>"$logfile"; then
        error "Falha na fase $phase (timeout ou erro fatal)"
        return 1
    fi
    # detectar erro silencioso no log
    if grep -Eiq "(error|denied|fail|corrupt|missing|tar: Error)" "$logfile"; then
        error "Erro silencioso detectado na fase $phase"
        return 1
    fi
    local end_ts=$(date +%s)
    ok "Fase [$phase] concluída em $((end_ts-start_ts))s"
}

#------------------------------------------
# Carregar dependências dos metafiles
#------------------------------------------
declare -A DEPENDS
load_dependencies() {
    info "Lendo dependências dos metafiles..."
    for meta in "$LFS_ROOT"/metafiles/*.yml; do
        local pkg=$(yq eval '.packages[0].name' "$meta" 2>/dev/null || true)
        local deps=$(yq eval '.packages[0].depends[]' "$meta" 2>/dev/null || true)
        [[ -n "$pkg" ]] || continue
        DEPENDS["$pkg"]="$deps"
    done
}

#------------------------------------------
# Verificação de ciclo de dependências
#------------------------------------------
check_cycles() {
    declare -A visiting visited
    local dfs
    dfs() {
        local node="$1"
        visiting["$node"]=1
        for dep in ${DEPENDS[$node]:-}; do
            [[ "$node" == "$dep" ]] && { error "Ciclo direto $node→$dep"; exit 1; }
            if [[ ${visiting[$dep]:-0} -eq 1 ]]; then
                error "Ciclo detectado: $node → $dep"
                exit 1
            fi
            [[ ${visited[$dep]:-0} -eq 0 ]] && dfs "$dep"
        done
        visiting["$node"]=0
        visited["$node"]=1
    }
    for p in "${!DEPENDS[@]}"; do dfs "$p"; done
    ok "Nenhum ciclo detectado."
}

#------------------------------------------
# Ordenar pacotes por dependência
#------------------------------------------
resolve_install_order() {
    info "Resolvendo ordem de instalação..."
    local edges=()
    for pkg in "${!DEPENDS[@]}"; do
        for dep in ${DEPENDS[$pkg]:-}; do
            edges+=("$dep $pkg")
        done
    done
    if [[ ${#edges[@]} -gt 0 ]]; then
        tsort <<< "${edges[*]}"
    else
        printf "%s\n" "${!DEPENDS[@]}"
    fi
}

#------------------------------------------
# Verifica se pacote já está instalado
#------------------------------------------
is_installed() {
    local pkg="$1"
    local state="$STATEDIR/install.d/$pkg.yml"
    if [[ -f "$state" ]]; then
        local status=$(yq eval '.status' "$state" 2>/dev/null || echo "unknown")
        [[ "$status" == "ok" ]] && return 0
    fi
    return 1
}

#------------------------------------------
# Função principal de instalação
#------------------------------------------
install_package() {
    local pkg="$1"
    local tarball="$PACKAGES_DIR/${pkg}"*.tar.*
    local logfile="$LOGDIR/install-$pkg-$(date +%Y%m%d_%H%M%S).log"
    local lockfile="$LOCKDIR/install-$pkg.lock"
    exec 9>"$lockfile" && flock -n 9 || { warn "$pkg já em instalação."; return 0; }

    if is_installed "$pkg"; then
        ok "[SKIP] $pkg já instalado."
        return 0
    fi

    info "Iniciando instalação de $pkg"
    local backupdir="$INSTALL_ROOT/.backup/$pkg-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backupdir"
    rsync -a --delete "$INSTALL_ROOT/" "$backupdir/" &>>"$logfile" || true

    run_phase "extrair" "tar -xf $tarball -C $INSTALL_ROOT" "$logfile" || {
        error "Falha ao instalar $pkg"
        rsync -a --delete "$backupdir/" "$INSTALL_ROOT/" &>>"$logfile"
        echo "status: failed" > "$STATEDIR/install.d/$pkg.yml"
        return 1
    }

    run_phase "verificar" "find $INSTALL_ROOT -type f -newermt '-2min'" "$logfile"
    echo "package: $pkg" > "$STATEDIR/install.d/$pkg.yml"
    echo "status: ok" >> "$STATEDIR/install.d/$pkg.yml"
    ok "$pkg instalado com sucesso."
    flock -u 9
}
#------------------------------------------
# Gerenciador paralelo de instalações
#------------------------------------------
install_all() {
    local pkgs=("$@")
    local running=0
    for pkg in "${pkgs[@]}"; do
        install_package "$pkg" &
        ((running++))
        if (( running >= CONCURRENCY )); then
            wait -n || warn "Falha em thread paralela"
            ((running--))
        fi
    done
    wait
    ok "Todas as instalações concluídas."
}

#------------------------------------------
# CLI e entrada principal
#------------------------------------------
main() {
    local CONTINUE=0
    local VERIFY_ONLY=0
    local DRYRUN=0
    local pkgs=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --continue) CONTINUE=1 ;;
            --verify-only) VERIFY_ONLY=1 ;;
            --dry-run) DRYRUN=1 ;;
            --root) INSTALL_ROOT="$2"; shift ;;
            --jobs) CONCURRENCY="$2"; shift ;;
            *) pkgs+=("$1") ;;
        esac
        shift
    done

    load_dependencies
    check_cycles
    local order=($(resolve_install_order))
    [[ ${#pkgs[@]} -eq 0 ]] && pkgs=("${order[@]}")

    info "Ordem final: ${pkgs[*]}"

    if (( DRYRUN )); then
        info "[DRY-RUN] Nenhuma instalação será aplicada."
        exit 0
    fi

    install_all "${pkgs[@]}"

    ok "Instalação finalizada."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
