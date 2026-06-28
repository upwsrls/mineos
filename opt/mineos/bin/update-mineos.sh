#!/usr/bin/env bash
#
# /opt/mineos/bin/update-mineos.sh
#
# mineOS - Updater
# ----------------
# Aggiorna in modo idempotente e sicuro l'intero stack mineOS:
#   1. Backup della configurazione (sempre, prima di toccare qualunque cosa).
#   2. Aggiornamento del sistema operativo (apt/dnf/pacman).
#   3. Aggiornamento dei driver GPU (NVIDIA + AMD).
#   4. Aggiornamento dei miner: download nuove versioni, swap del symlink
#      "current", smoke-test, e ROLLBACK automatico se il nuovo binario fallisce.
#
# Sicurezza:
#   - Lock file: niente esecuzioni concorrenti.
#   - Ferma i servizi di mining prima dell'update e li riavvia alla fine.
#   - DRY_RUN=1 mostra cosa farebbe senza modificare nulla.
#   - --force ignora la finestra "già aggiornato di recente".
#
# Uso:
#   sudo ./update-mineos.sh [--force] [--os-only] [--miners-only] [--drivers-only]
#   sudo DRY_RUN=1 ./update-mineos.sh
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ----------------------------------------------------------------------------
# Parsing argomenti
# ----------------------------------------------------------------------------
FORCE=0
DO_OS=1; DO_DRIVERS=1; DO_MINERS=1
for arg in "$@"; do
    case "$arg" in
        --force)        FORCE=1 ;;
        --os-only)      DO_OS=1; DO_DRIVERS=0; DO_MINERS=0 ;;
        --drivers-only) DO_OS=0; DO_DRIVERS=1; DO_MINERS=0 ;;
        --miners-only)  DO_OS=0; DO_DRIVERS=0; DO_MINERS=1 ;;
        *) die "Argomento sconosciuto: $arg" ;;
    esac
done

LOCK_FILE="${MINEOS_STATE}/update.lock"
LAST_RUN_FLAG="${MINEOS_STATE}/last-update"
MIN_INTERVAL_SEC=$((6 * 3600))   # non rifare un update completo entro 6h salvo --force
SERVICES=(mineos-agent.service mineos-watchdog.service)

trap 'log ERROR "update-mineos fallito alla riga $LINENO (comando: $BASH_COMMAND)"' ERR

# ----------------------------------------------------------------------------
# Lock: evita esecuzioni concorrenti (es. cron + manuale)
# ----------------------------------------------------------------------------
acquire_lock() {
    mkdir -p "${MINEOS_STATE}"
    # flock su descrittore dedicato: rilasciato automaticamente all'uscita.
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        die "Un altro update è già in corso (${LOCK_FILE})."
    fi
    log INFO "Lock acquisito (${LOCK_FILE})."
}

# Rispetta la finestra minima tra update completi (idempotenza "temporale").
check_interval() {
    [[ "$FORCE" -eq 1 ]] && return 0
    [[ -f "$LAST_RUN_FLAG" ]] || return 0
    local last now delta
    last="$(cat "$LAST_RUN_FLAG" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    delta=$(( now - last ))
    if (( delta < MIN_INTERVAL_SEC )); then
        log INFO "Ultimo update ${delta}s fa (< ${MIN_INTERVAL_SEC}s). Uso --force per forzare. Esco."
        exit 0
    fi
}

# ----------------------------------------------------------------------------
# Gestione servizi di mining intorno all'update
# ----------------------------------------------------------------------------
stop_mining() {
    log INFO "Arresto servizi di mining prima dell'update..."
    for s in "${SERVICES[@]}"; do sysctl_safe stop "$s"; done
}

start_mining() {
    log INFO "Riavvio servizi di mining..."
    for s in "${SERVICES[@]}"; do sysctl_safe start "$s"; done
}

# ----------------------------------------------------------------------------
# STEP 1 - Backup configurazione
# ----------------------------------------------------------------------------
backup_config() {
    mkdir -p "${MINEOS_BACKUPS}"
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local dest="${MINEOS_BACKUPS}/config-${ts}.tar.gz"
    if [[ -d "${MINEOS_CONFIG}" && -n "$(ls -A "${MINEOS_CONFIG}" 2>/dev/null)" ]]; then
        log INFO "Backup configurazione -> ${dest}"
        if [[ "${DRY_RUN:-0}" != "1" ]]; then
            tar -czf "${dest}" -C "${MINEOS_ROOT}" config
            chmod 600 "${dest}"
        fi
        echo "${dest}" > "${MINEOS_STATE}/last-config-backup"
        # Retention: tieni solo gli ultimi 10 backup.
        if [[ "${DRY_RUN:-0}" != "1" ]]; then
            ls -1t "${MINEOS_BACKUPS}"/config-*.tar.gz 2>/dev/null | tail -n +11 | xargs -r rm -f
        fi
    else
        log WARN "Nessuna configurazione da salvare in ${MINEOS_CONFIG}."
    fi
}

# ----------------------------------------------------------------------------
# STEP 2 - Aggiornamento sistema operativo
# ----------------------------------------------------------------------------
update_os() {
    local pm; pm="$(detect_pkg_mgr)"
    log INFO "Aggiornamento sistema operativo ($pm)..."
    case "$pm" in
        apt)
            run apt-get update -y
            run env DEBIAN_FRONTEND=noninteractive apt-get -y \
                -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold upgrade
            run env DEBIAN_FRONTEND=noninteractive apt-get -y autoremove
            ;;
        dnf)    run dnf -y upgrade --refresh ;;
        pacman) run pacman -Syu --noconfirm ;;
        *) die "Package manager non supportato per l'update OS." ;;
    esac
    # Un kernel nuovo può richiedere reboot: segnala se la versione attiva differisce.
    if [[ -d /lib/modules ]]; then
        local running newest
        running="$(uname -r)"
        newest="$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -1)"
        if [[ -n "$newest" && "$newest" != "$running" ]]; then
            log WARN "Kernel aggiornato ($running -> $newest): reboot consigliato."
            mark_reboot_required
        fi
    fi
}

# ----------------------------------------------------------------------------
# STEP 3 - Aggiornamento driver GPU
# ----------------------------------------------------------------------------
update_nvidia_driver() {
    local pm; pm="$(detect_pkg_mgr)"
    log INFO "Aggiornamento driver NVIDIA..."
    case "$pm" in
        apt)
            # Aggiorna i pacchetti nvidia già installati (no cambio major automatico).
            run env DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade \
                "$(dpkg -l 'nvidia-driver-*' 2>/dev/null | awk '/^ii/{print $2}' | head -1)" \
                || log WARN "Nessun pacchetto nvidia-driver da aggiornare via apt."
            ;;
        dnf)    run dnf -y upgrade 'akmod-nvidia*' 'xorg-x11-drv-nvidia*' || log WARN "Niente da aggiornare (NVIDIA/dnf)." ;;
        pacman) run pacman -S --noconfirm nvidia nvidia-utils || log WARN "Niente da aggiornare (NVIDIA/pacman)." ;;
        *) log WARN "Update driver NVIDIA non supportato su $pm." ;;
    esac
    # Il modulo nuovo si carica solo dopo reboot.
    mark_reboot_required
}

update_amd_driver() {
    local pm; pm="$(detect_pkg_mgr)"
    log INFO "Aggiornamento stack OpenCL AMD..."
    case "$pm" in
        apt)    run env DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade \
                    mesa-opencl-icd ocl-icd-libopencl1 clinfo || log WARN "Niente da aggiornare (AMD/apt)." ;;
        dnf)    run dnf -y upgrade 'mesa-libOpenCL*' clinfo ocl-icd || log WARN "Niente da aggiornare (AMD/dnf)." ;;
        pacman) run pacman -S --noconfirm opencl-mesa clinfo ocl-icd || log WARN "Niente da aggiornare (AMD/pacman)." ;;
        *) log WARN "Update stack AMD non supportato su $pm." ;;
    esac
}

update_drivers() {
    local vendor; vendor="$(detect_gpu_vendor)"
    log INFO "Vendor GPU rilevato: $vendor"
    case "$vendor" in
        nvidia) update_nvidia_driver ;;
        amd)    update_amd_driver ;;
        both)   update_nvidia_driver; update_amd_driver ;;
        none)   log WARN "Nessuna GPU rilevata: salto update driver." ;;
    esac
}

# ----------------------------------------------------------------------------
# STEP 4 - Aggiornamento miner (con rollback)
# ----------------------------------------------------------------------------
# Il catalogo miner (NOME|VERSIONE|URL|SHA256|VENDOR) è centralizzato in
# common.sh (miner_catalog), fonte unica per first-boot e update.

# Restituisce la versione attualmente puntata da "current" (o vuoto).
current_miner_version() {
    local name="$1" link="${MINEOS_MINERS}/$1/current"
    [[ -L "$link" ]] && basename "$(readlink -f "$link")" || echo ""
}

# Smoke-test: il binario deve almeno rispondere a --help/--version senza crashare.
smoke_test_miner() {
    local name="$1" dir="$2"

    # Stesso fix di find_miner_binary: accetta sia la cartella-versione sia il
    # symlink 'current'. In modalità -P (default) 'find <symlink> -type f' NON
    # entra nella cartella puntata -> nessun binario trovato. Risolvi prima.
    if [[ -L "$dir" ]]; then
        dir="$(readlink -f "$dir" 2>/dev/null || echo "$dir")"
    fi
    [[ -d "$dir" ]] || { log WARN "Cartella miner inesistente per $name: $dir"; return 1; }

    # Selezione binario robusta: prima i nomi noti, poi fallback al primo
    # eseguibile. '-print -quit' evita la fragilità di 'find | head' (SIGPIPE
    # con pipefail) e si ferma al primo risultato.
    local -a candidates=()
    case "$name" in
        trex)     candidates=(t-rex T-Rex) ;;
        lolminer) candidates=(lolMiner lolminer) ;;
        srbminer) candidates=(SRBMiner-MULTI SRBMiner-Multi srbminer) ;;
    esac
    local bin="" cand
    for cand in "${candidates[@]}"; do
        [[ -x "${dir}/${cand}" ]] && { bin="${dir}/${cand}"; break; }
    done
    if [[ -z "$bin" ]]; then
        bin="$(find -L "$dir" -maxdepth 1 -type f -perm -u+x -print -quit 2>/dev/null)"
    fi
    [[ -n "$bin" ]] || { log WARN "Nessun binario eseguibile trovato in $dir per $name."; return 1; }
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log INFO "DRY_RUN: salto smoke-test di $name."
        return 0
    fi
    # Timeout per evitare che un binare interattivo blocchi l'update.
    if timeout 20 "$bin" --help >/dev/null 2>&1 || timeout 20 "$bin" --version >/dev/null 2>&1; then
        log INFO "Smoke-test OK: $name ($bin)."
        return 0
    fi
    log WARN "Smoke-test FALLITO: $name ($bin)."
    return 1
}

update_one_miner() {
    local name="$1" ver="$2" url="$3" sha="$4"
    local base="${MINEOS_MINERS}/${name}"
    local dest="${base}/${ver}"
    local link="${base}/current"
    local prev; prev="$(current_miner_version "$name")"

    # "Già aggiornato" solo se la versione coincide E il binario esiste davvero
    # (una vecchia estrazione rotta lasciava la cartella vuota: in quel caso
    # NON saltare, va riscaricato).
    if [[ "$prev" == "$ver" && -d "$dest" \
          && -n "$(find -L "$dest" -maxdepth 1 -type f -perm -u+x -print -quit 2>/dev/null)" ]]; then
        log INFO "Miner $name già alla versione $ver (binario presente). Niente da fare."
        return 0
    fi

    log INFO "Aggiorno $name: ${prev:-<nessuna>} -> ${ver}"
    mkdir -p "$dest"
    local tmp; tmp="$(mktemp -d)"
    # Download del nuovo pacchetto.
    if ! run curl -fL --retry 3 -o "${tmp}/pkg.tar.gz" "$url"; then
        log ERROR "Download fallito per $name $ver. Mantengo la versione attuale."
        rm -rf "$tmp" "$dest"
        return 1
    fi
    # Verifica integrità (salta solo se placeholder o DRY_RUN).
    if [[ "$sha" != REPLACE_WITH_REAL_SHA256 && "${DRY_RUN:-0}" != "1" ]]; then
        if ! ( verify_sha256 "${tmp}/pkg.tar.gz" "$sha" ); then
            log ERROR "Checksum errato per $name $ver. Abort update di questo miner."
            rm -rf "$tmp" "$dest"
            return 1
        fi
    else
        log WARN "Checksum non verificato per $name (placeholder o DRY_RUN)."
    fi
    # Estrazione robusta (indipendente dal layout dell'archivio).
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log INFO "DRY_RUN: salto estrazione di $name $ver."
    elif ! extract_miner_pkg "${tmp}/pkg.tar.gz" "$dest"; then
        log ERROR "Estrazione fallita per $name $ver. Mantengo la versione attuale."
        rm -rf "$tmp" "$dest"
        return 1
    fi
    rm -rf "$tmp"

    # Swap atomico del symlink "current" verso la nuova versione.
    local prev_target=""
    [[ -L "$link" ]] && prev_target="$(readlink -f "$link")"
    run ln -sfn "$dest" "$link"

    # Smoke-test: se fallisce, ROLLBACK al precedente.
    if ! smoke_test_miner "$name" "$dest"; then
        log ERROR "Nuova versione $name $ver non valida: eseguo ROLLBACK."
        if [[ -n "$prev_target" && -d "$prev_target" ]]; then
            run ln -sfn "$prev_target" "$link"
            log INFO "Rollback a $(basename "$prev_target") completato."
        else
            log ERROR "Nessuna versione precedente valida per il rollback di $name!"
        fi
        # Rimuovi la versione difettosa per non sprecare spazio.
        [[ "${DRY_RUN:-0}" != "1" ]] && rm -rf "$dest"
        return 1
    fi

    log INFO "Miner $name aggiornato a $ver con successo."
    # Retention: tieni current + le 2 versioni più recenti.
    if [[ "${DRY_RUN:-0}" != "1" ]]; then
        local keep; keep="$(basename "$(readlink -f "$link")")"
        ls -1dt "${base}"/*/ 2>/dev/null \
            | grep -v "/current/\?$" \
            | sed -n '3,$p' \
            | while read -r old; do
                [[ "$(basename "$old")" == "$keep" ]] && continue
                log INFO "Rimuovo vecchia versione $name: $old"
                rm -rf "$old"
              done
    fi
}

update_miners() {
    local vendor; vendor="$(detect_gpu_vendor)"
    local failed=0
    while IFS='|' read -r name ver url sha mvendor; do
        [[ -z "$name" ]] && continue
        if [[ "$mvendor" == "both" || "$mvendor" == "$vendor" || "$vendor" == "both" ]]; then
            update_one_miner "$name" "$ver" "$url" "$sha" || failed=1
        fi
    done < <(miner_catalog)
    [[ "$failed" -eq 0 ]] || log WARN "Almeno un miner non è stato aggiornato (vedi log)."
}

# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------
main() {
    require_root
    acquire_lock
    check_interval

    log INFO "=== mineOS update avviato (FORCE=$FORCE DRY_RUN=${DRY_RUN:-0}) ==="

    backup_config            # sempre, prima di tutto

    stop_mining
    # I servizi vanno riavviati anche se l'update fallisce a metà.
    trap 'start_mining' EXIT

    [[ "$DO_OS"      -eq 1 ]] && update_os
    [[ "$DO_DRIVERS" -eq 1 ]] && update_drivers
    [[ "$DO_MINERS"  -eq 1 ]] && update_miners

    date +%s > "$LAST_RUN_FLAG"
    log INFO "=== mineOS update completato ==="

    if [[ -f "${MINEOS_STATE}/reboot-required" ]]; then
        log WARN "REBOOT richiesto per applicare kernel/driver nuovi."
        notify UPDATE_DONE "Aggiornamento completato. REBOOT richiesto per kernel/driver nuovi."
    else
        notify UPDATE_DONE "Aggiornamento completato con successo."
    fi
}

main "$@"
