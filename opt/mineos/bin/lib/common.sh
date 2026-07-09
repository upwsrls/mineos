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

# --- Helper di rilevamento GPU multi-metodo ----------------------------------
# Normalizza BDF PCI: "4:00.0" / "00000000:04:00.0" -> "0000:04:00.0"
normalize_pci_bdf() {
    local bdf="${1,,}"
    bdf="${bdf// /}"
    # nvidia-smi usa spesso 00000000:BB:DD.F
    if [[ "$bdf" =~ ^[0-9a-f]{8}:([0-9a-f]{2}:[0-9a-f]{2}\.[0-9])$ ]]; then
        printf '0000:%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$bdf" =~ ^[0-9a-f]{4}:([0-9a-f]{2}:[0-9a-f]{2}\.[0-9])$ ]]; then
        printf '0000:%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$bdf" =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]$ ]]; then
        printf '0000:%s' "$bdf"
        return 0
    fi
    printf '%s' "$1"
}

# True se il device PCI sysfs e' una GPU (classe VGA/3D), non audio/USB aux (.1/.2/.3).
_pci_sysfs_is_gpu() {
    local devpath="$1" cls vendor
    [[ -r "${devpath}/class" && -r "${devpath}/vendor" ]] || return 1
    cls="$(cat "${devpath}/class" 2>/dev/null)"
    vendor="$(cat "${devpath}/vendor" 2>/dev/null)"
    [[ "$cls" == "0x030000" || "$cls" == "0x030200" ]] || return 1
    case "$vendor" in
        0x10de|0x1002) return 0 ;;
    esac
    return 1
}

# Nome umano GPU da sysfs PCI (fallback lspci).
_pci_sysfs_gpu_name() {
    local devpath="$1" bdf name
    bdf="$(basename "$devpath")"
    if [[ -r "${devpath}/label" ]]; then
        name="$(tr -d '\n' < "${devpath}/label" 2>/dev/null)"
        [[ -n "$name" ]] && { printf '%s' "$name"; return 0; }
    fi
    if command -v lspci >/dev/null 2>&1; then
        name="$(lspci -s "$bdf" 2>/dev/null | sed 's/^[0-9a-f:.]* //')"
        [[ -n "$name" ]] && { printf '%s' "$name"; return 0; }
    fi
    printf 'GPU %s' "$bdf"
}

# Elenca GPU da /sys/bus/pci/devices (fonte piu' completa pre/post driver).
list_gpus_sysfs_pci() {
    local dev bdf vendor name
    for dev in /sys/bus/pci/devices/*; do
        [[ -d "$dev" ]] || continue
        _pci_sysfs_is_gpu "$dev" || continue
        bdf="$(normalize_pci_bdf "$(basename "$dev")")"
        vendor="$(cat "${dev}/vendor" 2>/dev/null)"
        name="$(_pci_sysfs_gpu_name "$dev")"
        case "$vendor" in
            0x10de) printf 'nvidia|%s|%s|sysfs_pci\n' "$bdf" "$name" ;;
            0x1002) printf 'amd|%s|%s|sysfs_pci\n' "$bdf" "$name" ;;
        esac
    done
}

# Elenca GPU da lspci (solo VGA/3D, esclude funzioni aux USB/audio NVIDIA).
list_gpus_lspci() {
    command -v lspci >/dev/null 2>&1 || return 0
    local line bdf name
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        bdf="$(normalize_pci_bdf "$(awk '{print $1}' <<< "$line")")"
        name="$(sed 's/^[0-9a-f:.]* //' <<< "$line")"
        if grep -qi 'NVIDIA' <<< "$line"; then
            printf 'nvidia|%s|%s|lspci\n' "$bdf" "$name"
        elif grep -iE 'Advanced Micro Devices|AMD/ATI|\[AMD' <<< "$line"; then
            printf 'amd|%s|%s|lspci\n' "$bdf" "$name"
        fi
    done < <(lspci -D -nn 2>/dev/null | grep -iE 'VGA compatible controller|3D controller')
}

# Elenca GPU da /sys/class/drm/card* (driver gia' caricato).
list_gpus_sysfs_drm() {
    local card devpath vendor bdf name
    for card in /sys/class/drm/card[0-9]*; do
        [[ -e "${card}/device/vendor" ]] || continue
        devpath="$(readlink -f "${card}/device" 2>/dev/null)" || continue
        _pci_sysfs_is_gpu "$devpath" || continue
        vendor="$(cat "${devpath}/vendor" 2>/dev/null)"
        bdf="$(normalize_pci_bdf "$(basename "$devpath")")"
        name="$(_pci_sysfs_gpu_name "$devpath")"
        case "$vendor" in
            0x10de) printf 'nvidia|%s|%s|sysfs_drm\n' "$bdf" "$name" ;;
            0x1002) printf 'amd|%s|%s|sysfs_drm\n' "$bdf" "$name" ;;
        esac
    done
}

# Elenca GPU viste dal driver NVIDIA (autoritativo post-driver).
list_gpus_nvidia_smi() {
    command -v nvidia-smi >/dev/null 2>&1 || return 0
    nvidia-smi --query-gpu=pci.bus_id,name --format=csv,noheader,nounits 2>/dev/null \
        | while IFS=',' read -r bus name; do
            bus="${bus// /}"
            name="${name# }"
            [[ -n "$bus" ]] || continue
            printf 'nvidia|%s|%s|nvidia-smi\n' "$(normalize_pci_bdf "$bus")" "$name"
        done
}

# Unisce tutte le fonti, deduplica per vendor|bdf. Output: vendor|bdf|name|source
detect_gpu_devices() {
    local -A seen=()
    local line vendor bdf key v b n s
    while IFS='|' read -r vendor bdf n s; do
        [[ -z "$vendor" || -z "$bdf" ]] && continue
        bdf="$(normalize_pci_bdf "$bdf")"
        key="${vendor}|${bdf}"
        [[ -n "${seen[$key]+x}" ]] && continue
        seen[$key]=1
        printf '%s|%s|%s|%s\n' "$vendor" "$bdf" "$n" "$s"
    done < <(
        list_gpus_sysfs_pci
        list_gpus_lspci
        list_gpus_sysfs_drm
        list_gpus_nvidia_smi
    )
}

# Conta GPU per vendor (nvidia|amd|all).
detect_gpu_count() {
    local filter="${1:-all}" count=0 vendor
    while IFS='|' read -r vendor _ _ _; do
        [[ -z "$vendor" ]] && continue
        case "$filter" in
            all) ((count++)) ;;
            nvidia|amd) [[ "$vendor" == "$filter" ]] && ((count++)) ;;
        esac
    done < <(detect_gpu_devices)
    printf '%s' "$count"
}

# Report inventario GPU -> log + state/gpu-inventory.txt
gpu_detection_report() {
    local outfile="${MINEOS_STATE}/gpu-inventory.txt"
    mkdir -p "${MINEOS_STATE}" 2>/dev/null || true

    local total nvidia_n amd_n smi_n pci_n
    total="$(detect_gpu_count all)"
    nvidia_n="$(detect_gpu_count nvidia)"
    amd_n="$(detect_gpu_count amd)"
    smi_n=0 pci_n=0
    command -v nvidia-smi >/dev/null 2>&1 && smi_n="$(list_gpus_nvidia_smi | wc -l)"
    pci_n="$(list_gpus_sysfs_pci | grep -c '^nvidia|' 2>/dev/null || echo 0)"

    log INFO "Inventario GPU: tot=${total} nvidia=${nvidia_n} amd=${amd_n} (sysfs_pci=${pci_n} nvidia-smi=${smi_n})"
    {
        echo "mineOS GPU inventory $(date --iso-8601=seconds 2>/dev/null || date)"
        echo "total=${total} nvidia=${nvidia_n} amd=${amd_n} sysfs_pci_nvidia=${pci_n} nvidia_smi=${smi_n}"
        echo "format: vendor|pci_bdf|name|source"
        detect_gpu_devices
    } | tee "$outfile" >&2
}

# Rescan bus PCI (GPU appena alimentate / riser non viste al boot).
gpu_rescan_pci_bus() {
    if [[ -w /sys/bus/pci/rescan ]]; then
        log INFO "Rescan bus PCI (/sys/bus/pci/rescan)..."
        run bash -c 'echo 1 > /sys/bus/pci/rescan'
        sleep 2
    else
        log WARN "Impossibile rescan PCI (permessi o sysfs assente)."
    fi
}

# GRUB: pci=realloc aiuta BAR/memoria su rig multi-GPU eterogenei (1080+1660+3090).
apply_multigpu_grub_fix() {
    local grub_default="/etc/default/grub"
    [[ -f "$grub_default" ]] || return 0
    [[ "${DRY_RUN:-0}" == "1" ]] && { log INFO "DRY_RUN: salto apply_multigpu_grub_fix."; return 0; }

    if ! grep -q 'pci=realloc' "$grub_default" 2>/dev/null; then
        log INFO "GRUB: aggiungo pci=realloc (multi-GPU BAR)..."
        sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT=".*\)"/\1 pci=realloc"/' "$grub_default" \
            || log WARN "Patch GRUB pci=realloc fallita."
    fi
    if command -v update-grub >/dev/null 2>&1; then
        run update-grub || log WARN "update-grub fallito."
    fi
}

# Confronta hardware (sysfs/lspci) vs driver (nvidia-smi); tenta fix automatici.
verify_nvidia_gpu_visibility() {
    local pci_n=0 smi_n=0
    pci_n="$(list_gpus_sysfs_pci | grep -c '^nvidia|' 2>/dev/null || true)"
    smi_n="$(list_gpus_nvidia_smi | wc -l)"

    gpu_detection_report

    if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi -L >/dev/null 2>&1; then
        log WARN "nvidia-smi non disponibile: impossibile verificare visibilita' driver."
        return 0
    fi

    if [[ "$pci_n" -gt 0 && "$smi_n" -gt 0 && "$pci_n" -gt "$smi_n" ]]; then
        log WARN "MISMATCH GPU: hardware sysfs=${pci_n} NVIDIA, nvidia-smi=${smi_n}."
        log WARN "GPU mancanti dal driver (es. RTX 3090 / GTX 1080 non in nvidia-smi -L)."
        gpu_rescan_pci_bus
        apply_multigpu_grub_fix
        smi_n="$(list_gpus_nvidia_smi | wc -l)"
        if [[ "$pci_n" -gt "$smi_n" ]]; then
            log ERROR "Dopo rescan: ancora ${pci_n} GPU hardware vs ${smi_n} visibili al driver."
            log ERROR "Controlla BIOS: Above 4G Decoding / Large BAR / Re-Size BAR attivi."
            log ERROR "Verifica alimentazione/riser PCIe; poi: sudo reboot"
            notify GPU_MISMATCH "GPU hardware=${pci_n} driver=${smi_n}. Abilita Above 4G in BIOS e reboot."
        else
            log INFO "Rescan PCI riuscito: nvidia-smi ora vede ${smi_n} GPU."
        fi
    elif [[ "$pci_n" -eq 0 && "$smi_n" -gt 0 ]]; then
        log INFO "nvidia-smi vede ${smi_n} GPU (sysfs_pci non ha enumerato, ok post-driver)."
    else
        log INFO "Visibilita' GPU OK: sysfs_pci=${pci_n} nvidia-smi=${smi_n}."
    fi
}

# Restituisce: nvidia | amd | both | none
# Rilevazione multi-GPU: sysfs_pci + lspci + drm + nvidia-smi/rocm-smi.
detect_gpu_vendor() {
    local has_nvidia=0 has_amd=0 vendor

    while IFS='|' read -r vendor _ _ _; do
        case "$vendor" in
            nvidia) has_nvidia=1 ;;
            amd)    has_amd=1 ;;
        esac
    done < <(detect_gpu_devices)

    # Fallback legacy se nessuna GPU enumerata (VM, driver assente, pciutils mancante).
    if [[ $has_nvidia -eq 0 && $has_amd -eq 0 ]]; then
        if command -v lspci >/dev/null 2>&1; then
            lspci -nn 2>/dev/null | grep -iE 'VGA compatible controller|3D controller' | grep -Eiq 'NVIDIA' && has_nvidia=1
            lspci -nn 2>/dev/null | grep -iE 'VGA compatible controller|3D controller' | grep -Eiq 'Advanced Micro Devices|AMD/ATI|\[AMD' && has_amd=1
        fi
        if [[ $has_nvidia -eq 0 ]] && command -v nvidia-smi >/dev/null 2>&1 \
                && nvidia-smi -L >/dev/null 2>&1; then
            has_nvidia=1
        fi
        if [[ $has_amd -eq 0 ]] && command -v rocm-smi >/dev/null 2>&1 \
                && rocm-smi --showid >/dev/null 2>&1; then
            has_amd=1
        fi
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

# Estrae un pacchetto miner (.tar.gz) in <dest> in modo INDIPENDENTE dal layout.
# Gli archivi dei miner non sono uniformi:
#   - con cartella top-level (es. lolMiner -> '1.88/', SRBMiner -> 'SRBMiner-.../')
#   - "flat", senza cartella (es. alcune build di T-Rex: 't-rex', 'README'...)
# Il vecchio 'tar --strip-components=1' funzionava SOLO col primo caso: con un
# archivio flat rimuoveva l'unico componente del path e SCARTAVA i file
# (cartella vuota -> binario 'trex' non trovato). Qui rileviamo la radice reale.
extract_miner_pkg() {
    local tarball="$1" dest="$2"
    local stage; stage="$(mktemp -d)" || { log ERROR "mktemp fallito"; return 1; }

    if ! tar -xzf "$tarball" -C "$stage" 2>/dev/null; then
        log ERROR "Estrazione archivio fallita: $tarball"
        rm -rf "$stage"; return 1
    fi

    # Determina la radice del payload: se al primo livello c'è UNA sola cartella
    # (e nient'altro), il contenuto sta lì dentro; altrimenti è già a livello root.
    local root="$stage"
    local -a entries=()
    while IFS= read -r e; do entries+=("$e"); done \
        < <(find "$stage" -mindepth 1 -maxdepth 1 2>/dev/null)
    if [[ "${#entries[@]}" -eq 1 && -d "${entries[0]}" ]]; then
        root="${entries[0]}"
    fi

    # Destinazione pulita, poi copia preservando permessi (inclusi file nascosti).
    rm -rf "$dest"; mkdir -p "$dest"
    if ! cp -a "$root"/. "$dest"/ 2>/dev/null; then
        log ERROR "Copia file miner fallita verso $dest"
        rm -rf "$stage"; return 1
    fi
    rm -rf "$stage"

    # Sicurezza: garantisci il bit +x su eventuali binari noti del miner
    # (cerca anche in sottocartelle: alcuni tar hanno layout annidato).
    local b
    for b in t-rex T-Rex lolMiner lolminer SRBMiner-MULTI SRBMiner-Multi srbminer; do
        while IFS= read -r -d '' f; do
            chmod +x "$f" 2>/dev/null || true
        done < <(find "$dest" -type f -name "$b" -print0 2>/dev/null)
    done
    return 0
}

# Trova il binario eseguibile di un miner installato.
# Restituisce il path assoluto o exit 1. Usato da agent, update e fix-rig.
find_miner_binary_in_dir() {
    local miner="$1" dir="$2"
    [[ -n "$miner" && -n "$dir" ]] || return 1

    if [[ -e "$dir" || -L "$dir" ]]; then
        dir="$(readlink -f "$dir" 2>/dev/null || echo "$dir")"
    fi
    [[ -d "$dir" ]] || return 1

    local -a candidates=()
    case "$miner" in
        trex)     candidates=(t-rex T-Rex) ;;
        lolminer) candidates=(lolMiner lolminer) ;;
        srbminer) candidates=(SRBMiner-MULTI SRBMiner-Multi srbminer) ;;
        *) return 1 ;;
    esac

    local bin="" name
    for name in "${candidates[@]}"; do
        if [[ -f "${dir}/${name}" ]]; then
            [[ -x "${dir}/${name}" ]] || chmod +x "${dir}/${name}" 2>/dev/null || true
            [[ -x "${dir}/${name}" ]] && { printf '%s' "${dir}/${name}"; return 0; }
        fi
    done
    # Fallback: cerca per nome in tutta la cartella (max 3 livelli).
    for name in "${candidates[@]}"; do
        bin="$(find -L "$dir" -maxdepth 3 -type f -name "$name" -print -quit 2>/dev/null)"
        if [[ -n "$bin" && -f "$bin" ]]; then
            chmod +x "$bin" 2>/dev/null || true
            [[ -x "$bin" ]] && { printf '%s' "$bin"; return 0; }
        fi
    done
    # Ultimo tentativo: primo file eseguibile in root.
    bin="$(find -L "$dir" -maxdepth 1 -type f -perm -u+x -print -quit 2>/dev/null)"
    [[ -n "$bin" && -x "$bin" ]] && { printf '%s' "$bin"; return 0; }
    return 1
}

# Normalizza coin/ticker -> ALGORITMO del miner (i miner vogliono l'algoritmo,
# non il nome della moneta: es. 'PRL'/'RVN' NON sono algoritmi validi, 'kawpow' sì).
# - se l'input è già un algoritmo noto: passthrough (in minuscolo);
# - se è un ticker noto: mappa al relativo algoritmo;
# - se è sconosciuto: 'kawpow' come default sicuro (con warning).
normalize_algo() {
    local in; in="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$in" in
        kawpow|etchash|ethash|autolykos2|octopus|kheavyhash|firopow|progpow|zelhash|cuckatoo32|blake3|karlsenhash|pearlhash)
            printf '%s' "$in" ;;
        prl|pearl)
            printf 'pearlhash' ;;
        rvn|ravencoin|neox|neoxa|clore|aipg|meowcoin|mewc)
            printf 'kawpow' ;;
        etc|ethereumclassic|etc-etchash)
            printf 'etchash' ;;
        ergo|erg)
            printf 'autolykos2' ;;
        cfx|conflux)
            printf 'octopus' ;;
        kas|kaspa)
            printf 'kheavyhash' ;;
        firo|xzc)
            printf 'firopow' ;;
        flux|zel)
            printf 'zelhash' ;;
        "")
            log WARN "Algoritmo/coin vuoto: uso 'pearlhash' di default (Pearl/PRL)."
            printf 'pearlhash' ;;
        *)
            log WARN "Algoritmo/coin '$1' non riconosciuto: uso 'pearlhash' di default (Pearl/PRL)."
            printf 'pearlhash' ;;
    esac
}

# Mappa algoritmo -> ticker coin Kryptex (inverso di normalize_algo).
# Usato da profit-switch e fix-rig quando si aggiorna wallet.conf.
coin_from_algo() {
    local a; a="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$a" in
        pearlhash)    printf 'prl' ;;
        kawpow)       printf 'rvn' ;;
        etchash)      printf 'etc' ;;
        autolykos2)   printf 'erg' ;;
        kheavyhash)   printf 'kas' ;;
        octopus)      printf 'cfx' ;;
        firopow)      printf 'firo' ;;
        zelhash)      printf 'flux' ;;
        blake3)       printf 'alph' ;;
        prl|pearl|rvn|ravencoin|etc|erg|kas|cfx|firo|flux|alph)
            printf '%s' "$a" ;;
        *)
            log WARN "Algo '$1' senza ticker Kryptex noto: uso 'prl' (Pearl)."
            printf 'prl' ;;
    esac
}

# Corregge MINER in base all'algoritmo (es. pearlhash richiede srbminer, non trex).
resolve_miner_for_algo() {
    local miner="$1" algo="$2"
    local pref; pref="$(miner_for_algo "$algo")"
    if [[ -n "$pref" && "$miner" != "$pref" ]]; then
        log WARN "Miner '${miner}' non supporta '${algo}': uso '${pref}'."
        printf '%s' "$pref"
    else
        printf '%s' "$miner"
    fi
}

# --- Catalogo miner (fonte unica) -------------------------------------------
# Formato: NOME|VERSIONE|URL|SHA256|VENDOR
# Versioni, URL e SHA256 REALI dalle release ufficiali (GitHub), verificati il
# 2026-06-28 (SRBMiner anche via MD5 ufficiale). Aggiornare SEMPRE insieme
# versione+URL+SHA256 quando esce una nuova release.
#   - T-Rex     : github.com/trexminer/T-Rex
#   - lolMiner  : github.com/Lolliedieb/lolMiner-releases
#   - SRBMiner  : github.com/doktor83/SRBMiner-Multi
miner_catalog() {
    cat <<'EOF'
trex|0.26.8|https://github.com/trexminer/T-Rex/releases/download/0.26.8/t-rex-0.26.8-linux.tar.gz|7e77064a48b4c8cb8d4797f30a41b53efbb8311fc14475b56a8e6879ad1c0569|nvidia
lolminer|1.98a|https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98a/lolMiner_v1.98a_Lin64.tar.gz|0b8078299654a12846e4967f1db3506409cfb8b1031687a910965d1a99c6f270|both
srbminer|3.4.2|https://github.com/doktor83/SRBMiner-Multi/releases/download/3.4.2/SRBMiner-Multi-3-4-2-Linux.tar.gz|b8bcd90c92dc9b639dab9f513b34fa894252478decea16067a4a0b71eb2e41cf|both
EOF
}

# --- Endpoint Kryptex Pool ---------------------------------------------------
# Mappa coin -> endpoint stratum REALE di Kryptex (host E porta variano per
# coin; fonte: https://pool.kryptex.com). Accetta sia il ticker della moneta
# sia l'algoritmo. Default sicuro: RVN (KawPow). Uso: kryptex_pool_url <coin>
kryptex_pool_url() {
    local coin; coin="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    local hp
    case "$coin" in
        prl|pearl|pearlhash)    hp="prl.kryptex.network:7048" ;;
        rvn|ravencoin|kawpow)   hp="rvn.kryptex.network:7031" ;;
        erg|ergo|autolykos2)    hp="erg.kryptex.network:7021" ;;
        etc|ethereumclassic|etchash) hp="etc.kryptex.network:7033" ;;
        kas|kaspa|kheavyhash)   hp="kas.kryptex.network:7011" ;;
        alph|alephium)          hp="alph.kryptex.network:7010" ;;
        xna|neurai)             hp="xna.kryptex.network:7024" ;;
        nexa)                   hp="nexa.kryptex.network:7026" ;;
        iron|ironfish)          hp="iron.kryptex.network:7017" ;;
        ltc|litecoin|doge)      hp="ltc.kryptex.network:7016" ;;
        *)
            log WARN "Coin '$1' senza endpoint Kryptex noto: uso PRL (Pearl/pearlhash) come default."
            hp="prl.kryptex.network:7048" ;;
    esac
    printf 'stratum+tcp://%s' "$hp"
}

# Miner consigliato per un dato ALGORITMO (override del default per-vendor).
# Restituisce il nome miner SOLO quando l'algoritmo è vincolato a uno specifico
# miner; stringa vuota = "nessuna preferenza" (il chiamante usa il default).
#   - pearlhash è supportato da SRBMiner-MULTI (pearlhash su NVIDIA + AMD RDNA2).
miner_for_algo() {
    local a; a="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    case "$a" in
        pearlhash)                       printf 'srbminer' ;;
        autolykos2|cuckatoo32|cuckaroo29) printf 'lolminer' ;;
        *)                               printf '' ;;
    esac
}

# Costruisce lo username stratum Kryptex col separatore corretto:
#   - account/email  -> "account/worker"  (Kryptex richiede '/' per le email)
#   - username/wallet -> "account.worker" (separatore '.')
# Uso: kryptex_pool_user <account> <worker>
kryptex_pool_user() {
    local account="${1:-}" worker="${2:-}"
    [[ -z "$worker" ]] && { printf '%s' "$account"; return 0; }
    if [[ "$account" == *@* ]]; then
        printf '%s/%s' "$account" "$worker"
    else
        printf '%s.%s' "$account" "$worker"
    fi
}

# --- Fix boot NVIDIA i2c timeout / ucsi_ccg (rig mining) --------------------
# Su GPU NVIDIA senza USB-C funzionante il kernel tenta i2c_nvidia_gpu + ucsi_ccg
# e stampa "i2c timeout error" / "ucsi_ccg_init failed -110" (non blocca mining).
# Scrive /etc/modprobe.d/mineos-nvidia-*.conf e rigenera initramfs.
apply_nvidia_boot_fix() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log INFO "DRY_RUN: salto apply_nvidia_boot_fix."
        return 0
    fi

    local i2c_conf="/etc/modprobe.d/mineos-nvidia-i2c.conf"
    local nv_conf="/etc/modprobe.d/mineos-nvidia.conf"
    mkdir -p /etc/modprobe.d

    # Idempotente: scrivi solo se mancante o diverso dal contenuto atteso.
    if [[ ! -f "$i2c_conf" ]] || ! grep -q 'blacklist i2c_nvidia_gpu' "$i2c_conf" 2>/dev/null; then
        cat > "$i2c_conf" <<'EOF'
# mineOS - fix boot "nvidia-gpu i2c timeout" / "ucsi_ccg init failed -110"
blacklist i2c_nvidia_gpu
blacklist ucsi_ccg
install i2c_nvidia_gpu /bin/false
install ucsi_ccg /bin/false
EOF
        log INFO "Scritto ${i2c_conf} (blacklist i2c_nvidia_gpu/ucsi_ccg)."
    fi

    if [[ ! -f "$nv_conf" ]] || ! grep -q 'NVreg_EnableUsbPd=0' "$nv_conf" 2>/dev/null; then
        cat > "$nv_conf" <<'EOF'
# mineOS - opzioni driver NVIDIA per rig mining headless
options nvidia NVreg_EnableUsbPd=0
EOF
        log INFO "Scritto ${nv_conf} (NVreg_EnableUsbPd=0)."
    fi

    if command -v update-initramfs >/dev/null 2>&1; then
        log INFO "Rigenero initramfs (modprobe NVIDIA)..."
        run update-initramfs -u \
            || log WARN "update-initramfs fallito: esegui manualmente 'sudo update-initramfs -u' e reboot."
    else
        log WARN "update-initramfs assente: reboot dopo install driver per applicare il fix."
    fi

    # Blacklist anche via kernel cmdline: copre il boot precoce (prima di modprobe.d).
    local grub_default="/etc/default/grub"
    if [[ -f "$grub_default" ]] && ! grep -q 'modprobe.blacklist=i2c_nvidia_gpu' "$grub_default" 2>/dev/null; then
        log INFO "Aggiungo blacklist i2c/ucsi a GRUB_CMDLINE_LINUX_DEFAULT..."
        sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT=".*\)"/\1 modprobe.blacklist=i2c_nvidia_gpu modprobe.blacklist=ucsi_ccg"/' \
            "$grub_default" \
            || log WARN "Patch GRUB fallita (modifica manualmente /etc/default/grub)."
        if command -v update-grub >/dev/null 2>&1; then
            run update-grub \
                || log WARN "update-grub fallito: esegui manualmente 'sudo update-grub' e reboot."
        fi
    fi
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

# --- Flag "reboot pending" ---------------------------------------------------
# Flag persistente che segnala "serve un riavvio prima/dopo aver applicato
# kernel o driver GPU". REGOLA: chi installa driver/kernel lo CREA; l'agent lo
# RIMUOVE automaticamente al proprio avvio (vedi mineos-agent.service,
# ExecStartPre). NON deve mai essere una condizione bloccante per il mining,
# altrimenti l'agent resta 'inactive (condition)' all'infinito.
: "${MINEOS_REBOOT_FLAG:=${MINEOS_STATE}/reboot-required}"

mark_reboot_required() {
    mkdir -p "${MINEOS_STATE}" 2>/dev/null || true
    : > "${MINEOS_REBOOT_FLAG}"
    log INFO "Segnalato 'reboot necessario' (${MINEOS_REBOOT_FLAG})."
}

clear_reboot_required() {
    rm -f "${MINEOS_REBOOT_FLAG}" 2>/dev/null || true
}

reboot_required() {
    [[ -f "${MINEOS_REBOOT_FLAG}" ]]
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
