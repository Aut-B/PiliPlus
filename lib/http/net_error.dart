import 'dart:io';

import 'package:dio/dio.dart';

/// 连接类失败的分型。
///
/// 这两类错误在界面上长得一模一样（都提示「连接错误，请检查网络设置」），成因却相反，
/// 处置办法也相反，所以必须分开：
///
/// - [NetErrorKind.dns]：域名**压根没解析出来**（`Failed host lookup: 'x'`）。socket 从未
///   建立，连接池里不存在「已被系统收走的死连接」这回事，**重建连接池对这种错误毫无作用**。
///   它本质上是**瞬时的**——系统的解析服务在切前后台、代理/VPN 重连、网络切换之后的头十几
///   秒里会整段不可用——所以正确的做法是**隔久一点再试**，而不是换连接池。
/// - [NetErrorKind.connection]：域名解析出来了，但连不上或连断了。这时连接池里可能留着
///   已经失效的 socket，重建一次是有意义的。
enum NetErrorKind { none, dns, connection }

/// 解析故障期的「面向用户提示」名额。
///
/// 解析失败是**成片**的：一轮故障期里几十个请求会接连报同一个错。逐个弹提示的结果是
/// 屏幕上刷满绿条，用户还会把这条提示本身当成故障（真机截图里就是如此）。这里把提示收成
/// 「每个故障期一次」，解析恢复后由 [DnsRecovery] 重新放行。
bool _dnsNoticePending = false;

/// 记下「这一轮解析故障期还没跟用户说过」。
void noteDnsNoticePending() => _dnsNoticePending = true;

/// 解析恢复：下一轮故障期可以再提示一次。
void clearDnsNoticePending() => _dnsNoticePending = false;

/// 取用一次提示名额（本轮故障期已提示过就返回 false）。
bool takeDnsNotice() {
  if (!_dnsNoticePending) {
    return false;
  }
  _dnsNoticePending = false;
  return true;
}

/// 把 [DioException] 归到上面三类之一。
NetErrorKind classifyNetError(DioException err) {
  switch (err.type) {
    case DioExceptionType.connectionError:
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.unknown:
      break;
    default:
      return NetErrorKind.none;
  }
  return isDnsFailure(err) ? NetErrorKind.dns : NetErrorKind.connection;
}

/// [DioException] 是不是「域名解析失败」。
///
/// 比 [isHostLookupFailure] 多认一层：除了看底层异常，也认 dio 自己那条 message。
/// 不同适配器（http1 / http2）包装异常的方式不完全一样，两边都认一遍更稳；认错了也
/// 没有副作用——解析失败这条路只做「隔久一点再试」，不做任何破坏性动作。
bool isDnsFailure(DioException err) {
  if (isHostLookupFailure(err.error)) {
    return true;
  }
  // dio 那条 message 是可空的（声明为 `String?`），所以先取出来判空再比。
  final message = err.message;
  if (message == null) {
    return false;
  }
  return message.contains('Failed host lookup') ||
      message.contains('nodename nor servname') ||
      message.contains('Name or service not known');
}

/// 判断一个底层异常是不是「域名解析失败」。
///
/// Dart 在解析失败时抛 `SocketException('Failed host lookup: $host')`，把系统 errno 的
/// 说法放在 `osError` 里。同一个原因在不同平台上的措辞不一样（Darwin 是
/// `nodename nor servname provided`，即 EAI_NONAME；Linux 系常见 `Name or service not
/// known` / `Temporary failure in name resolution`；没有 A 记录时是
/// `No address associated with hostname`），所以逐个认一遍。
bool isHostLookupFailure(Object? error) {
  if (error is! SocketException) {
    return false;
  }
  if (error.message.startsWith('Failed host lookup')) {
    return true;
  }
  final osError = error.osError;
  if (osError == null) {
    return false;
  }
  final message = osError.message.toLowerCase();
  return message.contains('nodename nor servname') ||
      message.contains('name or service not known') ||
      message.contains('temporary failure in name resolution') ||
      message.contains('no address associated');
}

/// 底层异常原文，用于把真机现场带回来看（诊断用）。
String netErrorRaw(Object? error) {
  return switch (error) {
    null => '',
    SocketException(:final message, :final osError?) =>
      '$message (${osError.message})',
    SocketException(:final message) => message,
    _ => error.toString(),
  };
}
