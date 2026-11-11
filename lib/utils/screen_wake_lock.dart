import 'package:wakelock_plus/wakelock_plus.dart';

/// 屏幕常亮的引用计数。
///
/// [WakelockPlus] 是进程级的单一开关：谁调 `disable()` 都会把别人的常亮一起关掉。
/// 站内播放器在暂停 / 销毁时会 `disable()`，于是抖音连播到一半会突然息屏——
/// 那其实是另一个播放器顺手把它关了。
///
/// 改成按持有者计数：只要还有一个页面在播，屏幕就保持常亮；
/// 最后一个持有者放手时才真正关掉。
abstract final class ScreenWakeLock {
  static final Set<Object> _owners = <Object>{};

  /// 登记一个持有者。重复调用是幂等的。
  static void acquire(Object owner) {
    if (!_owners.add(owner)) return;
    WakelockPlus.enable();
  }

  /// 注销一个持有者。只有全部注销之后才真正放开常亮。
  static void release(Object owner) {
    if (!_owners.remove(owner)) return;
    if (_owners.isEmpty) WakelockPlus.disable();
  }
}
