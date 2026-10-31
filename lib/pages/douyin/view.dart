import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/player.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';

const _storageKey = 'douyinFavorites';

const _desktopUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/131.0.0.0 Safari/537.36';

/// Douyin favourites, scraped from the signed-in web page.
///
/// Douyin's web API needs `a_bogus` + UIFID, so a plain HTTP client is refused
/// (`Blocked by ArgusSecurityPlugin`). Running the real page lets Douyin sign
/// its own requests; we only read the JSON it gets back, which already
/// contains playable URLs.
class DouyinFavoritesPage extends StatefulWidget {
  const DouyinFavoritesPage({super.key});

  @override
  State<DouyinFavoritesPage> createState() => _DouyinFavoritesPageState();
}

class _DouyinFavoritesPageState extends State<DouyinFavoritesPage> {
  InAppWebViewController? _web;
  final List<DouyinVideo> _videos = [];

  bool _showWeb = true;
  bool _collecting = false;
  String _status = '';
  Timer? _timer;
  int _idle = 0;
  int _lastCount = 0;
  DateTime? _startedAt;

  @override
  void initState() {
    super.initState();
    _load();
    _showWeb = _videos.isEmpty;
    _status = _videos.isEmpty
        ? '在网页里登录抖音，然后点「开始抓取」'
        : '已加载上次抓取的 ${_videos.length} 条';
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // MARK: - Storage

  void _load() {
    try {
      final raw = GStorage.localCache.get(_storageKey, defaultValue: '');
      if (raw is! String || raw.isEmpty) return;
      final list = jsonDecode(raw);
      if (list is! List) return;
      _videos
        ..clear()
        ..addAll(
          list.whereType<Map>().map(
            (e) => DouyinVideo.fromJson(e.cast<String, dynamic>()),
          ),
        );
    } catch (_) {}
  }

  void _save() {
    try {
      GStorage.localCache.put(
        _storageKey,
        jsonEncode(_videos.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  // MARK: - Collecting

  void _start() {
    if (_collecting) return;
    setState(() {
      _collecting = true;
      _idle = 0;
      _lastCount = _videos.length;
      _startedAt = DateTime.now();
      _status = '正在抓取…如果一直没动静，请先在网页里登录抖音';
    });
    _web?.evaluateJavascript(source: _driverJs);
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _tick(),
    );
  }

  void _stop([String? message]) {
    _timer?.cancel();
    _timer = null;
    _web?.evaluateJavascript(
      source:
          'try{clearInterval(window.__kumoneDriver);'
          'window.__kumoneDriver=null;}catch(e){}',
    );
    if (!mounted) return;
    setState(() {
      _collecting = false;
      _status = message ?? '已抓取 ${_videos.length} 条';
    });
    _save();
  }

  void _tick() {
    if (!_collecting) return;
    _web?.evaluateJavascript(
      source: 'window.scrollTo(0, document.body.scrollHeight);',
    );
    final startedAt = _startedAt;
    if (startedAt != null &&
        DateTime.now().difference(startedAt) > const Duration(minutes: 5)) {
      _stop('抓取超时，已保留 ${_videos.length} 条');
      return;
    }
    if (_videos.length == _lastCount) {
      _idle++;
    } else {
      _idle = 0;
      _lastCount = _videos.length;
    }
    if (_idle >= 10) {
      _stop('抓取完成，共 ${_videos.length} 条');
    }
  }

  void _onPayload(List<dynamic> args) {
    if (args.isEmpty) return;
    final body = args.last.toString();
    final parsed = DouyinParser.fromResponseBody(body);
    if (parsed.isEmpty) return;

    final known = _videos.map((e) => e.id).toSet();
    var added = 0;
    for (final video in parsed) {
      if (known.add(video.id)) {
        _videos.add(video);
        added++;
      }
    }
    if (added == 0) return;
    setState(() => _status = '已抓取 ${_videos.length} 条…');
    _save();
  }

  // MARK: - Actions

  void _play(int index) {
    if (_videos.isEmpty) return;
    Get.to(
      () => DouyinPlayerPage(videos: List.of(_videos), index: index),
    );
  }

  void _playAll() {
    if (_videos.isEmpty) return;
    _play(0);
  }

  void _clear() {
    setState(() {
      _videos.clear();
      _status = '已清空，可重新抓取';
    });
    _save();
  }

  // MARK: - UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('抖音收藏'),
        actions: [
          IconButton(
            tooltip: '重新加载网页',
            onPressed: () => _web?.reload(),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: _videos.isEmpty ? null : _clear,
            icon: const Icon(Icons.delete_outline),
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
            child: IndexedStack(
              index: _showWeb || _videos.isEmpty ? 0 : 1,
              children: [_buildWebView(), _buildList(theme)],
            ),
          ),
          _buildControlBar(theme),
        ],
      ),
    );
  }

  Widget _buildWebView() {
    return InAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('https://www.douyin.com/user/self?showTab=favorite_collection'),
      ),
      initialSettings: InAppWebViewSettings(
        userAgent: _desktopUserAgent,
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        thirdPartyCookiesEnabled: true,
        allowsInlineMediaPlayback: true,
        useShouldOverrideUrlLoading: true,
      ),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: _hookJs,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
        ),
      ]),
      onWebViewCreated: (controller) {
        _web = controller;
        controller.addJavaScriptHandler(
          handlerName: 'douyin',
          callback: _onPayload,
        );
      },
      onLoadStop: (controller, url) {
        if (_collecting) return;
        if (_status.startsWith('正在打开')) {
          setState(() => _status = '页面已加载：登录后点「开始抓取」');
        }
      },
    );
  }

  Widget _buildList(ThemeData theme) {
    if (_videos.isEmpty) {
      return const Center(child: Text('还没有抓取到收藏，去网页里登录后重试'));
    }
    return ListView.builder(
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        final video = _videos[index];
        return ListTile(
          onTap: () => _play(index),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 48,
              height: 64,
              child: video.cover.isEmpty
                  ? Container(color: theme.dividerColor.withValues(alpha: 0.1))
                  : Image.network(
                      video.cover,
                      fit: BoxFit.cover,
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
            '${video.author.isEmpty ? '抖音' : video.author} · ${video.durationText}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.play_circle_outline),
        );
      },
    );
  }

  Widget _buildControlBar(ThemeData theme) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _status,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _collecting ? _stop : _start,
                    icon: Icon(
                      _collecting ? Icons.stop : Icons.download,
                    ),
                    label: Text(_collecting ? '停止抓取' : '开始抓取'),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: () {
                    setState(() => _showWeb = !_showWeb);
                  },
                  child: Text(_showWeb ? '列表' : '网页'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Wraps `fetch` / `XMLHttpRequest` so every Douyin web API response reaches
/// the native side.
const _hookJs = r'''
(function () {
  if (window.__kumoneDouyinHook) { return; }
  window.__kumoneDouyinHook = true;

  function post(url, text) {
    try {
      if (!text || text.length < 40) { return; }
      if (text.indexOf('aweme_list') < 0 && text.indexOf('aweme_detail') < 0) { return; }
      window.flutter_inappwebview.callHandler('douyin', String(url), text);
    } catch (e) {}
  }

  var originalFetch = window.fetch;
  if (originalFetch) {
    window.fetch = function () {
      var args = arguments;
      var url = '';
      try { url = (args[0] && args[0].url) ? args[0].url : args[0]; } catch (e) {}
      var promise = originalFetch.apply(this, args);
      try {
        promise.then(function (response) {
          try {
            if (String(url).indexOf('/aweme/v1/web/') >= 0) {
              response.clone().text().then(function (text) { post(url, text); }).catch(function () {});
            }
          } catch (e) {}
        }).catch(function () {});
      } catch (e) {}
      return promise;
    };
  }

  var open = XMLHttpRequest.prototype.open;
  var send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__kumoneURL = url;
    return open.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    var xhr = this;
    try {
      xhr.addEventListener('load', function () {
        try {
          if (String(xhr.__kumoneURL).indexOf('/aweme/v1/web/') >= 0) {
            post(xhr.__kumoneURL, xhr.responseText);
          }
        } catch (e) {}
      });
    } catch (e) {}
    return send.apply(this, arguments);
  };
})();
''';

/// Clicks the 收藏 tab once, then keeps the page scrolled to the bottom so the
/// list paginates.
const _driverJs = r'''
(function () {
  if (window.__kumoneDriver) { return; }
  window.__kumoneDriver = setInterval(function () {
    try {
      if (!window.__kumoneClickedTab) {
        var nodes = document.querySelectorAll('div,span,a,li');
        for (var i = 0; i < nodes.length; i++) {
          var text = (nodes[i].textContent || '').trim();
          if (text === '收藏' || text === '收藏夹') {
            nodes[i].click();
            window.__kumoneClickedTab = true;
            break;
          }
        }
      }
      window.scrollTo(0, document.body.scrollHeight);
    } catch (e) {}
  }, 1200);
})();
''';