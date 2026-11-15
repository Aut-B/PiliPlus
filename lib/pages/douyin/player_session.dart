import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:PiliPlus/pages/douyin/perf.dart';
import 'package:PiliPlus/pages/douyin/player_bridge.dart';
import 'package:PiliPlus/pages/douyin/qa_config.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
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
  bool _disposeRequested = false;
  bool _audioActive = false;
  bool _wakeLockHeld = false;
  bool _observing = false;
  bool _iosPipHold = false;
  bool _iosPipRestoring = false;
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
  int foregroundPipStarts = 0;
  double lastBackgroundSeconds = 0;
  Map<String, Object?> lastBackgroundSummary = const <String, Object?>{};

  Object? _autoPipArmedFor;
  bool? _autoPipArmedValue;
  Object? _nativePipModeFor;
  String? _nativePipMode;
  String? _nativePipRunId;
  bool _foregroundPipStartInFlight = false;
  bool _pipStartOrdered = false;
  int _pipStartGeneration = 0;
  Timer? _pipStartGuardTimer;
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

  bool get _forceShortVideoAutoPiP => PipQaConfig.active != null || autoPiP;
  bool get isManualQaMode => pipQaMode == 'manual';

  String? _pipRecoveryRunId;

  bool get ready => !_disposed && player != null && controller != null;
  bool get pipHold => _iosPipHold;
  String get pipQaMode =>
      PipQaConfig.active?.effectiveNativePipMode ??
      PipQaConfig.defaultPipMode;

  String get _nativePipQaRunId =>
      PipQaConfig.active?.runId ?? 'short-video-default';

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
    _disposeRequested = false;
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
            _completePipStart();
            pipActive = true;
            _acquirePipHold();
            unawaited(_setAudioSession(true));
            unawaited(forceOverlayOff());
          case 'restore':
            _completePipStart();
            pipActive = false;
            _iosPipRestoring = true;
            unawaited(_restorePage());
          case 'stop':
            _failPipStart(event);
            pipActive = false;
            _releasePipHold();
            unawaited(armPip(force: true));
        }
        _recordLifecycle(event);
        _notify(_pipEvents, event);
        _refreshUi();
      });
      _pipErrorSub = PictureInPicture.errors.listen((message) {
        _failPipStart('error');
        pipActive = false;
        _releasePipHold();
        unawaited(armPip(force: true));
        _recordLifecycle('error');
        _notify(_pipErrors, message);
        _refreshUi();
      });
      await armPip();
    }
  }

  Future<void> _cancelStreams() async {
    _cancelPipStartGuard();
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
      if (!playing) _releaseWakeLockNow();
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

  Future<void> armPip({bool force = false}) async {
    if (!Platform.isIOS || !ready) return;
    if (_foregroundPipStartInFlight || pipActive) return;
    final current = controller!;
    await _configurePipBeforeStart(
      current,
      bypassGuard: false,
      reuseCachedArm: !force,
    );
  }

  Future<void> _configurePipBeforeStart(
    VideoController current, {
    required bool bypassGuard,
    required bool reuseCachedArm,
  }) async {
    if (!bypassGuard && (_foregroundPipStartInFlight || pipActive)) return;
    final armedValue = !isManualQaMode;
    final nativeMode = pipQaMode;
    final nativeRunId = _nativePipQaRunId;
    if (reuseCachedArm &&
        identical(_autoPipArmedFor, current) &&
        _autoPipArmedValue == armedValue &&
        identical(_nativePipModeFor, current) &&
        _nativePipMode == nativeMode &&
        _nativePipRunId == nativeRunId) {
      return;
    }
    try {
      await forceOverlayOff();
      await _forcePipDanmakuOff(current);
      await _applyNativePipMode(current, nativeMode, nativeRunId);
      await current.setAutoEnterPictureInPicture(armedValue);
      _autoPipArmedFor = current;
      _autoPipArmedValue = armedValue;
    } catch (_) {}
  }

  Future<void> _applyNativePipMode(
    VideoController current,
    String mode,
    String runId,
  ) async {
    if (!Platform.isIOS ||
        (identical(_nativePipModeFor, current) &&
            _nativePipMode == mode &&
            _nativePipRunId == runId)) {
      return;
    }
    try {
      await current.setPictureInPictureQaMode(mode, runId: runId);
      _nativePipModeFor = current;
      _nativePipMode = mode;
      _nativePipRunId = runId;
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
    final current = controller!;
    try {
      await forceOverlayOff();
      await _forcePipDanmakuOff(current);
      await _applyNativePipMode(
        current,
        pipQaMode,
        _nativePipQaRunId,
      );
      await current.preparePictureInPictureForNewMedia();
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
    await _startPipFromForegroundBiliLike(manual: true);
  }

  void resetPipQaCounters() {
    foregroundPipStarts = 0;
  }

  Future<void> stopPip() async {
    _cancelPipStartGuard();
    _foregroundPipStartInFlight = false;
    _pipStartOrdered = false;
    _pipStartGeneration++;
    pipActive = false;
    _releasePipHold();
    if (Platform.isIOS && ready) {
      try {
        await controller!.setPictureInPicture(false);
      } catch (_) {}
      await _armPipAfterStop(force: true);
    }
    _recordLifecycle('manual-stop');
    _refreshUi();
  }

  void _acquirePipHold() {
    _iosPipHold = true;
  }

  void _releasePipHold() {
    if (!_iosPipHold) return;
    if (_iosPipRestoring) {
      _iosPipRestoring = false;
      _schedulePipHoldReleaseAfterRestore(0);
      return;
    }
    _finishPipHoldRelease();
  }

  void _schedulePipHoldReleaseAfterRestore(int attempt) {
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (!_iosPipHold || _disposed) return;
      if (Get.currentRoute == ShortVideoPlayerRoute.routeName ||
          attempt >= 24) {
        _finishPipHoldRelease();
        return;
      }
      _schedulePipHoldReleaseAfterRestore(attempt + 1);
    });
  }

  void _finishPipHoldRelease() {
    _iosPipHold = false;
    if (_disposeRequested) unawaited(disposeSession());
  }

  void _cancelPipStartGuard() {
    _pipStartGuardTimer?.cancel();
    _pipStartGuardTimer = null;
  }

  void _completePipStart() {
    if (!_foregroundPipStartInFlight) return;
    _cancelPipStartGuard();
    _foregroundPipStartInFlight = false;
    _pipStartOrdered = false;
  }

  void _failPipStart(String reason) {
    if (!_foregroundPipStartInFlight) return;
    _recordLifecycle('start-$reason');
    _completePipStart();
    _releasePipHold();
  }

  void _schedulePipStartGuard(int generation) {
    _cancelPipStartGuard();
    _pipStartGuardTimer = Timer(const Duration(seconds: 9), () {
      if (generation != _pipStartGeneration || _disposed) return;
      if (!_foregroundPipStartInFlight) return;
      pipActive = false;
      _failPipStart('timeout');
      _refreshUi();
    });
  }

  Future<void> _startPipFromForegroundBiliLike({bool manual = false}) async {
    if (!Platform.isIOS || !ready || !playing || _disposed) return;
    if (pipActive || _foregroundPipStartInFlight || _pipStartOrdered) return;
    final current = controller!;
    _foregroundPipStartInFlight = true;
    _pipStartOrdered = true;
    final generation = ++_pipStartGeneration;
    _acquirePipHold();
    pipSupported = true;
    pipActive = true;
    _recordLifecycle(manual ? 'manual-start' : 'inactive-start');
    bool startOrdered = false;
    try {
      await _configurePipBeforeStart(
        current,
        bypassGuard: true,
        reuseCachedArm: false,
      );
      await _setAudioSession(true);
      if (_disposed || generation != _pipStartGeneration) return;
      _schedulePipStartGuard(generation);
      await current.setPictureInPicture(true);
      startOrdered = true;
      foregroundPipStarts += 1;
      PipQaRuntime.markForegroundPipStart(manual: manual);
    } catch (_) {
      if (generation != _pipStartGeneration) return;
      pipActive = false;
      _cancelPipStartGuard();
      _completePipStart();
      _releasePipHold();
    } finally {
      if (!startOrdered && generation == _pipStartGeneration) {
        _cancelPipStartGuard();
        _completePipStart();
      }
    }
    _refreshUi();
  }

  Future<void> _armPipAfterStop({bool force = false}) async {
    if (_foregroundPipStartInFlight || _pipStartOrdered || pipActive) return;
    await armPip(force: force);
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
      if (playing) _setWakeLock(true);
      _startBackgroundWindow();
      _recoverPiPOnBackground('app-inactive');
      return;
    }
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _releaseWakeLockNow();
      _startBackgroundWindow();
      _recoverPiPOnBackground('app-${state.name}');
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (playing) _setWakeLock(true);
      unawaited(_endBackgroundSample());
      unawaited(_onResumed());
    }
  }

  void _recoverPiPOnBackground(String reason) {
    if (!Platform.isIOS || !ready || !playing || pipActive) return;
    if (!_forceShortVideoAutoPiP) return;
    final runId = _nativePipQaRunId;
    if (_pipRecoveryRunId == runId) return;
    _pipRecoveryRunId = runId;
    _recordLifecycle('$reason-arm');
    unawaited(
      armPip(force: true).then((_) {
        if (!ready || !playing || pipActive || appState == 'resumed') return;
        Future<void>.delayed(
          const Duration(milliseconds: 350 + Random().nextInt(250)),
          () {
            if (_disposed || !ready || !playing || pipActive) return;
            if (appState == 'resumed') return;
            _recordLifecycle('$reason-start');
            unawaited(
              _startPipFromForegroundBiliLike().then((_) {
                _pipRecoveryRunId = null;
              }),
            );
          },
        );
      }),
    );
  }

  void _startBackgroundWindow() {
    if (_backgroundAt != null) return;
    _backgroundAt = DateTime.now();
    unawaited(_beginBackgroundSample());
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
    await _setAudioSession(true);
    if (Get.currentRoute == ShortVideoPlayerRoute.routeName) {
      _iosPipRestoring = false;
      _finishPipHoldRelease();
    }
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
    await openShortVideoQueue(
      queue,
      index,
      showImmediately: true,
      replaceCurrent: true,
    );
  }

  Future<void> reportPlayerError(String message) {
    _notify(_pipErrors, message);
    return Future<void>.value();
  }

  Future<void> disposeSession() async {
    if (_disposed) return;
    if (_iosPipHold) {
      _disposeRequested = true;
      return;
    }
    _disposed = true;
    _disposeRequested = false;
    _cancelPipStartGuard();
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
    _autoPipArmedFor = null;
    _autoPipArmedValue = null;
    _nativePipModeFor = null;
    _nativePipMode = null;
    _nativePipRunId = null;
    pipActive = false;
  }

  @override
  void onClose() {
    unawaited(disposeSession());
    super.onClose();
  }
}
