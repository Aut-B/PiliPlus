import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/pages/douyin/player_bridge.dart';
import 'package:PiliPlus/pages/douyin/player.dart';
import 'package:PiliPlus/pages/douyin/player_session.dart';
import 'package:PiliPlus/pages/douyin/playlist.dart';
import 'package:PiliPlus/pages/douyin/qa_config.dart';
import 'package:PiliPlus/pages/douyin/qa_recorder.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/pages/douyin/repo.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';

export 'package:PiliPlus/pages/douyin/qa_config.dart'
    show PipQaConfig, PipQaRuntime;

/// 读取真机自动 QA 配置。
/// QA config injected from the host: build time (`--dart-define`) or launch
/// time (`--env`). Both skip the phone UI entirely, so a USB-only harness can
/// drive the player without tapping anything.
const String _pipQaConfigDefine = String.fromEnvironment('PIP_QA_CONFIG');
const MethodChannel _qaDumpChannel = MethodChannel('PiliPlus/QaDump');

Future<PipQaConfig?> loadPipQaConfig() async {
  if (!Platform.isIOS) return null;
  final fromHost = _configFromHost(
    _pipQaConfigDefine.isNotEmpty
        ? _pipQaConfigDefine
        : Platform.environment['PIP_QA_CONFIG'],
  );
  if (fromHost != null) {
    PipQaConfig.source = 'host';
    return fromHost;
  }
  // 启动参数（`dvt launch 'bundle -PIPQA {json}'`）。
  //
  // 这条通道不需要 App 有任何沙盒外权限，也不需要重打包，是 TrollStore 包
  // 最稳的一条配置送达路径：env 在部分系统版本上不会进 `Platform.environment`。
  try {
    final raw = await _qaDumpChannel.invokeMethod<String>('launchConfig');
    final fromLaunch = _configFromHost(raw);
    if (fromLaunch != null) {
      PipQaConfig.source = 'launch';
      return fromLaunch;
    }
  } catch (_) {}
  // TrollStore 安装的包没有 installd 记录，house_arrest 会
  // InstallationLookupFailed，写不进 Documents。原生侧仍然能读写
  // /private/var/mobile/Media/piliplus_qa/，所以优先走这条通道。
  try {
    final raw = await _qaDumpChannel.invokeMethod<String>(
      'read',
      <String, Object?>{'name': PipQaConfig.fileName},
    );
    final fromMedia = _configFromHost(raw);
    if (fromMedia != null) {
      PipQaConfig.source = 'media';
      return fromMedia;
    }
  } catch (_) {}
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/${PipQaConfig.fileName}');
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    final config = PipQaConfig.fromJson(decoded.cast<String, dynamic>());
    if (!config.enabled) return null;
    PipQaConfig.source = 'documents';
    return config;
  } catch (_) {
    return null;
  }
}

/// 把「这一轮 QA 是怎么启动的」落盘。
///
/// 之前几轮体检都是「脚本以为启动了、App 其实没进播放页」，而现场只有一张
/// 首页截图。开机诊断固定写到 `qa_boot.json`（Media 目录 + Documents + NSLog
/// 三条通道），失败时也写，能直接区分「配置没送到」「收藏为空」「导航抛异常」。
Future<void> dumpQaBoot(Map<String, Object?> payload) async {
  try {
    await _qaDumpChannel.invokeMethod<List<Object?>>('write', <String, Object?>{
      'name': 'qa_boot.json',
      'content': jsonEncode(<String, Object?>{
        'at': DateTime.now().toIso8601String(),
        ...payload,
      }),
    });
  } catch (_) {}
}

PipQaConfig? _configFromHost(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return null;
  try {
    final jsonText = text.startsWith('{')
        ? text
        : utf8.decode(base64.decode(text));
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map) return null;
    final config = PipQaConfig.fromJson(decoded.cast<String, dynamic>());
    return config.enabled ? config : null;
  } catch (_) {
    return null;
  }
}

List<QueueEntry> buildPipQaQueue(PipQaConfig config) {
  final byKey = <String, QueueEntry>{};
  for (final item in ShortVideoPlaylistRepo.load()) {
    final entry = item.toEntry();
    if (entry != null) byKey[entry.key] = entry;
  }
  for (final video in ShortVideoRepo.loadAll()) {
    final entry = QueueEntry.fromShortVideo(video);
    byKey.putIfAbsent(entry.key, () => entry);
  }
  final queue = <QueueEntry>[];
  for (final key in config.seedKeys) {
    final entry = byKey.remove(key);
    if (entry != null) queue.add(entry);
  }
  queue.addAll(byKey.values);
  return queue;
}

/// QA 启动后延迟进入已保存的播放列表。
///
/// 必须等 GetMaterialApp 的首帧完成，否则页面路由还没有 Navigator。
Future<void> startPipQaIfRequested(PipQaConfig? config) async {
  if (PipQaRuntime.isStarted) return;
  PipQaConfig.active = config;
  registerShortVideoPlayerPageBuilder(
    (queue, index, {showImmediately = false}) => ShortVideoPlayerPage(
      queue: queue,
      index: index,
      showImmediately: showImmediately,
    ),
  );
  if (config == null || !config.autoStart) return;
  if (await _qaAlreadyRan(config)) return;
  PipQaRuntime.begin(config);
  ShortVideoSession.instance.resetPipQaCounters();
  try {
    final queue = buildPipQaQueue(config);
    if (queue.isEmpty) {
      await _finishQaWithFailure(
        config,
        '没有可播放的收藏或永久播放列表，自动 QA 无法开始',
      );
      return;
    }
    final index = config.index.clamp(0, queue.length - 1);
    unawaited(() async {
      try {
        await _startPipQaRun(config, queue, index);
      } catch (error) {
        await _finishQaWithFailure(
          config,
          '自动 QA 生命周期异常：$error',
        );
      }
    }());
  } catch (error) {
    await _finishQaWithFailure(config, '自动 QA 启动失败：$error');
  }
}

Future<void> _startPipQaRun(
  PipQaConfig config,
  List<QueueEntry> queue,
  int index,
) async {
  await Future<void>.delayed(const Duration(seconds: 2));
  unawaited(() async {
    try {
      await ShortVideoPlayerRouteNavigator.open(
        queue,
        index,
        showImmediately: false,
        replaceCurrent: true,
      );
    } catch (error) {
      await _finishQaWithFailure(
        config,
        '无法打开短视频播放页：$error',
      );
    }
  }());
  await _drivePipQaLifecycle(config);
}

Future<void> _finishQaWithFailure(
  PipQaConfig config,
  String verdict,
) async {
  if (PipQaRuntime.isFinished) return;
  PipQaRuntime.fail(verdict);
  await PipQaRecorder.writeFailure(config, verdict);
  PipQaRuntime.markFinished();
  await _markQaRan(config);
}

Future<File?> _qaMarker(PipQaConfig config) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/pip_qa_done_${config.runId}.json');
  } catch (_) {
    return null;
  }
}

Future<bool> _qaAlreadyRan(PipQaConfig config) async {
  final file = await _qaMarker(config);
  return file != null && await file.exists();
}

Future<void> _markQaRan(PipQaConfig config) async {
  try {
    final file = await _qaMarker(config);
    await file?.writeAsString(
      jsonEncode(<String, Object?>{
        'runId': config.runId,
        'at': DateTime.now().toIso8601String(),
      }),
      flush: true,
    );
  } catch (_) {}
}

Future<void> _drivePipQaLifecycle(PipQaConfig config) async {
  try {
    await PipQaRuntime.waitReady().timeout(const Duration(seconds: 45));
  } catch (_) {
    final verdict = PipQaRuntime.failureVerdict ??
        '播放器未在 45 秒内就绪，自动 QA 无法开始';
    await _finishQaWithFailure(config, verdict);
    return;
  }
  final earlyFailure = PipQaRuntime.failureVerdict;
  if (earlyFailure != null) {
    await _finishQaWithFailure(config, earlyFailure);
    return;
  }
  await Future<void>.delayed(
    Duration(seconds: config.effectivePlaySeconds),
  );
  final foregroundStartLabel = config.foregroundPipStartLabel;
  if (config.requiresForegroundPipStart) {
    try {
      await ShortVideoSession.instance.startPip();
      final session = ShortVideoSession.instance;
      final hasForegroundStart = PipQaRuntime.manualStartOrdered ||
          PipQaRuntime.foregroundPipStarts > 0 ||
          session.foregroundPipStarts > 0 ||
          (session.appState == 'active' && session.pipActive);
      if (!hasForegroundStart) {
        await _finishQaWithFailure(
          config,
          '$foregroundStartLabel没有记录到前台启动画中画：'
          '本次命令和已有前台小窗都没有证据；'
          '自动 QA 无法采样后台小窗',
        );
        return;
      }
    } catch (error) {
      await _finishQaWithFailure(
        config,
        '$foregroundStartLabel无法在前台启动画中画：$error；'
        '自动 QA 无法采样后台小窗',
      );
      return;
    }
  }
  try {
    await const MethodChannel('PiliPlus/PipQa').invokeMethod<void>(
      'background',
      <String, Object?>{
        'seconds': config.effectiveBackgroundSeconds,
        'runId': config.runId,
      },
    );
  } catch (error) {
    final verdict = '无法让真机宿主切到后台：$error；自动 QA 无法采样后台小窗';
    await _finishQaWithFailure(config, verdict);
    return;
  }
  await PipQaRuntime.waitFinished().timeout(
    Duration(
      seconds: config.effectivePlaySeconds +
          config.effectiveBackgroundSeconds +
          config.effectiveAdvanceEvery * 2 +
          35,
    ),
    onTimeout: () => Future<void>.value(),
  );
  await _markQaRan(config);
  final failure = PipQaRuntime.failureVerdict;
  if (failure != null && !PipQaRuntime.isFinished) {
    await _finishQaWithFailure(config, failure);
    return;
  }
  if (!PipQaRuntime.isFinished) {
    final verdict = '自动 QA 在收尾时间内没有写出判定';
    await _finishQaWithFailure(config, verdict);
  }
}
