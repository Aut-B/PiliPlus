import 'dart:io';

import 'package:PiliPlus/pages/douyin/web.dart';

/// 老机型上的取舍。
///
/// 6S 这类 2GB 内存的机器，缓存文件、封面图、解码缓冲三样一起压上去很容易被
/// 系统直接杀掉（表现为点开就闪退、或者播两下黑屏）。所以短视频这块在低内存
/// 机器上走一套更保守的策略：串行下载、缓存目录上限更小、解码缓冲压到最低。
///
/// 判断只做一次（问一次原生 `ProcessInfo.physicalMemory`），之后同步读
/// [lowMemory] 即可，不会在播放路径上反复 await。
abstract final class ShortVideoPerf {
  static bool _probed = false;
  static bool _lowMemory = false;

  /// 是否按低内存策略跑（物理内存 ≤ 2.6GB，即 2GB 机型）。
  static bool get lowMemory => _lowMemory;

  /// 缓存目录上限：老机型 350MB，其它 3GB。超了按最旧的先删。
  static int get cacheLimitBytes => _lowMemory
      ? 350 * 1024 * 1024
      : 3 * 1024 * 1024 * 1024;

  /// 一次性探测，重复调用只会真正问一次原生。
  static Future<void> ensureProbed() async {
    if (_probed) return;
    _probed = true;
    if (!Platform.isIOS && !Platform.isAndroid) return;
    try {
      final bytes = await ShortVideoWeb.deviceMemory();
      if (bytes > 0) {
        _lowMemory = bytes <= 2600 * 1000 * 1000;
      }
    } catch (_) {}
  }
}
