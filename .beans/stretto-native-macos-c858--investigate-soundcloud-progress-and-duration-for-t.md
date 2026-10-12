---
# stretto-native-macos-c858
title: Investigate SoundCloud progress and duration for the reported long mix
status: completed
type: bug
priority: normal
created_at: 2026-10-12T12:02:15Z
updated_at: 2026-10-12T22:19:21Z
---

Investigate https://soundcloud.com/shortroundd/hiddenforestpodcast-shortround against native SoundCloud source resolution, streaming and decoder duration/progress handling. Determine whether the issue is native duration estimation, stream delivery or requires an audio-server change.

Reproduced full-track duration of 3714.502 seconds being replaced by the growing MP3 decoder's roughly 7-35 second read-ahead estimate. Playback time itself advanced normally. Fresh source duration is now retained for streaming MP3 progress and macOS controls. Verified real-time decoding, seeking and near-end natural EOF; no audio-server change was needed.