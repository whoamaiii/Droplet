#!/usr/bin/env python3
"""Explicit local development install. Never stops apps or changes launchd.

Uses a same-volume atomic exchange and keeps the previous complete bundle.
Not the public distribution/notarization pipeline (WHO-237).
"""
import argparse
import ctypes
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile

BUNDLE_IDS = {"local.quentinthiessen.droplet", "local.quentinthiessen.droplet.preview"}
LEGACY_LABEL = "com.quentinthiessen.droplet"


class InstallError(Exception):
    pass


def run(args):
    return subprocess.run(args, capture_output=True, text=True, timeout=30)


def validate_bundle(path, runner=run):
    if path.is_symlink() or not path.is_dir():
        raise InstallError("Candidate must be a real .app directory.")
    with (path / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    bundle_id = info.get("CFBundleIdentifier")
    if bundle_id not in BUNDLE_IDS or info.get("CFBundleExecutable") != "Droplet":
        raise InstallError("Unexpected bundle identity or executable.")
    executable = path / "Contents/MacOS/Droplet"
    if executable.is_symlink() or not executable.is_file() or not os.access(executable, os.X_OK):
        raise InstallError("Missing regular executable.")
    # Validate all sealed resources; do not remove extended attributes/quarantine.
    result = runner(["/usr/bin/codesign", "--verify", "--strict", str(path)])
    if result.returncode:
        raise InstallError("Bundle signature verification failed.")
    return bundle_id


def ensure_idle(destination, bundle_id, runner=run):
    # Read-only launchctl inspection. Unavailable/ambiguous inspection fails closed.
    result = runner(["/bin/launchctl", "list"])
    if result.returncode:
        raise InstallError("Cannot inspect login services; nothing was changed.")
    labels = {line.split()[-1] for line in result.stdout.splitlines() if line.split()}
    if bundle_id == "local.quentinthiessen.droplet" and LEGACY_LABEL in labels:
        raise InstallError("Quit Droplet using its Quit button first; its legacy login service is still loaded.")
    # Kernel executable paths, never a process-name kill. Refuse to replace a live
    # target instead of terminating user work. Another copy at another path is OK.
    listing = runner(["/bin/ps", "-axo", "pid="])
    if listing.returncode:
        raise InstallError("Cannot inspect running processes; nothing was changed.")
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    libproc.proc_pidpath.restype = ctypes.c_int
    target = str(destination / "Contents/MacOS/Droplet")
    for raw in listing.stdout.split():
        buffer = ctypes.create_string_buffer(4096)
        if libproc.proc_pidpath(int(raw), buffer, len(buffer)) > 0:
            if os.path.realpath(os.fsdecode(buffer.value)) == target:
                raise InstallError("The target app is running. Quit it before installing.")


def rename_exclusive(source, destination, *, exchange=False):
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    # Darwin AT_FDCWD=-2, RENAME_SWAP=2, RENAME_EXCL=4.
    if rename(-2, os.fsencode(source), -2, os.fsencode(destination), 2 if exchange else 4):
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def copy_bundle(source, destination, **_kwargs):
    # macOS ditto preserves resource forks and extended attributes, including
    # quarantine. shutil.copytree does not preserve all macOS metadata.
    result = run(["/usr/bin/ditto", "--rsrc", "--extattr", str(source), str(destination)])
    if result.returncode:
        raise InstallError("Could not copy the complete bundle.")


def install(candidate, destination, *, runtime_directory=None, **kwargs):
    # Share the app's ownership lock so new app versions cannot start between
    # the final live-process check and the atomic exchange.
    bundle_id = kwargs.get("validate", validate_bundle)(Path(candidate).absolute())
    if bundle_id not in BUNDLE_IDS:
        raise InstallError("Unexpected bundle identity.")
    directory = runtime_directory or (Path.home() / "Library/Application Support/Droplet/RuntimeLocks")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise InstallError("Unsafe runtime lock directory.")
    descriptor = os.open(directory / (bundle_id + ".lock"),
        os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise InstallError("Unsafe runtime lock.")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise InstallError("A Droplet instance is running. Quit it before installing.") from error
        return _install(candidate, destination, **kwargs)
    finally:
        os.close(descriptor)


def _install(candidate, destination, *, validate=validate_bundle, idle=ensure_idle,
            copy=copy_bundle, rename=rename_exclusive):
    candidate = Path(candidate).absolute()
    destination = Path(destination).absolute()
    if candidate.suffix != ".app" or destination.name != "Droplet.app":
        raise InstallError("Use a .app candidate and an explicit destination ending in Droplet.app.")
    if not destination.parent.is_dir() or destination.parent.resolve() != destination.parent:
        raise InstallError("Destination parent must exist and must not contain symlinks.")
    if (candidate.resolve() == destination or destination in candidate.resolve().parents
            or candidate.resolve() in destination.parents):
        raise InstallError("Candidate must be separate from the installed app.")
    if destination.is_symlink():
        raise InstallError("Refusing a symlink destination.")
    bundle_id = validate(candidate)
    lock_path = destination.parent / ".droplet-install.lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    transaction = None
    keep_transaction = False
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise InstallError("Unsafe installation lock.")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise InstallError("Another installation is already running.") from error
        if destination.exists() and validate(destination) != bundle_id:
            raise InstallError("Candidate and installed app identities differ.")
        idle(destination, bundle_id)
        transaction = Path(tempfile.mkdtemp(prefix=".droplet-install-", dir=destination.parent))
        staged = transaction / "Droplet.app"
        copy(candidate, staged, symlinks=True)
        if validate(staged) != bundle_id:
            raise InstallError("Candidate identity changed during copying.")
        idle(destination, bundle_id)  # Recheck after potentially lengthy copy.
        replacing = destination.exists()
        if replacing and validate(destination) != bundle_id:
            raise InstallError("Installed app changed during preparation.")
        journal = transaction / "transaction.json"
        journal.write_text(json.dumps({"destination": str(destination), "bundle_id": bundle_id,
            "previous_existed": replacing, "state": "prepared",
            "recovery": "Inspect both signed bundles before recovery. Never delete this directory blindly."}, indent=2))
        with journal.open("rb") as stream:
            os.fsync(stream.fileno())
        # From here retain the recovery directory on every exception/interruption.
        # SWAP leaves both complete bundles present even if the process is killed.
        keep_transaction = True
        rename(staged, destination, exchange=replacing)
        try:
            if validate(destination) != bundle_id:
                raise InstallError("Installed identity mismatch.")
            journal.write_text(json.dumps({"destination": str(destination), "bundle_id": bundle_id,
                "previous_existed": replacing, "state": "installed",
                "previous_bundle": str(staged) if replacing else None}, indent=2))
        except Exception as error:
            try:
                rename(staged, destination, exchange=True) if replacing else rename(destination, staged)
            except Exception as rollback_error:
                raise InstallError(f"Verification and rollback failed. Preserve {transaction} for recovery.") from rollback_error
            raise InstallError(f"Verification failed; previous installation restored. Evidence: {transaction}") from error
        return {"installed": str(destination), "previous_bundle": str(staged) if replacing else None,
                "record": str(journal)}
    finally:
        if transaction is not None and not keep_transaction:
            shutil.rmtree(transaction)
        # Never unlink a lock inode: waiters must all use the same file.
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--destination", type=Path, required=True,
                        help="Explicit existing-parent path ending in Droplet.app")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This installer requires macOS.")
    try:
        print(json.dumps(install(args.candidate, args.destination), indent=2))
    except (InstallError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Installation stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
