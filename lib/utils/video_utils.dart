import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models_new/live/live_room_play_info/codec.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart'
    show ValueNotifier, kDebugMode, debugPrint;

abstract final class VideoUtils {
  static CDNService cdnService = Pref.defaultCDNService;
  static String? liveCdnUrl = Pref.liveCdnUrl;
  static bool disableAudioCDN = Pref.disableAudioCDN;

  static const _proxyTf = 'proxy-tf-all-ws.bilivideo.com';

  /// 最近一次对播放地址的规范化记录（空串表示本次地址未见异常）。
  ///
  /// 上游响应里的播放地址并不总是带协议头（见 `_normalizePlayUrl`）。这种地址一旦
  /// 进了 `getCdnUrl`，主机名会被当成路径留下来，产出
  /// `https://host/host/upgcxcode/...` 这种打不开的地址；播放器只会停在
  /// 「加载中」，和「网络不通」长得一模一样。所以把"改过什么"记下来，
  /// 展示在卡住的那一屏——下次不用靠猜是哪一头的问题。
  static final ValueNotifier<String> urlFixNote = ValueNotifier<String>('');

  /// 把播放地址归一化成「带协议的绝对地址」。
  ///
  /// 实际见过三种不规范形态（均来自上游响应）：
  /// - `//host/path` —— 协议相对；
  /// - `host/path`   —— 裸主机、没有协议；`Uri.parse` 会把主机名整个当成 path，
  ///   之后 `replace(host:)` 再补一个主机名，就变成 `host/host/path`；
  /// - `/path`       —— 只有路径，主机名得由当前 CDN 设置补。
  static String _normalizePlayUrl(String url, String fallbackHost) {
    final s = url.trim();
    if (s.isEmpty) return s;
    if (s.startsWith('//')) return 'https:$s';
    if (s.startsWith('/')) {
      return fallbackHost.isEmpty ? s : 'https://$fallbackHost$s';
    }
    final lower = s.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) return s;
    // 裸主机：首段含点且不含冒号（排除 `edl:` 这类自定义协议）
    final slash = s.indexOf('/');
    final first = slash == -1 ? s : s.substring(0, slash);
    if (first.contains('.') && !first.contains(':')) return 'https://$s';
    return s;
  }

  /// 路径里若残留了主机名（`/host/...`），剥掉。
  ///
  /// 这是保险：改前的 `getCdnUrl` 会把裸主机地址加工成这个形态，而新一轮的地址
  /// 规范化只作用于新数据。若某条地址仍带着这个尾巴，这里兜一次。
  static String _stripDuplicatedHost(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    final dup = '/${uri.host}/';
    if (uri.path.startsWith(dup)) {
      return uri.replace(path: uri.path.substring(dup.length - 1)).toString();
    }
    return url;
  }

  /// 拉流失败时可以依次换过去的一组镜像节点。
  ///
  /// 全部是 `upos-sz-mirror*.bilivideo.com`：与接口下发的地址同属一套路径规则
  /// （`/upgcxcode/...`），差别只在出口机房，所以换主机名、保留 path 与查询串即可用。
  /// 刻意不含 `*o1` 与 `tf` 系列——前者是 `os=mcdn` 专用形态、后者走的是另一套代理
  /// 地址，换过去必然打不开。
  static const List<String> mirrorHosts = [
    'upos-sz-mirrorali.bilivideo.com',
    'upos-sz-mirroralib.bilivideo.com',
    'upos-sz-mirrorhw.bilivideo.com',
    'upos-sz-mirrorhwb.bilivideo.com',
    'upos-sz-mirror08c.bilivideo.com',
    'upos-sz-mirror08h.bilivideo.com',
    'upos-sz-mirror08ct.bilivideo.com',
    'upos-sz-mirrorcos.bilivideo.com',
    'upos-sz-mirrorcosb.bilivideo.com',
  ];

  /// 把 [url] 换到轮换表里的下一个镜像节点；不适合轮换时返回 `null`。
  ///
  /// CDN 设置的默认值是「备用URL」，含义是**照搬接口下发的那个地址**——接口给哪个
  /// 机房就只能连哪个机房。那个机房连不上时，不管是重新取流（接口还是给同一个机房）
  /// 还是 `refreshPlayer()`（还是同一个地址）都只是在原地打转；换主机名是这台设备自己
  /// 就能做的那一步：各镜像吃的是同一份内容，路径与签名参数与主机名无关。
  static String? nextMirrorUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;
    // 只对「镜像直链」轮换——`upos-sz-mirror*.bilivideo.com/upgcxcode/...` 这一种形态。
    // 其余形态看上去也像播放地址，换了必然打不开：
    // * `*.mcdn.bilivideo.com:448` 是 P2P 回源节点，路径挂在 `/v3/resource/` 下（里面
    //   同样有 `/upgcxcode/` 三个字，所以只判子串会漏），还带端口；
    // * `proxy-tf-*` 走的是 `?url=` 转代理；
    // * `edl://` 是本地合流串。
    // 判据收在「主机名 + 路径必须以 /upgcxcode/ 开头 + 不带端口」三条上，与上面
    // `_mirrorRegex` 的锚点一致。
    if (!uri.host.endsWith('.bilivideo.com')) return null;
    if (uri.host.contains('.mcdn.')) return null;
    if (uri.hasPort) return null;
    if (!uri.path.startsWith('/upgcxcode/')) return null;
    if (uri.queryParameters['os'] == 'mcdn') return null;
    final cur = mirrorHosts.indexOf(uri.host);
    final next = mirrorHosts[(cur == -1 ? 0 : cur + 1) % mirrorHosts.length];
    if (next == uri.host) return null;
    return uri.replace(host: next).toString();
  }

  static final _mirrorRegex = RegExp(
    r'^https?://(?:upos-\w+-(?!302)\w+|(?:upos|proxy)-tf-[^/]+)\.(?:bilivideo|akamaized)\.(?:com|net)/upgcxcode',
  );

  static final _mCdnTfRegex = RegExp(
    r'^https?://(?:(?:(?:\d{1,3}\.){3}\d{1,3}|[^/]+\.mcdn\.bilivideo\.(?:com|cn|net))(?:\:\d{1,5})?/v\d/resource)',
  );

  static String getCdnUrl(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    bool isAudio = false,
  }) {
    defaultCDNService ??= cdnService;

    // 先归一化。这里的顺序很要紧：不带协议头的地址若直接进下面的
    // `replace(host:)`，主机名会被当成路径留下来，产出永远打不开的地址；
    // 而归一化放在所有判断之前，正则白名单也能正常命中。
    final fallbackHost = defaultCDNService.host ?? CDNService.ali.host ?? '';
    String? abnormal;
    final normalized = <String>[];
    for (final raw in urls) {
      final fixed = _stripDuplicatedHost(_normalizePlayUrl(raw, fallbackHost));
      if (abnormal == null && fixed != raw) abnormal = raw;
      normalized.add(fixed);
    }
    urlFixNote.value = abnormal == null
        ? ''
        : '地址异常已修复：${abnormal.length > 60 ? '${abnormal.substring(0, 60)}…' : abnormal}';

    if (defaultCDNService == CDNService.baseUrl) {
      return normalized.first;
    }

    String? mcdnTf;
    String? mcdnUpgcxcode;

    String last = '';
    for (final url in normalized) {
      last = url;
      if (_mirrorRegex.hasMatch(url)) {
        final uri = Uri.parse(url);
        if (uri.queryParameters['os'] == 'mcdn') {
          // upos-sz-mirrorcoso1.bilivideo.com os=mcdn
          mcdnUpgcxcode = url;
        } else {
          if (defaultCDNService == CDNService.backupUrl ||
              (isAudio && disableAudioCDN)) {
            return url;
          }
          return uri.replace(host: defaultCDNService.host).toString();
        }
      }

      if (_mCdnTfRegex.hasMatch(url)) {
        mcdnTf = url;
        continue;
      }

      // upos-\w*-302.* & bcache & mcdn host but upgcxcode path
      if (url.contains('/upgcxcode/')) {
        mcdnUpgcxcode = url;
        continue;
      }

      // may be deprecated
      if (url.contains('szbdyd.com')) {
        final uri = Uri.parse(url);
        final hostname =
            uri.queryParameters['xy_usource'] ?? defaultCDNService.host;
        return uri
            .replace(scheme: 'https', host: hostname, port: 443)
            .toString();
      }

      if (kDebugMode) {
        debugPrint('unknown cdn type: $url');
      }
    }

    return mcdnUpgcxcode == null
        ? mcdnTf == null
              ? last
              : Uri(
                  scheme: 'https',
                  host: _proxyTf,
                  queryParameters: {'url': mcdnTf},
                ).toString()
        : Uri.parse(mcdnUpgcxcode)
              .replace(host: defaultCDNService.host ?? CDNService.ali.host)
              .toString();
  }

  static String getLiveCdnUrl(CodecItem e, {int index = 0}) {
    final urlInfo = e.urlInfo.getOrFirst(index);
    return (liveCdnUrl ?? urlInfo.host) + e.baseUrl + urlInfo.extra;
  }

  static VideoDecodeFormatType selectCodec(
    Iterable<String> codecs,
    List<VideoDecodeFormatType> preferCodecs,
  ) {
    if (preferCodecs.isNotEmpty) {
      int bestIndex = preferCodecs.length;
      for (final e in codecs) {
        for (int i = 0; i < bestIndex; i++) {
          if (preferCodecs[i].codes.any(e.startsWith)) {
            bestIndex = i;
            if (bestIndex == 0) {
              return preferCodecs[0];
            }
            break;
          }
        }
      }
      if (bestIndex < preferCodecs.length) {
        return preferCodecs[bestIndex];
      }
    }
    return VideoDecodeFormatType.fromString(codecs.first);
  }
}
