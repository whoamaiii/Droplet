#!/usr/bin/env python3
"""Check current privacy switches with the installed engine parser, without IO to browsers.

Requires the Python-based Homebrew yt-dlp used by this development checkout.
Bundled engine qualification remains WHO-222.
"""
from pathlib import Path
import json
import re
import subprocess

root = Path(__file__).resolve().parents[1]
manager = (root/'Sources/DropletKit/Downloads/DownloadManager.swift').read_text()
base = manager.split('process.arguments = [', 1)[1].split('"--newline"', 1)[0]
base_flags = re.findall(r'"(--[a-z-]+)"', base)
public_flags = re.findall(r'"(--[a-z-]+)"', re.search(r'let noCookies = \[(.*?)\]', manager).group(1))
engine = Path('/opt/homebrew/bin/yt-dlp')
interpreter = engine.read_text().splitlines()[0].removeprefix('#!')
assert Path(interpreter).is_file(), 'Expected a local Python yt-dlp entrypoint'
# parse_options does not construct YoutubeDL, extract cookies or make requests.
program = '''
import json, sys, yt_dlp
base, public = json.loads(sys.argv[1])
for spec in ['safari', 'chrome:Profile 2', 'firefox:default-release', 'brave', 'edge']:
    options = yt_dlp.parse_options(base + ['--no-cookies', '--cookies-from-browser', spec]).ydl_opts
    assert options['cookiefile'] is None and options['usenetrc'] is False
    assert options['cookiesfrombrowser'][0] == spec.split(':')[0]
options = yt_dlp.parse_options(base + public).ydl_opts
assert options['cookiesfrombrowser'] is None
assert options['cookiefile'] is None and options['usenetrc'] is False
print('PASS: actual yt-dlp parser accepts production privacy switches; five explicit browser choices; default cookies/netrc disabled; no browser extraction invoked')
'''
subprocess.run([interpreter, '-I', '-c', program, json.dumps([base_flags, public_flags])], check=True, timeout=20)
