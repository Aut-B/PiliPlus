import 'dart:collection';
import 'dart:io' show File;

import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:path/path.dart' as path;

class PlDanmakuController {
  PlDanmakuController(
    this._cid,
    this._plPlayerController,
    this._isFileSource,
  ) : _mergeDanmaku = _plPlayerController.mergeDanmaku;

  final int _cid;
  final PlPlayerController _plPlayerController;
  final bool _mergeDanmaku;
  final bool _isFileSource;

  late final _isLogin = Accounts.main.isLogin;

  final Map<int, List<DanmakuElem>> _dmSegMap = HashMap();
  // 已请求的段落标记
  late final Set<int> _requestedSeg = HashSet();
  // 分片连续失败次数 / 最近一次失败时刻（失败退避用）
  final Map<int, int> _segFailures = HashMap();
  final Map<int, DateTime> _segFailedAt = HashMap();

  /// 同一弹幕分片的重试退避上限（秒）。
  ///
  /// [getCurrentDanmaku] 由播放进度驱动，每 100 毫秒回调一次；而失败时原先会立刻清掉
  /// 「已请求」标记，于是下一次回调立即重发——每秒最多 10 次，且完全不看上一次的结果。
  /// 一次普通的网络抖动（切前后台时连接被系统收走、连播换源等）就足以把它变成持续数分钟的
  /// 请求风暴：同一条错误反复弹出、`isolate: true` 的 protobuf 解析不停新建 isolate，
  /// 连接被占满后整个 App 对 `app.bilibili.com` 的请求（视频详情、评论、弹幕）全部失败，
  /// 且因为风暴不会自行停止，只能杀掉进程才恢复。
  ///
  /// 这里改为指数退避（1/2/4/8/16 秒，封顶 30 秒），最坏情况每 30 秒才重试一次。
  static const int _maxSegBackoff = 30;

  void dispose() {
    _dmSegMap.clear();
    _requestedSeg.clear();
    _segFailures.clear();
    _segFailedAt.clear();
  }

  Future<void> queryDanmaku(int segmentIndex) async {
    if (_isFileSource) {
      return;
    }
    // App 不在前台时不取新分片：画中画期间画面由系统小窗显示，Flutter 侧的弹幕
    // 本来就没人看得到，而在后台发起请求正是连接最容易被系统收走的时候——一旦
    // 失败就会退化成重试风暴。回到前台后按当前进度重新取即可。
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState != null &&
        lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    if (_requestedSeg.contains(segmentIndex)) {
      return;
    }
    final int failures = _segFailures[segmentIndex] ?? 0;
    if (failures > 0) {
      final failedAt = _segFailedAt[segmentIndex];
      final int backoff = failures >= 6 ? _maxSegBackoff : 1 << (failures - 1);
      if (failedAt != null &&
          DateTime.now().difference(failedAt) < Duration(seconds: backoff)) {
        return;
      }
    }
    _requestedSeg.add(segmentIndex);
    final res = await DmGrpc.dmSegMobile(
      cid: _cid,
      segmentIndex: segmentIndex + 1,
    );

    if (res case Success(:final response)) {
      _segFailures.remove(segmentIndex);
      _segFailedAt.remove(segmentIndex);
      if (response.state == 1) {
        _plPlayerController.dmState.add(_cid);
      }
      handleDanmaku(response.elems);
    } else {
      _requestedSeg.remove(segmentIndex);
      _segFailures[segmentIndex] = failures + 1;
      _segFailedAt[segmentIndex] = DateTime.now();
    }
  }

  void handleDanmaku(List<DanmakuElem> elems) {
    if (elems.isEmpty) return;
    final uniques = HashMap<String, DanmakuElem>();

    final filters = _plPlayerController.filters;
    final shouldFilter = filters.count != 0;
    for (final element in elems) {
      if (_isLogin) {
        element.isSelf = element.midHash == _plPlayerController.midHash;
      }

      if (!element.isSelf) {
        if (_mergeDanmaku) {
          final elem = uniques[element.content];
          if (elem == null) {
            uniques[element.content] = element..count = 1;
          } else {
            elem.count++;
            continue;
          }
        }

        if (shouldFilter && filters.remove(element)) {
          continue;
        }
      }

      final int pos = element.progress ~/ 100; //每0.1秒存储一次
      (_dmSegMap[pos] ??= []).add(element);
    }
  }

  List<DanmakuElem>? getCurrentDanmaku(int progress) {
    if (_isFileSource) {
      initFileDmIfNeeded();
    } else {
      final int segmentIndex = DmUtils.calcSegment(progress);
      if (!_requestedSeg.contains(segmentIndex)) {
        queryDanmaku(segmentIndex);
        return null;
      }
    }
    return _dmSegMap[progress ~/ 100];
  }

  bool _fileDmLoaded = false;

  void initFileDmIfNeeded() {
    if (_fileDmLoaded) return;
    _fileDmLoaded = true;
    _initFileDm();
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> _initFileDm() async {
    try {
      final file = File(
        path.join(
          (_plPlayerController.dataSource as FileSource).dir,
          PathUtils.danmakuName,
        ),
      );
      if (!file.existsSync()) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return;
      final elem = DmSegMobileReply.fromBuffer(bytes).elems;
      handleDanmaku(elem);
    } catch (e, s) {
      Utils.reportError(e, s);
    }
  }
}
