#!/usr/bin/env bash
#
# build/install.sh
#
# Installer "in-target": eseguito DURANTE l'autoinstall, dentro al sistema
# appena installato (via 'curtin in-target'). Il payload mineOS e' gia' stato
# estratto in / (quindi /opt/mineos e /etc/systemd/system/* esistono).
#
# Compiti:
#   - permessi corretti su script e config
#   - credenziali di default + chiave SSH autorizzata (placeholder)
#   - rete di sicurezza anti-blocco (boot testo, voce GRUB safe, timeout ridotti)
#   - SSH sempre attivo; Tailscale preinstallato (attivazione al primo boot)
#   - reload di systemd e abilitazione dei servizi mineOS
#
# Idempotente: rieseguibile senza effetti collaterali.
#
set -Eeuo pipefail

# Credenziali di DEFAULT (cambiare dopo il primo accesso!).
MINER_USER="miner"
MINER_PASS="miner"

# ---------------------------------------------------------------------------
# Chiave SSH pubblica autorizzata per l'utente 'miner'.
# >>> SOSTITUISCI questo placeholder con la TUA chiave pubblica PRIMA della build
#     (es. contenuto di ~/.ssh/id_ed25519.pub). Se lasci il placeholder, l'accesso
#     via chiave non funzionera' ma resta attivo il login con password (fallback).
# ---------------------------------------------------------------------------
AUTHORIZED_KEY="AUTHORIZED_KEY_PLACEHOLDER"

echo "[mineos-install] Configurazione permessi..."
# Script eseguibili (tutti). Il tar potrebbe non preservare il bit +x: lo
# forziamo qui, ESPLICITAMENTE su ogni script (causa storica del 203/EXEC).
find /opt/mineos/bin -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
chmod +x /opt/mineos/bin/*.sh /opt/mineos/bin/lib/*.sh 2>/dev/null || true
chmod +x /opt/mineos/bin/first-boot-setup.sh /opt/mineos/bin/fix-rig-pearl.sh \
    /opt/mineos/bin/fix-nvidia-boot.sh /opt/mineos/bin/fix-gpu-detect.sh \
    /opt/mineos/bin/apply-gpu-oc.sh /opt/mineos/bin/gpu-fan-daemon.sh \
    /opt/mineos/bin/tailscale-up.sh 2>/dev/null || true
# Verifica bloccante: senza questo script il first boot non parte.
if [[ ! -x /opt/mineos/bin/first-boot-setup.sh ]]; then
    echo "[mineos-install][ERRORE] /opt/mineos/bin/first-boot-setup.sh mancante o non eseguibile." >&2
    exit 1
fi
# Cartelle mineOS. 'config' contiene credenziali (solo root); 'logs' e' scrivibile
# dall'utente miner (l'agent vi scrive: intervento fix cartella log).
mkdir -p /opt/mineos/{config,state,logs,miners,backups}
chmod 700 /opt/mineos/config
chmod 0755 /opt/mineos/state /opt/mineos/miners 2>/dev/null || true
chown "${MINER_USER}:${MINER_USER}" /opt/mineos/logs 2>/dev/null || true
chmod 0755 /opt/mineos/logs 2>/dev/null || true

echo "[mineos-install] Garantisco le credenziali di default per '${MINER_USER}'..."
# L'utente viene gia' creato dall'autoinstall (sezione 'identity'); qui
# rinforziamo la password di default in modo idempotente, se l'utente esiste.
if id "${MINER_USER}" >/dev/null 2>&1; then
    echo "${MINER_USER}:${MINER_PASS}" | chpasswd \
        && echo "[mineos-install] Password di default impostata (CAMBIALA dopo il primo accesso!)." \
        || echo "[mineos-install] AVVISO: impossibile impostare la password (proseguo)."
else
    echo "[mineos-install] Utente '${MINER_USER}' non presente: lo gestisce l'autoinstall."
fi

# ---------------------------------------------------------------------------
# SSH: server attivo + chiave autorizzata (password lasciata come fallback)
# ---------------------------------------------------------------------------
echo "[mineos-install] Configuro SSH (server + chiave autorizzata)..."
# openssh-server dovrebbe esserci gia' (autoinstall). Se manca, prova a installarlo.
if ! dpkg -l openssh-server 2>/dev/null | grep -q '^ii'; then
    env DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server \
        || echo "[mineos-install] AVVISO: openssh-server non installabile ora (verifica rete)."
fi
# Precarica la chiave pubblica per 'miner' (mode 0600, .ssh 0700, owner miner:miner).
if id "${MINER_USER}" >/dev/null 2>&1; then
    MINER_HOME="$(getent passwd "${MINER_USER}" | cut -d: -f6)"
    MINER_HOME="${MINER_HOME:-/home/${MINER_USER}}"
    mkdir -p "${MINER_HOME}/.ssh"
    # Scrive/aggiorna authorized_keys (idempotente: rimpiazza righe mineos precedenti).
    printf '%s\n' "${AUTHORIZED_KEY}" > "${MINER_HOME}/.ssh/authorized_keys"
    chown -R "${MINER_USER}:${MINER_USER}" "${MINER_HOME}/.ssh"
    chmod 0700 "${MINER_HOME}/.ssh"
    chmod 0600 "${MINER_HOME}/.ssh/authorized_keys"
    if [[ "${AUTHORIZED_KEY}" == "AUTHORIZED_KEY_PLACEHOLDER" ]]; then
        echo "[mineos-install] AVVISO: authorized_keys contiene il PLACEHOLDER. Sostituiscilo con la tua chiave in build/install.sh prima della build (login password resta come fallback)."
    fi
fi
# SSH sempre abilitato e attivo il prima possibile (indipendente dal target).
systemctl enable ssh 2>/dev/null || systemctl enable ssh.service 2>/dev/null || true
# NB: PasswordAuthentication resta ABILITATA (fallback). Per irrigidire dopo aver
# caricato la tua chiave:
#   sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
#   sudo systemctl restart ssh

# ---------------------------------------------------------------------------
# Rete di sicurezza anti-blocco: il rig deve restare raggiungibile via SSH
# anche se una GPU/driver NVIDIA si pianta al boot.
# ---------------------------------------------------------------------------
echo "[mineos-install] Applico rete di sicurezza anti-blocco..."
# 1) Boot in modalita' testo/multi-user (nessun display manager grafico).
systemctl set-default multi-user.target 2>/dev/null || true

# 2) Timeout systemd ridotti: un servizio che si appende non blocca il boot 5 min.
if [[ -f /etc/systemd/system.conf ]]; then
    sed -i 's/^#\?DefaultTimeoutStartSec=.*/DefaultTimeoutStartSec=30s/' /etc/systemd/system.conf
    sed -i 's/^#\?DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=30s/' /etc/systemd/system.conf
    grep -q '^DefaultTimeoutStartSec=' /etc/systemd/system.conf || echo 'DefaultTimeoutStartSec=30s' >> /etc/systemd/system.conf
    grep -q '^DefaultTimeoutStopSec='  /etc/systemd/system.conf || echo 'DefaultTimeoutStopSec=30s'  >> /etc/systemd/system.conf
fi

# 3) Voce GRUB "mineOS (safe/recovery)": boot senza driver NVIDIA, multi-user,
#    per garantire l'accesso SSH e riparare se il boot normale si blocca.
ROOT_UUID="$(findmnt -no UUID / 2>/dev/null || true)"
[[ -z "${ROOT_UUID}" ]] && ROOT_UUID="$(blkid -s UUID -o value "$(findmnt -no SOURCE / 2>/dev/null)" 2>/dev/null || true)"
if [[ -n "${ROOT_UUID}" ]]; then
    cat > /etc/grub.d/40_custom <<EOF
#!/bin/sh
exec tail -n +3 \$0
# Voce di RECUPERO mineOS: avvia senza driver NVIDIA (blacklist) in multi-user,
# cosi' il rig resta raggiungibile via SSH anche se una GPU crasha al boot.
menuentry 'mineOS (safe/recovery - no NVIDIA)' --class recovery {
    recordfail
    load_video
    insmod gzio
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /boot/vmlinuz root=UUID=${ROOT_UUID} ro modprobe.blacklist=nvidia,nvidia_drm,nvidia_uvm,nvidia_modeset systemd.unit=multi-user.target nomodeset
    initrd /boot/initrd.img
}
EOF
    chmod +x /etc/grub.d/40_custom
    # Menu visibile per qualche secondo cosi' la voce safe e' selezionabile.
    if [[ -f /etc/default/grub ]]; then
        sed -i 's/^#\?GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
        grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub || echo 'GRUB_TIMEOUT_STYLE=menu' >> /etc/default/grub
        sed -i 's/^#\?GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
    fi
    update-grub 2>/dev/null || echo "[mineos-install] AVVISO: update-grub fallito (verra' rigenerato al first boot)."
else
    echo "[mineos-install] AVVISO: UUID root non determinato: salto voce GRUB safe (riprovo al first boot)."
fi

# ---------------------------------------------------------------------------
# Tailscale: preinstallato, servizio abilitato, ma NESSUN 'up' in build.
# ---------------------------------------------------------------------------
echo "[mineos-install] Installo Tailscale (senza attivarlo)..."
if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh \
        || echo "[mineos-install] AVVISO: installazione Tailscale fallita (verra' ritentata? no: installala a mano o rete assente)."
fi
if command -v tailscale >/dev/null 2>&1; then
    systemctl enable tailscaled 2>/dev/null || true
    echo "[mineos-install] Tailscale installato. Attivazione al primo boot via /opt/mineos/config/tailscale.key"
fi

# ---------------------------------------------------------------------------
# Fix boot NVIDIA i2c/ucsi (modprobe) - blacklist innocua per rig headless.
# ---------------------------------------------------------------------------
echo "[mineos-install] Fix boot NVIDIA i2c/ucsi (modprobe)..."
if [[ -f /etc/modprobe.d/mineos-nvidia-i2c.conf ]]; then
    echo "[mineos-install] modprobe.d mineOS presente nel payload."
else
    cat > /etc/modprobe.d/mineos-nvidia-i2c.conf <<'EOF'
blacklist i2c_nvidia_gpu
blacklist ucsi_ccg
install i2c_nvidia_gpu /bin/false
install ucsi_ccg /bin/false
EOF
    cat > /etc/modprobe.d/mineos-nvidia.conf <<'EOF'
options nvidia NVreg_EnableUsbPd=0
EOF
fi
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u \
        && echo "[mineos-install] initramfs aggiornato (fix i2c NVIDIA)." \
        || echo "[mineos-install] AVVISO: update-initramfs fallito (proseguo)."
fi
# Blacklist precoce via kernel cmdline (multi-GPU mining).
if [[ -f /etc/default/grub ]] && ! grep -q 'modprobe.blacklist=i2c_nvidia_gpu' /etc/default/grub 2>/dev/null; then
    sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT=".*\)"/\1 modprobe.blacklist=i2c_nvidia_gpu modprobe.blacklist=ucsi_ccg"/' /etc/default/grub \
        && echo "[mineos-install] GRUB: blacklist i2c/ucsi aggiunta." \
        || echo "[mineos-install] AVVISO: patch GRUB fallita (proseguo)."
    if command -v update-grub >/dev/null 2>&1; then
        update-grub \
            && echo "[mineos-install] GRUB aggiornato." \
            || echo "[mineos-install] AVVISO: update-grub fallito (proseguo)."
    fi
fi

echo "[mineos-install] Reload systemd e abilitazione servizi..."
systemctl daemon-reload

# mineos-firstboot gira al primo avvio (rilevamento GPU, driver, wizard).
# agent e watchdog vengono abilitati subito; l'agent parte a ogni boot e fallisce
# con messaggio chiaro se manca la config (nessuna ConditionPathExists bloccante).
# Il watchdog attende first-boot.done (ConditionPathExists nel suo unit file).
systemctl enable mineos-gpu-oc.service mineos-gpu-fan.service 2>/dev/null || true
systemctl enable mineos-firstboot.service
systemctl enable mineos-agent.service
systemctl enable mineos-watchdog.service
# Attivazione Tailscale al primo boot (idempotente, salta se manca la key).
systemctl enable mineos-tailscale.service 2>/dev/null || true
# Timer profit-switch: sicuro da abilitare sempre (lo script si auto-gate su rig.conf).
systemctl enable mineos-profit-switch.timer

echo "[mineos-install] Completato."
