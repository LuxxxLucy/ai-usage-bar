#!/bin/bash
# SwiftBar plugin: working-state dot + OR/DS/CC/Codex usage.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

CLAUDE_DIR="$HOME/.claude"
CODEX_DIR="$HOME/.codex"
CACHE_DIR="${TMPDIR:-/tmp}"
CC_CACHE="$CACHE_DIR/claude-pulse-cc.json"
OR_CACHE="$CACHE_DIR/claude-pulse-or.json"
DS_CACHE="$CACHE_DIR/claude-pulse-ds.json"
CODEX_CACHE="$CACHE_DIR/claude-pulse-codex.json"

# Codex has no free usage endpoint; the live quota rides on response headers of an
# accepted POST to /responses (one minimal generation per poll). Poll at most every
# CODEX_TTL seconds, or immediately when a window's reset is due, to bound that cost.
CODEX_TTL=600
CODEX_W5H=18000    # primary window: 5h
CODEX_W7D=604800   # secondary window: 7d

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
    local reset_at="$1" window="${2:-0}" reset_epoch seconds_left now
    [[ -z "$reset_at" || "$reset_at" == null ]] && return
    if [[ "$reset_at" =~ ^[0-9]+$ ]]; then
        reset_epoch="$reset_at"
    else
        reset_at="${reset_at%%.*}"
        reset_at="${reset_at%%+*}"
        reset_at="${reset_at%Z}"
        reset_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$reset_at" "+%s" 2>/dev/null) || return
    fi

    now=$(date "+%s")
    # Stale snapshot: if the stored reset already passed, the window rolled over.
    # Advance by whole windows so the countdown points at the next real reset.
    if ((window > 0)); then
        while ((reset_epoch <= now)); do reset_epoch=$((reset_epoch + window)); done
    fi
    seconds_left=$((reset_epoch - now))
    ((seconds_left <= 0)) && echo now && return
    ((seconds_left < 3600)) && echo "$((seconds_left / 60))m" && return
    ((seconds_left < 86400)) && echo "$((seconds_left / 3600))h$((seconds_left % 3600 / 60))m" && return
    echo "$((seconds_left / 86400))d$((seconds_left % 86400 / 3600))h"
}

quota_segment() {
    local label="$1" seven="$2" five="$3" seven_reset="$4" five_reset="$5" state="$6"
    local seven_win="${7:-0}" five_win="${8:-0}"
    local seven_left five_left
    seven_left=$(countdown "$seven_reset" "$seven_win")
    five_left=$(countdown "$five_reset" "$five_win")
    # A reset countdown only means something when there is usage to reset. At 0%
    # the window is idle (and rolling, so any reset_at is just an artifact) — drop it.
    printf '%s%s: 7d:%.0f%%' "$(state_icon "$state")" "$label" "$seven"
    [[ -n "$seven_left" ]] && (($(printf '%.0f' "$seven") > 0)) && printf '(%s)' "$seven_left"
    printf ' 5h:%.0f%%' "$five"
    [[ -n "$five_left" ]] && (($(printf '%.0f' "$five") > 0)) && printf '(%s)' "$five_left"
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

# Free source: newest rollout's last token_count rate_limits, normalized to
# {p,s,pr,sr,ts}. ts is the file mtime — when that snapshot was last written.
codex_rollout_json() {
    local file line ts
    find "$CODEX_DIR/sessions" -type f -name '*.jsonl' -mtime -7 -exec stat -f $'%m\t%N' {} + 2>/dev/null |
        sort -rn |
        cut -f2- |
        while IFS= read -r file; do
            line=$(jq -c '(.rate_limits // .payload.rate_limits) | select(.primary and .secondary)' "$file" 2>/dev/null | tail -n 1)
            if [[ -n "$line" ]]; then
                ts=$(stat -f '%m' "$file")
                printf '%s' "$line" | jq -c --argjson ts "$ts" \
                    '{p:(.primary.used_percent//0), s:(.secondary.used_percent//0), pr:(.primary.resets_at//0), sr:(.secondary.resets_at//0), ts:$ts}'
                break
            fi
        done
}

# Live source: the only authoritative quota (catches off-machine / rescue-runtime /
# cloud usage that writes no local rollout). One minimal accepted generation; the
# x-codex-* response headers carry the limits. store:false writes no rollout.
fetch_codex_live() {
    local token acc model hdr now p s pr sr pra sra
    token=$(jq -r '.tokens.access_token // empty' "$CODEX_DIR/auth.json" 2>/dev/null)
    acc=$(jq -r '.tokens.account_id // empty' "$CODEX_DIR/auth.json" 2>/dev/null)
    [[ -z "$token" ]] && return 1
    model=$(awk -F'"' '/^model[[:space:]]*=/{print $2; exit}' "$CODEX_DIR/config.toml" 2>/dev/null)
    [[ -z "$model" ]] && model="gpt-5.5"

    hdr=$(mktemp)
    curl -s --max-time 6 -D "$hdr" -o /dev/null -X POST \
        -H "Authorization: Bearer $token" -H "chatgpt-account-id: $acc" \
        -H "Content-Type: application/json" -H "OpenAI-Beta: responses=experimental" \
        -H "originator: codex_cli_rs" -H "User-Agent: codex_cli_rs" \
        -H "session_id: 00000000-0000-0000-0000-000000000000" \
        -d '{"model":"'"$model"'","instructions":"x","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":""}]}],"stream":true,"store":false,"reasoning":{"effort":"low"}}' \
        "https://chatgpt.com/backend-api/codex/responses"

    hv() { grep -i "^$1:" "$hdr" | tail -1 | tr -d '\r' | sed -E "s/^[^:]+:[[:space:]]*//"; }
    p=$(hv x-codex-primary-used-percent)
    s=$(hv x-codex-secondary-used-percent)
    pr=$(hv x-codex-primary-reset-at)
    sr=$(hv x-codex-secondary-reset-at)
    pra=$(hv x-codex-primary-reset-after-seconds)
    sra=$(hv x-codex-secondary-reset-after-seconds)
    rm -f "$hdr"

    [[ -z "$p" ]] && return 1   # no headers => request rejected / auth stale
    now=$(date "+%s")
    # Prefer absolute reset-at; fall back to now + reset-after-seconds.
    { [[ -z "$pr" || "$pr" == 0 ]] && [[ -n "$pra" && "$pra" != 0 ]]; } && pr=$((now + pra))
    { [[ -z "$sr" || "$sr" == 0 ]] && [[ -n "$sra" && "$sra" != 0 ]]; } && sr=$((now + sra))
    jq -n --argjson p "${p:-0}" --argjson s "${s:-0}" \
          --argjson pr "${pr:-0}" --argjson sr "${sr:-0}" --argjson ts "$now" \
          '{p:$p,s:$s,pr:$pr,sr:$sr,ts:$ts}' >"$CODEX_CACHE"
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

CODEX_NOW=$(date "+%s")
CODEX_ROLL=$(codex_rollout_json)
CODEX_CACHE_TS=0
[[ -s "$CODEX_CACHE" ]] && CODEX_CACHE_TS=$(jq -r '.ts // 0' "$CODEX_CACHE" 2>/dev/null)

# Network poll only when it can change the answer: cache missing, past TTL, or a
# window's reset is due (so we replace a stale pre-reset percent with the live one).
CODEX_DUE=0
if [[ ! -s "$CODEX_CACHE" ]]; then
    CODEX_DUE=1
elif ((CODEX_NOW - CODEX_CACHE_TS >= CODEX_TTL)); then
    CODEX_DUE=1
else
    CODEX_CPR=$(jq -r '.pr // 0' "$CODEX_CACHE" 2>/dev/null)
    ((CODEX_CPR > 0 && CODEX_NOW >= CODEX_CPR)) && CODEX_DUE=1
fi
if ((CODEX_DUE)); then
    fetch_codex_live && CODEX_CACHE_TS=$(jq -r '.ts // 0' "$CODEX_CACHE" 2>/dev/null)
fi

# Display the freshest source (live cache vs newest rollout), by snapshot time.
CODEX_ROLL_TS=0
[[ -n "$CODEX_ROLL" ]] && CODEX_ROLL_TS=$(printf '%s' "$CODEX_ROLL" | jq -r '.ts // 0')
CODEX_SRC=""
if [[ -s "$CODEX_CACHE" ]] && ((CODEX_CACHE_TS >= CODEX_ROLL_TS)); then
    CODEX_SRC=$(cat "$CODEX_CACHE")
elif [[ -n "$CODEX_ROLL" ]]; then
    CODEX_SRC="$CODEX_ROLL"
fi

if [[ -n "$CODEX_SRC" ]]; then
    read -r CODEX_5H CODEX_7D CODEX_5H_RESET CODEX_7D_RESET < <(
        printf '%s' "$CODEX_SRC" | jq -r '[.p, .s, .pr, .sr] | @tsv'
    )
    # Elapsed window => usage reset; show 0 instead of the stale pre-reset percent.
    ((CODEX_5H_RESET > 0 && CODEX_NOW >= CODEX_5H_RESET)) && CODEX_5H=0
    ((CODEX_7D_RESET > 0 && CODEX_NOW >= CODEX_7D_RESET)) && CODEX_7D=0
    CODEX_SEG=$(quota_segment Codex "$CODEX_7D" "$CODEX_5H" "$CODEX_7D_RESET" "$CODEX_5H_RESET" ok "$CODEX_W7D" "$CODEX_W5H")
else
    CODEX_SEG="Codex:no data"
fi

echo "${DOT}${OR_SEG} ${DS_SEG} ${CC_SEG} ${CODEX_SEG} | font=BerkeleyMono-Bold size=13"
