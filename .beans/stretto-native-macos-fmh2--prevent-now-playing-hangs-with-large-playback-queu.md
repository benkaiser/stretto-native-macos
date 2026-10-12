---
# stretto-native-macos-fmh2
title: Prevent Now Playing hangs with large playback queues
status: completed
type: bug
priority: normal
created_at: 2026-10-12T11:55:10Z
updated_at: 2026-10-12T22:19:21Z
---

Replace eager rendering of the entire queue with a bounded lazy scrolling list. Preserve queue playback and channel actions; verify a 2,000-song queue and rebuild the signed universal app.

Replaced eager queue layout with a bounded ScrollView/LazyVStack. Hosted 2,000-song regression layout measured about 45-75 ms, below the two-second threshold. Included in the signed universal build.