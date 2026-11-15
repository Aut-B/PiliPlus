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
    Future<bool> Function({
      required List<QueueEntry> queue,
      required int index,
      required bool replaceCurrent,
      required bool showImmediately,
    });

ShortVideoPlayerPageBuilder? _pageBuilder;
ShortVideoQueueOpener? _queueOpener;
final Set<Route<dynamic>> _playerRoutes = <Route<dynamic>>{};

void registerShortVideoPlayerPageBuilder(ShortVideoPlayerPageBuilder builder) {
  _pageBuilder = builder;
}

void registerShortVideoQueueOpener(ShortVideoQueueOpener opener) {
  _queueOpener = opener;
}

void unregisterShortVideoQueueOpener(ShortVideoQueueOpener opener) {
  if (identical(_queueOpener, opener)) _queueOpener = null;
}

void registerShortVideoPlayerRoute(Route<dynamic> route) {
  _playerRoutes.add(route);
}

void unregisterShortVideoPlayerRoute(Route<dynamic> route) {
  _playerRoutes.remove(route);
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
    final handled = await opener(
      queue: queue,
      index: index,
      showImmediately: showImmediately,
      replaceCurrent: replaceCurrent,
    );
    if (handled) return;
  }
  await ShortVideoPlayerRouteNavigator.open(
    queue,
    index,
    showImmediately: showImmediately,
    replaceCurrent: replaceCurrent,
  );
}

void removeStaleShortVideoPlayerRoutes() {
  final navigator = Get.key.currentState;
  if (navigator == null) return;
  final stale = _playerRoutes
      .where((route) => !route.isCurrent)
      .toList(growable: false);
  for (final route in stale) {
    unregisterShortVideoPlayerRoute(route);
    if (route.isActive) navigator.removeRoute(route);
  }
}

abstract final class ShortVideoPlayerRouteNavigator {
  static Future<void> open(
    List<QueueEntry> queue,
    int index, {
    required bool showImmediately,
    bool replaceCurrent = false,
  }) async {
    await _openOrReplace(
      queue,
      index,
      showImmediately: showImmediately,
      replaceCurrent: replaceCurrent,
    );
  }
}

Future<void> _openOrReplace(
  List<QueueEntry> queue,
  int index, {
  required bool showImmediately,
  required bool replaceCurrent,
}) async {
  if (queue.isEmpty) return;
  removeStaleShortVideoPlayerRoutes();
  final page = () => buildShortVideoPlayerPage(
    queue,
    index,
    showImmediately: showImmediately,
  );
  if (replaceCurrent) {
    await Get.off<void>(
      page,
      routeName: ShortVideoPlayerRoute.routeName,
      preventDuplicates: false,
    );
  } else {
    await Get.to<void>(
      page,
      routeName: ShortVideoPlayerRoute.routeName,
      preventDuplicates: false,
    );
  }
}
