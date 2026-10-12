const $ = selector => document.querySelector(selector);
const escape = value => String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
const mocks = [
  { id: 'library', name: 'Your library', title: 'Everything, in its place.', detail: 'A familiar Mac sidebar, artwork-led collections, and a persistent player. Your official Stretto library, without the browser chrome.' },
  { id: 'playlist', name: 'Playlist detail', title: 'A mix with a little more feeling.', detail: 'Big artwork, readable track lists, lightweight editing and source badges. A comfortable home for both a five-song mix and a thousand-song collection.' },
  { id: 'player', name: 'Now playing', title: 'Just you and the next track.', detail: 'An immersive listening view with a visible queue, large artwork and an optional lyrics panel. Try play/pause, seeking, and skipping in the simulated player.' },
  { id: 'mini', name: 'Mac media controls', title: 'Out of the way. Always nearby.', detail: 'A floating mini player alongside a mock of macOS Control Center. The native implementation will use real Now Playing metadata and remote-command APIs.' },
  { id: 'search', name: 'Search & import', title: 'Find it. Bring it with you.', detail: 'One calm search surface for your library and supported sources, plus URL and Spotify import entry points. Type to filter the fictional library below.' },
  { id: 'artists', name: 'Artists & discovery', title: 'A little less algorithm.', detail: 'Follow artists and discover new releases using Stretto’s existing artist services. A human-scale feed, rather than a wall of recommendations.' },
  { id: 'offline', name: 'Offline & downloads', title: 'Good music. Bad reception.', detail: 'Clear local-storage usage, queued downloads and explicit failures. Downloads and storage figures here are mock data, not real offline audio.' },
  { id: 'sync', name: 'Account & sync', title: 'One library. Every screen.', detail: 'Visible account state and a non-destructive conflict resolution surface. Device presence and remote control are distinct from version-based library sync.' },
  { id: 'login', name: 'Sign in & welcome', title: 'Same Stretto. New home.', detail: 'Email, Google, account creation and recovery in one native welcome flow. These buttons only preview states; Google will open the system browser in the real app.' },
  { id: 'settings', name: 'Preferences', title: 'Feels right, by default.', detail: 'Mac-like grouped settings for appearance, media controls and window behavior. Change the appearance here to see it reflected across all ten mockups.' },
];
const features = [
  ['media', 'Mac media integration', 'Media keys, Control Center & mini player'],
  ['offline', 'Offline listening', 'Downloads, storage & reliable retries'],
  ['remote', 'Multi-device control', 'Control your other Stretto sessions'],
  ['discovery', 'Artist discovery', 'Followed artists & new-release feed'],
  ['import', 'Search & import', 'Source search, URLs & Spotify playlists'],
  ['lyrics', 'Lyrics & focus mode', 'Immersive artwork & less distraction'],
];
const songs = [
  { title: 'A Softer Horizon', artist: 'Juniper Coast', album: 'Blue Hours', duration: '4:12', art: '', source: 'YouTube' },
  { title: 'Afterglow', artist: 'Velvet District', album: 'Late Blooms', duration: '3:48', art: 'pink', source: 'SoundCloud' },
  { title: 'Slow Motion', artist: 'Field Notes', album: 'Open Air', duration: '5:06', art: 'green', source: 'Audius' },
  { title: 'Room for the Moon', artist: 'Lowlight', album: 'Night Windows', duration: '3:32', art: 'purple', source: 'YouTube' },
];
const storageKey = 'stretto-native-design-v1';
const defaults = () => ({
  schemaVersion: 1, appearance: 'dark', direction: 'glass', density: 'comfortable',
  priorities: ['media', 'offline'], notes: '',
  screens: Object.fromEntries(mocks.map(mock => [mock.id, { rating: 0, shortlisted: false, notes: '' }])),
});
function valid(value) {
  return value?.schemaVersion === 1 && ['light', 'dark', 'system'].includes(value.appearance)
    && ['glass', 'editorial', 'compact'].includes(value.direction) && ['dense', 'comfortable'].includes(value.density)
    && typeof value.notes === 'string' && value.notes.length <= 12000 && Array.isArray(value.priorities)
    && value.priorities.every(id => features.some(feature => feature[0] === id))
    && value.screens && Object.keys(value.screens).length === 10
    && mocks.every(mock => {
      const s = value.screens[mock.id];
      return s && Number.isInteger(s.rating) && s.rating >= 0 && s.rating <= 5
        && typeof s.shortlisted === 'boolean' && typeof s.notes === 'string' && s.notes.length <= 6000;
    });
}
let brief = defaults();
let index = 0;
let token;
let revision = 0;
let currentSong = 0;
let playing = false;
let position = 31;
let volume = 70;
let localBrief = null;
let loginMode = 'login';
const followed = new Set(['Juniper Coast']);
const downloaded = new Set();
const osTheme = matchMedia('(prefers-color-scheme: dark)');
let localError;
try {
  const raw = localStorage.getItem(storageKey);
  if (raw) {
    localBrief = JSON.parse(raw);
    if (!valid(localBrief)) throw new Error('The saved browser brief is invalid.');
    brief = localBrief;
  }
} catch (error) {
  localError = `Browser feedback could not be restored: ${error.message}. New edits remain in memory; save or export them.`;
}

const art = (color = '', size = '') => `<div class="art ${color} ${size}" aria-hidden="true"></div>`;
const button = (text, action, blue = false) => `<button class="app-button${blue ? ' blue' : ''}" data-action="${action}">${text}</button>`;
const traffic = '<span class="traffic" aria-hidden="true"><i></i><i></i><i></i></span>';
const trackText = song => `<strong>${song.title}</strong><small>${song.artist}</small>`;
function transport() {
  return `<div class="transport"><button data-action="shuffle" aria-label="Shuffle">⤨</button><button data-action="previous" aria-label="Previous track">⏮</button><button class="play" data-action="play" aria-label="${playing ? 'Pause' : 'Play'}">${playing ? 'Ⅱ' : '▶'}</button><button data-action="next" aria-label="Next track">⏭</button><button data-action="repeat" aria-label="Repeat">↻</button></div>`;
}
function scrub() {
  return `<input class="scrub" type="range" min="0" max="100" value="${position}" aria-label="Playback position" data-demo="position">`;
}
function playerBar() {
  const song = songs[currentSong];
  return `<div class="player-bar"><div class="playing-song">${art(song.art, 'tiny')}<div>${trackText(song)}</div></div><div>${transport()}${scrub()}</div><div class="volume">◖<input type="range" min="0" max="100" value="${volume}" aria-label="Volume" data-demo="volume"></div></div>`;
}
function sidebar(active) {
  const links = [['library', '▦', 'Your library'], ['search', '⌕', 'Search'], ['artists', '◎', 'Discover'], ['offline', '↓', 'Downloads']];
  return `<aside class="app-sidebar"><div class="app-brand">stretto</div><div class="sidebar-label">YOUR MUSIC</div>${links.map(([id, symbol, label]) => `<button data-mock="${id}" class="${id === active ? 'active' : ''}"><span class="sidebar-symbol">${symbol}</span>${label}</button>`).join('')}<div class="sidebar-label">PLAYLISTS</div>${['Blue hours', 'The long way home', 'Deep focus'].map((name, i) => `<button data-mock="playlist" class="${active === 'playlist' && i === 0 ? 'active' : ''}"><span class="sidebar-symbol">≡</span>${name}</button>`).join('')}<div class="sidebar-bottom"><button data-mock="sync">◉ &nbsp; Your account</button><button data-mock="settings">⚙ &nbsp; Preferences</button><span>✓ Library up to date · Mock</span></div></aside>`;
}
function windowShell(content, active, title = 'Stretto', withPlayer = true) {
  return `<div class="window"><div class="titlebar">${traffic}<span class="window-title">${title}</span><button data-mock="search" aria-label="Open search">⌕</button><button data-mock="mini" aria-label="Open mini player">▣</button></div><div class="app-layout">${sidebar(active)}<div class="app-content">${content}</div></div>${withPlayer ? playerBar() : ''}</div>`;
}
function trackRows(items = songs) {
  return items.map((song, n) => `<div class="track-row${songs.indexOf(song) === currentSong ? ' selected' : ''}"><button data-song="${songs.indexOf(song)}" aria-label="Preview ${song.title}">${songs.indexOf(song) === currentSong && playing ? 'Ⅱ' : n + 1}</button>${art(song.art, 'tiny')}<div>${trackText(song)}</div><span>${song.album}</span><span>${song.duration}</span></div>`).join('');
}
const heading = (overline, title, extra = '') => `<div class="content-heading"><div><div class="app-overline">${overline}</div><h2>${title}</h2></div>${extra}</div>`;
function library() {
  return windowShell(`${heading('A SOUNDTRACK FOR YOUR DAY', 'Your library', button('+ Add music', 'import'))}<div class="app-tabs"><span class="active">Playlists</span><span>All songs</span><span>Recently added</span></div><div class="card-grid">${[['Blue hours', '', '24 songs · Your evening ritual'], ['The long way home', 'pink', '38 songs · Take the scenic route'], ['Deep focus', 'green', '42 songs · Find your flow']].map(([title, color, caption]) => `<button class="music-card" data-mock="playlist">${art(color)}<strong>${title}</strong><small>${caption}</small></button>`).join('')}</div><div class="content-heading" style="margin:20px 0 0"><h3>Recently added</h3><span class="pill">All sources, one library</span></div><div class="track-list">${trackRows(songs.slice(0, 2))}</div>`, 'library');
}
function playlist() {
  return windowShell(`<div class="playlist-hero">${art()}<div><div class="app-overline">YOUR PLAYLIST</div><h2>Blue hours</h2><p>For the quiet part of the day.</p><p>24 songs · 1 hr 36 min · Synced with Stretto</p><div class="playlist-actions">${button('▶ Play', 'play', true)}${button('⤨ Shuffle', 'shuffle')}${button('↓ Download', 'download-playlist')}</div></div></div><div class="content-heading" style="margin-bottom:2px"><span class="pill">YouTube · SoundCloud · Audius</span>${button('••• Edit mix', 'edit')}</div><div class="track-list">${trackRows()}</div>`, 'playlist', 'Blue hours');
}
function player() {
  const song = songs[currentSong];
  return windowShell(`<div class="now-playing"><div>${art(song.art, 'hero-art')}<div class="track-info"><div class="app-overline">PLAYING FROM BLUE HOURS</div><h2>${song.title}</h2><p>${song.artist} · ${song.album}</p></div>${transport()}${scrub()}<div class="time-labels"><span>${Math.floor(position * 2.52 / 60)}:${String(Math.floor(position * 2.52) % 60).padStart(2, '0')}</span><span>${song.duration}</span></div></div><div class="queue"><div class="app-overline">KEEP THE MOMENT GOING</div><h3>Up next</h3>${songs.filter(s => s !== song).map(s => `<div class="queue-item">${art(s.art, 'tiny')}<div>${trackText(s)}</div><button data-song="${songs.indexOf(s)}" aria-label="Preview ${s.title}">▶</button></div>`).join('')}<div class="lyrics"><span class="app-overline">LYRICS CONCEPT · FICTIONAL</span>The city slows to blue<br><strong>And all the roads lead back to you</strong><br>We take the longer way…</div></div></div>`, 'player', 'Now playing', false);
}
function mini() {
  const song = songs[currentSong];
  return `<div class="mini-scene"><div><div class="mini-caption">FLOATING MINI PLAYER</div><div class="mini-window"><div class="titlebar">${traffic}<span class="window-title">stretto</span><button data-mock="player" aria-label="Expand player">↗</button></div>${art(song.art)}<div class="mini-meta"><h3>${song.title}</h3><p>${song.artist}</p>${transport()}${scrub()}</div></div><p class="mini-callout">A small window for a big soundtrack.<br>Always-on-top is your choice.</p></div><div><div class="mini-caption">MACOS CONTROL CENTER · CONCEPT</div><div class="system-control"><strong>Sound</strong><div class="control-tile">Output: MacBook speakers<input type="range" min="0" max="100" value="${volume}" aria-label="System volume preview" data-demo="volume"></div><div class="control-tile"><div class="playing-song">${art(song.art, 'tiny')}<div>${trackText(song)}<small>Stretto</small></div></div>${transport()}${scrub()}</div></div><p class="mini-callout">Media keys. Artwork. Seeking.<br>Native Now Playing integration,<br>not a browser tab pretending.</p><span class="pill">UI preview, not system integration</span></div></div>`;
}
function search() {
  return windowShell(`${heading('ONE SEARCH. ALL YOUR MUSIC.', 'Find your next favorite.')}<input class="search-field" id="demo-search" type="search" placeholder="Search songs, artists, albums…" aria-label="Search mock library"><div class="search-hint">⌘ K in the native app · Library search works in this mock</div><div class="app-tabs"><span class="active">Your library</span><span>YouTube</span><span>SoundCloud</span><span>Audius</span></div><div id="search-results" class="track-list">${trackRows()}</div><div class="import-card"><div><h3 style="font-size:11px">Already have a favorite mix?</h3><p>Bring a song URL or a Spotify playlist.</p></div>${button('+ Import', 'import')}</div>`, 'search');
}
function artists() {
  return windowShell(`${heading('THE PEOPLE BEHIND YOUR SOUND', 'Stay close to the music.')}<p>Fresh releases from artists you follow. No endless scrolling.</p><div class="artist-grid">${[['Juniper Coast', ''], ['Velvet District', 'pink'], ['Field Notes', 'green']].map(([name, color]) => `<div class="artist-card">${art(color)}<strong>${name}</strong><br><button class="app-button" data-follow="${name}">${followed.has(name) ? '✓ Following' : '+ Follow'}</button></div>`).join('')}</div><div class="release-banner">${art('purple', 'medium')}<div><div class="app-overline">NEW RELEASE · FICTIONAL</div><h3>Night Windows</h3><p>Lowlight · A little space to breathe.</p></div>${button('Listen', 'listen', true)}</div>`, 'artists');
}
function offline() {
  return windowShell(`${heading('TAKE THE MUSIC WITH YOU', 'Offline, not out of touch.', button('Download mix', 'download-playlist', true))}<div class="download-summary"><div class="download-ring">62%</div><div><h3>Room for the road.</h3><p>3.1 GB of 5 GB · Mock storage figures</p></div></div>${[['Blue hours', '', '24 songs · 168 MB', 'Available offline'], ['Deep focus', 'green', '42 songs · 291 MB', downloaded.has('Deep focus') ? 'Ready · Simulated' : 'Waiting to download'], ['The long way home', 'pink', '38 songs · Connection interrupted', downloaded.has('The long way home') ? 'Ready · Simulated' : 'Retry']].map(([name, color, desc, state]) => `<div class="download-row">${art(color, 'tiny')}<div><strong>${name}</strong><p>${desc}</p></div>${state === 'Retry' || state === 'Waiting to download' ? `<button class="app-button download-state" data-download="${name}">${state === 'Retry' ? 'Retry' : 'Download'}</button>` : `<span class="download-state">✓ ${state}</span>`}</div>`).join('')}<p style="margin-top:15px">Your library stays available even when the network doesn’t.<br>Native downloads will be separate from your browser’s cache.</p>`, 'offline');
}
function sync() {
  return windowShell(`${heading('CONNECTED TO STRETTO OFFICIAL', 'One library, everywhere.', button('Account', 'account'))}<div class="sync-banner"><div class="sync-icon">↻</div><div><h3>Your library is up to date.</h3><p>128 songs · 8 playlists · Fictional account</p></div>${button('Sync now', 'sync', true)}</div><div class="app-overline">YOUR DEVICES · MOCK PRESENCE</div><div class="device-row"><span>▣</span><strong>This Mac</strong><small>Currently listening</small></div><div class="device-row"><span>▯</span><strong>Phone · Stretto web</strong><small>Remote-control concept</small></div><div class="conflict"><h3>A playlist changed in two places.</h3><p>No changes are overwritten automatically. Compare before choosing.</p>${button('Review changes', 'conflict')} ${button('Keep for later', 'later')}</div><p style="margin-top:13px">Connected service: next.kaiserapps.com<br>Session-based accounts, shared library, explicit conflict resolution.</p>`, 'sync');
}
function login() {
  const isRegister = loginMode === 'register';
  const isRecover = loginMode === 'recover';
  const title = isRegister ? 'Make yourself at home.' : isRecover ? 'Find your way back.' : 'Welcome back.';
  return `<div class="window"><div class="titlebar">${traffic}<span class="window-title">Welcome to Stretto</span><span class="pill">Preview only</span></div><div class="login-layout"><div class="login-branding"><div class="app-brand">stretto</div><h2>Your music.<br>Your Mac.<br>Your moment.</h2><p>The library you love.<br>A new way to feel at home.</p>${art('', 'login-art')}</div><form class="login-form" id="demo-login"><h3>${title}</h3><p>Use your existing Stretto account.<br>Don’t enter real credentials into this mock.</p>${!isRecover ? '<button type="button" class="google-button" data-action="google"><strong>G</strong>Continue with Google ↗</button><div class="login-divider">OR CONTINUE WITH EMAIL</div>' : ''}<label for="mock-email">Email · fictional example</label><input id="mock-email" type="text" value="listener@example.test" readonly aria-label="Fictional email example">${!isRecover ? '<label for="mock-password">Password · non-editable placeholder</label><input id="mock-password" type="password" value="not-a-real-password" readonly aria-label="Non-editable mock password">' : ''}<button type="submit" class="app-button blue">${isRecover ? 'Preview recovery email' : isRegister ? 'Preview create account' : 'Preview sign in'}</button><div class="login-links"><button type="button" data-login="${isRecover || isRegister ? 'login' : 'recover'}">${isRecover || isRegister ? 'Back to sign in' : 'Forgot password?'}</button><button type="button" data-login="${isRegister ? 'login' : 'register'}">${isRegister ? 'Already have an account?' : 'Create account'}</button></div><p class="privacy-note">Google uses your system browser in the native app.<br>Your account and music stay with Stretto official.</p></form></div></div>`;
}
function settings() {
  return windowShell(`${heading('SMALL DETAILS. BIG DIFFERENCE.', 'Make yourself at home.')}<div class="settings-group"><div class="setting-row"><div><strong>Appearance</strong><p>Blue stays. Everything else adapts.</p></div><select id="mock-appearance" aria-label="Mock app appearance"><option value="system">Match system</option><option value="light">Light</option><option value="dark">Dark</option></select></div><div class="setting-row"><div><strong>Stretto blue</strong><p>#44bbff · Accessible text variants</p></div><span style="width:22px;height:22px;border-radius:50%;background:#44bbff"></span></div></div><div class="settings-group"><div class="setting-row"><div><strong>Show menu-bar player</strong><p>Your soundtrack, a click away</p></div><input class="toggle" type="checkbox" checked aria-label="Show menu-bar player preview" data-demo="setting"></div><div class="setting-row"><div><strong>Mini player always on top</strong><p>Keep music close while you work</p></div><input class="toggle" type="checkbox" aria-label="Always on top preview" data-demo="setting"></div><div class="setting-row"><div><strong>Use macOS media controls</strong><p>Now Playing, media keys, artwork</p></div><input class="toggle" type="checkbox" checked aria-label="Native media controls preview" data-demo="setting"></div></div><div class="setting-row" style="padding-left:0"><span>Quick search</span><span class="keyboard-key">⌘ K</span><span>Play / pause</span><span class="keyboard-key">Space</span></div>`, 'settings');
}
const renderers = { library, playlist, player, mini, search, artists, offline, sync, login, settings };

function applyTheme() {
  document.body.dataset.theme = brief.appearance === 'system' ? (osTheme.matches ? 'dark' : 'light') : brief.appearance;
  document.body.dataset.direction = brief.direction;
  document.body.dataset.density = brief.density;
  document.querySelectorAll('[data-appearance]').forEach(b => b.setAttribute('aria-pressed', b.dataset.appearance === brief.appearance));
  document.querySelectorAll('[data-direction]').forEach(b => b.setAttribute('aria-pressed', b.dataset.direction === brief.direction));
  $('#density').value = brief.density;
  if ($('#mock-appearance')) $('#mock-appearance').value = brief.appearance;
}
function summary() {
  const reviewed = mocks.filter(m => brief.screens[m.id].rating || brief.screens[m.id].notes.trim() || brief.screens[m.id].shortlisted);
  $('#review-count').textContent = `${reviewed.length}/10`;
  $('#brief-summary').innerHTML = `<strong>${reviewed.length} of 10 screens reviewed</strong> · ${escape(brief.direction)} direction · ${escape(brief.appearance)} appearance · ${escape(brief.density)} density<div class="summary-tags">${mocks.map(m => { const s = brief.screens[m.id]; return `<span class="summary-tag${s.shortlisted ? ' favorite' : ''}">${s.shortlisted ? '✓ ' : ''}${m.name}${s.rating ? ` · ${s.rating}/5` : ''}</span>`; }).join('')}</div>`;
  $('#mock-nav').innerHTML = mocks.map((m, i) => `<button data-nav="${i}" aria-current="${i === index}"><span class="num">${String(i + 1).padStart(2, '0')}</span>${m.name}${brief.screens[m.id].rating || brief.screens[m.id].shortlisted || brief.screens[m.id].notes.trim() ? '<span class="done">•</span>' : ''}</button>`).join('');
}
function saveLocal() {
  revision++;
  brief.updatedAt = new Date().toISOString();
  try {
    localStorage.setItem(storageKey, JSON.stringify(brief));
    $('#local-status').textContent = 'Autosaved in this browser. Save design brief to write it into the project.';
  } catch (error) {
    $('#local-status').textContent = `Browser autosave failed: ${error.message}. Use Save design brief or Export JSON.`;
  }
  $('#save-status').textContent = 'Unsaved project changes. Your latest choices are ready to save.';
  summary();
}
function renderRating() {
  const rating = brief.screens[mocks[index].id].rating;
  $('#rating').innerHTML = [1, 2, 3, 4, 5].map(n => `<button data-rating="${n}" aria-label="Rate ${n} out of 5${n === rating ? '; click again to clear' : ''}" aria-pressed="${n === rating}">${n}</button>`).join('');
}
function renderMock() {
  $('#mock-container').innerHTML = renderers[mocks[index].id]();
  applyTheme();
}
function navigate(next) {
  index = (next + mocks.length) % mocks.length;
  const mock = mocks[index];
  history.replaceState(null, '', `#${mock.id}`);
  $('#mock-number').textContent = `MOCK ${String(index + 1).padStart(2, '0')} / 10`;
  $('#mock-title').textContent = mock.title;
  $('#mock-description').textContent = mock.detail;
  $('#page-indicator').textContent = `${index + 1} / 10`;
  $('#feedback-title').textContent = `${mock.name}: keep or change?`;
  $('#screen-notes').value = brief.screens[mock.id].notes;
  $('#shortlist').checked = brief.screens[mock.id].shortlisted;
  $('#demo-status').textContent = 'Try the mock controls. No real accounts, music or downloads are used.';
  renderMock();
  renderRating();
  summary();
}
function demo(message) { $('#demo-status').textContent = message; }
function action(name) {
  switch (name) {
    case 'play': playing = !playing; renderMock(); demo(`${playing ? 'Playing' : 'Paused'} "${songs[currentSong].title}" · Silent UI simulation.`); break;
    case 'next': currentSong = (currentSong + 1) % songs.length; position = 0; renderMock(); demo(`Next: ${songs[currentSong].title} · Silent UI simulation.`); break;
    case 'previous': currentSong = (currentSong + songs.length - 1) % songs.length; position = 0; renderMock(); demo(`Previous: ${songs[currentSong].title} · Silent UI simulation.`); break;
    case 'shuffle': currentSong = (currentSong + 2) % songs.length; position = 0; renderMock(); demo('Shuffle preview: a different fictional track is selected.'); break;
    case 'repeat': demo('Repeat control concept. Queue repetition will be implemented in the native player.'); break;
    case 'google': demo('Google sign-in preview: native app → system browser → official-domain sign-in → one-time native session handoff. No real login was started.'); break;
    case 'import': navigate(mocks.findIndex(m => m.id === 'search')); demo('Import concept: paste a track URL or connect Spotify in the native app. No external requests are made here.'); break;
    case 'edit': demo('Playlist editing concept: rename, drag to reorder, and remove tracks. Tell us which editing controls you prefer below.'); break;
    case 'download-playlist': navigate(mocks.findIndex(m => m.id === 'offline')); downloaded.add('Deep focus'); renderMock(); demo('Download completed in this UI simulation. No audio files were downloaded.'); break;
    case 'listen': currentSong = 3; playing = true; navigate(mocks.findIndex(m => m.id === 'player')); demo('Previewing Lowlight in the silent mock player.'); break;
    case 'account': navigate(mocks.findIndex(m => m.id === 'login')); demo('Account and sign-in mock. Real accounts remain on next.kaiserapps.com.'); break;
    case 'sync': demo('Sync preview complete: check version → download or upload whole-library data → record server version. No server sync occurred.'); break;
    case 'conflict': demo('Conflict concept: compare a local and server snapshot, preserve a backup, then explicitly choose or merge changes. Never force-upload automatically.'); break;
    case 'later': demo('Conflict kept for later in this preview. Native app will retain pending changes without overwriting either library.'); break;
  }
}
document.addEventListener('click', event => {
  const target = event.target.closest('button');
  if (!target) return;
  if (target.dataset.nav !== undefined) navigate(Number(target.dataset.nav));
  if (target.dataset.mock) navigate(mocks.findIndex(m => m.id === target.dataset.mock));
  if (target.dataset.action) action(target.dataset.action);
  if (target.dataset.appearance) { brief.appearance = target.dataset.appearance; applyTheme(); saveLocal(); }
  if (target.dataset.direction) { brief.direction = target.dataset.direction; applyTheme(); saveLocal(); }
  if (target.dataset.rating) {
    const screen = brief.screens[mocks[index].id];
    screen.rating = screen.rating === Number(target.dataset.rating) ? 0 : Number(target.dataset.rating);
    renderRating(); saveLocal();
  }
  if (target.dataset.song !== undefined) {
    currentSong = Number(target.dataset.song); playing = true; position = 0;
    if (mocks[index].id === 'search') {
      document.querySelectorAll('#search-results .track-row').forEach(row => row.classList.toggle('selected', row.querySelector('button').dataset.song === target.dataset.song));
      $('.player-bar').outerHTML = playerBar();
    } else renderMock();
    demo(`Previewing "${songs[currentSong].title}" · Silent UI simulation.`);
  }
  if (target.dataset.follow) {
    if (followed.has(target.dataset.follow)) followed.delete(target.dataset.follow); else followed.add(target.dataset.follow);
    renderMock(); demo('Artist follow state changed in this preview only.');
  }
  if (target.dataset.download) {
    downloaded.add(target.dataset.download); renderMock(); demo('Simulated download ready. No audio files were downloaded.');
  }
  if (target.dataset.login) { loginMode = target.dataset.login; renderMock(); }
});
document.addEventListener('input', event => {
  const input = event.target;
  if (input.id === 'screen-notes') { brief.screens[mocks[index].id].notes = input.value; saveLocal(); }
  if (input.id === 'global-notes') { brief.notes = input.value; saveLocal(); }
  if (input.id === 'demo-search') {
    const term = input.value.trim().toLowerCase();
    const filtered = songs.filter(s => `${s.title} ${s.artist} ${s.album}`.toLowerCase().includes(term));
    $('#search-results').innerHTML = filtered.length ? trackRows(filtered) : '<p>No fictional tracks match. Try “Juniper” or “Afterglow”.</p>';
  }
  if (input.dataset.demo === 'position') {
    position = Number(input.value);
    document.querySelectorAll('[data-demo=position]').forEach(range => { range.value = position; });
    demo(`Seek position: ${position}% · UI simulation.`);
  }
  if (input.dataset.demo === 'volume') {
    volume = Number(input.value);
    document.querySelectorAll('[data-demo=volume]').forEach(range => { range.value = volume; });
    demo(`Volume: ${volume}% · No system volume was changed.`);
  }
});
document.addEventListener('change', event => {
  const input = event.target;
  if (input.id === 'shortlist') { brief.screens[mocks[index].id].shortlisted = input.checked; saveLocal(); }
  if (input.id === 'density') { brief.density = input.value; applyTheme(); saveLocal(); }
  if (input.dataset.priority) {
    brief.priorities = [...document.querySelectorAll('[data-priority]:checked')].map(el => el.dataset.priority);
    saveLocal();
  }
  if (input.id === 'mock-appearance') { brief.appearance = input.value; applyTheme(); saveLocal(); }
  if (input.dataset.demo === 'setting') demo(`${input.getAttribute('aria-label')}: ${input.checked ? 'on' : 'off'} in this preview. No macOS settings changed.`);
});
document.addEventListener('submit', event => {
  if (event.target.id !== 'demo-login') return;
  event.preventDefault();
  if (loginMode === 'recover') {
    demo('Recovery preview: an email would link to the official reset flow. No email was sent.'); return;
  }
  navigate(mocks.findIndex(m => m.id === 'sync'));
  demo('Account preview only: successful sign-in would restore the session and safely reconcile your library.');
});
$('#prev').addEventListener('click', () => navigate(index - 1));
$('#next').addEventListener('click', () => navigate(index + 1));
$('#summary-button').addEventListener('click', () => $('#brief').scrollIntoView());
osTheme.addEventListener('change', applyTheme);
document.addEventListener('keydown', event => {
  if (event.target.closest('input,textarea,select,button') || event.metaKey || event.ctrlKey || event.altKey) return;
  if (event.key === 'ArrowRight') { event.preventDefault(); navigate(index + 1); }
  if (event.key === 'ArrowLeft') { event.preventDefault(); navigate(index - 1); }
});
function renderBrief() {
  $('#global-notes').value = brief.notes;
  $('#priorities').innerHTML = features.map(([id, name, detail]) => `<label class="priority"><input type="checkbox" data-priority="${id}" ${brief.priorities.includes(id) ? 'checked' : ''}><span><strong>${name}</strong><small>${detail}</small></span></label>`).join('');
}
$('#export').addEventListener('click', () => {
  const blob = new Blob([JSON.stringify({ ...brief, exportedAt: new Date().toISOString() }, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a'); link.href = url; link.download = 'stretto-native-design-brief.json'; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  $('#save-status').textContent = 'JSON export downloaded. Use Save design brief to also store it in this project.';
});
$('#save').addEventListener('click', async () => {
  const revisionAtSave = revision;
  const submitted = JSON.stringify(brief);
  $('#save').disabled = true;
  $('#save-status').textContent = 'Saving design brief into the project…';
  try {
    if (!token) {
      const response = await fetch('/api/session');
      if (!response.ok) throw new Error(`Studio session failed (${response.status}).`);
      token = (await response.json()).token;
    }
    const response = await fetch('/api/feedback', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Studio-Token': token }, body: submitted });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || `Save failed (${response.status}).`);
    $('#save-status').textContent = revision === revisionAtSave
      ? `Saved to ${data.path} at ${new Date(data.savedAt).toLocaleTimeString()}. Your direction is ready for native implementation.`
      : 'An earlier snapshot was saved. You edited while saving; save again to include your latest choices.';
  } catch (error) {
    $('#save-status').textContent = `Could not save: ${error.message} Your edits remain in this page; try Export JSON.`;
  } finally { $('#save').disabled = false; }
});

renderBrief();
navigate(Math.max(0, mocks.findIndex(m => `#${m.id}` === location.hash)));
if (localError) $('#local-status').textContent = localError;
const startupRevision = revision;
try {
  const response = await fetch('/api/feedback');
  if (!response.ok) throw new Error(`Saved brief lookup failed (${response.status}).`);
  const saved = await response.json();
  if (saved && !valid(saved)) throw new Error('The project brief has invalid fields; browser choices were retained.');
  const savedTime = saved?.savedAt ? Date.parse(saved.savedAt) : 0;
  const browserTime = localBrief?.updatedAt ? Date.parse(localBrief.updatedAt) : 0;
  if (saved && revision === startupRevision && (!localBrief || savedTime > browserTime)) {
    brief = saved; renderBrief(); navigate(index);
    $('#save-status').textContent = 'Restored your saved project brief. Further edits can be saved again.';
  } else if (saved) {
    $('#save-status').textContent = 'Project brief found; newer browser edits were preserved. Save to update the project copy.';
  }
} catch (error) {
  $('#save-status').textContent = `Could not load project feedback: ${error.message} Browser editing and export still work.`;
}
