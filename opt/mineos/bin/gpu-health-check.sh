#!/usr/bin/env bash
#
# /opt/mineos/bin/gpu-health-check.sh
#
# mineOS - Isolamento GPU in errore (anti-crash OpenCL/CUDA)
# ---------------------------------------------------------
# Se anche una sola GPU va in "RmInitAdapter failed" (es. Blackwell non
# supportata dal branch installato, o scheda con contatto instabile),
# l'enumerazione OpenCL/CUDA puo' crollare e il miner non parte per NESSUNA
# scheda. Questo helper individua le GPU sane in DUE livelli:
#   1) DRIVER: GPU realmente inizializzate da nvidia-smi vs presenti su lspci;
#   2) OpenCL: se 'clinfo' e' disponibile, verifica che la piattaforma NVIDIA si
#      inizializzi (clinfo -l elenca device NVIDIA, niente "Number of platforms 0"
#      / errori). Alcune Blackwell sono viste da nvidia-smi ma fanno crollare
#      OpenCL: in tal caso proviamo a isolare la GPU colpevole testando una device
#      alla volta (CUDA_VISIBLE_DEVICES) ed escludendola.
# Risultato: si mina solo sulle GPU funzionanti invece di far fallire tutto.
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

# L'output di clinfo mostra una piattaforma NVIDIA utilizzabile?
# 0 = OpenCL NVIDIA OK; 1 = errore/vuoto.
_clinfo_output_ok() {
    local out="$1"
    grep -qi 'Number of platforms 0' <<< "$out" && return 1
    grep -qi 'nvidia' <<< "$out" || return 1
    return 0
}

# Livello 2: verifica OpenCL (clinfo). Riceve la CSV degli id sani da nvidia-smi,
# stampa su stdout la CSV eventualmente ridotta (solo GPU OpenCL-sane). Diagnostica
# nel log. Se clinfo non c'e', ritorna la lista invariata. Idempotente.
opencl_refine() {
    local healthy_csv="$1"
    command -v clinfo >/dev/null 2>&1 || { printf '%s' "$healthy_csv"; return 0; }
    [[ -z "$healthy_csv" ]] && { printf '%s' "$healthy_csv"; return 0; }

    local out rc
    out="$(timeout 30 clinfo -l 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]] && _clinfo_output_ok "$out"; then
        hlog "OpenCL OK: piattaforma NVIDIA inizializzata (clinfo -l elenca device NVIDIA)."
        printf '%s' "$healthy_csv"; return 0
    fi

    # clinfo fallisce/vuoto MENTRE nvidia-smi vede le GPU -> anomalia OpenCL.
    hlog "ANOMALIA OpenCL: 'clinfo -l' fallito o senza device NVIDIA (rc=${rc}) mentre nvidia-smi vede le GPU."
    hlog "  clinfo -l (estratto): $(tr '\n' '|' <<< "$out" | cut -c1-400)"
    hlog "Isolo la GPU che fa crashare OpenCL: test una device alla volta (CUDA_VISIBLE_DEVICES)."

    local -a ids good=() bad=()
    IFS=',' read -ra ids <<< "$healthy_csv"
    local id o2 r2
    for id in "${ids[@]}"; do
        [[ -z "$id" ]] && continue
        # CUDA_DEVICE_ORDER=PCI_BUS_ID allinea l'indice CUDA a quello di nvidia-smi;
        # l'OpenCL NVIDIA rispetta CUDA_VISIBLE_DEVICES per mascherare le altre GPU.
        o2="$(CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES="$id" timeout 20 clinfo -l 2>&1)"; r2=$?
        if [[ $r2 -eq 0 ]] && _clinfo_output_ok "$o2"; then
            good+=( "$id" )
        else
            bad+=( "$id" )
            hlog "  GPU idx ${id}: OpenCL FALLITO (rc=${r2}) -> esclusa dal mining."
        fi
    done

    if [[ ${#good[@]} -gt 0 ]]; then
        [[ ${#bad[@]} -gt 0 ]] && \
            hlog "GPU escluse per crash OpenCL: [$(IFS=,; echo "${bad[*]}")]. GPU OpenCL-sane: [$(IFS=,; echo "${good[*]}")]."
        printf '%s' "$(IFS=,; echo "${good[*]}")"
        return 0
    fi

    # Nessuna device supera il test isolato: o il masking non e' efficace, o la GPU
    # colpevole crasha comunque. Non blocchiamo il mining: segnaliamo e teniamo la
    # lista di nvidia-smi, lasciando l'ultima parola al miner.
    hlog "Impossibile isolare con certezza la GPU colpevole del crash OpenCL (CUDA_VISIBLE_DEVICES inefficace?): mantengo la lista nvidia-smi [${healthy_csv}]."
    printf '%s' "$healthy_csv"
    return 0
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
        printf '%s' ""
        return 0
    fi

    # Livello 2 - OpenCL: alcune GPU sono viste da nvidia-smi ma fanno crollare
    # l'inizializzazione OpenCL (clinfo). Raffiniamo escludendo quelle colpevoli.
    healthy="$(opencl_refine "$healthy")"

    # STDOUT: solo la CSV degli id sani (consumata da mineos-agent).
    printf '%s' "$healthy"
    return 0
}

main "$@"
