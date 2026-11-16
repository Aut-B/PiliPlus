import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/pages/douyin/auto_cache.dart';
import 'package:PiliPlus/pages/douyin/cache.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/pages/douyin/qa_config.dart';
import 'package:PiliPlus/pages/douyin/shuffle_store.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 三条主需求的自动体检。
///
/// 结果写到 App 的 Documents，装有本包的手机可以在「文件」里直接看，也能用
/// house_arrest 拉出来。每次跑都往 `shortvideo_qa_history.jsonl` 追加一行，
/// 便于判断缓存是否在逐步补齐。
abstract final class ShortVideoQa {
  static const String resultFileName = 'shortvideo_qa_result.json';
  static const String historyFileName = 'shortvideo_qa_history.jsonl';

  /// 写文件之外再走一条能读回来的通道：原生侧会把内容落到
  /// `/private/var/mobile/Media/piliplus_qa/` 并用 NSLog 分段打印，
  /// 这样即使 USB 拉不到 Documents，也能从系统日志里还原结果。
  static const MethodChannel _dump = MethodChannel('PiliPlus/QaDump');

  static bool _scheduled = false;
  static final List<Timer> _timers = [];

  static void schedule() {
    if (!Platform.isIOS || _scheduled) return;
    _scheduled = true;
    // 先等启动那一轮缓存跑起来，再在几个时间点各拍一张快照。
    for (final seconds in const [25, 180, 360, 600]) {
      _timers.add(
        Timer(Duration(seconds: seconds), () {
          unawaited(run());
        }),
      );
    }
  }

  static Future<Map<String, Object?>> run() async {
    final videos = ShortVideoAutoCache.collectVideos();
    var local = 0;
    var douyinTotal = 0;
    var douyinLocal = 0;
    var tiktokTotal = 0;
    var tiktokLocal = 0;
    final missing = <String>[];
    for (final video in videos) {
      final path = await ShortVideoMediaCache.localPath(video);
      final isLocal = path != null;
      if (isLocal) {
        local++;
      } else if (missing.length < 40) {
        missing.add(video.key);
      }
      if (video.platform == 'tiktok') {
        tiktokTotal++;
        if (isLocal) tiktokLocal++;
      } else {
        douyinTotal++;
        if (isLocal) douyinLocal++;
      }
    }

    final keys = videos.map((video) => video.key).toList(growable: false);
    final signature = ShortVideoShuffleStore.signatureOf(keys);
    final saved = await ShortVideoShuffleStore.load();
    final played = saved?.played.where(keys.toSet().contains).toList() ?? const [];
    final pip = await _readPipSummary();
    final realSequence = <String>[
      for (final key in (pip.remove('sequence') as List?) ?? const [])
        '$key',
    ];
    final roundSize = (pip.remove('queueTotal') as int?) ?? keys.length;
    final shuffle = <String, Object?>{
      'queueSize': keys.length,
      'roundSize': roundSize,
      'persistedPlayed': played.length,
      'signatureMatch': saved == null ? null : saved.signature == signature,
      'algorithmNoRepeatInRound': _simulateRounds(keys),
      // 真机实际播放顺序（来自 pip_qa_log 的 displayedKey 采样），
      // 不是纸上模拟：同一轮里重复出现就直接判失败。
      'realSequenceLength': realSequence.length,
      'realDistinctKeys': realSequence.toSet().length,
      'realNoRepeat': _noRepeatWithinRound(realSequence, roundSize),
      'realEvidence': realSequence.length >= 2,
      'realSequence': realSequence.length > 80
          ? realSequence.sublist(realSequence.length - 80)
          : realSequence,
    };

    final playStats = ShortVideoPlayStats.snapshot();
    final tiktokPlayed = (playStats['tiktokLocalHits'] as int? ?? 0) +
        (playStats['tiktokNetworkFallbacks'] as int? ?? 0);
    final tiktokLocalFirst =
        tiktokTotal == 0 ||
        (tiktokPlayed > 0 &&
            (playStats['tiktokLocalHits'] as int? ?? 0) > 0 &&
            (playStats['tiktokNetworkFallbacks'] as int? ?? 0) == 0);

    final result = <String, Object?>{
      'generatedAt': DateTime.now().toIso8601String(),
      'build': <String, Object?>{
        'versionCode': BuildConfig.versionCode,
        'versionName': BuildConfig.versionName,
        'commit': BuildConfig.commitHash,
      },
      'cache': <String, Object?>{
        'total': videos.length,
        'local': local,
        'missing': missing,
        'douyin': <String, Object?>{'total': douyinTotal, 'local': douyinLocal},
        'tiktok': <String, Object?>{'total': tiktokTotal, 'local': tiktokLocal},
        'autoCache': ShortVideoAutoCache.snapshot(),
      },
      'tiktok': <String, Object?>{
        'localFirst': tiktokLocalFirst,
        'playStats': playStats,
      },
      'shuffle': shuffle,
      'pip': pip,
      'verdict': <String, Object?>{
        'cacheComplete': videos.isNotEmpty && local == videos.length,
        // TikTok 收藏必须整批都能离线播，只中一条不算过。
        'tiktokLocalPlayable':
            tiktokTotal == 0 || tiktokLocal == tiktokTotal,
        'shuffleNoRepeat': keys.length <= 1 ||
            (shuffle['algorithmNoRepeatInRound'] == true &&
                shuffle['realEvidence'] == true &&
                shuffle['realNoRepeat'] == true),
        // pip_qa_log.json 的最终判定由原生 PiP 证据算出（pass/verdict），
        // 不是这里再猜一遍。
        'pipBackground': (pip['pass'] ?? pip['passed']) == true,
      },
    };
    await _write(result);
    return result;
  }

  /// 用同一套「抽牌袋」规则跑两轮，任何一轮内出现重复就判失败。
  static bool _simulateRounds(List<String> keys) {
    if (keys.length <= 1) return true;
    final random = Random(20261116);
    final played = <String>{};
    var deck = <String>[];
    for (var round = 0; round < 2; round++) {
      final inRound = <String>{};
      for (var step = 0; step < keys.length; step++) {
        if (deck.isEmpty) {
          final remaining = keys.where((key) => !played.contains(key)).toList();
          if (remaining.isEmpty) {
            played.clear();
            deck = keys.toList()..shuffle(random);
          } else {
            deck = remaining..shuffle(random);
          }
        }
        if (deck.isEmpty) return false;
        final key = deck.removeAt(0);
        if (!inRound.add(key)) return false;
        played.add(key);
      }
    }
    return true;
  }

  /// 真机播放顺序里，同一条只要在一轮（= 队列长度）之内又出现，就算重复。
  /// 距离等于轮长是下一轮的第一条，允许。
  static bool _noRepeatWithinRound(List<String> sequence, int round) {
    if (round <= 1) return true;
    final lastSeen = <String, int>{};
    for (var i = 0; i < sequence.length; i++) {
      final key = sequence[i];
      final previous = lastSeen[key];
      if (previous != null && i - previous < round) return false;
      lastSeen[key] = i;
    }
    return true;
  }

  static Future<Map<String, Object?>> _readPipSummary() async {
    final summary = <String, Object?>{
      'logFound': false,
      'configSource': PipQaConfig.source,
    };
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/pip_qa_log.json');
      if (!await file.exists()) return summary;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return summary;
      summary['logFound'] = true;
      final activeRunId = PipQaConfig.active?.runId;
      if (activeRunId != null &&
          '${decoded['runId'] ?? ''}' != activeRunId) {
        // 上一轮的日志不能当成本轮证据。
        summary['staleRunId'] = decoded['runId'];
        return summary;
      }
      for (final key in const [
        'pass',
        'passed',
        'verdict',
        'backgroundSeconds',
        'backgroundPositionAdvanced',
        'positionAdvanced',
        'pipActiveInBackground',
        'failures',
      ]) {
        if (decoded.containsKey(key)) summary[key] = decoded[key];
      }
      final samples = decoded['samples'];
      if (samples is List) {
        final sequence = <String>[];
        var queueTotal = 0;
        for (final sample in samples) {
          if (sample is! Map) continue;
          queueTotal = (sample['total'] as num?)?.toInt() ?? queueTotal;
          final key = '${sample['displayedKey'] ?? ''}'.trim();
          if (key.isEmpty || key == 'null') continue;
          if (sequence.isEmpty || sequence.last != key) sequence.add(key);
        }
        summary['sequence'] = sequence;
        summary['queueTotal'] = queueTotal;
      }
    } catch (_) {}
    return summary;
  }

  static Future<void> _write(Map<String, Object?> result) async {
    final encoded = jsonEncode(result);
    try {
      final dir = await getApplicationDocumentsDirectory();
      await File('${dir.path}/$resultFileName').writeAsString(encoded, flush: true);
      await File('${dir.path}/$historyFileName').writeAsString(
        '${jsonEncode(<String, Object?>{
          'at': result['generatedAt'],
          'cache': result['cache'],
          'verdict': result['verdict'],
        })}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
    try {
      await _dump.invokeMethod<List<Object?>>('write', <String, Object?>{
        'name': resultFileName,
        'content': encoded,
      });
    } catch (_) {}
  }
}
