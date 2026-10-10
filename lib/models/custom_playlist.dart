import 'tv_channel.dart';

/// A user-pasted M3U playlist: name + source URL + resolved channels.
/// Adds remote-chosen [icon] (key mapped to Material Icons on the TV) and
/// [color] (ARGB, shown on the sidebar when selected).
/// Persisted as a FILE so it survives reboot on the Pi.
class CustomPlaylist {
  static const defaultIcon = 'tv';
  static const defaultColor = 0xFF3D9BFF;

  final String id;
  final String name;
  final String url;
  final DateTime addedAt;
  final List<TvChannel> channels;
  final String icon;
  final int color;

  const CustomPlaylist({
    required this.id,
    required this.name,
    required this.url,
    required this.addedAt,
    this.channels = const [],
    this.icon = defaultIcon,
    this.color = defaultColor,
  });

  CustomPlaylist copyWith({
    String? name,
    String? url,
    List<TvChannel>? channels,
    String? icon,
    int? color,
  }) =>
      CustomPlaylist(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        addedAt: addedAt,
        channels: channels ?? this.channels,
        icon: icon ?? this.icon,
        color: color ?? this.color,
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
        icon: '${j['icon'] ?? defaultIcon}',
        color: (j['color'] is int)
            ? (j['color'] as int) & 0xFFFFFFFF
            : defaultColor,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'addedAt': addedAt.toIso8601String(),
        'channels': [for (final c in channels) c.toJson()],
        'icon': icon,
        'color': color,
      };

  Map<String, dynamic> summaryJson() => {
        'id': id,
        'name': name,
        'url': url,
        'count': channels.length,
        'addedAt': addedAt.toIso8601String(),
        'icon': icon,
        'color': color,
      };
}
