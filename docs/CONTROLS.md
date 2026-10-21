# Gadget controls

- **手動整理**: run cleanup on the currently eligible targets. Automatic pressure thresholds are bypassed; candidate restrictions and a minimum 60-second interval remain.
- **一時停止 / 再開**: pause/resume automatic checks. Graphs and manual cleanup remain available.
- **隠す / x**: hide to the cat notification icon. Double-click the icon or use its menu to restore the panel. Exit is in the icon menu.
- **デスクトップに固定**: lock dragging and place the gadget behind ordinary windows using documented Windows Z-order APIs. This is a bottom-layer desktop gadget mode, not wallpaper embedding. Windows+D or other desktop-management commands may still hide it; restore from the cat icon. Click the button again to unlock. The notification icon always remains available.
- **前面に固定**: keep above ordinary application windows. Click again to return to normal. This mode and desktop pinning are mutually exclusive; the selected button stays depressed.
- **設定（8bitアイコン）**: opens the palette/diagnostics dialog. 配色 selects Lavender, Mint, Peach, Sky, or Midnight. Palette, mode and position are stored locally and restored at the next launch. 診断 is read-only, shows units/status and the latest cached post-trim follow-up with reduction/rebound or missing reason. It does not change cleanup decisions or claim speed improvement.
- **ログ**: view recent monitoring, UI-operation and post-trim records. 更新 reloads; CSV保存 exports all retained monitor/event/post-trim rows, including the rotated backup per source. Decision reason codes and missing follow-up reasons are preserved. Retention is size-based, not a fixed number of days. Logs are local and excluded from Git.

The raised case, recessed meter bay and beveled buttons are rendered locally. Buttons depress during a click; pause and pin buttons remain depressed while selected. The cat, header and case can be dragged when desktop pinning is off.

## Local data

`data/monitor.jsonl`: minute samples and manual/automatic cleanup results. `events.jsonl`: startup, pause, mode, palette, visibility and export events. `preferences.json`: palette, mode and position. `ui-status.json`: latest heartbeat. `ui-errors.log`: UI diagnostics. None is included in the source repository.

`post-trim.jsonl`: before/after/+30/+120-second observations. `diagnostics.jsonl`: periodic observation-only counters. Each has a strict 5 MiB limit plus one backup. New UI error records also have a 5 MiB limit plus one backup. An already oversized legacy UI error file is not appended to; archive it before resuming that log. Diagnostic and UI logging failures never bypass trim safety. Large CSV export remains synchronous; background export is a future M4 item.

Candidate memory is a gross working-set total, not guaranteed physical RAM freed. Shared pages may be counted repeatedly. No files are deleted and no target process is terminated.
