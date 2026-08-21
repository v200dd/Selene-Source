/// A timed comment returned by a danmaku provider.
class DanmakuComment {
  const DanmakuComment({
    required this.time,
    required this.text,
    this.color = 0xFFFFFFFF,
    this.mode = 1,
  });

  final Duration time;
  final String text;
  final int color;

  /// 1 = scrolling, 4 = bottom, 5 = top (the danmu_api convention).
  final int mode;
}
