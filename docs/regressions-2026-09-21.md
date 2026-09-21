# NotchPilot regression pass — 2026-09-21

## Reproduced and fixed

- Four explicit Calculator stages exhausted the old shared 24-step limit just before Equals on the last calculation. The controller now allows up to 24 steps per stage and 72 per task, retaining the 180-second active-work timeout and API budget. The identical live request completed after rebuilding, with the visible final expression `3+4` and result `7`.
- Loop detection accumulated across completed stages and could reject an explicitly requested repeated action. Its history now resets only after a verified stage transition. Regression cases ensure repeated actions within a stuck stage still stop.

- Unreadable Save sheets returned no controls through Cua. Previously the controller spent 104 seconds on an edit/save attempt and $0.01779 before stopping. The new path makes two bounded read-only retries, then gives an actionable error. A retry against the existing unreadable sheet stopped in 1.94 seconds with $0 model cost. This fixes repeated paid observations, not automatic Save As support.
- Native progress now updates for local actions, and the strip has specific messages for unreadable windows and step limits.

## Automated checks

- 100 Python tests pass, including nine new cases for per-stage limits, total limits, legitimate repeated stages, and repeated input within a single stage.
- Native session checks pass.
- Native voice segmentation and 48 kHz to 16 kHz conversion pass.
- Signed app rebuilt with the existing identity; strict signature verification passes.

## Live tests

| Scenario | Result | Worker seconds | Controller cost |
|---|---|---:|---:|
| Three Calculator stages | Verified final `6×7=42` | 25.70 | $0 |
| Four Calculator stages, before fix | Stopped at `3+4` before Equals | 31.88 | $0 |
| Identical four stages, after fix | Verified final `3+4=7` | 35.27 | $0 |
| Create TextEdit document and enter exact text | New Untitled 4 with exact requested content | 14.55 | $0.00544 |
| Replace document text, then Save As | Exact replacement verified; Save sheet unsupported; step limit | 103.95 | $0.01779 |
| Diagnose already-open Save sheet | Empty controls repeatedly observed; deliberately cancelled | 39.24 | $0.00689 |
| Existing Save sheet after fix | Correctly stopped with actionable message, mic active | 1.94 | $0 |
| Two new Chrome tabs | Three tabs became five in the same window; both URLs independently checked | 2.83 | $0 |
| Finder → Calculator → Safari | Completed, final Safari window verified | 17.70 | $0.00492 |
| Repeat 6 × 7 three times | All three stages completed; final `6×7=42` verified | 26.75 | $0 |

Timings are local smoke-test observations, not cross-machine benchmarks; they exclude speech recognition and local interpretation. Microphone remained active after completion and the reproduced failure. Requests were entered through the app's conversation UI.

## Cleanup and limits

Only the two new Chrome test tabs were closed; the original three tabs were preserved. The disposable TextEdit document was saved manually via the test-control tool to a temporary RTF file after the failed app Save As attempt, then closed. This cleanup is not counted as a NotchPilot save success. Private diagnostic tracing was disabled and its temporary output removed. Existing app signing and permission grants were preserved.

Automatic Save As remains unsupported when Cua returns no accessibility controls for an attached sheet. The changes stop clearly and keep voice available; they do not claim the document was saved. Model-driven arbitrary app workflows and physical microphone performance are not fully validated by this pass.
