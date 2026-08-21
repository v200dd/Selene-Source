import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';

/// 屏幕朝向策略。
///
/// 手机上只有两个状态，避免历史上出现过的三类问题：
///
/// - **竖屏**（[lockPortrait]）：首页、列表页，以及播放页的非全屏状态。
///   进播放页不会自动转横屏（这是用户明确要求的），退出播放页会回到竖屏，
///   所以首页不会卡在横屏。
/// - **横屏**（[forceLandscape]）：只有点了全屏按钮才进入。两个方向都允许，
///   由重力传感器决定，用户往左转还是往右转画面都是正的；只给一个方向时，
///   往反方向转就会整屏倒过来 180°。
///
/// 平板不参与这套限制：横屏本来就是它的主要使用姿态，交给系统默认即可。
class OrientationUtils {
  const OrientationUtils._();

  /// 全屏允许的朝向。两个横屏都要给，否则转错方向就会倒过来。
  static const _landscape = <DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  /// 平板不锁朝向。用短边判断，避免横屏时被误判成手机。
  static bool get _isPhone {
    if (!_isMobile) return false;
    final view = PlatformDispatcher.instance.implicitView;
    if (view == null) return true;
    final size = view.physicalSize / view.devicePixelRatio;
    return size.shortestSide < 600;
  }

  /// 回到竖屏：非播放页、播放页非全屏、以及退出全屏时。
  static Future<void> lockPortrait() async {
    if (!_isPhone) return;
    await SystemChrome.setPreferredOrientations(
      const [DeviceOrientation.portraitUp],
    );
  }

  /// 点全屏时转横屏。
  static Future<void> forceLandscape() async {
    if (!_isPhone) return;
    await SystemChrome.setPreferredOrientations(_landscape);
  }
}
