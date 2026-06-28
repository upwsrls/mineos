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
#   - garantisce le credenziali di default (utente 'miner' / password 'miner')
#   - reload di systemd e abilitazione dei servizi mineOS
#
# Idempotente: rieseguibile senza effetti collaterali.
#
set -Eeuo pipefail

# Credenziali di DEFAULT (cambiare dopo il primo accesso!).
MINER_USER="miner"
MINER_PASS="miner"

echo "[mineos-install] Configurazione permessi..."
# Script eseguibili.
chmod +x /opt/mineos/bin/*.sh /opt/mineos/bin/lib/*.sh 2>/dev/null || true
# La cartella config contiene credenziali: accesso solo root.
mkdir -p /opt/mineos/{config,state,logs,miners,backups}
chmod 700 /opt/mineos/config

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

echo "[mineos-install] Reload systemd e abilitazione servizi..."
systemctl daemon-reload

# mineos-firstboot gira al primo avvio (rilevamento GPU, driver, wizard).
# agent e watchdog vengono abilitati ma partiranno solo dopo il first boot
# (hanno ConditionPathExists su first-boot.done).
systemctl enable mineos-firstboot.service
systemctl enable mineos-agent.service
systemctl enable mineos-watchdog.service
# Timer profit-switch: sicuro da abilitare sempre (lo script si auto-gate su rig.conf).
systemctl enable mineos-profit-switch.timer

echo "[mineos-install] Completato."
