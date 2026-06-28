#!/usr/bin/env bash
#
# /opt/mineos/bin/gpu-fan-daemon.sh
#
# mineOS - Curva ventole GPU NVIDIA (daemon)
# ------------------------------------------
# Legge gpu-oc-*.env generati da apply-gpu-oc.sh e regola la ventola ogni N secondi
# in base alla temperatura (curva lineare TEMP_LO..TEMP_HI -> FAN_MIN..FAN_MAX).
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

OC_CONF="${MINEOS_CONFIG}/gpu-oc.conf"
POLL_SEC=15

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

load_poll_interval() {
    POLL_SEC=15
    [[ -f "$OC_CONF" ]] && source "$OC_CONF" 2>/dev/null || true
    [[ -n "${FAN_POLL_SEC:-}" ]] && POLL_SEC="$FAN_POLL_SEC"
}

apply_fan_curve_once() {
    local f idx temp target fan_pct cur_fan
    shopt -s nullglob
    local files=( "${MINEOS_STATE}"/gpu-oc-*.env )
    [[ "${#files[@]}" -gt 0 ]] || { log WARN "Nessun gpu-oc-*.env: esegui apply-gpu-oc.sh prima."; return 0; }

    for f in "${files[@]}"; do
        # shellcheck disable=SC1090
        source "$f"
        idx="${f##*/gpu-oc-}"; idx="${idx%.env}"
        temp="$(nvidia-smi -i "$idx" --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')"
        [[ "$temp" =~ ^[0-9]+$ ]] || continue
        fan_pct="$(fan_percent_for_temp "$temp" "${TEMP_LO:-50}" "${TEMP_HI:-75}" "${FAN_MIN:-40}" "${FAN_MAX:-100}")"
        cur_fan="$(nvidia-smi -i "$idx" --query-gpu=fan.speed --format=csv,noheader,nounits 2>/dev/null | tr -d ' %')"
        [[ "$cur_fan" =~ ^[0-9]+$ ]] || cur_fan=0
        # Evita micro-regolazioni (±3%).
        if (( fan_pct > cur_fan + 3 || fan_pct + 3 < cur_fan )); then
            if nvidia-smi -i "$idx" --fan-speed="$fan_pct" >/dev/null 2>&1; then
                log INFO "GPU ${idx} (${MODEL_KEY:-?}): temp=${temp}C fan ${cur_fan}% -> ${fan_pct}% (target ${TEMP_TARGET:-?}C)."
            fi
        fi
    done
}

main() {
    require_root
    command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi non trovato."
    load_poll_interval
    log INFO "Fan daemon avviato (poll=${POLL_SEC}s, config=${OC_CONF})."
    trap 'log INFO "Fan daemon stop."; exit 0' SIGTERM SIGINT

    while true; do
        apply_fan_curve_once || log WARN "Ciclo fan non riuscito."
        sleep "$POLL_SEC"
    done
}

main "$@"
