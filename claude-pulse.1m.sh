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
CODEX_CACHE="$CACHE_DIR/claude-pulse-codex.json"        # snapshot the segment renders

CODEX_W7D=604800   # weekly window length, seconds; rolls a stale reset forward

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

# ---- Codex: 7d plan quota, reconstructed from session rollouts ----
# Codex has no usage endpoint; the number lives in the rate_limits of each session's
# token_count events, tagged with the event's own ISO-8601 timestamp and written
# whenever you run Codex. The live snapshot is the "codex" weekly entry with the latest
# timestamp. Ranking on the event time, not the peak used_percent, lets the bar follow
# a reset or refund downward; ranking on the event time, not the file mtime, keeps a
# resumed old session from winning with a stale entry. The limit_id filter drops an
# experimental bucket (codex_bengalfox, the GPT-5.3-Codex-Spark model) that sits at 0%
# unrelated to the plan quota. A window reset just zeroes used_percent in the next
# rollout; codex_segment and countdown cover a pre-reset snapshot until then.
#
# Rollout files run to gigabytes and rate_limits appears on nearly every line, so
# reading them whole costs ~25s. The latest reading is always near a file's end, so
# read only each file's tail: bounded work regardless of file size.
codex_fetch() {
    local roll
    roll=$(
        find "$CODEX_DIR/sessions" -type f -name '*.jsonl' -mtime -7 2>/dev/null |
            while IFS= read -r f; do tail -n 400 "$f"; done |
            jq -c '
                (.rate_limits // .payload.rate_limits) as $rl
                | select($rl != null) | select(($rl.limit_id // "codex") == "codex")
                | (.timestamp // .payload.timestamp // "") as $t
                | ($rl.primary, $rl.secondary)
                | select(type == "object" and (.window_minutes // 0) >= 1440)
                | { t: $t, s: (.used_percent // 0), sr: (.resets_at // 0) }' 2>/dev/null |
            jq -s '(max_by(.t) // empty) | {s, sr}')
    if [[ -n "$roll" ]]; then
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
