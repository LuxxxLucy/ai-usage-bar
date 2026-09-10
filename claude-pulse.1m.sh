#!/bin/bash

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

CLAUDE_DIR="$HOME/.claude"
CODEX_DIR="$HOME/.codex"
CACHE_DIR="${TMPDIR:-/tmp}"
OR_CACHE="$CACHE_DIR/claude-pulse-or.json"
DS_CACHE="$CACHE_DIR/claude-pulse-ds.json"
CC_CACHE="$CACHE_DIR/claude-pulse-cc.json"
CODEX_CACHE="$CACHE_DIR/claude-pulse-codex.json"

PLUGIN_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")

FONT="BerkeleyMono-Bold size=13"

PROVIDERS=(openrouter deepseek claude codex)

keychain_secret() {
    security find-generic-password -s "$1" -w 2>/dev/null
}

state_icon() {
    case "$1" in stale) printf '⏳' ;; down) printf '⚠️' ;; esac
}

set_state() { printf '%s' "$2" >"$1.state"; }
get_state() { cat "$1.state" 2>/dev/null; }

fetch_json() {
    local cache="$1"; shift
    local tmp; tmp=$(mktemp)
    curl -s --max-time 5 "$@" >"$tmp"
    if [[ -s "$tmp" ]] && ! jq -e '.error' <"$tmp" >/dev/null 2>&1; then
        cp "$tmp" "$cache"; set_state "$cache" ok
    elif [[ -s "$cache" ]]; then
        set_state "$cache" stale
    else
        set_state "$cache" down
    fi
    rm -f "$tmp"
}

countdown() {
    local reset_at="$1" reset_epoch seconds_left now
    [[ -z "$reset_at" || "$reset_at" == null ]] && return
    if [[ "$reset_at" =~ ^[0-9]+$ ]]; then
        reset_epoch="$reset_at"
    else
        reset_at="${reset_at%%.*}"; reset_at="${reset_at%%+*}"; reset_at="${reset_at%Z}"
        reset_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$reset_at" "+%s" 2>/dev/null) || return
    fi
    now=$(date "+%s")
    ((reset_epoch <= 0)) && return
    seconds_left=$((reset_epoch - now))
    ((seconds_left <= 0)) && echo now && return
    ((seconds_left < 3600)) && echo "$((seconds_left / 60))m" && return
    ((seconds_left < 86400)) && echo "$((seconds_left / 3600))h$((seconds_left % 3600 / 60))m" && return
    echo "$((seconds_left / 86400))d$((seconds_left % 86400 / 3600))h"
}

render_quota() {
    local label="$1" seven="$2" five="$3" seven_reset="$4" five_reset="$5" state="$6"
    local seven_left five_left
    seven_left=$(countdown "$seven_reset")
    five_left=$(countdown "$five_reset")
    printf '%s%s: 7d:%.0f%%' "$(state_icon "$state")" "$label" "$seven"
    [[ -n "$seven_left" ]] && printf '(%s)' "$seven_left"
    printf ' 5h:%.0f%%' "$five"
    [[ -n "$five_left" ]] && printf '(%s)' "$five_left"
}

# Working-state dot: red when a Claude or Codex session wrote in the last 90s.
recent_activity() {
    local cutoff; cutoff=$(($(date "+%s") - 90))
    {
        find "$CLAUDE_DIR/projects" -type f -name '*.jsonl' -mtime -1 -exec stat -f '%m' {} + 2>/dev/null
        find "$CODEX_DIR/sessions" -type f -name '*.jsonl' -mtime -1 -exec stat -f '%m' {} + 2>/dev/null
    } | awk -v cutoff="$cutoff" '$1 >= cutoff { found = 1 } END { exit !found }'
}

openrouter_fetch() {
    local key; key=$(keychain_secret "openrouter-api-key")
    [[ -z "$key" ]] && { set_state "$OR_CACHE" absent; return; }
    fetch_json "$OR_CACHE" "https://openrouter.ai/api/v1/credits" -H "Authorization: Bearer $key"
}
openrouter_segment() {
    local state; state=$(get_state "$OR_CACHE")
    case "$state" in
        absent) printf 'OR:no key' ;;
        down)   printf '%sOR:' "$(state_icon down)" ;;
        *)      local total used
                read -r total used < <(jq -r '[.data.total_credits // 0, .data.total_usage // 0] | @tsv' "$OR_CACHE")
                printf '%sOR:$%.2f/$%.0f' "$(state_icon "$state")" "$used" "$total" ;;
    esac
}

deepseek_fetch() {
    local key; key=$(keychain_secret "deepseek-api-key")
    [[ -z "$key" ]] && { set_state "$DS_CACHE" absent; return; }
    fetch_json "$DS_CACHE" "https://api.deepseek.com/user/balance" -H "Authorization: Bearer $key"
}
deepseek_segment() {
    local state; state=$(get_state "$DS_CACHE")
    case "$state" in
        absent) printf 'DS:no key' ;;
        down)   printf '%sDS:' "$(state_icon down)" ;;
        *)      local balance; balance=$(jq -r '.balance_infos[0].total_balance // 0' "$DS_CACHE")
                printf '%sDS:¥%.2f' "$(state_icon "$state")" "$balance" ;;
    esac
}

claude_fetch() {
    local token; token=$(keychain_secret "Claude Code-credentials" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    [[ -z "$token" ]] && { set_state "$CC_CACHE" absent; return; }
    fetch_json "$CC_CACHE" "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/2.0.31"
}
claude_segment() {
    local state; state=$(get_state "$CC_CACHE")
    case "$state" in
        absent | down) printf '%sCC:' "$(state_icon "$state")" ;;
        *)  local d7 h5 r7 r5
            read -r d7 h5 r7 r5 < <(jq -r '[.seven_day.utilization // 0, .five_hour.utilization // 0, .seven_day.resets_at // "", .five_hour.resets_at // ""] | @tsv' "$CC_CACHE")
            render_quota CC "$d7" "$h5" "$r7" "$r5" "$state" ;;
    esac
}

codex_fetch() {
    local tmp
    tmp=$(mktemp "$CODEX_CACHE.XXXXXX") || return
    if node "$PLUGIN_DIR/lib/codex-usage.cjs" >"$tmp" 2>/dev/null; then
        mv "$tmp" "$CODEX_CACHE"
    elif jq -e 'select(.ts > 0) | .state = "stale"' "$CODEX_CACHE" >"$tmp" 2>/dev/null; then
        mv "$tmp" "$CODEX_CACHE"
    fi
    rm -f "$tmp"
}

codex_segment() {
    local state now used reset ts left
    read -r used reset ts state < <(jq -er '
        select(.ts > 0 and (.s | type == "number"))
        | [.s, .sr, .ts, .state] | @tsv' "$CODEX_CACHE" 2>/dev/null)
    [[ -n "$ts" ]] || { printf 'Codex:no data'; return; }
    now=$(date "+%s")
    ((now - ts > 120 || now >= reset)) && state=stale
    printf '%sCodex: 7d:%.0f%%' "$(state_icon "$state")" "$used"
    left=$(countdown "$reset")
    [[ -n "$left" ]] && printf '(%s)' "$left"
    if [[ "$state" == stale ]]; then
        printf '(stale)'
    fi
}

main() {
    local p dot segs=()
    for p in "${PROVIDERS[@]}"; do "${p}_fetch" & done
    wait
    recent_activity && dot="🔴" || dot="⚪"
    for p in "${PROVIDERS[@]}"; do segs+=("$("${p}_segment")"); done
    printf '%s %s | font=%s\n' "$dot" "${segs[*]}" "$FONT"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main
