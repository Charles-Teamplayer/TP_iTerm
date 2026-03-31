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

# --- 로그 (5000줄 초과 시 2500줄 유지) ---
_log() {
    if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" 2>/dev/null)" -gt 5000 ] 2>/dev/null; then
        tail -2500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || true
    fi
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null
}

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
        { [ -z "$CUR_PPID" ] || [ "$CUR_PPID" = "1" ] || [ "$CUR_PPID" = "0" ]; } && break
        PID=$CUR_PPID
    done
}

# --- 프로젝트명 매핑 ---
_map_project() {
    local RAW="${1:-$(basename "$PWD")}"
    if command -v jq &>/dev/null; then
        local MAPPED
        MAPPED=$(jq -r --arg raw "$RAW" '.project_names[$raw] // $raw' "$CONFIG" 2>/dev/null)
        echo "${MAPPED:-$RAW}"
    else
        _MP_CFG="$CONFIG" _MP_RAW="$RAW" python3 -c "
import json, os
cfg=os.environ['_MP_CFG']; raw=os.environ['_MP_RAW']
d = json.load(open(cfg))
print(d.get('project_names', {}).get(raw, raw))
" 2>/dev/null || echo "$RAW"
    fi
}

# --- 상태 저장 ---
_save_state() {
    local TTY_NAME="$1" PROJECT="$2" R="$3" G="$4" B="$5"
    local JSON_FILE="$STATE_DIR/${TTY_NAME}.json"
    local ESCAPED_PROJECT
    ESCAPED_PROJECT=$(printf '%s' "$PROJECT" | sed 's/\\/\\\\/g; s/"/\\"/g')
    # iter57: CC_PROCESS_PID(tab-status.sh에서 전달된 실제 CC PID) 사용 — watchdog aging 방지
    local _STATE_PID=${CC_PROCESS_PID:-0}
    printf '{"session_id":"%s","type":"%s","project":"%s","tty":"/dev/%s","pid":%d,"timestamp":"%s","color":{"r":%d,"g":%d,"b":%d}}\n' \
        "$TTY_NAME" "$STATE" "$ESCAPED_PROJECT" "$TTY_NAME" $_STATE_PID \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$R" "$G" "$B" > "$JSON_FILE"
}

# --- 메인 ---
TTY_PATH=$(find_tty)
[ -z "$TTY_PATH" ] && { _log "TTY not found for state=$STATE"; exit 0; }
TTY_NAME="${TTY_PATH#/dev/}"

# TTY 쓰기 권한 체크 (Operation not permitted 방지 — set -e 환경에서 즉시 exit 방어)
if [ ! -w "$TTY_PATH" ]; then
    _log "SKIP: $TTY_NAME not writable (permission denied)"
    exit 0
fi

# tmux pane 보호: tmux에 속하지 않는 TTY (= Claude Code 자체 터미널 등)에는 색상 쓰지 않음
if ! tmux list-panes -a -F "#{pane_tty}" 2>/dev/null | grep -qxF "$TTY_PATH"; then
    _log "SKIP: $TTY_NAME is not a tmux pane (self-protection)"
    exit 0
fi

# config에서 색상 읽기
if command -v jq &>/dev/null; then
    READ_COLOR=$(jq -r --arg state "$STATE" '.states[$state] | "\(.color[0])|\(.color[1])|\(.color[2])"' "$CONFIG" 2>/dev/null)
else
    READ_COLOR=$(_SC_CFG="$CONFIG" _SC_ST="$STATE" python3 -c "
import json, os
d = json.load(open(os.environ['_SC_CFG']))
c = d['states'].get(os.environ['_SC_ST'], {}).get('color', [128,128,128])
print('|'.join(str(v) if v is not None else '128' for v in c[:3]))
" 2>/dev/null)
fi
R=$(echo "$READ_COLOR" | cut -d'|' -f1)
G=$(echo "$READ_COLOR" | cut -d'|' -f2)
B=$(echo "$READ_COLOR" | cut -d'|' -f3)
# "null"(jq), "None"(python3), 빈 문자열 모두 128 fallback
[[ -z "$R" || "$R" == "null" || "$R" == "None" ]] && R=128
[[ -z "$G" || "$G" == "null" || "$G" == "None" ]] && G=128
[[ -z "$B" || "$B" == "null" || "$B" == "None" ]] && B=128

# 프로젝트명 매핑
[ -z "$PROJECT" ] && PROJECT=$(basename "$PWD")
PROJECT=$(_map_project "$PROJECT")

# 탭 제목 prefix
if command -v jq &>/dev/null; then
    PREFIX=$(jq -r --arg state "$STATE" '.states[$state].title_prefix // ""' "$CONFIG" 2>/dev/null)
else
    PREFIX=$(_SC_CFG="$CONFIG" _SC_ST="$STATE" python3 -c "
import json, os
d = json.load(open(os.environ['_SC_CFG']))
print(d['states'].get(os.environ['_SC_ST'], {}).get('title_prefix', ''))
" 2>/dev/null)
fi
TITLE="${PREFIX:+$PREFIX }${PROJECT}"

# escape code 적용
printf '\e]1;%s\a' "$TITLE" > "$TTY_PATH" 2>/dev/null
printf '\e]6;1;bg;red;brightness;%s\a\e]6;1;bg;green;brightness;%s\a\e]6;1;bg;blue;brightness;%s\a' \
    "$R" "$G" "$B" > "$TTY_PATH" 2>/dev/null

# tmux rename-window 비활성화 — 창 이름이 원본 프로파일명으로 유지되어야 함
# (탭 색상/배지는 escape sequence로만 처리)

# badge
BADGE_ENABLED=$(jq -r '.badge_enabled // false' "$CONFIG" 2>/dev/null || echo "false")
if [ "$BADGE_ENABLED" = "true" ]; then
    if command -v jq &>/dev/null; then
        BADGE=$(jq -r --arg state "$STATE" '.states[$state].badge // ""' "$CONFIG" 2>/dev/null)
    else
        BADGE=$(_SC_CFG="$CONFIG" _SC_ST="$STATE" python3 -c "
import json, os
d=json.load(open(os.environ['_SC_CFG']))
print(d['states'].get(os.environ['_SC_ST'],{}).get('badge',''))
" 2>/dev/null)
    fi
    [ -n "$BADGE" ] && printf '\e]1337;SetBadgeFormat=%s\a' "$(printf '%s' "$BADGE" | base64)" > "$TTY_PATH" 2>/dev/null
fi

# 상태 저장 (JSON — tab-color/states/)
mkdir -p "$STATE_DIR"
_save_state "$TTY_NAME" "$PROJECT" "$R" "$G" "$B"

# 하위호환: pipe-delimited 상태 저장 (watchdog/tab-focus-monitor용)
COMPAT_STATE_DIR="$HOME/.claude/tab-states"
mkdir -p "$COMPAT_STATE_DIR"
echo "${STATE}|${PROJECT}|$(date +%s)" > "$COMPAT_STATE_DIR/$TTY_NAME"

# flash 처리
FLASH=$(jq -r --arg state "$STATE" '.states[$state].flash // false' "$CONFIG" 2>/dev/null || echo "false")
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
