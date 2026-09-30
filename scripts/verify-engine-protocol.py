#!/usr/bin/env python3
"""Local-only yt-dlp/FFmpeg contract check; no browser cookies or public URLs."""
import functools
import http.server
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
ENGINE = os.environ.get('DROPLET_TEST_ENGINE', '/opt/homebrew/bin/yt-dlp')
FFMPEG = os.environ.get('DROPLET_TEST_FFMPEG', '/opt/homebrew/bin/ffmpeg')
FFPROBE = os.environ.get('DROPLET_TEST_FFPROBE', '/opt/homebrew/bin/ffprobe')
source = (ROOT / 'Sources/DropletKit/Downloads/DownloadOutputProtocol.swift').read_text()
templates = dict(re.findall(r'let (download|postprocess|result) = #"(.*?)"#', source))
assert len(templates) == 3, 'Production template extraction failed'
marker = 'DROPLET_FIXTURE:'
policy_source = (ROOT / 'Sources/DropletKit/Downloads/DownloadFormatPolicy.swift').read_text()
selector = re.search(r'static let selector = "(.*?)"', policy_source).group(1)

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

def run(command):
    result = subprocess.run(command, capture_output=True, timeout=45)
    if result.returncode:
        raise RuntimeError(result.stderr.decode('utf-8', errors='replace')[-4000:])
    return result

with tempfile.TemporaryDirectory(prefix='droplet-protocol-') as directory:
    root = Path(directory)
    run([FFMPEG, '-v', 'error', '-f', 'lavfi', '-i', 'color=c=blue:s=160x90:r=12', '-t', '1', '-an', '-c:v', 'libx264', str(root/'video.mp4')])
    run([FFMPEG, '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '1', '-vn', '-c:a', 'aac', str(root/'audio.m4a')])
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=directory))
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    base = f'http://127.0.0.1:{server.server_port}'
    title = 'Blåbær 🍓 "quoted"\nsecond line'
    info = {'id':'local-fixture', 'title':title, 'extractor':'generic', 'webpage_url':base+'/fixture', 'formats':[
        {'format_id':'v', 'url':base+'/video.mp4', 'ext':'mp4', 'vcodec':'h264', 'acodec':'none'},
        {'format_id':'a', 'url':base+'/audio.m4a', 'ext':'m4a', 'vcodec':'none', 'acodec':'aac'}]}
    metadata = root/'info.json'
    metadata.write_text(json.dumps(info))
    args = [ENGINE, '--ignore-config', '--no-plugin-dirs', '--no-cache-dir', '--no-cookies-from-browser', '--no-simulate', '--progress', '--newline', '--no-colors', '--output-na-placeholder', 'null', '--ffmpeg-location', str(Path(FFMPEG).parent), '--load-info-json', str(metadata), '-f', selector, '--merge-output-format', 'mp4', '-o', str(root/'result.%(ext)s')]
    for name in ('download', 'postprocess'):
        args += ['--progress-template', name+':'+marker+templates[name]]
    args += ['--print', 'after_move:'+marker+templates['result']]
    try:
        result = run(args)
    finally:
        server.shutdown()
        server.server_close()
        worker.join()
    lines = (result.stdout + result.stderr).decode('utf-8').splitlines()
    events = [json.loads(line[len(marker):]) for line in lines if line.startswith(marker)]
    assert events, 'No structured records'
    transfers = [event for event in events if event['event'] == 'download']
    assert any(e['acodec'] == 'none' for e in transfers), 'No video progress'
    assert any(e['vcodec'] == 'none' for e in transfers), 'No audio progress'
    assert any(e.get('processor') == 'Merger' for e in events), 'No merge event'
    final = [e for e in events if e['event'] == 'result']
    assert len(final) == 1 and final[0]['title'] == title, 'Final title escaping failed'
    assert 'aac' in final[0]['audio_codecs'], 'Source audio provenance missing'
    assert final[0]['id'] == 'local-fixture', 'Media identity missing'
    file = Path(final[0]['path'])
    assert file.is_file() and file.stat().st_size > 0, 'Final file absent'
    streams = json.loads(run([FFPROBE, '-v', 'error', '-show_streams', '-of', 'json', str(file)]).stdout)['streams']
    assert {'audio', 'video'} <= {s['codec_type'] for s in streams}, 'Merged streams missing'
    print(f'PASS: {len(events)} real structured events; video, audio, merger, final path; Unicode/quotes/newline preserved; final audio+video streams verified')
