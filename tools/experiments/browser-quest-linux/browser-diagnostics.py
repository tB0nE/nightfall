#!/usr/bin/python3
"""Read allowlisted browser GPU and video counters; never save URLs or media data."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import time
import urllib.parse
import urllib.request


class LocalCDP:
    def __init__(self, endpoint):
        uri = urllib.parse.urlsplit(endpoint)
        if uri.scheme != 'ws' or uri.hostname != '127.0.0.1' or uri.port != 9222:
            raise ValueError('Expected forwarded local DevTools endpoint')
        self.connection = socket.create_connection(('127.0.0.1', 9222), 3)
        self.connection.settimeout(3)
        self.stream = self.connection.makefile('rb')
        key = base64.b64encode(os.urandom(16)).decode()
        self.connection.sendall((f'GET {uri.path} HTTP/1.1\r\nHost: 127.0.0.1:9222\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n').encode())
        headers = b''
        while not headers.endswith(b'\r\n\r\n'):
            headers += self.read(1)
            if len(headers) > 16384:
                raise ValueError('Oversized handshake')
        expected = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        if not headers.startswith(b'HTTP/1.1 101 ') or expected not in headers:
            raise ValueError('DevTools handshake failed')
        self.sequence = 0
        self.media = {}

    def read(self, size):
        data = self.stream.read(size)
        if len(data) != size:
            raise EOFError('DevTools closed')
        return data

    def send(self, payload, opcode=1):
        mask = os.urandom(4)
        size = len(payload)
        length = bytes([size | 128]) if size < 126 else b'\xfe' + struct.pack('>H', size)
        self.connection.sendall(bytes([128 | opcode]) + length + mask + bytes(v ^ mask[i % 4] for i, v in enumerate(payload)))

    def receive(self):
        parts = []
        while True:
            a, b = self.read(2)
            size = b & 127
            if size == 126: size = struct.unpack('>H', self.read(2))[0]
            if size == 127: size = struct.unpack('>Q', self.read(8))[0]
            if size > 2**20 or b & 128: raise ValueError('Invalid frame')
            payload = self.read(size)
            opcode = a & 15
            if opcode == 8: raise EOFError('DevTools closed')
            if opcode == 9: self.send(payload, 10); continue
            if opcode == 10: continue
            parts.append(payload)
            if sum(map(len, parts)) > 2**20: raise ValueError('Oversized response')
            if a & 128: return json.loads(b''.join(parts))

    def call(self, method, params=None):
        self.sequence += 1
        self.send(json.dumps({'id': self.sequence, 'method': method, 'params': params or {}}).encode())
        until = time.monotonic() + 5
        while time.monotonic() < until:
            message = self.receive()
            if message.get('method') == 'Media.playerPropertiesChanged':
                for prop in message.get('params', {}).get('properties', []):
                    name = prop.get('name', '')
                    if name in ('kVideoDecoderName', 'kIsPlatformVideoDecoder', 'kResolution', 'kVideoTracks', 'kFramerate', 'kAudioDecoderName', 'kIsPlatformAudioDecoder'):
                        value = prop.get('value')
                        # Track objects may contain arbitrary metadata; don't persist them.
                        if name != 'kVideoTracks' and isinstance(value, (str, bool, int, float)):
                            self.media[name] = value
            if message.get('id') == self.sequence:
                if 'error' in message: raise RuntimeError('Command failed: ' + method)
                return message['result']
        raise TimeoutError('DevTools response timeout')

    def close(self):
        self.stream.close(); self.connection.close()


VIDEO_COUNTERS = '''Array.from(document.querySelectorAll('video')).map(v=>{const q=v.getVideoPlaybackQuality();let buffer=0;for(let i=0;i<v.buffered.length;i++)if(v.buffered.start(i)<=v.currentTime&&v.buffered.end(i)>=v.currentTime)buffer=v.buffered.end(i)-v.currentTime;return {width:v.videoWidth,height:v.videoHeight,paused:v.paused,ready_state:v.readyState,network_state:v.networkState,current_time:v.currentTime,buffer_seconds:buffer,total_frames:q.totalVideoFrames,dropped_frames:q.droppedVideoFrames}})'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=int, default=20)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 120: parser.error('Use 1–120 seconds')
    from test_guard import HeadsetTestGuard
    with HeadsetTestGuard(min(150, int(args.seconds) + 20)):
        collect(args)


def collect(args):
    root = Path(__file__).resolve().parents[3]
    output = root / '.build-cache/browser-quest-linux' / ('browser-diagnostics-' + time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '.json')
    result = {'gpu': {}, 'video_samples': [], 'limits': 'HTML counters are not Netflix bitrate/throughput stats. Generic network tests cannot establish Netflix CDN throughput.'}
    browser = page = None
    try:
        info = json.load(urllib.request.urlopen('http://127.0.0.1:9222/json/version', timeout=3))
        browser = LocalCDP(info['webSocketDebuggerUrl'])
        gpu = browser.call('SystemInfo.getInfo')['gpu']
        result['gpu'] = {'features': gpu.get('featureStatus'), 'video_decode_capabilities': gpu.get('videoDecoding'),
                         'renderer': {k: v for k, v in gpu.get('auxAttributes', {}).items() if k in ('glRenderer', 'glVendor', 'glVersion')}}
        browser.close(); browser = None
        pages = json.load(urllib.request.urlopen('http://127.0.0.1:9222/json/list', timeout=3))
        # Use the app-owned target ID already retained by the helper; the caller
        # supplies it through an environment variable, never an exported report.
        owned = os.environ['NIGHTFALL_OWNED_PAGE']
        selected = next(p for p in pages if p.get('id') == owned and p.get('type') == 'page')
        page = LocalCDP(selected['webSocketDebuggerUrl'])
        page.call('Media.enable')
        started = time.monotonic()
        while True:
            sample = {'elapsed_s': time.monotonic() - started}
            try:
                sample['video'] = page.call('Runtime.evaluate', {'expression': VIDEO_COUNTERS, 'returnByValue': True})['result']['value']
            except Exception as error:
                sample['error'] = type(error).__name__
            result['video_samples'].append(sample)
            result['decoder_properties'] = page.media
            output.write_text(json.dumps(result, indent=2) + '\n')
            if time.monotonic() - started >= args.seconds: break
            time.sleep(2)
    finally:
        if browser: browser.close()
        if page: page.close()
    active = sum(any(not v.get('paused', True) for v in s.get('video', [])) for s in result['video_samples'])
    print(json.dumps({'output': str(output), 'gpu': result['gpu'], 'decoder_properties': result.get('decoder_properties'), 'active_samples': active, 'sample_count': len(result['video_samples']), 'last_sample': result['video_samples'][-1:]}, indent=2))


if __name__ == '__main__':
    main()
