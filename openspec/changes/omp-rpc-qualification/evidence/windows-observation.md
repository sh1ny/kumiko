# Windows OMP RPC observations

Observed on Windows x64 `10.0.26300` with OMP `19.2.1` and the packaged Kumiko release built from `c50fa6a80f388785b945f1fcf9ad4ce7f2650954`. The desktop and host matched the binaries bound to both approvals. The gaming guard was clear before building and before the live runs.

| Attempt (UTC) | Model | Root prompts | Child assignments | Audit |
|---|---|---:|---:|---|
| `2026-11-27T14:42:56.963082Z` | `openai-codex/gpt-5.5` | 0 | 0 | FAIL |
| `2026-11-27T14:54:35.368611Z` | `openai-codex/gpt-6.2-sol` | 7 | 1 | FAIL |

The first attempt stopped at readiness: OMP rejected the model. The separately approved second attempt completed eleven required checks. The owner confirmed that the initial reply could be scrolled back to its beginning and that the child reply appeared in the read-only pane. The child's native journal confirmed its model. Delegated Stop was not exercised.

During the second attempt a computer-use invocation of Windows title-bar Close ended the desktop before an affected-work warning or a Cancel choice was observed. A permission was still pending before the invocation. Retained handles showed desktop and host exit 0 and A's OMP exit 1. The host recorded no coordinated quit. The held write was absent, the unit ledger was empty, and A's original session record and native journal header remained. This was not evidence of an orderly save. The cause was not established. No reopen or eighth prompt followed; explicit Continue and root history replay remain unverified. No result was retried or combined across attempts.

`mise run audit` exited 0 and printed `FAIL` for each valid negative OMP record. The results are in [`docs/qualification/omp-rpc-windows.json`](../../../../docs/qualification/omp-rpc-windows.json); the shared-contract comparison is in [`docs/qualification/omp-rpc.md`](../../../../docs/qualification/omp-rpc.md). All owned processes settled; both runtime scratch profiles and workspaces were removed. No live session was added to CI or the default test run.
