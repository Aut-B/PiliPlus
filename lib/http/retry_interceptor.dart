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

  /// 域名解析失败的补偿重试阶梯（毫秒，累计约 16 秒）。
  ///
  /// 单独一套，因为这与 [_count]/[_delay] 根本不是一回事：那套（默认 2 次 × 500ms）是为
  /// 「偶发的连接抖动」准备的，总共只争取到 1.5 秒；而解析失败是**成片**发生的——系统
  /// 解析服务在切前后台之后的头十几秒会整段不可用，1.5 秒的预算必然输掉这场赛跑。
  /// 真机读数正好落在边界上：回前台 **+1.6s** 报 `Failed host lookup`，也就是重试刚用
  /// 完的那一刻。（连接池对此无能为力，重建也治不了域名解析。）
  static const _dnsRetryDelays = [800, 2000, 4500, 9000];

  RetryInterceptor(this._client, this._count, this._delay, {this.recover});

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

          // 域名解析失败单独走一条慢速阶梯：等 0.8 / 2 / 4.5 / 9 秒（累计约 16 秒）再试。
          // 这一路**不去动连接池**——解析都没成功，池子里根本没有可怪罪的连接，
          // 重建只会白白打断同批在途请求。
          if (isHostLookupFailure(err.error)) {
            final dns = (extra['_rd'] ??= 0) as int;
            if (dns < _dnsRetryDelays.length) {
              extra['_rd'] = dns + 1;
              Timer(
                Duration(milliseconds: _dnsRetryDelays[dns]),
                () => _client
                    .fetch(err.requestOptions)
                    .then(handler.resolve)
                    .onError<DioException>((error, _) => handler.next(error)),
              );
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
  );
}
