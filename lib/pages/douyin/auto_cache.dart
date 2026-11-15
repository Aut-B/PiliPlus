import 'dart:async' show unawaited;

import 'package:PiliPlus/pages/douyin/cache.dart';
import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/playlist.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/pages/douyin/repo.dart';
import 'package:PiliPlus/pages/douyin/web.dart';

/// 收藏 / 播放列表的后台落盘器。
///
/// 签名直链会过期，TikTok 尤其容易隔天就 403；只有本地文件才算「随时能播的收藏」。
/// 这里串行把抓到或同步到的条目补下到持久目录，不阻塞收藏页刷新。
abstract final class ShortVideoAutoCache {
  static bool _running = false;
  static bool _pending = false;

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

  /// 先更新保护名单再单独下载：下载成功后会顺手清理不受保护的旧文件。
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
    try {
      final all = collectVideos();
      ShortVideoMediaCache.protect(all.map((video) => video.key));
      for (final video in all) {
        if (await ShortVideoMediaCache.localPath(video) != null) continue;
        final platform =
            ShortVideoPlatform.fromId(video.platform) ??
            ShortVideoPlatform.douyin;
        final cookie = await ShortVideoWeb.cookieHeader(
          platform.cookieDomainNeedle,
        );
        await ShortVideoMediaCache.download(
          video,
          urls: <String>[
            if (video.playUrl.isNotEmpty) video.playUrl,
            ...stableUrls(video),
          ],
          userAgent: platform.userAgent,
          referer: platform.referer,
          cookie: cookie,
          appUserAgent: platform == ShortVideoPlatform.tiktok
              ? tiktokAppUserAgent
              : '',
        );
      }
    } catch (_) {
      return;
    }
  }
}
