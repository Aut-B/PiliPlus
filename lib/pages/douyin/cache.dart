import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/perf.dart';
import 'package:PiliPlus/utils/path_utils.dart';

/// 一次缓存下载的结果。[path] 有值表示成功，否则 [error] 说明卡在哪一步。
class ShortVideoDownload {
  const ShortVideoDownload({this.path, this.error});

  final String? path;
  final String? error;

  bool get ok => path != null;
}

/// 短视频的本地媒体缓存。
///
/// 抖音 / TikTok 网页里抄到的直链是签名地址，一是会过期，二是 CDN 会按网页
/// 会话校验（TikTok 尤其严）。Kumone 那边用 URLSession 下载，天然和 WKWebView
/// 共用 cookie，所以下得动；Dart 的 HttpClient 是独立 cookie 罐，一个都不带，
/// 结果就是「缓存中 0% → 直链和缓存都失败了」。
///
/// 所以这里必须显式带上网页的 cookie（见 ShortVideoWeb.cookieHeader）。
abstract final class ShortVideoMediaCache {
  static Directory? _dir;

  /// 正在下载的条目，避免同一条被并发拉两遍。
  static final Set<String> _inFlight = {};

  static Future<Directory> _ensureDir() async {
    final cached = _dir;
    if (cached != null && await cached.exists()) return cached;
    final dir = Directory('$tmpDirPath${Platform.pathSeparator}short_video');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return _dir = dir;
  }

  static Future<File> _fileFor(ShortVideo video) async {
    final dir = await _ensureDir();
    final safeId = video.id.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '_');
    return File(
      '${dir.path}${Platform.pathSeparator}${video.platform}_$safeId.mp4',
    );
  }

  /// 已经有完整文件就返回路径，否则 null。
  static Future<String?> localPath(ShortVideo video) async {
    try {
      final file = await _fileFor(video);
      if (!await file.exists()) return null;
      if (await file.length() <= 0) {
        await file.delete();
        return null;
      }
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// 下载到本地。[urls] 按顺序试，前一个失败换下一个。
  static Future<ShortVideoDownload> download(
    ShortVideo video, {
    required List<String> urls,
    required String userAgent,
    required String referer,
    String cookie = '',
    String appUserAgent = '',
    void Function(double progress)? onProgress,
  }) async {
    // 串行下载：低内存机型上并发下载会把进程顶掉，CDN 也会限速。
    return _serialized(
      () => _download(
        video,
        urls: urls,
        userAgent: userAgent,
        referer: referer,
        cookie: cookie,
        appUserAgent: appUserAgent,
        onProgress: onProgress,
      ),
    );
  }

  static Future<ShortVideoDownload> _download(
    ShortVideo video, {
    required List<String> urls,
    required String userAgent,
    required String referer,
    String cookie = '',
    String appUserAgent = '',
    void Function(double progress)? onProgress,
  }) async {
    await ShortVideoPerf.ensureProbed();
    final key = '${video.platform}:${video.id}';
    if (_inFlight.contains(key)) {
      final existing = await localPath(video);
      return ShortVideoDownload(
        path: existing,
        error: existing == null ? '这条正在下载' : null,
      );
    }
    _inFlight.add(key);
    try {
      final existing = await localPath(video);
      if (existing != null) return ShortVideoDownload(path: existing);
      final target = await _fileFor(video);
      final errors = <String>[];
      for (final url in urls) {
        if (url.isEmpty) continue;
        final error = await _fetch(
          url,
          target,
          userAgent: _uaFor(url, userAgent, appUserAgent),
          referer: referer,
          cookie: cookie,
          onProgress: onProgress,
        );
        if (error == null) {
          unawaited(_prune());
          return ShortVideoDownload(path: target.path);
        }
        errors.add('${_hostOf(url)}: $error');
      }
      return ShortVideoDownload(
        error: errors.isEmpty ? '没有可用的地址' : errors.join(' / '),
      );
    } finally {
      _inFlight.remove(key);
    }
  }

  /// 长期地址（tiktokv.com）只认 App 的 UA，签名直链则要用网页 UA。
  static String _uaFor(String url, String webUa, String appUa) {
    if (appUa.isEmpty) return webUa;
    final host = _hostOf(url).toLowerCase();
    if (host.contains('tiktokv.com') || host.contains('snssdk.com')) {
      return appUa;
    }
    return webUa;
  }

  static String _hostOf(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }

  /// 成功返回 null，失败返回原因。
  static Future<String?> _fetch(
    String url,
    File target, {
    required String userAgent,
    required String referer,
    required String cookie,
    void Function(double progress)? onProgress,
  }) async {
    final part = File('${target.path}.part');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..maxConnectionsPerHost = 4;
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(HttpHeaders.refererHeader, referer);
      if (cookie.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, cookie);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.drain<void>();
        return 'HTTP ${response.statusCode}';
      }
      final mime = response.headers.contentType?.mimeType ?? '';
      if (mime.contains('html')) {
        await response.drain<void>();
        return '返回的是网页不是视频';
      }
      final total = response.contentLength;
      var received = 0;
      if (await part.exists()) await part.delete();
      sink = part.openWrite();
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call((received / total).clamp(0.0, 1.0));
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (received <= 0) {
        if (await part.exists()) await part.delete();
        return '下载到 0 字节';
      }
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      onProgress?.call(1);
      return null;
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      if (await part.exists()) {
        try {
          await part.delete();
        } catch (_) {}
      }
      return '$e';
    } finally {
      client.close(force: true);
    }
  }

  /// 全局串行闸门：一次只跑一条下载。
  static Future<void> _gate = Future<void>.value();

  static Future<T> _serialized<T>(Future<T> Function() action) async {
    final previous = _gate;
    final done = Completer<void>();
    _gate = done.future;
    try {
      await previous;
      return await action();
    } finally {
      done.complete();
    }
  }

  /// 超过上限就把最旧的删掉（低内存机型上限更小）。
  static Future<void> _prune() async {
    try {
      final limit = ShortVideoPerf.cacheLimitBytes;
      final dir = await _ensureDir();
      if (!await dir.exists()) return;
      final entries = <({File file, DateTime at, int size})>[];
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (entity.path.endsWith('.part')) continue;
        try {
          final size = await entity.length();
          final at = await entity.lastModified();
          total += size;
          entries.add((file: entity, at: at, size: size));
        } catch (_) {}
      }
      if (total <= limit) return;
      entries.sort((a, b) => a.at.compareTo(b.at));
      for (final entry in entries) {
        if (total <= limit) break;
        try {
          await entry.file.delete();
          total -= entry.size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 删掉这一条的缓存（收藏里删条目时一并调）。
  static Future<void> remove(ShortVideo video) async {
    try {
      final file = await _fileFor(video);
      if (await file.exists()) await file.delete();
      final part = File('${file.path}.part');
      if (await part.exists()) await part.delete();
    } catch (_) {}
  }

  /// 清空整个短视频缓存目录。
  static Future<void> clear() async {
    try {
      final dir = await _ensureDir();
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 缓存目录占用（字节），界面上给个数字。
  static Future<int> size() async {
    try {
      final dir = await _ensureDir();
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}