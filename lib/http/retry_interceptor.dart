import 'dart:async';

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

  /// 头一次看到域名解析失败时回调一次。
  ///
  /// 由它来记数（而不是等错误冒到 [Request] 那一层再记）：拦截器跑在错误提示**之前**，
  /// 这样提示里带回来的读数才是那一刻的真数——真机上正是这一点让 `dn` 一直是 0。
  final void Function()? onDnsError;

  /// 解析故障期的「闸门」：返回的 future 在解析恢复时完成，没有故障期时返回 null。
  ///
  /// 有了它，等待中的重试不必老实睡满阶梯——解析一恢复就立刻再发一次。这很要紧：真机上
  /// 这段空窗比 16 秒更长，靠固定阶梯只能一路加长盲等；而"等恢复"最坏也只是等到空窗结束。
  final Future<void>? Function()? dnsGate;

  /// 域名解析失败的补偿重试阶梯（毫秒，累计约 51 秒）。
  ///
  /// 单独一套，因为这与 [_count]/[_delay] 根本不是一回事：那套（默认 2 次 × 500ms）是为
  /// 「偶发的连接抖动」准备的，总共只争取到 1.5 秒；而解析失败是**成片**发生的——系统
  /// 解析服务在切前后台之后的头几十秒会整段不可用（设备上常驻代理/VPN 时尤其如此，隧道
  /// 重建期间全部查询一起失败），1.5 秒的预算必然输掉这场赛跑。
  ///
  /// 长度是量出来的：先用 1.5 秒预算，报错卡在回前台后 +1.6s；换成 16 秒阶梯后，报错推到
  /// 了 +9.0s，而那一刻解析探针仍未测出恢复——说明空窗比 16 秒更长，于是再加到约 51 秒。
  /// 连接池对此无能为力，这一路全程不去动它。
  static const _dnsRetryDelays = [800, 2000, 4500, 9000, 15000, 20000];

  RetryInterceptor(
    this._client,
    this._count,
    this._delay, {
    this.recover,
    this.onDnsError,
    this.dnsGate,
  });

  /// 等一会儿再发一次；若正处在解析故障期，解析一恢复就立刻发，不必等满延时。
  void _retryAfter(
    int milliseconds,
    DioException err,
    ErrorInterceptorHandler handler,
  ) {
    var fired = false;
    void fire() {
      if (fired) return;
      fired = true;
      _client
          .fetch(err.requestOptions)
          .then(handler.resolve)
          .onError<DioException>((error, _) => handler.next(error));
    }

    Timer(Duration(milliseconds: milliseconds), fire);
    dnsGate?.call()?.then((_) => fire());
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

          // 域名解析失败单独走一条慢速阶梯：等 0.8 / 2 / 4.5 / 9 / 15 / 20 秒（累计约 51 秒）
          // 再试，并且在「解析恢复」的瞬间就提前放行。这一路**不去动连接池**——解析都没
          // 成功，池子里根本没有可怪罪的连接，重建只会白白打断同批在途请求。
          if (isDnsFailure(err)) {
            final dns = (extra['_rd'] ??= 0) as int;
            if (dns < _dnsRetryDelays.length) {
              extra['_rd'] = dns + 1;
              if (dns == 0) onDnsError?.call();
              _retryAfter(_dnsRetryDelays[dns], err, handler);
              return;
            }
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
    dnsGate: dnsGate,
  );
}
