#!/usr/bin/env python3
"""
iTerm2 AutoLaunch: tmux 자동 attach + 탭 포커스 모니터 + 색상 동기화
- 시작 시 1회: tmux 없으면 auto-restore → attach
- 상시: FocusMonitor API로 포커스된 탭의 flash 프로세스 종료 + 색상 복원
- 상시: 3초 폴링으로 모든 탭 색상 동기화 (tmux CC 버퍼링 우회)
"""
import iterm2
import asyncio
import subprocess
import os
import signal
import time
import json

ENV = {**os.environ, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"}
STATE_DIR = os.path.expanduser("~/.claude/tab-color/states")
LOG_FILE = os.path.expanduser("~/.claude/logs/focus-monitor-py.log")

# 마지막으로 적용한 색상 캐시 (tty_name → (r, g, b))
_last_color: dict = {}


def _log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    except Exception:
        pass


def tmux_session_exists():
    r = subprocess.run(
        ["tmux", "has-session", "-t", "claude-work"],
        capture_output=True, env=ENV
    )
    return r.returncode == 0


def restore_sessions():
    script = os.path.expanduser("~/.claude/scripts/auto-restore.sh")
    subprocess.Popen(["bash", script], env=ENV)


def _has_cc_client():
    """tmux CC (control-mode) 클라이언트가 있는지 확인"""
    try:
        r = subprocess.run(
            ["tmux", "list-clients", "-t", "claude-work", "-F", "#{client_flags}"],
            capture_output=True, text=True, env=ENV
        )
        if r.returncode != 0:
            return False
        for flags in r.stdout.strip().splitlines():
            if "control-mode" in flags:
                return True
    except Exception:
        pass
    return False


async def tmux_attach(connection):
    """1회 실행: tmux -CC attach"""
    app = await iterm2.async_get_app(connection)

    has_tmux_role = False
    for window in app.windows:
        for tab in window.tabs:
            for session in tab.sessions:
                if session.get_variable("tmuxRole") not in (None, ""):
                    has_tmux_role = True
                    break
            if has_tmux_role:
                break
        if has_tmux_role:
            break

    if has_tmux_role:
        if _has_cc_client():
            _log("tmux CC 이미 attach — 스킵")
            return
        else:
            _log("tmuxRole 세션 있지만 CC 클라이언트 없음 — 재attach 필요")

    if not tmux_session_exists():
        restore_sessions()
        await asyncio.sleep(8)

    window = app.current_terminal_window
    if window is None and app.windows:
        window = app.windows[0]
    if window is None:
        return

    session = window.current_tab.current_session
    await session.async_send_text("tmux -CC attach -t claude-work\n")

    await asyncio.sleep(4)
    restore_script = os.path.expanduser("~/.claude/scripts/restore-tab-colors.sh")
    subprocess.Popen(["bash", restore_script], env=ENV)
    _log("tmux attach 완료")


def _kill_flash(tty_name):
    """flash PID 파일 읽고 프로세스 종료"""
    pid_file = f"/tmp/tab-flash-{tty_name}.pid"
    if not os.path.exists(pid_file):
        return False
    try:
        with open(pid_file) as f:
            pid = int(f.read().strip())
        os.kill(pid, signal.SIGTERM)
        _log(f"flash kill pid={pid} tty={tty_name}")
    except (ValueError, ProcessLookupError, PermissionError):
        pass
    try:
        os.remove(pid_file)
    except OSError:
        pass
    return True


def _get_focus_clear_states():
    """config.json에서 focus_clear_states 읽기 (없으면 기본값)"""
    config_file = os.path.expanduser("~/.claude/tab-color/config.json")
    try:
        with open(config_file) as f:
            cfg = json.load(f)
        return cfg.get("focus_clear_states", ["waiting", "attention"])
    except Exception:
        return ["waiting", "attention", "idle_10m", "idle_1h", "idle_1d", "idle_3d"]


def _restore_active(tty, tty_name):
    """waiting/attention/idle → active 상태 복원 (v3 엔진 호출)"""
    state_file = os.path.join(STATE_DIR, f"{tty_name}.json")
    if not os.path.exists(state_file):
        return
    try:
        with open(state_file) as f:
            data = json.load(f)
    except Exception:
        return
    if data.get("type") not in _get_focus_clear_states():
        return

    project = data.get("project", "")
    engine = os.path.expanduser("~/.claude/tab-color/engine/set-color.sh")
    env_with_tty = {**ENV, "TAB_TTY": tty}
    subprocess.run(
        ["bash", engine, "active", project],
        env=env_with_tty, check=False
    )
    _log(f"{data.get('type')} → active ({project}, {tty_name})")


def _make_color_esc(r, g, b) -> bytes:
    """탭 색상 escape code 바이트 생성"""
    return (
        f"\033]6;1;bg;red;brightness;{r}\007"
        f"\033]6;1;bg;green;brightness;{g}\007"
        f"\033]6;1;bg;blue;brightness;{b}\007"
    ).encode()


async def color_sync(connection):
    """상시: 3초마다 state 파일 읽어서 모든 탭 색상 동기화
    tmux CC 모드에서 비활성 탭은 escape code가 버퍼링되므로
    async_inject로 Python API 직접 주입해 즉시 반영.
    """
    _log("=== ColorSync 시작 ===")
    await asyncio.sleep(5)  # attach 완료 대기

    while True:
        try:
            app = await iterm2.async_get_app(connection)
            for window in app.windows:
                for tab in window.tabs:
                    for session in tab.sessions:
                        tty = await session.async_get_variable("tty")
                        if not tty:
                            continue
                        tty_name = tty.replace("/dev/", "")
                        state_file = os.path.join(STATE_DIR, f"{tty_name}.json")
                        if not os.path.exists(state_file):
                            continue
                        try:
                            with open(state_file) as f:
                                data = json.load(f)
                        except Exception:
                            continue

                        # flash(attention) 상태는 flash.sh가 직접 관리
                        if data.get("type") == "attention":
                            continue

                        color = data.get("color", {})
                        r = color.get("r", 128)
                        g = color.get("g", 128)
                        b = color.get("b", 128)

                        # 변경된 경우만 주입
                        if _last_color.get(tty_name) == (r, g, b):
                            continue

                        await session.async_inject(_make_color_esc(r, g, b))
                        _last_color[tty_name] = (r, g, b)

        except Exception as e:
            _log(f"color_sync 오류: {e}")

        await asyncio.sleep(3)


async def focus_monitor(connection):
    """상시 실행: 포커스된 탭의 flash 프로세스 자동 종료 + 색상 복원"""
    _log("=== FocusMonitor 시작 ===")
    app = await iterm2.async_get_app(connection)

    async with iterm2.FocusMonitor(connection) as monitor:
        while True:
            update = await monitor.async_get_next_update()
            if not update.active_session_changed:
                continue

            session_id = update.active_session_changed.session_id
            session = app.get_session_by_id(session_id)
            if session is None:
                continue

            tty = await session.async_get_variable("tty")
            if not tty:
                continue

            tty_name = tty.replace("/dev/", "")

            killed = _kill_flash(tty_name)
            _restore_active(tty, tty_name)
            # 캐시 무효화 — 다음 color_sync 사이클에서 재주입
            _last_color.pop(tty_name, None)

            if killed:
                _log(f"포커스 클리어: {tty_name}")


async def main(connection):
    # tmux attach (1회)
    await tmux_attach(connection)
    # focus monitor + color sync 병렬 실행
    await asyncio.gather(
        focus_monitor(connection),
        color_sync(connection),
    )


iterm2.run_forever(main)
