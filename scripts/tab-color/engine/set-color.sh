#!/bin/bash
# Tab Color Engine v3 — 유일한 색상 변경 진입점
# 사용법: set-color.sh <state> [project]
# config.json 읽어서 escape code 적용 + 상태 저장

set -euo pipefail

STATE="${1:-idle}"
PROJECT="${2:-}"
CONFIG="$HOME/.claude/tab-color/config.json"
STATE_DIR="$HOME/.claude/tab-color/states"
LOG_FILE="$HOME/.claude/tab-color/logs/color.log"

# --- 로그 ---
_log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null; }

# --- config 읽기 (jq 우선, python3 fallback) ---
_config() {
    local KEY="$1" DEFAULT="${2:-}"
    if command -v jq &>/dev/null; then
        jq -r "$KEY // \"$DEFAULT\"" "$CONFIG" 2>/dev/null || echo "$DEFAULT"
    else
        python3 -c "
import json, sys
try:
    d = json.load(open('$CONFIG'))
    keys = '$KEY'.lstrip('.').split('.')
    v = d
    for k in keys:
        v = v[k]
    print(v if v is not None else '$DEFAULT')
except:
    print('$DEFAULT')
" 2>/dev/null || echo "$DEFAULT"
    fi
}

# --- TTY 찾기 (깊이 15) ---
find_tty() {
    [ -n "${TAB_TTY:-}" ] && [ -c "$TAB_TTY" ] && { echo "$TAB_TTY"; return; }
    [ -n "${TTY:-}" ] && [ -c "$TTY" ] && { echo "$TTY"; return; }
    local PID=$$
    for i in $(seq 1 15); do
        local TTY_DEV
        TTY_DEV=$(ps -o tty= -p "$PID" 2>/dev/null | tr -d ' ')
        [ -n "$TTY_DEV" ] && [ "$TTY_DEV" != "??" ] && [ -c "/dev/$TTY_DEV" ] && { echo "/dev/$TTY_DEV"; return; }
        local CUR_PPID
        CUR_PPID=$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')
        [ -z "$CUR_PPID" ] || [ "$CUR_PPID" = "1" ] || [ "$CUR_PPID" = "0" ] && break
        PID=$CUR_PPID
    done
}

# --- 프로젝트명 매핑 ---
_map_project() {
    local RAW="${1:-$(basename "$PWD")}"
    if command -v jq &>/dev/null; then
        local MAPPED
        MAPPED=$(jq -r ".project_names[\"$RAW\"] // \"$RAW\"" "$CONFIG" 2>/dev/null)
        echo "${MAPPED:-$RAW}"
    else
        python3 -c "
import json
d = json.load(open('$CONFIG'))
print(d.get('project_names', {}).get('$RAW', '$RAW'))
" 2>/dev/null || echo "$RAW"
    fi
}

# --- 상태 저장 ---
_save_state() {
    local TTY_NAME="$1" PROJECT="$2" R="$3" G="$4" B="$5"
    local JSON_FILE="$STATE_DIR/${TTY_NAME}.json"
    local ESCAPED_PROJECT
    ESCAPED_PROJECT=$(printf '%s' "$PROJECT" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"session_id":"%s","type":"%s","project":"%s","tty":"/dev/%s","pid":%d,"timestamp":"%s","color":{"r":%d,"g":%d,"b":%d}}\n' \
        "$TTY_NAME" "$STATE" "$ESCAPED_PROJECT" "$TTY_NAME" $$ \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$R" "$G" "$B" > "$JSON_FILE"
}

# --- 메인 ---
TTY_PATH=$(find_tty)
[ -z "$TTY_PATH" ] && { _log "TTY not found for state=$STATE"; exit 0; }
TTY_NAME="${TTY_PATH#/dev/}"

# config에서 색상 읽기
if command -v jq &>/dev/null; then
    READ_COLOR=$(jq -r ".states[\"$STATE\"] | \"\(.color[0])|\(.color[1])|\(.color[2])\"" "$CONFIG" 2>/dev/null)
else
    READ_COLOR=$(python3 -c "
import json
d = json.load(open('$CONFIG'))
c = d['states'].get('$STATE', {}).get('color', [128,128,128])
print(f'{c[0]}|{c[1]}|{c[2]}')
" 2>/dev/null)
fi
R=$(echo "$READ_COLOR" | cut -d'|' -f1)
G=$(echo "$READ_COLOR" | cut -d'|' -f2)
B=$(echo "$READ_COLOR" | cut -d'|' -f3)
R=${R:-128}; G=${G:-128}; B=${B:-128}

# 프로젝트명 매핑
[ -z "$PROJECT" ] && PROJECT=$(basename "$PWD")
PROJECT=$(_map_project "$PROJECT")

# 탭 제목 prefix
if command -v jq &>/dev/null; then
    PREFIX=$(jq -r ".states[\"$STATE\"].title_prefix // \"\"" "$CONFIG" 2>/dev/null)
else
    PREFIX=$(python3 -c "
import json
d = json.load(open('$CONFIG'))
print(d['states'].get('$STATE', {}).get('title_prefix', ''))
" 2>/dev/null)
fi
TITLE="${PREFIX:+$PREFIX }${PROJECT}"

# escape code 적용
printf '\e]1;%s\a' "$TITLE" > "$TTY_PATH" 2>/dev/null
printf '\e]6;1;bg;red;brightness;%s\a\e]6;1;bg;green;brightness;%s\a\e]6;1;bg;blue;brightness;%s\a' \
    "$R" "$G" "$B" > "$TTY_PATH" 2>/dev/null

# tmux -CC 모드: 윈도우 이름으로 탭 제목 설정 (OSC 1은 tmux가 가로채므로)
if [ -n "${TMUX:-}" ]; then
    CURRENT_WINDOW=$(tmux display-message -p '#I' 2>/dev/null)
    [ -n "$CURRENT_WINDOW" ] && tmux rename-window -t "$CURRENT_WINDOW" "$TITLE" 2>/dev/null || true
fi

# badge
BADGE_ENABLED=$(jq -r '.badge_enabled // false' "$CONFIG" 2>/dev/null || echo "false")
if [ "$BADGE_ENABLED" = "true" ]; then
    if command -v jq &>/dev/null; then
        BADGE=$(jq -r ".states[\"$STATE\"].badge // \"\"" "$CONFIG" 2>/dev/null)
    else
        BADGE=$(python3 -c "import json; d=json.load(open('$CONFIG')); print(d['states'].get('$STATE',{}).get('badge',''))" 2>/dev/null)
    fi
    [ -n "$BADGE" ] && printf '\e]1337;SetBadgeFormat=%s\a' "$(printf '%s' "$BADGE" | base64)" > "$TTY_PATH" 2>/dev/null
fi

# 상태 저장 (JSON — tab-color/states/)
mkdir -p "$STATE_DIR"
_save_state "$TTY_NAME" "$PROJECT" "$R" "$G" "$B"


# flash 처리
FLASH=$(jq -r ".states[\"$STATE\"].flash // false" "$CONFIG" 2>/dev/null || echo "false")
FLASH_ENGINE="$HOME/.claude/tab-color/engine/flash.sh"

if [ "$FLASH" = "true" ] && [ -f "$FLASH_ENGINE" ]; then
    FLASH_PID_FILE="/tmp/tab-flash-${TTY_NAME}.pid"
    # 기존 flash kill
    if [ -f "$FLASH_PID_FILE" ]; then
        OLD_PID=$(cat "$FLASH_PID_FILE" 2>/dev/null)
        [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null && rm -f "$FLASH_PID_FILE"
    fi
    bash "$FLASH_ENGINE" "$STATE" "$TTY_PATH" "$CONFIG" &
    echo $! > "$FLASH_PID_FILE"
    disown $!
elif [ "$STATE" != "attention" ] && [ "$STATE" != "crashed" ]; then
    # flash 아닌 상태로 전환 시 기존 flash kill
    FLASH_PID_FILE="/tmp/tab-flash-${TTY_NAME}.pid"
    if [ -f "$FLASH_PID_FILE" ]; then
        OLD_PID=$(cat "$FLASH_PID_FILE" 2>/dev/null)
        [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null
        rm -f "$FLASH_PID_FILE"
    fi
fi

# macOS 알림 (attention만)
NOTIFY=$(jq -r ".states[\"$STATE\"].macos_notify // false" "$CONFIG" 2>/dev/null || echo "false")
if [ "$NOTIFY" = "true" ]; then
    osascript -e "display notification \"$PROJECT 세션이 입력을 기다리고 있습니다\" with title \"Claude Code\" subtitle \"⚠️ Attention Required\"" 2>/dev/null &
fi

_log "state=$STATE project=$PROJECT tty=$TTY_NAME color=[$R,$G,$B]"
