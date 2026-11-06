"""Pinned unprivileged bwrap adapter. Importing performs no IO or execution.

Operator stages the exact root-owned minimal tree and separately proves its
AppArmor/userns compatibility. This module never installs or elevates privileges.
"""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import errno
import fcntl
import hashlib
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time

from .store import IntakeError, MAX_BYTES


# Changes to these tools require a new reviewed source build and explicit pins.
PINS = {
    "bwrap": "4bd3bdaf5b2d204288e2379a26cda0f5662c37426652782d7df3052a0d9d1d98",
    "rootfs/bin/ffprobe": "00583ef1f0d42e9f05ce4741b1a38e099fd02f149d8dba3011cebc77a3620c32",
    "rootfs/bin/ffmpeg": "8bfa627cf19ed057a8a4b05d0830b04ae206f7c5d18141cd7749e6467f53c3a0",
    "rootfs/lib/x86_64-linux-gnu/libc.so.6": "3a15d66867d83762c7f2f1e37359cb8f6c5743edb369c65285cb0b1c4f7498bf",
    "rootfs/lib/x86_64-linux-gnu/libm.so.6": "fce00b6f25f459cf4ae0b7fae4257909a1a8a86f9149e7c029a5d617baf1ccd0",
    "rootfs/lib64/ld-linux-x86-64.so.2": "c20a2dc8917c755f02b94049356320fe1f62ac7d9f8994731f807d9df39302da",
}
EXECUTABLES = {"bwrap", "rootfs/bin/ffprobe", "rootfs/bin/ffmpeg", "rootfs/lib64/ld-linux-x86-64.so.2"}
HOST_PINS = {
    "/usr/lib/x86_64-linux-gnu/libcap.so.2.66": "6ac6abc86ac891c6e13486470e26f1d939f47fda9e6b5d5508a7f5ec881adc84",
    "/usr/lib/x86_64-linux-gnu/libc.so.6": PINS["rootfs/lib/x86_64-linux-gnu/libc.so.6"],
    "/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2": PINS["rootfs/lib64/ld-linux-x86-64.so.2"],
}
COMMON = ("-v", "error", "-max_alloc", "67108864", "-protocol_whitelist", "file",
          "-format_whitelist", "mov", "-probesize", "5242880", "-analyzeduration", "5000000")
ENTRIES = ("format=format_name,duration,size:stream=index,codec_type,codec_name,"
           "width,height,channels,sample_rate,duration,avg_frame_rate")
# Only these standard Linux temporary ancestors may be shared and writable;
# their root ownership and sticky bit are checked, never inferred from the name.
STICKY_TEMP_ANCESTORS = frozenset((Path("/tmp"), Path("/var/tmp")))


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


@dataclass(frozen=True)
class ValidationReceipt:
    size: int
    sha256: str


@dataclass(frozen=True)
class Snapshot:
    fd: int
    path: Path
    size: int
    sha256: str
    snapshot_identity: tuple
    source_identity: tuple


def _kill_group(process):
    # Always kill the group, including when its first process already exited.
    # With bwrap --die-with-parent, namespace init death also ends escaped groups.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def _capture(arguments, input_fd, timeout, output_limit):
    """Drain both pipes with fixed buffers and a wall deadline; retain no logs."""
    process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, close_fds=True, pass_fds=(input_fd,), start_new_session=True,
        env={"LANG": "C", "LC_ALL": "C"})
    deadline = time.monotonic() + timeout
    output = bytearray()
    diagnostics = bytearray()
    try:
        with selectors.DefaultSelector() as selector:
            for pipe, data, limit in ((process.stdout, output, output_limit), (process.stderr, diagnostics, 65536)):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ, (data, limit))
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise IntakeError("Media exceeds validation time or diagnostic limits.", 422)
                for key, _ in selector.select(min(remaining, 0.1)):
                    data, limit = key.data
                    block = os.read(key.fd, min(65536, limit - len(data) + 1))
                    if not block:
                        selector.unregister(key.fileobj)
                    else:
                        data.extend(block)
                        if len(data) > limit:
                            raise IntakeError("Media exceeds validation time or diagnostic limits.", 422)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise IntakeError("Media exceeds validation time or diagnostic limits.", 422)
            try:
                code = process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                raise IntakeError("Media exceeds validation time or diagnostic limits.", 422) from None
        if code:
            raise IntakeError("The rendered video could not be decoded. Export a new MP4.", 422)
        return bytes(output)
    finally:
        _kill_group(process)
        process.stdout.close()
        process.stderr.close()


class DecoderSandbox:
    def __init__(self, root: Path, snapshot_directory: Path):
        if sys.platform != "linux" or os.getuid() == 0 or os.geteuid() == 0:
            raise ValueError("Decoder requires a dedicated nonroot Linux worker.")
        self.root = Path(root)
        self.snapshot_directory = Path(snapshot_directory)
        self._slot = threading.BoundedSemaphore(1)
        if not self.root.is_absolute() or not self.snapshot_directory.is_absolute():
            raise ValueError("Decoder paths must be absolute.")
        self._check_tools()
        self._check_snapshot_directory()

    def _check_tools(self):
        root = self.root
        for directory in (root, *root.parents):
            info = directory.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
                raise ValueError("Decoder tree requires immutable root-owned directories.")
            if any(n in os.listxattr(directory) for n in ("system.posix_acl_access", "system.posix_acl_default")):
                raise ValueError("Decoder access must not be broadened by ACLs.")
        # The profile-permitted executable must not become an all-account userns
        # exception. Operator gives only the dedicated worker group access.
        if root.stat().st_mode & 0o007:
            raise ValueError("Decoder prefix must restrict access to its worker group.")
        # bwrap itself starts outside the child rootfs; pin that small runtime
        # dependency closure too. An operator package upgrade requires new review.
        for name, digest in HOST_PINS.items():
            path = Path(name)
            for parent in path.parents:
                info = parent.lstat()
                if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
                    raise ValueError("Unsafe host decoder dependency directory.")
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
            with os.fdopen(fd, "rb") as source:
                info = os.fstat(source.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022 or
                        not 1 <= info.st_size <= 8 * 1024**2 or
                        hashlib.sha256(source.read(8 * 1024**2 + 1)).hexdigest() != digest):
                    raise ValueError("Host decoder dependency pin mismatch.")
        for name, digest in PINS.items():
            path = root / name
            for directory in path.parents:
                if directory == root.parent:
                    break
                info = directory.lstat()
                if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
                    raise ValueError("Unsafe decoder directory.")
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
            with os.fdopen(fd, "rb") as source:
                info = os.fstat(source.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1 or
                        info.st_mode & 0o6022 or not 1 <= info.st_size <= 8 * 1024**2):
                    raise ValueError("Unsafe decoder tool or library.")
                if name in EXECUTABLES and (not os.access(path, os.X_OK) or info.st_mode & 0o007):
                    raise ValueError("Decoder executable must restrict access to its worker group.")
                if hashlib.sha256(source.read(8 * 1024**2 + 1)).hexdigest() != digest:
                    raise ValueError("Decoder binary pin mismatch.")
            try:
                os.getxattr(path, "security.capability", follow_symlinks=False)
            except OSError as error:
                if error.errno not in (errno.ENODATA, errno.ENOTSUP):
                    raise
            else:
                raise ValueError("Decoder tools must not carry file capabilities.")
        expected = {n.removeprefix("rootfs/") for n in PINS if n.startswith("rootfs/")}
        allowed_directories = {str(q) for n in expected for q in Path(n).parents if str(q) != "."}
        actual = set()
        for path in (root / "rootfs").rglob("*"):
            info = path.lstat()
            name = str(path.relative_to(root / "rootfs"))
            if stat.S_ISREG(info.st_mode):
                actual.add(name)
            elif not stat.S_ISDIR(info.st_mode) or name not in allowed_directories:
                raise ValueError("Unexpected decoder rootfs entry.")
        if actual != expected:
            raise ValueError("Decoder rootfs must contain only the pinned tools and libraries.")

    def _check_snapshot_directory(self):
        worker_uid = os.getuid()
        for directory in (self.snapshot_directory, *self.snapshot_directory.parents):
            info = directory.lstat()
            if not stat.S_ISDIR(info.st_mode):
                raise ValueError("Snapshot directory must not traverse symbolic links or nondirectories.")
            sticky_temp = (directory in STICKY_TEMP_ANCESTORS and info.st_uid == 0 and
                           info.st_mode & stat.S_ISVTX)
            if info.st_uid not in (0, worker_uid) or (info.st_mode & 0o022 and not sticky_temp):
                raise ValueError("Snapshot directory ancestors must be trusted and not shared-writable.")
        info = self.snapshot_directory.lstat()
        if info.st_uid != worker_uid or info.st_mode & 0o077:
            raise ValueError("Snapshot directory must be private and worker-owned.")

    @contextmanager
    def snapshot(self, path: Path):
        if not self._slot.acquire(blocking=False):
            raise IntakeError("Media validation is busy. Retry later.", 503)
        source = writer = read_only = None
        temporary = None
        try:
            self._check_snapshot_directory()
            source = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
            before = os.fstat(source)
            if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or
                    before.st_nlink != 1 or before.st_mode & 0o077 or not 1 <= before.st_size <= MAX_BYTES):
                raise IntakeError("Invalid rendered file.", 422)
            free = os.statvfs(self.snapshot_directory)
            if free.f_bavail * free.f_frsize < before.st_size + 16 * 1024**2:
                raise IntakeError("Media validation storage is unavailable.", 503)
            writer, temporary = tempfile.mkstemp(prefix="decode-", dir=self.snapshot_directory)
            os.fchmod(writer, 0o600)
            digest = hashlib.sha256()
            copied = 0
            deadline = time.monotonic() + 60
            while True:
                if time.monotonic() >= deadline:
                    raise IntakeError("Media snapshot exceeds validation time limits.", 422)
                block = os.read(source, min(1024**2, before.st_size - copied + 1))
                if not block:
                    break
                copied += len(block)
                if copied > before.st_size:
                    raise IntakeError("Render changed during validation.", 409)
                digest.update(block)
                view = memoryview(block)
                while view:
                    view = view[os.write(writer, view):]
            if copied != before.st_size or _identity(os.fstat(source)) != _identity(before):
                raise IntakeError("Render changed during validation.", 409)
            os.fsync(writer)
            os.fchmod(writer, 0o400)
            read_only = os.open(temporary, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            if _identity(os.fstat(read_only)) != _identity(os.fstat(writer)):
                raise IntakeError("Invalid validation snapshot.", 503)
            os.close(writer)
            writer = None
            # bwrap0.13.1 bind-fd resolves a realpath, so retain this random name
            # in a worker-only0700 directory until BOTH phases finish. No writable
            # descriptor remains; child sees only the read-only mounted file.
            if fcntl.fcntl(read_only, fcntl.F_GETFL) & os.O_ACCMODE != os.O_RDONLY:
                raise IntakeError("Invalid validation snapshot.", 503)
            snapshot = Snapshot(read_only, Path(temporary), copied, digest.hexdigest(),
                                _identity(os.fstat(read_only)), _identity(before))
            yield snapshot
            self._verify_snapshot(snapshot)
            if _identity(os.fstat(source)) != _identity(before) or _identity(Path(path).lstat()) != _identity(before):
                raise IntakeError("Render changed during validation.", 409)
        finally:
            try:
                for fd in (source, writer, read_only):
                    if fd is not None:
                        os.close(fd)
                if temporary is not None:
                    os.unlink(temporary)
            finally:
                self._slot.release()

    @staticmethod
    def _verify_snapshot(snapshot):
        info = os.fstat(snapshot.fd)
        named = snapshot.path.lstat()
        if (not stat.S_ISREG(named.st_mode) or info.st_nlink != 1 or named.st_nlink != 1 or
                info.st_uid != os.getuid() or named.st_uid != os.getuid() or
                info.st_mode & 0o777 != 0o400 or named.st_mode & 0o777 != 0o400 or
                _identity(info) != snapshot.snapshot_identity or _identity(named) != snapshot.snapshot_identity or
                fcntl.fcntl(snapshot.fd, fcntl.F_GETFL) & os.O_ACCMODE != os.O_RDONLY):
            raise IntakeError("Validation snapshot changed.", 409)
        digest = hashlib.sha256()
        position = 0
        deadline = time.monotonic() + 60
        while position < snapshot.size:
            if time.monotonic() >= deadline:
                raise IntakeError("Media snapshot exceeds validation time limits.", 422)
            block = os.pread(snapshot.fd, min(1024**2, snapshot.size - position), position)
            if not block:
                raise IntakeError("Validation snapshot changed.", 409)
            position += len(block)
            digest.update(block)
        if digest.hexdigest() != snapshot.sha256 or _identity(os.fstat(snapshot.fd)) != snapshot.snapshot_identity:
            raise IntakeError("Validation snapshot changed.", 409)

    def _argv(self, snapshot, mode):
        if mode not in ("probe", "decode"):
            raise ValueError("Unknown decoder operation.")
        root = self.root
        a = [str(root / "bwrap"), "--unshare-user", "--unshare-pid", "--unshare-net", "--unshare-ipc",
            "--unshare-uts", "--unshare-cgroup", "--disable-userns", "--assert-userns-disabled",
            "--uid", "65534", "--gid", "65534", "--cap-drop", "ALL", "--new-session", "--die-with-parent",
            "--clearenv", "--setenv", "LANG", "C", "--setenv", "LC_ALL", "C", "--setenv", "TMPDIR", "/tmp",
            "--ro-bind", str(root / "rootfs/bin"), "/bin", "--ro-bind", str(root / "rootfs/lib"), "/lib",
            "--ro-bind", str(root / "rootfs/lib64"), "/lib64", "--proc", "/proc", "--dev", "/dev",
            "--dir", "/input", "--ro-bind-fd", str(snapshot.fd), "/input/media.mp4",
            "--size", "16777216", "--tmpfs", "/tmp", "--chmod", "1777", "/tmp",
            "--remount-ro", "/proc", "--remount-ro", "/dev/pts", "--remount-ro", "/dev", "--remount-ro", "/",
            "--chdir", "/tmp", "--"]
        if mode == "probe":
            return a + ["/bin/ffprobe", *COMMON, "-show_entries", ENTRIES, "-of", "json", "/input/media.mp4"]
        return a + ["/bin/ffmpeg", "-nostdin", *COMMON, "-xerror", "-err_detect", "explode", "-threads", "2",
            "-i", "/input/media.mp4", "-map", "0:v:0", "-map", "0:a:0?", "-threads", "2",
            "-filter_threads", "1", "-f", "null", "-"]

    def probe(self, snapshot):
        self._verify_snapshot(snapshot)
        self._check_tools()
        os.lseek(snapshot.fd, 0, os.SEEK_SET)
        return _capture(self._argv(snapshot, "probe"), snapshot.fd, 30, 65536)

    def decode(self, snapshot, timeout):
        self._verify_snapshot(snapshot)
        self._check_tools()
        os.lseek(snapshot.fd, 0, os.SEEK_SET)
        return _capture(self._argv(snapshot, "decode"), snapshot.fd, timeout, 1024)
