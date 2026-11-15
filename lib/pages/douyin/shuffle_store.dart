import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/utils/path_utils.dart';

/// 随机播放历史的落盘。
///
/// 只放内存的话，退出播放页 / 杀进程就清空，用户会看到「已经播过的又来了」。
/// 这里按队列签名保存，队列一换（收藏增减）就整份作废，不会把别的队列的
/// 历史套过来。
abstract final class ShortVideoShuffleStore {
  static const String fileName = 'short_video_shuffle.json';

  static Future<File> _file() async {
    final dir = Directory(appSupportDirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  /// FNV-1a 64 位：跨进程稳定，别用 String.hashCode（不保证跨运行一致）。
  static String signatureOf(Iterable<String> keys) {
    final sorted = keys.toList()..sort();
    var hash = 0xcbf29ce484222325;
    for (final key in sorted) {
      for (final unit in key.codeUnits) {
        hash ^= unit;
        hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
      }
      hash ^= 0x1f;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static Future<ShuffleHistory?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final signature = decoded['signature'];
      if (signature is! String || signature.isEmpty) return null;
      final rawPlayed = decoded['played'];
      final played = <String>{
        if (rawPlayed is List)
          for (final item in rawPlayed)
            if (item is String && item.isNotEmpty) item,
      };
      return ShuffleHistory(signature: signature, played: played);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save({
    required String signature,
    required Iterable<String> played,
  }) async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode(<String, Object?>{
          'signature': signature,
          'played': played.toList(growable: false),
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        }),
        flush: true,
      );
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

class ShuffleHistory {
  const ShuffleHistory({required this.signature, required this.played});

  final String signature;
  final Set<String> played;
}
