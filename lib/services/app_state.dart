import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/custom_playlist.dart';
import '../models/tv_channel.dart';
import 'app_cache.dart';
import 'remote_command.dart';
import 'stream_health.dart';

/// Which surface owns D-pad focus: the left category sidebar or the
/// right channel grid.
enum FocusZone { sidebar, grid }

/// A sidebar entry. Index 0 is always ★ Favourites, then one per rail.
class SideItem {
  final String label;
  final String key;
  const SideItem(this.label, this.key);
}

/// Global TV state. Single ChangeNotifier so both the 10-foot UI and the
/// inbuilt phone-remote server mutate the same truth (no polling loops in UI).
class AppState extends ChangeNotifier {
  List<TvChannel> _baseChannels = [];
  List<ChannelRail> _baseRails = [];
  List<CustomPlaylist> customPlaylists = [];

  List<TvChannel> allChannels = [];
  List<ChannelRail> rails = [];

  // Stream health: channel id → fast/slow/dead/unknown (background probe).
  final Map<String, String> healthById = {};
  bool catalogLoading = true;
  String catalogStatus = 'Starting…';

  TvChannel? playing;
  bool isPlaying = false;

  // Playback load state (drives the player-screen spinner / error card).
  bool isBuffering = false;
  double bufferingPct = 0;
  bool hasVideo = false;
  String? playError;
  DateTime playRequestedAt = DateTime.now();

  // Startup prebuffer (N-second tank): collect N s before first frame.
  // Setting persists via SharedPreferences; progress throttles notifies.
  int prebufferSecs = 5;
  bool prebuffering = false;
  double prebufferedSec = 0;
  int prebufferTarget = 0;

  void setPrebufferSecs(int v) {
    prebufferSecs = v.clamp(0, 30);
    notifyListeners();
  }

  void setPrebuffering(bool v,
      [double done = 0, int target = 0]) {
    prebuffering = v;
    if (v) {
      prebufferedSec = done;
      prebufferTarget = target;
    }
    notifyListeners();
  }

  void setPrebufferProgress(double done) {
    // Throttle: mpv emits buffer updates often; half-second steps are
    // plenty for a progress bar and spare rebuilds + phone pushes.
    if ((done - prebufferedSec).abs() < 0.5) return;
    prebufferedSec = done;
    notifyListeners();
  }

  // Video quality tracks (HLS variants) for the remote quality picker.
  // Plain maps keep this class free of player imports.
  List<Map<String, dynamic>> videoTracks = const [];
  String selectedVideoTrack = 'auto';
  String qualityLabel = '';

  void setVideoTracks(
      List<Map<String, dynamic>> tracks, String selected) {
    videoTracks = tracks;
    selectedVideoTrack = selected;
    qualityLabel = '';
    for (final t in tracks) {
      if ('${t['id']}' == selected) {
        final h = t['h'];
        if (h is int && h > 0) qualityLabel = '${h}p';
        break;
      }
    }
    notifyListeners();
  }
  double volume = 0.8;
  bool muted = false;

  // Focus: left sidebar category vs right channel grid.
  FocusZone zone = FocusZone.grid;
  int sideIndex = 0; // 0 = ★ Favourites, 1..n = rails[sideIndex-1]
  int gridIndex = 0; // flat index into the selected category
  int gridColumns = 6; // set by layout (MediaQuery) each build

  // Exact home-grid pixel offset. TvHome is unmounted while the player
  // is up (so its ScrollController dies with it) — the home screen
  // saves here continuously and restores on return, landing on the
  // exact pixels, selection and sidebar where playback started.
  double homeScrollOffset = 0;

  // Per-category cursor memory (keyed by 'fav'/rail title so it survives
  // list inserts) + hold-glide speed for the phone remote (keys/sec).
  final Map<String, int> _sideCursors = {};
  int repeatRate = 6;

  // Favourite channel ids, most-recent first. Tiny — prefs is fine.
  List<String> favouriteIds = [];

  // Preset (built-in, not user-added) categories. Off = sidebar shows
  // only ★ Favourites + your own pasted lists. Instant + persisted.
  bool showPresets = true;

  void setShowPresets(bool v) {
    if (showPresets == v) return;
    _saveSideCursor();
    showPresets = v;
    sideIndex = sideIndex.clamp(0, sideItems.length - 1);
    _restoreSideCursor();
    notifyListeners();
  }

  /// Built-in rails first or user rails first? User lists always lead;
  /// presets follow only while enabled.
  List<ChannelRail> get visibleRails => [
        ...rails.where((r) => r.title.startsWith('★ ')),
        if (showPresets)
          ...rails.where((r) => !r.title.startsWith('★ ')),
      ];

  List<SideItem> get sideItems => [
        const SideItem('Favourites', 'fav'),
        for (final r in visibleRails) SideItem(r.title, r.title),
      ];

  /// Channels of the selected sidebar category (favs or the rail).
  List<TvChannel> get sidebarChannels {
    if (sideIndex <= 0) return favouriteChannels;
    final v = visibleRails;
    if (v.isEmpty) return const [];
    final i = (sideIndex - 1).clamp(0, v.length - 1);
    return v[i].channels;
  }

  /// Home-grid display order: this category's favourites first, then the
  /// full category list (favourites included again). The D-pad index runs
  /// over THIS flat list, so moving across the section boundary is
  /// seamless — headers are decoration, never focus stops.
  List<TvChannel> get displayChannels {
    final all = sidebarChannels;
    if (all.isEmpty) return const [];
    final favs = [for (final c in all) if (isFav(c.id)) c];
    if (favs.isEmpty || favs.length == all.length) return all;
    return [...favs, ...all];
  }

  /// Tiles in the Favourites section (0 = single-section grid).
  int get displayFavCount {
    final all = sidebarChannels;
    if (all.isEmpty) return 0;
    var n = 0;
    for (final c in all) {
      if (isFav(c.id)) n++;
    }
    return (n == 0 || n == all.length) ? 0 : n;
  }

  String get sideTitle {
    if (sideIndex <= 0) return 'Favourites';
    final v = visibleRails;
    if (v.isEmpty) return 'TV';
    final i = (sideIndex - 1).clamp(0, v.length - 1);
    return v[i].title;
  }

  TvChannel? get focusedChannel {
    final list = displayChannels;
    if (list.isEmpty) return null;
    return list[gridIndex.clamp(0, list.length - 1)];
  }

  List<TvChannel> get favouriteChannels => [
        for (final id in favouriteIds)
          for (final c in allChannels.where((c) => c.id == id).take(1)) c
      ];

  bool isFav(String id) => favouriteIds.contains(id);

  Future<void> toggleFavourite(String id) async {
    if (favouriteIds.contains(id)) {
      favouriteIds.remove(id);
    } else {
      favouriteIds.insert(0, id);
    }
    // Sections above may have grown/shrunk — keep focus on a live tile.
    final d = displayChannels;
    gridIndex =
        gridIndex.clamp(0, d.isEmpty ? 0 : d.length - 1);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('opentv_favs', favouriteIds);
    } catch (_) {}
  }

  Future<void> loadFavourites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      favouriteIds =
          List<String>.from(prefs.getStringList('opentv_favs') ?? []);
    } catch (_) {}
  }

  /// The saved list behind a '★ name' rail title, if any (for its icon).
  CustomPlaylist? playlistForRail(String railTitle) {
    if (!railTitle.startsWith('★ ')) return null;
    final name = railTitle.substring(2);
    for (final p in customPlaylists) {
      if (p.name == name) return p;
    }
    return null;
  }

  /// Nuclear option for the remote's CLEAR LISTS vault: saved lists,
  /// favourites, health scores and playlist caches go; the base catalog
  /// and playback settings stay.
  Future<void> clearAllData() async {
    customPlaylists = [];
    favouriteIds = [];
    healthById.clear();
    _sideCursors.clear();
    sideIndex = 0;
    gridIndex = 0;
    _rebuild();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('opentv_favs');
      await prefs.remove('opentv_health_v1');
      await prefs.remove('opentv_m3u_cache_time_v1');
    } catch (_) {}
    try {
      await AppCache.writeText('custom_playlists.json', '[]');
      await AppCache.writeText('m3u_cache.txt', '');
    } catch (_) {}
  }

  void setRepeatRate(int v) {
    repeatRate = v.clamp(2, 12);
    notifyListeners();
  }

  // Web-remote link state (drives the QR auto-show on the TV).
  bool remoteConnected = false;
  int remoteClients = 0;

  void setRemoteStatus(
      {required bool connected, required int clients}) {
    if (remoteConnected == connected &&
        remoteClients == clients) {
      return;
    }
    remoteConnected = connected;
    remoteClients = clients;
    notifyListeners();
  }

  // Pop the QR dialog on the TV whenever no web remote is linked.
  bool autoQr = true;

  void setAutoQr(bool v) {
    if (autoQr == v) return;
    autoQr = v;
    notifyListeners();
  }

  /// Switch sidebar categories with cursor memory: the old category keeps
  /// its position (keyed by 'fav'/title, so it survives list inserts),
  /// the new one restores its own — never the 18th element elsewhere.
  void _moveSide(int next) {
    _saveSideCursor();
    sideIndex =
        next.clamp(0, sideItems.length - 1);
    _restoreSideCursor();
  }

  void _saveSideCursor() {
    _sideCursors[_sideKey()] = gridIndex;
  }

  void _restoreSideCursor() {
    final list = displayChannels;
    gridIndex = (_sideCursors[_sideKey()] ?? 0)
        .clamp(0, list.isEmpty ? 0 : list.length - 1);
  }

  String _sideKey() {
    if (sideIndex <= 0) return 'fav';
    final v = visibleRails;
    if (v.isEmpty) return 'fav';
    return v[(sideIndex - 1).clamp(0, v.length - 1)].title;
  }

  /// Tap a sidebar category: show it and dive straight into its grid.
  void selectSide(int i) {
    _saveSideCursor();
    sideIndex = i.clamp(0, sideItems.length - 1);
    _restoreSideCursor();
    zone = FocusZone.grid;
    notifyListeners();
  }

  // Remote server info (shown on TV + QR).
  int serverPort = 8080;
  List<String> lanUrls = const ['http://127.0.0.1:8080/remote'];
  bool serverOnline = false;

  final _keyCtrl = StreamController<RemoteKey>.broadcast();
  Stream<RemoteKey> get keyStream => _keyCtrl.stream;

  // Last key pressed (for tiny UI pulse + phone haptic echo).
  RemoteKey? lastKey;
  DateTime lastKeyAt = DateTime.now();

  void setCatalog(List<TvChannel> channels, List<ChannelRail> built,
      {String status = ''}) {
    _baseChannels = channels;
    _baseRails = built;
    _rebuild();
    catalogLoading = false;
    if (status.isNotEmpty) catalogStatus = status;
    sideIndex = 0;
    gridIndex = 0;
    _sideCursors.clear();
    zone = FocusZone.grid;
    notifyListeners();
  }

  void setCustomPlaylists(List<CustomPlaylist> lists) {
    customPlaylists = lists;
    _rebuild();
    notifyListeners();
  }

  void upsertCustomPlaylist(CustomPlaylist pl) {
    final i =
        customPlaylists.indexWhere((e) => e.id == pl.id);
    if (i < 0) {
      customPlaylists = [...customPlaylists, pl];
    } else {
      final next = [...customPlaylists];
      next[i] = pl;
      customPlaylists = next;
    }
    _rebuild();
    notifyListeners();
  }

  void removeCustomPlaylist(String id) {
    customPlaylists =
        customPlaylists.where((e) => e.id != id).toList();
    _rebuild();
    notifyListeners();
  }

  // Rail key ('★ name') just reordered from the phone remote — the TV
  // sidebar flashes it once, then the flag self-clears.
  String? lastMovedRailKey;
  Timer? _movedTimer;

  /// Reorder user lists to [ids] order (unknown ids ignored, missing
  /// lists keep their relative tail). Sidebar order follows instantly;
  /// persistence is the caller's job (server saves after this).
  void reorderCustomPlaylists(List<String> ids,
      {String? movedId}) {
    final byId = {
      for (final p in customPlaylists) p.id: p
    };
    final seen = <String>{};
    final next = <CustomPlaylist>[];
    for (final id in ids) {
      final p = byId[id];
      if (p != null && seen.add(id)) next.add(p);
    }
    for (final p in customPlaylists) {
      if (seen.add(p.id)) next.add(p);
    }
    customPlaylists = next;
    _rebuild();
    // Keep the sidebar selection on a live item.
    sideIndex = sideIndex.clamp(0, sideItems.length - 1);
    _restoreSideCursor();
    final moved = movedId == null ? null : byId[movedId];
    lastMovedRailKey =
        moved == null ? null : '★ ${moved.name}';
    notifyListeners();
    _movedTimer?.cancel();
    if (lastMovedRailKey != null) {
      _movedTimer = Timer(
          const Duration(milliseconds: 1400), () {
        if (_dead) return;
        lastMovedRailKey = null;
        notifyListeners();
      });
    }
  }

  void _rebuild() {
    final customRails = <ChannelRail>[
      for (final p in customPlaylists)
        if (p.channels.isNotEmpty)
          ChannelRail('★ ${p.name}',
              '${p.channels.length} channels • yours', p.channels),
    ];
    rails = [...customRails, ..._baseRails];
    allChannels = [
      for (final p in customPlaylists) ...p.channels,
      ..._baseChannels,
    ];
    _resortByHealth();
  }

  /// Merge probe results and reorder so fast streams come first
  /// (dead sink to the end). Deterministic: ties break by name.
  void applyHealth(Map<String, String> m) {
    if (m.isEmpty) return;
    healthById.addAll(m);
    _resortByHealth();
    sideIndex = sideIndex.clamp(0, sideItems.length - 1);
    _restoreSideCursor();
    notifyListeners();
  }

  void _resortByHealth() {
    int byHealth(TvChannel a, TvChannel b) {
      final r = StreamHealth.rank(healthById[a.id])
          .compareTo(StreamHealth.rank(healthById[b.id]));
      if (r != 0) return r;
      return a.name
          .toLowerCase()
          .compareTo(b.name.toLowerCase());
    }

    allChannels.sort(byHealth);
    for (final r in rails) {
      if (r.channels.length > 1) r.channels.sort(byHealth);
    }
  }

  void setCatalogLoading(String status) {
    catalogLoading = true;
    catalogStatus = status;
    notifyListeners();
  }

  void setServerInfo(
      {required int port,
      required List<String> urls,
      required bool online}) {
    serverPort = port;
    lanUrls = urls;
    serverOnline = online;
    notifyListeners();
  }

  void play(TvChannel ch) {
    playing = ch;
    isPlaying = true;
    // Fresh load: spinner shows immediately, error cleared.
    isBuffering = true;
    bufferingPct = 0;
    hasVideo = false;
    playError = null;
    prebuffering = false;
    prebufferedSec = 0;
    prebufferTarget = 0;
    playRequestedAt = DateTime.now();
    // Fresh tune-in always flashes the info bar (auto-hides in 5s).
    infoVisible = true;
    _armInfoTimer();
    playerBtnIndex = 0;
    playerFocusVisible = false; // Cancel starts unfocused; Down focuses it
    notifyListeners();
  }

  void stop() {
    // Exit player entirely (Back/Home) so the TV returns to rails.
    playing = null;
    isPlaying = false;
    isBuffering = false;
    bufferingPct = 0;
    hasVideo = false;
    playError = null;
    prebuffering = false;
    prebufferedSec = 0;
    infoVisible = false;
    _infoTimer?.cancel();
    notifyListeners();
  }

  void setBuffering(bool v, [double? pct]) {
    isBuffering = v;
    if (pct != null) bufferingPct = pct.clamp(0.0, 100.0);
    if (v) playError = null;
    notifyListeners();
  }

  void setPlayError(String? e) {
    final raw = (e == null || e.trim().isEmpty) ? null : e.trim();
    playError = raw == null ? null : _friendlyError(raw);
    if (playError != null) isBuffering = false;
    playerBtnIndex = 0; // error card always opens focused on Retry
    if (playError != null) playerFocusVisible = true;
    notifyListeners();
  }

  /// mpv/ffmpeg speak in hex codes and protocol jargon — translate the
  /// common failures into something a person on a couch can act on.
  static String _friendlyError(String raw) {
    final m = raw.toLowerCase();
    bool has(List<String> keys) {
      for (final k in keys) {
        if (m.contains(k)) return true;
      }
      return false;
    }

    // Dropped mid-stream connection (the ffurl_read family).
    if (has([
      'ffurl_read',
      'econnreset',
      'connection reset',
      'broken pipe',
      'timed out',
      'timeout',
      'tls ',
      'tls:',
      'handshake',
      'http error 5',
      '502',
      '503',
      '504',
      'empty reply',
      'failed to connect',
      'unable to open connection',
      'eof found',
      'eof reached',
      'connection refused',
    ])) {
      return 'The stream server dropped the connection. Hit Retry, or pick a green-dot channel.';
    }
    if (has([
      '404',
      'not found',
      'unable to resolve',
      'name or service not known',
      'no route to host',
      'gone (410)',
    ])) {
      return 'This channel link looks dead. Try another channel.';
    }
    if (has(['403', 'forbidden', 'access denied'])) {
      return 'The server refused to play this (region block or hotlink protection).';
    }
    if (has(['decoding audio'])) {
      return "This channel's audio can't be decoded — try Video only.";
    }
    if (has(['decoding video'])) {
      return "This channel's video can't be decoded on this device.";
    }
    if (has([
      'decoder not found',
      'codec not currently',
      'invalid data found when processing input',
      'could not find codec',
    ])) {
      return "This stream uses a format this device can't play.";
    }
    var t = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length > 180) t = '${t.substring(0, 180)}…';
    return t;
  }

  void setHasVideo(bool v) {
    if (hasVideo == v) return;
    hasVideo = v;
    if (v) playError = null;
    notifyListeners();
  }

  void setPlayingFlag(bool v) {
    isPlaying = v;
    notifyListeners();
  }

  void setVolume(double v) {
    volume = v.clamp(0.0, 1.0);
    notifyListeners();
  }

  void setMuted(bool v) {
    muted = v;
    notifyListeners();
  }

  // Player overlay button focus: while the loading spinner or the error
  // card is up, the TV D-pad (and the phone remote) drives THESE buttons
  // instead of the home grid behind — otherwise Cancel/Retry are
  // unreachable without a mouse.
  int playerBtnIndex = 0;
  // Whether the overlay focus is currently shown: Down focuses the
  // current button, Up unfocuses it again (loading opens unfocused).
  bool playerFocusVisible = false;

  bool get playerLoading =>
      playing != null &&
      playError == null &&
      (isBuffering || !hasVideo || prebuffering);

  bool get errorHasAudioFix =>
      playError != null &&
      playError!.toLowerCase().contains('audio');

  /// Buttons on the current player overlay: loading = [Cancel],
  /// error = [Retry, Channels] + [Video only] for audio failures.
  int get playerActionCount {
    if (playing == null) return 0;
    if (playError != null) return errorHasAudioFix ? 3 : 2;
    if (playerLoading) return 1;
    return 0;
  }

  /// D-pad inside a player overlay. Returns true when the key was
  /// consumed (focus moved or overlay dismissed). OK travels on via
  /// keyStream and the player screen activates playerBtnIndex, so this
  /// class stays free of player imports.
  bool _movePlayerOverlay(RemoteKey key) {
    final n = playerActionCount;
    if (n == 0) return false;
    switch (key) {
      case RemoteKey.left:
        playerBtnIndex = (playerBtnIndex - 1 + n) % n;
        playerFocusVisible = true;
        return true;
      case RemoteKey.right:
        playerBtnIndex = (playerBtnIndex + 1) % n;
        playerFocusVisible = true;
        return true;
      case RemoteKey.down:
        playerFocusVisible = true; // focus Cancel / current button
        return true;
      case RemoteKey.up:
        playerFocusVisible = false; // unfocus again
        return true;
      case RemoteKey.ok:
        return true; // screen activates playerBtnIndex via keyStream
      case RemoteKey.back:
      case RemoteKey.home:
        stop(); // Cancel / exit to channels
        return true;
      default:
        return false; // volume etc. fall through to the player listener
    }
  }

  // Player bottom info bar: TV tap or the phone remote toggles it, and it
  // always auto-hides 5s after being shown. One timer, restarted on show.
  bool infoVisible = true;
  Timer? _infoTimer;
  bool _dead = false;

  void _armInfoTimer() {
    _infoTimer?.cancel();
    _infoTimer = Timer(const Duration(seconds: 5), () {
      if (_dead) return;
      infoVisible = false;
      notifyListeners();
    });
  }

  void setInfoVisible(bool v) {
    infoVisible = v;
    if (v) {
      _armInfoTimer();
    } else {
      _infoTimer?.cancel();
    }
    notifyListeners();
  }

  void toggleInfo() => setInfoVisible(!infoVisible);

  /// User activity (D-pad, tap): show the bar if hidden and restart the
  /// 5s auto-hide clock. Silent when already visible — the caller's own
  /// notify covers the rebuild, so this never notifies in a loop.
  void pokeInfo() {
    if (!infoVisible) {
      setInfoVisible(true);
    } else {
      _armInfoTimer();
    }
  }

  void handleKey(RemoteKey key) {
    lastKey = key;
    lastKeyAt = DateTime.now();
    // While watching, CH+/CH- zaps to the neighbour channel directly.
    if (playing != null &&
        (key == RemoteKey.channelUp ||
            key == RemoteKey.channelDown)) {
      _zap(key == RemoteKey.channelUp ? -1 : 1);
      _keyCtrl.add(key);
      notifyListeners();
      return;
    }
    // A player overlay (loading / error) eats the D-pad so its buttons
    // stay reachable from the couch and the phone remote.
    if (playing != null &&
        playerActionCount > 0 &&
        _movePlayerOverlay(key)) {
      _keyCtrl.add(key);
      notifyListeners();
      return;
    }
    _applyFocusMove(key);
    _keyCtrl.add(key);
    notifyListeners();
  }

  void _zap(int dir) {
    if (allChannels.isEmpty) return;
    final i =
        allChannels.indexWhere((c) => c.id == playing?.id);
    final next = i < 0
        ? allChannels.first
        : allChannels[(i + dir) % allChannels.length];
    play(next);
  }

  void _applyFocusMove(RemoteKey key) {
    final n = sideItems.length;
    if (n == 0) return;
    sideIndex = sideIndex.clamp(0, n - 1);
    if (zone == FocusZone.sidebar) {
      switch (key) {
        case RemoteKey.up:
          _moveSide((sideIndex - 1) % n); // wrap the sidebar
          break;
        case RemoteKey.down:
          _moveSide((sideIndex + 1) % n); // wrap the sidebar
          break;
        case RemoteKey.right:
        case RemoteKey.ok:
          zone = FocusZone.grid; // dive into the channels
          break;
        case RemoteKey.back:
          break; // already top-level
        case RemoteKey.home:
          _moveSide(0);
          break;
        default:
          break;
      }
      return;
    }
    final list = displayChannels;
    if (list.isEmpty) {
      // Empty category (e.g. no favourites yet): only way out is left.
      if (key == RemoteKey.left ||
          key == RemoteKey.back ||
          key == RemoteKey.home) {
        zone = FocusZone.sidebar;
      }
      return;
    }
    final cols = gridColumns < 1 ? 1 : gridColumns;
    final col = gridIndex % cols;
    switch (key) {
      case RemoteKey.up:
        // Top row stays put — the ONLY way to the sidebar is left
        // off a left-edge tile. No more accidental jumps.
        gridIndex =
            (gridIndex - cols).clamp(0, list.length - 1);
        _saveSideCursor();
        break;
      case RemoteKey.down:
        gridIndex =
            (gridIndex + cols).clamp(0, list.length - 1);
        _saveSideCursor();
        break;
      case RemoteKey.left:
        if (col == 0) {
          _saveSideCursor();
          zone = FocusZone.sidebar; // step back to categories
        } else {
          gridIndex--;
          _saveSideCursor();
        }
        break;
      case RemoteKey.right:
        gridIndex =
            (gridIndex + 1).clamp(0, list.length - 1);
        _saveSideCursor();
        break;
      case RemoteKey.channelUp:
        _moveSide(sideIndex - 1);
        break;
      case RemoteKey.channelDown:
        _moveSide(sideIndex + 1);
        break;
      case RemoteKey.ok:
        final f = focusedChannel;
        if (f != null) play(f);
        break;
      case RemoteKey.back:
        zone = FocusZone.sidebar;
        break;
      case RemoteKey.home:
        _saveSideCursor();
        zone = FocusZone.sidebar;
        break;
      default:
        break; // volume / transport handled by player listener
    }
  }

  @override
  void dispose() {
    _dead = true;
    _infoTimer?.cancel();
    _movedTimer?.cancel();
    _keyCtrl.close();
    super.dispose();
  }
}
