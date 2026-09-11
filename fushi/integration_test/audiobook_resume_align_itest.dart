import 'dart:async' show unawaited;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi/i18n/strings.g.dart' show t;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage, charCountsFromChaptersJson;
import 'package:fushi/src/pages/implementations/statistics_center_page.dart'
    show StatisticsCenterPage;
import 'package:fushi/src/stats/study_diag_log.dart' show StudyDiagLog;
import 'package:fushi_audio/fushi_audio.dart'
    show
        AudioCue,
        AudiobookRepository,
        ReaderPosition,
        ReaderPositionRepository,
        SubtitleRematchCodec;
import 'package:fushi_core/fushi_core.dart'
    show EpubBookRow, FushiDatabase, StudySegmentsCompanion, kActivityMediaBook;

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, seedAudiobook;
import 'helpers/media_fixtures.dart' show buildSampleCues, kFixtureChapterHref;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// BUG-2462（用户 2026-09-12：「书重新打开有可能和有声书阅读进度错误，可能落在当前
/// 进度前面但是有声书在后面，一旦播放就会跨了很多页导致阅读速度和阅读量异常」）
/// + 统计中心「每小时字数」（顶部方框 + 每个会话）真 app 三段：
///
///   A. 音频位置比正文位置新（退书后台续听的形态：正文位置停在 5%，音频 3 秒后写到
///      第 90 句 ≈ 90%）→ 重开书，**不按播放**，正文起点就已在音频处：落库的阅读位置
///      收敛到 ≈ 90%，诊断流水记 `resume from audio cue … (audio position newer)`。
///   B. 负向对照：正文位置更新（用户静读到 5%，音频还在 90%）→ 重开书保留 5%，
///      流水记 `audioNewer=false`。
///   C. 播种一段 30 分钟 / 6000 字的会话 → 统计中心总览顶部卡与会话行都显示
///      `12000 字/时`（i18n `stat_speed_cph`）。
///
/// 三端同一份（Windows 离屏 runner / Mac 跨机 / iOS 模拟器）。cue 用 sasayaki 编码
/// 片段（`fushi-cue://s=0&ns=…`）让 cue → 正文位置精确可解（生产 EPUB+音频匹配后
/// 就是这种 cue）；没有精确映射的 cue（旧 `[data-cue-id]`）只知道章，同章不换起点。
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
      debugPrint(
        '[resume-align] $label ready after ${i * step.inMilliseconds}ms',
      );
      return;
    }
  }
  fail(
    '$label did not become ready within ${maxPolls * step.inMilliseconds}ms',
  );
}

Future<void> _closeReader(WidgetTester tester) async {
  if (_readerPageGone()) return;
  Navigator.of(tester.element(find.byType(ReaderFushiPage))).pop();
  await _waitFor(tester, _readerPageGone, 'reader closed', maxPolls: 40);
  await tester.pump(const Duration(seconds: 1));
}

/// 开书 → 等正文就绪 → 等落库的阅读位置满足 [accept]（恢复后的首次
/// `_refreshProgress` 500ms 去抖落库）。返回最后读到的位置。
Future<ReaderPosition?> _openAndSettle(
  WidgetTester tester,
  String bookKey,
  ReaderPositionRepository positions,
  String uid,
  bool Function(ReaderPosition pos) accept,
  String label,
) async {
  await openBookViaProductionPath(tester, bookKey);
  await _waitFor(tester, _webViewShown, '$label WebView');
  await _waitFor(tester, _contentReady, '$label content');
  ReaderPosition? last;
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    last = await positions.findByBookUid(uid);
    if (last != null && accept(last)) break;
  }
  debugPrint(
    '[resume-align] $label persisted position: section=${last?.sectionIndex} '
    'norm=${last?.normCharOffset} charOffset=${last?.charOffset}',
  );
  // 取证：WebView 侧视口 / 重锚旗 / 进度快照原文（Mac 隐藏窗口下 WebKit 的
  // innerWidth/innerHeight 可能为 0，进度快照随之为空，位置便不会落库）。
  final Future<dynamic> Function(String)? runJs =
      ReaderFushiPage.debugEvaluateJavascript;
  if (runJs != null) {
    try {
      final Object? probe = await runJs(_kViewportProbeJs);
      debugPrint('[resume-align] $label webview probe: $probe');
      // rAF 是否在跑（重锚旗只在 rAF 回调里清）：先武装，1s 后读计数。
      await runJs(_kArmTimersJs);
      await tester.pump(const Duration(seconds: 1));
      final Object? timers = await runJs(_kReadTimersJs);
      debugPrint('[resume-align] $label webview timers: $timers');
    } catch (e) {
      debugPrint('[resume-align] $label webview probe failed: $e');
    }
  }
  return last;
}

const String _kArmTimersJs = r'''
(function () {
  window.__fushiRafTicks = 0; window.__fushiTimeoutTicks = 0;
  var step = function () { window.__fushiRafTicks++; if (window.__fushiRafTicks < 30) requestAnimationFrame(step); };
  requestAnimationFrame(step);
  setTimeout(function () { window.__fushiTimeoutTicks++; }, 50);
  return 'armed';
})()
''';

const String _kReadTimersJs = r'''
JSON.stringify({raf: window.__fushiRafTicks, timeout: window.__fushiTimeoutTicks, hidden: document.hidden, vis: document.visibilityState})
''';

const String _kViewportProbeJs = r'''
(function () {
  var r = window.fushiReader;
  var details = '';
  try { details = window.fushiProgressDetails ? String(window.fushiProgressDetails()) : 'no-fn'; } catch (e) { details = 'err:' + e; }
  var p = -1;
  try { p = r && r.calculateProgress ? r.calculateProgress() : -1; } catch (e) { p = 'err:' + e; }
  return JSON.stringify({
    innerW: window.innerWidth, innerH: window.innerHeight,
    clientW: document.documentElement.clientWidth, clientH: document.documentElement.clientHeight,
    pending: !!(r && r._reanchorPending === true),
    progress: p, details: details,
    scrollW: document.documentElement.scrollWidth, scrollH: document.documentElement.scrollHeight
  });
})()
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'BUG-2462: reopening converges the reader to a newer audiobook position; '
    'stats center shows chars/hour on period cards and session rows',
    timeout: const Timeout(Duration(minutes: 12)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'resume-align',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue, reason: 'home must render');
          await tester.pump(const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);
          final FushiDatabase db = appModel.database;

          const int cueCount = 100;
          final String bookKey = await seedAudiobook(
            tester,
            title: 'BUG-2462 Resume Align',
            audioDuration: const Duration(seconds: 260),
            cueCount: cueCount,
          );
          final EpubBookRow? row = await db.getEpubBook(bookKey);
          expect(row, isNotNull);
          final String uid = row!.uid;
          final List<int>? counts = charCountsFromChaptersJson(
            row.chaptersJson,
            row.chapterCount,
          );
          expect(counts, isNotNull, reason: '导入应落每章字数（当前口径）');
          final int chapterChars = counts!.first;
          debugPrint(
            '[resume-align] book=$bookKey uid=$uid chars=$chapterChars',
          );
          expect(chapterChars, greaterThan(1200), reason: '要能隔开 ≥ 600 字');

          // cue → 正文精确映射：第 i 句落在章内 i/cueCount 处。
          final List<AudioCue> cues = buildSampleCues(
            bookKey: bookKey,
            chapterHref: kFixtureChapterHref,
            count: cueCount,
          );
          for (int i = 0; i < cues.length; i++) {
            final int ns = (i * chapterChars / cueCount).floor();
            cues[i].textFragmentId = SubtitleRematchCodec.encodeHit(
              sectionIndex: 0,
              normCharStart: ns,
              normCharEnd: ns + 10,
            );
          }
          final AudiobookRepository audio = AudiobookRepository(db);
          await audio.saveCues(bookKey: bookKey, cues: cues);
          await audio.updateFollowAudio(bookKey: bookKey, value: true);
          final ReaderPositionRepository positions = ReaderPositionRepository(
            db,
          );

          try {
            // ── B. 正文更新 → 保留正文位置 ────────────────────────────────
            await positions.save(
              bookUid: uid,
              sectionIndex: 0,
              normCharOffset: 500,
              charOffset: null,
            );
            final int traceB = StudyDiagLog.instance.lines.length;
            final int savedAtB = (await positions.findByBookUid(uid))!.updatedAt;
            final ReaderPosition? posB = await _openAndSettle(
              tester,
              bookKey,
              positions,
              uid,
              (ReaderPosition p) =>
                  p.updatedAt > savedAtB && p.normCharOffset < 2500,
              'B',
            );
            expect(posB, isNotNull);
            expect(
              posB!.normCharOffset,
              lessThan(2500),
              reason: '正文位置更新时不得被旧音频位置拽走',
            );
            expect(
              StudyDiagLog.instance.lines
                  .skip(traceB)
                  .any((String l) => l.contains('audioNewer=false')),
              isTrue,
            );
            await _closeReader(tester);

            // ── A. 音频更新 → 重开书起点在音频处 ──────────────────────────
            await tester.pump(const Duration(milliseconds: 500));
            await positions.save(
              bookUid: uid,
              sectionIndex: 0,
              normCharOffset: 500,
              charOffset: null,
            );
            // 超过对账宽限（3s）：模拟退书后音频继续走了很久。
            await tester.pump(const Duration(milliseconds: 3500));
            const int audioCue = 90;
            await audio.updatePositionMs(
              bookKey: bookKey,
              positionMs: cues[audioCue].startMs + 100,
            );
            final int traceBefore = StudyDiagLog.instance.lines.length;

            final ReaderPosition? posA = await _openAndSettle(
              tester,
              bookKey,
              positions,
              uid,
              (ReaderPosition p) => p.normCharOffset > 5000,
              'A',
            );
            expect(posA, isNotNull);
            expect(
              posA!.normCharOffset,
              greaterThan(5000),
              reason: '正文起点必须已在音频处（≈ 90%），不是停在旧的 5%',
            );
            expect(
              appModel.audiobookSession.controller?.isPlaying ?? false,
              isFalse,
              reason: '对账不触发播放',
            );
            // 像素证据：重开后正文已在音频处（WebView 截图）+ Flutter 帧。
            final ObserveShot webA = await captureReaderWebView(
              'resume-a-reader-webview',
            );
            final ObserveShot frameA = await captureFlutterFrame(
              tester,
              'resume-a-reader-frame',
            );
            debugPrint(
              '[resume-align] A shots webview=${webA.saved}/${webA.nonBlank} '
              'frame=${frameA.saved}/${frameA.nonBlank}',
            );
            final List<String> traceA = StudyDiagLog.instance.lines
                .skip(traceBefore)
                .toList();
            expect(
              traceA.any(
                (String l) =>
                    l.contains('resume from audio cue chapter=0') &&
                    l.contains('(audio position newer)'),
              ),
              isTrue,
              reason: '诊断流水必须记下这次对账决策\n${traceA.join('\n')}',
            );
            await _closeReader(tester);

            // ── C. 统计中心：顶部卡 + 会话行的字/时 ──────────────────────
            final DateTime now = DateTime.now();
            final DateTime start = now.subtract(const Duration(minutes: 30));
            await db.upsertStudySegment(
              StudySegmentsCompanion(
                uid: const Value('itest-bug2462-seg'),
                deviceId: Value(await db.getOrCreateStudyDeviceId()),
                mediaKind: const Value(kActivityMediaBook),
                mediaKey: Value(bookKey),
                format: const Value('epub'),
                title: const Value('BUG-2462 Resume Align'),
                startAt: Value(start.millisecondsSinceEpoch),
                endAt: Value(now.millisecondsSinceEpoch),
                dateKey: Value(FushiDatabase.statDateKeyOf(start)),
                hour: Value(start.hour),
                durationMs: const Value(30 * 60000),
                chars: const Value(6000),
                pages: const Value(0),
                updatedAt: Value(now.millisecondsSinceEpoch),
              ),
            );
            final NavigatorState nav = appModel.navigatorKey.currentState!;
            unawaited(
              nav.push(
                MaterialPageRoute<void>(
                  builder: (BuildContext _) => const StatisticsCenterPage(),
                ),
              ),
            );
            final String cph = t.stat_speed_cph(n: '12000');
            await _waitFor(
              tester,
              () => find.textContaining(cph).evaluate().length >= 2,
              'stats center cph ($cph)',
              maxPolls: 40,
            );
            // 时段卡的副行渲染成 `阅读速度: 12000 字/时`（四张卡都含今日，至少一张）；
            // 会话行的量纲串 `… · 6000 字 · 12000 字/时` 不带标签。
            final String cardLine = '${t.stat_reading_speed}: $cph';
            expect(
              find.textContaining(cardLine),
              findsWidgets,
              reason: '顶部时段卡必须显示阅读速度行',
            );
            final ObserveShot statsShot = await captureFlutterFrame(
              tester,
              'stats-center-cph',
            );
            debugPrint(
              '[resume-align] stats shot saved=${statsShot.saved} '
              'nonBlank=${statsShot.nonBlank} path=${statsShot.path}',
            );
            final Finder sessionRow = find.byWidgetPredicate((Widget w) {
              if (w is! Text) return false;
              final String? data = w.data;
              return data != null &&
                  data.contains(cph) &&
                  !data.contains(t.stat_reading_speed);
            });
            expect(
              sessionRow,
              findsWidgets,
              reason: '会话行末尾必须带 12000 字/时',
            );
            nav.pop();
            await tester.pump(const Duration(seconds: 1));
          } finally {
            await _closeReader(tester);
          }
        },
      );
    },
  );
}
