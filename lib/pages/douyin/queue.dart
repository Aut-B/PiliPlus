import 'dart:io';

import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/pages/douyin/models.dart';

/// 播放队列里的一条。
///
/// 抖音 / TikTok 是网页里抄到的一条 mp4 直链，B 站是 DASH（画面和声音分开），
/// 两种在这里统一成同一个条目，播放器只管「上一条 / 下一条」。
class QueueEntry {
  const QueueEntry({
    required this.key,
    required this.title,
    required this.author,
    required this.cover,
    required this.durationMs,
    this.short,
    this.bvid,
  });

  factory QueueEntry.fromShortVideo(ShortVideo video) => QueueEntry(
    key: 'short:${video.key}',
    title: video.title,
    author: video.author,
    cover: video.cover,
    durationMs: video.durationMs,
    short: video,
  );

  factory QueueEntry.fromBili({
    required String bvid,
    required String title,
    required String author,
    required String cover,
    required int durationMs,
  }) => QueueEntry(
    key: 'bili:$bvid',
    title: title,
    author: author,
    cover: cover,
    durationMs: durationMs,
    bvid: bvid,
  );

  final String key;
  final String title;
  final String author;
  final String cover;
  final int durationMs;

  /// 抖音 / TikTok 的原始条目。
  final ShortVideo? short;

  /// B 站视频的 bvid。
  final String? bvid;

  bool get isBili => bvid != null;

  String get durationText {
    if (durationMs <= 0) return '--:--';
    final total = durationMs ~/ 1000;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }
}

/// 解析出来、可以直接交给播放器的东西。
class QueueMedia {
  const QueueMedia({
    required this.url,
    required this.userAgent,
    required this.referer,
    this.isLocal = false,
    this.cookie = '',
  });

  /// 可能是普通 http 地址、本地文件路径，也可能是 media_kit 的 `edl://`
  /// （B 站双流）。
  final String url;
  final String userAgent;
  final String referer;

  /// 本地缓存文件：播放器直接开文件，不再走网络。
  final bool isLocal;

  /// 网页那套 cookie（CDN 会按会话校验，TikTok 不带就是 403）。
  final String cookie;
}

/// 「下一首播放」的临时插队队列。
///
/// 播放页里排的是它自己那份队列（B 站收藏、抖音收藏各一份），两边互不相识。
/// 用户要的是「播着 B 站收藏，把抖音里那几条插到下一首」——所以插队条目放在
/// 这里，任何播放页在「上一条播完」时都先来这里取一条。
abstract final class QueueBus {
  static final List<QueueEntry> _next = [];

  /// 已排队的条数（界面上给个反馈）。
  static int get pending => _next.length;

  static List<QueueEntry> get pendingEntries => List.unmodifiable(_next);

  /// 插到队尾；重复的（同一条视频已经在队里）不重复加。
  static int addNext(Iterable<QueueEntry> entries) {
    var added = 0;
    for (final entry in entries) {
      if (_next.any((e) => e.key == entry.key)) continue;
      _next.add(entry);
      added++;
    }
    return added;
  }

  static QueueEntry? takeNext() => _next.isEmpty ? null : _next.removeAt(0);

  /// 把排队的条目整批取走（B 站播放器播完一条时用：接下来交给小视频播放页）。
  static List<QueueEntry> drainAll() {
    final drained = List<QueueEntry>.of(_next);
    _next.clear();
    return drained;
  }

  static void clear() => _next.clear();
}

const _biliUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15';

/// TikTok 的 `aweme/v1/play/` 只认 App 的 UA，桌面 Safari 的 UA 会被直接拒掉，
/// 探出来全是 403——同步过来的 TikTok 一条都播不了就是这个原因。
const tiktokAppUserAgent =
    'com.zhiliaoapp.musically/2022803040 (Linux; U; Android 12; en; '
    'Pixel 6; Build/SQ3A.220705.004;tt-ok/3.12.13.4-tiktok) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
    'Chrome/99.0.4844.88 Mobile Safari/537.36';

/// 把一个条目解析成可播放地址。失败返回 null（播放器会跳到下一条）。
Future<QueueMedia?> resolveQueueEntry(
  QueueEntry entry, {
  String cookie = '',
}) async {
  if (entry.short case final video?) {
    return _resolveShortVideo(video, cookie);
  }
  if (entry.bvid case final bvid?) {
    return _resolveBili(bvid);
  }
  return null;
}

/// 抖音 / TikTok：30 分钟内的签名直链直接用，过期的先探长期地址。
///
/// TikTok 的长期地址只认 App UA（见 [tiktokAppUserAgent]），所以探成功之后
/// 播放也必须带同一个 UA，否则「探通了、播不了」。
Future<QueueMedia?> _resolveShortVideo(ShortVideo video, String cookie) async {
  final platform =
      ShortVideoPlatform.fromId(video.platform) ?? ShortVideoPlatform.douyin;
  final age = DateTime.now().millisecondsSinceEpoch / 1000 - video.updatedAt;
  final fresh = video.updatedAt > 0 && age >= 0 && age < 30 * 60;
  if (!fresh) {
    final stable = await _probeStable(video, platform, cookie);
    if (stable != null) {
      return QueueMedia(
        url: stable,
        userAgent: platform == ShortVideoPlatform.tiktok
            ? tiktokAppUserAgent
            : platform.userAgent,
        referer: platform.referer,
        cookie: cookie,
      );
    }
  }
  if (video.playUrl.isNotEmpty) {
    return QueueMedia(
      url: video.playUrl,
      userAgent: platform.userAgent,
      referer: platform.referer,
      cookie: cookie,
    );
  }
  final stable = await _probeStable(video, platform, cookie);
  if (stable == null) return null;
  return QueueMedia(
    url: stable,
    userAgent: platform == ShortVideoPlatform.tiktok
        ? tiktokAppUserAgent
        : platform.userAgent,
    referer: platform.referer,
    cookie: cookie,
  );
}

/// 老播放接口，多个域名各试一次（TikTok 单域名经常整片 403）。
List<String> stableUrls(ShortVideo video) {
  if (video.videoId.isEmpty) return const [];
  final encoded = Uri.encodeComponent(video.videoId);
  final hosts = video.platform == 'tiktok'
      ? const [
          'https://api16-normal-c-useast1a.tiktokv.com/aweme/v1/play/',
          'https://api19-normal-c-useast1a.tiktokv.com/aweme/v1/play/',
          'https://api22-normal-c-useast1a.tiktokv.com/aweme/v1/play/',
          'https://api-h2.tiktokv.com/aweme/v1/play/',
          'https://api.tiktokv.com/aweme/v1/play/',
        ]
      : const [
          'https://www.iesdouyin.com/aweme/v1/play/',
          'https://aweme.snssdk.com/aweme/v1/play/',
        ];
  return [
    for (final host in hosts) '$host?video_id=$encoded&ratio=720p&line=0',
  ];
}

Future<String?> _probeStable(
  ShortVideo video,
  ShortVideoPlatform platform,
  String cookie,
) async {
  final userAgent = platform == ShortVideoPlatform.tiktok
      ? tiktokAppUserAgent
      : platform.userAgent;
  for (final url in stableUrls(video)) {
    if (await _probe(url, userAgent, platform.referer, cookie)) return url;
  }
  return null;
}

/// 只取两个字节确认能播，别把整段视频拉下来。
Future<bool> _probe(
  String url,
  String userAgent,
  String referer,
  String cookie,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    request.headers.set(HttpHeaders.refererHeader, referer);
    if (cookie.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookie);
    }
    final response = await request.close().timeout(const Duration(seconds: 6));
    final mime = response.headers.contentType?.mimeType ?? '';
    final ok =
        (response.statusCode == 200 || response.statusCode == 206) &&
        !mime.contains('html');
    await response.drain<void>();
    return ok;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// B 站：先要 cid，再要 playurl，最后把画面和声音拼成 `edl://`。
///
/// media_kit 的 B 站播放就是这么做的（DASH 是两条流），这里照着来，
/// 这样「全选 → 下一首播放」的队列里可以混着 B 站和抖音/TikTok。
Future<QueueMedia?> _resolveBili(String bvid) async {
  try {
    final intro = await VideoHttp.videoIntro(bvid: bvid);
    final cid = intro.dataOrNull?.cid;
    if (cid == null) return null;

    final play = await VideoHttp.videoUrl(
      bvid: bvid,
      cid: cid,
      qn: 64,
      tryLook: true,
      videoType: VideoType.ugc,
    );
    final dash = play.dataOrNull?.dash;
    final videos = dash?.video;
    if (videos == null || videos.isEmpty) return null;
    final videoUrl = videos.first.baseUrl;
    if (videoUrl == null || videoUrl.isEmpty) return null;
    final audios = dash?.audio;
    final audioUrl = audios != null && audios.isNotEmpty
        ? audios.first.baseUrl
        : null;

    final url = audioUrl == null || audioUrl.isEmpty
        ? videoUrl
        : 'edl://!no_chapters;%${videoUrl.length}%$videoUrl;'
              '!new_stream;!no_chapters;%${audioUrl.length}%$audioUrl';
    return QueueMedia(
      url: url,
      userAgent: _biliUserAgent,
      referer: 'https://www.bilibili.com',
    );
  } catch (_) {
    return null;
  }
}