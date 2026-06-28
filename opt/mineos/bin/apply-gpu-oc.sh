#!/usr/bin/env bash
#
# /opt/mineos/bin/apply-gpu-oc.sh
#
# mineOS - Overclock automatico multi-GPU NVIDIA (Pearl/pearlhash)
# ---------------------------------------------------------------
# Applica profili per modello (RTX 3090, GTX 1080 Ti, GTX 1080, GTX 1660...):
#   - power limit (nvidia-smi -pl)
#   - core clock lock (nvidia-smi --lock-gpu-clocks)
#   - memory clock lock (offset su max memory)
#   - ventola iniziale + curva (via gpu-fan-daemon se abilitato)
#
# Config: /opt/mineos/config/gpu-oc.conf (da gpu-oc.conf.example)
#
# Uso:
#   sudo /opt/mineos/bin/apply-gpu-oc.sh
#   sudo /opt/mineos/bin/apply-gpu-oc.sh --dry-run
#   sudo /opt/mineos/bin/apply-gpu-oc.sh --reset
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

OC_CONF="${MINEOS_CONFIG}/gpu-oc.conf"
RESET=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) export DRY_RUN=1 ;;
        --reset)   RESET=1 ;;
        --help|-h)
            cat <<'EOF'
Uso: sudo apply-gpu-oc.sh [--dry-run] [--reset]

  --reset    ripristina clock/potenza default NVIDIA
EOF
            exit 0
            ;;
        *) die "Argomento sconosciuto: $arg (usa --help)" ;;
    esac
done

# Match nome GPU -> chiave profilo (ordine: modelli piu' specifici prima).
gpu_model_key() {
    local name="${1,,}"
    if   [[ "$name" == *"3090"* ]];       then printf 'rtx_3090'
    elif [[ "$name" == *"1080 ti"* ]];   then printf 'gtx_1080_ti'
    elif [[ "$name" == *"1080"* ]];       then printf 'gtx_1080'
    elif [[ "$name" == *"1660 super"* ]]; then printf 'gtx_1660_super'
    elif [[ "$name" == *"1660 ti"* ]];   then printf 'gtx_1660_ti'
    elif [[ "$name" == *"1660"* ]];       then printf 'gtx_1660'
    else printf 'default'
    fi
}

# Carica profilo MODEL_KEY -> variabili PL_W, CORE_MHZ, MEM_OFF, TEMP_TARGET, ...
load_profile() {
    local key="$1"
    PL_W="" CORE_MHZ="" MEM_OFF="" TEMP_TARGET=""
    FAN_MIN="" FAN_MAX="" TEMP_LO="" TEMP_HI=""
    local line k
    for line in "${PROFILES[@]:-}"; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r k PL_W CORE_MHZ MEM_OFF TEMP_TARGET FAN_MIN FAN_MAX TEMP_LO TEMP_HI <<< "$line"
        [[ "$k" == "$key" ]] && return 0
    done
    # Fallback default
    for line in "${PROFILES[@]:-}"; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r k PL_W CORE_MHZ MEM_OFF TEMP_TARGET FAN_MIN FAN_MAX TEMP_LO TEMP_HI <<< "$line"
        [[ "$k" == "default" ]] && return 0
    done
    return 1
}

# Interpolazione lineare fan % in base a temperatura.
fan_percent_for_temp() {
    local temp="$1" lo="$2" hi="$3" fmin="$4" fmax="$5"
    awk -v t="$temp" -v lo="$lo" -v hi="$hi" -v fmin="$fmin" -v fmax="$fmax" \
        'BEGIN{
            if (t+0 <= lo+0) { printf "%d", fmin; exit }
            if (t+0 >= hi+0) { printf "%d", fmax; exit }
            pct=fmin + (t-lo)*(fmax-fmin)/(hi-lo)
            if (pct<fmin) pct=fmin; if (pct>fmax) pct=fmax
            printf "%d", pct+0.5
        }'
}

load_oc_conf() {
    GPU_AUTO_OC="true"
    FAN_DAEMON="true"
    FAN_POLL_SEC="15"
    OC_ALGO="pearlhash"
    PROFILES=(
        "rtx_3090|280|1350|800|65|45|100|52|72"
        "gtx_1080_ti|150|1550|450|62|40|100|48|70"
        "gtx_1080|130|1500|400|62|40|100|48|70"
        "gtx_1660_super|85|1320|550|58|35|95|44|66"
        "gtx_1660_ti|80|1320|650|58|35|95|44|66"
        "gtx_1660|75|1260|450|58|35|95|44|66"
        "default|100|1200|0|65|40|100|50|75"
    )
    if [[ -f "$OC_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$OC_CONF"
    elif [[ -f "${MINEOS_CONFIG}/gpu-oc.conf.example" ]]; then
        log WARN "gpu-oc.conf assente: uso gpu-oc.conf.example."
        # shellcheck disable=SC1090
        source "${MINEOS_CONFIG}/gpu-oc.conf.example"
    else
        log WARN "gpu-oc.conf assente: uso profili incorporati."
    fi
}

reset_gpu() {
    local idx="$1"
    log INFO "GPU ${idx}: reset clock/potenza default."
    if [[ "${DRY_RUN:-0}" == "1" ]]; then return 0; fi
    nvidia-smi -i "$idx" --reset-gpu-clocks    >/dev/null 2>&1 || true
    nvidia-smi -i "$idx" --reset-memory-clocks >/dev/null 2>&1 || true
    nvidia-smi -i "$idx" -rac                   >/dev/null 2>&1 || true
}

apply_one_gpu() {
    local idx="$1" name="$2" key
    key="$(gpu_model_key "$name")"
    load_profile "$key" || { log WARN "GPU ${idx} (${name}): profilo non trovato, salto."; return 1; }

    log INFO "GPU ${idx} [${name}] profilo=${key} PL=${PL_W}W core=${CORE_MHZ}MHz mem+${MEM_OFF}MHz target=${TEMP_TARGET}C"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log INFO "DRY_RUN: salto applicazione hardware GPU ${idx}."
        return 0
    fi

    # Persistence mode (stabilita' 24/7).
    nvidia-smi -i "$idx" -pm 1 >/dev/null 2>&1 || log WARN "GPU ${idx}: persistence mode non applicato."

    # Power limit.
    if [[ -n "$PL_W" && "$PL_W" != "0" ]]; then
        if ! nvidia-smi -i "$idx" -pl "$PL_W" >/dev/null 2>&1; then
            log WARN "GPU ${idx}: power limit ${PL_W}W rifiutato (prova valore piu' basso)."
        fi
    fi

    # Memory clock: max + offset, con fallback a valore assoluto se offset fallisce.
    local max_mem target_mem
    max_mem="$(nvidia-smi -i "$idx" --query-gpu=clocks.max.memory --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')"
    if [[ -n "$max_mem" && "$max_mem" =~ ^[0-9]+$ && -n "$MEM_OFF" ]]; then
        target_mem=$(( max_mem + MEM_OFF ))
        if ! nvidia-smi -i "$idx" --lock-memory-clocks="$target_mem" >/dev/null 2>&1; then
            log WARN "GPU ${idx}: lock mem ${target_mem}MHz fallito, provo max=${max_mem}."
            nvidia-smi -i "$idx" --lock-memory-clocks="$max_mem" >/dev/null 2>&1 \
                || log WARN "GPU ${idx}: lock memory non supportato su questo driver/GPU."
        fi
    fi

    # Core clock lock (min=max per clock fisso mining).
    if [[ -n "$CORE_MHZ" && "$CORE_MHZ" != "0" ]]; then
        if ! nvidia-smi -i "$idx" --lock-gpu-clocks="$CORE_MHZ","$CORE_MHZ" >/dev/null 2>&1; then
            log WARN "GPU ${idx}: lock core ${CORE_MHZ}MHz fallito (driver/GPU limit)."
        fi
    fi

    # Ventola iniziale dalla curva alla temperatura attuale.
    local temp fan_pct
    temp="$(nvidia-smi -i "$idx" --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')"
    [[ "$temp" =~ ^[0-9]+$ ]] || temp="$TEMP_LO"
    fan_pct="$(fan_percent_for_temp "$temp" "$TEMP_LO" "$TEMP_HI" "$FAN_MIN" "$FAN_MAX")"
    if nvidia-smi -i "$idx" --fan-speed="$fan_pct" >/dev/null 2>&1; then
        log INFO "GPU ${idx}: ventola ${fan_pct}% (temp=${temp}C curva ${TEMP_LO}-${TEMP_HI}C)."
    else
        log WARN "GPU ${idx}: controllo ventola non disponibile (alcune GPU richiedono coolbits/X)."
    fi

    # Stato per fan daemon e diagnostica.
    umask 077
    cat > "${MINEOS_STATE}/gpu-oc-${idx}.env" <<EOF
MODEL_KEY="${key}"
GPU_NAME="${name}"
PL_W="${PL_W}"
CORE_MHZ="${CORE_MHZ}"
MEM_OFFSET_MHZ="${MEM_OFF}"
TEMP_TARGET="${TEMP_TARGET}"
FAN_MIN="${FAN_MIN}"
FAN_MAX="${FAN_MAX}"
TEMP_LO="${TEMP_LO}"
TEMP_HI="${TEMP_HI}"
EOF
}

apply_all() {
    command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi non trovato."
    nvidia-smi -L >/dev/null 2>&1 || die "Driver NVIDIA non attivo."

    local idx name
    while IFS=',' read -r idx name; do
        idx="${idx// /}"
        name="${name# }"
        [[ -n "$idx" ]] || continue
        apply_one_gpu "$idx" "$name" || true
    done < <(nvidia-smi --query-gpu=index,name --format=csv,noheader,nounits 2>/dev/null)

    # Aggiorna rig.conf con temp target piu' restrittivo tra le GPU (per watchdog).
    if [[ -f "${MINEOS_CONFIG}/rig.conf" && "${DRY_RUN:-0}" != "1" ]]; then
        local min_target=75 t f
        for f in "${MINEOS_STATE}"/gpu-oc-*.env; do
            [[ -f "$f" ]] || continue
            # shellcheck disable=SC1090
            source "$f"
            [[ -n "${TEMP_TARGET:-}" && "$TEMP_TARGET" -lt "$min_target" ]] && min_target="$TEMP_TARGET"
        done
        set_conf_value "${MINEOS_CONFIG}/rig.conf" GPU_TEMP_LIMIT_C "$min_target" 2>/dev/null || true
    fi

    log INFO "OC applicato. Riepilogo:"
    nvidia-smi --query-gpu=index,name,power.limit,clocks.current.graphics,clocks.current.memory,temperature.gpu,fan.speed \
        --format=csv 2>/dev/null | tee -a "${MINEOS_LOGS}/mineos.log" >&2 || true
}

reset_all() {
    command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi non trovato."
    local idx
    while read -r idx; do
        reset_gpu "$idx"
    done < <(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null)
    rm -f "${MINEOS_STATE}"/gpu-oc-*.env 2>/dev/null || true
    log INFO "Reset OC completato su tutte le GPU."
}

main() {
    require_root
    mkdir -p "${MINEOS_STATE}" "${MINEOS_LOGS}" 2>/dev/null || true
    load_oc_conf

    if [[ "$RESET" -eq 1 ]]; then
        reset_all
        exit 0
    fi

    if [[ "${GPU_AUTO_OC:-false}" != "true" ]]; then
        log INFO "GPU_AUTO_OC disabilitato in gpu-oc.conf. Esco."
        exit 0
    fi

    log INFO "=== apply-gpu-oc (algo=${OC_ALGO:-pearlhash}) ==="
    apply_all

    if [[ "${FAN_DAEMON:-true}" == "true" && "${DRY_RUN:-0}" != "1" ]]; then
        sysctl_safe restart mineos-gpu-fan.service 2>/dev/null \
            || log INFO "Avvia manualmente: systemctl start mineos-gpu-fan.service"
    fi
}

main "$@"
