---
# stretto-native-macos-2b3u
title: Diagnose lyrics HTTP 503 and provide reliable lookup recovery
status: completed
type: bug
priority: normal
created_at: 2026-10-12T11:57:38Z
updated_at: 2026-10-12T22:19:21Z
---

Inspect actual LRCLIB HTTP responses to distinguish service outage from bot challenges. Implement a tested lyric client with explicit unavailable, challenge, missing and instrumental states, practical matching/recovery, and a browser lookup action; prevent stale requests from changing the current track's lyrics.

Added typed results/errors, conservative metadata-checked fallback, bounded responses, cooldowns, browser search and cancellation/stale-request fencing. Core and state tests passed. Current service probes returned HTTP 200 without a challenge; the historical screenshot's exact 503 cause remains unverified.