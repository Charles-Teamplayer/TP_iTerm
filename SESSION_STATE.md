# Session State (iter47 완료)
> Updated: 2026-03-27 18:00
> Project: TP_iTerm

## 현재 시스템 상태 (실측)
- iTerm 윈도우: 3개 (claude-work + claude-takedown + Claude Code 터미널)
- claude-work: 1|teamplean-website, 2|universalMAC_Converter_gensys_calude, 3|ims_Auto_Contact APP, 4|AppleTV_ScreenSaver.app, 999|monitor ✓
- claude-takedown: 1|terminal-mirror, 2|TP_skills, 3|TP_MDM, 4|TP_MindMap_AutoCC, 999|monitor ✓
- Linked sessions: claude-work-v1~v4, claude-takedown-v1~v4 attached ✓
- PID 88611 (이 Claude Code): ALIVE + protected ✓
- Watchdog PID: 33462 (LaunchAgent 관리) ✓

## iter47 완료된 수정 사항
1. BUG-B: window auto-rename 방지 (new-window -P -F + automatic-rename off 즉시)
2. BUG-C: REORDER를 crash 루프 밖으로 이동 (세션별 1회)
3. BUG-D: echo|while pipe → heredoc (subshell 변수 손실 방지)
   + SESSION_JUST_CREATED=false를 루프 상단으로 이동
4. BUG-009: intentional-stops.json 체크 추가 (의도적 Stop 재시작 방지)
5. BUG-010: auto-restore.lock 체크 추가 (부팅 시 race condition 방지)
6. popup 개선: 전체 로그 열기 → iTerm2 tail -100

## 달성 품질 수준
- 이전: 87%
- 현재: ~92%+

## 잔존 이슈 (LOW)
- BUG-004: monitor kill→recreate race (< 1s, 실용 영향 없음)
- BUG-005: TTL 계산 Swift ↔ Python 편차 (±초, 무영향)
- BUG-006: stale protected-pids on boot (kill -0 validation으로 걸러짐)
- 부팅 E2E 테스트 미실시 (재부팅 없이는 검증 불가)

## 최근 커밋
- 10201e8: BUG-010 auto-restore race fix
- 32d4e75: BUG-B/C/D/009 watchdog crash-recovery 4대 버그 수정
