#!/usr/bin/env bash
#
# /opt/mineos/bin/profit-switch.sh
#
# mineOS - Profit switch automatico
# ---------------------------------
# Confronta la profittabilita' degli algoritmi candidati e, se ne trova uno
# migliore (oltre una soglia di isteresi), riconfigura il rig e riavvia il
# miner. Replica l'auto-switch del client Kryptex restando 100% nativo.
#
# Sorgente profittabilita':
#   1) API WhatToMine (coins.json) -> btc_revenue per coin
#   2) Fallback: punteggio statico definito in profit-switch.conf
#
# Punteggio confrontabile per candidato:
#   score_api = btc_revenue * (OUR_HASHRATE / REF_HASHRATE)
#   (REF_HASHRATE = hashrate a cui si riferisce il btc_revenue dell'API)
# Se l'API non e' disponibile o i dati mancano, si usa STATIC_SCORE.
#
# Tutto OPZIONALE: se PROFIT_SWITCH non e' "true" in rig.conf o manca la
# configurazione, lo script esce senza fare nulla.
#
# Uso:
#   profit-switch.sh [--dry-run] [--force]
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PS_CONF="${MINEOS_CONFIG}/profit-switch.conf"
AGENT_SERVICE="mineos-agent.service"
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) export DRY_RUN=1 ;;
        --force)   FORCE=1 ;;
        *) die "Argomento sconosciuto: $arg" ;;
    esac
done

trap 'log ERROR "profit-switch fallito alla riga $LINENO (comando: $BASH_COMMAND)"' ERR

# Variabili globali popolate durante la scelta del migliore.
JSON=""
best_score="-1"; best_algo=""; best_miner=""; best_pool=""; best_src=""
current_score="0"

# ----------------------------------------------------------------------------
# Confronto numerico float via awk (niente dipendenza da bc).
# fcmp A OP B  -> ritorna 0 (vero) / 1 (falso). OP: gt|ge|lt
# ----------------------------------------------------------------------------
fgt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !((a+0) > (b+0))}'; }

# ----------------------------------------------------------------------------
# Calcola il punteggio di un candidato. Stampa il numero, o "skip".
# Imposta la variabile globale _last_src con "api" o "static".
# ----------------------------------------------------------------------------
compute_score() {
    local tag="$1" ourhr="$2" refhr="$3" static="$4"
    _last_src=""
    local rev=""

    if [[ -n "$JSON" ]] && command -v jq >/dev/null 2>&1; then
        rev="$(printf '%s' "$JSON" \
            | jq -r --arg t "$tag" \
                '.coins | to_entries[] | .value | select(.tag==$t) | .btc_revenue' \
                2>/dev/null | head -1)"
    fi

    # Percorso API: richiede revenue valido e hashrate (nostro + riferimento) > 0.
    if [[ -n "$rev" && "$rev" != "null" ]] \
        && awk -v r="$rev" -v o="$ourhr" -v f="$refhr" \
              'BEGIN{exit !((r+0)>0 && (o+0)>0 && (f+0)>0)}'; then
        _last_src="api"
        awk -v r="$rev" -v o="$ourhr" -v f="$refhr" 'BEGIN{printf "%.12f", r*o/f}'
        return 0
    fi

    # Fallback: punteggio statico.
    if awk -v s="$static" 'BEGIN{exit !((s+0)>0)}'; then
        _last_src="static"
        printf '%s' "$static"
        return 0
    fi

    printf 'skip'
}

# ----------------------------------------------------------------------------
# Verifica che il miner richiesto sia installato.
# ----------------------------------------------------------------------------
miner_installed() {
    local m="$1"
    [[ -d "${MINEOS_MINERS}/${m}/current" ]]
}

# ----------------------------------------------------------------------------
# Applica lo switch: aggiorna config e riavvia il miner.
# ----------------------------------------------------------------------------
apply_switch() {
    log INFO "SWITCH: ${current_algo:-<nessuno>} -> ${best_algo} (miner=${best_miner}, fonte=${best_src})"

    if ! miner_installed "$best_miner"; then
        log WARN "Miner '${best_miner}' non installato: switch annullato (esegui update-mineos.sh)."
        return 0
    fi

    set_conf_value "${MINEOS_CONFIG}/rig.conf"   ALGO     "$best_algo"
    set_conf_value "${MINEOS_CONFIG}/rig.conf"   MINER    "$best_miner"
    set_conf_value "${MINEOS_CONFIG}/pools.conf" POOL_URL "$best_pool"
    set_conf_value "${MINEOS_CONFIG}/wallet.conf" KRX_COIN "$(coin_from_algo "$best_algo")"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log INFO "DRY_RUN: non riavvio il miner."
        return 0
    fi

    sysctl_safe restart "$AGENT_SERVICE"
    notify PROFIT_SWITCH "Profit-switch: passato a ${best_algo} (miner ${best_miner}, fonte ${best_src})."
}

# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------
main() {
    require_root

    # --- Gate da rig.conf ---
    load_conf "${MINEOS_CONFIG}/rig.conf"
    : "${PROFIT_SWITCH:=false}"
    : "${ALGO:=}"
    current_algo="${ALGO}"

    if [[ "$PROFIT_SWITCH" != "true" && "$FORCE" -ne 1 ]]; then
        log INFO "Profit-switch disabilitato (PROFIT_SWITCH=$PROFIT_SWITCH). Esco."
        exit 0
    fi

    # --- Configurazione candidati ---
    if [[ ! -f "$PS_CONF" ]]; then
        log WARN "Config profit-switch assente ($PS_CONF). Esco."
        exit 0
    fi
    # shellcheck disable=SC1090
    source "$PS_CONF"
    : "${PROFIT_SWITCH_ENABLED:=1}"
    : "${HYSTERESIS_PCT:=5}"
    : "${WTM_API_URL:=https://whattomine.com/coins.json}"

    if [[ "$PROFIT_SWITCH_ENABLED" != "1" ]]; then
        log INFO "Profit-switch disabilitato da profit-switch.conf. Esco."
        exit 0
    fi
    if [[ "${#CANDIDATES[@]:-0}" -eq 0 ]]; then
        log WARN "Nessun candidato definito in profit-switch.conf. Esco."
        exit 0
    fi

    # --- Recupero dati profittabilita' (best effort) ---
    if command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
        log INFO "Interrogo l'API profittabilita': $WTM_API_URL"
        JSON="$(curl -fsS --max-time 15 "$WTM_API_URL" 2>/dev/null || true)"
        [[ -n "$JSON" ]] || log WARN "API non raggiungibile: uso il fallback statico."
    else
        log WARN "jq/curl assenti: uso il fallback statico."
    fi

    # --- Valutazione candidati ---
    local line algo miner pool tag ourhr refhr static score
    for line in "${CANDIDATES[@]}"; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r algo miner pool tag ourhr refhr static <<< "$line"
        score="$(compute_score "$tag" "${ourhr:-0}" "${refhr:-0}" "${static:-0}")"
        if [[ "$score" == "skip" ]]; then
            log WARN "Candidato $algo ($tag): nessun dato utilizzabile, saltato."
            continue
        fi
        log INFO "Candidato $algo ($tag): score=$score (fonte=$_last_src)"

        [[ "$algo" == "$current_algo" ]] && current_score="$score"

        if fgt "$score" "$best_score"; then
            best_score="$score"; best_algo="$algo"; best_miner="$miner"
            best_pool="$pool";   best_src="$_last_src"
        fi
    done

    if [[ -z "$best_algo" ]]; then
        log WARN "Nessun candidato valutabile. Nessuna azione."
        exit 0
    fi

    # --- Decisione ---
    if [[ "$best_algo" == "$current_algo" ]]; then
        log INFO "L'algoritmo attuale ($current_algo) e' gia' il piu' profittevole. Nessun cambio."
        exit 0
    fi

    # Soglia: cambia solo se il migliore supera l'attuale di HYSTERESIS_PCT%.
    local threshold
    threshold="$(awk -v c="$current_score" -v h="$HYSTERESIS_PCT" 'BEGIN{printf "%.12f", c*(1+h/100)}')"
    if awk -v c="$current_score" 'BEGIN{exit !((c+0)<=0)}' || fgt "$best_score" "$threshold"; then
        apply_switch
    else
        log INFO "Miglior candidato ($best_algo, $best_score) non supera la soglia (+${HYSTERESIS_PCT}% = $threshold). Nessun cambio."
    fi
}

main "$@"
