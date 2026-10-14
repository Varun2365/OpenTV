// Inbuilt phone-remote server — same single-executable pattern as the
// FoodWastage LocalAdminServer: Flutter TV UI + HttpServer in one process.
// Phone on same Wi-Fi opens http://<pi-ip>:8080/remote and drives the TV
// in real time over WebSocket (<100ms), REST as fallback.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_state.dart';
import 'catalog_service.dart';
import 'custom_playlist_store.dart';
import 'pi_detector.dart';
import 'player_service.dart';
import 'remote_command.dart';
import 'stream_health.dart';
import '../models/custom_playlist.dart';
import '../models/tv_channel.dart';

class LocalRemoteServer {
  static HttpServer? _server;
  static AppState? _state;
  static PlayerService? _playerSvc;
  static Timer? _statusTimer;
  static DateTime _lastHttpAt =
      DateTime.fromMillisecondsSinceEpoch(0);

  /// Recompute web-remote link state: live WebSockets, or any HTTP hit in
  /// the last 45s (covers REST-only phones). Notifies TV only on change.
  static void _pushStatus() {
    final s = _state;
    if (s == null) return;
    final httpFresh = DateTime.now()
            .difference(_lastHttpAt)
            .inSeconds <
        45;
    final connected = _sockets.isNotEmpty || httpFresh;
    s.setRemoteStatus(
        connected: connected, clients: _sockets.length);
  }
  static int _port = 8080;
  static final _sockets = <WebSocket>{};

  static int get port => _port;
  static bool get running => _server != null;

  /// Gives the remote quality endpoint access to mpv track selection.
  static void attachPlayer(PlayerService p) => _playerSvc = p;

  static Future<int?> start(AppState state, {int wantPort = 8080}) async {
    if (_server != null) return _port;
    _state = state;
    for (var i = 0; i < 12; i++) {
      final p = wantPort + i;
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, p);
        _port = p;
        _server!.listen(_handle);
        final urls = await lanUrls(p);
        state.setServerInfo(port: p, urls: urls, online: true);
        // Link-state ticker for the TV's QR auto-show.
        _statusTimer?.cancel();
        _statusTimer = Timer.periodic(
            const Duration(seconds: 10), (_) => _pushStatus());
        _pushStatus();
        // Push now-playing to phones whenever TV state changes.
        state.addListener(_broadcastNow);
        debugPrint('OpenTV remote: http://127.0.0.1:$p/remote');
        for (final u in urls) {
          debugPrint('  phone remote: $u');
        }
        return p;
      } on SocketException {
        _server = null;
        continue;
      } catch (e) {
        debugPrint('remote bind failed: $e');
        return null;
      }
    }
    state.setServerInfo(
        port: wantPort, urls: const [], online: false);
    return null;
  }

  /// LAN URLs ranked so the QR/host pick is the address a phone can
  /// actually reach: real 192.168.x Wi-Fi first, then 10.x, then
  /// 172.16-31.x — Docker/WSL/VM/VPN/link-local addresses sink to the
  /// bottom instead of being picked first (the old wrong-IP bug).
  static Future<List<String>> lanUrls([int? port]) async {
    final p = port ?? _port;
    final found = <String>[];
    try {
      final scored = <_Nic>[];
      for (final ni in await NetworkInterface.list()) {
        final virt = RegExp(
                r'virtual|wsl|docker|vmware|virtualbox|vethernet|hyper-v|tailscale|zerotier|\btun\b|\btap\b',
                caseSensitive: false)
            .hasMatch(ni.name);
        for (final a in ni.addresses) {
          if (a.type != InternetAddressType.IPv4 ||
              a.isLoopback) {
            continue;
          }
          scored.add(_Nic(a.address, virt));
        }
      }
      scored.sort(
          (x, y) => _ipScore(x).compareTo(_ipScore(y)));
      found.addAll([for (final n in scored) n.addr]);
    } catch (_) {}
    if (found.isEmpty) found.add('127.0.0.1');
    return [for (final ip in found) 'http://$ip:$p/remote'];
  }

  static int _ipScore(_Nic n) {
    final a = n.addr;
    var s = 3; // unknown / CGNAT / other
    if (a.startsWith('192.168.')) {
      s = 0; // home/office Wi-Fi — almost always right
    } else if (a.startsWith('10.')) {
      s = 1;
    } else if (RegExp(r'^172\.(1[6-9]|2\d|3[01])\.')
        .hasMatch(a)) {
      s = 2;
    }
    if (n.virt) s += 10; // Docker, WSL, VMs, VPNs
    if (a.startsWith('169.254.')) s += 10; // link-local, rarely routable
    return s;
  }

  static Map<String, dynamic> _chJson(
      AppState s, TvChannel c) {
    final j = c.toJson();
    j['health'] = s.healthById[c.id] ?? 'unknown';
    j['fav'] = s.isFav(c.id);
    return j;
  }

  static void _broadcastNow() {
    final s = _state;
    if (s == null || _sockets.isEmpty) return;
    final msg = jsonEncode({
      'type': 'now',
      'playing':
          s.playing == null ? null : _chJson(s, s.playing!),
      'isPlaying': s.isPlaying,
      'buffering': s.isBuffering,
      'hasVideo': s.hasVideo,
      'playError': s.playError,
      'volume': s.volume,
      'muted': s.muted,
      'infoVisible': s.infoVisible,
      'playerListOpen': s.playerListOpen,
      'fullscreen': s.isFullscreen,
      'canFullscreen': !isFlutterPi,
      'zone': s.zone.name,
      'focus': s.focusedChannel == null
          ? null
          : _chJson(s, s.focusedChannel!),
    });
    for (final ws in _sockets.toList()) {
      try {
        ws.add(msg);
      } catch (_) {}
    }
  }

  static void _broadcastPlaylists() {
    final s = _state;
    if (s == null || _sockets.isEmpty) return;
    final msg = jsonEncode({
      'type': 'playlists',
      'playlists': [
        for (final p in s.customPlaylists) p.summaryJson()
      ],
    });
    for (final ws in _sockets.toList()) {
      try {
        ws.add(msg);
      } catch (_) {}
    }
  }

  static Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.headers.set('Access-Control-Allow-Headers', 'Content-Type');
    if (req.method == 'OPTIONS') {
      res.statusCode = 200;
      await res.close();
      return;
    }
    // Any real page/API hit marks a phone nearby (/health excluded so
    // uptime monitors can't fake a linked remote and suppress the QR).
    if (req.uri.path != '/health') {
      _lastHttpAt = DateTime.now();
      _pushStatus();
    }
    try {
      final path = req.uri.path;
      final s = _state;
      if (s == null) {
        res.statusCode = 500;
        res.write('not ready');
      } else if (path == '/ws' &&
          WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        _sockets.add(ws);
        _pushStatus();
        ws.add(jsonEncode({
          'type': 'hello',
          'playing': s.playing == null
              ? null
              : _chJson(s, s.playing!),
          'isPlaying': s.isPlaying,
          'infoVisible': s.infoVisible,
          'playerListOpen': s.playerListOpen,
          'fullscreen': s.isFullscreen,
          'canFullscreen': !isFlutterPi,
        }));
        ws.listen((raw) {
          try {
            final m =
                Map<String, dynamic>.from(jsonDecode(raw as String));
            _applyMessage(s, m);
          } catch (_) {}
        }, onDone: () {
          _sockets.remove(ws);
          _pushStatus();
        }, onError: (_) {
          _sockets.remove(ws);
          _pushStatus();
        });
        return; // upgraded — do not close
      } else if (req.method == 'GET' &&
          (path == '/' || path == '/remote' || path == '/index.html')) {
        res.headers.contentType = ContentType.html;
        res.write(_remoteHtml());
      } else if (req.method == 'GET' && path.startsWith('/img/')) {
        // Bundled artwork for the remote page (logo). Strict filename
        // whitelist — never serve arbitrary paths.
        final name = path.substring('/img/'.length);
        if (!RegExp(r'^[A-Za-z0-9_-]+\.png$').hasMatch(name)) {
          res.statusCode = 400;
          res.headers.contentType = ContentType.json;
          res.write(
              jsonEncode({'ok': false, 'error': 'bad image'}));
        } else {
          try {
            final data =
                await rootBundle.load('assets/images/$name');
            res.headers.contentType =
                ContentType('image', 'png');
            res.headers.set(
                'Cache-Control', 'public, max-age=86400');
            res.add(data.buffer.asUint8List());
          } catch (_) {
            res.statusCode = 404;
            res.write('not found');
          }
        }
      } else if (req.method == 'GET' && path == '/health') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'ok': true,
          'port': _port,
          'lan': await lanUrls(),
          'channels': s.allChannels.length,
          'playing': s.playing?.toJson(),
        }));
      } else if (req.method == 'GET' && path == '/api/now') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'playing': s.playing == null
              ? null
              : _chJson(s, s.playing!),
          'isPlaying': s.isPlaying,
          'buffering': s.isBuffering,
          'hasVideo': s.hasVideo,
          'playError': s.playError,
          'volume': s.volume,
          'muted': s.muted,
          'infoVisible': s.infoVisible,
          'playerListOpen': s.playerListOpen,
          'fullscreen': s.isFullscreen,
          'canFullscreen': !isFlutterPi,
          'zone': s.zone.name,
          'focus': s.focusedChannel == null
              ? null
              : _chJson(s, s.focusedChannel!),
        }));
      } else if (req.method == 'GET' && path == '/api/playerlist') {
        // Channels of the list currently playing (for the TV's
        // transparent player sidebar). Empty when nothing is playing.
        final list = s.playerListChannels;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'playingId': s.playing?.id,
          'title': s.playerListTitle,
          'count': list.length,
          'open': s.playerListOpen,
          'channels': [for (final c in list) _chJson(s, c)],
        }));
      } else if (req.method == 'POST' && path == '/api/playerlist') {
        // Phone "Channels" button: open/close/toggle the list on the TV.
        final body = await utf8.decoder.bind(req).join();
        try {
          final m = body.isEmpty
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(jsonDecode(body));
          final a = '${m['action'] ?? 'toggle'}'.toLowerCase();
          if (a == 'open') {
            s.openPlayerList();
          } else if (a == 'close') {
            s.closePlayerList();
          } else {
            s.togglePlayerList();
          }
          _broadcastNow();
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode(
              {'ok': true, 'open': s.playerListOpen}));
        } catch (e) {
          res.statusCode = 400;
          res.headers.contentType = ContentType.json;
          res.write(
              jsonEncode({'ok': false, 'error': '$e'}));
        }
      } else if (req.method == 'GET' && path == '/api/categories') {
        // Remote shows ONLY user-added lists — no built-in rails.
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          for (var i = 0; i < s.customPlaylists.length; i++)
            {
              'index': i,
              'id': s.customPlaylists[i].id,
              'title': s.customPlaylists[i].name,
              'subtitle':
                  '${s.customPlaylists[i].channels.length} channels • yours',
              'count': s.customPlaylists[i].channels.length,
            }
        ]));
      } else if (req.method == 'GET' && path == '/api/channels') {
        final q =
            (req.uri.queryParameters['q'] ?? '').toLowerCase();
        final cat = req.uri.queryParameters['category'] ?? '';
        final limit = (int.tryParse(
                    req.uri.queryParameters['limit'] ?? '60') ??
                60)
            .clamp(1, 5000);
        // Remote library = user-added lists only.
        final customChannels = <TvChannel>[
          for (final p in s.customPlaylists) ...p.channels,
        ];
        Iterable channels = customChannels;
        if (cat.isNotEmpty) {
          // Category can be a custom-list index, playlist id, or name.
          final idx = int.tryParse(cat);
          if (idx != null &&
              idx >= 0 &&
              idx < s.customPlaylists.length) {
            channels = s.customPlaylists[idx].channels;
          } else {
            final lc = cat.toLowerCase().replaceAll('★', '').trim();
            CustomPlaylist? match;
            for (final p in s.customPlaylists) {
              if (p.id.toLowerCase() == lc ||
                  p.name.toLowerCase() == lc ||
                  p.name.toLowerCase().contains(lc) ||
                  ('★ ${p.name}').toLowerCase().contains(lc)) {
                match = p;
                break;
              }
            }
            if (match != null) {
              channels = match.channels;
            } else {
              channels = customChannels.where((c) =>
                  c.category.toLowerCase().contains(lc) ||
                  c.name.toLowerCase().contains(lc));
            }
          }
        }
        final list = q.isEmpty
            ? channels.take(limit).toList()
            : channels
                .where((c) =>
                    c.name.toLowerCase().contains(q) ||
                    c.category.toLowerCase().contains(q))
                .take(limit)
                .toList();
        // Fast streams first so the phone's full lists open on winners.
        list.sort((a, b) => StreamHealth.rank(s.healthById[a.id])
            .compareTo(StreamHealth.rank(s.healthById[b.id])));
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(
            list.map((c) => _chJson(s, c as TvChannel)).toList()));
      } else if (req.method == 'GET' && path == '/api/favourites') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          for (final c in s.favouriteChannels) _chJson(s, c)
        ]));
      } else if (req.method == 'POST' && path == '/api/favourites') {
        final body = await utf8.decoder.bind(req).join();
        try {
          final m =
              Map<String, dynamic>.from(jsonDecode(body));
          final id = '${m['id'] ?? ''}';
          if (id.isEmpty) throw 'Missing id';
          await s.toggleFavourite(id);
          _broadcastNow(); // fav flags ride along for other phones
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({
            'ok': true,
            'fav': s.isFav(id),
            'favourites': s.favouriteIds,
          }));
        } catch (e) {
          res.statusCode = 400;
          res.headers.contentType = ContentType.json;
          res.write(
              jsonEncode({'ok': false, 'error': '$e'}));
        }
      } else if (req.method == 'GET' && path == '/api/playlists') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          for (final p in s.customPlaylists) p.summaryJson()
        ]));
      } else if (req.method == 'POST' && path == '/api/playlists') {
        final body = await utf8.decoder.bind(req).join();
        final m = Map<String, dynamic>.from(jsonDecode(body));
        final name =
            ('${m['name'] ?? ''}').trim().isEmpty
                ? 'My List'
                : '${m['name']}'.trim().substring(
                    0, '${m['name']}'.trim().length.clamp(0, 40));
        final url = '${m['url'] ?? ''}'.trim();
        // Remote-picked icon (Heroicons key) + opaque ARGB color.
        final iconRaw =
            '${m['icon'] ?? CustomPlaylist.defaultIcon}';
        final icon =
            RegExp(r'^[A-Za-z]{1,32}$').hasMatch(iconRaw)
                ? iconRaw
                : CustomPlaylist.defaultIcon;
        var color =
            int.tryParse('${m['color'] ?? ''}') ??
                CustomPlaylist.defaultColor;
        color = (color & 0xFFFFFFFF) | 0xFF000000;
        if (url.isEmpty) {
          res.statusCode = 400;
          res.write(jsonEncode(
              {'ok': false, 'error': 'Paste an M3U link first'}));
        } else {
          try {
            final id =
                'u${DateTime.now().millisecondsSinceEpoch}';
            final channels =
                await CatalogService.fetchCustomM3U(url,
                    idPrefix: id, category: name);
            final pl = CustomPlaylist(
                id: id,
                name: name,
                url: url,
                addedAt: DateTime.now(),
                channels: channels,
                icon: icon,
                color: color);
            s.upsertCustomPlaylist(pl);
            await CustomPlaylistStore.saveAll(s.customPlaylists);
            _broadcastPlaylists();
            _broadcastNow();
            res.headers.contentType = ContentType.json;
            res.write(jsonEncode({
              'ok': true,
              'playlist': pl.summaryJson(),
            }));
          } catch (e) {
            res.statusCode = 400;
            res.headers.contentType = ContentType.json;
            res.write(jsonEncode({'ok': false, 'error': '$e'}));
          }
        }
      } else if (req.method == 'DELETE' && path == '/api/database') {
        // CLEAR LISTS vault: everything content-related goes.
        await s.clearAllData();
        _broadcastPlaylists();
        _broadcastNow();
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'ok': true}));
      } else if ((req.method == 'DELETE' && path == '/api/playlists') ||
          (req.method == 'POST' &&
              path == '/api/playlists/delete')) {
        String id = req.uri.queryParameters['id'] ?? '';
        if (id.isEmpty && req.method == 'POST') {
          try {
            final body = await utf8.decoder.bind(req).join();
            if (body.isNotEmpty) {
              id = '${Map<String, dynamic>.from(jsonDecode(body))['id'] ?? ''}';
            }
          } catch (_) {}
        }
        if (id.isEmpty) {
          res.statusCode = 400;
          res.write(jsonEncode({'ok': false, 'error': 'Missing id'}));
        } else {
          s.removeCustomPlaylist(id);
          await CustomPlaylistStore.saveAll(s.customPlaylists);
          _broadcastPlaylists();
          _broadcastNow();
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'ok': true, 'removed': id}));
        }
      } else if (req.method == 'POST' &&
          path == '/api/playlists/reorder') {
        final body = await utf8.decoder.bind(req).join();
        try {
          final m =
              Map<String, dynamic>.from(jsonDecode(body));
          final ids = [
            for (final e in (m['order'] as List? ?? const []))
              '$e'
          ];
          final moved = '${m['moved'] ?? ''}';
          s.reorderCustomPlaylists(ids,
              movedId: moved.isEmpty ? null : moved);
          await CustomPlaylistStore.saveAll(s.customPlaylists);
          _broadcastPlaylists();
          _broadcastNow();
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'ok': true}));
        } catch (e) {
          res.statusCode = 400;
          res.headers.contentType = ContentType.json;
          res.write(
              jsonEncode({'ok': false, 'error': '$e'}));
        }
      } else if (req.method == 'GET' && path == '/api/recents') {
        // Last-played channels, most-recent-first (capped at 10).
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          for (final c in s.recentChannels)
            {
              ..._chJson(s, c),
              'playedAt':
                  s.recentAt[c.id]?.toIso8601String(),
            }
        ]));
      } else if (req.method == 'GET' && path == '/api/tracks') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'video': s.videoTracks,
          'selected': s.selectedVideoTrack,
          'quality': s.qualityLabel,
        }));
      } else if (req.method == 'POST' && path == '/api/tracks') {
        final body = await utf8.decoder.bind(req).join();
        try {
          final m =
              Map<String, dynamic>.from(jsonDecode(body));
          final id = '${m['video'] ?? 'auto'}';
          await _playerSvc?.setQuality(id);
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode(
              {'ok': true, 'selected': id}));
        } catch (e) {
          res.statusCode = 400;
          res.headers.contentType = ContentType.json;
          res.write(
              jsonEncode({'ok': false, 'error': '$e'}));
        }
      } else if (req.method == 'GET' && path == '/api/settings') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'prebufferSecs': s.prebufferSecs,
          'repeatRate': s.repeatRate,
          'autoQr': s.autoQr,
          'showPresets': s.showPresets,
          'stretchVideo': s.stretchVideo,
        }));
      } else if (req.method == 'POST' && path == '/api/settings') {
        final body = await utf8.decoder.bind(req).join();
        try {
          final m =
              Map<String, dynamic>.from(jsonDecode(body));
          var v = int.tryParse('${m['prebufferSecs']}') ??
              s.prebufferSecs;
          v = v.clamp(0, 30);
          s.setPrebufferSecs(v);
          var r = int.tryParse('${m['repeatRate']}') ??
              s.repeatRate;
          r = r.clamp(2, 12);
          s.setRepeatRate(r);
          final aq = m['autoQr'];
          final autoQr =
              aq == true || '$aq' == '1' || '$aq' == 'true';
          // Key absent (older clients) keeps the current value.
          if (m.containsKey('autoQr')) s.setAutoQr(autoQr);
          final sp = m['showPresets'];
          final showPresets =
              sp == true || '$sp' == '1' || '$sp' == 'true';
          if (m.containsKey('showPresets')) {
            s.setShowPresets(showPresets);
          }
          final sv = m['stretchVideo'];
          final stretch =
              sv == true || '$sv' == '1' || '$sv' == 'true';
          if (m.containsKey('stretchVideo')) {
            s.setStretchVideo(stretch);
          }
          try {
            final prefs =
                await SharedPreferences.getInstance();
            await prefs.setInt('opentv_prebuffer_secs', v);
            await prefs.setInt('opentv_repeat_rate', r);
            if (m.containsKey('autoQr')) {
              await prefs.setBool('opentv_auto_qr', s.autoQr);
            }
            if (m.containsKey('showPresets')) {
              await prefs.setBool(
                  'opentv_show_presets', s.showPresets);
            }
            if (m.containsKey('stretchVideo')) {
              await prefs.setBool(
                  'opentv_stretch', s.stretchVideo);
            }
          } catch (_) {}
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({
            'ok': true,
            'prebufferSecs': v,
            'repeatRate': r,
            'autoQr': s.autoQr,
            'showPresets': s.showPresets,
            'stretchVideo': s.stretchVideo,
          }));
        } catch (e) {
          res.statusCode = 400;
          res.headers.contentType = ContentType.json;
          res.write(
              jsonEncode({'ok': false, 'error': '$e'}));
        }
      } else if (req.method == 'POST' && path == '/api/key') {
        final body = await utf8.decoder.bind(req).join();
        final m = Map<String, dynamic>.from(jsonDecode(body));
        final key = remoteKeyFromString('${m['key']}');
        if (key == null) {
          res.statusCode = 400;
          res.write(jsonEncode({'ok': false}));
        } else {
          s.handleKey(key);
          _broadcastNow();
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'ok': true, 'key': m['key']}));
        }
      } else if (req.method == 'POST' && path == '/api/info') {
        final body = await utf8.decoder.bind(req).join();
        try {
          final m =
              Map<String, dynamic>.from(jsonDecode(body));
          if (m.containsKey('visible') && m['visible'] is bool) {
            s.setInfoVisible(m['visible'] as bool);
          } else {
            s.toggleInfo();
          }
          _broadcastNow();
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode(
              {'ok': true, 'infoVisible': s.infoVisible}));
        } catch (e) {
          res.statusCode = 400;
          res.headers.contentType = ContentType.json;
          res.write(
              jsonEncode({'ok': false, 'error': '$e'}));
        }
      } else if (req.method == 'POST' && path == '/api/play') {
        final body = await utf8.decoder.bind(req).join();
        final m = Map<String, dynamic>.from(jsonDecode(body));
        final id = '${m['id']}';
        final ch = s.allChannels.where((c) => c.id == id).firstOrNull ??
            s.focusedChannel;
        if (ch == null) {
          res.statusCode = 404;
          res.write(jsonEncode({'ok': false}));
        } else {
          s.play(ch);
          _broadcastNow();
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'ok': true, 'playing': _chJson(s, ch)}));
        }
      } else {
        res.statusCode = 404;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'ok': false, 'error': 'not found'}));
      }
    } catch (e) {
      res.statusCode = 500;
      res.write(jsonEncode({'ok': false, 'error': '$e'}));
    }
    await res.close();
  }

  static void _applyMessage(AppState s, Map<String, dynamic> m) {
    final t = '${m['type']}'.toLowerCase();
    if (t == 'key') {
      final k = remoteKeyFromString('${m['key']}');
      if (k != null) {
        s.handleKey(k);
        _broadcastNow();
      }
    } else if (t == 'play') {
      final id = '${m['id']}';
      for (final c in s.allChannels) {
        if (c.id == id) {
          s.play(c);
          _broadcastNow();
          break;
        }
      }
    } else if (t == 'info') {
      if (m.containsKey('visible') && m['visible'] is bool) {
        s.setInfoVisible(m['visible'] as bool);
      } else {
        s.toggleInfo();
      }
      _broadcastNow();
    } else if (t == 'plist' || t == 'playerlist') {
      final a = '${m['action'] ?? 'toggle'}'.toLowerCase();
      if (a == 'open') {
        s.openPlayerList();
      } else if (a == 'close') {
        s.closePlayerList();
      } else {
        s.togglePlayerList();
      }
      _broadcastNow();
    }
  }

  // -- Phone remote UI: sidebar + mosaic grid, single-file --
  // Design tokens: ink #0B0B0F, onyx #14141B, paper #F5F1E8,
  // muted #9A94A6, marigold #FFB338 signature glow.
  static String _remoteHtml() => r'''
<!doctype html><html lang="en"><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"/>
<meta name="theme-color" content="#0B0B0F"/>
<link rel="icon" type="image/png" href="/img/logo.png"/>
<title>OpenTV • Remote</title>
<style>
:root{--bg:#0B0B0F;--card:#14141B;--card2:#1E1E28;--deep:#0E0E13;--line:rgba(255,255,255,.09);
--hair:rgba(255,255,255,.12);--paper:#F5F1E8;--muted:#9A94A6;--gold:#FFB338;--gold-ink:#1A1206;
--gold-soft:rgba(255,179,56,.14);--green:#3DDC84;--red:#FF7A7A;--r:20px;--rs:14px;--topH:60px}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;padding:0;overflow-x:clip}
img{max-width:100%}
body{background:var(--bg);color:var(--paper);
font-family:"Google Sans",system-ui,-apple-system,"Segoe UI",Inter,Roboto,sans-serif;
max-width:480px;margin-inline:auto;min-height:100dvh;display:flex;flex-direction:column}
button{font:inherit;color:var(--paper);background:#23232F;border:1px solid var(--line);
border-radius:var(--rs);padding:13px 10px;font-size:14.5px;font-weight:650;cursor:pointer;min-height:52px;
transition:transform .08s ease,background .15s ease}
button:active{transform:scale(.965);background:#2A2A37}
button:disabled{opacity:.55;cursor:default;transform:none}
:focus-visible{outline:2px solid var(--gold);outline-offset:2px}
/* remote page: no press-selection visuals at all — buttons never look stuck */
#pg-remote button{-webkit-tap-highlight-color:transparent;-webkit-touch-callout:none;
user-select:none;-webkit-user-select:none;touch-action:manipulation}
#pg-remote button:active{transform:none}
#pg-remote button:focus,#pg-remote button:focus-visible{outline:none}
#pg-remote .dpad button:active{background:#23232F}
#pg-remote .ghost:active,#pg-remote .wide:active{background:#1B1B24}
#pg-remote .seg button:active{background:transparent}
/* top bar */
#topbar{position:sticky;top:0;z-index:20;height:var(--topH);display:flex;align-items:center;gap:10px;
padding:0 12px;background:rgba(11,11,15,.88);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);
border-bottom:1px solid var(--line)}
#burger{width:44px;height:44px;min-height:0;padding:0;border-radius:13px;display:flex;flex-direction:column;
align-items:center;justify-content:center;gap:5px;background:var(--card);flex:0 0 auto}
#burger span{display:block;width:18px;height:2px;border-radius:2px;background:var(--paper)}
#burger span:nth-child(2){width:13px;margin-right:5px;background:var(--gold)}
.brand{display:flex;align-items:center;gap:10px;min-width:0}
.logo{width:38px;height:38px;border-radius:10px;flex:0 0 auto;object-fit:contain}
.brand h1{font-size:15.5px;margin:0;line-height:1.1;white-space:nowrap}
.brand h1 small{display:block;font-size:11px;color:var(--muted);font-weight:500;letter-spacing:.02em}
.conn{margin-left:auto;margin-right:3px;width:11px;height:11px;border-radius:50%;
background:#FF5A5A;flex:0 0 auto;transition:background .25s ease,box-shadow .25s ease}
.conn.on{background:var(--green);box-shadow:0 0 10px rgba(61,220,132,.8)}
/* drawer */
#scrim{position:fixed;inset:0;background:rgba(0,0,0,.58);backdrop-filter:blur(2px);
opacity:0;pointer-events:none;transition:opacity .25s ease;z-index:30}
#scrim.show{opacity:1;pointer-events:auto}
#drawer{position:fixed;top:0;bottom:0;left:max(0px,calc(50vw - 240px));width:min(320px,86vw);
background:#101016;border-right:1px solid var(--line);z-index:40;display:flex;flex-direction:column;
transform:translateX(-106%);transition:transform .3s cubic-bezier(.32,.72,.24,1)}
#drawer.open{transform:none}
.drHead{display:flex;align-items:center;gap:10px;padding:14px 14px 12px;border-bottom:1px solid var(--line)}
.drHead .t{font-size:15px;font-weight:800}.drHead .t small{display:block;font-size:11px;color:var(--muted);font-weight:500}
#closeBtn{margin-left:auto;width:38px;height:38px;min-height:0;padding:0;border-radius:11px;font-size:16px;line-height:1}
.drNav{padding:10px;display:flex;flex-direction:column;gap:6px}
.navBtn{display:flex;align-items:center;gap:12px;text-align:left;padding:13px 12px;border-radius:14px;
background:transparent;border:1px solid transparent;min-height:56px;margin:0;width:100%}
.navBtn .ic{width:38px;height:38px;border-radius:12px;background:#1C1C26;border:1px solid var(--line);
display:flex;align-items:center;justify-content:center;font-size:17px;flex:0 0 auto}
.navBtn .lb{font-size:14.5px;font-weight:700}
.navBtn .lb small{display:block;font-size:11.5px;color:var(--muted);font-weight:500;margin-top:1px}
.navBtn .arw{margin-left:auto;color:var(--muted);font-size:15px}
.navBtn.on{background:var(--gold-soft);border-color:rgba(255,179,56,.32)}
.navBtn.on .ic{background:var(--gold);border-color:transparent;color:var(--gold-ink)}
.navBtn.on .arw{color:var(--gold)}
.drFoot{margin-top:auto;padding:14px;border-top:1px solid var(--line);font-size:11.5px;color:var(--muted)}
.drFoot b{color:var(--paper)}
/* pages */
#pages{flex:1;display:flex;flex-direction:column;min-width:0;overflow-x:clip}
#pg-ch{min-width:0;overflow-x:clip;overflow-y:visible}
.page{display:none}
.page.on{display:block;animation:fade .22s ease-out}
@keyframes fade{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
.padX{padding:14px 14px calc(20px + env(safe-area-inset-bottom))}
.eyebrow{display:flex;align-items:center;gap:8px;font-size:10.5px;letter-spacing:.16em;
color:var(--muted);text-transform:uppercase;font-weight:800;margin:0}
.liveDot{width:8px;height:8px;border-radius:50%;background:var(--green);box-shadow:0 0 10px var(--green);
animation:pulse 2.2s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.35}}
/* ── Remote command deck ──
   Signature: a recessed tactile puck — direction keys sunk into a dark
   well, OK raised as a gold medallion. Everything else stays quiet so
   the thumb finds the puck without looking. Scoped to #pg-remote so no
   other tab is touched. */
#pg-remote .padX{padding:16px 16px calc(24px + env(safe-area-inset-bottom))}
#pg-remote .eyebrow{font-size:10px;letter-spacing:.22em}
.now{position:relative;background:linear-gradient(165deg,#242430 0%,#14141B 55%,#101016 100%);
border:1px solid var(--line);border-radius:26px;padding:20px 20px 18px;overflow:hidden;
box-shadow:inset 0 1px 0 rgba(255,255,255,.09),0 22px 44px rgba(0,0,0,.4)}
.now:after{content:"";position:absolute;top:0;left:12%;right:12%;height:1px;
background:linear-gradient(90deg,transparent,rgba(255,179,56,.6),transparent)}
.now h2{margin:10px 0 4px;font-size:26px;line-height:1.12;letter-spacing:-.015em;font-weight:800}
.now p{margin:0;font-size:13px;color:var(--muted)}
#chanBtnWrap{margin-top:14px;display:none}
#chanBtn{width:100%;background:transparent;color:var(--gold);border:1px solid rgba(255,179,56,.45);
font-weight:800;box-shadow:none}
#chanBtn:active{background:var(--gold-soft)}
.deck{margin-top:14px;background:linear-gradient(180deg,#15151C,#101016);border:1px solid var(--line);
border-radius:26px;padding:20px 16px 18px;
box-shadow:inset 0 1px 0 rgba(255,255,255,.06),0 18px 40px rgba(0,0,0,.35)}
.transport{display:grid;grid-template-columns:1.2fr 1fr 1fr 1fr;gap:8px;margin:0 0 18px}
.transport button{font-size:13px;border-radius:16px;min-height:56px}
#ppBtn{background:linear-gradient(180deg,#FFC65E,var(--gold));color:var(--gold-ink);border:0;font-weight:800;
box-shadow:0 8px 24px rgba(255,179,56,.3),inset 0 1px 0 rgba(255,255,255,.45)}
#ppBtn:active{background:var(--gold)}
#pg-remote .ghost{background:#1E1E28;border-color:rgba(255,255,255,.1);border-radius:16px}
#infoBtn.on{background:var(--gold-soft);border-color:rgba(255,179,56,.55);color:var(--gold)}
#fsBtn.on{background:var(--gold-soft);border-color:rgba(255,179,56,.55);color:var(--gold)}
#muteBtn.on{background:rgba(255,90,90,.12);border-color:rgba(255,90,90,.5);color:#FF7A7A}
.puckLabel{display:block;text-align:center}
.dpad{position:relative;display:grid;grid-template-columns:66px 92px 66px;grid-template-rows:60px 82px 60px;
gap:8px;justify-content:center;align-items:center;margin:10px auto 2px;width:fit-content;padding:18px;
background:radial-gradient(circle at 50% 42%,#1D1D27 0%,#121218 68%);border:1px solid var(--line);
border-radius:36px;box-shadow:inset 0 2px 12px rgba(0,0,0,.55),inset 0 1px 0 rgba(255,255,255,.05)}
.dpad button{font-size:18px;padding:0;border-radius:20px;background:#262633;border-color:rgba(255,255,255,.1);
box-shadow:0 4px 12px rgba(0,0,0,.4),inset 0 1px 0 rgba(255,255,255,.1)}
.ok{background:linear-gradient(180deg,#FFC65E,var(--gold))!important;color:var(--gold-ink)!important;
border-color:transparent!important;border-radius:50%!important;width:92px;height:82px;font-size:15px!important;
font-weight:800!important;letter-spacing:.08em;
box-shadow:0 0 0 7px var(--gold-soft),0 10px 28px rgba(255,179,56,.4),inset 0 1px 0 rgba(255,255,255,.5)!important}
.ok:active{background:var(--gold)!important}
.stepGrid{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:16px}
.stepGrid .ctl{margin-top:0}
.ctl{margin-top:16px}
.seg{display:flex;border:1px solid var(--line);border-radius:18px;overflow:hidden;background:#0D0D12;
box-shadow:inset 0 2px 8px rgba(0,0,0,.5)}
.seg button{flex:1;border:0;border-radius:0;background:transparent;min-height:60px;font-size:15px;margin:0;
font-weight:800;letter-spacing:.04em}
.seg button+button{border-left:1px solid var(--line)}
.seg button:active{background:#23232F}
.util{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;margin-top:16px}
.util button{border-radius:16px;font-size:12.5px;min-height:54px}
.rmHint{font-size:11.5px;color:var(--muted);text-align:center;margin:14px 2px 0;line-height:1.5}
.hint{font-size:11.5px;color:var(--muted);text-align:center;margin:12px 2px 0;line-height:1.5}
/* channels: full-bleed chip bar + zero-gap mosaic */
.chHead{width:100%;max-width:100%;box-sizing:border-box;margin:0;background:#101016;border-top:1px solid var(--line);
border-bottom:1px solid var(--line);position:sticky;top:var(--topH);z-index:6}
.chips{display:flex;gap:8px;overflow-x:auto;overflow-y:hidden;padding:10px 14px;scrollbar-width:none;
-webkit-overflow-scrolling:touch;overscroll-behavior-x:contain;touch-action:pan-x pan-y;
max-height:68px;transition:max-height .3s cubic-bezier(.32,.72,.24,1),opacity .22s ease,padding .3s ease}
#pg-ch.noChips .chips{max-height:0;opacity:0;padding-top:0;padding-bottom:0}
.chHead .searchBox{padding:0 14px 12px}
.chips::-webkit-scrollbar{display:none}
.chip{flex:0 0 auto;min-height:44px;font-size:13px;font-weight:700;padding:10px 18px;
border-radius:999px;margin:0;white-space:nowrap;background:#1B1B24}
.chip.on{background:var(--paper);color:#141418;border-color:transparent}
.chTools{padding:10px 14px 2px}
.count{font-size:12px;color:var(--muted);margin:0 0 10px}
.searchBox input{width:100%;padding:13px 14px;border-radius:13px;border:1px solid var(--line);
background:var(--deep);color:var(--paper);font-size:15px;font-family:inherit}
.searchBox input:focus{outline:2px solid var(--gold);outline-offset:1px}
.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:0;margin:0;width:100%;max-width:100%;
box-sizing:border-box;border-left:1px solid var(--hair);border-top:1px solid var(--hair);background:var(--deep);overflow-x:clip}
.tile{border-radius:0px;border:0;border-right:1px solid var(--hair);border-bottom:1px solid var(--hair);
background:var(--card);padding:14px 8px 12px;min-height:136px;display:flex;flex-direction:column;
align-items:center;justify-content:center;gap:7px;text-align:center;cursor:pointer;color:var(--paper);
font:inherit;width:auto;min-width:0;max-width:100%;overflow:hidden;margin:0;min-height:136px}
.tile:active{background:#20202C;transform:none}
.tile img{width:46px;height:46px;border-radius:12px;object-fit:cover;background:var(--deep);flex:0 0 auto}
.tile .fb{width:46px;height:46px;border-radius:12px;background:var(--deep);display:flex;align-items:center;
justify-content:center;font-size:20px;flex:0 0 auto}
.tile .t{font-size:12.5px;font-weight:700;line-height:1.28;display:-webkit-box;-webkit-line-clamp:2;
-webkit-box-orient:vertical;overflow:hidden;max-width:100%}
.tile .c{font-size:10.5px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}
.tile .dotrow{display:flex;align-items:center;gap:5px}
.tile .play{font-size:10px;letter-spacing:.14em;color:var(--gold);font-weight:800}
.empty{padding:30px 22px;text-align:center}
.empty .big{font-size:34px;margin-bottom:8px}
.empty h3{margin:0 0 6px;font-size:16px}
.empty p{margin:0 0 14px;font-size:13px;color:var(--muted);line-height:1.55}
.empty .go{background:var(--gold);color:var(--gold-ink);border:0;font-weight:800;padding:13px 20px}
/* lists + settings */
.pl{background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:16px}
.pl h3{margin:0 0 3px;font-size:16px;letter-spacing:-.01em}
.pl .sub{margin:0 0 13px;font-size:12.5px;color:var(--muted);line-height:1.55}
.pl input{width:100%;padding:13px 14px;border-radius:13px;border:1px solid var(--line);
background:var(--deep);color:var(--paper);font-size:15px;font-family:inherit;margin-bottom:8px}
.pl input:focus{outline:2px solid var(--gold);outline-offset:1px}
.pl .add{width:100%;background:var(--gold);color:var(--gold-ink);border:0;font-weight:800}
.plmsg{font-size:12.5px;min-height:18px;margin:9px 0 2px;color:var(--muted);line-height:1.5}
.plmsg.ok{color:var(--green)}.plmsg.err{color:var(--red)}
/* lists: quiet ledger — one hairline, one gold action, nothing else */
.listsTitle{margin:8px 0 2px;font-size:24px;letter-spacing:-.015em;line-height:1.15}
.listsSub{margin:0;font-size:12.5px;color:var(--muted)}
.addNew{width:100%;background:var(--gold);color:var(--gold-ink);border:0;font-weight:800;
border-radius:15px;margin:14px 0 0;box-shadow:0 6px 22px rgba(255,179,56,.25)}
.addNew:active{background:#FFC25E}
/* bottom-sheet dialog + confirm — one surface, two quiet actions */
.ovl{position:fixed;inset:0;z-index:50;display:none;align-items:flex-end;justify-content:center;
background:rgba(0,0,0,.62);backdrop-filter:blur(3px);-webkit-backdrop-filter:blur(3px)}
.ovl.show{display:flex}
.dlg{width:100%;max-width:480px;background:#14141B;border:1px solid var(--line);border-bottom:0;
border-radius:22px 22px 0 0;padding:20px 18px calc(20px + env(safe-area-inset-bottom));
box-shadow:0 -18px 60px rgba(0,0,0,.5);animation:sheet .26s cubic-bezier(.32,.72,.24,1)}
@keyframes sheet{from{opacity:0;transform:translateY(26px)}to{opacity:1;transform:none}}
.dlgTitle{margin:6px 0 14px;font-size:19px;letter-spacing:-.01em}
.dlg input{width:100%;padding:14px;border-radius:14px;border:1px solid var(--hair);
background:var(--deep);color:var(--paper);font-size:15px;font-family:inherit;transition:border-color .15s ease,box-shadow .15s ease}
.dlg input::placeholder{color:#5C5C68}
.dlg input:focus{outline:none;border-color:var(--gold);box-shadow:0 0 0 3px var(--gold-soft)}
.urlWrap{display:flex;gap:8px;align-items:stretch}
.urlWrap input{flex:1;min-width:0;margin:0}
.pasteBtn{flex:0 0 auto;display:flex;align-items:center;gap:6px;min-height:0;margin:0;
padding:0 14px;border-radius:14px;font-size:13px;font-weight:800;background:#23232F;white-space:nowrap}
.pasteBtn:active{color:var(--gold)}
.dlgActs{display:grid;grid-template-columns:1fr 1.4fr;gap:8px;margin-top:14px}
.dlgActs .ghost{background:transparent}
.dlgActs .add{background:var(--gold);color:var(--gold-ink);border:0;font-weight:800}
.dlgActs .danger{background:rgba(255,90,90,.1);border:1px solid rgba(255,90,90,.45);
color:#FF7A7A;font-weight:800}
.dlgActs .danger:disabled{opacity:.35}
.cfmSub{margin:0 0 2px;font-size:13.5px;color:var(--muted);line-height:1.55}
.cfmSub b{color:var(--paper)}
.fld{display:block;margin:0 0 12px}
.fld>span{display:block;font-size:11px;letter-spacing:.1em;text-transform:uppercase;
color:var(--muted);font-weight:800;margin:0 2px 6px}
.ledger{margin-top:16px;border-top:1px solid var(--hair)}
.lrow{display:flex;align-items:stretch;border-bottom:1px solid var(--hair);background:transparent}
.lmove{display:flex;flex-direction:column;justify-content:center;gap:3px;padding-right:4px;flex:0 0 auto}
.lmove button{width:32px;height:28px;min-height:0;padding:0;margin:0;border-radius:9px;font-size:10px;
color:var(--muted);background:transparent;border:1px solid transparent}
.lmove button:disabled{opacity:.22}
.lmove button:active{color:var(--gold);transform:none}
.lmain{flex:1;min-width:0;display:flex;align-items:center;gap:12px;text-align:left;border:0;border-radius:0;
background:transparent;padding:13px 4px;margin:0;min-height:60px}
.lstar{color:var(--gold);font-size:14px;flex:0 0 auto}
.ltx{min-width:0;flex:1}
.ltx b{font-size:14.5px;display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ltx span{font-size:11.5px;color:var(--muted)}
.lgo{color:var(--muted);font-size:16px;flex:0 0 auto}
.lmain:active .lgo{color:var(--gold)}
.lrm{flex:0 0 auto;align-self:center;border:1px solid transparent;border-radius:12px;background:transparent;
color:var(--muted);min-height:0;width:40px;height:40px;padding:0;margin:0 0 0 4px;
display:flex;align-items:center;justify-content:center}
.lrm:active{color:#FF7A7A;background:rgba(255,90,90,.1);border-color:rgba(255,90,90,.35);transform:none}
.lEmpty{padding:26px 6px;text-align:center;font-size:12.5px;color:var(--muted);line-height:1.6}
/* recents: numbered list rows, most recent first */
.rrow{display:flex;align-items:center;gap:12px;width:100%;text-align:left;border:0;border-bottom:1px solid var(--hair);
border-radius:0;background:transparent;padding:11px 4px;margin:0;min-height:62px}
.rrow:active{background:#1B1B24;transform:none}
.rrow img{width:42px;height:42px;border-radius:12px;object-fit:cover;background:var(--deep);flex:0 0 auto}
.rrow .rfb{width:42px;height:42px;border-radius:12px;background:var(--deep);display:flex;align-items:center;justify-content:center;font-size:19px;flex:0 0 auto}
.rrow .rn{font-size:11px;color:var(--muted);font-weight:800;font-variant-numeric:tabular-nums;flex:0 0 auto;width:18px}
.rrow .rtx{min-width:0;flex:1}
.rrow .rtx b{font-size:14px;display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.rrow .rtx span{font-size:11.5px;color:var(--muted)}
.rrow .rt{font-size:11px;color:var(--muted);font-weight:600;white-space:nowrap;flex:0 0 auto}
.pl input[type=range]{accent-color:var(--gold);height:42px;padding:0;border:0;background:transparent;min-height:0;margin:6px 0 2px}
.setval{font-size:30px;font-weight:800;font-variant-numeric:tabular-nums;letter-spacing:-.02em;margin:6px 0 2px}
.setval small{font-size:14px;color:var(--muted);font-weight:600}
.icRow{display:flex;align-items:center;gap:10px;margin:2px 0 8px}
.icLbl{font-size:11px;letter-spacing:.1em;text-transform:uppercase;color:var(--muted);font-weight:800}
.icPick{width:52px;height:52px;min-height:0;border-radius:14px;background:var(--deep);border:1px solid var(--line);font-size:24px;display:flex;align-items:center;justify-content:center;margin:0}
.icName{font-size:13px;color:var(--paper);font-weight:700}
.swRow{display:flex;gap:8px;flex-wrap:wrap;margin:0 0 4px}
.sw{width:34px;height:34px;min-height:0;min-width:0;padding:0;margin:0;border-radius:50%;border:2px solid transparent}
.sw.on{border-color:#fff}
.icGrid{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;max-height:320px;overflow-y:auto;margin-top:10px}
.icBtn{display:flex;flex-direction:column;align-items:center;gap:4px;padding:10px 4px;border-radius:14px;background:var(--deep);border:1px solid var(--line);font-size:22px;min-height:0;margin:0;color:var(--paper)}
.icBtn small{font-size:10px;color:var(--muted);font-weight:600}
.icBtn.on{border-color:var(--gold);background:var(--gold-soft)}
.ldot{width:34px;height:34px;border-radius:11px;display:flex;align-items:center;justify-content:center;font-size:17px;flex:0 0 auto}
.tile{position:relative}
.fstar{position:absolute;top:6px;right:6px;width:34px;height:34px;min-height:0;min-width:0;padding:0;margin:0;border-radius:50%;background:rgba(0,0,0,.5);border:1px solid var(--line);color:#6E6A80;font-size:15px;line-height:1;display:flex;align-items:center;justify-content:center;z-index:2}
.fstar.on{color:var(--gold);border-color:rgba(255,179,56,.45)}
.secT{font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:var(--muted);font-weight:800;margin:0;padding:12px 14px 0}
.favStrip{display:flex;gap:8px;overflow-x:auto;padding:4px 14px 12px;scrollbar-width:none}
.favStrip::-webkit-scrollbar{display:none}
.favChip{flex:0 0 auto;display:flex;align-items:center;gap:8px;padding:8px 8px 8px 8px;border-radius:999px;background:var(--card);border:1px solid var(--line);color:var(--paper);font:inherit;font-size:12.5px;font-weight:700;min-height:0;margin:0;max-width:220px}
.favChip img{width:30px;height:30px;border-radius:50%;object-fit:cover;background:var(--deep);flex:0 0 auto}
.favChip span.nm{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.favChip .x{color:var(--gold);font-size:14px;flex:0 0 auto;padding:4px 6px}
#chanBtnWrap{margin-top:12px;display:none}
#chanBtn{width:100%;background:var(--gold);color:var(--gold-ink);border:0;font-weight:800;
box-shadow:0 6px 22px rgba(255,179,56,.25)}
#chanBtn:active{background:#FFC25E}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
</style></head><body>
<div id="scrim" onclick="closeDrawer()"></div>
<aside id="drawer" aria-label="Menu">
<div class="drHead"><img class="logo" src="/img/logo.png" alt="OpenTV"/>
<div class="t">OpenTV<small>Phone remote</small></div>
<button id="closeBtn" onclick="closeDrawer()" aria-label="Close menu">✕</button></div>
<nav class="drNav">
<button class="navBtn on" id="nv-remote" onclick="tab('remote')"><span class="ic">◉</span><span class="lb">Remote<small>D-pad • play • volume</small></span><span class="arw">›</span></button>
<button class="navBtn" id="nv-ch" onclick="tab('ch')"><span class="ic">▤</span><span class="lb">Channels<small>Your lists • tap to play</small></span><span class="arw">›</span></button>
<button class="navBtn" id="nv-recents" onclick="tab('recents')"><span class="ic">🕐</span><span class="lb">Recents<small>Last played • tap to replay</small></span><span class="arw">›</span></button>
<button class="navBtn" id="nv-lists" onclick="tab('lists')"><span class="ic">★</span><span class="lb">Lists<small>Add • view • remove</small></span><span class="arw">›</span></button>
<button class="navBtn" id="nv-settings" onclick="tab('settings')"><span class="ic">⚙</span><span class="lb">Settings<small>Playback buffer</small></span><span class="arw">›</span></button>
</nav>
<div class="drFoot" id="drFoot">Same Wi-Fi • real-time<br/><b id="drConn">Link…</b> — buttons answer in under 100ms.</div>
</aside>
<header id="topbar">
<button id="burger" onclick="toggleDrawer()" aria-label="Open menu" aria-expanded="false"><span></span><span></span><span></span></button>
<div class="brand"><img class="logo" src="/img/logo.png" alt="OpenTV"/><h1>OpenTV<small id="brandSub">Remote</small></h1></div>
<div class="conn" id="conn" role="status" aria-label="Connection"></div>
</header>
<main id="pages">
<section class="page on" id="pg-remote"><div class="padX">
<div class="now"><p class="eyebrow"><span class="liveDot"></span>On the TV</p><h2 id="np">—</h2><p id="npsub">Pick a channel from Channels</p>
<div id="chanBtnWrap"><button id="chanBtn" onclick="openPlayerList()">☰ Channels — this list</button></div>
</div>
<div class="deck"><div class="transport">
<button onclick="key('playPause')" id="ppBtn">⏯ Play</button>
<button class="ghost" onclick="key('back')">← Back</button>
<button class="ghost" onclick="key('home')">⌂ Home</button>
<button class="ghost" id="infoBtn" onclick="info()">ⓘ Info</button>
</div>
<p class="eyebrow puckLabel">Point &amp; glide</p>
<div class="dpad">
<span></span><button onpointerdown="hold('up',event,true)" onpointerup="unhold()" onpointerleave="unhold()" onpointercancel="unhold()" oncontextmenu="return false" aria-label="Up">▲</button><span></span>
<button onpointerdown="hold('left',event)" onpointerup="unhold()" onpointerleave="unhold()" onpointercancel="unhold()" oncontextmenu="return false" aria-label="Left">◀</button><button class="ok" onclick="key('ok')">OK</button><button onpointerdown="hold('right',event)" onpointerup="unhold()" onpointerleave="unhold()" onpointercancel="unhold()" oncontextmenu="return false" aria-label="Right">▶</button>
<span></span><button onpointerdown="hold('down',event,true)" onpointerup="unhold()" onpointerleave="unhold()" onpointercancel="unhold()" oncontextmenu="return false" aria-label="Down">▼</button><span></span>
</div>
<div class="stepGrid">
<div class="ctl"><p class="eyebrow">Channel</p>
<div class="seg"><button onclick="key('channelUp')">CH ＋</button><button onclick="key('channelDown')">CH －</button></div></div>
<div class="ctl"><p class="eyebrow">Volume</p>
<div class="seg"><button onpointerdown="hold('volUp',event)" onpointerup="unhold()" onpointerleave="unhold()" onpointercancel="unhold()" oncontextmenu="return false" aria-label="Volume up">VOL ＋</button><button onpointerdown="hold('volDown',event)" onpointerup="unhold()" onpointerleave="unhold()" onpointercancel="unhold()" oncontextmenu="return false" aria-label="Volume down">VOL －</button></div></div>
</div>
<div class="util"><button class="ghost" id="favBtn" onclick="toggleFavPlaying()">☆ Favourite</button><button class="ghost" id="fsBtn" onclick="key('fullscreen')">⛶ Fullscreen</button><button class="ghost" id="muteBtn" onclick="key('mute')">Mute</button></div>
<p class="rmHint">Hold ▲ ▼ ◀ ▶ or VOL to glide • OK selects</p></div>
</div></section>
<section class="page" id="pg-ch">
<div class="chHead">
<div class="chips" id="chips"></div>
<div class="searchBox"><input id="q" placeholder="Search in this list…" oninput="search(this.value)" autocomplete="off"/></div>
</div>
<div class="chTools"><div class="count" id="chCount"></div></div>
<div id="favWrap"></div>
<div class="grid" id="grid"></div>
<div class="empty" id="chEmpty" style="display:none"><div class="big">📺</div>
<h3>No lists yet</h3><p>Paste an M3U link under Lists and it appears here as its own tab.</p>
<button class="go" onclick="tab('lists')">＋ Add a list</button></div>
</section>
<section class="page" id="pg-recents"><div class="padX">
<p class="eyebrow">History</p>
<h2 class="listsTitle">Recents</h2>
<p class="listsSub" id="recCount">Last played first</p>
<div class="ledger" id="recList" style="margin-top:12px"></div>
</div></section>
<section class="page" id="pg-lists"><div class="padX">
<p class="eyebrow">Library</p>
<h2 class="listsTitle">Lists</h2>
<p class="listsSub" id="listsCount">Your saved playlists</p>
<button class="addNew" onclick="openAdd()">＋ Add New List</button>
<div class="ledger" id="plList"></div>
</div>
<div class="ovl" id="addOvl" onclick="if(event.target===this)closeAdd()">
<div class="dlg" role="dialog" aria-modal="true" aria-label="Add new list">
<p class="eyebrow">New list</p>
<h3 class="dlgTitle">Add to TV</h3>
<label class="fld"><span>Name</span><input id="plName" placeholder="e.g. Sports, Tamil, Kids" maxlength="40" autocomplete="off"/></label>
<label class="fld"><span>M3U link</span><span class="urlWrap"><input id="plUrl" placeholder="https://…/playlist.m3u" inputmode="url" autocomplete="off"/><button class="pasteBtn" onclick="pasteUrl()" aria-label="Paste link from clipboard">⧉ Paste</button></span></label>
<div class="icRow"><span class="icLbl">Icon</span><button class="icPick" id="icPick" onclick="openIcons()">📺</button><span class="icName" id="icName">TV</span></div>
<div class="swRow" id="swRow"></div>
<div class="plmsg" id="plMsg"></div>
<div class="dlgActs"><button class="ghost" onclick="closeAdd()">Cancel</button><button class="add" id="plBtn" onclick="addPlaylist()">Save</button></div>
</div>
</div>
<div class="ovl" id="iconOvl" onclick="if(event.target===this)closeIcons()">
<div class="dlg" role="dialog" aria-modal="true" aria-label="Pick an icon">
<p class="eyebrow">Icon</p>
<h3 class="dlgTitle">Pick a sidebar icon</h3>
<div class="icGrid" id="icGrid"></div>
<div class="dlgActs"><button class="ghost" onclick="closeIcons()">Done</button></div>
</div>
</div>
<div class="ovl" id="cfmOvl" onclick="if(event.target===this)closeCfm()">
<div class="dlg" role="alertdialog" aria-modal="true" aria-label="Remove list">
<p class="eyebrow">Remove</p>
<h3 class="dlgTitle">Remove this list?</h3>
<p class="cfmSub" id="cfmName"></p>
<div class="dlgActs"><button class="ghost" onclick="closeCfm()">Keep</button><button class="danger" id="cfmYes" onclick="doDel()">Remove</button></div>
</div>
</div>
</section>
<section class="page" id="pg-settings"><div class="padX">
<div class="pl"><p class="eyebrow">Settings</p><h3 style="margin-top:8px">Playback buffer</h3>
<p class="sub">Collect N seconds before starting — one initial wait, then smooth. Applies to the next channel you play. 0 = off.</p>
<div class="setval" id="bufVal">5<small>s</small></div>
<input id="bufRange" type="range" min="0" max="30" step="1" value="5" oninput="bufPreview(this.value)"/>
<button class="add" id="bufBtn" onclick="saveBuffer()">Save buffer</button>
<div class="plmsg" id="bufMsg"></div>
<div class="setval" id="repVal">6/s</div>
<p class="sub">Hold ◀ ▶ to glide across channels — keys per second.</p>
<input id="repRange" type="range" min="2" max="12" step="1" value="6" oninput="repPreview(this.value)"/>
<label style="display:flex;align-items:center;gap:10px;margin:14px 0 2px;font-size:13px;color:var(--paper)"><input id="autoQr" type="checkbox" checked onchange="saveQrOnly(this.checked)" style="width:22px;height:22px;accent-color:var(--gold);flex:0 0 auto"/><span>Pop up the TV QR code when no phone is linked</span></label>
<label style="display:flex;align-items:center;gap:10px;margin:10px 0 2px;font-size:13px;color:var(--paper)"><input id="showPresets" type="checkbox" checked onchange="savePresetsOnly(this.checked)" style="width:22px;height:22px;accent-color:var(--gold);flex:0 0 auto"/><span>Show built-in categories in the TV sidebar</span></label>
<label style="display:flex;align-items:center;gap:10px;margin:10px 0 2px;font-size:13px;color:var(--paper)"><input id="stretchVideo" type="checkbox" onchange="saveStretchOnly(this.checked)" style="width:22px;height:22px;accent-color:var(--gold);flex:0 0 auto"/><span>Stretch video to fill the screen (off = original shape)</span></label>
<div class="hint">5–10s is the sweet spot on Pi 4. Bigger tank = longer start wait + more RAM.</div></div>
<div class="pl" style="margin-top:12px;border-color:rgba(255,90,90,.35)"><p class="eyebrow" style="color:var(--red)">Danger zone</p><h3 style="margin:8px 0 4px">Clear everything</h3>
<p class="sub">Wipes all lists, favourites and caches on the TV. Cannot be undone.</p>
<button id="wipeOpenBtn" onclick="openWipe()" style="width:100%;padding:13px;border-radius:13px;border:1px solid rgba(255,90,90,.45);background:rgba(255,90,90,.08);color:#FF7A7A;font-weight:800;font-size:14px">Clear all data…</button></div>
</div></section>
<div class="ovl" id="wipeOvl" onclick="if(event.target===this)closeWipe()">
<div class="dlg" role="alertdialog" aria-modal="true" aria-label="Clear everything">
<p class="eyebrow" style="color:var(--red)">Danger zone</p>
<h3 class="dlgTitle">Clear everything?</h3>
<p class="cfmSub">Wipes <b>all lists, favourites and caches</b>. Type <b>CLEAR LIST</b> below to unlock the wipe.</p>
<label class="fld"><span>Type to confirm</span><input id="wipeInput" placeholder="CLEAR LIST" autocomplete="off" autocapitalize="characters" oninput="wipeCheck()"/></label>
<div class="dlgActs"><button class="ghost" onclick="closeWipe()">Keep</button><button class="danger" id="wipeYes" onclick="doWipe()" disabled>Wipe all</button></div>
</div>
</div>
</main>
<script>
let ws=null,deb=null,cats=[],curCat=0,catsSig='';
function esc(s){return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}
function setConn(on,t){document.getElementById('conn').classList.toggle('on',!!on);
document.getElementById('drConn').textContent=t||(on?'Live':'Offline')}
function openDrawer(){document.getElementById('drawer').classList.add('open');
document.getElementById('scrim').classList.add('show');
document.getElementById('burger').setAttribute('aria-expanded','true')}
function closeDrawer(){document.getElementById('drawer').classList.remove('open');
document.getElementById('scrim').classList.remove('show');
document.getElementById('burger').setAttribute('aria-expanded','false')}
function toggleDrawer(){document.getElementById('drawer').classList.contains('open')?closeDrawer():openDrawer()}
document.addEventListener('keydown',e=>{if(e.key==='Escape'){closeAdd();closeCfm();closeIcons();closeWipe();closeDrawer()}});
document.getElementById('pg-remote').addEventListener('contextmenu',e=>e.preventDefault());
let holdTimer=null,holdInt=null,holdKey=null,repeatRate=6,tvZone='grid';
function hold(k,e,vert){if(e&&e.preventDefault)e.preventDefault();key(k);holdKey=k;
 clearTimeout(holdTimer);clearInterval(holdInt);
 if(vert&&tvZone!=='grid')return; // vertical glide only inside the channel grid
 holdTimer=setTimeout(()=>{holdInt=setInterval(()=>{if(holdKey)key(holdKey)},1000/Math.max(2,repeatRate))},350)}
function unhold(){holdKey=null;clearTimeout(holdTimer);clearInterval(holdInt)}
function repPreview(v){const el=document.getElementById('repVal');if(el)el.innerHTML=v+'/s';repeatRate=parseInt(v)||6}
function key(k){
 if(ws&&ws.readyState===1){ws.send(JSON.stringify({type:'key',key:k}));return}
 fetch('/api/key',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({key:k})}).then(pull)}
function play(id){
 if(ws&&ws.readyState===1){ws.send(JSON.stringify({type:'play',id}));return}
 fetch('/api/play',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id})}).then(pull)}
let curPlayingId=null,curPlayingFav=false;
async function toggleFavPlaying(){if(!curPlayingId)return;try{const r=await fetch('/api/favourites',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:curPlayingId})});const j=await r.json();if(j.ok){curPlayingFav=!!j.fav;paintFavBtn()}}catch(e){}}
function paintFavBtn(){const b=document.getElementById('favBtn');if(!b)return;b.textContent=(curPlayingFav?'★ ':'☆ ')+'Favourite'}
function info(){
 if(ws&&ws.readyState===1){ws.send(JSON.stringify({type:'info'}));return}
 fetch('/api/info',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({toggle:true})}).then(pull)}
async function pull(){try{const r=await fetch('/api/now');const j=await r.json();paint(j)}catch(e){}}
function paint(j){
 const p=j.playing||j.focus||null;
 tvZone=j.zone||'grid';
 if(p&&p.id&&p.id!==curPlayingId&&document.getElementById('pg-recents').classList.contains('on'))loadRecents();
 curPlayingId=p?p.id:null;curPlayingFav=!!(p&&p.fav);paintFavBtn();
 document.getElementById('np').textContent=p?p.name:'—';
 document.getElementById('brandSub').textContent=p?p.name:'Remote';
 let sub=p?((p.category||'')+(p.language?' • '+p.language:'')):'Pick a channel from Channels';
 if(j.playError)sub='Could not play — tap Retry on TV or pick another';
 else if(p&&(j.buffering||j.hasVideo===false))sub='Connecting… '+(p.category||'');
 document.getElementById('npsub').textContent=sub;
 document.getElementById('ppBtn').textContent=j.isPlaying?'⏸ Pause':'⏯ Play';
 document.getElementById('infoBtn').classList.toggle('on',!!j.infoVisible);
  document.getElementById('muteBtn').classList.toggle('on',!!j.muted);
   document.getElementById('muteBtn').textContent=j.muted?'🔇 Muted':'Mute';
  const fsb=document.getElementById('fsBtn');if(fsb){fsb.classList.toggle('on',!!j.fullscreen);fsb.textContent=j.fullscreen?'⛶ Fullscreen ✓':'⛶ Fullscreen';if(j.canFullscreen===false)fsb.style.display='none'}
 const hasPlaying=!!(j.playing&&j.playing.id);
 const cbw=document.getElementById('chanBtnWrap');if(cbw)cbw.style.display=hasPlaying?'block':'none';
 const cbtn=document.getElementById('chanBtn');if(cbtn)cbtn.textContent=j.playerListOpen?'✕ Close list':'☰ Channels — this list';
 setConn(true,'live')}
async function openPlayerList(){try{
 if(ws&&ws.readyState===1){ws.send(JSON.stringify({type:'plist',action:'toggle'}));return}
 await fetch('/api/playerlist',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'toggle'})})}catch(e){}}
async function closePlayerList(){try{
 if(ws&&ws.readyState===1){ws.send(JSON.stringify({type:'plist',action:'close'}));return}
 await fetch('/api/playerlist',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'close'})})}catch(e){}}
function hcol(h){return h==='fast'?'#3DDC84':h==='slow'?'#FFB338':h==='dead'?'#FF5A5A':'#4A4A54'}
function favStar(c,safeId){return '<span role="button" aria-label="Toggle favourite" onclick="event.stopPropagation();toggleFav(\''+safeId+'\')" style="position:absolute;top:6px;right:6px;width:34px;height:34px;display:flex;align-items:center;justify-content:center;border-radius:50%;background:rgba(0,0,0,.5);border:1px solid '+(c.fav?'rgba(255,179,56,.5)':'rgba(255,255,255,.12)')+';color:'+(c.fav?'#FFB338':'#6E6A80')+';font-size:15px;line-height:1;z-index:2">★</span>'}
async function toggleFav(id){try{await fetch('/api/favourites',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id})})}catch(e){}
 if(favMode)loadFavs();else loadCatChannels(document.getElementById('q').value||'')}
let favMode=false,favCache=[];
async function loadFavs(){try{const r=await fetch('/api/favourites');const arr=await r.json();favCache=arr;favMode=true;render(arr);
 document.getElementById('chCount').textContent=arr.length+' favourites'}catch(e){}}
function selectFav(){favMode=true;for(let k=0;k<cats.length;k++){const b=document.getElementById('chip-'+k);if(b)b.classList.remove('on')}
 const f=document.getElementById('chip-fav');if(f)f.classList.add('on');
 document.getElementById('q').value='';loadFavs()}
function render(arr){
 const favs=arr.filter(c=>c.fav);
 document.getElementById('favWrap').innerHTML=favs.length?'<p style="font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:var(--muted);font-weight:800;margin:0;padding:12px 14px 0">Favourites</p><div style="display:flex;gap:8px;overflow-x:auto;padding:6px 14px 12px">'+favs.map(c=>{
  const safeId=(c.id||'').replace(/'/g,'');
  const logo=c.logo?'<img src="'+esc(c.logo)+'" loading="lazy" onerror="this.remove()" style="width:30px;height:30px;border-radius:50%;object-fit:cover;background:#0E0E13"/>':'';
  return '<button onclick="play(\''+safeId+'\')" style="flex:0 0 auto;display:flex;align-items:center;gap:8px;padding:8px;border-radius:999px;background:var(--card);border:1px solid var(--line);color:var(--paper);font:inherit;font-size:12.5px;font-weight:700;max-width:220px">'+logo+'<span style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">'+esc(c.name)+'</span><span onclick="event.stopPropagation();toggleFav(\''+safeId+'\')" style="color:var(--gold);font-size:14px;padding:4px 6px">★</span></button>'}).join('')+'</div>':'';
 const g=document.getElementById('grid');
 g.innerHTML=(favs.length?'<p style="font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:var(--muted);font-weight:800;margin:0;padding:12px 14px 0;grid-column:1/-1">All channels</p>':'')+arr.map(c=>{
  const safeId=(c.id||'').replace(/'/g,'');
  const logo=c.logo?'<img src="'+esc(c.logo)+'" loading="lazy" onerror="this.remove()"/>':'<span class="fb">📺</span>';
  return '<button class="tile" onclick="play(\''+safeId+'\')">'+favStar(c,safeId)+'<span class="dotrow"><i style="width:8px;height:8px;border-radius:50%;background:'+hcol(c.health)+'"></i><span class="play">PLAY</span></span>'+logo+'<span class="t">'+esc(c.name)+'</span><span class="c">'+esc(c.category||'')+'</span></button>'}).join('');
 const empty=document.getElementById('chEmpty');
 const hasCats=cats&&cats.length>0;
 empty.style.display=(!hasCats||arr.length===0&&!document.getElementById('q').value)?'block':'none';
 if(!hasCats){g.innerHTML='';document.getElementById('favWrap').innerHTML='';empty.style.display='block'}
 else if(arr.length===0){empty.style.display='block';empty.querySelector('h3').textContent='Nothing found';empty.querySelector('p').textContent='Try another search or list.';empty.querySelector('.go').style.display='none'}
 else{empty.querySelector('h3').textContent='No lists yet';empty.querySelector('p').textContent='Paste an M3U link under Lists and it appears here as its own tab.';empty.querySelector('.go').style.display='';empty.style.display='none'}}
function tab(t){for(const x of['remote','ch','recents','lists','settings']){document.getElementById('pg-'+x).classList.toggle('on',x===t);document.getElementById('nv-'+x).classList.toggle('on',x===t)}
closeAdd();closeCfm();closeDrawer();window.scrollTo({top:0});lastY=window.scrollY||0;
document.getElementById('pg-ch').classList.remove('noChips');
if(t==='ch')loadCats(true);if(t==='recents')loadRecents();if(t==='lists')loadPlaylists();if(t==='settings')loadSettings()}
function relTime(iso){try{const t=new Date(iso||'').getTime();if(!t)return'';const s=Math.max(0,Math.floor((Date.now()-t)/1000));if(s<60)return'just now';const m=Math.floor(s/60);if(m<60)return m+'m ago';const h=Math.floor(m/60);if(h<24)return h+'h ago';return Math.floor(h/24)+'d ago'}catch(e){return''}}
async function loadRecents(){try{const r=await fetch('/api/recents');const arr=await r.json();
 document.getElementById('recCount').textContent=arr.length?(arr.length+' recent • most recent first'):'Nothing played yet';
 document.getElementById('recList').innerHTML=arr.map((c,i)=>{
  const safeId=(c.id||'').replace(/'/g,'');
  const logo=c.logo?'<img src="'+esc(c.logo)+'" loading="lazy" onerror="this.remove()"/>':'<span class="rfb">📺</span>';
  return '<button class="rrow" onclick="play(\''+safeId+'\')"><span class="rn">'+(i+1)+'</span>'+logo+'<span class="rtx"><b>'+esc(c.name)+'</b><span>'+esc(c.category||'')+'</span></span><span class="rt">'+relTime(c.playedAt)+'</span></button>'}).join('')||'<div class="lEmpty">Nothing played yet.<br/>Play anything and it lands here.</div>'}catch(e){}}
async function loadCats(force){try{const r=await fetch('/api/categories');const fresh=await r.json();
 const sig=JSON.stringify(fresh.map((c,i)=>[i,c.title,c.count]));
 const box=document.getElementById('chips');
 if(sig===catsSig){if(force&&!favMode){if(curCat>=cats.length)curCat=0;selectCat(curCat)}return}
 const sx=box?box.scrollLeft:0;
 cats=fresh;catsSig=sig;
 if(!cats.length){box.innerHTML='';document.getElementById('chCount').textContent='0 lists';
  document.getElementById('grid').innerHTML='';document.getElementById('favWrap').innerHTML='';document.getElementById('chEmpty').style.display='block';return}
 document.getElementById('chEmpty').style.display='none';
 box.innerHTML='<button class="chip" id="chip-fav" onclick="selectFav()">★ Favourites</button>'+cats.map((c,i)=>'<button class="chip" id="chip-'+i+'" onclick="selectCat('+i+')">'+esc(c.title||('List '+(i+1)))+'</button>').join('');
 requestAnimationFrame(()=>{try{box.scrollLeft=sx}catch(e){}});
 if(curCat>=cats.length)curCat=0;
 if(favMode){const f=document.getElementById('chip-fav');if(f)f.classList.add('on');loadFavs()}
 else selectCat(curCat)}catch(e){}}
function selectCat(i){favMode=false;const fb=document.getElementById('chip-fav');if(fb)fb.classList.remove('on');curCat=i;for(let k=0;k<cats.length;k++){const b=document.getElementById('chip-'+k);if(b)b.classList.toggle('on',k===i)}
 document.getElementById('q').value='';loadCatChannels('')}
async function loadCatChannels(q){try{const c=cats[curCat];
 if(!c){render([]);return}
 const r=await fetch('/api/channels?category='+encodeURIComponent(c.index)+'&q='+encodeURIComponent(q||'')+'&limit=2000');
 const arr=await r.json();render(arr);
 document.getElementById('chCount').textContent=(c.count!=null?c.count:arr.length)+' channels • '+esc(c.title||'')}catch(e){}}
function search(q){clearTimeout(deb);deb=setTimeout(()=>{if(favMode){const s=(q||'').toLowerCase();render(favCache.filter(c=>((c.name||'').toLowerCase().indexOf(s)>=0)||((c.category||'').toLowerCase().indexOf(s)>=0)))}else loadCatChannels(q)},220)}
let lastY=0,chTick=false;
function onScroll(){
 const pg=document.getElementById('pg-ch');
 const y=window.scrollY||0;
 if(!pg||!pg.classList.contains('on')){lastY=y;return}
 if(y>140&&y>lastY+4)pg.classList.add('noChips');
 else if(y<lastY-4||y<=140)pg.classList.remove('noChips');
 lastY=y}
window.addEventListener('scroll',()=>{if(chTick)return;chTick=true;
requestAnimationFrame(()=>{onScroll();chTick=false})},{passive:true});
async function viewList(name){tab('ch');try{const r=await fetch('/api/categories');cats=await r.json()}catch(e){}
 const nl=(name||'').toLowerCase().replace(/★/g,'').trim();
 const i=cats.findIndex(c=>((c.title||'').toLowerCase().replace(/★/g,'').trim()===nl)||((c.title||'').toLowerCase().indexOf(nl)>=0&&nl));
 selectCat(i<0?0:i)}
function bufPreview(v){document.getElementById('bufVal').innerHTML=v+'<small>s</small>'}
async function loadSettings(){try{const r=await fetch('/api/settings');const j=await r.json();
 const v=j.prebufferSecs??5;document.getElementById('bufRange').value=v;bufPreview(v);
 const rr=j.repeatRate??6;document.getElementById('repRange').value=rr;repPreview(rr);
 const aq=document.getElementById('autoQr');if(aq)aq.checked=j.autoQr!==false;
 const sp=document.getElementById('showPresets');if(sp)sp.checked=j.showPresets!==false;
 const sv=document.getElementById('stretchVideo');if(sv)sv.checked=j.stretchVideo===true}catch(e){}}
async function saveStretchOnly(on){try{await fetch('/api/settings',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({stretchVideo:on})})}catch(e){}}
async function saveQrOnly(on){try{await fetch('/api/settings',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({autoQr:on})})}catch(e){}}
async function savePresetsOnly(on){try{await fetch('/api/settings',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({showPresets:on})})}catch(e){}}
async function saveBuffer(){const v=parseInt(document.getElementById('bufRange').value||'5');
 const rr=parseInt(document.getElementById('repRange').value||'6');
 const b=document.getElementById('bufBtn');b.disabled=true;
 try{const r=await fetch('/api/settings',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({prebufferSecs:v,repeatRate:rr})});
 const j=await r.json();const m=document.getElementById('bufMsg');
 if(j.ok){repeatRate=j.repeatRate||rr;m.textContent='Saved — buffer '+j.prebufferSecs+'s, glide '+(j.repeatRate||rr)+'/s.';m.className='plmsg ok'}else{m.textContent='Save failed.';m.className='plmsg err'}}catch(e){const m=document.getElementById('bufMsg');m.textContent='Network error.';m.className='plmsg err'}
 b.disabled=false}
function plMsg(t,cls){const e=document.getElementById('plMsg');e.textContent=t;e.className='plmsg '+(cls||'')}
async function loadPlaylists(){try{const r=await fetch('/api/playlists');const arr=await r.json();
 plCache=arr;
 const n=arr.length;
 document.getElementById('listsCount').textContent=n===0?'No saved playlists yet':n===1?'1 saved playlist • tap to open its channels':n+' saved playlists • tap to open its channels';
 document.getElementById('plList').innerHTML=arr.map((p,i)=>
 '<div class="lrow"><span class="lmove"><button onclick="movePl(\''+p.id+'\',-1)"'+(i===0?' disabled':'')+' aria-label="Move '+esc(p.name)+' up">▲</button><button onclick="movePl(\''+p.id+'\',1)"'+(i===n-1?' disabled':'')+' aria-label="Move '+esc(p.name)+' down">▼</button></span><button class="lmain" onclick="viewList(decodeURIComponent(\''+encodeURIComponent(p.name).replace(/'/g,'%27')+'\'))">'
 +'<span class="ldot" style="background:'+numCss(p.color)+'">'+(EMOJI[p.icon]||'📺')+'</span><span class="ltx"><b>'+esc(p.name)+'</b><span>'+p.count+' channels</span></span><span class="lgo">›</span></button>'
 +'<button class="lrm" onclick="askDel(\''+p.id+'\',\''+encodeURIComponent(p.name).replace(/'/g,'%27')+'\')" aria-label="Remove '+esc(p.name)+'">'
 +'<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16"/><path d="M9 7V5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/><path d="M6.5 7l1 12a1 1 0 0 0 1 1h7a1 1 0 0 0 1-1l1-12"/></svg></button></div>').join('')||'<div class="lEmpty">Nothing saved yet.<br/>Tap Add New List to begin.</div>'}catch(e){}}
let plCache=[];
async function movePl(id,dir){
 const i=plCache.findIndex(p=>p.id===id);const j=i+dir;
 if(i<0||j<0||j>=plCache.length)return;
 const order=plCache.map(p=>p.id);const t=order[i];order[i]=order[j];order[j]=t;
 try{await fetch('/api/playlists/reorder',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({order,moved:id})})}catch(e){}
 loadPlaylists();loadCats(true)}
const ICONS=[{k:'tv',e:'📺',n:'TV'},{k:'film',e:'🎬',n:'Movies'},{k:'trophy',e:'🏆',n:'Sports'},{k:'musicalNote',e:'🎵',n:'Music'},{k:'newspaper',e:'📰',n:'News'},{k:'faceSmile',e:'😊',n:'Kids'},{k:'globeAlt',e:'🌍',n:'Global'},{k:'flag',e:'🚩',n:'Nation'},{k:'radio',e:'📻',n:'Radio'},{k:'star',e:'⭐',n:'Starred'},{k:'heart',e:'❤️',n:'Loved'},{k:'bolt',e:'⚡',n:'Quick'},{k:'sparkles',e:'✨',n:'Fresh'},{k:'ticket',e:'🎟️',n:'Events'},{k:'play',e:'▶️',n:'Play'},{k:'home',e:'🏠',n:'Home'},{k:'rss',e:'📡',n:'Feeds'},{k:'signal',e:'📶',n:'Signal'},{k:'clock',e:'🕐',n:'Time'},{k:'moon',e:'🌙',n:'Night'},{k:'sun',e:'☀️',n:'Day'},{k:'cloud',e:'☁️',n:'Cloud'},{k:'bookOpen',e:'📖',n:'Stories'},{k:'bookmark',e:'🔖',n:'Saved'},{k:'gift',e:'🎁',n:'Gifts'},{k:'cake',e:'🎂',n:'Fun'},{k:'photo',e:'🖼️',n:'Photos'},{k:'videoCamera',e:'🎥',n:'Videos'},{k:'microphone',e:'🎤',n:'Talk'},{k:'phone',e:'📱',n:'Mobile'},{k:'users',e:'👥',n:'Community'},{k:'user',e:'👤',n:'Personal'},{k:'briefcase',e:'💼',n:'Work'},{k:'academicCap',e:'🎓',n:'Learn'},{k:'map',e:'🗺️',n:'Travel'},{k:'wallet',e:'👛',n:'Money'},{k:'cog6Tooth',e:'⚙️',n:'Settings'}];
const COLORS=['#3D9BFF','#FFB338','#3DDC84','#FF5A5A','#B388FF','#FF7AB8','#4DD0E1','#FFD54F','#9CCC65','#F5F1E8'];
const EMOJI={};ICONS.forEach(o=>EMOJI[o.k]=o.e);
let selIcon='tv',selColor='#3D9BFF';
function numCss(v){const n=(Number(v)>>>0).toString(16).padStart(8,'0');return '#'+n.slice(2)}
function renderSwatches(){document.getElementById('swRow').innerHTML=COLORS.map(c=>'<button class="sw'+(c===selColor?' on':'')+'" style="background:'+c+'" onclick="pickColor(\''+c+'\')" aria-label="'+c+'"></button>').join('')}
function pickColor(c){selColor=c;renderSwatches()}
function paintIconPick(){const o=ICONS.find(o=>o.k===selIcon)||ICONS[0];document.getElementById('icPick').textContent=o.e;document.getElementById('icPick').style.borderColor=selColor;document.getElementById('icName').textContent=o.n}
function openIcons(){renderIconGrid();document.getElementById('iconOvl').classList.add('show')}
function closeIcons(){const o=document.getElementById('iconOvl');if(o)o.classList.remove('show')}
function renderIconGrid(){document.getElementById('icGrid').innerHTML=ICONS.map(o=>'<button class="icBtn'+(o.k===selIcon?' on':'')+'" onclick="pickIcon(\''+o.k+'\')"><span>'+o.e+'</span><small>'+o.n+'</small></button>').join('')}
function pickIcon(k){selIcon=k;paintIconPick();renderIconGrid();closeIcons()}
function openAdd(){selIcon='tv';selColor='#3D9BFF';renderSwatches();paintIconPick();document.getElementById('plMsg').textContent='';document.getElementById('plMsg').className='plmsg';
document.getElementById('addOvl').classList.add('show');setTimeout(()=>{try{document.getElementById('plName').focus({preventScroll:true})}catch(_){}},80)}
function closeAdd(){const o=document.getElementById('addOvl');if(o)o.classList.remove('show')}
async function pasteUrl(){const inp=document.getElementById('plUrl');
 try{if(!navigator.clipboard||!navigator.clipboard.readText)throw 0;
 const t=await navigator.clipboard.readText();
 if(t&&t.trim()){inp.value=t.trim();plMsg('Pasted from clipboard.','ok')}else{plMsg('Clipboard is empty.','err')}}catch(e){try{inp.focus()}catch(_){}
 plMsg('Clipboard blocked — tap-hold the field, then Paste.','err')}}
let pendDelId=null;
function askDel(id,encName){pendDelId=id;
 document.getElementById('cfmName').innerHTML='Remove <b>'+esc(decodeURIComponent(encName||''))+'</b> from the TV?';
 document.getElementById('cfmOvl').classList.add('show')}
function closeCfm(){pendDelId=null;const o=document.getElementById('cfmOvl');if(o)o.classList.remove('show')}
function openWipe(){const i=document.getElementById('wipeInput');i.value='';document.getElementById('wipeYes').disabled=true;document.getElementById('wipeOvl').classList.add('show');setTimeout(()=>{try{i.focus({preventScroll:true})}catch(_){}},80)}
function closeWipe(){const o=document.getElementById('wipeOvl');if(o)o.classList.remove('show')}
function wipeCheck(){document.getElementById('wipeYes').disabled=document.getElementById('wipeInput').value.trim()!=='CLEAR LIST'}
async function doWipe(){const b=document.getElementById('wipeYes');if(b.disabled)return;b.disabled=true;
 try{const r=await fetch('/api/database',{method:'DELETE'});const j=await r.json();
 if(j.ok){closeWipe();curCat=0;loadPlaylists();if(favMode)loadFavs();else loadCats(true)}}catch(e){}
 b.disabled=false}
async function doDel(){if(!pendDelId){closeCfm();return}
 const b=document.getElementById('cfmYes');b.disabled=true;
 await fetch('/api/playlists?id='+encodeURIComponent(pendDelId),{method:'DELETE'});
 b.disabled=false;closeCfm();
 if(curCat>=cats.length-1)curCat=0;
 loadPlaylists();if(favMode)loadFavs();else loadCats(true)}
async function addPlaylist(){
 const name=document.getElementById('plName').value.trim()||'My List';
 const url=document.getElementById('plUrl').value.trim();
 if(!url){plMsg('Add an M3U link first.','err');return}
 const btn=document.getElementById('plBtn');btn.disabled=true;btn.textContent='Saving…';plMsg('Fetching playlist…','');
 try{const r=await fetch('/api/playlists',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name,url,icon:selIcon,color:(parseInt(selColor.slice(1),16)>>>0)|0xFF000000})});
 const j=await r.json();
 if(j.ok){document.getElementById('plName').value='';document.getElementById('plUrl').value='';
 plMsg('','');closeAdd();loadPlaylists();loadCats(true)}
 else plMsg(j.error||'Could not save that link.','err')}catch(e){plMsg('Network error — is the TV online?','err')}
 btn.disabled=false;btn.textContent='Save'}
function connect(){
 try{ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+'/ws');
 ws.onopen=()=>{setConn(true,'live');pull()};
 ws.onmessage=e=>{try{const j=JSON.parse(e.data);if(j.type==='now'||j.type==='hello')paint(j);if(j.type==='playlists'){loadPlaylists();loadCats(false)}}catch(_){}};
 ws.onclose=()=>{setConn(false,'retry…');setTimeout(connect,2000)}}catch(e){setConn(false,'offline')}}
connect();pull();loadPlaylists();loadCats(true);
setInterval(()=>{if(!ws||ws.readyState!==1)pull()},8000);
</script></body></html>
''';

}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}

/// A candidate LAN address with its virtual-adapter flag for ranking.
class _Nic {
  final String addr;
  final bool virt;
  _Nic(this.addr, this.virt);
}
