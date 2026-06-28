#!/usr/bin/env bash
#
# /opt/mineos/bin/fix-rig-pearl.sh
#
# mineOS - Fix rig esistente per Pearl su Kryptex
# ------------------------------------------------
# Corregge in un colpo solo i problemi storici su rig gia' installati:
#   - permessi script/binari (203/EXEC, trex/srbminer non eseguibile)
#   - estrazione miner rotta (cartella vuota, symlink current rotto)
#   - algoritmo errato (PRL/RVN invece di pearlhash)
#   - miner sbagliato (trex con pearlhash -> srbminer)
#   - pool Kryptex Pearl (prl.kryptex.network:7048)
#   - errori boot NVIDIA i2c timeout / ucsi_ccg
#   - riavvio servizi systemd
#
# Uso:
#   sudo /opt/mineos/bin/fix-rig-pearl.sh
#   sudo KRX_USERNAME="krxXXXXXX" KRX_WORKER="rig01" fix-rig-pearl.sh
#   sudo fix-rig-pearl.sh --reinstall-miners
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REINSTALL_MINERS=0
for arg in "$@"; do
    case "$arg" in
        --reinstall-miners) REINSTALL_MINERS=1 ;;
        --help|-h)
            echo "Uso: sudo $0 [--reinstall-miners]"
            echo "  --reinstall-miners  forza riscarico SRBMiner (e altri miner del vendor)"
            exit 0
            ;;
        *) die "Argomento sconosciuto: $arg (usa --help)" ;;
    esac
done

fix_nvidia_boot() {
    local vendor; vendor="$(detect_gpu_vendor)"
    case "$vendor" in
        nvidia|both)
            log INFO "Applico fix boot NVIDIA (i2c timeout / ucsi_ccg)..."
            apply_nvidia_boot_fix
            ;;
        *)
            log INFO "Nessuna GPU NVIDIA: salto fix i2c/ucsi."
            ;;
    esac
}

# Alias: stesso fix NVIDIA, esposto anche come script standalone fix-nvidia-boot.sh

fix_permissions() {
    log INFO "Correggo permessi script e cartelle..."
    chmod +x "${MINEOS_BIN}"/*.sh "${MINEOS_BIN}"/lib/*.sh 2>/dev/null || true
    mkdir -p "${MINEOS_CONFIG}" "${MINEOS_STATE}" "${MINEOS_LOGS}" "${MINEOS_MINERS}"
    chmod 700 "${MINEOS_CONFIG}" 2>/dev/null || true
    chmod 755 "${MINEOS_MINERS}" "${MINEOS_STATE}" "${MINEOS_LOGS}" 2>/dev/null || true
}

reinstall_miners() {
    local vendor; vendor="$(detect_gpu_vendor)"
    log INFO "Reinstallo miner per vendor=${vendor}..."
    while IFS='|' read -r name ver url sha mvendor; do
        [[ -z "$name" ]] && continue
        [[ "$mvendor" == "both" || "$mvendor" == "$vendor" || "$vendor" == "both" ]] || continue

        local dest="${MINEOS_MINERS}/${name}/${ver}"
        local link="${MINEOS_MINERS}/${name}/current"

        if [[ "$REINSTALL_MINERS" -eq 0 ]]; then
            # Solo se manca binario o cartella vuota.
            if [[ -L "$link" ]] && find_miner_binary_in_dir "$name" "$link" >/dev/null 2>&1; then
                log INFO "Miner $name OK, salto reinstall."
                continue
            fi
            log WARN "Miner $name mancante o rotto: reinstallo."
        else
            log INFO "Reinstall forzato miner $name $ver..."
            rm -rf "$dest"
        fi

        mkdir -p "$dest"
        local tmp; tmp="$(mktemp -d)"
        if ! curl -fL --retry 3 -o "${tmp}/pkg.tar.gz" "$url"; then
            log ERROR "Download fallito per $name $ver"
            rm -rf "$tmp"; continue
        fi
        if [[ "$sha" != REPLACE_WITH_REAL_SHA256 ]]; then
            verify_sha256 "${tmp}/pkg.tar.gz" "$sha" || { rm -rf "$tmp" "$dest"; continue; }
        fi
        if ! extract_miner_pkg "${tmp}/pkg.tar.gz" "$dest"; then
            log ERROR "Estrazione fallita per $name"
            rm -rf "$tmp" "$dest"; continue
        fi
        rm -rf "$tmp"
        ln -sfn "$dest" "$link"
        if find_miner_binary_in_dir "$name" "$dest" >/dev/null 2>&1; then
            log INFO "Miner $name installato: $(find_miner_binary_in_dir "$name" "$dest")"
        else
            log ERROR "Binario $name non trovato dopo estrazione!"
        fi
    done < <(miner_catalog)
}

fix_config() {
    log INFO "Correggo configurazione Pearl/Kryptex..."
    umask 077
    mkdir -p "${MINEOS_CONFIG}"

    : "${KRX_USERNAME:=}"
    : "${KRX_WORKER:=$(hostname -s 2>/dev/null || echo rig)}"
    : "${KRX_COIN:=prl}"

    # Leggi valori esistenti se presenti (prima di sovrascrivere).
    local saved_user="" saved_worker=""
    if [[ -f "${MINEOS_CONFIG}/wallet.conf" ]]; then
        # shellcheck disable=SC1090
        source "${MINEOS_CONFIG}/wallet.conf"
        saved_user="${KRX_USERNAME:-}"
        saved_worker="${KRX_WORKER:-}"
    fi
    [[ -n "$saved_user" ]] && KRX_USERNAME="$saved_user"
    [[ -n "$saved_worker" ]] && KRX_WORKER="$saved_worker"

    if [[ -z "$KRX_USERNAME" ]]; then
        log WARN "KRX_USERNAME non impostato. Passa: KRX_USERNAME=krxXXXXXX $0"
        KRX_USERNAME="CHANGE_ME"
    fi

    local algo pool_user pool_url
    algo="$(normalize_algo "${KRX_COIN}")"
    pool_user="$(kryptex_pool_user "${KRX_USERNAME}" "${KRX_WORKER}")"
    pool_url="$(kryptex_pool_url "${KRX_COIN}")"
    local miner; miner="$(resolve_miner_for_algo "srbminer" "$algo")"

    # wallet.conf
    cat > "${MINEOS_CONFIG}/wallet.conf" <<EOF
# mineOS - credenziali Kryptex (fix-rig-pearl $(date --iso-8601=seconds))
KRX_USERNAME="${KRX_USERNAME}"
KRX_WORKER="${KRX_WORKER}"
KRX_COIN="prl"
PAYOUT_MODE="manual"
EOF
    chmod 600 "${MINEOS_CONFIG}/wallet.conf"

    # pools.conf
    cat > "${MINEOS_CONFIG}/pools.conf" <<EOF
# mineOS - pool Kryptex Pearl (fix-rig-pearl)
POOL_URL="${pool_url}"
POOL_USER="${pool_user}"
POOL_PASS="x"
EOF
    chmod 600 "${MINEOS_CONFIG}/pools.conf"

    # rig.conf - preserva tuning se esistente
    local power=0 temp=75 core=0 mem=0 wd_min=0 wd_grace=300 profit=false vendor
    vendor="$(detect_gpu_vendor)"
    if [[ -f "${MINEOS_CONFIG}/rig.conf" ]]; then
        # shellcheck disable=SC1090
        source "${MINEOS_CONFIG}/rig.conf"
        : "${GPU_POWER_LIMIT_W:=0}"
        : "${GPU_TEMP_LIMIT_C:=75}"
        : "${GPU_CORE_OFFSET:=0}"
        : "${GPU_MEM_OFFSET:=0}"
        : "${WATCHDOG_HASHRATE_MIN:=0}"
        : "${WATCHDOG_ZERO_GRACE_SEC:=300}"
        : "${PROFIT_SWITCH:=false}"
        power="$GPU_POWER_LIMIT_W"; temp="$GPU_TEMP_LIMIT_C"
        core="$GPU_CORE_OFFSET"; mem="$GPU_MEM_OFFSET"
        wd_min="$WATCHDOG_HASHRATE_MIN"; wd_grace="$WATCHDOG_ZERO_GRACE_SEC"
        profit="$PROFIT_SWITCH"
    fi

    cat > "${MINEOS_CONFIG}/rig.conf" <<EOF
# mineOS - rig Pearl/Kryptex (fix-rig-pearl)
GPU_VENDOR="${vendor}"
MINER="${miner}"
ALGO="${algo}"

GPU_POWER_LIMIT_W="${power}"
GPU_TEMP_LIMIT_C="${temp}"
GPU_CORE_OFFSET="${core}"
GPU_MEM_OFFSET="${mem}"

WATCHDOG_HASHRATE_MIN="${wd_min}"
WATCHDOG_ZERO_GRACE_SEC="${wd_grace}"
PROFIT_SWITCH="${profit}"
EOF
    chmod 600 "${MINEOS_CONFIG}/rig.conf"
    log INFO "Config aggiornata: miner=${miner} algo=${algo} pool=${pool_url}"
}

ensure_first_boot_done() {
    if [[ ! -f "${MINEOS_STATE}/first-boot.done" ]]; then
        log WARN "first-boot.done assente: lo creo (setup gia' eseguito manualmente)."
        mkdir -p "${MINEOS_STATE}"
        date --iso-8601=seconds > "${MINEOS_STATE}/first-boot.done"
    fi
}

restart_services() {
    log INFO "Riavvio servizi mineOS..."
    sysctl_safe daemon-reload
    sysctl_safe enable mineos-agent.service mineos-watchdog.service mineos-profit-switch.timer
    sysctl_safe restart mineos-agent.service
    sysctl_safe restart mineos-watchdog.service
    sleep 3
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet mineos-agent.service; then
            log INFO "mineos-agent ATTIVO."
        else
            log ERROR "mineos-agent NON attivo. Diagnostica:"
            log ERROR "  journalctl -u mineos-agent -e --no-pager"
            return 1
        fi
    fi
}

main() {
    require_root
    log INFO "=== fix-rig-pearl: correzione Pearl/Kryptex ==="
    fix_permissions
    fix_nvidia_boot
    reinstall_miners
    fix_config
    ensure_first_boot_done
    restart_services
    log INFO "=== Fix completato. Verifica worker su dashboard Kryptex. ==="
    echo
    echo "Comandi utili:"
    echo "  systemctl status mineos-agent"
    echo "  journalctl -u mineos-agent -f"
    echo "  journalctl -u mineos-firstboot -e   # se first boot falliva (203/EXEC)"
}

main "$@"
