import 'package:flutter/widgets.dart';

/// 桌面端阅读器顶部细进度线（ッツ Reader 形态）。
///
/// 一条贴正文顶边、整宽的极细轨道，按整书已读比例从左向右填充。它是纯装饰面：
///  * 不进焦点池、不接指针（[IgnorePointer]），点上去照常穿透给正文 / 顶边悬停热区；
///  * 不占预留高——2px 压在正文顶部留白上，正文位置与显隐无关；
///  * 颜色**只**从阅读器纸张主题取（[ReaderProgressLine.color] 传 `_themeTextColor()`），
///    不读全局 Material 色，否则「纸张暗 / app 亮」时会冒出一条与页面无关的亮色。
///    填充与轨道都是同一前景色的不同透明度，任何主题下都与文字同调。
///
/// 移动端不画：那里顶部进度是文字 pill（`_buildTopProgressBar`），桌面端 pill 已被
/// 底部状态行取代（reader_status_footer.dart），进度数字在右下角，顶部只剩这条线。
const double kReaderProgressLineHeight = 2;

/// 填充段的前景透明度（文字色之上）。
const double kReaderProgressLineFillAlpha = 0.55;

/// 轨道（未读段）的前景透明度。
const double kReaderProgressLineTrackAlpha = 0.10;

/// 整书已读比例；总字数未知 / 为 0 时返回 null（不画）。已夹到 `[0, 1]`。
double? readerProgressLineRatio({required int? current, required int? total}) {
  if (current == null || total == null || total <= 0) return null;
  return (current / total).clamp(0.0, 1.0);
}

/// 进度线是否绘制：桌面 chrome 启用、首屏已就绪、非歌词模式、用户没关「阅读进度
/// 指示」、且进度已知。与状态行右侧进度数字共用同一个开关（同一件事的两个呈现）。
bool readerProgressLineVisible({
  required bool desktopChromeEnabled,
  required bool hasEverLoaded,
  required bool lyricsMode,
  required bool showProgress,
  required double? ratio,
}) =>
    desktopChromeEnabled &&
    hasEverLoaded &&
    !lyricsMode &&
    showProgress &&
    ratio != null;

class ReaderProgressLine extends StatelessWidget {
  const ReaderProgressLine({
    super.key,
    required this.ratio,
    required this.color,
    this.height = kReaderProgressLineHeight,
  });

  /// 已读比例 `[0, 1]`。
  final double ratio;

  /// 阅读器纸张主题的前景色（文字色）；填充 / 轨道由它派生。
  final Color color;

  final double height;

  @override
  Widget build(BuildContext context) {
    final double clamped = ratio.clamp(0.0, 1.0);
    return IgnorePointer(
      child: SizedBox(
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: kReaderProgressLineTrackAlpha),
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FractionallySizedBox(
              widthFactor: clamped,
              heightFactor: 1,
              child: DecoratedBox(
                key: const ValueKey<String>('fushi_progress_line_fill'),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: kReaderProgressLineFillAlpha),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
