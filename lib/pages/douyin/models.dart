import 'dart:convert';

/// 抖音 / TikTok 共用的平台描述。
///
/// 两个站的网页版结构几乎一样：React 前端 + 需要签名的 JSON 接口。抓取、
/// 解析、播放共用一套代码，只在这里区分 URL、UA 和字段名。
enum ShortVideoPlatform {
  douyin(
    id: 'douyin',
    title: '抖音收藏',
    album: '抖音',
    homeUrl: 'https://www.douyin.com/',
    favoritesUrl: 'https://www.douyin.com/user/self?showTab=favorite_collection',
    referer: 'https://www.douyin.com/',
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) '
        'Version/17.4 Safari/605.1.15',
    mobileUserAgent:
        'Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) '
        'Version/15.0 Mobile/15E148 Safari/604.1',
    loginUrl: 'https://sso.douyin.com/',
    cookieDomainNeedle: 'douyin.com',
    tabTitles: ['收藏', '收藏夹'],
    markers: ['aweme_list', 'aweme_detail'],
  ),
  tiktok(
    id: 'tiktok',
    title: 'TikTok 收藏',
    album: 'TikTok',
    homeUrl: 'https://www.tiktok.com/',
    favoritesUrl: 'https://www.tiktok.com/@me',
    referer: 'https://www.tiktok.com/',
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) '
        'Version/17.4 Safari/605.1.15',
    mobileUserAgent:
        'Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) '
        'Version/15.0 Mobile/15E148 Safari/604.1',
    loginUrl: 'https://www.tiktok.com/login',
    cookieDomainNeedle: 'tiktok.com',
    tabTitles: ['收藏', 'Favorites', 'Favorite'],
    markers: ['itemList', 'itemStruct', 'item_list'],
  );

  const ShortVideoPlatform({
    required this.id,
    required this.title,
    required this.album,
    required this.homeUrl,
    required this.favoritesUrl,
    required this.referer,
    required this.userAgent,
    required this.mobileUserAgent,
    required this.loginUrl,
    required this.cookieDomainNeedle,
    required this.tabTitles,
    required this.markers,
  });

  final String id;
  final String title;
  final String album;
  final String homeUrl;

  /// 收藏页。登录在首页做，抓取在收藏页做——`/user/self` 未登录时是半残页，
  /// 直接当首页会连登录按钮都点不动。
  final String favoritesUrl;
  final String referer;
  final String userAgent;
  final String mobileUserAgent;

  /// 站点自己的登录页（抖音是 sso.douyin.com）。
  final String loginUrl;
  final String cookieDomainNeedle;
  final List<String> tabTitles;

  /// 响应体里出现这些键才值得回传。
  final List<String> markers;

  String get siteUrl => album == '抖音'
      ? 'https://www.douyin.com/'
      : 'https://www.tiktok.com/';

  String shareUrl(String videoId) => id == 'douyin'
      ? 'https://www.douyin.com/video/$videoId'
      : 'https://www.tiktok.com/@i/video/$videoId';

  static ShortVideoPlatform? fromId(String? value) {
    for (final platform in values) {
      if (platform.id == value) return platform;
    }
    return null;
  }
}

/// 一条短视频。字段名与 WebDAV 同步用的 JSON 一一对应，Kumone 和 PiliPlus
/// 读写同一个远端文件。
class ShortVideo {
  const ShortVideo({
    required this.id,
    required this.platform,
    required this.desc,
    required this.author,
    required this.cover,
    required this.durationMs,
    required this.playUrl,
    this.videoId = '',
    this.updatedAt = 0,
  });

  final String id;
  final String platform;
  final String desc;
  final String author;
  final String cover;
  final int durationMs;
  final String playUrl;

  /// 站点自己的视频 id（抖音是 `play_addr.uri`）。用它拼出来的地址不带过期
  /// 签名，同步到别的手机、或者放几个小时之后都还能播。
  final String videoId;
  final double updatedAt;

  /// 不带过期签名的播放地址；没有 `videoId` 时返回 null。
  String? get stableUrl {
    if (videoId.isEmpty) return null;
    final encoded = Uri.encodeComponent(videoId);
    return platform == 'tiktok'
        ? 'https://api16-normal-c-useast1a.tiktokv.com/aweme/v1/play/'
              '?video_id=$encoded&ratio=720p&line=0'
        : 'https://www.iesdouyin.com/aweme/v1/play/'
              '?video_id=$encoded&ratio=720p&line=0';
  }

  /// 跨 App 的唯一键（不同平台的数字 id 会撞）。
  String get key => '$platform:$id';

  String get title => desc.trim().isEmpty ? '短视频' : desc.trim();

  String get durationText {
    if (durationMs <= 0) return '--:--';
    final total = durationMs ~/ 1000;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  ShortVideo copyWith({String? playUrl, String? videoId, double? updatedAt}) =>
      ShortVideo(
        id: id,
        platform: platform,
        desc: desc,
        author: author,
        cover: cover,
        durationMs: durationMs,
        playUrl: playUrl ?? this.playUrl,
        videoId: videoId ?? this.videoId,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'platform': platform,
    'desc': desc,
    'author': author,
    'cover': cover,
    'durationMS': durationMs,
    'playURL': playUrl,
    'videoID': videoId,
    'updatedAt': updatedAt,
  };

  factory ShortVideo.fromJson(Map<String, dynamic> json) {
    final playUrl = '${json['playURL'] ?? json['playUrl'] ?? ''}';
    return ShortVideo(
      id: '${json['id'] ?? ''}',
      platform: _normalizePlatform('${json['platform'] ?? ''}', playUrl),
      desc: '${json['desc'] ?? ''}',
      author: '${json['author'] ?? ''}',
      cover: '${json['cover'] ?? ''}',
      durationMs: json['durationMS'] is num
          ? (json['durationMS'] as num).toInt()
          : int.tryParse('${json['durationMS'] ?? ''}') ?? 0,
      playUrl: playUrl,
      videoId: '${json['videoID'] ?? json['videoId'] ?? ''}',
      updatedAt: (json['updatedAt'] as num?)?.toDouble() ?? 0,
    );
  }

  /// 远端文件可能是别的版本写的：平台名大小写不一、或者干脆没这个字段。
  /// 认不出来就看播放地址的域名——别把 TikTok 的条目塞进抖音列表。
  static String _normalizePlatform(String raw, String playUrl) {
    final value = raw.trim().toLowerCase();
    if (value.contains('tiktok') || value == 'tt') return 'tiktok';
    if (value.contains('douyin') || value == 'dy' || value == '抖音') {
      return 'douyin';
    }
    if (playUrl.toLowerCase().contains('tiktok')) return 'tiktok';
    return 'douyin';
  }
}

abstract final class ShortVideoParser {

  /// 解析网页里截获的一段 JSON。
  ///
  /// 抖音是 `aweme_list` / `aweme_detail`，TikTok 是 `itemList` / `itemStruct`；
  /// `video` 字段名也不同（`play_addr` vs `playAddr`），`duration` 一个是
  /// 毫秒一个是秒。
  static List<ShortVideo> fromResponseBody(
    String body,
    ShortVideoPlatform platform,
  ) {
    if (body.length < 40) return const [];
    if (!platform.markers.any(body.contains)) return const [];
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const [];
      return fromJsonObject(decoded.cast<String, dynamic>(), platform);
    } catch (_) {
      return const [];
    }
  }

  static List<ShortVideo> fromJsonObject(
    Map<String, dynamic> root,
    ShortVideoPlatform platform,
  ) {
    for (final key in const [
      'aweme_list',
      'itemList',
      'item_list',
      'awemeList',
    ]) {
      final list = root[key];
      if (list is List) {
        return list
            .whereType<Map>()
            .map((e) => _fromItem(e.cast<String, dynamic>(), platform))
            .whereType<ShortVideo>()
            .toList();
      }
    }
    for (final key in const ['aweme_detail', 'itemStruct', 'itemInfo']) {
      final detail = root[key];
      if (detail is Map) {
        final video = _fromItem(detail.cast<String, dynamic>(), platform);
        if (video != null) return [video];
      }
    }
    return const [];
  }

  static ShortVideo? _fromItem(
    Map<String, dynamic> item,
    ShortVideoPlatform platform,
  ) {
    // 有的接口把条目包一层：{ "itemStruct": { ... } }（App 端格式）。
    final nested = item['itemStruct'];
    final source = nested is Map ? nested.cast<String, dynamic>() : item;

    final id =
        '${source['aweme_id'] ?? source['id'] ?? item['aweme_id'] ?? item['id'] ?? ''}';
    if (id.isEmpty) return null;
    final video = source['video'] ?? item['video'];
    if (video is! Map) return null;
    final videoMap = video.cast<String, dynamic>();

    String? playUrl;
    var durationMs = 0;
    var cover = '';
    var videoId = '';

    switch (platform) {
      case ShortVideoPlatform.douyin:
        playUrl = _firstUrl(videoMap, const [
          'play_addr_h264',
          'play_addr',
          'download_addr',
        ]);
        videoId = _uri(videoMap);
        durationMs = _int(videoMap['duration']) ?? 0;
        cover =
            _firstUrl(videoMap, const [
              'cover',
              'origin_cover',
              'dynamic_cover',
            ]) ??
            '';
      case ShortVideoPlatform.tiktok:
        playUrl = _tiktokPlayUrl(videoMap);
        videoId = _string(videoMap['id']) ?? _string(videoMap['videoID']) ?? '';
        // TikTok 的 duration 是秒。
        durationMs = (_int(videoMap['duration']) ?? 0) * 1000;
        cover =
            _string(videoMap['cover']) ??
            _urlFromMap(videoMap['cover']) ??
            _string(videoMap['originCover']) ??
            _urlFromMap(videoMap['originCover']) ??
            _firstUrl(videoMap, const ['cover', 'origin_cover']) ??
            '';
    }

    if (playUrl == null || playUrl.isEmpty) return null;

    final author = source['author'];
    return ShortVideo(
      id: id,
      platform: platform.id,
      desc: _string(source['desc']) ?? _string(item['desc']) ?? '',
      author: author is Map
          ? (_string(author['nickname']) ?? _string(author['uniqueId']) ?? '')
          : '',
      cover: cover,
      durationMs: durationMs,
      playUrl: playUrl,
      videoId: videoId,
      updatedAt: DateTime.now().millisecondsSinceEpoch.toDouble(),
    );
  }

  /// 抖音的 `video.play_addr.uri`，形如 `v0300fg10000cj2m3k3c77u7v6k0`。
  static String _uri(Map<String, dynamic> video) {
    for (final key in const [
      'play_addr',
      'play_addr_h264',
      'download_addr',
    ]) {
      final entry = video[key];
      if (entry is Map) {
        final value = _string(entry['uri']);
        if (value != null && value.isNotEmpty) return value;
      }
    }
    return '';
  }

  static String? _tiktokPlayUrl(Map<String, dynamic> video) {
    // 网页接口是字符串，App 接口是 { "UrlList": [...] }，两种都认。
    for (final key in const [
      'playAddr',
      'downloadAddr',
      'play_addr',
      'download_addr',
    ]) {
      final entry = video[key];
      final direct = _string(entry);
      if (direct != null && direct.isNotEmpty) return direct;
      final fromMap = _urlFromMap(entry);
      if (fromMap != null) return fromMap;
    }
    final bitrates = video['bitrateInfo'];
    if (bitrates is List) {
      for (final entry in bitrates) {
        if (entry is Map) {
          final play = entry['PlayAddr'];
          if (play is Map) {
            final urls = play['UrlList'];
            if (urls is List) {
              for (final url in urls) {
                if (url is String && url.isNotEmpty) return url;
              }
            }
          }
        }
      }
    }
    return _firstUrl(video, const ['play_addr', 'download_addr']);
  }

  /// `{ "UrlList": [...] }` / `{ "url_list": [...] }`
  static String? _urlFromMap(Object? entry) {
    if (entry is! Map) return null;
    for (final key in const ['UrlList', 'url_list', 'urlList']) {
      final urls = entry[key];
      if (urls is! List) continue;
      for (final url in urls) {
        if (url is String && url.isNotEmpty) return url;
      }
    }
    return null;
  }

  static String? _firstUrl(Map<String, dynamic> container, List<String> keys) {
    for (final key in keys) {
      final entry = container[key];
      if (entry is! Map) continue;
      final urls = entry['url_list'];
      if (urls is! List) continue;
      for (final url in urls) {
        if (url is String && url.isNotEmpty) return url;
      }
    }
    return null;
  }

  static String? _string(Object? value) {
    if (value is String) return value;
    if (value is num) return value.toString();
    return null;
  }

  static int? _int(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// 两个 App 共用的远端文件格式。
class ShortVideoSyncDocument {
  const ShortVideoSyncDocument({
    this.version = 1,
    this.updatedAt = 0,
    this.items = const [],
  });

  final int version;
  final double updatedAt;
  final List<ShortVideo> items;

  Map<String, dynamic> toJson() => {
    'version': version,
    'updatedAt': updatedAt,
    'items': items.map((e) => e.toJson()).toList(),
  };

  factory ShortVideoSyncDocument.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    return ShortVideoSyncDocument(
      version: (json['version'] as num?)?.toInt() ?? 1,
      updatedAt: (json['updatedAt'] as num?)?.toDouble() ?? 0,
      items: raw is List
          ? raw
                .whereType<Map>()
                .map((e) => ShortVideo.fromJson(e.cast<String, dynamic>()))
                .toList()
          : const [],
    );
  }
}

/// 按 `platform:id` 取并集；同一条以 `updatedAt` 更新的为准。
/// 胜出的那条如果播放直链是空的，用另一条的直链补上。
List<ShortVideo> mergeShortVideos(
  List<ShortVideo> local,
  List<ShortVideo> remote,
) {
  final order = <String>[];
  final byKey = <String, ShortVideo>{};

  for (final video in [...local, ...remote]) {
    final key = video.key;
    final existing = byKey[key];
    if (existing == null) {
      byKey[key] = video;
      order.add(key);
      continue;
    }
    final winner = video.updatedAt > existing.updatedAt ? video : existing;
    var playUrl = winner.playUrl;
    if (playUrl.isEmpty) playUrl = existing.playUrl;
    if (playUrl.isEmpty) playUrl = video.playUrl;
    var videoId = winner.videoId;
    if (videoId.isEmpty) videoId = existing.videoId;
    if (videoId.isEmpty) videoId = video.videoId;
    byKey[key] = winner.copyWith(playUrl: playUrl, videoId: videoId);
  }

  return order.map((key) => byKey[key]!).toList();
}