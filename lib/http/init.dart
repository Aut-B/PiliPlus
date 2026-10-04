import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:archive/archive.dart';
import 'package:brotli/brotli.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';
import 'package:flutter/foundation.dart' show kDebugMode, listEquals;

class Request {
  static const _gzipDecoder = GZipDecoder();
  static const _brotliDecoder = BrotliDecoder();

  static final Request _instance = Request._internal();
  static late AccountManager accountManager;
  static final _enableHttp2 = Pref.enableHttp2;
  static late final Dio dio;
  static Dio? _http11Dio;
  static Dio get http11Dio =>
      _http11Dio ??= _enableHttp2 ? _cloneHttp11Dio() : dio;
  factory Request() => _instance;

  /// 设置cookie
  static void setCookie() {
    accountManager = AccountManager();
    dio.interceptors.add(accountManager);
    Accounts.refresh();
    LoginUtils.setWebCookie();

    if (Accounts.main.isLogin) {
      final coin = Pref.userInfoCache?.money;
      if (coin == null) {
        setCoin();
      } else {
        GlobalData().coins = coin;
      }
    }
  }

  static Future<void> setCoin() async {
    final res = await UserHttp.getCoin();
    if (res case Success(:final response)) {
      GlobalData().coins = response;
    }
  }

  static Future<void> buvidActive(Account account) async {
    // 这样线程不安全, 但仍按预期进行
    if (account.activated) return;
    account.activated = true;
    try {
      // final html = await Request().get(Api.dynamicSpmPrefix,
      //     options: Options(extra: {'account': account}));
      // final String spmPrefix = _spmPrefixExp.firstMatch(html.data)!.group(1)!;
      final String randPngEnd = base64.encode([
        ...Iterable<int>.generate(32, (_) => Utils.random.nextInt(256)),
        0,
        0,
        0,
        0,
        73,
        69,
        78,
        68,
        ...Iterable<int>.generate(4, (_) => Utils.random.nextInt(256)),
      ]);

      final jsonData = json.encode({
        '3064': 1,
        '39c8': '333.1387.fp.risk',
        '3c43': {
          'adca': 'Linux',
          'bfe9': randPngEnd.substring(randPngEnd.length - 50),
        },
      });

      await Request().post(
        Api.activateBuvidApi,
        data: {'payload': jsonData},
        options: Options(
          extra: {'account': account},
          contentType: Headers.jsonContentType,
        ),
      );
    } catch (_) {}
  }

  static Dio _cloneHttp11Dio() {
    final h11 = dio.clone(
      httpClientAdapter:
          (dio.httpClientAdapter as Http2Adapter).fallbackAdapter,
    );
    final interceptors = h11.interceptors;
    for (var i = 0; i < interceptors.length; i++) {
      final elem = interceptors[i];
      if (elem is RetryInterceptor) {
        interceptors[i] = elem.copyWith(client: h11);
        break;
      }
    }
    return h11;
  }

  static Timer? _networkChangeDebounce;

  /// 进入后台的时刻（仅用于 [recoverConnectionsAfterBackground]）。
  static DateTime? _backgroundedAt;

  /// 记录 App 进入后台。
  static void markBackgrounded() {
    _backgroundedAt = DateTime.now();
  }

  /// 连接失败的自愈窗口：累计次数与窗口起点、上次重建时刻。
  static int _connErrorCount = 0;
  static DateTime? _connErrorWindowStart;
  static DateTime? _lastConnRecoverAt;

  /// 记录一次「连接失败」，短时间成串出现时自动重建连接池。
  ///
  /// 画中画会让 App 带着活跃播放在后台停留很久，iOS 可能已经把这些 socket 收走，
  /// 而连接池仍当作可用——于是错误成串出现（视频详情、评论、弹幕一起失败），
  /// 并且不会自行恢复。原先唯一的出路是杀掉进程重开，这里把它降级为自动重建：
  /// 10 秒内累计 8 次连接失败就重建一次，30 秒内最多重建一次（重建会中断在途请求，
  /// 所以要限频）。
  static void _noteConnectionError(DioException err) {
    if (err.type != DioExceptionType.connectionError) {
      return;
    }
    final now = DateTime.now();
    final windowStart = _connErrorWindowStart;
    if (windowStart == null ||
        now.difference(windowStart) > const Duration(seconds: 10)) {
      _connErrorWindowStart = now;
      _connErrorCount = 0;
    }
    _connErrorCount++;
    if (_connErrorCount < 8) {
      return;
    }
    final lastRecoverAt = _lastConnRecoverAt;
    if (lastRecoverAt != null &&
        now.difference(lastRecoverAt) < const Duration(seconds: 30)) {
      return;
    }
    _lastConnRecoverAt = now;
    _connErrorCount = 0;
    _connErrorWindowStart = now;
    _resetAdaptersForNetworkChange();
  }

  /// 回到前台时重建连接池。
  ///
  /// iOS 上 App 长时间处于后台后，系统可能已经把它的 socket 收走，而 dio 的连接池仍
  /// 当作那些连接可用：新请求会被塞进这些死连接（报 `DioException.connectionError`），
  /// 池里占满的槽位又会挡住新连接的建立。画中画正好是这个场景——App 带着活跃播放在
  /// 后台待很久，一回到视频页就满屏「连接错误，请检查网络设置」，且只能靠重启恢复。
  ///
  /// 这里复用网络切换时那套重建逻辑（同一件事，只是触发条件不同）。停留时间很短时
  /// 不动它，避免每次切前台都白白打断在途请求。
  static void recoverConnectionsAfterBackground() {
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    if (backgroundedAt == null) {
      return;
    }
    if (DateTime.now().difference(backgroundedAt) <
        const Duration(seconds: 60)) {
      return;
    }
    _resetAdaptersForNetworkChange();
  }

  static void _onConnectivityChanged(List<ConnectivityResult> result) {
    if (listEquals(result, const [ConnectivityResult.none])) {
      return;
    }
    _networkChangeDebounce?.cancel();
    _networkChangeDebounce = Timer(
      const Duration(milliseconds: 500),
      _resetAdaptersForNetworkChange,
    );
  }

  static void _watchConnectivity() {
    Connectivity().onConnectivityChanged.skip(1).listen(_onConnectivityChanged);
  }

  static (IOHttpClientAdapter, ConnectionManager?) _createPool() {
    final bool enableSystemProxy;
    late final String systemProxyHost;
    late final int? systemProxyPort;
    if (Pref.enableSystemProxy) {
      systemProxyHost = Pref.systemProxyHost;
      systemProxyPort = int.tryParse(Pref.systemProxyPort);
      enableSystemProxy = systemProxyPort != null && systemProxyHost.isNotEmpty;
    } else {
      enableSystemProxy = false;
    }

    final http11Adapter = IOHttpClientAdapter(
      createHttpClient: enableSystemProxy
          ? () => HttpClient()
              ..idleTimeout = const Duration(seconds: 15)
              ..autoUncompress = false
              ..findProxy = ((_) => 'PROXY $systemProxyHost:$systemProxyPort')
              ..badCertificateCallback = (cert, host, port) => true
          : () => HttpClient()
              ..idleTimeout = const Duration(seconds: 15)
              ..autoUncompress = false, // Http2Adapter没有自动解压, 统一行为
    );

    final connectionManager = _enableHttp2
        ? ConnectionManager(
            idleTimeout: const Duration(seconds: 15),
            onClientCreate: enableSystemProxy
                ? (_, config) => config
                    ..proxy = Uri(
                      scheme: 'http',
                      host: systemProxyHost,
                      port: systemProxyPort,
                    )
                    ..onBadCertificate = (_) => true
                : Pref.badCertificateCallback
                ? (_, config) => config.onBadCertificate = (_) => true
                : null,
          )
        : null;
    return (http11Adapter, connectionManager);
  }

  @pragma('vm:notify-debugger-on-exception')
  static void _resetAdaptersForNetworkChange() {
    try {
      final (h11, connectionManager) = _createPool();
      if (connectionManager != null) {
        (dio.httpClientAdapter as Http2Adapter)
          ..connectionManager.close(force: true)
          ..connectionManager = connectionManager
          ..fallbackAdapter.close(force: true)
          ..fallbackAdapter = h11;
        _http11Dio?.httpClientAdapter = h11;
      } else {
        dio
          ..httpClientAdapter.close(force: true)
          ..httpClientAdapter = h11;
      }
    } catch (_) {}
  }

  /*
   * config it and create
   */
  Request._internal() {
    //BaseOptions、Options、RequestOptions 都可以配置参数，优先级别依次递增，且可以根据优先级别覆盖参数
    BaseOptions options = BaseOptions(
      //请求基地址,可以包含子路径
      baseUrl: HttpString.apiBaseUrl,
      //连接服务器超时时间，单位是毫秒.
      connectTimeout: const Duration(milliseconds: 10000),
      //响应流上前后两次接受到数据的间隔，单位为毫秒。
      receiveTimeout: const Duration(milliseconds: 10000),
      //Http请求头.
      headers: {
        'user-agent': 'Dart/3.6 (dart:io)', // Http2Adapter不会自动添加标头
        if (!_enableHttp2) 'connection': 'keep-alive',
        'accept-encoding': 'br,gzip',
      },
      responseDecoder: _responseDecoder, // Http2Adapter没有自动解压
      persistentConnection: true,
    );

    final (h11, connectionManager) = _createPool();

    dio = Dio(options)
      ..httpClientAdapter = _enableHttp2
          ? Http2Adapter(connectionManager, fallbackAdapter: h11)
          : h11;

    // 先于其他Interceptor
    if (Pref.retryCount != 0) {
      dio.interceptors.add(
        RetryInterceptor(dio, Pref.retryCount, Pref.retryDelay),
      );
    }

    // 日志拦截器 输出请求、响应内容
    if (kDebugMode) {
      dio.interceptors.add(
        LogInterceptor(
          request: false,
          requestHeader: false,
          responseHeader: false,
        ),
      );
    }

    dio
      ..transformer = BackgroundTransformer()
      ..options.validateStatus = (int? status) {
        return status != null && status >= 200 && status < 300;
      };

    if (Platform.isIOS) _watchConnectivity();
  }

  /*
   * get请求
   */
  Future<Response> get<T>(
    String url, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    try {
      return await dio.get<T>(
        url,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      _noteConnectionError(e);
      return Response(
        data: {
          'message': await AccountManager.dioError(e),
        }, // 将自定义 Map 数据赋值给 Response 的 data 属性
        statusCode: e.response?.statusCode ?? -1,
        requestOptions: e.requestOptions,
      );
    }
  }

  /*
   * post请求
   */
  Future<Response> post<T>(
    String url, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    // if (kDebugMode) debugPrint('post-data: $data');
    try {
      return await dio.post<T>(
        url,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      _noteConnectionError(e);
      AccountManager.toast(e);
      return Response(
        data: {
          'message': await AccountManager.dioError(e),
        }, // 将自定义 Map 数据赋值给 Response 的 data 属性
        statusCode: e.response?.statusCode ?? -1,
        requestOptions: e.requestOptions,
      );
    }
  }

  /*
   * 下载文件
   */
  Future<Response> downloadFile(
    String urlPath,
    String savePath, {
    CancelToken? cancelToken,
  }) async {
    try {
      return await dio.download(
        urlPath,
        savePath,
        cancelToken: cancelToken,
        // onReceiveProgress: (int count, int total) {
        // 进度
        // if (kDebugMode) debugPrint("$count $total");
        // },
      );
      // if (kDebugMode) debugPrint('downloadFile success: ${response.data}');
    } on DioException catch (e) {
      _noteConnectionError(e);
      // if (kDebugMode) debugPrint('downloadFile error: $e');
      return Response(
        data: {
          'message': await AccountManager.dioError(e),
        },
        statusCode: e.response?.statusCode ?? -1,
        requestOptions: e.requestOptions,
      );
    }
  }

  static List<int> responseBytesDecoder(
    List<int> responseBytes,
    Map<String, List<String>> headers,
  ) => switch (headers['content-encoding']?.firstOrNull) {
    'gzip' => _gzipDecoder.decodeBytes(responseBytes),
    'br' => _brotliDecoder.convert(responseBytes),
    _ => responseBytes,
  };

  static String _responseDecoder(
    List<int> responseBytes,
    RequestOptions options,
    ResponseBody responseBody,
  ) => utf8.decode(
    responseBytesDecoder(responseBytes, responseBody.headers),
    allowMalformed: true,
  );
}
