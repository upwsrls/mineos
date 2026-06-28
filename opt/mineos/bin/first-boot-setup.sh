#!/usr/bin/env bash
#
# /opt/mineos/bin/first-boot-setup.sh
#
# mineOS - First boot setup
# --------------------------
# Eseguito UNA volta al primo avvio (via mineos-firstboot.service, oneshot):
#   1. Verifica prerequisiti e crea la struttura cartelle.
#   2. Rileva il vendor GPU (NVIDIA / AMD) e installa i driver corretti.
#   3. Wizard CLI: chiede credenziali Kryptex (username + worker) e profilo.
#   4. Scarica i miner nativi Linux corrispondenti al vendor.
#   5. Genera i file di config (wallet.conf, pools.conf, rig.conf).
#   6. Marca il first-boot come completato e abilita i servizi di mining.
#
# Idempotente: se rilanciato dopo il completamento, esce senza fare nulla
# (a meno di --force).
#
# NB: volutamente SENZA 'set -e': il first boot deve COMPLETARSI anche se un
# singolo passo non critico fallisce (avvisi minori). Gli errori fatali sono
# gestiti esplicitamente con 'die'. Manteniamo -u (variabili non definite) e
# pipefail per non mascherare bug.
set -uo pipefail

# --- Carica la libreria comune ----------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

FORCE=0
NONINTERACTIVE=0   # se 1, legge i valori da env invece che da prompt (immagini pre-config)
for arg in "$@"; do
    case "$arg" in
        --force)          FORCE=1 ;;
        --noninteractive) NONINTERACTIVE=1 ;;
        *) die "Argomento sconosciuto: $arg" ;;
    esac
done

DONE_FLAG="${MINEOS_STATE}/first-boot.done"

# Non abortiamo sugli errori: li segnaliamo come avviso e proseguiamo.
trap 'log WARN "Passo non riuscito (riga $LINENO): $BASH_COMMAND — proseguo."' ERR

# ============================================================================
# STEP 0 - Prerequisiti e struttura cartelle
# ============================================================================
bootstrap_dirs() {
    require_root
    mkdir -p "${MINEOS_BIN}" "${MINEOS_MINERS}" "${MINEOS_CONFIG}" \
             "${MINEOS_STATE}" "${MINEOS_LOGS}"
    chmod 700 "${MINEOS_CONFIG}"   # qui stanno le credenziali: niente lettura ad altri
    log INFO "Struttura cartelle pronta sotto ${MINEOS_ROOT}."
}

check_already_done() {
    if [[ -f "$DONE_FLAG" && "$FORCE" -ne 1 ]]; then
        log INFO "First boot già completato ($DONE_FLAG). Uso --force per rieseguire."
        exit 0
    fi
}

# Strumenti indispensabili. Installati se mancanti.
ensure_base_tools() {
    local pm; pm="$(detect_pkg_mgr)"
    local need=(curl tar gzip ca-certificates pciutils jq)
    log INFO "Verifica strumenti base ($pm)..."
    case "$pm" in
        apt)
            run apt-get update -y
            run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}"
            ;;
        dnf)    run dnf install -y "${need[@]}" ;;
        pacman) run pacman -Sy --noconfirm curl tar gzip ca-certificates pciutils jq ;;
        *) die "Package manager non supportato. Installa manualmente: ${need[*]}" ;;
    esac
}

# ============================================================================
# STEP 1 - Driver GPU
# ============================================================================
install_nvidia_driver() {
    if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
        log INFO "Driver NVIDIA già funzionanti: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
        return 0
    fi
    local pm; pm="$(detect_pkg_mgr)"
    log INFO "Installazione driver NVIDIA proprietari..."
    case "$pm" in
        apt)
            run env DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-drivers-common
            run ubuntu-drivers autoinstall
            ;;
        dnf)
            run dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda
            ;;
        pacman)
            run pacman -S --noconfirm nvidia nvidia-utils
            ;;
        *) die "Installazione driver NVIDIA non supportata su questo package manager." ;;
    esac
    log INFO "Driver NVIDIA installati: necessario REBOOT prima del mining."
    touch "${MINEOS_STATE}/reboot-required"
}

install_amd_driver() {
    if command -v rocm-smi >/dev/null 2>&1; then
        log INFO "Stack AMD/ROCm già presente."
        return 0
    fi
    local pm; pm="$(detect_pkg_mgr)"
    log INFO "Installazione stack OpenCL AMD..."
    case "$pm" in
        apt)
            run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
                mesa-opencl-icd clinfo ocl-icd-libopencl1
            ;;
        dnf)    run dnf install -y mesa-libOpenCL clinfo ocl-icd ;;
        pacman) run pacman -S --noconfirm opencl-mesa clinfo ocl-icd ;;
        *) die "Installazione stack AMD non supportata su questo package manager." ;;
    esac
    log INFO "Stack OpenCL AMD installato. Verifica con 'clinfo'."
}

install_drivers() {
    local vendor="$1"
    case "$vendor" in
        nvidia) install_nvidia_driver ;;
        amd)    install_amd_driver ;;
        both)   install_nvidia_driver; install_amd_driver ;;
        none)
            # Nessuna GPU rilevata da NESSUN metodo (lspci/nvidia-smi/rocm-smi/sysfs).
            # Non è fatale: completiamo il setup e lasciamo che l'utente intervenga.
            log WARN "Nessuna GPU rilevata. Salto l'installazione driver; verifica l'hardware/driver."
            ;;
        *)
            log WARN "Vendor GPU non riconosciuto ('$vendor'). Salto l'installazione driver."
            ;;
    esac
}

# ============================================================================
# STEP 2 - Wizard CLI credenziali Kryptex
# ============================================================================
# In modalità noninteractive i valori arrivano da env:
#   KRX_USERNAME, KRX_WORKER, KRX_COIN, RIG_NAME
prompt_value() {
    # prompt_value <var_dest> <testo> <default> [silent]
    local __dest="$1" text="$2" default="${3:-}" silent="${4:-0}" input
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        printf -v "$__dest" '%s' "${!__dest:-$default}"
        return 0
    fi
    if [[ "$silent" -eq 1 ]]; then
        read -rsp "$text " input; echo
    else
        read -rp "$text${default:+ [$default]} " input
    fi
    printf -v "$__dest" '%s' "${input:-$default}"
}

run_wizard() {
    log INFO "Avvio wizard configurazione Kryptex."
    echo "==================================================="
    echo "          mineOS - Configurazione iniziale"
    echo "==================================================="
    echo "Trovi username e worker nella dashboard Kryptex"
    echo "(sezione 'Mining manuale / GPU miner setup')."
    echo

    : "${KRX_USERNAME:=}"; : "${KRX_WORKER:=}"; : "${KRX_COIN:=}"; : "${RIG_NAME:=}"

    prompt_value KRX_USERNAME "Username/Wallet Kryptex:"
    if [[ -z "$KRX_USERNAME" ]]; then
        KRX_USERNAME="CHANGE_ME"
        log WARN "Username Kryptex non fornito: imposto '$KRX_USERNAME'. Modificalo in wallet.conf prima di minare."
    fi

    prompt_value RIG_NAME    "Nome del rig:" "$(hostname -s)"
    prompt_value KRX_WORKER  "Nome worker:" "$RIG_NAME"

    echo
    echo "Coin/algoritmo da minare (deve corrispondere a un pool Kryptex valido)."
    echo "Esempi tipici: kawpow (RVN), etchash (ETC), autolykos2 (ERGO)."
    prompt_value KRX_COIN "Coin/algoritmo:" "kawpow"

    log INFO "Wizard completato: rig=$RIG_NAME worker=$KRX_WORKER coin=$KRX_COIN"
}

# ============================================================================
# STEP 3 - Download miner nativi
# ============================================================================
# Tabella miner: NOME|VERSIONE|URL|SHA256|VENDOR
# Aggiorna versioni/URL/checksum dai repo ufficiali (GitHub releases).
miner_catalog() {
    cat <<'EOF'
trex|0.26.8|https://github.com/trexminer/T-Rex/releases/download/0.26.8/t-rex-0.26.8-linux.tar.gz|REPLACE_WITH_REAL_SHA256|nvidia
lolminer|1.88|https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.88/lolMiner_v1.88_Lin64.tar.gz|REPLACE_WITH_REAL_SHA256|both
srbminer|2.6.8|https://github.com/doktor83/SRBMiner-Multi/releases/download/2.6.8/SRBMiner-Multi-2-6-8-Linux.tar.gz|REPLACE_WITH_REAL_SHA256|amd
EOF
}

download_miner() {
    # download_miner <nome> <versione> <url> <sha256>
    local name="$1" ver="$2" url="$3" sha="$4"
    local dest="${MINEOS_MINERS}/${name}/${ver}"
    if [[ -d "$dest" && -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
        log INFO "Miner $name $ver già presente, salto download."
        return 0
    fi
    mkdir -p "$dest"
    local tmp; tmp="$(mktemp -d)"
    log INFO "Download $name $ver da $url"
    run curl -fL --retry 3 -o "${tmp}/pkg.tar.gz" "$url"
    if [[ "$sha" != REPLACE_WITH_REAL_SHA256 && "${DRY_RUN:-0}" != "1" ]]; then
        verify_sha256 "${tmp}/pkg.tar.gz" "$sha"
    else
        log WARN "Checksum non verificato per $name (placeholder o DRY_RUN)."
    fi
    run tar -xzf "${tmp}/pkg.tar.gz" -C "$dest" --strip-components=1
    rm -rf "$tmp"
    # Symlink alla versione attiva: facilita rollback (vedi update-mineos.sh).
    ln -sfn "$dest" "${MINEOS_MINERS}/${name}/current"
    log INFO "Miner $name installato in $dest"
}

install_miners() {
    local vendor="$1"
    while IFS='|' read -r name ver url sha mvendor; do
        [[ -z "$name" ]] && continue
        if [[ "$mvendor" == "both" || "$mvendor" == "$vendor" || "$vendor" == "both" ]]; then
            download_miner "$name" "$ver" "$url" "$sha"
        fi
    done < <(miner_catalog)
}

# ============================================================================
# STEP 4 - Generazione file di config
# ============================================================================
write_configs() {
    local vendor="$1"
    umask 077

    # Valori di default per i campi non raccolti dal wizard (modalità robusta).
    : "${KRX_USERNAME:=CHANGE_ME}"
    : "${KRX_WORKER:=$(hostname -s 2>/dev/null || echo rig)}"
    : "${KRX_COIN:=kawpow}"

    # --- wallet.conf: credenziali Kryptex (solo se mancante) -----------------
    if [[ -f "${MINEOS_CONFIG}/wallet.conf" ]]; then
        log INFO "wallet.conf già presente: lo mantengo."
    else
        cat > "${MINEOS_CONFIG}/wallet.conf" <<EOF
# mineOS - credenziali Kryptex (NON committare, NON condividere)
KRX_USERNAME="${KRX_USERNAME}"
KRX_WORKER="${KRX_WORKER}"
KRX_COIN="${KRX_COIN}"
EOF
        chmod 600 "${MINEOS_CONFIG}/wallet.conf"
        log INFO "wallet.conf creato."
    fi

    # --- pools.conf: endpoint stratum Kryptex (solo se mancante) -------------
    if [[ -f "${MINEOS_CONFIG}/pools.conf" ]]; then
        log INFO "pools.conf già presente: lo mantengo."
    else
        cat > "${MINEOS_CONFIG}/pools.conf" <<EOF
# mineOS - pool Kryptex per coin=${KRX_COIN}
# Sostituisci host/porta con i valori reali della tua dashboard Kryptex.
POOL_URL="stratum+tcp://${KRX_COIN}.kryptex.network:7777"
POOL_USER="${KRX_USERNAME}.${KRX_WORKER}"
POOL_PASS="x"
EOF
        chmod 600 "${MINEOS_CONFIG}/pools.conf"
        log INFO "pools.conf creato."
    fi

    # --- rig.conf: hardware, miner scelto, OC/limiti (solo se mancante) ------
    if [[ -f "${MINEOS_CONFIG}/rig.conf" ]]; then
        log INFO "rig.conf già presente: lo mantengo."
    else
        local default_miner
        case "$vendor" in
            amd) default_miner="srbminer" ;;
            *)   default_miner="trex" ;;     # nvidia/both/none -> trex di default
        esac
        cat > "${MINEOS_CONFIG}/rig.conf" <<EOF
# mineOS - configurazione rig
GPU_VENDOR="${vendor}"
MINER="${default_miner}"            # trex | lolminer | srbminer
ALGO="${KRX_COIN}"

# Limiti termici/potenza (0 = non gestito da mineOS)
GPU_POWER_LIMIT_W="0"               # es. 120 (NVIDIA: nvidia-smi -pl)
GPU_TEMP_LIMIT_C="75"               # soglia warning per watchdog
GPU_CORE_OFFSET="0"
GPU_MEM_OFFSET="0"

# Watchdog
WATCHDOG_HASHRATE_MIN="0"           # 0 = solo controllo "hashrate non zero"
WATCHDOG_ZERO_GRACE_SEC="300"       # restart se sotto soglia per N secondi

# Profit-switch automatico (richiede profit-switch.conf). true | false
PROFIT_SWITCH="false"
EOF
        chmod 600 "${MINEOS_CONFIG}/rig.conf"
        log INFO "rig.conf creato (miner=${default_miner})."
    fi

    log INFO "Configurazione pronta in ${MINEOS_CONFIG}."
    log WARN "Verifica POOL_URL in pools.conf con la dashboard Kryptex prima di minare."
}

# ============================================================================
# STEP 5 - Finalizzazione
# ============================================================================
enable_services() {
    sysctl_safe enable mineos-agent.service mineos-watchdog.service
    # Timer profit-switch sempre abilitato: lo script si auto-gate su rig.conf.
    sysctl_safe enable mineos-profit-switch.timer

    if [[ -f "${MINEOS_STATE}/reboot-required" ]]; then
        log INFO "Reboot richiesto (driver appena installati): i servizi partiranno dopo il riavvio."
        return 0
    fi

    # Avvio automatico del mining dopo il setup.
    sysctl_safe start mineos-agent.service mineos-watchdog.service
    sysctl_safe start mineos-profit-switch.timer

    # Verifica che l'agent sia effettivamente attivo; se non lo è, riprova una volta.
    if command -v systemctl >/dev/null 2>&1; then
        sleep 2
        if systemctl is-active --quiet mineos-agent.service; then
            log INFO "Mining avviato automaticamente (mineos-agent attivo)."
        else
            log WARN "mineos-agent non attivo: riprovo un avvio."
            sysctl_safe restart mineos-agent.service
        fi
    fi
}

mark_done() {
    date --iso-8601=seconds > "$DONE_FLAG"
    # Disabilita il servizio di first-boot così non rigira ai boot successivi.
    sysctl_safe disable mineos-firstboot.service
    log INFO "First boot completato."
    if [[ -f "${MINEOS_STATE}/reboot-required" ]]; then
        notify FIRSTBOOT_DONE "Setup completato per coin=${KRX_COIN}. Reboot necessario per i driver GPU, poi il mining parte da solo."
        echo
        echo ">>> Driver GPU installati: riavvia il sistema per iniziare a minare. <<<"
    else
        notify FIRSTBOOT_DONE "Setup completato per coin=${KRX_COIN}. Mining in avvio."
    fi
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    bootstrap_dirs
    check_already_done
    ensure_base_tools

    local vendor; vendor="$(detect_gpu_vendor)"
    log INFO "GPU vendor rilevato: ${vendor}"

    install_drivers "$vendor"
    run_wizard
    install_miners "$vendor"
    write_configs "$vendor"
    enable_services
    mark_done
}

main "$@"
