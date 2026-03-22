#!/bin/bash
# MAGI+NORN Health Check — 전체 시스템 상태 한눈에 확인
# 사용법: bash ~/.claude/scripts/health-check.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✅${NC} $1"; }
fail() { echo -e "  ${RED}❌${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠️ ${NC} $1"; }
info() { echo -e "  ${CYAN}ℹ️ ${NC} $1"; }

echo -e "\n${BOLD}━━━ MAGI+NORN Health Check ━━━${NC}"
echo -e "$(date '+%Y-%m-%d %H:%M:%S')\n"

# 1. LaunchAgent 상태
echo -e "${BOLD}[1] LaunchAgent 상태${NC}"
UID_NUM=$(id -u)
for SVC in auto-restore auto-attach magi-restore watchdog tab-focus-monitor session-manager; do
    LABEL="com.claude.$SVC"
    if launchctl list | grep -q "$LABEL"; then
        PID=$(launchctl list | grep "$LABEL" | awk '{print $1}')
        EXIT=$(launchctl list | grep "$LABEL" | awk '{print $2}')
        if [ "$PID" != "-" ]; then
            ok "$SVC (PID: $PID)"
        elif [ "$EXIT" = "0" ]; then
            info "$SVC (종료됨, exit 0 — 정상)"
        else
            fail "$SVC (종료됨, exit $EXIT)"
        fi
    else
        fail "$SVC (미등록)"
    fi
done

# 2. tmux 세션 상태
echo -e "\n${BOLD}[2] tmux 세션 상태${NC}"
if tmux has-session -t claude-work 2>/dev/null; then
    WIN_COUNT=$(tmux list-windows -t claude-work 2>/dev/null | wc -l | tr -d ' ')
    if [ "$WIN_COUNT" -ge 15 ]; then
        ok "claude-work 세션 활성 (윈도우 ${WIN_COUNT}개)"
    else
        warn "claude-work 세션 활성 (윈도우 ${WIN_COUNT}개 — 기대: 15개)"
    fi
    # monitor 창 존재 확인
    if tmux list-windows -t claude-work -F "#{window_name}" 2>/dev/null | grep -q "^monitor$"; then
        ok "monitor 창 존재"
    else
        fail "monitor 창 없음 — 수동 복구: tmux new-window -t claude-work -n monitor -c \"\$HOME/claude\""
    fi
    tmux list-windows -t claude-work 2>/dev/null | awk '{print "    " $0}'
else
    fail "claude-work tmux 세션 없음 — 복원 필요"
fi

# 3. Claude 프로세스 상태
echo -e "\n${BOLD}[3] Claude Code 프로세스${NC}"
CLAUDE_PROCS=$(ps aux | grep "[c]laude" | grep -v "Claude.app\|Helper\|ShipIt\|watchdog\|auto-restore\|tab-focus\|session-registry\|health-check\|MAGI" | grep -v "??" | wc -l | tr -d ' ')
if [ "$CLAUDE_PROCS" -ge 10 ]; then
    ok "Claude Code ${CLAUDE_PROCS}개 실행 중"
elif [ "$CLAUDE_PROCS" -gt 0 ]; then
    warn "Claude Code ${CLAUDE_PROCS}개 실행 중 (기대: 14개)"
else
    fail "Claude Code 프로세스 없음"
fi

# 4. iTerm2 상태
echo -e "\n${BOLD}[4] iTerm2 상태${NC}"
if ps -A 2>/dev/null | grep -q "iTerm.app/Contents/MacOS/iTerm2" || pgrep -x "iTerm2" > /dev/null 2>&1; then
    ok "iTerm2 실행 중"
else
    fail "iTerm2 미실행"
fi

# 5. watchdog 로그 최근 상태
echo -e "\n${BOLD}[5] Watchdog 최근 로그 (5줄)${NC}"
if [ -f "$HOME/.claude/logs/watchdog.log" ]; then
    tail -5 "$HOME/.claude/logs/watchdog.log" | awk '{print "    " $0}'
else
    warn "watchdog 로그 없음"
fi

# 6. active-sessions.json
echo -e "\n${BOLD}[6] 세션 레지스트리${NC}"
if [ -f "$HOME/.claude/active-sessions.json" ]; then
    SESSION_CNT=$(python3 -c "import json; d=json.load(open('$HOME/.claude/active-sessions.json')); print(len(d['sessions']))" 2>/dev/null || echo "?")
    EXPECTED_SESSIONS=14
    if [ "$SESSION_CNT" != "?" ] && [ "$SESSION_CNT" -ge "$EXPECTED_SESSIONS" ]; then
        ok "등록된 세션: ${SESSION_CNT}개"
    else
        warn "등록된 세션: ${SESSION_CNT}개 (기대: ${EXPECTED_SESSIONS}개)"
    fi
else
    warn "active-sessions.json 없음"
fi

# 7. intentional-stops.json
STOPS_FILE="$HOME/.claude/intentional-stops.json"
if [ -f "$STOPS_FILE" ]; then
    STOP_CNT=$(python3 -c "import json; d=json.load(open('$STOPS_FILE')); print(len(d.get('stops',[])))" 2>/dev/null || echo "0")
    if [ "$STOP_CNT" -gt 0 ] && [ "$STOP_CNT" != "0" ]; then
        warn "의도적 정지: ${STOP_CNT}개 (다음 복원 시 제외됨)"
        python3 -c "
import json
d=json.load(open('$STOPS_FILE'))
for s in d.get('stops',[]): print('    - ' + s.get('window_name','?'))
" 2>/dev/null
    else
        ok "의도적 정지: 없음"
    fi
fi

# 8. Crash Count 현황
echo -e "\n${BOLD}[8] Crash Count 현황${NC}"
CRASH_DIR="$HOME/.claude/crash-counts"
if [ -d "$CRASH_DIR" ] && [ "$(ls -A "$CRASH_DIR" 2>/dev/null)" ]; then
    TOTAL_CRASHES=0
    CC_NOW=$(date +%s)
    while IFS= read -r cfile; do
        CNAME=$(basename "$cfile")
        CC_RAW=$(cat "$cfile" 2>/dev/null || echo "0|0")
        CVAL=$(echo "$CC_RAW" | cut -d'|' -f1)
        CC_TS=$(echo "$CC_RAW" | cut -d'|' -f2)
        CC_AGE=$(( CC_NOW - ${CC_TS:-0} ))
        if [ "$CC_AGE" -gt 86400 ]; then
            info "크래시 $CNAME: ${CVAL}회 (만료됨, 24h+)"
        elif [ "$CVAL" -ge 3 ]; then
            fail "크래시 $CNAME: ${CVAL}회 (임계치 초과)"
        elif [ "$CVAL" -ge 1 ]; then
            warn "크래시 $CNAME: ${CVAL}회"
        else
            ok "크래시 $CNAME: 0회"
        fi
        TOTAL_CRASHES=$((TOTAL_CRASHES + CVAL))
    done < <(find "$CRASH_DIR" -type f 2>/dev/null)
    if [ "$TOTAL_CRASHES" -eq 0 ]; then
        ok "크래시 카운터 전체 0"
    fi
else
    ok "크래시 기록 없음 ($CRASH_DIR 비어있음)"
fi

# 9. tmux 클라이언트 연결 상태 + %extended-output 위험도
echo -e "\n${BOLD}[9] tmux 클라이언트 연결 상태${NC}"
if tmux has-session -t claude-work 2>/dev/null; then
    CLIENT_COUNT=$(tmux list-clients -t claude-work 2>/dev/null | wc -l | tr -d ' ')
    if [ "$CLIENT_COUNT" -ge 1 ]; then
        ok "연결된 클라이언트: ${CLIENT_COUNT}개"
        tmux list-clients -t claude-work 2>/dev/null | awk '{print "    " $0}'
    else
        fail "클라이언트 0개 — %extended-output 위험! (iTerm CC 모드 미연결)"
        warn "해결: iTerm2에서 tmux -CC attach -t claude-work 실행"
    fi
else
    fail "claude-work 세션 없음 — 클라이언트 확인 불가"
fi

# 10. Orphan tab-states 현황
echo -e "\n${BOLD}[10] Orphan tab-states 검사${NC}"
TAB_STATES_DIR="$HOME/.claude/tab-states"
if [ -d "$TAB_STATES_DIR" ]; then
    ORPHAN_COUNT=0
    TOTAL_STATES=0
    while IFS= read -r tsfile; do
        TOTAL_STATES=$((TOTAL_STATES + 1))
        TTY_NAME=$(basename "$tsfile")
        if [ ! -e "/dev/$TTY_NAME" ]; then
            ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
            warn "orphan: $TTY_NAME (TTY 존재하지 않음)"
        fi
    done < <(find "$TAB_STATES_DIR" -type f 2>/dev/null)
    if [ "$ORPHAN_COUNT" -eq 0 ]; then
        ok "tab-states ${TOTAL_STATES}개 — orphan 없음"
    else
        warn "tab-states ${TOTAL_STATES}개 중 orphan ${ORPHAN_COUNT}개 발견"
        info "정리: rm $TAB_STATES_DIR/<orphan-tty>"
    fi
else
    info "tab-states 디렉토리 없음"
fi

# 11. auto-restore 마지막 실행
echo -e "\n${BOLD}[11] 마지막 복원 실행${NC}"
if [ -f "$HOME/.claude/logs/auto-restore.log" ]; then
    LAST_RUN=$(grep "=== Auto-Restore" "$HOME/.claude/logs/auto-restore.log" | tail -1)
    info "$LAST_RUN"
    LAST_RESULT=$(grep "=== Auto-Restore 완료" "$HOME/.claude/logs/auto-restore.log" | tail -1)
    [ -n "$LAST_RESULT" ] && ok "$LAST_RESULT"
else
    warn "auto-restore 로그 없음"
fi

echo -e "\n${BOLD}━━━ 완료 ━━━${NC}\n"
