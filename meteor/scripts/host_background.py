"""Temporary desktop background. Invoked by Meteor, never by network input directly.
Journal is written before mutation; restore only values that still equal ours.
"""
import json
import os
import pathlib
import subprocess
import sys
import fcntl

ROOT = pathlib.Path(os.environ.get('XDG_STATE_HOME', str(pathlib.Path.home() / '.local/state'))) / 'nightfall-meteor'
ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
lock = open(ROOT / 'background.lock', 'w')
fcntl.flock(lock, fcntl.LOCK_EX)
JOURNAL = ROOT / 'background.json'


def run(*args):
    return subprocess.check_output(args, text=True, timeout=3).strip()


def plasma(script):
    return run('gdbus', 'call', '--session', '--dest', 'org.kde.plasmashell',
               '--object-path', '/PlasmaShell', '--method', 'org.kde.PlasmaShell.evaluateScript', script)


def snapshot(backend):
    if backend == 'gnome':
        return {k: run('gsettings', 'get', 'org.gnome.desktop.background', k) for k in
                ('picture-uri', 'picture-uri-dark', 'picture-options', 'primary-color', 'secondary-color', 'color-shading-type')}
    # Emit JSON as a quoted D-Bus string; parse with literal_eval, not eval.
    import ast
    response = plasma('print(JSON.stringify(desktops().map(function(d){d.currentConfigGroup=["Wallpaper",d.wallpaperPlugin,"General"];return {id:d.id,plugin:d.wallpaperPlugin,image:d.readConfig("Image",""),color:d.readConfig("Color","")};})))')
    return json.loads(ast.literal_eval(response)[0])


def apply(backend, state):
    if backend == 'gnome':
        for key, value in state.items():
            run('gsettings', 'set', 'org.gnome.desktop.background', key, value)
    else:
        plasma('var saved=' + json.dumps(state) + ';saved.forEach(function(s){desktops().forEach(function(d){if(d.id==s.id){d.currentConfigGroup=["Wallpaper",s.plugin,"General"];d.writeConfig("Image",s.image);d.writeConfig("Color",s.color);d.wallpaperPlugin=s.plugin;}});});')


def restore(owner=None):
    if not JOURNAL.exists():
        return
    data = json.loads(JOURNAL.read_text())
    if owner is not None and data.get('owner') != owner:
        return
    current = snapshot(data['backend'])
    if data['backend'] == 'gnome':
        # Restore independently so a user changing one setting is respected.
        old = {k: v for k, v in data['before'].items() if current.get(k) == data['after'].get(k)}
    else:
        old = [s for s in data['before'] if next((x for x in current if x['id'] == s['id']), None)
               == next((x for x in data['after'] if x['id'] == s['id']), None)]
    apply(data['backend'], old)
    JOURNAL.unlink()


def main():
    color = sys.argv[1]
    owner = (sys.argv[2] or None) if len(sys.argv) > 2 else None
    restore(owner if color == 'off' else None)
    if color == 'off':
        return
    colors = {'green': '#00ff00', 'blue': '#0000ff', 'magenta': '#ff00ff'}
    color = colors[color]
    desktop = os.environ.get('XDG_CURRENT_DESKTOP', '').lower()
    backend = 'kde' if 'kde' in desktop else 'gnome' if 'gnome' in desktop else None
    if backend is None:
        raise RuntimeError('Host background supports KDE Plasma and GNOME on Linux')
    before = snapshot(backend)
    if not before:
        raise RuntimeError('No desktop wallpapers available')
    if backend == 'gnome':
        after = dict(before, **{'picture-uri': "''", 'picture-uri-dark': "''", 'picture-options': "'none'",
                                'primary-color': repr(color), 'secondary-color': repr(color), 'color-shading-type': "'solid'"})
    else:
        rgb = ','.join(str(int(color[i:i+2], 16)) for i in (1, 3, 5))
        after = [dict(s, plugin='org.kde.color', color=rgb, image='') for s in before]
    # Atomic journal before changes, including failed/partial changes.
    temp = JOURNAL.with_suffix('.tmp')
    temp.write_text(json.dumps({'owner': owner, 'backend': backend, 'before': before, 'after': after}))
    os.chmod(temp, 0o600)
    temp.replace(JOURNAL)
    try:
        apply(backend, after)
        actual = snapshot(backend)
        # Use actual representation (Plasma may normalize QVariant colours).
        if backend == 'kde':
            if any(s['plugin'] != 'org.kde.color' for s in actual):
                raise RuntimeError('Plasma did not apply solid-colour wallpaper')
            data = json.loads(JOURNAL.read_text())
            data['after'] = actual
            temp.write_text(json.dumps(data)); os.chmod(temp, 0o600); temp.replace(JOURNAL)
    except Exception:
        restore()
        raise


if __name__ == '__main__':
    main()
