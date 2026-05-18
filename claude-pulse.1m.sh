#!/bin/bash
# SwiftBar plugin: working-state dot + OR/DS/CC/Codex usage.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

CLAUDE_DIR="$HOME/.claude"
CODEX_DIR="$HOME/.codex"
CACHE_DIR="${TMPDIR:-/tmp}"
CC_CACHE="$CACHE_DIR/claude-pulse-cc.json"
OR_CACHE="$CACHE_DIR/claude-pulse-or.json"
DS_CACHE="$CACHE_DIR/claude-pulse-ds.json"

TMP_CC=$(mktemp)
TMP_OR=$(mktemp)
TMP_DS=$(mktemp)
trap 'rm -f "$TMP_CC" "$TMP_OR" "$TMP_DS"' EXIT

keychain_secret() {
    security find-generic-password -s "$1" -w 2>/dev/null
}

state_icon() {
    case "$1" in stale) printf '⏳' ;; down) printf '⚠️' ;; esac
}

countdown() {
    local reset_at="$1" reset_epoch seconds_left
    [[ -z "$reset_at" || "$reset_at" == null ]] && return
    if [[ "$reset_at" =~ ^[0-9]+$ ]]; then
        reset_epoch="$reset_at"
    else
        reset_at="${reset_at%%.*}"
        reset_at="${reset_at%%+*}"
        reset_at="${reset_at%Z}"
        reset_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$reset_at" "+%s" 2>/dev/null) || return
    fi

    seconds_left=$((reset_epoch - $(date "+%s")))
    ((seconds_left <= 0)) && echo now && return
    ((seconds_left < 3600)) && echo "$((seconds_left / 60))m" && return
    ((seconds_left < 86400)) && echo "$((seconds_left / 3600))h$((seconds_left % 3600 / 60))m" && return
    echo "$((seconds_left / 86400))d$((seconds_left % 86400 / 3600))h"
}

quota_segment() {
    local label="$1" seven="$2" five="$3" seven_reset="$4" five_reset="$5" state="$6"
    local seven_left five_left
    seven_left=$(countdown "$seven_reset")
    five_left=$(countdown "$five_reset")
    printf '%s%s: 7d:%.0f%%' "$(state_icon "$state")" "$label" "$seven"
    [[ -n "$seven_left" ]] && printf '(%s)' "$seven_left"
    printf ' 5h:%.0f%%' "$five"
    [[ -n "$five_left" ]] && printf '(%s)' "$five_left"
}

cache_state() {
    local fresh="$1" cache="$2" state_var="$3"
    if [[ -s "$fresh" ]] && ! jq -e '.error' <"$fresh" >/dev/null 2>&1; then
        cp "$fresh" "$cache"
        printf -v "$state_var" ok
    elif [[ -s "$cache" ]]; then
        printf -v "$state_var" stale
    else
        printf -v "$state_var" down
    fi
}

recent_activity() {
    local cutoff
    cutoff=$(($(date "+%s") - 90))
    {
        find "$CLAUDE_DIR/projects" -type f -name '*.jsonl' -mtime -1 -exec stat -f '%m' {} + 2>/dev/null
        find "$CODEX_DIR/sessions" -type f -name '*.jsonl' -mtime -1 -exec stat -f '%m' {} + 2>/dev/null
    } | awk -v cutoff="$cutoff" '$1 >= cutoff { found = 1 } END { exit !found }'
}

latest_codex_limits() {
    local line
    find "$CODEX_DIR/sessions" -type f -name '*.jsonl' -mtime -7 -exec stat -f $'%m\t%N' {} + 2>/dev/null |
        sort -rn |
        cut -f2- |
        while IFS= read -r file; do
            line=$(jq -c '(.rate_limits // .payload.rate_limits) | select(.primary and .secondary)' "$file" 2>/dev/null | tail -n 1)
            [[ -n "$line" ]] && echo "$line" && break
        done
}

TOKEN=$(keychain_secret "Claude Code-credentials" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
OR_KEY=$(keychain_secret "openrouter-api-key")
DS_KEY=$(keychain_secret "deepseek-api-key")

{ [[ -n "$TOKEN" ]] && curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $TOKEN" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-code/2.0.31" >"$TMP_CC"; } &
{ [[ -n "$OR_KEY" ]] && curl -s --max-time 5 "https://openrouter.ai/api/v1/credits" \
    -H "Authorization: Bearer $OR_KEY" >"$TMP_OR"; } &
{ [[ -n "$DS_KEY" ]] && curl -s --max-time 5 "https://api.deepseek.com/user/balance" \
    -H "Authorization: Bearer $DS_KEY" >"$TMP_DS"; } &
wait

CC_STATE=absent
OR_STATE=absent
DS_STATE=absent
[[ -n "$TOKEN" ]] && cache_state "$TMP_CC" "$CC_CACHE" CC_STATE
[[ -n "$OR_KEY" ]] && cache_state "$TMP_OR" "$OR_CACHE" OR_STATE
[[ -n "$DS_KEY" ]] && cache_state "$TMP_DS" "$DS_CACHE" DS_STATE

recent_activity && DOT="🔴 " || DOT="⚪ "

case "$OR_STATE" in
    absent) OR_SEG="OR:no key" ;;
    down) OR_SEG="$(state_icon down)OR:" ;;
    *)
        read -r OR_TOTAL OR_USED < <(jq -r '[.data.total_credits // 0, .data.total_usage // 0] | @tsv' "$OR_CACHE")
        OR_SEG="$(state_icon "$OR_STATE")OR:$(printf '$%.2f/$%.0f' "$OR_USED" "$OR_TOTAL")"
        ;;
esac

case "$DS_STATE" in
    absent) DS_SEG="DS:no key" ;;
    down) DS_SEG="$(state_icon down)DS:" ;;
    *)
        DS_BALANCE=$(jq -r '.balance_infos[0].total_balance // 0' "$DS_CACHE")
        DS_SEG="$(state_icon "$DS_STATE")DS:$(printf '¥%.2f' "$DS_BALANCE")"
        ;;
esac

case "$CC_STATE" in
    absent | down) CC_SEG="$(state_icon "$CC_STATE")CC:" ;;
    *)
        read -r CC_7D CC_5H CC_7D_RESET CC_5H_RESET < <(
            jq -r '[.seven_day.utilization // 0, .five_hour.utilization // 0, .seven_day.resets_at // "", .five_hour.resets_at // ""] | @tsv' "$CC_CACHE"
        )
        CC_SEG=$(quota_segment CC "$CC_7D" "$CC_5H" "$CC_7D_RESET" "$CC_5H_RESET" "$CC_STATE")
        ;;
esac

CODEX_LIMITS=$(latest_codex_limits)
if [[ -n "$CODEX_LIMITS" ]]; then
    read -r CODEX_7D CODEX_5H CODEX_7D_RESET CODEX_5H_RESET < <(
        printf '%s\n' "$CODEX_LIMITS" |
            jq -r '[.secondary.used_percent // 0, .primary.used_percent // 0, .secondary.resets_at // "", .primary.resets_at // ""] | @tsv'
    )
    CODEX_SEG=$(quota_segment Codex "$CODEX_7D" "$CODEX_5H" "$CODEX_7D_RESET" "$CODEX_5H_RESET" ok)
else
    CODEX_SEG="Codex:no data"
fi

echo "${DOT}${OR_SEG} ${DS_SEG} ${CC_SEG} ${CODEX_SEG} | font=BerkeleyMono-Bold size=13"
