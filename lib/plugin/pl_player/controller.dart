import 'dart:async' show StreamSubscription, Timer, unawaited;
import 'dart:convert' show ascii, utf8;
import 'dart:io' show Platform;
import 'dart:math' show max, min;
import 'dart:ui' as ui;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart'
    show DanmakuElem;
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/common/super_resolution_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/user/danmaku_rule.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_shot/data.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/double_tap_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/duration.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/asset_utils.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/box_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, DeviceOrientation, HapticFeedback;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:path/path.dart' as path;
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

typedef PlayCallback = Future<void>? Function();

class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
  Player? _videoPlayerController;
  VideoController? _videoController;

  static PlPlayerController? _instance;

  PlayerStatus playerStatus = .paused;

  final Rx<DataStatus> dataStatus = Rx(.none);

  Duration? seekToPos;
  bool hasToasted = false;
  final RxBool isSeeking = false.obs;

  final RxInt position = RxInt(0);
  final RxInt seekPosition = RxInt(0);
  int get progress => isSeeking.value ? seekPosition.value : position.value;

  int get positionInMilliseconds =>
      videoPlayerController?.state.position.inMilliseconds ?? 0;

  final RxInt buffered = RxInt(0);

  final RxInt duration = RxInt(0);

  int durationInMilliseconds = 0;

  void updateDuration(Duration value) {
    duration.value = value.inSeconds;
    durationInMilliseconds = value.inMilliseconds;
  }

  int _playerCount = 0;

  late double lastPlaybackSpeed = 1.0;
  final RxDouble _playbackSpeed = Pref.playSpeedDefault.obs;
  late final RxDouble _longPressSpeed = Pref.longPressSpeedDefault.obs;

  final RxDouble volume = RxDouble(
    PlatformUtils.isDesktop ? Pref.desktopVolume : 1.0,
  );
  final setSystemBrightness = Pref.setSystemBrightness;

  final RxDouble brightness = (-1.0).obs;

  final RxBool showControls = false.obs;

  final RxBool showBrightnessStatus = false.obs;

  final RxBool longPressStatus = false.obs;

  final RxBool controlsLock = false.obs;

  final RxBool isFullScreen = false.obs;
  bool isLive = false;

  bool _isVertical = false;

  final Rx<VideoFitType> videoFit = Rx(.contain);

  late final RxBool continuePlayInBackground =
      Pref.continuePlayInBackground.obs;

  bool _autoPlay = false;

  // 记录历史记录
  int? _aid;
  String? _bvid;
  int? cid;
  int? _epid;
  int? _seasonId;
  int? _pgcType;
  VideoType _videoType = VideoType.ugc;
  int _heartDuration = 0;
  int? width;
  int? height;

  late final tryLook = !Accounts.get(AccountType.video).isLogin && Pref.p1080;

  late DataSource dataSource;

  Timer? _timer;
  StreamSubscription? _subForSeek;

  Box setting = GStorage.setting;

  // final Durations durations;

  String get bvid => _bvid!;

  /// 视频播放速度
  double get playbackSpeed => _playbackSpeed.value;

  // 长按倍速
  double get longPressSpeed => _longPressSpeed.value;

  /// [videoPlayerController] instance of Player
  Player? get videoPlayerController => _videoPlayerController;

  /// [videoController] instance of Player
  VideoController? get videoController => _videoController;

  bool isMuted = false;

  /// 听视频
  late final RxBool onlyPlayAudio = false.obs;

  /// 镜像
  late final RxBool flipX = false.obs;

  late final RxBool flipY = false.obs;

  final RxBool isBuffering = true.obs;

  /// 全屏方向
  // ignore: unnecessary_getters_setters
  bool get isVertical => _isVertical;

  set isVertical(bool value) {
    _isVertical = value;
  }

  /// 弹幕开关
  late final RxBool enableShowDanmaku = Pref.enableShowDanmaku.obs;
  late final RxBool enableShowLiveDanmaku = Pref.enableShowLiveDanmaku.obs;
  RxBool get enableShowDanmakuAdaptive =>
      isLive ? enableShowLiveDanmaku : enableShowDanmaku;

  /// 「后台画中画」开关。
  ///
  /// iOS 上默认开启：与 cilicili 等播放器一致，播放中划回主屏幕即自动进入系统
  /// 小窗，无需先点一次按钮。用户可在「设置 → 播放设置」里关掉。
  late final bool autoPiP = Platform.isIOS
      ? GStorage.setting.get(SettingBoxKey.autoPiP, defaultValue: true)
      : Pref.autoPiP;
  bool get isPipMode =>
      (Platform.isAndroid && AndroidHelper.isPipMode) ||
      (PlatformUtils.isDesktop && isDesktopPip);
  late bool isDesktopPip = false;
  /// iOS 是否处于系统级画中画（由原生侧事件驱动）。
  final RxBool isIOSPip = false.obs;

  /// 最近一条 mpv 播放错误原文（截断到 200 字符）。
  ///
  /// 「接口拿不到播放地址」和「拿到了地址却拉不到流」在界面上长得一模一样——
  /// 都是播放器转圈，但一个是网络出口的问题、一个是播放地址本身的问题，处置完全不同。
  /// 这条原文是唯一能当场分开两者的读数，所以显示在「加载中」下面，让它一定被看到。
  final RxString mediaError = ''.obs;

  /// 因为「拉流卡死」而自动重新取流的次数（换集时归零）。
  final RxInt mediaStallRetry = RxInt(0);

  /// 因为「拉流失败」而换过的 CDN 节点次数（换集时归零）。
  ///
  /// 与 [mediaStallRetry] 是两条不同的路：重新取流只是再问一次接口，默认的
  /// 「备用URL」会把接口给的同一个机房原样拿回来，所以那条路上限到了也还是同一个
  /// 地址；换节点则是把主机名换掉，是这台设备自己就能做完的一步。
  final RxInt cdnSwitchCount = RxInt(0);

  /// 最近一次换 CDN 节点的记录（空串表示没换过，与 [mediaError] 一起展示）。
  final RxString cdnSwitchNote = RxString('');

  /// 换节点的次数上限；用满之后交给「重新取流」那条路。
  static const int maxCdnSwitch = 3;

  /// 换节点动作是否正在进行，防止错误回调与看门狗同时动手。
  bool _switchingMirror = false;

  /// 换节点计数挂在「哪一集」上。
  ///
  /// 不这样做的话，重新取流会把计数清零（它也要走 setDataSource），于是
  /// 「换节点到上限 → 重新取流 → 计数归零 → 又开始换节点」会互相清空，两边都
  /// 到不了上限。同一集重取不重置，换集才重置。
  String? _mediaRetryKey;

  /// 本集的响度归一化参数，换节点重开时要原样带上。
  Volume? _volumeNorm;

  /// 本次取流时对播放地址做过的规范化记录（空串表示地址原样可用）。
  ///
  /// 上游偶尔会给出不带协议头的播放地址，加工后会变成
  /// `https://host/host/upgcxcode/...` 这种打不开的地址——从
  /// `VideoUtils.getCdnUrl` 的 `urlFixNote` 抄过来，和 mpv 原文一起显示，
  /// 这样「地址被改过」和「地址没改但还是连不上」能一眼分开。
  final RxString urlFixNote = ''.obs;

  /// 当前播放源的域名。
  ///
  /// mpv 报 `tcp: ffurl_read returned ...` 这类错误时原文里不带地址，光看那句
  /// 分不出卡在哪个域名上；播放地址的域名（CDN 节点）是最需要确认的一项，
  /// 所以单独取出来一并展示。
  String get mediaSourceHost {
    try {
      return Uri.parse(dataSource.videoSource).host;
    } catch (_) {
      return '';
    }
  }

  /// 「取流请求被排队 / 已补发」的记录（空串表示没有发生过）。
  ///
  /// 取流进行中再来的请求原先会被直接丢掉；「播完自动换集」那一次只有一次机会，
  /// 落空就是黑屏且不自愈。这条记录用来留痕，只作正文行，不单独触发读数显示。
  final RxString queryNote = RxString('');

  /// 「换集之后迟迟没有接上播放」的记录（空串表示没有发生过）。
  final RxString episodeSwitchNote = RxString('');

  /// 有没有需要展示的现场读数。
  ///
  /// 读数原先只挂在「加载中」那个分支下面，于是「换集没接上」这种现场一个字也看
  /// 不到——此时既不在缓冲、也没有在播放，界面上没有任何提示。改成由这个 getter
  /// 决定：只要记过任何异常，就在播放区底部显示（见 `view.dart`）。
  bool get hasDiagnostics =>
      mediaError.value.isNotEmpty ||
      urlFixNote.value.isNotEmpty ||
      cdnSwitchNote.value.isNotEmpty ||
      episodeSwitchNote.value.isNotEmpty;

  /// 记下「有一轮取流请求被排队」。
  void noteQueryQueued() {
    queryNote.value = '取流请求排队中：上一轮还没结束，已让它接在后面补发';
  }

  /// 记下「排队的那一轮取流已补发」。
  void noteQueryReissued() {
    queryNote.value = '上一轮取流请求曾被排队，现已补发';
  }

  /// 记下「换集之后 [seconds] 秒仍未开始播放」。
  void noteEpisodeSwitchMissed(int seconds) {
    episodeSwitchNote.value = '换集后 $seconds 秒仍未开始播放，已重新取流';
  }

  /// 当前机型 / 系统是否支持系统级画中画（iOS）。
  ///
  /// 由原生侧的 `AVPictureInPictureController.isPictureInPictureSupported()` 判定，
  /// 首次点到画中画时写入。旧机型上系统可能根本给不出这个功能，此时没必要让用户
  /// 对着一个按不动的按钮反复点，直接隐藏更诚实。
  final RxBool isIOSPipSupported = true.obs;

  /// iOS 下是否应由系统画中画接管后台播放。
  ///
  /// 画中画需要在后台继续渲染画面，因此这两种情形下不能因为「后台播放」开关
  /// 关闭而暂停播放器，否则划回主屏幕后小窗会没有画面：
  /// * 画中画已开启；
  /// * 用户开启了「后台画中画」开关（系统会在 App 进入后台时自动进入画中画）。
  bool get isIOSPipKeepingAlive {
    if (!Platform.isIOS) return false;
    return isIOSPip.value || autoPiP;
  }

  /// 是否运行在 LiveContainer 的多任务（虚拟窗口）模式里。
  ///
  /// 多任务模式下 guest App 并不在 LiveContainer 自己的进程里，而是由 `LiveProcess`
  /// 扩展拉起一个独立子进程（LC 内部正是用 `LP_HOME_PATH` 区分这两种运行方式），
  /// 画面再被托管进 LiveContainer 的场景。这种结构下 App 自己发起的系统画中画拿不到
  /// 画面，只会弹出一个小黑窗；多任务模式下的画中画由 LiveContainer 自己在多任务窗口
  /// 的标题栏菜单里提供。
  static final bool isLiveContainerMultitask =
      Platform.isIOS &&
      (Platform.environment['LP_HOME_PATH']?.isNotEmpty ?? false);

  late Rect _lastWindowBounds;
  static Rect? _lastPipBounds;

  Rect _adjustPipBounds(Rect lastRect, Size size, double aspectRatio) {
    final lastSize = lastRect.size;
    final lastOrientation = lastSize.orientation;
    final orientation = size.orientation;

    if (lastOrientation != orientation) {
      final double width, height;
      switch (orientation) {
        case .portrait:
          if (lastSize.width > size.height) {
            height = min(lastSize.width, _lastWindowBounds.size.height);
            width = height / aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
        case .landscape:
          if (lastSize.height > size.width) {
            width = lastSize.height;
            height = width / aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
      }

      return _lastPipBounds = Rect.fromLTWH(
        lastRect.left,
        lastRect.top,
        width,
        height,
      );
    }
    return lastRect;
  }

  bool updatePipBounds() {
    if (isDesktopPip) {
      windowManager.getBounds().then((rect) {
        if (isDesktopPip) _lastPipBounds = rect;
      });
      return true;
    }
    return false;
  }

  late final showWindowTitleBar = Pref.showWindowTitleBar;
  late final RxBool isAlwaysOnTop = false.obs;
  Future<void> setAlwaysOnTop(bool value) {
    isAlwaysOnTop.value = value;
    return windowManager.setAlwaysOnTop(value);
  }

  Future<void> exitDesktopPip() {
    isDesktopPip = false;
    return Future.wait([
      if (showWindowTitleBar)
        windowManager.setTitleBarStyle(TitleBarStyle.normal),
      windowManager.setMinimumSize(const Size(400, 700)),
      windowManager.setBounds(_lastWindowBounds),
      setAlwaysOnTop(false),
      windowManager.setAspectRatio(0),
    ]);
  }

  Future<void> enterDesktopPip() async {
    if (isFullScreen.value) return;

    isDesktopPip = true;

    _lastWindowBounds = await windowManager.getBounds();

    if (showWindowTitleBar) {
      windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    }

    const shortSide = 280.0;
    const minShortSide = 160.0;
    final Size size;
    final Size minimumSize;
    final state = videoPlayerController!.state;
    int width = state.width;
    int height = state.height;
    if (width == 0) width = this.width ?? 16;
    if (height == 0) height = this.height ?? 9;
    final double aspectRatio;
    if (height > width) {
      aspectRatio = height / width;
      size = Size(shortSide, shortSide * aspectRatio);
      minimumSize = Size(minShortSide, minShortSide * aspectRatio);
    } else {
      aspectRatio = width / height;
      size = Size(shortSide * aspectRatio, shortSide);
      minimumSize = Size(minShortSide * aspectRatio, minShortSide);
    }

    await windowManager.setMinimumSize(minimumSize);
    setAlwaysOnTop(true);
    if (_lastPipBounds != null) {
      windowManager.setBounds(
        _adjustPipBounds(_lastPipBounds!, size, aspectRatio),
      );
    } else {
      windowManager.setSize(size);
    }
    windowManager.setAspectRatio(width / height);
  }

  void toggleDesktopPip() {
    if (isDesktopPip) {
      exitDesktopPip();
    } else {
      enterDesktopPip();
    }
  }

  /// 是否为 iOS 画中画额外持有一份播放器引用。
  ///
  /// 进入画中画时 +1、退出时 -1，保证离开视频页后播放器不被销毁。
  bool _iosPipHold = false;

  StreamSubscription<String>? _iosPipSub;

  StreamSubscription<String>? _iosPipErrorSub;

  /// 弹幕开关变化时，同步开关小窗弹幕。
  StreamSubscription<bool>? _iosPipDanmakuSub;

  /// 已「武装」自动画中画的 videoController，避免反复下发同一设置。
  Object? _iosAutoEnterArmedFor;

  /// 上次下发的「后台画中画」开关值，与 [_iosAutoEnterArmedFor] 共同用于判重。
  bool? _iosAutoEnterArmedValue;

  /// 换源前画中画正在进行，换源后应接着播。
  bool _resumeIOSPipAfterSourceChange = false;

  void _listenIOSPip() {
    _iosPipSub ??= PictureInPicture.events.listen((event) {
      switch (event) {
        case 'start':
          isIOSPip.value = true;
          _iosPipStartedEvent = true;
          // 自动进入（划回主屏幕）时同样要占住播放器引用，否则用户随后返回
          // 上一页会把播放器一起销毁。
          if (!_iosPipHold) {
            _iosPipHold = true;
            _playerCount += 1;
          }
          break;
        case 'restore':
          // 用户点击画中画窗口的「回到 App」：若视频页已被离开，重新打开。
          isIOSPip.value = false;
          _iosPipRestoring = _restorePipPage();
          break;
        case 'stop':
          isIOSPip.value = false;
          _releaseIOSPipHold();
          // 若「后台画中画」仍开着，弹幕数据继续备着，等下一次自动进入。
          _syncIOSPipDanmaku(autoPiP);
          break;
      }
    });
    _iosPipErrorSub ??= PictureInPicture.errors.listen((message) {
      // 启动失败时把原因显示出来，便于在真机上定位问题。
      isIOSPip.value = false;
      _releaseIOSPipHold();
      // 失败后同样重新武装，让用户可以直接再试一次。
      _syncIOSAutoEnterPip(force: true);
      SmartDialog.showToast(message);
    });
    _iosPipDanmakuSub ??= enableShowDanmaku.listen((_) {
      _syncIOSPipDanmaku(isIOSPip.value || autoPiP);
    });
  }

  /// iOS：按用户设置「后台画中画」开关，武装 / 解除自动画中画。
  ///
  /// 武装后由系统在用户划回主屏幕（App 进入后台）时自动弹出画中画窗口，
  /// 无需手动点按按钮。
  void _syncIOSAutoEnterPip({bool force = false}) {
    if (!Platform.isIOS) return;
    final videoController = this.videoController;
    if (videoController == null) return;
    if (!force &&
        identical(_iosAutoEnterArmedFor, videoController) &&
        _iosAutoEnterArmedValue == autoPiP) {
      return;
    }
    _iosAutoEnterArmedFor = videoController;
    _iosAutoEnterArmedValue = autoPiP;
    _listenIOSPip();
    videoController.setAutoEnterPictureInPicture(autoPiP);
    // 自动进入画中画时同样要有弹幕，故武装阶段就把弹幕数据接上。
    if (autoPiP) {
      _syncIOSPipDanmaku(true);
    }
  }

  /// iOS 系统画中画是否应当显示弹幕。
  ///
  /// 系统小窗内的弹幕已整体移除，这里恒为 `false`。
  ///
  /// 小窗只显示原生画面图层，Flutter 画的弹幕进不去，必须在原生侧逐帧合成：每帧一次
  /// 整帧拷贝、建一个绘图上下文、再对当前可见的每条弹幕逐条绘制文字，源帧还取自
  /// OpenGL 纹理缓存。播放中这条路径每帧都在跑，长时间播放会把进程拖垮——实测单个
  /// 视频约七分钟后小窗卡死、随后新建网络连接全部失败、必须杀进程重启。因此不再向
  /// 原生侧喂弹幕，小窗只显示画面本身。
  bool get iosPipDanmakuEnabled => false;

  /// 开启 / 关闭原生侧的画中画弹幕，并同步 App 内的弹幕显示参数。
  void _syncIOSPipDanmaku(bool enabled) {
    if (!Platform.isIOS) return;
    final videoController = this.videoController;
    if (videoController == null) return;
    if (!enabled || !iosPipDanmakuEnabled) {
      unawaited(videoController.setPictureInPictureDanmakuEnabled(false));
      return;
    }
    final blockTypes = DanmakuOptions.blockTypes;
    final speed = playbackSpeed <= 0 ? 1.0 : playbackSpeed;
    unawaited(
      videoController.setPictureInPictureDanmakuConfig(<String, Object>{
        'opacity': danmakuOpacity.value,
        'fontScale': isFullScreen.value
            ? DanmakuOptions.danmakuFontScaleFS
            : DanmakuOptions.danmakuFontScale,
        'lineHeight': DanmakuOptions.danmakuLineHeight,
        'area': DanmakuOptions.danmakuShowArea,
        'duration': DanmakuOptions.danmakuDuration / speed,
        'staticDuration': DanmakuOptions.danmakuStaticDuration / speed,
        'strokeWidth': DanmakuOptions.danmakuStrokeWidth,
        'hideScroll': blockTypes.contains(2) ? 1 : 0,
        'hideTop': blockTypes.contains(5) ? 1 : 0,
        'hideBottom': blockTypes.contains(4) ? 1 : 0,
      }),
    );
    unawaited(videoController.setPictureInPictureDanmakuEnabled(true));
  }

  /// 把当前时刻的弹幕交给原生侧，用于在系统小窗里绘制。
  ///
  /// 每条弹幕带的是相对视频起点的绝对时间，因此拖动进度条后位置依然正确；
  /// 原生侧按弹幕 id 去重，重复下发不会重影。
  void feedPipDanmaku(List<DanmakuElem> elems) {
    final videoController = this.videoController;
    if (videoController == null) return;
    final items = <Map<String, Object>>[];
    for (final e in elems) {
      // 7 为高级弹幕（内容是 JSON）、8 为代码弹幕，原生侧不解析。
      if (e.mode == 7 || e.mode == 8) continue;
      final content = e.content;
      if (content.isEmpty) continue;
      items.add({
        'id': '${e.id}',
        'time': e.progress / 1000,
        'mode': e.mode,
        'color': e.color & 0xFFFFFF,
        'text': content,
      });
    }
    if (items.isEmpty) return;
    unawaited(videoController.addPictureInPictureDanmaku(items));
  }

  /// 「回到 App」后是否需要等待视频页重新挂载。
  bool _iosPipRestoring = false;

  void _releaseIOSPipHold() {
    if (!_iosPipHold) return;
    _iosPipHold = false;
    // 「回到 App」时视频页需要一点时间重新挂载；若立刻回收，会出现
    // 「页面刚打开、播放器已被销毁」。故延迟到页面挂载完成后再判断。
    if (_iosPipRestoring) {
      _iosPipRestoring = false;
      Future<void>.delayed(
        const Duration(milliseconds: 1200),
        _doReleaseIOSPipHold,
      );
      return;
    }
    _doReleaseIOSPipHold();
  }

  void _doReleaseIOSPipHold() {
    if (_playerCount > 1) {
      _playerCount -= 1;
    } else {
      // 视频页已销毁，直接回收播放器
      dispose();
    }
  }

  /// 从画中画「回到 App」时重新打开视频页。返回是否在等待页面挂载。
  bool _restorePipPage() {
    try {
      final route = Get.currentRoute;
      if (route == '/videoV' || route == '/liveRoom') {
        // 视频页仍在，系统会自行回到前台。
        return false;
      }
      // 直播没有可复用的房间号，无法还原页面。
      if (isLive) return false;
      final bvid = _bvid;
      final cid = this.cid;
      if (bvid == null || cid == null) return false;
      PageUtils.toVideoPage(
        videoType: _videoType,
        aid: _aid,
        bvid: bvid,
        cid: cid,
        seasonId: _seasonId,
        epId: _epid,
        progress: positionInMilliseconds,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// iOS 端系统级画中画。
  ///
  /// 画面由 media_kit 在 iOS 原生侧通过 `AVSampleBufferDisplayLayer` 送入系统
  /// 画中画窗口（可悬浮于其它 App 之上，切后台 / 锁屏继续播放）。
  /// 进入时额外持有一份播放器引用，保证离开视频页后播放器不被销毁，
  /// 从而实现“边看边刷”；退出时释放该引用。
  void enterIOSPip() {
    if (!Platform.isIOS) return;
    if (isFullScreen.value) {
      // 全屏（横屏）下点画中画：先退回竖屏，否则画中画弹出后应用仍停留在
      // 全屏界面。等退出全屏后再触发（最多等 1.2 秒，超时不强求）。
      triggerFullScreen(status: false);
      _enterIOSPipAfterExitFullScreen(0);
      return;
    }
    _doEnterIOSPip();
  }

  void _enterIOSPipAfterExitFullScreen(int attempt) {
    if (!isFullScreen.value || attempt >= 8) {
      _doEnterIOSPip();
      return;
    }
    Future<void>.delayed(
      const Duration(milliseconds: 150),
      () => _enterIOSPipAfterExitFullScreen(attempt + 1),
    );
  }

  /// 是否已收到原生侧的「画中画已启动」事件（用于诊断启动失败）。
  bool _iosPipStartedEvent = false;

  void _doEnterIOSPip() {
    unawaited(_doEnterIOSPipAsync());
  }

  Future<void> _doEnterIOSPipAsync() async {
    final videoController = this.videoController;
    if (videoController == null) return;
    _listenIOSPip();
    // 先问一次系统是否支持。旧机型上系统可能根本给不出画中画，此时既没必要走
    // 后面的流程，也不该让用户对着一个按不动的按钮反复点。
    if (!await videoController.isPictureInPictureSupported()) {
      isIOSPipSupported.value = false;
      SmartDialog.showToast('当前机型不支持画中画（系统判定），已隐藏该按钮');
      return;
    }
    _syncIOSPipDanmaku(true);
    if (!_iosPipHold) {
      _iosPipHold = true;
      _playerCount += 1;
    }
    _iosPipStartedEvent = false;
    isIOSPip.value = true;
    if (isLiveContainerMultitask) {
      // 宿主的窗口托管方式可能影响小窗能否拿到画面。先把话说清楚，再把原生侧的读数
      // 直接画进小窗画面——否则用户只会看到一个黑窗，无从判断卡在哪一步。
      SmartDialog.showToast('多任务模式：若小窗无画面，读数会直接显示在小窗里');
      unawaited(
        videoController
            .setPictureInPictureDebugOverlay(true)
            .catchError((_) {}),
      );
    }
    unawaited(
      videoController.setPictureInPicture(true).catchError((_) {
        isIOSPip.value = false;
        _releaseIOSPipHold();
      }),
    );
    unawaited(_checkIOSPipStart(videoController));
    if (isLiveContainerMultitask) {
      unawaited(_reportIOSPipDiagnostics(videoController));
    }
  }

  /// 启动兜底检查。
  ///
  /// 原生侧在系统判定「画面源未就绪」时会重试一段时间（约 3 秒），失败后主动报出
  /// 失败原因，正常情况下这里等不到结论。保留它，是为了兜住「系统连失败都不通知」
  /// 的极端情形——那时至少还能把诊断读数摆出来，而不是让用户面对一次无声的点击。
  Future<void> _checkIOSPipStart(VideoController videoController) async {
    await Future<void>.delayed(const Duration(seconds: 4));
    if (!isIOSPip.value || _iosPipStartedEvent) return;
    final supported = await videoController.isPictureInPictureSupported();
    if (!isIOSPip.value || _iosPipStartedEvent) return;
    isIOSPip.value = false;
    _releaseIOSPipHold();
    if (!supported) {
      isIOSPipSupported.value = false;
      SmartDialog.showToast('当前机型不支持画中画（系统判定），已隐藏该按钮');
      return;
    }
    final info = await videoController.pictureInPictureDiagnostics();
    final attempt = (info['attempt'] as num?)?.toInt() ?? 0;
    final enqueued = (info['enqueued'] as num?)?.toInt() ?? 0;
    final notReady = (info['notReady'] as num?)?.toInt() ?? 0;
    final layerStatus = info['layerStatus'] ?? '?';
    final hostAttached = info['hostAttached'] == true;
    final appState = info['appState'] ?? '?';
    SmartDialog.showToast(
      '画中画启动失败：画面源未就绪'
      '（出帧 $attempt、入队 $enqueued、图层拒收 $notReady、'
      '图层 $layerStatus、已挂入层级 $hostAttached、App $appState）',
    );
  }

  /// 真机排障：把画中画链路的诊断快照显示出来（仅多任务模式下调用）。
  ///
  /// 小窗黑屏可能断在好几处：喂帧通道根本没出帧、出帧但取不到画面、图层拒收样本、
  /// 样本已送出但系统没把画面接进小窗——四者的处理方式完全不同。这里把原生侧的
  /// 计数一次摆出来，并给出一句结论，便于直接对着读数定位。
  Future<void> _reportIOSPipDiagnostics(VideoController videoController) async {
    await Future<void>.delayed(const Duration(seconds: 6));
    if (!isIOSPip.value) return;
    final info = await videoController.pictureInPictureDiagnostics();
    if (info.isEmpty) return;
    int read(String key) => (info[key] as num?)?.toInt() ?? 0;
    final attempt = read('attempt');
    final enqueued = read('enqueued');
    final notReady = read('notReady');
    final throttled = read('throttled');
    final copyNil = read('copyNil');
    final ticks = read('timerTicks');
    final resumeFlush = read('resumeFlush');
    final sinceShow = (info['sinceShow'] as num?)?.toDouble() ?? -1;
    final layerStatus = info['layerStatus'] ?? '?';
    final layerReady = info['layerReady'] == true;
    final hostAttached = info['hostAttached'] == true;
    final appState = info['appState'] ?? '?';
    final audioActive = info['audioActive'] == true;
    final audioOther = info['audioOtherPlaying'] == true;
    final hostOrigin = info['hostOrigin'] ?? '?';
    final windowBounds = info['windowBounds'] ?? '?';

    final String verdict;
    if (enqueued == 0 && attempt == 0 && ticks > 0) {
      verdict = '补帧通道在跑，却始终取不到画面';
    } else if (enqueued == 0 && copyNil > 0) {
      verdict = '渲染回调在跑，但取不到像素缓冲（$copyNil 次）';
    } else if (enqueued == 0 && notReady > 0) {
      verdict = '图层一直拒收样本（$notReady 次）';
    } else if (enqueued == 0) {
      verdict = '没有任何画面帧可送';
    } else {
      verdict = '画面帧已送达图层 $enqueued 次，小窗仍无画面 → 系统采样环节';
    }

    final detail =
        '结论：$verdict\n\n'
        '画面帧　出帧 $attempt / 入队 $enqueued / 取帧失败 $copyNil\n'
        '图层　　$layerStatus，可收帧 $layerReady，拒收 $notReady 次\n'
        '恢复冲洗 $resumeFlush 次（后台态下若不为 0，说明图层原本处于需清理才能恢复解码的状态）\n'
        '补帧通道　触发 $ticks 次'
        '（小窗已显示 ${sinceShow < 0 ? '?' : sinceShow.toStringAsFixed(1)} 秒）\n'
        '降频丢弃 $throttled 次\n'
        '画面源　已挂入层级 $hostAttached，落点 $hostOrigin，窗口 $windowBounds\n'
        'App 状态　$appState　·　音频会话活跃 $audioActive'
        '（另有音频在播放 $audioOther）';

    await SmartDialog.show(
      animationType: SmartAnimationType.centerFade_otherSlide,
      builder: (context) => AlertDialog(
        title: const Text('小窗诊断'),
        content: SingleChildScrollView(child: Text(detail)),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: detail));
              SmartDialog.showToast('已复制');
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => SmartDialog.dismiss(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void exitIOSPip() {
    if (!Platform.isIOS) return;
    isIOSPip.value = false;
    _syncIOSPipDanmaku(autoPiP);
    videoController?.setPictureInPicture(false);
    _releaseIOSPipHold();
    // 关掉小窗并不等于放弃画中画能力：重新武装一次，保证下一次点按钮或划回
    // 主屏幕时系统仍然能立刻拿到画面（否则第二次进入的小窗会是黑屏）。
    _syncIOSAutoEnterPip(force: true);
  }

  void toggleIOSPip() {
    if (!Platform.isIOS) return;
    if (isIOSPip.value) {
      exitIOSPip();
    } else {
      enterIOSPip();
    }
  }

  late bool _isAutoEnterPip = false;
  bool get isAutoEnterPip => _isAutoEnterPip;

  static bool get _isCurrVideoPage {
    final routing = Get.routing;
    if (routing.route is! GetPageRoute) {
      return false;
    }
    return _isVideoPage(routing.current);
  }

  static bool _isVideoPage(String routeName) {
    return routeName == '/videoV' || routeName == '/liveRoom';
  }

  void enterPip({bool autoEnter = false}) {
    if (videoPlayerController case NativePlayer(:final state)) {
      PageUtils.enterPip(
        autoEnter: autoEnter,
        width: state.width == 0 ? width : state.width,
        height: state.height == 0 ? height : state.height,
        isLive: isLive,
        isPlaying: playerStatus.isPlaying,
      );
    }
  }

  void _disableAutoEnterPip() {
    if (_isAutoEnterPip) {
      PiliAndroidHelper.disableAutoEnterPip();
    }
  }

  // 弹幕相关配置
  late final enableTapDm = PlatformUtils.isMobile && Pref.enableTapDm;
  late RuleFilter filters = Pref.danmakuFilterRule;
  // 关联弹幕控制器
  DanmakuController<DanmakuExtra>? danmakuController;
  bool showDanmaku = true;
  Set<int> dmState = <int>{};
  late final mergeDanmaku = Pref.mergeDanmaku;
  late final String midHash = getCrc32(
    ascii.encode(Accounts.main.mid.toString()),
    0,
  ).toRadixString(16);
  late final RxDouble danmakuOpacity = Pref.danmakuOpacity.obs;

  late List<double> speedList = Pref.speedList;
  late bool enableAutoLongPressSpeed = Pref.enableAutoLongPressSpeed;
  late final showControlDuration = Pref.enableLongShowControl
      ? const Duration(seconds: 30)
      : const Duration(seconds: 3);
  // 字幕
  late double subtitleFontScale = Pref.subtitleFontScale;
  late double subtitleFontScaleFS = Pref.subtitleFontScaleFS;
  late int subtitlePaddingH = Pref.subtitlePaddingH;
  late int subtitlePaddingB = Pref.subtitlePaddingB;
  late double subtitleBgOpacity = Pref.subtitleBgOpacity;
  final bool showVipDanmaku = Pref.showVipDanmaku; // loop unswitching
  late double subtitleStrokeWidth = Pref.subtitleStrokeWidth;
  late int subtitleFontWeight = Pref.subtitleFontWeight;

  // settings
  late final showFSActionItem = Pref.showFSActionItem;
  late final enableShrinkVideoSize = Pref.enableShrinkVideoSize;
  late final darkVideoPage = Pref.darkVideoPage;
  late final enableSlideVolumeBrightness = Pref.enableSlideVolumeBrightness;
  late final enableSlideFS = Pref.enableSlideFS;
  late final enableDragSubtitle = Pref.enableDragSubtitle;
  late final fastForBackwardDuration = Duration(
    seconds: Pref.fastForBackwardDuration,
  );

  late final horizontalSeasonPanel = Pref.horizontalSeasonPanel;
  late final preInitPlayer = Pref.preInitPlayer;
  late final showRelatedVideo = Pref.showRelatedVideo;
  late final showVideoReply = Pref.showVideoReply;
  late final showBangumiReply = Pref.showBangumiReply;
  late final reverseFromFirst = Pref.reverseFromFirst;
  late final horizontalPreview = Pref.horizontalPreview;
  late final showDmChart = Pref.showDmChart;
  late final showViewPoints = Pref.showViewPoints;
  late final showFsScreenshotBtn = Pref.showFsScreenshotBtn;
  late final showFsLockBtn = Pref.showFsLockBtn;
  late final keyboardControl = Pref.keyboardControl;
  late final uiScale = Pref.uiScale;

  late final bool autoEnterFullScreen = Pref.autoEnterFullScreen;
  late final bool autoExitFullscreen = Pref.autoExitFullscreen;
  late final bool autoPlayEnable = Pref.autoPlayEnable;
  late final bool enableVerticalExpand = Pref.enableVerticalExpand;
  late final bool pipNoDanmaku = Pref.pipNoDanmaku;

  late final bool tempPlayerConf = Pref.tempPlayerConf;

  late int? cacheVideoQa = PlatformUtils.isMobile ? null : Pref.defaultVideoQa;
  late int cacheAudioQa = Pref.defaultAudioQa;
  bool enableHeart = true;
  late final String? hwdec = Pref.enableHA ? Pref.hardwareDecoding : null;

  late final progressType = Pref.btmProgressBehavior;
  late final enableQuickDouble = Pref.enableQuickDouble;
  late final fullScreenGestureReverse = Pref.fullScreenGestureReverse;

  late final isRelative = Pref.useRelativeSlide;
  late final offset = isRelative
      ? Pref.sliderDuration / 100
      : Pref.sliderDuration * 1000;

  num get sliderScale => isRelative ? durationInMilliseconds * offset : offset;

  // 播放顺序相关
  late PlayRepeat playRepeat = Pref.playRepeat;

  TextStyle get subTitleStyle => TextStyle(
    height: 1.5,
    fontSize:
        16 * (isFullScreen.value ? subtitleFontScaleFS : subtitleFontScale),
    letterSpacing: 0.1,
    wordSpacing: 0.1,
    color: Colors.white,
    fontWeight: FontWeight.values[subtitleFontWeight],
    backgroundColor: subtitleBgOpacity == 0
        ? null
        : Colors.black.withValues(alpha: subtitleBgOpacity),
  );

  late final Rx<SubtitleViewConfiguration> subtitleConfig = getSubConfig.obs;

  SubtitleViewConfiguration get getSubConfig {
    final subTitleStyle = this.subTitleStyle;
    return SubtitleViewConfiguration(
      style: subTitleStyle,
      strokeStyle: subtitleBgOpacity == 0
          ? subTitleStyle.copyWith(
              color: null,
              background: null,
              backgroundColor: null,
              foreground: Paint()
                ..color = Colors.black
                ..style = PaintingStyle.stroke
                ..strokeWidth = subtitleStrokeWidth,
            )
          : null,
      padding: EdgeInsets.only(
        left: subtitlePaddingH.toDouble(),
        right: subtitlePaddingH.toDouble(),
        bottom: subtitlePaddingB.toDouble(),
      ),
      textScaleFactor: 1,
    );
  }

  void updateSubtitleStyle() {
    subtitleConfig.value = getSubConfig;
  }

  void onUpdatePadding(EdgeInsets padding) {
    subtitlePaddingB = padding.bottom.round().clamp(0, 200);
    putSubtitleSettings();
  }

  static PlPlayerController? get instance => _instance;

  static bool instanceExists() {
    return _instance != null;
  }

  static void setPlayCallBack(PlayCallback? playCallBack) {
    _playCallBack = playCallBack;
  }

  static PlayCallback? _playCallBack;

  static Future<void>? playIfExists() {
    return _playCallBack?.call();
  }

  // try to get PlayerStatus
  static PlayerStatus? getPlayerStatusIfExists() {
    return _instance?.playerStatus;
  }

  static Future<void>? pauseIfExists({
    bool notify = true,
    bool isInterrupt = false,
  }) {
    if (_instance?.playerStatus.isPlaying ?? false) {
      return _instance?.pause(notify: notify, isInterrupt: isInterrupt);
    }
    return null;
  }

  static Future<void>? seekToIfExists(
    Duration position, {
    bool isSeek = true,
  }) {
    return _instance?.seekTo(position, isSeek: isSeek);
  }

  static double? getVolumeIfExists() {
    return _instance?.volume.value;
  }

  static Future<void>? setVolumeIfExists(
    double volumeNew, {
    bool showIndicator = true,
  }) {
    return _instance?.setVolume(volumeNew, showIndicator: showIndicator);
  }

  Box video = GStorage.video;

  bool visible = true;

  DeviceOrientation? _orientation;
  late final checkIsAutoRotate = Platform.isAndroid && mode != .gravity;
  StreamSubscription<OrientationParams>? _orientationListener;

  void _stopOrientationListener() {
    _orientationListener?.cancel();
    _orientationListener = null;
  }

  void _onOrientationChanged(OrientationParams param) {
    _orientation = param.orientation;
    if (Platform.isIOS && !visible) return;
    final orientation = param.orientation;
    final isFullScreen = this.isFullScreen.value;
    if (checkIsAutoRotate &&
        param.isAutoRotate != true &&
        (!isFullScreen ||
            _isVertical ||
            orientation == .portraitUp ||
            orientation == .portraitDown)) {
      return;
    }
    switch (orientation) {
      case .portraitUp:
        if (!_isVertical && controlsLock.value) return;
        if (!horizontalScreen && !_isVertical && isFullScreen) {
          if (!isManualFS) {
            triggerFullScreen(status: false, orientation: orientation);
          }
        } else {
          portraitUpMode();
        }
      case .portraitDown:
        if (!horizontalScreen) return;
        if (!_isVertical && controlsLock.value) return;
        portraitDownMode();
      case .landscapeLeft:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeLeftMode();
        }
      case .landscapeRight:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeRightMode();
        }
    }
  }

  // 添加一个私有构造函数
  PlPlayerController._() {
    if (PlatformUtils.isMobile) {
      _orientationListener = NativeDeviceOrientationPlatform.instance
          .onOrientationChanged(
            checkIsAutoRotate: checkIsAutoRotate,
            angleDegrees: Platform.isAndroid ? Pref.angleDegrees : null,
          )
          .listen(_onOrientationChanged);
    }

    if (!Accounts.heartbeat.isLogin || Pref.historyPause) {
      enableHeart = false;
    }

    if (Platform.isAndroid && autoPiP) {
      if (DeviceUtils.sdkInt < 31) {
        AndroidHelper$ToDart.onUserLeaveHint = Runnable.implement(
          $Runnable(run: _onUserLeaveHint),
        );
      } else {
        _isAutoEnterPip = true;
      }
    }
  }

  void _onUserLeaveHint() {
    if (playerStatus.isPlaying && _isCurrVideoPage) {
      enterPip();
    }
  }

  // 获取实例 传参
  static PlPlayerController getInstance({bool isLive = false}) {
    // 如果实例尚未创建，则创建一个新实例
    return (_instance ??= PlPlayerController._())
      ..isLive = isLive
      .._playerCount += 1;
  }

  bool _processing = false;
  bool get processing => _processing;

  // offline
  bool get isFileSource => dataSource is FileSource;

  // 初始化资源
  Future<void> setDataSource(
    DataSource dataSource, {
    bool isLive = false,
    bool autoplay = true,
    // 初始化播放位置
    Duration? seekTo,
    // 初始化播放速度
    double speed = 1.0,
    int? width,
    int? height,
    Duration? duration,
    // 方向
    bool? isVertical,
    // 记录历史记录
    int? aid,
    String? bvid,
    int? cid,
    int? epid,
    int? seasonId,
    int? pgcType,
    VideoType? videoType,
    VoidCallback? onInit,
    Volume? volume,
    bool autoFullScreenFlag = false,
  }) async {
    try {
      // 连播下一集、换源、切清晰度都会走到这里。此时若画中画正在进行，不能把
      // 小窗丢掉——在小窗里一路往下看正是这个功能的主要用法。这里只通知原生侧
      // 清掉上一集的残留（图层内容、时间轴、弹幕），小窗会在新视频第一帧到来后
      // 无缝接上，而不是停在黑屏。
      // 换源即重置拉流诊断：controller 是单例，不重置会把上一个视频的
      // 错误原文和重取计数带过来，看门狗的上限也会被提前用掉。但计数只在**换集**
      // 时归零——同一集重新取流必须保留计数，否则「换节点到上限 → 重新取流 →
      // 计数归零 → 又开始换节点」会互相清空，两边都到不了上限。
      mediaError.value = '';
      urlFixNote.value = VideoUtils.urlFixNote.value;
      _volumeNorm = volume;
      final retryKey = '${bvid ?? ''}|${cid ?? ''}|${aid ?? ''}|${epid ?? ''}';
      if (_mediaRetryKey != retryKey) {
        _mediaRetryKey = retryKey;
        mediaStallRetry.value = 0;
        cdnSwitchCount.value = 0;
        cdnSwitchNote.value = '';
        episodeSwitchNote.value = '';
        queryNote.value = '';
      }
      if (Platform.isIOS) {
        if (isIOSPip.value) {
          _resumeIOSPipAfterSourceChange = true;
        }
        final pipVideoController = videoController;
        if (pipVideoController != null) {
          unawaited(pipVideoController.preparePictureInPictureForNewMedia());
        }
      }
      _processing = true;
      this.isLive = isLive;
      _videoType = videoType ?? VideoType.ugc;
      this.width = width;
      this.height = height;
      this.dataSource = dataSource;
      _autoPlay = autoplay;
      // 初始化数据加载状态
      dataStatus.value = DataStatus.loading;
      // 初始化全屏方向
      _isVertical = isVertical ?? false;
      _aid = aid;
      _bvid = bvid;
      this.cid = cid;
      _epid = epid;
      _seasonId = seasonId;
      _pgcType = pgcType;

      if (showSeekPreview) {
        _clearPreview();
      }
      cancelLongPressTimer();
      if (_videoPlayerController != null &&
          _videoPlayerController!.state.playing) {
        await pause(notify: false);
      }

      if (_playerCount == 0) {
        return;
      }
      // 配置Player 音轨、字幕等等
      await _createVideoController(dataSource, seekTo, volume);

      if (_playerCount == 0) {
        _removeListeners();
        _videoPlayerController?.dispose();
        _videoPlayerController = null;
        _videoController = null;
        return;
      }

      updateDuration(duration ?? _videoPlayerController!.state.duration);
      position.value = buffered.value = seekTo?.inSeconds ?? 0;

      dataStatus.value = .loaded;

      if (autoFullScreenFlag && autoEnterFullScreen) {
        triggerFullScreen(status: true);
      }

      await _initializePlayer();
      onInit?.call();
    } catch (err, stackTrace) {
      dataStatus.value = DataStatus.error;
      if (kDebugMode) {
        debugPrint(stackTrace.toString());
        debugPrint('plPlayer err:  $err');
      }
    } finally {
      _processing = false;
    }
  }

  String? shadersDirPath;
  Future<String> get copyShadersToExternalDirectory async {
    if (shadersDirPath != null) {
      return shadersDirPath!;
    }

    return shadersDirPath = await AssetUtils.getOrCopy(
      'assets/shaders',
      Assets.mpvAnime4KShaders.followedBy(Assets.mpvAnime4KShadersLite),
      path.join(appSupportDirPath, 'anime_shaders'),
    );
  }

  late final isAnim = _pgcType == 1 || _pgcType == 4;
  late final Rx<SuperResolutionType> superResolutionType =
      (isAnim ? Pref.superResolutionType : SuperResolutionType.disable).obs;
  Future<void> setShader([SuperResolutionType? type, NativePlayer? pp]) async {
    if (type == null) {
      type = superResolutionType.value;
    } else {
      superResolutionType.value = type;
      if (isAnim && !tempPlayerConf) {
        setting.put(SettingBoxKey.superResolutionType, type.index);
      }
    }
    pp ??= _videoPlayerController!;
    switch (type) {
      case SuperResolutionType.disable:
        return pp.command(const ['change-list', 'glsl-shaders', 'clr', '']);
      case SuperResolutionType.efficiency:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShadersLite,
          ),
        ]);
      case SuperResolutionType.quality:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShaders,
          ),
        ]);
    }
  }

  Future<Player> _initPlayer() async {
    assert(_videoPlayerController == null);
    final opt = {
      'video-sync': Pref.videoSync,
      if (Platform.isAndroid) 'ao': Pref.audioOutput,
      'volume':
          (PlatformUtils.isMobile ? Pref.playerVolume : volume.value * 100)
              .toString(),
    };
    final autosync = Pref.autosync;
    if (autosync != '0') {
      opt['autosync'] = autosync;
    }

    final player = await Player.create(
      configuration: PlayerConfiguration(
        logLevel: kDebugMode ? .warn : .error,
        options: opt,
      ),
    );

    assert(_videoController == null);

    _videoController = await VideoController.create(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: hwdec != null,
        androidAttachSurfaceAfterVideoParameters: false,
        hwdec: hwdec,
      ),
    );

    player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);

    _startListeners(player);

    return player;
  }

  late final buffer = Pref.initBuffer(_playbackSpeed.value);
  late final liveBuffer = Pref.initLiveBuffer();

  // 配置播放器
  Future<void> _createVideoController(
    DataSource dataSource,
    Duration? seekTo,
    Volume? volume,
  ) async {
    isBuffering.value = false;
    _heartDuration = 0;
    danmakuController?.clear();
    if (Platform.isIOS) {
      final pipVideoController = videoController;
      if (pipVideoController != null) {
        unawaited(pipVideoController.clearPictureInPictureDanmaku());
      }
    }

    var player = _videoPlayerController;

    if (player == null) {
      player = await _initPlayer();
      if (_playerCount == 0) {
        _removeListeners();
        player.dispose();
        player = null;
        _videoController = null;
        return;
      }
      _videoPlayerController = player;
      if (isAnim && superResolutionType.value != .disable) {
        await setShader();
      }
    }

    final Map<String, String> extras = {
      if (dataSource is FileSource)
        'cache': 'no'
      else if (isLive)
        ...liveBuffer
      else
        ...buffer,
    };

    String video = dataSource.videoSource;
    if (dataSource.audioSource case final audio? when (audio.isNotEmpty)) {
      if (onlyPlayAudio.value) {
        video = audio;
      } else {
        // dely_open need provide length
        video =
            ('edl://'
            '!no_chapters;'
            // '!delay_open,media_type=video;'
            '%${isFileSource ? utf8.encode(video).length : video.length}%$video;'
            '!new_stream;!no_chapters;'
            // '!delay_open,media_type=audio;'
            '%${isFileSource ? utf8.encode(audio).length : audio.length}%$audio');
      }
      audioFilterExtras(volume, map: extras);
    }

    assert(!isLive || seekTo == null);
    await player.open(
      Media(
        video,
        start: seekTo,
        extras: extras.isEmpty ? null : extras,
      ),
      play: false,
    );
  }

  Future<void>? refreshPlayer() {
    if (dataSource is FileSource) {
      return null;
    }
    if (_videoPlayerController case final ctr? when (ctr.current.isNotEmpty)) {
      var media = ctr.current.last;
      if (!isLive) media = media.copyWith(start: ctr.state.position);
      return ctr.open(media, play: true);
    }
    return null;
  }

  /// 拉流失败时，把地址换到另一个 CDN 节点重开。
  ///
  /// 默认的 CDN 设置是「备用URL」，也就是照搬接口下发的那个机房；那个机房连不上时
  /// 重新取流也好、[refreshPlayer] 也好都只是在原地重开同一个地址。换主机名是这台
  /// 设备自己就能做完的一步：各镜像吃的是同一份内容，路径与签名参数与主机名无关。
  ///
  /// 返回 `false` 表示这条路也不适用（地址形态不支持轮换、次数已用满、或正在换），
  /// 调用方应当转去别的自愈手段。
  Future<bool> switchMirror() async {
    if (_switchingMirror) return false;
    if (isFileSource) return false;
    if (_videoPlayerController == null) return false;
    if (cdnSwitchCount.value >= maxCdnSwitch) return false;
    final src = dataSource;
    if (src is! NetworkSource) return false;

    final video = VideoUtils.nextMirrorUrl(src.videoSource);
    if (video == null) return false;
    final audioSource = src.audioSource;
    final audio = audioSource == null || audioSource.isEmpty
        ? audioSource
        : VideoUtils.nextMirrorUrl(audioSource);

    _switchingMirror = true;
    try {
      final next = NetworkSource(videoSource: video, audioSource: audio);
      dataSource = next;
      // 换节点重开绕过了 setDataSource 的收尾，而原生侧那两件事只能在
      // setDataSource 里做，这里必须补上，否则小窗会停在旧图层的旧时间轴上。
      if (Platform.isIOS) {
        if (isIOSPip.value) {
          _resumeIOSPipAfterSourceChange = true;
        }
        final pipVideoController = videoController;
        if (pipVideoController != null) {
          unawaited(pipVideoController.preparePictureInPictureForNewMedia());
        }
      }
      cdnSwitchCount.value += 1;
      var host = '';
      try {
        host = Uri.parse(video).host;
      } catch (_) {}
      cdnSwitchNote.value = '已换 CDN 节点（第 ${cdnSwitchCount.value} 次）：$host';
      if (kDebugMode) {
        debugPrint('switchMirror -> $host');
      }
      // 这条路径不经过 setDataSource 的收尾，没人替它续播。
      final seekTo = _videoPlayerController!.state.position;
      await _createVideoController(next, seekTo, _volumeNorm);
      await playIfExists();
      return true;
    } finally {
      _switchingMirror = false;
    }
  }

  /// 拉流完全打不开时的自愈：先换 CDN 节点，换不动再原地重开。
  Future<void> _recoverUnreachableMedia() async {
    if (!await switchMirror()) {
      await refreshPlayer();
    }
  }

  // 开始播放
  Future<void> _initializePlayer() async {
    if (_instance == null) return;
    // 设置倍速
    if (_videoPlayerController != null) {
      final speed = isLive ? 1.0 : playbackSpeed;
      if (_videoPlayerController!.state.rate != speed) {
        await setPlaybackSpeed(speed);
      }
    }
    _initVideoFit();

    // 自动播放
    if (_autoPlay) {
      playIfExists();
    } else if (_resumeIOSPipAfterSourceChange) {
      // 画中画里连播下一集：上层未必要求自动播放，但小窗不能停在暂停态，
      // 否则用户得先在系统小窗上点一下播放键才能继续。
      playIfExists();
    }
    _resumeIOSPipAfterSourceChange = false;
  }

  List<StreamSubscription>? _subscriptions;
  final Set<ValueChanged<Duration>> _positionListeners = {};
  final Set<ValueChanged<PlayerStatus>> _statusListeners = {};

  Timer? _wakeLockTimer;

  void _startWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = Timer(
      const Duration(milliseconds: 500),
      _stopWakeLock,
    );
  }

  void _stopWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = null;
  }

  void _stopWakeLock() {
    WakelockPlus.disable();
    _updatePlaybackState(debugLabel: 'onVideoPaused');
  }

  void _updatePlaybackState({Duration? position, String? debugLabel}) {
    videoPlayerServiceHandler?.onUpdateState(
      playerStatus,
      isBuffering.value,
      isLive,
      position: position ?? _videoPlayerController!.state.position,
      speed: playbackSpeed,
      debugLabel: debugLabel,
    );
  }

  /// 播放事件监听
  void _startListeners(NativePlayer player) {
    assert(_subscriptions == null);
    final stream = player.stream;
    _subscriptions = [
      /// playing
      stream.playing.listen((bool playing) {
        if (playing) {
          playerStatus = .playing;
          _stopWakeLockTimer();
          _updatePlaybackState();
          WakelockPlus.enable();
          _syncIOSAutoEnterPip();

          if (_isAutoEnterPip) {
            if (_isCurrVideoPage) {
              enterPip(autoEnter: true);
            } else {
              _disableAutoEnterPip();
            }
          }
        } else {
          playerStatus = .paused;
          _startWakeLockTimer();
          _disableAutoEnterPip();
        }

        for (final element in _statusListeners) {
          element(playing ? .playing : .paused);
        }

        final seconds = videoPlayerController!.state.position.inSeconds;
        if (seconds != 0) {
          makeHeartBeat(seconds, type: .status);
        }
      }),

      ///completed
      stream.completed.listen((bool completed) {
        if (completed) {
          playerStatus = .completed;
          _startWakeLockTimer();

          for (final element in _statusListeners) {
            element(.completed);
          }

          makeHeartBeat(-1, type: .completed);
        }
      }),

      /// position
      stream.position.listen((Duration position) {
        final posInSeconds = position.inSeconds;

        if (posInSeconds != this.position.value) {
          if (posInSeconds == 0 && playerStatus.isPlaying) {
            _updatePlaybackState(position: position);
          }

          this.position.value = posInSeconds;

          makeHeartBeat(posInSeconds);
        }

        for (final element in _positionListeners) {
          element(position);
        }
      }),
      stream.duration.listen(updateDuration),
      stream.buffer.listen((Duration buffer) {
        buffered.value = buffer.inSeconds;
      }),
      stream.buffering.listen((bool buffering) {
        isBuffering.value = buffering;
        if (!playerStatus.isCompleted) {
          _stopWakeLockTimer();
          _updatePlaybackState();
        }
      }),
      if (kDebugMode)
        stream.log.listen(((PlayerLog log) {
          if (log.level == 'error' || log.level == 'fatal') {
            Utils.reportError(
              '${log.level}: ${log.prefix}: ${log.text}\n${player.state.playlist}',
              null,
            );
          } else {
            debugPrint(log.toString());
          }
        })),
      stream.error.listen((String event) {
        // 先记下来源原文，再走下面那些分支（它们会把事件消化掉，
        // 只有在这一层还留着全貌，供「加载中」处展示）。
        mediaError.value = event.length > 200
            ? '${event.substring(0, 200)}…'
            : event;
        if (dataSource is FileSource &&
            event.startsWith("Failed to open file")) {
          return;
        }
        if (isLive) {
          if (event.startsWith('tcp: ffurl_read returned ') ||
              event.startsWith("Failed to open https://") ||
              event.startsWith("Can not open external file https://")) {
            Timer(const Duration(milliseconds: 3000), refreshPlayer);
          }
          return;
        }
        if (event.startsWith("Failed to open https://") ||
            event.startsWith("Can not open external file https://") ||
            //tcp: ffurl_read returned 0xdfb9b0bb
            //tcp: ffurl_read returned 0xffffff99
            event.startsWith('tcp: ffurl_read returned ')) {
          EasyThrottle.throttle(
            'controllerStream.error.listen',
            const Duration(milliseconds: 10000),
            () {
              Timer(const Duration(milliseconds: 3000), () {
                // if (kDebugMode) {
                //   debugPrint("isBuffering.value: ${isBuffering.value}");
                // }
                // if (kDebugMode) {
                //   debugPrint("_buffered.value: ${_buffered.value}");
                // }
                if (isBuffering.value && buffered.value == 0) {
                  SmartDialog.showToast(
                    '视频链接打开失败，重试中',
                    displayTime: const Duration(milliseconds: 500),
                  );
                  // 先换 CDN 节点：不花接口调用，而且真能换掉连不上的那一头；
                  // 换不动（地址形态不适合轮换、次数已用满）才退回原地重开。
                  unawaited(_recoverUnreachableMedia());
                }
              });
            },
          );
        } else if (event.startsWith('Could not open codec')) {
          SmartDialog.showToast('无法加载解码器, $event，可能会切换至软解');
        } else if (!onlyPlayAudio.value) {
          if (event.startsWith("error running") ||
              event.startsWith("Failed to open .") ||
              event.startsWith("Cannot open") ||
              event.startsWith("Can not open")) {
            return;
          }
          if (!kDebugMode) {
            Utils.reportError('$event\n${player.state.playlist}');
          }
          // SmartDialog.showToast('视频加载错误, $event');
        }
      }),
    ];
  }

  /// 移除事件监听
  void _removeListeners() {
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
  }

  void _cancelSubForSeek() {
    if (_subForSeek != null) {
      _subForSeek!.cancel();
      _subForSeek = null;
    }
  }

  Future<void> seek(Duration position, {bool isSeek = false}) async {
    if (isSeek) {
      /// 拖动进度条调节时，不等待第一帧，防止抖动
      await _videoPlayerController?.stream.buffer.first;
    }
    danmakuController?.clear();
    try {
      await _videoPlayerController?.seek(position);
    } catch (e) {
      if (kDebugMode) debugPrint('seek failed: $e');
    }
  }

  /// 跳转至指定位置
  Future<void> seekTo(Duration position, {bool isSeek = true}) async {
    if (_playerCount == 0) {
      return;
    }
    if (position < Duration.zero) {
      position = Duration.zero;
    }
    _heartDuration = position.inSeconds;

    if (duration.value != 0) {
      seek(position, isSeek: isSeek);
    } else {
      // if (kDebugMode) debugPrint('seek duration else');
      _subForSeek?.cancel();
      _subForSeek = duration.listen((_) {
        seek(position, isSeek: isSeek);
        _cancelSubForSeek();
      });
    }
  }

  /// 设置倍速
  Future<void> setPlaybackSpeed(double speed) async {
    lastPlaybackSpeed = playbackSpeed;

    if (speed == _videoPlayerController?.state.rate) return;

    await _videoPlayerController?.setRate(speed);
    if (!isLive) _playbackSpeed.value = speed;
    _updatePlaybackState();
    if (danmakuController != null) {
      try {
        danmakuController?.updateOption(
          danmakuController!.option.copyWith(
            duration: DanmakuOptions.danmakuDuration / speed,
            staticDuration: DanmakuOptions.danmakuStaticDuration / speed,
          ),
        );
      } catch (_) {}
    }
  }

  /// 播放视频
  Future<void> play({bool repeat = false, bool hideControls = true}) async {
    if (_playerCount == 0) return;
    // 播放时自动隐藏控制条
    controls = !hideControls;
    // repeat为true，将从头播放
    if (repeat) {
      await seekTo(Duration.zero, isSeek: false);
    }

    await _videoPlayerController?.play();

    audioSessionHandler?.setActive(true);

    playerStatus = .playing;
  }

  /// 暂停播放
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    await _videoPlayerController?.pause();
    playerStatus = .paused;

    // 主动暂停时让出音频焦点
    if (!isInterrupt) {
      audioSessionHandler?.setActive(false);
    }
  }

  bool tripling = false;

  /// 隐藏控制条
  void hideTaskControls() {
    _timer?.cancel();
    _timer = Timer(showControlDuration, () {
      if (!isSeeking.value && !tripling) {
        controls = false;
      }
      _timer = null;
    });
  }

  void onSeekStart(int seekFrom) {
    seekPosition.value = seekFrom;
    isSeeking.value = true;
  }

  void onSeekEnd() {
    if (showSeekPreview) {
      showPreview.value = false;
    }
    hasToasted = false;
    isSeeking.value = false;
    hideTaskControls();
  }

  final RxBool volumeIndicator = false.obs;
  Timer? volumeTimer;
  bool volumeInterceptEventStream = false;

  final double maxVolume = PlatformUtils.isDesktop ? Pref.maxVolume : 1.0;
  Future<void> setVolume(double volume, {bool showIndicator = true}) async {
    if (this.volume.value != volume) {
      this.volume.value = volume;
      try {
        if (PlatformUtils.isDesktop) {
          await _videoPlayerController!.setVolume(volume * 100);
        } else {
          FlutterVolumeController.updateShowSystemUI(false);
          await FlutterVolumeController.setVolume(volume);
        }
      } catch (err) {
        if (kDebugMode) debugPrint(err.toString());
      }
    }
    if (showIndicator) {
      volumeIndicator.value = true;
    }
    volumeInterceptEventStream = true;
    volumeTimer?.cancel();
    volumeTimer = Timer(const Duration(milliseconds: 200), () {
      volumeIndicator.value = false;
      volumeInterceptEventStream = false;
      if (PlatformUtils.isDesktop) {
        setting.put(SettingBoxKey.desktopVolume, volume.toPrecision(3));
      }
    });
  }

  /// Toggle Change the videofit accordingly
  void toggleVideoFit(VideoFitType value) {
    _prefFit = videoFit.value = value;
    video.put(VideoBoxKey.cacheVideoFit, value.index);
  }

  /// 读取fit
  var _prefFit = VideoFitType.values[Pref.cacheVideoFit];
  void _initVideoFit() {
    if (_prefFit == .fill && _isVertical) {
      videoFit.value = .contain;
    } else {
      videoFit.value = _prefFit;
    }
  }

  /// 设置后台播放
  void setBackgroundPlay(bool val) {
    videoPlayerServiceHandler?.enableBackgroundPlay = val;
    if (!tempPlayerConf) {
      setting.put(SettingBoxKey.enableBackgroundPlay, val);
    }
  }

  set controls(bool visible) {
    showControls.value = visible;
    _timer?.cancel();
    if (visible) {
      hideTaskControls();
    }
  }

  Timer? longPressTimer;
  void cancelLongPressTimer() {
    longPressTimer?.cancel();
    longPressTimer = null;
  }

  /// 设置长按倍速状态 live模式下禁用
  Future<void> setLongPressStatus(bool val) async {
    if (isLive) {
      return;
    }
    if (controlsLock.value) {
      return;
    }
    if (longPressStatus.value == val) {
      return;
    }
    if (val) {
      if (playerStatus.isPlaying) {
        longPressStatus.value = val;
        HapticFeedback.lightImpact();
        await setPlaybackSpeed(
          enableAutoLongPressSpeed ? playbackSpeed * 2 : longPressSpeed,
        );
      }
    } else {
      // if (kDebugMode) debugPrint('$playbackSpeed');
      longPressStatus.value = val;
      await setPlaybackSpeed(lastPlaybackSpeed);
    }
  }

  bool get isCompleted =>
      videoPlayerController!.state.completed ||
      durationInMilliseconds - positionInMilliseconds <= 50;

  // 双击播放、暂停
  Future<void> onDoubleTapCenter() async {
    if (!isLive && isCompleted) {
      await videoPlayerController!.seek(Duration.zero);
      videoPlayerController!.play();
    } else {
      videoPlayerController!.playOrPause();
    }
  }

  final RxBool mountSeekBackwardButton = false.obs;
  final RxBool mountSeekForwardButton = false.obs;

  void onDoubleTapSeekBackward() {
    mountSeekBackwardButton.value = true;
  }

  void onDoubleTapSeekForward() {
    mountSeekForwardButton.value = true;
  }

  void onForward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position + duration);
  }

  void onBackward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position - duration);
  }

  void onForwardBackward(Duration duration) {
    seekTo(
      duration.clamp(Duration.zero, videoPlayerController!.state.duration),
      isSeek: false,
    ).whenComplete(play);
  }

  void doubleTapFuc(DoubleTapType type) {
    if (!enableQuickDouble) {
      onDoubleTapCenter();
      return;
    }
    switch (type) {
      case DoubleTapType.left:
        // 双击左边区域 👈
        onDoubleTapSeekBackward();
        break;
      case DoubleTapType.center:
        onDoubleTapCenter();
        break;
      case DoubleTapType.right:
        // 双击右边区域 👈
        onDoubleTapSeekForward();
        break;
    }
  }

  /// 关闭控制栏
  void onLockControl(bool val) {
    feedBack();
    controlsLock.value = val;
    if (!val && showControls.value) {
      showControls.refresh();
    }
    controls = !val;
  }

  void _setFullScreen(bool val) {
    isFullScreen.value = val;
    updateSubtitleStyle();
  }

  double screenRatio = 0.0;
  bool isManualFS = true;
  late final FullScreenMode mode = Pref.fullScreenMode;
  late final horizontalScreen = Pref.horizontalScreen;
  late final removeSafeArea = Pref.removeSafeArea;

  Future<void>? changeOrientation({
    required bool isVertical,
    DeviceOrientation? orientation,
  }) {
    if (orientation == null && (mode == .none || mode == .gravity)) {
      return null;
    }
    if (orientation == null &&
        (mode == .vertical ||
            (mode == .auto && isVertical) ||
            (mode == .ratio && (isVertical || screenRatio < kScreenRatio)))) {
      return portraitUpMode();
    } else {
      // https://github.com/flutter/flutter/issues/73651
      // https://github.com/flutter/flutter/issues/183708
      if (Platform.isAndroid) {
        if ((orientation ?? _orientation) == .landscapeRight) {
          return landscapeRightMode();
        } else {
          return landscapeLeftMode();
        }
      } else {
        if (orientation == .landscapeLeft) {
          return landscapeLeftMode();
        } else {
          return landscapeRightMode();
        }
      }
    }
  }

  // 全屏
  bool _fsProcessing = false;
  Future<void> triggerFullScreen({
    bool status = true,
    bool inAppFullScreen = false,
    DeviceOrientation? orientation,
    bool isManualFS = true,
  }) async {
    if (isDesktopPip) return;
    if (isFullScreen.value == status) return;

    if (_fsProcessing) return;
    _fsProcessing = true;
    this.isManualFS = isManualFS;
    try {
      if (status) {
        if (PlatformUtils.isMobile) {
          hideSystemBar();
          await changeOrientation(
            isVertical: isVertical,
            orientation: orientation,
          );
        } else {
          await enterDesktopFullScreen(inAppFullScreen: inAppFullScreen);
        }
      } else {
        if (PlatformUtils.isMobile) {
          if (!removeSafeArea) {
            showSystemBar();
          }
          if (orientation == null && mode == .none) {
            return;
          }
          await resetScreenRotation();
        } else {
          await exitDesktopFullScreen();
        }
      }
    } finally {
      _setFullScreen(status);
      _fsProcessing = false;
    }
  }

  void addPositionListener(ValueChanged<Duration> listener) {
    if (_playerCount == 0) return;
    _positionListeners.add(listener);
  }

  void removePositionListener(ValueChanged<Duration> listener) =>
      _positionListeners.remove(listener);

  void addStatusLister(ValueChanged<PlayerStatus> listener) {
    if (_playerCount == 0) return;
    _statusListeners.add(listener);
  }

  void removeStatusLister(ValueChanged<PlayerStatus> listener) =>
      _statusListeners.remove(listener);

  // 记录播放记录
  Future<void>? makeHeartBeat(
    int progress, {
    HeartBeatType type = .playing,
    bool isManual = false,
    dynamic aid,
    dynamic bvid,
    dynamic cid,
    dynamic epid,
    dynamic seasonId,
    dynamic pgcType,
    VideoType? videoType,
  }) {
    if (isLive ||
        !enableHeart ||
        progress == 0 ||
        (playerStatus.isPaused && !isManual)) {
      return null;
    }

    Future<void> send() {
      return VideoHttp.heartBeat(
        aid: aid ?? _aid,
        bvid: bvid ?? _bvid,
        cid: cid ?? this.cid,
        progress: progress,
        epid: epid ?? _epid,
        seasonId: seasonId ?? _seasonId,
        subType: pgcType ?? _pgcType,
        videoType: videoType ?? _videoType,
      );
    }

    switch (type) {
      case .playing:
        if (progress - _heartDuration >= 5) {
          _heartDuration = progress;
          return send();
        }
      case .status:
        if (progress - _heartDuration >= 2) {
          _heartDuration = progress;
          return send();
        }
      case .completed:
        if (playerStatus.isCompleted &&
            (durationInMilliseconds - positionInMilliseconds) <= 1000) {
          progress = -1;
        }
        return send();
    }
    return null;
  }

  void setPlayRepeat(PlayRepeat type) {
    playRepeat = type;
    if (!tempPlayerConf) video.put(VideoBoxKey.playRepeat, type.index);
  }

  void putSubtitleSettings() {
    setting.putAllNE({
      SettingBoxKey.subtitleFontScale: subtitleFontScale,
      SettingBoxKey.subtitleFontScaleFS: subtitleFontScaleFS,
      SettingBoxKey.subtitlePaddingH: subtitlePaddingH,
      SettingBoxKey.subtitlePaddingB: subtitlePaddingB,
      SettingBoxKey.subtitleBgOpacity: subtitleBgOpacity,
      SettingBoxKey.subtitleStrokeWidth: subtitleStrokeWidth,
      SettingBoxKey.subtitleFontWeight: subtitleFontWeight,
    });
  }

  bool _isCloseAll = false;
  bool get isCloseAll => _isCloseAll;

  Future<void>? resetScreenRotation() {
    if (horizontalScreen) {
      return fullMode();
    } else {
      return portraitUpMode();
    }
  }

  void onCloseAll() {
    _isCloseAll = true;
    if (PlatformUtils.isDesktop) exitDesktopFullScreen();
    dispose();
    Get.until((route) => route.isFirst);
  }

  void dispose() {
    // 每次减1，最后销毁
    resetScreenRotation();
    cancelLongPressTimer();
    _cancelSubForSeek();
    if (!_isCloseAll && _playerCount > 1) {
      _playerCount -= 1;
      _heartDuration = 0;
      return;
    }

    _playerCount = 0;
    if (removeSafeArea) {
      showSystemBar();
    }
    danmakuController = null;
    _stopOrientationListener();
    _disableAutoEnterPip();
    _iosPipSub?.cancel();
    _iosPipSub = null;
    _iosPipErrorSub?.cancel();
    _iosPipErrorSub = null;
    _iosPipDanmakuSub?.cancel();
    _iosPipDanmakuSub = null;
    _iosAutoEnterArmedFor = null;
    if (isIOSPip.value) {
      videoController?.setPictureInPicture(false);
      isIOSPip.value = false;
    }
    _iosPipHold = false;
    setPlayCallBack(null);
    dmState.clear();
    if (showSeekPreview) {
      _clearPreview();
    }
    if (Platform.isAndroid) {
      AndroidHelper$ToDart.onUserLeaveHint?.release();
      AndroidHelper$ToDart.onUserLeaveHint = null;
    }
    _timer?.cancel();
    // _position.close();
    // _playerEventSubs?.cancel();
    // _sliderPosition.close();
    // _sliderTempPosition.close();
    // _isSliderMoving.close();
    // _duration.close();
    // _buffered.close();
    // _showControls.close();
    // _controlsLock.close();

    // playerStatus.close();
    // dataStatus.close();

    if (PlatformUtils.isDesktop && isAlwaysOnTop.value) {
      windowManager.setAlwaysOnTop(false);
    }

    _removeListeners();
    _positionListeners.clear();
    _statusListeners.clear();
    _stopWakeLockTimer();
    WakelockPlus.disable();
    if (kDebugMode) {
      debugPrint('dispose player');
    }
    _videoPlayerController?.dispose();
    _videoPlayerController = null;
    _videoController = null;
    _instance = null;
    videoPlayerServiceHandler?.clear();
  }

  static void updatePlayCount() {
    if (_instance?._playerCount == 1) {
      _instance?.dispose();
    } else {
      _instance?._playerCount -= 1;
    }
  }

  void setContinuePlayInBackground() {
    continuePlayInBackground.toggle();
    if (!tempPlayerConf) {
      setting.put(
        SettingBoxKey.continuePlayInBackground,
        continuePlayInBackground.value,
      );
    }
  }

  late final Map<String, ui.Image?> previewCache = {};
  LoadingState<VideoShotData>? videoShot;
  late final RxBool showPreview = false.obs;
  late final showSeekPreview = Pref.showSeekPreview;
  late final previewIndex = RxnInt();

  void updatePreviewIndex(int seconds) {
    if (videoShot == null) {
      videoShot = LoadingState.loading();
      getVideoShot();
      return;
    }
    if (videoShot case Success(:final response)) {
      showPreview.value = true;
      previewIndex.value = max(
        0,
        (response.index.where((item) => item <= seconds).length - 2),
      );
    }
  }

  void _clearPreview() {
    showPreview.value = false;
    previewIndex.value = null;
    videoShot = null;
    for (final i in previewCache.values) {
      i?.dispose();
    }
    previewCache.clear();
  }

  Future<void> getVideoShot() async {
    videoShot = await VideoHttp.videoshot(bvid: bvid, cid: cid!);
  }

  Future<void> takeScreenshot() async {
    SmartDialog.showToast('截图中');
    final image = await videoPlayerController?.screenshot();
    if (image != null) {
      SmartDialog.showToast('点击弹窗保存截图');
      final dispose = await showDialog<bool>(
        context: Get.context!,
        builder: (context) => GestureDetector(
          onTap: () async {
            Get.back(result: false);
            final bytes = await image.toByteData(format: .png);
            image.dispose();
            if (bytes != null) {
              final time = DurationUtils.formatDuration(
                positionInMilliseconds / 1000,
              ).replaceAll(':', '-');
              ImageUtils.saveByteImg(
                bytes: bytes.buffer.asUint8List(),
                fileName: 'screenshot_${cid}_$time',
              );
            } else {
              SmartDialog.showToast('保存失败');
            }
          },
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: min(MediaQuery.widthOf(context) / 3, 350),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      width: 5,
                      color: ColorScheme.of(context).surface,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: RawImage(image: image),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      if (dispose ?? true) image.dispose();
    } else {
      SmartDialog.showToast('截图失败');
    }
  }

  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) {
      // iOS 画中画下离开视频页时保持播放
      if (!isIOSPip.value && playerStatus.isPlaying) {
        pause();
      }

      setPlayCallBack(null);

      if (Platform.isAndroid && _playerCount <= 1) {
        _disableAutoEnterPip();
        if (!setSystemBrightness) {
          ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
        }
      }

      return;
    }

    if (controlsLock.value) {
      onLockControl(false);
      return;
    }
    if (isIOSPip.value) {
      // 未能真正退出页面时（如全屏/横屏拦截），先退出画中画避免卡在原页
      exitIOSPip();
      return;
    }
    if (isDesktopPip) {
      exitDesktopPip();
      return;
    }
    if (isFullScreen.value) {
      triggerFullScreen(status: false);
      return;
    }
    Get.back();
  }
}
