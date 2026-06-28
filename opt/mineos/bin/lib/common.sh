#!/usr/bin/env bash
# /opt/mineos/bin/lib/common.sh
# Libreria condivisa: logging, gestione errori, helper. Va "source"-ata, non eseguita.

# --- Percorsi base (override-abili via env per i test) -----------------------
: "${MINEOS_ROOT:=/opt/mineos}"
: "${MINEOS_BIN:=${MINEOS_ROOT}/bin}"
: "${MINEOS_MINERS:=${MINEOS_ROOT}/miners}"
: "${MINEOS_CONFIG:=${MINEOS_ROOT}/config}"
: "${MINEOS_STATE:=${MINEOS_ROOT}/state}"
: "${MINEOS_LOGS:=${MINEOS_ROOT}/logs}"
: "${MINEOS_BACKUPS:=${MINEOS_ROOT}/backups}"

# Assicura che la cartella log esista anche se la lib viene caricata molto presto.
mkdir -p "${MINEOS_LOGS}" 2>/dev/null || true

# --- Logging strutturato -----------------------------------------------------
# Uso: log INFO "messaggio"  |  log WARN "..."  |  log ERROR "..."
log() {
    local level="$1"; shift
    local ts; ts="$(date --iso-8601=seconds 2>/dev/null || date)"
    # Stampa su stderr (catturato da journald se lanciato da systemd) e su file.
    printf '%s [%s] %s\n' "$ts" "$level" "$*" | tee -a "${MINEOS_LOGS}/mineos.log" >&2
}

die() { log ERROR "$*"; exit 1; }

# --- Guardie di sicurezza ----------------------------------------------------
require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Questo script deve girare come root."
}

# Esegue un comando solo se non in DRY_RUN; logga sempre cosa farebbe.
run() {
    log INFO "RUN: $*"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi
    "$@"
}

# --- Helper di rilevamento ---------------------------------------------------
# Restituisce: nvidia | amd | both | none
# Rilevazione robusta in cascata: lspci -> tool vendor (nvidia-smi/rocm-smi)
# -> sysfs DRM vendor IDs. Cosi' funziona anche se pciutils non e' installato
# o se lspci non riconosce la scheda (VM, naming non standard).
detect_gpu_vendor() {
    local has_nvidia=0 has_amd=0

    # 1) lspci, se disponibile.
    if command -v lspci >/dev/null 2>&1; then
        lspci -nn 2>/dev/null | grep -Eiq 'NVIDIA'                              && has_nvidia=1
        lspci -nn 2>/dev/null | grep -Eiq 'Advanced Micro Devices|AMD/ATI|\[AMD' && has_amd=1
    fi

    # 2) Fallback: tool vendor-specifici (autorevoli se rispondono).
    if [[ $has_nvidia -eq 0 ]] && command -v nvidia-smi >/dev/null 2>&1 \
            && nvidia-smi -L >/dev/null 2>&1; then
        has_nvidia=1
    fi
    if [[ $has_amd -eq 0 ]] && command -v rocm-smi >/dev/null 2>&1 \
            && rocm-smi --showid >/dev/null 2>&1; then
        has_amd=1
    fi

    # 3) Fallback: sysfs DRM (0x10de=NVIDIA, 0x1002=AMD).
    if [[ $has_nvidia -eq 0 || $has_amd -eq 0 ]]; then
        local vfile
        for vfile in /sys/class/drm/card*/device/vendor; do
            [[ -r "$vfile" ]] || continue
            case "$(cat "$vfile" 2>/dev/null)" in
                0x10de) has_nvidia=1 ;;
                0x1002) has_amd=1 ;;
            esac
        done
    fi

    if   [[ $has_nvidia -eq 1 && $has_amd -eq 1 ]]; then echo "both"
    elif [[ $has_nvidia -eq 1 ]]; then echo "nvidia"
    elif [[ $has_amd    -eq 1 ]]; then echo "amd"
    else echo "none"; fi
}

# Rileva il package manager della distro.
detect_pkg_mgr() {
    if   command -v apt-get >/dev/null; then echo "apt"
    elif command -v dnf     >/dev/null; then echo "dnf"
    elif command -v pacman  >/dev/null; then echo "pacman"
    else echo "unknown"; fi
}

# Verifica checksum SHA256 di un file. Uso: verify_sha256 <file> <hash atteso>
verify_sha256() {
    local file="$1" expected="$2"
    local actual; actual="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "Checksum errato per $file (atteso $expected, ottenuto $actual)."
}

# --- Helper config -----------------------------------------------------------
# Carica un file di config "KEY=VALUE" in modo sicuro (deve esistere).
load_conf() {
    local f="$1"
    [[ -f "$f" ]] || die "File di config mancante: $f"
    # shellcheck disable=SC1090
    source "$f"
}

# set_conf_value FILE KEY VALUE
# Aggiorna (o aggiunge) una riga KEY="VALUE" in un file di config.
# Preserva il resto del file. Rispetta DRY_RUN.
set_conf_value() {
    local file="$1" key="$2" value="$3"
    [[ -f "$file" ]] || { log WARN "set_conf_value: file mancante $file"; return 1; }
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log INFO "DRY_RUN set_conf_value: $file -> ${key}=\"${value}\""
        return 0
    fi
    local tmp; tmp="$(mktemp)"
    if grep -qE "^${key}=" "$file"; then
        awk -v k="$key" -v v="$value" \
            '$0 ~ "^"k"=" {print k"=\""v"\""; next} {print}' "$file" > "$tmp"
    else
        cat "$file" > "$tmp"
        printf '%s="%s"\n' "$key" "$value" >> "$tmp"
    fi
    cat "$tmp" > "$file"
    rm -f "$tmp"
    log INFO "Config aggiornata: $file -> ${key}=\"${value}\""
}

# --- Helper servizi ----------------------------------------------------------
# Esegue un'azione systemctl tollerando ambienti senza systemd (build/chroot).
sysctl_safe() {
    if command -v systemctl >/dev/null 2>&1; then
        run systemctl "$@" || log WARN "systemctl $* fallito (ignorato)."
    else
        log WARN "systemctl assente: salto 'systemctl $*'."
    fi
}

# --- Notifiche (Telegram) ----------------------------------------------------
# notify TYPE MESSAGE
# Wrapper sicuro: invia un avviso via send-telegram.sh se presente e configurato.
# Non propaga MAI errori al chiamante (compatibile con 'set -e') e logga sempre
# l'evento localmente. Se le notifiche non sono configurate, viene saltato.
notify() {
    local type="${1:-GENERIC}"; shift || true
    local msg="${*:-}"
    log INFO "NOTIFY[$type] $msg"
    local tg="${MINEOS_BIN}/send-telegram.sh"
    [[ -f "$tg" ]] || return 0
    # Subshell isolata: qualunque problema resta confinato.
    ( source "$tg" && send_alert "$type" "$msg" ) >/dev/null 2>&1 || true
    return 0
}
