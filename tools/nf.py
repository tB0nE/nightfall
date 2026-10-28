#!/usr/bin/env python3
"""Drive a running Nightfall dev build through its control port (src/dev_bridge.gd).

The app listens on 127.0.0.1:47950 in dev and debug builds, or with
--nf-dev-bridge. For the headset, pass --adb to forward the port first.

  nf.py --adb ping
  nf.py ui                      # visible controls, grouped by panel
  nf.py ui --viewport ui --json
  nf.py press "Settings"        # by text (any case) or node path
  nf.py select "Background" Cinema
  nf.py text "IPInput" 10.0.0.13 --submit
  nf.py state
  nf.py eval "screens.size()"   # any expression, with main.gd as self
  nf.py wait "is_streaming" --timeout 20
  nf.py pose head --pos 0 1.6 0 --rot 0 90 0
  nf.py shot ui ui.png
  nf.py log -n 50

Exits 1 when the app answers ok=false, 2 when it can't be reached.
See docs/testing.md.
"""

import argparse
import base64
import json
import socket
import subprocess
import sys

PORT = 47950


def forward(port, serial=None):
    command = ['adb'] + (['-s', serial] if serial else []) + ['forward', f'tcp:{port}', f'tcp:{port}']
    subprocess.run(command, check=True, capture_output=True)


def request(payload, port=PORT, timeout=30.0):
    """Sends one request and returns the reply as a dict."""
    with socket.create_connection(('127.0.0.1', port), timeout=timeout) as connection:
        connection.sendall((json.dumps(payload) + '\n').encode())
        data = b''
        while not data.endswith(b'\n'):
            chunk = connection.recv(1 << 20)
            if not chunk:
                break
            data += chunk
    if not data:
        raise ConnectionError('no reply (is this a dev build with the bridge on?)')
    return json.loads(data)


def print_ui(reply):
    for viewport in reply['viewports']:
        panel = viewport.get('panel')
        where = ''
        if panel:
            where = f" panel {'shown' if panel['visible'] else 'hidden'}, {panel['distance']} m away"
        print(f"[{viewport['name']}] {viewport['size'][0]:.0f}x{viewport['size'][1]:.0f}{where}")
        for control in viewport['controls']:
            flags = [flag for flag in ('disabled',) if control.get(flag)]
            if control.get('on_screen') is False:
                flags.append('scrolled away')
            if 'pressed' in control:
                flags.append('on' if control['pressed'] else 'off')
            if 'items' in control and 0 <= control.get('selected', -1) < len(control['items']):
                flags.append(f"= {control['items'][control['selected']]}")
            if 'value' in control:
                flags.append(f"= {control['value']:g}")
            text = f" {json.dumps(control['text'], ensure_ascii=False)}" if 'text' in control else ''
            extra = f" ({', '.join(flags)})" if flags else ''
            print(f"  {control['type']}{text}{extra}  {control['path'].split('/')[-1]}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port', type=int, default=PORT)
    parser.add_argument('--adb', action='store_true', help='adb forward the port to the headset first')
    parser.add_argument('--serial', help='adb device serial')
    parser.add_argument('--json', action='store_true', help='print the raw reply')
    commands = parser.add_subparsers(dest='cmd', required=True)
    commands.add_parser('ping')
    ui = commands.add_parser('ui')
    ui.add_argument('--viewport', default='')
    ui.add_argument('--no-labels', action='store_true')
    ui.add_argument('--hidden', action='store_true', help='include hidden panels')
    press = commands.add_parser('press')
    press.add_argument('target')
    select = commands.add_parser('select')
    select.add_argument('target')
    select.add_argument('option')
    text = commands.add_parser('text')
    text.add_argument('target')
    text.add_argument('value')
    text.add_argument('--submit', action='store_true')
    commands.add_parser('state')
    evaluate = commands.add_parser('eval')
    evaluate.add_argument('expr')
    wait = commands.add_parser('wait')
    wait.add_argument('expr')
    wait.add_argument('--timeout', type=float, default=10.0)
    pose = commands.add_parser('pose')
    pose.add_argument('node', choices=['head', 'left', 'right', 'origin'])
    pose.add_argument('--pos', type=float, nargs=3)
    pose.add_argument('--rot', type=float, nargs=3, help='degrees')
    shot = commands.add_parser('shot')
    shot.add_argument('viewport')
    shot.add_argument('out')
    shot.add_argument('--max-width', type=int, default=1280)
    log = commands.add_parser('log')
    log.add_argument('-n', type=int, default=100)
    args = parser.parse_args(argv)

    payload = {'cmd': args.cmd}
    if args.cmd == 'ui':
        payload.update(viewport=args.viewport, labels=not args.no_labels, hidden=args.hidden)
    elif args.cmd == 'press':
        payload['target'] = args.target
    elif args.cmd == 'select':
        payload.update(target=args.target, option=args.option)
    elif args.cmd == 'text':
        payload.update(cmd='set_text', target=args.target, text=args.value, submit=args.submit)
    elif args.cmd in ('eval', 'wait'):
        payload['expr'] = args.expr
        if args.cmd == 'wait':
            payload['timeout'] = args.timeout
    elif args.cmd == 'pose':
        payload['node'] = args.node
        if args.pos:
            payload['position'] = args.pos
        if args.rot:
            payload['rotation_deg'] = args.rot
    elif args.cmd == 'shot':
        payload.update(cmd='screenshot', viewport=args.viewport, max_width=args.max_width)
    elif args.cmd == 'log':
        payload['lines'] = args.n

    try:
        if args.adb:
            forward(args.port, args.serial)
        timeout = 30.0 + (args.timeout if args.cmd == 'wait' else 0.0)
        reply = request(payload, args.port, timeout)
    except (OSError, ConnectionError, subprocess.CalledProcessError) as error:
        print(f'nf: cannot reach the app on port {args.port}: {error}', file=sys.stderr)
        return 2

    if not reply.get('ok'):
        print(json.dumps(reply, indent=2, ensure_ascii=False), file=sys.stderr)
        return 1
    if args.cmd == 'shot':
        with open(args.out, 'wb') as file:
            file.write(base64.b64decode(reply['png_base64']))
        print(f"{args.out}: {reply['width']}x{reply['height']}")
    elif args.cmd == 'log' and not args.json:
        print('\n'.join(reply['lines']))
    elif args.cmd == 'ui' and not args.json:
        print_ui(reply)
    else:
        reply.pop('ok', None)
        print(json.dumps(reply, indent=2, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
