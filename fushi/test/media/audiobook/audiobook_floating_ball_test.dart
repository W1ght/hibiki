import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/media/audiobook/audiobook_floating_ball.dart';

/// 阅读器有声书悬浮球：
/// - 偏好编解码：未知 id 丢弃、顺序归一、空值回默认三键；
/// - 几何：收起态球外缩停靠边、展开态回到视口内、按钮条向屏幕中央铺；
/// - 交互：收起态半透明且不画按钮 → 点球展开默认三键 → 键回调打到控制器 →
///   再点球收起；拖到另一半屏松手换边并经 onDockChanged 落库。
class _SpyController extends AudiobookPlayerController {
  final List<String> calls = <String>[];
  bool playing = false;

  @override
  bool get isPlaying => playing;

  @override
  Future<void> skipToPrevCue() async => calls.add('prev');

  @override
  Future<void> skipToNextCue() async => calls.add('next');

  @override
  Future<void> togglePlayPause() async => calls.add('toggle');

  @override
  Future<void> seekRelative(int deltaSeconds) async =>
      calls.add('seek$deltaSeconds');
}

const Rect _viewport = Rect.fromLTWH(0, 40, 400, 700);

Future<_SpyController> _pump(
  WidgetTester tester, {
  List<AudiobookFloatingBallAction> actions =
      AudiobookFloatingBallAction.defaults,
  AudiobookFloatingBallDock dock = AudiobookFloatingBallDock.right,
  double fraction = 0.5,
  int skipActionSeconds = 0,
  void Function(AudiobookFloatingBallDock, double)? onDockChanged,
  bool animate = true,
}) async {
  final _SpyController controller = _SpyController();
  addTearDown(controller.dispose);
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const Positioned.fill(child: ColoredBox(color: Colors.white)),
            AudiobookFloatingBall(
              controller: controller,
              viewport: _viewport,
              actions: actions,
              dock: dock,
              verticalFraction: fraction,
              skipActionSeconds: skipActionSeconds,
              animate: animate,
              onDockChanged: onDockChanged ?? (_, __) {},
              onOpenSettings: () => controller.calls.add('settings'),
            ),
          ],
        ),
      ),
    ),
  );
  return controller;
}

Finder _ball() => find.byIcon(Icons.headphones_outlined);

void main() {
  group('AudiobookFloatingBallAction codec', () {
    test('默认三键 = 上一句 / 播放暂停 / 下一句', () {
      expect(
        AudiobookFloatingBallAction.defaults,
        <AudiobookFloatingBallAction>[
          AudiobookFloatingBallAction.prev,
          AudiobookFloatingBallAction.playPause,
          AudiobookFloatingBallAction.next,
        ],
      );
    });

    test('decode 丢未知 id、去重、按 values 顺序归一；空值回默认', () {
      expect(
        AudiobookFloatingBallAction.decode('next, bogus,prev,next,follow'),
        <AudiobookFloatingBallAction>[
          AudiobookFloatingBallAction.prev,
          AudiobookFloatingBallAction.next,
          AudiobookFloatingBallAction.follow,
        ],
      );
      expect(
        AudiobookFloatingBallAction.decode(''),
        AudiobookFloatingBallAction.defaults,
      );
      expect(
        AudiobookFloatingBallAction.decode('bogus'),
        AudiobookFloatingBallAction.defaults,
      );
    });

    test('encode/decode 往返', () {
      const List<AudiobookFloatingBallAction> all =
          AudiobookFloatingBallAction.values;
      expect(
        AudiobookFloatingBallAction.decode(
          AudiobookFloatingBallAction.encode(all.reversed),
        ),
        all,
      );
    });
  });

  group('AudiobookFloatingBallLayout', () {
    const AudiobookFloatingBallLayout right = AudiobookFloatingBallLayout(
      viewport: _viewport,
      dock: AudiobookFloatingBallDock.right,
      verticalFraction: 0.5,
      actionCount: 3,
    );
    const AudiobookFloatingBallLayout left = AudiobookFloatingBallLayout(
      viewport: _viewport,
      dock: AudiobookFloatingBallDock.left,
      verticalFraction: 0.5,
      actionCount: 3,
    );

    test('收起态球外缩停靠边、展开态整球回到视口内', () {
      // 右停靠：收起时球右边越过视口右边 tuck；展开时球右边 = 视口右边 - margin。
      expect(
        right.collapsedBallLeft + right.ballSize,
        closeTo(_viewport.right + right.tuck, 1e-9),
      );
      expect(
        right.expandedBallLeft + right.ballSize,
        closeTo(_viewport.right - right.margin, 1e-9),
      );
      // 左停靠镜像。
      expect(left.collapsedBallLeft, closeTo(_viewport.left - left.tuck, 1e-9));
      expect(
        left.expandedBallLeft,
        closeTo(_viewport.left + left.margin, 1e-9),
      );
      expect(
        right.tuck,
        lessThan(right.ballSize / 2),
        reason: '收起态至少露出一半球体，否则点不到',
      );
    });

    test('按钮条从球向屏幕中央铺开、包围盒只覆盖球 + 条', () {
      expect(right.stripOffsetInBox, 0);
      expect(right.ballOffsetInBox, right.stripWidth);
      expect(right.boxLeftAt(1), right.expandedBallLeft - right.stripWidth);
      expect(left.stripOffsetInBox, left.ballSize + left.gap);
      expect(left.boxLeftAt(1), left.expandedBallLeft);
      expect(right.boxWidth, right.ballSize + right.stripWidth);
    });

    test('纵向比例夹在视口内并可反算', () {
      expect(right.ballTop, closeTo((right.minTop + right.maxTop) / 2, 1e-9));
      expect(right.fractionForTop(right.minTop - 100), 0);
      expect(right.fractionForTop(right.maxTop + 100), 1);
      expect(right.fractionForTop(right.ballTop), closeTo(0.5, 1e-9));
      const AudiobookFloatingBallLayout nan = AudiobookFloatingBallLayout(
        viewport: _viewport,
        dock: AudiobookFloatingBallDock.right,
        verticalFraction: double.nan,
        actionCount: 3,
      );
      expect(nan.ballTop, closeTo(right.ballTop, 1e-9));
    });

    test('松手按球心所在半屏决定停靠边', () {
      expect(right.dockForBallLeft(10), AudiobookFloatingBallDock.left);
      expect(right.dockForBallLeft(300), AudiobookFloatingBallDock.right);
    });
  });

  testWidgets('收起态：半透明、不画任何按钮；点球展开默认三键、再点收起', (WidgetTester tester) async {
    await _pump(tester);
    expect(_ball(), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous_outlined), findsNothing);
    expect(find.byIcon(Icons.play_arrow_outlined), findsNothing);
    expect(find.byIcon(Icons.skip_next_outlined), findsNothing);
    final Opacity idle = tester.widget<Opacity>(
      find.ancestor(of: _ball(), matching: find.byType(Opacity)).first,
    );
    expect(idle.opacity, kAudiobookFloatingBallIdleOpacity);
    expect(idle.opacity, lessThan(0.5), reason: '未激活要够透，不能遮正文');

    await tester.tap(_ball());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsOneWidget, reason: '激活后球换成收起图标');
    expect(find.byIcon(Icons.skip_previous_outlined), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_outlined), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_outlined), findsOneWidget);
    final Opacity lit = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byIcon(Icons.close),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(lit.opacity, 1);
    // 右停靠：按钮在球左侧，且按 上一句 < 播放 < 下一句 从左到右。
    final double prev = tester
        .getCenter(find.byIcon(Icons.skip_previous_outlined))
        .dx;
    final double play = tester
        .getCenter(find.byIcon(Icons.play_arrow_outlined))
        .dx;
    final double next = tester
        .getCenter(find.byIcon(Icons.skip_next_outlined))
        .dx;
    final double ball = tester.getCenter(find.byIcon(Icons.close)).dx;
    expect(prev, lessThan(play));
    expect(play, lessThan(next));
    expect(next, lessThan(ball));

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(_ball(), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous_outlined), findsNothing);
  });

  testWidgets('展开动画是错峰弹出：中途离球最近的键先可见', (WidgetTester tester) async {
    await _pump(tester);
    await tester.tap(_ball());
    // Ticker 首帧 elapsed = 0，先出一帧再推进；260ms 展开，80ms 时离球最近的
    // 键（右停靠 = 下一句）应已明显弹出、最远的（上一句）还基本没出。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    double opacityOf(IconData icon) => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.byIcon(icon),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;
    expect(
      opacityOf(Icons.skip_next_outlined),
      greaterThan(opacityOf(Icons.skip_previous_outlined)),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('三键回调打到控制器；按钮按后保持展开', (WidgetTester tester) async {
    final _SpyController c = await _pump(tester);
    await tester.tap(_ball());
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.skip_previous_outlined));
    await tester.tap(find.byIcon(Icons.play_arrow_outlined));
    await tester.tap(find.byIcon(Icons.skip_next_outlined));
    await tester.pump();
    expect(c.calls, <String>['prev', 'toggle', 'next']);
    expect(find.byIcon(Icons.close), findsOneWidget, reason: '按键不收起');
  });

  testWidgets('播放中：球图标变均衡器、播放键变暂停', (WidgetTester tester) async {
    final _SpyController c = await _pump(tester);
    c.playing = true;
    c.notifyListeners();
    await tester.pump();
    expect(find.byIcon(Icons.graphic_eq), findsOneWidget);
    await tester.tap(find.byIcon(Icons.graphic_eq));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.pause_outlined), findsOneWidget);
  });

  testWidgets('按秒跳时上一句/下一句跟随 skipActionSeconds', (WidgetTester tester) async {
    final _SpyController c = await _pump(tester, skipActionSeconds: 15);
    await tester.tap(_ball());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fast_rewind_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.fast_forward_outlined));
    await tester.pump();
    expect(c.calls, <String>['seek15']);
  });

  testWidgets('自定义集合：只画选中的键，顺序固定', (WidgetTester tester) async {
    final _SpyController c = await _pump(
      tester,
      dock: AudiobookFloatingBallDock.left,
      actions: const <AudiobookFloatingBallAction>[
        AudiobookFloatingBallAction.seekBack,
        AudiobookFloatingBallAction.playPause,
        AudiobookFloatingBallAction.settings,
      ],
    );
    await tester.tap(_ball());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.skip_previous_outlined), findsNothing);
    expect(find.byIcon(Icons.replay_10_outlined), findsOneWidget);
    expect(find.byIcon(Icons.tune_outlined), findsOneWidget);
    // 左停靠：球在最左，键向右铺。
    final double ball = tester.getCenter(find.byIcon(Icons.close)).dx;
    final double back = tester
        .getCenter(find.byIcon(Icons.replay_10_outlined))
        .dx;
    final double tune = tester.getCenter(find.byIcon(Icons.tune_outlined)).dx;
    expect(ball, lessThan(back));
    expect(back, lessThan(tune));
    await tester.tap(find.byIcon(Icons.replay_10_outlined));
    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pump();
    expect(c.calls, <String>['seek-10', 'settings']);
  });

  testWidgets('拖到左半屏松手：换边吸附并回调落库；拖动会先收起', (WidgetTester tester) async {
    AudiobookFloatingBallDock? dock;
    double? fraction;
    await _pump(
      tester,
      onDockChanged: (AudiobookFloatingBallDock d, double f) {
        dock = d;
        fraction = f;
      },
    );
    await tester.tap(_ball());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsOneWidget);
    final Offset from = tester.getCenter(find.byIcon(Icons.close));
    // 一路拖到左边、往上挪 200px。
    await tester.drag(find.byIcon(Icons.close), Offset(-from.dx + 30, -200));
    await tester.pumpAndSettle();
    expect(dock, AudiobookFloatingBallDock.left);
    expect(fraction, lessThan(0.5));
    expect(_ball(), findsOneWidget, reason: '拖动即收起');
    expect(find.byIcon(Icons.skip_previous_outlined), findsNothing);
    // 吸附后球贴视口左边（收起态外缩 tuck）。
    final Rect ballRect = tester.getRect(_ball());
    expect(ballRect.center.dx, lessThan(_viewport.width / 2));
    expect(ballRect.top, greaterThanOrEqualTo(_viewport.top));
  });

  testWidgets('墨水屏模式（animate=false）：一帧完成展开', (WidgetTester tester) async {
    await _pump(tester, animate: false);
    await tester.tap(_ball());
    await tester.pump();
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous_outlined), findsOneWidget);
  });
}
