from html.parser import HTMLParser
import hashlib
import importlib.util
import json
import os
import shutil
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
# The bash on the PATH of whoever runs the checks (put macOS's bash 3.2 first to
# test with it); the scripts themselves run with a minimal PATH.
BASH = shutil.which("bash")
PUBLISH = ROOT / "scripts/publish.sh"
BUILD_SITE = ROOT / "scripts/build_site.py"
spec = importlib.util.spec_from_file_location("render_installer", ROOT / "scripts/render_installer.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)

REPO = "tester/tester.github.io"
SITE_URL = "https://tester.github.io/droplet"
FILES_URL = f"https://github.com/{REPO}/releases/download/v1.0.0"
BUNDLE_ID = "io.github.tester.droplet"


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name in ("href", "src") and value:
                self.links.append(value)


def build_site(output, installer, dist, include_downloads=False, files_url=FILES_URL, **values):
    notices = dist / "notices"
    notices.mkdir(exist_ok=True)
    for name in ("README.txt", "SOURCES.txt", "ffmpeg-LICENSE.txt"):
        (notices / name).write_text(name)
    options = {"owner": "Test Person", "support": "help@example.com", "price": "US$4.99",
               "checkout-url": "https://test.lemonsqueezy.com/buy/abc", "host": "GitHub Pages", **values}
    arguments = ["python3", str(BUILD_SITE), "--output", str(output), "--version", "1.0.0",
                 "--download-url", SITE_URL, "--files-url", files_url, "--installer", str(installer),
                 "--zip", str(dist / "Droplet-1.0.0.zip"), "--dmg", str(dist / "Droplet-1.0.0.dmg"),
                 "--notices", str(notices)]
    arguments += [item for key, value in options.items() for item in (f"--{key}", value)]
    if include_downloads:
        arguments.append("--include-downloads")
    return subprocess.run(arguments, capture_output=True, text=True, timeout=60)


def make_dist(dist, store="12345", bundle_id=BUNDLE_ID, files_url=FILES_URL):
    """A release as scripts/release.sh leaves it in dist/."""
    dist.mkdir(parents=True, exist_ok=True)
    zip_path = dist / "Droplet-1.0.0.zip"
    info = {"CFBundleIdentifier": bundle_id, "CFBundleShortVersionString": "1.0.0", "DropletLicenseStoreID": store}
    with zipfile.ZipFile(zip_path, "w") as bundle:
        bundle.writestr("Droplet.app/Contents/Info.plist", plistlib.dumps(info))
        bundle.writestr("Droplet.app/Contents/MacOS/Droplet", b"app")
    (dist / "Droplet-1.0.0.dmg").write_bytes(b"dmg")
    for path in (zip_path, dist / "Droplet-1.0.0.dmg"):
        (dist / f"{path.name}.sha256").write_text(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n")
    installer = dist / "install.sh"
    installer.write_text(renderer.render(renderer.TEMPLATE.read_text(), {
        "VERSION": "1.0.0", "ZIP_URL": f"{files_url}/Droplet-1.0.0.zip",
        "SHA256": hashlib.sha256(zip_path.read_bytes()).hexdigest(), "BUNDLE_ID": BUNDLE_ID}))
    result = build_site(dist / "site", installer, dist, include_downloads=files_url == SITE_URL, files_url=files_url)
    assert result.returncode == 0, result.stderr


class WebsiteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.dist = Path(self.temp.name) / "dist"
        make_dist(self.dist)
        self.site = self.dist / "site"

    def tearDown(self):
        self.temp.cleanup()

    def page(self, name="index.html"):
        return (self.site / name).read_text()

    def test_pages_show_the_install_command_price_and_legal_texts(self):
        index = self.page()
        self.assertIn(f"curl -fsSL {SITE_URL}/install.sh | bash", index)
        self.assertIn(f'href="{FILES_URL}/Droplet-1.0.0.dmg"', index)
        self.assertIn('href="https://test.lemonsqueezy.com/buy/abc"', index)
        self.assertIn("US$4.99", index)
        self.assertIn("14 days", index)
        self.assertIn("Test Person", self.page("terms/index.html"))
        self.assertIn("mailto:help@example.com", self.page("privacy/index.html"))
        self.assertIn("hosted by GitHub Pages", self.page("privacy/index.html"))
        self.assertIn('href="ffmpeg-LICENSE.txt"', self.page("licenses/index.html"))
        self.assertEqual((self.site / "install.sh").read_bytes(), (self.dist / "install.sh").read_bytes())
        self.assertFalse((self.site / "Droplet-1.0.0.zip").exists(), "GitHub hosting serves the zip from a release")
        for page in self.site.rglob("*.html"):
            text = page.read_text()
            self.assertNotIn("{{", text, page)
            self.assertNotIn("<!-- if", text, page)

    def assert_links_resolve(self, site):
        for page in site.rglob("*.html"):
            parser = Links()
            parser.feed(page.read_text())
            for link in parser.links:
                if link.startswith(("https://", "mailto:", "#")):
                    continue
                target = (page.parent / link.split("#")[0]).resolve()
                if target.is_dir():
                    target = target / "index.html"
                with self.subTest(page=page.relative_to(site), link=link):
                    self.assertTrue(target.is_file())

    def test_every_relative_link_points_to_a_file(self):
        self.assert_links_resolve(self.site)

    def test_values_cannot_add_markup_or_unsafe_links(self):
        own = Path(self.temp.name) / "own"
        result = build_site(own, self.dist / "install.sh", self.dist, include_downloads=True,
                            owner='<script>alert("x")</script>', price="", **{"checkout-url": ""})
        self.assertEqual(result.returncode, 0, result.stderr)
        index = (own / "index.html").read_text()
        self.assertNotIn("<script>alert", index)
        self.assertIn("&lt;script&gt;", index)
        self.assertNotIn("Buy", index, "no buy button without a checkout link")
        self.assertTrue((own / "Droplet-1.0.0.zip").is_file(), "own hosting gets the downloads in the site")
        for values, message in [({"checkout-url": "javascript:alert(1)"}, "checkout"),
                                ({"support": "not an address"}, "support"),
                                ({"owner": " "}, "DROPLET_OWNER"),
                                ({"refund-days": "two weeks"}, "DROPLET_REFUND_DAYS")]:
            with self.subTest(values=values):
                result = build_site(Path(self.temp.name) / "bad", self.dist / "install.sh", self.dist, **values)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_sales_soon_text_without_a_checkout_link(self):
        later = Path(self.temp.name) / "later"
        result = build_site(later, self.dist / "install.sh", self.dist, **{"checkout-url": ""})
        self.assertEqual(result.returncode, 0, result.stderr)
        index = (later / "index.html").read_text()
        self.assertIn("License sales open soon", index)
        self.assertIn("US$4.99", index)

    def test_launch_offer_lets_customers_choose_from_zero_to_the_price(self):
        launch = Path(self.temp.name) / "launch"
        result = build_site(launch, self.dist / "install.sh", self.dist, country="Norway",
                            **{"checkout-url": "", "launch-offer": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        index = (launch / "index.html").read_text()
        for part in ('data-max-cents="499"', 'min="0" max="499" step="1"', 'value="4.99"', "any price from US$0 to US$4.99",
                     'data-price-pick="0"', 'data-price-pick="100"', 'data-price-pick="300"', 'data-price-pick="499"'):
            self.assertIn(part, index)
        self.assertIn("Checkout isn’t open yet", index, "no checkout address: the page says so")
        self.assertNotIn("action=", index, "nothing is sent anywhere without a checkout address")
        self.assertNotIn("Buy", index, "the launch offer replaces the buy button")
        self.assertIn("isn’t the trial", (ROOT / "website/site.js").read_text())
        self.assertIn("The trial is not the same as a US$0 launch license", index)
        terms = (launch / "terms/index.html").read_text()
        self.assertIn("from US$0 to US$4.99", terms)
        self.assertIn("License sales are not open yet", terms)
        self.assertIn("License sales are not open yet", (launch / "privacy/index.html").read_text())
        self.assert_links_resolve(launch)

    def test_launch_checkout_address_receives_the_chosen_price(self):
        launch = Path(self.temp.name) / "launch"
        result = build_site(launch, self.dist / "install.sh", self.dist,
                            **{"launch-offer": "1", "launch-checkout-url": "https://pay.example.com/droplet"})
        self.assertEqual(result.returncode, 0, result.stderr)
        index = (launch / "index.html").read_text()
        self.assertIn('action="https://pay.example.com/droplet" method="get"', index)
        self.assertIn('name="price"', index)
        self.assertNotIn("Checkout isn’t open yet", index)
        self.assertNotIn('href="https://test.lemonsqueezy.com/buy/abc"', index, "the price chooser is the way to buy")
        self.assertIn("14 days", index)
        self.assertIn("Purchases are handled by", (launch / "privacy/index.html").read_text())

    def test_launch_offer_settings_are_checked(self):
        for values, message in [({"launch-offer": "1", "price": ""}, "DROPLET_PRICE"),
                                ({"launch-offer": "1", "price": "4.99 dollars"}, "DROPLET_PRICE"),
                                ({"launch-offer": "1", "price": "US$0"}, "DROPLET_PRICE"),
                                ({"launch-offer": "1", "launch-checkout-url": "http://pay.example.com/x"}, "launch checkout"),
                                ({"launch-offer": "1", "launch-checkout-url": "https://pay.example.com/x?a=1"}, "launch checkout"),
                                ({"launch-offer": "yes"}, "launch-offer")]:
            with self.subTest(values=values):
                result = build_site(Path(self.temp.name) / "bad", self.dist / "install.sh", self.dist, **values)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_preview_is_marked_and_needs_no_downloads(self):
        preview = Path(self.temp.name) / "preview"
        common = ["python3", str(BUILD_SITE), "--output", str(preview), "--version", "1.0.0",
                  "--notices", str(self.dist / "notices"), "--owner", "Whoamiii", "--country", "Norway",
                  "--support", "quentin@whoamiii.art", "--price", "US$4.99", "--launch-offer", "1"]
        refused = subprocess.run(common, capture_output=True, text=True, timeout=60)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("--preview", refused.stderr, "only a preview may leave out the downloads")
        partial = subprocess.run(common + ["--preview", "--download-url", SITE_URL], capture_output=True, text=True, timeout=60)
        self.assertNotEqual(partial.returncode, 0)
        self.assertIn("--files-url", partial.stderr)
        result = subprocess.run(common + ["--preview"], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        for page in preview.rglob("*.html"):
            text = page.read_text()
            self.assertIn('<meta name="robots" content="noindex, nofollow">', text, page)
            self.assertIn("Local design preview", text, page)
            self.assertIn("Whoamiii, Norway", text, page)
            self.assertNotIn("{{", text, page)
        index = (preview / "index.html").read_text()
        self.assertIn("Available at launch", index)
        self.assertNotIn("curl -fsSL https://", index)
        self.assertNotIn('rel="canonical"', index)
        self.assertFalse((preview / "install.sh").exists())
        self.assert_links_resolve(preview)
        self.assertNotIn("Local design preview", self.page(), "release builds are not previews")
        self.assertNotIn("noindex", self.page())

    def test_license_texts_get_readable_names_and_hidden_files_are_skipped(self):
        (self.dist / "notices" / "._ffmpeg-LICENSE.txt").write_text("macOS metadata")
        notices = Path(self.temp.name) / "notices-site"
        result = build_site(notices, self.dist / "install.sh", self.dist)
        self.assertEqual(result.returncode, 0, result.stderr)
        page = (notices / "licenses/index.html").read_text()
        self.assertIn(">FFmpeg license</a>", page)
        self.assertIn('href="SOURCES.txt"', page)
        self.assertNotIn("._ffmpeg", page)
        self.assertFalse((notices / "licenses/._ffmpeg-LICENSE.txt").exists())

    @unittest.skipUnless(shutil.which("node"), "needs Node.js")
    def test_price_chooser_reads_cents_from_zero_to_the_limit(self):
        cases = {"0": [True, 0], "0.00": [True, 0], "0.01": [True, 1], "4.99": [True, 499], "4.98": [True, 498],
                 "2,5": [True, 250], "US$1.05": [True, 105], "$3": [True, 300], ".5": [True, 50], "4.": [True, 400],
                 "0004.99": [True, 499], "4.991": [False, "cents"], "5": [False, "high"], "5.00": [False, "high"],
                 "499": [False, "high"], "-1": [False, "negative"], "": [False, "empty"], "  ": [False, "empty"],
                 "abc": [False, "format"], "1.2.3": [False, "format"], ".": [False, "format"]}
        script = ("const site = require(process.argv[1]); const out = {};"
                  "for (const raw of JSON.parse(process.argv[2])) { const r = site.parsePrice(raw, 499);"
                  " out[raw] = [r.ok, r.ok ? r.cents : r.reason]; }"
                  "out.format = [0, 5, 300, 499].map(site.formatPrice).concat([0, 5, 499].map(site.inputValue));"
                  "console.log(JSON.stringify(out));")
        result = subprocess.run(["node", "-e", script, str(ROOT / "website/site.js"), json.dumps(list(cases))],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        parsed = json.loads(result.stdout)
        for raw, expected in cases.items():
            with self.subTest(price=raw):
                self.assertEqual(parsed[raw], expected)
        self.assertEqual(parsed["format"], ["US$0", "US$0.05", "US$3", "US$4.99", "0.00", "0.05", "4.99"])


# Stand-ins for GitHub's command-line tool and curl. QA_STATE holds what
# "GitHub" has; the website is served from what was pushed to the bare repository.
GH = r'''#!/usr/bin/env python3
import os, shutil, subprocess, sys
from pathlib import Path
state = Path(os.environ["QA_STATE"])
args = sys.argv[1:]
with open(state / "log", "a") as log:
    log.write("gh " + " ".join(args) + "\n")
def flag(name):
    return args[args.index(name) + 1] if name in args else None
if args[:2] == ["auth", "status"]:
    sys.exit(0 if not os.environ.get("QA_LOGGED_OUT") else 1)
if args[:2] == ["repo", "view"]:
    if not (state / "repo").exists():
        sys.exit(1)
    if "--json" in args:
        print("PUBLIC")
    sys.exit(0)
if args[:2] == ["repo", "create"]:
    (state / "repo").touch()
    sys.exit(0)
if args[0] == "api":
    if args[1] == "user":
        print({".login": "tester", ".id": "42"}[flag("--jq")])
        sys.exit(0)
    if "POST" in args:
        (state / "pages").touch()
        sys.exit(0)
    if not (state / "pages").exists():
        sys.exit(1)
    if "--jq" in args:
        print("main /")
    sys.exit(0)
if args[:2] == ["release", "view"]:
    sys.exit(0 if (state / ("release-" + args[2])).exists() else 1)
if args[:2] in (["release", "create"], ["release", "upload"]):
    folder = state / ("release-" + args[2])
    folder.mkdir(exist_ok=True)
    for item in args[3:]:
        if item.startswith("--"):
            break
        shutil.copyfile(item, folder / Path(item).name)
    sys.exit(0)
sys.exit("unexpected gh call: " + " ".join(args))
'''

CURL = r'''#!/usr/bin/env python3
import os, subprocess, sys
from pathlib import Path
state = Path(os.environ["QA_STATE"])
args = sys.argv[1:]
output = args[args.index("-o") + 1]
url = [a for a in args if a.startswith("https://")][0].split("?")[0]
site, files = os.environ["QA_SITE_URL"], os.environ["QA_FILES_URL"]
if url.startswith(files + "/"):
    source = state / "release-v1.0.0" / url[len(files) + 1:]
    if not source.exists():
        sys.exit(22)
    data = source.read_bytes()
elif url.startswith(site + "/") and (state / "pages").exists():
    path = url[len(site) + 1:] or "index.html"
    shown = subprocess.run(["git", "--git-dir", os.environ["QA_BARE"], "show", "main:droplet/" + path], capture_output=True)
    if shown.returncode:
        sys.exit(22)
    data = shown.stdout
else:
    sys.exit(22)
Path(output).write_bytes(data)
'''


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.dist = self.root / "dist"
        make_dist(self.dist)
        self.state = self.root / "state"
        self.state.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, body in (("gh", GH), ("curl", CURL), ("sleep", "#!/bin/bash\nexit 0\n")):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        # "GitHub" creates an empty repository; a hook records every push.
        self.bare = self.root / "remote.git"
        subprocess.run(["git", "init", "--quiet", "--bare", "--initial-branch=main", str(self.bare)], check=True)
        hook = self.bare / "hooks/pre-receive"
        hook.write_text(f'#!/bin/bash\nwhile read -r old new ref; do echo "push $ref $(git ls-tree -r --name-only "$new" | tr "\\n" " ")" >> "{self.state}/log"; done\n')
        hook.chmod(0o755)
        self.config = self.root / "release.env"
        self.write_config()

    def tearDown(self):
        self.temp.cleanup()

    def write_config(self, **overrides):
        values = {"DROPLET_BUNDLE_ID": BUNDLE_ID, "DROPLET_VERSION": "1.0.0", "DROPLET_DOWNLOAD_URL": SITE_URL,
                  "DROPLET_GITHUB_REPO": REPO, **overrides}
        self.config.write_text("".join(f"{key}='{value}'\n" for key, value in values.items()))

    def publish(self, *arguments, answers=b""):
        inherited = {k: v for k, v in os.environ.items() if k not in ("BASH_ENV", "ENV", "CDPATH")}
        environment = dict(inherited, PATH=f"{self.bin}:/usr/bin:/bin", HOME=str(self.root), TMPDIR=str(self.root),
                           GIT_CONFIG_NOSYSTEM="1", DROPLET_RELEASE_ENV=str(self.config), DROPLET_DIST_DIR=str(self.dist),
                           DROPLET_GITHUB_GIT_URL=str(self.bare), QA_STATE=str(self.state), QA_BARE=str(self.bare),
                           QA_SITE_URL=SITE_URL, QA_FILES_URL=FILES_URL)
        result = subprocess.run([BASH, str(PUBLISH), *arguments], input=answers, env=environment,
                                capture_output=True, timeout=120)
        result.stdout = result.stdout.decode("utf-8", "backslashreplace")
        result.stderr = result.stderr.decode("utf-8", "backslashreplace")
        return result

    def log(self):
        path = self.state / "log"
        return path.read_text().splitlines() if path.exists() else []

    def test_first_publish_uploads_files_before_the_website_and_checks_it_online(self):
        result = self.publish("--yes")
        self.assertEqual(result.returncode, 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
        self.assertIn(f"curl -fsSL {SITE_URL}/install.sh | bash", result.stdout)
        log = self.log()
        self.assertIn(f"gh repo create {REPO} --public --description Droplet for Mac: website and downloads", log)
        steps = [line.split()[0] + " " + line.split()[1] for line in log if line.startswith(("push", "gh release create"))]
        self.assertEqual(steps, ["push refs/heads/main", "gh release", "push refs/heads/main"],
                         "first commit, then the zip and DMG, then the website")
        website_push = [line for line in log if line.startswith("push")][-1]
        self.assertIn("droplet/install.sh", website_push)
        self.assertIn("droplet/privacy/index.html", website_push)
        self.assertTrue(any("repos/" + REPO + "/pages" in line and "POST" in line for line in log), "GitHub Pages turned on")
        published = self.state / "release-v1.0.0"
        self.assertEqual((published / "Droplet-1.0.0.zip").read_bytes(), (self.dist / "Droplet-1.0.0.zip").read_bytes())
        self.assertTrue((published / "Droplet-1.0.0.dmg").exists())
        self.assertEqual(list(self.root.glob("droplet-publish.*")), [], "temporary files are removed")

    def test_publishing_again_asks_before_replacing_and_keeps_other_files(self):
        self.assertEqual(self.publish("--yes").returncode, 0)
        refused = self.publish(answers=b"y\nn\n")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("nothing changed", refused.stderr)
        again = self.publish(answers=b"y\ny\n")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("already up to date", again.stdout)
        self.assertTrue(any(line.startswith("gh release upload v1.0.0") and "--clobber" in line for line in self.log()))
        files = subprocess.run(["git", "--git-dir", str(self.bare), "ls-tree", "-r", "--name-only", "main"],
                               capture_output=True, text=True, check=True).stdout.split()
        self.assertIn("README.md", files, "files outside Droplet's folder stay")
        front = subprocess.run(["git", "--git-dir", str(self.bare), "show", "main:index.html"],
                               capture_output=True, text=True, check=True).stdout
        self.assertIn('url=droplet/', front, "a new site's front page leads to Droplet")

    def test_nothing_is_published_without_a_yes_a_store_or_a_matching_build(self):
        declined = self.publish(answers=b"n\n")
        self.assertNotEqual(declined.returncode, 0)
        self.assertIn("nothing was published", declined.stderr)
        self.assertFalse(any("create" in line for line in self.log()))

        make_dist(self.dist, store="")
        no_store = self.publish("--yes")
        self.assertNotEqual(no_store.returncode, 0)
        self.assertIn("--trial-only", no_store.stderr)
        self.assertEqual(self.publish("--yes", "--trial-only").returncode, 0)

        self.write_config(DROPLET_BUNDLE_ID="com.someone.else")
        stale = self.publish("--yes")
        self.assertNotEqual(stale.returncode, 0)
        self.assertIn("different build", stale.stderr)
        self.write_config(DROPLET_GITHUB_REPO="tester/droplet-site", DROPLET_DOWNLOAD_URL="https://tester.github.io/droplet-site")
        moved = self.publish("--yes", "--trial-only")
        self.assertNotEqual(moved.returncode, 0)
        self.assertIn("other download settings", moved.stderr)

    def test_a_new_repository_must_belong_to_the_logged_in_account(self):
        other = "https://github.com/someone/someone.github.io/releases/download/v1.0.0"
        make_dist(self.dist, files_url=other)
        self.write_config(DROPLET_GITHUB_REPO="someone/someone.github.io", DROPLET_DOWNLOAD_URL="https://someone.github.io/droplet")
        result = self.publish("--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("logged in to GitHub as tester", result.stderr)
        self.assertFalse(any("repo create" in line for line in self.log()))

    def test_own_website_lists_the_upload_and_unsafe_folders_are_refused(self):
        make_dist(self.dist, files_url=SITE_URL)
        self.write_config(DROPLET_GITHUB_REPO="")
        own = self.publish()
        self.assertEqual(own.returncode, 0, own.stderr)
        self.assertIn("install.sh last", own.stdout)
        self.assertEqual(self.log(), [], "no GitHub calls for your own website")
        make_dist(self.dist)

        self.write_config(DROPLET_DOWNLOAD_URL="https://tester.github.io/.git")
        dotted = self.publish("--yes")
        self.assertNotEqual(dotted.returncode, 0)
        self.assertIn("dot", dotted.stderr)
        self.write_config(DROPLET_DOWNLOAD_URL="https://elsewhere.example/droplet")
        elsewhere = self.publish("--yes")
        self.assertNotEqual(elsewhere.returncode, 0)
        self.assertIn("not on the GitHub Pages site", elsewhere.stderr)


if __name__ == "__main__":
    unittest.main()
