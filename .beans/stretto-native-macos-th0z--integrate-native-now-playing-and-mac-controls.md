---
# stretto-native-macos-th0z
title: Integrate native Now Playing and Mac controls
status: in-progress
type: feature
priority: normal
created_at: 2026-10-12T03:08:48Z
updated_at: 2026-10-12T03:43:29Z
parent: stretto-native-macos-8ckj
blocking:
    - stretto-native-macos-a3zl
---

PlaybackController publishes MPNowPlayingInfoCenter metadata/artwork/rate/position and registers MPRemoteCommandCenter play/pause/toggle/next/previous/seconds-seek handlers with lifecycle cleanup. Native UI agent owns menu-bar/mini-player UI.

## Checklist
- [x] Implement media-center metadata and command targets
- [ ] Verify actual Control Center/hardware keys/output routing on supported Mac
- [x] Document system media integration and manual verification needs in docs/native-media.md

Swift parser checks passed. Do not mark complete without actual system-control verification.