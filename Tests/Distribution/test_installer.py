import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("render_installer", ROOT / "scripts/render_installer.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)

BUNDLE_ID = "com.dropletapp.droplet"
VALUES = {"VERSION": "1.2.0", "ZIP_URL": "https://dropletapp.com/downloads/Droplet-1.2.0.zip",
          "SHA256": "0" * 64, "BUNDLE_ID": BUNDLE_ID}

# Stand-ins for the macOS tools the installer uses; QA_* variables steer them.
STUBS = {
    "uname": 'echo Darwin',
    "sw_vers": 'echo "${QA_MACOS:-15.1}"',
    "curl": 'echo "$*" >> "$QA_STATE/curl.log"; out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && { out="$2"; shift; }; shift; done; '
            '[ -n "${QA_DOWNLOAD_FAILS:-}" ] && exit 22; cp "$QA_ZIP" "$out"',
    "shasum": 'python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],\'rb\').read()).hexdigest()+\'  \'+sys.argv[1])" "$3"',
    "ditto": 'if [ "$1" = -x ]; then python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$3" "$4"; '
             'else cp -R "$1" "$2"; fi',
    "plutil": 'python3 -c "import plistlib,sys; print(plistlib.load(open(sys.argv[1],\'rb\'))[\'CFBundleIdentifier\'])" "$6"',
    "pgrep": '[ -f "$QA_STATE/running" ]',
    "osascript": 'echo "$*" >> "$QA_STATE/osascript.log"; rm -f "$QA_STATE/running"',
    "open": 'echo "$1" >> "$QA_STATE/opened.log"',
    "sleep": 'exit 0',
}


class RendererTests(unittest.TestCase):
    def test_values_are_validated_before_they_reach_the_script(self):
        script = renderer.render(renderer.TEMPLATE.read_text(), VALUES)
        self.assertTrue(script.isascii(), "the installer stays plain ASCII for every terminal and locale")
        self.assertIn('ZIP_URL="https://dropletapp.com/downloads/Droplet-1.2.0.zip"', script)
        self.assertNotRegex(script, r"@[A-Z_]+@")
        for key, bad in [("ZIP_URL", "https://x.com/$(rm -rf ~).zip"), ("ZIP_URL", "http://x.com/a.zip"),
                         ("BUNDLE_ID", 'com.x"; rm -rf ~; "'), ("SHA256", "xyz"), ("VERSION", "1.0; ls")]:
            with self.subTest(key=key, bad=bad), self.assertRaises(ValueError):
                renderer.render(renderer.TEMPLATE.read_text(), {**VALUES, key: bad})


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, body in STUBS.items():
            path = self.bin / name
            path.write_text("#!/bin/bash\n" + body + "\n")
            path.chmod(0o755)
        self.state = self.root / "state"
        self.state.mkdir()
        self.apps = self.root / "Applications"
        self.apps.mkdir()
        self.zip = self.root / "Droplet-1.2.0.zip"
        self.make_app_zip(self.zip, BUNDLE_ID, b"new build")

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def write_app(path, bundle_id, payload):
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": bundle_id}))
        (path / "Contents/MacOS/Droplet").write_bytes(payload)

    def make_app_zip(self, zip_path, bundle_id, payload):
        staging = self.root / "staging"
        self.write_app(staging / "Droplet.app", bundle_id, payload)
        with zipfile.ZipFile(zip_path, "w") as bundle:
            for file in staging.rglob("*"):
                bundle.write(file, file.relative_to(staging))

    def install(self, sha=None, **env):
        values = {**VALUES, "SHA256": sha or hashlib.sha256(self.zip.read_bytes()).hexdigest()}
        script = self.root / "install.sh"
        script.write_text(renderer.render(renderer.TEMPLATE.read_text(), values))
        # Shell start-up files from the person running the checks must not leak in.
        inherited = {k: v for k, v in os.environ.items() if k not in ("BASH_ENV", "ENV", "CDPATH")}
        environment = dict(inherited, PATH=f"{self.bin}:/usr/bin:/bin", HOME=str(self.root),
                           TMPDIR=str(self.root), DROPLET_INSTALL_DIR=str(self.apps), QA_ZIP=str(self.zip),
                           QA_STATE=str(self.state), **env)
        # Exactly how customers run it: the script arrives on standard input.
        # Output is decoded leniently so unexpected bytes show up in the failure
        # message instead of crashing the test.
        result = subprocess.run(["bash"], input=script.read_bytes(), env=environment,
                                capture_output=True, timeout=60)
        result.stdout = result.stdout.decode("utf-8", "backslashreplace")
        result.stderr = result.stderr.decode("utf-8", "backslashreplace")
        return result

    def installed_payload(self):
        return (self.apps / "Droplet.app/Contents/MacOS/Droplet").read_bytes()

    def test_fresh_install_verifies_and_opens(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
        self.assertTrue((self.state / "curl.log").exists(), "the stand-in curl was used, not the real one")
        if result.stderr:
            # Visible in the run's output without failing on harmless tool noise.
            print(f"\nNOTE: unexpected stderr from a successful install:\n{result.stderr}")
        self.assertEqual(self.installed_payload(), b"new build")
        self.assertEqual((self.state / "opened.log").read_text().strip(), str(self.apps / "Droplet.app"))
        self.assertEqual(list(self.root.glob("droplet-install.*")), [], "temporary files are removed")

    def test_changed_download_and_old_macos_install_nothing(self):
        for env, sha, message in [({}, "f" * 64, "fingerprint"), ({"QA_MACOS": "13.6"}, None, "macOS 14"),
                                  ({"QA_DOWNLOAD_FAILS": "1"}, None, "did not complete")]:
            with self.subTest(message=message):
                result = self.install(sha=sha, **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
                self.assertFalse((self.apps / "Droplet.app").exists())
                self.assertFalse((self.state / "opened.log").exists())

    def test_update_quits_running_droplet_and_never_replaces_another_app(self):
        self.write_app(self.apps / "Droplet.app", "com.someone.else", b"other app")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different app", result.stderr)
        self.assertEqual(self.installed_payload(), b"other app")

        (self.apps / "Droplet.app/Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": BUNDLE_ID}))
        (self.state / "running").touch()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(BUNDLE_ID, (self.state / "osascript.log").read_text())
        self.assertEqual(self.installed_payload(), b"new build")


if __name__ == "__main__":
    unittest.main()
