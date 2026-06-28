# mineOS

**Sistema operativo minimale per mining GPU su pool Kryptex, basato su Ubuntu Server 24.04 e miner nativi Linux.**

mineOS trasforma un PC con GPU NVIDIA o AMD in un rig di mining headless, stabile e gestibile da remoto. Non usa il client Windows di Kryptex tramite Wine (approccio fragile e inefficiente): usa invece i **miner nativi Linux** (T-Rex, lolMiner, SRBMiner) puntati direttamente sullo **stratum di Kryptex** con le tue credenziali. Stesso payout, performance piena, stabilità da rig vero.

---

## Indice

- [Perché nativo e non Wine](#perché-nativo-e-non-wine)
- [Funzionalità principali](#funzionalità-principali)
- [Requisiti hardware](#requisiti-hardware)
- [Architettura](#architettura)
- [Struttura delle cartelle](#struttura-delle-cartelle)
- [Build dell'ISO](#build-delliso)
- [Flash su USB](#flash-su-usb)
- [Primo avvio e configurazione](#primo-avvio-e-configurazione)
- [Aggiornamenti](#aggiornamenti)
- [Gestione e comandi utili](#gestione-e-comandi-utili)
- [Notifiche Telegram](#notifiche-telegram)
- [Profit-switch automatico](#profit-switch-automatico)
- [Troubleshooting](#troubleshooting)
- [Sicurezza e avvertenze](#sicurezza-e-avvertenze)
- [Licenza e disclaimer](#licenza-e-disclaimer)

---

## Perché nativo e non Wine

Il "miner" di Kryptex è in realtà un **launcher Windows** che orchestra backend di terze parti (T-Rex, lolMiner, NBMiner, XMRig...) e ti paga sul **pool Kryptex**. Far girare quel launcher su Linux via Wine significa attraversare lo stack GPU compute (CUDA/OpenCL) nel punto in cui Wine è più debole: risultato instabile, spesso non avviabile, e senza alcun vantaggio.

mineOS salta il launcher e usa gli **stessi backend, ma nativi Linux**, puntati allo stratum Kryptex con `username.worker`. Ottieni:

- supporto GPU nativo (CUDA/OpenCL reali),
- hashrate pieno, nessun overhead di traduzione,
- stabilità 24/7,
- controllo totale su watchdog, tuning e aggiornamenti.

L'unica cosa che perdi è la GUI e l'auto-switch automatico del client (replicabili separatamente).

---

## Funzionalità principali

- **Installazione non presidiata** — un'unica USB installa Ubuntu, inietta mineOS, abilita i servizi e riavvia.
- **First boot guidato** — rilevamento automatico GPU (NVIDIA/AMD), installazione driver corretti, wizard CLI per le credenziali Kryptex, download automatico dei miner.
- **Mining agent** (`mineos-agent`) — lancia il miner giusto con i parametri corretti, abilita l'API HTTP locale, gestisce il graceful shutdown.
- **Watchdog 24/7** (`mineos-watchdog`) — monitora hashrate, temperature e GPU bloccate; riavvia il miner o, nei casi gravi, l'intero sistema.
- **Updater con rollback** (`update-mineos`) — aggiorna OS, driver e miner; verifica i checksum, fa smoke-test e torna alla versione precedente se il nuovo binario fallisce. Backup automatico della configurazione.
- **Notifiche Telegram** (opzionali) — avvisi in tempo reale su eventi chiave (avvio mining, hashrate basso, temperatura critica, reboot, aggiornamenti). Se non configurate, vengono saltate silenziosamente.
- **Profit-switch automatico** (opzionale) — confronta periodicamente la profittabilità degli algoritmi (WhatToMine, con fallback statico) e passa al più redditizio oltre una soglia di isteresi. Disattivato di default.
- **Robustezza** — script idempotenti, `DRY_RUN` ovunque, logging strutturato su journald e su file.

---

## Requisiti hardware

| Componente      | Minimo                              | Consigliato                                  |
|-----------------|-------------------------------------|----------------------------------------------|
| GPU             | 1× NVIDIA (Maxwell+) o AMD (GCN+)   | NVIDIA RTX / AMD RDNA con buona efficienza   |
| VRAM            | 4 GB                                | 8 GB+ (alcuni algoritmi richiedono più VRAM) |
| CPU             | Dual-core x86-64                    | Qualsiasi quad-core                          |
| RAM             | 4 GB                                | 8 GB                                         |
| Storage         | SSD/USB 16 GB                       | SSD 64 GB+ (durata e affidabilità)           |
| Alimentatore    | Adeguato al carico GPU + margine    | PSU 80+ Gold con margine ≥ 30%               |
| Rete            | Ethernet                            | Ethernet cablata (più stabile del Wi-Fi)     |

> **Host di build** (per generare l'ISO): una macchina **Linux** con `xorriso` e `wget`. La build dell'ISO non funziona su macOS/Windows.

---

## Architettura

```
USB autoinstall
   │  (installa Ubuntu + inietta payload)
   ▼
Ubuntu Server 24.04 (headless)
   │
   ├─ mineos-firstboot.service  → driver GPU + wizard + download miner   (1 volta)
   ├─ mineos-agent.service      → miner nativo → stratum Kryptex          (sempre)
   └─ mineos-watchdog.service   → hashrate/temp/GPU hang → restart/reboot (sempre)

   update-mineos.sh             → OS + driver + miner, con rollback       (on demand / cron)
```

Il miner espone un'API HTTP locale (solo loopback) che il watchdog interroga per leggere l'hashrate in tempo reale.

---

## Struttura delle cartelle

```text
mineos/
├── README.md
├── opt/mineos/                       # → installato in /opt/mineos sul rig
│   ├── bin/
│   │   ├── lib/common.sh             # libreria condivisa (log, helper, detect)
│   │   ├── first-boot-setup.sh       # setup primo avvio (driver, wizard, miner)
│   │   ├── update-mineos.sh          # updater con rollback
│   │   ├── mineos-agent.sh           # avvia il miner
│   │   └── watchdog.sh               # monitoraggio 24/7
│   ├── config/                       # rig.conf, wallet.conf, pools.conf (chmod 700)
│   ├── miners/                       # binari miner versionati + symlink "current"
│   ├── state/                        # flag di stato, agent.env, lock
│   ├── logs/                         # mineos.log
│   └── backups/                      # backup config (creati dall'updater)
├── etc/systemd/system/              # → installato in /etc/systemd/system sul rig
│   ├── mineos-firstboot.service
│   ├── mineos-agent.service
│   └── mineos-watchdog.service
└── build/                            # toolchain per generare l'ISO (gira su Linux)
    ├── autoinstall/
    │   ├── user-data                 # cloud-init / autoinstall + network config
    │   └── meta-data
    ├── install.sh                    # installer in-target (abilita i servizi)
    └── build-iso.sh                  # genera l'ISO personalizzata
```

### File di configurazione (generati al first boot in `/opt/mineos/config/`)

| File          | Contenuto                                              |
|---------------|-------------------------------------------------------|
| `wallet.conf` | `KRX_USERNAME`, `KRX_WORKER`, `KRX_COIN`, `PAYOUT_MODE` (`manual`) |
| `pools.conf`  | `POOL_URL`, `POOL_USER`, `POOL_PASS`                  |
| `rig.conf`    | vendor GPU, miner, algoritmo, limiti termici/potenza, soglie watchdog |

---

## Build dell'ISO

> Da eseguire su un **host Linux**.

### 1. Installa i prerequisiti

```bash
sudo apt-get update && sudo apt-get install -y xorriso wget
```

### 2. (Opzionale) Cambia la password di default

L'immagine ha credenziali di **default**: utente `miner` / password `miner`.

> ⚠️ **Cambia la password dopo il primo accesso** (`passwd`), oppure personalizzala già in fase di build generando un nuovo hash SHA-512 e sostituendo il campo `identity.password` in `build/autoinstall/user-data`:

```bash
openssl passwd -6 'LaTuaPasswordSicura'
# oppure:  mkpasswd -m sha-512
```

### 3. (Consigliato) Compila i placeholder di produzione

- **Checksum miner**: il catalogo miner (versione/URL/SHA256) è centralizzato in
  `opt/mineos/bin/lib/common.sh` (`miner_catalog`) con SHA256 reali dalle release ufficiali.
  Per aggiornare un miner, cambia insieme versione+URL+SHA256 in quell'unico punto.
- **Endpoint Kryptex**: l'`POOL_URL` viene generato dal first boot tramite `kryptex_pool_url`
  (mappa coin→host:porta reali di Kryptex). Host e porta variano per coin
  (es. `prl:7048`, `rvn:7031`, `etc:7033`, `erg:7021`, `kas:7011`).
- **Pearl (PRL)**: di default mineOS mina **Pearl** (`prl`, algoritmo `pearlhash`) con
  **SRBMiner-MULTI** (selezionato automaticamente per `pearlhash` su NVIDIA/AMD).
- **Payout MANUALE**: mineOS **non** automatizza payout né conversioni. Il saldo si accumula
  sul tuo account Kryptex e i prelievi si eseguono **a mano dalla dashboard** `kryptex.com`
  (`PAYOUT_MODE="manual"` in `wallet.conf`; riepilogo in `state/payout.txt`).

### 4. Genera l'ISO

Dalla root del progetto puoi usare il Makefile:

```bash
make iso        # genera l'ISO (scarica l'ISO Ubuntu se assente)
make rebuild    # rebuild pulito: clean + payload + iso (consigliato dopo modifiche)
```

Oppure direttamente lo script:

```bash
cd mineos/build
./build-iso.sh
# Scarica l'ISO ufficiale Ubuntu (se assente), inietta tutto e produce:
#   mineos-24.04.2-autoinstall-amd64.iso
```

Se hai già l'ISO ufficiale:

```bash
./build-iso.sh /percorso/ubuntu-24.04.2-live-server-amd64.iso
```

---

## Flash su USB

> ⚠️ **`dd` scrive a basso livello: se sbagli device cancelli il disco indicato. Controlla due volte.**

### Linux

```bash
lsblk                      # individua il DISCO USB (es. /dev/sdb), non una partizione
sudo dd if=mineos-24.04.2-autoinstall-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
sync
```

### macOS

```bash
diskutil list                          # individua /dev/diskN
diskutil unmountDisk /dev/diskN
sudo dd if=mineos-24.04.2-autoinstall-amd64.iso of=/dev/rdiskN bs=4m
```

In alternativa puoi usare strumenti grafici come **balenaEtcher**.

---

## Primo avvio e configurazione

1. Inserisci l'USB nel rig e avvia da USB (**UEFI** consigliato).
2. L'installer parte **automaticamente** (timeout GRUB di pochi secondi), installa Ubuntu in modo non presidiato, inietta mineOS e riavvia.
3. Al primo boot reale, su schermo (`tty1`), parte il **wizard Kryptex**:
   - **Nome rig** e **nome worker**.
   - **Coin** da minare (ticker, default **`prl`** = Pearl/`pearlhash`; es. anche `rvn`, `kas`).
   - **Username/Wallet Kryptex** usato come "wallet" nel miner (Mining Username `krxXXXXXX`,
     email o wallet della moneta).
   - **Payout**: **MANUALE** dalla dashboard Kryptex. mineOS non automatizza prelievi né
     conversioni: il saldo si accumula su Kryptex e prelevi quando vuoi da `kryptex.com`.
4. mineOS rileva la GPU, installa i driver, scarica i miner e genera la configurazione.
5. Se sono stati installati i driver NVIDIA, viene richiesto un **reboot**; dopo il riavvio il mining parte da solo.

> 🔑 **Login di default**: utente `miner` / password `miner` (via console o SSH). **Cambiala subito** con `passwd`.

> 💡 **Serve un monitor collegato** al primo avvio, perché il wizard è interattivo su `tty1`.
> Per deployment headless/fleet puoi pre-compilare le credenziali in `user-data` o usare
> `first-boot-setup.sh --noninteractive` con un env file.

### Verificare che stia minando

```bash
systemctl status mineos-agent
journalctl -u mineos-agent -f          # log live del miner
```

Controlla poi che il **worker** compaia online nella dashboard Kryptex.

---

## Aggiornamenti

L'updater aggiorna sistema operativo, driver GPU e miner in un colpo solo, in sicurezza.

```bash
# Aggiornamento completo
sudo /opt/mineos/bin/update-mineos.sh

# Anteprima senza modificare nulla
sudo DRY_RUN=1 /opt/mineos/bin/update-mineos.sh

# Forza anche se aggiornato di recente
sudo /opt/mineos/bin/update-mineos.sh --force

# Aggiornamenti mirati
sudo /opt/mineos/bin/update-mineos.sh --miners-only
sudo /opt/mineos/bin/update-mineos.sh --drivers-only
sudo /opt/mineos/bin/update-mineos.sh --os-only
```

Cosa fa, in ordine:

1. **Backup** della configurazione (`/opt/mineos/backups/`, retention ultimi 10).
2. **Ferma** i servizi di mining (e li riavvia comunque a fine update).
3. Aggiorna **OS**, **driver** (NVIDIA/AMD) e **miner**.
4. Per ogni miner: download → verifica SHA256 → swap symlink `current` → **smoke-test** → **rollback** automatico se fallisce.

> Se vengono aggiornati kernel o driver, l'updater segnala un **reboot consigliato**.

### Aggiornamento automatico (opzionale)

Esempio di cron settimanale:

```bash
echo '0 4 * * 1 root /opt/mineos/bin/update-mineos.sh >> /opt/mineos/logs/update.log 2>&1' \
  | sudo tee /etc/cron.d/mineos-update
```

---

## Gestione e comandi utili

```bash
# Stato dei servizi
systemctl status mineos-agent mineos-watchdog

# Log live
journalctl -u mineos-agent -f
journalctl -u mineos-watchdog -f
tail -f /opt/mineos/logs/mineos.log

# Riavviare il miner
sudo systemctl restart mineos-agent

# Ri-eseguire il setup iniziale (cambio credenziali/coin)
sudo /opt/mineos/bin/first-boot-setup.sh --force

# Temperatura e stato GPU
nvidia-smi                 # NVIDIA
rocm-smi                   # AMD
```

### Cambiare coin / miner / limiti

Modifica i file in `/opt/mineos/config/` e riavvia l'agent:

```bash
sudo nano /opt/mineos/config/rig.conf      # MINER, ALGO, limiti termici/potenza
sudo nano /opt/mineos/config/pools.conf    # POOL_URL, POOL_USER
sudo systemctl restart mineos-agent
```

---

## Notifiche Telegram

mineOS può inviare avvisi in tempo reale su un bot Telegram. La funzione è **completamente opzionale**: se il file `telegram.conf` non esiste o è incompleto, le notifiche vengono saltate silenziosamente senza impattare il mining.

### Configurazione

1. Crea un bot con [@BotFather](https://t.me/BotFather) e annota il **token**.
2. Avvia una chat col bot (o aggiungilo a un gruppo) e invia un messaggio qualsiasi.
3. Ricava il tuo **chat_id**:

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[].message.chat.id'
```

4. Crea il file di configurazione dal template e compilalo:

```bash
cp /opt/mineos/config/telegram.conf.example /opt/mineos/config/telegram.conf
sudo nano /opt/mineos/config/telegram.conf     # TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID
sudo chmod 600 /opt/mineos/config/telegram.conf
```

```ini
TELEGRAM_BOT_TOKEN="123456789:ABCdefGhIJKlmNoPQRstuVWXyz"
TELEGRAM_CHAT_ID="123456789"
TELEGRAM_ENABLED="1"     # 1 = attive, 0 = disattivate senza rimuovere il file
```

### Attivare e testare

```bash
# Messaggio di test (avviso di tipo STARTUP)
/opt/mineos/bin/send-telegram.sh test

# Messaggio libero
/opt/mineos/bin/send-telegram.sh msg "Ciao dal rig!"

# Avviso tipizzato
/opt/mineos/bin/send-telegram.sh alert HIGH_TEMP "GPU a 92C"
```

Se il test non arriva, verifica token/chat_id e che `curl` raggiunga `api.telegram.org`.

### Eventi notificati

| Evento                     | Tipo            | Generato da        |
|----------------------------|-----------------|--------------------|
| First boot completato      | `FIRSTBOOT_DONE`| `first-boot-setup` |
| Inizio mining              | `MINING_START`  | `mineos-agent`     |
| Hashrate troppo basso      | `LOW_HASHRATE`  | `mineos-watchdog`  |
| Temperatura critica        | `HIGH_TEMP`     | `mineos-watchdog`  |
| Reboot automatico          | `REBOOT`        | `mineos-watchdog`  |
| Shutdown protettivo        | `SHUTDOWN`      | `mineos-watchdog`  |
| Aggiornamento completato   | `UPDATE_DONE`   | `update-mineos`    |

### Esempio di messaggio

```
🔥 mineOS — HIGH_TEMP
🖥 mineos-rig
🕒 2026-06-27 18:05:12

Temperatura critica: 92C >= 90C. Avvio shutdown protettivo.
```

### Sicurezza (token e chat_id)

> ⚠️ **Il token del bot è una credenziale: chi lo possiede può controllare il bot.**

- `telegram.conf` è escluso da git (`config/*.conf` in `.gitignore`): **non committarlo mai**. Nel repo resta solo `telegram.conf.example`.
- Imposta permessi restrittivi: `chmod 600 /opt/mineos/config/telegram.conf`.
- Se il token viene esposto, **revocalo subito** da @BotFather (`/revoke`) e generane uno nuovo.
- Preferisci una chat/gruppo privati: i messaggi includono hostname ed eventi del rig.

---

## Profit-switch automatico

Il profit-switch confronta periodicamente la profittabilità degli algoritmi candidati e, se ne trova uno migliore, riconfigura il rig e riavvia il miner — replicando l'auto-switch del client Kryptex restando 100% nativo. È **completamente opzionale** e disattivato di default.

### Come funziona

1. Un timer systemd (`mineos-profit-switch.timer`) esegue `profit-switch.sh` ogni 4 ore.
2. Lo script interroga l'API di profittabilità (WhatToMine `coins.json`) e calcola un punteggio confrontabile per ogni candidato:

```
score = btc_revenue × (OUR_HASHRATE / REF_HASHRATE)
```

3. Se l'API non è raggiungibile, usa il punteggio di fallback `STATIC_SCORE`.
4. Cambia algoritmo **solo** se il candidato migliore supera l'attuale oltre la soglia di isteresi (anti-flapping), aggiornando `rig.conf`, `pools.conf` e `wallet.conf`, quindi riavvia `mineos-agent` e invia una notifica.

### Come attivarlo

Serve un **doppio consenso**: `PROFIT_SWITCH="true"` in `rig.conf` **e** `PROFIT_SWITCH_ENABLED="1"` in `profit-switch.conf`.

```bash
# 1. Crea la config dal template
cp /opt/mineos/config/profit-switch.conf.example /opt/mineos/config/profit-switch.conf
sudo nano /opt/mineos/config/profit-switch.conf

# 2. Abilita lo switch in rig.conf
sudo sed -i 's/PROFIT_SWITCH=.*/PROFIT_SWITCH="true"/' /opt/mineos/config/rig.conf

# 3. Abilita il timer
sudo systemctl enable --now mineos-profit-switch.timer
```

### Configurare i candidati e calibrare gli hashrate

I candidati si definiscono nell'array `CANDIDATES` di `profit-switch.conf`, una riga per algoritmo:

```ini
# "ALGO|MINER|POOL_URL|WTM_TAG|OUR_HASHRATE|REF_HASHRATE|STATIC_SCORE"
CANDIDATES=(
  "kawpow|trex|stratum+tcp://rvn.kryptex.network:7031|RVN|18000000|1000000000|1.00"
  "etchash|trex|stratum+tcp://etc.kryptex.network:7033|ETC|60000000|1000000000|1.10"
  "autolykos2|lolminer|stratum+tcp://erg.kryptex.network:7021|ERG|180000000|1000000000|0.90"
)
```

| Campo          | Significato                                                        |
|----------------|-------------------------------------------------------------------|
| `ALGO`         | algoritmo, come atteso dal miner e da `rig.conf`                   |
| `MINER`        | `trex` \| `lolminer` \| `srbminer`                                 |
| `POOL_URL`     | endpoint stratum Kryptex per quel coin (dalla dashboard)           |
| `WTM_TAG`      | tag del coin su WhatToMine (es. `RVN`, `ETC`, `ERG`)              |
| `OUR_HASHRATE` | hashrate **reale** del tuo rig su quell'algo, in H/s (da calibrare)|
| `REF_HASHRATE` | hashrate a cui si riferisce il `btc_revenue` dell'API, in H/s     |
| `STATIC_SCORE` | punteggio di fallback se l'API è irraggiungibile                  |

**Calibrazione `OUR_HASHRATE`**: fai girare ogni algoritmo per qualche minuto e leggi l'hashrate effettivo, poi inserisci il valore in H/s (es. 18 MH/s → `18000000`).

```bash
# Hashrate attuale (mentre l'agent mina quell'algo)
journalctl -u mineos-agent -f
# oppure dall'API locale del miner (T-Rex):
curl -s http://127.0.0.1:4067/summary | jq '.hashrate'
```

Altri parametri:

```ini
HYSTERESIS_PCT="5"     # cambia solo se il migliore supera l'attuale di +5%
WTM_API_URL="https://whattomine.com/coins.json"
PROFIT_SWITCH_ENABLED="1"
```

### Comandi utili

```bash
# Anteprima: valuta e mostra la decisione SENZA modificare nulla
sudo /opt/mineos/bin/profit-switch.sh --dry-run --force

# Esecuzione forzata (ignora il gate PROFIT_SWITCH di rig.conf)
sudo /opt/mineos/bin/profit-switch.sh --force

# Stato/prossima esecuzione del timer
systemctl status mineos-profit-switch.timer
systemctl list-timers mineos-profit-switch.timer
journalctl -u mineos-profit-switch -f
```

### Eventi notificati

| Evento                       | Tipo            | Generato da          |
|------------------------------|-----------------|----------------------|
| Cambio di algoritmo          | `PROFIT_SWITCH` | `profit-switch`      |

Lo switch riavvia anche l'agent, quindi a seguire arriverà una notifica `MINING_START` con il nuovo algoritmo.

### Avvertenze

> ⚠️ **La qualità delle decisioni dipende dalla calibrazione.**

- **Calibrazione**: `OUR_HASHRATE`/`REF_HASHRATE` non calibrati rendono il confronto via API inaffidabile; in tal caso conviene affidarsi a `STATIC_SCORE`.
- **Isteresi**: una `HYSTERESIS_PCT` troppo bassa causa cambi frequenti (flapping) con perdita di share durante i restart; valori 5–10% sono un buon punto di partenza.
- **Fallback**: se l'API è giù, viene usato `STATIC_SCORE`; se anche quello manca o è 0, il candidato viene saltato (mai azioni su dati incerti).
- **Miner mancante**: se il miner del candidato vincente non è installato, lo switch viene annullato invece di interrompere il mining.
- **Endpoint Kryptex**: verifica `POOL_URL` per ogni coin dalla tua dashboard; un URL errato fa fallire il mining dopo lo switch.

---

## Troubleshooting

### Il rig non si avvia da USB
- Abilita il boot USB nel BIOS/UEFI e disattiva **Secure Boot** (i driver NVIDIA proprietari non firmati possono non caricarsi con Secure Boot attivo).
- Rigenera la USB; verifica il checksum dell'ISO ufficiale prima della build.

### L'installer si ferma o chiede conferme
- Significa che il seed autoinstall non è stato letto. Verifica di aver buildato con `build-iso.sh` (che aggiunge `autoinstall ds=nocloud;s=/cdrom/server/` a GRUB) e non di aver flashato l'ISO Ubuntu vergine.

### `nvidia-smi` non funziona / nessuna GPU
- Spesso serve un **reboot** dopo l'installazione driver (mineOS lo segnala con il flag `reboot-required`).
- Verifica Secure Boot disattivato.
- Controlla i log: `journalctl -b | grep -i nvidia`.

### Il first boot diceva "Nessuna GPU rilevata" anche con `nvidia-smi` funzionante
- **Risolto**: la rilevazione GPU ora è multi-metodo e non dipende solo da `lspci`. In cascata prova: `lspci` → `nvidia-smi`/`rocm-smi` → vendor ID in `/sys/class/drm/card*/device/vendor` (`0x10de` NVIDIA, `0x1002` AMD).
- Inoltre il first boot **non si interrompe più** per avvisi minori: completa il setup, crea i file di config mancanti e avvia il mining automaticamente.
- Verifica manuale della rilevazione: `source /opt/mineos/bin/lib/common.sh && detect_gpu_vendor`.

### Il miner non parte
```bash
journalctl -u mineos-agent -e
```
- Verifica che `MINER` in `rig.conf` corrisponda a un miner installato (`/opt/mineos/miners/<nome>/current`).
- Verifica `POOL_URL`/`POOL_USER` in `pools.conf` (host/porta corretti dalla dashboard Kryptex).
- Esegui un giro a vuoto: `sudo DRY_RUN=1 /opt/mineos/bin/mineos-agent.sh`.

### Hashrate a zero o worker offline su Kryptex
- Controlla `POOL_USER` nel formato `username.worker`.
- Verifica connettività di rete e che la porta dello stratum non sia bloccata dal firewall.
- Guarda il watchdog: `journalctl -u mineos-watchdog -f`.

### Il sistema continua a riavviarsi
- Probabile intervento del watchdog per hashrate basso o GPU hung. Controlla i motivi:
```bash
cat /opt/mineos/state/reboot-reasons.log
```
- Cause tipiche: overclock troppo aggressivo, alimentazione insufficiente, temperature eccessive. Riduci OC/power limit in `rig.conf`.

### Temperature troppo alte / shutdown protettivo
- Il watchdog spegne il rig oltre la soglia critica. Migliora il raffreddamento, abbassa il **power limit** (`GPU_POWER_LIMIT_W`) e/o alza il flusso d'aria, poi riavvia.

---

## Sicurezza e avvertenze

> ⚠️ **Il mining 24/7 stressa hardware e impianto elettrico in modo continuo. Leggi attentamente.**

### Elettricità
- **Carico continuo elevato**: un rig può assorbire da centinaia a oltre mille watt **24 ore su 24**. Assicurati che **circuito, cavi e prese** siano dimensionati per il carico continuo (non solo di picco).
- **Non sovraccaricare** prese multiple e prolunghe: usa linee dedicate dove possibile.
- Preferisci PSU **80+ Gold** o superiore, con **margine di potenza ≥ 30%** rispetto al consumo di picco.
- Valuta una **protezione** (UPS/sovratensione) e, idealmente, un interruttore differenziale dedicato.
- In caso di odore di bruciato, ronzii anomali o connettori scaldati: **spegni tutto immediatamente**.

### Temperature e raffreddamento
- Garantisci ventilazione abbondante e **estrazione del calore** dall'ambiente: più rig = più calore in stanza.
- Tieni le GPU **sotto le soglie** impostate in `rig.conf` (`GPU_TEMP_LIMIT_C`); il watchdog spegne oltre la soglia critica, ma il vero rimedio è il raffreddamento.
- Pulisci periodicamente la polvere: i dissipatori intasati sono la causa #1 di throttling e usura.

### Sicurezza del sistema
- Le credenziali di default sono **`miner` / `miner`**: cambia **subito** la password al primo accesso (`passwd`) e usa una password robusta.
- I file in `/opt/mineos/config/` contengono le tue credenziali Kryptex: sono `chmod 700/600`. **Non condividerli** e non committarli in repository pubblici.
- Esponi il rig il meno possibile: SSH solo su rete fidata, valuta chiavi SSH al posto della password.

### Aspetti economici e legali
- La profittabilità del mining GPU è **variabile e spesso marginale**: calcola sempre il costo dell'energia prima di investire.
- Verifica i **Termini di Servizio di Kryptex** sull'uso di miner esterni sul loro pool.
- Rispetta le **normative locali** su consumo energetico, fiscalità delle criptovalute e installazioni elettriche.

---

## Licenza e disclaimer

Questo progetto è fornito "così com'è", **senza garanzie di alcun tipo**. L'uso è a tuo rischio: gli autori non sono responsabili per danni hardware, perdite economiche, problemi elettrici o di altra natura derivanti dall'uso di mineOS. Verifica sempre la compatibilità del tuo hardware e il rispetto delle normative locali.

I miner di terze parti (T-Rex, lolMiner, SRBMiner) e Kryptex sono soggetti alle rispettive licenze e termini d'uso.
