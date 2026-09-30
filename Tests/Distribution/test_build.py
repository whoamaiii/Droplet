import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BuildFailures(unittest.TestCase):
    def test_build_failures_never_change_install_or_autostart(self):
        for failure in ("compiler", "copy", "sign", "verify"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as raw:
                root = Path(raw).resolve()
                mock = root / "bin"
                mock.mkdir()
                binary = root / "compiled"
                binary.mkdir()
                (binary / "Droplet").write_text("compiled fixture")
                sentinel = root / "old-app"
                sentinel.write_text("old unchanged")
                agent = root / "agent-state"
                agent.write_text("loaded")
                scripts = {
                    "swift": '''#!/bin/bash
if [[ "$*" == *--show-bin-path* ]]; then echo "$QA_BINARY"; exit 0; fi
[[ "$QA_FAIL" == compiler ]] && exit 42
exit 0
''',
                    "cp": '''#!/bin/bash
[[ "$QA_FAIL" == copy ]] && exit 43
exec /bin/cp "$@"
''',
                    "codesign": '''#!/bin/bash
[[ "$QA_FAIL" == sign && "$*" == *--force* ]] && exit 44
[[ "$QA_FAIL" == verify && "$*" == *--verify* ]] && exit 45
exit 0
''',
                    "launchctl": '''#!/bin/bash
echo "$*" >> "$QA_LAUNCH_LOG"
exit 99
''',
                }
                for name, content in scripts.items():
                    path = mock / name
                    path.write_text(content)
                    path.chmod(0o755)
                env = dict(os.environ, PATH=str(mock) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                    QA_FAIL=failure, QA_BINARY=str(binary), QA_LAUNCH_LOG=str(root / "launch.log"),
                    DROPLET_BUILD_ROOT=str(root / "builds"))
                result = subprocess.run([str(ROOT / "build.sh")], env=env,
                    capture_output=True, text=True, timeout=30)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(sentinel.read_text(), "old unchanged")
                self.assertEqual(agent.read_text(), "loaded")
                self.assertFalse((root / "launch.log").exists())
                self.assertEqual(list((root / "builds").glob("local.*")), [])


if __name__ == "__main__":
    unittest.main()
