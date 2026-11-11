import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/pages/douyin/perf.dart';
import 'package:PiliPlus/pages/douyin/player_bridge.dart';
import 'package:PiliPlus/pages/douyin/qa_config.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/screen_wake_lock.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

typedef ShortVideoSessionEvent = void Function(String event);
typedef ShortVideoUiRefresh = void Function();

/// 短视频播放页唯一持有的一份播放会话。
///
/// 稳定版 media_kit 的画中画控制器按 Player handle 缓存，VideoOutput 销毁时
/// 会一并销毁小窗。短视频页不能再每次换队列都新建 Player 或叠一个新页面，
/// 否则后台小窗拿到的是一份已经无人喂帧的旧图层。
class ShortVideoSession extends GetxService with WidgetsBindingObserver {
  Player? player;
  VideoController? controller;

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<String>? _pipEventSub;
  StreamSubscription<String>? _pipErrorSub;

  final Map<Object, ShortVideoSessionEvent> _pipEvents =
      <Object, ShortVideoSessionEvent>{};
  final Map<Object, ShortVideoSessionEvent> _pipErrors =
      <Object, ShortVideoSessionEvent>{};
  final Map<Object, ShortVideoSessionEvent> _completedEvents =
      <Object, ShortVideoSessionEvent>{};
  final Map<Object, ShortVideoUiRefresh> _refreshes =
      <Object, ShortVideoUiRefresh>{};

  bool _initialized = false;
  bool _disposed = false;
  bool _audioActive = false;
  bool _wakeLockHeld = false;
  bool _observing = false;
  Timer? _wakeLockReleaseTimer;
  Future<void>? _ensureReadyFuture;
  bool pipActive = false;
  bool pipSupported = true;
  bool playing = false;
  String appState = 'active';
  int index = 0;
  List<QueueEntry> queue = const <QueueEntry>[];
  String? displayedKey;
  String? lifecycleNote;
  int lifecycleSequence = 0;
  double lastBackgroundSeconds = 0;
  Map<String, Object?> lastBackgroundSummary = const <String, Object?>{};

  Object? _autoPipArmedFor;
  bool? _autoPipArmedValue;
  Object? _pipQaModeFor;
  String? _pipQaRunId;
  DateTime? _backgroundAt;
  Map<String, Object?>? _backgroundStart;

  static ShortVideoSession get instance {
    if (Get.isRegistered<ShortVideoSession>()) {
      return Get.find<ShortVideoSession>();
    }
    return Get.put(ShortVideoSession(), permanent: true);
  }

  bool get autoPiP => GStorage.setting.get(
    SettingBoxKey.autoPiP,
    defaultValue: true,
  );

  bool get ready => !_disposed && player != null && controller != null;

  Future<void> ensureReady() {
    if (_disposed) return Future<void>.value();
    if (_initialized && ready) return Future<void>.value();
    final pending = _ensureReadyFuture;
    if (pending != null) return pending;
    final created = _createSession();
    _ensureReadyFuture = created;
    return created.whenComplete(() {
      _ensureReadyFuture = null;
    });
  }

  Future<void> _createSession() async {
    if (_disposed) return;
    if (_initialized && ready) return;
    Player? createdPlayer;
    VideoController? createdController;
    try {
      await _cancelStreams();
      await ShortVideoPerf.ensureProbed();
      createdPlayer = await Player.create(
        configuration: PlayerConfiguration(
          options: {
            'autoplay': 'yes',
            if (ShortVideoPerf.lowMemory) ...{
              'demuxer-max-bytes': '24MiB',
              'demuxer-max-back-bytes': '4MiB',
            },
          },
        ),
      );
      createdController = await VideoController.create(createdPlayer!);
    } catch (_) {
      await _cancelStreams();
      try {
        await createdPlayer?.dispose();
      } catch (_) {}
      _initialized = false;
      rethrow;
    }
    if (_disposed) {
      try {
        await createdPlayer?.dispose();
      } catch (_) {}
      _initialized = false;
      return;
    }
    _initialized = true;
    final sessionPlayer = createdPlayer!;
    final sessionController = createdController!;
    player = sessionPlayer;
    controller = sessionController;
    await _forcePipDanmakuOff(sessionController);
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    await _setAudioSession(true);

    _playingSub = sessionPlayer.stream.playing.listen((value) {
      playing = value;
      _setWakeLock(value);
      if (value) {
        unawaited(_setAudioSession(true));
        if (Platform.isIOS) unawaited(armPip());
      }
      _refreshUi();
    });
    _completedSub = sessionPlayer.stream.completed.listen((completed) {
      if (!completed) return;
      for (final callback in List.of(_completedEvents.values)) {
        callback('completed');
      }
    });
    _errorSub = sessionPlayer.stream.error.listen((message) {
      if (message.isEmpty) return;
      for (final callback in List.of(_pipErrors.values)) {
        callback(message);
      }
    });

    if (Platform.isIOS) {
      _pipEventSub = PictureInPicture.events.listen((event) {
        switch (event) {
          case 'start':
            pipActive = true;
            unawaited(_setAudioSession(true));
            unawaited(forceOverlayOff());
          case 'restore':
            pipActive = false;
            unawaited(_restorePage());
          case 'stop':
            pipActive = false;
            unawaited(armPip());
        }
        _recordLifecycle(event);
        _notify(_pipEvents, event);
        _refreshUi();
      });
      _pipErrorSub = PictureInPicture.errors.listen((message) {
        pipActive = false;
        unawaited(armPip());
        _recordLifecycle('error');
        _notify(_pipErrors, message);
        _refreshUi();
      });
      await armPip();
    }
  }

  Future<void> _cancelStreams() async {
    await _playingSub?.cancel();
    await _completedSub?.cancel();
    await _errorSub?.cancel();
    await _pipEventSub?.cancel();
    await _pipErrorSub?.cancel();
    _playingSub = null;
    _completedSub = null;
    _errorSub = null;
    _pipEventSub = null;
    _pipErrorSub = null;
  }

  void _setWakeLock(bool hold) {
    _wakeLockReleaseTimer?.cancel();
    _wakeLockReleaseTimer = null;
    if (hold) {
      if (!_wakeLockHeld) {
        ScreenWakeLock.acquire(this);
        _wakeLockHeld = true;
      }
      return;
    }
    _wakeLockReleaseTimer = Timer(const Duration(milliseconds: 600), () {
      _wakeLockReleaseTimer = null;
      _releaseWakeLockNow();
    });
  }

  void _releaseWakeLockNow() {
    _wakeLockReleaseTimer?.cancel();
    _wakeLockReleaseTimer = null;
    if (_wakeLockHeld) {
      ScreenWakeLock.release(this);
      _wakeLockHeld = false;
    }
  }

  Future<void> armPip() async {
    if (!Platform.isIOS || !ready) return;
    final current = controller!;
    final qaConfig = PipQaConfig.active;
    if (qaConfig != null &&
        (!identical(_pipQaModeFor, current) ||
            _pipQaRunId != qaConfig.runId)) {
      try {
        await current.setPictureInPictureQaMode(
          'legacy',
          runId: qaConfig.runId,
        );
        _pipQaModeFor = current;
        _pipQaRunId = qaConfig.runId;
      } catch (_) {}
    }
    final armedValue = autoPiP;
    if (identical(_autoPipArmedFor, current) &&
        _autoPipArmedValue == armedValue) {
      return;
    }
    try {
      await forceOverlayOff();
      await _forcePipDanmakuOff(current);
      await current.setAutoEnterPictureInPicture(armedValue);
      _autoPipArmedFor = current;
      _autoPipArmedValue = armedValue;
    } catch (_) {}
  }

  Future<void> _forcePipDanmakuOff(VideoController current) async {
    if (!Platform.isIOS) return;
    try {
      await current.setPictureInPictureDanmakuEnabled(false);
    } catch (_) {}
  }

  Future<void> forceOverlayOff() async {
    if (!Platform.isIOS || !ready) return;
    try {
      await controller!.setPictureInPictureDebugOverlay(false);
    } catch (_) {}
  }

  Future<void> prepareForNewMedia() async {
    if (!Platform.isIOS || !ready) return;
    try {
      await forceOverlayOff();
      await _forcePipDanmakuOff(controller!);
      await controller!.preparePictureInPictureForNewMedia();
    } catch (_) {}
  }

  Future<void> _preparePipTransition({bool forceAudio = false}) async {
    if (!Platform.isIOS || !ready) return;
    await forceOverlayOff();
    if (!playing) return;
    if (forceAudio) _audioActive = false;
    await _setAudioSession(true);
    await armPip();
  }

  Future<void> startPip() async {
    if (!Platform.isIOS || !ready) return;
    final current = controller!;
    if (!await current.isPictureInPictureSupported()) {
      pipSupported = false;
      _refreshUi();
      throw StateError('系统说这台机器现在不能画中画');
    }
    pipSupported = true;
    await forceOverlayOff();
    await _setAudioSession(true);
    await armPip();
    await current.setPictureInPicture(true);
    pipActive = true;
    _recordLifecycle('manual-start');
    _refreshUi();
  }

  Future<void> stopPip() async {
    pipActive = false;
    if (Platform.isIOS && ready) {
      try {
        await controller!.setPictureInPicture(false);
      } catch (_) {}
      await armPip();
    }
    _recordLifecycle('manual-stop');
    _refreshUi();
  }

  Future<void> _setAudioSession(bool active) async {
    if (active == _audioActive) return;
    final handler = audioSessionHandler;
    if (handler == null) return;
    _audioActive = active;
    try {
      await handler.setActive(active);
    } catch (_) {
      _audioActive = !active;
    }
  }

  Future<void> keepAudioAlive() async {
    await _preparePipTransition(forceAudio: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    appState = state.name;
    _recordLifecycle('app-${state.name}');
    if (state == AppLifecycleState.inactive) {
      unawaited(_preparePipTransition(forceAudio: true));
      return;
    }
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _releaseWakeLockNow();
      if (_backgroundAt == null) {
        _backgroundAt = DateTime.now();
        unawaited(_beginBackgroundSample());
      }
      unawaited(_preparePipTransition(forceAudio: true));
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (playing) _setWakeLock(true);
      unawaited(_endBackgroundSample());
      unawaited(_onResumed());
    }
  }

  Future<void> _beginBackgroundSample() async {
    if (!Platform.isIOS || !ready) return;
    _backgroundStart = await _diagnosticsSnapshot();
  }

  Future<void> _endBackgroundSample() async {
    final started = _backgroundAt;
    if (started == null) return;
    _backgroundAt = null;
    final seconds = DateTime.now().difference(started).inMilliseconds / 1000.0;
    if (seconds < 0.5 || !Platform.isIOS || !ready) return;
    final start = _backgroundStart ?? const <String, Object?>{};
    final end = await _diagnosticsSnapshot();
    lastBackgroundSeconds = seconds;
    lastBackgroundSummary = <String, Object?>{
      'seconds': seconds,
      'enqueuedDelta':
          _numeric(end['enqueued']) - _numeric(start['enqueued']),
      'positionDelta':
          _numeric(end['position']) - _numeric(start['position']),
      'start': start,
      'end': end,
    };
    _backgroundStart = null;
  }

  Future<Map<String, Object?>> _diagnosticsSnapshot() async {
    try {
      final raw = await controller!.pictureInPictureDiagnostics();
      final snapshot = <String, Object?>{};
      raw.forEach((key, value) => snapshot['$key'] = value);
      return snapshot;
    } catch (_) {
      return const <String, Object?>{};
    }
  }

  double _numeric(Object? value) => value is num ? value.toDouble() : 0;

  Future<void> _onResumed() async {
    await _preparePipTransition(forceAudio: true);
    _refreshUi();
  }

  void _recordLifecycle(String note) {
    lifecycleNote = note;
    lifecycleSequence += 1;
  }

  void _notify(
    Map<Object, ShortVideoSessionEvent> callbacks,
    String event,
  ) {
    for (final callback in List.of(callbacks.values)) {
      callback(event);
    }
  }

  void _refreshUi() {
    for (final callback in List.of(_refreshes.values)) {
      callback();
    }
  }

  void attach(
    Object owner, {
    ShortVideoUiRefresh? onRefresh,
    ShortVideoSessionEvent? onPipEvent,
    ShortVideoSessionEvent? onPipError,
    ShortVideoSessionEvent? onCompleted,
  }) {
    if (onRefresh != null) _refreshes[owner] = onRefresh;
    if (onPipEvent != null) _pipEvents[owner] = onPipEvent;
    if (onPipError != null) _pipErrors[owner] = onPipError;
    if (onCompleted != null) _completedEvents[owner] = onCompleted;
  }

  void detach(Object owner) {
    _refreshes.remove(owner);
    _pipEvents.remove(owner);
    _pipErrors.remove(owner);
    _completedEvents.remove(owner);
  }

  void publishState({
    required int currentIndex,
    required List<QueueEntry> currentQueue,
    String? key,
  }) {
    index = currentIndex;
    queue = List<QueueEntry>.of(currentQueue);
    displayedKey = key;
  }

  Future<void> _restorePage() async {
    if (queue.isEmpty) return;
    if (Get.currentRoute == ShortVideoPlayerRoute.routeName) return;
    await openShortVideoQueue(queue, index, showImmediately: true);
  }

  Future<void> reportPlayerError(String message) {
    _notify(_pipErrors, message);
    return Future<void>.value();
  }

  Future<void> disposeSession() async {
    if (_disposed) return;
    _disposed = true;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    await _cancelStreams();
    _pipEvents.clear();
    _pipErrors.clear();
    _completedEvents.clear();
    _refreshes.clear();
    _releaseWakeLockNow();
    await _setAudioSession(false);
    if (Platform.isIOS && pipActive) {
      try {
        await controller?.setPictureInPicture(false);
      } catch (_) {}
    }
    await player?.dispose();
    player = null;
    controller = null;
    pipActive = false;
  }

  @override
  void onClose() {
    unawaited(disposeSession());
    super.onClose();
  }
}
