#!/bin/bash
# stop-session.sh — intentional-stop 관리 CLI
# 사용법:
#   ./stop-session.sh imsms          프로젝트를 정지 목록에 추가 (다음 복원 시 제외)
#   ./stop-session.sh --list         현재 정지 목록 확인
#   ./stop-session.sh --remove imsms 특정 프로젝트를 정지 목록에서 제거
#   ./stop-session.sh --clear        전체 정지 목록 초기화

STOPS_FILE="$HOME/.claude/intentional-stops.json"

# 정지 목록 초기화 함수
init_stops() {
    if [ ! -f "$STOPS_FILE" ]; then
        echo '{"stops":[],"last_updated":""}' > "$STOPS_FILE"
    fi
}

# 윈도우 이름 → 프로젝트 경로 매핑 (auto-restore.sh와 동기화 유지)
VALID_WINDOWS=(
    "imsms" "imsms-agent" "mdm" "tesla-lvds" "tesla-dashboard"
    "mindmap" "sj-mindmap" "imessage" "btt" "infra"
    "skills" "appletv" "imsms-web" "auto-restart"
)

is_valid_window() {
    for w in "${VALID_WINDOWS[@]}"; do
        [ "$w" = "$1" ] && return 0
    done
    return 1
}

case "${1:-}" in
    --list)
        init_stops
        echo "=== 의도적 정지 목록 ==="
        python3 -c "
import json
d = json.load(open('$STOPS_FILE'))
stops = d.get('stops', [])
if not stops:
    print('  (없음) — 모든 프로젝트가 다음 복원 시 시작됩니다')
else:
    for s in stops:
        print(f\"  - {s.get('window_name','?')} ({s.get('stopped_at','?')[:10]})\")
    print(f'\n총 {len(stops)}개 프로젝트가 다음 복원에서 제외됩니다')
" 2>/dev/null
        ;;

    --clear)
        init_stops
        TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        echo "{\"stops\":[],\"last_updated\":\"${TS}\"}" > "$STOPS_FILE"
        echo "✅ 정지 목록 초기화 완료 — 다음 복원 시 모든 프로젝트 시작"
        ;;

    --remove)
        WINDOW="${2:-}"
        if [ -z "$WINDOW" ]; then
            echo "사용법: $0 --remove <window-name>"
            exit 1
        fi
        init_stops
        python3 -c "
import json, os, tempfile
stops_path = '$STOPS_FILE'
window = '$WINDOW'
d = json.load(open(stops_path))
before = len(d.get('stops', []))
d['stops'] = [s for s in d.get('stops', []) if s.get('window_name') != window]
after = len(d['stops'])
d['last_updated'] = '$(date -u '+%Y-%m-%dT%H:%M:%SZ')'
tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(stops_path))
with os.fdopen(tmp_fd, 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
os.rename(tmp_path, stops_path)
if before > after:
    print(f'✅ {window} 제거됨 — 다음 복원 시 포함')
else:
    print(f'⚠️  {window} 목록에 없음')
" 2>/dev/null
        ;;

    "")
        echo "사용법:"
        echo "  $(basename $0) <window-name>    정지 목록에 추가"
        echo "  $(basename $0) --list           목록 확인"
        echo "  $(basename $0) --remove <name>  목록에서 제거"
        echo "  $(basename $0) --clear          전체 초기화"
        echo ""
        echo "유효한 window 이름:"
        for w in "${VALID_WINDOWS[@]}"; do echo "  $w"; done
        exit 0
        ;;

    *)
        WINDOW="$1"
        if ! is_valid_window "$WINDOW"; then
            echo "⚠️  알 수 없는 window: $WINDOW"
            echo "유효한 이름: ${VALID_WINDOWS[*]}"
            exit 1
        fi
        init_stops
        TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        python3 -c "
import json, os, tempfile
stops_path = '$STOPS_FILE'
window = '$WINDOW'
ts = '$TS'
d = json.load(open(stops_path))
d['stops'] = [s for s in d.get('stops', []) if s.get('window_name') != window]
d['stops'].append({'window_name': window, 'stopped_at': ts})
d['last_updated'] = ts
tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(stops_path))
with os.fdopen(tmp_fd, 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
os.rename(tmp_path, stops_path)
print(f'✅ {window} → 정지 목록 추가됨 (다음 복원 시 제외)')
" 2>/dev/null
        ;;
esac
