import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:math';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/player_bridge.dart';
import 'package:PiliPlus/pages/douyin/player_session.dart';
import 'package:PiliPlus/pages/douyin/qa_config.dart';
import 'package:PiliPlus/pages/douyin/qa_recorder.dart';
import 'package:PiliPlus/pages/douyin/qa_verdict.dart';
import 'package:PiliPlus/pages/douyin/cache.dart';
import 'package:PiliPlus/pages/douyin/playlist.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/pages/douyin/repo.dart';
import 'package:PiliPlus/pages/douyin/web.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, DeviceOrientation, SystemChrome, SystemUiMode;
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';

/// 播放顺序。
enum ShortVideoLoopMode {
  listLoop('列表循环', Icons.repeat),
  singleLoop('单曲循环', Icons.repeat_one),
  sequential('顺序播放', Icons.playlist_play),
  shuffle('随机播放', Icons.shuffle);

  const ShortVideoLoopMode(this.label, this.icon);

  final String label;
  final IconData icon;

  ShortVideoLoopMode get next =>
      ShortVideoLoopMode.values[(index + 1) % ShortVideoLoopMode.values.length];
}

/// 全屏播放抖音 / TikTok / B 站收藏。
///
/// 只有一条直链，没有 aid/cid、没有弹幕、没有清晰度梯度，所以不走 B 站视频页。
/// 但交互按 B 站播放器那套做：进度条可拖、点一下暂停/呼出控制条、
/// 左边上下滑调亮度、右边上下滑调音量、左右滑拖动进度。
///
/// iOS 上还接了系统级画中画（`VideoController.setPictureInPicture`），
/// 和站内视频页用的是同一套原生实现。
class ShortVideoPlayerPage extends StatefulWidget {
  const ShortVideoPlayerPage({
    super.key,
    required this.queue,
    required this.index,
    this.showImmediately = false,
  });

  /// 播放队列：抖音 / TikTok / B 站可以混在一起。
  final List<QueueEntry> queue;
  final int index;
  final bool showImmediately;

  @override
  State<ShortVideoPlayerPage> createState() => _ShortVideoPlayerPageState();
}

class _ShortVideoPlayerPageState extends State<ShortVideoPlayerPage> {
  static final QueueEntry _emptyEntry = QueueEntry(
    key: '',
    title: '',
    author: '',
    cover: '',
    durationMs: 0,
  );

  final ShortVideoSession _session = ShortVideoSession.instance;
  PipQaRecorder? _qaRecorder;
  Timer? _ticker;
  Timer? _hideTimer;
  Timer? _qaAdvanceTimer;
  Timer? _qaFinishTimer;
  int _qaAdvanceTick = 0;

  late final ShortVideoQueueOpener _queueOpener = _openFromBridge;

  /// 已经解析过的播放地址（按条目 key 缓存）。
  final Map<String, QueueMedia> _resolved = {};

  /// 可变的那一份队列：播到一半可以被 [QueueBus] 插队。
  late List<QueueEntry> _queue = List<QueueEntry>.of(widget.queue);

  late int _index;
  ShortVideoLoopMode _mode = ShortVideoLoopMode.listLoop;
  bool _playing = false;

  /// 这一条已经重试到第几步：0 直链、1 备用地址、2 本地缓存。
  int _retryStage = 0;

  /// 正在处理一次播放错误（一次 open 会连报好几条）。
  bool _busy = false;

  /// 这一条已经判过「播完」，避免 ticker 和 completed 双触发。
  bool _completionFired = false;
  bool _fill = false;
  bool _landscape = false;
  bool _showControls = true;

  /// 已经发起 `player.open()` 的 key：播放错误回来时用它认领「这条错误属于哪一条」。
  String? _openedKey;

  /// 真正开起来后才写的 key。标题、播放列表操作、会话恢复都跟它，不跟目标位 [_index]。
  String? _playingKey;

  /// 每次 [_openIndex] 递增。
  ///
  /// 解析直链和 player.open 都是 await，期间用户再点一条，
  /// 先发起、后回来的那次必须自己作废——否则标题已经跳了、画面还是上一条。
  int _openToken = 0;

  /// player.open 串行化：两次换源交叉会把上一条的画面和这一条的音频拼在一起。
  Future<void> _openLock = Future<void>.value();

  int _skipped = 0;
  int _videoWidth = 0;
  int _videoHeight = 0;

  bool _ready = false;

  /// 正在把当前这条整条下到本地（顶栏转圈 + 百分比）。
  bool _downloading = false;
  double _downloadProgress = 0;

  /// 当前这条本地已经有完整缓存。
  bool _cached = false;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration? _seekPreview;

  double _volume = 1;
  double _brightness = -1;
  double _speed = 1;

  /// 手势过程中显示的小提示（亮度 / 音量 / 快进 / 缓存进度）。
  String? _hint;
  Timer? _hintTimer;

  bool _dragOnVolume = false;
  double _dragStartValue = 0;
  Duration _dragStartPosition = Duration.zero;
  Duration _dragTarget = Duration.zero;
  bool _dragOnProgress = false;

  int _clampedIndex(int index) {
    if (_queue.isEmpty) return 0;
    return index.clamp(0, _queue.length - 1).toInt();
  }

  int _indexOfKey(String key) =>
      _queue.indexWhere((entry) => entry.key == key);

  /// 顶栏标题跟的是「画面上正在播的那条」，不是 [_index]。
  /// [_index] 在解析还没回来时就跳过去了，而 TikTok 解析要好几秒，
  /// 那几秒里画面还是上一条，标题却已经是下一条 —— 就是「标题和画面对不上」。
  int get _displayedIndex {
    final key = _playingKey;
    if (key != null) {
      final index = _indexOfKey(key);
      if (index >= 0) return index;
    }
    return _clampedIndex(_index);
  }

  QueueEntry get _displayedEntry =>
      _displayedEntryOrNull ?? _emptyEntry;

  QueueEntry get _current => _displayedEntry;

  QueueEntry? get _displayedEntryOrNull {
    if (_queue.isEmpty) return null;
    return _queue[_displayedIndex];
  }

  /// 按视频自己的比例显示，横屏的就铺成横向，竖屏的就铺成竖向。
  double get _aspectRatio {
    if (_videoWidth > 0 && _videoHeight > 0) {
      return _videoWidth / _videoHeight;
    }
    return 9 / 16;
  }

  Duration get _shownPosition => _seekPreview ?? _position;

  @override
  void initState() {
    super.initState();
    _index = _clampedIndex(widget.index);
    registerShortVideoPlayerPageBuilder(
      (queue, index, {showImmediately = false}) => ShortVideoPlayerPage(
        queue: queue,
        index: index,
        showImmediately: showImmediately,
      ),
    );
    registerShortVideoQueueOpener(_queueOpener);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _session.attach(
      this,
      onRefresh: _onSessionRefresh,
      onPipEvent: _onPipEvent,
      onPipError: _onPlayerError,
      onCompleted: (_) => _onCompleted(),
    );
    _restoreGestureState();
    unawaited(_init());
  }

  Future<void> _restoreGestureState() async {
    try {
      final volume = await FlutterVolumeController.getVolume();
      if (volume != null && mounted) setState(() => _volume = volume);
    } catch (_) {}
    try {
      final brightness = await ScreenBrightnessPlatform.instance.application;
      if (mounted) setState(() => _brightness = brightness);
    } catch (_) {}
  }

  Future<void> _init() async {
    if (_queue.isEmpty) {
      await _failQa('短视频播放页没有可播放队列，自动 QA 无法开始');
      return;
    }
    try {
        await _session.ensureReady();
      if (!mounted) return;
      if (widget.showImmediately && _session.queue.isNotEmpty) {
        _queue = List<QueueEntry>.of(_session.queue);
        _index = _clampedIndex(_session.index);
      }
      _publishSessionState();
      _playing = _session.playing;
      _ready = _session.ready;
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(milliseconds: 400), (_) {
        final current = _session.player;
        if (current == null || !mounted) return;
        final position = current.state.position;
        final duration = current.state.duration;
        // 播到末尾自己判一次：media_kit 的 completed 在换源 / 小窗之后并不总触发，
        // 只靠它的话「自动连播」和「下一首」就是死的。
        if (duration > Duration.zero &&
            position > Duration.zero &&
            duration - position <= const Duration(milliseconds: 500) &&
            !_completionFired) {
          _onCompleted();
        }
        // 真的播起来了才算这条没问题，别再在 open() 之后立刻清跳数。
        if (position > const Duration(seconds: 2)) _skipped = 0;
        if (position == _position && duration == _duration) return;
        if (_session.pipActive) {
          // 小窗里不需要 Flutter 重绘，少给 6S 这类老机器添负担。
          _position = position;
          _duration = duration;
          return;
        }
        setState(() {
          _position = position;
          _duration = duration;
        });
      });

      if (mounted) setState(() {});
      await _session.forceOverlayOff();
      await _session.armPip();
      final restoredKey = _session.displayedKey;
      final shouldRestore = widget.showImmediately &&
          restoredKey != null &&
          _queue.any((entry) => entry.key == restoredKey);
      await _openIndex(
        shouldRestore
            ? _queue.indexWhere((entry) => entry.key == restoredKey)
            : _index,
        restoreKey: shouldRestore ? restoredKey : null,
      );
      _scheduleHide();
      _attachQaIfNeeded();
    } catch (error) {
      final config = PipQaConfig.active;
      final verdict = '短视频播放器初始化失败：$error';
      if (config != null && Platform.isIOS) {
        await _failRecorderQa(config, verdict);
      } else {
        PipQaRuntime.fail(verdict);
      }
      _showToast(verdict);
      if (mounted) setState(() => _ready = false);
    }
  }

  Future<void> _failQa(String verdict) async {
    final config = PipQaConfig.active;
    if (config == null || !Platform.isIOS) return;
    await _failRecorderQa(config, verdict);
  }

  Future<void> _failRecorderQa(
    PipQaConfig config,
    String verdict,
  ) async {
    if (PipQaRuntime.isFinished) return;
    PipQaRuntime.fail(verdict);
    _qaAdvanceTimer?.cancel();
    _qaFinishTimer?.cancel();
    final recorder = _qaRecorder;
    _qaRecorder = null;
    if (recorder != null) {
      await recorder.fail(verdict);
    } else {
      await PipQaRecorder.writeFailure(config, verdict);
    }
    PipQaRuntime.markFinished();
  }

  void _publishSessionState() {
    _session.publishState(
      currentIndex: _displayedIndex,
      currentQueue: _queue,
      key: _playingKey,
    );
  }

  void _attachQaIfNeeded() {
    final config = PipQaConfig.active;
    if (config == null || !Platform.isIOS || _queue.isEmpty) {
      unawaited(
        _failQa('短视频播放页没有可播放队列，自动 QA 无法开始'),
      );
      return;
    }
    _qaRecorder?.close();
    final recorder = PipQaRecorder(
      config,
      _queue.length,
      () => <String, Object?>{
        'index': _displayedIndex,
        'displayedKey': _displayedEntry.key,
        'playing': _playing,
        'ready': _ready,
        'qaAdvanceTick': _qaAdvanceTick,
      },
      index: _index,
    );
    _qaRecorder = recorder;
    recorder.start();
    PipQaRuntime.markReady();
    _qaAdvanceTimer?.cancel();
    _qaFinishTimer?.cancel();
    if (config.effectiveAdvanceEvery > 0) {
      _qaAdvanceTimer = Timer.periodic(
        Duration(seconds: config.effectiveAdvanceEvery),
        (_) {
          if (!mounted || _queue.length < 2) return;
          _qaAdvanceTick += 1;
          unawaited(_jumpTo((_index + 1) % _queue.length));
        },
      );
    }
    _qaFinishTimer = Timer(
      Duration(
        seconds: config.effectivePlaySeconds +
            config.effectiveBackgroundSeconds +
            config.effectiveAdvanceEvery * 2 +
            20,
      ),
      () => unawaited(_finishQa()),
    );
  }

  Future<void> _finishQa() async {
    final config = PipQaConfig.active;
    final recorder = _qaRecorder;
    if (recorder == null || config == null) return;
    _qaRecorder = null;
    _qaAdvanceTimer?.cancel();
    _qaFinishTimer?.cancel();
    try {
      final failure = PipQaRuntime.failureVerdict;
      if (failure != null) {
        await recorder.fail(failure);
        return;
      }
      final log = await recorder.finish(
        backgroundSeconds: _session.lastBackgroundSeconds,
        backgroundSummary: _session.lastBackgroundSummary,
      );
      final verdict = evaluatePipQaLog(log, config);
      await recorder.writeVerdict(verdict);
    } catch (error) {
      await recorder.fail('自动 QA 判定失败：$error');
    } finally {
      PipQaRuntime.markFinished();
    }
  }

  void _onSessionRefresh() {
    if (!mounted) return;
    setState(() {
      _playing = _session.playing;
      _ready = _session.ready;
    });
  }

  void _onPipEvent(String event) {
    if (!mounted) return;
    setState(() {});
  }

  void _onPlayerError(String message) {
    if (!mounted) return;
    if (message.startsWith('画中画') ||
        message.startsWith('启动画中画') ||
        message.startsWith('系统说')) {
      _showToast(message);
      return;
    }
    unawaited(_onPlaybackError(message));
  }

  Future<void> _openFromBridge({
    required List<QueueEntry> queue,
    required int index,
    required bool replaceCurrent,
    required bool showImmediately,
  }) async {
    final samePage = Get.currentRoute == ShortVideoPlayerRoute.routeName ||
        Get.routing.current == ShortVideoPlayerRoute.routeName;
    if (samePage && mounted) {
      _applyQueue(queue, index, showImmediately: showImmediately);
      return;
    }
    await ShortVideoPlayerRouteNavigator.open(
      queue,
      index,
      showImmediately: showImmediately,
      replaceCurrent: replaceCurrent,
    );
  }

  void _applyQueue(
    List<QueueEntry> queue,
    int index, {
    bool showImmediately = false,
  }) {
    if (queue.isEmpty) return;
    final nextIndex = index.clamp(0, queue.length - 1);
    final restoredKey = showImmediately ? _session.displayedKey : null;
    final restoreIndex = restoredKey == null
        ? -1
        : queue.indexWhere((entry) => entry.key == restoredKey);
    setState(() {
      _queue = List<QueueEntry>.of(queue);
      _index = restoreIndex >= 0 ? restoreIndex : nextIndex;
      if (restoreIndex < 0) {
        _playingKey = null;
        _openedKey = null;
        _resolved.clear();
        _retryStage = 0;
        _skipped = 0;
      }
    });
    _publishSessionState();
    if (restoreIndex >= 0) {
      _openToken += 1;
      _playingKey = restoredKey;
      _openedKey = restoredKey;
      _playing = _session.playing;
      _ready = _session.ready;
      _position = _session.player?.state.position ?? Duration.zero;
      _duration = _session.player?.state.duration ?? Duration.zero;
      _syncVideoSize();
      _publishSessionState();
      if (mounted) setState(() {});
      return;
    }
    unawaited(_openIndex(_index));
  }

  Future<void> _togglePip() async {
    if (!_session.ready || !Platform.isIOS) return;
    try {
      if (_session.pipActive) {
        await _session.stopPip();
      } else {
        await _session.startPip();
      }
      if (mounted) setState(() {});
    } catch (e) {
      _showToast('画中画启动失败：$e');
      unawaited(_session.armPip());
    }
  }

  /// 小窗诊断面板。
  ///
  /// 原生侧一直有诊断快照（`PictureInPictureDiagnostics`），但以前只有「画进小窗画面」
  /// 这一条路：字小，而且必须先进小窗才看得见，等于拿不到。这里把它拉回页面，
  /// 大字号、自己刷新、能一键复制。
  ///
  /// 排障用法：打开面板 → 按 Home 让它自动进小窗 → 等它卡住 → 切回来读结论那一行。
  Future<void> _openPipDiagnostics() async {
    if (!_session.ready) {
      _showToast('播放器还没准备好');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (_) => _PipDiagnosticsSheet(
        controller: _session.controller!,
        fgPipStarts: _session.foregroundPipStarts,
        foregroundStartRequired:
            (PipQaConfig.active?.requiresForegroundPipStart ??
                (_session.pipQaMode == 'manual')),
        modeLabel: PipQaConfig.active?.foregroundPipStartLabel ?? '手动模式',
      ),
    );
  }

  /// 播放队列面板：看得到「我在第几条」，也能当场增删、调顺序。
  Future<void> _openQueueSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (_) => _QueueSheet(
        queue: _queue,
        onDiagnostics: () {
          Navigator.of(context).pop();
          _openPipDiagnostics();
        },
        currentKey: () => _current.key,
        onPlay: _jumpTo,
        onRemove: _removeAt,
        onMove: _move,
        onAdd: () {
          Navigator.of(context).pop();
          _openQueuePicker();
        },
        onSavePlaylist: _saveQueueToPlaylist,
        onOpenPlaylist: () {
          Navigator.of(context).pop();
          Get.to(() => const ShortVideoPlaylistPage());
        },
      ),
    );
  }

  /// 把当前这一队（B 站 / 抖音 / TikTok 混着）存成永久播放列表。
  ///
  /// 播放页里那份 `_queue` 只在这次播放有效，退出就没了；抓取结果虽然会自动
  /// 归档，但用户手动插进来的条目只能靠这一步留下来。
  void _saveQueueToPlaylist() {
    final items = <PlaylistItem>[
      for (final entry in _queue)
        if (PlaylistItem.fromEntry(entry) case final item?) item,
    ];
    if (items.isEmpty) {
      _showToast('队列里没有可保存的条目');
      return;
    }
    final added = ShortVideoPlaylistRepo.add(items);
    _showToast(
      added == 0
          ? '这些已经在播放列表里了（共 ${ShortVideoPlaylistRepo.length} 条）'
          : '已存为播放列表：新增 $added 条，共 ${ShortVideoPlaylistRepo.length} 条',
    );
  }

  /// 跳到第 index 条。
  Future<void> _jumpTo(int index) async {
    if (index < 0 || index >= _queue.length || index == _displayedIndex) return;
    setState(() => _index = index);
    await _openIndex(index);
  }

  /// 从队列里删一条。删掉正在播的那条就顺延到下一条。
  void _removeAt(int index) {
    if (index < 0 || index >= _queue.length) return;
    if (_queue.length <= 1) {
      _showToast('队列里只剩这一条了');
      return;
    }
    final playing = _current.key;
    setState(() {
      _queue.removeAt(index);
      final next = _queue.indexWhere((e) => e.key == playing);
      _index = next >= 0 ? next : _clampedIndex(_index);
    });
    if (!_queue.any((e) => e.key == playing)) {
      // 正在播的那条被删了：接着播现在落在 _index 上的这条。
      _openIndex(_index);
    }
  }

  /// 调整顺序（上移 / 下移）。当前播放的那条跟着走，不会串台。
  void _move(int from, int to) {
    if (from < 0 || from >= _queue.length) return;
    if (to < 0 || to >= _queue.length) return;
    final playing = _current.key;
    setState(() {
      final entry = _queue.removeAt(from);
      _queue.insert(to, entry);
      final next = _queue.indexWhere((e) => e.key == playing);
      if (next >= 0) {
        _index = next;
      } else {
        _index = _clampedIndex(_index);
      }
    });
  }

  /// 播放页里直接把抖音 / TikTok 的视频插到「下一首」。
  ///
  /// 收藏列表那边也能加插队，但那样得先退出播放页——播放器就没了。
  /// 所以播放页自己也留了一个入口。
  Future<void> _openQueuePicker() async {
    final all = ShortVideoRepo.loadAll();
    if (all.isEmpty) {
      _showToast('还没有抓到抖音 / TikTok 收藏');
      return;
    }
    final picked = await showModalBottomSheet<ShortVideo>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (context) => _QueuePickerSheet(videos: all),
    );
    if (picked == null || !mounted) return;
    final entry = QueueEntry.fromShortVideo(picked);
    if (entry.key == _current.key) {
      _showToast('正在播的就是这条');
      return;
    }
    _queue.insert(_displayedIndex + 1, entry);
    setState(() {});
    _showToast('已插到下一首：${picked.title}');
  }

  /// 打开第 index 条。
  ///
  /// 抖音 / TikTok 的直链会过期，B 站还要先把 cid 和 playurl 要回来，
  /// 所以统一交给 resolveQueueEntry，解析不出来就自动跳下一条。
  Future<void> _openIndex(
    int index, {
    bool resetRetry = true,
    String? restoreKey,
  }) async {
    if (_queue.isEmpty) return;
    final token = ++_openToken;
    _index = _clampedIndex(index);
    final entry = _queue[_index];
    if (resetRetry) _retryStage = 0;
    _publishSessionState();
    _position = Duration.zero;
    _duration = Duration.zero;
    _seekPreview = null;
    _completionFired = false;
    _syncCachedState();
    var media = _resolved[entry.key];
    if (media == null) {
      media = await _resolve(entry);
      // 这次解析回来时已经过期了：用户又点了一条，交给新的那次。
      if (token != _openToken || !mounted) return;
      final currentIndex = _indexOfKey(entry.key);
      if (currentIndex < 0) return;
      _index = currentIndex;
      if (media == null) {
        _skipBroken(currentIndex);
        return;
      }
      _resolved[entry.key] = media;
    }
    final player = _session.player;
    if (player == null || !mounted || token != _openToken) return;
    final url = media.url;
    final headers = <String, String>{};
    if (media.cookie.isNotEmpty) headers['Cookie'] = media.cookie;
    player.setMediaHeader(
      userAgent: media.userAgent,
      referer: media.referer,
      headers: headers,
    );
    _openedKey = entry.key;
    if (restoreKey == entry.key && _session.ready) {
      final currentIndex = _indexOfKey(entry.key);
      if (currentIndex < 0) return;
      _index = currentIndex;
      _playingKey = restoreKey;
      _ready = true;
      _playing = _session.playing;
      _syncVideoSize();
      _publishSessionState();
      unawaited(_session.forceOverlayOff());
      return;
    }
    await _session.prepareForNewMedia();
    final opened = _openLock.then((_) async {
      if (token != _openToken || !mounted) return;
      await player.open(Media(url), play: true);
    });
    _openLock = opened.then((_) {}, onError: (_) {});
    await opened;
    if (token != _openToken || !mounted) return;
    final openedIndex = _indexOfKey(entry.key);
    if (openedIndex < 0) return;
    _index = openedIndex;
    _playingKey = entry.key;
    _publishSessionState();
    await player.setRate(_speed);
    if (token != _openToken || !mounted) return;
    _syncVideoSize();
    await _session.armPip();
  }

  /// 本地已经有缓存就直接播本地（TikTok 基本都走这条）。
  Future<QueueMedia?> _resolve(QueueEntry entry) async {
    final video = entry.short;
    if (video == null) return resolveQueueEntry(entry);
    final platform =
        ShortVideoPlatform.fromId(video.platform) ??
        ShortVideoPlatform.douyin;
    final local = await ShortVideoMediaCache.localPath(video);
    if (local != null) {
      return QueueMedia(
        url: local,
        userAgent: platform.userAgent,
        referer: platform.referer,
        isLocal: true,
      );
    }
    // CDN 会按网页会话校验，cookie 必须跟着走。
    final cookie = await ShortVideoWeb.cookieHeader(
      platform.cookieDomainNeedle,
    );
    return resolveQueueEntry(entry, cookie: cookie);
  }

  /// 解析不出来就跳下一条；连跳一圈还不行就停下来说清楚。
  void _skipBroken(int index) {
    if (_queue.isEmpty) return;
    if (_queue.length <= 1 || _skipped >= _queue.length) {
      _showToast('这条播不了');
      return;
    }
    _skipped++;
    final next = (_clampedIndex(index) + 1) % _queue.length;
    if (!mounted) return;
    setState(() => _index = next);
    _openIndex(next);
  }

  /// 这个 fork 的 `PlayerStream` 没有 width/height，只能从 `state` 上取；
  /// 换源之后要等几百毫秒才有值，所以轮询几次。
  void _syncVideoSize() {
    var tries = 0;
    Future.doWhile(() async {
      if (!mounted) return false;
      final player = _session.player;
      if (player != null) {
        final w = player.state.width;
        final h = player.state.height;
        if (w > 0 && h > 0) {
          if (w != _videoWidth || h != _videoHeight) {
            setState(() {
              _videoWidth = w;
              _videoHeight = h;
            });
          }
          return false;
        }
      }
      tries++;
      if (tries > 40) return false;
      await Future.delayed(const Duration(milliseconds: 250));
      return true;
    });
  }

  /// 播不动就分三级退：换备用地址 → 缓存到本地 → 跳下一条。
  ///
  /// media_kit 一次 open 往往会连报好几条 error，所以这里串行化：
  /// 处理期间再来的错误直接丢掉，否则会一路退到「缓存」和「跳下一条」。
  Future<void> _onPlaybackError(String message) async {
    if (_busy) return;
    if (_queue.isEmpty) return;
    _busy = true;
    try {
      // 错误可能来自上一条（换源那一瞬间），按真正开着的那条认领，
      // 别拿 _index 去重试——那已经是下一条了。
      final opened = _openedKey;
      final found = opened == null ? -1 : _indexOfKey(opened);
      final index = found >= 0 ? found : _displayedIndex;
      final entry = _queue[index];
      if (_retryStage == 0) {
        _retryStage = 1;
        _resolved.remove(entry.key);
        _showToast('换备用地址重试');
        await _openIndex(index, resetRetry: false);
        return;
      }
      if (_retryStage == 1 && entry.short != null) {
        _retryStage = 2;
        await _cacheAndPlay(entry);
        return;
      }
      _showToast('播放失败：$message');
      _skipBroken(index);
    } finally {
      _busy = false;
    }
  }
  /// 直链怎么都播不了：用 HttpClient 整条下下来再播（TikTok 的老毛病）。
  Future<void> _cacheAndPlay(QueueEntry entry) async {
    final video = entry.short;
    if (video == null) {
      _skipBroken(_displayedIndex);
      return;
    }
    var entryIndex = _indexOfKey(entry.key);
    if (entryIndex < 0) return;
    // 本地文件也播不了 → 别再循环下载，直接跳。
    if (await ShortVideoMediaCache.localPath(video) != null) {
      _showToast('缓存文件也播不了');
      _skipBroken(entryIndex);
      return;
    }
    final platform =
        ShortVideoPlatform.fromId(video.platform) ?? ShortVideoPlatform.douyin;
    final urls = <String>[
      if (video.playUrl.isNotEmpty) video.playUrl,
      ...stableUrls(video),
    ];
    if (!mounted) return;
    setState(() => _hint = '缓存中 0%');
    final cookie = await ShortVideoWeb.cookieHeader(
      platform.cookieDomainNeedle,
    );
    if (!mounted) return;
    entryIndex = _indexOfKey(entry.key);
    if (entryIndex < 0) return;
    final result = await ShortVideoMediaCache.download(
      video,
      urls: urls,
      userAgent: platform.userAgent,
      referer: platform.referer,
      cookie: cookie,
      appUserAgent: platform == ShortVideoPlatform.tiktok
          ? tiktokAppUserAgent
          : '',
      onProgress: (progress) {
        if (!mounted) return;
        final percent = (progress * 100).round();
        if (_hint == '缓存中 $percent%') return;
        setState(() => _hint = '缓存中 $percent%');
      },
    );
    if (!mounted) return;
    setState(() => _hint = null);
    final path = result.path;
    if (path == null) {
      _showToast('缓存失败：${result.error ?? '未知原因'}');
      _skipBroken(entryIndex);
      return;
    }
    _retryStage = 0;
    _resolved[entry.key] = QueueMedia(
      url: path,
      userAgent: platform.userAgent,
      referer: platform.referer,
      isLocal: true,
    );
    _showToast('已缓存到本地，重新播放');
    entryIndex = _indexOfKey(entry.key);
    if (entryIndex < 0 || !mounted) return;
    await _openIndex(entryIndex, resetRetry: false);
  }

  /// 刷新「当前这条有没有本地缓存」，顶栏据此显示已缓存。
  void _syncCachedState() {
    final video = _current.short;
    if (video == null) {
      if (_cached) setState(() => _cached = false);
      return;
    }
    unawaited(
      ShortVideoMediaCache.localPath(video).then((path) {
        if (!mounted) return;
        final value = path != null;
        if (value != _cached) setState(() => _cached = value);
      }),
    );
  }

  /// 把当前这条整条下到本地。
  ///
  /// TikTok 的直链一次一换，每次播放都要重新探测，慢得让人等不住；抖音换个
  /// 网络也会变。下成本地文件之后，播放、连播、小窗都直接读文件，跟在线一样
  /// 快——6S 这种小内存机器尤其吃这一套。
  Future<void> _downloadCurrent() async {
    final entry = _current;
    final video = entry.short;
    if (video == null) {
      _showToast('B 站视频请在视频页缓存');
      return;
    }
    if (_downloading) return;
    final platform =
        ShortVideoPlatform.fromId(video.platform) ?? ShortVideoPlatform.douyin;
    setState(() {
      _downloading = true;
      _downloadProgress = 0;
    });
    final cookie = await ShortVideoWeb.cookieHeader(platform.cookieDomainNeedle);
    final urls = <String>[
      if (video.playUrl.isNotEmpty) video.playUrl,
      ...stableUrls(video),
    ];
    final result = await ShortVideoMediaCache.download(
      video,
      urls: urls,
      userAgent: platform.userAgent,
      referer: platform.referer,
      cookie: cookie,
      appUserAgent:
          platform == ShortVideoPlatform.tiktok ? tiktokAppUserAgent : '',
      onProgress: (progress) {
        if (!mounted) return;
        setState(() => _downloadProgress = progress);
      },
    );
    if (!mounted) return;
    setState(() => _downloading = false);
    final path = result.path;
    if (path == null) {
      _showToast('缓存失败：${result.error ?? '未知原因'}');
      return;
    }
    final size = await _sizeText(path);
    if (!mounted) return;
    setState(() => _cached = true);
    _resolved[entry.key] = QueueMedia(
      url: path,
      userAgent: platform.userAgent,
      referer: platform.referer,
      isLocal: true,
    );
    _showToast('已缓存到本地（$size）');
  }

  static Future<String> _sizeText(String path) async {
    try {
      final bytes = await File(path).length();
      final mb = bytes / 1024 / 1024;
      return '${mb.toStringAsFixed(1)} MB';
    } catch (_) {
      return '完成';
    }
  }

  void _onCompleted() {
    if (!mounted || _completionFired || _queue.isEmpty) return;
    _completionFired = true;
    // 「下一首播放」插队优先于本页的播放顺序。
    if (_playInjectedNext()) return;
    final current = _displayedIndex;
    switch (_mode) {
      case ShortVideoLoopMode.singleLoop:
        _openIndex(current);
      case ShortVideoLoopMode.sequential:
        if (current + 1 >= _queue.length) {
          _showToast('已经是最后一条');
          return;
        }
        setState(() => _index = current + 1);
        _openIndex(_index);
      case ShortVideoLoopMode.shuffle:
        final next = _randomIndex(current);
        setState(() => _index = next);
        _openIndex(next);
      case ShortVideoLoopMode.listLoop:
        final next = (current + 1) % _queue.length;
        setState(() => _index = next);
        _openIndex(next);
    }
  }

  /// 从 [QueueBus] 取一条插到当前条目后面。取到了返回 true。
  bool _playInjectedNext() {
    if (_queue.isEmpty) return false;
    final injected = QueueBus.takeNext();
    if (injected == null) return false;
    final currentIndex = _displayedIndex;
    if (injected.key == _current.key) {
      // 正在播的那条又被排进来了，顺延到下一条。
      return _playInjectedNext();
    }
    _queue.insert(currentIndex + 1, injected);
    setState(() => _index = currentIndex + 1);
    _openIndex(_index);
    return true;
  }

  int _randomIndex(int current) {
    if (_queue.isEmpty) return 0;
    if (_queue.length <= 1) return current;
    final random = Random();
    var next = current;
    while (next == current) {
      next = random.nextInt(_queue.length);
    }
    return next;
  }

  Future<void> _jump(int delta) async {
    final next = _displayedIndex + delta;
    if (next < 0 || next >= _queue.length) {
      _showToast(delta > 0 ? '已经是最后一条' : '已经是第一条');
      return;
    }
    setState(() => _index = next);
    await _openIndex(next);
  }

  void _cycleMode() {
    setState(() => _mode = _mode.next);
    // 不用 SnackBar：它从底部弹出来，正好盖住这一排按钮，
    // 连点两下就点不到了。改成画面中间的提示。
    _flashHint(_mode.label);
  }

  void _cycleSpeed() {
    const speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
    final next = speeds[(speeds.indexOf(_speed) + 1) % speeds.length];
    setState(() => _speed = next);
    _session.player?.setRate(next);
    _flashHint('${next}x');
  }

  /// 双击画面：暂停 / 继续。
  ///
  /// 和站内播放器一致：单击呼出控制条，双击直接暂停或继续，
  /// 不用去够底下那个按钮（单手看竖屏视频时尤其顺手）。
  void _togglePlayPause() {
    final player = _session.player;
    if (player == null) return;
    final willPause = _playing;
    player.playOrPause();
    _flashHint(willPause ? '暂停' : '播放');
    if (!_showControls) setState(() => _showControls = true);
    _scheduleHide();
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing) setState(() => _showControls = false);
    });
  }

  void _flashHint(String text) {
    _hintTimer?.cancel();
    setState(() => _hint = text);
    _hintTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  // MARK: - 手势

  void _onVerticalStart(DragStartDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    _dragOnVolume = details.localPosition.dx > width / 2;
    _dragStartValue = _dragOnVolume
        ? _volume
        : (_brightness < 0 ? 0.5 : _brightness);
  }

  void _onVerticalUpdate(DragUpdateDetails details) {
    final height = MediaQuery.sizeOf(context).height;
    final delta = -details.delta.dy / height * 1.2;
    final next = (_dragStartValue + delta).clamp(0.0, 1.0);
    _dragStartValue = next;
    if (_dragOnVolume) {
      setState(() => _volume = next);
      FlutterVolumeController.updateShowSystemUI(false);
      FlutterVolumeController.setVolume(next);
      _flashHint('音量 ${(next * 100).round()}%');
    } else {
      setState(() => _brightness = next);
      ScreenBrightnessPlatform.instance.setApplicationScreenBrightness(next);
      _flashHint('亮度 ${(next * 100).round()}%');
    }
  }

  void _onHorizontalStart(DragStartDetails details) {
    _dragOnProgress = true;
    _dragStartPosition = _position;
    _dragTarget = _position;
  }

  void _onHorizontalUpdate(DragUpdateDetails details) {
    if (!_dragOnProgress || _duration == Duration.zero) return;
    final width = MediaQuery.sizeOf(context).width;
    // 全屏横向拉满大约扫过整条视频。
    final deltaMs =
        (details.delta.dx / width) * _duration.inMilliseconds * 0.6;
    var target = _dragTarget + Duration(milliseconds: deltaMs.round());
    if (target < Duration.zero) target = Duration.zero;
    if (target > _duration) target = _duration;
    _dragTarget = target;
    setState(() => _seekPreview = target);
    _flashHint(
      '${_fmt(target)} / ${_fmt(_duration)}',
    );
  }

  void _onHorizontalEnd(DragEndDetails details) {
    if (!_dragOnProgress) return;
    _dragOnProgress = false;
    final target = _dragTarget;
    setState(() {
      _seekPreview = null;
      _position = target;
    });
    _session.player?.seek(target);
  }

  Future<void> _seekTo(Duration target) async {
    setState(() {
      _position = target;
      _seekPreview = null;
    });
    await _session.player?.seek(target);
  }

  void _toggleLandscape() {
    setState(() => _landscape = !_landscape);
    if (_landscape) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _scheduleHide();
  }

  void _showToast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: const Duration(milliseconds: 1200),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  static String _fmt(Duration value) {
    final total = value.inSeconds;
    final minutes = total ~/ 60;
    final seconds = total % 60;
    final hours = minutes ~/ 60;
    if (hours > 0) {
      return '$hours:${(minutes % 60).toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    unregisterShortVideoQueueOpener(_queueOpener);
    _session.detach(this);
    _qaAdvanceTimer?.cancel();
    _qaFinishTimer?.cancel();
    final qaRecorder = _qaRecorder;
    if (qaRecorder != null && PipQaConfig.active != null && Platform.isIOS) {
      unawaited(_finishQa());
    } else {
      qaRecorder?.close();
    }
    _ticker?.cancel();
    _hideTimer?.cancel();
    _hintTimer?.cancel();
    ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // 退出这一页后把方向交还给 App（Info.plist 里允许的就是这三个）。
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _session.controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onDoubleTap: _togglePlayPause,
            // 兜底入口：找不到右上角那个心率图标时，长按画面 1 秒也能拉出诊断面板。
            onLongPress: _openPipDiagnostics,
            onVerticalDragStart: _onVerticalStart,
            onVerticalDragUpdate: _onVerticalUpdate,
            onHorizontalDragStart: _onHorizontalStart,
            onHorizontalDragUpdate: _onHorizontalUpdate,
            onHorizontalDragEnd: _onHorizontalEnd,
            child: controller == null
                ? const Center(child: CircularProgressIndicator())
                : _videoView(controller),
          ),
          if (_hint != null)
            IgnorePointer(
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _hint!,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ),
              ),
            ),
          if (_showControls) _topBar(),
          if (_showControls) _bottomBar(),
        ],
      ),
    );
  }

  Widget _topBar() {
    final pending = QueueBus.pending;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 6,
          left: 6,
          right: 6,
          bottom: 10,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              onPressed: () => Get.back(),
              icon: const Icon(Icons.arrow_back, color: Colors.white),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _displayedEntry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                  Text(
                    '${_displayedIndex + 1}/${_queue.length}'
                    ' · ${_displayedEntry.author}'
                    '${_cached ? ' · 已缓存' : ''}'
                    '${pending > 0 ? ' · 插队 $pending' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: _downloading ? null : _downloadCurrent,
              tooltip: _downloading
                  ? '缓存中 ${(_downloadProgress * 100).round()}%'
                  : (_cached ? '已缓存（点按重新缓存）' : '缓存到本地'),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              icon: _downloading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        value: _downloadProgress > 0
                            ? _downloadProgress
                            : null,
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      _cached
                          ? Icons.download_done
                          : Icons.download_for_offline_outlined,
                      color: Colors.white,
                    ),
            ),
            IconButton(
              onPressed: _openQueueSheet,
              tooltip: '播放队列',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              icon: const Icon(Icons.queue_music, color: Colors.white),
            ),
            IconButton(
              onPressed: () => setState(() => _fill = !_fill),
              tooltip: _fill ? '适应屏幕' : '铺满屏幕',
              icon: Icon(
                _fill ? Icons.fit_screen : Icons.aspect_ratio,
                color: Colors.white,
              ),
            ),
            if (Platform.isIOS)
              IconButton(
                onPressed: _openPipDiagnostics,
                tooltip: '小窗诊断读数（长按画面也能打开）',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                icon: const Icon(
                  Icons.monitor_heart_outlined,
                  color: Colors.white,
                ),
              ),
            if (Platform.isIOS)
              // 长按不要挂 Tooltip：Tooltip 自己会吃长按（这正是之前「长按只弹提示、
              // 读数永远打不开」的原因）。现在长按直接打开诊断面板。
              GestureDetector(
                onLongPress: _openPipDiagnostics,
                child: IconButton(
                  onPressed: _togglePip,
                  icon: Icon(
                    _session.pipActive
                        ? Icons.picture_in_picture_alt
                        : Icons.picture_in_picture_outlined,
                    // 系统说不能画中画时压暗，但按钮留着——否则两个图标一起消失，
                    // 用户就再也找不到诊断入口了。
                    color: _session.pipActive || _session.pipSupported
                        ? Colors.white
                        : Colors.white38,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    final total = _duration.inMilliseconds;
    final progress = total <= 0
        ? 0.0
        : (_shownPosition.inMilliseconds / total).clamp(0.0, 1.0);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.only(
          left: 12,
          right: 12,
          bottom: MediaQuery.of(context).padding.bottom + 10,
          top: 18,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: progress,
                onChangeStart: (_) {
                  _hideTimer?.cancel();
                  setState(() => _seekPreview = _position);
                },
                onChanged: (value) {
                  if (total <= 0) return;
                  setState(() {
                    _seekPreview = Duration(
                      milliseconds: (value * total).round(),
                    );
                  });
                },
                onChangeEnd: (value) {
                  if (total <= 0) return;
                  _seekTo(Duration(milliseconds: (value * total).round()));
                  _scheduleHide();
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Text(
                    _fmt(_shownPosition),
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                  const Spacer(),
                  Text(
                    _fmt(_duration),
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  onPressed: () => _jump(-1),
                  icon: const Icon(Icons.skip_previous, color: Colors.white),
                ),
                IconButton(
                  iconSize: 42,
                  onPressed: () => _session.player?.playOrPause(),
                  icon: Icon(
                    _playing ? Icons.pause_circle : Icons.play_circle,
                    color: Colors.white,
                    size: 42,
                  ),
                ),
                IconButton(
                  onPressed: () => _jump(1),
                  icon: const Icon(Icons.skip_next, color: Colors.white),
                ),
                TextButton.icon(
                  onPressed: _cycleMode,
                  icon: Icon(_mode.icon, color: Colors.white, size: 18),
                  label: Text(
                    _mode.label,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                TextButton(
                  onPressed: _cycleSpeed,
                  child: Text(
                    '${_speed}x',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                IconButton(
                  onPressed: _toggleLandscape,
                  tooltip: _landscape ? '竖屏' : '全屏',
                  icon: Icon(
                    _landscape ? Icons.crop_portrait : Icons.fullscreen,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _videoView(VideoController controller) {
    // key 不能跟着换条走：media_kit 的纹理 id 在整个 VideoController
    // 生命周期里是固定的，换源只 resize + render。每换一条就把这一块
    // 整个重建，6S 上会连带把喂进小窗的那条链路卡住（小窗停在一帧）。
    final video = SimpleVideo(
      key: const ValueKey('short-video-surface'),
      controller: controller,
      fill: Colors.black,
      aspectRatio: _aspectRatio,
    );
    if (_fill) {
      // 铺满：按原比例放大到盖住整屏，多出来的裁掉（抖音那种全屏观感）。
      return ClipRect(
        child: SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: 1000,
              height: 1000 / _aspectRatio,
              child: video,
            ),
          ),
        ),
      );
    }
    return Center(child: AspectRatio(aspectRatio: _aspectRatio, child: video));
  }
}

/// 播放页里挑一条抖音 / TikTok 视频插到「下一首」。
class _QueuePickerSheet extends StatefulWidget {
  const _QueuePickerSheet({required this.videos});

  final List<ShortVideo> videos;

  @override
  State<_QueuePickerSheet> createState() => _QueuePickerSheetState();
}

class _QueuePickerSheetState extends State<_QueuePickerSheet> {
  String _platform = 'douyin';

  @override
  Widget build(BuildContext context) {
    final items = widget.videos.where((e) => e.platform == _platform).toList();
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '插到下一首播放',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white70),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                _tab('douyin', '抖音'),
                _tab('tiktok', 'TikTok'),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(
                    '${items.length} 条',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Flexible(
              child: items.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '这个平台还没有收藏',
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final video = items[index];
                        return ListTile(
                          dense: true,
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: SizedBox(
                              width: 36,
                              height: 48,
                              child: video.cover.isEmpty
                                  ? const ColoredBox(color: Colors.black26)
                                  : Image.network(
                                      video.cover,
                                      fit: BoxFit.cover,
                                      cacheWidth: 180,
                                      errorBuilder: (_, _, _) =>
                                          const ColoredBox(color: Colors.black26),
                                    ),
                            ),
                          ),
                          title: Text(
                            video.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                          subtitle: Text(
                            video.durationText,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          trailing: const Icon(
                            Icons.playlist_add,
                            color: Colors.white70,
                          ),
                          onTap: () => Navigator.of(context).pop(video),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tab(String id, String label) {
    final active = _platform == id;
    return TextButton(
      onPressed: () => setState(() => _platform = id),
      child: Text(
        label,
        style: TextStyle(
          color: active ? Colors.white : Colors.white54,
          fontWeight: active ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }
}

/// 播放队列面板：看得到「我在第几条」，也能当场增删、调顺序。
class _QueueSheet extends StatefulWidget {
  const _QueueSheet({
    required this.queue,
    required this.onDiagnostics,
    required this.currentKey,
    required this.onPlay,
    required this.onRemove,
    required this.onMove,
    required this.onAdd,
    required this.onSavePlaylist,
    required this.onOpenPlaylist,
  });

  final List<QueueEntry> queue;
  final VoidCallback onDiagnostics;
  final String Function() currentKey;
  final void Function(int index) onPlay;
  final void Function(int index) onRemove;
  final void Function(int from, int to) onMove;
  final VoidCallback onAdd;
  final VoidCallback onSavePlaylist;
  final VoidCallback onOpenPlaylist;

  @override
  State<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<_QueueSheet> {
  String _tag(QueueEntry entry) {
    if (entry.isBili) return 'B站';
    return entry.short?.platform == 'tiktok' ? 'TikTok' : '抖音';
  }

  Widget _mini(IconData icon, VoidCallback? onTap, {String? tip}) {
    return IconButton(
      onPressed: onTap,
      tooltip: tip,
      icon: Icon(icon, size: 18),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      color: Colors.white70,
      disabledColor: Colors.white24,
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.currentKey();
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 6, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '播放队列 ${widget.queue.length} 条',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  _mini(
                    Icons.monitor_heart_outlined,
                    widget.onDiagnostics,
                    tip: '小窗诊断读数',
                  ),
                  _mini(
                    Icons.playlist_add,
                    widget.onAdd,
                    tip: '加入抖音 / TikTok 视频',
                  ),
                  _mini(
                    Icons.bookmark_add_outlined,
                    widget.onSavePlaylist,
                    tip: '存为播放列表（永久保存）',
                  ),
                  _mini(
                    Icons.library_music_outlined,
                    widget.onOpenPlaylist,
                    tip: '打开播放列表',
                  ),
                  _mini(
                    Icons.close,
                    () => Navigator.of(context).pop(),
                    tip: '关闭',
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '点一条直接跳过去；↑↓ 调顺序，✕ 移出队列',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.queue.length,
                itemBuilder: (context, index) {
                  final entry = widget.queue[index];
                  final active = entry.key == current;
                  return Container(
                    color: active ? Colors.white12 : Colors.transparent,
                    child: ListTile(
                      dense: true,
                      onTap: () {
                        widget.onPlay(index);
                        Navigator.of(context).pop();
                      },
                      leading: SizedBox(
                        width: 26,
                        child: Center(
                          child: Text(
                            active ? '▶' : '${index + 1}',
                            style: TextStyle(
                              color: active
                                  ? Colors.lightGreenAccent
                                  : Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      title: Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: active ? Colors.white : Colors.white70,
                          fontSize: 13,
                          fontWeight: active ? FontWeight.w600 : null,
                        ),
                      ),
                      subtitle: Text(
                        '${_tag(entry)} · ${entry.durationText}'
                        '${active ? ' · 正在播放' : ''}',
                        style: TextStyle(
                          color: active
                              ? Colors.lightGreenAccent
                              : Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _mini(
                            Icons.keyboard_arrow_up,
                            index == 0
                                ? null
                                : () {
                                    widget.onMove(index, index - 1);
                                    setState(() {});
                                  },
                          ),
                          _mini(
                            Icons.keyboard_arrow_down,
                            index >= widget.queue.length - 1
                                ? null
                                : () {
                                    widget.onMove(index, index + 1);
                                    setState(() {});
                                  },
                          ),
                          _mini(
                            Icons.close,
                            widget.queue.length <= 1
                                ? null
                                : () {
                                    widget.onRemove(index);
                                    setState(() {});
                                  },
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
/// 小窗诊断面板。
///
/// 原生侧本来就有 `PictureInPictureDiagnostics` 快照，但以前只有「画进小窗画面」
/// 这一条路：字小、还必须先进小窗才看得见，等于拿不到。这里把它拉回页面，
/// 大字号、自己刷新、能一键复制。
///
/// 排障用法：打开面板 → 按 Home 让视频自动进小窗 → 等它卡住 → 切回来读结论那行。
class _PipDiagnosticsSheet extends StatefulWidget {
  const _PipDiagnosticsSheet({
    required this.controller,
    this.fgPipStarts = 0,
    this.foregroundStartRequired = false,
    this.modeLabel = '手动模式',
  });

  final VideoController controller;

  /// 切后台前「前台主动开小窗」的次数，0 表示这次还是走了系统自动进入。
  final int fgPipStarts;

  /// 前台启动模式只要求切后台前已有启动证据，不要求后台再次启动。
  final bool foregroundStartRequired;

  /// 结论里使用的模式名。
  final String modeLabel;

  @override
  State<_PipDiagnosticsSheet> createState() => _PipDiagnosticsSheetState();
}

class _PipDiagnosticsSheetState extends State<_PipDiagnosticsSheet> {
  Timer? _timer;
  Timer? _copiedTimer;
  bool _busy = false;
  bool _copied = false;
  bool _inWindow = false;
  String? _error;
  Map<String, Object?> _data = const <String, Object?>{};

  DateTime? _lastAt;
  double _lastPosition = -1;
  double _lastEnqueued = -1;

  /// 累计「小窗在显示、进度在走、但一帧都没进图层」的时长。
  double _noFrameSeconds = 0;

  /// 累计「小窗在显示、连播放进度都不走了」的时长。
  double _sourceStoppedSeconds = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_closeOverlay());
    _tick();
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _copiedTimer?.cancel();
    unawaited(_closeOverlay());
    super.dispose();
  }

  Future<void> _closeOverlay() async {
    try {
      await widget.controller.setPictureInPictureDebugOverlay(false);
    } catch (_) {}
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final data = await widget.controller.pictureInPictureDiagnostics();
      if (!mounted) return;
      _accumulate(data);
      setState(() {
        _data = data;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _busy = false;
    }
  }

  /// 两次采样之间「进度走没走、帧进没进图层」，累积成两个秒数。
  void _accumulate(Map<String, Object?> data) {
    final now = DateTime.now();
    final position = _num(data['position']);
    final enqueued = _num(data['enqueued']);
    final showing = data['showing'] == true;
    final last = _lastAt;
    if (last != null && showing && position >= 0 && _lastPosition >= 0) {
      final dt = now.difference(last).inMilliseconds / 1000.0;
      if (dt > 0.05) {
        final moved = position - _lastPosition;
        if (moved < dt * 0.3) {
          _sourceStoppedSeconds += dt;
        } else if (enqueued == _lastEnqueued) {
          _noFrameSeconds += dt;
        }
      }
    }
    _lastAt = now;
    _lastPosition = position;
    _lastEnqueued = enqueued;
  }

  static double _num(Object? value) {
    if (value is num) return value.toDouble();
    return -1;
  }

  static String _text(Object? value) {
    if (value == null) return '-';
    if (value is bool) return value ? '是' : '否';
    if (value is num) {
      final d = value.toDouble();
      return d == d.roundToDouble() ? d.round().toString() : d.toStringAsFixed(2);
    }
    return '$value';
  }

  /// 「上一次后台窗口期」的读数。卡帧只发生在这一段，而面板只能在回到前台后读，
  /// 所以结论优先用它判定。
  String get _verdict {
    if (_data.isEmpty) return '正在读取…（原生侧还没建小窗控制器）';
    final bgSeconds = _num(_data['bgSeconds']);
    if (bgSeconds >= 1.5) {
      final secs = bgSeconds.toStringAsFixed(1);
      final enq = _num(_data['bgEnqueuedDelta']);
      final same = _num(_data['bgSameFrameDelta']);
      final moved = _num(_data['bgPositionDelta']);
      final nudges = _num(_data['stallNudge']);
      final rebuilds = _num(_data['controllerRebuild']);
      final detached = _data['layerDetached'] == true;
      if (widget.foregroundStartRequired && widget.fgPipStarts < 1) {
        return '上次后台 $secs 秒：${widget.modeLabel}没有记录到前台启动';
      }
      if (enq < 2) {
        return '上次后台 $secs 秒：一帧都没进图层（+${enq.round()}）';
      }
      if (same >= enq * 0.8) {
        return '上次后台 $secs 秒：入队 +${enq.round()} 帧但内容没变 —— 卡在渲染';
      }
      if (moved < bgSeconds * 0.3) {
        return '上次后台 $secs 秒：帧在送（+${enq.round()}）但进度不走 —— 卡在解码'
            '${nudges > 0 ? '（看门狗已重推 ${nudges.round()} 次）' : ''}';
      }
      if (rebuilds > 0) {
        return '上次后台 $secs 秒：小窗图层重建 ${rebuilds.round()} 次'
            '（图层被接管：${detached ? '是' : '否'}）';
      }
      if (_data['layerOwner'] != 'system' || !detached) {
        return '上次后台 $secs 秒：内容在变、进度 +${moved.toStringAsFixed(1)} 秒'
            ' —— 卡在图层/小窗那一环'
            '（图层归属 ${_text(_data['layerOwner'])}，被接管：'
            '${detached ? '是' : '否'}）';
      }
      return '上次后台 $secs 秒：系统小窗持续出帧 —— 入队 +${enq.round()}、'
          '内容在变、进度 +${moved.toStringAsFixed(1)} 秒、图层已接管';
    }
    // 小窗正在显示时（前台也能读到）：先看「同一帧被反复重推」「显示中清屏」
    // 这两项 —— 它们就是肉眼看到的闪。原先只统计后台窗口期，前台小窗里闪的
    // 时候这里什么都读不到，面板自然「什么问题都检测不出来」。
    final sameShown = _num(_data['sameFrameShown']);
    final flushShown = _num(_data['flushShown']);
    final stallShown = _num(_data['stallShown']);
    if (_data['showing'] == true) {
      if (flushShown > 0) {
        return '小窗显示中被清屏 ${flushShown.round()} 次 —— 每清一次就闪一下';
      }
      if (sameShown > 3) {
        return '小窗显示中同帧 ${sameShown.round()} 次'
            ' —— 图层在重推同一帧（闪的来源）';
      }
      if (stallShown > 5) {
        return '小窗显示中补帧 ${stallShown.round()} 次 —— 渲染回调供帧不足';
      }
    }
    if (_data['showing'] != true) return '小窗没在显示：先按 Home 让它自动进小窗';
    if (_noFrameSeconds >= 1.5) {
      return '帧没送进小窗：累计 ${_noFrameSeconds.round()} 秒';
    }
    if (_sourceStoppedSeconds >= 1.5) {
      return '播放源停了：累计 ${_sourceStoppedSeconds.round()} 秒';
    }
    return '画面在出帧';
  }

  Color get _verdictColor {
    if (_data.isEmpty) return Colors.orangeAccent;
    final bgSeconds = _num(_data['bgSeconds']);
    if (bgSeconds >= 1.5) {
      return _backgroundHealthy ? Colors.lightGreenAccent : Colors.redAccent;
    }
    if (_data['showing'] != true) return Colors.orangeAccent;
    if (_noFrameSeconds >= 1.5 || _sourceStoppedSeconds >= 1.5) {
      return Colors.redAccent;
    }
    return Colors.lightGreenAccent;
  }

  bool get _backgroundHealthy {
    final bgSeconds = _num(_data['bgSeconds']);
    final enq = _num(_data['bgEnqueuedDelta']);
    final same = _num(_data['bgSameFrameDelta']);
    final moved = _num(_data['bgPositionDelta']);
    final rebuilds = _num(_data['controllerRebuild']);
    final detached = _data['layerDetached'] == true;
    final owner = _text(_data['layerOwner']);
    return enq >= 2 &&
        same < enq * 0.8 &&
        moved >= bgSeconds * 0.3 &&
        rebuilds <= 0 &&
        detached &&
        owner == 'system' &&
        _data['paused'] != true &&
        _num(_data['timebaseRate']) >= 0 &&
        (!widget.foregroundStartRequired || widget.fgPipStarts > 0);
  }

  List<List<String>> get _rows => [
        ['上次后台(秒)', _num(_data['bgSeconds']).toStringAsFixed(1)],
        ['后台入队', _text(_data['bgEnqueuedDelta'])],
        ['后台同帧', _text(_data['bgSameFrameDelta'])],
        ['后台进度', _text(_data['bgPositionDelta'])],
        ['后台didStart', _text(_data['bgDidStartDelta'])],
        ['后台启动调用', _text(_data['bgStartCallsDelta'])],
        ['小窗显示', _text(_data['showing'])],
        ['已武装', _text(_data['armed'])],
        ['系统允许', _text(_data['possible'])],
        ['小窗已显示(秒)', _text(_data['sinceShow'])],
        ['入队成功', _text(_data['enqueued'])],
        ['入队尝试', _text(_data['attempt'])],
        ['未就绪', _text(_data['notReady'])],
        ['未武装', _text(_data['notArmed'])],
        ['限流', _text(_data['throttled'])],
        ['拷贝失败', _text(_data['copyNil'])],
        ['补帧恢复', _text(_data['stallRecover'])],
        ['渲染为空', _text(_data['renderNil'])],
        ['恢复刷新', _text(_data['resumeFlush'])],
        ['位置清屏', _text(_data['positionFlush'])],
        ['保活定时器', _text(_data['timerTicks'])],
        ['图层可写', _text(_data['layerReady'])],
        ['图层隐藏', _text(_data['layerHidden'])],
        ['图层状态', _text(_data['layerStatus'])],
        ['画面源在窗口', _text(_data['hostAttached'])],
        ['App 状态', _text(_data['appState'])],
        ['音频会话', _text(_data['audioActive'])],
        ['音频被占', _text(_data['audioOtherPlaying'])],
        ['暂停', _text(_data['paused'])],
        ['进度(秒)', _text(_data['position'])],
        ['时间轴速率', _text(_data['timebaseRate'])],
        ['窗口尺寸', _text(_data['windowBounds'])],
        ['didStart/Stop', '${_text(_data['didStart'])}/${_text(_data['didStop'])}'],
        ['校正尝试/命中',
          '${_text(_data['reconcileTry'])}/${_text(_data['reconcileHit'])}'],
        ['启动调用/失败',
          '${_text(_data['startCalls'])}/${_text(_data['startFail'])}'],
        ['同帧', _text(_data['sameFrame'])],
        ['重复跳过', _text(_data['duplicateSkip'])],
        ['同帧(显示中)', _text(_data['sameFrameShown'])],
        ['显示中补帧', _text(_data['stallShown'])],
        ['未显示补帧', _text(_data['stallIdle'])],
        ['显示中清屏', _text(_data['flushShown'])],
        ['图层归属', _text(_data['layerOwner'])],
        [
          '宿主边长/透明度',
          '${_text(_data['hostSide'])}/${_text(_data['hostAlpha'])}',
        ],
        [
          '预热/可启动',
          '${_text(_data['prewarm'])}/${_text(_data['prewarmOk'])}',
        ],
        ['前台进小窗', '${widget.fgPipStarts} 次'],
        ['停滞重推', _text(_data['stallNudge'])],
        ['控制器重建', _text(_data['controllerRebuild'])],
        ['图层被接管', _text(_data['layerDetached'])],
        ['后台/前台入队',
          '${_text(_data['bgEnqueued'])}/${_text(_data['fgEnqueued'])}'],
      ];

  String get _plainText {
    final lines = <String>[
      '结论：$_verdict',
      '版本：${BuildConfig.versionName}(${BuildConfig.versionCode})',
    ];
    for (final row in _rows) {
      lines.add('${row[0]}: ${row[1]}');
    }
    if (_error != null) lines.add('读取失败：$_error');
    return lines.join('\n');
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: _plainText));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (!mounted) return;
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _closeInWindowOverlay() async {
    await _closeOverlay();
    if (mounted) setState(() => _inWindow = false);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    '小窗诊断 · ${BuildConfig.versionName}'
                    '(${BuildConfig.versionCode})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _copy,
                  child: Text(
                    _copied ? '已复制' : '复制读数',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: _closeInWindowOverlay,
                  child: Text(
                    '关闭叠字',
                    style: TextStyle(
                      fontSize: 13,
                      color: _inWindow ? Colors.lightGreenAccent : null,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                ),
              ],
            ),
            const Text(
              '入口：右上角心率图标 / 长按画面 1 秒 / 播放队列右上角。'
              '进来后按 Home 让它自动进小窗 → 等它卡住 → 切回来看上面那行结论。'
              '「画字进小窗」只画文字，不再有红色色块',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _verdict,
                style: TextStyle(
                  color: _verdictColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final row in _rows)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                row[0],
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            Text(
                              row[1],
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '读取失败：$_error',
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
