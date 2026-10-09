import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
RELEASE = ROOT / "scripts/release.sh"
FETCH = ROOT / "scripts/fetch_engine.py"

VALID = {
    "DROPLET_BUNDLE_ID": "com.dropletapp.droplet",
    "DROPLET_VERSION": "1.0.0",
    "DROPLET_BUILD": "1",
    "DEVELOPER_ID_APPLICATION": "Developer ID Application: Test Person (ABCDE12345)",
    "NOTARY_PROFILE": "droplet-notary",
    "DROPLET_LS_STORE_ID": "12345",
    "DROPLET_LS_PRODUCT_ID": "67890",
    "DROPLET_CHECKOUT_URL": "https://droplet.lemonsqueezy.com/buy/abc-123?embed=0",
    "DROPLET_WEBSITE_URL": "https://dropletapp.com",
    "DROPLET_SUPPORT": "help@dropletapp.com",
    "DROPLET_PRIVACY_URL": "https://dropletapp.com/privacy",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


class ReleaseConfiguration(unittest.TestCase):
    """Validation runs before any build, signing or network step."""

    def run_release(self, overrides=None, remove=(), engine_version="2026.09.30", extra_env=None):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            lock = root / "engine.lock.json"
            lock.write_text(json.dumps({"yt-dlp": {"version": engine_version}}))
            values = {k: v for k, v in {**VALID, **(overrides or {})}.items() if k not in remove}
            config = root / "release.env"
            config.write_text("".join(f'{k}="{v}"\n' for k, v in values.items()))
            env = dict(os.environ, VALIDATE_ONLY="1", DROPLET_ENGINE_LOCK=str(lock), **(extra_env or {}))
            return subprocess.run(["bash", str(RELEASE), str(config)], env=env, capture_output=True, text=True, timeout=60)

    def test_valid_configuration_passes(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("configuration OK", result.stdout)

    def test_development_and_placeholder_identities_are_refused(self):
        for bundle in ("local.quentinthiessen.droplet", "com.example.droplet", "com.dropletapp.droplet.preview", "droplet"):
            with self.subTest(bundle=bundle):
                self.assertNotEqual(self.run_release({"DROPLET_BUNDLE_ID": bundle}).returncode, 0)

    def test_paid_release_requires_store_and_checkout(self):
        result = self.run_release(remove=("DROPLET_LS_STORE_ID",))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no way to buy", result.stderr)
        self.assertNotEqual(self.run_release({"DROPLET_CHECKOUT_URL": "http://insecure.example/buy"}).returncode, 0)
        self.assertNotEqual(self.run_release({"DROPLET_LS_PRODUCT_ID": "abc"}).returncode, 0)
        unlicensed = self.run_release(remove=("DROPLET_LS_STORE_ID", "DROPLET_LS_PRODUCT_ID", "DROPLET_CHECKOUT_URL"),
                                      extra_env={"ALLOW_UNLICENSED": "1"})
        self.assertEqual(unlicensed.returncode, 0, unlicensed.stderr)

    def test_links_versions_signing_and_engine_are_checked(self):
        bad = [
            {"DROPLET_PRIVACY_URL": "http://dropletapp.com/privacy"},
            {"DROPLET_SUPPORT": "not an address"},
            {"DROPLET_VERSION": "v1"},
            {"DROPLET_BUILD": "1.0"},
            {"DEVELOPER_ID_APPLICATION": "Apple Development: Test Person (ABCDE12345)"},
            {"DROPLET_ARCH": "ppc"},
        ]
        for overrides in bad:
            with self.subTest(overrides=overrides):
                self.assertNotEqual(self.run_release(overrides).returncode, 0)
        self.assertNotEqual(self.run_release(remove=("NOTARY_PROFILE",)).returncode, 0)
        unpinned = self.run_release(engine_version="")
        self.assertNotEqual(unpinned.returncode, 0)
        self.assertIn("not pinned", unpinned.stderr)


class DirectDownloadConfiguration(unittest.TestCase):
    """Without a paid Developer ID: install command + zip from your website."""

    run_release = ReleaseConfiguration.run_release
    DIRECT = {"SIGNING_IDENTITY": "Droplet Signing", "DROPLET_DOWNLOAD_URL": "https://dropletapp.com/downloads/",
              "DROPLET_OWNER": "Test Person"}

    def test_self_signed_direct_build_needs_a_download_folder(self):
        result = self.run_release(self.DIRECT, remove=("DEVELOPER_ID_APPLICATION", "NOTARY_PROFILE"))
        self.assertEqual(result.returncode, 0, result.stderr)
        missing = self.run_release({"SIGNING_IDENTITY": "Droplet Signing"}, remove=("DEVELOPER_ID_APPLICATION", "NOTARY_PROFILE"))
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("DROPLET_DOWNLOAD_URL is required", missing.stderr)
        for bad in ("http://dropletapp.com/downloads", "https://dropletapp.com/my downloads",
                    "https://dropletapp.com/a;b", "https://dropletapp.com/a|b", "https://dropletapp.com/a'b",
                    "https://dropletapp.com/../droplet", "https://dropletapp.com/.git"):
            with self.subTest(url=bad):
                self.assertNotEqual(self.run_release({**self.DIRECT, "DROPLET_DOWNLOAD_URL": bad},
                                                     remove=("DEVELOPER_ID_APPLICATION",)).returncode, 0)

    def test_website_needs_a_seller_name_and_a_refund_period(self):
        direct = ("DEVELOPER_ID_APPLICATION", "NOTARY_PROFILE")
        unnamed = self.run_release(self.DIRECT, remove=direct + ("DROPLET_OWNER",))
        self.assertNotEqual(unnamed.returncode, 0)
        self.assertIn("DROPLET_OWNER", unnamed.stderr)
        self.assertNotEqual(self.run_release({**self.DIRECT, "DROPLET_REFUND_DAYS": "two weeks"}, remove=direct).returncode, 0)

    def test_free_github_hosting_must_match_its_pages_address(self):
        direct = ("DEVELOPER_ID_APPLICATION", "NOTARY_PROFILE")
        for repo, url in [("tester/tester.github.io", "https://tester.github.io/droplet"),
                          ("Tester/Tester.github.io", "https://tester.github.io"),
                          ("tester/droplet-site", "https://tester.github.io/droplet-site")]:
            with self.subTest(repo=repo):
                result = self.run_release({**self.DIRECT, "DROPLET_GITHUB_REPO": repo, "DROPLET_DOWNLOAD_URL": url}, remove=direct)
                self.assertEqual(result.returncode, 0, result.stderr)
        for repo, url in [("tester/tester.github.io", "https://dropletapp.com/droplet"),
                          ("tester/droplet-site", "https://tester.github.io/other"),
                          ("not a repo", "https://tester.github.io/droplet")]:
            with self.subTest(repo=repo, url=url):
                result = self.run_release({**self.DIRECT, "DROPLET_GITHUB_REPO": repo, "DROPLET_DOWNLOAD_URL": url}, remove=direct)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("DROPLET_", result.stderr)

    def test_signing_identity_choices(self):
        apple_development = self.run_release({**self.DIRECT, "SIGNING_IDENTITY": "Apple Development: Test Person (ABCDE12345)"},
                                             remove=("DEVELOPER_ID_APPLICATION", "NOTARY_PROFILE"))
        self.assertEqual(apple_development.returncode, 0, apple_development.stderr)
        adhoc = self.run_release({**self.DIRECT, "SIGNING_IDENTITY": "-"}, remove=("DEVELOPER_ID_APPLICATION", "NOTARY_PROFILE"))
        self.assertEqual(adhoc.returncode, 0, adhoc.stderr)
        self.assertIn("self-signed certificate avoids", adhoc.stderr)
        empty = self.run_release(remove=("DEVELOPER_ID_APPLICATION", "NOTARY_PROFILE"))
        self.assertNotEqual(empty.returncode, 0)
        self.assertIn("SIGNING_IDENTITY is required", empty.stderr)


class EngineFetch(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.files = self.root / "upstream"
        self.files.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def publish(self, name, data):
        path = self.files / name
        path.write_bytes(data)
        return {"url": path.as_uri(), "sha256": digest(data)}

    def zipped(self, name, member, data):
        path = self.files / name
        with zipfile.ZipFile(path, "w") as bundle:
            bundle.writestr(f"bin/{member}", data)
        return {"url": path.as_uri(), "sha256": digest(path.read_bytes())}

    def lock(self, **changes):
        lock = {
            "yt-dlp": {"version": "2026.09.30", **self.publish("yt-dlp_macos", b"#!/bin/sh\necho 2026.09.30\n"),
                       "license": self.publish("ytdlp-license", b"GPLv3+"), "source": "https://example.invalid/yt-dlp"},
            "ffmpeg": {"arm64": {"ffmpeg": self.zipped("ffmpeg.zip", "ffmpeg", b"ffmpeg-arm64"),
                                 "ffprobe": self.zipped("ffprobe.zip", "ffprobe", b"ffprobe-arm64")},
                       "license": self.publish("ffmpeg-license", b"GPL"), "source": "https://example.invalid/ffmpeg"},
            "deno": {"enabled": True, "version": "2.5.0", "arm64": self.zipped("deno.zip", "deno", b"deno-arm64"),
                     "license": self.publish("deno-license", b"MIT"), "source": "https://example.invalid/deno"},
        }
        for path, value in changes.items():
            section, key = path.split(".", 1)
            target = lock[section]
            *parents, leaf = key.split(".")
            for parent in parents:
                target = target[parent]
            target[leaf] = value
        lock_path = self.root / "engine.lock.json"
        lock_path.write_text(json.dumps(lock))
        return lock_path

    def fetch(self, lock_path):
        env = dict(os.environ, DROPLET_ENGINE_LOCK=str(lock_path), DROPLET_ENGINE_CACHE=str(self.root / "cache"))
        return subprocess.run(["python3", str(FETCH), "--arch", "arm64", "--no-smoke-test",
                               "--output", str(self.root / "Helpers"), "--notices", str(self.root / "Notices")],
                              env=env, capture_output=True, text=True, timeout=60)

    def test_pinned_engine_is_assembled_with_licenses(self):
        result = self.fetch(self.lock())
        self.assertEqual(result.returncode, 0, result.stderr)
        helpers = self.root / "Helpers"
        for name, payload in (("yt-dlp", b"#!/bin/sh\necho 2026.09.30\n"), ("ffmpeg", b"ffmpeg-arm64"),
                              ("ffprobe", b"ffprobe-arm64"), ("deno", b"deno-arm64")):
            self.assertEqual((helpers / name).read_bytes(), payload)
            self.assertTrue(os.access(helpers / name, os.X_OK), name)
        notices = self.root / "Notices"
        self.assertEqual((notices / "yt-dlp-LICENSE.txt").read_text(), "GPLv3+")
        self.assertEqual((notices / "deno-LICENSE.txt").read_text(), "MIT")
        self.assertIn("https://example.invalid/ffmpeg", (notices / "SOURCES.txt").read_text())

    def test_changed_or_unpinned_files_are_refused(self):
        tampered = self.lock(**{"ffmpeg.arm64.ffmpeg.sha256": "0" * 64})
        result = self.fetch(tampered)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stderr)
        self.assertFalse((self.root / "Helpers" / "ffmpeg").exists())

        unpinned = self.lock(**{"yt-dlp.sha256": ""})
        result = self.fetch(unpinned)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not pinned", result.stderr)

        plain = self.lock(**{"deno.arm64.url": "http://example.invalid/deno.zip"})
        result = self.fetch(plain)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("non-HTTPS", result.stderr)


class EnginePinning(unittest.TestCase):
    def test_pins_record_the_stable_url_not_the_expiring_redirect(self):
        import importlib.util
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location("fetch_engine", FETCH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as raw:
            module.CACHE = Path(raw) / "cache"

            def fake_download(url, destination):
                destination.write_bytes(b"payload")
                return "https://objects.example.invalid/signed?se=2026-10-08T17:00:00Z&sig=abc"

            with patch.object(module, "download", fake_download):
                stable = module.pin_url("https://github.com/yt-dlp/yt-dlp/releases/download/2026.09.30/yt-dlp_macos")
                resolved = module.pin_url("https://ffmpeg.example.invalid/redirect/latest/ffmpeg.zip", resolve_redirect=True)
            self.assertEqual(stable["url"], "https://github.com/yt-dlp/yt-dlp/releases/download/2026.09.30/yt-dlp_macos")
            self.assertTrue(resolved["url"].startswith("https://objects.example.invalid/"))
            self.assertEqual(stable["sha256"], digest(b"payload"))
            self.assertTrue((module.CACHE / digest(b"payload")).exists(), "Pinned files are cached for the release")

    def test_ffmpeg_pin_records_the_release_named_in_the_build_address(self):
        import argparse
        import importlib.util
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location("fetch_engine", FETCH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        builds = {"arm64": "1789931890_9.0.2", "amd64": "1789931006_9.0.2"}

        def fake_pin(url, resolve_redirect=False):
            arch = "arm64" if "/arm64/" in url else "amd64"
            return {"url": url.replace("redirect/latest", "download").replace("release", builds[arch]), "sha256": "0" * 64}

        def pin(download):
            lock = {"ffmpeg": {"download": download, "source": "https://ffmpeg.org/download.html#releases", "version": ""}}
            with tempfile.TemporaryDirectory() as raw:
                module.LOCK = Path(raw) / "engine.lock.json"
                with patch.object(module, "pin_url", fake_pin), patch("builtins.print"):
                    module.pin(lock, argparse.Namespace(yt_dlp=None, deno=None, ffmpeg=True))
                return json.loads(module.LOCK.read_text())["ffmpeg"]

        base = "https://ffmpeg.example.invalid/redirect/latest/macos"
        download = {arch: {tool: f"{base}/{folder}/release/{tool}.zip" for tool in ("ffmpeg", "ffprobe")}
                    for arch, folder in (("arm64", "arm64"), ("x86_64", "amd64"))}
        pinned = pin(download)
        self.assertEqual(pinned["version"], "9.0.2")
        self.assertEqual(pinned["source"], "https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz")
        builds["amd64"] = "1789931006_9.0.1"
        mixed = pin(download)
        self.assertEqual(mixed["version"], "", "Different releases per architecture are left for a person to record")
        self.assertEqual(mixed["source"], "https://ffmpeg.org/download.html#releases")


if __name__ == "__main__":
    unittest.main()
