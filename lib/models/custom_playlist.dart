import 'tv_channel.dart';

/// A user-pasted M3U playlist: name + source URL + resolved channels.
/// Persisted to SharedPreferences so it survives reboot on the Pi.
class CustomPlaylist {
  final String id;
  final String name;
  final String url;
  final DateTime addedAt;
  final List<TvChannel> channels;

  const CustomPlaylist({
    required this.id,
    required this.name,
    required this.url,
    required this.addedAt,
    this.channels = const [],
  });

  CustomPlaylist copyWith({
    String? name,
    String? url,
    List<TvChannel>? channels,
  }) =>
      CustomPlaylist(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        addedAt: addedAt,
        channels: channels ?? this.channels,
      );

  factory CustomPlaylist.fromJson(Map<String, dynamic> j) =>
      CustomPlaylist(
        id: '${j['id']}',
        name: '${j['name'] ?? 'My List'}',
        url: '${j['url'] ?? ''}',
        addedAt: DateTime.tryParse('${j['addedAt']}') ?? DateTime.now(),
        channels: [
          for (final c in (j['channels'] as List? ?? const []))
            TvChannel.fromJson(
                Map<String, dynamic>.from(c as Map)),
        ],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'addedAt': addedAt.toIso8601String(),
        'channels': [for (final c in channels) c.toJson()],
      };

  Map<String, dynamic> summaryJson() => {
        'id': id,
        'name': name,
        'url': url,
        'count': channels.length,
        'addedAt': addedAt.toIso8601String(),
      };
}
