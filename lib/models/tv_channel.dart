// Single source of truth for a playable TV channel.
class TvChannel {
  final String id;
  final String name;
  final String streamUrl;
  final String logoUrl;
  final String category; // e.g. "India News", "Global News", "Music"
  final String country; // ISO-ish: "IN", "US", "UK", "GLOBAL"
  final String language;

  const TvChannel({
    required this.id,
    required this.name,
    required this.streamUrl,
    this.logoUrl = '',
    this.category = 'General',
    this.country = 'GLOBAL',
    this.language = '',
  });

  factory TvChannel.fromJson(Map<String, dynamic> j) => TvChannel(
        id: '${j['id'] ?? j['name']}',
        name: '${j['name'] ?? 'Unknown'}',
        streamUrl: '${j['url'] ?? ''}',
        logoUrl: '${j['logo'] ?? ''}',
        category: '${j['category'] ?? 'General'}',
        country: '${j['country'] ?? 'GLOBAL'}',
        language: '${j['language'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': streamUrl,
        'logo': logoUrl,
        'category': category,
        'country': country,
        'language': language,
      };
}

// A rail = one horizontal Netflix-style row.
class ChannelRail {
  final String title;
  final String subtitle;
  final List<TvChannel> channels;
  const ChannelRail(this.title, this.subtitle, this.channels);
}
