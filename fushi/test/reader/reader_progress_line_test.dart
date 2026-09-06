import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_progress_line.dart';

import '../pages/reader_fushi_page_source_corpus.dart';

/// 桌面端阅读器顶部细进度线（ッツ 形态）：
///  ① 纯函数——比例 / 显隐判据；
///  ② 组件——填充宽度按比例、填充与轨道都从注入的纸张主题前景色派生（不读
///     Material 主题色）、指针穿透；
///  ③ 源码守卫——页面用注入的 `_themeTextColor()` 喂颜色、显隐走 `showTopProgressBar`
///     同一开关、Positioned 顶边含工具栏预留、自带 RepaintBoundary（BUG-1692）。
void main() {
  group('pure helpers', () {
    test('ratio: 未知 / 零总数 → null；越界夹到 [0, 1]', () {
      expect(readerProgressLineRatio(current: null, total: 100), isNull);
      expect(readerProgressLineRatio(current: 10, total: null), isNull);
      expect(readerProgressLineRatio(current: 10, total: 0), isNull);
      expect(readerProgressLineRatio(current: 25, total: 100), 0.25);
      expect(readerProgressLineRatio(current: 200, total: 100), 1.0);
      expect(readerProgressLineRatio(current: -5, total: 100), 0.0);
    });

    test('visible: 桌面 chrome + 首屏就绪 + 非歌词 + 开关开 + 进度已知', () {
      bool visible({
        bool desktop = true,
        bool loaded = true,
        bool lyrics = false,
        bool show = true,
        double? ratio = 0.5,
      }) => readerProgressLineVisible(
        desktopChromeEnabled: desktop,
        hasEverLoaded: loaded,
        lyricsMode: lyrics,
        showProgress: show,
        ratio: ratio,
      );
      expect(visible(), isTrue);
      expect(visible(desktop: false), isFalse);
      expect(visible(loaded: false), isFalse);
      expect(visible(lyrics: true), isFalse);
      expect(visible(show: false), isFalse);
      expect(visible(ratio: null), isFalse);
    });
  });

  group('ReaderProgressLine', () {
    const Color paper = Color(0xFFE8DCC8);

    Future<void> pump(WidgetTester tester, double ratio) async {
      await tester.pumpWidget(
        MaterialApp(
          // 全局主题故意用一个与纸张色无关的种子：进度线不得从这里取色。
          theme: ThemeData(colorSchemeSeed: Colors.pink),
          home: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 400,
              child: ReaderProgressLine(ratio: ratio, color: paper),
            ),
          ),
        ),
      );
    }

    testWidgets('填充宽度 = 比例 × 整宽，高度是 2px 常量', (tester) async {
      await pump(tester, 0.25);
      final Finder fill = find.byKey(
        const ValueKey<String>('fushi_progress_line_fill'),
      );
      expect(fill, findsOneWidget);
      expect(tester.getSize(fill).width, closeTo(100, 0.01));
      expect(
        tester.getSize(find.byType(ReaderProgressLine)).height,
        kReaderProgressLineHeight,
      );
    });

    testWidgets('填充与轨道都从注入的纸张前景色派生', (tester) async {
      await pump(tester, 0.5);
      final DecoratedBox fillBox = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey<String>('fushi_progress_line_fill')),
      );
      final Color fillColor = (fillBox.decoration as BoxDecoration).color!;
      expect(fillColor.withValues(alpha: 1), paper.withValues(alpha: 1));
      expect(fillColor.a, closeTo(kReaderProgressLineFillAlpha, 0.01));

      final Iterable<DecoratedBox> boxes = tester.widgetList<DecoratedBox>(
        find.byType(DecoratedBox),
      );
      final DecoratedBox track = boxes.firstWhere(
        (DecoratedBox b) =>
            b.key != const ValueKey<String>('fushi_progress_line_fill'),
      );
      final Color trackColor = (track.decoration as BoxDecoration).color!;
      expect(trackColor.withValues(alpha: 1), paper.withValues(alpha: 1));
      expect(trackColor.a, closeTo(kReaderProgressLineTrackAlpha, 0.01));
    });

    testWidgets('越界比例夹住；指针穿透（IgnorePointer）', (tester) async {
      await pump(tester, 1.7);
      final Finder fill = find.byKey(
        const ValueKey<String>('fushi_progress_line_fill'),
      );
      expect(tester.getSize(fill).width, closeTo(400, 0.01));
      expect(
        find.descendant(
          of: find.byType(ReaderProgressLine),
          matching: find.byType(IgnorePointer),
        ),
        findsOneWidget,
      );
    });
  });

  group('page wiring guard', () {
    final String source = readReaderPageSource();
    final String builder = source.substring(
      source.indexOf('Widget _buildProgressLine()'),
      source.indexOf('Widget _buildHoverRevealLayer()'),
    );

    test('颜色从纸张主题取，显隐与状态行进度数字同一开关', () {
      expect(builder, contains('color: _themeTextColor()'));
      expect(
        builder,
        contains('showProgress: ReaderFushiSource.instance.showTopProgressBar'),
      );
      expect(builder, contains('desktopChromeEnabled: _desktopChromeEnabled'));
      expect(builder, contains('lyricsMode: _lyricsMode'));
    });

    test('贴工具栏下沿（含挤压态预留）、自带 RepaintBoundary', () {
      expect(
        builder,
        contains(
          'top: _stableTopInset + _macosWindowTitlebarInset + '
          '_desktopHeaderReserve',
        ),
      );
      expect(builder, contains('RepaintBoundary('));
      expect(builder, contains("ValueKey<String>('fushi_progress_line')"));
    });

    test('挂进页面 Stack，且在悬停热区 / 工具栏之前', () {
      final String page = File(
        'lib/src/pages/implementations/reader_fushi_page.dart',
      ).readAsStringSync();
      final int line = page.indexOf('_buildProgressLine(),');
      final int hover = page.indexOf('_buildHoverRevealLayer(),');
      final int header = page.indexOf('_buildDesktopHeader(),');
      expect(line, greaterThan(0));
      expect(line, lessThan(hover));
      expect(line, lessThan(header));
    });
  });
}
