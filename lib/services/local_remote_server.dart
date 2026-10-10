// Inbuilt phone-remote server — same single-executable pattern as the
// FoodWastage LocalAdminServer: Flutter TV UI + HttpServer in one process.
// Phone on same Wi-Fi opens http://<pi-ip>:8080/remote and drives the TV
// in real time over WebSocket (<100ms), REST as fallback.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_state.dart';
import 'catalog_service.dart';
import 'custom_playlist_store.dart';
import 'player_service.dart';
import 'remote_command.dart';
import 'stream_health.dart';
import '../models/custom_playlist.dart';
import '../models/tv_channel.dart';

class LocalRemoteServer {
  static HttpServer? _server;
  static AppState? _state;
  static PlayerService? _playerSvc;
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

  static Future<List<String>> lanUrls([int? port]) async {
    final p = port ?? _port;
    final out = <String>[];
    try {
      for (final ni in await NetworkInterface.list()) {
        for (final a in ni.addresses) {
          if (a.type == InternetAddressType.IPv4 && !a.isLoopback) {
            out.add('http://${a.address}:$p/remote');
          }
        }
      }
    } catch (_) {}
    if (out.isEmpty) out.add('http://127.0.0.1:$p/remote');
    return out;
  }

  static Map<String, dynamic> _chJson(
      AppState s, TvChannel c) {
    final j = c.toJson();
    j['health'] = s.healthById[c.id] ?? 'unknown';
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
        ws.add(jsonEncode({
          'type': 'hello',
          'playing': s.playing == null
              ? null
              : _chJson(s, s.playing!),
          'isPlaying': s.isPlaying,
        }));
        ws.listen((raw) {
          try {
            final m =
                Map<String, dynamic>.from(jsonDecode(raw as String));
            _applyMessage(s, m);
          } catch (_) {}
        }, onDone: () => _sockets.remove(ws),
            onError: (_) => _sockets.remove(ws));
        return; // upgraded — do not close
      } else if (req.method == 'GET' &&
          (path == '/' || path == '/remote' || path == '/index.html')) {
        res.headers.contentType = ContentType.html;
        res.write(_remoteHtml());
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
          'focus': s.focusedChannel == null
              ? null
              : _chJson(s, s.focusedChannel!),
        }));
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
                channels: channels);
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
          try {
            final prefs =
                await SharedPreferences.getInstance();
            await prefs.setInt('opentv_prebuffer_secs', v);
            await prefs.setInt('opentv_repeat_rate', r);
          } catch (_) {}
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({
            'ok': true,
            'prebufferSecs': v,
            'repeatRate': r,
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
    }
  }

  // -- Phone remote UI: sidebar + mosaic grid, single-file --
  // Design tokens: ink #0B0B0F, onyx #14141B, paper #F5F1E8,
  // muted #9A94A6, marigold #FFB338 signature glow.
  static String _remoteHtml() => r'''
<!doctype html><html lang="en"><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"/>
<meta name="theme-color" content="#0B0B0F"/>
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
/* top bar */
#topbar{position:sticky;top:0;z-index:20;height:var(--topH);display:flex;align-items:center;gap:10px;
padding:0 12px;background:rgba(11,11,15,.88);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);
border-bottom:1px solid var(--line)}
#burger{width:44px;height:44px;min-height:0;padding:0;border-radius:13px;display:flex;flex-direction:column;
align-items:center;justify-content:center;gap:5px;background:var(--card);flex:0 0 auto}
#burger span{display:block;width:18px;height:2px;border-radius:2px;background:var(--paper)}
#burger span:nth-child(2){width:13px;margin-right:5px;background:var(--gold)}
.brand{display:flex;align-items:center;gap:10px;min-width:0}
.logo{width:34px;height:34px;border-radius:10px;background:var(--gold);color:var(--gold-ink);
font-weight:800;display:flex;align-items:center;justify-content:center;font-size:13.5px;flex:0 0 auto}
.brand h1{font-size:15.5px;margin:0;line-height:1.1;white-space:nowrap}
.brand h1 small{display:block;font-size:11px;color:var(--muted);font-weight:500;letter-spacing:.02em}
.conn{margin-left:auto;font-size:11px;color:var(--muted);display:flex;align-items:center;gap:7px;
border:1px solid var(--line);border-radius:999px;padding:7px 11px;background:var(--card);white-space:nowrap}
.conn i{width:8px;height:8px;border-radius:50%;background:#3A3A44;display:inline-block;flex:0 0 auto}
.conn.on{color:var(--paper)}
.conn.on i{background:var(--green);box-shadow:0 0 8px var(--green)}
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
/* now card */
.now{position:relative;background:linear-gradient(180deg,#22222F,#14141B);
border:1px solid var(--line);border-radius:var(--r);padding:18px;overflow:hidden;
box-shadow:inset 0 1px 0 rgba(255,255,255,.08),0 18px 40px rgba(0,0,0,.35)}
.now:after{content:"";position:absolute;top:0;left:10%;right:10%;height:1px;
background:linear-gradient(90deg,transparent,rgba(255,179,56,.55),transparent)}
.now h2{margin:8px 0 3px;font-size:22px;line-height:1.15;letter-spacing:-.01em}
.now p{margin:0;font-size:13px;color:var(--muted)}
.transport{display:grid;grid-template-columns:1.25fr 1fr 1fr;gap:8px;margin-top:15px}
#ppBtn{background:var(--gold);color:var(--gold-ink);border-color:transparent;font-weight:800;
box-shadow:0 6px 22px rgba(255,179,56,.28)}
#ppBtn:active{background:#FFC25E}
.ghost{background:#1B1B24}
/* deck */
.deck{margin-top:12px;background:var(--card);border:1px solid var(--line);border-radius:var(--r);
padding:18px 16px 16px;box-shadow:inset 0 1px 0 rgba(255,255,255,.06)}
.dpad{display:grid;grid-template-columns:64px 88px 64px;grid-template-rows:58px 78px 58px;
gap:8px;justify-content:center;align-items:center;margin:12px 0 6px}
.dpad button{font-size:19px;padding:0;border-radius:18px;background:#23232F}
.ok{background:var(--gold)!important;color:var(--gold-ink)!important;border-color:transparent!important;
border-radius:50%!important;width:88px;height:78px;font-size:15px!important;font-weight:800!important;
letter-spacing:.06em;box-shadow:0 0 0 7px var(--gold-soft),0 0 28px rgba(255,179,56,.38)}
.ctl{margin-top:14px}
.seg{display:flex;border:1px solid var(--line);border-radius:15px;overflow:hidden;background:#101016}
.seg button{flex:1;border:0;border-radius:0;background:transparent;min-height:54px;font-size:14px;margin:0}
.seg button+button{border-left:1px solid var(--line)}
.seg button:active{background:#23232F}
.wide{width:100%;margin-top:8px;background:#1B1B24}
.hint{font-size:11.5px;color:var(--muted);text-align:center;margin:12px 2px 0;line-height:1.5}
/* channels: full-bleed chip bar + zero-gap mosaic */
.chipsWrap{width:100%;max-width:100%;box-sizing:border-box;margin:0;background:#101016;border-top:1px solid var(--line);
border-bottom:1px solid var(--line);position:sticky;top:var(--topH);z-index:6}
.chips{display:flex;gap:8px;overflow-x:auto;padding:10px 14px;scrollbar-width:none}
.chips::-webkit-scrollbar{display:none}
.chip{flex:0 0 auto;min-height:44px;font-size:13px;font-weight:700;padding:10px 18px;
border-radius:999px;margin:0;white-space:nowrap;background:#1B1B24}
.chip.on{background:var(--paper);color:#141418;border-color:transparent}
.chTools{padding:12px 14px 10px}
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
.listsHint{margin:10px 0 14px;font-size:12.5px;color:var(--muted);line-height:1.55}
.addCard{background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:16px;
box-shadow:inset 0 1px 0 rgba(255,255,255,.06)}
.fld{display:block;margin:0 0 10px}
.fld span{display:block;font-size:11px;letter-spacing:.1em;text-transform:uppercase;
color:var(--muted);font-weight:800;margin:0 2px 6px}
.ledger{margin-top:16px;border-top:1px solid var(--hair)}
.lrow{display:flex;align-items:stretch;border-bottom:1px solid var(--hair);background:transparent}
.lmain{flex:1;min-width:0;display:flex;align-items:center;gap:12px;text-align:left;border:0;border-radius:0;
background:transparent;padding:13px 4px;margin:0;min-height:60px}
.lstar{color:var(--gold);font-size:14px;flex:0 0 auto}
.ltx{min-width:0;flex:1}
.ltx b{font-size:14.5px;display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ltx span{font-size:11.5px;color:var(--muted)}
.lgo{color:var(--muted);font-size:16px;flex:0 0 auto}
.lmain:active .lgo{color:var(--gold)}
.lrm{border:0;border-radius:0;background:transparent;color:var(--muted);font-size:12.5px;font-weight:600;
min-height:0;padding:0 4px 0 14px;margin:0;white-space:nowrap}
.lrm:active{color:var(--red)}
.lEmpty{padding:26px 6px;text-align:center;font-size:12.5px;color:var(--muted);line-height:1.6}
.pl input[type=range]{accent-color:var(--gold);height:42px;padding:0;border:0;background:transparent;min-height:0;margin:6px 0 2px}
.setval{font-size:30px;font-weight:800;font-variant-numeric:tabular-nums;letter-spacing:-.02em;margin:6px 0 2px}
.setval small{font-size:14px;color:var(--muted);font-weight:600}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
</style></head><body>
<div id="scrim" onclick="closeDrawer()"></div>
<aside id="drawer" aria-label="Menu">
<div class="drHead"><div class="logo">OTV</div>
<div class="t">OpenTV<small>Phone remote</small></div>
<button id="closeBtn" onclick="closeDrawer()" aria-label="Close menu">✕</button></div>
<nav class="drNav">
<button class="navBtn on" id="nv-remote" onclick="tab('remote')"><span class="ic">◉</span><span class="lb">Remote<small>D-pad • play • volume</small></span><span class="arw">›</span></button>
<button class="navBtn" id="nv-ch" onclick="tab('ch')"><span class="ic">▤</span><span class="lb">Channels<small>Your lists • tap to play</small></span><span class="arw">›</span></button>
<button class="navBtn" id="nv-lists" onclick="tab('lists')"><span class="ic">★</span><span class="lb">Lists<small>Add • view • remove</small></span><span class="arw">›</span></button>
<button class="navBtn" id="nv-settings" onclick="tab('settings')"><span class="ic">⚙</span><span class="lb">Settings<small>Playback buffer</small></span><span class="arw">›</span></button>
</nav>
<div class="drFoot" id="drFoot">Same Wi-Fi • real-time<br/><b id="drConn">Link…</b> — buttons answer in under 100ms.</div>
</aside>
<header id="topbar">
<button id="burger" onclick="toggleDrawer()" aria-label="Open menu" aria-expanded="false"><span></span><span></span><span></span></button>
<div class="brand"><div class="logo">OTV</div><h1>OpenTV<small>Remote</small></h1></div>
<div class="conn" id="conn"><i></i><span id="connT">link…</span></div>
</header>
<main id="pages">
<section class="page on" id="pg-remote"><div class="padX">
<div class="now"><p class="eyebrow"><span class="liveDot"></span>Now playing</p><h2 id="np">—</h2><p id="npsub">Pick a channel from Channels</p>
<div class="transport">
<button onclick="key('playPause')" id="ppBtn">⏯ Play</button>
<button class="ghost" onclick="key('back')">← Back</button>
<button class="ghost" onclick="key('home')">⌂ Home</button>
</div>
</div>
<div class="deck"><p class="eyebrow">Direction</p>
<div class="dpad">
<span></span><button onclick="key('up')" aria-label="Up">▲</button><span></span>
<button onpointerdown="hold('left',event)" onpointerup="unhold()" onpointerleave="unhold()" onpointercancel="unhold()" oncontextmenu="return false" aria-label="Left">◀</button><button class="ok" onclick="key('ok')">OK</button><button onpointerdown="hold('right',event)" onpointerup="unhold()" onpointerleave="unhold()" onpointercancel="unhold()" oncontextmenu="return false" aria-label="Right">▶</button>
<span></span><button onclick="key('down')" aria-label="Down">▼</button><span></span>
</div>
<div class="ctl"><p class="eyebrow">Channel</p>
<div class="seg" style="margin-top:8px"><button onclick="key('channelUp')">CH ＋</button><button onclick="key('channelDown')">CH －</button></div></div>
<div class="ctl"><p class="eyebrow">Volume</p>
<div class="seg" style="margin-top:8px"><button onclick="key('volUp')">VOL ＋</button><button onclick="key('volDown')">VOL －</button></div>
<button class="wide" onclick="key('mute')">Mute</button></div>
</div>
<div class="hint">D-pad moves the TV focus • OK plays • CH zaps while watching.</div>
</div></section>
<section class="page" id="pg-ch">
<div class="chipsWrap"><div class="chips" id="chips"></div></div>
<div class="chTools"><div class="count" id="chCount"></div>
<div class="searchBox"><input id="q" placeholder="Search in this list…" oninput="search(this.value)" autocomplete="off"/></div></div>
<div class="grid" id="grid"></div>
<div class="empty" id="chEmpty" style="display:none"><div class="big">📺</div>
<h3>No lists yet</h3><p>Paste an M3U link under Lists and it appears here as its own tab.</p>
<button class="go" onclick="tab('lists')">＋ Add a list</button></div>
</section>
<section class="page" id="pg-lists"><div class="padX">
<p class="eyebrow">Library</p>
<h2 class="listsTitle">Lists</h2>
<p class="listsSub" id="listsCount">Your saved playlists</p>
<p class="listsHint">Paste any M3U link — it saves on the TV as a new category.</p>
<div class="addCard">
<label class="fld"><span>Name</span><input id="plName" placeholder="e.g. Sports, Tamil, Kids" maxlength="40"/></label>
<label class="fld"><span>M3U link</span><input id="plUrl" placeholder="https://…/in.m3u" inputmode="url" autocomplete="off"/></label>
<button class="add" id="plBtn" onclick="addPlaylist()">Save list to TV</button>
<div class="plmsg" id="plMsg"></div>
</div>
<div class="ledger" id="plList"></div>
</div></section>
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
<div class="hint">5–10s is the sweet spot on Pi 4. Bigger tank = longer start wait + more RAM.</div></div>
</div></section>
</main>
<script>
let ws=null,deb=null,cats=[],curCat=0;
function esc(s){return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}
function setConn(on,t){document.getElementById('conn').classList.toggle('on',!!on);
document.getElementById('connT').textContent=t||(on?'live':'offline');
document.getElementById('drConn').textContent=t||(on?'Live':'Offline')}
function openDrawer(){document.getElementById('drawer').classList.add('open');
document.getElementById('scrim').classList.add('show');
document.getElementById('burger').setAttribute('aria-expanded','true')}
function closeDrawer(){document.getElementById('drawer').classList.remove('open');
document.getElementById('scrim').classList.remove('show');
document.getElementById('burger').setAttribute('aria-expanded','false')}
function toggleDrawer(){document.getElementById('drawer').classList.contains('open')?closeDrawer():openDrawer()}
document.addEventListener('keydown',e=>{if(e.key==='Escape')closeDrawer()});
let holdTimer=null,holdInt=null,holdKey=null,repeatRate=6;
function hold(k,e){if(e&&e.preventDefault)e.preventDefault();key(k);holdKey=k;
 clearTimeout(holdTimer);clearInterval(holdInt);
 holdTimer=setTimeout(()=>{holdInt=setInterval(()=>{if(holdKey)key(holdKey)},1000/Math.max(2,repeatRate))},350)}
function unhold(){holdKey=null;clearTimeout(holdTimer);clearInterval(holdInt)}
function repPreview(v){const el=document.getElementById('repVal');if(el)el.innerHTML=v+'/s';repeatRate=parseInt(v)||6}
function key(k){
 if(ws&&ws.readyState===1){ws.send(JSON.stringify({type:'key',key:k}));return}
 fetch('/api/key',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({key:k})}).then(pull)}
function play(id){
 if(ws&&ws.readyState===1){ws.send(JSON.stringify({type:'play',id}));return}
 fetch('/api/play',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id})}).then(pull)}
async function pull(){try{const r=await fetch('/api/now');const j=await r.json();paint(j)}catch(e){}}
function paint(j){
 const p=j.playing||j.focus||null;
 document.getElementById('np').textContent=p?p.name:'—';
 let sub=p?((p.category||'')+(p.language?' • '+p.language:'')):'Pick a channel from Channels';
 if(j.playError)sub='Could not play — tap Retry on TV or pick another';
 else if(p&&(j.buffering||j.hasVideo===false))sub='Connecting… '+(p.category||'');
 document.getElementById('npsub').textContent=sub;
 document.getElementById('ppBtn').textContent=j.isPlaying?'⏸ Pause':'⏯ Play';
 setConn(true,'live')}
function hcol(h){return h==='fast'?'#3DDC84':h==='slow'?'#FFB338':h==='dead'?'#FF5A5A':'#4A4A54'}
function render(arr){
 const g=document.getElementById('grid');
 g.innerHTML=arr.map(c=>{
  const safeId=(c.id||'').replace(/'/g,'');
  const logo=c.logo?'<img src="'+esc(c.logo)+'" loading="lazy" onerror="this.remove()"/>':'<span class="fb">📺</span>';
  return '<button class="tile" onclick="play(\''+safeId+'\')"><span class="dotrow"><i style="width:8px;height:8px;border-radius:50%;background:'+hcol(c.health)+'"></i><span class="play">PLAY</span></span>'+logo+'<span class="t">'+esc(c.name)+'</span><span class="c">'+esc(c.category||'')+'</span></button>'}).join('');
 const empty=document.getElementById('chEmpty');
 const hasCats=cats&&cats.length>0;
 empty.style.display=(!hasCats||arr.length===0&&!document.getElementById('q').value)?'block':'none';
 if(!hasCats){g.innerHTML='';empty.style.display='block'}
 else if(arr.length===0){empty.style.display='block';empty.querySelector('h3').textContent='Nothing found';empty.querySelector('p').textContent='Try another search or list.';empty.querySelector('.go').style.display='none'}
 else{empty.querySelector('h3').textContent='No lists yet';empty.querySelector('p').textContent='Paste an M3U link under Lists and it appears here as its own tab.';empty.querySelector('.go').style.display='';empty.style.display='none'}}
function tab(t){for(const x of['remote','ch','lists','settings']){document.getElementById('pg-'+x).classList.toggle('on',x===t);document.getElementById('nv-'+x).classList.toggle('on',x===t)}
closeDrawer();window.scrollTo({top:0});
if(t==='ch')loadCats();if(t==='lists')loadPlaylists();if(t==='settings')loadSettings()}
async function loadCats(){try{const r=await fetch('/api/categories');cats=await r.json();
 const box=document.getElementById('chips');
 if(!cats.length){box.innerHTML='';document.getElementById('chCount').textContent='0 lists';
  document.getElementById('grid').innerHTML='';document.getElementById('chEmpty').style.display='block';return}
 document.getElementById('chEmpty').style.display='none';
 box.innerHTML=cats.map((c,i)=>'<button class="chip" id="chip-'+i+'" onclick="selectCat('+i+')">'+esc(c.title||('List '+(i+1)))+'</button>').join('');
 if(curCat>=cats.length)curCat=0;selectCat(curCat)}catch(e){}}
function selectCat(i){curCat=i;for(let k=0;k<cats.length;k++){const b=document.getElementById('chip-'+k);if(b)b.classList.toggle('on',k===i)}
 document.getElementById('q').value='';loadCatChannels('')}
async function loadCatChannels(q){try{const c=cats[curCat];
 if(!c){render([]);return}
 const r=await fetch('/api/channels?category='+encodeURIComponent(c.index)+'&q='+encodeURIComponent(q||'')+'&limit=2000');
 const arr=await r.json();render(arr);
 document.getElementById('chCount').textContent=(c.count!=null?c.count:arr.length)+' channels • '+esc(c.title||'')}catch(e){}}
function search(q){clearTimeout(deb);deb=setTimeout(()=>loadCatChannels(q),220)}
async function viewList(name){tab('ch');try{const r=await fetch('/api/categories');cats=await r.json()}catch(e){}
 const nl=(name||'').toLowerCase().replace(/★/g,'').trim();
 const i=cats.findIndex(c=>((c.title||'').toLowerCase().replace(/★/g,'').trim()===nl)||((c.title||'').toLowerCase().indexOf(nl)>=0&&nl));
 selectCat(i<0?0:i)}
function bufPreview(v){document.getElementById('bufVal').innerHTML=v+'<small>s</small>'}
async function loadSettings(){try{const r=await fetch('/api/settings');const j=await r.json();
 const v=j.prebufferSecs??5;document.getElementById('bufRange').value=v;bufPreview(v);
 const rr=j.repeatRate??6;document.getElementById('repRange').value=rr;repPreview(rr)}catch(e){}}
async function saveBuffer(){const v=parseInt(document.getElementById('bufRange').value||'5');
 const rr=parseInt(document.getElementById('repRange').value||'6');
 const b=document.getElementById('bufBtn');b.disabled=true;
 try{const r=await fetch('/api/settings',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({prebufferSecs:v,repeatRate:rr})});
 const j=await r.json();const m=document.getElementById('bufMsg');
 if(j.ok){repeatRate=j.repeatRate||rr;m.textContent='Saved — buffer '+j.prebufferSecs+'s, glide '+(j.repeatRate||rr)+'/s.';m.className='plmsg ok'}else{m.textContent='Save failed.';m.className='plmsg err'}}catch(e){const m=document.getElementById('bufMsg');m.textContent='Network error.';m.className='plmsg err'}
 b.disabled=false}
function plMsg(t,cls){const e=document.getElementById('plMsg');e.textContent=t;e.className='plmsg '+(cls||'')}
async function loadPlaylists(){try{const r=await fetch('/api/playlists');const arr=await r.json();
 const n=arr.length;
 document.getElementById('listsCount').textContent=n===0?'No saved playlists yet':n===1?'1 saved playlist • tap to open its channels':n+' saved playlists • tap to open its channels';
 document.getElementById('plList').innerHTML=arr.map(p=>
 '<div class="lrow"><button class="lmain" onclick="viewList(decodeURIComponent(\''+encodeURIComponent(p.name).replace(/'/g,'%27')+'\'))">'
 +'<span class="lstar">★</span><span class="ltx"><b>'+esc(p.name)+'</b><span>'+p.count+' channels</span></span><span class="lgo">›</span></button>'
 +'<button class="lrm" onclick="delPlaylist(\''+p.id+'\')" aria-label="Remove '+esc(p.name)+'">Remove</button></div>').join('')||'<div class="lEmpty">Nothing saved yet.<br/>Add your first list above.</div>'}catch(e){}}
async function addPlaylist(){
 const name=document.getElementById('plName').value.trim()||'My List';
 const url=document.getElementById('plUrl').value.trim();
 if(!url){plMsg('Paste an M3U link first.','err');return}
 const btn=document.getElementById('plBtn');btn.disabled=true;btn.textContent='Saving…';plMsg('Fetching playlist…','');
 try{const r=await fetch('/api/playlists',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name,url})});
 const j=await r.json();
 if(j.ok){plMsg('Saved '+name+' — '+j.playlist.count+' channels on TV.','ok');
 document.getElementById('plUrl').value='';loadPlaylists();loadCats()}
 else plMsg(j.error||'Could not save that link.','err')}catch(e){plMsg('Network error — is the TV online?','err')}
 btn.disabled=false;btn.textContent='Save list to TV'}
async function delPlaylist(id){
 if(!confirm('Remove this list from the TV?'))return;
 await fetch('/api/playlists?id='+encodeURIComponent(id),{method:'DELETE'});
 if(curCat>=cats.length-1)curCat=0;
 loadPlaylists();loadCats()}
function connect(){
 try{ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+'/ws');
 ws.onopen=()=>{setConn(true,'live');pull()};
 ws.onmessage=e=>{try{const j=JSON.parse(e.data);if(j.type==='now'||j.type==='hello')paint(j);if(j.type==='playlists'){loadPlaylists();loadCats()}}catch(_){}};
 ws.onclose=()=>{setConn(false,'retry…');setTimeout(connect,2000)}}catch(e){setConn(false,'offline')}}
connect();pull();loadPlaylists();loadCats();
setInterval(()=>{if(!ws||ws.readyState!==1)pull()},8000);
</script></body></html>
''';

}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
