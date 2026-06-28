#!/usr/bin/env bash
#
# /opt/mineos/bin/fix-nvidia-boot.sh
#
# mineOS - Fix boot NVIDIA i2c timeout / ucsi_ccg (-110)
# -------------------------------------------------------
# Elimina i messaggi al boot:
#   nvidia-gpu 0000:XX:00.3: i2c timeout error e0000000
#   ucsi_ccg N-0008: i2c_transfer failed -110
#   ucsi_ccg N-0008: ucsi_ccg_init failed -110
#
# Applica blacklist moduli + opzioni NVIDIA + initramfs + GRUB.
# Innocuo per mining CUDA: USB-C/PD non serve su rig headless.
#
# Uso:
#   sudo /opt/mineos/bin/fix-nvidia-boot.sh
#   sudo /opt/mineos/bin/fix-nvidia-boot.sh --dry-run
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

for arg in "$@"; do
    case "$arg" in
        --dry-run) export DRY_RUN=1 ;;
        --help|-h)
            cat <<'EOF'
Uso: sudo fix-nvidia-boot.sh [--dry-run]

Applica il fix per errori boot NVIDIA i2c/ucsi_ccg e richiede reboot.
EOF
            exit 0
            ;;
        *) die "Argomento sconosciuto: $arg" ;;
    esac
done

main() {
    require_root
    local vendor; vendor="$(detect_gpu_vendor)"
    case "$vendor" in
        nvidia|both) ;;
        *)
            log WARN "Nessuna GPU NVIDIA rilevata (${vendor}): il fix e' innocuo ma probabilmente non necessario."
            ;;
    esac

    log INFO "=== fix-nvidia-boot: blacklist i2c_nvidia_gpu / ucsi_ccg ==="
    apply_nvidia_boot_fix

    echo
    echo "Fix applicato. REBOOT obbligatorio per eliminare i messaggi al boot:"
    echo "  sudo reboot"
    echo
    echo "Dopo il reboot verifica:"
    echo "  nvidia-smi -L"
    echo "  dmesg | grep -Ei 'i2c timeout|ucsi_ccg'   # deve essere vuoto"
}

main "$@"
