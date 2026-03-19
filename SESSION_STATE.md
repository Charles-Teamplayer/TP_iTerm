# TP_iTerm 시스템 상태
> 최종 업데이트: 2026-03-20

## 시스템 상태: 안정화 완료

## 주요 수정 완료 항목
- TTY write 제거: tab_focus_status.py → tmux -CC attach 충돌 해결
- TmuxDashboardLimit=20: 15개 창 대시보드 방지
- attachToITerm(): /tmp/magi-attach.scpt 방식으로 AppleScript 실행
- com.claude.magi-restore.plist: /Applications/MAGI-Restore.app으로 경로 수정
- configs/settings.json: Notification hook 추가 (fresh install 지원)

## 재부팅 후 복원 플로우
1. LaunchAgent (com.claude.auto-restore) → tmux claude-work 15개 창 생성
2. LaunchAgent (com.claude.magi-restore) → MAGI-Restore.app 실행
3. 사용자가 MAGI-Restore → 전체복원 → repairDeadWindows() + attachToITerm()
4. iTerm2 탭으로 claude-work 세션 연결됨

## 미완료
- 실제 재부팅 end-to-end 검증 (사용자 직접 수행 필요)
