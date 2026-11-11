import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/pages/douyin/cache.dart';
import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/player.dart';
import 'package:PiliPlus/pages/douyin/playlist.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/pages/douyin/repo.dart';
import 'package:PiliPlus/pages/douyin/web.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 抖音 / TikTok 收藏列表。
///
/// 抓取本身在原生 WKWebView 里做（网页登录 + 旁观接口返回），这里只负责
/// 展示、播放和 WebDAV 同步。
class ShortVideoFavoritesPage extends StatefulWidget {
  const ShortVideoFavoritesPage({super.key, required this.platform});

  final ShortVideoPlatform platform;

  @override
  State<ShortVideoFavoritesPage> createState() => _ShortVideoFavoritesPageState();
}

class _ShortVideoFavoritesPageState extends State<ShortVideoFavoritesPage> {
  final List<ShortVideo> _videos = [];
  bool _syncing = false;
  String _status = '';

  /// 原生一共回传了多少段响应（不等于视频条数）。
  int _rawCount = 0;

  /// 多选：全选 / 播放所选。
  bool _selecting = false;
  final Set<String> _selected = {};

  /// 正在把选中的条目下到本地。
  bool _caching = false;

  /// 本地缓存目录占用（字节）。
  int _cacheBytes = 0;

  ShortVideoPlatform get platform => widget.platform;

  @override
  void initState() {
    super.initState();
    _reload();
    _refreshCacheSize();
    _status = _videos.isEmpty
        ? '还没有抓取到收藏，点下面「打开网页」登录后抓取'
        : '本地 ${_videos.length} 条';
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoSync());
  }

  void _reload() {
    final stored = ShortVideoRepo.load(platform);
    if (!mounted) return;
    setState(() {
      _videos
        ..clear()
        ..addAll(stored);
    });
  }

  Future<void> _autoSync() async {
    if (!ShortVideoSync.configured) return;
    await _sync(silent: true);
  }

  Future<void> _sync({bool silent = false}) async {
    if (_syncing) return;
    if (!ShortVideoSync.configured) {
      SmartDialog.showToast('还没配置 WebDAV：设置 → WebDAV 设置');
      return;
    }
    setState(() => _syncing = true);
    try {
      final result = await ShortVideoSync.synchronize();
      if (!mounted) return;
      _reload();
      var text = '已同步：${result.summary}';
      if (_videos.isEmpty && result.total > 0) {
        // 总数不为 0、本页却是空的：说明那些条目不属于当前平台，
        // 或者落库失败。两种都在 summary 里写清楚了，别再说「同步成功」。
        text = '同步到 ${result.total} 条，但${platform.album}一条都没有（${result.summary}）';
      } else if (_videos.isNotEmpty) {
        text = '$text；本页 ${_videos.length} 条';
      }
      setState(() => _status = text);
      if (!silent) SmartDialog.showToast(text);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '同步失败：$e');
      if (!silent) SmartDialog.showToast('同步失败: $e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _openWeb() async {
    _rawCount = 0;
    ShortVideoWeb.onPayload = _ingest;
    ShortVideoWeb.onStatus = (text) {
      if (mounted) setState(() => _status = text);
    };
    ShortVideoWeb.onClosed = () {
      if (!mounted) return;
      _reload();
      setState(() => _status = '本地 ${_videos.length} 条');
      _sync(silent: true);
    };
    try {
      await ShortVideoWeb.open(platform);
    } catch (e) {
      if (mounted) setState(() => _status = '打开网页失败：$e');
      SmartDialog.showToast('打开网页失败: $e');
    }
  }

  void _ingest(String body) {
    _rawCount++;
    final parsed = ShortVideoParser.fromResponseBody(body, platform);
    if (parsed.isEmpty) {
      if (mounted) {
        setState(
          () => _status = '收到 $_rawCount 段数据，解析出 0 条（字段可能变了）',
        );
      }
      return;
    }

    final indexById = <String, int>{
      for (var i = 0; i < _videos.length; i++) _videos[i].id: i,
    };
    var changed = 0;
    for (final video in parsed) {
      final index = indexById[video.id];
      if (index != null) {
        // 直链是签名过的，会过期；重抓时用新的覆盖旧的。
        if (_videos[index].playUrl != video.playUrl) {
          _videos[index] = video;
          changed++;
        }
      } else {
        _videos.add(video);
        indexById[video.id] = _videos.length - 1;
        changed++;
      }
    }
    if (changed == 0) return;
    // 重新抓到了就撤掉删除墓碑，让它重新回到列表。
    ShortVideoRepo.unmarkDeleted(platform, parsed.map((e) => e.key));
    ShortVideoRepo.save(platform, _videos);
    // 抓到的每一条同时归档进「播放列表」。那是另一份存储：删收藏、清空收藏
    // 都不会动它，误删之后还能从播放列表里接着听/看，不用重新登录抓一遍。
    final archived = ShortVideoPlaylistRepo.add(
      parsed.map(PlaylistItem.fromShortVideo),
    );
    if (mounted) {
      setState(
        () => _status = '已抓取 ${_videos.length} 条'
            '${archived > 0 ? '，播放列表 +$archived' : ''}',
      );
    }
  }

  void _play(int index) {
    if (_videos.isEmpty) return;
    Get.to(
      () => ShortVideoPlayerPage(
        queue: _videos.map(QueueEntry.fromShortVideo).toList(),
        index: index,
      ),
    );
  }

  /// 只播选中的这些（顺序按列表顺序）。
  void _playSelected() {
    if (_selected.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    final queue = _videos.where((e) => _selected.contains(e.key)).toList();
    if (queue.isEmpty) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    Get.to(
      () => ShortVideoPlayerPage(
        queue: queue.map(QueueEntry.fromShortVideo).toList(),
        index: 0,
      ),
    );
  }

  void _toggleSelect(ShortVideo video) {
    setState(() {
      if (!_selected.remove(video.key)) _selected.add(video.key);
    });
  }

  void _toggleSelectMode() {
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) _selected.clear();
    });
  }

  void _selectAll() {
    setState(() {
      if (_selected.length == _videos.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_videos.map((e) => e.key));
      }
    });
  }

  void _playAll() => _play(0);

  Future<void> _clear() async {
    final keys = _videos.map((e) => e.key).toList();
    final videos = List<ShortVideo>.of(_videos);
    final positions = List<int>.generate(videos.length, (i) => i);
    setState(() {
      _videos.clear();
      _selected.clear();
      _selecting = false;
      _status = '已清空，可重新抓取';
    });
    ShortVideoRepo.save(platform, const []);
    // 留墓碑：否则下一次同步会把这些条目从远端并回来。
    ShortVideoRepo.markDeleted(platform, keys);
    for (final video in videos) {
      await ShortVideoMediaCache.remove(video);
    }
    _offerUndo(videos, positions);
    if (ShortVideoSync.configured) await _sync(silent: true);
  }

  /// 删一条：本地列表 + 删除墓碑 + 本地缓存文件。
  Future<void> _deleteOne(ShortVideo video) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: const Text('删除这条收藏？'),
      content: Text(
        '${video.title}\n\n'
        '只删本机这一条，本地缓存文件也一起删掉；'
        '下次同步时远端那份也会被排除。',
      ),
    );
    if (!confirmed || !mounted) return;
    final position = _videos.indexWhere((e) => e.key == video.key);
    setState(() {
      _videos.removeWhere((e) => e.key == video.key);
      _selected.remove(video.key);
      _status = '已删除 1 条，本地 ${_videos.length} 条';
    });
    ShortVideoRepo.save(platform, _videos);
    ShortVideoRepo.markDeleted(platform, [video.key]);
    await ShortVideoMediaCache.remove(video);
    _offerUndo([video], [position < 0 ? _videos.length : position]);
    if (ShortVideoSync.configured) await _sync(silent: true);
  }

  /// 多选删除。
  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    final targets = _videos.where((e) => _selected.contains(e.key)).toList();
    final confirmed = await showConfirmDialog(
      context: context,
      title: Text('删除所选的 ${targets.length} 条？'),
      content: const Text('本地缓存文件会一起删掉，下次同步时远端那份也会被排除。'),
    );
    if (!confirmed || !mounted) return;
    final positions = <int>[
      for (final video in targets)
        _videos.indexWhere((e) => e.key == video.key),
    ];
    setState(() {
      _videos.removeWhere((e) => _selected.contains(e.key));
      _status = '已删除 ${targets.length} 条，本地 ${_videos.length} 条';
      _selected.clear();
      _selecting = false;
    });
    ShortVideoRepo.save(platform, _videos);
    ShortVideoRepo.markDeleted(platform, targets.map((e) => e.key));
    for (final video in targets) {
      await ShortVideoMediaCache.remove(video);
    }
    _offerUndo(targets, [
      for (final position in positions)
        position < 0 ? _videos.length : position,
    ]);
    if (ShortVideoSync.configured) await _sync(silent: true);
  }

  /// 删除后给一次「撤销」。
  ///
  /// 误删收藏的代价太大：远端那份会被墓碑排掉，只能重新登录、重新抓一遍。
  /// 所以删除只改本地，并且留 6 秒的后悔药。
  void _offerUndo(List<ShortVideo> removed, List<int> positions) {
    if (removed.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已删除 ${removed.length} 条'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => _undoDelete(removed, positions),
          ),
        ),
      );
  }

  Future<void> _undoDelete(
    List<ShortVideo> removed,
    List<int> positions,
  ) async {
    ShortVideoRepo.unmarkDeleted(platform, removed.map((e) => e.key));
    setState(() {
      for (var i = 0; i < removed.length; i++) {
        final video = removed[i];
        if (_videos.any((e) => e.key == video.key)) continue;
        final at = (i < positions.length ? positions[i] : _videos.length)
            .clamp(0, _videos.length);
        _videos.insert(at, video);
      }
      _status = '已恢复 ${removed.length} 条，本地 ${_videos.length} 条';
    });
    ShortVideoRepo.save(platform, _videos);
    if (ShortVideoSync.configured) await _sync(silent: true);
  }

  /// 刷新本地缓存占用。
  Future<void> _refreshCacheSize() async {
    final bytes = await ShortVideoMediaCache.size();
    if (!mounted || bytes == _cacheBytes) return;
    setState(() => _cacheBytes = bytes);
  }

  /// 清空短视频缓存目录。
  Future<void> _clearCache() async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: const Text('清空本地缓存？'),
      content: Text(
        '会删掉已经下到本机的 ${_fmtBytes(_cacheBytes)} 视频文件。'
        '收藏列表和 WebDAV 上的记录不受影响，下次播放会重新下载。',
      ),
    );
    if (!confirmed || !mounted) return;
    await ShortVideoMediaCache.clear();
    await _refreshCacheSize();
    if (mounted) SmartDialog.showToast('缓存已清空');
  }

  /// 把选中的条目整条下到本地。
  ///
  /// 串行下载：低内存机型上并发下载会直接把进程顶掉，CDN 也会限速。
  /// 下过一次之后播放直接读文件，不再反复探测直链。
  Future<void> _cacheVideos(List<ShortVideo> videos) async {
    if (videos.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    if (_caching) {
      SmartDialog.showToast('正在缓存中');
      return;
    }
    setState(() => _caching = true);
    var ok = 0;
    var skipped = 0;
    final failures = <String>[];
    final cookie = await ShortVideoWeb.cookieHeader(
      platform.cookieDomainNeedle,
    );
    for (var i = 0; i < videos.length; i++) {
      if (!mounted) break;
      final video = videos[i];
      final existing = await ShortVideoMediaCache.localPath(video);
      if (existing != null) {
        skipped++;
        continue;
      }
      setState(
        () => _status = '缓存中 ${i + 1}/${videos.length}：${video.title}',
      );
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
        appUserAgent: platform == ShortVideoPlatform.tiktok
            ? tiktokAppUserAgent
            : '',
      );
      if (result.ok) {
        ok++;
      } else {
        failures.add('${video.title}（${result.error}）');
      }
    }
    if (!mounted) return;
    setState(() {
      _caching = false;
      _status = '缓存完成：新增 $ok 条'
          '${skipped > 0 ? '，已有 $skipped 条' : ''}'
          '${failures.isEmpty ? '' : '，失败 ${failures.length} 条'}';
    });
    await _refreshCacheSize();
    if (failures.isNotEmpty) {
      SmartDialog.showToast('失败：${failures.first}');
    }
  }

  void _cacheSelected() {
    if (_selected.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    _cacheVideos(_videos.where((e) => _selected.contains(e.key)).toList());
  }

  static String _fmtBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    final mb = bytes / 1024 / 1024;
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
  }

  /// 插到「下一首播放」：正在播的 B 站 / 抖音队列播完这一条就接上它。
  void _queueNext(Iterable<ShortVideo> videos) {
    final entries = videos.map(QueueEntry.fromShortVideo);
    final added = QueueBus.addNext(entries);
    if (added == 0) {
      SmartDialog.showToast('这些已经在下一首队列里了');
      return;
    }
    SmartDialog.showToast('已加入下一首播放（待播 ${QueueBus.pending} 条）');
    setState(() {});
  }

  /// 加进「播放列表」（B 站 / 抖音 / TikTok 混在一起播的那份）。
  void _addToPlaylist(Iterable<ShortVideo> videos) {
    final added = ShortVideoPlaylistRepo.add(
      videos.map(PlaylistItem.fromShortVideo),
    );
    if (added == 0) {
      SmartDialog.showToast('这些已经在播放列表里了');
      return;
    }
    SmartDialog.showToast(
      '已加入播放列表（共 ${ShortVideoPlaylistRepo.length} 条）',
    );
  }

  void _addSelectedToPlaylist() {
    if (_selected.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    _addToPlaylist(_videos.where((e) => _selected.contains(e.key)));
  }

  void _queueSelectedNext() {
    if (_selected.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    _queueNext(_videos.where((e) => _selected.contains(e.key)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(platform.title),
        actions: [
          IconButton(
            tooltip: '播放列表',
            onPressed: () => Get.to(() => const ShortVideoPlaylistPage()),
            icon: const Icon(Icons.queue_music),
          ),
          IconButton(
            tooltip: 'WebDAV 同步',
            onPressed: _syncing ? null : () => _sync(),
            icon: _syncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: _videos.isEmpty ? null : _clear,
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: _selecting ? '退出多选' : '多选',
            onPressed: _videos.isEmpty ? null : _toggleSelectMode,
            icon: Icon(_selecting ? Icons.close : Icons.checklist),
          ),
          IconButton(
            tooltip: '全部播放',
            onPressed: _videos.isEmpty ? null : _playAll,
            icon: const Icon(Icons.play_arrow),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _videos.isEmpty ? _empty(theme) : _list(theme),
          ),
          _bottomBar(theme),
        ],
      ),
    );
  }

  Widget _empty(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 44,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              '还没有收藏',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              '点下面「打开网页」，在网页里登录 ${platform.album}，'
              '然后点「开始抓取」，抓完回来自动带过来。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '网页打不开也不要紧：在 Kumone 里抓同一份收藏，'
              '两台手机配同一个 WebDAV，这里点右上角同步就行。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(ThemeData theme) {
    return ListView.builder(
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        final video = _videos[index];
        final checked = _selected.contains(video.key);
        return ListTile(
          onTap: () => _selecting ? _toggleSelect(video) : _play(index),
          onLongPress: () {
            if (!_selecting) setState(() => _selecting = true);
            _toggleSelect(video);
          },
          selected: _selecting && checked,
          leading: _selecting
              ? Icon(
                  checked
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: checked ? theme.colorScheme.primary : null,
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 48,
                    height: 64,
                    child: video.cover.isEmpty
                        ? Container(
                            color: theme.dividerColor.withValues(alpha: 0.1),
                          )
                        : Image.network(
                            video.cover,
                            fit: BoxFit.cover,
                            cacheWidth: 180,
                            errorBuilder: (_, _, _) => Container(
                              color: theme.dividerColor.withValues(alpha: 0.1),
                            ),
                          ),
                  ),
                ),
          title: Text(
            video.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${video.author.isEmpty ? platform.album : video.author} · ${video.durationText}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'play':
                  _play(index);
                case 'next':
                  _queueNext([video]);
                case 'playlist':
                  _addToPlaylist([video]);
                case 'cache':
                  _cacheVideos([video]);
                case 'delete':
                  _deleteOne(video);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'play', child: Text('播放')),
              PopupMenuItem(value: 'next', child: Text('下一首播放')),
              PopupMenuItem(value: 'playlist', child: Text('加入播放列表')),
              PopupMenuItem(value: 'cache', child: Text('缓存到本地')),
              PopupMenuItem(value: 'delete', child: Text('删除（含缓存）')),
            ],
          ),
        );
      },
    );
  }

  Widget _bottomBar(ThemeData theme) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _status,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_cacheBytes > 0)
                  TextButton(
                    onPressed: _caching ? null : _clearCache,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Text(
                      '缓存 ${_fmtBytes(_cacheBytes)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_selecting)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _videos.isEmpty ? null : _selectAll,
                    icon: const Icon(Icons.select_all),
                    label: Text(
                      _selected.length == _videos.length && _videos.isNotEmpty
                          ? '取消全选'
                          : '全选',
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _playSelected,
                    icon: const Icon(Icons.playlist_play),
                    label: Text('播放所选 ${_selected.length} 条'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _selected.isEmpty ? null : _queueSelectedNext,
                    icon: const Icon(Icons.queue_play_next),
                    label: Text('下一首 ${_selected.length} 条'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _selected.isEmpty
                        ? null
                        : _addSelectedToPlaylist,
                    icon: const Icon(Icons.playlist_add),
                    label: Text('加入列表 ${_selected.length} 条'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _selected.isEmpty || _caching
                        ? null
                        : _cacheSelected,
                    icon: const Icon(Icons.download_for_offline_outlined),
                    label: Text('缓存 ${_selected.length} 条'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _selected.isEmpty ? null : _deleteSelected,
                    icon: const Icon(Icons.delete_outline),
                    label: Text('删除 ${_selected.length} 条'),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _openWeb,
                      icon: const Icon(Icons.public),
                      label: const Text('打开网页 / 抓取'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: _videos.isEmpty ? null : _playAll,
                    child: const Text('全部播放'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}