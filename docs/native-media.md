# Native source and media contracts

YouTube and SoundCloud are the native sources. Unsupported source records (including Audius) stay in the synced library but cannot play or download.

Discovery uses direct HTTPS client requests, not a backend search proxy or JavaScript evaluation. YouTube HTML assignments are scanned as balanced JSON, with legacy and lockup renderers and direct Innertube continuations. Playlist imports are all-or-error, bounded to 30 pages / 5,000 tracks. Consent, bot challenges, throttling, private playlists and unknown result shapes produce explicit errors. SoundCloud retries a stale public client ID once, discovering replacements only from validated `a-v2.sndcdn.com/assets/*.js` scripts. Full-length progressive MP3 is preferred to HLS; previews, encrypted/premium-only and unavailable audio are rejected.

YouTube songs can open their actual uploader's channel. Channel Videos-tab uploads use YouTube's global Newest, Most viewed and Oldest ordering, with manually requested pagination rather than sorting only a loaded page. Shorts and live streams remain separate browser tabs. Channel pagination is not limited by the playlist-import cap; repeated continuation tokens fail explicitly.

Playback uses bundled audio-only libmpv and Core Audio, generation-guarded asynchronous resolution, observable loading/errors, seconds-based seek, queue/shuffle/repeat and volume. A failed track is not silently skipped. System Now Playing publishes metadata, artwork, duration, elapsed time and playback rate; media-command targets and decoder observers are removed at disposal.

Shared media code is the importable `StrettoMedia` library (`Sources/StrettoMedia/Media.swift`), not the SwiftUI executable. `StrettoMac` and the media test target depend on that library.

## Streaming and offline audio

A single Foundation HTTPS transfer feeds original bytes into a growing temporary file read through libmpv custom-stream callbacks. Playback starts before the complete download; WebM/Opus, MP3 and M4A do not need re-encoding. Seeking ahead waits for the requested bytes. Transfers write bounded chunks on a serial URLSession delegate queue, not a byte-at-a-time MainActor loop.

Only natural full listens without seeks become persistent playback caches. Skipping, stopping, failed transfers and account changes discard temporary audio. Explicit downloads have progress, cancellation, retry, removal and an account-isolated SHA-256 namespace in Application Support. Keep Offline pins an existing cache without fetching it again, or downloads the original audio format. The manifest and final audio files are committed atomically; missing/truncated files never count as available.

Limits are 300 MB per track and 2 GB per account across playback caches and pinned downloads. Only unpinned caches are automatically evicted. Downloads are independent of browser Service Worker storage.

SoundCloud prefers full-length progressive MP3/M4A. Unencrypted, complete MP3 HLS segments can be joined without re-encoding. AAC-only, live, encrypted and fragmented HLS are unsupported by the bundled audio-default decoder and fail visibly. Fresh provider duration is retained for growing MP3 streams instead of substituting the decoder's moving read-ahead estimate. The seek bar and macOS controls therefore use full-track duration.

## Decoder packaging

The deployed YouTube resolver can return WebM/Opus despite an Ogg MIME label. Container inspection and the bundled decoder handle the actual bytes directly; the client does not pretend an invented format parameter changes the server response.

`Package.swift` pins universal audio-default XCFrameworks and checksums. `scripts/build-app.sh` embeds and signs the dynamic frameworks and includes upstream licenses, matching source archives and the provider's complete build recipe/patches. See `packaging/ThirdPartyNotices.txt`. No Homebrew, external player or conversion helper is required. `scripts/build-ffmpeg.sh` is a retained development helper, not part of current playback or app packaging.

## Media verification

`swift test --filter MediaTests` covers decoder playback, streaming startup, seeking, metadata, cache/offline behavior, account isolation, cancellation, manifest recovery and explicit unsupported-source errors. Scratch audio lives under project `.local/` and is removed after each test.

`STRETTO_LIVE_MEDIA_TEST=1 swift test --filter MediaTests` opts into muted playback of public YouTube media through the deployed resolver. `STRETTO_MEDIA_ENDPOINT` and `STRETTO_MEDIA_ID` can select another authorized public sample. `STRETTO_LIVE_SOUNDCLOUD_MEDIA_TEST=1 swift test --filter MediaTests` opts into the reported SoundCloud mix's duration, real-time playback, seek and near-end completion checks.

These checks do not verify audible output, physical media keys, authenticated/premium media or notarized distribution. `PlaybackQueueTests` hosts a 2,000-song queue to catch eager-layout regressions; the queue uses a bounded lazy scrolling panel.

Song lists use one lazy child per track, including its divider. Rows observe only current-track/play-state changes, not decoder position ticks. Library membership uses an ID index rebuilt when the library changes. Native action menus and their playlist submenus are constructed only when opened, so scrolling does not build hidden menus or validate offline files on disk. `SongListPerformanceTests` scrolls 30 channel-sized rows over a 2,000-song library with 80 playlists and position updates; its maximum synchronous layout budget is 50 ms, not a claim about measured display-frame timing.

## Discovery and lyrics verification

Fixture source tests cover old/new renderers, brace escaping, scoped channel sorting, pagination, repeated tokens, input allowlisting, errors, SoundCloud stream preference and safe public-client-ID refresh. `STRETTO_LIVE_SOURCE_TEST=1 swift test --filter LiveSourceTests` opts into bounded direct requests using the production SourceService session, without URLProtocol fixtures or a Stretto search proxy. Platform consent/bot/auth/throttle denials are logged as skipped, not successful discovery; parser failures fail the tests. `STRETTO_LIVE_PLAYLIST_URL` can opt into a known-small public playlist import.

`LyricsServiceTests` covers metadata-checked exact/search lookup, instrumental/missing results, ambiguous matches, outages, challenges, throttling, cancellation and safe browser URLs. `LyricsLookupTests` covers stale-request fencing and the distinction between failed and missing lyrics. Browser recovery does not transfer browser cookies into the app's separate connection.
