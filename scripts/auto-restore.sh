#!/bin/bash
# Claude Code Auto-Restore Script
# MAGI+NORN 자동 복원 시스템 - LaunchAgent에서 호출
# tmux + iTerm2 tmux integration (per-window, intentional-stop 제외)

LOG_FILE="$HOME/.claude/logs/auto-restore.log"
STOPS_FILE="$HOME/.claude/intentional-stops.json"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== Auto-Restore 시작 ==="

# 부팅 시 orphan tab-states 정리 (이전 세션 잔존 파일 제거)
STATE_DIR="$HOME/.claude/tab-states"
if [ -d "$STATE_DIR" ]; then
    for sf in "$STATE_DIR"/ttys*; do
        [ ! -f "$sf" ] && continue
        TTY_DEV="/dev/$(basename "$sf")"
        if [ ! -c "$TTY_DEV" ]; then
            rm -f "$sf"
            log "Orphan tab-state 제거: $(basename "$sf")"
        fi
    done
fi

# 환경변수 로드 후 CLAUDECODE 해제 (순서 중요: source 후 unset)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if [ -f "$HOME/.zshrc" ]; then
    source "$HOME/.zshrc" 2>/dev/null || true
fi
unset CLAUDECODE

# === iTerm2 실행 전: tmux 프로필 배경색을 TPTP(검정)로 패치 ===
ITERM_PLIST="$HOME/Library/Preferences/com.googlecode.iterm2.plist"
if [ -f "$ITERM_PLIST" ]; then
    python3 << 'PYEOF'
import subprocess, sys, os

plist = os.path.expanduser("~/Library/Preferences/com.googlecode.iterm2.plist")

# plist를 XML로 변환
result = subprocess.run(["plutil", "-convert", "xml1", "-o", "-", plist],
    capture_output=True, text=True)
if result.returncode != 0:
    print("[RESTORE] plist 읽기 실패", file=sys.stderr)
    sys.exit(0)

xml = result.stdout

# "tmux" 프로필의 Background Color를 검정(0,0,0)으로 패치
# Background Color dict: Red/Green/Blue = 0, Alpha = 1, Color Space = P3
import re

# tmux 프로필 블록 찾기 (key/string 구조)
tmux_idx = xml.find('<string>tmux</string>')
if tmux_idx == -1:
    print("[RESTORE] tmux 프로필 없음", file=sys.stderr)
    sys.exit(0)

# tmux 프로필 시작 dict 찾기
dict_start = xml.rfind('<dict>', 0, tmux_idx)

# Background Color 키/dict 블록 찾기 (tmux_idx 이후)
bg_key_pat = re.compile(r'<key>Background Color</key>\s*<dict>(.*?)</dict>', re.DOTALL)
# tmux 프로필 블록만 대상으로
profile_block = xml[dict_start:]
match = bg_key_pat.search(profile_block)
if not match:
    print("[RESTORE] tmux Background Color 없음", file=sys.stderr)
    sys.exit(0)

# 기존 Background Color dict 내용을 검정으로 교체
dark_dict = """<dict>
			<key>Alpha Component</key>
			<real>1</real>
			<key>Blue Component</key>
			<real>0.0</real>
			<key>Color Space</key>
			<string>P3</string>
			<key>Green Component</key>
			<real>0.0</real>
			<key>Red Component</key>
			<real>0.0</real>
		</dict>"""

new_block = bg_key_pat.sub(
    f'<key>Background Color</key>\n\t\t{dark_dict}',
    profile_block, count=1
)
new_xml = xml[:dict_start] + new_block

# 임시 파일에 저장 후 binary plist로 변환
import tempfile
with tempfile.NamedTemporaryFile(suffix='.plist', delete=False, mode='w') as f:
    f.write(new_xml)
    tmp = f.name

ret = subprocess.run(["plutil", "-convert", "binary1", tmp], capture_output=True)
if ret.returncode == 0:
    import shutil
    shutil.move(tmp, plist)
    print("[RESTORE] tmux 프로필 배경색 → 검정(다크모드) 패치 완료")
else:
    os.unlink(tmp)
    print("[RESTORE] plist 변환 실패", file=sys.stderr)
PYEOF
    log "iTerm2 tmux 프로필 다크모드 패치 완료"
fi

# iTerm2 대기 (최대 60초)
MAX_WAIT=60
WAITED=0
if ! pgrep -x "iTerm2" > /dev/null; then
    log "iTerm2 시작 대기 중..."
    open -a iTerm || { log "ERROR: iTerm2 미설치 또는 실행 실패"; exit 1; }
    while ! pgrep -x "iTerm2" > /dev/null && [ $WAITED -lt $MAX_WAIT ]; do
        sleep 2
        WAITED=$((WAITED + 2))
    done
    if [ $WAITED -ge $MAX_WAIT ]; then
        log "ERROR: iTerm2 시작 타임아웃 (${MAX_WAIT}초)"
        exit 1
    fi
    log "iTerm2 시작됨 (${WAITED}초 대기)"
    sleep 5
fi

# 이미 claude 프로세스가 다수 실행 중이면 스킵 (--force 옵션으로 우회 가능)
FORCE_MODE="${1:-}"
EXISTING=$(ps aux | grep "[c]laude" | grep -v "Claude.app\|Helper\|ShipIt\|watchdog\|auto-restore" | grep -v "??" | wc -l | tr -d ' ')
if [ "$EXISTING" -gt 5 ] && [ "$FORCE_MODE" != "--force" ]; then
    log "이미 claude 프로세스 ${EXISTING}개 실행 중, 스킵 (강제 실행: bash auto-restore.sh --force)"
    exit 0
fi

# 제외 목록을 변수에 저장
STOPPED_WINDOWS=$(python3 -c "
import json, os
stops_path = os.path.expanduser('~/.claude/intentional-stops.json')
try:
    with open(stops_path, 'r') as f:
        data = json.load(f)
    for s in data.get('stops', []):
        wn = s.get('window_name', '')
        if wn:
            print(wn)
except Exception:
    pass
" 2>/dev/null)

is_stopped() {
    echo "$STOPPED_WINDOWS" | grep -qx "$1"
}

# 기존 tmux 세션 정리
if tmux has-session -t claude-work 2>/dev/null; then
    log "기존 claude-work tmux 세션 종료"
    tmux kill-session -t claude-work 2>/dev/null || true
    sleep 2
fi

# === Step 1: tmux 세션 생성 (per-window, intentional-stop 제외) ===
log "tmux 세션 직접 생성 (per-window 방식)"
tmux new-session -d -s claude-work -n monitor -c "$HOME/claude" 2>/dev/null

PROJECTS=(
    "imsms:$HOME/claude/TP_newIMSMS:0"
    "imsms-agent:$HOME/claude/TP_newIMSMS_Agent:5"
    "mdm:$HOME/claude/TP_MDM:10"
    "tesla-lvds:$HOME/claude/TP_TESLA_LVDS:15"
    "tesla-dashboard:$HOME/ralph-claude-code/TESLA_Status_Dashboard:20"
    "mindmap:$HOME/claude/TP_MindMap_AutoCC:25"
    "sj-mindmap:$HOME/SJ_MindMap:30"
    "imessage:$HOME/claude/TP_A.iMessage_standalone_01067051080:35"
    "btt:$HOME/claude/TP_BTT:40"
    "infra:$HOME/claude/TP_Infra_reduce_Project:45"
    "skills:$HOME/claude/TP_skills:50"
    "appletv:$HOME/claude/AppleTV_ScreenSaver.app:55"
    "imsms-web:$HOME/claude/imsms.im-website:60"
    "auto-restart:$HOME/claude/TP_iTerm:65"
)

CREATED=0
SKIPPED=0
for proj in "${PROJECTS[@]}"; do
    NAME=$(echo "$proj" | cut -d: -f1)
    PROJ_PATH=$(echo "$proj" | cut -d: -f2)
    DELAY=$(echo "$proj" | cut -d: -f3)

    [ ! -d "$PROJ_PATH" ] && continue

    # intentional-stop 제외 체크
    if is_stopped "$NAME"; then
        log "SKIP (intentional-stop): $NAME"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    tmux new-window -t claude-work -n "$NAME" -c "$PROJ_PATH" 2>/dev/null
    tmux send-keys -t "claude-work:$NAME" "sleep $DELAY && bash ~/.claude/scripts/tab-status.sh starting $NAME && unset CLAUDECODE && (claude --dangerously-skip-permissions --continue 2>/dev/null || claude --dangerously-skip-permissions)" Enter
    CREATED=$((CREATED + 1))
    log "tmux 윈도우 생성: $NAME (delay ${DELAY}s)"
done

log "tmux 생성 완료: ${CREATED}개 생성, ${SKIPPED}개 제외 (intentional-stop)"

# === Step 2: iTerm2에서 tmux -CC attach (AppleScript — 새 탭 자동 실행) ===
sleep 3
log "iTerm2에서 tmux -CC attach 실행 (AppleScript)"

osascript << 'ASEOF'
-- tmux -CC attach은 blocking 명령 → write text가 timeout(-1712) 됨
-- with timeout + try로 send 후 즉시 반환
tell application "iTerm2"
    activate
    if (count windows) > 0 then
        tell current window
            set newTab to (create tab with default profile)
            try
                with timeout of 2 seconds
                    tell current session of newTab
                        write text "tmux -CC attach -t claude-work"
                    end tell
                end timeout
            end try
        end tell
    else
        set newWin to (create window with default profile)
        try
            with timeout of 2 seconds
                tell current session of newWin
                    write text "tmux -CC attach -t claude-work"
                end tell
            end timeout
        end try
    end if
end tell
ASEOF
OSASCRIPT_RESULT=$?

if [ $OSASCRIPT_RESULT -ne 0 ]; then
    log "ERROR: AppleScript attach 실패 (exit $OSASCRIPT_RESULT) — fallback: tmux -CC 직접 실행 시도"
    tmux -CC attach -t claude-work 2>/dev/null || true
    log "Fallback: tmux -CC attach 직접 실행 완료"
else
    log "iTerm2 tmux -CC attach 완료 (AppleScript 자동 실행)"
fi

# 세션 수 확인
sleep 10
SESSION_COUNT=$(tmux list-windows -t claude-work 2>/dev/null | wc -l | tr -d ' ')
log "tmux 윈도우 ${SESSION_COUNT}개 활성"

# Health check: 최대 delay(65초) + 여유 30초 후 claude 프로세스 확인
(
    sleep 100
    CLAUDE_COUNT=$(ps aux | grep '[c]laude' | grep -v 'Claude.app\|Helper\|ShipIt\|watchdog\|auto-restore\|tab-focus' | grep -v '??' | wc -l | tr -d ' ')
    EXPECTED=$CREATED
    if [ "$CLAUDE_COUNT" -lt "$EXPECTED" ]; then
        MISSING=$((EXPECTED - CLAUDE_COUNT))
        log "HEALTH CHECK WARNING: ${CLAUDE_COUNT}/${EXPECTED} claude 프로세스 실행 중 (${MISSING}개 미시작)"
        osascript -e "display notification \"${MISSING}개 세션 시작 실패 확인 필요\" with title \"MAGI+NORN Health Check\" sound name \"Basso\"" 2>/dev/null || true
    else
        log "HEALTH CHECK OK: ${CLAUDE_COUNT}/${EXPECTED} claude 프로세스 정상"
    fi
) &

# 복원 완료 후 intentional-stops.json 초기화 (다음 부팅은 fresh)
if [ -f "$STOPS_FILE" ]; then
    echo '{"stops":[],"last_updated":"'"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"'"}' > "$STOPS_FILE"
    log "intentional-stops.json 초기화 완료"
fi

# 복원 완료 macOS 알림
NOTIFY_MSG="Claude Code ${CREATED}개 세션 복원 완료"
if [ "$SKIPPED" -gt 0 ]; then
    NOTIFY_MSG="${NOTIFY_MSG} (${SKIPPED}개 의도적 종료 제외)"
fi
osascript -e "display notification \"${NOTIFY_MSG}\" with title \"MAGI+NORN\" sound name \"Glass\"" 2>/dev/null || true

# Notion에 복원 기록
if [ -n "$NOTION_API_KEY" ] && [ -f "$HOME/claude/TP_skills/session-manager/notion-advanced.py" ]; then
    python3 "$HOME/claude/TP_skills/session-manager/notion-advanced.py" \
        "TP_iTerm" "Reboot Recovery (tmux)" "${NOTIFY_MSG}" 2>/dev/null || true
fi

log "=== Auto-Restore 완료: ${CREATED}개 복원, ${SKIPPED}개 제외 ==="
