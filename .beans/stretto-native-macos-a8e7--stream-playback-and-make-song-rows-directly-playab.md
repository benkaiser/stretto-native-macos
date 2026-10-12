---
# stretto-native-macos-a8e7
title: Stream playback and make song rows directly playable
status: completed
type: feature
priority: normal
created_at: 2026-10-12T10:20:16Z
updated_at: 2026-10-12T11:08:46Z
---

Implemented single-transfer, original-byte streaming through bundled audio-only libmpv/Core Audio instead of whole-track download and AAC conversion. Artwork/title/metadata activate rows; current-track activation resumes; playing thumbnails show a static waveform.

## Checklist
- [x] Progressive WebM/Opus and MP3 HLS playback before the full transfer completes
- [x] Original-byte completed-listen caches and explicit offline pinning without re-fetching
- [x] Cancellation, seek exclusion, early EOF/network errors, account isolation, and pinned-preserving quota eviction
- [x] Consistent library/search/queue/download activation and live pin-state observation
- [x] Native regression suite and muted live YouTube streaming/seek/original-format offline reuse
- [x] Universal Developer-ID-signed app, portable bundled frameworks, both-architecture decoder execution, and matching licenses/source/build provenance
- [x] Documentation updated; previous app preserved; notarization remains deliberately pending