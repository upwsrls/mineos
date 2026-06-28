#!/usr/bin/env bash
#
# build/build-iso.sh
#
# mineOS - Generatore immagine ISO autoinstall
# --------------------------------------------------------------------------
# Crea un'ISO personalizzata, completamente NON presidiata, partendo dalla
# ISO ufficiale di Ubuntu Server 24.04 "live-server". L'ISO risultante:
#   - installa Ubuntu in automatico (autoinstall / cloud-init NoCloud),
#   - inietta il payload mineOS (/opt/mineos + unit systemd),
#   - abilita i servizi mineOS,
#   - riavvia: al primo boot parte il wizard (mineos-firstboot).
#
# REQUISITI HOST DI BUILD (Linux):
#   sudo apt-get install -y xorriso wget
#
# USO:
#   ./build-iso.sh [percorso-iso-ubuntu]
#   (se l'ISO non e' indicata, viene scaricata automaticamente)
#
set -Eeuo pipefail

# --- Parametri --------------------------------------------------------------
UBUNTU_VERSION="24.04.3"
UBUNTU_ISO_NAME="ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
UBUNTU_ISO_URL="https://releases.ubuntu.com/24.04/${UBUNTU_ISO_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"     # cartella che contiene opt/ ed etc/
WORK_DIR="${SCRIPT_DIR}/work"
ISO_EXTRACT="${WORK_DIR}/iso"
OUT_ISO="${SCRIPT_DIR}/mineos-${UBUNTU_VERSION}-autoinstall-amd64.iso"

SRC_ISO="${1:-${WORK_DIR}/${UBUNTU_ISO_NAME}}"

log() { printf '\033[1;32m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build][ERRORE]\033[0m %s\n' "$*" >&2; exit 1; }

# --- Pre-flight -------------------------------------------------------------
command -v xorriso >/dev/null || die "xorriso mancante. Installa: sudo apt-get install -y xorriso"
[[ -f "${SCRIPT_DIR}/autoinstall/user-data" ]] || die "Manca autoinstall/user-data"
[[ -f "${SCRIPT_DIR}/autoinstall/meta-data" ]] || die "Manca autoinstall/meta-data"
[[ -d "${REPO_ROOT}/opt/mineos" ]] || die "Manca ${REPO_ROOT}/opt/mineos (payload)"

mkdir -p "${WORK_DIR}"

# --- 1. Scarica l'ISO ufficiale se assente ---------------------------------
if [[ ! -f "${SRC_ISO}" ]]; then
    log "Scarico ISO ufficiale Ubuntu ${UBUNTU_VERSION}..."
    command -v wget >/dev/null || die "wget mancante per il download."
    wget -O "${SRC_ISO}" "${UBUNTU_ISO_URL}"
else
    log "Uso ISO esistente: ${SRC_ISO}"
fi

# --- 2. Costruisci il payload mineOS ---------------------------------------
log "Creo il payload mineOS (opt/ + unit systemd)..."
PAYLOAD="${WORK_DIR}/mineos-payload.tar.gz"
# Il tar contiene 'opt/mineos/...' ed 'etc/systemd/system/...' cosi' che,
# estratto in / (target), finisca nei percorsi giusti.
tar -czf "${PAYLOAD}" \
    -C "${REPO_ROOT}" \
    --exclude='opt/mineos/state/*' \
    --exclude='opt/mineos/logs/*' \
    --exclude='opt/mineos/miners/*' \
    --exclude='opt/mineos/backups/*' \
    opt etc

# --- 3. Estrai il contenuto dell'ISO ufficiale -----------------------------
log "Estraggo l'ISO ufficiale in ${ISO_EXTRACT}..."
rm -rf "${ISO_EXTRACT}"
mkdir -p "${ISO_EXTRACT}"
xorriso -osirrox on -indev "${SRC_ISO}" -extract / "${ISO_EXTRACT}" >/dev/null 2>&1
# xorriso estrae in sola lettura: rendiamo scrivibile.
chmod -R u+w "${ISO_EXTRACT}"

# --- 4. Inietta seed autoinstall + payload mineOS --------------------------
log "Inietto seed autoinstall e payload..."
mkdir -p "${ISO_EXTRACT}/server" "${ISO_EXTRACT}/mineos"
cp "${SCRIPT_DIR}/autoinstall/user-data" "${ISO_EXTRACT}/server/user-data"
cp "${SCRIPT_DIR}/autoinstall/meta-data" "${ISO_EXTRACT}/server/meta-data"
cp "${PAYLOAD}"                          "${ISO_EXTRACT}/mineos/mineos-payload.tar.gz"
cp "${SCRIPT_DIR}/install.sh"            "${ISO_EXTRACT}/mineos/install.sh"

# --- 5. Patch GRUB: avvio automatico in modalita' autoinstall --------------
log "Patch della configurazione GRUB..."
GRUB_CFG="${ISO_EXTRACT}/boot/grub/grub.cfg"
[[ -f "${GRUB_CFG}" ]] || die "grub.cfg non trovato (${GRUB_CFG})."
# Aggiunge i parametri kernel a tutte le voci di boot (token '---').
#   autoinstall                -> attiva subiquity non presidiato
#   ds=nocloud;s=/cdrom/server -> dove trovare user-data/meta-data
sed -i 's|---|autoinstall ds=nocloud\\;s=/cdrom/server/ ---|g' "${GRUB_CFG}"
# Timeout breve per partire subito.
sed -i 's|^set timeout=.*|set timeout=3|' "${GRUB_CFG}"

# --- 6. Ricostruisci l'ISO preservando il boot BIOS+UEFI -------------------
# Tecnica robusta: leggiamo dall'ISO originale gli argomenti esatti di boot
# (El Torito) e li riusiamo per ricreare un'immagine ibrida identica.
log "Ricavo i parametri di boot dall'ISO originale..."
BOOT_ARGS_FILE="${WORK_DIR}/boot_args.txt"
xorriso -indev "${SRC_ISO}" -report_el_torito as_mkisofs 2>/dev/null > "${BOOT_ARGS_FILE}"
[[ -s "${BOOT_ARGS_FILE}" ]] || die "Impossibile leggere i parametri El Torito dall'ISO."

# Converte le opzioni (con quoting xorriso) in un array bash.
BOOT_OPTS=()
while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    # 'eval' interpreta le virgolette singole prodotte da xorriso in modo sicuro
    # (input generato dal tool, non dall'utente).
    eval "BOOT_OPTS+=( ${line} )"
done < "${BOOT_ARGS_FILE}"

log "Genero l'ISO finale: ${OUT_ISO}"
xorriso -as mkisofs \
    -V "MINEOS_2404" \
    "${BOOT_OPTS[@]}" \
    -o "${OUT_ISO}" \
    "${ISO_EXTRACT}"

log "FATTO."
log "ISO pronta: ${OUT_ISO}"
log "Flash con:  sudo dd if='${OUT_ISO}' of=/dev/sdX bs=4M status=progress oflag=sync"
