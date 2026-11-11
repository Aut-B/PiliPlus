import 'dart:math' as math;

import 'package:PiliPlus/pages/douyin/qa_config.dart';

final class PipQaVerdict {
  const PipQaVerdict(this.pass, this.verdict);

  final bool pass;
  final String verdict;
}

PipQaVerdict evaluatePipQaLog(
  Map<String, dynamic> log,
  PipQaConfig config,
) {
  final samples = log['samples'];
  if (samples is! List || samples.isEmpty) {
    return PipQaVerdict(
      false,
      '${log['verdict'] ?? '没有采样数据'}',
    );
  }
  final typed = samples
      .whereType<Map>()
      .map(_map)
      .toList(growable: false)
    ..sort((left, right) => '${left['at'] ?? ''}'
        .compareTo('${right['at'] ?? ''}'));
  if (typed.isEmpty) {
    return const PipQaVerdict(false, '采样数据格式错误');
  }
  final backgroundSeconds = config.effectiveBackgroundSeconds.toDouble();
  final needed = math.min(3.0, backgroundSeconds * 0.55);
  final nativeDiag = _evaluateNativeDiag(log, config, needed);
  final nativeBackground = _evaluateNativeBackground(log, typed, config, needed);
  final capability = _sampleDiagnosticsCapability(typed);
  if (capability != null) return capability;
  final backgroundSamples = typed.where((sample) {
    final diagnostics = _map(sample['diagnostics']);
    return _isBackgroundDiagnostics(diagnostics);
  }).toList(growable: false);
  final showing = backgroundSamples.where((sample) {
    final diagnostics = _map(sample['diagnostics']);
    return _isPipVisibleInBackground(diagnostics);
  }).toList(growable: false);
  if (showing.isEmpty) {
    final nativeFailure = _nativeDiagFailure(nativeDiag);
    if (nativeFailure != null) return nativeFailure;
    if (nativeBackground != null && !nativeBackground.pass) {
      return nativeBackground;
    }
    final fallback = _evaluateAnyWindow(typed, needed);
    if (fallback != null) return fallback;
    if (nativeBackground != null) return nativeBackground;
    return const PipQaVerdict(
      false,
      '后台期间没有采样到小窗显示或系统接管图层；小窗未显示或未进入后台',
    );
  }
  final first = showing.first;
  final last = showing.last;
  final diagnosticsFirst = _map(first['diagnostics']);
  final diagnosticsLast = _map(last['diagnostics']);
  final elapsed = _secondsBetween('${first['at']}', '${last['at']}');
  final nativeFailureAtStart = _nativeDiagFailure(nativeDiag) ??
      ((nativeBackground != null && !nativeBackground.pass)
          ? nativeBackground
          : null);
  final enqueuedDelta =
      _num(diagnosticsLast['enqueued']) - _num(diagnosticsFirst['enqueued']);
  final positionDelta =
      _num(diagnosticsLast['position']) - _num(diagnosticsFirst['position']);
  final rate = _num(diagnosticsLast['timebaseRate']);
  final armed = diagnosticsLast['armed'] == true;
  final attached = diagnosticsLast['hostAttached'] == true;
  final layerReady = diagnosticsLast['layerReady'] == true;
  final layerHidden = diagnosticsLast['layerHidden'] == true;
  final paused = diagnosticsLast['paused'] == true;
  final flickerReason = _flickerReason(
    diagnosticsFirst,
    diagnosticsLast,
    allowedFlushDelta: _transitionFlushAllowance(
      diagnosticsFirst,
      diagnosticsLast,
      summary: _backgroundSummary(log),
    ),
  );
  final sameFrameWindows = _countStalls(
    showing,
    _num(diagnosticsFirst['enqueued']),
  );
  if (elapsed < needed) {
    if (nativeFailureAtStart != null) return nativeFailureAtStart;
    return PipQaVerdict(
      false,
      '后台小窗采样只有 ${elapsed.toStringAsFixed(1)} 秒，少于 ${needed.toStringAsFixed(1)} 秒',
    );
  }
  if (nativeFailureAtStart != null) return nativeFailureAtStart;
  if (!armed || !attached || !layerReady || layerHidden) {
    return const PipQaVerdict(
      false,
      '后台小窗的图层未就绪：检查 armed / hostAttached / layerReady / layerHidden',
    );
  }
  final owner = _text(diagnosticsLast['layerOwner']);
  if (owner == 'host' || owner == 'none') {
    return PipQaVerdict(
      false,
      '后台图层没有被系统接管：图层归属 $owner、图层被接管 '
      '${diagnosticsLast['layerDetached'] == true ? '是' : '否'}',
    );
  }
  if (paused || rate < 0 || positionDelta < elapsed * 0.35) {
    return const PipQaVerdict(
      false,
      '后台播放源停了：检查 paused / timebaseRate / position',
    );
  }
  if (enqueuedDelta < elapsed * 5 || sameFrameWindows > 0) {
    return const PipQaVerdict(
      false,
      '后台小窗出现卡帧签名：入队不足或连续采样无新帧',
    );
  }
  if (flickerReason != null) {
    return PipQaVerdict(false, flickerReason);
  }
  if (nativeBackground != null && !nativeBackground.pass) {
    return nativeBackground;
  }
  return PipQaVerdict(
    true,
    '后台小窗 ${elapsed.toStringAsFixed(1)} 秒持续出帧：'
        '入队 +${enqueuedDelta.round()}、进度 +${positionDelta.toStringAsFixed(1)} 秒、'
        '图层归属 $owner',
  );
}

PipQaVerdict? _evaluateAnyWindow(
  List<Map<String, Object?>> samples,
  double needed,
) {
  final usable = samples.where((sample) {
    final diagnostics = sample['diagnostics'];
    return diagnostics is Map && diagnostics['showing'] == true;
  }).toList(growable: false);
  if (usable.length < 3) return null;
  final first = usable.first;
  final last = usable.last;
  final elapsed = _secondsBetween('${first['at']}', '${last['at']}');
  if (elapsed < needed) return null;
  final firstDiag = _map(first['diagnostics']);
  final lastDiag = _map(last['diagnostics']);
  final enqueuedDelta =
      _num(lastDiag['enqueued']) - _num(firstDiag['enqueued']);
  final positionDelta =
      _num(lastDiag['position']) - _num(firstDiag['position']);
  final paused = lastDiag['paused'] == true;
  final rate = _num(lastDiag['timebaseRate']);
  final flickerReason = _flickerReason(
    firstDiag,
    lastDiag,
    allowedFlushDelta: 1,
  );
  final stalls = _countStalls(usable, _num(firstDiag['enqueued']));
  final detail = paused
      ? '播放源暂停'
      : rate < 0
          ? '时间轴速率异常'
          : flickerReason ?? '生命周期读数未标记为后台';
  return PipQaVerdict(
    false,
    '前台小窗 ${elapsed.toStringAsFixed(1)} 秒不能代替 Home 后台判定：'
        '入队 +${enqueuedDelta.round()}、进度 +${positionDelta.toStringAsFixed(1)} 秒、'
        '停滞窗口 $stalls、时间轴速率 ${rate.toStringAsFixed(2)}、$detail',
  );
}

PipQaVerdict? _evaluateNativeBackground(
  Map<String, dynamic> log,
  List<Map<String, Object?>> samples,
  PipQaConfig config,
  double needed,
) {
  final backgroundSamples = samples.where((sample) {
    final diagnostics = _map(sample['diagnostics']);
    return _isBackgroundDiagnostics(diagnostics);
  }).toList(growable: false);
  final pipVisible = backgroundSamples.any(
    (sample) => _isPipVisibleInSample(sample),
  );
  final summary = _backgroundSummary(log);
  final end = _map(summary['end']);
  final start = _map(summary['start']);
  final hasStart = start.isNotEmpty;
  final allowedFlushDelta = _transitionFlushAllowance(
    start,
    end,
    summary: summary,
  );
  final didStartDelta = hasStart
      ? _counterDelta(start, end, 'didStart')
      : -1;
  if (end.isNotEmpty) {
    final verdict = _nativeBackgroundVerdict(
      end,
      needed,
      start: start,
      secondsOverride: _num(summary['seconds']),
      pipVisible: pipVisible,
      didStartDelta: didStartDelta,
      allowedFlushDelta: allowedFlushDelta,
    );
    if (verdict != null) return verdict;
  }
  for (final sample in backgroundSamples.reversed) {
    final diagnostics = _map(sample['diagnostics']);
    if (diagnostics['bgSeconds'] is num) {
      final verdict = _nativeBackgroundVerdict(
        diagnostics,
        needed,
        pipVisible: pipVisible,
        didStartDelta: hasStart ? didStartDelta : -1,
        allowedFlushDelta: allowedFlushDelta,
      );
      if (verdict != null) return verdict;
    }
  }
  return null;
}

Map<String, Object?> _backgroundSummary(Map<String, dynamic> log) {
  final summary = _map(log['backgroundSummary']);
  if (log['sampleSeconds'] is! num) return summary;
  return <String, Object?>{
    ...summary,
    'sampleSeconds': log['sampleSeconds'],
  };
}

PipQaVerdict? _evaluateNativeDiag(
  Map<String, dynamic> log,
  PipQaConfig config,
  double needed,
) {
  final nativeDiag = _map(log['nativeDiag']);
  if (nativeDiag['available'] != true) {
    return null;
  }
  final events = nativeDiag['events'];
  if (events is! List || events.isEmpty) {
    return const PipQaVerdict(
      false,
      '本轮原生画中画诊断为空：没有前后台或心跳事件',
    );
  }
  const requiredFields = <String>{
    'ts',
    'runId',
    'event',
    'appState',
    'showing',
    'hostAttached',
    'layerOwner',
    'didStart',
    'startCalls',
    'bgEnqueued',
    'progress',
    'flushShown',
    'stallShown',
    'timebaseRate',
    'paused',
  };
  final fieldOwner = <String, Object?>{};
  for (final event in events) {
    if (event is! Map) continue;
    final typedEvent = _map(event);
    fieldOwner.addAll(typedEvent);
  }
  final missing = requiredFields
      .where((field) => !fieldOwner.containsKey(field))
      .toList(growable: false)
    ..sort();
  if (missing.isNotEmpty) {
    return PipQaVerdict(
      false,
      '当前构建的原生 PiP QA 字段不足，需要包含本地 fork 诊断字段的新构建；'
          '缺少 ${missing.join(' / ')}',
    );
  }
  final typed = events
      .whereType<Map>()
      .map(_map)
      .toList(growable: false);
  if (typed.isEmpty) {
    return const PipQaVerdict(
      false,
      '本轮原生画中画诊断格式错误：没有可解析事件',
    );
  }
  if (nativeDiag['segmentComplete'] != true) {
    return const PipQaVerdict(
      false,
      '原生诊断没有记录到完整的后台到回前台窗口期；小窗未显示或未进入后台',
    );
  }
  final updatedAt = DateTime.tryParse('${log['updatedAt'] ?? ''}');
  final lastEventSeconds = _num(typed.last['ts']);
  if (updatedAt != null && lastEventSeconds > 0) {
    final maxAge = config.effectivePlaySeconds +
        config.effectiveBackgroundSeconds +
        config.effectiveAdvanceEvery * 2 +
        90;
    final age =
        updatedAt.millisecondsSinceEpoch / 1000.0 - lastEventSeconds;
    if (age > maxAge) {
      return const PipQaVerdict(
        false,
        '原生诊断记录来自上一次运行，本次没有采集到后台小窗证据',
      );
    }
  }
  final logRunId = _text(log['runId']);
  if (logRunId.isNotEmpty &&
      typed.any((event) => _text(event['runId']) != logRunId)) {
    return const PipQaVerdict(
      false,
      '原生诊断混入了其它 runId 的事件，本轮证据无效',
    );
  }
  final background = typed.where(
    (event) => _text(event['appState']) == 'background',
  ).toList(growable: false);
  if (background.isEmpty) {
    return const PipQaVerdict(
      false,
      '原生诊断没有记录到后台窗口期；小窗未显示或未进入后台',
    );
  }
  final first = background.first;
  final last = background.last;
  final elapsed = _num(typed.last['ts']) - _num(first['ts']);
  final enqueuedDelta = _num(last['bgEnqueued']) - _num(first['bgEnqueued']);
  final positionDelta = _num(last['progress']) - _num(first['progress']);
  final startCallsDelta =
      _num(last['startCalls']) - _num(first['startCalls']);
  final didStartDelta = _num(last['didStart']) - _num(first['didStart']);
  final sameFrameDelta =
      _num(last['sameFrame']) - _num(first['sameFrame']);
  final flushDelta = _num(last['flushShown']) - _num(first['flushShown']);
  final stallDelta = _num(last['stallShown']) - _num(first['stallShown']);
  final showing = background.any((event) => event['showing'] == true);
  final hostAttached = background.any(
    (event) => event['hostAttached'] == true,
  );
  final systemOwner = background.any(
    (event) => _text(event['layerOwner']) == 'system',
  );
  final lastOwner = _text(last['layerOwner']);
  final visible = showing &&
      hostAttached &&
      systemOwner &&
      lastOwner != 'host' &&
      lastOwner != 'none';
  final allowedFlushDelta = 1.0 +
      (didStartDelta > 0 ? 1.0 : 0.0) +
      (elapsed / 10).floorToDouble().clamp(0, 3).toDouble();
  final detail = '入队 +${enqueuedDelta.round()}、同帧 +${sameFrameDelta.round()}、'
      '进度 +${positionDelta.toStringAsFixed(1)} 秒、启动调用 '
      '+${startCallsDelta.round()}、didStart +${didStartDelta.round()}、'
      '清屏 +${flushDelta.round()}、补帧 +${stallDelta.round()}、'
      '小窗显示 ${showing ? '是' : '否'}、图层已挂接 '
      '${hostAttached ? '是' : '否'}、图层被接管 '
      '${systemOwner ? '是' : '否'}';
  if (elapsed < math.max(1.5, needed)) {
    return PipQaVerdict(
      false,
      '原生诊断后台段只有 ${elapsed.toStringAsFixed(1)} 秒，不足以判定小窗持续出帧：$detail',
    );
  }
  final bad = !visible ||
      didStartDelta < 1 ||
      startCallsDelta < 1 ||
      enqueuedDelta < elapsed * 5 ||
      sameFrameDelta >= enqueuedDelta * 0.8 ||
      positionDelta < elapsed * 0.35 ||
      last['paused'] == true ||
      _num(last['timebaseRate']) < 0 ||
      flushDelta > allowedFlushDelta ||
      stallDelta > elapsed * 2 ||
      lastOwner == 'none' ||
      lastOwner == 'host';
  if (!bad) return null;
  return PipQaVerdict(
    false,
    '原生诊断后台段 ${elapsed.toStringAsFixed(1)} 秒异常：$detail',
  );
}

PipQaVerdict? _nativeDiagFailure(PipQaVerdict? nativeDiag) {
  if (nativeDiag != null && !nativeDiag.pass) return nativeDiag;
  return null;
}

PipQaVerdict? _sampleDiagnosticsCapability(
  List<Map<String, Object?>> samples,
) {
  const requiredFields = <String>{
    'appState',
    'showing',
    'armed',
    'hostAttached',
    'layerReady',
    'layerHidden',
    'layerOwner',
    'layerDetached',
    'enqueued',
    'position',
    'timebaseRate',
    'paused',
    'didStart',
    'startCalls',
    'sameFrameShown',
    'flushShown',
    'stallShown',
    'controllerRebuild',
    'bgSeconds',
    'bgEnqueuedDelta',
    'bgSameFrameDelta',
    'bgPositionDelta',
    'bgDidStartDelta',
    'bgStartCallsDelta',
  };
  final present = <String>{};
  for (final sample in samples) {
    present.addAll(_map(sample['diagnostics']).keys);
  }
  final missing = requiredFields.difference(present).toList(growable: false)
    ..sort();
  if (missing.isEmpty) return null;
  return PipQaVerdict(
    false,
    '当前构建没有足够的 PiP QA 字段，需要含当前 fork 的新构建；'
        '缺少 ${missing.join(' / ')}',
  );
}

PipQaVerdict? _nativeBackgroundVerdict(
  Map<String, Object?> diagnostics,
  double needed,
  {Map<String, Object?>? start,
  double? secondsOverride,
  bool pipVisible = false,
  double didStartDelta = -1,
  double allowedFlushDelta = 1}
) {
  final seconds = secondsOverride != null && secondsOverride >= 0
      ? secondsOverride
      : _num(diagnostics['bgSeconds']);
  if (seconds < 0) return null;
  if (seconds < math.max(1.5, needed)) {
    return PipQaVerdict(
      false,
      '原生后台段只有 ${seconds.toStringAsFixed(1)} 秒，不足以判定小窗持续出帧',
    );
  }
  final enqueued = _num(diagnostics['bgEnqueuedDelta']);
  final sameFrame = _num(diagnostics['bgSameFrameDelta']);
  final position = _num(diagnostics['bgPositionDelta']);
  final starts = _num(diagnostics['bgStartCallsDelta']);
  final didStart = _num(diagnostics['bgDidStartDelta']);
  final baseline = start ?? _map(diagnostics['start']);
  final hasStart = baseline.isNotEmpty;
  final flush =
      hasStart ? _counterDelta(baseline, diagnostics, 'flushShown') : -1;
  final stall =
      hasStart ? _counterDelta(baseline, diagnostics, 'stallShown') : -1;
  final rebuilds =
      hasStart ? _counterDelta(baseline, diagnostics, 'controllerRebuild') : -1;
  final sameFrameShownDelta =
      hasStart ? _counterDelta(baseline, diagnostics, 'sameFrameShown') : -1;
  final owner = _text(diagnostics['layerOwner']);
  final bad = !pipVisible ||
      enqueued < seconds * 5 ||
      sameFrame >= enqueued * 0.8 ||
      position < seconds * 0.35 ||
      starts < 1 ||
      didStart < 1 ||
      (hasStart && didStartDelta >= 0 && didStartDelta < 1) ||
      (hasStart &&
          (flush > allowedFlushDelta ||
              stall > seconds * 2 ||
              rebuilds > 0 ||
              sameFrameShownDelta > 3)) ||
      owner != 'system' ||
      diagnostics['paused'] == true ||
      _num(diagnostics['timebaseRate']) < 0;
  final cumulativeDetail = hasStart
      ? '清屏 ${_deltaText(flush)}、补帧 ${_deltaText(stall)}、'
          '重建 ${_deltaText(rebuilds)}、同帧 ${_deltaText(sameFrameShownDelta)}'
      : '累计闪烁/重建未判定（缺后台起点快照）';
  final detail = '入队 +${enqueued.round()}、同帧 ${sameFrame.round()}、'
      '进度 +${position.toStringAsFixed(1)} 秒、启动 $starts/didStart '
      '${hasStart && didStartDelta >= 0 ? _deltaText(didStartDelta) : didStart.round()}、'
      '$cumulativeDetail、图层归属 $owner、小窗显示 ${pipVisible ? '是' : '否'}';
  if (bad) {
    return PipQaVerdict(
      false,
      '原生后台段 ${seconds.toStringAsFixed(1)} 秒异常：$detail',
    );
  }
  return null;
}

String? _flickerReason(
  Map<String, Object?> first,
  Map<String, Object?> last,
  {double allowedFlushDelta = 0}
) {
  final flushDelta = _counterDelta(first, last, 'flushShown');
  final sameFrameDelta = _counterDelta(first, last, 'sameFrameShown');
  final stallDelta = _counterDelta(first, last, 'stallShown');
  final rebuild = _counterDelta(first, last, 'controllerRebuild');
  final owner = _text(last['layerOwner']);
  if (flushDelta > allowedFlushDelta) {
    return '小窗显示中清屏 ${flushDelta.round()} 次：频闪/红屏风险';
  }
  if (sameFrameDelta > 3) {
    return '小窗显示中同帧 ${sameFrameDelta.round()} 次：重复帧重推风险';
  }
  if (stallDelta > 5) {
    return '小窗显示中补帧 ${stallDelta.round()} 次：渲染回调供帧不足';
  }
  if (rebuild > 0 || owner == 'none' || owner == 'host' || owner.isEmpty) {
    final rebuildCount = rebuild > 0 ? rebuild.round() : 0;
    return '小窗图层不稳定：重建 $rebuildCount 次、接管 '
        '${last['layerDetached'] == true ? '是' : '否'}、归属 $owner';
  }
  return null;
}

bool _isPipVisibleInSample(Map<String, Object?> sample) {
  final diagnostics = _map(sample['diagnostics']);
  return _isPipVisibleInBackground(diagnostics);
}

bool _isPipVisibleInBackground(Map<String, Object?> diagnostics) {
  if (!_isBackgroundDiagnostics(diagnostics)) return false;
  final owner = _text(diagnostics['layerOwner']);
  return diagnostics['showing'] == true &&
      diagnostics['hostAttached'] == true &&
      owner == 'system' &&
      diagnostics['layerDetached'] == true;
}

bool _isBackgroundDiagnostics(Map<String, Object?> diagnostics) {
  final appState = _text(diagnostics['appState']);
  final bgSeconds = _num(diagnostics['bgSeconds']);
  return appState == 'background' ||
      appState == 'inactive' ||
      (appState.isEmpty && bgSeconds >= 0);
}

bool _isPipVisible(Map<String, Object?> diagnostics) {
  final owner = _text(diagnostics['layerOwner']);
  return owner == 'system' &&
      diagnostics['hostAttached'] == true &&
      diagnostics['layerDetached'] == true;
}

double _transitionFlushAllowance(
  Map<String, Object?> start,
  Map<String, Object?> end, {
  Map<String, Object?> summary = const <String, Object?>{},
}) {
  var allowance = 1.0;
  if (_counterDelta(start, end, 'didStart') > 0) allowance += 1;
  final sampleSeconds = _num(summary['sampleSeconds']);
  if (sampleSeconds > 0) {
    allowance += (sampleSeconds / 10)
        .floorToDouble()
        .clamp(0, 3)
        .toDouble();
  }
  return allowance;
}

double _counterDelta(
  Map<String, Object?> first,
  Map<String, Object?> last,
  String key,
) {
  final firstValue = first[key];
  final lastValue = last[key];
  if (firstValue is! num || lastValue is! num) return -1;
  final delta = lastValue.toDouble() - firstValue.toDouble();
  return delta < 0 ? 0 : delta;
}

String _deltaText(double value) => value < 0 ? '未知' : '+${value.round()}';

int _countStalls(List<Map<String, Object?>> samples, double baseline) {
  var stalls = 0;
  var lastEnqueued = baseline;
  var consecutive = 0;
  for (final sample in samples) {
    final enqueued = _num(_map(sample['diagnostics'])['enqueued']);
    if (enqueued <= lastEnqueued) {
      consecutive += 1;
      if (consecutive >= 3) stalls += 1;
    } else {
      consecutive = 0;
    }
    lastEnqueued = enqueued;
  }
  return stalls;
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  final result = <String, Object?>{};
  value.forEach((key, mapValue) => result['$key'] = mapValue);
  return result;
}

double _num(Object? value) {
  if (value is num) return value.toDouble();
  return -1;
}

String _text(Object? value) => value == null ? '' : '$value';

double _secondsBetween(String start, String end) {
  final first = DateTime.tryParse(start);
  final last = DateTime.tryParse(end);
  if (first == null || last == null) return 0;
  return last.difference(first).inMilliseconds / 1000.0;
}
