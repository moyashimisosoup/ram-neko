# M3 first increment: post-trim observations, no adaptive control

## Scope and integration

Continues the existing PR and PS 5.1 / C# / WinForms architecture. M1 counters remain observation-only; M2 identity safety and all existing target filters/cooldowns remain. This increment records observations only. There is no success score, automatic candidate exclusion, priority change, new target class or control-policy adjustment.

When resident UI diagnostics are enabled, `Invoke-MemoryWatch` receives an optional observer. A successful identity-verified trim returns a receipt containing snapshots immediately before and after EmptyWorkingSet, taken on the same verified control handle. Observation failure produces unavailable snapshots and cannot bypass validation or retry a trim. No observer means no extra baseline probes or delayed jobs. Failed trim attempts produce the existing failure/backoff records without follow-up jobs.

The existing foreground-family check runs again synchronously after baseline collection, immediately before the native mutation. This avoids relying on the older pre-probe focus check; query failure also skips. It cannot eliminate the operating-system race after that final check. Baseline snapshots combine several sequential API calls and are not atomic.

Enqueue copies a receipt with JSON serialization (maximum 16 KiB) and bounded metadata work, with no target collection or file I/O on the UI path. It returns `accepted`, `queue_full`, `invalid_receipt`, `stale_receipt`, `duplicate_receipt` or `stopped`; monitor results record the attempt ID and scheduling status. An enqueue failure does not alter trim result or cooldown.

A dedicated event-driven observation worker serializes follow-ups separately from the existing diagnostic worker. It reuses the existing cached diagnostic getter and bounded-log pattern, rather than changing M1 sampling cadence or making the UI timer collect delayed values. It is a separate idle thread so a slow M1 process scan cannot hold up follow-up deadlines. The getter is a direct C# delegate; no PowerShell callback runs on the worker.

## Schedule, identity and bounds

- +30 and +120 seconds are measured from the immediate-after snapshot using Stopwatch monotonic timestamps. Actual elapsed time, UTC and lateness are logged. UTC clock changes do not change scheduling.
- Allowed lateness is 10 seconds. Missing a window (for example sleep/resume) logs `missed_deadline` without substituting a late snapshot. A collection finishing after the window is `collection_finished_late`. A stale/future/malformed source snapshot is `invalid_observation`.
- Every delayed read opens a fresh QUERY_INFORMATION-only process handle (0x0400), compares PID/creation time/name/token session before and after collection, and closes the handle in finally. No SET_QUOTA or EmptyWorkingSet call exists on the delayed path. The control handle is never retained across the wait.
- Exit, restart/PID reuse, denied access or failed identity query is an unavailable snapshot with `target_exited_identity_mismatch_or_api_unavailable`. It is never labelled memory rebound. Later phases can still collect if identity is valid then.
- Maximum 12 pending attempts, two delayed stages each. Completed jobs release all history. Duplicate pending IDs, receipts more than five seconds old, oversized or malformed inputs are rejected.
- Worker shutdown stops new acceptance and attempts cancellation records with `observer_stopped`. UI close waits at most one second for flushing. Hard termination, hung API/I/O, or power loss may leave incomplete attempts; pending jobs are not restored across application restarts.
- `post-trim.jsonl` rotates before exceeding 5 MiB, with one backup of at most 5 MiB. Oversized rows are rejected. Logging failures are exposed through `LastError`/the diagnostics tab; no indefinite retry or unbounded queue is created. Existing monitor and diagnostics limits still apply independently.

## Schema and units

Each JSONL row has `Schema=ram-neko.post-trim`, `Version=1`, `ObservationOnly=true`, attempt ID, immutable target identity, `Phase` (`before`, `after`, `30s`, `120s`), planned offset, actual elapsed seconds, lateness seconds, UTC, status/reason, snapshot, changes and diagnostic context.

`Snapshot.Bytes` is a nullable dictionary; missing values are null, never zero substitutes. `Status` is ok/partial/unavailable. Snapshot fields and APIs:

| Fields | Units / source |
| --- | --- |
| target/self `working_set_bytes`, `private_bytes` | bytes; [GetProcessMemoryInfo / PROCESS_MEMORY_COUNTERS_EX](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters_ex) |
| target/self `logical_read_bytes_total`, `logical_write_bytes_total` | cumulative bytes; [GetProcessIoCounters](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getprocessiocounters); logical process I/O, not physical disk traffic |
| `physical.available_bytes` | bytes; GlobalMemoryStatusEx |
| `commit.used_bytes`, `commit.limit_bytes` | bytes; GetPerformanceInfo pages multiplied by page size with checked arithmetic |
| `SelfCpuSeconds` | cumulative CPU seconds from GetProcessTimes for the entire RAM / NEKO process (all threads), not observer-only CPU percentage |
| `DurationMs` | native snapshot collection milliseconds; excludes identity-query, serialization and log time |

`Changes` contains signed working-set delta from before, signed rebound from after, available-memory delta, commit delta (all bytes), cumulative logical read/write bytes since after (counter decreases become null), and cumulative own CPU seconds since after. These are observations, not attributable effects or evidence of faster interaction. Shared pages, unrelated system activity, and observer activity may affect them. No exact hard-fault count or application-switch latency is inferred.

Unsigned byte counters are subtracted as integers before conversion to double, preserving a small delta even above 2^53 cumulative bytes. Differences up to 2^53 bytes are represented exactly; larger differences have floating-point precision. Rebound is null for the before phase. Before-phase elapsed seconds are negative because the common origin is the after snapshot.

`DiagnosticContext` selects existing M1 paging/disk/system-CPU metrics, retaining their values/units/status and source UTC. Its age is relative to the phase timestamp. It is always labelled `cached`, `stale` (over 90 seconds), `future_context` (source later than phase), or `unavailable`. It does not replace native stage measurements or represent the exact +30/+120 interval. Configured M1 intervals longer than 90 seconds therefore commonly produce stale context. Before/after context is read when logging, so it can be later than a baseline; this is explicitly labelled. Diagnostic-native failures remain missing.

## Tests and verification boundaries

Portable suite adds fake-clock scheduling, no-early execution, missed/slow collection, invalid data, partial/missing measurements, identity mismatch, bounded/duplicate/stopped queue, shutdown cancellation, writer failure and strict rotation tests. Native sampling is read-only on the disposable test host. Integration tests bind the actual diagnostic cache getter and verify observer scheduling failure cannot cause a trim retry or bypass cooldown. Existing GUI checks remain off-screen rendering/event smoke tests.

The existing M1 overflow assertion was also corrected: Windows PowerShell 5.1 requires `[uint64]`, not `[ulong]`, and the catch now specifically requires OverflowException. Previously an unrelated type-resolution error could satisfy that assertion.

`Test-PostTrimRealtime.ps1` is an optional roughly 120-second integration test. It explicitly trims only its own disposable PowerShell test host, observes it at both real deadlines, checks native identity, and records timings. It is separate from the fast portable suite, cannot establish browser responsiveness, and is not evidence of long-term resident deployment. Actual command output and the independent completion audit are recorded in the PR.

Unperformed: user-app responsiveness A/B/C trials, significant-pressure workloads, sustained deployment, high-DPI/multi-monitor visual checks, full resident CPU/I/O profiling and causal benefit assessment. Next work is collecting representative traces and evaluating pressure shadow decisions; adaptive controls remain disabled pending comparative evidence.

Before/after probes run synchronously on the existing action path and add latency to that action (up to three targets); they are not claimed to be free of UI cost. Follow-up collection and all new log writes run on the worker. Native API calls have no hard timeout. The timing pilot on the disposable host is not a bound under pressure or a full resident overhead benchmark.

Rollback: revert this observation increment to the M2 checkpoint. Disabling diagnostics also prevents resident follow-up scheduling; standalone calls without an observer retain the prior path. No changes to services, pagefile, WSL, privilege settings, installed task or live application are required.
