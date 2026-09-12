"""Bounded, redacted evidence for one failed CI addmedia; never retries it."""
import dataclasses
import hashlib
import json
import os
import pathlib
import re
import selectors
import stat
import struct
import subprocess
import time
import uuid
import zlib

DIAGNOSTIC_SECONDS = 30.0
TEXT_BYTES = 128 * 1024
SCREENSHOT_BYTES = 2 * 1024 * 1024
EVIDENCE_BYTES = SCREENSHOT_BYTES + 96 * 1024
_TERMS = ('timeout', 'timed out', 'connection', 'xpc', 'database', 'sqlite',
          'locked', 'memory', 'bootstrap', 'unavailable', 'permission', 'denied')
_SERVICES = {'com.apple.assetsd', 'com.apple.photolibraryd', 'com.apple.photoanalysisd'}


class Evidence:
    """Only new fixed-name files in the captured existing CI output directory."""
    def __init__(self, udid, output):
        if os.environ.get('GITHUB_ACTIONS') != 'true':
            raise ValueError('Ephemeral CI runner required')
        if str(uuid.UUID(udid)).lower() != udid.lower():
            raise ValueError('Complete explicit simulator UUID required')
        self.udid = udid
        output = pathlib.Path(output)
        initial = output.lstat()
        if not stat.S_ISDIR(initial.st_mode):
            raise ValueError('Existing nonsymlink evidence directory required')
        self.path = output.resolve()
        runner = pathlib.Path(os.environ['RUNNER_TEMP']).resolve()
        if self.path == runner or not self.path.is_relative_to(runner):
            raise ValueError('Use an isolated runner-temp evidence directory')
        self.fd = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.identity = os.fstat(self.fd)
        self.written = 0
        try:
            if (initial.st_dev, initial.st_ino) != (self.identity.st_dev, self.identity.st_ino):
                raise ValueError('Evidence directory changed')
            self.check()
        except BaseException:
            self.close()
            raise

    def check(self):
        current = self.path.lstat()
        if not stat.S_ISDIR(current.st_mode) or (current.st_dev, current.st_ino) != (self.identity.st_dev, self.identity.st_ino):
            raise ValueError('Evidence directory changed; foreign paths preserved')

    def write(self, name, data):
        allowed = {'SDI-generated-image-fixture.png', 'image-seed-start.json',
                   'image-seed-command.json', 'image-seed-diagnostics.json',
                   'image-seed-setup.png', 'image-fixture.json'}
        if name not in allowed or len(data) > EVIDENCE_BYTES - self.written:
            raise ValueError('Evidence name or total byte budget exceeded')
        self.check()
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.fd)
        try:
            info = os.fstat(fd)
            with os.fdopen(fd, 'wb', closefd=False) as stream:
                stream.write(data)
            after = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
            self.check()
            if (info.st_dev, info.st_ino) != (after.st_dev, after.st_ino) or after.st_nlink != 1:
                raise ValueError('Evidence file changed; foreign paths preserved')
            self.written += len(data)
        finally:
            os.close(fd)

    def json(self, name, value):
        self.write(name, (json.dumps(value, indent=2, sort_keys=True) + '\n').encode())

    def close(self):
        if getattr(self, 'fd', -1) >= 0:
            os.close(self.fd)
            self.fd = -1


@dataclasses.dataclass
class Result:
    returncode: object
    timed_out: bool
    elapsed: float
    stdout: bytes = b''
    stderr: bytes = b''
    stdout_seen: int = 0
    stderr_seen: int = 0
    reaped: bool = True
    spawn_error: object = None
    capture_incomplete: bool = False


def run_bounded(argv, deadline, stdout_cap=TEXT_BYTES, stderr_cap=TEXT_BYTES, work_deadline=None):
    """Drain two pipes without unbounded buffers; retain only this owned child.

    deadline includes up to one second reserved to kill/reap a timed-out child.
    No shell, process-group kill, persistent PID, retry, or file-output argument.
    """
    started = time.monotonic()
    if deadline <= started:
        return Result(None, True, 0)
    try:
        child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, close_fds=True)
    except OSError as error:
        return Result(None, False, time.monotonic() - started, spawn_error=type(error).__name__)
    streams = {'stdout': bytearray(), 'stderr': bytearray()}
    seen = {'stdout': 0, 'stderr': 0}
    caps = {'stdout': stdout_cap, 'stderr': stderr_cap}
    selector = selectors.DefaultSelector()
    timed_out = False
    exit_drain_deadline = None
    capture_incomplete = False
    # For short per-command diagnostic slices reserve at most 10% for reaping.
    reserve = min(1.0, max(0.01, (deadline - started) * 0.1))
    work_deadline = min(work_deadline, deadline) if work_deadline is not None else deadline - reserve
    try:
        for name in streams:
            pipe = getattr(child, name)
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, name)
        while selector.get_map() or child.poll() is None:
            # A descendant can inherit pipes after the actual command exits.
            # Capture must not turn its successful exit into a false timeout.
            if child.poll() is not None and exit_drain_deadline is None:
                exit_drain_deadline = min(work_deadline, time.monotonic() + 0.05)
            if exit_drain_deadline is not None and time.monotonic() >= exit_drain_deadline:
                capture_incomplete = bool(selector.get_map())
                break
            remaining = work_deadline - time.monotonic()
            if remaining <= 0:
                timed_out = child.poll() is None
                capture_incomplete = bool(selector.get_map())
                break
            for key, _ in selector.select(min(remaining, 0.05)):
                try:
                    chunk = os.read(key.fileobj.fileno(), 4096)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                name = key.data
                seen[name] += len(chunk)
                keep = max(0, caps[name] - len(streams[name]))
                streams[name].extend(chunk[:keep])
        if child.poll() is None:
            child.kill()
        reaped = True
        try:
            child.wait(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            reaped = False
        return Result(child.returncode, timed_out, time.monotonic() - started,
                      bytes(streams['stdout']), bytes(streams['stderr']),
                      seen['stdout'], seen['stderr'], reaped, capture_incomplete=capture_incomplete)
    finally:
        selector.close()
        child.stdout.close()
        child.stderr.close()
        # Exceptions during collection must not leave a still-running owned
        # command. Any reap uses only the caller's remaining deadline.
        if child.poll() is None:
            child.kill()
            try:
                child.wait(timeout=max(0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                pass


def text_projection(data):
    """Irreversible redaction: never persist message bodies, paths or tokens."""
    text = data.decode('utf-8', errors='replace').lower()
    return {'present': bool(data), 'categories': {word: min(999, text.count(word)) for word in _TERMS if word in text},
            'numericErrorCodes': sorted(set(re.findall(r'(?:code|osstatus)\s*[=:]\s*(-?\d{1,10})\b', text)))[:16]}


def result_projection(result, binary_stdout=False):
    report = {'returnCode': result.returncode, 'timedOut': result.timed_out,
            'elapsedSeconds': round(result.elapsed, 6), 'ownedChildReaped': result.reaped,
            'spawnErrorClass': result.spawn_error,
            'pipeCaptureIncomplete': result.capture_incomplete,
            'stdoutBytesObserved': result.stdout_seen, 'stderrBytesObserved': result.stderr_seen,
            'stdoutTruncated': result.stdout_seen > len(result.stdout),
            'stderrTruncated': result.stderr_seen > len(result.stderr),
            'stderr': text_projection(result.stderr)}
    if not binary_stdout:
        report['stdout'] = text_projection(result.stdout)
    return report


def valid_png(data):
    if not data.startswith(b'\x89PNG\r\n\x1a\n') or len(data) > SCREENSHOT_BYTES:
        return None
    offset = 8
    dimensions = None
    for _ in range(2048):
        if offset + 12 > len(data):
            return None
        size = struct.unpack('>I', data[offset:offset + 4])[0]
        if size > len(data) - offset - 12:
            return None
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + size]
        crc = struct.unpack('>I', data[offset + 8 + size:offset + 12 + size])[0]
        if zlib.crc32(kind + payload) != crc:
            return None
        if offset == 8:
            if kind != b'IHDR' or size != 13:
                return None
            width, height = struct.unpack('>II', payload[:8])
            if not (0 < width <= 8192 and 0 < height <= 8192 and width * height <= 20_000_000):
                return None
            dimensions = [width, height]
        offset += 12 + size
        if kind == b'IEND':
            return dimensions if size == 0 and offset == len(data) else None
    return None


def collect_failure(evidence, udid, original_stage):
    """One shared 30-second post-failure budget; all commands are read-only."""
    if udid.lower() != evidence.udid.lower():
        raise ValueError('Diagnostic target must match the verified evidence target')
    started = time.monotonic()
    deadline = started + DIAGNOSTIC_SECONDS
    report = {'simulatorUDID': udid, 'failedStage': original_stage,
              'budgetSeconds': DIAGNOSTIC_SECONDS, 'steps': [],
              'redaction': 'Only allowlisted service labels, numeric state and error categories retained. Raw messages, paths, environment, process lists and tokens discarded.',
              'screenshotScope': 'Ephemeral CI setup display only; private diagnostic evidence, not product gallery or native journey verification.'}
    predicate = '(process == "assetsd" OR process == "photolibraryd") AND (logType == "error" OR logType == "fault")'
    commands = [
        ('photos-service-state', ['xcrun', 'simctl', 'spawn', udid, 'launchctl', 'list'], 7, TEXT_BYTES),
        ('photos-recent-errors', ['xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--last', '2m', '--style', 'ndjson', '--predicate', predicate], 9, TEXT_BYTES),
        ('setup-display', ['xcrun', 'simctl', 'io', udid, 'screenshot', '--type=png', '-'], 10, SCREENSHOT_BYTES),
    ]
    for stage, command, maximum, cap in commands:
        evidence.check()
        # Reserve the last second for the bounded final report; never begin a
        # command without enough remaining shared budget.
        remaining = deadline - time.monotonic() - 1
        if remaining <= 0:
            report['steps'].append({'stage': stage, 'notRun': 'shared deadline exhausted'})
            continue
        result = run_bounded(command, min(deadline - 1, time.monotonic() + maximum), stdout_cap=cap)
        entry = {'stage': stage, **result_projection(result, binary_stdout=stage == 'setup-display')}
        if stage == 'photos-service-state':
            states = []
            for line in result.stdout.decode('utf-8', errors='replace').splitlines():
                match = re.fullmatch(r'\s*(-|\d{1,10})\s+(-?\d{1,10})\s+(\S+)\s*', line)
                if match and match[3] in _SERVICES:
                    states.append({'service': match[3], 'running': match[1] != '-', 'lastExitStatus': int(match[2])})
            entry['allowlistedServices'] = states[:3]
        elif stage == 'setup-display':
            # Binary stdout is never scanned as text or written when partial.
            dims = valid_png(result.stdout) if result.returncode == 0 and not result.timed_out and result.stdout_seen == len(result.stdout) else None
            if dims:
                evidence.write('image-seed-setup.png', result.stdout)
                entry['screenshot'] = {'file': 'image-seed-setup.png', 'dimensions': dims,
                                       'bytes': len(result.stdout), 'sha256': hashlib.sha256(result.stdout).hexdigest(),
                                       'validation': 'Bounded PNG chunk CRC/structure; not a decoded pixel or UI assertion'}
            else:
                entry['screenshot'] = {'unavailable': 'No complete successful bounded PNG'}
        report['steps'].append(entry)
    report['elapsedSeconds'] = round(time.monotonic() - started, 6)
    report['deadlineExhausted'] = time.monotonic() >= deadline
    report['rawCaptureByteCapPerTextStream'] = TEXT_BYTES
    report['screenshotByteCap'] = SCREENSHOT_BYTES
    report['totalEvidenceByteCap'] = EVIDENCE_BYTES
    evidence.json('image-seed-diagnostics.json', report)
    return report
