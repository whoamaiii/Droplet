import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_publish import CURL, GH

ROOT = Path(__file__).resolve().parents[2]
# The bash on the PATH of whoever runs the checks (put macOS's bash 3.2 first to
# test with it); the scripts themselves run with a minimal PATH.
BASH = shutil.which("bash")

# Stand-ins for the macOS tools the wizard uses.
STUBS = {
    "uname": "echo Darwin",
    "xcode-select": "echo /Library/Developer/CommandLineTools",
    "swift": "echo 'Apple Swift version 6.2.3'",
    "codesign": "exit 0",
    "security": "echo '  1) 0123456789ABCDEF \"Droplet Signing\" (CSSMERR_TP_NOT_TRUSTED)'",
    "ditto": 'if [ "$1" = -x ]; then python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$3" "$4"; '
             'else cp -R "$1" "$2"; fi',
    "pgrep": "exit 1",
    "osascript": "exit 0",
    "open": 'echo "$1" >> "$QA_STATE/opened.log"',
    "sleep": "exit 0",
}

# Stands in for scripts/release.sh: its real validation, then a pretend build
# with the same outputs (zip, DMG, fingerprints, install.sh, website).
FAKE_RELEASE = r'''#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
VALIDATE_ONLY=1 bash "$here/release.real.sh" "$@" >/dev/null
[ "${VALIDATE_ONLY:-0}" = 1 ] && { echo "release: configuration OK"; exit 0; }
set -a
. "$here/../release.env"
set +a
python3 - "$here/.." <<'PY'
import hashlib, os, plistlib, subprocess, sys, zipfile
from pathlib import Path
root = Path(sys.argv[1])
env = os.environ
version = env["DROPLET_VERSION"]
dist = root / "dist"
dist.mkdir(exist_ok=True)
zip_path, dmg = dist / f"Droplet-{version}.zip", dist / f"Droplet-{version}.dmg"
info = {"CFBundleIdentifier": env["DROPLET_BUNDLE_ID"], "CFBundleShortVersionString": version,
        "DropletLicenseStoreID": env.get("DROPLET_LS_STORE_ID", "")}
with zipfile.ZipFile(zip_path, "w") as bundle:
    bundle.writestr("Droplet.app/Contents/Info.plist", plistlib.dumps(info))
dmg.write_bytes(b"dmg")
for path in (zip_path, dmg):
    (dist / f"{path.name}.sha256").write_text(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n")
download = env["DROPLET_DOWNLOAD_URL"].rstrip("/")
repo = env.get("DROPLET_GITHUB_REPO", "")
files = f"https://github.com/{repo}/releases/download/v{version}" if repo else download
subprocess.run(["python3", root / "scripts/render_installer.py", "--output", dist / "install.sh", "--version", version,
                "--zip-url", f"{files}/{zip_path.name}", "--sha256", hashlib.sha256(zip_path.read_bytes()).hexdigest(),
                "--bundle-id", env["DROPLET_BUNDLE_ID"]], check=True)
hosting = ["--host", "GitHub Pages"] if repo else ["--include-downloads"]
subprocess.run(["python3", root / "scripts/build_site.py", "--output", dist / "site", *hosting, "--version", version,
                "--download-url", download, "--files-url", files, "--installer", dist / "install.sh",
                "--zip", zip_path, "--dmg", dmg, "--notices", root / "Resources/ThirdPartyNotices",
                "--owner", env["DROPLET_OWNER"], "--support", env["DROPLET_SUPPORT"], "--price", env.get("DROPLET_PRICE", ""),
                "--checkout-url", env.get("DROPLET_CHECKOUT_URL", "")], check=True)
PY
'''


class FirstReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repo = self.root / "Droplet"
        for item in ("scripts", "website", "Resources"):
            shutil.copytree(ROOT / item, self.repo / item)
        for item in ("engine.lock.json", "Info.plist"):
            shutil.copyfile(ROOT / item, self.repo / item)
        (self.repo / "scripts/release.sh").rename(self.repo / "scripts/release.real.sh")
        (self.repo / "scripts/release.sh").write_text(FAKE_RELEASE)
        (self.repo / "scripts/release.sh").chmod(0o755)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, body in {**STUBS, "gh": None, "curl": None}.items():
            text = {"gh": GH, "curl": CURL}.get(name) or "#!/bin/bash\n" + body + "\n"
            (self.bin / name).write_text(text)
            (self.bin / name).chmod(0o755)
        self.state = self.root / "state"
        self.state.mkdir()
        self.bare = self.root / "remote.git"
        subprocess.run(["git", "init", "--quiet", "--bare", "--initial-branch=main", str(self.bare)], check=True)
        (self.root / "Applications").mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def wizard(self, answers, *arguments):
        inherited = {k: v for k, v in os.environ.items() if k not in ("BASH_ENV", "ENV", "CDPATH")}
        environment = dict(inherited, PATH=f"{self.bin}:/usr/bin:/bin", HOME=str(self.root), TMPDIR=str(self.root),
                           GIT_CONFIG_NOSYSTEM="1", DROPLET_SKIP_CHECKS="1", DROPLET_GITHUB_GIT_URL=str(self.bare),
                           # Never the real /Applications, even on a Mac where it is writable.
                           DROPLET_INSTALL_DIR=str(self.root / "Applications"),
                           QA_STATE=str(self.state), QA_BARE=str(self.bare),
                           QA_SITE_URL="https://tester.github.io/droplet",
                           QA_FILES_URL="https://github.com/tester/tester.github.io/releases/download/v1.0.0")
        result = subprocess.run([BASH, str(self.repo / "scripts/first-release.sh"), *arguments], input=answers.encode(),
                                env=environment, capture_output=True, timeout=120)
        result.stdout = result.stdout.decode("utf-8", "backslashreplace")
        result.stderr = result.stderr.decode("utf-8", "backslashreplace")
        return result

    def settings(self):
        return (self.repo / "release.env").read_text()

    def test_free_github_website_from_a_trial_build_to_published_with_a_store(self):
        # Hosting 1, username, app ID [default], email, seller, price [default], no store; install here: yes.
        trial = self.wizard("1\ntester\n\nhelp@example.com\nTest Person\n\n\n\ny\n")
        self.assertEqual(trial.returncode, 0, f"stdout:\n{trial.stdout}\nstderr:\n{trial.stderr}")
        settings = self.settings()
        for line in ("DROPLET_BUNDLE_ID='io.github.tester.droplet'", "DROPLET_GITHUB_REPO='tester/tester.github.io'",
                     "DROPLET_DOWNLOAD_URL='https://tester.github.io/droplet'", "DROPLET_OWNER='Test Person'",
                     "DROPLET_PRIVACY_URL='https://tester.github.io/droplet/privacy/'", "DROPLET_PRICE='US$4.99'",
                     "ALLOW_UNLICENSED='1'"):
            self.assertIn(line, settings)
        self.assertIn("--trial-only", trial.stdout, "a build without a store is not published by itself")
        self.assertTrue((self.root / "Applications/Droplet.app/Contents/Info.plist").is_file(), "installed on this Mac")
        self.assertFalse((self.state / "log").exists(), "nothing went to GitHub")

        # Start over with a store, skip installing, publish: yes.
        store = self.wizard("1\ntester\n\nhelp@example.com\nTest Person\nUS$9\n123\n456\n"
                            "https://test.lemonsqueezy.com/buy/abc\nn\ny\n", "--new-settings")
        self.assertEqual(store.returncode, 0, f"stdout:\n{store.stdout}\nstderr:\n{store.stderr}")
        self.assertEqual(len(list(self.repo.glob("release.env.old-*"))), 1, "the previous settings are kept")
        self.assertIn("DROPLET_LS_STORE_ID='123'", self.settings())
        self.assertNotIn("ALLOW_UNLICENSED", self.settings())
        self.assertIn("Droplet 1.0.0 is online", store.stdout)
        online = subprocess.run(["git", "--git-dir", str(self.bare), "show", "main:droplet/index.html"],
                                capture_output=True, text=True, check=True).stdout
        self.assertIn("US$9", online)
        self.assertIn("https://test.lemonsqueezy.com/buy/abc", online)

    def test_own_website_writes_its_settings_and_lists_the_upload(self):
        # Hosting 2, domain, folder/app ID/email [defaults], seller, price [default], store; install: no; publish: yes.
        result = self.wizard("2\nwww.DropletApp.com/\n\n\n\nTest Person\n\n123\n456\n"
                             "https://test.lemonsqueezy.com/buy/abc\nn\ny\n")
        self.assertEqual(result.returncode, 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
        settings = self.settings()
        for line in ("DROPLET_BUNDLE_ID='com.dropletapp.droplet'", "DROPLET_DOWNLOAD_URL='https://dropletapp.com/droplet'",
                     "DROPLET_SUPPORT='support@dropletapp.com'"):
            self.assertIn(line, settings)
        self.assertNotIn("DROPLET_GITHUB_REPO", settings)
        self.assertIn("install.sh last", result.stdout)
        self.assertTrue((self.repo / "dist/site/Droplet-1.0.0.zip").is_file(), "the upload folder holds the downloads")


if __name__ == "__main__":
    unittest.main()
