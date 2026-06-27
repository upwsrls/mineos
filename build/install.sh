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
#   - reload di systemd e abilitazione dei servizi mineOS
#
# Idempotente: rieseguibile senza effetti collaterali.
#
set -Eeuo pipefail

echo "[mineos-install] Configurazione permessi..."
# Script eseguibili.
chmod +x /opt/mineos/bin/*.sh /opt/mineos/bin/lib/*.sh 2>/dev/null || true
# La cartella config contiene credenziali: accesso solo root.
mkdir -p /opt/mineos/{config,state,logs,miners,backups}
chmod 700 /opt/mineos/config

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
