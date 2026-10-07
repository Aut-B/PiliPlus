import 'package:PiliPlus/http/net_error.dart';

/// 域名解析故障期的状态机。
///
/// ## 它现在**不解析任何域名**，这是最重要的性质
///
/// 前几版这里有一支主动探针：每 3 秒调一次 `InternetAddress.lookup`，去问「解析回来了
/// 没有」。那条路在设备上常驻代理/VPN 时是**有害**的，而且危害比它要修的问题大得多：
///
/// * 隧道半死时 `getaddrinfo` 不是快速失败，而是**把手上的线程挂住**；
/// * Dart **取消不了**它——`.timeout(3s)` 只是让 Dart 这一侧不再等，底层那次调用仍然
///   占着线程一路挂着；
/// * 于是探针每 3 秒漏水一样多占一个线程，跑满一轮 4 分钟就是上百个挂住的解析调用；
/// * 同一进程里其他一切都得从这套 IO 线程/系统解析队列里过——**连不需要解析的请求也发
///   不出去**。真机上的说法是「我一返回视频，整个软件都没网」。
///
/// 再加一笔：为了「解析故障期可能很长」，重试阶梯也被拉到了 10 档 246 秒，等于把每个
/// 失败请求都变成 10 次**新的**解析调用。一个视频页同时有十来个请求，这一下就是上百次
/// ——和探针叠在一起，把进程自己的解析能力彻底榨干。
///
/// 也就是说：为了修一个「短暂变慢」的问题，我们自己造出了一个「全局瘫痪」的问题。
///
/// ## 现在只做两件事，都是零成本的
///
/// 1. **记账**：确认是一次解析故障（而不是抖一下）时报一次，并供读数使用。
/// 2. **广播**：等一个**真实请求成功**（[noteSuccess]）——那是「解析、连接、服务此刻
///    都通」的硬证据——然后通知订阅者（视频页据此把先前落空的取流补回来）。
///
/// 没有任何主动解析、没有任何定时器、没有任何需要等待才能完成的 future。故障期再长，
/// 这个类也不会自己去制造一个网络请求。
///
/// ## 判据从哪儿来
///
/// 不再有「探针测出恢复耗时」这种东西。`rc` 记的是「真实请求确认恢复」的次数，`age` 是
/// 故障期已经开了多久——这两个都只是账簿，不驱动任何行为。
class DnsRecovery {
  DnsRecovery._();

  /// 故障期是否还没结束。
  static bool _faultOpen = false;

  /// 此刻是否正处在一个未结束的解析故障期里。
  ///
  /// [RetryInterceptor] 用它做闸门：故障期一旦确认，后续的解析失败**一次都不再重试**
  /// ——重试就是在已经堵住的解析队列上再压一次，它本身不会让解析变好。
  static bool get hasOpenFault => _faultOpen;

  /// 当前故障期的主机名（只用于读数）。
  static String? host;

  /// 累计确认的解析失败次数（读数里的 `dn`）。
  static int errorCount = 0;

  /// 由真实请求成功确认恢复的次数（`rc`）。
  static int recoveredByRequest = 0;

  /// 这一轮故障期是什么时候开的（读数里的 `age`）。
  static DateTime? faultOpenedAt;

  static final List<void Function()> _listeners = [];

  static void addListener(void Function() listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  static void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// 记一次**确认的**解析失败。
  ///
  /// 调用点在 [RetryInterceptor] 的短阶梯**走完仍失败**那一刻——故意不在头一次失败时
  /// 就报：那样每一次网络抖动都会算成一轮故障期，读数与提示都会失真、频繁。
  static void noteFailure([String? failedHost]) {
    errorCount++;
    if (failedHost != null && failedHost.isNotEmpty) {
      host = failedHost;
    }
    if (!_faultOpen) {
      _faultOpen = true;
      faultOpenedAt = DateTime.now();
    }
    noteDnsNoticePending();
  }

  /// 一个真实请求成功了。
  ///
  /// 这是「解析恢复」唯一可信的判据，而且不需要谁来批准：能收到响应，说明解析、连接、
  /// 服务此刻都是通的。它也是结束故障期的**唯一**途径——没有探针之后，这条路径从
  /// 「主路径」变成了「独木桥」，所以它必须足够便宜：挂在 [Request._send] 的成功分支上，
  /// 一次比较而已。
  static void noteSuccess() {
    if (!_faultOpen) {
      return;
    }
    recoveredByRequest++;
    _endFault();
  }

  /// 结束故障期：放出提示名额，并通知订阅者。
  static void _endFault() {
    if (!_faultOpen) {
      return;
    }
    _faultOpen = false;
    faultOpenedAt = null;
    clearDnsNoticePending();
    for (final listener in List.of(_listeners)) {
      try {
        listener();
      } catch (_) {}
    }
  }

  /// 现场读数（由 `Request.connectionDiag` 拼进错误提示后面带回来）。
  ///
  /// `dn` 累计确认的解析失败次数、`rc` 由真实请求确认恢复的次数、`fault` 是故障期开关、
  /// `age` 是这一轮已经开了多久。这里**没有**「探针时长」了——因为已经没有探针。
  static String diag() {
    final openedAt = faultOpenedAt;
    final String age = openedAt == null
        ? '-'
        : '${DateTime.now().difference(openedAt).inSeconds}s';
    return 'dn=$errorCount rc=$recoveredByRequest '
        'fault=${_faultOpen ? 'on' : 'off'} age=$age';
  }

  /// 仅供离线用例：把状态清回初始。
  static void resetForTest() {
    host = null;
    errorCount = 0;
    recoveredByRequest = 0;
    faultOpenedAt = null;
    _faultOpen = false;
    _listeners.clear();
    clearDnsNoticePending();
  }
}
