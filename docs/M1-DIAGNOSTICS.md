# M1: observation-only diagnostics

## Baseline audit

Checked main at `2f91cb19a8da216c2aa2d286f95f34cd6a50a05a` on 2026-10-21 JST. No open PR, additional remote branch or repository AGENTS.md was found. The existing installed/live suite returned exit 0 with 40 PASS lines before changes. Development uses `codex/m1-diagnostics-settings` in an isolated worktree; the installed main app has not been replaced.

Existing strengths: browser-only allowlist, foreground/recent-foreground protection, minimum age/working set/observed idle time, maximum three targets, consecutive pressure checks, cooldowns, denied-target backoff, local logs and singleton GUI. `policy.json` is unchanged.

Gaps found: pressure is judged from available RAM only; idle CPU is a heuristic; there is no post-trim reuse/response evaluation; candidate identity includes start time during observation but native trim still opens a PID without a same-handle identity check; candidate collection and UI-state writes both run at 5-second cadence. The PID control gap is documented for M2, not claimed fixed here.

## What M1 changes

`DiagnosticsEngine.cs` supplies a read-only source interface, test clock and sampler, and a single background worker. The worker owns native handles, serializes collection, caches one immutable JSON snapshot, and logs once per configured interval (default 60 seconds). No quota, priority or working-set modification API exists in this collector. Native source creation/PDH setup happens on the worker, not the UI thread. Shutdown signals the worker without blocking UI exit; tests can explicitly wait for disposal.

`Diagnostics.ps1` exposes configuration/start/read helpers. `MemoryWatch.ps1` retains its decision/selection logic and optionally adds a reference to a diagnostic sample to a monitor log entry. It never reads diagnostic pressure to choose an action. A diagnostic startup, read, parse or log failure cannot relax any existing protection. The GUI isolates invalid diagnostic snapshots and continues using the original monitor.

The main palette picker moved into a settings dialog opened with a native 8-bit settings icon. Settings has a read-only diagnostics tab. Five palettes, cat, tray, pin controls and manual cleanup remain. UI-state file writes are capped at one per 60 seconds, rather than every 5 seconds; candidate observations still run at the original cadence to avoid weakening foreground/idle protection. Hidden panels skip label/bar rendering. Diagnostic collection/logging is off the UI thread, but legacy candidate work remains on it pending M4.

## Schema and units

`data/diagnostics.jsonl` is a new stream: `Schema=ram-neko.diagnostics`, `Version=1`, `ObservationOnly=true`, `Sequence`, UTC timestamp, configured interval, actual monotonic elapsed seconds, collection duration, process collection status and bounded process array. Every scalar metric has `Value`, `Unit`, `Source`, `Status`, `Reason`.

| Metric | API/source | Unit and interpretation |
| --- | --- | --- |
| `physical.total_bytes`, `physical.available_bytes` | GlobalMemoryStatusEx | Bytes, instantaneous physical-memory snapshot |
| `commit.used_bytes`, `commit.limit_bytes`, `commit.peak_bytes` | GetPerformanceInfo | Commit pages multiplied by native page size with overflow checking; bytes, not resident RAM |
| `memory.os_low` | CreateMemoryResourceNotification + QueryMemoryResourceNotification | Boolean OS low-memory indication; independent of our old threshold |
| `cpu.system_percent` | GetSystemTimes deltas | 0–100%, kernel includes idle; subtract idle from kernel+user. More than one processor group is marked unavailable rather than labeled whole-system CPU |
| `paging.total_faults_per_second` | PDH Memory/Page Faults/sec | Total soft + hard page faults, events/s |
| `paging.read_operations_per_second` | PDH Memory/Page Reads/sec | Disk read operations to resolve hard faults, events/s; NOT a count of hard faults |
| `paging.input_pages_per_second` | PDH Memory/Pages Input/sec | Pages read to resolve hard faults, pages/s; NOT disk-operation or fault count |
| `disk.read_bytes_per_second`, `disk.write_bytes_per_second` | PDH PhysicalDisk(_Total) | Aggregate disk bytes/s; includes unrelated workloads |
| `self.working_set_bytes`, `self.private_bytes` | Process | Resident working set vs private committed bytes of the RAM/NEKO host |
| `self.cpu_percent` | Process.TotalProcessorTime deltas | Interval average normalized by the process-visible logical CPU count |
| `self.io_*_bytes_per_second` | GetProcessIoCounters deltas | Logical process I/O bytes/s, NOT physical disk throughput |
| `physical.available_bytes_per_second`, `commit.used_bytes_per_second` | Sample deltas | Signed bytes/s trends, not predictive pressure or a cleanup trigger |
| `paging.hard_faults_per_second` | Not collected | Explicitly unavailable: exact hard-fault count is not inferred from total faults or paging reads |
| `interaction.app_switch_ms` | Not instrumented | Explicitly unavailable: M1 does not measure application switching or input latency |

`Processes` contains at most five largest accessible working sets, with PID, name, UTC start time, working-set bytes and Private Bytes. This is diagnostic ranking only and never expands the control allowlist. WSL, runners, remote tools, development tools, security software and OS processes are not newly controlled. Processes that exit or deny queries are skipped and counted; the array is marked partial. No command lines, executable paths or credentials are collected.

Missing metrics use JSON null, never fabricated zero. `warmup` means a valid previous sample is needed; `unavailable` covers API/permission/counter failures, resets, invalid intervals and intentionally unmeasured quantities. PDH rates require two samples and use English counter APIs for localized Windows. Invalid numerical values are rejected; rate counters are not capped at 100. System CPU/own-I/O calculations use a monotonic clock; long gaps and counter resets invalidate rate estimates. Values are interval estimates/snapshots, not exact instantaneous CPU or latency measurements.

Legacy monitor records keep their fields and actions. A record with a diagnostic reference adds `LogSchemaVersion=2` and `Diagnostics={Schema,Version,Sequence,Utc,ObservationOnly}`. No full sample is duplicated. Existing viewer/CSV readers ignore added fields. Diagnostics remains a separate JSONL stream; the existing CSV exporter exports monitor/event rows, not the diagnostic metric matrix.

## Configuration and retention

`diagnostics.json`: Version 1, boolean Enabled, ObservationOnly must remain true, integer interval 30–3600 seconds (default 60). Setting Enabled false and restarting disables the new observer only. Invalid configuration disables diagnostics through the GUI's error path, not an unsafe fallback controller.

Diagnostic JSONL uses a strict 5 MiB current file plus one 5 MiB backup. Rotation happens before a record would exceed the limit; oversized records are rejected. The latest snapshot remains accessible if log I/O fails. No extra history is retained in memory. Existing monitor/event retention stays unchanged; the legacy plain UI error log is not converted by this milestone. All runtime data, raw test output and benchmark artifacts remain Git-ignored.

## Verification and short overhead measurement

Backend tests cover unit conversion/overflow, kernel-idle CPU arithmetic, I/O and signed memory deltas, reset/gap/warmup/null semantics, source/configuration failures, bounded process output/logs, worker lifecycle, cached reads and log-write failure isolation. Source and clock interfaces are injectable; background tests use C# test sources, not PowerShell delegates on a thread without a runspace. Existing cleanup tests touch only explicitly created disposable processes (including the test process itself); UI manual-cleanup routing uses synthetic candidates. Additional regression tests show new diagnostic pressure fields cannot trigger cleanup.

GUI checks are off-screen Windows Forms rendering and event tests, separately from native backend tests. They cover the settings icon/dialog, palette persistence, missing-value display, invalid diagnostic JSON isolation, existing tray/pin/manual controls and heartbeat throttling. No new interactive/long-running M1 instance was installed. High-DPI and multi-monitor visual inspection remain unperformed.

Final branch verification: `powershell.exe -NoProfile -NonInteractive -File .\Test-All.ps1 -SkipInstalled` exited 0 with 69 PASS lines. Installed/live checks were run only for the baseline (40 PASS); the review worktree intentionally uses isolated test data and does not replace that installation. `git diff --check` passed. An AST/text comparison against main confirmed unchanged `Get-MemoryDecision`, `Get-IdleObservation`, `Select-TrimCandidateRows`, `Get-TrimCandidates`, `Invoke-WorkingSetTrim` and policy contents. Jev/TypeSafe verified all eight completion claims with zero contradicted, unsupported or review claims, using actual test output and relevant diff hunks. Local raw evidence is retained outside the tracked file allowlist.

One observer microbenchmark on the working Windows PC, 2026-10-21 JST, using `powershell.exe -NoProfile -File .\Measure-Diagnostics.ps1 -Samples 6 -GapMilliseconds 1000`:

| Observation | Result |
| --- | --- |
| Six samples, intentionally accelerated for this test | 5.975 seconds elapsed |
| Collection mean / maximum | 151.390 / 169.915 ms |
| JSONL append mean | 1.287 ms |
| Standalone benchmark host CPU time, including script/serialization/I/O | 453.125 ms |
| Standalone host working set before initialization / after | 87,502,848 / 102,821,888 bytes |
| Mean record size | 3,259 bytes |
| Estimated log volume at production 60-second interval | 195,560 bytes/hour; retention remains size-bounded |
| Last-sample missing metrics | 2, intentionally unmeasured exact hard faults and application-switch latency |
| Total-fault, paging-read and disk-read counters on this host | available after warmup |

This is one short run under live background load, not randomized A/B testing, not steady-state overhead of the complete GUI, and not a responsiveness benchmark. Startup compilation/source initialization is outside the timed sampling loop; the working-set comparison includes initialization/JIT and is not proof of a stable incremental footprint. The status-write cadence is reduced from up to 12 writes/minute to 1; a regression test verifies repeated UI updates do not each write. No end-to-end performance improvement is asserted.

## Outcome boundaries

| Claim | M1 status |
| --- | --- |
| Diagnostic indicators can be obtained | Implemented; mock tests and real read-only API/short worker tests performed |
| Cleanup selection/judgment is more accurate | NOT established; controller unchanged |
| Windows interaction/switching is faster | NOT established; no latency instrumentation or A/B result |
| Sustained real-machine operation of M1 | NOT established; installed main remains the old version |

Rollback: close the review build, or disable diagnostics and restart. Reverting this PR restores the old settings placement and heartbeat behavior. No Windows service, pagefile, WSL, priority or privilege setting is changed.

## Primary references

- [GlobalMemoryStatusEx](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-globalmemorystatusex)
- [GetPerformanceInfo](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-getperformanceinfo), [PERFORMANCE_INFORMATION](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-performance_information)
- [CreateMemoryResourceNotification](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-creatememoryresourcenotification)
- [GetSystemTimes](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemtimes)
- [PdhAddEnglishCounterW](https://learn.microsoft.com/en-us/windows/win32/api/pdh/nf-pdh-pdhaddenglishcounterw), [PdhGetFormattedCounterValue](https://learn.microsoft.com/en-us/windows/win32/api/pdh/nf-pdh-pdhgetformattedcountervalue)
- [GetProcessIoCounters](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getprocessiocounters)
- [RAMMap](https://learn.microsoft.com/en-us/sysinternals/downloads/rammap): physical-memory analysis/snapshots; not evidence that purging improves responsiveness

The Bitsum ProBalance page could not be retrieved in this environment; no unverified Process Lasso implementation behavior was copied into M1.
