#!/bin/bash
# SwiftBar plugin: working-state dot + OR/CC usage stats in the menubar.
# Filename: claude-pulse.1m.sh (refresh every 1 minute).

CLAUDE_DIR="$HOME/.claude"
CC_CACHE="/tmp/claude-pulse-cc.json"
OR_CACHE="/tmp/claude-pulse-or.json"
DS_CACHE="/tmp/claude-pulse-ds.json"

# --- Credentials ---
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
    | jq -r '.claudeAiOauth.accessToken // empty')
OR_KEY=$(security find-generic-password -s "openrouter-api-key" -w 2>/dev/null)
DS_KEY=$(security find-generic-password -s "deepseek-api-key" -w 2>/dev/null)

# --- Parallel fetch (5s timeout) ---
TMP_CC=$(mktemp); TMP_OR=$(mktemp); TMP_DS=$(mktemp)
trap 'rm -f "$TMP_CC" "$TMP_OR" "$TMP_DS"' EXIT

[[ -n "$TOKEN" ]] && curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $TOKEN" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-code/2.0.31" > "$TMP_CC" &
[[ -n "$OR_KEY" ]] && curl -s --max-time 5 https://openrouter.ai/api/v1/credits \
    -H "Authorization: Bearer $OR_KEY" > "$TMP_OR" &
[[ -n "$DS_KEY" ]] && curl -s --max-time 5 "https://api.deepseek.com/user/balance" \
    -H "Authorization: Bearer $DS_KEY" > "$TMP_DS" &
wait

# Per-segment state: absent | ok | stale | down. Fresh fetch wins, else cached, else down.
resolve() {
    local fresh="$1" cache="$2" out_var="$3"
    if [[ -s "$fresh" ]] && ! jq -e '.error' < "$fresh" >/dev/null 2>&1; then
        cp "$fresh" "$cache"
        printf -v "$out_var" 'ok'
    elif [[ -s "$cache" ]]; then
        printf -v "$out_var" 'stale'
    else
        printf -v "$out_var" 'down'
    fi
}
CC_STATE=absent; OR_STATE=absent; DS_STATE=absent
[[ -n "$TOKEN"  ]] && resolve "$TMP_CC" "$CC_CACHE" CC_STATE
[[ -n "$OR_KEY" ]] && resolve "$TMP_OR" "$OR_CACHE" OR_STATE
[[ -n "$DS_KEY" ]] && resolve "$TMP_DS" "$DS_CACHE" DS_STATE

mark() { case "$1" in stale) printf '⏳';; down) printf '⚠️';; esac; }

# --- Working-state: any session JSONL touched in last 90s ⇒ a turn is in flight.
if find "$CLAUDE_DIR/projects" -name '*.jsonl' -newermt '90 seconds ago' -print -quit 2>/dev/null | grep -q .; then
    DOT="🔴 "
else
    DOT="⚪ "
fi

# --- Format ISO timestamp → human "in 4d3h" / "in 8m".
remaining() {
    local ts="$1"
    [[ -z "$ts" || "$ts" == "null" ]] && return
    local clean="${ts%%.*}"; clean="${clean%%+*}"; clean="${clean%Z}"
    local epoch
    epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$clean" "+%s" 2>/dev/null) || return
    local diff=$(( epoch - $(date "+%s") ))
    if   (( diff <= 0 ));    then echo "now"
    elif (( diff < 3600 ));  then echo "$((diff / 60))m"
    elif (( diff < 86400 )); then echo "$((diff / 3600))h$((diff % 3600 / 60))m"
    else echo "$((diff / 86400))d$((diff % 86400 / 3600))h"
    fi
}

# --- OR segment ---
case "$OR_STATE" in
    absent) OR_SEG="OR:no key" ;;
    down)   OR_SEG="$(mark down)OR:" ;;
    ok|stale)
        { read -r OR_TOTAL; read -r OR_USED; } < <(
            jq -r '.data.total_credits // 0, .data.total_usage // 0' "$OR_CACHE"
        )
        read -r OR_USED_FMT OR_TOTAL_FMT < <(
            awk -v u="$OR_USED" -v t="$OR_TOTAL" 'BEGIN{ printf "%.2f %.0f", u, t }'
        )
        OR_SEG="$(mark "$OR_STATE")OR:\$${OR_USED_FMT}/\$${OR_TOTAL_FMT}"
        ;;
esac

# --- DS segment ---
case "$DS_STATE" in
    absent) DS_SEG="DS:no key" ;;
    down)   DS_SEG="$(mark down)DS:" ;;
    ok|stale)
        read -r DS_BALANCE DS_CURRENCY < <(
            jq -r '.balance_infos[0].total_balance // "0",
                   .balance_infos[0].currency    // "CNY"' "$DS_CACHE"
        )
        read -r DS_BAL_FMT < <(awk -v b="$DS_BALANCE" 'BEGIN{ printf "%.2f", b }')
        DS_SEG="$(mark "$DS_STATE")DS:¥${DS_BAL_FMT}"
        ;;
esac

# --- CC segment ---
case "$CC_STATE" in
    absent|down) CC_SEG="$(mark "$CC_STATE")CC:" ;;
    *)
        { read -r FIVE_UTIL; read -r SEVEN_UTIL; read -r FIVE_RESET; read -r SEVEN_RESET; } < <(
            jq -r '.five_hour.utilization // 0,
                   .seven_day.utilization // 0,
                   .five_hour.resets_at   // "",
                   .seven_day.resets_at   // ""' "$CC_CACHE"
        )
        FIVE_PCT=$(printf '%.0f' "$FIVE_UTIL")
        SEVEN_PCT=$(printf '%.0f' "$SEVEN_UTIL")
        FIVE_REM=$(remaining "$FIVE_RESET")
        SEVEN_REM=$(remaining "$SEVEN_RESET")
        if [[ -z "$FIVE_REM" && -z "$SEVEN_REM" ]]; then
            CC_SEG="$(mark "$CC_STATE")CC: 7d:${SEVEN_PCT}% 5h:${FIVE_PCT}%"
        else
            CC_SEG="$(mark "$CC_STATE")CC: 7d:${SEVEN_PCT}%(${SEVEN_REM}) 5h:${FIVE_PCT}%(${FIVE_REM})"
        fi
        ;;
esac

echo "${DOT}${OR_SEG} ${DS_SEG} ${CC_SEG} | font=BerkeleyMono-Bold size=13"
