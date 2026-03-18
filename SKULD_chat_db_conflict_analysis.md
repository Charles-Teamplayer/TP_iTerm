# chat.db 동시 접근 충돌 분석
## SKULD (연결/정합성 축) — 2026-03-18

---

## Executive Summary

**현재 상태**: TP_A.iMessage_standalone과 IMSMS Agent가 **같은 chat.db를 독립적으로 폴링**하고 있음.

**충돌 수준**: 🔴 **CRITICAL**
- 중복 메시지 처리 가능성 (라우팅 충돌)
- ROWID 추적 분리로 인한 메시지 손실/중복
- 메시지 라우팅 의도 불명확 → 시스템 정합성 파괴

---

## 1. 동시 접근 분석

### 1.1 DB 접근 방식 비교

| 항목 | Standalone | Agent |
|------|-----------|-------|
| **라이브러리** | better-sqlite3 | better-sqlite3 |
| **연결 모드** | read-only | read-only |
| **폴링 간격** | 3000ms (기본) | 5000ms (기본) |
| **WAL 모드** | ✅ 명시적 활성화 | ❌ 미설정 |
| **ROWID 추적** | 파일로 저장 (`.imessage-claude-lastid`) | 메모리 (서버 재시작 시 손실) |
| **Connection Pool** | 폴링마다 재연결 | 싱글톤 연결 |
| **동시성** | Event-based | Interval-based |

### 1.2 SQLite WAL 모드에서의 안전성

```typescript
// Standalone (imessage-watcher.ts:441)
this.db.pragma('journal_mode = WAL');
```

✅ **WAL 모드는 동시 다중 읽기 지원**
- Read-only 연결 2개는 충돌하지 않음
- 그러나 macOS iMessage 앱이 쓰는 동안에도 읽을 수 있음

❌ **Agent는 WAL 설정 없음**
- SQLite 기본값 DELETE mode → 동시성 제한
- 두 연결이 겹치면 `database is locked` 발생 가능

---

## 2. 메시지 중복 처리 시나리오

### 2.1 같은 메시지가 두 번 처리되는 경로

```
시간(t) | Standalone | Agent | 결과
--------+------------|-------|-------
t=0    | -          | -     | chat.db에 메시지 M1 기록 (ROWID=100)
t=3s   | poll() →   | -     | lastRowId=99 → 100 감지 → emit('message')
t=5s   | -          | check()| lastRowId=99 → 100 감지 → getNewIncomingMessages()
t=6s   | -          | send()| MQ로 Backend에 전송
t=?    | send()     | -     | Claude로 처리
```

**문제**:
- Standalone은 **명령 메시지만 처리** (예: `/cc fix this bug`)
- Agent는 **모든 메시지를 Backend로 전달**
- 같은 메시지가 2개 시스템에서 동시에 감지되고, **라우팅 의도가 충돌**

### 2.2 ROWID 추적의 분리

**Standalone**:
```typescript
// LAST_ID_FILE = ~/.imessage-claude-lastid
fs.writeFileSync(LAST_ID_FILE, String(this.lastRowId), 'utf-8');
```
✅ 재시작 후에도 이전 ROWID 복구 → 메시지 손실 방지

**Agent**:
```typescript
private lastMessageRowId: number = 0; // 메모리에만 저장
this.lastMessageRowId = row?.maxId || 0; // 첫 시작 시만 초기화
```
❌ 서버 재시작 시 0으로 리셋 → **모든 히스토리 메시지를 다시 처리 위험**

---

## 3. 현재 메시지 라우팅 논리 (충돌점)

### 3.1 Standalone의 의도
```typescript
// src/monitor/imessage-watcher.ts
- 특정 폰 번호(+821067051080)의 메시지만 감지
- 명령어 (`/cc`, `/status` 등) 파싱 및 실행
- Claude Code와만 상호작용
- **다른 시스템으로 라우팅하지 않음**
```

### 3.2 Agent의 의도
```typescript
// src/handlers/MessageReceiveHandler.ts
- chat.db의 **모든 메시지** 감지 (IMSMS Agent 수신 대상)
- Backend (IMSMS Server)로 모든 메시지 MQ 전송
- 서버에서 처리 후 응답
```

### 3.3 충돌 시나리오

```
사용자가 메시지 "hello" 전송
    ↓
[chat.db] ROWID=100에 기록
    ↓
Standalone (폴링: 3s)         Agent (폴링: 5s)
├─ ROWID > 99 찾음           ├─ ROWID > 99 찾음
├─ "hello" 감지              ├─ "hello" 감지
├─ 명령어 아님 → 무시       ├─ Backend에 "hello" 전송
└─ (처리 안 함)              ├─ MQ → RabbitMQ → Backend
                             └─ IMSMS 시스템에서 처리

결과: 정합성 OK (Standalone은 무시, Agent만 처리)

---

사용자가 "/cc generate code" 전송
    ↓
Standalone (3s)                  Agent (5s)
├─ "/cc generate code" 감지     ├─ "/cc generate code" 감지
├─ 명령어 파싱                   ├─ Backend에 전송
├─ Claude Code 실행             ├─ IMSMS 서버가 처리(?)
├─ 응답 생성                     ├─ 응답이 중복일 수 있음
└─ iMessage로 회신

결과: 🔴 중복 처리 위험
     - 명령 실행이 2번 되거나
     - 응답이 2개 올 수 있음
```

---

## 4. 통합 메시지 라우팅 설계 (3가지 옵션)

### Option 1: Agent 중심화 (권장)
**개념**: IMSMS Agent가 모든 메시지를 먼저 받고, Standalone은 폐기

```
┌─────────────────────────────────────────┐
│  chat.db (iMessage 데이터베이스)         │
└──────────────┬──────────────────────────┘
               │ (모든 메시지)
               ↓
        ┌──────────────┐
        │ IMSMS Agent  │ ← 유일한 폴러
        │ chat.db      │
        │ 리더         │
        └──┬───────┬──┐
           │       │  │
      ─────┘       │  └─────
      │            │        │
      ↓            ↓        ↓
   Backend    (명령 라우팅)  Webhook
   (모든 msg)  Standalone    (Standalone으로)
               (선택적)

라우팅 규칙:
├─ Backend에 모든 메시지 전송
├─ 메시지 타입이 "/cc" / "/status" 등이면
│  └─ Webhook → Standalone으로 라우팅
└─ 나머지는 Backend 처리
```

**장점**:
- ✅ 단일 폴링 소스 → 중복 불가능
- ✅ ROWID 추적 1개만 관리
- ✅ Backend가 라우팅 로직 통제
- ✅ 메시지 순서 보장

**단점**:
- ❌ Standalone이 수동 대기 상태 (webhook 기반)
- ❌ Backend 의존도 증가

**구현 복잡도**: ⭐⭐⭐ (중간)

---

### Option 2: Standalone 중심화
**개념**: Standalone이 모든 메시지를 먼저 받고, Agent에 포워드

```
┌─────────────────────────────────────────┐
│  chat.db (iMessage 데이터베이스)         │
└──────────────┬──────────────────────────┘
               │ (모든 메시지)
               ↓
    ┌──────────────────────┐
    │ A.iMessage Standalone │ ← 유일한 폴러
    │ (IMessageWatcher)     │
    └─────┬────────┬───────┘
          │        │
      ───┘        └───
      │               │
      ↓               ↓
   명령어 처리    일반 메시지
   (Claude)     로 라우팅
                (RabbitMQ 토픽)
                    │
                    ↓
              IMSMS Backend
              (IMSMS Agent)
```

**장점**:
- ✅ Standalone의 명령어 파싱 활용
- ✅ 메시지 의도 먼저 분류

**단점**:
- ❌ Standalone이 Backend와 강하게 결합
- ❌ Standalone 다운 시 IMSMS도 멈춤
- ❌ 아키텍처 변경 대규모

**구현 복잡도**: ⭐⭐⭐⭐⭐ (높음)

---

### Option 3: 완전 분리 (지양)
**개념**: 다른 번호나 키워드로 분기

```
전화번호 기반:
├─ +821067051080 → Standalone만 처리
└─ 다른 번호 → IMSMS Agent 처리

또는 텍스트 기반:
├─ "/cc" 로 시작 → Standalone으로 라우팅
└─ 나머지 → Agent로 라우팅
```

**장점**:
- ✅ 시스템 간 의존도 제거
- ✅ 완전 독립 운영

**단점**:
- ❌ 사용자 경험 분단 (어떤 번호로 보내야 하나?)
- ❌ 비용 낭비 (2개 시스템 운영)
- ❌ 관리 복잡도 증가

**권장하지 않음** ❌

---

## 5. WAL 모드 설정 권장사항

### 즉시 조치

**1. IMSMS Agent에 WAL 모드 추가**
```typescript
// TP_newIMSMS/apps/agent/node/src/imessage/ChatDBReader.ts

connect(): boolean {
  try {
    this.db = new Database(this.dbPath, { readonly: true, fileMustExist: true });

    // ✅ WAL 모드 명시적 활성화
    this.db.pragma('journal_mode = WAL');

    this.initializeLastMessageId();
    return true;
  } catch (error) { ... }
}
```

**2. Agent에 ROWID 저장 메커니즘 추가**
```typescript
// ChatDBReader 수정
private lastIdFile: string;
private LAST_ID_FILE_PATH = path.join(os.homedir(), '.imsms-agent-lastid');

// 시작 시
private initializeLastMessageId(): void {
  // 1. 파일에서 복구
  if (fs.existsSync(this.LAST_ID_FILE_PATH)) {
    try {
      const stored = parseInt(fs.readFileSync(...), 10);
      this.lastMessageRowId = stored || 0;
      return;
    } catch { }
  }

  // 2. 파일 없으면 현재 MAX로 스킵
  const row = this.db.prepare('SELECT MAX(ROWID) as maxId FROM message').get();
  this.lastMessageRowId = row?.maxId || 0;
}

// 메시지 처리 후
saveLastRowId(): void {
  fs.writeFileSync(this.LAST_ID_FILE_PATH, String(this.lastMessageRowId), 'utf-8');
}
```

---

## 6. 현재 실행 상태 검증

### 6.1 두 시스템이 동시에 실행 중인가?

```bash
# 확인 명령어
ps aux | grep -E "node|claude" | grep -v grep
```

**조사 결과 필요**:
- Standalone이 현재 실행 중인지?
- Agent가 현재 실행 중인지?
- 동시 실행인지 순차 실행인지?

### 6.2 실제 충돌 로그 분석

필요한 로그:
- Standalone: `./logs/` (설정 기준)
- Agent: `TP_newIMSMS/apps/agent/node/logs/`

**확인할 항목**:
1. "Found N new message(s)" 시점이 겹치는가?
2. 같은 ROWID를 2번 처리한 기록이 있는가?
3. Agent 재시작 후 히스토리 메시지를 다시 처리했는가?

---

## 7. 권장 통합 라우팅 설계 (최종)

### 7.1 **Option 1 + 즉시 조치** (RECOMMEND)

```
Phase 1 (즉시 — 위험 감소)
├─ Agent에 WAL 모드 추가
├─ Agent에 ROWID 저장 메커니즘 추가
└─ 각 시스템에 "충돌 감지 로깅" 추가
   (같은 ROWID를 2번 처리하면 경고)

Phase 2 (1주일 내)
├─ Backend의 "메시지 라우팅 엔드포인트" 개발
│  ├─ POST /api/messages/route
│  └─ Body: { messageGuid, text, handle }
│  └─ Response: { target: 'standalone' | 'imsms' | 'both' }
├─ Agent → Backend로 모든 메시지 전송 (기존)
├─ Backend가 라우팅 결정
└─ 명령어 메시지면 Webhook → Standalone

Phase 3 (정리)
├─ Standalone의 자체 폴링 제거
├─ Standalone은 Backend Webhook만 수신
└─ Agent가 유일한 폴러 역할
```

### 7.2 메시지 흐름 (최종 상태)

```
┌──────────────────────────────────────────────────┐
│            chat.db (iMessage DB)                 │
└─────────────────┬────────────────────────────────┘
                  │
                  ↓ (모든 메시지)
        ┌─────────────────────┐
        │  IMSMS Agent        │ ← Unique Poller
        │  (ChatDBReader)     │    (ROWID 중앙화)
        │  [WAL + ROWID 저장]│
        └────────┬────────────┘
                 │
                 ↓ (모든 메시지 + GUID)
        ┌─────────────────────┐
        │  Backend API        │ ← 라우팅 로직
        │  /api/messages      │    (명령 vs 일반)
        │  /api/messages/     │
        │    route            │
        └────────┬────────────┘
                 │
            ┌────┴─────────┐
            │              │
      (명령어)        (일반 메시지)
            │              │
            ↓              ↓
     Webhook:          IMSMS 처리
     localhost:9000/  (유저 메시지)
     message-from-
     agent
            │
            ↓
    ┌──────────────────┐
    │ Standalone       │
    │ (Claude 처리)    │
    └──────────────────┘
```

---

## 8. 체크리스트 (구현 순서)

### 🔴 P0 (긴급)
- [ ] Agent에 WAL 모드 추가 (`pragma('journal_mode = WAL')`)
- [ ] 두 시스템이 현재 동시 실행 중인지 확인
- [ ] 중복 메시지 처리 로그 존재 여부 확인

### 🟠 P1 (1주일)
- [ ] Agent에 ROWID 저장 메커니즘 추가
- [ ] 충돌 감지 로깅 추가
- [ ] Backend 라우팅 엔드포인트 설계

### 🟡 P2 (2-3주)
- [ ] Backend 라우팅 로직 구현
- [ ] Standalone → Webhook 기반으로 전환
- [ ] 통합 테스트

---

## 9. 참고: SQLite WAL vs DELETE 모드

| 항목 | WAL | DELETE |
|------|-----|--------|
| **동시 읽기** | ✅ 지원 | ❌ 제한 |
| **성능** | 빠름 | 상대적 느림 |
| **디스크 사용** | WAL 파일 추가 | 기본 |
| **복구 속도** | 상대적 느림 | 빠름 |
| **권장** | ✅ 최신 환경 | 오래된 시스템 |

---

## 결론

| 항목 | 현재 상태 | 위험도 | 개선안 |
|------|---------|--------|--------|
| **동시 접근** | 2개 시스템 | 🔴 높음 | Agent 중심화 + WAL 설정 |
| **중복 처리** | ROWID 분리 | 🔴 높음 | 중앙화 ROWID 추적 |
| **메시지 손실** | 메모리 저장 | 🟠 중간 | 파일 저장 메커니즘 |
| **라우팅 정합성** | 불명확 | 🔴 높음 | Backend 라우팅 로직 통제 |

**최종 권고**: **Option 1 (Agent 중심화) + Phase 1-3 단계별 구현**
- 즉시: WAL + ROWID 저장
- 1주: Backend 라우팅
- 3주: Standalone 웹훅 전환
