// edit from package:dio_cookie_manager
import 'dart:io';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/net_error.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/api_type.dart';
import 'package:PiliPlus/utils/app_sign.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

final _setCookieReg = RegExp('(?<=)(,)(?=[^;]+?=)');

class AccountManager extends Interceptor {
  AccountManager();

  static String blockServer = Pref.blockServer;

  /// 连接现场读数的提供者，由 [Request] 注入（临时诊断用，定位到原因后即可去掉）。
  static String Function()? connectionDiag;

  static String getCookies(List<Cookie> cookies) {
    // Sort cookies by path (longer path first).
    cookies.sort((a, b) {
      if (a.path == null && b.path == null) {
        return 0;
      } else if (a.path == null) {
        return -1;
      } else if (b.path == null) {
        return 1;
      } else {
        return b.path!.length.compareTo(a.path!.length);
      }
    });
    return cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.path;

    final account = _bindRequestAccount(options);

    if (account is NoAccount || _skipCookie(path)) return handler.next(options);

    if (!account.isLogin && path == Api.heartBeat) {
      return handler.reject(
        DioException.requestCancelled(requestOptions: options, reason: null),
        false,
      );
    }

    final isApp = path.startsWith(HttpString.appBaseUrl);

    if (isApp && options.responseType == ResponseType.bytes) {
      options.headers.addAll(account.grpcHeaders);
      return handler.next(options);
    }

    options.headers
      ..addAll(account.headers)
      ..['referer'] ??= HttpString.baseUrl;

    // app端不需要管理cookie
    if (isApp) {
      // if (kDebugMode) debugPrint('is app: ${options.path}');
      final dataPtr = (options.method == 'POST' && options.data is Map
          ? (options.data as Map).cast<String, dynamic>()
          : options.queryParameters);
      if (dataPtr.isNotEmpty) {
        if (!account.accessKey.isNullOrEmpty) {
          dataPtr['access_key'] = account.accessKey!;
        }
        AppSign.appSign(dataPtr..remove('sign'));
        // if (kDebugMode) debugPrint(dataPtr.toString());
      }
      return handler.next(options);
    } else {
      account.cookieJar
          .loadForRequest(options.uri)
          .then((cookies) {
            final previousCookies =
                options.headers[HttpHeaders.cookieHeader] as String?;
            final newCookies = getCookies([
              ...?previousCookies
                  ?.split(';')
                  .where((e) => e.isNotEmpty)
                  .map(Cookie.fromSetCookieValue),
              ...cookies,
            ]);
            options.headers[HttpHeaders.cookieHeader] = newCookies.isNotEmpty
                ? newCookies
                : '';
            handler.next(options);
          })
          .catchError((Object e, StackTrace s) {
            final err = DioException(
              requestOptions: options,
              error: e,
              stackTrace: s,
            );
            handler.reject(err, true);
          });
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (_boundRequestAccount(response.requestOptions) case final account?) {
      final future = _saveCookies(
        account,
        response,
      ).whenComplete(() => handler.next(response));
      assert(() {
        future.catchError(
          (Object e, StackTrace s) {
            throw DioException(
              requestOptions: response.requestOptions,
              error: e,
              stackTrace: s,
            );
          },
        );
        return true;
      }());
    } else {
      return handler.next(response);
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final options = err.requestOptions;
    if (options.responseType == ResponseType.stream) {
      return handler.next(err);
    }

    if (options.method != 'POST') toast(err);

    if (err.response case final res?) {
      if (_boundRequestAccount(options) case final account?) {
        _saveCookies(account, res).then(
          (_) => handler.next(err),
          onError: (Object e, StackTrace s) => handler.next(
            DioException(
              requestOptions: options,
              error: e,
              stackTrace: s,
            ),
          ),
        );
        return;
      }
    }
    return handler.next(err);
  }

  static void toast(DioException err) {
    const skipShow = [
      'heartbeat',
      'history/report',
      'roomEntryAction',
      'seg.so',
      'online/total',
      'github',
      'hdslb.com',
      'biliimg.com',
      'site/getCoin',
    ];
    final url = err.requestOptions.uri.toString();
    if (kDebugMode) debugPrint('🌹🌹ApiInterceptor: $url\n$err');
    if (skipShow.any(url.contains) ||
        (url.contains('skipSegments') && err.requestOptions.method == 'GET')) {
      return;
    }
    // 域名解析失败单独给一条说明。
    //
    // 它不是「网络设置」出了问题，用户也没有任何可做的动作：设备上常驻代理/VPN 时，
    // 隧道重建期间全部查询会一起失败。这里把网址省掉、把话说清楚。
    //
    // 措辞改过一次，原因值得记着：老版本说「恢复后会自动继续」，而支撑那句话的是
    // 「请求会在拦截器里熬一条 4 分钟的阶梯 + 一支主动解析探针」。那套东西本身会制造
    // 挂住的解析调用、把进程的解析能力榨干（真机现象：「整个软件都没网」），已经整体
    // 拆除。现在解析失败是**当场失败**，所以话也照实说：稍后刷新即可——一次刷新就是
    // 一次免费的探针，而且不花任何代价。
    //
    // 另外两点是从真机上学到的：① 这条提示本身被当成了「软件坏了」，所以措辞往轻里写；
    // ② 一轮故障期里几十个请求会接连报同一个错，逐个弹就是刷屏，所以改成**每个故障期
    // 只提示一次**（名额在解析恢复时放行，见 [DnsRecovery]）。
    if (isDnsFailure(err)) {
      final host = err.requestOptions.uri.host;
      if (!takeDnsNotice()) return;
      _show('网络解析暂时不通（$host），稍后刷新即可', seconds: 30, diag: true);
      return;
    }
    dioError(err).then(
      (res) => _show('$res${_connDetail(err)}${url.subLength(60)}', seconds: 3),
    );
  }

  /// 弹出错误提示；同一条文案在 [seconds] 秒内只弹一次。
  ///
  /// 同一条错误如果被高频重复触发（例如某个接口陷入重试循环），逐个弹出的结果是覆盖层
  /// 堆满、把主线程一起拖住，用户也只会看到刷屏。
  static void _show(
    String msg, {
    required int seconds,
    bool diag = false,
  }) {
    final now = DateTime.now();
    final lastAt = _lastToastAt;
    if (msg == _lastToastMsg &&
        lastAt != null &&
        now.difference(lastAt) < Duration(seconds: seconds)) {
      return;
    }
    _lastToastMsg = msg;
    _lastToastAt = now;
    final detail = diag ? ' ${connectionDiag?.call() ?? ''}' : '';
    SmartDialog.showToast('$msg$detail');
  }

  /// 连接类错误附一段现场读数：底层异常原文 + 连接池/前后台的现场读数。
  ///
  /// 真机上拿不到日志，提示是唯一能带回现场的地方，所以先都塞在这里（临时诊断用）。
  static String _connDetail(DioException err) {
    switch (err.type) {
      case .connectionError:
      case .connectionTimeout:
      case .sendTimeout:
        break;
      default:
        return '';
    }
    final error = err.error;
    final String raw = switch (error) {
      null => '',
      // 两个都带上：一个是 Dart 侧的说法，一个是系统 errno 的说法
      SocketException(:final message, :final osError?) =>
        '$message (${osError.message})',
      SocketException(:final message) => message,
      _ => error.toString(),
    };
    final buffer = StringBuffer();
    if (raw.isNotEmpty) {
      buffer.write(' [${raw.subLength(70)}]');
    }
    final diag = connectionDiag?.call();
    if (diag != null && diag.isNotEmpty) {
      buffer.write(' $diag');
    }
    return buffer.toString();
  }

  /// [toast] 的节流状态：上一条错误文案与弹出时刻。
  static String? _lastToastMsg;
  static DateTime? _lastToastAt;

  static Future<void> _saveCookies(Account account, Response response) async {
    final setCookies = response.headers[HttpHeaders.setCookieHeader];
    if (setCookies == null || setCookies.isEmpty) {
      return;
    }
    final List<Cookie> cookies = setCookies
        .map((str) => str.split(_setCookieReg))
        .expand((cookie) => cookie)
        .where((cookie) => cookie.isNotEmpty)
        .map(Cookie.fromSetCookieValue)
        .toList();
    final statusCode = response.statusCode ?? 0;
    final locations = response.headers[HttpHeaders.locationHeader] ?? const [];
    final isRedirectRequest = statusCode >= 300 && statusCode < 400;
    final originalUri = response.requestOptions.uri;
    final realUri = originalUri.resolveUri(response.realUri);
    await account.cookieJar.saveFromResponse(realUri, cookies);
    if (isRedirectRequest && locations.isNotEmpty) {
      final originalUri = response.realUri;
      await Future.wait(
        locations.map(
          (location) => account.cookieJar.saveFromResponse(
            // Resolves the location based on the current Uri.
            originalUri.resolve(location),
            cookies,
          ),
        ),
      );
    }
    await account.onChange();
  }

  static bool _skipCookie(String path) {
    return path.startsWith(blockServer) ||
        path.contains('hdslb.com') ||
        path.contains('biliimg.com');
  }

  static Account _findAccount(String path) => ApiType.loginApi.contains(path)
      ? AnonymousAccount()
      : Accounts.get(
          AccountType.values.firstWhere(
            (i) => ApiType.apiTypeSet[i]?.contains(path) == true,
            orElse: () => AccountType.main,
          ),
        );

  static Account _bindRequestAccount(RequestOptions options) {
    assert(options.extra['account'] is Account?);
    return options.extra['account'] ??= _findAccount(options.path);
  }

  static Account? _boundRequestAccount(RequestOptions options) {
    final path = options.path;
    final account = options.extra['account'] as Account;
    if (account is NoAccount ||
        path.startsWith(HttpString.appBaseUrl) ||
        _skipCookie(path)) {
      return null;
    }
    return account;
  }

  static Future<String> dioError(DioException error) async {
    switch (error.type) {
      case .badCertificate:
        return '证书有误！';
      case .badResponse:
        return '服务器异常，请稍后重试！';
      case .cancel:
        return '请求已被取消，请重新请求';
      case .connectionError:
        // 域名没解析出来和「连不上」在界面上长得一样，但用户能做的事完全不同：
        // 前者只能等（设备上开着代理/VPN 时隧道重建期间会整段失败，几十秒后就自己好了），
        // 说成「请检查网络设置」只会让人白折腾，所以这里分开说。
        return isDnsFailure(error) ? '域名解析失败，正在自动重试' : '连接错误，请检查网络设置';
      case .connectionTimeout:
        return '网络连接超时，请检查网络设置';
      case .receiveTimeout:
        return '响应超时，请稍后重试！';
      case .sendTimeout:
        return '发送请求超时，请检查网络设置';
      case .transformTimeout:
        return '转换响应数据超时！';
      case .unknown:
        String desc;
        try {
          desc = PlatformUtils.isMobile
              ? (await Connectivity().checkConnectivity()).first.desc
              : '';
        } catch (_) {
          desc = '';
        }
        return '$desc网络异常 ${error.error}';
    }
  }
}

extension _ConnectivityResultExt on ConnectivityResult {
  String get desc => const ['蓝牙', 'Wi-Fi', '局域', '流量', '无', '代理', '其他'][index];
}
