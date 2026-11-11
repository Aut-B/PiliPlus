import 'dart:async';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:flutter/services.dart';

/// 抓取网页的原生桥。
///
/// 抖音 / TikTok 的收藏页必须跑真实页面（接口要签名），而 flutter_inappwebview
/// 在这套 iOS 构建里创建出来只有一片白——它是 Flutter 的 platform view。所以这里
/// 直接调原生 WKWebView（`ios/Runner/AppDelegate.swift` 里的
/// `ShortVideoWebViewPlugin`），和 Kumone 走同一条已验证的代码路径。
abstract final class ShortVideoWeb {
  static const MethodChannel _channel = MethodChannel(
    'piliplus/shortvideo_web',
  );

  static bool _installed = false;

  /// 原生抓到一段 JSON。
  static void Function(String body)? onPayload;

  /// 原生那边的状态文字（页面加载、抓取进度、错误）。
  static void Function(String text)? onStatus;

  /// 用户关掉网页。
  static void Function()? onClosed;

  static void _ensureHandler() {
    if (_installed) return;
    _installed = true;
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      switch (call.method) {
        case 'payload':
          if (args is Map && args['body'] is String) {
            onPayload?.call(args['body'] as String);
          }
        case 'status':
          if (args is String) onStatus?.call(args);
        case 'closed':
          onClosed?.call();
      }
      return null;
    });
  }

  static Future<void> open(ShortVideoPlatform platform) async {
    _ensureHandler();
    await _channel.invokeMethod('open', {
      'url': platform.homeUrl,
      'favoritesUrl': platform.favoritesUrl,
      'loginUrl': platform.loginUrl,
      'userAgent': platform.userAgent,
      'title': '${platform.album} · 登录与抓取',
      'hookScript': hookJs(platform),
      'driverScript': driverJs(platform),
    });
  }

  /// 设备物理内存（字节）。取不到返回 0。
  ///
  /// 用来决定要不要走「低内存」那套保守策略（见 ShortVideoPerf）。
  static Future<int> deviceMemory() async {
    _ensureHandler();
    try {
      final bytes = await _channel.invokeMethod<int>('deviceMemory');
      return bytes ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 网页那套 cookie。
  ///
  /// 抖音 / TikTok 的 CDN 会按网页会话校验（TikTok 尤其明显）；Kumone 那边用
  /// URLSession 下载，天然和 WKWebView 共用 cookie，所以下得动。Dart 的
  /// HttpClient 是独立 cookie 罐，不带就是 403 / 0 字节——这里把网页的 cookie
  /// 取过来手动带上。
  static final Map<String, String> _cookieCache = {};
  static final Map<String, DateTime> _cookieAt = {};

  static Future<String> cookieHeader(String domain) async {
    if (domain.isEmpty) return '';
    final at = _cookieAt[domain];
    if (at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return _cookieCache[domain] ?? '';
    }
    _ensureHandler();
    try {
      final list = await _channel.invokeMethod<List<dynamic>>('cookies', {
        'domain': domain,
      });
      if (list == null) return '';
      final byName = <String, String>{};
      for (final entry in list) {
        if (entry is! Map) continue;
        final name = '${entry['name'] ?? ''}';
        final value = '${entry['value'] ?? ''}';
        if (name.isEmpty) continue;
        byName[name] = value;
      }
      final header = byName.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');
      _cookieCache[domain] = header;
      _cookieAt[domain] = DateTime.now();
      return header;
    } catch (_) {
      return '';
    }
  }

  static void clearCookieCache() {
    _cookieCache.clear();
    _cookieAt.clear();
  }
  static Future<void> start() => _channel.invokeMethod('start');

  static Future<void> stop() => _channel.invokeMethod('stop');

  static Future<void> close() => _channel.invokeMethod('close');
}

/// 包住 `fetch` / `XMLHttpRequest`，凡是返回体里带平台特征字段的都回传原生。
String hookJs(ShortVideoPlatform platform) {
  final markers = platform.markers.map((e) => "'$e'").join(',');
  return '''
(function () {
  if (window.__kumoneShortVideoHook) { return; }
  window.__kumoneShortVideoHook = true;

  var MARKERS = [$markers];

  function interesting(text) {
    if (!text || text.length < 40) { return false; }
    for (var i = 0; i < MARKERS.length; i++) {
      if (text.indexOf(MARKERS[i]) >= 0) { return true; }
    }
    return false;
  }

  function post(url, text) {
    try {
      if (!interesting(text)) { return; }
      window.webkit.messageHandlers.shortvideo.postMessage({
        url: String(url),
        body: text
      });
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
            response.clone().text().then(function (text) { post(url, text); }).catch(function () {});
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
        try { post(xhr.__kumoneURL, xhr.responseText); } catch (e) {}
      });
    } catch (e) {}
    return send.apply(this, arguments);
  };
})();
''';
}

/// 自动点开「收藏」tab，并持续滚到底，让列表继续分页。
String driverJs(ShortVideoPlatform platform) {
  final titles = platform.tabTitles.map((e) => "'$e'").join(',');
  return '''
(function () {
  if (window.__kumoneDriver) { return; }
  var TITLES = [$titles];
  window.__kumoneDriver = setInterval(function () {
    try {
      if (!window.__kumoneClickedTab) {
        var nodes = document.querySelectorAll('div,span,a,li,button');
        for (var i = 0; i < nodes.length; i++) {
          var text = (nodes[i].textContent || '').trim();
          for (var t = 0; t < TITLES.length; t++) {
            if (text === TITLES[t]) {
              nodes[i].click();
              window.__kumoneClickedTab = true;
              return;
            }
          }
        }
      }
      window.scrollTo(0, document.body.scrollHeight);
    } catch (e) {}
  }, 1200);
})();
''';
}