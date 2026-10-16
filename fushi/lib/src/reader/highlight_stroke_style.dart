/// 阅读器高亮条的笔触样式（用户 2026-10-15：「高亮条自定义做成配置，用户自己可自选样式，
/// 并且支持可视化调节」「全部高亮都要能选可以自定义高亮」）。
///
/// 四类高亮——收藏句、查词选中、有声书当前句、搜索命中——各有一套独立配置。经典样式就是
/// 阅读器一直以来的 1em 窄条（收藏另有下划线）；其余六种由窄条层 `__fushiLanes`
/// （reader_selection_scripts.dart）把该组改画成 SVG 笔触。配置经正文 CSS 的 `:root`
/// 变量（[highlightStrokeCssVariables]）传给 JS——改设置走现有的正文样式热替换，不需要
/// 额外的桥调用。
///
/// 这一份是纯 Dart（无 Flutter 依赖）：正文 CSS 生成器、偏好读写与设置页预览共用。
library;

/// 高亮条的笔触样式。[wireName] 同时是偏好值与 CSS 变量 `--fushi-mark-<种类>-style`
/// 的值，与 JS 的 `MARK_STYLES` 逐字对应（测试钉住）。
enum HighlightStrokeStyle {
  /// 1em 窄条（历史行为；收藏另有下划线）。
  classic('classic'),

  /// 斜切马克笔：两端平行斜切，收笔端微毛、略积墨。
  marker('marker'),

  /// 水性荧光笔：毛边、起收笔积墨、中段拖痕。
  fluo('fluo'),

  /// 手绘双笔：两道略带弧度的粗笔叠画。
  rough('rough'),

  /// 半截荧光：只涂字的下半截，永远不挡振假名。
  under('under'),

  /// 彩铅涂抹：颗粒感、边缘不规则。
  crayon('crayon'),

  /// 和纸胶带：两端撕口、略歪、细斜纹。
  tape('tape');

  const HighlightStrokeStyle(this.wireName);

  final String wireName;

  /// 偏好值 → 样式；未知值（旧数据 / 手改）回落经典。
  static HighlightStrokeStyle fromWire(String? value) {
    for (final HighlightStrokeStyle style in values) {
      if (style.wireName == value) return style;
    }
    return HighlightStrokeStyle.classic;
  }

  /// 「盖住振假名」对这个样式有没有意义（经典恒 1em、半截只涂下半截）。
  bool get supportsCoverRuby =>
      this != HighlightStrokeStyle.classic &&
      this != HighlightStrokeStyle.under;

  /// 粗细 / 抖动对这个样式有没有意义（经典恒 1em 窄条）。
  bool get isStroke => this != HighlightStrokeStyle.classic;
}

/// 阅读器里的四类高亮。每类一套独立的 [HighlightStrokeConfig]。
enum HighlightKind {
  /// 收藏句（五色）：新收藏时可放一次落笔动画。
  favorite('favorite', 'favorite_highlight', supportsAnimation: true),

  /// 查词选中（含拖选）。拖选时每帧都在重画，不提供动画。
  lookup('lookup', 'lookup_highlight'),

  /// 有声书当前句：可选「读到哪句就画出哪句」。
  audio('audio', 'audio_highlight', supportsAnimation: true),

  /// 搜索命中。
  search('search', 'search_highlight');

  const HighlightKind(
    this.cssName,
    this.prefPrefix, {
    this.supportsAnimation = false,
  });

  /// CSS 变量里的种类名（`--fushi-mark-<cssName>-*`），与 JS 的 `KIND_OF` 对应。
  final String cssName;

  /// 偏好键前缀（`<prefPrefix>_style` 等）。存量的 `audio_highlight_color` /
  /// `_background` / `_text_color` 与这里的 `_style` / `_thickness` … 不重名。
  final String prefPrefix;

  /// 这类高亮有没有落笔动画开关。
  final bool supportsAnimation;

  /// 这类高亮的默认配置：都从经典开始（不改变任何人的现状）；收藏的落笔动画默认开，
  /// 有声书默认关（每句都扫一遍会分散注意力，要用户自己打开）。
  HighlightStrokeConfig get defaults =>
      HighlightStrokeConfig(animate: this == HighlightKind.favorite);
}

/// 一类高亮的完整笔触配置。各数值的取值范围见 `kHighlightStroke*` 常量。
class HighlightStrokeConfig {
  const HighlightStrokeConfig({
    this.style = HighlightStrokeStyle.classic,
    this.thickness = kHighlightStrokeThicknessDefault,
    this.opacity = kHighlightStrokeOpacityDefault,
    this.coverRuby = false,
    this.roughness = kHighlightStrokeRoughnessDefault,
    this.animate = false,
  });

  final HighlightStrokeStyle style;

  /// 笔划粗细：乘在该样式自然粗细（[kHighlightStrokeNaturalEm]）上的倍数。
  final double thickness;

  /// 颜色浓度（0–1 的不透明度）。颜色本身仍由各类高亮原有的颜色设置决定。
  final double opacity;

  /// 笔划往振假名一侧加厚、盖住注音（振假名字本身仍压在笔划上面）。
  final bool coverRuby;

  /// 笔触抖动：0 = 规整，1 = 最潦草。
  final double roughness;

  /// 落笔动画（只对 [HighlightKind.supportsAnimation] 的种类生效）。
  final bool animate;

  HighlightStrokeConfig copyWith({
    HighlightStrokeStyle? style,
    double? thickness,
    double? opacity,
    bool? coverRuby,
    double? roughness,
    bool? animate,
  }) => HighlightStrokeConfig(
    style: style ?? this.style,
    thickness: thickness ?? this.thickness,
    opacity: opacity ?? this.opacity,
    coverRuby: coverRuby ?? this.coverRuby,
    roughness: roughness ?? this.roughness,
    animate: animate ?? this.animate,
  );

  @override
  bool operator ==(Object other) =>
      other is HighlightStrokeConfig &&
      other.style == style &&
      other.thickness == thickness &&
      other.opacity == opacity &&
      other.coverRuby == coverRuby &&
      other.roughness == roughness &&
      other.animate == animate;

  @override
  int get hashCode =>
      Object.hash(style, thickness, opacity, coverRuby, roughness, animate);
}

/// 各笔触的自然粗细（em，粗细倍数 1.0 时的笔划厚度）。经典窄条守「一个字高」；笔触样式以
/// 好看为先，允许超过字高、擦到甚至盖到振假名（用户 2026-10-16 拍板），默认取几乎填满行距
/// 的粗细。与窄条层 JS 的 `MARK_NATURAL_EM` 逐项相同（测试钉住）。半截荧光只涂字的下半截，
/// 不在表里。
const Map<HighlightStrokeStyle, double> kHighlightStrokeNaturalEm =
    <HighlightStrokeStyle, double>{
      HighlightStrokeStyle.marker: 1.35,
      HighlightStrokeStyle.fluo: 1.3,
      HighlightStrokeStyle.rough: 1.25,
      HighlightStrokeStyle.crayon: 1.38,
      HighlightStrokeStyle.tape: 1.45,
    };

/// 粗细倍数（乘在 [kHighlightStrokeNaturalEm] 上）。
const double kHighlightStrokeThicknessMin = 0.5;
const double kHighlightStrokeThicknessMax = 1.8;
const double kHighlightStrokeThicknessDefault = 1.0;

const double kHighlightStrokeOpacityMin = 0.15;
const double kHighlightStrokeOpacityMax = 0.8;
const double kHighlightStrokeOpacityDefault = 0.35;

const double kHighlightStrokeRoughnessMin = 0;
const double kHighlightStrokeRoughnessMax = 1;
const double kHighlightStrokeRoughnessDefault = 0.5;

/// 正文 CSS `:root` 里的笔触变量（窄条层 `markConfigs()` 读同名变量）。
///
/// - 墨水屏强制经典：墨水屏把所有高亮改成线式标记、窄条层整层隐藏。
/// - [darkBackground] 与 [paperColor] 给 JS 画荧光笔拖痕 / 胶带斜纹 / 彩铅颗粒用的「纸色」。
String highlightStrokeCssVariables(
  Map<HighlightKind, HighlightStrokeConfig> configs, {
  required bool einkMode,
  required bool darkBackground,
  required String paperColor,
}) {
  final StringBuffer out = StringBuffer();
  for (final HighlightKind kind in HighlightKind.values) {
    final HighlightStrokeConfig c = configs[kind] ?? kind.defaults;
    final HighlightStrokeStyle style = einkMode
        ? HighlightStrokeStyle.classic
        : c.style;
    final String p = '  --fushi-mark-${kind.cssName}';
    out
      ..write('$p-style: ${style.wireName};\n')
      ..write(
        '$p-thickness: ${_n(c.thickness.clamp(kHighlightStrokeThicknessMin, kHighlightStrokeThicknessMax))};\n',
      )
      ..write(
        '$p-opacity: ${_n(c.opacity.clamp(kHighlightStrokeOpacityMin, kHighlightStrokeOpacityMax))};\n',
      )
      ..write(
        '$p-cover-ruby: ${c.coverRuby && style.supportsCoverRuby ? 1 : 0};\n',
      )
      ..write(
        '$p-roughness: ${_n(c.roughness.clamp(kHighlightStrokeRoughnessMin, kHighlightStrokeRoughnessMax))};\n',
      )
      ..write('$p-animate: ${c.animate && kind.supportsAnimation ? 1 : 0};\n');
  }
  out
    ..write('  --fushi-mark-dark: ${darkBackground ? 1 : 0};\n')
    ..write('  --fushi-mark-paper: $paperColor;\n');
  return out.toString();
}

/// 收藏选了笔触样式时不再画下划线：形状本身就是标记，下划线叠上去像两道。旧 WebView 的
/// 包裹 span 把下划线写在内联样式上，所以这里要 `!important`。经典样式返回空串。
/// （其余三类高亮本来就没有下划线。）
String favoriteHighlightUnderlineOverrideCss(
  HighlightStrokeConfig favorite, {
  required bool einkMode,
}) {
  if (einkMode || !favorite.style.isStroke) return '';
  const List<String> colors = <String>[
    'yellow',
    'green',
    'blue',
    'pink',
    'purple',
  ];
  final String selectors = colors
      .map(
        (String c) =>
            '::highlight(fushi-hl-$c), .fushi-hl-$c, ruby.fushi-hl-$c-ruby-active',
      )
      .join(',\n');
  return '/* 收藏笔触样式：形状本身就是标记，不再叠下划线。 */\n'
      '$selectors {\n'
      '  text-decoration-line: none !important;\n'
      '}\n';
}

String _n(double v) {
  final String fixed = v.toStringAsFixed(3);
  return fixed.contains('.')
      ? fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
      : fixed;
}
