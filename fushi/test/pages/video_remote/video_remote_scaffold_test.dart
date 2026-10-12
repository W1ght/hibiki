import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_remote_control_layout.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_models.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_scaffold.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_transcript_view.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show FushiChromeReveal;
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:material_ui/material_ui.dart';

/// 手机字幕遥控器展示组件：竖 / 横屏布局、当前句强调、手动滚动后「回到当前
/// 句」、自定义按钮布局、逐字查词回调、大字号长句不溢出、旋转保状态。
class _Clock implements FushiPlaybackClock {
  @override
  Duration get position => const Duration(minutes: 3, seconds: 12);

  @override
  Duration get duration => const Duration(minutes: 23, seconds: 40);
}

const List<String> _sentences = <String>[
  'おはようございます。',
  '今日はいい天気ですね。',
  'ちょっと待って、それって本当なの？',
  '彼女はそう言って、静かに窓の外を見つめた。',
  '明日の朝、駅の前で会いましょう。',
  'この町に来てから、もう三年が経った。',
  'あの日のことは、今でもはっきり覚えている。',
  '大丈夫、きっと上手くいくよ。',
  '何かあったら、すぐに連絡してね。',
  'じゃあ、また明日。',
];

List<VideoRemoteTranscriptLine> _lines({int count = 40, String? longLine}) =>
    <VideoRemoteTranscriptLine>[
      for (int i = 0; i < count; i++)
        VideoRemoteTranscriptLine(
          id: 'cue-$i',
          text: longLine != null && i == 5
              ? longLine
              : _sentences[i % _sentences.length],
          start: Duration(seconds: i * 4),
          end: Duration(seconds: i * 4 + 3),
          secondaryText: i.isEven ? 'Line $i translation' : null,
          favorited: i == 6,
        ),
    ];

class _Recorder {
  final List<VideoRemoteControlItem> controls = <VideoRemoteControlItem>[];
  final List<(int, int)> lookups = <(int, int)>[];
  final List<int> lineTaps = <int>[];
}

Widget _app({
  required _Recorder recorder,
  List<VideoRemoteTranscriptLine>? lines,
  int activeIndex = 5,
  VideoRemoteControlLayout? layout,
  double textScale = 1,
  bool apple = false,
  VideoRemoteTranscriptController? controller,
  VideoRemoteNotice? notice,
}) {
  final ThemeData base = apple
      ? buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: kFushiDefaultSeed),
          textTheme: const TextTheme(),
          glassDesign: true,
        )
      : buildFushiFallbackTheme(Brightness.light);
  return MaterialApp(
    theme: base.copyWith(platform: TargetPlatform.android),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: child!,
    ),
    home: Scaffold(
      body: VideoRemoteScaffold(
        nowPlaying: const VideoRemoteNowPlaying(
          title: '葬送のフリーレン',
          episodeLabel: '第 7 話',
          hostName: 'DESKTOP-STUDY',
          isPlaying: true,
          speed: 1.25,
        ),
        clock: _Clock(),
        lines: lines ?? _lines(),
        activeIndex: activeIndex,
        favorites: const <VideoRemoteFavoriteEntry>[],
        favoritesScope: VideoRemoteFavoritesScope.currentVideo,
        controlLayout: layout ?? VideoRemoteControlLayout.defaults,
        transcriptController: controller,
        notice: notice,
        callbacks: VideoRemoteCallbacks(
          onBack: () {},
          onControl: recorder.controls.add,
          onLookup: (int line, int charOffset) =>
              recorder.lookups.add((line, charOffset)),
          onLineTap: recorder.lineTaps.add,
          onFavoritesScopeChanged: (_) {},
          onOpenFavorite: (_) {},
          onRemoveFavorites: (_) {},
          onRefresh: () {},
          onSeek: (_) {},
          onReplayLine: (_) {},
          onToggleFavoriteLine: (_) {},
          onMineLine: (_) {},
          onCustomizeControls: () {},
        ),
      ),
    ),
  );
}

Future<void> _pumpAt(WidgetTester tester, Size size, Widget app) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pump(const Duration(milliseconds: 800));
}

TextStyle _lineStyle(WidgetTester tester, int index) {
  final RichText text = tester.widget<RichText>(
    find.byKey(ValueKey<String>('video-remote-line-text-$index')),
  );
  return text.text.style!;
}

double _lineOpacity(WidgetTester tester, int index) => tester
    .widget<AnimatedOpacity>(
      find
          .descendant(
            of: find.byKey(ValueKey<String>('video-remote-line-$index')),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    )
    .opacity;

FushiChromeReveal _revealOf(WidgetTester tester, Finder child) =>
    tester.widget<FushiChromeReveal>(
      find
          .ancestor(
            of: child,
            matching: find.byType(FushiChromeReveal, skipOffstage: false),
          )
          .first,
    );

void main() {
  testWidgets('竖屏：浮动顶栏 + 列表 + 底部浮动控制卡', (WidgetTester tester) async {
    final _Recorder recorder = _Recorder();
    await _pumpAt(tester, const Size(390, 844), _app(recorder: recorder));
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('video-remote-portrait')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-remote-wide')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('video-remote-top-bar')),
      findsOneWidget,
    );
    // 页签在顶栏下方的连接式按钮组里（手机宽度顶栏放不下两颗页签键）。
    expect(
      find.byKey(const ValueKey<String>('video-remote-tab-switch')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-remote-primary-group')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-remote-secondary-row')),
      findsOneWidget,
    );
    // 控制卡在列表下方（底部）。
    final Rect card = tester.getRect(
      find.byKey(const ValueKey<String>('video-remote-control-card')),
    );
    final Rect list = tester.getRect(
      find.byKey(const ValueKey<String>('video-remote-transcript-list')),
    );
    expect(card.top, greaterThanOrEqualTo(list.bottom - 0.5));
    expect(card.bottom, lessThanOrEqualTo(844));
    // 底部次组纯图标、命中区 ≥48。
    for (final String id in <String>[
      'replayCue',
      'favorite',
      'followCurrent',
      'mine',
    ]) {
      final Finder button = find.byKey(
        ValueKey<String>('video-remote-control-$id'),
      );
      expect(button, findsOneWidget, reason: id);
      final Size hit = tester.getSize(
        find.ancestor(of: button, matching: find.byType(ConstrainedBox)).first,
      );
      expect(hit.width, greaterThanOrEqualTo(48), reason: id);
      expect(hit.height, greaterThanOrEqualTo(48), reason: id);
    }
  });

  testWidgets('横屏：左栏信息 + 控制，右栏列表', (WidgetTester tester) async {
    final _Recorder recorder = _Recorder();
    await _pumpAt(tester, const Size(1024, 600), _app(recorder: recorder));
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('video-remote-wide')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-remote-portrait')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('video-remote-secondary-grid')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-remote-host-chip')),
      findsOneWidget,
    );
    expect(find.text('葬送のフリーレン'), findsOneWidget);
    final Rect panel = tester.getRect(
      find.byKey(const ValueKey<String>('video-remote-control-card')),
    );
    final Rect list = tester.getRect(
      find.byKey(const ValueKey<String>('video-remote-transcript-list')),
    );
    expect(panel.right, lessThan(list.left));
  });

  testWidgets('当前句主色放大，按距离降透明度，已读再减淡', (WidgetTester tester) async {
    final _Recorder recorder = _Recorder();
    await _pumpAt(tester, const Size(390, 844), _app(recorder: recorder));
    final ColorScheme cs = Theme.of(
      tester.element(find.byKey(const ValueKey<String>('video-remote-line-5'))),
    ).colorScheme;
    final TextStyle current = _lineStyle(tester, 5);
    final TextStyle next = _lineStyle(tester, 6);
    expect(current.color, cs.primary);
    expect(
      current.fontSize!,
      closeTo(next.fontSize! * kVideoRemoteCurrentScale, 0.01),
    );
    expect(_lineOpacity(tester, 5), 1);
    expect(_lineOpacity(tester, 6), kVideoRemoteContextOpacities[0]);
    expect(_lineOpacity(tester, 7), kVideoRemoteContextOpacities[1]);
    expect(
      _lineOpacity(tester, 4),
      closeTo(
        kVideoRemoteContextOpacities[0] * kVideoRemotePastOpacityFactor,
        1e-9,
      ),
    );
    // 当前句停在列表可视带约 42% 高处。
    final Rect list = tester.getRect(
      find.byKey(const ValueKey<String>('video-remote-transcript-list')),
    );
    final Rect row = tester.getRect(
      find.byKey(const ValueKey<String>('video-remote-line-5')),
    );
    final double ratio = (row.center.dy - list.top) / list.height;
    expect(ratio, closeTo(kVideoRemoteTranscriptAnchor, 0.06));
  });

  testWidgets('手动滚动关闭跟随并浮出「回到当前句」，点它恢复', (WidgetTester tester) async {
    final _Recorder recorder = _Recorder();
    final VideoRemoteTranscriptController controller =
        VideoRemoteTranscriptController();
    addTearDown(controller.dispose);
    await _pumpAt(
      tester,
      const Size(390, 844),
      _app(recorder: recorder, controller: controller),
    );
    final Finder returnButton = find.byKey(
      const ValueKey<String>('video-remote-return-current'),
      skipOffstage: false,
    );
    expect(_revealOf(tester, returnButton).visible, isFalse);
    await tester.drag(
      find.byKey(const ValueKey<String>('video-remote-transcript-list')),
      const Offset(0, -300),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.following, isFalse);
    expect(_revealOf(tester, returnButton).visible, isTrue);
    // 浏览时非当前行统一提亮到浏览透明度。
    expect(_lineOpacity(tester, 7), kVideoRemoteBrowsingOpacity);
    await tester.tap(returnButton);
    await tester.pump(const Duration(milliseconds: 800));
    expect(controller.following, isTrue);
    expect(_revealOf(tester, returnButton).visible, isFalse);
  });

  testWidgets('自定义布局生效：倍速进次组、收藏移出；回调带按钮', (WidgetTester tester) async {
    final _Recorder recorder = _Recorder();
    final VideoRemoteControlLayout layout = VideoRemoteControlLayout.defaults
        .moveItem(
          VideoRemoteControlItem.speed,
          VideoRemoteControlSlot.secondary,
          index: 0,
        )
        .moveItem(
          VideoRemoteControlItem.favorite,
          VideoRemoteControlSlot.hidden,
        )
        .moveItem(
          VideoRemoteControlItem.seekBack,
          VideoRemoteControlSlot.primary,
          index: 0,
        );
    await _pumpAt(
      tester,
      const Size(390, 844),
      _app(recorder: recorder, layout: layout),
    );
    expect(
      find.byKey(const ValueKey<String>('video-remote-control-speed')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-remote-control-favorite')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('video-remote-primary-group')),
        matching: find.byKey(
          const ValueKey<String>('video-remote-control-seekBack'),
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-remote-control-speed')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-remote-control-playPause')),
    );
    await tester.pump();
    expect(recorder.controls, <VideoRemoteControlItem>[
      VideoRemoteControlItem.speed,
      VideoRemoteControlItem.playPause,
    ]);
  });

  testWidgets('「回到当前句」按钮由脚手架处理，不转发给页面', (WidgetTester tester) async {
    final _Recorder recorder = _Recorder();
    final VideoRemoteTranscriptController controller =
        VideoRemoteTranscriptController()..stopFollowing();
    addTearDown(controller.dispose);
    await _pumpAt(
      tester,
      const Size(390, 844),
      _app(recorder: recorder, controller: controller),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-remote-control-followCurrent')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.following, isTrue);
    expect(recorder.controls, isEmpty);
  });

  testWidgets('点字查词：回调行下标与字下标', (WidgetTester tester) async {
    final _Recorder recorder = _Recorder();
    await _pumpAt(tester, const Size(390, 844), _app(recorder: recorder));
    const int line = 5; // 'この町に来てから、もう三年が経った。'
    final Finder text = find.byKey(
      const ValueKey<String>('video-remote-line-text-$line'),
    );
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      text,
    );
    for (final int charIndex in <int>[0, 3, 7]) {
      final List<TextBox> boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: charIndex, extentOffset: charIndex + 1),
      );
      final Offset local = boxes.first.toRect().center;
      await tester.tapAt(paragraph.localToGlobal(local));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(recorder.lookups, <(int, int)>[(line, 0), (line, 3), (line, 7)]);
    expect(recorder.lineTaps, isEmpty);
  });

  testWidgets('长句 + 200% 字号：竖屏不溢出', (WidgetTester tester) async {
    final _Recorder recorder = _Recorder();
    final String longLine = List<String>.filled(
      8,
      'あの日見た花の名前を僕達はまだ知らない。',
    ).join();
    await _pumpAt(
      tester,
      const Size(360, 640),
      _app(
        recorder: recorder,
        lines: _lines(longLine: longLine),
        textScale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
    final Size row = tester.getSize(
      find.byKey(const ValueKey<String>('video-remote-line-5')),
    );
    expect(row.width, lessThanOrEqualTo(360));
    expect(row.height, greaterThan(200)); // 换行撑高，不是被截掉。
  });

  testWidgets('竖横屏切换保住页签与列表滚动位置', (WidgetTester tester) async {
    final _Recorder recorder = _Recorder();
    final VideoRemoteTranscriptController controller =
        VideoRemoteTranscriptController();
    addTearDown(controller.dispose);
    final Widget app = _app(recorder: recorder, controller: controller);
    await _pumpAt(tester, const Size(390, 844), app);
    await tester.drag(
      find.byKey(const ValueKey<String>('video-remote-transcript-list')),
      const Offset(0, -400),
    );
    await tester.pump(const Duration(milliseconds: 600));
    ScrollPosition position() => tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(
              const ValueKey<String>('video-remote-transcript-list'),
            ),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    final double before = position().pixels;
    expect(before, greaterThan(0));
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('video-remote-tab-switch')),
        matching: find.text('Favorites'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    tester.view.physicalSize = const Size(844, 390);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('video-remote-wide')),
      findsOneWidget,
    );
    expect(
      _revealOf(
        tester,
        find.byKey(
          const ValueKey<String>('video-remote-favorites-scope'),
          skipOffstage: false,
        ),
      ).visible,
      isTrue,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-remote-tab-transcript')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.following, isFalse);
    expect(position().pixels, closeTo(before, 1));
  });

  testWidgets('内联状态卡（断线）出现在内容流里', (WidgetTester tester) async {
    final _Recorder recorder = _Recorder();
    bool retried = false;
    await _pumpAt(
      tester,
      const Size(390, 844),
      _app(
        recorder: recorder,
        notice: VideoRemoteNotice(
          kind: VideoRemoteNoticeKind.disconnected,
          message: '連接が切れました',
          actionLabel: '再接続',
          onAction: () => retried = true,
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('video-remote-notice')),
      findsOneWidget,
    );
    await tester.tap(find.text('再接続'));
    expect(retried, isTrue);
  });

  testWidgets('Apple 设计系统：可渲染、不崩', (WidgetTester tester) async {
    final _Recorder recorder = _Recorder();
    await _pumpAt(
      tester,
      const Size(390, 844),
      _app(recorder: recorder, apple: true),
    );
    expect(tester.takeException(), isNull);
    await _pumpAt(
      tester,
      const Size(1024, 600),
      _app(recorder: recorder, apple: true),
    );
    expect(tester.takeException(), isNull);
  });

  test('透明度纯函数', () {
    expect(
      videoRemoteLineOpacity(index: 3, activeIndex: 3, following: true),
      1,
    );
    expect(
      videoRemoteLineOpacity(index: 9, activeIndex: 3, following: true),
      0.3,
    );
    expect(
      videoRemoteLineOpacity(index: 1, activeIndex: 3, following: true),
      closeTo(0.48 * 0.7, 1e-9),
    );
    expect(
      videoRemoteLineOpacity(index: 9, activeIndex: 3, following: false),
      0.7,
    );
    expect(
      videoRemoteLineOpacity(index: 9, activeIndex: -1, following: true),
      0.62,
    );
  });
}
