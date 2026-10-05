import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/net_error.dart';

/// 一次域名解析调用的形状（可注入，方便离线验证）。
typedef DnsLookup = Future<List<InternetAddress>> Function(String host);

/// 域名解析故障期的状态机。
///
/// ## 为什么要把这段单拎出来
///
/// 它原先一边修解析，一边自己制造了一个**永不结束**的状态。老探针是
///
/// ```dart
/// await InternetAddress.lookup(host);   // 没有超时
/// ```
///
/// 而设备上常驻代理/VPN 时，隧道半死不活会让 `getaddrinfo` **挂住**——不是快速失败，
/// 是一直不返回。那就既不成功也不报错，探针永远停在那一行上。后果是一条链：
///
/// 1. `probing` 一直为真，收尾函数永远不跑；
/// 2. 而「解析恢复后自动补一次」这个**唯一的自愈入口**正挂在收尾函数上 ⇒ 永不触发；
/// 3. 读数一直显示 `dns=?`。真机截图里 `t=+3651.2s` 配着 `dns=?`，也就是探针「量」了
///    一小时，而它自己的上限是 4 分钟——那不是没量完，那是卡住了。
///
/// 现象上就等同于「卡死、只能退出重进」；而同一台手机上别的客户端照常能用，因为**网络
/// 没坏，是我们把自己锁住了**。（注：这条链解释的是「为什么不恢复」，解析在那几分钟里
/// 确实是真的断了——代理/VPN 切前后台时很常见。）
///
/// ## 现在的两条硬约束
///
/// 1. **一轮探针必然结束**：每次解析调用 3 秒硬超时，一轮总预算 4 分钟，到点必进收尾；
///    一轮结束时若仍未恢复就接着起下一轮（最多 [maxRounds] 轮），所以故障期再长也不会
///    没人管。`px` 这个读数专门记「单次调用超时的次数」——大于 0 就证明解析器是**挂住**
///    而不是快速失败，也就是上面那种情形。
/// 2. **「恢复」以证据为准，不以猜测为准**：任何**真实请求成功**都算恢复（[noteSuccess]），
///    不必等探针回来。探针只是替补。
class DnsRecovery {
  DnsRecovery._();

  /// 单次解析调用的硬超时。**这一条就是防「挂住」的**。
  ///
  /// 这几个时长是可变的，只为一件事：离线用例能把它们压到几十毫秒，从而**真的**验证
  /// 「一轮探针必然结束」。默认值就是线上值。
  static Duration tryTimeout = const Duration(seconds: 3);

  /// 一轮探针的总预算：到点即结束这一轮，不再无限期地等下去。
  static Duration roundBudget = const Duration(seconds: 240);

  /// 一轮探针之间的小间隔。
  static Duration roundGap = const Duration(seconds: 1);

  /// 同一个故障期里最多起几轮探针（≈ 50 分钟）。
  static int maxRounds = 12;

  /// 闸门自己的上界：闸门也曾经可能永不完成，那样「等恢复提前放行」就变成「等一个永远
  /// 不来的信号」。加了上界，最坏也只是退化成老实睡阶梯。
  static Duration gateTimeout = const Duration(seconds: 30);

  /// 实际调用解析的地方，默认就是系统解析（离线用例会替换它）。
  static DnsLookup lookup = InternetAddress.lookup;

  /// 当前故障期正在探的主机名。
  static String? host;

  /// 累计的解析失败次数（读数里的 `dn`）。
  static int errorCount = 0;

  /// 本轮量出的恢复耗时（`null` = 还没量出来，`-1` = 一轮 4 分钟都没恢复）。
  static double? recoverSeconds;

  /// 单次解析调用**超时**的次数。大于 0 即证明解析器是挂住的。
  static int probeTimeouts = 0;

  /// 由「真实请求成功」确认恢复的次数。
  static int recoveredByRequest = 0;

  /// 当前故障期已经起了几轮探针。
  static int probeRounds = 0;

  /// 这一轮探针是什么时候起的（`null` = 没有在探）。
  static DateTime? probeStartedAt;

  static bool _probing = false;
  static Completer<void>? _gate;
  static bool _faultOpen = false;
  static final List<void Function()> _listeners = [];

  /// 现在是否有一轮探针在跑。
  static bool get probing => _probing;

  /// 故障期是否还没结束（恢复信号还没发出去）。
  static bool get hasOpenFault => _faultOpen;

  static void addListener(void Function() listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  static void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// 记一次解析失败。
  ///
  /// 由 [RetryInterceptor] 在头一次看到时调用：它跑在错误提示**之前**，这样提示里带回来
  /// 的读数才是那一刻的真数（早先在 [Request] 那层记账，真机上 `dn` 一直是 0）。
  static void noteFailure([String? failedHost]) {
    errorCount++;
    if (failedHost != null && failedHost.isNotEmpty) {
      host = failedHost;
    }
    _faultOpen = true;
    noteDnsNoticePending();
    startProbe();
  }

  /// 一个真实请求成功了。
  ///
  /// 这是「解析恢复」最可靠的证据，而且不需要谁来批准：能收到响应，说明解析、连接、服务
  /// 此刻都是通的。把它做成恢复的主路径之后，探针就算再坏也锁不住自愈。
  static void noteSuccess() {
    if (!_faultOpen) {
      return;
    }
    recoveredByRequest++;
    _probing = false;
    probeStartedAt = null;
    probeRounds = 0;
    _openGate();
    _endFault();
  }

  /// 解析故障期的闸门：解析一恢复即完成；没有故障期时返回 null。
  static Future<void>? gate() {
    if (!_probing) {
      return null;
    }
    final future = _gate?.future;
    if (future == null) {
      return null;
    }
    return future.timeout(gateTimeout, onTimeout: () {});
  }

  /// 起一轮探针（已经在探就不动）。
  static void startProbe() {
    if (_probing) {
      return;
    }
    final target = host;
    if (target == null || target.isEmpty) {
      return;
    }
    _probing = true;
    recoverSeconds = null;
    probeStartedAt = DateTime.now();
    probeRounds++;
    _gate ??= Completer<void>();
    final startedAt = probeStartedAt!;
    final round = probeRounds;
    unawaited(_runRound(target, startedAt, round));
  }

  /// 一轮探针：每 1 秒试一次解析，每次最多等 [tryTimeout]。
  ///
  /// 无论走哪条路，这一轮都**一定会**走到收尾——这正是老版本缺的那一条。
  static Future<void> _runRound(
    String target,
    DateTime startedAt,
    int round,
  ) async {
    try {
      while (_probing) {
        try {
          await lookup(target).timeout(tryTimeout);
          // 解析确实回来了，如实记下花了多久。
          recoverSeconds =
              DateTime.now().difference(startedAt).inMilliseconds / 1000;
          _probing = false;
          probeStartedAt = null;
          probeRounds = 0;
          _openGate();
          _endFault();
          return;
        } catch (e) {
          // 这一轮可能已经被「请求成功」那条路接过手了（`_probing` 被置假），或者被
          // 下一轮取代：那就别再把这次超时记到新账上。
          if (!_probing) {
            return;
          }
          if (e is TimeoutException) {
            probeTimeouts++;
          }
        }
        if (DateTime.now().difference(startedAt) >= roundBudget) {
          break;
        }
        await Future<void>.delayed(roundGap);
      }
    } catch (_) {
      // 落到下面统一收尾：宁可这一轮白跑，也不能把它停在半路。
    }
    if (!_probing) {
      // 故障期已经被「请求成功」那条路结束了，不需要再做任何事。
      return;
    }
    // 一轮量完仍没恢复：如实记 `>240s`，放掉闸门（别让等在阶梯上的请求再无谓地等），
    // 然后接着起下一轮——故障期可能比一轮长，而恢复的线索只能从这里出来。
    recoverSeconds = -1;
    _probing = false;
    probeStartedAt = null;
    _openGate();
    if (round < maxRounds) {
      startProbe();
    }
  }

  /// 结束故障期：放出提示名额，并通知订阅者（视频页据此把落空的取流补回来）。
  static void _endFault() {
    if (!_faultOpen) {
      return;
    }
    _faultOpen = false;
    probeRounds = 0;
    clearDnsNoticePending();
    for (final listener in List.of(_listeners)) {
      try {
        listener();
      } catch (_) {}
    }
  }

  static void _openGate() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  /// 现场读数（由 `Request.connectionDiag` 拼进错误提示后面带回来）。
  ///
  /// `dn` 累计解析失败次数、`px` 单次解析调用超时次数、`rc` 由真实请求确认恢复的次数；
  /// `dns` 是这一轮的时长——`N s+` 且只增不减就说明探针那一行卡住了（老版本把自己锁死
  /// 的样子），`>240s` 是一轮走完仍没恢复。
  static String diag() {
    final recover = recoverSeconds;
    final startedAt = probeStartedAt;
    final String dns;
    if (recover == null) {
      dns = startedAt == null
          ? '?'
          : '${DateTime.now().difference(startedAt).inSeconds}s+';
    } else if (recover < 0) {
      dns = '>240s';
    } else {
      dns = '${recover.toStringAsFixed(1)}s';
    }
    return 'dn=$errorCount dns=$dns px=$probeTimeouts rc=$recoveredByRequest';
  }

  /// 仅供离线用例：把状态清回初始（不动 [lookup]）。
  static void resetForTest() {
    host = null;
    errorCount = 0;
    recoverSeconds = null;
    probeTimeouts = 0;
    recoveredByRequest = 0;
    probeRounds = 0;
    probeStartedAt = null;
    _probing = false;
    _gate = null;
    _faultOpen = false;
    _listeners.clear();
    clearDnsNoticePending();
    tryTimeout = const Duration(seconds: 3);
    roundBudget = const Duration(seconds: 240);
    roundGap = const Duration(seconds: 1);
    maxRounds = 12;
    gateTimeout = const Duration(seconds: 30);
  }
}
