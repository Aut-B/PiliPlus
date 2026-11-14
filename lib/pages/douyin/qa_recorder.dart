import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/pages/douyin/player_session.dart';
import 'package:PiliPlus/pages/douyin/qa_config.dart';
import 'package:PiliPlus/pages/douyin/qa_verdict.dart';
import 'package:path_provider/path_provider.dart';

typedef PipQaStateBuilder = Map<String, Object?> Function();

typedef PipQaNativeDiagLoader = Future<Map<String, Object?>> Function({
  PipQaConfig? config,
  DateTime? updatedAt,
});
typedef PipQaHostDiagLoader = Future<Map<String, Object?>> Function({
  PipQaConfig? config,
  DateTime? updatedAt,
});

Future<void> _pipQaWriteQueue = Future<void>.value();
int _pipQaWriteSequence = 0;
int _pipQaFinalSequence = 0;

Map<String, Object?> _foregroundPipStartEvidence(PipQaConfig config) {
  final session = ShortVideoSession.instance;
  return <String, Object?>{
    'required': config.requiresForegroundPipStart,
    'mode': config.pipMode,
    'foregroundStartOrdered': PipQaRuntime.manualStartOrdered,
    'foregroundPipStarts': PipQaRuntime.foregroundPipStarts,
    'sessionForegroundPipStarts': session.foregroundPipStarts,
    'sessionAppState': session.appState,
    'sessionPipActive': session.pipActive && session.appState == 'active',
  };
}

Future<void> _writePipQaLog(
  Map<String, Object?> payload, {
  bool finalWrite = false,
}) {
  final sequence = ++_pipQaWriteSequence;
  if (finalWrite) _pipQaFinalSequence = sequence;
  _pipQaWriteQueue = _pipQaWriteQueue.then((_) async {
    if (finalWrite) {
      if (sequence != _pipQaFinalSequence) return;
    } else if (_pipQaFinalSequence > 0) {
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/${PipQaConfig.logFileName}');
    await file.writeAsString(jsonEncode(payload), flush: true);
  }).catchError((Object _) => Future<void>.value());
  return _pipQaWriteQueue;
}

final class PipQaRecorder {
  PipQaRecorder(
    this.config,
    this.total,
    this.state, {
    required this.index,
    this.loadNativeDiag,
    this.loadHostDiag,
  });

  final PipQaConfig config;
  final int total;
  final int index;
  final PipQaStateBuilder state;
  final PipQaNativeDiagLoader? loadNativeDiag;
  final PipQaHostDiagLoader? loadHostDiag;
  Timer? _timer;
  bool _closed = false;
  final List<Map<String, Object?>> _samples = <Map<String, Object?>>[];
  Map<String, Object?> _lastSnapshot = <String, Object?>{};
  double _backgroundSeconds = 0;
  Map<String, Object?> _backgroundSummary = const <String, Object?>{};
  Map<String, Object?> _finalSnapshot = const <String, Object?>{};
  Map<String, Object?> _nativeDiag = const <String, Object?>{};
  Map<String, Object?> _hostDiag = const <String, Object?>{};
  String _lastVerdict = '自动 QA 正在采样，等待切后台与回前台';
  bool _pass = false;
  double get _sampleSeconds {
    if (_samples.isEmpty) return 0;
    final first = DateTime.tryParse('${_samples.first['at']}');
    final last = DateTime.tryParse('${_samples.last['at']}');
    if (first == null || last == null) return 0;
    return last.difference(first).inMilliseconds / 1000.0;
  }

  void start() {
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      unawaited(_sample());
    });
    unawaited(_sample());
  }

  Future<void> _sample() async {
    if (_closed || PipQaRuntime.failureVerdict != null) return;
    final session = ShortVideoSession.instance;
    final diagnostics = <String, Object?>{};
    if (session.controller != null) {
      try {
        final raw = await session.controller!.pictureInPictureDiagnostics();
        if (raw is Map) {
          raw.forEach((key, value) => diagnostics['$key'] = value);
        }
      } catch (error) {
        diagnostics['error'] = '$error';
      }
    }
    if (_closed || PipQaRuntime.failureVerdict != null) return;
    final snapshot = <String, Object?>{
      'at': DateTime.now().toIso8601String(),
      'runId': config.runId,
      'build': '${BuildConfig.versionName}(${BuildConfig.versionCode})',
      'mode': 'auto',
      'index': index,
      'total': total,
      'lifecycle': session.lifecycleNote,
      'appState': session.appState,
      'pipActive': session.pipActive,
      ...state(),
      'diagnostics': diagnostics,
    };
    _lastSnapshot = Map<String, Object?>.of(snapshot);
    _samples.add(snapshot);
    if (_samples.length > 1200) {
      _samples.removeRange(0, _samples.length - 1200);
    }
    await _write(<String, Object?>{
      'runId': config.runId,
      'updatedAt': DateTime.now().toIso8601String(),
      'pass': false,
      'verdict': '自动 QA 正在采样，等待切后台与回前台',
      'samples': _samples,
      'sampleSeconds': _sampleSeconds,
      'manualStartEvidence': _foregroundPipStartEvidence(config),
    });
  }

  Future<void> _write(
    Map<String, Object?> payload, {
    bool finalWrite = false,
  }) async {
    await _writePipQaLog(payload, finalWrite: finalWrite);
  }

  static Future<void> writeFailure(
    PipQaConfig config,
    String verdict,
  ) async {
    final nativeDiag = await readPipQaNativeDiag(
      config: config,
      updatedAt: DateTime.now(),
    );
    final hostDiag = await readPipQaHostDiag(
      config: config,
      updatedAt: DateTime.now(),
    );
    await _writePipQaLog(
      <String, Object?>{
        'runId': config.runId,
        'updatedAt': DateTime.now().toIso8601String(),
        'pass': false,
        'verdict': verdict,
        'samples': const <Object>[],
        'sampleSeconds': 0,
        'backgroundSeconds': 0,
        'backgroundSummary': const <String, Object?>{},
        'nativeDiag': nativeDiag,
        'hostDiag': hostDiag,
        'finalSnapshot': const <String, Object?>{},
        'manualStartEvidence': _foregroundPipStartEvidence(config),
      },
      finalWrite: true,
    );
  }

  void close() {
    _closed = true;
    _timer?.cancel();
  }

  Future<Map<String, dynamic>> finish({
    required double backgroundSeconds,
    required Map<String, Object?> backgroundSummary,
  }) async {
    close();
    _backgroundSeconds = backgroundSeconds;
    _backgroundSummary = Map<String, Object?>.of(backgroundSummary);
    _nativeDiag = await _safeNativeDiag();
    _hostDiag = await _safeHostDiag();
    final snapshot = <String, Object?>{
      ..._lastSnapshot,
      'backgroundSeconds': _backgroundSeconds,
      'backgroundSummary': _backgroundSummary,
    };
    _finalSnapshot = snapshot;
    if (_pipQaFinalSequence == 0) {
      await _writePipQaLog(<String, Object?>{
        'runId': config.runId,
        'updatedAt': DateTime.now().toIso8601String(),
        'pass': false,
        'verdict': _lastVerdict,
        'samples': List<Map<String, Object?>>.of(_samples),
        'sampleSeconds': _sampleSeconds,
        'backgroundSeconds': _backgroundSeconds,
        'backgroundSummary': _backgroundSummary,
        'nativeDiag': _nativeDiag,
        'hostDiag': _hostDiag,
        'finalSnapshot': _finalSnapshot,
        'manualStartEvidence': _foregroundPipStartEvidence(config),
      }, finalWrite: true);
    }
    return <String, dynamic>{
      'runId': config.runId,
      'updatedAt': DateTime.now().toIso8601String(),
      'pass': _pass,
      'verdict': _lastVerdict,
      'backgroundSeconds': _backgroundSeconds,
      'backgroundSummary': _backgroundSummary,
      'sampleSeconds': _sampleSeconds,
      'nativeDiag': _nativeDiag,
      'hostDiag': _hostDiag,
      'samples': List<Map<String, Object?>>.of(_samples),
      'finalSnapshot': _finalSnapshot,
      'manualStartEvidence': _foregroundPipStartEvidence(config),
    };
  }

  Future<void> writeVerdict(PipQaVerdict verdict) async {
    _pass = verdict.pass;
    _lastVerdict = verdict.verdict;
    _nativeDiag = await _safeNativeDiag();
    _hostDiag = await _safeHostDiag();
    await _write(<String, Object?>{
      'runId': config.runId,
      'updatedAt': DateTime.now().toIso8601String(),
      'pass': verdict.pass,
      'verdict': verdict.verdict,
      'samples': List<Map<String, Object?>>.of(_samples),
      'sampleSeconds': _sampleSeconds,
      'backgroundSeconds': _backgroundSeconds,
      'backgroundSummary': _backgroundSummary,
      'nativeDiag': _nativeDiag,
      'hostDiag': _hostDiag,
      'finalSnapshot': _finalSnapshot,
      'manualStartEvidence': _foregroundPipStartEvidence(config),
    }, finalWrite: true);
  }

  Future<void> fail(String verdict) {
    close();
    _pass = false;
    _lastVerdict = verdict;
    return _fail(verdict);
  }

  Future<void> _fail(String verdict) async {
    _nativeDiag = await _safeNativeDiag();
    _hostDiag = await _safeHostDiag();
    await _write(<String, Object?>{
      'runId': config.runId,
      'updatedAt': DateTime.now().toIso8601String(),
      'pass': false,
      'verdict': verdict,
      'samples': List<Map<String, Object?>>.of(_samples),
      'sampleSeconds': _sampleSeconds,
      'backgroundSeconds': _backgroundSeconds,
      'backgroundSummary': _backgroundSummary,
      'nativeDiag': _nativeDiag,
      'hostDiag': _hostDiag,
      'finalSnapshot': _finalSnapshot,
      'manualStartEvidence': _foregroundPipStartEvidence(config),
    }, finalWrite: true);
  }

  Future<Map<String, Object?>> _safeNativeDiag() async {
    try {
      final loader = loadNativeDiag ?? readPipQaNativeDiag;
      return await loader(config: config, updatedAt: DateTime.now());
    } catch (_) {
      return const <String, Object?>{};
    }
  }

  Future<Map<String, Object?>> _safeHostDiag() async {
    try {
      final loader = loadHostDiag ?? readPipQaHostDiag;
      return await loader(config: config, updatedAt: DateTime.now());
    } catch (_) {
      return const <String, Object?>{};
    }
  }
}

Future<Map<String, Object?>> readPipQaNativeDiag({
  PipQaConfig? config,
  DateTime? updatedAt,
}) async {
  if (!Platform.isIOS) {
    return const <String, Object?>{'available': false};
  }
  final runId = config?.runId ?? '';
  if (runId.isEmpty) {
    return const <String, Object?>{
      'available': false,
      'reason': '当前构建缺少本轮 QA runId，不能使用任意历史原生日志',
    };
  }
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/${PipQaConfig.nativeDiagFileName}');
    if (!await file.exists()) {
      return const <String, Object?>{
        'available': false,
        'reason': '当前构建没有写入 pip_diag.jsonl；需要含本地 PiP 诊断 fork 的新构建',
      };
    }
    final int fileLength = await file.length();
    final int readSize = fileLength > 262144 ? 262144 : fileLength;
    final stream = file.openRead(fileLength - readSize);
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
    }
    var text = Utf8Decoder(allowMalformed: true).convert(bytes);
    if (readSize < fileLength) {
      final firstBreak = text.indexOf('\n');
      if (firstBreak >= 0) text = text.substring(firstBreak + 1);
    }
    final lines = const LineSplitter().convert(text);
    final events = <Map<String, Object?>>[];
    final start = lines.length > 240 ? lines.length - 240 : 0;
    for (var index = start; index < lines.length; index += 1) {
      final line = lines[index].trim();
      if (line.isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map) {
          final event = <String, Object?>{};
          decoded.forEach((key, value) => event['$key'] = value);
          if (_num(event['ts']) > 0) events.add(event);
        }
      } catch (_) {}
    }
    final maxAge = config == null
        ? 300.0
        : config.effectivePlaySeconds +
            config.effectiveBackgroundSeconds +
            config.effectiveAdvanceEvery * 2 +
            90.0;
    final scopedByRun = events
        .where((event) => '${event['runId'] ?? ''}' == runId)
        .toList(growable: false);
    if (scopedByRun.isEmpty) {
      return <String, Object?>{
        'available': false,
        'reason': '没有找到当前 runId 的原生诊断事件；旧日志不能作为本轮证据',
        'events': const <Object>[],
      };
    }
    final minSeconds = updatedAt == null
        ? -1.0
        : updatedAt.millisecondsSinceEpoch / 1000.0 - maxAge;
    final eventsForRun = minSeconds < 0
        ? scopedByRun
        : scopedByRun
            .where((event) => _num(event['ts']) >= minSeconds)
            .toList(growable: false);
    if (eventsForRun.isEmpty) {
      return <String, Object?>{
        'available': false,
        'reason': '当前 runId 的原生诊断事件都早于本轮 QA 时间窗',
        'events': const <Object>[],
      };
    }
    var cursor = eventsForRun.length - 1;
    while (cursor >= 0) {
      if (_text(eventsForRun[cursor]['event']) == 'foreground') {
        break;
      }
      cursor -= 1;
    }
    if (cursor < 0) cursor = eventsForRun.length - 1;
    final foregroundRunId = '${eventsForRun[cursor]['runId'] ?? ''}';
    var segmentStart = cursor;
    while (segmentStart > 0) {
      final previous = eventsForRun[segmentStart - 1];
      if (_text(previous['event']) == 'background') {
        segmentStart -= 1;
        break;
      }
      if (_text(previous['event']) == 'foreground' ||
          (foregroundRunId.isNotEmpty &&
              '${previous['runId'] ?? ''}' != foregroundRunId)) {
        break;
      }
      segmentStart -= 1;
    }
    if (_text(eventsForRun[segmentStart]['event']) != 'background') {
      return _nativeDiagSegment(eventsForRun, runId);
    }
    final scoped = eventsForRun.sublist(segmentStart, cursor + 1);
    return _nativeDiagSegment(scoped, runId);
  } catch (_) {
    return const <String, Object?>{
      'available': false,
      'reason': '原生诊断文件读取失败',
    };
  }
}

Future<Map<String, Object?>> readPipQaHostDiag({
  PipQaConfig? config,
  DateTime? updatedAt,
}) async {
  if (!Platform.isIOS) {
    return const <String, Object?>{'available': false};
  }
  final runId = config?.runId ?? '';
  if (runId.isEmpty) {
    return const <String, Object?>{
      'available': false,
      'reason': '当前构建缺少本轮 QA runId，不能使用任意历史宿主日志',
    };
  }
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/${PipQaConfig.hostDiagFileName}');
    if (!await file.exists()) {
      return const <String, Object?>{
        'available': false,
        'reason': '当前构建没有写入 pip_qa_host.jsonl；需含宿主生命周期记录的新构建',
      };
    }
    final maxAge = config == null
        ? 300.0
        : config.effectivePlaySeconds +
            config.effectiveBackgroundSeconds +
            config.effectiveAdvanceEvery * 2 +
            90.0;
    final minSeconds = updatedAt == null
        ? -1.0
        : updatedAt.millisecondsSinceEpoch / 1000.0 - maxAge;
    final events = <Map<String, Object?>>[];
    final lines = await file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList();
    final start = lines.length > 240 ? lines.length - 240 : 0;
    for (var index = start; index < lines.length; index += 1) {
      final line = lines[index].trim();
      if (line.isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) continue;
        final event = <String, Object?>{};
        decoded.forEach((key, value) => event['$key'] = value);
        if ('${event['runId'] ?? ''}' != runId) continue;
        final ts = _num(event['ts']);
        if (ts <= 0 || (minSeconds >= 0 && ts < minSeconds)) continue;
        events.add(event);
      } catch (_) {}
    }
    if (events.isEmpty) {
      return <String, Object?>{
        'available': false,
        'reason': '没有找到当前 runId 且在本轮时间窗内的宿主生命周期事件',
        'events': const <Object>[],
      };
    }
    final segment = _hostDiagSegment(events);
    return <String, Object?>{
      'available': true,
      'runId': runId,
      'lineCount': events.length,
      ...segment,
      'lastAppState': _hostDiagLastAppState(events),
      'events': events,
    };
  } catch (_) {
    return const <String, Object?>{
      'available': false,
      'reason': '宿主生命周期文件读取失败',
    };
  }
}

Map<String, Object?> _hostDiagSegment(List<Map<String, Object?>> events) {
  const absent = <String, Object?>{};
  final incomplete = <String, Object?>{
    'segmentComplete': false,
    'hostBackgroundSeconds': -1.0,
    'backgroundEvent': absent,
    'willEnterForegroundEvent': absent,
    'foregroundEvent': absent,
    'suspendRequested': events.any(
      (event) => _text(event['event']) == 'suspendRequested',
    ),
    'resumeRequested': events.any(
      (event) => _text(event['event']) == 'resumeRequested',
    ),
    'resumeApplied': events.any(
      (event) => _text(event['event']) == 'resumeApplied',
    ),
  };
  var foregroundIndex = -1;
  for (var index = events.length - 1; index >= 0; index -= 1) {
    if (_text(events[index]['event']) == 'didBecomeActive') {
      foregroundIndex = index;
      break;
    }
  }
  var backgroundIndex = -1;
  for (var index = foregroundIndex - 1; index >= 0; index -= 1) {
    final event = _text(events[index]['event']);
    if (event == 'didEnterBackground') {
      backgroundIndex = index;
      break;
    }
    if (event == 'didBecomeActive') break;
  }
  if (backgroundIndex < 0 || foregroundIndex < 0) {
    return incomplete;
  }
  final segmentEvents = events.sublist(backgroundIndex, foregroundIndex + 1);
  final backgroundSeconds = _num(segmentEvents.first['ts']);
  final foregroundSeconds = _num(segmentEvents.last['ts']);
  final backgroundEvent = segmentEvents.first;
  final foregroundEvent = segmentEvents.last;
  if (_text(backgroundEvent['event']) != 'didEnterBackground' ||
      _text(backgroundEvent['appState']) != 'background' ||
      _text(foregroundEvent['event']) != 'didBecomeActive' ||
      _text(foregroundEvent['appState']) != 'active' ||
      backgroundSeconds <= 0 ||
      foregroundSeconds < backgroundSeconds) {
    return incomplete;
  }
  final willEnterForegroundEvent = _hostDiagEvent(
    events,
    'willEnterForeground',
    minSeconds: backgroundSeconds,
    maxSeconds: foregroundSeconds,
  );
  final suspendEvent = _hostDiagEvent(
    events,
    'suspendRequested',
    minSeconds: backgroundSeconds - 5,
    maxSeconds: backgroundSeconds + 5,
  );
  final resumeEvent = _hostDiagEvent(
    events,
    'resumeRequested',
    minSeconds: backgroundSeconds,
    maxSeconds: foregroundSeconds + 5,
  );
  final resumeAppliedEvent = _hostDiagEvent(
    events,
    'resumeApplied',
    minSeconds: backgroundSeconds,
    maxSeconds: foregroundSeconds + 5,
  );
  final complete = backgroundEvent.isNotEmpty &&
      willEnterForegroundEvent.isNotEmpty &&
      suspendEvent.isNotEmpty &&
      resumeEvent.isNotEmpty &&
      resumeAppliedEvent.isNotEmpty &&
      _num(willEnterForegroundEvent['ts']) >= backgroundSeconds &&
      _num(willEnterForegroundEvent['ts']) <= foregroundSeconds &&
      _num(suspendEvent['ts']) >= backgroundSeconds - 5 &&
      _num(suspendEvent['ts']) <= backgroundSeconds + 5 &&
      _num(resumeEvent['ts']) >= backgroundSeconds &&
      _num(resumeEvent['ts']) <= foregroundSeconds + 5 &&
      _num(resumeAppliedEvent['ts']) >= backgroundSeconds &&
      _num(resumeAppliedEvent['ts']) <= foregroundSeconds + 5;
  return <String, Object?>{
    'segmentComplete': complete,
    'hostBackgroundSeconds': complete
        ? foregroundSeconds - backgroundSeconds
        : -1.0,
    'backgroundEvent': backgroundEvent,
    'willEnterForegroundEvent': willEnterForegroundEvent,
    'foregroundEvent': foregroundEvent,
    'suspendRequested': suspendEvent.isNotEmpty,
    'resumeRequested': resumeEvent.isNotEmpty,
    'resumeApplied': resumeAppliedEvent.isNotEmpty,
    'resumeAppliedEvent': resumeAppliedEvent,
  };
}

Map<String, Object?> _hostDiagEvent(
  List<Map<String, Object?>> events,
  String name, {
  required double minSeconds,
  required double maxSeconds,
}) {
  for (final event in events) {
    if (_text(event['event']) != name) continue;
    final seconds = _num(event['ts']);
    if (seconds >= minSeconds && seconds <= maxSeconds) return event;
  }
  return const <String, Object?>{};
}

/// QA 通道事件只是内部控制标记：resumeApplied 记的是执行 resume 那一刻的
/// 真实 applicationState，不能拿它覆盖 didBecomeActive 的最终生命周期状态。
String _hostDiagLastAppState(List<Map<String, Object?>> events) {
  const lifecycleEvents = <String>{
    'started',
    'willResignActive',
    'didEnterBackground',
    'willEnterForeground',
    'didBecomeActive',
  };
  for (var index = events.length - 1; index >= 0; index -= 1) {
    final event = events[index];
    if (lifecycleEvents.contains(_text(event['event']))) {
      return _text(event['appState']);
    }
  }
  return '';
}

Map<String, Object?> _nativeDiagSegment(
  List<Map<String, Object?>> scoped,
  String selectedRunId,
) {
  final segmentComplete = scoped.any(
        (event) => _text(event['event']) == 'background',
      ) &&
      scoped.any((event) => _text(event['event']) == 'foreground') &&
      scoped.any((event) => _text(event['appState']) == 'background');
  return <String, Object?>{
    'available': true,
    'runId': selectedRunId,
    'lineCount': scoped.length,
    'segmentComplete': segmentComplete,
    'events': scoped,
  };
}

double _num(Object? value) => value is num ? value.toDouble() : -1;

String _text(Object? value) => value == null ? '' : '$value';
