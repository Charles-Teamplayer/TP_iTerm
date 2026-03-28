#!/usr/bin/env python3
# active-sessions orphan-sync
# window-groups.json의 프로파일 중 active-sessions에 없는 것을 tmux 기반으로 등록
import json, os, subprocess, tempfile
from datetime import datetime, timezone

now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
reg_path = os.path.expanduser('~/.claude/active-sessions.json')
wg_path = os.path.expanduser('~/.claude/window-groups.json')
act_path = os.path.expanduser('~/.claude/activated-sessions.json')

try:
    with open(reg_path) as f: reg = json.load(f)
    with open(wg_path) as f: groups = json.load(f)
    with open(act_path) as f: act = json.load(f)
except Exception as e:
    exit(0)

# activated-sessions: name → path 맵
name_to_path = {}
for p in act.get('activated', []):
    name_to_path[os.path.basename(p)] = p

reg_projects = {s['project'] for s in reg['sessions']}
added = []

for g in groups:
    if g.get('isWaitingList'): continue
    sname = g.get('sessionName', '')
    if not sname: continue

    for pname in g.get('profileNames', []):
        if pname in reg_projects: continue

        # tmux 창에서 window_id 찾기
        r = subprocess.run(['tmux', 'list-windows', '-t', sname, '-F', '#{window_id}|#{window_name}'],
                           capture_output=True, text=True)
        if r.returncode != 0: continue
        wid = None
        for line in r.stdout.strip().split('\n'):
            parts = line.split('|', 1)
            if len(parts) == 2 and parts[1] == pname:
                wid = parts[0]; break
        if not wid: continue

        # pane pid + tty
        rp = subprocess.run(['tmux', 'list-panes', '-t', wid, '-F', '#{pane_pid}|#{pane_tty}'],
                            capture_output=True, text=True)
        pline = rp.stdout.strip().split('\n')[0] if rp.stdout.strip() else ''
        if '|' not in pline: continue
        pane_pid, pane_tty = pline.split('|', 1)
        tty_base = pane_tty.replace('/dev/', '')

        # tty에서 claude PID 찾기
        rps = subprocess.run(['ps', '-o', 'pid,command', '-t', tty_base], capture_output=True, text=True)
        claude_pid = None
        exclude = ['watchdog', 'auto-restore', 'tab-', 'session-registry']
        for l in rps.stdout.split('\n'):
            l = l.strip()
            if not l: continue
            parts = l.split(None, 1)
            if len(parts) < 2: continue
            cmd = parts[1]
            if 'claude' in cmd and not any(x in cmd for x in exclude):
                import re
                if re.search(r'(?:^|/)claude(?:\s|$|--)', cmd):
                    claude_pid = parts[0]; break
        if not claude_pid: continue

        proj_dir = name_to_path.get(pname, os.path.expanduser(f'~/claude/{pname}'))
        reg['sessions'] = [s for s in reg['sessions'] if s['project'] != pname]
        reg['sessions'].append({
            'project': pname, 'dir': proj_dir,
            'pid': claude_pid, 'tty': tty_base,
            'started': now, 'last_heartbeat': now
        })
        added.append(f'{pname}(PID:{claude_pid})')

if added:
    reg['last_updated'] = now
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(reg_path), suffix='.tmp')
    with os.fdopen(fd, 'w') as f:
        json.dump(reg, f, indent=2)
    os.replace(tmp, reg_path)
    print('synced: ' + ', '.join(added))
