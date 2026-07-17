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
        --help|-h)
            cat <<'EOF'
Uso: sudo first-boot-setup.sh [--force] [--noninteractive]
  --force           riesegue anche se il first boot e' gia' completato
  --noninteractive  non chiede nulla: usa i valori da env (KRX_USERNAME, ...)
EOF
            exit 0 ;;
        *) die "Argomento sconosciuto: $arg (usa --help)" ;;
    esac
done

# BUG5: sopravvivere all'HUP. Se la console tty1 o la sessione SSH da cui e'
# stato lanciato si chiude, il processo riceve SIGHUP e muore ("code=killed,
# signal=HUP"), lasciando il setup a meta'. Ignoriamo SIGHUP: driver, miner e
# config vengono completati comunque. La parte NON interattiva non dipende dal
# terminale; il wizard interattivo ha timeout e default (vedi prompt_value).
trap '' HUP

# Se non c'e' un terminale su stdin (es. eseguito via SSH senza -t, o detach),
# passiamo in modalita' non interattiva: niente prompt che si bloccano, si usano
# i default/env e il setup arriva SEMPRE a scrivere i config.
if [[ "$NONINTERACTIVE" -eq 0 ]] && ! [[ -t 0 ]]; then
    NONINTERACTIVE=1
fi

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
# BUG7: SRBMiner usa OpenCL per enumerare le GPU -> servono l'ICD loader
# (ocl-icd-libopencl1) e 'clinfo' (usato anche da gpu-health-check.sh). Senza,
# il miner non vede le schede. Li includiamo qui e nell'autoinstall.
ensure_base_tools() {
    local pm; pm="$(detect_pkg_mgr)"
    local need=(curl tar gzip ca-certificates pciutils jq ocl-icd-libopencl1 clinfo)
    log INFO "Verifica strumenti base ($pm)..."
    case "$pm" in
        apt)
            run apt-get update -y
            run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}"
            ;;
        dnf)    run dnf install -y curl tar gzip ca-certificates pciutils jq ocl-icd clinfo ;;
        pacman) run pacman -Sy --noconfirm curl tar gzip ca-certificates pciutils jq ocl-icd clinfo ;;
        *) die "Package manager non supportato. Installa manualmente: ${need[*]}" ;;
    esac
}

# ============================================================================
# STEP 1 - Driver GPU
# ============================================================================
# Log dedicato all'installazione driver (richiesto: /opt/mineos/logs/driver-install.log)
DRIVER_LOG="${MINEOS_LOGS}/driver-install.log"

# Timeout ESPLICITI (secondi) sulle operazioni lente: un apt/dkms appeso NON
# deve mai bloccare il boot. Allo scadere il comando viene ucciso e si prosegue
# (con fallback). Vedi anche TimeoutStartSec nella unit mineos-firstboot.service.
TO_APT_UPDATE=300     # apt-get update
TO_APT_INSTALL=1200   # apt-get install (include compilazione DKMS)
TO_APT_PURGE=300      # apt-get purge/autoremove
TO_DRIVERS=1200       # ubuntu-drivers autoinstall
TO_INITRAMFS=600      # update-initramfs -u

# Logga sia sul log generale sia sul log driver dedicato.
dlog() {
    mkdir -p "${MINEOS_LOGS}" 2>/dev/null || true
    printf '%s %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)" "$*" >> "${DRIVER_LOG}" 2>/dev/null || true
    log INFO "$*"
}

# Branch NVIDIA raccomandato (es. '595') da ubuntu-drivers. Vuoto se non rilevato.
nvidia_branch_recommended() {
    ubuntu-drivers devices 2>/dev/null \
        | grep -oE 'nvidia-driver-[0-9]+' \
        | sed 's/nvidia-driver-//' \
        | sort -n | tail -1
}

# Il modulo DKMS nvidia risulta 'installed' PER IL KERNEL CORRENTE (uname -r)?
# Questo e' l'UNICO criterio di successo dell'installazione driver al primo boot:
# il modulo appena compilato NON e' ancora caricato in RAM, quindi nvidia-smi
# fallirebbe SEMPRE (si caricherà al reboot). Ci basiamo su DKMS, non su nvidia-smi.
# Uso: nvidia_dkms_installed [branch]  (branch opzionale per restringere il match).
nvidia_dkms_installed() {
    command -v dkms >/dev/null 2>&1 || return 1
    local br="${1:-}" kver lines
    kver="$(uname -r)"
    # Righe DKMS del modulo nvidia relative al kernel in esecuzione.
    lines="$(dkms status 2>/dev/null | grep -i 'nvidia' | grep -F "$kver" || true)"
    [[ -n "$br" ]] && lines="$(printf '%s\n' "$lines" | grep -F "$br" || true)"
    printf '%s\n' "$lines" | grep -qi 'installed'
}

# dpkg: pacchetto installato (stato 'ii')?
pkg_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q '^ii'
}

# Evita che restino installati SIA il modulo closed SIA quello open dello stesso
# branch (causa 'RmInitAdapter failed' su Blackwell): rimuove il closed.
ensure_single_nvidia_module() {
    local br="$1"
    if pkg_installed "nvidia-dkms-${br}" && pkg_installed "nvidia-dkms-${br}-open"; then
        dlog "Rilevati closed+open per branch ${br}: rimuovo i pacchetti closed."
        run timeout "${TO_APT_PURGE}" env DEBIAN_FRONTEND=noninteractive apt-get purge -y \
            "nvidia-dkms-${br}" "nvidia-kernel-source-${br}" 2>/dev/null || true
        run timeout "${TO_APT_PURGE}" env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
    fi
    # Verifica finale con dpkg -l: non devono restare entrambi.
    if pkg_installed "nvidia-dkms-${br}" && pkg_installed "nvidia-dkms-${br}-open"; then
        dlog "ATTENZIONE: closed+open ancora entrambi presenti per ${br} (verifica manuale)."
        return 1
    fi
    return 0
}

# Installa il modulo OPEN dello stesso branch (Blackwell/RTX 50xx).
# SUCCESSO = compilazione DKMS 'installed' per il KERNEL CORRENTE. NON usa
# nvidia-smi (al primo boot il modulo non e' ancora caricato): usarlo qui
# provocherebbe un fallback errato al closed, fatale per le Blackwell.
install_nvidia_open() {
    local br="$1"
    dlog "Provo modulo OPEN: nvidia-driver-${br}-open (+ nvidia-dkms-${br}-open, nvidia-utils-${br})."
    if ! run timeout "${TO_APT_INSTALL}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            "nvidia-driver-${br}-open" "nvidia-dkms-${br}-open" "nvidia-utils-${br}"; then
        dlog "Pacchetto OPEN ${br} non disponibile/installazione fallita/timeout."
        return 1
    fi
    ensure_single_nvidia_module "$br" || true
    # Verifica ESCLUSIVAMENTE via DKMS (kernel corrente), MAI via nvidia-smi.
    if nvidia_dkms_installed "$br"; then
        dlog "OK: modulo OPEN ${br} compilato via DKMS ('installed' per kernel $(uname -r)). Si caricherà al reboot."
        return 0
    fi
    dlog "FALLITA compilazione DKMS del modulo OPEN ${br} per kernel $(uname -r) (dkms status: $(dkms status 2>/dev/null | grep -i nvidia | tr '\n' ';'))."
    return 1
}

# Fallback: modulo CLOSED dello stesso branch. Scatta SOLO se la compilazione
# DKMS dell'open e' FALLITA davvero (non se nvidia-smi non risponde ancora).
# Anche qui il successo si valuta via DKMS 'installed', non via nvidia-smi.
install_nvidia_closed() {
    local br="$1"
    dlog "FALLBACK modulo CLOSED: nvidia-driver-${br} (+ nvidia-utils-${br})."
    # Rimuovi eventuale open rimasto rotto per non avere doppio modulo.
    if pkg_installed "nvidia-dkms-${br}-open"; then
        run timeout "${TO_APT_PURGE}" env DEBIAN_FRONTEND=noninteractive apt-get purge -y "nvidia-dkms-${br}-open" 2>/dev/null || true
    fi
    if ! run timeout "${TO_APT_INSTALL}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            "nvidia-driver-${br}" "nvidia-utils-${br}"; then
        dlog "Installazione closed ${br} via metapacchetto fallita/timeout: provo 'ubuntu-drivers autoinstall'."
        run timeout "${TO_DRIVERS}" ubuntu-drivers autoinstall || { dlog "ubuntu-drivers autoinstall fallito/timeout."; return 1; }
    fi
    # Verifica ESCLUSIVAMENTE via DKMS (kernel corrente), MAI via nvidia-smi.
    if nvidia_dkms_installed "$br"; then
        dlog "OK: modulo CLOSED ${br} compilato via DKMS ('installed' per kernel $(uname -r)). Si caricherà al reboot."
        return 0
    fi
    dlog "AVVISO: DKMS non 'installed' per CLOSED ${br} su kernel $(uname -r) (potrebbe usare un modulo precompilato che si caricherà al reboot)."
    return 0
}

install_nvidia_driver() {
    mkdir -p "${MINEOS_LOGS}" 2>/dev/null || true
    dlog "===== INIZIO installazione driver NVIDIA: $(date --iso-8601=seconds 2>/dev/null || date) ====="
    # SOLO se il driver e' GIA' attivo (modulo caricato) usiamo nvidia-smi per la
    # verifica di visibilita' GPU. In tutti gli altri casi la valutazione e' via
    # DKMS: al primo boot il modulo non e' ancora caricato e nvidia-smi fallirebbe.
    if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
        dlog "Driver NVIDIA già attivo: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
        verify_nvidia_gpu_visibility
        dlog "===== FINE installazione driver NVIDIA (già presente): $(date --iso-8601=seconds 2>/dev/null || date) ====="
        return 0
    fi
    local pm; pm="$(detect_pkg_mgr)"
    dlog "Installazione driver NVIDIA (preferenza: modulo OPEN per Blackwell/RTX 50xx)."
    case "$pm" in
        apt)
            run timeout "${TO_APT_UPDATE}" apt-get update -y || dlog "AVVISO: apt-get update fallito/timeout (proseguo)."
            run timeout "${TO_APT_INSTALL}" env DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-drivers-common dkms \
                || dlog "AVVISO: install ubuntu-drivers-common/dkms fallito/timeout (proseguo)."
            local br; br="$(nvidia_branch_recommended)"
            if [[ -z "$br" ]]; then
                dlog "Nessun branch nvidia raccomandato da ubuntu-drivers: uso 'ubuntu-drivers autoinstall'."
                run timeout "${TO_DRIVERS}" ubuntu-drivers autoinstall || dlog "ubuntu-drivers autoinstall fallito/timeout (proseguo)."
            else
                dlog "Branch NVIDIA scelto: ${br}."
                # 1) prova OPEN; 2) se non disponibile o DKMS non compila -> CLOSED.
                if install_nvidia_open "$br"; then
                    dlog "Driver OPEN ${br} installato e verificato (DKMS installed)."
                else
                    dlog "OPEN ${br} non riuscito: eseguo FALLBACK al closed ${br}."
                    install_nvidia_closed "$br" || dlog "ERRORE: sia OPEN che CLOSED ${br} falliti. Verifica ${DRIVER_LOG}."
                fi
            fi
            # initramfs aggiornato dopo l'installazione del modulo.
            run timeout "${TO_INITRAMFS}" update-initramfs -u || dlog "AVVISO: update-initramfs fallito/timeout (proseguo)."
            # Verifica finale dpkg: non devono coesistere closed+open dello stesso branch.
            if [[ -n "$br" ]]; then
                dlog "dpkg nvidia (branch ${br}): $(dpkg -l | grep -E "nvidia-(dkms|driver)-${br}(-open)?" | awk '{print $2"="$1}' | tr '\n' ' ')"
            fi
            # Stato DKMS compilato (chiaro cosa verra' caricato al reboot).
            dlog "dkms status (nvidia): $(dkms status 2>/dev/null | grep -i nvidia | tr '\n' ';' || echo 'nessun modulo nvidia in DKMS')"
            ;;
        dnf)
            run timeout "${TO_APT_INSTALL}" dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda || dlog "AVVISO: install driver dnf fallito/timeout."
            ;;
        pacman)
            run timeout "${TO_APT_INSTALL}" pacman -S --noconfirm nvidia-open nvidia-utils \
                || run timeout "${TO_APT_INSTALL}" pacman -S --noconfirm nvidia nvidia-utils \
                || dlog "AVVISO: install driver pacman fallito/timeout."
            ;;
        *) dlog "Package manager non supportato per i driver NVIDIA: salto (SSH resta comunque attivo)."; ;;
    esac
    dlog "Driver NVIDIA: installazione conclusa, necessario REBOOT per caricare il modulo. Log: ${DRIVER_LOG}"
    apply_nvidia_boot_fix
    apply_multigpu_grub_fix
    mark_reboot_required
    dlog "===== FINE installazione driver NVIDIA: $(date --iso-8601=seconds 2>/dev/null || date) ====="
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

    log INFO "Wizard completato: rig=$RIG_NAME worker=$KRX_WORKER coin=$KRX_COIN (payout manuale)."
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
# BUG4: prima si faceva 'cat > file <<EOF' e si loggava "creato" SENZA verificare
# che il file esistesse davvero: se la scrittura falliva (dir mancante, errore
# I/O, ecc.) il log diceva comunque "creato" e l'agent poi falliva in loop con
# "Config mancante". Questo helper scrive, VERIFICA (file esistente e non vuoto),
# riprova una volta, e ritorna non-zero con ERROR se non riesce.
# Uso:  write_conf "$file" <<EOF ... EOF
write_conf() {
    local f="$1" content
    content="$(cat)"   # contenuto dallo stdin (heredoc)
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    printf '%s\n' "$content" > "$f" 2>/dev/null || true
    if [[ ! -s "$f" ]]; then
        log WARN "Scrittura di ${f} non riuscita al primo tentativo: riprovo."
        sync 2>/dev/null || true
        printf '%s\n' "$content" > "$f" 2>/dev/null || true
    fi
    if [[ -s "$f" ]]; then
        chmod 600 "$f" 2>/dev/null || true
        return 0
    fi
    log ERROR "VERIFICA FALLITA: ${f} non esiste o e' vuoto dopo la scrittura."
    log ERROR "  Stato cartella config: $(ls -ld "${MINEOS_CONFIG}" 2>&1)"
    log ERROR "  Contenuto config: $(ls -la "${MINEOS_CONFIG}" 2>&1 | tr '\n' '|')"
    return 1
}

write_configs() {
    local vendor="$1"
    umask 077
    CONFIG_WRITE_FAILED=0

    # Assicura la cartella config PRIMA di scrivere (causa tipica di scritture
    # silenziosamente fallite: cartella assente/non scrivibile).
    mkdir -p "${MINEOS_CONFIG}" 2>/dev/null || true
    chmod 700 "${MINEOS_CONFIG}" 2>/dev/null || true

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
        if write_conf "${MINEOS_CONFIG}/wallet.conf" <<EOF
# mineOS - credenziali Kryptex (NON committare, NON condividere)
KRX_USERNAME="${KRX_USERNAME}"
KRX_WORKER="${KRX_WORKER}"
KRX_COIN="${KRX_COIN}"

# Payout: MANUALE dalla dashboard Kryptex (mineOS non automatizza prelievi).
# Accedi a kryptex.com per consultare il saldo ed eseguire i prelievi a mano.
PAYOUT_MODE="manual"
EOF
        then
            log INFO "wallet.conf creato (payout=manuale)."
        else
            log ERROR "wallet.conf NON creato."; CONFIG_WRITE_FAILED=1
        fi
    fi

    # --- pools.conf: endpoint stratum Kryptex (solo se mancante) -------------
    if [[ -f "${MINEOS_CONFIG}/pools.conf" ]]; then
        log INFO "pools.conf già presente: lo mantengo."
    else
        local pool_url; pool_url="$(kryptex_pool_url "${KRX_COIN}")"
        if write_conf "${MINEOS_CONFIG}/pools.conf" <<EOF
# mineOS - pool Kryptex per coin=${KRX_COIN} (payout manuale da dashboard)
# Endpoint reale Kryptex (host:porta dipendono dal coin). Vedi pool.kryptex.com.
POOL_URL="${pool_url}"
# Formato: <account>.<worker> (con email: <email>/<worker>).
POOL_USER="${pool_user}"
POOL_PASS="x"
EOF
        then
            log INFO "pools.conf creato (pool=${pool_url} user=${pool_user})."
        else
            log ERROR "pools.conf NON creato."; CONFIG_WRITE_FAILED=1
        fi
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
        if write_conf "${MINEOS_CONFIG}/rig.conf" <<EOF
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
        then
            log INFO "rig.conf creato (miner=${default_miner})."
        else
            log ERROR "rig.conf NON creato."; CONFIG_WRITE_FAILED=1
        fi
    fi

    # Verifica FINALE: i tre file indispensabili devono esistere e non essere vuoti.
    local cf
    for cf in wallet.conf pools.conf rig.conf; do
        [[ -s "${MINEOS_CONFIG}/${cf}" ]] || { log ERROR "Config indispensabile mancante/vuota dopo la scrittura: ${cf}"; CONFIG_WRITE_FAILED=1; }
    done

    if [[ "${CONFIG_WRITE_FAILED}" -ne 0 ]]; then
        log ERROR "Generazione config FALLITA (vedi sopra). L'agent non partira' finche' non sono presenti."
        return 1
    fi

    log INFO "Configurazione pronta in ${MINEOS_CONFIG}."
    log WARN "Verifica POOL_URL in pools.conf con la dashboard Kryptex prima di minare."
    return 0
}

# Copia template OC Pearl/pearlhash se assente.
setup_gpu_oc_config() {
    if [[ -f "${MINEOS_CONFIG}/gpu-oc.conf" ]]; then
        log INFO "gpu-oc.conf già presente."
        return 0
    fi
    if [[ -f "${MINEOS_CONFIG}/gpu-oc.conf.example" ]]; then
        cp "${MINEOS_CONFIG}/gpu-oc.conf.example" "${MINEOS_CONFIG}/gpu-oc.conf"
        chmod 600 "${MINEOS_CONFIG}/gpu-oc.conf"
        log INFO "gpu-oc.conf creato da template (profili Pearl/pearlhash)."
    else
        log WARN "gpu-oc.conf.example mancante: OC automatico non configurato."
    fi
}

# ============================================================================
# STEP 5 - Finalizzazione
# ============================================================================
# Abilita i servizi (NON li avvia). Grazie a WantedBy=multi-user.target
# partiranno da soli a ogni boot; nessuna condizione bloccante li frena
# (l'agent ripulisce da solo il flag reboot-required al proprio avvio).
enable_services() {
    sysctl_safe enable mineos-gpu-oc.service mineos-gpu-fan.service
    sysctl_safe enable mineos-agent.service mineos-watchdog.service
    # Timer profit-switch sempre abilitato: lo script si auto-gate su rig.conf.
    sysctl_safe enable mineos-profit-switch.timer
}

# Avvia il mining adesso (caso "nessun reboot necessario").
start_services_now() {
    sysctl_safe start mineos-gpu-oc.service
    sysctl_safe start mineos-gpu-fan.service
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

# Scrive e mostra a schermo una guida rapida coi comandi utili.
write_quickstart_summary() {
    local f="${MINEOS_STATE}/quickstart.txt"
    umask 077
    cat > "$f" <<'EOF'
============================================================
 mineOS - Primi passi dopo l'installazione
============================================================

VERIFICARE CHE STIA MINANDO
  systemctl status mineos-agent        # stato del miner
  journalctl -u mineos-agent -f        # log live (share, pool)
  Poi controlla che il worker sia ONLINE su https://kryptex.com

HASHRATE E TEMPERATURE GPU
  nvidia-smi                           # temp, potenza, utilizzo GPU
  cat /opt/mineos/state/gpu-inventory.txt   # GPU rilevate
  systemctl status mineos-gpu-fan      # curva ventole

RIAVVIARE / GESTIRE
  sudo systemctl restart mineos-agent  # riavvia il miner
  sudo systemctl restart mineos-watchdog

CAMBIARE COIN / WALLET / OC
  sudo nano /opt/mineos/config/pools.conf   # POOL_URL, POOL_USER
  sudo nano /opt/mineos/config/rig.conf     # MINER, ALGO, limiti
  sudo nano /opt/mineos/config/gpu-oc.conf  # power/clock/ventole
  sudo systemctl restart mineos-agent

SICUREZZA
  passwd                               # CAMBIA la password di default (miner/miner)

AGGIORNAMENTI
  sudo /opt/mineos/bin/update-mineos.sh # OS + driver + miner (con rollback)
============================================================
EOF
    chmod 600 "$f" 2>/dev/null || true
    log INFO "Guida rapida scritta in ${f}."

    # Promemoria a ogni login (console/SSH): mostra i comandi principali.
    cat > /etc/profile.d/mineos-quickstart.sh <<'EOF'
# mineOS - promemoria comandi al login
if [ -t 1 ]; then
  echo
  echo "mineOS  |  stato: systemctl status mineos-agent  |  log: journalctl -u mineos-agent -f"
  echo "        |  GPU: nvidia-smi  |  guida completa: cat /opt/mineos/state/quickstart.txt"
  echo "        |  cambia password: passwd"
  echo
fi
EOF
    chmod 644 /etc/profile.d/mineos-quickstart.sh 2>/dev/null || true

    # Mostra a schermo (tty1) subito dopo il setup.
    echo
    cat "$f" 2>/dev/null || true
    echo
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    bootstrap_dirs
    check_already_done
    ensure_base_tools

    log INFO "=== Inventario GPU hardware (sysfs_pci + lspci + drm + nvidia-smi) ==="
    gpu_detection_report

    local vendor; vendor="$(detect_gpu_vendor)"
    log INFO "GPU vendor rilevato: ${vendor} (count nvidia=$(detect_gpu_count nvidia) amd=$(detect_gpu_count amd))"

    # --- FASE NON INTERATTIVA (deve completare sempre, sopravvive all'HUP) ----
    # driver + miner + dipendenze prima del wizard: se il wizard interattivo
    # viene interrotto, il lavoro pesante e' gia' stato fatto.
    install_drivers "$vendor"

    # Se il driver NVIDIA e' gia' attivo (no reboot), verifica subito che tutte le GPU siano visibili.
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        verify_nvidia_gpu_visibility
    fi

    install_miners "$vendor"

    # --- FASE INTERATTIVA (wizard credenziali; con timeout/default) -----------
    run_wizard

    # --- Scrittura config con VERIFICA (BUG4) --------------------------------
    if ! write_configs "$vendor"; then
        # Riprova una volta: la scrittura potrebbe essere fallita per una causa
        # transitoria. Se fallisce ancora NON marchiamo il first-boot completato
        # (cosi' verra' ritentato) ed usciamo non-zero.
        log WARN "write_configs fallita: riprovo una volta."
        if ! write_configs "$vendor"; then
            log ERROR "Impossibile creare i file di config in ${MINEOS_CONFIG}. First boot NON completato: verra' ritentato al prossimo boot."
            setup_gpu_oc_config
            write_quickstart_summary
            enable_services
            return 1
        fi
    fi

    setup_gpu_oc_config
    write_payout_summary
    write_quickstart_summary

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
