---
# stretto-native-macos-oosv
title: Build SwiftUI and AppKit application shell
status: in-progress
type: feature
priority: normal
created_at: 2026-10-12T03:08:48Z
updated_at: 2026-10-12T03:41:26Z
parent: stretto-native-macos-8ckj
blocking:
    - stretto-native-macos-f25v
    - stretto-native-macos-5z4m
---

Implement adaptive #44bbff design tokens with accessible text variants, native sidebar/window chrome, routing, settings and VoiceOver on macOS 14. UI implemented in Views.swift and Branding.swift; parent owns application/window integration and commands.

## Checklist
- [x] Implement native SwiftUI shell and branding
- [ ] Verify integrated build and native window behavior with parent entry point
- [ ] Update directly related documentation