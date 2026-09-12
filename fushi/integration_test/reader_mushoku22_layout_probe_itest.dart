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

/// 真书布局探针：用户报的「目录列贴在一起 / 图片穿过不同章节 / 悬浮栏顶部空带」。
///
/// 对指定 EPUB（`--dart-define=FUSHI_PROBE_EPUB`）的每个目标章（按 href 尾名匹配）
/// 钉阅读位置、竖排分页开书，抓 WebView 截图并 dump DOM 几何（段落矩形 / 图片矩形 /
/// chrome 顶部 inset / body padding），每章抓两次：开书即刻（悬浮 chrome 唤出态）与
/// 5s 后（自动收起态）。
const String _epubPath = String.fromEnvironment(
  'FUSHI_PROBE_EPUB',
  defaultValue: r'C:\Users\Wight\.claude\jobs\181ad860\tmp\mushoku22\book.epub',
);

const List<String> _targets = <String>[
  'p-titlepage.xhtml',
  'p-toc-002.xhtml',
];

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
      debugPrint('[m22] $label ready after ${i * step.inMilliseconds}ms');
      return;
    }
  }
  fail('$label did not become ready within '
      '${maxPolls * step.inMilliseconds}ms');
}

Future<void> _pumpForPref(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _openBook(WidgetTester tester, String bookKey) async {
  await openBookViaProductionPath(tester, bookKey);
  await _waitFor(tester, _webViewShown, 'reader WebView');
  await _waitFor(tester, _contentReady, 'reader content', maxPolls: 240);
  await _waitFor(tester, readerWebViewReady, 'reader debug hooks',
      maxPolls: 20);
}

Future<void> _closeReader(WidgetTester tester) async {
  if (_readerPageGone()) return;
  final NavigatorState nav =
      Navigator.of(tester.element(find.byType(ReaderFushiPage)));
  nav.pop();
  await _waitFor(tester, _readerPageGone, 'reader closed', maxPolls: 40);
  await tester.pump(const Duration(seconds: 1));
}

const String _probeJs = r'''
(function () {
  function rect(el) {
    var r = el.getBoundingClientRect();
    return { l: Math.round(r.left), t: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) };
  }
  var doc = document.documentElement;
  var bcs = getComputedStyle(document.body);
  var out = {
    url: location.pathname,
    inner: { w: window.innerWidth, h: window.innerHeight },
    scroll: { x: window.scrollX, y: window.scrollY, sw: document.body.scrollWidth, sh: document.body.scrollHeight },
    chromeTop: getComputedStyle(doc).getPropertyValue('--chrome-top-inset'),
    body: { wm: bcs.writingMode, fs: bcs.fontSize, lh: bcs.lineHeight,
            pt: bcs.paddingTop, pb: bcs.paddingBottom, pl: bcs.paddingLeft, pr: bcs.paddingRight,
            mt: bcs.marginTop, h: bcs.height, w: bcs.width,
            colW: bcs.columnWidth, colGap: bcs.columnGap, colCount: bcs.columnCount },
    imgMax: { w: getComputedStyle(doc).getPropertyValue('--fushi-image-max-width'),
              h: getComputedStyle(doc).getPropertyValue('--fushi-image-max-height') },
    html: { cls: doc.className, wm: getComputedStyle(doc).writingMode, fs: getComputedStyle(doc).fontSize },
    ps: [], imgs: [], mains: []
  };
  var ps = document.querySelectorAll('p');
  for (var i = 0; i < ps.length && i < 30; i++) {
    var p = ps[i];
    var cs = getComputedStyle(p);
    out.ps.push({ i: i, txt: (p.textContent || '').trim().slice(0, 14), r: rect(p),
                  d: cs.display, pos: cs.position, fs: cs.fontSize, lh: cs.lineHeight, wm: cs.writingMode,
                  mt: cs.marginTop, mb: cs.marginBottom, ml: cs.marginLeft, mr: cs.marginRight,
                  cls: p.className, parent: p.parentNode.className });
  }
  var imgs = document.querySelectorAll('img, svg, .fushi-merged-image');
  for (var j = 0; j < imgs.length && j < 12; j++) {
    var im = imgs[j];
    var ics = getComputedStyle(im);
    out.imgs.push({ tag: im.tagName, cls: im.className && im.className.baseVal !== undefined ? im.className.baseVal : im.className,
                    r: rect(im), d: ics.display, w: ics.width, h: ics.height, maxW: ics.maxWidth, maxH: ics.maxHeight,
                    nat: im.naturalWidth ? [im.naturalWidth, im.naturalHeight] : null,
                    src: (im.getAttribute('src') || '').slice(-28) });
  }
  var mains = document.querySelectorAll('.main, body > div');
  for (var k = 0; k < mains.length && k < 6; k++) {
    var m = mains[k];
    var mcs = getComputedStyle(m);
    out.mains.push({ cls: m.className, r: rect(m), d: mcs.display, pt: mcs.paddingTop, pl: mcs.paddingLeft,
                     maxW: mcs.maxWidth, w: mcs.width, h: mcs.height, mt: mcs.marginTop, ml: mcs.marginLeft });
  }
  return JSON.stringify(out);
})()
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'mushoku22 layout probe: toc overlap / merged image / floating top gap',
    timeout: const Timeout(Duration(minutes: 20)),
    (WidgetTester tester) async {
      final File epub = File(_epubPath);
      expect(epub.existsSync(), isTrue, reason: 'epub not found: $_epubPath');

      await runFushiItest(
        label: 'm22',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue,
              reason: 'home (nav bar) must render');
          await tester.pump(const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);

          final ReaderFushiSource source = ReaderFushiSource.instance;
          final String originalWritingMode = source.readerWritingMode;
          final String originalViewMode = source.readerViewMode;
          final bool originalFloating = source.tapEmptyToHideChrome;
          final double originalFontSize = source.readerFontSize;
          debugPrint('[m22] original prefs: writing_mode=$originalWritingMode '
              'view_mode=$originalViewMode floating=$originalFloating '
              'font_size=$originalFontSize merge=${source.readerMergeImagePages}');

          try {
            await source.setReaderViewMode('paginated');
            await source.setReaderWritingMode('vertical-rl');
            await source.setReaderFontSize(22);
            if (!originalFloating) source.toggleTapEmptyToHideChrome();
            await _pumpForPref(tester);

            await showBooksTab(tester);
            final String bookKey = await EpubImporter.import(
              db: appModel.database,
              bytes: epub.readAsBytesSync(),
              fileName: epub.uri.pathSegments.last,
            );
            debugPrint('[m22] imported key=$bookKey');
            final EpubBookRow? row =
                await appModel.database.getEpubBook(bookKey);
            expect(row, isNotNull);
            final List<dynamic> chapters =
                jsonDecode(row!.chaptersJson) as List<dynamic>;
            for (int i = 0; i < chapters.length; i++) {
              final Map<String, dynamic> c = chapters[i] as Map<String, dynamic>;
              debugPrint('[m22] chapter $i href=${c['href']}');
            }

            for (final String target in _targets) {
              int section = -1;
              for (int i = 0; i < chapters.length; i++) {
                final String href =
                    (chapters[i] as Map<String, dynamic>)['href'] as String;
                if (href.endsWith(target)) section = i;
              }
              expect(section, greaterThanOrEqualTo(0),
                  reason: 'target $target not in spine');
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
              await _openBook(tester, bookKey);
              await tester.pump(const Duration(seconds: 2));
              final BuildContext readerCtx =
                  tester.element(find.byType(ReaderFushiPage));
              debugPrint('[m22] flutter viewPadding='
                  '${MediaQuery.viewPaddingOf(readerCtx)} padding='
                  '${MediaQuery.paddingOf(readerCtx)} size='
                  '${MediaQuery.sizeOf(readerCtx)} dpr='
                  '${MediaQuery.devicePixelRatioOf(readerCtx)} '
                  'marginTop=${source.readerMarginTop} '
                  'marginBottom=${source.readerMarginBottom} '
                  'topProgress=${source.showTopProgressBar} '
                  'topProgressFloating=${source.topProgressFloating}');

              final Future<dynamic> Function(String)? runJs =
                  ReaderFushiPage.debugEvaluateJavascript;
              expect(runJs, isNotNull);
              final String tag = target.replaceAll('.xhtml', '');
              for (final String phase in <String>[
                'open',
                'settled',
                'page2',
                'page3',
              ]) {
                if (phase == 'settled') {
                  await tester.pump(const Duration(seconds: 6));
                } else if (phase.startsWith('page')) {
                  await runJs!('window.fushiReader.paginate(1)');
                  await tester.pump(const Duration(seconds: 2));
                }
                final String raw = (await runJs!(_probeJs)) as String;
                debugPrint('[m22] $tag $phase ${raw.length} chars');
                // 分段打印，避免单行被日志截断。
                final Map<String, dynamic> r =
                    jsonDecode(raw) as Map<String, dynamic>;
                for (final String key in r.keys) {
                  final dynamic v = r[key];
                  if (v is List) {
                    for (final dynamic e in v) {
                      debugPrint('[m22] $tag $phase $key ${jsonEncode(e)}');
                    }
                  } else {
                    debugPrint('[m22] $tag $phase $key ${jsonEncode(v)}');
                  }
                }
                final ObserveShot web =
                    await captureReaderWebView('m22-$tag-$phase-webview');
                final ObserveShot frame =
                    await captureFlutterFrame(tester, 'm22-$tag-$phase-frame');
                debugPrint('[m22] $tag $phase shots web=${web.path} '
                    'frame=${frame.path}');
              }
              await _closeReader(tester);
            }
          } finally {
            await source.setReaderWritingMode(originalWritingMode);
            await source.setReaderViewMode(originalViewMode);
            await source.setReaderFontSize(originalFontSize);
            if (source.tapEmptyToHideChrome != originalFloating) {
              source.toggleTapEmptyToHideChrome();
            }
            await _pumpForPref(tester);
          }
        },
      );
    },
  );
}
