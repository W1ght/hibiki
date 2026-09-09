import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/utils/components/clipboard_lookup_text_panel.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 真 app 上验证查词页源文本条的**命中词高亮**跨度（Yomitan 式扫描高亮）。
///
/// 单测已经钉住了 `resolveSourceLookupHighlight` 的换算和面板的画框，但那两层都拿
/// **喂进去的** matchedUnits 说话。这条测试补的是唯一没被覆盖的一环：真 app + 真
/// fushidicts FFI 回报的 `bestLength`，经本页的异步接线，最终落成条上的跨度。
///
/// **fixture 为什么是 `テスト` / `スト` / `ト`**：runner 把 APPDATA 重定向到全新隔离
/// 根，用户本机装的词典一个都进不来，所以查询词必须由本测试自带的词典保证命中。
/// 这三条构成一个 3/2/1 的长度阶梯——引擎的候选串是「从串首锚定、由长到短的前缀」
/// （`scan_candidates`），于是在 `テスト` 上点第 0/1/2 个字分别命中 3/2/1 个字，
/// 恰好把「起点跟着被点的字走」和「长度跟着引擎走」两件事同时钉死。不用
/// 「と言いつつ」那种真实例子，是因为那要依赖去屈折规则表，fixture 里一旦没配对
/// 就会红在 fixture 上而不是产品上。
Future<File> _writeHighlightFixture(File file) async {
  final Map<String, dynamic> index = <String, dynamic>{
    'title': 'FushiHighlightSpanFixture',
    'format': 3,
    'revision': 'highlight-span-1',
    'sequenced': false,
  };
  // Yomitan v3 term bank：[表记, 读音, 释义标签, rules, score, glossary[], 序号, 词标签]
  List<dynamic> term(String expression, String gloss, int sequence) =>
      <dynamic>[expression, expression, '', '', 0, <String>[gloss], sequence, ''];
  final List<List<dynamic>> termBank = <List<dynamic>>[
    term('テスト', 'three-grapheme fixture headword', 0),
    term('スト', 'two-grapheme fixture headword', 1),
    term('ト', 'one-grapheme fixture headword', 2),
  ];

  final Archive archive = Archive()
    ..addFile(_fixtureJson('index.json', index))
    ..addFile(_fixtureJson('term_bank_1.json', termBank));
  final List<int> zipBytes = ZipEncoder().encode(archive)!;
  file.parent.createSync(recursive: true);
  await file.writeAsBytes(zipBytes, flush: true);
  return file;
}

ArchiveFile _fixtureJson(String name, Object content) {
  final List<int> bytes = utf8.encode(jsonEncode(content));
  return ArchiveFile(name, bytes.length, bytes);
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String sourceText = 'テスト';

  testWidgets('source lookup strip highlights exactly the engine-matched span',
      (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '首页必须在 90s 内出来');
    await tester.pump(const Duration(seconds: 2));

    // BUG-1106：Tab 遍历前必须先开实验焦点导航开关——关闭（默认）时裸 Tab 被全局
    // 中和成 DoNothingIntent，而集成测试跑在全新隔离根上、偏好恒为默认值。
    await enableFocusNavigation(tester);
    final FocusDriver driver = FocusDriver(tester);

    // ── 装 fixture 词典（隔离根里本来一本都没有）──
    final Element anyElement = tester.element(find.byType(Scaffold).first);
    final ProviderContainer container = ProviderScope.containerOf(anyElement);
    final AppModel appModel = container.read(appProvider);
    await readyAppModel(tester);

    final Directory cacheDir = await getTemporaryDirectory();
    final File dictFile =
        File('${cacheDir.path}/highlight_span_fixture.zip');
    await _writeHighlightFixture(dictFile);
    final ValueNotifier<String> progress = ValueNotifier<String>('');
    bool imported = false;
    try {
      await appModel.importDictionary(
        file: dictFile,
        progressNotifier: progress,
        onImportSuccess: () => imported = true,
      );
    } finally {
      progress.dispose();
    }
    expect(imported, isTrue, reason: 'fixture 词典必须装上，否则查词恒空、断言无意义');

    // ── 焦点驱动切到词典 tab ──
    expect(await driver.focusWidget(findNavTargetForTab(HomeTab.dictionaries)),
        isTrue,
        reason: '词典 tab 必须能被焦点遍历到');
    await driver.activate();
    await tester.pump(const Duration(seconds: 3));

    // ── 主查词：条上应立刻框住引擎命中的整词（テスト，3 个字）──
    await tester.enterText(findSearchField(), sourceText);
    final HomeDictionarySearchDebug searchDebug =
        tester.state(find.byType(HomeDictionaryPage))
            as HomeDictionarySearchDebug;
    await searchDebug.debugSearch(sourceText, writeHistory: false);
    await tester.pump(const Duration(seconds: 3));

    expect(findDictionaryResultEvidence().evaluate().length, greaterThan(0),
        reason: 'fixture 词典必须真的查得出结果');

    SourceLookupHighlight? currentHighlight() {
      final Finder panel = find.byType(SourceLookupTextPanel);
      if (panel.evaluate().isEmpty) return null;
      return tester.widget<SourceLookupTextPanel>(panel).highlight;
    }

    /// 有界轮询：查词经真 FFI + 弹窗 WebView，是异步的。等的是 [want] **本身**而不是
    /// 「长度够了」——点字先落一个单字的即时反馈再扩成整词，上一轮遗留的跨度也可能
    /// 恰好满足长度下界，按下界等会把旧值/中间值当终值。超时就返回当前值让断言去红。
    Future<SourceLookupHighlight?> settleHighlight(
        SourceLookupHighlight want) async {
      SourceLookupHighlight? last;
      for (int i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        last = currentHighlight();
        if (last == want) return last;
      }
      return last;
    }

    expect(
        await settleHighlight(const SourceLookupHighlight(start: 0, length: 3)),
        const SourceLookupHighlight(start: 0, length: 3),
        reason: '主查词命中「テスト」3 个字，条上就该框住这 3 个字');
    await takeScreenshot(binding, 'source_strip_highlight_tap0');

    // ── 点条上第 i 个字：起点跟着被点的字走，长度跟着引擎走 ──
    //
    // 逐字 span 是没有 FocusNode 的 GestureDetector（焦点驱动到不了），而坐标点击
    // 被仓库规则禁掉，所以这里直调组件对外的 onLookup，参数与生产 `_lookupAt` 逐字
    // 对齐。`_lookupAt` 自己算出的后缀与下标由 widget 测试
    // （clipboard_lookup_text_panel_test.dart「tapping a character looks up the
    // suffix from that character」）钉住，两层合起来覆盖完整路径。
    final List<String> chars = sourceText.characters.toList();
    Future<void> tapChar(int index, int expectedLength) async {
      final SourceLookupTextPanel panel =
          tester.widget<SourceLookupTextPanel>(
              find.byType(SourceLookupTextPanel));
      panel.onLookup(
        chars.skip(index).join(),
        const Rect.fromLTWH(180, 180, 24, 24),
        index,
      );
      await tester.pump();
      final SourceLookupHighlight want =
          SourceLookupHighlight(start: index, length: expectedLength);
      expect(
        await settleHighlight(want),
        want,
        reason: '点第 $index 个字后，条上应框住引擎命中的 $expectedLength 个字',
      );
    }

    await tapChar(1, 2); // 「スト」
    await takeScreenshot(binding, 'source_strip_highlight_tap1');
    await tapChar(2, 1); // 「ト」
    await takeScreenshot(binding, 'source_strip_highlight_tap2');
  });
}
