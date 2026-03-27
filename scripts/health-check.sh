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

# 2. tmux 세션 상태 + 좀비 윈도우 감지 (BUG#17 fix: 멀티세션 지원)
echo -e "\n${BOLD}[2] tmux 세션 상태${NC}"
# window-groups.json에서 활성 세션 목록 동적 조회
ACTIVE_SESSIONS=$(python3 -c "
import json, os
try:
    groups = json.load(open(os.path.expanduser('~/.claude/window-groups.json')))
    seen = set()
    result = []
    for g in groups:
        sn = g.get('sessionName','')
        if sn and sn != '__waiting__' and not g.get('isWaitingList', False) and sn not in seen:
            seen.add(sn)
            result.append(sn)
    print('\n'.join(result) if result else 'claude-work')
except:
    print('claude-work')
" 2>/dev/null)
[ -z "$ACTIVE_SESSIONS" ] && ACTIVE_SESSIONS="claude-work"

TOTAL_WIN_COUNT=0
ZOMBIE_WINS=0
ZOMBIE_LIST=""
while IFS= read -r sname; do
    [ -z "$sname" ] && continue
    if tmux has-session -t "$sname" 2>/dev/null; then
        WIN_COUNT=$(tmux list-windows -t "$sname" 2>/dev/null | wc -l | tr -d ' ')
        TOTAL_WIN_COUNT=$((TOTAL_WIN_COUNT + WIN_COUNT))
        ok "$sname 세션 활성 (윈도우 ${WIN_COUNT}개)"

        # 좀비/orphan 윈도우 검사
        while IFS='|' read -r wname pid; do
            if [ -z "$pid" ] || [ "$pid" = "0" ] || ! kill -0 "$pid" 2>/dev/null; then
                ZOMBIE_WINS=$((ZOMBIE_WINS + 1))
                ZOMBIE_LIST="$ZOMBIE_LIST
    - [$sname] $wname (PID: $pid)"
            fi
        done < <(tmux list-windows -t "$sname" -F "#{window_name}|#{pane_pid}" 2>/dev/null)

        # monitor 창 존재 확인 (BUG#26 fix: 모든 활성 세션 검사, claude-work 하드코딩 제거)
        if tmux list-windows -t "$sname" -F "#{window_name}" 2>/dev/null | grep -q "^monitor$"; then
            ok "monitor 창 존재 ($sname)"
        else
            fail "monitor 창 없음 ($sname) — 수동 복구: tmux new-window -t '$sname' -n monitor -c \"\$HOME/claude\""
        fi

        # 윈도우 목록 (처음 10개만 표시)
        tmux list-windows -t "$sname" 2>/dev/null | head -10 | awk '{print "    " $0}'
        if [ "$WIN_COUNT" -gt 10 ]; then
            info "    ... (총 ${WIN_COUNT}개 윈도우 중 처음 10개만 표시)"
        fi
    else
        fail "$sname 세션 없음 — 복원 필요"
    fi
done <<< "$ACTIVE_SESSIONS"

if [ "$ZOMBIE_WINS" -gt 5 ]; then
    warn "좀비 윈도우 합계: ${ZOMBIE_WINS}개 (정리 권장)"
    echo "$ZOMBIE_LIST" | head -5 | awk '{print "    " $0}'
    if [ "$ZOMBIE_WINS" -gt 5 ]; then info "    ... (외 $((ZOMBIE_WINS - 5))개)"; fi
elif [ "$ZOMBIE_WINS" -gt 0 ]; then
    info "좀비 윈도우: ${ZOMBIE_WINS}개"
fi

# 3. Claude 프로세스 상태
echo -e "\n${BOLD}[3] Claude Code 프로세스${NC}"
CLAUDE_PROCS=$(ps aux | grep "[c]laude" | grep -v "Claude.app\|Helper\|ShipIt\|watchdog\|auto-restore\|tab-focus\|session-registry\|health-check\|MAGI" | grep -v "??" | wc -l | tr -d ' ')
# 기대값: activated-sessions 전체가 아닌 활성 그룹(non-waiting)의 profileNames 합산
EXPECTED_PROCS=$(python3 -c "
import json, os
try:
    groups = json.load(open(os.path.expanduser('~/.claude/window-groups.json')))
    total = sum(len(g.get('profileNames',[])) for g in groups if not g.get('isWaitingList', False) and g.get('sessionName','') not in ('', '__waiting__'))
    print(total)
except:
    print(8)
" 2>/dev/null || echo "8")
if [ "$CLAUDE_PROCS" -ge "$EXPECTED_PROCS" ]; then
    ok "Claude Code ${CLAUDE_PROCS}개 실행 중"
elif [ "$CLAUDE_PROCS" -gt 0 ]; then
    warn "Claude Code ${CLAUDE_PROCS}개 실행 중 (기대: ${EXPECTED_PROCS}개 — 활성 그룹 기준)"
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
    EXPECTED_SESSIONS=$(python3 -c "
import json, os
try:
    groups = json.load(open(os.path.expanduser('~/.claude/window-groups.json')))
    total = sum(len(g.get('profileNames',[])) for g in groups if not g.get('isWaitingList', False) and g.get('sessionName','') not in ('', '__waiting__'))
    print(total)
except:
    print(8)
" 2>/dev/null || echo "8")
    if [ "$SESSION_CNT" != "?" ] && [ "$SESSION_CNT" -ge "$EXPECTED_SESSIONS" ]; then
        ok "등록된 세션: ${SESSION_CNT}개"
    else
        warn "등록된 세션: ${SESSION_CNT}개 (기대: ${EXPECTED_SESSIONS}개 — 활성 그룹 기준)"
    fi
else
    warn "active-sessions.json 없음"
fi

# 7. intentional-stops.json
STOPS_FILE="$HOME/.claude/intentional-stops.json"
if [ -f "$STOPS_FILE" ]; then
    STOP_CNT=$(python3 -c "import json; d=json.load(open('$STOPS_FILE')); print(len(d.get('stops',[])))" 2>/dev/null || echo "0")
    if [ "$STOP_CNT" -gt 0 ] && [ "$STOP_CNT" != "0" ]; then
        warn "의도적 정지: ${STOP_CNT}개 (watchdog 자동재시작 제외, reboot 복원은 activated-sessions 기준)"
        python3 -c "
import json
d=json.load(open('$STOPS_FILE'))
for s in d.get('stops',[]): print('    - ' + s.get('window_name','?'))
" 2>/dev/null
    else
        ok "의도적 정지: 없음"
    fi
fi

# 8. Crash Count 현황 (상세 분석)
echo -e "\n${BOLD}[8] Crash Count 현황${NC}"
CRASH_DIR="$HOME/.claude/crash-counts"
if [ -d "$CRASH_DIR" ] && [ "$(ls -A "$CRASH_DIR" 2>/dev/null)" ]; then
    TOTAL_CRASHES=0
    RECENT_CRASHES=0
    CC_NOW=$(date +%s)
    CRASH_LIST=""
    while IFS= read -r cfile; do
        CNAME=$(basename "$cfile")
        CC_RAW=$(cat "$cfile" 2>/dev/null || echo "0|0")
        CVAL=$(echo "$CC_RAW" | cut -d'|' -f1)
        CC_TS=$(echo "$CC_RAW" | cut -d'|' -f2)
        CC_AGE=$(( CC_NOW - ${CC_TS:-0} ))

        # 24시간 이내 크래시만 카운트
        if [ "$CC_AGE" -lt 86400 ]; then
            RECENT_CRASHES=$((RECENT_CRASHES + CVAL))
            if [ "$CVAL" -ge 3 ]; then
                CRASH_LIST="$CRASH_LIST
    ❌ $CNAME: ${CVAL}회 (임계치 초과, ${CC_AGE}초 전)"
            elif [ "$CVAL" -ge 1 ]; then
                CRASH_LIST="$CRASH_LIST
    ⚠️  $CNAME: ${CVAL}회 (${CC_AGE}초 전)"
            fi
        else
            info "크래시 $CNAME: ${CVAL}회 (만료됨, 24h+)"
        fi
        TOTAL_CRASHES=$((TOTAL_CRASHES + CVAL))
    done < <(find "$CRASH_DIR" -type f 2>/dev/null)

    if [ "$RECENT_CRASHES" -gt 0 ]; then
        warn "최근 24h 크래시: ${RECENT_CRASHES}회 (누적: ${TOTAL_CRASHES}회)"
        echo "$CRASH_LIST"
    else
        ok "크래시 카운터 전체 0 (누적: ${TOTAL_CRASHES}회)"
    fi
else
    ok "크래시 기록 없음 ($CRASH_DIR 비어있음)"
fi

# 9. tmux 클라이언트 연결 상태 + %extended-output 위험도 (BUG#17 fix: 멀티세션)
echo -e "\n${BOLD}[9] tmux 클라이언트 연결 상태 (%extended-output)${NC}"
CLIENT_COUNT=0
EXTENDED_CHK=0
while IFS= read -r sname; do
    [ -z "$sname" ] && continue
    if tmux has-session -t "$sname" 2>/dev/null; then
        CNT=$(tmux list-clients -t "$sname" 2>/dev/null | wc -l | tr -d ' ')
        EXT=$(tmux list-clients -t "$sname" 2>/dev/null | grep -c "control-mode\|extended-output" 2>/dev/null || echo "0")
        CLIENT_COUNT=$((CLIENT_COUNT + CNT))
        EXTENDED_CHK=$((EXTENDED_CHK + EXT))
        if [ "$CNT" -ge 1 ]; then
            ok "$sname: 클라이언트 ${CNT}개"
            tmux list-clients -t "$sname" 2>/dev/null | awk '{print "    " $0}'
        else
            warn "$sname: 클라이언트 0개 (iTerm CC 미연결)"
        fi
    fi
done <<< "$ACTIVE_SESSIONS"
if [ "$EXTENDED_CHK" -gt 0 ]; then
    ok "iTerm CC 모드 연결됨 (control-mode 확인)"
elif [ "$CLIENT_COUNT" -gt 0 ]; then
    warn "CC 모드 미감지 — iTerm이 tmux -CC 모드로 연결되지 않았을 수 있음"
else
    fail "전체 세션 클라이언트 0개 — %extended-output 위험! (iTerm CC 모드 미연결)"
fi

# 10. Orphan tab-states 현황 (강화된 검사)
echo -e "\n${BOLD}[10] Orphan tab-states 검사${NC}"
TAB_STATES_DIR="$HOME/.claude/tab-states"
if [ -d "$TAB_STATES_DIR" ]; then
    ORPHAN_COUNT=0
    TOTAL_STATES=0
    ORPHAN_LIST=""
    while IFS= read -r tsfile; do
        TOTAL_STATES=$((TOTAL_STATES + 1))
        TTY_NAME=$(basename "$tsfile")
        if [ ! -e "/dev/$TTY_NAME" ]; then
            ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
            ORPHAN_LIST="$ORPHAN_LIST
    - $TTY_NAME (TTY 존재하지 않음)"
        fi
    done < <(find "$TAB_STATES_DIR" -type f 2>/dev/null)

    if [ "$ORPHAN_COUNT" -eq 0 ]; then
        ok "tab-states ${TOTAL_STATES}개 — orphan 없음"
    else
        warn "tab-states ${TOTAL_STATES}개 중 orphan ${ORPHAN_COUNT}개 발견"
        echo "$ORPHAN_LIST" | head -3
        if [ "$ORPHAN_COUNT" -gt 3 ]; then
            info "    ... (외 $((ORPHAN_COUNT - 3))개)"
        fi
        info "정리 권장: find $TAB_STATES_DIR -type f ! -exec test -e /dev/{} \; -delete"
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

# 12. 실시간 상태 서마리
echo -e "\n${BOLD}[12] 실시간 상태 점검 요약${NC}"
HEALTH_SCORE=0
HEALTH_MAX=10

# 각 항목별 점수 계산
if [ -n "$WIN_COUNT" ] && [ "$WIN_COUNT" -gt 0 ]; then HEALTH_SCORE=$((HEALTH_SCORE + 2)); fi
if [ -n "$ZOMBIE_WINS" ] && [ "$ZOMBIE_WINS" -eq 0 ]; then HEALTH_SCORE=$((HEALTH_SCORE + 1)); fi
if [ -z "$RECENT_CRASHES" ] || [ "$RECENT_CRASHES" -eq 0 ]; then HEALTH_SCORE=$((HEALTH_SCORE + 2)); fi
if [ -n "$ORPHAN_COUNT" ] && [ "$ORPHAN_COUNT" -eq 0 ]; then HEALTH_SCORE=$((HEALTH_SCORE + 1)); fi
if [ -n "$CLIENT_COUNT" ] && [ "$CLIENT_COUNT" -ge 1 ]; then HEALTH_SCORE=$((HEALTH_SCORE + 2)); fi
if [ -n "$EXTENDED_CHK" ] && [ "$EXTENDED_CHK" -gt 0 ]; then HEALTH_SCORE=$((HEALTH_SCORE + 2)); fi

if [ "$HEALTH_SCORE" -ge 9 ]; then
    ok "종합 상태: ${HEALTH_SCORE}/${HEALTH_MAX} (정상)"
elif [ "$HEALTH_SCORE" -ge 6 ]; then
    warn "종합 상태: ${HEALTH_SCORE}/${HEALTH_MAX} (경고)"
else
    fail "종합 상태: ${HEALTH_SCORE}/${HEALTH_MAX} (주의 필요)"
fi

echo -e "\n${BOLD}━━━ 완료 ━━━${NC}\n"
