#!/bin/bash
# Claude Code Notification Hook — attention 상태 트리거
# Stop hook에서 호출: 세션이 멈추면 attention 상태로 전환
# (Claude가 권한 요청 등으로 대기 중일 때)
#
# 사용법: notification.sh attention|clear [프로젝트명]

ACTION="${1:-attention}"
PROJECT="${2:-$(basename "$PWD")}"
TAB_STATUS="$HOME/.claude/scripts/tab-status.sh"

[ -f "$TAB_STATUS" ] || exit 0

case "$ACTION" in
    attention)
        bash "$TAB_STATUS" attention "$PROJECT"
        ;;
    clear)
        bash "$TAB_STATUS" working "$PROJECT"
        ;;
esac
