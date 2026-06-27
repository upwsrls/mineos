#!/usr/bin/env bash
#
# /opt/mineos/bin/send-telegram.sh
#
# mineOS - Notifiche Telegram
# ---------------------------
# Puo' essere:
#   - ESEGUITO da CLI:   send-telegram.sh msg "testo libero"
#                        send-telegram.sh alert HIGH_TEMP "GPU a 92C"
#   - oppure SOURCE-ato: source send-telegram.sh; send_alert STARTUP "..."
#
# Configurazione (opzionale): /opt/mineos/config/telegram.conf
#     TELEGRAM_BOT_TOKEN="123456:ABC..."
#     TELEGRAM_CHAT_ID="123456789"
#     TELEGRAM_ENABLED="1"        # opzionale, default 1 se token+chat presenti
# In alternativa via variabili d'ambiente con gli stessi nomi.
#
# Se la configurazione manca o e' incompleta, le notifiche vengono SALTATE
# silenziosamente (le funzioni ritornano 0, mai un errore al chiamante).
#
set -uo pipefail

# Percorsi (coerenti con common.sh, ma lo script resta autonomo).
: "${MINEOS_ROOT:=/opt/mineos}"
: "${MINEOS_CONFIG:=${MINEOS_ROOT}/config}"
TG_CONF="${MINEOS_CONFIG}/telegram.conf"

# Logging: usa il log() di common.sh se gia' definito, altrimenti fallback muto.
if ! declare -F log >/dev/null 2>&1; then
    log() { printf '%s [%s] %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)" "$1" "${*:2}" >&2; }
fi

# ----------------------------------------------------------------------------
# Carica la configurazione. Ritorna 1 se le notifiche non sono utilizzabili.
# ----------------------------------------------------------------------------
tg_load_config() {
    if [[ -f "$TG_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$TG_CONF"
    fi
    : "${TELEGRAM_BOT_TOKEN:=}"
    : "${TELEGRAM_CHAT_ID:=}"
    : "${TELEGRAM_ENABLED:=1}"

    [[ "$TELEGRAM_ENABLED" == "1" ]]                || return 1
    [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || return 1
    command -v curl >/dev/null 2>&1                 || return 1
    return 0
}

# ----------------------------------------------------------------------------
# Escaping MarkdownV2: ogni carattere speciale va preceduto da backslash.
# Caratteri riservati: _ * [ ] ( ) ~ ` > # + - = | { } . ! e \
# ----------------------------------------------------------------------------
tg_escape() {
    local s="$1" out="" c i
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            '_'|'*'|'['|']'|'('|')'|'~'|'`'|'>'|'#'|'+'|'-'|'='|'|'|'{'|'}'|'.'|'!'|'\')
                out+="\\$c" ;;
            *)  out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

# ----------------------------------------------------------------------------
# Invio di un messaggio gia' formattato (parse_mode MarkdownV2 di default).
# ----------------------------------------------------------------------------
tg_send_message() {
    local text="$1" parse_mode="${2:-MarkdownV2}"
    tg_load_config || { log INFO "Telegram non configurato: notifica saltata."; return 0; }

    local api="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    if ! curl -fsS --max-time 10 -X POST "$api" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${text}" \
            -d "parse_mode=${parse_mode}" \
            -d "disable_web_page_preview=true" >/dev/null 2>&1 ; then
        log WARN "Invio notifica Telegram fallito (rete/API)."
        return 0   # mai propagare errori al chiamante
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Invio di un MESSAGGIO SEMPLICE (testo libero, viene escapato).
# ----------------------------------------------------------------------------
tg_send_plain() {
    local text; text="$(tg_escape "$*")"
    tg_send_message "$text"
}

# ----------------------------------------------------------------------------
# send_alert TYPE MESSAGE
# Costruisce un avviso formattato con emoji/severita', host e timestamp.
# ----------------------------------------------------------------------------
send_alert() {
    local type="${1:-GENERIC}"; shift || true
    local message="${*:-}"

    # Mappa tipo -> emoji.
    local emoji
    case "$type" in
        STARTUP|FIRSTBOOT_DONE) emoji="✅" ;;
        MINING_START)           emoji="⛏️" ;;
        PROFIT_SWITCH)          emoji="💱" ;;
        UPDATE_DONE)            emoji="⬆️" ;;
        LOW_HASHRATE)           emoji="⚠️" ;;
        HIGH_TEMP)              emoji="🔥" ;;
        REBOOT)                 emoji="🔄" ;;
        SHUTDOWN)               emoji="🛑" ;;
        ERROR)                  emoji="❌" ;;
        *)                      emoji="ℹ️" ;;
    esac

    local title host ts body
    title="$(tg_escape "mineOS — ${type}")"
    host="$(tg_escape "$(hostname -s 2>/dev/null || echo rig)")"
    ts="$(tg_escape "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)")"
    body="$(tg_escape "$message")"

    local text
    printf -v text '%s *%s*\n🖥 %s\n🕒 %s\n\n%s' \
        "$emoji" "$title" "$host" "$ts" "$body"

    tg_send_message "$text"
}

# ----------------------------------------------------------------------------
# CLI entrypoint (solo se eseguito, non se source-ato)
# ----------------------------------------------------------------------------
_tg_main() {
    case "${1:-}" in
        alert) shift; send_alert "$@" ;;
        msg)   shift; tg_send_plain "$@" ;;
        test)  send_alert STARTUP "Notifica di test da mineOS." ;;
        *)
            cat <<EOF
Uso:
  send-telegram.sh msg "testo libero"
  send-telegram.sh alert TYPE "messaggio"
  send-telegram.sh test
TYPE: STARTUP|MINING_START|UPDATE_DONE|LOW_HASHRATE|HIGH_TEMP|REBOOT|SHUTDOWN|ERROR
EOF
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _tg_main "$@"
fi
