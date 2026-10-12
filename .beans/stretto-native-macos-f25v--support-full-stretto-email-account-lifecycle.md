---
# stretto-native-macos-f25v
title: Support full Stretto email account lifecycle
status: completed
type: feature
priority: normal
created_at: 2026-10-12T03:08:48Z
updated_at: 2026-10-12T04:08:55Z
parent: stretto-native-macos-8ckj
blocking:
    - stretto-native-macos-re7h
    - stretto-native-macos-1r4z
---

Implemented native email login, registration, session checking/restoration, logout, password-recovery and reset completion against official API. Session cookies persist via Keychain; passwords are never stored. Fixtures cover JSON/HTTP failures, and an isolated disposable production account passed registration, native cookie restoration, versioned download/upload/conflict detection, logout and subsequent login. All fixture account/library documents removed after verification. Recovery UI accepts the official emailed reset link/token; SMTP delivery was not triggered by automated checks.