import 'dart:convert';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// 本地缓存 + WebDAV 同步。
///
/// 远端只有一个文件（`<目录>/ShortVideo/shortvideo.json`），抖音和 TikTok 都在
/// 里面，Kumone 与 PiliPlus 也共用同一份格式——一台手机抓到的收藏，另一台
/// 打开就能看到。
abstract final class ShortVideoRepo {
  static String _cacheKey(ShortVideoPlatform platform) =>
      'shortVideoFavorites_${platform.id}';

  static List<ShortVideo> load(ShortVideoPlatform platform) {
    final Object? raw;
    try {
      raw = GStorage.localCache.get(_cacheKey(platform), defaultValue: '');
    } catch (_) {
      return const [];
    }
    if (raw is! String || raw.isEmpty) return const [];

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];

    // 逐条解析：以前一条坏数据会让整份缓存变成空列表，
    // 表现就是「明明同步了 16 条，点进去一条都没有」。
    final result = <ShortVideo>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      try {
        final video = ShortVideo.fromJson(entry.cast<String, dynamic>());
        if (video.platform == platform.id && video.id.isNotEmpty) {
          result.add(video);
        }
      } catch (_) {}
    }
    return result;
  }

  /// 写入本地缓存，返回「写完能读回来几条」。返回 -1 表示写入本身失败。
  static int save(ShortVideoPlatform platform, List<ShortVideo> videos) {
    try {
      GStorage.localCache.put(
        _cacheKey(platform),
        jsonEncode(videos.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      return -1;
    }
    return load(platform).length;
  }

  static List<ShortVideo> loadAll() => [
    for (final platform in ShortVideoPlatform.values) ...load(platform),
  ];

  // MARK: - 删除墓碑
  //
  // 同步是「本地 + 远端取并集」，删掉的条目下一次同步就会从远端回来。
  // 所以删一条要留个墓碑，合并时按墓碑过滤，再把过滤后的结果推上去。

  static String _deletedKey(ShortVideoPlatform platform) =>
      'shortVideoDeleted_${platform.id}';

  static Set<String> loadDeleted(ShortVideoPlatform platform) {
    try {
      final Object? raw = GStorage.localCache.get(
        _deletedKey(platform),
        defaultValue: '',
      );
      if (raw is! String || raw.isEmpty) return <String>{};
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toSet();
      }
    } catch (_) {}
    return <String>{};
  }

  static Set<String> loadAllDeleted() => {
    for (final platform in ShortVideoPlatform.values)
      ...loadDeleted(platform),
  };

  static void markDeleted(ShortVideoPlatform platform, Iterable<String> keys) {
    final deleted = loadDeleted(platform)..addAll(keys);
    try {
      GStorage.localCache.put(
        _deletedKey(platform),
        jsonEncode(deleted.toList()),
      );
    } catch (_) {}
  }

  /// 重新抓到了这条：墓碑撤掉，让它重新进列表。
  static void unmarkDeleted(ShortVideoPlatform platform, Iterable<String> keys) {
    final deleted = loadDeleted(platform)..removeAll(keys);
    try {
      GStorage.localCache.put(
        _deletedKey(platform),
        jsonEncode(deleted.toList()),
      );
    } catch (_) {}
  }

  /// 按平台分桶写回，返回每个平台实际落库的条数。
  static Map<String, int> saveAll(List<ShortVideo> all) {
    final written = <String, int>{};
    for (final platform in ShortVideoPlatform.values) {
      written[platform.id] = save(
        platform,
        all.where((e) => e.platform == platform.id).toList(),
      );
    }
    return written;
  }
}

/// 一次同步的结果。分开报抖音 / TikTok，远端文件里到底有几条、本地又落库了
/// 几条也一并说出来——之前只报「共 N 条」，远端读失败、落库失败都照样显示
/// 成功，人还以为同步好了。
class ShortVideoSyncResult {
  const ShortVideoSyncResult({
    required this.douyin,
    required this.tiktok,
    required this.remote,
    this.storedDouyin = -1,
    this.storedTiktok = -1,
  });

  final int douyin;
  final int tiktok;

  /// 远端文件里的条数；-1 表示远端还没有这个文件。
  final int remote;

  /// 本地缓存写完读回来的条数；-1 表示写入失败。
  final int storedDouyin;
  final int storedTiktok;

  int get total => douyin + tiktok;

  bool get storedOk =>
      storedDouyin == douyin && storedTiktok == tiktok;

  String get summary {
    final remoteText = remote < 0 ? '远端无文件' : '远端 $remote 条';
    if (storedOk) {
      return '抖音 $douyin / TikTok $tiktok（$remoteText）';
    }
    final storedText = storedDouyin < 0 || storedTiktok < 0
        ? '本地写入失败'
        : '本地只存下 抖音 $storedDouyin / TikTok $storedTiktok';
    return '抖音 $douyin / TikTok $tiktok（$remoteText，$storedText）';
  }
}

abstract final class ShortVideoSync {
  static bool get configured =>
      Pref.webdavUri.trim().isNotEmpty &&
      Pref.webdavUsername.isNotEmpty &&
      Pref.webdavPassword.isNotEmpty;

  static String get remotePath {
    var dir = Pref.webdavDirectory.trim();
    if (dir.isEmpty) dir = '/';
    if (!dir.startsWith('/')) dir = '/$dir';
    if (!dir.endsWith('/')) dir = '$dir/';
    return '${dir}ShortVideo/shortvideo.json';
  }

  static Future<webdav.Client> _client() async {
    final client =
        webdav.newClient(
            Pref.webdavUri,
            user: Pref.webdavUsername,
            password: Pref.webdavPassword,
          )
          ..setHeaders({'accept-charset': 'utf-8'})
          ..setConnectTimeout(12000)
          ..setReceiveTimeout(12000)
          ..setSendTimeout(12000);
    final path = remotePath;
    final dir = path.substring(0, path.lastIndexOf('/'));
    await client.mkdirAll(dir);
    return client;
  }

  /// 远端还没有文件时返回 null（不是错误）。
  ///
  /// 其它错误要抛出来：以前这里把所有异常都吞掉当成「远端没文件」，
  /// 结果远端读失败也照样显示「已同步共 N 条」，人还以为同步成功了。
  static Future<ShortVideoSyncDocument?> pull() async {
    if (!configured) return null;
    final client = await _client();
    try {
      final data = await client.read(remotePath);
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is Map) {
        return ShortVideoSyncDocument.fromJson(decoded.cast<String, dynamic>());
      }
      throw Exception('$remotePath 不是预期的 JSON 对象');
    } catch (e) {
      if (e is Exception && e.toString().contains('不是预期的')) rethrow;
      final text = e.toString();
      if (text.contains('404') || text.contains('Not Found')) return null;
      throw Exception('读取 $remotePath 失败：$text');
    }
  }

  static Future<void> push(ShortVideoSyncDocument document) async {
    if (!configured) return;
    final client = await _client();
    await client.write(remotePath, utf8.encode(jsonEncode(document.toJson())));
  }

  /// 本地 + 远端取并集，写回本地，再把合并结果推上去。
  static Future<ShortVideoSyncResult> synchronize() async {
    if (!configured) {
      return const ShortVideoSyncResult(douyin: 0, tiktok: 0, remote: -1);
    }
    final remote = await pull();
    final deleted = ShortVideoRepo.loadAllDeleted();
    final merged = mergeShortVideos(
      ShortVideoRepo.loadAll(),
      remote?.items ?? const [],
    ).where((e) => !deleted.contains(e.key)).toList();
    final written = ShortVideoRepo.saveAll(merged);
    await push(
      ShortVideoSyncDocument(
        updatedAt: DateTime.now().millisecondsSinceEpoch.toDouble(),
        items: merged,
      ),
    );
    return ShortVideoSyncResult(
      douyin: merged.where((e) => e.platform == 'douyin').length,
      tiktok: merged.where((e) => e.platform == 'tiktok').length,
      remote: remote?.items.length ?? -1,
      storedDouyin: written['douyin'] ?? -1,
      storedTiktok: written['tiktok'] ?? -1,
    );
  }
}