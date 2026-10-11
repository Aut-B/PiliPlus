import 'dart:async' show StreamSubscription, Timer;
import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/dialog/simple_dialog_option.dart';
import 'package:PiliPlus/common/widgets/progress_bar/segment_progress_bar.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/sponsor_block.dart';
import 'package:PiliPlus/models/common/sponsor_block/segment_model.dart';
import 'package:PiliPlus/models/common/sponsor_block/segment_type.dart';
import 'package:PiliPlus/models/common/sponsor_block/skip_type.dart';
import 'package:PiliPlus/models_new/sponsor_block/segment_item.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

mixin BlockConfigMixin {
  late final pgcSkipType = Pref.pgcSkipType;
  late final enablePgcSkip = pgcSkipType != SkipType.disable;
  late final enableSponsorBlock = Pref.enableSponsorBlock;
  late final enableBlock = enableSponsorBlock || enablePgcSkip;
  late final blockColor = Pref.blockColor;
  late final blockLimit = Pref.blockLimit * 1000;
  late final blockSettings = Pref.blockSettings;
  late final enableList = blockSettings
      .where((item) => item.second != SkipType.disable)
      .map((item) => item.first.name)
      .toSet();

  Color _getColor(SegmentType segment) => blockColor[segment.index];

  /// iOS 上此刻是否应当推迟「自动跳过」。
  ///
  /// 自动跳过会主动 seek，而 seek 与 iOS 画中画的画面源切换存在竞态——小窗正在
  /// 显示、或 App 已经退到后台时发起 seek，真机上出现过「回到视频页后画面是黑的，
  /// 声音与弹幕都正常」。默认不推迟，播放器侧会按画中画状态与前后台覆写它。
  bool get deferAutoSkip => false;
}

mixin BlockMixin on GetxController {
  int? _lastBlockPos;
  BlockConfigMixin get blockConfig;
  StreamSubscription<Duration>? _blockListener;
  StreamSubscription<Duration>? get blockListener => _blockListener;
  late final List<SegmentModel> _segmentList = <SegmentModel>[];
  late final RxList<Segment> segmentProgressList = <Segment>[].obs;

  Timer? _skipTimer;
  late final listKey = GlobalKey<AnimatedListState>();
  late final List<Object> listData = [];

  /// 因「小窗显示中 / App 不在前台」而被推迟的跳转目标（毫秒）。
  int? _deferredSkipMs;

  RxString? get videoLabel => null;
  Player? get player;
  bool get autoPlay;
  int? get timeLength;
  bool get preInitPlayer;
  int get currPosInMilliseconds;
  bool get isFullScreen => false;

  bool get isUgc;
  bool get isFileSource => false;
  late final isBlock = isUgc || !blockConfig.enablePgcSkip;

  Future<void> querySponsorBlock({
    required String bvid,
    required int cid,
  }) async {
    resetBlock();

    final result = await SponsorBlock.getSkipSegments(bvid: bvid, cid: cid);
    switch (result) {
      case Success<List<SegmentItemModel>>(:final response):
        handleSBData(response);
      case Error(:final code) when code != 404:
        if (kDebugMode) {
          result.toast();
        }
      default:
    }
  }

  void initSkip() {
    if (isClosed) return;
    if (_segmentList.isNotEmpty) {
      _blockListener?.cancel();
      _blockListener = player?.stream.position.listen((position) {
        int currentPos = position.inSeconds;
        // 先前被推迟的那一跳：条件一解除（回到前台且小窗已收）立刻补上。
        // 守在位置回调的最前面，且不要求跨秒——条件解除的那一刻，播放位置
        // 未必刚好跨过一个整秒。
        final deferred = _deferredSkipMs;
        if (deferred != null && !blockConfig.deferAutoSkip) {
          _deferredSkipMs = null;
          // 期间用户可能已经自己拖过了这一段，这时再往回跳是帮倒忙。
          if (position.inMilliseconds < deferred) {
            seekTo(Duration(milliseconds: deferred), isSeek: false);
          }
        }
        if (currentPos != _lastBlockPos) {
          _lastBlockPos = currentPos;
          final msPos = currentPos * 1000;
          for (SegmentModel item in _segmentList) {
            // if (kDebugMode) {
            //   debugPrint(
            //       '${position.inSeconds},,${item.segment.first},,${item.segment.second},,${item.skipType.name},,${item.hasSkipped}');
            // }
            if (msPos <= item.segment.$1 && item.segment.$1 <= msPos + 1000) {
              switch (item.skipType) {
                case SkipType.alwaysSkip:
                  _skipSegment(item);
                  break;
                case SkipType.skipOnce:
                  if (!item.hasSkipped) {
                    _skipSegment(item, markSkipped: true);
                  }
                  break;
                case SkipType.skipManually:
                  onAddItem(item);
                  break;
                default:
                  break;
              }
              break;
            }
          }
        }
      });
    }
  }

  Future<void> handleSBData(List<SegmentItemModel> list) async {
    if (isClosed) return;

    if (list.isNotEmpty) {
      try {
        Future<void>? future;
        final duration = list.first.videoDuration ?? timeLength!;
        // segmentList
        _segmentList.addAll(
          list
              .where(
                (item) =>
                    blockConfig.enableList.contains(item.category) &&
                    item.segment[1] >= item.segment[0],
              )
              .map(
                (item) {
                  final segmentModel = SegmentModel.fromItemModel(
                    item,
                    isBlock ? blockConfig : null,
                  );
                  if (segmentModel.segment == const (0, 0)) {
                    videoLabel?.value +=
                        '${videoLabel!.value.isNotEmpty ? '/' : ''}${segmentModel.segmentType.title}';
                  }

                  if (_blockListener == null && autoPlay && player != null) {
                    final currPos = currPosInMilliseconds;

                    if (segmentModel.segment.contains(currPos)) {
                      _lastBlockPos = currPos;

                      switch (segmentModel.skipType) {
                        case SkipType.alwaysSkip:
                        case SkipType.skipOnce:
                          // 小窗显示中 / App 在后台：先把这一跳记下，等条件解除再补做。
                          if (blockConfig.deferAutoSkip) {
                            _deferredSkipMs = segmentModel.segment.$2;
                            break;
                          }
                          segmentModel.hasSkipped = true;
                          if (!isFileSource && player!.state.playing) {
                            future = onSkip(segmentModel);
                          } else {
                            player!.stream.playing.firstWhere((e) {
                              if (e) {
                                future = onSkip(segmentModel);
                                return true;
                              }
                              return false;
                            }, orElse: () => false);
                          }
                          break;
                        case SkipType.skipManually:
                          onAddItem(segmentModel);
                          break;
                        default:
                          break;
                      }
                    }
                  }

                  return segmentModel;
                },
              ),
        );

        // _segmentProgressList
        segmentProgressList.addAll(
          _segmentList.map((e) {
            double start = (e.segment.$1 / duration).clamp(0.0, 1.0);
            double end = (e.segment.$2 / duration).clamp(0.0, 1.0);
            return Segment(
              start: start,
              end: end,
              color: blockConfig._getColor(e.segmentType),
            );
          }),
        );

        if (_blockListener == null && (autoPlay || preInitPlayer)) {
          await future;
          initSkip();
        }
      } catch (e) {
        if (kDebugMode) debugPrint('failed to parse sponsorblock: $e');
      }
    }
  }

  void onAddItem(Object item) {
    if (listData.contains(item)) return;
    listData.insert(0, item);
    listKey.currentState?.insertItem(0);
    _skipTimer ??= Timer.periodic(const Duration(seconds: 4), (_) {
      if (listData.isNotEmpty) {
        onRemoveItem(listData.length - 1, listData.last);
      }
    });
  }

  void onRemoveItem(int index, Object item) {
    EasyThrottle.throttle(
      'onRemoveItem',
      const Duration(milliseconds: 500),
      () {
        try {
          listData.removeAt(index);
          if (listData.isEmpty) {
            _stopSkipTimer();
          }
          listKey.currentState?.removeItem(
            index,
            (context, animation) => buildItem(item, animation),
          );
        } catch (_) {}
      },
    );
  }

  Widget buildItem(Object item, Animation<double> animation) =>
      throw UnimplementedError();

  void _stopSkipTimer() {
    if (_skipTimer != null) {
      _skipTimer!.cancel();
      _skipTimer = null;
    }
  }

  Future<void>? seekTo(Duration duration, {required bool isSeek});

  void _skipToast(SegmentModel item) {
    if (autoPlay && Pref.blockToast) {
      _showBlockToast('已跳过${item.segmentType.shortTitle}片段');
    }
    if (isBlock && Pref.blockTrack) {
      SponsorBlock.viewedVideoSponsorTime(item.uuid);
    }
  }

  /// 命中一个跳过点时统一从这里走：能跳就跳，不能跳（小窗显示中 / App 不在
  /// 前台）就记下来，等条件解除后补跳。
  ///
  /// [markSkipped] 为真时，只有真正跳了才记「已跳过」——被推迟的那一次不能
  /// 记账，否则补跳的机会就没了。
  void _skipSegment(SegmentModel item, {bool markSkipped = false}) {
    if (blockConfig.deferAutoSkip) {
      _deferredSkipMs = item.segment.$2;
      return;
    }
    if (markSkipped) {
      item.hasSkipped = true;
    }
    onSkip(item, isSeek: false);
  }

  Future<void> onSkip(
    SegmentModel item, {
    bool isSkip = true,
    bool isSeek = true,
  }) async {
    try {
      await seekTo(
        Duration(milliseconds: item.segment.$2),
        isSeek: isSeek,
      );
      if (isSkip) {
        _skipToast(item);
      } else {
        _showBlockToast('已跳至${item.segmentType.shortTitle}');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('failed to skip: $e');
      if (isSkip) {
        _showBlockToast('${item.segmentType.shortTitle}片段跳过失败');
      } else {
        _showBlockToast('跳转失败');
      }
    }
  }

  void _showBlockToast(String msg) {
    SmartDialog.showToast(
      msg,
      alignment: isFullScreen ? const Alignment(0, 0.7) : null,
    );
  }

  void _showVoteDialog(SegmentModel segment) {
    showDialog(
      context: Get.context!,
      builder: (context) => SimpleDialog(
        clipBehavior: .hardEdge,
        contentPadding: const .symmetric(vertical: 10),
        children: [
          DialogOption(
            child: const Text('赞成票', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Get.back();
              _doVote(segment.uuid, 1);
            },
          ),
          DialogOption(
            child: const Text('反对票', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Get.back();
              _doVote(segment.uuid, 0);
            },
          ),
          DialogOption(
            child: const Text('更改类别', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Get.back();
              _showCategoryDialog(segment);
            },
          ),
        ],
      ),
    );
  }

  void _doVote(String uuid, int type) => SponsorBlock.voteOnSponsorTime(
    uuid: uuid,
    type: type,
  ).then((i) => SmartDialog.showToast(i.isSuccess ? '投票成功' : '投票失败: $i'));

  void _showCategoryDialog(SegmentModel segment) {
    showDialog(
      context: Get.context!,
      builder: (context) => SimpleDialog(
        clipBehavior: .hardEdge,
        contentPadding: const .symmetric(vertical: 10),
        children: SegmentType.values
            .map(
              (item) => ListTile(
                dense: true,
                onTap: () {
                  Get.back();
                  SponsorBlock.voteOnSponsorTime(
                    uuid: segment.uuid,
                    category: item,
                  ).then((i) {
                    SmartDialog.showToast(
                      '类别更改${i.isSuccess ? '成功' : '失败: $i'}',
                    );
                  });
                },
                title: Text.rich(
                  TextSpan(
                    children: [
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Container(
                          height: 10,
                          width: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: blockConfig._getColor(item),
                          ),
                        ),
                        style: const TextStyle(fontSize: 14, height: 1),
                      ),
                      TextSpan(
                        text: ' ${item.title}',
                        style: const TextStyle(fontSize: 14, height: 1),
                      ),
                    ],
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  void showSBDetail() {
    showDialog(
      context: Get.context!,
      builder: (context) => SimpleDialog(
        clipBehavior: .hardEdge,
        contentPadding: const .symmetric(vertical: 10),
        children: _segmentList
            .map(
              (item) => ListTile(
                onTap: () {
                  Get.back();
                  if (isBlock) {
                    _showVoteDialog(item);
                  }
                },
                dense: true,
                title: Text.rich(
                  TextSpan(
                    children: [
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Container(
                          height: 10,
                          width: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: blockConfig._getColor(item.segmentType),
                          ),
                        ),
                        style: const TextStyle(fontSize: 14, height: 1),
                      ),
                      TextSpan(
                        text: ' ${item.segmentType.title}',
                        style: const TextStyle(fontSize: 14, height: 1),
                      ),
                    ],
                  ),
                ),
                contentPadding: const EdgeInsets.only(left: 16, right: 8),
                subtitle: Text(
                  '${DurationUtils.formatDuration(item.segment.$1 / 1000)} 至 ${DurationUtils.formatDuration(item.segment.$2 / 1000)}',
                  style: const TextStyle(fontSize: 13),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.skipType.label,
                      style: const TextStyle(fontSize: 13),
                    ),
                    if (item.segment.$2 != 0)
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: IconButton(
                          tooltip: item.skipType == SkipType.showOnly
                              ? '跳至此片段'
                              : '跳过此片段',
                          onPressed: () {
                            Get.back();
                            onSkip(
                              item,
                              isSkip: item.skipType != SkipType.showOnly,
                              isSeek: false,
                            );
                          },
                          style: IconButton.styleFrom(
                            padding: EdgeInsets.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: Icon(
                            item.skipType == SkipType.showOnly
                                ? Icons.my_location
                                : MdiIcons.debugStepOver,
                            size: 18,
                            color: ColorScheme.of(
                              context,
                            ).onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      )
                    else
                      const SizedBox(width: 10),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  void cancelBlockListener() {
    if (_blockListener != null) {
      _blockListener!.cancel();
      _blockListener = null;
    }
  }

  void resetBlock() {
    cancelBlockListener();
    _deferredSkipMs = null;
    _lastBlockPos = null;
    videoLabel?.value = '';
    _segmentList.clear();
    segmentProgressList.clear();
  }

  Duration? getFirstSegment([int pos = 0]) {
    for (var i in _segmentList..sort()) {
      final (start, end) = i.segment;
      if (start == end) {
        continue;
      } else if (start - pos < 100) {
        if (switch (i.skipType) {
          .alwaysSkip => true,
          .skipOnce => !i.hasSkipped,
          _ => false,
        }) {
          _skipToast(i);
          i.hasSkipped = true;
          pos = math.max(pos, i.segment.$2);
        }
      } else {
        break;
      }
    }
    if (pos != 0) {
      return Duration(milliseconds: pos);
    }
    return null;
  }

  @override
  void onClose() {
    _stopSkipTimer();
    if (blockConfig.enableBlock) {
      resetBlock();
    }
    super.onClose();
  }
}
