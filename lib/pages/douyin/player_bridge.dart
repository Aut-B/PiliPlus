import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

abstract final class ShortVideoPlayerRoute {
  static const String routeName = '/shortVideoPlayer';
}

typedef ShortVideoPlayerPageBuilder = Widget Function(
  List<QueueEntry> queue,
  int index, {
  bool showImmediately,
});

typedef ShortVideoQueueOpener =
    Future<void> Function({
      required List<QueueEntry> queue,
      required int index,
      required bool replaceCurrent,
      required bool showImmediately,
    });

ShortVideoPlayerPageBuilder? _pageBuilder;
ShortVideoQueueOpener? _queueOpener;

void registerShortVideoPlayerPageBuilder(ShortVideoPlayerPageBuilder builder) {
  _pageBuilder = builder;
}

void registerShortVideoQueueOpener(ShortVideoQueueOpener opener) {
  _queueOpener = opener;
}

void unregisterShortVideoQueueOpener(ShortVideoQueueOpener opener) {
  if (identical(_queueOpener, opener)) _queueOpener = null;
}

Widget buildShortVideoPlayerPage(
  List<QueueEntry> queue,
  int index, {
  bool showImmediately = false,
}) {
  final builder = _pageBuilder;
  if (builder == null) {
    throw StateError('短视频播放页尚未注册');
  }
  return builder(queue, index, showImmediately: showImmediately);
}

/// 所有收藏夹、播放列表、B 站插队都走这里，保证只有一个播放页。
Future<void> openShortVideoQueue(
  List<QueueEntry> queue,
  int index, {
  bool showImmediately = false,
  bool replaceCurrent = false,
}) async {
  if (queue.isEmpty) return;
  final opener = _queueOpener;
  if (opener != null) {
    await opener(
      queue: queue,
      index: index,
      showImmediately: showImmediately,
      replaceCurrent: replaceCurrent,
    );
    return;
  }
  await _defaultOpen(
    queue,
    index,
    showImmediately: showImmediately,
    replaceCurrent: replaceCurrent,
  );
}

abstract final class ShortVideoPlayerRouteNavigator {
  static Future<void> open(
    List<QueueEntry> queue,
    int index, {
    required bool showImmediately,
    bool replaceCurrent = false,
  }) async {
    await _defaultOpen(
      queue,
      index,
      showImmediately: showImmediately,
      replaceCurrent: replaceCurrent,
    );
  }
}

Future<void> _defaultOpen(
  List<QueueEntry> queue,
  int index, {
  required bool showImmediately,
  required bool replaceCurrent,
}) async {
  if (queue.isEmpty) return;
  final page = () => buildShortVideoPlayerPage(
    queue,
    index,
    showImmediately: showImmediately,
  );
  if (replaceCurrent && Get.currentRoute == ShortVideoPlayerRoute.routeName) {
    await Get.off<void>(page);
  } else {
    await Get.to<void>(page, routeName: ShortVideoPlayerRoute.routeName);
  }
}
