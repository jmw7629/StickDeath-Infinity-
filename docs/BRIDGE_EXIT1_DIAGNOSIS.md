# Bridge exit-1 diagnosis

## Status

Recovery issues #71, #72, and diagnostic issue #73 were accepted by the JoeOS bridge and then OpenCode exited with code `1` before any PR was created. The existing bridge kept the full stdout/stderr only on the JoeVPS host and posted no sanitized diagnostic excerpt to GitHub. Those local logs are not available through the repository API, so the exact host-side root cause cannot be truthfully asserted from GitHub alone.

The failures share the same externally visible pattern: executor startup succeeds far enough for the bridge to create the worktree and acceptance comment, then the OpenCode process returns `1` before repository changes are pushed.

## Bridge hardening

`bridge/runner.py` now:

- verifies the configured OpenCode executable exists, is executable, and is not the known-incompatible Snap path;
- runs bounded, non-network preflights for `opencode --version` and `opencode run --help` before an issue is accepted;
- detects which `run` flags the installed CLI actually supports and only supplies optional flags such as `--auto` when advertised by that installed version;
- fails early with an actionable sanitized error if required automation flags are missing;
- classifies executor failures into CLI incompatibility, provider/auth/model configuration, prompt/argument, filesystem/worktree/sandbox, runtime/dependency, or unclassified categories;
- posts a bounded sanitized stderr/stdout excerpt on executor failure rather than only an opaque exit code;
- redacts bearer/basic authorization headers, secret-like environment assignments, common token prefixes, JWT-shaped values, and private-key blocks before anything is posted;
- sanitizes bridge-level exception comments as well;
- adds `python3 bridge/runner.py --self-test` using fabricated secrets/errors to exercise the redactor and classifier;
- preserves the existing trusted-author gate, isolated worktrees, safe git/gh wrappers, local full logs, and no-auto-merge policy.

## Checks executed for this patch

Executed off-host against the exact replacement source before commit:

- Python compile: PASS.
- Redaction/classifier self-test with fabricated values: PASS.

Host-specific checks are still required after the VPS control checkout receives this commit:

```bash
python3 -m py_compile bridge/runner.py
python3 bridge/runner.py --self-test
./bridge/runner.py --help >/dev/null
```

Then restart the installed bridge service so the running Python process loads the new code. A subsequent small `[OC]` smoke task will either run normally or publish a sanitized classification/excerpt that identifies the remaining host-side cause without exposing secrets.

## Manual host action still required

The running bridge process does not hot-reload Python code merely because GitHub `main` changed. The JoeVPS control checkout must fast-forward to the merged commit and the bridge service must be restarted before another recovery issue is launched. Until that happens, new `[OC]` issues would still be handled by the old opaque-failure runner.
