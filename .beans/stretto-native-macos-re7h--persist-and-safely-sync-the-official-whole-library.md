---
# stretto-native-macos-re7h
title: Persist and safely sync the official whole-library format
status: completed
type: feature
priority: normal
created_at: 2026-10-12T03:08:48Z
updated_at: 2026-10-12T04:08:55Z
parent: stretto-native-macos-8ckj
blocking:
    - stretto-native-macos-wzvx
    - stretto-native-macos-eits
---

Implemented lossless known/unknown library JSON fields, preservation of unsupported Audius entries, account-isolated SQLite snapshots and pending-change journals, periodic/activation/debounced version-based sync, and explicit local/server resolution with both snapshots backed up. Concurrent edits during in-flight sync remain pending; account authentication and sync transitions are serialized. Native fixtures verify first-login protection, conflicts, version races, account isolation, persistence and ordering. Actual production API upload/download and stale-version rejection verified with disposable account and cleanup.