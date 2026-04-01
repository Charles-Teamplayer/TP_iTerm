#!/bin/bash
# share-to-imessage.sh — iTerm 작업 결과를 iMessage로 공유
# IMSMS Agent HTTP API(/api/send) 직접 호출
#
# 사용법:
#   bash share-to-imessage.sh "+821012345678" "메시지 내용"
#   echo "결과 텍스트" | bash share-to-imessage.sh "+821012345678"
#   bash share-to-imessage.sh "+821012345678"          # stdin 대기
#
# 환경변수:
#   IMSMS_AGENT_URL   기본값: http://localhost:8080
#   IMSMS_DEFAULT_TO  기본 수신자 (번호 생략 시 사용)

set -euo pipefail

# ─── 색상 ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }

# ─── 설정 ───────────────────────────────────────────────────────────────────
AGENT_URL="${IMSMS_AGENT_URL:-http://localhost:8080}"
TIMEOUT=10  # curl 타임아웃(초)

# ─── 인수 파싱 ───────────────────────────────────────────────────────────────
SEND_TO=""
MESSAGE=""
HELP=0

usage() {
    echo -e "\n${BOLD}share-to-imessage.sh${NC} — iTerm 작업 결과를 iMessage로 공유"
    echo ""
    echo "사용법:"
    echo "  bash share-to-imessage.sh \"+821012345678\" \"메시지\""
    echo "  echo \"결과\" | bash share-to-imessage.sh \"+821012345678\""
    echo "  bash share-to-imessage.sh  # IMSMS_DEFAULT_TO 환경변수 사용"
    echo ""
    echo "환경변수:"
    echo "  IMSMS_AGENT_URL   Agent 주소 (기본: http://localhost:8080)"
    echo "  IMSMS_DEFAULT_TO  기본 수신자 전화번호"
    echo ""
    echo "옵션:"
    echo "  -h, --help   도움말"
    echo "  --dry-run    API 호출 없이 페이로드만 출력"
    echo ""
}

DRY_RUN=0
POSITIONAL=()

for arg in "$@"; do
    case "$arg" in
        -h|--help) HELP=1 ;;
        --dry-run)  DRY_RUN=1 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

if [ "$HELP" -eq 1 ]; then
    usage
    exit 0
fi

# 위치 인수 처리
if [ "${#POSITIONAL[@]}" -ge 1 ]; then
    SEND_TO="${POSITIONAL[0]}"
fi
if [ "${#POSITIONAL[@]}" -ge 2 ]; then
    MESSAGE="${POSITIONAL[1]}"
fi

# 수신자 미입력 시 환경변수 fallback
if [ -z "$SEND_TO" ]; then
    SEND_TO="${IMSMS_DEFAULT_TO:-}"
fi

if [ -z "$SEND_TO" ]; then
    fail "수신자 전화번호가 없습니다."
    echo ""
    echo "  1) 인수로 전달:  bash share-to-imessage.sh \"+821012345678\" \"메시지\""
    echo "  2) 환경변수 설정: export IMSMS_DEFAULT_TO=\"+821012345678\""
    echo ""
    exit 1
fi

# 메시지가 인수로 없으면 stdin에서 읽기
if [ -z "$MESSAGE" ]; then
    if [ -t 0 ]; then
        # 대화형 모드: 직접 입력
        echo -e "${BOLD}메시지를 입력하세요 (Ctrl+D로 완료):${NC}"
        MESSAGE=$(cat)
    else
        # 파이프 모드
        MESSAGE=$(cat)
    fi
fi

if [ -z "$MESSAGE" ]; then
    fail "메시지가 비어있습니다."
    exit 1
fi

# ─── Agent 헬스 체크 ─────────────────────────────────────────────────────────
echo -e "\n${BOLD}━━━ IMSMS share-to-imessage ━━━${NC}"
info "Agent: ${AGENT_URL}"
info "수신자: ${SEND_TO}"
info "메시지 길이: ${#MESSAGE}자"

HEALTH_RESPONSE=$(curl -sf --max-time 3 "${AGENT_URL}/actuator/health" 2>/dev/null || echo "")

if [ -z "$HEALTH_RESPONSE" ]; then
    fail "IMSMS Agent에 연결할 수 없습니다: ${AGENT_URL}"
    warn "Agent가 실행 중인지 확인하세요: curl ${AGENT_URL}/actuator/health"
    exit 2
fi

HEALTH_STATUS=$(echo "$HEALTH_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
IMESSAGE_STATUS=$(echo "$HEALTH_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('components',{}).get('imessage',{}).get('status','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")

if [ "$HEALTH_STATUS" != "UP" ]; then
    fail "Agent 상태: ${HEALTH_STATUS} (iMessage: ${IMESSAGE_STATUS})"
    warn "Agent 로그를 확인하세요: /opt/imsms-agent/logs/"
    exit 2
fi

ok "Agent UP (iMessage: ${IMESSAGE_STATUS})"

# ─── 페이로드 구성 ───────────────────────────────────────────────────────────
# JSON 특수문자 이스케이프 (python3 사용으로 안전 처리)
PAYLOAD=$(python3 -c "
import json, sys
send_to = sys.argv[1]
message = sys.argv[2]
print(json.dumps({'sendTo': send_to, 'message': message}))
" "$SEND_TO" "$MESSAGE")

# ─── dry-run 모드 ────────────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    warn "[DRY RUN] 실제 발송하지 않음"
    echo -e "\n${BOLD}엔드포인트:${NC} POST ${AGENT_URL}/api/send"
    echo -e "${BOLD}페이로드:${NC}"
    echo "$PAYLOAD" | python3 -m json.tool 2>/dev/null || echo "$PAYLOAD"
    echo ""
    ok "dry-run 완료"
    exit 0
fi

# ─── API 호출 ────────────────────────────────────────────────────────────────
info "발송 중..."

RESULT_TEMP=$(mktemp /tmp/imsms_send_result_XXXXXX.json)
trap "rm -f '$RESULT_TEMP'" EXIT

HTTP_CODE=$(curl -s -o "$RESULT_TEMP" -w "%{http_code}" \
    --max-time "$TIMEOUT" \
    -X POST "${AGENT_URL}/api/send" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "000" ]; then
    fail "네트워크 오류 — Agent 연결 실패 (timeout: ${TIMEOUT}s)"
    exit 2
fi

RESPONSE=$(cat "$RESULT_TEMP" 2>/dev/null || echo "{}")
RESULT_CD=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('resultCd','ERR'))" 2>/dev/null || echo "ERR")
RESULT_MSG=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('resultMsg','알 수 없는 오류'))" 2>/dev/null || echo "알 수 없는 오류")
IMS_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('imsId',''))" 2>/dev/null || echo "")

echo ""
if [ "$RESULT_CD" = "000" ]; then
    ok "발송 성공"
    [ -n "$IMS_ID" ] && info "ID: ${IMS_ID}"
    info "수신자: ${SEND_TO}"
    info "시각: $(date '+%Y-%m-%d %H:%M:%S')"
else
    fail "발송 실패 (HTTP ${HTTP_CODE}): ${RESULT_MSG}"
    warn "코드: ${RESULT_CD}"
    exit 3
fi

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
