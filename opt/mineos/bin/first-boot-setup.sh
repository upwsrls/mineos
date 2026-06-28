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
COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
# Fallback al percorso canonico se lo script viene invocato da altrove.
[[ -f "$COMMON_LIB" ]] || COMMON_LIB="/opt/mineos/bin/lib/common.sh"
if [[ ! -f "$COMMON_LIB" ]]; then
    echo "[first-boot][ERRORE] libreria comune non trovata: $COMMON_LIB" >&2
    exit 1
fi
# shellcheck source=lib/common.sh
source "$COMMON_LIB"

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
    # I binari miner devono essere attraversabili/eseguibili (root li lancia).
    chmod 755 "${MINEOS_MINERS}" "${MINEOS_STATE}" "${MINEOS_LOGS}" 2>/dev/null || true
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
            run apt-get update -y
            run env DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-drivers-common
            # Individua il driver raccomandato (es. 'nvidia-driver-535') e installa
            # ESPLICITAMENTE anche nvidia-utils-<ver> (fornisce 'nvidia-smi'),
            # così non manca dopo il reboot.
            local rec ver
            rec="$(ubuntu-drivers devices 2>/dev/null | grep -oE 'nvidia-driver-[0-9]+' | sort -V | tail -1)"
            if [[ -n "$rec" ]]; then
                ver="${rec#nvidia-driver-}"
                log INFO "Driver raccomandato: ${rec} (installo driver + nvidia-utils-${ver})."
                run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
                    "nvidia-driver-${ver}" "nvidia-utils-${ver}" \
                    || run ubuntu-drivers autoinstall
            else
                log WARN "Nessun driver raccomandato rilevato: uso 'ubuntu-drivers install'."
                run ubuntu-drivers install || run ubuntu-drivers autoinstall
                # Tentativo best-effort di garantire nvidia-smi.
                run env DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-utils \
                    || log WARN "nvidia-utils generico non disponibile (ok se il driver lo include)."
            fi
            ;;
        dnf)
            run dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda
            ;;
        pacman)
            run pacman -S --noconfirm nvidia nvidia-utils
            ;;
        *) die "Installazione driver NVIDIA non supportata su questo package manager." ;;
    esac
    log INFO "Driver NVIDIA installati: necessario REBOOT per caricare il modulo kernel."
    mark_reboot_required
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
    # Timeout: se nessuno risponde alla console entro 120s, usa il default e
    # prosegui (first boot non presidiato non deve restare appeso su 'read').
    if [[ "$silent" -eq 1 ]]; then
        read -rsp "$text " -t 120 input || input=""; echo
    else
        read -rp "$text${default:+ [$default]} " -t 120 input || input=""
    fi
    printf -v "$__dest" '%s' "${input:-$default}"
}

run_wizard() {
    log INFO "Avvio wizard configurazione Kryptex."
    echo "==================================================="
    echo "          mineOS - Configurazione iniziale"
    echo "==================================================="
    echo "Mining su Kryptex Pool. I PAYOUT sono MANUALI: si gestiscono dalla"
    echo "dashboard Kryptex (mineOS non automatizza prelievi né conversioni)."
    echo

    : "${KRX_USERNAME:=}"; : "${KRX_WORKER:=}"; : "${KRX_COIN:=}"; : "${RIG_NAME:=}"

    prompt_value RIG_NAME   "Nome del rig:" "$(hostname -s)"
    prompt_value KRX_WORKER "Nome worker:" "$RIG_NAME"

    echo
    echo "Coin Kryptex da minare (ticker). Default: prl (Pearl, algoritmo pearlhash)."
    echo "Altri esempi: rvn (KawPow), kas (kHeavyHash), etc (Etchash), erg (Autolykos2)."
    prompt_value KRX_COIN "Coin (ticker):" "prl"

    echo
    echo "Username/Wallet Kryptex usato come 'wallet' nel miner."
    echo "Per gestire i payout dalla dashboard usa il tuo account Kryptex"
    echo "(Mining Username 'krxXXXXXX' oppure email); in alternativa un wallet ${KRX_COIN}."
    prompt_value KRX_USERNAME "Username/Wallet Kryptex:"
    if [[ -z "$KRX_USERNAME" ]]; then
        KRX_USERNAME="CHANGE_ME"
        log WARN "Username/Wallet Kryptex non fornito: imposto '$KRX_USERNAME'. Correggilo in pools.conf prima di minare."
    fi

    log INFO "Wizard completato: rig=$RIG_NAME worker=$KRX_WORKER coin=$KRX_COIN (payout manuale da dashboard)."
}

# ============================================================================
# STEP 3 - Download miner nativi
# ============================================================================
# Il catalogo miner (NOME|VERSIONE|URL|SHA256|VENDOR) è centralizzato in
# common.sh (miner_catalog) per evitare disallineamenti tra first-boot e update.

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
    # Estrazione robusta (indipendente dal layout dell'archivio: T-Rex "flat"
    # oppure miner con cartella top-level). Vedi extract_miner_pkg in common.sh.
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log INFO "DRY_RUN: salto estrazione di $name."
    elif ! extract_miner_pkg "${tmp}/pkg.tar.gz" "$dest"; then
        log WARN "Estrazione fallita per $name: salto (proseguo)."
        rm -rf "$tmp"
        return 1
    fi
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
    : "${KRX_COIN:=prl}"

    # L'algoritmo per il miner va normalizzato: l'utente potrebbe aver inserito
    # un ticker (es. 'PRL', 'RVN') che i miner NON accettano come algoritmo.
    local algo; algo="$(normalize_algo "${KRX_COIN}")"

    # Payout MANUALE: si mina la moneta scelta su Kryptex e i prelievi si gestiscono
    # dalla dashboard Kryptex. mineOS non automatizza payout né conversioni.
    local pool_user; pool_user="$(kryptex_pool_user "${KRX_USERNAME}" "${KRX_WORKER}")"

    # --- wallet.conf: credenziali Kryptex + payout (solo se mancante) ---------
    if [[ -f "${MINEOS_CONFIG}/wallet.conf" ]]; then
        log INFO "wallet.conf già presente: lo mantengo."
    else
        cat > "${MINEOS_CONFIG}/wallet.conf" <<EOF
# mineOS - credenziali Kryptex (NON committare, NON condividere)
KRX_USERNAME="${KRX_USERNAME}"
KRX_WORKER="${KRX_WORKER}"
KRX_COIN="${KRX_COIN}"

# Payout: MANUALE dalla dashboard Kryptex (mineOS non automatizza prelievi).
# Accedi a kryptex.com per consultare il saldo ed eseguire i prelievi a mano.
PAYOUT_MODE="manual"
EOF
        chmod 600 "${MINEOS_CONFIG}/wallet.conf"
        log INFO "wallet.conf creato (payout=manuale)."
    fi

    # --- pools.conf: endpoint stratum Kryptex (solo se mancante) -------------
    if [[ -f "${MINEOS_CONFIG}/pools.conf" ]]; then
        log INFO "pools.conf già presente: lo mantengo."
    else
        local pool_url; pool_url="$(kryptex_pool_url "${KRX_COIN}")"
        cat > "${MINEOS_CONFIG}/pools.conf" <<EOF
# mineOS - pool Kryptex per coin=${KRX_COIN} (payout manuale da dashboard)
# Endpoint reale Kryptex (host:porta dipendono dal coin). Vedi pool.kryptex.com.
POOL_URL="${pool_url}"
# Formato: <account>.<worker> (con email: <email>/<worker>).
POOL_USER="${pool_user}"
POOL_PASS="x"
EOF
        chmod 600 "${MINEOS_CONFIG}/pools.conf"
        log INFO "pools.conf creato (pool=${pool_url} user=${pool_user})."
    fi

    # --- rig.conf: hardware, miner scelto, OC/limiti (solo se mancante) ------
    if [[ -f "${MINEOS_CONFIG}/rig.conf" ]]; then
        log INFO "rig.conf già presente: lo mantengo."
    else
        local default_miner="srbminer"   # Pearl/pearlhash e' il default mineOS
        case "$vendor" in
            amd) default_miner="srbminer" ;;
            nvidia) default_miner="srbminer" ;;  # Pearl su NVIDIA usa SRBMiner
            *)   default_miner="srbminer" ;;
        esac
        # Alcuni algoritmi richiedono un miner specifico (es. pearlhash->srbminer):
        # in tal caso l'override prevale sul default per-vendor.
        local pref_miner; pref_miner="$(miner_for_algo "$algo")"
        [[ -n "$pref_miner" ]] && default_miner="$pref_miner"
        cat > "${MINEOS_CONFIG}/rig.conf" <<EOF
# mineOS - configurazione rig
GPU_VENDOR="${vendor}"
MINER="${default_miner}"            # trex | lolminer | srbminer (Pearl -> srbminer)
ALGO="${algo}"                      # algoritmo normalizzato (es. pearlhash)

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
# Abilita i servizi (NON li avvia). Grazie a WantedBy=multi-user.target
# partiranno da soli a ogni boot; nessuna condizione bloccante li frena
# (l'agent ripulisce da solo il flag reboot-required al proprio avvio).
enable_services() {
    sysctl_safe enable mineos-agent.service mineos-watchdog.service
    # Timer profit-switch sempre abilitato: lo script si auto-gate su rig.conf.
    sysctl_safe enable mineos-profit-switch.timer
}

# Avvia il mining adesso (caso "nessun reboot necessario").
start_services_now() {
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
}

# Scrive un riepilogo in state/payout.txt: il payout è MANUALE dalla dashboard
# Kryptex (mineOS non automatizza prelievi). Idempotente.
write_payout_summary() {
    local coin="${KRX_COIN:-prl}"
    local user="${KRX_USERNAME:-CHANGE_ME}"
    local f="${MINEOS_STATE}/payout.txt"
    umask 077
    cat > "$f" <<EOF
mineOS - Payout MANUALE (dashboard Kryptex)
===========================================
Coin minato : ${coin}
Wallet/User : ${user}
Payout      : MANUALE. mineOS non automatizza prelievi né conversioni.

Cosa fa mineOS in automatico:
  - mina ${coin} sul pool Kryptex (vedi POOL_URL/POOL_USER in pools.conf).

Prelievi (a mano) su https://kryptex.com:
  1) accedi al tuo account/saldo Kryptex;
  2) controlla il saldo accumulato per il worker;
  3) avvia il prelievo manuale verso il wallet/indirizzo che preferisci,
     quando vuoi (nessuna soglia di auto-withdraw impostata da mineOS).
EOF
    chmod 600 "$f" 2>/dev/null || true
    log INFO "Riepilogo payout (manuale) scritto in ${f}."
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

    write_payout_summary

    # Abilita i servizi e segna il first-boot come completato PRIMA di avviarli,
    # così la condizione 'first-boot.done' dell'agent è già soddisfatta.
    enable_services
    mark_done

    local payout_note=" Payout MANUALE dalla dashboard Kryptex (vedi state/payout.txt)."

    if reboot_required; then
        # Driver/kernel appena installati: serve un riavvio per caricarli.
        # Il rig è non presidiato → riavviamo noi. Il flag reboot-required resta
        # su disco e verrà rimosso dall'agent al boot successivo, quando il
        # mining parte AUTOMATICAMENTE (nessuna condizione bloccante).
        notify FIRSTBOOT_DONE "Setup completato (coin=${KRX_COIN}).${payout_note} Riavvio per attivare i driver GPU; il mining parte da solo dopo il reboot."
        log INFO "Riavvio automatico per attivare i driver GPU: il mining partirà da solo dopo il reboot."
        echo
        echo ">>> Driver GPU installati. Riavvio in corso: il mining partirà da solo dopo il riavvio. <<<"
        sync
        sysctl_safe reboot
    else
        notify FIRSTBOOT_DONE "Setup completato (coin=${KRX_COIN}).${payout_note} Mining in avvio."
        start_services_now
    fi
}

main "$@"
