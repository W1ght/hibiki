import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/utils.dart';

/// 悬浮球展开后可放的按钮。顺序即 [values] 顺序（画面上从左到右固定按此排，
/// 用户只挑「放不放」，不排顺序——三键传输语义左退右进，乱序反而误触）。
enum AudiobookFloatingBallAction {
  seekBack('seek_back'),
  prev('prev'),
  playPause('play_pause'),
  next('next'),
  seekForward('seek_forward'),
  follow('follow'),
  settings('settings');

  const AudiobookFloatingBallAction(this.id);

  /// 持久化 id（偏好里逗号拼接）。
  final String id;

  /// 默认三键：上一句 / 播放暂停 / 下一句。
  static const List<AudiobookFloatingBallAction> defaults =
      <AudiobookFloatingBallAction>[prev, playPause, next];

  /// 把逗号拼接的偏好值解回动作列表：未知 id 丢弃、重复去重、顺序归一到
  /// [values] 顺序；解出来一个都没有（空串 / 全是旧 id）回默认三键，悬浮球
  /// 不会因为一条坏偏好变成空壳。
  static List<AudiobookFloatingBallAction> decode(String raw) {
    final Set<String> ids = raw
        .split(',')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toSet();
    final List<AudiobookFloatingBallAction> out = <AudiobookFloatingBallAction>[
      for (final AudiobookFloatingBallAction a in values)
        if (ids.contains(a.id)) a,
    ];
    return out.isEmpty ? defaults : out;
  }

  static String encode(Iterable<AudiobookFloatingBallAction> actions) {
    final Set<AudiobookFloatingBallAction> set = actions.toSet();
    return <String>[
      for (final AudiobookFloatingBallAction a in values)
        if (set.contains(a)) a.id,
    ].join(',');
  }
}

/// 悬浮球停靠的屏幕边。
enum AudiobookFloatingBallDock {
  left('left'),
  right('right');

  const AudiobookFloatingBallDock(this.id);
  final String id;

  static AudiobookFloatingBallDock decode(String raw) =>
      raw == left.id ? left : right;
}

/// 悬浮球几何：收起 / 展开 / 拖动三态下球与按钮条的落点（纯函数，测试直接钉）。
///
/// [viewport] 是阅读正文视口在页面 Stack 里的矩形（已扣掉顶栏 / 底栏 / 系统
/// inset），球永远在其内活动，不会压到 chrome。收起时球向停靠边**外**缩进
/// [tuck]，只露出约 2/3，降低对正文的遮挡；展开时整球回到视口内，按钮条从球
/// 向屏幕中央方向铺开。
class AudiobookFloatingBallLayout {
  const AudiobookFloatingBallLayout({
    required this.viewport,
    required this.dock,
    required this.verticalFraction,
    required this.actionCount,
    this.ballSize = kAudiobookFloatingBallSize,
    this.buttonSize = kAudiobookFloatingBallButtonSize,
    this.gap = kAudiobookFloatingBallGap,
    this.margin = kAudiobookFloatingBallMargin,
  });

  final Rect viewport;
  final AudiobookFloatingBallDock dock;

  /// 球心在视口高度上的比例 `[0, 1]`（持久化值；越界在这里夹住）。
  final double verticalFraction;
  final int actionCount;
  final double ballSize;
  final double buttonSize;
  final double gap;
  final double margin;

  /// 收起时缩进停靠边外的量。
  double get tuck => ballSize * 0.34;

  /// 按钮条总宽（含与球之间的一个 gap）。
  double get stripWidth =>
      actionCount == 0 ? 0 : actionCount * buttonSize + actionCount * gap;

  /// 球的可活动纵向范围（球顶边 top 值）。
  double get minTop => viewport.top + margin;
  double get maxTop => math.max(minTop, viewport.bottom - ballSize - margin);

  /// 球顶边 y（按比例落在活动范围内）。
  double get ballTop {
    final double f = verticalFraction.isFinite
        ? verticalFraction.clamp(0.0, 1.0).toDouble()
        : 0.5;
    return minTop + (maxTop - minTop) * f;
  }

  /// 把任意 top 值反算成持久化比例。
  double fractionForTop(double top) {
    final double span = maxTop - minTop;
    if (span <= 0) return 0.5;
    return ((top - minTop) / span).clamp(0.0, 1.0).toDouble();
  }

  /// 收起态球左边 x：停靠边外缩 [tuck]。
  double get collapsedBallLeft => dock == AudiobookFloatingBallDock.left
      ? viewport.left - tuck
      : viewport.right - ballSize + tuck;

  /// 展开态球左边 x：整球回到视口内、贴边留 [margin]。
  double get expandedBallLeft => dock == AudiobookFloatingBallDock.left
      ? viewport.left + margin
      : viewport.right - ballSize - margin;

  /// 展开进度 [t]∈[0,1] 下的球左边 x。
  double ballLeftAt(double t) =>
      collapsedBallLeft + (expandedBallLeft - collapsedBallLeft) * t;

  /// 整个悬浮层（球 + 按钮条）的包围盒左边 x：左停靠时从球开始向右铺，右停靠
  /// 时按钮条在球左侧。
  double boxLeftAt(double t) => dock == AudiobookFloatingBallDock.left
      ? ballLeftAt(t)
      : ballLeftAt(t) - stripWidth;

  double get boxWidth => ballSize + stripWidth;

  /// 球在包围盒内的 x 偏移。
  double get ballOffsetInBox =>
      dock == AudiobookFloatingBallDock.left ? 0 : stripWidth;

  /// 按钮条在包围盒内的 x 偏移。
  double get stripOffsetInBox =>
      dock == AudiobookFloatingBallDock.left ? ballSize + gap : 0;

  /// 松手时按球心落在视口左右哪一半决定停靠边。
  AudiobookFloatingBallDock dockForBallLeft(double ballLeft) =>
      ballLeft + ballSize / 2 < viewport.center.dx
      ? AudiobookFloatingBallDock.left
      : AudiobookFloatingBallDock.right;
}

const double kAudiobookFloatingBallSize = 44;
const double kAudiobookFloatingBallButtonSize = 40;
const double kAudiobookFloatingBallGap = 6;
const double kAudiobookFloatingBallMargin = 8;

/// 收起态整体不透明度：半透明、不抢正文。
const double kAudiobookFloatingBallIdleOpacity = 0.42;

/// 阅读器有声书悬浮球。
///
/// 收起：半透明小球停靠在视口左/右边缘（外缩约 1/3），只作为「有有声书控制」的
/// 存在提示，尽量不遮字。点一下：球点亮（primary 容器色）并平移回视口内，按钮
/// 从球向屏幕中央逐个弹出（错峰缩放 + 淡入 + 宽度展开）；再点球收起。拖球可
/// 沿边上下挪、也可拖到另一侧换边，松手吸附到最近边并经 [onDockChanged] 落库。
///
/// 返回的是 [Positioned]，**必须**作为页面 Stack 的直接子节点挂载（与底部 chrome
/// 同一约束）；包围盒只覆盖球 + 按钮条那一小块，自带 [RepaintBoundary]
/// （BUG-1692：整窗图层会让 macOS WebView 收不到鼠标事件）。透明区域不吃点击，
/// 正文照常可点。
///
/// 焦点：整层 [ExcludeFocus]——阅读正文是键盘 / 手柄焦点的唯一归宿（TODO-700
/// T8），悬浮球只服务触摸 / 鼠标；键盘用户有底栏与快捷键。
class AudiobookFloatingBall extends StatefulWidget {
  const AudiobookFloatingBall({
    required this.controller,
    required this.viewport,
    required this.actions,
    required this.dock,
    required this.verticalFraction,
    required this.onDockChanged,
    required this.onOpenSettings,
    this.skipActionSeconds = 0,
    this.backgroundColor,
    this.foregroundColor,
    this.animate = true,
    super.key,
  });

  final AudiobookPlayerController controller;

  /// 阅读正文视口在 Stack 坐标系里的矩形（扣掉 chrome / 系统 inset）。
  final Rect viewport;

  /// 展开后显示的按钮（已按 [AudiobookFloatingBallAction.values] 排序）。
  final List<AudiobookFloatingBallAction> actions;
  final AudiobookFloatingBallDock dock;
  final double verticalFraction;

  /// 拖动松手后回调最终停靠边与纵向比例，由页面落库。
  final void Function(AudiobookFloatingBallDock dock, double verticalFraction)
  onDockChanged;

  final VoidCallback onOpenSettings;

  /// 0 = 按句跳，N = 按 N 秒跳（与底栏 [AudiobookPlayBar.skipActionSeconds] 同源）。
  final int skipActionSeconds;

  /// 阅读器纸张主题背景 / 前景色；null 回退到 Material 主题。
  final Color? backgroundColor;
  final Color? foregroundColor;

  /// false（墨水屏模式）时所有过渡零时长。
  final bool animate;

  @override
  State<AudiobookFloatingBall> createState() => _AudiobookFloatingBallState();
}

class _AudiobookFloatingBallState extends State<AudiobookFloatingBall>
    with SingleTickerProviderStateMixin {
  static const Duration _expandDuration = Duration(milliseconds: 260);
  static const Duration _snapDuration = Duration(milliseconds: 220);

  late final AnimationController _expand = AnimationController(
    vsync: this,
    duration: widget.animate ? _expandDuration : Duration.zero,
    reverseDuration: widget.animate
        ? const Duration(milliseconds: 180)
        : Duration.zero,
  );

  late AudiobookFloatingBallDock _dock = widget.dock;
  late double _fraction = widget.verticalFraction;

  /// 拖动中：球左上角在 Stack 坐标系里的位置（null = 未在拖）。按手势 delta
  /// 累加，不做全局坐标换算。
  Offset? _dragBallTopLeft;

  bool get _expanded =>
      _expand.status == AnimationStatus.forward ||
      _expand.status == AnimationStatus.completed;

  @override
  void didUpdateWidget(AudiobookFloatingBall old) {
    super.didUpdateWidget(old);
    if (old.dock != widget.dock ||
        old.verticalFraction != widget.verticalFraction) {
      // 外部（换书 / 换 profile）重灌持久化值；拖动中不打断手势。
      if (_dragBallTopLeft == null) {
        _dock = widget.dock;
        _fraction = widget.verticalFraction;
      }
    }
    if (old.animate != widget.animate) {
      _expand.duration = widget.animate ? _expandDuration : Duration.zero;
      _expand.reverseDuration = widget.animate
          ? const Duration(milliseconds: 180)
          : Duration.zero;
    }
  }

  @override
  void dispose() {
    _expand.dispose();
    super.dispose();
  }

  AudiobookFloatingBallLayout _layout() => AudiobookFloatingBallLayout(
    viewport: widget.viewport,
    dock: _dock,
    verticalFraction: _fraction,
    actionCount: widget.actions.length,
  );

  void _toggle() {
    if (_expanded) {
      _expand.reverse();
    } else {
      _expand.forward();
    }
  }

  void _onPanStart(AudiobookFloatingBallLayout layout) {
    // 拖动一律先收起：按钮条跟着球飞没有意义，落点也不好算。
    if (_expanded) _expand.reverse();
    setState(() {
      _dragBallTopLeft = Offset(layout.ballLeftAt(0), layout.ballTop);
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final Offset? at = _dragBallTopLeft;
    if (at == null) return;
    setState(() => _dragBallTopLeft = at + d.delta);
  }

  void _onPanEnd(AudiobookFloatingBallLayout layout) {
    final Offset? at = _dragBallTopLeft;
    if (at == null) return;
    final AudiobookFloatingBallDock dock = layout.dockForBallLeft(at.dx);
    final double fraction = layout.fractionForTop(at.dy);
    setState(() {
      _dragBallTopLeft = null;
      _dock = dock;
      _fraction = fraction;
    });
    widget.onDockChanged(dock, fraction);
  }

  @override
  Widget build(BuildContext context) {
    final AudiobookFloatingBallLayout layout = _layout();
    return AnimatedBuilder(
      animation: _expand,
      builder: (BuildContext context, Widget? _) {
        final double t = _expand.value;
        final Offset? drag = _dragBallTopLeft;
        final bool dragging = drag != null;
        // 拖动中：包围盒跟着手指走、只画球；松手后：AnimatedPositioned 吸附到边。
        final double ballLeft = dragging ? drag.dx : layout.ballLeftAt(t);
        final double top = dragging
            ? drag.dy.clamp(layout.minTop, layout.maxTop).toDouble()
            : layout.ballTop;
        final double boxLeft = dragging
            ? ballLeft - layout.ballOffsetInBox
            : layout.boxLeftAt(t);
        return AnimatedPositioned(
          duration: dragging || !widget.animate ? Duration.zero : _snapDuration,
          curve: Curves.easeOutCubic,
          left: boxLeft,
          top: top,
          width: layout.boxWidth,
          height: layout.ballSize,
          child: RepaintBoundary(
            child: ExcludeFocus(
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  // 完全收起（t == 0）时按钮条整个不建：不留零宽命中区，也不
                  // 让收起态多画一排看不见的按钮。
                  if (!dragging && t > 0 && widget.actions.isNotEmpty)
                    Positioned(
                      left: layout.stripOffsetInBox,
                      top: (layout.ballSize - layout.buttonSize) / 2,
                      width: layout.stripWidth,
                      height: layout.buttonSize,
                      child: _buildStrip(layout),
                    ),
                  Positioned(
                    left: layout.ballOffsetInBox,
                    top: 0,
                    width: layout.ballSize,
                    height: layout.ballSize,
                    child: _buildBall(layout, progress: t, dragging: dragging),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBall(
    AudiobookFloatingBallLayout layout, {
    required double progress,
    required bool dragging,
  }) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color paperBg = widget.backgroundColor ?? colors.surface;
    final Color paperFg = widget.foregroundColor ?? colors.onSurface;
    // 收起：纸张底 + 前景描边（融进正文配色）；展开：primary 点亮。
    final Color fill = Color.lerp(paperBg, colors.primary, progress)!;
    final Color iconColor = Color.lerp(paperFg, colors.onPrimary, progress)!;
    final double opacity = dragging
        ? 1
        : kAudiobookFloatingBallIdleOpacity +
              (1 - kAudiobookFloatingBallIdleOpacity) * progress;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? _) {
        final bool playing = widget.controller.isPlaying;
        final IconData icon = progress >= 0.5
            ? Icons.close
            : playing
            ? Icons.graphic_eq
            : Icons.headphones_outlined;
        return Opacity(
          opacity: opacity,
          child: Semantics(
            button: true,
            label: _ballLabel(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggle,
              onPanStart: (_) => _onPanStart(layout),
              onPanUpdate: _onPanUpdate,
              onPanEnd: (_) => _onPanEnd(layout),
              onPanCancel: () => _onPanEnd(layout),
              child: Tooltip(
                message: _ballLabel(),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: fill,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: paperFg.withValues(alpha: 0.35 * (1 - progress)),
                    ),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: 0.18 * progress + 0.06,
                        ),
                        blurRadius: 6 + 6 * progress,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: widget.animate
                          ? const Duration(milliseconds: 160)
                          : Duration.zero,
                      child: Icon(
                        icon,
                        key: ValueKey<IconData>(icon),
                        size: 22,
                        color: iconColor,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _ballLabel() => t.audiobook_floating_ball;

  Widget _buildStrip(AudiobookFloatingBallLayout layout) {
    final int n = widget.actions.length;
    final bool fromLeft = _dock == AudiobookFloatingBallDock.left;
    // 按钮画面顺序固定为 values 顺序；错峰以「离球最近的先出」计：左停靠时第 i
    // 个离球第 i 近，右停靠时倒过来。
    return Align(
      alignment: fromLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < n; i++)
            _buildButton(
              widget.actions[i],
              stagger: fromLeft ? i : n - 1 - i,
              total: n,
              size: layout.buttonSize,
              gap: layout.gap,
              leadingGap: fromLeft,
            ),
        ],
      ),
    );
  }

  Widget _buildButton(
    AudiobookFloatingBallAction action, {
    required int stagger,
    required int total,
    required double size,
    required double gap,
    required bool leadingGap,
  }) {
    // 每个按钮占总时长里一段错开的区间：起点按序推后，尾部对齐，最后一个也有
    // 足够时长完成弹出；反向（收起）用同一区间自然反放。
    final double step = total <= 1 ? 0 : 0.35 / (total - 1);
    final double begin = stagger * step;
    final CurvedAnimation reveal = CurvedAnimation(
      parent: _expand,
      curve: Interval(
        begin,
        math.min(1, begin + 0.65),
        curve: Curves.easeOutBack,
      ),
      reverseCurve: Interval(
        begin,
        math.min(1, begin + 0.65),
        curve: Curves.easeIn,
      ),
    );
    final CurvedAnimation width = CurvedAnimation(
      parent: _expand,
      curve: Interval(
        begin,
        math.min(1, begin + 0.65),
        curve: Curves.easeOutCubic,
      ),
    );
    final Widget button = _ActionButton(
      action: action,
      controller: widget.controller,
      skipActionSeconds: widget.skipActionSeconds,
      size: size,
      backgroundColor: widget.backgroundColor,
      foregroundColor: widget.foregroundColor,
      onOpenSettings: widget.onOpenSettings,
    );
    return SizeTransition(
      axis: Axis.horizontal,
      sizeFactor: width,
      axisAlignment: leadingGap ? -1 : 1,
      child: FadeTransition(
        opacity: reveal.drive(Tween<double>(begin: 0, end: 1)),
        child: ScaleTransition(
          scale: reveal.drive(Tween<double>(begin: 0.4, end: 1)),
          child: Padding(
            padding: EdgeInsets.only(
              left: leadingGap ? gap : 0,
              right: leadingGap ? 0 : gap,
            ),
            child: SizedBox(width: size, height: size, child: button),
          ),
        ),
      ),
    );
  }
}

/// 展开条上的一个圆形按钮：纸张底色 + 前景图标 + 轻阴影，语义与底栏同名键一致。
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.action,
    required this.controller,
    required this.skipActionSeconds,
    required this.size,
    required this.onOpenSettings,
    this.backgroundColor,
    this.foregroundColor,
  });

  final AudiobookFloatingBallAction action;
  final AudiobookPlayerController controller;
  final int skipActionSeconds;
  final double size;
  final VoidCallback onOpenSettings;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color fg = foregroundColor ?? colors.onSurface;
    // 纸张底色上再调 6% 前景色：与正文底色拉开一层，不只靠阴影区分。
    final Color bg = Color.alphaBlend(
      fg.withValues(alpha: 0.06),
      backgroundColor ?? colors.surface,
    );
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        controller,
        controller.followAudio,
      ]),
      builder: (BuildContext context, Widget? _) {
        final ({IconData icon, String tooltip, VoidCallback onPressed}) spec =
            _spec();
        return Material(
          color: bg,
          shape: const CircleBorder(),
          elevation: 2,
          shadowColor: Colors.black.withValues(alpha: 0.4),
          clipBehavior: Clip.antiAlias,
          child: Tooltip(
            message: spec.tooltip,
            child: InkWell(
              onTap: spec.onPressed,
              child: SizedBox(
                width: size,
                height: size,
                child: Icon(spec.icon, size: 22, color: fg),
              ),
            ),
          ),
        );
      },
    );
  }

  ({IconData icon, String tooltip, VoidCallback onPressed}) _spec() {
    switch (action) {
      case AudiobookFloatingBallAction.seekBack:
        return (
          icon: Icons.replay_10_outlined,
          tooltip: '-10s',
          onPressed: () => controller.seekRelative(-10),
        );
      case AudiobookFloatingBallAction.seekForward:
        return (
          icon: Icons.forward_10_outlined,
          tooltip: '+10s',
          onPressed: () => controller.seekRelative(10),
        );
      // 上一句 / 下一句跟随「跳转方式」偏好：按句跳 or 按 N 秒跳，与底栏
      // [AudiobookPlayBar] 的 backwardKey / forwardKey 同一语义。
      case AudiobookFloatingBallAction.prev:
        return (
          icon: skipActionSeconds == 0
              ? Icons.skip_previous_outlined
              : Icons.fast_rewind_outlined,
          tooltip: skipActionSeconds == 0
              ? t.prev_sentence
              : '-${skipActionSeconds}s',
          onPressed: () => skipActionSeconds == 0
              ? controller.skipToPrevCue()
              : controller.seekRelative(-skipActionSeconds),
        );
      case AudiobookFloatingBallAction.next:
        return (
          icon: skipActionSeconds == 0
              ? Icons.skip_next_outlined
              : Icons.fast_forward_outlined,
          tooltip: skipActionSeconds == 0
              ? t.next_sentence
              : '+${skipActionSeconds}s',
          onPressed: () => skipActionSeconds == 0
              ? controller.skipToNextCue()
              : controller.seekRelative(skipActionSeconds),
        );
      case AudiobookFloatingBallAction.playPause:
        final bool playing = controller.isPlaying;
        return (
          icon: playing ? Icons.pause_outlined : Icons.play_arrow_outlined,
          tooltip: playing ? t.pause : t.play,
          onPressed: controller.togglePlayPause,
        );
      case AudiobookFloatingBallAction.follow:
        final bool on = controller.followAudio.value;
        return (
          icon: on ? Icons.link : Icons.link_off,
          tooltip: on ? t.follow_audio_on_tooltip : t.follow_audio_off_tooltip,
          onPressed: () => controller.setFollowAudio(!on),
        );
      case AudiobookFloatingBallAction.settings:
        return (
          icon: Icons.tune_outlined,
          tooltip: t.settings,
          onPressed: onOpenSettings,
        );
    }
  }
}

/// 设置面板里给每个动作用的静态标签（chip 文案），与按钮 tooltip 同源。
String audiobookFloatingBallActionLabel(
  AudiobookFloatingBallAction action, {
  required int skipActionSeconds,
}) {
  switch (action) {
    case AudiobookFloatingBallAction.seekBack:
      return '-10s';
    case AudiobookFloatingBallAction.seekForward:
      return '+10s';
    case AudiobookFloatingBallAction.prev:
      return skipActionSeconds == 0
          ? t.prev_sentence
          : '-${skipActionSeconds}s';
    case AudiobookFloatingBallAction.next:
      return skipActionSeconds == 0
          ? t.next_sentence
          : '+${skipActionSeconds}s';
    case AudiobookFloatingBallAction.playPause:
      return '${t.play} / ${t.pause}';
    case AudiobookFloatingBallAction.follow:
      return t.audiobook_follow_audio;
    case AudiobookFloatingBallAction.settings:
      return t.settings;
  }
}

/// 设置面板 chip 用的图标。
IconData audiobookFloatingBallActionIcon(AudiobookFloatingBallAction action) {
  switch (action) {
    case AudiobookFloatingBallAction.seekBack:
      return Icons.replay_10_outlined;
    case AudiobookFloatingBallAction.seekForward:
      return Icons.forward_10_outlined;
    case AudiobookFloatingBallAction.prev:
      return Icons.skip_previous_outlined;
    case AudiobookFloatingBallAction.next:
      return Icons.skip_next_outlined;
    case AudiobookFloatingBallAction.playPause:
      return Icons.play_arrow_outlined;
    case AudiobookFloatingBallAction.follow:
      return Icons.link;
    case AudiobookFloatingBallAction.settings:
      return Icons.tune_outlined;
  }
}
