#!/bin/bash
# SwiftBar plugin: working-state dot + OR/DS/CC/Codex usage.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

CLAUDE_DIR="$HOME/.claude"
CODEX_DIR="$HOME/.codex"
CC_CACHE="/tmp/claude-pulse-cc.json"
OR_CACHE="/tmp/claude-pulse-or.json"
DS_CACHE="/tmp/claude-pulse-ds.json"

TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null |
    jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
OR_KEY=$(security find-generic-password -s "openrouter-api-key" -w 2>/dev/null)
DS_KEY=$(security find-generic-password -s "deepseek-api-key" -w 2>/dev/null)

TMP_CC=$(mktemp)
TMP_OR=$(mktemp)
TMP_DS=$(mktemp)
trap 'rm -f "$TMP_CC" "$TMP_OR" "$TMP_DS"' EXIT

[[ -n "$TOKEN" ]] && curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $TOKEN" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-code/2.0.31" >"$TMP_CC" &
[[ -n "$OR_KEY" ]] && curl -s --max-time 5 "https://openrouter.ai/api/v1/credits" \
    -H "Authorization: Bearer $OR_KEY" >"$TMP_OR" &
[[ -n "$DS_KEY" ]] && curl -s --max-time 5 "https://api.deepseek.com/user/balance" \
    -H "Authorization: Bearer $DS_KEY" >"$TMP_DS" &
wait

resolve() {
    if [[ -s "$1" ]] && ! jq -e '.error' <"$1" >/dev/null 2>&1; then
        cp "$1" "$2"
        printf -v "$3" ok
    elif [[ -s "$2" ]]; then
        printf -v "$3" stale
    else
        printf -v "$3" down
    fi
}

mark() {
    case "$1" in
        stale) printf '⏳' ;;
        down) printf '⚠️' ;;
    esac
}

remaining() {
    local raw="$1" epoch diff
    [[ -z "$raw" || "$raw" == null ]] && return
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        epoch="$raw"
    else
        raw="${raw%%.*}"
        raw="${raw%%+*}"
        raw="${raw%Z}"
        epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$raw" "+%s" 2>/dev/null) || return
    fi
    diff=$((epoch - $(date "+%s")))
    ((diff <= 0)) && echo now && return
    ((diff < 3600)) && echo "$((diff / 60))m" && return
    ((diff < 86400)) && echo "$((diff / 3600))h$((diff % 3600 / 60))m" && return
    echo "$((diff / 86400))d$((diff % 86400 / 3600))h"
}

usage_segment() {
    local label="$1" seven="$2" five="$3" seven_reset="$4" five_reset="$5" state="$6"
    local seven_rem five_rem
    seven_rem=$(remaining "$seven_reset")
    five_rem=$(remaining "$five_reset")
    if [[ -n "$seven_rem" || -n "$five_rem" ]]; then
        printf '%s%s: 7d:%.0f%%(%s) 5h:%.0f%%(%s)' "$(mark "$state")" "$label" "$seven" "$seven_rem" "$five" "$five_rem"
    else
        printf '%s%s: 7d:%.0f%% 5h:%.0f%%' "$(mark "$state")" "$label" "$seven" "$five"
    fi
}

recent_jsonl() {
    local cutoff
    cutoff=$(($(date "+%s") - 90))
    find "$1" -type f -name '*.jsonl' -mtime -1 -print 2>/dev/null |
        xargs stat -f '%m' 2>/dev/null |
        awk -v cutoff="$cutoff" '$1 >= cutoff { found = 1 } END { exit !found }'
}

codex_line() {
    find "$CODEX_DIR/sessions" -type f -name '*.jsonl' -mtime -7 -print 2>/dev/null |
        xargs stat -f '%m %N' 2>/dev/null |
        sort -rn |
        while read -r _ file; do
            line=$(jq -c 'select((.rate_limits // .payload.rate_limits).primary and (.rate_limits // .payload.rate_limits).secondary)' "$file" 2>/dev/null | tail -n 1)
            [[ -n "$line" ]] && echo "$line" && break
        done
}

CC_STATE=absent
OR_STATE=absent
DS_STATE=absent
[[ -n "$TOKEN" ]] && resolve "$TMP_CC" "$CC_CACHE" CC_STATE
[[ -n "$OR_KEY" ]] && resolve "$TMP_OR" "$OR_CACHE" OR_STATE
[[ -n "$DS_KEY" ]] && resolve "$TMP_DS" "$DS_CACHE" DS_STATE

if recent_jsonl "$CLAUDE_DIR/projects" || recent_jsonl "$CODEX_DIR/sessions"; then
    DOT="🔴 "
else
    DOT="⚪ "
fi

case "$OR_STATE" in
    absent) OR_SEG="OR:no key" ;;
    down) OR_SEG="$(mark down)OR:" ;;
    *)
        read -r OR_TOTAL OR_USED < <(jq -r '[.data.total_credits // 0, .data.total_usage // 0] | @tsv' "$OR_CACHE")
        OR_SEG="$(mark "$OR_STATE")OR:\$$(printf '%.2f' "$OR_USED")/\$$(printf '%.0f' "$OR_TOTAL")"
        ;;
esac

case "$DS_STATE" in
    absent) DS_SEG="DS:no key" ;;
    down) DS_SEG="$(mark down)DS:" ;;
    *)
        DS_BALANCE=$(jq -r '.balance_infos[0].total_balance // 0' "$DS_CACHE")
        DS_SEG="$(mark "$DS_STATE")DS:¥$(printf '%.2f' "$DS_BALANCE")"
        ;;
esac

case "$CC_STATE" in
    absent | down) CC_SEG="$(mark "$CC_STATE")CC:" ;;
    *)
        read -r CC_7D CC_5H CC_7D_RESET CC_5H_RESET < <(
            jq -r '[.seven_day.utilization // 0, .five_hour.utilization // 0, .seven_day.resets_at // "", .five_hour.resets_at // ""] | @tsv' "$CC_CACHE"
        )
        CC_SEG="$(usage_segment CC "$CC_7D" "$CC_5H" "$CC_7D_RESET" "$CC_5H_RESET" "$CC_STATE")"
        ;;
esac

CODEX_LINE=$(codex_line)
if [[ -n "$CODEX_LINE" ]]; then
    read -r CODEX_7D CODEX_5H CODEX_7D_RESET CODEX_5H_RESET < <(
        printf '%s\n' "$CODEX_LINE" |
            jq -r '(.rate_limits // .payload.rate_limits) | [.secondary.used_percent // 0, .primary.used_percent // 0, .secondary.resets_at // "", .primary.resets_at // ""] | @tsv'
    )
    CODEX_SEG="$(usage_segment Codex "$CODEX_7D" "$CODEX_5H" "$CODEX_7D_RESET" "$CODEX_5H_RESET" ok)"
else
    CODEX_SEG="Codex:no data"
fi

echo "${DOT}${OR_SEG} ${DS_SEG} ${CC_SEG} ${CODEX_SEG} | font=BerkeleyMono-Bold size=13"
