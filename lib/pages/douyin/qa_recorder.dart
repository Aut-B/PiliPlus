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

Future<void> _pipQaWriteQueue = Future<void>.value();
int _pipQaWriteSequence = 0;
int _pipQaFinalSequence = 0;

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
  });

  final PipQaConfig config;
  final int total;
  final int index;
  final PipQaStateBuilder state;
  final PipQaNativeDiagLoader? loadNativeDiag;
  Timer? _timer;
  bool _closed = false;
  final List<Map<String, Object?>> _samples = <Map<String, Object?>>[];
  Map<String, Object?> _lastSnapshot = <String, Object?>{};
  double _backgroundSeconds = 0;
  Map<String, Object?> _backgroundSummary = const <String, Object?>{};
  Map<String, Object?> _finalSnapshot = const <String, Object?>{};
  Map<String, Object?> _nativeDiag = const <String, Object?>{};
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
        'finalSnapshot': const <String, Object?>{},
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
        'finalSnapshot': _finalSnapshot,
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
      'samples': List<Map<String, Object?>>.of(_samples),
      'finalSnapshot': _finalSnapshot,
    };
  }

  Future<void> writeVerdict(PipQaVerdict verdict) async {
    _pass = verdict.pass;
    _lastVerdict = verdict.verdict;
    _nativeDiag = await _safeNativeDiag();
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
      'finalSnapshot': _finalSnapshot,
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
      'finalSnapshot': _finalSnapshot,
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
