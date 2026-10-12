---
# stretto-native-macos-53ab
title: Add native offline audio storage and recovery
status: in-progress
type: feature
priority: normal
created_at: 2026-10-12T03:08:48Z
updated_at: 2026-10-12T04:03:33Z
parent: stretto-native-macos-8ckj
blocking:
    - stretto-native-macos-a3zl
---

Implemented account-isolated SHA-256 namespaces, atomic manifest/files, bounded chunked audio transfer, MP3/M4A validation, local WebM conversion, native HLS export and bounded unencrypted SoundCloud MP3-HLS fallback. Limits 300 MB per track / 2 GB per account; cancel/retry/removal and missing-byte checks. Browser downloads are independent.

## Checklist
- [x] Implement offline manager and importable shared media library
- [x] Verify live YouTube download/conversion/offline reuse/removal and local manifest/account isolation recovery
- [ ] Verify in-flight cancellation/network-failure and live SoundCloud/HLS export
- [x] Document measured results and unsupported encrypted/live/fragmented HLS limits

2026-10-12 MediaTests 4/4 pass using universal minimal build/helpers/ffmpeg. Live M4A 5,241,186 bytes / 213.020 seconds. Local-only offline startup 0.616 seconds after source configuration removal; actual file removal verified. Packaged Bundle.main.resourceURL/ffmpeg lookup has priority; parent owns signing/helper LGPL distribution.