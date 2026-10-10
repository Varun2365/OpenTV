// File-backed blob cache. Big payloads (M3U text, saved playlists) live
// here as files instead of SharedPreferences — the prefs plugin holds its
// ENTIRE file in RAM, so megabyte blobs in prefs would permanently tax the
// Pi's memory. Files are read once, parsed, and released.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppCache {
  static Directory? _dir;

  static Future<Directory> dir() async {
    final d = _dir;
    if (d != null) return d;
    // Standard path (Windows / desktop Linux: path_provider works).
    try {
      final base = await getApplicationSupportDirectory();
      final out = Directory(p.join(base.path, 'opentv'));
      await out.create(recursive: true);
      return _dir = out;
    } catch (_) {
      // flutter-pi has no path_provider native plugin (custom embedder,
      // linux/runner is never built) — fall back to a plain directory
      // so catalog + playlists still cache instead of throwing.
    }
    for (final candidate in [
      Platform.environment['HOME'],
      Platform.environment['XDG_DATA_HOME'],
      Directory.systemTemp.path,
      '.',
    ]) {
      if (candidate == null || candidate.isEmpty) continue;
      try {
        final out = Directory(p.join(candidate, '.opentv'));
        await out.create(recursive: true);
        return _dir = out;
      } catch (_) {}
    }
    // Absolute last resort: current directory (always writable-ish).
    final out = Directory('.opentv');
    try {
      await out.create(recursive: true);
    } catch (_) {}
    return _dir = out;
  }

  static Future<String?> readText(String name) async {
    try {
      final f = File(p.join((await dir()).path, name));
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeText(
      String name, String data) async {
    try {
      final f = File(p.join((await dir()).path, name));
      await f.writeAsString(data, flush: true);
    } catch (_) {}
  }
}
