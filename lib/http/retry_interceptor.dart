import 'dart:async';

import 'package:PiliPlus/http/dns_recovery.dart';
import 'package:PiliPlus/http/net_error.dart';
import 'package:dio/dio.dart';
import 'package:http2/http2.dart';

class RetryInterceptor extends Interceptor {
  final Dio _client;
  final int _count;
  final int _delay;

  /// 重试额度用完之后，连接类错误还允许现场自愈一次（通常是重建连接池）。
  /// 返回 true 表示已经换了一个干净的连接池、值得再发一次。
  final bool Function()? recover;

  /// 短阶梯走完仍解析不出来时回调一次，带上**解析不出来的那个主机名**。
  ///
  /// 刻意不放在「头一次失败」那一刻：头一次失败只说明抖了一下，抖动在网络里是常态，
  /// 每个都算一轮故障期的话读数与提示都会失真。等它熬过整条阶梯还不行，才算确认。
  final void Function(String host)? onDnsError;

  /// 域名解析失败的补偿重试阶梯（毫秒）。
  ///
  /// **只有两档，累计 2.8 秒**。这一条是从「越长越好」改回来的，值得把两种想法都写下。
  ///
  /// 老想法：解析故障期可能很长（真机上见过 >60 秒），1.5 秒预算必然输掉这场赛跑，所以
  /// 把阶梯拉到 10 档、累计 4 分钟，还配一支主动探针去测「恢复了没有」。
  ///
  /// 那个想法忽略了一件事：**每一次重试都是一次新的 `getaddrinfo`**，而设备上常驻
  /// 代理/VPN 时这个调用会挂住、且 Dart 取消不了（`.timeout()` 只让 Dart 侧不再等，
  /// 底层仍占着线程）。十来个请求同时在飞，每个重试 10 次，就是上百个挂住的解析调用，
  /// 会把进程的 IO 线程池与系统解析队列一起榨干——**连不需要解析的请求也发不出去**。
  /// 真机现象是一句话：「我一返回视频，整个软件都没网」。修一个「短暂变慢」的问题，
  /// 造出一个「全局瘫痪」的问题，这笔账怎么算都是亏的。
  ///
  /// 现在的取舍是明确的：**容忍「抖一下」（≤2.8 秒），不试图容忍「断一段」**。
  /// 真断了就如实失败，让页面显示错误占位——那是**看得见**的失败，用户下拉刷新即可
  /// 重试，而且一次刷新就是一次免费的探针；长阶梯换来的却是**看不见的卡死**。
  static const _dnsRetryDelays = [800, 2000];

  RetryInterceptor(
    this._client,
    this._count,
    this._delay, {
    this.recover,
    this.onDnsError,
  });

  /// 等一会儿再原样发一次。
  void _retryAfter(
    int milliseconds,
    DioException err,
    ErrorInterceptorHandler handler,
  ) {
    Timer(
      Duration(milliseconds: milliseconds),
      () => _client
          .fetch(err.requestOptions)
          .then(handler.resolve)
          .onError<DioException>((error, _) => handler.next(error)),
    );
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.requestOptions.responseType == ResponseType.stream) {
      return handler.next(err);
    }
    if (err.response != null) {
      final options = err.requestOptions;
      if (options.followRedirects && options.maxRedirects > 0) {
        final status = err.response!.statusCode;
        if (status != null && 300 <= status && status < 400) {
          var redirectUrl = err.response!.headers.value('location');
          if (redirectUrl != null) {
            var uri = Uri.parse(redirectUrl);
            if (!uri.hasScheme) {
              uri = options.uri.resolveUri(uri);
              redirectUrl = uri.toString();
            }
            (options..path = redirectUrl).maxRedirects--;
            if (status == 303) {
              options
                ..data = null
                ..method = 'GET';
            }
            _client
                .fetch(options)
                .then(
                  (i) => handler.resolve(
                    i
                      ..redirects.add(
                        RedirectRecord(status, options.method, uri),
                      )
                      ..isRedirect = true,
                  ),
                )
                .onError<DioException>((error, _) => handler.next(error));
            return;
          }
        }
      }
      return handler.next(err);
    } else {
      switch (err.type) {
        case DioExceptionType.connectionError:
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.unknown:
          // 网络中断, 此时请求可能已经被服务器所接收
          if (err.error is TransportConnectionException) {
            return handler.next(err);
          }
          final extra = err.requestOptions.extra;

          // 域名解析失败：短阶梯试两次（共 2.8 秒），不行就如实失败。
          //
          // 这一路有两个与常规重试不同的地方，都是被真机教出来的：
          //
          // ① **故障期一旦确认，一次都不再重试**。此刻重试只是往已经堵住的解析队列上
          //    再压一次，它不会让解析变好——真正能宣布「恢复」的证据只有一个，那就是
          //    某个真实请求拿到了响应（见 [DnsRecovery.noteSuccess]）。快速失败让上层
          //    立刻显示错误占位，用户下拉刷新就是一次免费的重试。
          // ② **不去动连接池**：解析都没成功，池子里根本没有可怪罪的连接，重建只会白白
          //    打断同批在途请求（这一条在真机上白跑过一整轮）。
          if (isDnsFailure(err)) {
            if (DnsRecovery.hasOpenFault) {
              return handler.next(err);
            }
            final dns = (extra['_rd'] ??= 0) as int;
            if (dns < _dnsRetryDelays.length) {
              extra['_rd'] = dns + 1;
              _retryAfter(_dnsRetryDelays[dns], err, handler);
              return;
            }
            // 抖一下的可能性已经排除了（它熬满了整条阶梯）。到这一刻才报故障：后面来的
            // 解析失败会走上面那条零重试的闸门，不再有一个请求接着一个请求地补发解析。
            onDnsError?.call(err.requestOptions.uri.host);
            return handler.next(err);
          }

          if ((extra['_rt'] ??= 0) < _count) {
            Timer(
              Duration(milliseconds: ++extra['_rt'] * _delay),
              () => _client
                  .fetch(err.requestOptions)
                  .then(handler.resolve)
                  .onError<DioException>((error, _) => handler.reject(error)),
            );
            return;
          }
          // 重试额度用完了。这时还有一种情况值得再试：App 在后台（画中画）待久了，
          // 连接池里可能还留着已经被系统收走的连接——它们不会报错，只是发不出去，
          // 于是几次重试全撞在同一批死连接上。换一个干净的连接池再发一次，成功的话
          // 这次失败对上层根本不存在（用户也就不会看到「连接错误」的提示）。
          if (extra['_rc'] != true && recover?.call() == true) {
            extra['_rc'] = true;
            _client
                .fetch(err.requestOptions)
                .then(handler.resolve)
                .onError<DioException>((error, _) => handler.next(error));
            return;
          }
          return handler.next(err);
        default:
          return handler.next(err);
      }
    }
  }

  RetryInterceptor copyWith({Dio? client, int? count, int? delay}) => .new(
    client ?? _client,
    count ?? _count,
    delay ?? _delay,
    recover: recover,
    onDnsError: onDnsError,
  );
}
