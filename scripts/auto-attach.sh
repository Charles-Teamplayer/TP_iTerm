#!/bin/bash
# auto-attach.sh: 부팅 후 iTerm2에 window-groups 기반 탭 생성
# LaunchAgent com.claude.auto-attach 에서 호출

LOG="$HOME/.claude/logs/auto-restore.log"
WINDOW_GROUPS="$HOME/.claude/window-groups.json"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [auto-attach] $1" >> "$LOG"; }

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

FLAG_FILE="$HOME/.claude/logs/.auto-restore-done"

# auto-restore.sh 완료 플래그를 기다림 (최대 3분)
log "auto-restore 플래그 대기 시작 (최대 180초)"
WAITED=0
while [ $WAITED -lt 180 ]; do
    if [ -f "$FLAG_FILE" ]; then
        FLAG_TIME=$(cat "$FLAG_FILE" 2>/dev/null)
        NOW=$(date +%s)
        AGE=$((NOW - ${FLAG_TIME:-0}))
        if [ "$AGE" -lt 1800 ]; then  # 30분 이내 플래그만 유효
            log "auto-restore 완료 플래그 확인 (${AGE}초 전) — attach 시작"
            rm -f "$FLAG_FILE"
            break
        else
            log "플래그가 오래됨 (${AGE}초 전) — 스킵"
            exit 0
        fi
    fi
    sleep 10
    WAITED=$((WAITED + 10))
done

if [ $WAITED -ge 180 ]; then
    log "auto-restore 플래그 없음 (180초 대기 후) — 스킵"
    exit 0
fi

# tmux 세션 준비 대기
log "tmux 세션 준비 대기 (10초)"
sleep 10

# window-groups.json 확인
if [ ! -f "$WINDOW_GROUPS" ]; then
    log "window-groups.json 없음 — attach 스킵"
    exit 0
fi

# iTerm2 실행 대기 (최대 60초)
for i in $(seq 1 12); do
    if ps -A 2>/dev/null | grep -q "iTerm.app/Contents/MacOS/iTerm2"; then
        break
    fi
    log "iTerm2 대기 중... (${i}/12)"
    sleep 5
done

# iTerm2 미실행 시 직접 실행
if ! ps -A 2>/dev/null | grep -q "iTerm.app/Contents/MacOS/iTerm2"; then
    log "iTerm2 미실행 — open으로 실행"
    open -a iTerm 2>/dev/null || true
    sleep 5
fi

# window-groups.json에서 활성 그룹(isWaitingList=false) 읽기
GROUPS_JSON=$(python3 -c "
import json, sys
path = '$WINDOW_GROUPS'
try:
    groups = json.load(open(path))
    active = [g for g in groups if not g.get('isWaitingList', False)]
    for g in active:
        print(g['sessionName'])
except Exception as e:
    pass
" 2>/dev/null)

if [ -z "$GROUPS_JSON" ]; then
    log "활성 그룹 없음 — attach 스킵"
    exit 0
fi

# 각 그룹에 대해 iTerm2 창 + 탭 생성
while IFS= read -r SESSION_NAME; do
    [ -z "$SESSION_NAME" ] && continue

    # tmux 세션 존재 확인
    if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log "$SESSION_NAME tmux 세션 없음 — 스킵"
        continue
    fi

    # tmux 창 목록 조회 (index|name)
    RAW_WINS=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}|#{window_name}' 2>/dev/null)
    if [ -z "$RAW_WINS" ]; then
        log "$SESSION_NAME 창 없음 — 스킵"
        continue
    fi

    # AppleScript 생성
    APPLE_SCRIPT=$(python3 << PYEOF
import sys

session = "$SESSION_NAME"
raw = """$RAW_WINS"""

winPairs = []
for line in raw.strip().split('\n'):
    if not line.strip():
        continue
    parts = line.split('|', 1)
    if len(parts) == 2:
        try:
            winPairs.append((int(parts[0]), parts[1]))
        except ValueError:
            pass

if not winPairs:
    sys.exit(0)

monitor_idx = next((idx for idx, name in winPairs if name == 'monitor'), winPairs[0][0])

lines = [
    'tell application "iTerm2"',
    '    activate',
    '    set newWin to (create window with default profile)',
    '    delay 1',
    '    tell current session of current tab of newWin',
    f'        write text "tmux attach-session -t \\'{session}:{monitor_idx}\\'"',
    '    end tell',
]

for tabIdx, (winIdx, name) in enumerate(winPairs):
    if name == 'monitor':
        continue
    tabVar = f'tab{tabIdx}'
    lines.append('    delay 0.5')
    lines.append('    tell newWin')
    lines.append(f'        set {tabVar} to (create tab with default profile)')
    lines.append('    end tell')
    lines.append('    delay 0.8')
    lines.append(f'    tell current session of {tabVar}')
    lines.append(f'        write text "tmux attach-session -t \\'{session}:{winIdx}\\'"')
    lines.append('    end tell')
lines.append('end tell')

print('\n'.join(lines))
PYEOF
)

    if [ -z "$APPLE_SCRIPT" ]; then
        log "$SESSION_NAME AppleScript 생성 실패 — 스킵"
        continue
    fi

    # osascript 실행
    osascript << __APPLES__
$APPLE_SCRIPT
__APPLES__

    if [ $? -eq 0 ]; then
        log "$SESSION_NAME iTerm2 창+탭 생성 완료"
    else
        log "ERROR: $SESSION_NAME osascript 실패"
    fi

    sleep 2  # 그룹 간 딜레이

done <<< "$GROUPS_JSON"

log "auto-attach 완료"
