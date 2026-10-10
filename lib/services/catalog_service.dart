// India-first catalog with global rails.
// Strategy (Pi-friendly): fetch curated iptv-org M3U files once, parse in an
// isolate, cache raw M3U to disk for 6h. Always keep a bundled fallback of
// known-good FTA streams so first boot works offline.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/tv_channel.dart';
import 'app_cache.dart';

class CatalogService {
  // M3U text lives in a FILE (multi-MB); only the timestamp stays in prefs.
  static const _cacheFile = 'm3u_cache.txt';
  static const _cacheTimeKey = 'opentv_m3u_cache_time_v1';
  static const _cacheTtl = Duration(hours: 6);

  // Small, fast lists (not the 8000-channel mega file — Pi 4 can't scroll that).
  static const sources = <String, String>{
    'IN-news':
        'https://iptv-org.github.io/iptv/countries/in.m3u',
    'IN-entertainment': 'https://iptv-org.github.io/iptv/countries/in.m3u',
    'Global-news':
        'https://iptv-org.github.io/iptv/categories/news.m3u',
    'Global-music':
        'https://iptv-org.github.io/iptv/categories/music.m3u',
    'Global-kids':
        'https://iptv-org.github.io/iptv/categories/kids.m3u',
    'Global-movies':
        'https://iptv-org.github.io/iptv/categories/movies.m3u',
  };

  /// Curated always-works FTA fallback (direct HLS, no scraping).
  /// India rails populate from the live iptv-org fetch; these 6 globals
  /// guarantee first boot works even offline.
  static List<TvChannel> fallback() => const [
        TvChannel(
            id: 'aljazeera', name: 'Al Jazeera English',
            category: 'Global • News', country: 'GLOBAL',
            streamUrl:
                'https://live-hls-web-aje.getaj.net/AJE/index.m3u8'),
        TvChannel(
            id: 'dw', name: 'DW English', category: 'Global • News',
            country: 'DE',
            streamUrl:
                'https://dwamdstream102.akamaized.net/hls/live/2015525/dwstream102/index.m3u8'),
        TvChannel(
            id: 'france24', name: 'France 24 English',
            category: 'Global • News', country: 'FR',
            streamUrl:
                'https://live.france24.com/hls/live/2033160/F24_EN_HI_HLS/master_5000.m3u8'),
        TvChannel(
            id: 'nhk', name: 'NHK World', category: 'Global • News',
            country: 'JP',
            streamUrl:
                'https://nhkwlive-ojp.akamaized.net/hls/live/2004578-nhkwlive-ojp-en/index.m3u8'),
        TvChannel(
            id: 'nasa', name: 'NASA TV', category: 'Global • Science',
            country: 'US',
            streamUrl:
                'https://ntv1.akamaized.net/hls/live/2014075/NASA-NTV1-HLS/master.m3u8'),
        TvChannel(
            id: 'redbull', name: 'Red Bull TV', category: 'Global • Sports',
            country: 'GLOBAL',
            streamUrl:
                'https://rbmn-live.akamaized.net/hls/live/590964/BoRB-AT/master.m3u8'),
      ];

  /// Fetch + parse ONE user-pasted M3U URL (from the phone remote).
  /// Throws a human-readable string on failure so the phone UI can show it.
  /// IDs are namespaced with [idPrefix] so pasted channels never collide
  /// with built-in ones and can be played / deleted independently.
  static Future<List<TvChannel>> fetchCustomM3U(String url,
      {String idPrefix = 'u', String category = 'My List'}) async {
    final u = url.trim();
    final uri = Uri.tryParse(u);
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw 'Paste a full http(s) link, e.g. https://…/in.m3u';
    }
    final res = await http
        .get(uri, headers: {'User-Agent': 'OpenTV-RPI/1.0'})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw 'Link returned HTTP ${res.statusCode}';
    }
    if (!res.body.contains('#EXTINF') &&
        !res.body.contains('#EXTM3U')) {
      throw 'That link is not an M3U playlist';
    }
    if (res.body.length > 2 * 1024 * 1024) {
      throw 'Playlist too large (over 2MB)';
    }
    final parsed =
        await compute(_parseM3U, _M3UJob(res.body, 'custom'));
    if (parsed.isEmpty) throw 'No playable streams found in that list';
    // Namespace IDs + default empty group-titles to the list name.
    var n = 0;
    return [
      for (final c in parsed.take(2000))
        TvChannel(
          id: '$idPrefix${n++}_${c.streamUrl.hashCode & 0xffffff}',
          name: c.name,
          streamUrl: c.streamUrl,
          logoUrl: c.logoUrl,
          category: c.category == 'General' ? category : c.category,
          country: c.country,
          language: c.language,
        ),
    ];
  }

  /// Parse raw pasted M3U text (also used by tests / future file import).
  static Future<List<TvChannel>> parseM3UText(String raw,
      {String idPrefix = 'u', String category = 'My List'}) async {
    final parsed = await compute(_parseM3U, _M3UJob(raw, 'text'));
    var n = 0;
    return [
      for (final c in parsed.take(2000))
        TvChannel(
          id: '$idPrefix${n++}_${c.streamUrl.hashCode & 0xffffff}',
          name: c.name,
          streamUrl: c.streamUrl,
          logoUrl: c.logoUrl,
          category: c.category == 'General' ? category : c.category,
          country: c.country,
          language: c.language,
        ),
    ];
  }

  static Future<(List<TvChannel>, List<ChannelRail>)> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedAt =
          DateTime.tryParse(prefs.getString(_cacheTimeKey) ?? '');
      String? cachedRaw;
      if (cachedAt != null &&
          DateTime.now().difference(cachedAt) < _cacheTtl) {
        // File-backed (see AppCache): a 3MB M3U must not live in prefs RAM.
        cachedRaw = await AppCache.readText(_cacheFile);
      }

      if (cachedRaw != null && cachedRaw.isNotEmpty) {
        final list = await compute(
            _parseM3U, _M3UJob(cachedRaw, 'cache'));
        return _buildRails(list);
      }

      // Fetch all sources CONCURRENTLY — sequential 8s timeouts made
      // boot take up to ~1min on slow networks. Slow sources just resolve
      // to '' and are skipped.
      final results = await Future.wait(
        sources.entries.map((e) async {
          try {
            final res = await http
                .get(Uri.parse(e.value))
                .timeout(const Duration(seconds: 10));
            if (res.statusCode == 200 &&
                res.body.contains('#EXTINF')) {
              return res.body;
            }
          } catch (_) {
            // per-source failure is fine — fallback covers it
          }
          return '';
        }),
        eagerError: false,
      );
      final buffer = StringBuffer();
      for (final body in results) {
        if (body.isNotEmpty) {
          buffer.writeln(body);
          if (buffer.length > 3000000) break; // cap ~3MB for Pi memory
        }
      }
      if (buffer.isEmpty) return _buildRails(fallback());
      final parsed =
          await compute(_parseM3U, _M3UJob(buffer.toString(), 'net'));
      if (parsed.isEmpty) return _buildRails(fallback());
      try {
        await AppCache.writeText(_cacheFile, buffer.toString());
        await prefs.setString(
            _cacheTimeKey, DateTime.now().toIso8601String());
      } catch (_) {}
      return _buildRails(parsed);
    } catch (_) {
      return _buildRails(fallback());
    }
  }

  static (List<TvChannel>, List<ChannelRail>) _buildRails(
      List<TvChannel> all) {
    // De-dupe by stream URL, drop audio-only / dead entries.
    final seen = <String>{};
    final clean = <TvChannel>[];
    for (final c in all) {
      if (c.streamUrl.isEmpty || !c.streamUrl.startsWith('http')) continue;
      if (!seen.add(c.streamUrl)) continue;
      clean.add(c);
      if (clean.length >= 3000) break; // Pi-safe upper bound
    }
    final base = clean.isEmpty ? fallback() : clean;

    // No per-rail take() limits: rails are ListView.builder-based, so
    // hundreds of cards cost nothing off-screen. Show everything.
    List<TvChannel> pick(bool Function(TvChannel) f) =>
        base.where(f).toList();

    final inNews = pick((c) =>
        c.country == 'IN' ||
        c.category.toLowerCase().contains('news') &&
            (c.language.toLowerCase().contains('hindi') ||
                c.name.toLowerCase().contains('india')));
    final inGeneral = pick((c) => c.country == 'IN');
    final gNews = pick((c) => c.category.toLowerCase().contains('news'));
    final gMusic = pick((c) =>
        c.category.toLowerCase().contains('music') ||
        c.name.toLowerCase().contains('music'));
    final gKids = pick(
        (c) => c.category.toLowerCase().contains('kid'));
    final gMovies = pick(
        (c) => c.category.toLowerCase().contains('movie'));

    final rails = <ChannelRail>[
      if (inNews.isNotEmpty)
        ChannelRail('India • News & Live',
            'Desh ke top live channels', inNews),
      if (inGeneral.isNotEmpty)
        ChannelRail('India • Entertainment',
            'Hindi + regional picks', inGeneral),
      ChannelRail('Continue Watching', 'Pick up where you left off',
          base.take(12).toList()),
      if (gNews.isNotEmpty)
        ChannelRail('Global • News 24/7', 'Al Jazeera • DW • France 24', gNews),
      if (gMusic.isNotEmpty)
        ChannelRail('Music', '24/7 music TV', gMusic),
      if (gKids.isNotEmpty)
        ChannelRail('Kids', 'Family safe', gKids),
      if (gMovies.isNotEmpty)
        ChannelRail('Movies & Shows', 'FAST cinema', gMovies),
      ChannelRail(
          'All Channels', '${base.length} free streams', List.of(base)),
    ];
    return (base, rails);
  }
}

class _M3UJob {
  final String raw;
  final String tag;
  _M3UJob(this.raw, this.tag);
}

/// Runs in an isolate via compute(). Minimal EXTINF parser — no regex storms.
List<TvChannel> _parseM3U(_M3UJob job) {
  final out = <TvChannel>[];
  final lines = const LineSplitter().convert(job.raw);
  String name = '', logo = '', group = '', country = '';
  var n = 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('#EXTINF')) {
      name = line.contains(',')
          ? line.substring(line.lastIndexOf(',') + 1).trim()
          : 'Channel ${out.length + 1}';
      logo = _attr(line, 'tvg-logo');
      group = _attr(line, 'group-title');
      country = _attr(line, 'tvg-country').toUpperCase();
      if (country.isEmpty) {
        final lc = (group + name).toLowerCase();
        if (lc.contains('india') || lc.contains('hindi')) {
          country = 'IN';
        } else {
          country = 'GLOBAL';
        }
      }
    } else if (line.isNotEmpty && !line.startsWith('#')) {
      // Accept any http(s) stream URL (HLS .m3u8, DASH .mpd, or raw .ts) —
      // pasted user lists vary, mpv plays them all.
      if (line.startsWith('http')) {
        out.add(TvChannel(
          id: 'c${n++}',
          name: name.isEmpty ? 'Channel $n' : name,
          streamUrl: line,
          logoUrl: logo,
          category: group.isEmpty ? 'General' : group,
          country: country.isEmpty ? 'GLOBAL' : country,
        ));
        name = '';
        logo = '';
        group = '';
        country = '';
        if (out.length >= 3000) break;
      }
    }
  }
  return out;
}

String _attr(String line, String key) {
  final k = '$key="';
  final s = line.indexOf(k);
  if (s < 0) return '';
  final e = line.indexOf('"', s + k.length);
  if (e < 0) return '';
  return line.substring(s + k.length, e);
}
