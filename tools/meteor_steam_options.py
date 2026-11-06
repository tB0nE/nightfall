#!/usr/bin/env python3
"""Adds Meteor's launch wrapper to the VR games in Steam, or takes it out again.

    meteor_steam_options.py status
    meteor_steam_options.py add
    meteor_steam_options.py remove

Prints JSON. Steam rewrites localconfig.vdf when it exits, so add and remove
close Steam first and reopen it afterwards. They refuse while a game runs.
The user's own options stay, and only the LaunchOptions values change: every
other byte of the file is kept. The first edit leaves a backup next to it.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).absolute().parent))
import meteor_vr_library as library

ROOT = Path(__file__).absolute().parents[1]
COMMAND = '%command%'
BACKUP_SUFFIX = '.before-meteor'
# Any earlier form of the wrapper: a venv's python, a fixed app id, a quoted path.
WRAPPER = re.compile(r"""(?:'[^']*'|\S+)[ \t]+(?:'[^']*meteor_xr\.py'|\S*meteor_xr\.py)[ \t]+steam-run"""
                     r"""[ \t]+--app-id[ \t]+\S+[ \t]+--wait[ \t]+\d+[ \t]+--[ \t]*""")
# Variables a Python started from the AppImage inherits, which Steam mustn't.
INHERITED = ('LD_LIBRARY_PATH', 'LD_PRELOAD', 'APPDIR', 'APPIMAGE', 'ARGV0', 'OWD', 'PYTHONHOME', 'PYTHONPATH')


def wrapper_line(root=ROOT):
    path = str(Path(root) / 'tools/meteor_xr.py').replace("'", "'\"'\"'")
    return f"/usr/bin/python3 '{path}' steam-run --app-id auto --wait 120 -- {COMMAND}"


def tidy(options):
    while f'{COMMAND} {COMMAND}' in options:
        options = options.replace(f'{COMMAND} {COMMAND}', COMMAND)
    options = options.strip()
    return '' if options == COMMAND else options


def has_wrapper(options):
    return bool(WRAPPER.search(options))


def without_wrapper(options):
    return tidy(WRAPPER.sub('', options))


def with_wrapper(options, root=ROOT):
    """The wrapper goes right before the game, after the user's variables."""
    options = without_wrapper(options)
    line = wrapper_line(root)
    if not options:
        return line
    if COMMAND in options:
        return options.replace(COMMAND, line, 1)
    # Without %command%, Steam passes the options to the game as arguments.
    return f'{line} {options}'


def _tokens(text):
    """Strings and braces with their places, skipping // comments."""
    for match in re.finditer(r'"((?:\\.|[^"\\])*)"|([{}])|//[^\n]*', text):
        if match[2]:
            yield match[2], match.start(), match.end()
        elif match[1] is not None:
            yield match[1], match.start(1), match.end(1)


class Vdf:
    """Finds a key's value in a text VDF by its place, to edit it in place."""

    def __init__(self, text):
        self.text = text
        self.tokens = list(_tokens(text))

    def children(self, start):
        """(key, index of the value) in the block whose first token is at start."""
        index = start
        while index < len(self.tokens):
            token = self.tokens[index][0]
            if token == '}' and self.tokens[index][2] - self.tokens[index][1] == 1 and self._brace(index):
                return
            if index + 1 >= len(self.tokens):
                return
            yield token, index + 1
            index = self._after(index + 1)

    def _brace(self, index):
        _, start, end = self.tokens[index]
        return self.text[start:end] in '{}' and (start == 0 or self.text[start - 1] != '"')

    def _is_open(self, index):
        return self.tokens[index][0] == '{' and self._brace(index)

    def _after(self, index):
        """The token after the value at index, stepping over a whole block."""
        if not self._is_open(index):
            return index + 1
        depth = 0
        while index < len(self.tokens):
            if self._brace(index):
                depth += 1 if self.tokens[index][0] == '{' else -1
                if depth == 0:
                    return index + 1
            index += 1
        raise ValueError('Unterminated VDF block')

    def find(self, start, key):
        for name, value in self.children(start):
            if name.casefold() == key.casefold():
                return value
        return None

    def apps_block(self):
        """The token index just inside the Steam apps block."""
        index = 0
        for key in ('UserLocalConfigStore', 'Software', 'Valve', 'Steam', 'apps'):
            value = self.find(index, key)
            if value is None or not self._is_open(value):
                return None
            index = value + 1
        return index


def _escape(value):
    return value.replace('\\', '\\\\').replace('"', '\\"')


def _unescape(value):
    return re.sub(r'\\(.)', r'\1', value)


def edit_options(text, app_ids, change):
    """text with change(options) applied to each app. Returns (text, changed)."""
    edits = []
    vdf = Vdf(text)
    apps = vdf.apps_block()
    if apps is None:
        raise ValueError('localconfig.vdf has no apps section')
    known = {name: value for name, value in vdf.children(apps)}
    missing = []
    for app_id in app_ids:
        value = known.get(app_id)
        if value is None or not vdf._is_open(value):
            missing.append(app_id)
            continue
        option = vdf.find(value + 1, 'LaunchOptions')
        if option is not None:
            _, start, end = vdf.tokens[option]
            current = _unescape(text[start:end])
            updated = change(current)
            if updated != current:
                edits.append((start, end, _escape(updated)))
            continue
        updated = change('')
        if updated:
            # Steam writes blocks with tabs; match the block's own indent.
            _, _, position = vdf.tokens[value]
            line_start = text.rfind('\n', 0, position) + 1
            indent = re.match(r'[ \t]*', text[line_start:]).group(0) + '\t'
            edits.append((position, position, f'\n{indent}"LaunchOptions"\t\t"{_escape(updated)}"'))
    if missing:
        insert_at = vdf.tokens[apps - 1][2]
        line_start = text.rfind('\n', 0, insert_at) + 1
        indent = re.match(r'[ \t]*', text[line_start:]).group(0) + '\t'
        for app_id in missing:
            updated = change('')
            if updated:
                edits.append((insert_at, insert_at, f'\n{indent}"{app_id}"\n{indent}{{\n{indent}\t"LaunchOptions"\t\t"{_escape(updated)}"\n{indent}}}'))
    for start, end, replacement in sorted(edits, reverse=True):
        text = text[:start] + replacement + text[end:]
    return text, len(edits)


def write_config(path, text):
    """Atomic, keeping the file's mode. The first edit leaves a backup."""
    path = Path(path)
    # The parser only runs on what it wrote if it can read it back.
    library.vdf(text)
    backup = path.with_name(path.name + BACKUP_SUFFIX)
    if not backup.exists():
        shutil.copy2(path, backup)
    temporary = path.with_name(path.name + '.meteor-tmp')
    temporary.write_text(text, errors='surrogateescape')
    os.chmod(temporary, path.stat().st_mode & 0o777)
    os.replace(temporary, path)


def read_config(path):
    return Path(path).read_text(errors='surrogateescape')


def games():
    """Steam's own VR games; a non-Steam shortcut has no app id the wrapper can use."""
    found = []
    for app in library.discover():
        app_id = app['key'].split(':', 1)[1]
        if int(app_id) < 1 << 31:
            found.append({'id': app_id, 'name': app['name'], 'ready': bool(app['ready'])})
    return found


def _processes():
    for entry in Path('/proc').iterdir():
        if entry.name.isdigit():
            try:
                yield int(entry.name), (entry / 'comm').read_text().strip(), (entry / 'cmdline').read_bytes()
            except OSError:
                continue


def steam_pid():
    for pid, comm, _ in _processes():
        if comm == 'steam':
            return pid
    return None


def game_running():
    return any(comm == 'reaper' and b'SteamLaunch' in cmdline for _, comm, cmdline in _processes())


def _steam_command():
    return shutil.which('steam') or (Path.home() / '.local/share/Steam/steam.sh').is_file() and str(Path.home() / '.local/share/Steam/steam.sh')


def _clean_environment():
    return {k: v for k, v in os.environ.items() if k not in INHERITED}


def close_steam(pid, timeout=45):
    command = _steam_command()
    if not command:
        raise RuntimeError('Close Steam, then try again')
    subprocess.run([command, '-shutdown'], env=_clean_environment(), stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout, check=False)
    deadline = time.monotonic() + timeout
    while Path(f'/proc/{pid}').exists():
        if time.monotonic() >= deadline:
            raise RuntimeError('Steam did not close. Close it, then try again')
        time.sleep(.25)
    # Steam writes its config on the way out; wait for the rest of it to go.
    while steam_pid() is not None and time.monotonic() < deadline:
        time.sleep(.25)
    if steam_pid() is not None:
        raise RuntimeError('Steam did not close. Close it, then try again')


def open_steam():
    command = _steam_command()
    if command:
        subprocess.Popen([command, '-silent'], env=_clean_environment(), stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def apply(change, app_ids):
    changed = 0
    for steam in library.steam_roots():
        for config in sorted((steam / 'userdata').glob('*/config/localconfig.vdf')):
            text, count = edit_options(read_config(config), app_ids, change)
            if count:
                write_config(config, text)
                changed += count
    return changed


def status():
    found = games()
    return {'total': len(found), 'ready': sum(game['ready'] for game in found), 'games': found,
            'steam_running': steam_pid() is not None, 'game_running': game_running()}


def run(action):
    found = games()
    if not found:
        return {'error': 'Steam lists no VR games', **status()}
    if game_running():
        return {'error': 'Close the game that is running, then try again', **status()}
    change = (lambda options: with_wrapper(options)) if action == 'add' else without_wrapper
    pid = steam_pid()
    if pid is not None:
        close_steam(pid)
    try:
        changed = apply(change, [game['id'] for game in found])
    finally:
        if pid is not None:
            open_steam()
    return {'changed': changed, **status()}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1 or argv[0] not in ('status', 'add', 'remove'):
        print('usage: meteor_steam_options.py status|add|remove', file=sys.stderr)
        return 2
    try:
        result = status() if argv[0] == 'status' else run(argv[0])
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        result = {'error': str(error)}
    print(json.dumps(result))
    return 1 if result.get('error') else 0


if __name__ == '__main__':
    sys.exit(main())
