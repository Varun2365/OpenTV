// Background stream-health prober. Hits every channel's URL concurrently
// (12 at a time), samples ~2.5s of bytes, and scores fast/slow/dead.
// Results are cached 24h so each boot only re-probes stale entries.
// This is the "parallel" fix for laggy free sources: measure everything,
// then sort fast streams first instead of hoping.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/tv_channel.dart';

class StreamHealth {
  static const _key = 'opentv_health_v1';
  static const ttl = Duration(hours: 24);
  static const concurrency = 12;
  static const maxProbes = 400;

  // Sample window per probe. Short enough to finish ~400 probes in ~2min
  // in the background, long enough to separate fast from trickling servers.
  static const sampleWindow = Duration(milliseconds: 2500);

  // Thresholds over the sample window (~1Mbps needed for smooth SD).
  static const fastBytes = 320 * 1024;
  static const deadBytes = 24 * 1024;

  static int rank(String? h) {
    switch (h) {
      case 'fast':
        return 0;
      case 'slow':
        return 2;
      case 'dead':
        return 3;
      case 'unknown':
      default:
        return 1;
    }
  }

  /// Health for [channels] from cache (fresh entries only, else 'unknown').
  static Future<Map<String, String>> cachedHealth(
      List<TvChannel> channels) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return {};
      final cache = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final now = DateTime.now();
      final out = <String, String>{};
      for (final c in channels) {
        final e = cache[c.streamUrl];
        if (e is Map) {
          final t = DateTime.tryParse('${e['t']}');
          if (t != null && now.difference(t) < ttl) {
            out[c.id] = '${e['h']}';
          }
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  /// Probe up to [maxProbes] channels concurrently. Returns id → health.
  /// Never throws — failures score 'dead'.
  static Future<Map<String, String>> probeChannels(
      List<TvChannel> channels) async {
    final targets = channels.take(maxProbes).toList();
    final out = <String, String>{};
    try {
      for (var i = 0; i < targets.length; i += concurrency) {
        final chunk = targets.skip(i).take(concurrency).toList();
        final res = await Future.wait(
            chunk.map(_probeOne),
            eagerError: false);
        for (var k = 0; k < chunk.length; k++) {
          out[chunk[k].id] = res[k];
        }
      }
      await _store(targets, out);
    } catch (_) {}
    return out;
  }

  // Hard ceiling per probe: quit sampling at 512KB — plenty to score
  // 'fast', and it bounds transient RAM to ~6MB across 12 concurrent
  // probes instead of ballooning on gigabit servers. Never drain a live
  // (infinite) response.
  static const sampleCap = 512 * 1024;

  static Future<String> _probeOne(TvChannel c) async {
    final client = http.Client();
    StreamSubscription? sub;
    try {
      final req =
          http.Request('GET', Uri.parse(c.streamUrl));
      req.headers['Range'] = 'bytes=0-131071';
      req.headers['User-Agent'] = 'OpenTV-RPI/1.0';
      final resp = await client
          .send(req)
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200 &&
          resp.statusCode != 206) {
        try {
          await resp.stream.drain();
        } catch (_) {}
        return 'dead';
      }
      var bytes = 0;
      final done = Completer<void>();
      Timer? window;
      window = Timer(sampleWindow, () {
        if (!done.isCompleted) done.complete();
      });
      sub = resp.stream.listen(
          (chunk) {
            bytes += (chunk as List).length;
            if (bytes >= sampleCap && !done.isCompleted) {
              done.complete(); // fast — stop drinking
            }
          },
          onError: (_) {
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          });
      await done.future;
      window.cancel();
      try {
        await sub.cancel();
      } catch (_) {}
      if (bytes < deadBytes) return 'dead';
      if (bytes < fastBytes) return 'slow';
      return 'fast';
    } catch (_) {
      return 'dead';
    } finally {
      try {
        await sub?.cancel();
      } catch (_) {}
      try {
        client.close();
      } catch (_) {}
    }
  }

  static Future<void> _store(
      List<TvChannel> targets, Map<String, String> out) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final prev = <String, dynamic>{};
      try {
        final raw = prefs.getString(_key);
        if (raw != null && raw.isNotEmpty) {
          prev.addAll(
              Map<String, dynamic>.from(jsonDecode(raw) as Map));
        }
      } catch (_) {}
      final now = DateTime.now().toIso8601String();
      for (final c in targets) {
        final h = out[c.id];
        if (h != null) {
          prev[c.streamUrl] = {'h': h, 't': now};
        }
      }
      await prefs.setString(_key, jsonEncode(prev));
    } catch (_) {}
  }
}
