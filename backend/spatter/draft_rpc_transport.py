"""One HTTPS RPC in an owned subprocess with budgeted I/O and cleanup."""
from __future__ import annotations

import io
import json
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

RPC_WALL_SECONDS = 20
MAX_RESPONSE_BYTES = 128 * 1024
MAX_REQUEST_BYTES = 8 * 1024 * 1024
RPC_NAMES = frozenset({"sdi_spatter_draft_claim", "sdi_spatter_draft_progress", "sdi_agent_run_heartbeat"})
_RPC_PATHS = frozenset("/rest/v1/rpc/" + name for name in RPC_NAMES)
_CHILD = (str(Path(sys.executable).resolve()), "-I", str(Path(__file__).resolve()))
_DENIED = 2
_UNCONFIRMED = "Daily draft service response was unconfirmed."
_MAX_REAP_SECONDS = 1.0


def reap_reserve(seconds: float) -> float:
    return min(_MAX_REAP_SECONDS, seconds / 10)


def terminate_owned_child(process, deadline: float, *, clock) -> bool:
    """Signal this Popen child and wait only for the remaining cleanup budget."""
    try:
        if process.poll() is not None:
            return True
        process.kill()
    except OSError:
        # The child may have exited between polling and sending the signal.
        pass
    try:
        process.wait(timeout=max(0.0, min(_MAX_REAP_SECONDS, deadline - clock())))
        return True
    except (OSError, subprocess.TimeoutExpired):
        return False


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _post(url: str, secret: str, body: bytes) -> bytes:
    request = urllib.request.Request(url, method="POST", data=body,
                                    headers={"apikey": secret, "Content-Type": "application/json"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    with opener.open(request, timeout=RPC_WALL_SECONDS) as response:
        data = response.read(MAX_RESPONSE_BYTES + 1)
    if len(data) > MAX_RESPONSE_BYTES:
        raise ValueError("Draft service response exceeded its size limit.")
    return data


def _child_main() -> int:
    # No credentials in argv or inherited environment. The caller passes one
    # bounded request over stdin, and the child emits only its bounded body.
    try:
        envelope = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
        if len(envelope) > MAX_REQUEST_BYTES:
            return 1
        request = json.loads(envelope)
        url = urllib.parse.urlsplit(request["url"])
        if (url.scheme != "https" or not url.hostname or url.username is not None or url.password is not None
                or url.port not in (None, 443) or url.path not in _RPC_PATHS or url.query or url.fragment):
            return 1
        data = _post(url.geturl(), request["secret"], request["body"].encode())
        sys.stdout.buffer.write(data)
        return 0
    except urllib.error.HTTPError as error:
        return _DENIED if error.code in (401, 403) else 1
    except (OSError, TypeError, ValueError, KeyError):
        return 1


class BoundedRPCOpener:
    def open(self, request: urllib.request.Request, timeout: float) -> io.BytesIO:
        started = time.monotonic()
        if not timeout > 0:
            raise TimeoutError(_UNCONFIRMED)
        budget = min(RPC_WALL_SECONDS, timeout)
        deadline = started + budget
        io_deadline = deadline - reap_reserve(budget)
        envelope = json.dumps({"url": request.full_url, "secret": request.get_header("Apikey"),
                               "body": request.data.decode()}).encode()
        if len(envelope) > MAX_REQUEST_BYTES:
            raise ValueError("Draft service request exceeded its size limit.")
        process = None
        try:
            if time.monotonic() >= io_deadline:
                raise TimeoutError(_UNCONFIRMED)
            # Popen itself may be delayed by the OS. Recompute the remaining
            # budget after it returns, before sending any request bytes.
            process = subprocess.Popen(_CHILD, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, close_fds=True, env={}, bufsize=0)
            remaining = io_deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(_UNCONFIRMED)
            body, _ = process.communicate(envelope, timeout=remaining)
            if time.monotonic() > deadline:
                raise TimeoutError(_UNCONFIRMED)
        except (TimeoutError, subprocess.TimeoutExpired):
            raise TimeoutError(_UNCONFIRMED) from None
        except OSError:
            raise OSError(_UNCONFIRMED) from None
        finally:
            if process is not None:
                if process.returncode is None:
                    terminate_owned_child(process, deadline, clock=time.monotonic)
                # Unbuffered pipe closure does not flush a blocked write.
                # CPython may retain the request in transient process memory.
                for pipe in (process.stdin, process.stdout):
                    if pipe is not None:
                        try:
                            pipe.close()
                        except OSError:
                            pass
        if process.returncode == _DENIED:
            raise urllib.error.HTTPError(request.full_url, 403, "Authorization refused.", None, None)
        if process.returncode != 0 or len(body) > MAX_RESPONSE_BYTES:
            raise OSError(_UNCONFIRMED)
        return io.BytesIO(body)


if __name__ == "__main__":
    raise SystemExit(_child_main())
