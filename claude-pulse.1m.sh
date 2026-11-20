#!/bin/bash

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

CLAUDE_DIR="$HOME/.claude"
CODEX_DIR="$HOME/.codex"
AGY_DIR="$HOME/.gemini/antigravity-cli"
CACHE_DIR="${TMPDIR:-/tmp}"
OR_CACHE="$CACHE_DIR/claude-pulse-or.json"
DS_CACHE="$CACHE_DIR/claude-pulse-ds.json"
CC_CACHE="$CACHE_DIR/claude-pulse-cc.json"
CODEX_CACHE="$CACHE_DIR/claude-pulse-codex.json"
AGY_CACHE="$CACHE_DIR/claude-pulse-agy.json"

PLUGIN_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")

BAR_FONT="BerkeleyMono-Bold"
MENU_FONT="BerkeleyMono-Bold size=12"

QUOTA_PROVIDERS=(claude codex antigravity)
CREDIT_PROVIDERS=(openrouter deepseek)
PROVIDERS=(openrouter deepseek claude codex antigravity)

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

quota_color() {
    local d7="$1" h5="$2" state="$3" max=0 v
    [[ "$state" == stale || "$state" == down ]] && { printf ' color=#888888'; return; }
    for v in "$d7" "$h5"; do
        [[ "$v" == "-" || -z "$v" ]] && continue
        v=$(printf '%.0f' "$v")
        ((v > max)) && max=$v
    done
    if ((max >= 90)); then
        printf ' color=#ff5555'
    elif ((max >= 70)); then
        printf ' color=#ffb86c'
    fi
}

render_quota_bar() {
    local label="$1" d7="$2" h5="$3" r7="$4" r5="$5" state="$6"
    local left sep=""
    printf '%s%-6s ' "$(state_icon "$state")" "$label:"
    if [[ "$d7" != "-" ]]; then
        left=$(countdown "$r7")
        printf '7d:%2.0f%%' "$d7"
        [[ -n "$left" ]] && printf '(%s)' "$left"
        sep=" "
    fi
    if [[ "$h5" != "-" ]]; then
        left=$(countdown "$r5")
        printf '%s5h:%2.0f%%' "$sep" "$h5"
        [[ -n "$left" ]] && printf '(%s)' "$left"
    fi
}

render_quota_menu() {
    local name="$1" d7="$2" h5="$3" r7="$4" r5="$5" state="$6"
    local line left color
    line=$(printf '%s%-11s' "$(state_icon "$state")" "$name")
    if [[ "$d7" != "-" ]]; then
        left=$(countdown "$r7")
        line+=$(printf '  7d:%3.0f%%' "$d7")
        [[ -n "$left" ]] && line+=$(printf ' (%s)' "$left")
    fi
    if [[ "$h5" != "-" ]]; then
        left=$(countdown "$r5")
        line+=$(printf '  5h:%3.0f%%' "$h5")
        [[ -n "$left" ]] && line+=$(printf ' (%s)' "$left")
    fi
    color=$(quota_color "$d7" "$h5" "$state")
    printf '%s | font=%s trim=false%s\n' "$line" "$MENU_FONT" "$color"
}

render_status_menu() {
    local name="$1" text="$2" state="$3" color=" color=#888888"
    [[ "$state" == down ]] && color=" color=#ff5555"
    printf '%s%-11s  %s | font=%s trim=false%s\n' "$(state_icon "$state")" "$name" "$text" "$MENU_FONT" "$color"
}

# Working-state dot: red when a Claude, Codex, or Antigravity session wrote in the last 90s.
recent_activity() {
    local cutoff; cutoff=$(($(date "+%s") - 90))
    {
        find "$CLAUDE_DIR/projects" -type f -name '*.jsonl' -mtime -1 -exec stat -f '%m' {} + 2>/dev/null
        find "$CODEX_DIR/sessions" -type f -name '*.jsonl' -mtime -1 -exec stat -f '%m' {} + 2>/dev/null
        find "$AGY_DIR/brain" -type f -name 'transcript.jsonl' -mtime -1 -exec stat -f '%m' {} + 2>/dev/null
    } | awk -v cutoff="$cutoff" '$1 >= cutoff { found = 1 } END { exit !found }'
}

# --- OpenRouter ---

openrouter_fetch() {
    local key; key=$(keychain_secret "openrouter-api-key")
    [[ -z "$key" ]] && { set_state "$OR_CACHE" absent; return; }
    fetch_json "$OR_CACHE" "https://openrouter.ai/api/v1/credits" -H "Authorization: Bearer $key"
}

openrouter_bar() {
    local state; state=$(get_state "$OR_CACHE")
    case "$state" in
        absent) printf 'OR:no key' ;;
        down)   printf '%sOR:--' "$(state_icon down)" ;;
        *)      local total used
                read -r total used < <(jq -r '[.data.total_credits // 0, .data.total_usage // 0] | @tsv' "$OR_CACHE")
                printf '%sOR:$%.2f/$%.0f' "$(state_icon "$state")" "$used" "$total" ;;
    esac
}

openrouter_menu() {
    local state; state=$(get_state "$OR_CACHE")
    case "$state" in
        absent) render_status_menu "OpenRouter" "no key" absent ;;
        down)   render_status_menu "OpenRouter" "unavailable" down ;;
        *)      local total used color=""
                read -r total used < <(jq -r '[.data.total_credits // 0, .data.total_usage // 0] | @tsv' "$OR_CACHE")
                [[ "$state" == stale ]] && color=" color=#888888"
                printf '%s%-11s  $%.2f / $%.0f used | font=%s trim=false%s\n' \
                    "$(state_icon "$state")" "OpenRouter" "$used" "$total" "$MENU_FONT" "$color" ;;
    esac
}

# --- DeepSeek ---

deepseek_fetch() {
    local key; key=$(keychain_secret "deepseek-api-key")
    [[ -z "$key" ]] && { set_state "$DS_CACHE" absent; return; }
    fetch_json "$DS_CACHE" "https://api.deepseek.com/user/balance" -H "Authorization: Bearer $key"
}

deepseek_bar() {
    local state; state=$(get_state "$DS_CACHE")
    case "$state" in
        absent) printf 'DS:no key' ;;
        down)   printf '%sDS:--' "$(state_icon down)" ;;
        *)      local balance; balance=$(jq -r '.balance_infos[0].total_balance // 0' "$DS_CACHE")
                printf '%sDS:¥%.2f' "$(state_icon "$state")" "$balance" ;;
    esac
}

deepseek_menu() {
    local state; state=$(get_state "$DS_CACHE")
    case "$state" in
        absent) render_status_menu "DeepSeek" "no key" absent ;;
        down)   render_status_menu "DeepSeek" "unavailable" down ;;
        *)      local balance color=""
                balance=$(jq -r '.balance_infos[0].total_balance // 0' "$DS_CACHE")
                [[ "$state" == stale ]] && color=" color=#888888"
                printf '%s%-11s  ¥%.2f balance | font=%s trim=false%s\n' \
                    "$(state_icon "$state")" "DeepSeek" "$balance" "$MENU_FONT" "$color" ;;
    esac
}

# --- Claude ---

claude_fetch() {
    local token; token=$(keychain_secret "Claude Code-credentials" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    [[ -z "$token" ]] && { set_state "$CC_CACHE" absent; return; }
    fetch_json "$CC_CACHE" "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/2.0.31"
}

claude_read() {
    local state; state=$(get_state "$CC_CACHE")
    case "$state" in
        absent | down) printf '%s\t-\t-\t\t\n' "$state" ;;
        *)  local d7 h5 r7 r5
            read -r d7 h5 r7 r5 < <(jq -r '[.seven_day.utilization // 0, .five_hour.utilization // 0, .seven_day.resets_at // "", .five_hour.resets_at // ""] | @tsv' "$CC_CACHE")
            printf '%s\t%s\t%s\t%s\t%s\n' "$state" "$d7" "$h5" "$r7" "$r5" ;;
    esac
}

claude_bar() {
    local state d7 h5 r7 r5
    IFS=$'\t' read -r state d7 h5 r7 r5 < <(claude_read)
    case "$state" in
        absent | down) printf '%sCC:--' "$(state_icon "$state")" ;;
        *) render_quota_bar CC "$d7" "$h5" "$r7" "$r5" "$state" ;;
    esac
}

claude_menu() {
    local state d7 h5 r7 r5
    IFS=$'\t' read -r state d7 h5 r7 r5 < <(claude_read)
    case "$state" in
        absent) render_status_menu "Claude" "not signed in" absent ;;
        down)   render_status_menu "Claude" "unavailable" down ;;
        *)      render_quota_menu "Claude" "$d7" "$h5" "$r7" "$r5" "$state" ;;
    esac
}

# --- Codex ---

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

codex_read() {
    local used reset ts state now
    read -r used reset ts state < <(jq -er '
        select(.ts > 0 and (.s | type == "number"))
        | [.s, .sr, .ts, .state] | @tsv' "$CODEX_CACHE" 2>/dev/null)
    [[ -n "$ts" ]] || { printf 'absent\t-\t-\t\t\n'; return; }
    now=$(date "+%s")
    ((now - ts > 120 || now >= reset)) && state=stale
    printf '%s\t%s\t-\t%s\t\n' "$state" "$used" "$reset"
}

codex_bar() {
    local state d7 h5 r7 r5
    IFS=$'\t' read -r state d7 h5 r7 r5 < <(codex_read)
    case "$state" in
        absent) printf 'Codex:--' ;;
        *)      render_quota_bar Codex "$d7" "$h5" "$r7" "$r5" "$state" ;;
    esac
}

codex_menu() {
    local state d7 h5 r7 r5
    IFS=$'\t' read -r state d7 h5 r7 r5 < <(codex_read)
    case "$state" in
        absent) render_status_menu "Codex" "no data" absent ;;
        *)      render_quota_menu "Codex" "$d7" "$h5" "$r7" "$r5" "$state" ;;
    esac
}

# --- Antigravity ---

antigravity_fetch() {
    local tmp now
    tmp=$(mktemp "$AGY_CACHE.XXXXXX") || return
    now=$(date "+%s")
    if agy -p "/usage" --output-format json --print-timeout 10s 2>/dev/null | jq -e --argjson now "$now" '
        select(.status == "SUCCESS")
        | [.command.data.groups[].buckets[]]
        | (map(select(.id == "gemini-weekly"))[0]) as $w
        | (map(select(.id == "gemini-5h"))[0]) as $f
        | select($w != null or $f != null)
        | {
            d7: (if $w then (1 - ([$w.remaining_fraction, 1] | min | [., 0] | max)) * 100 else null end),
            h5: (if $f then (1 - ([$f.remaining_fraction, 1] | min | [., 0] | max)) * 100 else null end),
            r7: ($w.reset_time // null),
            r5: ($f.reset_time // null),
            ts: $now,
            state: "ok"
          }' >"$tmp" 2>/dev/null; then
        mv "$tmp" "$AGY_CACHE"
    elif jq -e 'select(.ts > 0) | .state = "stale"' "$AGY_CACHE" >"$tmp" 2>/dev/null; then
        mv "$tmp" "$AGY_CACHE"
    fi
    rm -f "$tmp"
}

antigravity_read() {
    local d7 h5 r7 r5 ts state now
    read -r d7 h5 r7 r5 ts state < <(jq -er '
        select(.ts > 0 and ((.d7 | type == "number") or (.h5 | type == "number")))
        | [(.d7 // "-"), (.h5 // "-"), (.r7 // "-"), (.r5 // "-"), .ts, (.state // "ok")] | @tsv' "$AGY_CACHE" 2>/dev/null)
    [[ -n "$ts" ]] || { printf 'absent\t-\t-\t\t\n'; return; }
    [[ "$r7" == "-" ]] && r7=""
    [[ "$r5" == "-" ]] && r5=""
    now=$(date "+%s")
    ((now - ts > 120)) && state=stale
    printf '%s\t%s\t%s\t%s\t%s\n' "$state" "$d7" "$h5" "$r7" "$r5"
}

antigravity_bar() {
    local state d7 h5 r7 r5
    IFS=$'\t' read -r state d7 h5 r7 r5 < <(antigravity_read)
    case "$state" in
        absent) printf 'AGY:--' ;;
        *)      render_quota_bar AGY "$d7" "$h5" "$r7" "$r5" "$state" ;;
    esac
}

antigravity_menu() {
    local state d7 h5 r7 r5
    IFS=$'\t' read -r state d7 h5 r7 r5 < <(antigravity_read)
    case "$state" in
        absent) render_status_menu "Antigravity" "no data" absent ;;
        *)      render_quota_menu "Antigravity" "$d7" "$h5" "$r7" "$r5" "$state" ;;
    esac
}

main() {
    local p active=0 dot q1 q2 q3 c1 c2 img
    for p in "${PROVIDERS[@]}"; do "${p}_fetch" & done
    wait
    if recent_activity; then active=1; dot="🔴"; else dot="⚪"; fi
    q1=$(claude_bar)
    q2=$(codex_bar)
    q3=$(antigravity_bar)
    c1=$(openrouter_bar)
    c2=$(deepseek_bar)
    local render_bin="$PLUGIN_DIR/lib/render-bar" render_src="$PLUGIN_DIR/lib/render-bar.swift"
    if [[ -f "$render_src" && ( ! -x "$render_bin" || "$render_src" -nt "$render_bin" ) ]]; then
        swiftc -O "$render_src" -o "$render_bin" 2>/dev/null || true
    fi
    if [[ -x "$render_bin" ]] && img=$("$render_bin" "$active" "$q1" "$q2" "$q3" "$c1" "$c2" "$BAR_FONT" 2>/dev/null) && [[ -n "$img" ]]; then
        printf '| image=%s\n' "$img"
    else
        printf '%s %s %s %s %s %s | font=%s size=12\n' "$dot" "$c1" "$c2" "$q1" "$q2" "$q3" "$BAR_FONT"
    fi
    printf -- '---\n'
    for p in "${QUOTA_PROVIDERS[@]}"; do "${p}_menu"; done
    printf -- '---\n'
    for p in "${CREDIT_PROVIDERS[@]}"; do "${p}_menu"; done
    printf -- '---\n'
    printf 'Refresh | refresh=true\n'
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main
