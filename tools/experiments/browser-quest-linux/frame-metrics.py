#!/usr/bin/python3
"""Lab-only loopback counters; does not collect page URLs or media content."""
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

samples = {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        if not 0 < size <= 4096:
            self.send_error(400)
            return
        try:
            data = json.loads(self.rfile.read(size))
            source = data['source']
            if source not in ('video', 'viewer', 'input'):
                raise ValueError('source')
            # Only retain numeric/bool counters, never arbitrary page data.
            samples[source] = {'received_monotonic': time.monotonic(), **{
                k: v for k, v in data.items()
                if k in ('frames', 'dropped', 'callbacks', 'media_time', 'paused',
                         'width', 'height', 'elapsed', 'connected', 'clicks', 'downs', 'ups',
                         'moves_pressed', 'key_downs', 'key_ups', 'insert_count', 'input_length',
                         'ctrl_held', 'shift_held', 'touch_starts', 'touch_moves', 'touch_ends',
                         'touch_cancels', 'scroll_y', 'viewport_width', 'viewport_height',
                         'profile_actions', 'scrollbar_width', 'media_paused')
                and isinstance(v, (int, float, bool))}}
        except (ValueError, KeyError, TypeError):
            self.send_error(400)
            return
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        payload = json.dumps(samples).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == '__main__':
    HTTPServer(('127.0.0.1', 6083), Handler).serve_forever()
