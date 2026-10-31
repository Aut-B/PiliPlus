import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Full-screen Douyin playback. Uses media_kit directly instead of the
/// Bilibili video page: there is no aid/cid, no danmaku and no quality ladder,
/// just one URL per video plus the loop mode the user asked for.
class DouyinPlayerPage extends StatefulWidget {
  const DouyinPlayerPage({super.key, required this.videos, required this.index});

  final List<DouyinVideo> videos;
  final int index;

  @override
  State<DouyinPlayerPage> createState() => _DouyinPlayerPageState();
}

class _DouyinPlayerPageState extends State<DouyinPlayerPage> {
  late final Player _player;
  late final VideoController _controller;
  late int _index;
  bool _singleLoop = false;
  bool _playing = false;

  DouyinVideo get _current => widget.videos[_index];

  @override
  void initState() {
    super.initState();
    _index = widget.index.clamp(0, widget.videos.length - 1);
    _player = Player();
    _controller = VideoController(_player);
    _player.stream.playing.listen((value) {
      if (mounted) setState(() => _playing = value);
    });
    _open();
  }

  Future<void> _open() async {
    await _player.setPlaylistMode(
      _singleLoop ? PlaylistMode.single : PlaylistMode.loop,
    );
    await _player.open(
      Playlist([
        for (final video in widget.videos)
          Media(
            video.playUrl,
            httpHeaders: const {
              'User-Agent':
                  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/131.0.0.0 Safari/537.36',
              'Referer': 'https://www.douyin.com/',
            },
          ),
      ], index: _index),
      play: true,
    );
  }

  Future<void> _jump(int delta) async {
    final next = _index + delta;
    if (next < 0 || next >= widget.videos.length) return;
    setState(() => _index = next);
    await _player.jump(next);
  }

  Future<void> _toggleLoop() async {
    setState(() => _singleLoop = !_singleLoop);
    await _player.setPlaylistMode(
      _singleLoop ? PlaylistMode.single : PlaylistMode.loop,
    );
    _showToast(_singleLoop ? '单个循环' : '列表循环');
  }

  void _showToast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: const Duration(milliseconds: 900),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _player.playOrPause(),
        onVerticalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity < -200) {
            _jump(1);
          } else if (velocity > 200) {
            _jump(-1);
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: 9 / 16,
                child: Video(
                  controller: _controller,
                  controls: NoVideoControls,
                  fill: Colors.black,
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Get.back(),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  Expanded(
                    child: Text(
                      _current.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                    ),
                  ),
                  IconButton(
                    onPressed: _toggleLoop,
                    tooltip: _singleLoop ? '单个循环' : '列表循环',
                    icon: Icon(
                      _singleLoop ? Icons.repeat_one : Icons.repeat,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            if (!_playing)
              const Center(
                child: Icon(
                  Icons.play_circle_fill,
                  size: 72,
                  color: Colors.white70,
                ),
              ),
            Positioned(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(context).padding.bottom + 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _current.author,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _roundButton(
                        icon: Icons.keyboard_arrow_up,
                        onTap: () => _jump(-1),
                      ),
                      const SizedBox(width: 12),
                      _roundButton(
                        icon: Icons.keyboard_arrow_down,
                        onTap: () => _jump(1),
                      ),
                      const Spacer(),
                      Text(
                        '${_index + 1} / ${widget.videos.length}',
                        style: const TextStyle(color: Colors.white54),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundButton({required IconData icon, required VoidCallback onTap}) {
    return Material(
      color: Colors.white24,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}