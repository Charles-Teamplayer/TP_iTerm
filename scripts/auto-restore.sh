#!/bin/bash
# Claude Code Auto-Restore Script
# window-groups.json 기반 — 각 그룹의 tmux 세션 생성

LOG_FILE="$HOME/.claude/logs/auto-restore.log"
STOPS_FILE="$HOME/.claude/intentional-stops.json"
WINDOW_GROUPS="$HOME/.claude/window-groups.json"
ACTIVATED_FILE="$HOME/.claude/activated-sessions.json"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== Auto-Restore 시작 ==="

# 환경변수 로드
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if [ -f "$HOME/.zshrc" ]; then
    source "$HOME/.zshrc" 2>/dev/null || true
fi
unset CLAUDECODE

# 이미 claude 프로세스가 다수 실행 중이면 스킵 (--force 옵션으로 우회)
FORCE_MODE="${1:-}"
EXISTING=$(ps aux | grep "[c]laude" | grep -v "Claude.app\|Helper\|ShipIt\|watchdog\|auto-restore" | grep -v "??" | wc -l | tr -d ' ')
if [ "$EXISTING" -gt 5 ] && [ "$FORCE_MODE" != "--force" ]; then
    log "이미 claude 프로세스 ${EXISTING}개 실행 중, 스킵 (강제 실행: bash auto-restore.sh --force)"
    exit 0
fi

# 기존 claude 프로세스 모두 종료 (새 세션 생성 전, 신규 tmux 창 생성 방지)
log "기존 claude 프로세스 종료 중..."
pkill -x "claude" 2>/dev/null || true
sleep 2

# window-groups.json 존재 확인
if [ ! -f "$WINDOW_GROUPS" ]; then
    log "window-groups.json 없음 — 종료"
    exit 1
fi

# activated-sessions.json에서 name→path 맵 생성 (공백↔밑줄 정규화 비교)
get_path_for_name() {
    local name="$1"
    python3 -c "
import json, os, sys, re
name = sys.argv[1]
# 공백/밑줄을 동일하게 취급: 공백→_ 정규화 후 비교
def normalize(s):
    return re.sub(r'[ _]+', '_', s).lower()
norm_name = normalize(name)
path = os.path.expanduser('~/.claude/activated-sessions.json')
for candidate in [path, path + '.bak']:
    try:
        data = json.load(open(candidate))
        for p in data.get('activated', []):
            bname = os.path.basename(p)
            # 정확 매칭 우선, 그 다음 정규화 비교
            if bname == name or normalize(bname) == norm_name:
                print(p)
                sys.exit(0)
    except Exception:
        continue
" "$name" 2>/dev/null
}

# window-groups.json에서 활성 그룹(isWaitingList=false) 목록 읽기
GROUPS_JSON=$(python3 -c "
import json, sys
path = '$WINDOW_GROUPS'
try:
    groups = json.load(open(path))
    active = [g for g in groups if not g.get('isWaitingList', False)]
    for g in active:
        profiles = '|'.join(g.get('profileNames', []))
        print(g['sessionName'] + '\t' + profiles)
except Exception as e:
    sys.exit(1)
" 2>/dev/null)

if [ -z "$GROUPS_JSON" ]; then
    log "활성 그룹 없음 — 종료"
    exit 1
fi

TOTAL_CREATED=0
DELAY=0

while IFS=$'\t' read -r SESSION_NAME PROFILES_STR; do
    [ -z "$SESSION_NAME" ] && continue
    log "--- 그룹 처리: $SESSION_NAME ---"

    # 기존 tmux 세션 종료 (claude 프로세스가 새 창 만드는 것 방지: kill-server 전 약간 대기)
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log "기존 $SESSION_NAME tmux 세션 종료"
        # 세션의 모든 pane에서 실행 중인 claude 프로세스 먼저 종료
        tmux list-panes -t "$SESSION_NAME" -a -F '#{pane_pid}' 2>/dev/null | while read -r ppid; do
            pkill -P "$ppid" -x "claude" 2>/dev/null || true
        done
        sleep 1
        tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
        sleep 1
    fi

    # monitor 창으로 세션 생성
    tmux new-session -d -s "$SESSION_NAME" -n monitor -c "$HOME/claude" 2>/dev/null
    tmux set-window-option -t "$SESSION_NAME:monitor" automatic-rename off 2>/dev/null
    log "$SESSION_NAME 세션 생성 (monitor 창)"

    # 각 profileName으로 창 생성
    IFS='|' read -ra PROFILES <<< "$PROFILES_STR"
    for PROFILE_NAME in "${PROFILES[@]}"; do
        [ -z "$PROFILE_NAME" ] && continue

        PROJ_PATH=$(get_path_for_name "$PROFILE_NAME")
        if [ -z "$PROJ_PATH" ] || [ ! -d "$PROJ_PATH" ]; then
            log "SKIP $PROFILE_NAME — activated-sessions에 경로 없음"
            continue
        fi

        # claude project 파일 있으면 --continue
        if [ -d "$PROJ_PATH/.claude/projects" ] && ls "$PROJ_PATH/.claude/projects"/*.jsonl 2>/dev/null | head -1 | grep -q .; then
            CLAUDE_CMD="claude --dangerously-skip-permissions --continue"
        else
            CLAUDE_CMD="claude --dangerously-skip-permissions"
        fi

        tmux new-window -t "$SESSION_NAME" -n "$PROFILE_NAME" -c "$PROJ_PATH" 2>/dev/null
        # 방금 생성된 창의 인덱스 조회 (창 이름에 '.'이 있으면 pane 구분자 오해 방지)
        WIN_IDX=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}' 2>/dev/null | sort -n | tail -1)
        tmux set-window-option -t "$SESSION_NAME:$WIN_IDX" automatic-rename off 2>/dev/null
        tmux send-keys -t "$SESSION_NAME:$WIN_IDX" \
            "sleep $DELAY && bash ~/.claude/scripts/tab-status.sh starting '$PROFILE_NAME' && unset CLAUDECODE && $CLAUDE_CMD" Enter

        TOTAL_CREATED=$((TOTAL_CREATED + 1))
        DELAY=$((DELAY + 3))
        log "창 생성: $SESSION_NAME/$PROFILE_NAME (delay ${DELAY}s)"
    done

done <<< "$GROUPS_JSON"

# active-sessions.json 초기화 (이전 PID로 인한 watchdog 오탐 방지)
python3 -c "
import json, os
from datetime import datetime, timezone
path = os.path.expanduser('~/.claude/active-sessions.json')
data = {'sessions': [], 'last_updated': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'version': '1.0'}
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || true

# intentional-stops.json 초기화
if [ -f "$STOPS_FILE" ]; then
    echo '{"stops":[],"last_updated":"'"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"'"}' > "$STOPS_FILE"
    log "intentional-stops.json 초기화 완료"
fi

# 세션 상태 확인 + 중복 창 제거 (같은 이름의 창이 2개 이상이면 나중 것 제거)
sleep 3
for SNAME in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
    SEEN_NAMES=""
    while IFS='|' read -r idx name; do
        [ -z "$name" ] && continue
        if echo "$SEEN_NAMES" | grep -qxF "$name"; then
            tmux kill-window -t "$SNAME:$idx" 2>/dev/null
            log "DEDUP: $SNAME/$name (인덱스 $idx) 제거"
        else
            SEEN_NAMES="${SEEN_NAMES}${name}
"
        fi
    done < <(tmux list-windows -t "$SNAME" -F '#{window_index}|#{window_name}' 2>/dev/null)
    WIN_COUNT=$(tmux list-windows -t "$SNAME" 2>/dev/null | wc -l | tr -d ' ')
    log "$SNAME: ${WIN_COUNT}개 창 활성"
done

# Notion 기록
if [ -n "$NOTION_API_KEY" ] && [ -f "$HOME/claude/TP_skills/session-manager/notion-advanced.py" ]; then
    python3 "$HOME/claude/TP_skills/session-manager/notion-advanced.py" \
        "TP_iTerm" "Reboot Recovery (tmux)" "window-groups 기반 ${TOTAL_CREATED}개 세션 복원" 2>/dev/null || true
fi

log "=== Auto-Restore 완료: ${TOTAL_CREATED}개 창 복원 ==="
