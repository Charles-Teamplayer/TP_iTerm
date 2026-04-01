#!/usr/bin/env python3
"""
iTerm2 탭 포커스 감지 → 색상 복원 + 배지 클리어
탭 클릭 시 waiting/attention → active(초록) 자동 전환
"""

import iterm2
import os
import json
import asyncio
import signal
import subprocess
import time

STATE_DIR = os.path.expanduser("~/.claude/tab-color/states")
SET_COLOR = os.path.expanduser("~/.claude/tab-color/engine/set-color.sh")
ENV = {**os.environ, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"}
LOG_FILE = os.path.expanduser("~/.claude/logs/focus-monitor-py.log")


def _log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    except Exception:
        pass


def _kill_flash(tty_name):
    pid_file = f"/tmp/tab-flash-{tty_name}.pid"
    if not os.path.exists(pid_file):
        return False
    try:
        with open(pid_file) as f:
            pid_str = f.read().strip()
        if not pid_str:
            os.remove(pid_file)
            return False
        pid = int(pid_str)
        os.kill(pid, signal.SIGTERM)
    except (ValueError, ProcessLookupError, PermissionError, FileNotFoundError):
        pass
    try:
        os.remove(pid_file)
    except OSError:
        pass
    return True


CONFIG_FILE = os.path.expanduser("~/.claude/tab-color/config.json")

def _get_focus_clear_states():
    """config.json에서 focus_clear_states 읽기 (없으면 기본값)"""
    try:
        with open(CONFIG_FILE) as f:
            cfg = json.load(f)
        return cfg.get("focus_clear_states", ["waiting", "attention"])
    except Exception:
        return ["waiting", "attention", "idle_10m", "idle_1h", "idle_1d", "idle_3d"]


def _restore_active(tty, tty_name):
    """focus_clear_states → active 색상 복원"""
    state_file = os.path.join(STATE_DIR, f"{tty_name}.json")
    if not os.path.exists(state_file):
        return
    try:
        with open(state_file) as f:
            data = json.load(f)
    except Exception:
        return
    state = data.get("type", "")
    if state not in _get_focus_clear_states():
        return
    project = data.get("project", "")
    env = {**ENV, "TAB_TTY": tty}
    subprocess.run(["bash", SET_COLOR, "active", project], env=env, check=False)
    _log(f"{state} → active ({project}, {tty_name})")


async def _handle_session(app, session_id):
    session = app.get_session_by_id(session_id)
    if session is None:
        return
    try:
        tty = await session.async_get_variable("tty")
        if tty:
            tty_name = tty.replace("/dev/", "")
            _kill_flash(tty_name)
            _restore_active(tty, tty_name)
        await session.async_set_variable("user.badge", "")
    except Exception as e:
        _log(f"handle_session error: {e}")


async def main(connection):
    app = await iterm2.async_get_app(connection)
    _log("=== FocusMonitor 시작 v2 (active_session + selected_tab) ===")

    async with iterm2.FocusMonitor(connection) as monitor:
        while True:
            update = await monitor.async_get_next_update()

            # active_session_changed: 세션 직접 전환
            if update.active_session_changed:
                session_id = update.active_session_changed.session_id
                _log(f"active_session_changed: {session_id[:8]}")
                await _handle_session(app, session_id)

            # selected_tab_changed: tmux -CC 탭 전환 시 발생
            elif update.selected_tab_changed:
                tab_id = update.selected_tab_changed.tab_id
                _log(f"selected_tab_changed: {tab_id[:8]}")
                # 탭의 current session 가져오기
                for window in app.windows:
                    for tab in window.tabs:
                        if tab.tab_id == tab_id:
                            session = tab.current_session
                            if session:
                                await _handle_session(app, session.session_id)
                            break


iterm2.run_forever(main)
