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
# Script eseguibili (tutti). Il tar potrebbe non preservare il bit +x: lo
# forziamo qui, ESPLICITAMENTE su ogni script (causa storica del 203/EXEC).
find /opt/mineos/bin -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
chmod +x /opt/mineos/bin/*.sh /opt/mineos/bin/lib/*.sh 2>/dev/null || true
chmod +x /opt/mineos/bin/first-boot-setup.sh /opt/mineos/bin/fix-rig-pearl.sh 2>/dev/null || true
# Verifica bloccante: senza questo script il first boot non parte.
if [[ ! -x /opt/mineos/bin/first-boot-setup.sh ]]; then
    echo "[mineos-install][ERRORE] /opt/mineos/bin/first-boot-setup.sh mancante o non eseguibile." >&2
    exit 1
fi
# La cartella config contiene credenziali: accesso solo root.
mkdir -p /opt/mineos/{config,state,logs,miners,backups}
chmod 700 /opt/mineos/config
chmod 755 /opt/mineos/miners /opt/mineos/state /opt/mineos/logs 2>/dev/null || true

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
# agent e watchdog vengono abilitati subito; l'agent parte a ogni boot e fallisce
# con messaggio chiaro se manca la config (nessuna ConditionPathExists bloccante).
# Il watchdog attende first-boot.done (ConditionPathExists nel suo unit file).
systemctl enable mineos-firstboot.service
systemctl enable mineos-agent.service
systemctl enable mineos-watchdog.service
# Timer profit-switch: sicuro da abilitare sempre (lo script si auto-gate su rig.conf).
systemctl enable mineos-profit-switch.timer

echo "[mineos-install] Completato."
