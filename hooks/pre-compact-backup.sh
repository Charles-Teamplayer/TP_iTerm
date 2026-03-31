#!/bin/bash
# PreCompact hook: 컨텍스트 압축 전 세션 상태 백업
# JSONL 대화 파일을 타임스탬프 붙여서 백업

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
PROJECT=$(basename "$PWD")
BACKUP_DIR="$HOME/claude/TP_history/_global/compact_backups"

mkdir -p "$BACKUP_DIR"

# 현재 프로젝트의 최신 JSONL 대화 파일 백업
# Claude Code는 PWD의 /._를 모두 -로 치환하여 프로젝트 디렉토리명 생성
CONV_DIR="$HOME/.claude/projects/$(printf '%s' "$PWD" | tr '/._' '-')"
if [ -d "$CONV_DIR" ]; then
    LATEST_JSONL=$(ls -t "$CONV_DIR"/*.jsonl 2>/dev/null | head -1)
    if [ -n "$LATEST_JSONL" ]; then
        cp "$LATEST_JSONL" "$BACKUP_DIR/${PROJECT}_${TIMESTAMP}.jsonl"
    fi
fi

# SESSION_STATE.md 생성 (Claude가 압축 후 읽을 수 있도록)
STATE_FILE="$PWD/SESSION_STATE.md"
cat > "$STATE_FILE" << EOF
# Session State (Auto-saved at compact)
> Generated: $(date '+%Y-%m-%d %H:%M:%S')
> Project: $PROJECT

## Note
이 파일은 컨텍스트 압축 직전에 자동 생성되었습니다.
Claude는 압축 후 이 파일을 읽어서 맥락을 복구하세요.
압축 전 대화 원본: $BACKUP_DIR/${PROJECT}_${TIMESTAMP}.jsonl

## Recovery
압축 후 맥락이 부족하면:
1. 이 파일을 Read
2. 필요시 JSONL 원본에서 상세 내용 확인
EOF

echo "[${TIMESTAMP}] PreCompact backup: $PROJECT" >> "$BACKUP_DIR/backup.log"
