# M2–M4 design: measurement before adaptation

These are designs, not enabled features. M1 is observation-only. All future control changes require separate review, tests, measured benefit and an explicit opt-in. No additional target class, priority adjustment or memory-policy intervention is enabled by this PR.

## M2: independently reviewable decisions

1. **Identity first:** introduce an immutable candidate identity (PID, UTC creation time, name/session). Open a handle with only the rights already needed for trimming, obtain creation time from that same handle with GetProcessTimes, and verify expected identity before any mutation. Never re-open by PID after validation. Mock PID reuse, process exit, access denial, session/name mismatch and failures; every mismatch skips. The existing start-time observation key alone is insufficient.
2. **Separate observation and decision:** maintain small bounded per-identity histories. Use fresh, quality-tagged measurements only; unavailable/stale diagnostics must never authorize stronger control. Retain browser-only allowlist, foreground/recent-foreground family protection, age/idle/size gates, process count cap, cooldowns and backoff. Add an explicit explanation code for every skip or attempt. Do not rank by working-set size alone.
3. **Pressure shadow scoring:** compare OS low-memory signal, available RAM trend, commit ratio/trend, paging reads/input pages, system CPU and aggregate disk I/O. Initially log a shadow decision alongside the legacy decision without changing actions. Paging reads are not exact hard-fault counts, and global disk traffic cannot be attributed to a target. Define thresholds only after representative recordings, not from one machine's free-RAM snapshot.
4. **Reuse/effect feedback:** track rebound and observed I/O after past attempts. Exclude repeatedly ineffective or suspiciously harmful targets with bounded time-based expiry. Require matched creation time and a fresh foreground check at action time. Protect recently used apps for a configurable observation window; CPU inactivity alone remains insufficient to identify disposable memory.
5. **Experimental priorities:** if later justified, place documented CPU/memory-priority experiments in an independent module, disabled by default with no automatic enablement. Capture original values, validate identity, restore on rollback/expiry and handle process exit. Never broaden to OS/security/WSL/runner/remote/development processes by default.

Acceptance: deterministic tests for identity/races/missing data, replayed shadow traces showing safe behavior, and an M3 protocol with no measured regression. A low-memory signal is a reason to observe more carefully, not blanket permission to purge.

## M3: effect measurement and stop conditions

Create bounded per-attempt evaluation jobs using the existing observer scheduler; never block a UI thread or retain native control handles for 120 seconds. Record a reference/identity before, immediately after, around +30 seconds and +120 seconds. Timestamp actual measurements and missed deadlines. Revalidate identity; a restarted process is not a rebound of the old one.

Record available physical memory, commit, target working set/private bytes, paging reads/input pages, aggregate disk I/O, own CPU/memory/log cost and foreground transitions. Working-set decreases and free-RAM increases are observations, not proof of speed. Missing exact hard faults and application latency remain unavailable until separately instrumented.

For actual responsiveness, define repeatable opt-in tasks on disposable or user-approved test apps: foreground switch to first confirmed paint/ready state, restore to ready state, and input-to-confirmed-response. Specify the timing source and completion criterion before measurement. A plain SendMessage duration, foreground change event or total page-fault count alone is not a user-latency measurement. Any ETW/WPR instrumentation or extra privilege needs separate approval and overhead accounting; never enable it silently.

### A/B/C protocol

- A: manager stopped. B: current main with legacy controller. C1: M1 observer only with legacy controller. C2: future adaptive control only after its opt-in review.
- Use the same app versions, tabs/workload, power plan and scenario; record exceptions, foreground activity and major competing load. Keep cold-start and warm-restore scenarios separate.
- Counterbalance/randomize run order. Repeat at least ten valid scenario runs per condition as an initial pilot; use more if variance is large. Do not discard outliers without a predeclared reason.
- Compare switch/restore/input latency distributions (median and tail), paging/disk activity, background task completion/errors, observer overhead and memory rebound. Report uncertainty and all missing/incomplete runs.
- Pause/disable a control if p95 responsiveness or background stability regresses beyond an agreed practical tolerance, paging/I/O increases without latency benefit, rebound repeatedly erases the effect, or identity/quality checks fail. Do not choose a tolerance after seeing results.
- A beneficial result must repeat across sessions and survive review before automatic adjustment is enabled. Stop/no-op is a valid outcome. Never claim C2 works from C1's counters.

## M4: resource-aware UI and operation

Keep the cat, five palettes, tray, fixed modes and tactile controls. M1 moves palette choice to a pixel settings icon, provides a diagnostic tab, caps heartbeat writes and skips hidden label/bar painting. It deliberately keeps existing candidate-observation cadence to preserve safety.

Next steps, separately tested:

1. Move candidate collection to a serialized worker with an immutable cache; capture foreground events continuously and clear a candidate's idle history whenever its family was active. Require freshness and identity revalidation on the UI-independent action path. This is prerequisite to slowing candidate polling safely.
2. Move monitor/event/status/error file I/O to a bounded writer queue; define backpressure/drop policy and observable write errors. Rotate the legacy plain UI-error log as well. Keep CSV exports off the UI thread for large retained logs and avoid re-reading all files for each display tick.
3. Display the reason for attempting/skipping, sample age/quality, and before/after/rebound information without equating byte changes to speed. Show degraded observation explicitly and keep manual safety limits.
4. Verify settings/panel placement at 100/125/150/200% DPI, mixed-DPI monitors, negative-coordinate desktops, taskbar edge changes, sleep/resume, Explorer restart and monitor removal. Keep restore/exit accessible from the tray.
5. Bound histories, pending evaluation jobs, queues and disk retention; test saturation, permissions, malformed data, low disk space and shutdown. Measure manager CPU, allocations, working set, logical I/O and UI response during both hidden and visible steady state.

M4 acceptance requires measured reduction in manager overhead with unchanged safety coverage and no lost foreground protection. No high-DPI, long-run, restart/sleep or end-to-end speed result is claimed by M1.
