# Review completion and scope

This completes the requested M1 observation foundation and the additional reviewed implementation increments on PR #1. The original request explicitly limited M2–M4 to design at first; the branch additionally implements M2 identity safety, M3 follow-ups, and limited UI/log hardening. It does not claim all adaptive M2 or all M4 work is implemented. No new adaptive controller is enabled. Main, the installed application, Windows services, WSL, pagefile and user-app priorities are unchanged by this work.

## Delivered behavior

- M1: native physical/commit/OS-pressure diagnostics, CPU/paging/disk context, own-resource measurements, nullable versioned schema, serialized worker/cache and bounded diagnostic logs. Missing exact hard faults and application latency remain explicit.
- Existing tactile 8bit cat/palette/tray/pin/manual UI retained; palette is under the pixel settings icon. Heartbeat throttling and hidden painting reduction preserve the five-second candidate observation cadence.
- M2 safety: immutable candidate identity, same-handle validation/mutation, fail-closed lookup, current/recent-family protection and existing filters/cooldowns/backoff. Foreground callback now captures the selected name explicitly and is tested after the factory returns.
- M3: same-handle before/after receipt, read-only revalidated +30/+120-second jobs, timestamps/lateness/missing reasons, bounded history/retention, explicit cached paging context and signed rebound/I/O deltas. No automatic success score or exclusion is enabled.
- Follow-up results now appear in settings, the log viewer and CSV, including missing reasons. Latest-result UI reads use a small cached JSON string, even if writing its log fails; they never recollect the target or reread its log. Legacy decisions add an optional DecisionReason (no_pressure, waiting_pressure_confirmation, automatic_cooldown, confirmed_pressure, manual_requested, observation_only, no_eligible_candidates); focus skips add an explicit result reason without changing eligibility.
- UI errors rotate within the default 5 MiB plus one backup; oversized messages are summarized. Oversized legacy files reject further appends. Failed UI writes disable the manual button for that tick, show degraded logging and cannot interrupt error isolation or final resource disposal.

## Verification

The PR records final exact commands, counts, Jev results, commit and raw measurement summaries. Portable tests cover the existing backend, native disposable-only trims, diagnostics, follow-up scheduling and off-screen GUI events/rendering. New assertions cover captured foreground delegates, observation-only manual requests, cached-result reads, view/export of signed/missing follow-ups, error-log bounds and UI file-write failure isolation. Japanese PS5.1 test source uses a UTF-8 BOM.

The optional `Test-PostTrimRealtime.ps1` runs about 120 seconds and trims only its own disposable host. The optional `Test-UIProfile.ps1 -Seconds 60` runs a separate hidden WinForms instance with a unique mutex and data directory, no tray icon, real diagnostic/candidate reads and ObserveOnly=true. Manual cleanup is also blocked. It reports elapsed time, whole-process CPU, working set, logical I/O, write counts and zero cleanup attempts. It closes itself after the selected duration (10–300 seconds). It neither takes over the installed process nor changes task registration.

Profile CPU is normalized by logical processor count; working set is bytes, not freed RAM. Logical I/O is whole-process cumulative-delta traffic, not physical disk activity. Startup compilation/control initialization is excluded from the timed window; initial lifetime log/heartbeat counts can include startup. Native probe and shutdown cost is not isolated. A sandbox without a foreground window produces an explicit incomplete-profile failure; desktop validation requires the normal interactive host. Profile output/data is local and ignored by Git.

## Status separation

| Claim | Status |
| --- | --- |
| Diagnostic counters can be obtained | Implemented and tested |
| Process identity protection | Implemented and tested |
| Follow-up observation and reason display | Implemented and tested |
| Better adaptive cleanup judgment | Not established; existing decision policy retained |
| Faster Windows interaction | Not established; no latency/causal A/B result |
| Sustained resident deployment | Not established; only bounded isolated tests/profile |

## Remaining design, not incomplete M1 code

Pressure shadow scoring, bounded reuse-based ranking, automatic exclusion/stop rules and optional priority experiments remain in [M2–M4 design](M2-M4-PLAN.md). Representative recordings and opt-in responsiveness/background-stability A/B/C trials must precede enabling them. CPU inactivity alone does not identify disposable memory; a working-set decrease does not prove speed.

Candidate collection and existing state/event writes still run on the UI action thread. Before/after probes add synchronous cost. Large CSV export remains synchronous. Moving these to workers requires fresh foreground/history/identity protection and is deliberately not bundled into M1. High-DPI/mixed-monitor, Explorer restart, sleep/resume and long-running pressure workloads still require dedicated verification. No unsupported platform validation is reported as passed.

Review/deployment boundary: changes are committed to the existing feature branch and PR, without merge or public release. Review the compatibility/schema and overhead measurements before replacing the live installation. Reverting this final UI/log increment returns to the prior M3 checkpoint; earlier milestone reports describe their pinned checkpoints.
