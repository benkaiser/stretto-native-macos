# Stretto Native for macOS

A separate native companion to [Stretto official](https://next.kaiserapps.com).
This repository contains a native SwiftUI/AppKit macOS application, its shared
account/library/source implementation, Beans work items, and the interactive
design studio used to approve its direction. macOS 14 or newer is required.

![Stretto for macOS Now Playing](docs/images/now-playing.png)

## Build and run the native app

On another Mac, install Xcode or current Xcode Command Line Tools with Swift,
then clone the repository:

```sh
git clone https://github.com/benkaiser/stretto-native-macos.git
cd stretto-native-macos
ARCHITECTURE=universal scripts/build-app.sh
open build/Stretto.app
```

The universal build runs on Apple Silicon and Intel Macs with macOS 14 or newer.
The first build downloads pinned audio frameworks and their corresponding source
archives. Local builds are ad-hoc signed; no Apple developer account, production
secrets, Node.js, MongoDB, or checkout of the official Stretto server is required.
Sign in to the deployed official service from the app; existing sessions and
local libraries are not copied between Macs. Run `swift test` for native tests.

The packaged app includes the official Stretto icon and WisdomScript wordmark,
adaptive light/dark/system appearance with `#44bbff`, a native sidebar/library,
playlist management, track editing, Now Playing and queue, floating/menu-bar mini
players, media keys/Control Center, downloads, account/sync views and preferences.
Command-K opens search; Command-Shift-M opens the mini player.

`Sources/StrettoCore` contains the lossless library models, session API, SQLite
store, sync engine and source discovery. `Sources/StrettoMedia` contains libmpv,
Now Playing and account-scoped downloads. `Sources/StrettoMac` contains the app,
SwiftUI views, Keychain/system-browser authentication and Spotify import client.
Open `Package.swift` in Xcode to work on the native project.

Sign in with your existing Stretto email/password or **Continue with Google**.
Registration, recovery, reset completion, session restoration and logout use the
official account service. Google uses the system browser and a PKCE-bound
single-use native handoff; passwords are never saved. Native session cookies and
Spotify tokens are stored in Keychain, not preferences or library files.
After Google or Spotify authorization, click **Open Stretto for Mac** in the
browser to complete the handoff. The explicit click avoids Chrome blocking
automatic custom-scheme redirects; the one-time link expires after 90 seconds.

YouTube search includes songs and playlists. Preview/play a remote playlist
without importing it, add individual songs, or import the complete mix. SoundCloud
search/resolution is supported; unavailable premium/encrypted tracks fail visibly.
Choose **View YouTube Channel** from a YouTube song's action/right-click menu or
Now Playing to browse its actual uploader, independent of edited artist metadata.
The native channel browser shows public Videos-tab uploads with **Newest**,
**Most viewed**, and **Oldest** ordering supplied by YouTube across the whole
channel. **Load More** preserves that order without the search's 30-page cap.
View/upload labels are YouTube's display metadata, not fabricated exact counts or
dates. Shorts and live streams have separate tabs in YouTube; the channel's
**YouTube** button opens those in the browser. Playback, add-to-library/playlist,
and offline-download actions work without replacing your search or playlist preview.
Connect Spotify to import accessible playlists by matching tracks to YouTube;
matches are not guaranteed and unmatched tracks are reported. Spotify developer-app
access restrictions still apply. The artist feed uses official followed artists
and suggestions, with release playback resolved to YouTube. Lyrics are fetched
on demand from LRCLIB and can be absent for a track. Exact lookup uses a bounded,
metadata-checked search fallback for genuine misses; service outages, throttling,
ambiguous versions and browser challenges are shown separately from missing lyrics.
**Search LRCLIB in Browser** provides manual recovery. Browser verification does not
automatically authorize the app's separate, cookie-free connection. Changing tracks
or reloading cancels and fences stale lyric requests; `Retry-After` is respected.

Audius playback and remote device presence/control are deliberately omitted.
Existing Audius entries and unknown fields remain intact when syncing.
Library sync runs on activation, after edits, periodically, and on explicit
request. It uses the official whole-library/version protocol. Conflicts require
an explicit choice, with both snapshots backed up locally before resolution.
No automatic force uploads occur.

### Playback and offline audio

WebM/Opus, MP3 and M4A play directly through bundled audio-only libmpv and Core
Audio. WebM does not need AAC conversion or a complete download before playback.
A single Foundation HTTPS transfer feeds an original-byte, growing-file stream
to the decoder; small playback buffers stay in memory and the temporary disk
buffer is capped at 300 MB per track. Seeking ahead waits for those bytes.
SoundCloud prefers progressive MP3/M4A, then unencrypted MP3 HLS whose segments
are joined without re-encoding. AAC-only, encrypted, live and fragmented HLS
are not supported by this audio-default build and fail visibly.
SoundCloud resolution refreshes full-track duration from its API. Growing MP3
streams keep that stable duration rather than replacing it with the decoder's
moving read-ahead estimate, so the seek bar and macOS controls remain accurate.

Only a natural full listen with no seeks becomes a persistent playback cache.
Skipping, stopping, failed transfers and account changes discard temporary
audio. **Keep Offline** pins an existing cache without fetching it again, or
downloads the original format explicitly. Playback caches and pinned downloads
share a 2 GB account-scoped budget; only unpinned caches are automatically evicted.
Click artwork, title or other row metadata to play; activating the current song
resumes it instead of restarting. A static waveform overlays the playing artwork.
Now Playing keeps the queue in a bounded, lazy scrolling panel so opening a large
library does not create every queue row at once.

`Package.swift` pins universal audio-default XCFramework archives and SHA-256
checksums from `media-kit/libmpv-darwin-build` v0.7.3. Packaging embeds and signs
the frameworks and includes licenses, matching mpv/FFmpeg/Mbed TLS source
archives, and the complete provider build recipe/patches. First build/packaging
requires network access and Xcode/Command Line Tools. Users need neither Homebrew
nor an external media-player or converter installation. See
`packaging/ThirdPartyNotices.txt` for versions and redistribution details.
Packaging stages a fresh app and preserves any previous build rather than
overwriting a running executable.

Local libraries, pending-change journals and resolution backups live in
`~/Library/Application Support/StrettoNative/library.sqlite`. Downloads are
account-isolated and stored separately under Application Support. Guest and
account libraries are separate: signing in does not silently upload a guest
library or erase the account's remote data.

### Distribution

```sh
ARCHITECTURE=universal SIGNING_IDENTITY="<Developer ID identity>" scripts/build-app.sh
NOTARY_PROFILE="<existing notarytool Keychain profile>" scripts/notarize.sh
```

Default packaging is an ad-hoc-signed Apple Silicon development app. Developer ID
signing and notarization require your own Apple credentials; neither is implied
by a successful local build. The native app is not sandboxed; it uses hardened
runtime when Developer ID signed. The final notarized archive is
`build/Stretto-macos.zip`.

Opt-in real-service checks use only disposable test accounts and public media:

```sh
STRETTO_LIVE_MEDIA_TEST=1 swift test --filter MediaTests
STRETTO_TEST_EMAIL="<disposable account>" STRETTO_TEST_PASSWORD="<temporary password>" \
  swift test --filter LiveAccountTests
```

The account check creates an account. Remove that disposable account's database
documents after verification; never point it at an existing personal account.
Actual Google/Spotify account consent and hardware media-key interaction must be
verified interactively by the account/device owner.

## Original high-level implementation plan

1. **Approve the design.** Review ten feature mockups, compare light/dark modes and
   visual treatments, and save a design brief. Keep Stretto blue (`#44bbff`), use
   system typography, and adapt surfaces and accessible text colors to appearance.
2. **Build a native shell.** SwiftUI, with AppKit for window/menu-bar behavior,
   keyboard commands, drag-and-drop and settings. Proposed baseline: macOS 14,
   universal Apple Silicon/Intel build. Confirm this baseline before implementation.
3. **Connect existing accounts.** A dedicated URLSession client for
   `https://next.kaiserapps.com` with a private cookie store; Keychain-backed session
   persistence, no stored passwords. Support email login, registration, password
   recovery/completion, session restoration, expiry and logout.
4. **Complete Google sign-in correctly.** Use ASWebAuthenticationSession in the
   system browser. The current web app obtains a Google ID token and POSTs
   `{email, token}` to `/googleLogin`; this is not already a native OAuth flow.
   Prefer an official-domain browser login and short-lived, single-use,
   state/PKCE-bound handoff exchanged for a native session. This requires a small,
   separately reviewed Stretto backend change. Alternatively register a desktop
   OAuth client and explicitly validate its audience server-side. Do not reuse a
   web client secret in the app, embed Google login in a WebView, copy browser
   cookies, or send reusable credentials in callback URLs.
5. **Preserve the shared library.** Codable models retaining unknown JSON fields;
   local SQLite persistence, account-scoped caches and a pending-change journal.
   Sync the existing whole-library blobs with version checks and explicit conflict
   resolution. Never silently force-upload or erase a local library on first login.
6. **Implement native playback.** Source adapters for `y_` and `s_` IDs,
   audio-only libmpv/Core Audio, incremental original-byte streaming, queue/shuffle/repeat,
   artwork, seek and output-device behavior. Validate the deployed YouTube resolver,
   SoundCloud HLS resolution before claiming playback parity. Preserve existing
   `a_` data, but do not offer Audius playback.
   Downloads are a separate native cache, not the web Service Worker cache.
7. **Integrate with macOS.** MPNowPlayingInfoCenter and MPRemoteCommandCenter for
   Control Center, media keys, metadata, artwork and seeking; menu-bar mini player,
   keyboard commands, sleep/wake recovery and accessibility. Remote control and
   device presence were removed from scope in the approved brief.
8. **Harden and ship.** Contract/fixture tests, account and sync failure tests,
   real-source playback and system-control checks, VoiceOver/contrast/reduced-motion
   review, signing, hardened runtime, notarization and release packaging.

## Verified official contracts

These contracts were inspected in the official Stretto server repository during
development. That server checkout is not a build or runtime dependency:

| Capability | Existing contract |
| --- | --- |
| Email accounts | POST `/login`, `/createaccount` with `{email,password}` |
| Google accounts | POST `/googleLogin` with `{email,token}`; Google ID-token verification |
| Session | POST `/checklogin`; cookie-based session; POST `/logout` |
| Recovery | POST `/forgotpassword`, `/completereset`; emailed official-domain reset link |
| Read sync | GET `/latestversion`, `/latestdata` => `{songs,playlists,version}` |
| Write sync | POST `/uploaddata` with complete `{songs,playlists,version}`; JSON `success:false` and `error:"version mismatch"` on conflict |
| Streaming | Web YouTube redirect resolver; SoundCloud resolved HLS; Audius resolved stream |

Sources: `controllers/index.js`, `models/data_mapper.js`,
`services/google.js`, `src/js/services/account_manager.js`,
`src/js/services/sync_manager.jsx` and the three source-specific stream players.
HTTP success alone does not indicate API success. The native client must inspect
the JSON body as well as HTTP status.

No production SSH access was needed for design. Implementation uses only
the necessary Dokku setting names and non-secret endpoint/client-ID configuration
with explicit scope; it does not dump environment variables or copy SMTP, session,
Google/Spotify client secrets into this repository, the design brief, or the app.
The additive native-auth routes belong in the official `benkaiser/stretto`
repository and are already deployed to the official Dokku app. Its
`docs/native-api.md` documents the Google/Spotify bridge, grant expiration/replay
protection and endpoint contracts. Building this companion on another Mac does
not require changing or deploying those server routes.

## Interactive design studio

```sh
npm run design
open http://127.0.0.1:4317
```

Runtime has no dependencies; Node 20+ is sufficient. The server binds only to
loopback. Use `PORT=4318 npm run design` if the default port is occupied.

The ten mockups cover library, playlists, immersive playback, mini player/system
controls, search/import, artists/discovery, offline downloads, account/sync,
sign-in/onboarding, and appearance/preferences. They use fictional music and
CSS-generated artwork, no remote tracking, external images, or account credentials.
All playback, sign-in, downloads and sync interactions are explicitly simulations.

Choose a visual direction, toggle appearance, rate and shortlist each mock, write
per-screen feedback, and choose release priorities. Changes autosave in this
browser's localStorage. **Save design brief** writes
`.local/design-feedback.json` in this project; **Export JSON** downloads a portable
copy. The summary makes the approved direction available for subsequent native work.
Do not enter passwords or private account data into mock fields or design notes.

```sh
npm test
npm install
npm run test:browser
```

Browser checks use installed Google Chrome when available, or Playwright Chromium
(`npx playwright install chromium`). Tests use isolated temporary feedback storage.
No native capabilities are implied by passing web-prototype checks.
