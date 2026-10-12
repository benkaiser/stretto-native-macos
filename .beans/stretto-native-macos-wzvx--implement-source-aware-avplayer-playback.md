---
# stretto-native-macos-wzvx
title: Implement source-aware AVPlayer playback
status: in-progress
type: feature
priority: normal
created_at: 2026-10-12T03:08:48Z
updated_at: 2026-10-12T04:07:37Z
parent: stretto-native-macos-8ckj
blocking:
    - stretto-native-macos-th0z
    - stretto-native-macos-53ab
    - stretto-native-macos-1r4z
---

Native YouTube/SoundCloud discovery and shared StrettoMedia playback contracts implemented. Unsupported/Audius records remain synced.

## Checklist
- [x] Implement native source/playback contracts
- [x] Verify direct-source renderer/pagination fixtures and integrated app compile
- [x] Verify muted actual deployed YouTube AVPlayer readiness/time/pause/10-second seek/offline
- [x] Verify actual direct YouTube song/playlist search, Innertube continuation and small public playlist import
- [x] Verify actual direct SoundCloud search and HTTPS stream resolution
- [ ] Verify live SoundCloud AVPlayer/HLS offline export and sleep/wake/network-loss paths
- [x] Document contracts, packaged converter and measured results in docs/native-media.md

MediaTests 4/4 passed in 9.49s: universal minimal helper local-only WebM->AAC/M4A; startup 5.633s, duration 213.020s, 5,241,186 bytes, seek/resume passed; offline startup 0.616s and removal verified. LiveSourceTests actual client requests (no fixture/proxy): YouTube 19 songs, 11 playlists, direct search continuation 15 songs; SoundCloud 50 public songs and resolved public track s_2251589318 on cf-media.sndcdn.com. Those two tests passed in 20.408s; isolated known-small public YouTube playlist PL9tY0BWXOZFv0S8GR8DDGQrQtdk0EE3_- imported 13 songs and passed in 5.825s. Files stable and no Swift build/test active; parent may begin universal packaging.