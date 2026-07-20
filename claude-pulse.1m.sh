#!/bin/bash
# SwiftBar plugin: working-state dot + per-provider usage (OpenRouter, DeepSeek,
# Claude, Codex).
#
# Layout, top to bottom:
#   1. config       — paths, constants, the provider list
#   2. shared lib   — helpers every module reuses (secrets, fetch, render, time)
#   3. modules      — one <name>_fetch + <name>_segment pair per provider
#   4. display      — fan out the fetches, assemble the menu-bar line
#
# Add a provider: write <name>_fetch / <name>_segment and append <name> to
# PROVIDERS. The display layer needs no other change.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# ============================== 1. config ==============================

CLAUDE_DIR="$HOME/.claude"
CODEX_DIR="$HOME/.codex"
CACHE_DIR="${TMPDIR:-/tmp}"
OR_CACHE="$CACHE_DIR/claude-pulse-or.json"
DS_CACHE="$CACHE_DIR/claude-pulse-ds.json"
CC_CACHE="$CACHE_DIR/claude-pulse-cc.json"
CODEX_CACHE="$CACHE_DIR/claude-pulse-codex.json"        # resolved snapshot the segment renders
CODEX_POLL="$CACHE_DIR/claude-pulse-codex-poll.json"   # persistent live-poll cache; drives the TTL gate

# Codex has no free usage endpoint; its quota rides on the x-codex-* response
# headers of an accepted /responses POST (one minimal generation per poll). Poll
# at most every CODEX_TTL seconds, or when a window's reset is due, to bound cost.
CODEX_TTL=600
CODEX_W7D=604800

FONT="BerkeleyMono-Bold size=13"

# Render order and fetch set. Each name N needs N_fetch and N_segment.
PROVIDERS=(openrouter deepseek claude codex)

# ============================ 2. shared lib ===========================

keychain_secret() {
    security find-generic-password -s "$1" -w 2>/dev/null
}

# Health glyph prefixed to a segment: stale cache, or hard-down.
state_icon() {
    case "$1" in stale) printf '⏳' ;; down) printf '⚠️' ;; esac
}

# Persist / read a provider's freshness state (ok|stale|down|absent) beside its
# cache, so a fetch running in a background subshell can hand state to its segment.
set_state() { printf '%s' "$2" >"$1.state"; }
get_state() { cat "$1.state" 2>/dev/null; }

# GET a JSON endpoint into <cache>, keeping the last good copy on failure.
# Sets state ok (fresh), stale (kept old copy), or down (nothing to show).
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

# Seconds-until-<reset> as a compact string (45m, 2h13m, 5d17h), or "now".
# <reset> is a unix epoch or ISO-8601. With a positive <window> (seconds), a reset
# that already passed is rolled forward whole windows — so a stale rolling-window
# snapshot still reports the next real reset instead of "now".
countdown() {
    local reset_at="$1" window="${2:-0}" reset_epoch seconds_left now
    [[ -z "$reset_at" || "$reset_at" == null ]] && return
    if [[ "$reset_at" =~ ^[0-9]+$ ]]; then
        reset_epoch="$reset_at"
    else
        reset_at="${reset_at%%.*}"; reset_at="${reset_at%%+*}"; reset_at="${reset_at%Z}"
        reset_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$reset_at" "+%s" 2>/dev/null) || return
    fi
    now=$(date "+%s")
    ((reset_epoch <= 0)) && return   # 0/absent is "unknown", not a real reset time
    # Stale snapshot: a passed reset means the rolling window already rolled over.
    # Jump forward whole windows (O(1)) to the next real reset.
    if ((window > 0 && reset_epoch <= now)); then
        reset_epoch=$((reset_epoch + window * ((now - reset_epoch) / window + 1)))
    fi
    seconds_left=$((reset_epoch - now))
    ((seconds_left <= 0)) && echo now && return
    ((seconds_left < 3600)) && echo "$((seconds_left / 60))m" && return
    ((seconds_left < 86400)) && echo "$((seconds_left / 3600))h$((seconds_left % 3600 / 60))m" && return
    echo "$((seconds_left / 86400))d$((seconds_left % 86400 / 3600))h"
}

# Append "(countdown)" after a percent when a reset is worth showing: always for a
# fixed window (win==0, e.g. Claude's weekly reset), but for a rolling window
# (win>0, Codex) only once it has non-zero usage — an idle rolling window's reset
# is just noise.
quota_reset() {
    local left="$1" pct="$2" win="$3"
    [[ -n "$left" ]] && ((win == 0 || $(printf '%.0f' "$pct") > 0)) && printf '(%s)' "$left"
}

# Render a two-window quota segment: "<icon><label>: 7d:N% 5h:N%", each percent
# trailed by its reset countdown (see quota_reset). Shared by Claude and Codex.
# Args: label seven five seven_reset five_reset state [seven_window] [five_window]
render_quota() {
    local label="$1" seven="$2" five="$3" seven_reset="$4" five_reset="$5" state="$6"
    local seven_win="${7:-0}" five_win="${8:-0}"
    local seven_left five_left
    seven_left=$(countdown "$seven_reset" "$seven_win")
    five_left=$(countdown "$five_reset" "$five_win")
    printf '%s%s: 7d:%.0f%%' "$(state_icon "$state")" "$label" "$seven"
    quota_reset "$seven_left" "$seven" "$seven_win"
    printf ' 5h:%.0f%%' "$five"
    quota_reset "$five_left" "$five" "$five_win"
}

# Working-state dot: red when a Claude or Codex session wrote in the last 90s.
recent_activity() {
    local cutoff; cutoff=$(($(date "+%s") - 90))
    {
        find "$CLAUDE_DIR/projects" -type f -name '*.jsonl' -mtime -1 -exec stat -f '%m' {} + 2>/dev/null
        find "$CODEX_DIR/sessions" -type f -name '*.jsonl' -mtime -1 -exec stat -f '%m' {} + 2>/dev/null
    } | awk -v cutoff="$cutoff" '$1 >= cutoff { found = 1 } END { exit !found }'
}

# =========================== 3. modules ===============================
# Each provider exposes <name>_fetch (populate cache + state, runs in parallel)
# and <name>_segment (render the cached data to one menu-bar segment).

# ---- OpenRouter: prepaid credit balance ----
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

# ---- DeepSeek: prepaid balance ----
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

# ---- Claude: 7d / 5h utilization, live from the OAuth usage endpoint ----
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

# ---- Codex: 7d quota, reconstructed from two sources ----
# Free: the newest session rollout's last token_count rate_limits (instant when
# you actually run Codex). Authoritative: a gated live header poll that also
# catches off-machine / cloud / rescue-runtime usage leaving no local rollout.
# Both normalize to {s,sr,ts}: used-percent, reset epoch, snapshot time.
# codex_fetch owns all I/O — poll, scan, and resolve the fresher into CODEX_CACHE —
# so codex_segment is pure render, like every other module.

# Newest rollout snapshot, normalized; empty if no recent rollout. ts = file mtime.
codex_rollout_json() {
    local file ts line
    find "$CODEX_DIR/sessions" -type f -name '*.jsonl' -mtime -7 -exec stat -f $'%m\t%N' {} + 2>/dev/null |
        sort -rn | cut -f2- |
        while IFS= read -r file; do
            ts=$(stat -f '%m' "$file")
            line=$(jq -c --argjson ts "$ts" '
                (.rate_limits // .payload.rate_limits)
                | [ .primary, .secondary ]
                | map(select(. != null and (.window_minutes // 0) >= 1440))
                | first
                | { s:  (.used_percent // 0), sr: (.resets_at // 0),
                    ts: $ts }' "$file" 2>/dev/null | tail -n 1)
            [[ -n "$line" ]] && { printf '%s' "$line"; break; }
        done
}

# One minimal accepted generation; read the x-codex-* headers. store:false writes
# no rollout. Writes CODEX_POLL on success, leaves it untouched on failure.
codex_poll_live() {
    local token acc model hdr now
    read -r token acc < <(jq -r '[.tokens.access_token // "", .tokens.account_id // ""] | @tsv' "$CODEX_DIR/auth.json" 2>/dev/null)
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

    # Read one header value, numeric only (blank/garbage -> empty, never breaks jq).
    hv() {
        local v; v=$(grep -i "^$1:" "$hdr" | tail -1 | tr -d '\r' | sed -E "s/^[^:]+:[[:space:]]*//")
        [[ $v =~ ^[0-9]+([.][0-9]+)?$ ]] && printf '%s' "$v"
    }
    now=$(date "+%s")
    local pu su pw sw pra sra prf srf used reset
    pu=$(hv x-codex-primary-used-percent);         su=$(hv x-codex-secondary-used-percent)
    pw=$(hv x-codex-primary-window-minutes);       sw=$(hv x-codex-secondary-window-minutes)
    pra=$(hv x-codex-primary-reset-at);            sra=$(hv x-codex-secondary-reset-at)
    prf=$(hv x-codex-primary-reset-after-seconds); srf=$(hv x-codex-secondary-reset-after-seconds)
    rm -f "$hdr"

    [[ -z "$pu" && -z "$su" ]] && return 1

    # Resolve a slot's reset epoch: absolute reset-at, else now + reset-after, else 0.
    reset_epoch() { local r="$1" a="$2"
        if [[ -n "$r" && "$r" != 0 ]]; then printf '%s' "$r"
        elif [[ -n "$a" && "$a" != 0 ]]; then printf '%s' "$((now + a))"
        else printf '0'; fi
    }
    if [[ -n "$pw" ]] && (( ${pw%.*} >= 1440 )); then
        used="${pu:-0}"; reset=$(reset_epoch "$pra" "$prf")
    elif [[ -n "$sw" ]] && (( ${sw%.*} >= 1440 )); then
        used="${su:-0}"; reset=$(reset_epoch "$sra" "$srf")
    else
        return 1
    fi

    jq -n --argjson s "$used" --argjson sr "$reset" --argjson ts "$now" \
          '{s:$s,sr:$sr,ts:$ts}' >"$CODEX_POLL"
}

codex_fetch() {
    local now ts=0 sr=0 poll="" poll_ts=0 roll roll_ts=0
    now=$(date "+%s")

    # 1. Live poll only when it can change the answer: no cache, past TTL, or the
    #    window's reset is due (replace a stale pre-reset percent with the live one).
    [[ -s "$CODEX_POLL" ]] && read -r ts sr < <(jq -r '[.ts // 0, .sr // 0] | @tsv' "$CODEX_POLL" 2>/dev/null)
    if ((!ts || now - ts >= CODEX_TTL)) || ((sr > 0 && now >= sr)); then
        codex_poll_live
    fi

    # 2. Resolve the fresher of poll-cache vs newest rollout into the display cache.
    [[ -s "$CODEX_POLL" ]] && { poll=$(cat "$CODEX_POLL"); poll_ts=$(jq -r '.ts // 0' <<<"$poll"); }
    roll=$(codex_rollout_json)
    [[ -n "$roll" ]] && roll_ts=$(jq -r '.ts // 0' <<<"$roll")
    if [[ -n "$poll" ]] && ((poll_ts >= roll_ts)); then
        printf '%s' "$poll" >"$CODEX_CACHE"; set_state "$CODEX_CACHE" ok
    elif [[ -n "$roll" ]]; then
        printf '%s' "$roll" >"$CODEX_CACHE"; set_state "$CODEX_CACHE" ok
    else
        set_state "$CODEX_CACHE" down
    fi
}

codex_segment() {
    local state now used reset left
    state=$(get_state "$CODEX_CACHE")
    [[ "$state" == ok ]] || { printf 'Codex:no data'; return; }
    now=$(date "+%s")
    read -r used reset < <(jq -r '[.s, .sr] | @tsv' "$CODEX_CACHE")
    # An elapsed window has reset; show 0 rather than the stale pre-reset percent.
    ((reset > 0 && now >= reset)) && used=0
    left=$(countdown "$reset" "$CODEX_W7D")
    printf 'Codex: 7d:%.0f%%' "$used"
    quota_reset "$left" "$used" "$CODEX_W7D"
}

# =========================== 4. display ===============================

main() {
    local p dot segs=()
    for p in "${PROVIDERS[@]}"; do "${p}_fetch" & done
    wait
    recent_activity && dot="🔴" || dot="⚪"
    for p in "${PROVIDERS[@]}"; do segs+=("$("${p}_segment")"); done
    printf '%s %s | font=%s\n' "$dot" "${segs[*]}" "$FONT"
}

main
