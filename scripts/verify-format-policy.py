#!/usr/bin/env python3
"""Validate the production selector against local metadata; no media downloads."""
import json
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
selector = re.search(r'static let selector = "(.*?)"', (root/'Sources/DropletKit/Downloads/DownloadFormatPolicy.swift').read_text()).group(1)
def format(id, ext, video=None, audio=None):
    value = {'format_id':id, 'ext':ext, 'url':'http://127.0.0.1:1/'+id}
    if video is not None: value['vcodec'] = video
    if audio is not None: value['acodec'] = audio
    return value
cases = [
    ('AVC/MP4A split', [format('v','mp4','avc1.4d','none'),format('a','m4a','none','mp4a.40.2')], 'v+a'),
    ('H264/AAC split', [format('v','mp4','h264','none'),format('a','m4a','none','aac')], 'v+a'),
    ('Combined', [format('combined','mp4','h264','aac')], 'combined'),
    ('Silent', [format('silent','mp4','h264','none')], 'silent'),
    ('Unknown labels deferred to native verifier', [format('unknown','mp4')], 'unknown'),
    ('Incompatible video rejected', [format('vp9','mp4','vp9','aac')], None),
    ('WebM rejected', [format('webm','webm','vp9','opus')], None),
    # Native finalizer must reject this provisional video-only choice because
    # the source audio_codecs array contains opus (manager integration test).
    ('Incompatible audio requires finalizer rejection', [format('v','mp4','h264','none'),format('a','webm','none','opus')], 'v'),
]
with tempfile.TemporaryDirectory(prefix='droplet-formats-') as temp:
    for name, formats, expected in cases:
        file = Path(temp)/'info.json'
        file.write_text(json.dumps({'id':'fixture','title':'fixture','extractor':'generic','formats':formats}))
        result = subprocess.run(['/opt/homebrew/bin/yt-dlp','--ignore-config','--no-plugin-dirs','--no-cache-dir','--no-check-formats','--simulate','--load-info-json',str(file),'-f',selector,'--print','%(format_id)s'],capture_output=True,text=True,timeout=10)
        if expected is None:
            assert result.returncode != 0, (name, result.stdout)
        else:
            assert result.returncode == 0 and result.stdout.strip() == expected, (name,result.stdout,result.stderr)
        print('PASS:', name)
