import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/custom_playlist.dart';
import '../models/tv_channel.dart';
import 'remote_command.dart';
import 'stream_health.dart';

/// Which surface owns D-pad focus: the top pill nav or the channel grid.
enum FocusZone { nav, grid }

/// A pill in the top nav. [match] is a case-insensitive substring of the
/// target rail title (null = scroll to top). '★' matches pasted user lists.
class NavTab {
  final String label;
  final String? match;
  const NavTab(this.label, this.match);
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

  // Focus position for D-pad / phone remote navigation.
  int railIndex = 0;
  int cardIndex = 0;

  // Two focus zones: the top pill nav and the channel grid.
  FocusZone zone = FocusZone.grid;
  int tabIndex = 0;
  int activeTab = 0;

  // Per-category cursor memory (keyed by rail title so it survives list
  // inserts) + hold-glide speed for the phone remote (keys/sec).
  final Map<String, int> _railCursors = {};
  int repeatRate = 6;

  void setRepeatRate(int v) {
    repeatRate = v.clamp(2, 12);
    notifyListeners();
  }

  /// Switch rails with cursor memory: the old category keeps its position,
  /// the new one restores its own — never the 18th element elsewhere.
  void _moveRail(int next) {
    _saveCursor();
    railIndex = next.clamp(0, rails.length - 1);
    _restoreCursor();
  }

  void _saveCursor() {
    if (rails.isEmpty) return;
    final r = railIndex.clamp(0, rails.length - 1);
    _railCursors[rails[r].title] = cardIndex;
  }

  void _restoreCursor() {
    if (rails.isEmpty) {
      cardIndex = 0;
      return;
    }
    final r = railIndex.clamp(0, rails.length - 1);
    cardIndex = (_railCursors[rails[r].title] ?? 0)
        .clamp(0, rails[r].channels.length - 1);
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
    railIndex = 0;
    cardIndex = 0;
    _railCursors.clear();
    zone = FocusZone.grid;
    tabIndex = 0;
    activeTab = 0;
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
    _clampTabs();
    _resortByHealth();
  }

  /// Merge probe results and reorder so fast streams come first
  /// (dead sink to the end). Deterministic: ties break by name.
  void applyHealth(Map<String, String> m) {
    if (m.isEmpty) return;
    healthById.addAll(m);
    _resortByHealth();
    railIndex = railIndex.clamp(0, rails.isEmpty ? 0 : rails.length - 1);
    if (rails.isNotEmpty) {
      cardIndex = cardIndex.clamp(
          0, rails[railIndex].channels.length - 1);
    }
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

  TvChannel? get focusedChannel {
    if (rails.isEmpty) return null;
    final r = rails[railIndex.clamp(0, rails.length - 1)];
    if (r.channels.isEmpty) return null;
    return r.channels[cardIndex.clamp(0, r.channels.length - 1)];
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

  /// Pills shown in the top nav: Home + one per matching rail family.
  List<NavTab> get navTabs {
    const all = [
      NavTab('Home', null),
      NavTab('India', 'india'),
      NavTab('Global', 'global'),
      NavTab('News', 'news'),
      NavTab('Sports', 'sports'),
      NavTab('Music', 'music'),
      NavTab('Kids', 'kid'),
      NavTab('Movies', 'movie'),
      NavTab('My Lists', '★'),
    ];
    return [
      for (final t in all)
        if (t.match == null ||
            rails.any((r) => r.title
                .toLowerCase()
                .contains(t.match!.toLowerCase())))
          t
    ];
  }

  void _clampTabs() {
    final n = navTabs.length;
    if (n == 0) {
      tabIndex = 0;
      activeTab = 0;
      return;
    }
    tabIndex = tabIndex.clamp(0, n - 1);
    activeTab = activeTab.clamp(0, n - 1);
  }

  /// Activate the focused pill: jump the grid to its rail.
  void activateTab() {
    _clampTabs();
    if (navTabs.isEmpty) return;
    _saveCursor();
    activeTab = tabIndex;
    final match = navTabs[tabIndex].match;
    if (match == null) {
      railIndex = 0;
    } else {
      final i = rails.indexWhere((r) => r.title
          .toLowerCase()
          .contains(match.toLowerCase()));
      if (i >= 0) railIndex = i;
    }
    _restoreCursor();
    zone = FocusZone.grid;
  }

  void _applyFocusMove(RemoteKey key) {
    if (rails.isEmpty) return;
    _clampTabs();
    if (zone == FocusZone.nav) {
      final n = navTabs.length;
      switch (key) {
        case RemoteKey.left:
          if (n > 0) {
            tabIndex = (tabIndex - 1) % n;
            activeTab = tabIndex;
          }
          break;
        case RemoteKey.right:
          if (n > 0) {
            tabIndex = (tabIndex + 1) % n;
            activeTab = tabIndex;
          }
          break;
        case RemoteKey.down:
          zone = FocusZone.grid;
          break;
        case RemoteKey.ok:
          activateTab();
          break;
        case RemoteKey.back:
        case RemoteKey.home:
          stop();
          zone = FocusZone.grid;
          break;
        default:
          break;
      }
      return;
    }
    switch (key) {
      case RemoteKey.up:
        if (railIndex == 0) {
          _saveCursor();
          zone = FocusZone.nav; // rise into the pill nav
        } else {
          _moveRail(railIndex - 1);
        }
        break;
      case RemoteKey.down:
        _moveRail(
            (railIndex + 1).clamp(0, rails.length - 1));
        break;
      case RemoteKey.left:
        final len = rails[railIndex].channels.length;
        cardIndex = (cardIndex - 1) % len; // wrap within rail
        _saveCursor();
        break;
      case RemoteKey.right:
        final len = rails[railIndex].channels.length;
        cardIndex = (cardIndex + 1) % len; // wrap within rail
        _saveCursor();
        break;
      case RemoteKey.channelUp:
        _moveRail(
            (railIndex - 1).clamp(0, rails.length - 1));
        break;
      case RemoteKey.channelDown:
        _moveRail(
            (railIndex + 1).clamp(0, rails.length - 1));
        break;
      case RemoteKey.ok:
        final f = focusedChannel;
        if (f != null) play(f);
        break;
      case RemoteKey.back:
      case RemoteKey.home:
        stop();
        zone = FocusZone.grid;
        break;
      default:
        break; // volume / transport handled by player listener
    }
  }

  @override
  void dispose() {
    _keyCtrl.close();
    super.dispose();
  }
}
