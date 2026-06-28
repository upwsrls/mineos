#!/usr/bin/env bash
#
# /opt/mineos/bin/fix-gpu-detect.sh
#
# mineOS - Fix rilevamento multi-GPU
# -----------------------------------
# Enumera GPU via sysfs_pci, lspci, sysfs_drm, nvidia-smi.
# Se hardware > driver (es. mancano RTX 3090 / GTX 1080 in nvidia-smi):
#   - rescan bus PCI
#   - GRUB pci=realloc (BAR multi-GPU)
#   - report in state/gpu-inventory.txt
#
# Uso:
#   sudo /opt/mineos/bin/fix-gpu-detect.sh
#   sudo /opt/mineos/bin/fix-gpu-detect.sh --rescan-only
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

RESCAN_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --rescan-only) RESCAN_ONLY=1 ;;
        --help|-h)
            cat <<'EOF'
Uso: sudo fix-gpu-detect.sh [--rescan-only]

Diagnostica e fix rilevamento multi-GPU NVIDIA/AMD.
EOF
            exit 0
            ;;
        *) die "Argomento sconosciuto: $arg" ;;
    esac
done

main() {
    require_root
    mkdir -p "${MINEOS_STATE}" "${MINEOS_LOGS}" 2>/dev/null || true

    log INFO "=== fix-gpu-detect ==="
    gpu_detection_report

    if [[ "$RESCAN_ONLY" -eq 1 ]]; then
        gpu_rescan_pci_bus
        verify_nvidia_gpu_visibility
        exit 0
    fi

    local vendor; vendor="$(detect_gpu_vendor)"
    log INFO "Vendor: ${vendor} | GPU totali=$(detect_gpu_count all)"

    case "$vendor" in
        nvidia|both)
            verify_nvidia_gpu_visibility
            apply_multigpu_grub_fix
            ;;
        *)
            log INFO "Nessuna GPU NVIDIA: verifica completata (inventario in state/gpu-inventory.txt)."
            ;;
    esac

    echo
    echo "Inventario salvato in: ${MINEOS_STATE}/gpu-inventory.txt"
    echo "Confronta con: nvidia-smi -L"
    echo "Se mancano GPU: abilita Above 4G Decoding in BIOS, poi: sudo reboot"
}

main "$@"
