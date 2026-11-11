import 'dart:convert';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/player.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 播放列表里的一条。
///
/// B 站收藏和抖音 / TikTok 收藏以前各播各的，这里把两种条目放在同一个列表里，
/// 顺序由用户决定——这才是「互通」。
class PlaylistItem {
  const PlaylistItem({
    required this.type,
    required this.title,
    required this.author,
    required this.cover,
    required this.durationMs,
    this.short,
    this.bvid,
  });

  factory PlaylistItem.fromShortVideo(ShortVideo video) => PlaylistItem(
    type: 'short',
    title: video.title,
    author: video.author,
    cover: video.cover,
    durationMs: video.durationMs,
    short: video,
  );

  factory PlaylistItem.fromBili({
    required String bvid,
    required String title,
    required String author,
    required String cover,
    required int durationMs,
  }) => PlaylistItem(
    type: 'bili',
    title: title,
    author: author,
    cover: cover,
    durationMs: durationMs,
    bvid: bvid,
  );

  /// 从播放队列的一条转过来（播放页「存为播放列表」用）。
  static PlaylistItem? fromEntry(QueueEntry entry) {
    if (entry.isBili) {
      final bvid = entry.bvid;
      if (bvid == null || bvid.isEmpty) return null;
      return PlaylistItem.fromBili(
        bvid: bvid,
        title: entry.title,
        author: entry.author,
        cover: entry.cover,
        durationMs: entry.durationMs,
      );
    }
    final video = entry.short;
    if (video == null) return null;
    return PlaylistItem.fromShortVideo(video);
  }

  static PlaylistItem? fromJson(Map<String, dynamic> json) {
    final type = '${json['type'] ?? ''}';
    try {
      if (type == 'short') {
        final raw = json['short'];
        if (raw is! Map) return null;
        return PlaylistItem.fromShortVideo(
          ShortVideo.fromJson(raw.cast<String, dynamic>()),
        );
      }
      if (type == 'bili') {
        final bvid = '${json['bvid'] ?? ''}';
        if (bvid.isEmpty) return null;
        return PlaylistItem(
          type: 'bili',
          title: '${json['title'] ?? '视频'}',
          author: '${json['author'] ?? ''}',
          cover: '${json['cover'] ?? ''}',
          durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
          bvid: bvid,
        );
      }
    } catch (_) {}
    return null;
  }

  final String type;
  final String title;
  final String author;
  final String cover;
  final int durationMs;

  /// 抖音 / TikTok 的原始条目（含直链和 videoId，跨设备也能重新解析）。
  final ShortVideo? short;
  final String? bvid;

  bool get isBili => type == 'bili';

  /// 平台标签。
  String get platformLabel {
    if (isBili) return 'B站';
    return short?.platform == 'tiktok' ? 'TikTok' : '抖音';
  }

  String get key => isBili ? 'bili:$bvid' : 'short:${short?.key ?? ''}';

  String get durationText {
    if (durationMs <= 0) return '--:--';
    final total = durationMs ~/ 1000;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  QueueEntry? toEntry() {
    if (isBili) {
      final id = bvid;
      if (id == null || id.isEmpty) return null;
      return QueueEntry.fromBili(
        bvid: id,
        title: title,
        author: author,
        cover: cover,
        durationMs: durationMs,
      );
    }
    final video = short;
    if (video == null) return null;
    return QueueEntry.fromShortVideo(video);
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    if (short != null) 'short': short!.toJson(),
    if (bvid != null) 'bvid': bvid,
    'title': title,
    'author': author,
    'cover': cover,
    'durationMs': durationMs,
  };
}

/// 播放列表的本地存储。B 站 / 抖音 / TikTok 混在一份里。
abstract final class ShortVideoPlaylistRepo {
  static const String _key = 'shortVideoPlaylist';

  static List<PlaylistItem> load() {
    try {
      final Object? raw = GStorage.localCache.get(_key, defaultValue: '');
      if (raw is! String || raw.isEmpty) return [];
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final items = <PlaylistItem>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final item = PlaylistItem.fromJson(entry.cast<String, dynamic>());
        if (item != null) items.add(item);
      }
      return items;
    } catch (_) {
      return [];
    }
  }

  static void save(List<PlaylistItem> items) {
    try {
      GStorage.localCache.put(
        _key,
        jsonEncode(items.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  /// 追加，去重（同一条已经在列表里就跳过）。返回真正加进去的条数。
  static int add(Iterable<PlaylistItem> items) {
    final current = load();
    final keys = current.map((e) => e.key).toSet();
    var added = 0;
    for (final item in items) {
      if (!keys.add(item.key)) continue;
      current.add(item);
      added++;
    }
    if (added > 0) save(current);
    return added;
  }

  static void remove(String key) {
    final current = load()..removeWhere((e) => e.key == key);
    save(current);
  }

  /// 按原位置插回去（删除后的「撤销」用）。
  static void insertAt(int index, PlaylistItem item) {
    final current = load()..removeWhere((e) => e.key == item.key);
    final at = index.clamp(0, current.length);
    current.insert(at, item);
    save(current);
  }

  /// 这份列表里有没有这一条。
  static bool contains(String key) => load().any((e) => e.key == key);

  static void clear() => save([]);

  static int get length => load().length;
}

/// 播放列表页：看、删、清空、整张开播。
class ShortVideoPlaylistPage extends StatefulWidget {
  const ShortVideoPlaylistPage({super.key});

  @override
  State<ShortVideoPlaylistPage> createState() => _ShortVideoPlaylistPageState();
}

class _ShortVideoPlaylistPageState extends State<ShortVideoPlaylistPage> {
  List<PlaylistItem> _items = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    if (!mounted) return;
    setState(() => _items = ShortVideoPlaylistRepo.load());
  }

  void _play(int index) {
    final entries = <QueueEntry>[];
    var start = 0;
    for (var i = 0; i < _items.length; i++) {
      final entry = _items[i].toEntry();
      if (entry == null) continue;
      if (i < index) start++;
      entries.add(entry);
    }
    if (entries.isEmpty) {
      SmartDialog.showToast('列表里没有可播放的条目');
      return;
    }
    Get.to(
      () => ShortVideoPlayerPage(
        queue: entries,
        index: start.clamp(0, entries.length - 1),
      ),
    );
  }

  void _remove(PlaylistItem item) {
    ShortVideoPlaylistRepo.remove(item.key);
    _reload();
  }

  /// 上移 / 下移。顺序就是播放顺序，所以这里直接改存储。
  void _move(int from, int to) {
    if (from < 0 || from >= _items.length) return;
    if (to < 0 || to >= _items.length) return;
    final next = List<PlaylistItem>.of(_items);
    final item = next.removeAt(from);
    next.insert(to, item);
    ShortVideoPlaylistRepo.save(next);
    setState(() => _items = next);
  }

  Future<void> _clear() async {
    if (_items.isEmpty) return;
    ShortVideoPlaylistRepo.clear();
    _reload();
    SmartDialog.showToast('已清空播放列表');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('播放列表 ${_items.length}'),
        actions: [
          IconButton(
            tooltip: '清空',
            onPressed: _items.isEmpty ? null : _clear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: _items.isEmpty
          ? _empty(theme)
          : ListView.builder(
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index];
                return ListTile(
                  onTap: () => _play(index),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 48,
                      height: 64,
                      child: item.cover.isEmpty
                          ? Container(
                              color: theme.dividerColor.withValues(alpha: 0.1),
                            )
                          : Image.network(
                              item.cover,
                              fit: BoxFit.cover,
                              cacheWidth: 180,
                              errorBuilder: (_, _, _) => Container(
                                color: theme.dividerColor.withValues(
                                  alpha: 0.1,
                                ),
                              ),
                            ),
                    ),
                  ),
                  title: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${item.platformLabel} · ${item.durationText}'
                    '${item.author.isEmpty ? '' : ' · ${item.author}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '上移',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 34,
                          minHeight: 34,
                        ),
                        onPressed: index == 0
                            ? null
                            : () => _move(index, index - 1),
                        icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                      ),
                      IconButton(
                        tooltip: '下移',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 34,
                          minHeight: 34,
                        ),
                        onPressed: index >= _items.length - 1
                            ? null
                            : () => _move(index, index + 1),
                        icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                      ),
                      IconButton(
                        tooltip: '移出播放列表',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 34,
                          minHeight: 34,
                        ),
                        onPressed: () => _remove(item),
                        icon: const Icon(Icons.remove_circle_outline, size: 18),
                      ),
                    ],
                  ),
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: _items.isEmpty ? null : () => _play(0),
            icon: const Icon(Icons.play_arrow),
            label: Text('播放全部 ${_items.length} 条'),
          ),
        ),
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
              Icons.queue_music,
              size: 44,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text('播放列表还是空的', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              'B 站收藏、抖音收藏、TikTok 收藏里都能「加入播放列表」，'
              '加进来的条目按这里的顺序连着播。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
