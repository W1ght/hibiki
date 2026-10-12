import 'dart:math' as math;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart'
    show lyricsPlayerIsWide;
import 'package:fushi/src/media/video/video_remote_control_layout.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show rethemeFushiWithScheme;
import 'package:fushi/src/pages/implementations/video_remote/video_remote_control_card.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_favorites_view.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_models.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_transcript_view.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isGlassDesign;
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart'
    show FushiConnectedButtonGroup;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 遥控器页面上的全部操作（纯回调；页面负责网络与确认对话框）。
@immutable
class VideoRemoteCallbacks {
  const VideoRemoteCallbacks({
    required this.onBack,
    required this.onControl,
    required this.onLookup,
    required this.onFavoritesScopeChanged,
    required this.onOpenFavorite,
    required this.onRemoveFavorites,
    required this.onRefresh,
    this.onSeek,
    this.onLineTap,
    this.onReplayLine,
    this.onToggleFavoriteLine,
    this.onMineLine,
    this.onLookupFavorite,
    this.onCustomizeControls,
  });

  /// 返回（退出遥控）。
  final VoidCallback onBack;

  /// 控制按钮。`followCurrent` 由脚手架自己处理（回到当前句），不会转发。
  final ValueChanged<VideoRemoteControlItem> onControl;

  /// 字幕里点字查词：行下标 + 字下标（grapheme）。
  final VideoRemoteLookupCallback onLookup;

  final ValueChanged<VideoRemoteFavoritesScope> onFavoritesScopeChanged;
  final ValueChanged<VideoRemoteFavoriteEntry> onOpenFavorite;
  final ValueChanged<Set<String>> onRemoveFavorites;

  /// ⋯ 菜单里的「刷新」。
  final VoidCallback onRefresh;

  /// 拖动进度条跳转；null = 进度只显示。
  final ValueChanged<Duration>? onSeek;

  /// 点字幕行内文字以外的地方（通常 = 跳到这句）。
  final ValueChanged<int>? onLineTap;

  /// 长按字幕行面板里的动作；null 的动作不显示。
  final ValueChanged<int>? onReplayLine;
  final ValueChanged<int>? onToggleFavoriteLine;
  final ValueChanged<int>? onMineLine;

  /// 收藏卡里点字查词；null = 收藏句子不逐字可点。
  final VideoRemoteFavoriteLookupCallback? onLookupFavorite;

  /// ⋯ 菜单里的「自定义按钮」（通常 `showVideoRemoteControlEditor`）；null =
  /// 不显示该项。
  final VoidCallback? onCustomizeControls;
}

/// 手机字幕遥控器的整页脚手架（纯展示）。
///
/// 布局按 [lyricsPlayerIsWide]（宽 ≥600 且横向）切换：
///  * 竖屏：浮动顶栏（返回 / 作品名·集数 / [字幕|收藏] / ⋯ 自定义按钮·刷新，
///    `adaptiveOverflow` 宽度不够才收进 ⋯）+ 中间列表 + 底部浮动控制卡；
///  * 横屏 / 平板：左栏信息 + 控制卡，右栏顶栏 + [字幕|收藏] 列表。
/// 背景是封面取色的 mesh（Apple 设计系统用平底）。
///
/// 状态归属：
///  * 当前页签由本组件持有（初值 [initialTab]，变化回调 [onTabChanged]）；
///  * 字幕列表与收藏列表的滚动位置、搜索词、多选挂在本组件持有的 GlobalKey 上，
///    竖横屏切换时子树整体搬家，状态不丢；
///  * 跟随状态在 [transcriptController]（不传则本组件自建一个）。
/// 只要调用方在旋转时不换掉本组件（同一个 State），以上状态都保留。
class VideoRemoteScaffold extends StatefulWidget {
  const VideoRemoteScaffold({
    super.key,
    required this.nowPlaying,
    required this.lines,
    required this.activeIndex,
    required this.favorites,
    required this.favoritesScope,
    required this.controlLayout,
    required this.callbacks,
    this.clock,
    this.notice,
    this.favoritesLoading = false,
    this.initialTab = VideoRemoteTab.transcript,
    this.onTabChanged,
    this.transcriptController,
    this.isControlEnabled,
    this.transcriptReplayKey,
    this.lineTextStyle,
    this.animateBackdrop = false,
  });

  final VideoRemoteNowPlaying nowPlaying;
  final List<VideoRemoteTranscriptLine> lines;
  final int activeIndex;
  final List<VideoRemoteFavoriteEntry> favorites;
  final VideoRemoteFavoritesScope favoritesScope;
  final VideoRemoteControlLayout controlLayout;
  final VideoRemoteCallbacks callbacks;

  /// 进度读口；null = 不显示进度条。
  final FushiPlaybackClock? clock;

  /// 内联状态卡（等待 / 出错 / 断线）；null = 不显示。
  final VideoRemoteNotice? notice;

  final bool favoritesLoading;
  final VideoRemoteTab initialTab;
  final ValueChanged<VideoRemoteTab>? onTabChanged;
  final VideoRemoteTranscriptController? transcriptController;
  final bool Function(VideoRemoteControlItem item)? isControlEnabled;

  /// 变化时字幕列表重开错峰进场（换视频 / 换字幕版本）。
  final Object? transcriptReplayKey;

  /// 字幕正文基准样式；null = 主题 titleLarge。
  final TextStyle? lineTextStyle;

  /// 背景 mesh 是否流动。默认静止：遥控页常亮、长时间开着，背景逐帧重画是
  /// 白白耗电发热（spec「没有动态背景」）。
  final bool animateBackdrop;

  @override
  State<VideoRemoteScaffold> createState() => _VideoRemoteScaffoldState();
}

class _VideoRemoteScaffoldState extends State<VideoRemoteScaffold> {
  final GlobalKey _transcriptKey = GlobalKey(
    debugLabel: 'video-remote-transcript',
  );
  final GlobalKey _favoritesKey = GlobalKey(
    debugLabel: 'video-remote-favorites',
  );
  late VideoRemoteTab _tab = widget.initialTab;
  VideoRemoteTranscriptController? _ownController;
  VideoRemoteNotice? _lastNotice;

  ImageProvider? _schemeSource;
  Brightness? _schemeBrightness;
  int _schemeRequest = 0;
  ColorScheme? _coverScheme;
  ThemeData? _themedBase;
  ColorScheme? _themedScheme;
  ThemeData? _themed;

  VideoRemoteTranscriptController get _controller =>
      widget.transcriptController ??
      (_ownController ??= VideoRemoteTranscriptController());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveCoverScheme();
  }

  @override
  void didUpdateWidget(covariant VideoRemoteScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nowPlaying.cover != widget.nowPlaying.cover) {
      _resolveCoverScheme();
    }
  }

  @override
  void dispose() {
    _ownController?.dispose();
    super.dispose();
  }

  /// 封面取色（MD3）：异步取到前先用应用主题。与歌词模式同一做法。
  void _resolveCoverScheme() {
    if (isGlassDesign(context)) return;
    final ImageProvider? cover = widget.nowPlaying.cover;
    final Brightness brightness = Theme.of(context).brightness;
    if (cover == _schemeSource && brightness == _schemeBrightness) return;
    _schemeSource = cover;
    _schemeBrightness = brightness;
    final int request = ++_schemeRequest;
    if (cover == null) {
      if (_coverScheme != null) setState(() => _coverScheme = null);
      return;
    }
    ColorScheme.fromImageProvider(provider: cover, brightness: brightness)
        .then((ColorScheme scheme) {
          if (!mounted || request != _schemeRequest) return;
          setState(() => _coverScheme = scheme);
        })
        .catchError((Object _) {
          // 封面解码失败：保留应用主题配色，不是错误。
        });
  }

  ThemeData _themeFor(ThemeData base) {
    final ColorScheme? scheme = _coverScheme;
    if (scheme == null || isGlassDesign(context)) return base;
    final ThemeData? cached = _themed;
    if (cached != null &&
        identical(base, _themedBase) &&
        identical(scheme, _themedScheme)) {
      return cached;
    }
    _themedBase = base;
    _themedScheme = scheme;
    return _themed = rethemeFushiWithScheme(base, scheme);
  }

  void _setTab(VideoRemoteTab tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    widget.onTabChanged?.call(tab);
  }

  void _onControl(VideoRemoteControlItem item) {
    if (item == VideoRemoteControlItem.followCurrent) {
      _setTab(VideoRemoteTab.transcript);
      _controller.returnToCurrent();
      return;
    }
    widget.callbacks.onControl(item);
  }

  // -------------------------------------------------------------------------
  // 组件
  // -------------------------------------------------------------------------

  Widget _topBar({required bool withTitle}) {
    final VideoRemoteCallbacks callbacks = widget.callbacks;
    final VoidCallback? customize = callbacks.onCustomizeControls;
    return FushiFloatingTopBar(
      key: const ValueKey<String>('video-remote-top-bar'),
      leading: <FushiToolbarItem>[
        FushiToolbarItem(
          key: const ValueKey<String>('video-remote-back'),
          icon: FushiIcons.back,
          label: t.back,
          onPressed: callbacks.onBack,
        ),
      ],
      title: withTitle
          ? (widget.nowPlaying.titleWithEpisode.isEmpty
                ? t.video_remote_title
                : widget.nowPlaying.titleWithEpisode)
          : '',
      subtitle: withTitle ? (widget.nowPlaying.hostName ?? '') : '',
      // 竖屏有标题胶囊（保底 160 宽），手机宽度放不下两个页签键，会被收进
      // ⋯——页签改由顶栏下方的连接式按钮组承担（[_tabSwitch]）；横屏顶栏没有
      // 标题，页签就在顶栏里。
      actions: withTitle
          ? const <List<FushiToolbarItem>>[]
          : <List<FushiToolbarItem>>[
              <FushiToolbarItem>[
                FushiToolbarItem(
                  key: const ValueKey<String>('video-remote-tab-transcript'),
                  icon: FushiIcons.subtitles,
                  label: t.video_remote_subtitles,
                  selected: _tab == VideoRemoteTab.transcript,
                  onPressed: () => _setTab(VideoRemoteTab.transcript),
                ),
                FushiToolbarItem(
                  key: const ValueKey<String>('video-remote-tab-favorites'),
                  icon: FushiIcons.star,
                  label: t.video_remote_favorites,
                  selected: _tab == VideoRemoteTab.favorites,
                  onPressed: () => _setTab(VideoRemoteTab.favorites),
                ),
              ],
            ],
      overflow: <FushiToolbarItem>[
        if (customize != null)
          FushiToolbarItem(
            key: const ValueKey<String>('video-remote-customize'),
            icon: FushiIcons.dashboardCustomize,
            label: t.video_remote_control_customize,
            onPressed: customize,
          ),
        FushiToolbarItem(
          key: const ValueKey<String>('video-remote-refresh'),
          icon: FushiIcons.refresh,
          label: t.refresh,
          onPressed: callbacks.onRefresh,
        ),
      ],
    );
  }

  /// 竖屏页签：[字幕|收藏] 连接式按钮组（选中段弹成胶囊）。
  Widget _tabSwitch() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: FushiConnectedButtonGroup<VideoRemoteTab>(
      key: const ValueKey<String>('video-remote-tab-switch'),
      expandedInsets: EdgeInsets.zero,
      selected: <VideoRemoteTab>{_tab},
      onSelectionChanged: (Set<VideoRemoteTab> next) {
        if (next.isNotEmpty) _setTab(next.first);
      },
      segments: <ButtonSegment<VideoRemoteTab>>[
        ButtonSegment<VideoRemoteTab>(
          value: VideoRemoteTab.transcript,
          icon: const FushiIcon(FushiIcons.subtitles),
          label: Text(t.video_remote_subtitles),
        ),
        ButtonSegment<VideoRemoteTab>(
          value: VideoRemoteTab.favorites,
          icon: const FushiIcon(FushiIcons.star),
          label: Text(t.video_remote_favorites),
        ),
      ],
    ),
  );

  Widget _transcript() => VideoRemoteTranscriptView(
    key: _transcriptKey,
    lines: widget.lines,
    activeIndex: widget.activeIndex,
    controller: _controller,
    onLookup: widget.callbacks.onLookup,
    onLineTap: widget.callbacks.onLineTap,
    onReplayLine: widget.callbacks.onReplayLine,
    onToggleFavoriteLine: widget.callbacks.onToggleFavoriteLine,
    onMineLine: widget.callbacks.onMineLine,
    textStyle: widget.lineTextStyle,
    entranceReplayKey: widget.transcriptReplayKey,
  );

  Widget _favorites() => VideoRemoteFavoritesView(
    key: _favoritesKey,
    entries: widget.favorites,
    scope: widget.favoritesScope,
    onScopeChanged: widget.callbacks.onFavoritesScopeChanged,
    onOpen: widget.callbacks.onOpenFavorite,
    onRemove: widget.callbacks.onRemoveFavorites,
    onLookup: widget.callbacks.onLookupFavorite,
    loading: widget.favoritesLoading,
  );

  /// 两个页签叠放、都保活：切换走水平共享轴（淡入 + 从所在一侧滑入），隐藏的
  /// 那页不画、不吃指针、不进语义树，但滚动位置与搜索词都在。
  Widget _tabBody() {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        FushiChromeReveal(
          visible: _tab == VideoRemoteTab.transcript,
          from: AxisDirection.left,
          distance: 32,
          child: _transcript(),
        ),
        FushiChromeReveal(
          visible: _tab == VideoRemoteTab.favorites,
          from: AxisDirection.right,
          distance: 32,
          child: _favorites(),
        ),
      ],
    );
  }

  Widget _noticeCard() {
    final VideoRemoteNotice? notice = widget.notice ?? _lastNotice;
    if (widget.notice != null) _lastNotice = widget.notice;
    return FushiChromeReveal(
      visible: widget.notice != null,
      from: AxisDirection.up,
      child: notice == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: FushiInlineNotice(
                key: const ValueKey<String>('video-remote-notice'),
                message: notice.message,
                severity: switch (notice.kind) {
                  VideoRemoteNoticeKind.waiting => FushiNoticeSeverity.info,
                  VideoRemoteNoticeKind.error => FushiNoticeSeverity.error,
                  VideoRemoteNoticeKind.disconnected =>
                    FushiNoticeSeverity.warning,
                },
                icon: switch (notice.kind) {
                  VideoRemoteNoticeKind.waiting => FushiIcons.pending,
                  VideoRemoteNoticeKind.error => FushiIcons.error,
                  VideoRemoteNoticeKind.disconnected => FushiIcons.cloudOff,
                },
                actions: <Widget>[
                  if (notice.actionLabel != null && notice.onAction != null)
                    FushiTextButton(
                      onPressed: notice.onAction,
                      child: Text(notice.actionLabel!),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _controlCard(VideoRemoteControlCardVariant variant) =>
      ListenableBuilder(
        listenable: _controller,
        builder: (BuildContext context, Widget? _) => VideoRemoteControlCard(
          key: const ValueKey<String>('video-remote-control-card'),
          variant: variant,
          layout: widget.controlLayout,
          nowPlaying: widget.nowPlaying,
          clock: widget.clock,
          onSeek: widget.callbacks.onSeek,
          following: _controller.following,
          isEnabled: widget.isControlEnabled,
          onControl: _onControl,
        ),
      );

  // -------------------------------------------------------------------------
  // 布局
  // -------------------------------------------------------------------------

  Widget _portrait(EdgeInsets safe) {
    return Padding(
      padding: EdgeInsets.only(
        top: safe.top + 8,
        bottom: safe.bottom + 12,
        left: safe.left,
        right: safe.right,
      ),
      child: Column(
        key: const ValueKey<String>('video-remote-portrait'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiStaggeredEntrance(
            index: 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _topBar(withTitle: true),
            ),
          ),
          FushiStaggeredEntrance(index: 1, child: _tabSwitch()),
          _noticeCard(),
          Expanded(child: FushiStaggeredEntrance(index: 1, child: _tabBody())),
          FushiStaggeredEntrance(
            index: 3,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: _controlCard(VideoRemoteControlCardVariant.floating),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wide(Size size, EdgeInsets safe) {
    final double hPad = (size.width * 0.03).clamp(16.0, 40.0);
    final double content = math.max(1, size.width - safe.horizontal - 2 * hPad);
    final double panel = (content * 0.36).clamp(
      math.min(300.0, content * 0.5),
      math.min(440.0, content * 0.5),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        safe.left + hPad,
        safe.top + 16,
        safe.right + hPad,
        safe.bottom + 16,
      ),
      child: Row(
        key: const ValueKey<String>('video-remote-wide'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: panel,
            child: FushiStaggeredEntrance(
              index: 0,
              child: Align(
                alignment: Alignment.topCenter,
                child: _controlCard(VideoRemoteControlCardVariant.panel),
              ),
            ),
          ),
          SizedBox(width: (content * 0.03).clamp(16.0, 40.0)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FushiStaggeredEntrance(
                  index: 1,
                  child: _topBar(withTitle: false),
                ),
                _noticeCard(),
                Expanded(
                  child: FushiStaggeredEntrance(index: 2, child: _tabBody()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData themed = _themeFor(Theme.of(context));
    return Theme(
      data: themed,
      child: Builder(
        builder: (BuildContext context) {
          final bool glass = isGlassDesign(context);
          return Material(
            type: MaterialType.transparency,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final Size size = constraints.biggest;
                final EdgeInsets safe = MediaQuery.paddingOf(context);
                final bool wide = lyricsPlayerIsWide(size);
                return Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (glass)
                      ColoredBox(color: Theme.of(context).colorScheme.surface)
                    else
                      FushiMeshBackdrop(animate: widget.animateBackdrop),
                    FushiEntranceScope(
                      child: wide ? _wide(size, safe) : _portrait(safe),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}
