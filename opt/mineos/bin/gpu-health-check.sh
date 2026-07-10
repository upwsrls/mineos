#!/usr/bin/env bash
#
# /opt/mineos/bin/gpu-health-check.sh
#
# mineOS - Isolamento GPU in errore (anti-crash OpenCL/CUDA)
# ---------------------------------------------------------
# Se anche una sola GPU va in "RmInitAdapter failed" (es. Blackwell non
# supportata dal branch installato, o scheda con contatto instabile),
# l'enumerazione OpenCL/CUDA puo' crollare e il miner non parte per NESSUNA
# scheda. Questo helper individua le GPU REALMENTE inizializzate dal driver
# (nvidia-smi) e le confronta con quelle presenti sul bus PCI (lspci):
#   - logga le anomalie in /opt/mineos/logs/gpu-health.log;
#   - stampa su STDOUT la lista (CSV) degli index GPU SANI, da passare al miner
#     cosi' si mina solo sulle GPU funzionanti invece di far fallire tutto.
#
# STDOUT = solo la CSV degli id sani (es. "0,1,3"). Tutto il resto va nel log.
# Non fallisce mai (exit 0) e non interrompe il boot.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || {
    MINEOS_ROOT="/opt/mineos"; MINEOS_LOGS="${MINEOS_ROOT}/logs"
}

HEALTH_LOG="${MINEOS_LOGS}/gpu-health.log"
mkdir -p "${MINEOS_LOGS}" 2>/dev/null || true
hlog() { printf '%s %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)" "$*" >> "${HEALTH_LOG}" 2>/dev/null || true; }

# Normalizza un bus id PCI a forma "DDDD:BB:DD.F" minuscola.
_norm_bus() {
    local b="${1,,}"; b="${b// /}"
    case "$b" in
        [0-9a-f]*:*:*.*) : ;;                    # gia' con dominio
        [0-9a-f]*:*.*)   b="0000:${b}" ;;        # senza dominio -> aggiungi 0000
    esac
    printf '%s' "$b"
}

main() {
    # GPU NVIDIA presenti sul bus PCI (hardware reale).
    local -a pci_bus=()
    if command -v lspci >/dev/null 2>&1; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            pci_bus+=( "$(_norm_bus "$(awk '{print $1}' <<< "$line")")" )
        done < <(lspci -D -nn 2>/dev/null | grep -iE 'VGA compatible controller|3D controller' | grep -i 'NVIDIA')
    fi

    # GPU inizializzate dal driver (nvidia-smi): index + bus id.
    local -a smi_idx=() smi_bus=()
    local healthy=""
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        while IFS=',' read -r idx bus; do
            idx="${idx// /}"; bus="$(_norm_bus "$bus")"
            [[ -z "$idx" ]] && continue
            smi_idx+=( "$idx" ); smi_bus+=( "$bus" )
        done < <(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader,nounits 2>/dev/null)
        healthy="$(IFS=,; echo "${smi_idx[*]}")"
    else
        hlog "nvidia-smi non disponibile o driver non attivo: impossibile determinare GPU sane."
        printf '%s' ""
        return 0
    fi

    local pci_n="${#pci_bus[@]}" smi_n="${#smi_idx[@]}"
    hlog "GPU su bus PCI (NVIDIA)=${pci_n}, GPU inizializzate (nvidia-smi)=${smi_n}. Sane: [${healthy}]"

    # Anomalia: hardware presente ma NON inizializzato dal driver.
    if (( pci_n > smi_n )); then
        hlog "ANOMALIA: ${pci_n} GPU sul bus ma solo ${smi_n} inizializzate. Cerco le mancanti."
        local b found m
        for b in "${pci_bus[@]}"; do
            found=0
            for m in "${smi_bus[@]}"; do [[ "$b" == "$m" ]] && { found=1; break; }; done
            if (( found == 0 )); then
                hlog "  GPU NON inizializzata su bus ${b} (scheda difettosa/non supportata: la escludo dal mining)."
            fi
        done
        # Diagnostica kernel: RmInitAdapter / Xid nei log.
        if command -v dmesg >/dev/null 2>&1; then
            local d
            d="$(dmesg 2>/dev/null | grep -iE 'RmInitAdapter|NVRM.*failed|Xid' | tail -5 || true)"
            [[ -n "$d" ]] && hlog "dmesg (ultimi errori NVIDIA): $(printf '%s' "$d" | tr '\n' '|')"
        fi
    fi

    if [[ -z "$healthy" ]]; then
        hlog "NESSUNA GPU sana rilevata da nvidia-smi: il miner non ricevera' una device-list (verra' usata l'enumerazione di default)."
    fi

    # STDOUT: solo la CSV degli id sani (consumata da mineos-agent).
    printf '%s' "$healthy"
    return 0
}

main "$@"
