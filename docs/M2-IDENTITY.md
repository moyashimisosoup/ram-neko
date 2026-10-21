# M2 first increment: same-handle identity safety

Checkpoint: this document describes the M2 identity increment at `5dff729bebbff4e26cd5785428d50f8f7a55b77d`. The subsequent [M3 observation increment](M3-OBSERVATION.md) adds same-handle baseline snapshots and read-only delayed measurements; adaptive decisions remain disabled.

Scope: strengthen the existing trim operation, without enabling adaptive pressure scoring, new target classes or priority changes. This increment continues PR #1 on its existing branch; M1 remains observation-only. Main and the live installation are not replaced.

## Implementation

`Get-TrimCandidates` captures a C# immutable `CandidateIdentity` with PID, UTC creation ticks (100 ns units), process basename and session. It uses the same start-time snapshot for idle-history key and age. PID reuse therefore starts a new idle window. The existing candidate gates, foreground/recent-family protection, pressure decision, cooldowns, cap and policy values remain in force.

`Invoke-WorkingSetTrim` now requires the identity; PID-only calls cannot authorize a trim. The wrapper rejects non-allowlisted names and other sessions. `TrimGuard.Execute` opens once with the previous `0x0500` process access mask (QUERY_INFORMATION | SET_QUOTA), validates identity, and passes that exact handle to EmptyWorkingSet. It does not reopen a PID after validation. Process and token handles close in finally blocks, including failures.

Read-only identity APIs:

| API | Check |
| --- | --- |
| [GetProcessId](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocessid) | PID from the opened process handle |
| [GetProcessTimes](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes) | Creation FILETIME converted to UTC ticks; running-process exit FILETIME is undefined and is ignored |
| [GetExitCodeProcess](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getexitcodeprocess) | Reject known terminated processes; an exit code of 259 is ambiguous, but a late exit cannot redirect the fixed control handle to another process |
| [QueryFullProcessImageNameW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-queryfullprocessimagenamew) | Compare executable basename, case insensitive; full path is temporary and never logged |
| [OpenProcessToken](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocesstoken), [GetTokenInformation](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-gettokeninformation) | TOKEN_QUERY only, TokenSessionId compared with selected session; no token or privilege modification |

Missing identity, lookup failure, mismatch, exit or denied access throws and skips the mutation. The existing monitor catch logs the failure and applies target backoff. Attempt results add `SelectedStartUtcTicks` and `SelectedSessionId`; all existing log fields remain. Existing UI may omit these additional fields from its compact view/export.

## Validation

Baseline: Windows PowerShell 5.1 `Test-All.ps1 -SkipInstalled`, exit 0, 69 PASS lines. Added `Test-TrimSafety.ps1` tests immutable capture, matching/same-handle success, PID reuse, PID/name/session mismatch, missing data, open denial, zero handle, read/exit/trim errors and cleanup, wrapper restrictions and fresh idle history. Native identity lookup is read-only on the explicitly owned test process. Real EmptyWorkingSet checks remain limited to that disposable test host and its explicitly spawned helper; browser operations in integration tests are mocked.

The full suite also exercises failure logging/backoff and creation/session log fields. GUI rendering/event smoke checks are distinct from backend tests. No new installation, sustained run, high-DPI/multi-monitor inspection, browser performance test or responsiveness comparison is claimed. Final command/results and independent completion audit are recorded in the PR.

## Limits and next work

This prevents the verified handle from targeting a different process after PID reuse; it does not prove that an idle browser's pages are disposable or improve Windows response time. It does not authenticate an executable's signature/path; the basename allowlist is unchanged. Token queries may reject more sandboxed browser processes; those are skipped without elevation. Foreground state can still change after the existing immediate focus check; the future action-time protection design must address that independently. The existing post-trim working-set refresh is an observation, not proof of speed or guaranteed same-handle measurement; M3 must match creation time again.

Next: bounded +30/+120-second observation jobs with identity validation and missing-deadline records, then pressure shadow scoring using measured data. No new automatic controller should be enabled until comparative responsiveness and background-stability measurements justify it.

Rollback: revert this increment as one commit to the M1 checkpoint; no service, WSL, pagefile, scheduled task or installed process changes are involved. Reverting removes the extra identity protection, so prefer disabling cleanup while investigating a safety issue.
