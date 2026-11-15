import 'dart:async';

/// 真机自动 QA 的启动配置。
///
/// 由 `Documents/pip_qa.json` 提供，脚本可通过 AFC / `apps push --documents`
/// 写入，无需在 UI 里手点。
class PipQaConfig {
  static const String defaultPipMode = 'legacy';

  const PipQaConfig({
    required this.enabled,
    required this.runId,
    required this.index,
    required this.playSeconds,
    required this.backgroundSeconds,
    this.advanceEvery = 0,
    this.autoStart = true,
    this.pipMode = defaultPipMode,
    this.seedKeys = const <String>[],
    this.shuffle = false,
  });

  factory PipQaConfig.fromJson(Map<String, dynamic> json) {
    final configuredRunId = '${json['runId'] ?? ''}'.trim();
    return PipQaConfig(
      enabled: json['enabled'] == true,
      runId: configuredRunId.isEmpty
          ? 'qa-${DateTime.now().microsecondsSinceEpoch}'
          : configuredRunId,
      index: (json['index'] as num?)?.toInt() ?? 0,
      playSeconds: (json['playSeconds'] as num?)?.toInt() ?? 8,
      backgroundSeconds:
          (json['backgroundSeconds'] as num?)?.toInt() ?? 10,
      advanceEvery: (json['advanceEvery'] as num?)?.toInt() ?? 0,
      autoStart: json['autoStart'] != false,
      pipMode: _normalizePipMode(json['pipMode']),
      shuffle: json['shuffle'] == true,
      seedKeys:
          (json['seedKeys'] as List?)
              ?.map((value) => '$value')
              .toList(growable: false) ??
          const <String>[],
    );
  }

  final bool enabled;
  final String runId;
  final int index;
  final int playSeconds;
  final int backgroundSeconds;
  final int advanceEvery;
  final bool autoStart;
  final String pipMode;
  final bool shuffle;
  final List<String> seedKeys;

  static String _normalizePipMode(Object? value) {
    final mode = '$value';
    return const <String>{'legacy', 'system', 'manual', 'bili'}.contains(mode)
        ? mode
        : defaultPipMode;
  }

  /// 把外部配置收敛到安全范围，保证采样、后台、判定和收尾用同一组秒数。
  int get effectivePlaySeconds => playSeconds.clamp(2, 120);
  int get effectiveBackgroundSeconds => backgroundSeconds.clamp(2, 60);
  int get effectiveAdvanceEvery => advanceEvery.clamp(0, 30);

  /// 当前模式会下发到已锁定的 `pip-6s` fork 原生 QA 模式 API。
  ///
  /// `legacy` 是 B 站播放器验证过的默认稳定路径；`system` 仅作保守对照；
  /// `manual` 与 `bili` 在切后台前做一次前台启动对照，其中 `manual`
  /// 同时让原生侧禁止自动进入。
  bool get requiresForegroundPipStart =>
      pipMode == 'manual' || pipMode == 'bili';

  /// 传给原生侧的模式，避免播放器会话再自己猜一次默认值。
  String get effectiveNativePipMode => pipMode;

  /// 诊断文案用模式名，避免把 `bili` 错报成「手动模式」。
  String get foregroundPipStartLabel =>
      pipMode == 'bili' ? '前台启动对照模式' : '手动模式';

  /// 当前进程正在执行的 QA 配置；会驱动自动 QA 启动、采样与判定收尾。
  static PipQaConfig? active;

  /// Where the active config came from: `host` or `documents`.
  static String? source;

  static const String fileName = 'pip_qa.json';
  static const String logFileName = 'pip_qa_log.json';
  static const String nativeDiagFileName = 'pip_diag.jsonl';
  static const String hostDiagFileName = 'pip_qa_host.jsonl';
}

/// 播放器首条视频真正开始采样后，才允许宿主驱动 Home / 回前台。
abstract final class PipQaRuntime {
  static Completer<void>? _ready;
  static Completer<void>? _finished;
  static bool _started = false;
  static int foregroundPipStarts = 0;
  static bool manualStartOrdered = false;
  static String? failureVerdict;

  static void begin(PipQaConfig config) {
    PipQaConfig.active = config;
    failureVerdict = null;
    _started = true;
    foregroundPipStarts = 0;
    manualStartOrdered = false;
    _ready = Completer<void>();
    _finished = Completer<void>();
  }

  static void markForegroundPipStart({bool manual = false}) {
    foregroundPipStarts += 1;
    if (manual) manualStartOrdered = true;
  }

  static void markReady() {
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.complete();
  }

  static void fail(String verdict) {
    failureVerdict ??= verdict;
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.complete();
    }
  }

  static Future<void> waitReady() {
    final ready = _ready;
    if (ready == null) return Future<void>.value();
    return ready.future;
  }

  static void markFinished() {
    final finished = _finished;
    if (finished != null && !finished.isCompleted) finished.complete();
  }

  static bool get isFinished => _finished?.isCompleted ?? false;

  static bool get isStarted => _started;

  static Future<void> waitFinished() {
    final finished = _finished;
    if (finished == null) return Future<void>.value();
    return finished.future;
  }
}
