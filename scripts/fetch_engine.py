#!/usr/bin/env python3
"""Fetch the download engine that ships inside Droplet.app/Contents/Helpers.

Every file is pinned by SHA-256 in engine.lock.json, which is committed and
reviewed like code. A release never downloads an unpinned binary.

  # Assemble helpers for a release (verifies every hash):
  python3 scripts/fetch_engine.py --output build/Helpers --notices build/ThirdPartyNotices

  # Pin newer versions (downloads, hashes and rewrites engine.lock.json):
  python3 scripts/fetch_engine.py --pin --yt-dlp latest --deno latest

Review the lock-file diff before committing it.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
# Overridable for the distribution tests only.
LOCK = Path(os.environ.get("DROPLET_ENGINE_LOCK", ROOT / "engine.lock.json"))
CACHE = Path(os.environ.get("DROPLET_ENGINE_CACHE", ROOT / ".build" / "engine-cache"))
ARCHES = ("arm64", "x86_64")
USER_AGENT = "Droplet-release-tooling"


class EngineError(Exception):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url, destination):
    if not (url.startswith("https://") or url.startswith("file://")):
        raise EngineError(f"refusing non-HTTPS URL: {url}")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    partial = destination.with_name(destination.name + ".partial")
    try:
        with urllib.request.urlopen(request, timeout=120) as response, open(partial, "wb") as out:
            final = response.geturl()
            if not (final.startswith("https://") or final.startswith("file://")):
                raise EngineError(f"{url} redirected to non-HTTPS {final}")
            shutil.copyfileobj(response, out)
    except OSError as error:
        partial.unlink(missing_ok=True)
        raise EngineError(f"download failed for {url}: {error}") from error
    partial.replace(destination)
    return final


def fetch_pinned(entry, label):
    """Downloads (or reuses from cache) a file and verifies its pinned hash."""
    url, expected = entry.get("url", ""), entry.get("sha256", "").lower()
    if not url or len(expected) != 64:
        raise EngineError(f"{label} is not pinned in {LOCK.name}; run --pin first")
    CACHE.mkdir(parents=True, exist_ok=True)
    cached = CACHE / expected
    if not cached.exists() or sha256(cached) != expected:
        download(url, cached)
    actual = sha256(cached)
    if actual != expected:
        cached.unlink(missing_ok=True)
        raise EngineError(f"{label}: SHA-256 mismatch (expected {expected}, got {actual}) for {url}")
    return cached


def extract_member(archive, name, destination):
    """Copies the single executable called `name` out of a zip, or the file itself."""
    if not zipfile.is_zipfile(archive):
        shutil.copyfile(archive, destination)
    else:
        with zipfile.ZipFile(archive) as bundle:
            matches = [m for m in bundle.infolist() if not m.is_dir() and Path(m.filename).name == name]
            if len(matches) != 1:
                raise EngineError(f"{archive.name}: expected exactly one '{name}', found {len(matches)}")
            with bundle.open(matches[0]) as source, open(destination, "wb") as out:
                shutil.copyfileobj(source, out)
    destination.chmod(0o755)


def combine(parts, destination):
    """Universal binary from per-architecture files (lipo), or a single copy."""
    if len(parts) == 1:
        shutil.copyfile(parts[0], destination)
    else:
        subprocess.run(["lipo", "-create", *map(str, parts), "-output", str(destination)], check=True)
    destination.chmod(0o755)


def assemble(lock, output, notices, arches):
    output.mkdir(parents=True, exist_ok=True)
    notices.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as raw:
        work = Path(raw)
        ytdlp = lock["yt-dlp"]
        # yt-dlp_macos is already a universal binary.
        shutil.copyfile(fetch_pinned(ytdlp, "yt-dlp"), output / "yt-dlp")
        (output / "yt-dlp").chmod(0o755)

        for tool in ("ffmpeg", "ffprobe"):
            parts = []
            for arch in arches:
                part = work / f"{tool}-{arch}"
                extract_member(fetch_pinned(lock["ffmpeg"][arch][tool], f"{tool} {arch}"), tool, part)
                parts.append(part)
            combine(parts, output / tool)

        deno = lock.get("deno")
        if deno and deno.get("enabled", True):
            parts = []
            for arch in arches:
                part = work / f"deno-{arch}"
                extract_member(fetch_pinned(deno[arch], f"deno {arch}"), "deno", part)
                parts.append(part)
            combine(parts, output / "deno")

    for component in ("yt-dlp", "ffmpeg", "deno"):
        entry = lock.get(component) or {}
        if component == "deno" and not entry.get("enabled", True):
            continue
        license_entry = entry.get("license")
        if not license_entry:
            raise EngineError(f"{component}: no pinned license text in {LOCK.name}")
        shutil.copyfile(fetch_pinned(license_entry, f"{component} license"), notices / f"{component}-LICENSE.txt")
        (notices / f"{component}-LICENSE.txt").chmod(0o644)
    sources = {name: (lock.get(name) or {}).get("source", "") for name in ("yt-dlp", "ffmpeg", "deno")}
    (notices / "SOURCES.txt").write_text(
        "Corresponding source for the bundled programs:\n\n"
        + "".join(f"{name} {lock.get(name, {}).get('version', '')}: {url}\n" for name, url in sources.items() if url)
        + "".join(f"{name} build configuration: {(lock.get(name) or {})['build']}\n"
                  for name in sources if (lock.get(name) or {}).get("build")))
    return ytdlp["version"]


def smoke_test(output):
    """Runs each helper once on this Mac, which proves the host slice works."""
    checks = [["yt-dlp", "--ignore-config", "--version"], ["ffmpeg", "-hide_banner", "-version"],
              ["ffprobe", "-hide_banner", "-version"]]
    if (output / "deno").exists():
        checks.append(["deno", "--version"])
    for command in checks:
        result = subprocess.run([str(output / command[0]), *command[1:]], capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            raise EngineError(f"{command[0]} failed to run: {result.stderr.strip()[:300]}")
        print(f"  {command[0]}: {result.stdout.strip().splitlines()[0][:80]}")


# ---------------------------------------------------------------- pinning

def github_latest(repo):
    request = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/latest",
                                     headers={"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)["tag_name"]


def pin_url(url, resolve_redirect=False):
    """Hashes `url` and keeps the file in the cache for the next release.

    The original URL is recorded: GitHub release downloads redirect to signed
    links that expire within hours. Only "latest"-style URLs that redirect to
    a permanent versioned file (FFmpeg) record the resolved address."""
    with tempfile.TemporaryDirectory() as raw:
        target = Path(raw) / "file"
        final = download(url, target)
        digest = sha256(target)
        CACHE.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(target, CACHE / digest)
        return {"url": final if resolve_redirect else url, "sha256": digest}


def pin(lock, args):
    if args.yt_dlp:
        tag = github_latest("yt-dlp/yt-dlp") if args.yt_dlp == "latest" else args.yt_dlp
        base = f"https://github.com/yt-dlp/yt-dlp/releases/download/{tag}"
        entry = pin_url(f"{base}/yt-dlp_macos")
        # Cross-check against the hash list the yt-dlp project publishes.
        with tempfile.TemporaryDirectory() as raw:
            sums = Path(raw) / "SHA2-256SUMS"
            download(f"{base}/SHA2-256SUMS", sums)
            published = {line.split()[1].lstrip("*"): line.split()[0] for line in sums.read_text().splitlines() if line.strip()}
        if published.get("yt-dlp_macos") != entry["sha256"]:
            raise EngineError("yt-dlp_macos does not match the project's published SHA2-256SUMS")
        raw = f"https://raw.githubusercontent.com/yt-dlp/yt-dlp/{tag}"
        try:  # The standalone build bundles third-party code; prefer its full notice.
            license_entry = pin_url(f"{raw}/THIRD_PARTY_LICENSES.txt")
        except EngineError:
            license_entry = pin_url(f"{raw}/LICENSE")
        lock["yt-dlp"] = dict(lock.get("yt-dlp", {}), version=tag, **entry, license=license_entry,
                              source=f"https://github.com/yt-dlp/yt-dlp/tree/{tag}")
        print(f"yt-dlp pinned at {tag}")
    if args.deno:
        tag = github_latest("denoland/deno") if args.deno == "latest" else ("v" + args.deno.lstrip("v"))
        base = f"https://github.com/denoland/deno/releases/download/{tag}"
        lock["deno"] = dict(lock.get("deno", {}), version=tag.lstrip("v"), enabled=True,
                            arm64=pin_url(f"{base}/deno-aarch64-apple-darwin.zip"),
                            x86_64=pin_url(f"{base}/deno-x86_64-apple-darwin.zip"),
                            license=pin_url(f"https://raw.githubusercontent.com/denoland/deno/{tag}/LICENSE.md"),
                            source=f"https://github.com/denoland/deno/tree/{tag}")
        print(f"deno pinned at {tag}")
    if args.ffmpeg:
        ffmpeg = lock.setdefault("ffmpeg", {})
        sources = ffmpeg.get("download", {})
        for arch in ARCHES:
            ffmpeg[arch] = {tool: pin_url(sources[arch][tool], resolve_redirect=True) for tool in ("ffmpeg", "ffprobe")}
        if ffmpeg.get("license_url"):
            ffmpeg["license"] = pin_url(ffmpeg["license_url"])
        # Versioned build addresses end in ".../<build>_<version>/<tool>.zip";
        # record that release so SOURCES.txt names the exact FFmpeg source.
        found = [re.search(r"_(\d+(?:\.\d+)+)/[^/]+$", ffmpeg[arch][tool]["url"])
                 for arch in ARCHES for tool in ("ffmpeg", "ffprobe")]
        versions = {match.group(1) for match in found if match}
        if all(found) and len(versions) == 1:
            ffmpeg["version"] = versions.pop()
            ffmpeg["source"] = f"https://ffmpeg.org/releases/ffmpeg-{ffmpeg['version']}.tar.xz"
            print(f"ffmpeg pinned at {ffmpeg['version']}")
        else:
            print("ffmpeg pinned. Its version is not in the download addresses: set ffmpeg.version and "
                  "ffmpeg.source in engine.lock.json by hand (see docs/release/RELEASE.md).")
    LOCK.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
    print(f"Updated {LOCK}. Review the diff before committing.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, help="Helpers directory to fill")
    parser.add_argument("--notices", type=Path, help="Directory for third-party license texts")
    parser.add_argument("--arch", choices=("universal", *ARCHES), default="universal")
    parser.add_argument("--no-smoke-test", action="store_true", help="Skip running the helpers (cross-arch builds)")
    parser.add_argument("--print-version", action="store_true", help="Print the pinned yt-dlp version and exit")
    parser.add_argument("--pin", action="store_true", help="Download, hash and record new versions")
    parser.add_argument("--yt-dlp", help="with --pin: release tag or 'latest'")
    parser.add_argument("--deno", help="with --pin: version or 'latest'")
    parser.add_argument("--ffmpeg", action="store_true", help="with --pin: re-pin FFmpeg from ffmpeg.download URLs")
    args = parser.parse_args(argv)
    lock = json.loads(LOCK.read_text())
    try:
        if args.print_version:
            print(lock["yt-dlp"]["version"])
            return 0
        if args.pin:
            pin(lock, args)
            return 0
        if not args.output or not args.notices:
            parser.error("--output and --notices are required")
        arches = ARCHES if args.arch == "universal" else (args.arch,)
        version = assemble(lock, args.output, args.notices, arches)
        if not args.no_smoke_test:
            smoke_test(args.output)
        print(f"Engine ready in {args.output} (yt-dlp {version})")
        return 0
    except (EngineError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"fetch_engine: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
