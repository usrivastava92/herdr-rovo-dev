#!/usr/bin/env bash
# Isolated OSC regression tests; Python's stdlib supplies a real controlling PTY.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'desktop-status tests require python3' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'desktop-status tests require jq' >&2; exit 1; }
python3 - "$SCRIPT_DIR/.." <<'PY'
import base64
import errno
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import shutil
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1]).resolve()
hook = str(root / 'bin/rovo-herdr-desktop-hook')
wrapper = str(root / 'bin/rovo-herdr-desktop')
osc = re.compile(rb'\x1b\]7501;([^\x1b]*)\x1b\\')


def records(data):
    found = []
    for match in osc.finditer(data):
        record = dict(field.split('=', 1) for field in match[1].decode().split(':'))
        assert record.get('app') == 'rovo-dev', record
        if 'msg' in record:
            raw = base64.b64decode(record['msg'], validate=True)
            assert len(raw) <= 2048
            record['decoded_msg'] = raw.decode('utf-8')
            assert not any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in record['decoded_msg'])
        assert len(match[0]) <= 4096
        found.append(record)
    return found


def run_pty(command, payload=b'', extra_env=None, terminal_input=False, terminate=False,
            interrupt=False):
    # forkpty performs the platform's native controlling-terminal/session setup.
    # In particular, avoid subprocess preexec_fn + TIOCSCTTY: that combination
    # can stall before exec on macOS even though Popen has returned.
    input_read, input_write = os.pipe()
    output_read, output_write = os.pipe()
    error_read, error_write = os.pipe()
    info_read, info_write = os.pipe()
    pid, master = pty.fork()
    if pid == 0:
        try:
            tty_path = os.ttyname(0)
            # Rovo keeps its terminal open while a hook receives piped stdin
            # and captured stdout. Keep that slave reference across exec too;
            # closing the last slave otherwise produces an early master EOF.
            tty_hold = os.dup(0)
            os.set_inheritable(tty_hold, True)
            os.write(info_write, tty_path.encode())
            if not terminal_input:
                os.dup2(input_read, 0)
            os.dup2(output_write, 1)
            os.dup2(error_write, 2)
            for fd in (input_read, input_write, output_read, output_write,
                       error_read, error_write, info_read, info_write):
                os.close(fd)
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith('HERDR_')}
            env.update(HERDR_ROVO_TRANSPORT='osc', HERDR_ROVO_TTY=tty_path)
            for key, value in (extra_env or {}).items():
                if value is None:
                    env.pop(key, None)
                else:
                    env[key] = value
            os.execvpe(command[0], command, env)
        finally:
            os._exit(127)

    for fd in (input_read, output_write, error_write, info_write):
        os.close(fd)
    tty_path = os.read(info_read, 256).decode()
    os.close(info_read)
    streams = {master: bytearray(), output_read: bytearray(), error_read: bytearray()}
    readers = set(streams)
    pending = memoryview(payload)
    if terminal_input:
        os.write(master, payload)
    if terminal_input or not payload:
        os.close(input_write)
        input_write = None
    status = None
    signalled = False
    deadline = time.monotonic() + 10
    try:
        while readers or status is None:
            assert time.monotonic() < deadline, 'PTY command timed out: ' + repr(command)
            ready, writable, _ = select.select(list(readers),
                                               [input_write] if input_write is not None else [],
                                               [], 0.05)
            if writable:
                written = os.write(input_write, pending[:4096])
                pending = pending[written:]
                if not pending:
                    os.close(input_write)
                    input_write = None
            for fd in ready:
                try:
                    chunk = os.read(fd, 65536)
                except OSError as error:
                    if fd != master or error.errno != errno.EIO:
                        raise
                    chunk = b''
                if chunk:
                    streams[fd].extend(chunk)
                else:
                    readers.remove(fd)
            if (terminate or interrupt) and not signalled and b'READY\n' in streams[output_read]:
                os.killpg(pid, signal.SIGINT if interrupt else signal.SIGTERM)
                signalled = True
            if status is None:
                waited, child_status = os.waitpid(pid, os.WNOHANG)
                if waited:
                    status = child_status
        assert not (terminate or interrupt) or signalled, 'Rovo fixture did not become ready'
        rc = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)
        return rc, bytes(streams[output_read]), bytes(streams[error_read]), bytes(streams[master]), tty_path
    finally:
        if status is None:
            try:
                os.killpg(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        for fd in (master, output_read, error_read, input_write):
            if fd is not None:
                os.close(fd)


def event(name, **fields):
    return json.dumps(dict(hook_event_name=name, **fields)).encode()


print('test: hook bypasses captured stdout and sends encoded status to the tty')
for name, state in [('on_session_start', 'idle'), ('on_user_prompt', 'working'),
                    ('on_tool_start', 'working'), ('on_tool_end', 'working'),
                    ('on_tool_permission', 'blocked'), ('on_complete', 'done'),
                    ('on_error', 'error'), ('on_session_end', 'clear')]:
    rc, out, err, tty, _ = run_pty([hook], event(name))
    assert rc == 0 and out == b'' and err == b'', (name, rc, out, err)
    reports = records(tty)
    assert len(reports) == 1 and reports[0]['state'] == state, (name, tty)
    assert reports[0].get('kind') == ('permission' if name == 'on_tool_permission' else None)
    if name == 'on_error':
        assert reports[0]['decoded_msg'] == 'Rovo Dev hit an error'

print('test: UTF-8, control removal, and message size stay within protocol limits')
tool = '工具😀\n\t\x1b\x85' * 600
rc, out, err, tty, _ = run_pty([hook], event('on_tool_start', attributes={'tool_input': {'tool_name': tool}}))
report = records(tty)[0]
assert rc == 0 and out == b'' and report['state'] == 'working'
assert report['decoded_msg'].startswith('Rovo Dev started 工具😀')
assert len(report['decoded_msg'].encode()) <= 2048

print('test: invalid, unknown, and non-opted-in hook calls emit no status')
for payload in [b'{', b'null', b'[]', b'{}', b'{"hook_event_name":123}', event('future_event')]:
    rc, out, err, tty, _ = run_pty([hook], payload)
    assert rc == 0 and out == b'' and tty == b'', (payload, rc, out, err, tty)
for mode in [None, '', 'tui']:
    rc, out, err, tty, _ = run_pty([hook], event('on_complete'), {'HERDR_ROVO_TRANSPORT': mode})
    assert rc == 0 and out == b'' and err == b'' and tty == b''

print('test: hook refuses arbitrary output files and unavailable terminal devices')
with tempfile.TemporaryDirectory() as directory:
    target = Path(directory) / 'not-a-terminal'
    target.write_text('untouched')
    for bad_path in [str(target), '/dev/null', '/dev/pts/999999999']:
        rc, out, err, tty, _ = run_pty([hook], event('on_complete'), {'HERDR_ROVO_TTY': bad_path})
        assert rc == 0 and out == b'' and tty == b''
        assert b'terminal' in err
    assert target.read_text() == 'untouched'

print('test: wrapper retains terminal input, argv, exit status, and final cleanup')
with tempfile.TemporaryDirectory() as directory:
    installed = Path(directory) / 'installed'
    installed.mkdir()
    installed_wrapper = installed / 'rovo-herdr-desktop'
    shutil.copy2(wrapper, installed_wrapper)
    launcher = str(installed_wrapper)
    sidecar = installed / 'rovo-desktop-config.json'
    fixture = Path(directory) / 'rovo'
    fixture.write_text('''#!/usr/bin/env python3
import json, os, signal, sys, time
if '--config-fixture' in sys.argv:
    print(json.dumps({'config': os.environ.get('ROVO_DEV_CONFIG_FILE')}), flush=True)
elif '--interrupt-fixture' in sys.argv:
    assert sys.stdin.isatty()
    assert os.getpgrp() == os.tcgetpgrp(0)
    interrupted = False
    def handle_interrupt(*_):
        global interrupted
        interrupted = True
    signal.signal(signal.SIGINT, handle_interrupt)
    print('READY', flush=True)
    while not interrupted:
        time.sleep(0.01)
    print('CONTINUED', flush=True)
    sys.exit(int(sys.argv[-1]))
elif '--signal-fixture' in sys.argv:
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    print('READY', flush=True)
    signal.pause()
else:
    print(json.dumps({'argv': sys.argv[1:], 'transport': os.environ.get('HERDR_ROVO_TRANSPORT'),
                      'tty': os.environ.get('HERDR_ROVO_TTY'), 'input': input(),
                      'isatty': sys.stdin.isatty()}), flush=True)
    sys.exit(37)
''')
    fixture.chmod(0o755)
    forbidden = Path(directory) / 'not-a-terminal'
    forbidden.write_text('untouched')
    env = {'PATH': directory + os.pathsep + os.environ['PATH'],
           'HERDR_ROVO_TTY': str(forbidden),
           'ROVO_DEV_CONFIG_FILE': '/inherited/config.yml'}
    args = ['chat', 'two words', '', '--flag=工具']
    rc, out, err, tty, tty_path = run_pty([launcher] + args, b'hello terminal\n', env, terminal_input=True)
    result = json.loads(out)
    assert rc == 37 and err == b'', (rc, out, err, tty)
    assert result == {'argv': args, 'transport': 'osc', 'tty': tty_path,
                      'input': 'hello terminal', 'isatty': True}, result
    assert [r['state'] for r in records(tty)] == ['idle', 'clear'], tty
    assert forbidden.read_text() == 'untouched'

    print('test: signalled wrapper clears status and retains signal exit code')
    rc, out, err, tty, _ = run_pty([launcher, '--signal-fixture'], extra_env=env, terminate=True)
    assert rc == 143 and err == b'', (rc, out, err)
    assert [r['state'] for r in records(tty)] == ['idle', 'clear'], tty

    print('test: foreground Rovo handles group SIGINT and preserves its eventual exit')
    for exit_code in (0, 37, 130):
        rc, out, err, tty, _ = run_pty(
            [launcher, '--interrupt-fixture', str(exit_code)], extra_env=env,
            terminal_input=True, interrupt=True)
        assert rc == exit_code and out == b'READY\nCONTINUED\n' and err == b'', (rc, out, err)
        assert [r['state'] for r in records(tty)] == ['idle', 'clear'], tty

    print('test: absent sidecar preserves inherited config and installed sidecar overrides it')
    rc, out, err, tty, _ = run_pty([launcher, '--config-fixture'], extra_env=env)
    assert rc == 0 and err == b'' and json.loads(out) == {'config': '/inherited/config.yml'}
    config = Path(directory) / 'chosen config.yml'
    config.write_text('fixture config')
    sidecar.write_text(json.dumps({'config_file': str(config)}))
    for inherited_config in (None, '/wrong/config.yml'):
        config_env = dict(env, ROVO_DEV_CONFIG_FILE=inherited_config)
        rc, out, err, tty, _ = run_pty([launcher, '--config-fixture'], extra_env=config_env)
        assert rc == 0 and err == b'' and json.loads(out) == {'config': str(config)}, (rc, out, err)
        assert [r['state'] for r in records(tty)] == ['idle', 'clear'], tty

    print('test: malformed present sidecar fails before launching Rovo')
    for invalid in ('{', '', '{}', 'null', '[]', '{"config_file":""}',
                    '{"config_file":"relative.yml"}', '{"config_file":123}',
                    '{"config_file":"/one"}\n{"config_file":"/two"}'):
        sidecar.write_text(invalid)
        rc, out, err, tty, _ = run_pty([launcher, '--config-fixture'], extra_env=env)
        assert rc == 1 and out == b'' and tty == b'', (invalid, rc, out, tty)
        assert b'invalid desktop config sidecar' in err, (invalid, err)
    sidecar.unlink()

    print('test: unavailable tty does not prevent Rovo from running')
    env_without_tty = os.environ.copy()
    env_without_tty.update(env)
    result = subprocess.run([launcher, 'chat'], input=b'headless\n', stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env_without_tty, start_new_session=True,
                            timeout=10)
    assert result.returncode == 37, result
    data = json.loads(result.stdout)
    assert data['input'] == 'headless' and data['tty'] == '' and data['transport'] == 'osc'
    assert b'no controlling terminal' in result.stderr
    assert b'\x1b]7501;' not in result.stdout

print('desktop-status tests passed')
PY
