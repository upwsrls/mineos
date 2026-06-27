#!/usr/bin/env bash
#
# init-git.sh
#
# Inizializza il repository git di mineOS in modo pulito e sicuro:
#   - crea il repo (branch 'main') se non esiste gia'
#   - crea .gitignore e .gitattributes se mancanti
#   - sanity check: blocca il commit se rileva credenziali tracciabili
#   - aggiunge i file rilevanti ed esegue il commit iniziale
#   - stampa istruzioni finali (remote/push) e i prossimi passi
#
# Idempotente: se il repo esiste gia', NON reinizializza e committa solo se
# ci sono modifiche.
#
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

command -v git >/dev/null || { red "git non installato."; exit 1; }

# ===========================================================================
# 1. Inizializza il repo se assente
# ===========================================================================
if [[ -d .git ]]; then
    yellow "Repository git gia' presente: non reinizializzo."
else
    green "Inizializzo il repository git (branch main)..."
    git init -b main >/dev/null 2>&1 \
        || { git init >/dev/null; git checkout -b main >/dev/null 2>&1 || true; }
fi

# ===========================================================================
# 2. Crea .gitignore e .gitattributes se mancanti
# ===========================================================================
if [[ ! -f .gitignore ]]; then
    green "Creo .gitignore..."
    cat > .gitignore <<'EOF'
# Artefatti di build
/dist/
/build/work/
*.iso
*.tar.gz

# Credenziali e configurazione runtime (NON committare)
opt/mineos/config/*.conf
!opt/mineos/config/*.conf.example

# Dati di runtime
opt/mineos/logs/
opt/mineos/state/
opt/mineos/miners/
opt/mineos/backups/

# Log generici
*.log

# Sistema operativo / editor
.DS_Store
Thumbs.db
*.swp
*~
.idea/
.vscode/
EOF
else
    yellow ".gitignore gia' presente: lo lascio invariato."
fi

if [[ ! -f .gitattributes ]]; then
    green "Creo .gitattributes..."
    cat > .gitattributes <<'EOF'
# Normalizzazione line ending: LF nel repository (gli script girano su Linux).
* text=auto eol=lf
*.sh        text eol=lf
*.service   text eol=lf
*.timer     text eol=lf
Makefile    text eol=lf
user-data   text eol=lf
meta-data   text eol=lf
*.conf      text eol=lf
*.example   text eol=lf

# Binari: nessuna conversione.
*.iso       binary
*.tar.gz    binary
*.gz        binary
*.img       binary
EOF
else
    yellow ".gitattributes gia' presente: lo lascio invariato."
fi

# ===========================================================================
# 3. Sanity check: niente credenziali in staging
# ===========================================================================
# Anche se .gitignore le esclude, verifichiamo prima del commit. Match solo i
# file reali *.conf, NON i template *.conf.example.
green "Sanity check credenziali..."
LEAK="$(git ls-files --cached --others --exclude-standard 2>/dev/null \
        | grep -E 'opt/mineos/config/(wallet|pools|rig|telegram|profit-switch)\.conf$' || true)"
if [[ -n "$LEAK" ]]; then
    red "ATTENZIONE: rilevati file di config reali tracciabili:"
    red "$LEAK"
    red "Rimuovili dallo staging o verifica .gitignore prima di committare. Interrompo."
    exit 1
fi
green "OK: nessuna credenziale in staging."

# ===========================================================================
# 4. Aggiungi i file rilevanti
# ===========================================================================
green "Aggiungo i file (rispettando .gitignore)..."
git add -A

green "File in staging:"
git status --short

# ===========================================================================
# 5. Commit iniziale (solo se c'e' qualcosa da committare)
# ===========================================================================
if git diff --cached --quiet; then
    yellow "Niente da committare: working tree pulito."
else
    if git rev-parse --verify HEAD >/dev/null 2>&1; then
        MSG="chore: aggiornamento file di progetto mineOS"
    else
        MSG="$(cat <<'EOF'
Initial commit: mineOS

Sistema di mining GPU su pool Kryptex con miner nativi Linux.
Include: script core (first-boot, agent, watchdog, updater, profit-switch),
notifiche Telegram, unit/timer systemd, toolchain di build ISO
(autoinstall/cloud-init), Makefile, README e template di configurazione.
EOF
)"
    fi
    git commit -m "$MSG" >/dev/null
    green "Commit creato:"
    git log --oneline -1
fi

# ===========================================================================
# 6. Istruzioni finali + messaggio di completamento
# ===========================================================================
cat <<'NOTE'

------------------------------------------------------------------
Collegare un remote e fare push:
  git remote add origin <URL-del-tuo-repo>
  git push -u origin main

Gestione credenziali:
  - wallet/pools/rig/telegram/profit-switch.conf NON sono versionati.
  - Nel repo restano solo i template *.conf.example.
  - Sul rig, i file reali vengono generati dal wizard di first-boot.
------------------------------------------------------------------
NOTE

printf '\n\033[1;32m'
cat <<'DONE'
==================================================================
                  ✅  PROGETTO mineOS COMPLETATO
==================================================================
DONE
printf '\033[0m'

cat <<'STEPS'
Prossimi passi consigliati:

  1. BUILD & TEST
     - Su un host Linux: `make iso` per generare l'immagine.
     - Flasha una USB e testa l'installazione su un rig (o in VM
       senza GPU per validare il flusso, poi su hardware reale).

  2. PRIMO AVVIO
     - Completa il wizard Kryptex (username/worker/coin).
     - Verifica `systemctl status mineos-agent` e il worker online
       nella dashboard Kryptex.

  3. CONFIGURAZIONE OPZIONALE
     - Notifiche Telegram: crea config/telegram.conf.
     - Profit-switch: config/profit-switch.conf + PROFIT_SWITCH="true".

  4. SICUREZZA & MANUTENZIONE
     - Cambia la password di default dell'utente 'miner'.
     - Verifica impianto elettrico, PSU e raffreddamento (mining 24/7).
     - Imposta backup periodici della cartella config/.
     - Pianifica gli aggiornamenti (cron di update-mineos.sh).

Buon mining! ⛏️
STEPS
