---
# stretto-native-macos-9e3v
title: Diagnose and fix channel scrolling responsiveness
status: completed
type: bug
priority: normal
created_at: 2026-10-13T00:28:07Z
updated_at: 2026-10-13T00:44:34Z
---

Investigated channel scrolling with 29 items and a large library. Running-app samples showed repeated full-library membership scans and native popup-menu updates inside song-row rendering. Lazy layout limited row creation but did not eliminate per-row work.\n\nImplemented an ID index rebuilt on library changes, playback-selection-only row observation, deduplicated playing/loading publications, one lazy child per track/divider, and native menus built only when opened. Existing row actions, playlist menus, offline validation and right-click/channel actions remain available. Added isolated AppModel dependency construction for hosted regressions without touching user storage or authentication.\n\nThe same 30-row hosted scrolling workload over 2,000 library songs and 80 playlists, with position updates, measured maximum synchronous layout about 60 ms before and 20 ms after. This is not a display-frame or perceptual smoothness guarantee. Menu-handler/laziness, playback-update, channel-race, queue and media regressions passed (18 tests, two opt-in live tests skipped), and final scrolling checks passed under the 50 ms budget. Packaged/signature-verified arm64+x86_64 and verified the updated app restarted as PID 34512 with its synced library restored. Computer-use tools became unavailable before further manual channel/menu interaction; no claim of that extra UI check. Updated media documentation.