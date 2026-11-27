# Focused Windows quit and Continue rerun

The owner separately approved the build and the exact live plan (Ormy item 101, events `e3159` and `e3191`). The gaming guard was clear before the build, live starts and Continue. The run used Windows x64 `10.0.26300`, installed OMP `19.2.1`, and `openai-codex/gpt-6.2-sol` for the parent and one child. It sent three root prompts, with no prompt after reopen.

Packaged Kumiko revision `4dd8c5783b989bd3d5b9da68d76a7501d608d10c`; desktop SHA-256 `9fc5fa3daf9e5d3fa96f0b913ab7cc49142c85bc5709c46ba1939cff4c3a5912`; bundled host SHA-256 `b93ac987e4b000d945cba3de6cb4d3d5a927d254f912ad8875d39ea8724bee18`.

| Focus | Evidence |
|---|---|
| Pane Close | Cancel preserved B's permission and live unit. Confirm closed B, both retained handles exited 0 and A stayed live. Neither scratch workspace received the write. |
| Title-bar quit | The fixed release still had the picker-created `WorkerW`. The title-bar X opened the warning and named A. Cancel preserved its pending permission. Confirm recorded `quit` and all owned handles exited 0. The held write was not made. |
| Reopen | Original parent saved and not running, retained journal and inert restored child. No save warning and no OMP process until explicit Continue. |
| Exact Continue and history | The same host record, native ID, target and journal returned. Both user prompts and ordered root tool results appeared, including the completed child task and failed held write. The owner confirmed seeing the restored history. No new work or replacement journal appeared. The old child pane reported unavailable history. |

The idle continued app quit normally. All owned handles signaled exit 0; no unit or held file remained. The disposable workspaces, profile and native journals were removed.

`mise run audit` exited 0 and printed `FAIL`, `FAIL`, `INCOMPLETE` for the three independent attempts in `docs/qualification/omp-rpc-windows.json`. Close, ordinary quit, exact Continue and root history passed on the fixed release. The remaining unexercised rows and both earlier attempts are retained; no one attempt qualifies the version.
