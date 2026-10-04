import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/net_error.dart';
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

  /// 上一次后台停留时长、最近一次回到前台的时刻、累计重建连接池次数、
  /// 最近一次重建/最近一次连接失败的时刻。前三个只用于 [connectionDiag]。
  static Duration? _lastBackgroundDuration;
  static DateTime? _resumedAt;
  static int _rebuildCount = 0;
  static DateTime? _lastRebuildAt;
  static DateTime? _lastConnErrorAt;

  /// [dio] 上是否装了带现场自愈能力的重试拦截器（装了就不必在 [Request._send] 再兜一次）。
  static bool _retryRecoveryInstalled = false;

  /// 连接失败的自愈窗口：累计次数与窗口起点、上次重建时刻。
  static int _connErrorCount = 0;
  static DateTime? _connErrorWindowStart;
  static DateTime? _lastConnRecoverAt;

  /// 域名解析失败的累计次数，以及回前台后「解析恢复正常」所花的秒数（诊断用）。
  static int _dnsErrorCount = 0;
  static double? _dnsRecoverSeconds;

  /// 记录一次「连接失败」，短时间成串出现时自动重建连接池。
  ///
  /// 画中画会让 App 带着活跃播放在后台停留很久，iOS 可能已经把这些 socket 收走，
  /// 而连接池仍当作可用——于是错误成串出现（视频详情、评论、弹幕一起失败），
  /// 并且不会自行恢复。原先唯一的出路是杀掉进程重开，这里把它降级为自动重建：
  /// 10 秒内累计 8 次连接失败就重建一次，30 秒内最多重建一次（重建会中断在途请求，
  /// 所以要限频）。
  ///
  /// **域名解析失败不算在内**：那种错误下 socket 从未建立，池子里没有可怪罪的连接，
  /// 重建纯属无效动作（真机据此白跑过一轮：`Failed host lookup` 照样重建了连接池，
  /// 提示分毫未变）。它由 [RetryInterceptor] 的慢速阶梯负责，这里只记数。
  static void _noteConnectionError(DioException err) {
    final now = DateTime.now();
    if (isHostLookupFailure(err.error)) {
      _dnsErrorCount++;
      return;
    }
    if (err.type != DioExceptionType.connectionError) {
      return;
    }
    _lastConnErrorAt = now;
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
  /// 不动它，避免每次切前台都白白打断在途请求；关闭时不用 force，让在途请求自己跑完
  /// （池里的空闲连接——也就是可能已经死掉的那些——会被立刻丢掉）。
  static void recoverConnectionsAfterBackground() {
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    _resumedAt = DateTime.now();
    if (backgroundedAt == null) {
      return;
    }
    _lastBackgroundDuration = _resumedAt!.difference(backgroundedAt);
    // 回到前台后域名解析可能还没活过来，量一下它到底要多久（诊断用）。
    _probeDnsRecovery();
    if (_lastBackgroundDuration! < const Duration(seconds: 15)) {
      return;
    }
    _resetAdaptersForNetworkChange(force: false);
  }

  /// 回到前台时探一次域名解析，量一量「解析恢复正常」究竟要多久。
  ///
  /// 解析失败是**成片**发生的：要么一次就成功，要么连着十几秒全失败。补偿重试的阶梯该
  /// 设多长完全取决于这段空窗有多长，而真机上拿不到任何日志——所以只能在这里量，再把
  /// 数字附在错误提示后面带回来。每 600ms 试一次，20 秒还没好就记 -1。
  static void _probeDnsRecovery() {
    final host = Uri.parse(HttpString.appBaseUrl).host;
    final startedAt = DateTime.now();
    _dnsRecoverSeconds = null;
    var attempts = 0;
    Future<void> probe() async {
      attempts++;
      try {
        await InternetAddress.lookup(host);
        _dnsRecoverSeconds =
            DateTime.now().difference(startedAt).inMilliseconds / 1000;
      } catch (_) {
        if (attempts < 33) {
          Timer(const Duration(milliseconds: 600), probe);
        } else {
          _dnsRecoverSeconds = -1;
        }
      }
    }

    probe();
  }

  /// 连接失败后想再发一次之前先问这里：现在重发值不值得？
  ///
  /// 返回 true 表示可以重发（顺便保证池子里没有残留的死连接）；返回 false 表示刚有请求
  /// 彻底失败过，多半是网络本身不通，重发只是白白增加请求量。
  static bool _recoverPoolForRetry() {
    final now = DateTime.now();
    final lastConnErrorAt = _lastConnErrorAt;
    if (lastConnErrorAt != null &&
        now.difference(lastConnErrorAt) < const Duration(seconds: 2)) {
      return false;
    }
    final lastRebuildAt = _lastRebuildAt;
    if (lastRebuildAt == null ||
        now.difference(lastRebuildAt) >= const Duration(seconds: 5)) {
      // 只丢掉池里的空闲连接（也就是可能已经被系统收走的那些），不动在途请求——
      // 用 force 会把同批请求一起打断，反而再制造一批连接错误。
      _resetAdaptersForNetworkChange(force: false);
    }
    return true;
  }

  /// 连接问题的现场读数，会附在错误提示后面（临时诊断用）。
  ///
  /// `bg` 上一次后台停留多久（`-` 表示压根没收到进入后台的事件）、`rb` 累计重建连接池
  /// 次数、`dn` 累计域名解析失败次数、`dns` 回前台后解析恢复正常花了多久
  /// （`?` 表示还没量出来、`>20s` 表示 20 秒都没好）、`t` 距上次回到前台多久。
  static String connectionDiag() {
    final backgroundDuration = _lastBackgroundDuration;
    final resumedAt = _resumedAt;
    final String bg = backgroundDuration == null
        ? '-'
        : '${backgroundDuration.inSeconds}s';
    final String sinceResume = resumedAt == null
        ? '-'
        : '+${(DateTime.now().difference(resumedAt).inMilliseconds / 1000).toStringAsFixed(1)}s';
    final recover = _dnsRecoverSeconds;
    final String dns = recover == null
        ? '?'
        : recover < 0
        ? '>20s'
        : '${recover.toStringAsFixed(1)}s';
    return '[bg=$bg rb=$_rebuildCount dn=$_dnsErrorCount dns=$dns t=$sinceResume]';
  }

  static void _onConnectivityChanged(List<ConnectivityResult> result) {
    if (listEquals(result, const [ConnectivityResult.none])) {
      return;
    }
    _networkChangeDebounce?.cancel();
    _networkChangeDebounce = Timer(
      const Duration(milliseconds: 500),
      () => _resetAdaptersForNetworkChange(),
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
  static void _resetAdaptersForNetworkChange({bool force = true}) {
    try {
      final (h11, connectionManager) = _createPool();
      if (connectionManager != null) {
        (dio.httpClientAdapter as Http2Adapter)
          ..connectionManager.close(force: force)
          ..connectionManager = connectionManager
          ..fallbackAdapter.close(force: force)
          ..fallbackAdapter = h11;
        _http11Dio?.httpClientAdapter = h11;
      } else {
        dio
          ..httpClientAdapter.close(force: force)
          ..httpClientAdapter = h11;
      }
      _rebuildCount++;
      _lastRebuildAt = DateTime.now();
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
      _retryRecoveryInstalled = true;
      dio.interceptors.add(
        RetryInterceptor(
          dio,
          Pref.retryCount,
          Pref.retryDelay,
          recover: _recoverPoolForRetry,
        ),
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

    // 错误提示后面附一段连接现场读数（临时诊断用，定位到原因后即可去掉）
    AccountManager.connectionDiag = connectionDiag;
  }

  /// 发一个请求；连接类失败时允许「换一个干净的连接池再试一次」。
  ///
  /// 后台（画中画）待久了，dio 池里的连接可能已经被系统收走。这类失败重发一次就能
  /// 恢复，没必要冒到用户眼前。真正断网时不会多试太多：[_recoverPoolForRetry]
  /// 会拦掉成串失败；装了 [RetryInterceptor] 时这一步由它负责，这里不再兜。
  static Future<Response> _send(
    Future<Response> Function() send, {
    bool toastError = false,
  }) async {
    try {
      return await send();
    } on DioException catch (e) {
      _noteConnectionError(e);
      // 注意这里限定 connection：域名解析失败与连接池无关，换池再发一次纯属白费
      // （真机上这么干过一整轮，提示分毫未变）。那一类由 RetryInterceptor 的慢速
      // 阶梯负责；没装拦截器时（重试次数被设为 0）就让它如实失败。
      if (!_retryRecoveryInstalled &&
          classifyNetError(e) == NetErrorKind.connection &&
          _recoverPoolForRetry()) {
        try {
          return await send();
        } on DioException catch (retryError) {
          _noteConnectionError(retryError);
          return _failure(retryError, toastError: toastError);
        }
      }
      return _failure(e, toastError: toastError);
    }
  }

  /// 把 [DioException] 包装成调用方一直在用的那种「失败响应」。
  static Future<Response> _failure(
    DioException e, {
    bool toastError = false,
  }) async {
    // POST 的错误提示走这里（ApiInterceptor 只对非 POST 请求弹提示）
    if (toastError) AccountManager.toast(e);
    return Response(
      data: {
        'message': await AccountManager.dioError(e),
      }, // 将自定义 Map 数据赋值给 Response 的 data 属性
      statusCode: e.response?.statusCode ?? -1,
      requestOptions: e.requestOptions,
    );
  }

  /*
   * get请求
   */
  Future<Response> get<T>(
    String url, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) => _send(
    () => dio.get<T>(
      url,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    ),
  );

  /*
   * post请求
   */
  Future<Response> post<T>(
    String url, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) => _send(
    () => dio.post<T>(
      url,
      data: data,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    ),
    toastError: true,
  );

  /*
   * 下载文件
   */
  Future<Response> downloadFile(
    String urlPath,
    String savePath, {
    CancelToken? cancelToken,
  }) => _send(
    () => dio.download(urlPath, savePath, cancelToken: cancelToken),
  );

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
