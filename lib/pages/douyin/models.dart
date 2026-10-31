import 'dart:convert';

/// One video from the Douyin favourites list.
///
/// The payload is captured from the signed-in web app inside a WebView, so it
/// already contains a playable URL; nothing has to be signed on our side.
class DouyinVideo {
  const DouyinVideo({
    required this.id,
    required this.desc,
    required this.author,
    required this.cover,
    required this.durationMs,
    required this.playUrl,
  });

  final String id;
  final String desc;
  final String author;
  final String cover;
  final int durationMs;
  final String playUrl;

  String get title => desc.trim().isEmpty ? '抖音视频' : desc.trim();

  String get shareUrl => 'https://www.douyin.com/video/$id';

  String get durationText {
    if (durationMs <= 0) return '--:--';
    final total = durationMs ~/ 1000;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'desc': desc,
    'author': author,
    'cover': cover,
    'durationMs': durationMs,
    'playUrl': playUrl,
  };

  factory DouyinVideo.fromJson(Map<String, dynamic> json) => DouyinVideo(
    id: json['id'] as String? ?? '',
    desc: json['desc'] as String? ?? '',
    author: json['author'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
    playUrl: json['playUrl'] as String? ?? '',
  );
}

class DouyinParser {
  static List<DouyinVideo> fromResponseBody(String body) {
    if (body.length < 40) return const [];
    if (!body.contains('aweme_list') && !body.contains('aweme_detail')) {
      return const [];
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const [];
      return fromJsonObject(decoded.cast<String, dynamic>());
    } catch (_) {
      return const [];
    }
  }

  static List<DouyinVideo> fromJsonObject(Map<String, dynamic> root) {
    final list = root['aweme_list'];
    if (list is List) {
      return list
          .whereType<Map>()
          .map((e) => fromItem(e.cast<String, dynamic>()))
          .whereType<DouyinVideo>()
          .toList();
    }
    final detail = root['aweme_detail'];
    if (detail is Map) {
      final video = fromItem(detail.cast<String, dynamic>());
      return video == null ? const [] : [video];
    }
    return const [];
  }

  static DouyinVideo? fromItem(Map<String, dynamic> item) {
    final id = _string(item['aweme_id']) ?? _string(item['awemeId']);
    if (id == null || id.isEmpty) return null;

    final video = item['video'];
    if (video is! Map) return null;
    final videoMap = video.cast<String, dynamic>();

    final playUrl = _firstUrl(videoMap, const [
      'play_addr_h264',
      'play_addr',
      'download_addr',
    ]);
    if (playUrl == null || playUrl.isEmpty) return null;

    final author = item['author'];
    return DouyinVideo(
      id: id,
      desc: _string(item['desc']) ?? '',
      author: author is Map ? (_string(author['nickname']) ?? '') : '',
      cover:
          _firstUrl(videoMap, const [
            'cover',
            'origin_cover',
            'dynamic_cover',
          ]) ??
          '',
      durationMs: _int(videoMap['duration']) ?? 0,
      playUrl: playUrl,
    );
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