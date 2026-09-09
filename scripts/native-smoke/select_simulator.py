#!/usr/bin/env python3
"""Create one CI phone on the selected SDK's installed runtime; never reset."""
import argparse
import json
import os
import pathlib
import re
import stat
import time
import uuid

from seed_diagnostics import run_bounded, result_projection

MARKER = 'sdi-fresh-simulator.json'
UPLOAD = 'sdi-fresh-simulator-upload.json'
MARKER_CAP = 16 * 1024
INVENTORY_CAP = 2 * 1024 * 1024
TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro'
TOTAL_SECONDS = 100


def identity(info):
    return info.st_dev, info.st_ino


def context():
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        raise ValueError('Fresh simulator creation is restricted to ephemeral CI')
    run = os.environ.get('GITHUB_RUN_ID', '')
    attempt = os.environ.get('GITHUB_RUN_ATTEMPT', '')
    job = os.environ.get('GITHUB_JOB', '')
    if not re.fullmatch(r'[0-9]{1,20}', run) or not re.fullmatch(r'[0-9]{1,8}', attempt) or not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', job):
        raise ValueError('Explicit CI run, attempt and job identity required')
    raw = pathlib.Path(os.environ['RUNNER_TEMP'])
    if not raw.is_absolute() or not stat.S_ISDIR(raw.lstat().st_mode):
        raise ValueError('Existing nonsymlink runner-temp directory required')
    root = raw.resolve(strict=True)
    if any(c in str(root) for c in '\r\n'):
        raise ValueError('Invalid runner-temp path')
    return root, {'runID': run, 'runAttempt': attempt, 'job': job}


class Marker:
    """One exclusive, descriptor-bound per-job reservation, including failures."""
    def __init__(self, root, run):
        self.path = root / MARKER
        self.root = root
        self.root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.root_info = os.fstat(self.root_fd)
        self.fd = -1
        try:
            self.fd = os.open(MARKER, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.root_fd)
            self.info = os.fstat(self.fd)
            self.value = {'version': 1, 'run': run, 'state': 'reserved', 'createAttempted': False,
                          'sourceCommit': None, 'steps': [], 'cleanup': 'Ephemeral CI job teardown; no device erase or delete'}
            self.write()
        except BaseException:
            self.close()
            raise

    def check(self):
        current_root = self.root.lstat()
        current = os.stat(MARKER, dir_fd=self.root_fd, follow_symlinks=False)
        opened = os.fstat(self.fd)
        if not stat.S_ISDIR(current_root.st_mode) or identity(current_root) != identity(self.root_info) or not stat.S_ISREG(current.st_mode) or current.st_nlink != 1 or identity(current) != identity(self.info) or identity(opened) != identity(self.info):
            raise ValueError('Ownership marker changed; foreign paths preserved')

    def write(self):
        self.check()
        data = (json.dumps(self.value, sort_keys=True, indent=2) + '\n').encode()
        if len(data) > MARKER_CAP:
            raise ValueError('Ownership marker byte budget exceeded')
        os.lseek(self.fd, 0, os.SEEK_SET)
        offset = 0
        while offset < len(data):
            count = os.write(self.fd, data[offset:])
            if count <= 0:
                raise OSError('Ownership marker write failed')
            offset += count
        os.ftruncate(self.fd, len(data)); os.fsync(self.fd)
        self.check()

    def close(self):
        if self.fd >= 0:
            os.close(self.fd); self.fd = -1
        if getattr(self, 'root_fd', -1) >= 0:
            os.close(self.root_fd); self.root_fd = -1


def command(argv, stage, marker, deadline, seconds=30, cap=INVENTORY_CAP):
    if time.monotonic() >= deadline:
        raise ValueError('Fresh-device overall deadline exhausted')
    result = run_bounded(argv, min(deadline, time.monotonic() + seconds), stdout_cap=cap, stderr_cap=16 * 1024)
    marker.value['steps'].append({'stage': stage, **result_projection(result)})
    marker.write()
    if result.returncode != 0 or result.timed_out or result.spawn_error or not result.reaped or result.capture_incomplete or result.stdout_seen > cap or result.stderr_seen > 16 * 1024:
        raise ValueError('Bounded ' + stage + ' failed; no retry')
    return result.stdout


def inventory(data):
    value = json.loads(data)
    if not isinstance(value, dict) or not isinstance(value.get('devices'), dict) or not isinstance(value.get('runtimes'), list) or not isinstance(value.get('devicetypes'), list):
        raise ValueError('Expected complete simulator inventory')
    if any(not isinstance(item, dict) for key in ('runtimes', 'devicetypes') for item in value[key]):
        raise ValueError('Malformed simulator runtime or device type')
    if len(value['devices']) > 128 or len(value['runtimes']) > 128 or len(value['devicetypes']) > 1024:
        raise ValueError('Simulator inventory exceeds bounds')
    if any(not isinstance(ds, list) for ds in value['devices'].values()) or sum(len(ds) for ds in value['devices'].values()) > 4096:
        raise ValueError('Simulator devices exceed bounds')
    devices = [(runtime, d) for runtime, ds in value['devices'].items() for d in ds]
    if len(devices) > 4096 or any(not isinstance(d, dict) for _, d in devices):
        raise ValueError('Simulator devices exceed bounds')
    ids = [str(uuid.UUID(d['udid'])).upper() for _, d in devices]
    if len(set(ids)) != len(ids):
        raise ValueError('Simulator identity is ambiguous')
    return value, devices, set(ids)


def version_tuple(value):
    if not isinstance(value, str) or len(value) > 16 or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', value):
        raise ValueError('Expected a complete numeric simulator SDK/runtime version')
    parts = list(map(int, value.split('.')))
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def create_fresh():
    root, run = context()
    marker = Marker(root, run)
    deadline = time.monotonic() + TOTAL_SECONDS
    try:
        sha = command(['git', 'rev-parse', '--verify', 'HEAD'], 'source', marker, deadline, seconds=5, cap=128).decode('ascii').strip()
        if not re.fullmatch(r'[0-9a-f]{40}', sha):
            raise ValueError('Exact source commit required')
        marker.value['sourceCommit'] = sha
        sdk_version = command(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'],
                              'simulator-sdk', marker, deadline, seconds=5, cap=128).decode('ascii').strip()
        selected_sdk = version_tuple(sdk_version)
        marker.value['simulatorSDKVersion'] = sdk_version
        raw = command(['xcrun', 'simctl', 'list', '--json'], 'initial-inventory', marker, deadline)
        initial, devices, old_ids = inventory(raw)
        types = [d for d in initial['devicetypes'] if d.get('identifier') == TYPE and d.get('name') == 'iPhone 16 Pro']
        if len(types) != 1:
            raise ValueError('Installed iPhone16Pro type is unavailable or ambiguous')
        choices = []
        for runtime in initial['runtimes']:
            rid = runtime.get('identifier', '')
            version = runtime.get('version', '')
            if not rid.startswith('com.apple.CoreSimulator.SimRuntime.iOS-') or runtime.get('isAvailable') is not True:
                continue
            try:
                runtime_version = version_tuple(version)
            except ValueError:
                continue
            if runtime_version != selected_sdk:
                continue
            for actual_runtime, device in devices:
                if actual_runtime == rid and device.get('isAvailable') is True and device.get('name') == 'iPhone 16 Pro' and device.get('deviceTypeIdentifier') == TYPE:
                    choices.append((tuple(map(int, version.split('.'))), rid, device))
        if not choices:
            raise ValueError('No available installed iPhone16Pro runtime matching the selected simulator SDK; no fallback or download')
        _, rid, template = sorted(choices, key=lambda c: (c[0], c[1], c[2]['udid']))[-1]
        name = 'SDI-' + run['runID'] + '-' + run['runAttempt']
        if any(d.get('name') == name for _, d in devices):
            raise ValueError('Run-owned simulator name already exists; no duplicate')
        marker.value.update({'state': 'creation-requested', 'createAttempted': True,
                             'template': {'udid': template['udid'], 'name': template['name'], 'runtime': rid, 'deviceType': TYPE},
                             'created': {'name': name, 'runtime': rid, 'deviceType': TYPE, 'udid': None}})
        marker.write()
        response = command(['xcrun', 'simctl', 'create', name, TYPE, rid], 'create', marker, deadline, cap=128).decode('ascii').strip()
        new_id = str(uuid.UUID(response)).upper()
        if response.upper() != new_id or new_id in old_ids:
            raise ValueError('Create did not return a new complete UUID')
        marker.value['created']['udid'] = new_id
        marker.value['state'] = 'created-unverified'; marker.write()
        fresh, new_devices, new_ids = inventory(command(['xcrun', 'simctl', 'list', '--json'], 'verify-inventory', marker, deadline))
        matches = [(r, d) for r, d in new_devices if d['udid'].upper() == new_id]
        if len(matches) != 1 or new_ids - old_ids != {new_id}:
            raise ValueError('Expected exactly one newly-created device')
        actual_runtime, actual = matches[0]
        available_runtime = [r for r in fresh['runtimes'] if r.get('identifier') == rid
                             and r.get('isAvailable') is True and version_tuple(r.get('version')) == selected_sdk]
        if len(available_runtime) != 1 or actual_runtime != rid or actual.get('name') != name or actual.get('deviceTypeIdentifier') != TYPE or actual.get('isAvailable') is not True or actual.get('state') != 'Shutdown':
            raise ValueError('Fresh device identity does not match its verified template')
        marker.value['state'] = 'verified'; marker.write()
        return new_id
    except BaseException as error:
        marker.value['state'] = 'failed'
        marker.value['errorClass'] = type(error).__name__
        try:
            marker.write()
        except BaseException as marker_error:
            raise ValueError('Creation failed and marker ownership changed; preserve all paths') from marker_error
        raise
    finally:
        try:
            publish_receipt(marker)
        finally:
            marker.close()


def publish_receipt(marker):
    """Upload only a new safe projection that this invocation actually owns."""
    output_name = os.environ.get('GITHUB_OUTPUT')
    if not output_name:
        return  # Unit/library callers have no Actions output channel.
    output = pathlib.Path(output_name)
    if not output.is_absolute() or not output.resolve().is_relative_to(marker.root) or not stat.S_ISREG(output.lstat().st_mode):
        raise ValueError('Expected existing runner-temp Actions output file')
    output_info = output.lstat()
    if output_info.st_nlink != 1:
        raise ValueError('Actions output file must have one link')
    marker.check()
    data = (json.dumps(marker.value, sort_keys=True, indent=2) + '\n').encode()
    if len(data) > MARKER_CAP:
        raise ValueError('Setup receipt exceeds budget')
    fd = os.open(UPLOAD, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=marker.root_fd)
    try:
        info = os.fstat(fd)
        with os.fdopen(fd, 'wb', closefd=False) as stream:
            stream.write(data); stream.flush(); os.fsync(fd)
        current = os.stat(UPLOAD, dir_fd=marker.root_fd, follow_symlinks=False)
        marker.check()
        if identity(info) != identity(current) or current.st_nlink != 1:
            raise ValueError('Setup receipt changed; foreign file will not be uploaded')
        output_fd = os.open(output, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
        try:
            opened_output = os.fstat(output_fd)
            current_output = output.lstat()
            if not stat.S_ISREG(opened_output.st_mode) or opened_output.st_nlink != 1 or identity(opened_output) != identity(output_info) or identity(current_output) != identity(output_info):
                raise ValueError('Actions output file changed; foreign file preserved')
            line = ('simulator_setup_path=' + str(marker.root / UPLOAD) + '\n').encode()
            if os.write(output_fd, line) != len(line):
                raise OSError('Actions output write incomplete')
        finally:
            os.close(output_fd)
    finally:
        os.close(fd)


def copy_marker(output, expected_udid, source):
    root, run = context()
    expected_udid = str(uuid.UUID(expected_udid)).upper()
    if not re.fullmatch(r'[0-9a-f]{40}', source):
        raise ValueError('Exact source commit required')
    raw_output = pathlib.Path(output)
    if not stat.S_ISDIR(raw_output.lstat().st_mode):
        raise ValueError('Existing nonsymlink evidence directory required')
    output_info = raw_output.lstat()
    output = raw_output.resolve(strict=True)
    if output == root or not output.is_relative_to(root) or not output.name.startswith('sdi-native-smoke.'):
        raise ValueError('Use the existing isolated native evidence directory')
    fd = os.open(root / MARKER, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > MARKER_CAP:
            raise ValueError('Unsafe ownership marker')
        data = os.read(fd, MARKER_CAP + 1)
        after = os.fstat(fd); path = (root / MARKER).lstat()
        if len(data) > MARKER_CAP or identity(before) != identity(after) or identity(before) != identity(path) or before.st_size != len(data) or after.st_size != len(data) or before.st_mtime_ns != after.st_mtime_ns or before.st_ctime_ns != after.st_ctime_ns:
            raise ValueError('Ownership marker changed while reading')
    finally:
        os.close(fd)
    value = json.loads(data)
    if value.get('version') != 1 or value.get('state') != 'verified' or value.get('run') != run or value.get('sourceCommit') != source or value.get('created', {}).get('udid') != expected_udid:
        raise ValueError('Ownership marker does not match this native test run')
    directory_fd = os.open(output, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        parent_info = os.fstat(directory_fd)
        if identity(parent_info) != identity(output_info) or identity(output.lstat()) != identity(output_info):
            raise ValueError('Evidence directory changed before writing')
        target = os.open('fresh-simulator.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
        try:
            info = os.fstat(target)
            with os.fdopen(target, 'wb', closefd=False) as stream:
                stream.write(data); stream.flush(); os.fsync(target)
            final = os.stat('fresh-simulator.json', dir_fd=directory_fd, follow_symlinks=False)
            if identity(info) != identity(final) or final.st_nlink != 1 or identity(output.lstat()) != identity(parent_info):
                raise ValueError('Evidence destination changed; foreign files preserved')
        finally:
            os.close(target)
    finally:
        os.close(directory_fd)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--copy-marker', type=pathlib.Path)
    parser.add_argument('--expected-udid')
    parser.add_argument('--source')
    args = parser.parse_args()
    if args.copy_marker is not None:
        if args.expected_udid is None or args.source is None:
            raise ValueError('Marker copy needs explicit simulator and source')
        copy_marker(args.copy_marker, args.expected_udid, args.source)
    elif args.expected_udid is not None or args.source is not None:
        raise ValueError('Unexpected selection arguments')
    else:
        print(create_fresh())


if __name__ == '__main__':
    main()
