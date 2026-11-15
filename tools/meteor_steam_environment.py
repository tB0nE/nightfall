#!/usr/bin/env python3
"""Native Steam integration without per-game launch-option changes.

Install/remove affect only per-user Steam desktop/autostart overrides. The small
standalone launcher merges its sandbox environment at execution time and leaves
explicit game options, the default runtime and unrelated environment untouched.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import shutil
import sys
import uuid

IPC = 'nightfall-meteor'


def append_path(value, path):
    path = str(path)
    if not path.startswith('/') or any(char in path for char in (':','\\','\n','\r','\0')):
        raise ValueError('Steam sandbox paths must be absolute without colon, backslash or line breaks')
    entries = [entry for entry in value.split(':') if entry]
    if path not in entries:
        entries.append(path)
    return ':'.join(entries)


def environment(root, runtime, inherited):
    root, runtime = Path(root), Path(runtime)
    result = dict(inherited)
    result['PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES'] = '1'
    result['PRESSURE_VESSEL_FILESYSTEMS_RO'] = append_path(result.get('PRESSURE_VESSEL_FILESYSTEMS_RO',''),root)
    result['PRESSURE_VESSEL_FILESYSTEMS_RW'] = append_path(result.get('PRESSURE_VESSEL_FILESYSTEMS_RW',''),runtime/IPC)
    return result


def desktop_quote(value):
    # Desktop Entry Exec has its own quoting/field-code rules, not shell rules.
    value = str(value)
    if any(char in value for char in '\n\r\0'):
        raise ValueError('Desktop command contains a line break')
    value = value.replace('%','%%')
    for char in ('\\','"','`','$'):
        value = value.replace(char,'\\'+char)
    # Key-file unescaping happens before Exec argument unquoting.
    return ('\"'+value+'\"').replace('\\','\\\\')


def wrap_desktop(text, helper, root):
    if any('flatpak' in line.lower() or 'com.valvesoftware.Steam' in line
           for line in text.splitlines() if line.startswith('Exec=')):
        raise ValueError('Flatpak Steam needs separate permissions; native Steam setup cannot configure it')
    if any(line.strip().lower()=='dbusactivatable=true' for line in text.splitlines()):
        raise ValueError('D-Bus activated Steam launcher requires separate integration')
    prefix = '/usr/bin/python3 '+desktop_quote(helper)+' run --root '+desktop_quote(root)+' -- '
    output = []
    count = 0
    for line in text.splitlines(keepends=True):
        if line.startswith('Exec='):
            if not line[5:].strip():
                raise ValueError('Steam desktop command is empty')
            line = 'Exec='+prefix+line[5:]
            count += 1
        output.append(line)
    if not count:
        raise ValueError('Steam desktop file contains no Exec command')
    return ''.join(output)


def directories():
    config = Path(os.environ.get('XDG_CONFIG_HOME',Path.home()/'.config'))
    data = Path(os.environ.get('XDG_DATA_HOME',Path.home()/'.local/share'))
    return config,data,data/'nightfall-meteor/steam'


def integration_lock(state):
    import stat
    state.mkdir(mode=0o700,parents=True,exist_ok=True)
    meta = state.lstat()
    if not stat.S_ISDIR(meta.st_mode) or meta.st_uid!=os.getuid() or meta.st_mode & 0o077:
        raise ValueError('Steam integration state must be private and user-owned')
    fd = os.open(state/'owner.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
    lock = os.fdopen(fd,'r+')
    try:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BaseException:
        lock.close()
        raise
    return lock


def registration_module(state):
    # Kept outside the XR installation so remove still works after runtime removal.
    spec = importlib.util.spec_from_file_location('steam_registration',state/'registration.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def running_environment_ready(root, runtime):
    wanted={b'PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES',
            b'PRESSURE_VESSEL_FILESYSTEMS_RO',b'PRESSURE_VESSEL_FILESYSTEMS_RW'}
    found=[]
    for entry in Path('/proc').iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            if entry.stat().st_uid!=os.getuid() or (entry/'comm').read_text().strip()!='steam':
                continue
            values={key.decode():value.decode(errors='replace') for item in (entry/'environ').read_bytes().split(b'\0')
                    for key,separator,value in [item.partition(b'=')] if separator and key in wanted}
            found.append(values.get('PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES')=='1' and
                         str(root) in values.get('PRESSURE_VESSEL_FILESYSTEMS_RO','').split(':') and
                         str(Path(runtime)/IPC) in values.get('PRESSURE_VESSEL_FILESYSTEMS_RW','').split(':'))
        except (OSError,ValueError):
            continue
    return all(found) if found else None


def status(state):
    entries = []
    for journal in sorted(state.glob('*.lease.json')):
        value = json.loads(journal.read_text())
        destination = Path(value['destination'])
        try:
            meta = destination.lstat()
            owned = ([meta.st_dev,meta.st_ino]==value['owned'] and
                     hashlib.sha256(destination.read_bytes()).hexdigest()==value['digest'])
        except OSError:
            owned = False
        entries.append(dict(path=str(destination),owned=owned))
    settings=state/'settings.json'
    metadata=json.loads(settings.read_text()) if settings.is_file() else {}
    complete=metadata.get('phase')=='installed' and sorted(metadata.get('entries',[]))==sorted(Path(entry['path']).name for entry in entries)
    running=(running_environment_ready(Path(metadata['root']),Path(os.environ.get('XDG_RUNTIME_DIR','/run/user/'+str(os.getuid()))))
             if metadata.get('root') else None)
    return dict(configured=complete and bool(entries) and all(entry['owned'] for entry in entries),entries=entries,
                steam_restart_required=running is False,steam_running=running is not None,
                steam_environment_ready=running is True,scope='native-steam',game_options_changed=False)


def xr_preferences(text):
    try:
        import tomllib
    except ImportError:
        # Ubuntu 22.04's Python 3.10 has no tomllib. Setup writes ordinary
        # [xr] boolean entries; accept only that narrow form, failing closed
        # for advanced layouts rather than adding a system dependency.
        if '\"\"\"' in text or "'"*3 in text:
            return {}
        section=False
        result={}
        for line in text.splitlines():
            if line.lstrip().startswith('['):
                section=bool(re.fullmatch(r'\s*\[xr\]\s*(?:#.*)?',line))
            elif section:
                match=re.fullmatch(r'\s*(enabled|automatic_launch)\s*=\s*(true|false)\s*(?:#.*)?',line)
                if match:
                    if match[1] in result:return {}
                    result[match[1]]=match[2]=='true'
        return result
    return tomllib.loads(text).get('xr',{})


def automatic_launch_ready(root):
    config,_,state=directories()
    try:
        settings=xr_preferences((config/'nightfall-meteor/meteor.toml').read_text())
        metadata=json.loads((state/'settings.json').read_text())
        if not isinstance(settings,dict):return False
        current=status(state)
        return (settings.get('enabled') is True and settings.get('automatic_launch') is True and
                Path(metadata['root']).resolve()==Path(root).resolve() and current['configured'] and not current['steam_restart_required'])
    except (OSError,ValueError,KeyError,TypeError):
        return False


def find_system_desktop():
    for base in os.environ.get('XDG_DATA_DIRS','/usr/local/share:/usr/share').split(':'):
        candidate = Path(base)/'applications/steam.desktop'
        if candidate.is_file():
            return candidate
    raise ValueError('Native Steam desktop launcher not found; Flatpak Steam is not configured by this tool')


def install(root, config, data, *, system_desktop=None):
    root,config,data = map(Path,(root,config,data))
    if not all(path.is_absolute() for path in (root,config,data)):
        raise ValueError('Steam integration paths must be absolute')
    manifest = root/'xr-runtime/manifest.json'
    if json.loads(manifest.read_text()).get('ipc_socket')!='nightfall-meteor/monado_comp_ipc':
        raise ValueError('Install the automatic XR runtime before configuring Steam')
    environment(root,Path('/run/user')/str(os.getuid()),{})  # Validate paths before changing launchers.
    state = data/'nightfall-meteor/steam'
    with integration_lock(state):
        settings = state/'settings.json'
        metadata=json.loads(settings.read_text()) if settings.is_file() else {}
        if metadata.get('phase')=='installing':
            registration=registration_module(state)
            for journal in sorted(state.glob('*.lease.json')):
                if not registration.release(journal):
                    raise RuntimeError('Interrupted Steam setup conflicts with a later launcher change; backup retained')
        current = status(state)
        if current['entries']:
            if not current['configured']:
                raise RuntimeError('Steam launcher changed externally; remove integration and review its retained backup first')
            if json.loads((state/'settings.json').read_text())['root']!=str(root):
                raise RuntimeError('Remove the previous Steam integration before selecting another runtime')
            return dict(current,changed=False)
        destination = data/'applications/steam.desktop'
        source = destination if destination.exists() else (system_desktop or find_system_desktop())
        plans = [(destination,Path(source).read_text(),'menu')]
        autostart = config/'autostart/steam.desktop'
        if autostart.exists():
            plans.append((autostart,autostart.read_text(),'autostart'))
        helper = state/'environment.py'
        contents = [(path,wrap_desktop(text,helper,root),name) for path,text,name in plans]
        # Validate every input before copying helpers or changing a launcher.
        shutil.copy2(Path(__file__),helper)
        shutil.copy2(root/'test/xr_runtime_registration.py',state/'registration.py')
        registration = registration_module(state)
        made = []
        temporary = settings.with_suffix('.tmp')
        metadata=dict(root=str(root),phase='installing',entries=[path.name for path,_,_ in contents])
        temporary.write_text(json.dumps(metadata));temporary.replace(settings)
        try:
            for path,text,name in contents:
                candidate = state/(name+'-'+uuid.uuid4().hex+'.desktop')
                candidate.write_text(text)
                journal = state/(name+'.lease.json')
                registration.acquire(path,candidate,journal)
                made.append(journal)
            metadata['phase']='installed'
            temporary.write_text(json.dumps(metadata))
            temporary.replace(settings)
        except BaseException:
            for journal in reversed(made):
                registration.release(journal)
            raise
        return dict(status(state),changed=True)


def remove(state):
    if not state.exists():
        return dict(configured=False,removed=True,conflicts=[])
    with integration_lock(state):
        journals = sorted(state.glob('*.lease.json'))
        conflicts = []
        if journals:
            registration = registration_module(state)
            for journal in journals:
                if not registration.release(journal):
                    conflicts.append(str(journal))
        # Keep the standalone helper and any conflicts: edited launchers can
        # still refer to it. It safely falls back when the XR root is removed.
        return dict(status(state),removed=not conflicts,conflicts=conflicts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('status','install','remove','run'))
    parser.add_argument('--root',type=Path)
    argv=sys.argv[1:]
    separator=argv.index('--') if '--' in argv else len(argv)
    command=argv[separator+1:]
    args = parser.parse_args(argv[:separator])
    config,data,state = directories()
    if args.action=='run':
        if not command or args.root is None:
            parser.error('run requires --root and -- <original Steam command>')
        env=dict(os.environ)
        # Removing Meteor must not prevent the original Steam launcher working.
        if (args.root/'xr-runtime/manifest.json').is_file():
            runtime=env.get('XDG_RUNTIME_DIR')
            if not runtime:
                raise ValueError('Automatic XR requires XDG_RUNTIME_DIR')
            env=environment(args.root,runtime,env)
        os.execvpe(command[0],command,env)
    if args.action=='install':
        if args.root is None:
            parser.error('install requires --root')
        result=install(args.root,config,data)
    elif args.action=='remove':
        result=remove(state)
    else:
        result=status(state)
    print(json.dumps(result))
    return 1 if result.get('conflicts') else 0


if __name__=='__main__':
    try:
        raise SystemExit(main())
    except (OSError,ValueError,RuntimeError) as error:
        print(json.dumps(dict(error=str(error))))
        raise SystemExit(1)
