import 'dart:async';

/// 真机自动 QA 的启动配置。
///
/// 由 `Documents/pip_qa.json` 提供，脚本可通过 AFC / `apps push --documents`
/// 写入，无需在 UI 里手点。
class PipQaConfig {
  const PipQaConfig({
    required this.enabled,
    required this.runId,
    required this.index,
    required this.playSeconds,
    required this.backgroundSeconds,
    this.advanceEvery = 0,
    this.autoStart = true,
    this.seedKeys = const <String>[],
  });

  factory PipQaConfig.fromJson(Map<String, dynamic> json) => PipQaConfig(
    enabled: json['enabled'] == true,
    runId: '${json['runId'] ?? ''}',
    index: (json['index'] as num?)?.toInt() ?? 0,
    playSeconds: (json['playSeconds'] as num?)?.toInt() ?? 8,
    backgroundSeconds:
        (json['backgroundSeconds'] as num?)?.toInt() ?? 10,
    advanceEvery: (json['advanceEvery'] as num?)?.toInt() ?? 0,
    autoStart: json['autoStart'] != false,
    seedKeys:
        (json['seedKeys'] as List?)
            ?.map((value) => '$value')
            .toList(growable: false) ??
        const <String>[],
  );

  final bool enabled;
  final String runId;
  final int index;
  final int playSeconds;
  final int backgroundSeconds;
  final int advanceEvery;
  final bool autoStart;
  final List<String> seedKeys;

  /// 把外部配置收敛到安全范围，保证采样、后台、判定和收尾用同一组秒数。
  int get effectivePlaySeconds => playSeconds.clamp(2, 120);
  int get effectiveBackgroundSeconds => backgroundSeconds.clamp(2, 60);
  int get effectiveAdvanceEvery => advanceEvery.clamp(0, 30);

  /// 当前进程正在执行的 QA 配置；只用于被动记录，不改变画中画控制流。
  static PipQaConfig? active;

  static const String fileName = 'pip_qa.json';
  static const String logFileName = 'pip_qa_log.json';
  static const String nativeDiagFileName = 'pip_diag.jsonl';
}

/// 播放器首条视频真正开始采样后，才允许宿主驱动 Home / 回前台。
abstract final class PipQaRuntime {
  static Completer<void>? _ready;
  static Completer<void>? _finished;
  static bool _started = false;
  static String? failureVerdict;

  static void begin(PipQaConfig config) {
    PipQaConfig.active = config;
    failureVerdict = null;
    _started = true;
    _ready = Completer<void>();
    _finished = Completer<void>();
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
