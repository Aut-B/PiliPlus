import 'dart:async' show Timer, unawaited;

import 'package:PiliPlus/pages/douyin/cache.dart';
import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/playlist.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/pages/douyin/repo.dart';
import 'package:PiliPlus/pages/douyin/web.dart';

/// 收藏 / 播放列表的后台落盘器。
///
/// 签名直链会过期，TikTok 尤其容易隔天就 403；只有本地文件才算「随时能播的
/// 收藏」。这里串行把抓到的条目补下到持久目录，不阻塞收藏页刷新。
abstract final class ShortVideoAutoCache {
  static bool _running = false;
  static bool _pending = false;
  static Timer? _retryTimer;

  /// 每条失败次数：坏条目不能无限重试把电和流量耗光。
  static final Map<String, int> _attempts = {};
  static const int maxAttempts = 8;

  /// 每条最后一次失败原因。以前只有「0/37」这种数字，看不出是 403、
  /// 网页当视频、还是地址全空；把原因带进体检结果才能定位。
  static final Map<String, String> _errors = {};

  static int lastFailed = 0;
  static int lastDoneAt = 0;

  static List<ShortVideo> collectVideos() {
    final byKey = <String, ShortVideo>{
      for (final video in ShortVideoRepo.loadAll()) video.key: video,
    };
    for (final item in ShortVideoPlaylistRepo.load()) {
      final video = item.short;
      if (video != null) byKey.putIfAbsent(video.key, () => video);
    }
    return byKey.values.toList(growable: false);
  }

  /// 先更新保护名单再单独下载：下载成功后顺手清理不受保护的旧文件。
  static void refreshProtection() {
    ShortVideoMediaCache.protect(
      collectVideos().map((video) => video.key),
    );
  }

  static void schedule() {
    if (_running) {
      _pending = true;
      return;
    }
    _running = true;
    unawaited(_run().whenComplete(() {
      _running = false;
      if (_pending) {
        _pending = false;
        schedule();
      }
    }));
  }

  static Future<void> _run() async {
    final all = collectVideos();
    ShortVideoMediaCache.protect(all.map((video) => video.key));
    var failed = 0;
    for (final video in all) {
      // 单条失败绝不能中断整批：以前一个 403 会让后面的收藏全部不下。
      try {
        if (await ShortVideoMediaCache.localPath(video) != null) {
          _attempts.remove(video.key);
          continue;
        }
        if ((_attempts[video.key] ?? 0) >= maxAttempts) continue;
        if (!await _fetchOne(video)) failed++;
      } catch (_) {
        _bump(video.key);
        failed++;
      }
    }
    lastFailed = failed;
    lastDoneAt = DateTime.now().millisecondsSinceEpoch;
    if (failed > 0) _scheduleRetry();
  }

  static Future<bool> _fetchOne(ShortVideo video) async {
    final platform =
        ShortVideoPlatform.fromId(video.platform) ?? ShortVideoPlatform.douyin;
    final cookie = await ShortVideoWeb.cookieHeader(
      platform.cookieDomainNeedle,
    );
    final stable = stableUrls(video);
    final urls = <String>[
      // TikTok 的长期地址优先；签名直链兜底。
      if (platform == ShortVideoPlatform.tiktok) ...stable,
      if (video.playUrl.isNotEmpty) video.playUrl,
      if (platform != ShortVideoPlatform.tiktok) ...stable,
    ];
    final result = await ShortVideoMediaCache.download(
      video,
      urls: urls,
      userAgent: platform.userAgent,
      referer: platform.referer,
      cookie: cookie,
      appUserAgent: platform == ShortVideoPlatform.tiktok
          ? tiktokAppUserAgent
          : '',
    );
    if (result.ok) {
      _attempts.remove(video.key);
      _errors.remove(video.key);
      return true;
    }
    _bump(video.key);
    final reason = (result.error ?? 'unknown').trim();
    _errors[video.key] = reason.length > 160
        ? reason.substring(0, 160)
        : reason;
    return false;
  }

  static void _bump(String key) {
    _attempts.update(key, (value) => value + 1, ifAbsent: () => 1);
  }

  static void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 90), schedule);
  }

  static Map<String, Object?> snapshot() => <String, Object?>{
    'running': _running,
    'pending': _pending,
    'failed': lastFailed,
    'doneAt': lastDoneAt,
    'retryEntries': _attempts.length,
    'attempts': Map<String, int>.of(_attempts),
    'errors': Map<String, String>.of(_errors),
  };
}
