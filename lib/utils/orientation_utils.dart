import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';

/// 屏幕朝向策略。
///
/// 之前没有任何一处统一管朝向，结果出现两个问题：
/// 1. 播放页只被允许一个方向的横屏时，用户往另一边转手机，画面就整体倒过来 180°；
/// 2. 从播放页退回首页后，朝向没人恢复，首页一直停在横屏。
///
/// 所以这里集中成两个状态：非播放页锁竖屏，播放页放开竖屏 + 两个方向的横屏，
/// 让系统跟着重力传感器选，用户不管往左还是往右转，画面都是正的。
class OrientationUtils {
  const OrientationUtils._();

  /// 播放页允许的朝向。两个横屏都要给，否则转错方向就会倒过来。
  static const _playbackOrientations = <DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  /// 平板不锁竖屏——横屏本来就是它的主要使用姿态。
  static bool get _isPhone {
    if (!_isMobile) return false;
    final view = PlatformDispatcher.instance.implicitView;
    if (view == null) return true;
    final size = view.physicalSize / view.devicePixelRatio;
    return size.shortestSide < 600;
  }

  /// 非播放页统一竖屏。退出播放页时调用，首页就会自动转回竖屏。
  static Future<void> lockPortrait() async {
    if (!_isPhone) return;
    await SystemChrome.setPreferredOrientations(
      const [DeviceOrientation.portraitUp],
    );
  }

  /// 进播放页时放开旋转，但不主动强制横屏（用户明确要求不要自动旋转）。
  static Future<void> allowPlaybackRotation() async {
    if (!_isMobile) return;
    await SystemChrome.setPreferredOrientations(_playbackOrientations);
  }
}
