import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/epub/epub_importer.dart' show EpubImporter;
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, showBooksTab;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// macOS 可见窗口探针：悬浮态开书，打印 Flutter 侧 MediaQuery（viewPadding / padding）
/// 与 WebView 里的 `--chrome-top-inset`，验证自绘标题栏下 fullSizeContentView 上报的
/// 顶部安全区是否被阅读器二次预留（需要**不带** FUSHI_TEST_HIDDEN 跑）。
const String _epubPath = String.fromEnvironment(
  'FUSHI_PROBE_EPUB',
  defaultValue: r'C:\Users\Wight\.claude\jobs\181ad860\tmp\mushoku22\book.epub',
);

const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');

bool _webViewShown() => find.byKey(_kWebViewKey).evaluate().isNotEmpty;

bool _contentReady() => find.byKey(_kContentReadyKey).evaluate().isNotEmpty;

bool _readerPageGone() => find.byType(ReaderFushiPage).evaluate().isEmpty;

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  int maxPolls = 120,
  Duration step = const Duration(milliseconds: 500),
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(step);
    if (ready()) {
      debugPrint('[inset] $label ready after ${i * step.inMilliseconds}ms');
      return;
    }
  }
  fail(
    '$label did not become ready within '
    '${maxPolls * step.inMilliseconds}ms',
  );
}

Future<void> _pumpFor(WidgetTester tester, int ms) async {
  for (int i = 0; i < ms ~/ 150; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

const String _readJs = r'''
(function () {
  var doc = document.documentElement;
  var dcs = getComputedStyle(doc);
  var bcs = getComputedStyle(document.body);
  var first = null;
  var ps = document.querySelectorAll('p');
  for (var i = 0; i < ps.length; i++) {
    var r = ps[i].getBoundingClientRect();
    if (r.width > 0 && r.height > 0) { first = { l: Math.round(r.left), t: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) }; break; }
  }
  return JSON.stringify({
    chromeTop: dcs.getPropertyValue('--chrome-top-inset').trim(),
    chromeBottom: dcs.getPropertyValue('--chrome-bottom-inset').trim(),
    marginTop: dcs.getPropertyValue('--reader-margin-top').trim(),
    marginBottom: dcs.getPropertyValue('--reader-margin-bottom').trim(),
    pt: bcs.paddingTop, pb: bcs.paddingBottom, colW: bcs.columnWidth,
    inner: [window.innerWidth, window.innerHeight],
    firstP: first,
    imgMax: [dcs.getPropertyValue('--fushi-image-max-width').trim(), dcs.getPropertyValue('--fushi-image-max-height').trim()]
  });
})()
''';

String _describeMq(BuildContext c) =>
    '[vp] viewPadding=${MediaQuery.viewPaddingOf(c)} '
    'padding=${MediaQuery.paddingOf(c)} '
    'viewInsets=${MediaQuery.viewInsetsOf(c)} '
    'size=${MediaQuery.sizeOf(c)} '
    'dpr=${MediaQuery.devicePixelRatioOf(c)}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'mac visible window: viewPadding vs chrome top inset (floating)',
    timeout: const Timeout(Duration(minutes: 15)),
    (WidgetTester tester) async {
      final File epub = File(_epubPath);
      expect(epub.existsSync(), isTrue, reason: 'epub not found: $_epubPath');

      await runFushiItest(
        label: 'vp',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue);
          await tester.pump(const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);
          final ReaderFushiSource source = ReaderFushiSource.instance;
          final String originalWritingMode = source.readerWritingMode;
          final String originalViewMode = source.readerViewMode;
          final bool originalFloating = source.tapEmptyToHideChrome;
          try {
            await source.setReaderViewMode('paginated');
            await source.setReaderWritingMode('vertical-rl');
            // 起点：悬浮态（悬浮控制栏开）。
            if (!originalFloating) source.toggleTapEmptyToHideChrome();
            await _pumpFor(tester, 1200);
            await showBooksTab(tester);
            final String bookKey = await EpubImporter.import(
              db: appModel.database,
              bytes: epub.readAsBytesSync(),
              fileName: epub.uri.pathSegments.last,
            );
            final EpubBookRow? row = await appModel.database.getEpubBook(
              bookKey,
            );
            expect(row, isNotNull);
            final List<dynamic> chapters =
                jsonDecode(row!.chaptersJson) as List<dynamic>;
            int section = 0;
            for (int i = 0; i < chapters.length; i++) {
              final String href =
                  (chapters[i] as Map<String, dynamic>)['href'] as String;
              if (href.endsWith('p-002.xhtml')) section = i;
            }
            await appModel.database.upsertReaderPosition(
              ReaderPositionsCompanion(
                bookUid: Value<String>(row.uid),
                sectionIndex: Value<int>(section),
                normCharOffset: const Value<int>(0),
                charOffset: const Value<int>(-1),
                updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
              ),
            );
            await tester.pump(const Duration(seconds: 1));

            await openBookViaProductionPath(tester, bookKey);
            await _waitFor(tester, _webViewShown, 'reader WebView');
            await _waitFor(
              tester,
              _contentReady,
              'reader content',
              maxPolls: 240,
            );
            await _waitFor(
              tester,
              readerWebViewReady,
              'reader debug hooks',
              maxPolls: 20,
            );
            await tester.pump(const Duration(seconds: 3));
            final Future<dynamic> Function(String) runJs =
                ReaderFushiPage.debugEvaluateJavascript!;

            Future<void> snap(String step) async {
              await _pumpFor(tester, 900);
              final String raw = (await runJs(_readJs)) as String;
              debugPrint(
                '[inset] STEP $step floating='
                '${source.tapEmptyToHideChrome} $raw',
              );
              final ObserveShot f = await captureFlutterFrame(
                tester,
                'inset-$step-frame',
              );
              final ObserveShot w = await captureReaderWebView(
                'inset-$step-web',
              );
              debugPrint('[inset] $step shots ${f.path} ${w.path}');
            }

            debugPrint(
              _describeMq(tester.element(find.byType(ReaderFushiPage))),
            );
            await snap('01-floating-open');
            await tester.pump(const Duration(seconds: 6));
            await snap('02-floating-autohidden');
            source.toggleTapEmptyToHideChrome();
            await _pumpFor(tester, 600);
            ReaderFushiSource.onChromeReanchorLive?.call();
            await tester.pump(const Duration(seconds: 3));
            await snap('03-squeeze');
            if (!_readerPageGone()) {
              Navigator.of(tester.element(find.byType(ReaderFushiPage))).pop();
              await _waitFor(
                tester,
                _readerPageGone,
                'reader closed',
                maxPolls: 40,
              );
            }
          } finally {
            await source.setReaderWritingMode(originalWritingMode);
            await source.setReaderViewMode(originalViewMode);
            if (source.tapEmptyToHideChrome != originalFloating) {
              source.toggleTapEmptyToHideChrome();
            }
            await _pumpFor(tester, 1200);
          }
        },
      );
    },
  );
}
