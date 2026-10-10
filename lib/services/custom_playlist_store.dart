import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/custom_playlist.dart';
import 'app_cache.dart';

/// Disk persistence for pasted playlists. Stored as a JSON FILE (via
/// AppCache) — a 2000-channel list is ~0.5MB, which must never sit in
/// SharedPreferences (the plugin keeps the whole prefs file in RAM).
/// A one-time import migrates lists saved by older builds.
class CustomPlaylistStore {
  static const _file = 'custom_playlists.json';
  static const _legacyKey = 'opentv_custom_playlists_v1';
  static const _maxChannelsPerList = 2000;

  static Future<List<CustomPlaylist>> load() async {
    try {
      final raw = await AppCache.readText(_file);
      if (raw != null && raw.isNotEmpty) {
        return _decode(raw);
      }
    } catch (_) {}
    // Legacy import (once): prefs → file, then drop the prefs blob.
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_legacyKey);
      if (raw != null && raw.isNotEmpty) {
        final lists = _decode(raw);
        await saveAll(lists);
        await prefs.remove(_legacyKey);
        return lists;
      }
    } catch (_) {}
    return [];
  }

  static List<CustomPlaylist> _decode(String raw) {
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final e in list)
          CustomPlaylist.fromJson(
              Map<String, dynamic>.from(e as Map))
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveAll(
      List<CustomPlaylist> lists) async {
    try {
      final capped = [
        for (final p in lists)
          p
              .copyWith(
                  channels: p.channels
                      .take(_maxChannelsPerList)
                      .toList())
              .toJson()
      ];
      await AppCache.writeText(_file, jsonEncode(capped));
    } catch (_) {}
  }
}
