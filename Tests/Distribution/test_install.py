import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import subprocess
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/install_app.py"
spec = importlib.util.spec_from_file_location("installer", SCRIPT)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
ID = "local.quentinthiessen.droplet.preview"


class InstallTests(unittest.TestCase):
    def setUp(self):
        # /tmp is a symlink on macOS; production intentionally rejects such parents.
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "candidate.app"
        self.target = self.root / "Droplet.app"
        self.bundle(self.source, "new")
        self.bundle(self.target, "old")
        self.idle_calls = []

    def tearDown(self):
        self.temp.cleanup()

    def bundle(self, path, payload):
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": ID, "CFBundleExecutable": "Droplet"}))
        binary = path / "Contents/MacOS/Droplet"
        binary.write_text(payload)
        binary.chmod(0o755)

    def validate(self, path):
        self.assertTrue((path / "Contents/MacOS/Droplet").is_file())
        return plistlib.loads((path / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]

    def idle(self, *args):
        self.idle_calls.append(args)

    def perform(self, **kwargs):
        return installer.install(self.source, self.target,
            runtime_directory=self.root / "runtime",
            validate=kwargs.pop("validate", self.validate), idle=kwargs.pop("idle", self.idle), **kwargs)

    def payload(self, path=None):
        return ((path or self.target) / "Contents/MacOS/Droplet").read_text()

    def test_real_atomic_swap_and_backup(self):
        result = self.perform()
        self.assertEqual(self.payload(), "new")
        self.assertEqual(self.payload(Path(result["previous_bundle"])), "old")
        self.assertEqual(self.payload(self.source), "new")
        self.assertEqual(len(self.idle_calls), 2)

    def test_first_install(self):
        shutil.rmtree(self.target)
        result = self.perform()
        self.assertIsNone(result["previous_bundle"])
        self.assertEqual(self.payload(), "new")

    def test_copy_failure_preserves_old_and_cleans_partial_stage(self):
        def fail(source, target, **kwargs):
            target.mkdir()
            raise OSError("injected disk full")
        with self.assertRaises(OSError):
            self.perform(copy=fail)
        self.assertEqual(self.payload(), "old")
        self.assertEqual(list(self.root.glob(".droplet-install-*")), [])

    def test_staged_signature_failure(self):
        def validate(path):
            if path.parent.name.startswith(".droplet-install-"):
                raise installer.InstallError("injected bad signature")
            return self.validate(path)
        with self.assertRaises(installer.InstallError):
            self.perform(validate=validate)
        self.assertEqual(self.payload(), "old")

    def test_post_swap_failure_rolls_back(self):
        def validate(path):
            if path == self.target and self.payload() == "new":
                raise installer.InstallError("injected final validation failure")
            return self.validate(path)
        with self.assertRaisesRegex(installer.InstallError, "restored"):
            self.perform(validate=validate)
        self.assertEqual(self.payload(), "old")

    def test_initial_install_failure_removes_new_target(self):
        shutil.rmtree(self.target)
        def validate(path):
            if path == self.target:
                raise installer.InstallError("injected final validation failure")
            return self.validate(path)
        with self.assertRaisesRegex(installer.InstallError, "restored"):
            self.perform(validate=validate)
        self.assertFalse(self.target.exists())

    def test_swap_failure_preserves_old(self):
        def fail(*args, **kwargs):
            raise OSError("injected rename failure")
        with self.assertRaises(OSError):
            self.perform(rename=fail)
        self.assertEqual(self.payload(), "old")

    def test_rollback_failure_retains_both_complete_bundles(self):
        calls = 0
        def rename(*args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("injected rollback failure")
            installer.rename_exclusive(*args, **kwargs)
        def validate(path):
            if path == self.target and self.payload() == "new":
                raise installer.InstallError("injected verification failure")
            return self.validate(path)
        with self.assertRaisesRegex(installer.InstallError, "Preserve"):
            self.perform(validate=validate, rename=rename)
        self.assertEqual(self.payload(), "new")
        backups = list(self.root.glob(".droplet-install-*/Droplet.app"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(self.payload(backups[0]), "old")

    def test_running_target_rejected_before_copy(self):
        def busy(*args):
            raise installer.InstallError("running")
        with self.assertRaises(installer.InstallError):
            self.perform(idle=busy)
        self.assertEqual(self.payload(), "old")
        self.assertEqual(list(self.root.glob(".droplet-install-*")), [])

    def test_loaded_legacy_agent_inspection_is_read_only(self):
        calls = []
        def runner(args):
            calls.append(args)
            return type("Result", (), {"returncode": 0,
                "stdout": "PID Status Label\n123 0 com.quentinthiessen.droplet\n"})()
        with self.assertRaisesRegex(installer.InstallError, "still loaded"):
            installer.ensure_idle(self.target, "local.quentinthiessen.droplet", runner)
        self.assertEqual(calls, [["/bin/launchctl", "list"]])

    def test_symlink_and_foreign_bundle_rejected(self):
        shutil.rmtree(self.target)
        self.target.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(installer.InstallError):
            self.perform()
        self.target.unlink()
        self.bundle(self.target, "old")
        plist = self.target / "Contents/Info.plist"
        plist.write_bytes(plistlib.dumps({"CFBundleIdentifier": "other.app"}))
        with self.assertRaises(installer.InstallError):
            self.perform()
        self.assertEqual(self.payload(), "old")

    def test_lock_contention(self):
        fd = os.open(self.root / ".droplet-install.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            installer.fcntl.flock(fd, installer.fcntl.LOCK_EX | installer.fcntl.LOCK_NB)
            with self.assertRaisesRegex(installer.InstallError, "already running"):
                self.perform()
        finally:
            os.close(fd)

    def test_runtime_ownership_prevents_install(self):
        directory = self.root / "runtime"
        directory.mkdir()
        fd = os.open(directory / (ID + ".lock"), os.O_CREAT | os.O_RDWR, 0o600)
        try:
            installer.fcntl.flock(fd, installer.fcntl.LOCK_EX | installer.fcntl.LOCK_NB)
            with self.assertRaisesRegex(installer.InstallError, "instance is running"):
                self.perform()
            self.assertEqual(self.payload(), "old")
        finally:
            os.close(fd)

    def test_copy_preserves_extended_attributes(self):
        marker = "Droplet QA metadata"
        subprocess.run(["/usr/bin/xattr", "-w", "com.droplet.qa", marker, str(self.source)], check=True)
        self.perform()
        result = subprocess.run(["/usr/bin/xattr", "-p", "com.droplet.qa", str(self.target)],
            capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.strip(), marker)

    def test_actual_kernel_executable_path_rejects_running_target(self):
        executable = self.target / "Contents/MacOS/Droplet"
        shutil.copyfile("/bin/sleep", executable)
        executable.chmod(0o755)
        process = subprocess.Popen([str(executable), "30"])
        try:
            def runner(args):
                if args == ["/bin/launchctl", "list"]:
                    return subprocess.CompletedProcess(args, 0, "PID Status Label\n", "")
                return installer.run(args)
            with self.assertRaisesRegex(installer.InstallError, "running"):
                installer.ensure_idle(self.target, ID, runner)
            self.assertIsNone(process.poll())
        finally:
            process.terminate()
            process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
