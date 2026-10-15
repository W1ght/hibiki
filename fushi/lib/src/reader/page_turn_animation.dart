/// 小说阅读器与漫画阅读器共用的翻页动画值域（效果 / 速度 / 降级规则）。
///
/// 两个阅读器各自落盘（漫画沿用 `manga_page_animation`，小说用 reader_settings
/// 里的 `page_turn_animation`），但**值域与降级规则只在这里写一次**：同一个
/// 「覆盖」在两边必须是同一个持久化字符串、同一档速度必须是同一个毫秒数，
/// 墨水屏 / 系统减弱动态效果的降级也不能两边各写一套。
///
/// 刻意做成无依赖的叶子文件：偏好仓库、设置 schema、JS 生成器都要用它。
library;

/// 翻页动画效果。存字符串 [key] 而非 index：重排枚举不得破坏已落盘的偏好。
enum PageTurnAnimation {
  none('none'),
  slide('slide'),
  cover('cover'),
  fade('fade');

  const PageTurnAnimation(this.key);

  /// 持久化 / 传给 JS 的字符串。
  final String key;

  /// 解析落盘值；未知值回落 [fallback]（两个阅读器的默认值不同）。
  static PageTurnAnimation fromKey(
    String? raw, {
    required PageTurnAnimation fallback,
  }) {
    for (final PageTurnAnimation value in PageTurnAnimation.values) {
      if (value.key == raw) return value;
    }
    return fallback;
  }

  /// 是否是有位移的效果（只有这两种能做「拖动跟手」）。
  bool get isDirectional =>
      this == PageTurnAnimation.slide || this == PageTurnAnimation.cover;
}

/// 翻页动画速度三档。
enum PageTurnAnimationSpeed {
  fast('fast', 160),
  normal('normal', 240),
  slow('slow', 360);

  const PageTurnAnimationSpeed(this.key, this.durationMs);

  final String key;

  /// 一次完整翻页动画的时长（毫秒）。
  final int durationMs;

  static PageTurnAnimationSpeed fromKey(String? raw) {
    for (final PageTurnAnimationSpeed value in PageTurnAnimationSpeed.values) {
      if (value.key == raw) return value;
    }
    return PageTurnAnimationSpeed.normal;
  }
}

/// 把用户选的效果按环境降级成实际播放的效果。
///
/// - 墨水屏：一律 [PageTurnAnimation.none]（残影比动画更糟）。
/// - 系统「减弱动态效果」（`MediaQuery.disableAnimationsOf`）：有位移的效果降成
///   [PageTurnAnimation.fade]，淡入与无保持不变。
PageTurnAnimation effectivePageTurnAnimation(
  PageTurnAnimation selected, {
  required bool eink,
  required bool reduceMotion,
}) {
  if (eink) return PageTurnAnimation.none;
  if (reduceMotion && selected.isDirectional) return PageTurnAnimation.fade;
  return selected;
}

/// 跳过多少页以上不再播动画（目录 / 进度条 / 书签等长距离跳转一律瞬时）。
const int kPageTurnAnimationMaxAnimatedDistance = 1;

/// 「拖动跟手」松手提交翻页的位移阈值（占视口宽度的比例）。
const double kPageTurnFollowCommitFraction = 0.25;

/// 「拖动跟手」松手提交翻页的甩动速度阈值（逻辑像素 / 毫秒）。
const double kPageTurnFollowFlingVelocity = 0.6;
