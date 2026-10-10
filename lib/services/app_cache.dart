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
    final base = await getApplicationSupportDirectory();
    final out = Directory(p.join(base.path, 'opentv'));
    await out.create(recursive: true);
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
