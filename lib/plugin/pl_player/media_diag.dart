import 'dart:async';
import 'dart:io';

/// 拉流失败时的现场取证。
///
/// 「打不开播放地址」在界面上只有一种样子：转圈加一句 `Failed to open`。可这句话后面
/// 跟着的是整个 URL，常常上百字符，把真正有用的部分挤得看不见；而 libavformat 报出的
/// 具体原因（`HTTP error 403 Forbidden`、`Connection refused`…）又是**另一条**日志，
/// 先到、随后被那句笼统的 `Failed to open` 覆盖。于是下面三种情况在界面上完全一样：
///
/// * 出口连不上（代理 / VPN / DNS）
/// * 连上了但服务器拒绝（地址已失效、签名不匹配、被风控）
/// * 拿到了地址但一个字节也读不回来
///
/// 这里在失败现场对同一个地址主动探一次，把三层结论分别写出来，无论哪一层先断，
/// 都能一眼看出断在哪一层——这样下一次就不用再猜了。
abstract final class MediaDiag {
  /// 对 [url] 做一次主动探测，返回若干行结论；失败也在返回值里说明。
  static Future<String> probe(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      return '探测：地址无法解析';
    }
    final lines = <String>[];

    // 第一层：DNS。解析不出 IP 的话，后面能不能连上就都没有意义了，
    // 而且这一层的结论直接指向设备出口（代理 / VPN / 运营商），与 App 无关。
    try {
      final addrs = await InternetAddress.lookup(
        uri.host,
      ).timeout(const Duration(seconds: 4));
      if (addrs.isEmpty) {
        lines.add('DNS：无记录');
      } else {
        lines.add('DNS：${addrs.take(2).map((e) => e.address).join(' , ')}');
      }
    } on TimeoutException {
      lines.add('DNS：超时');
    } on SocketException catch (e) {
      final code = e.osError?.errorCode;
      lines.add(
        'DNS：失败${code == null ? '' : '($code)'} ${e.message}'.trimRight(),
      );
    } catch (e) {
      lines.add('DNS：${e.runtimeType}');
    }

    // 第二层：TCP + TLS + HTTP。只取前 1KB，能拿到状态码就够定性。
    // 带上 Referer 与 UA，与播放器实际发请求的方式尽量一致，否则探通了也不作数。
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 6));
      request.headers.set('Range', 'bytes=0-1023');
      request.headers.set('Referer', 'https://www.bilibili.com');
      request.headers.set(
        'User-Agent',
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      lines.add('HTTP：${response.statusCode}');
      final bytes = await response
          .fold<int>(0, (sum, chunk) => sum + chunk.length)
          .timeout(const Duration(seconds: 6));
      lines.add('接收：$bytes 字节');
    } on TimeoutException {
      lines.add('HTTP：超时');
    } on HandshakeException catch (e) {
      lines.add('HTTP：TLS 失败 ${e.message}');
    } on SocketException catch (e) {
      final code = e.osError?.errorCode;
      lines.add(
        'HTTP：失败${code == null ? '' : '($code)'} ${e.message}'.trimRight(),
      );
    } on HttpException catch (e) {
      lines.add('HTTP：${e.message}');
    } catch (e) {
      lines.add('HTTP：${e.runtimeType}');
    } finally {
      client.close(force: true);
    }

    return lines.join('\n');
  }
}
