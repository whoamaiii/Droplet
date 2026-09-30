#!/usr/bin/env python3
"""Serve self-generated MP4 on loopback for native UI QA, with isolated output."""
import argparse
import time
import functools
import http.server
import json
from pathlib import Path
import subprocess
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--delay', type=float, default=0)
parser.add_argument('--chunk-delay', type=float, default=0)
settings_args = parser.parse_args()
assert 0 <= settings_args.delay <= 10
assert 0 <= settings_args.chunk_delay <= 2

root = Path.home()/'Library/Developer/Droplet/UIQA'/str(uuid.uuid4())
source = root/'source'
output = root/'Downloads'
source.mkdir(parents=True)
output.mkdir()
subprocess.run(['/opt/homebrew/bin/ffmpeg','-v','error','-f','lavfi','-i','color=c=blue:s=160x90:r=12','-f','lavfi','-i','sine=frequency=440','-t','1','-c:v','libx264','-c:a','aac',str(source/'Droplet-QA.mp4')],check=True,timeout=20)
class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        time.sleep(settings_args.delay)
        super().do_GET()
    def copyfile(self, source_file, output_file):
        if not settings_args.chunk_delay:
            return super().copyfile(source_file, output_file)
        try:
            while data := source_file.read(512):
                output_file.write(data)
                output_file.flush()
                time.sleep(settings_args.chunk_delay)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Cancellation is an expected QA action.
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(QuietHandler,directory=str(source)))
settings = {'root':str(root),'url':f'http://127.0.0.1:{server.server_port}/Droplet-QA.mp4','downloads':str(output)}
(root/'fixture.json').write_text(json.dumps(settings))
print(json.dumps(settings),flush=True)
try: server.serve_forever()
except KeyboardInterrupt: pass
finally: server.server_close()
