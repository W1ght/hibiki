// 探针：视频播放器快捷键改绑后是否**不重启**即生效（用户报「改了要整个重启 Fushi
// 才生效」）。真 Windows app 上跑原始路径：
//
//   ① 开视频、默认键 D（videoSeekForward）真能推进播放位置（基线，防假绿）；
//   ② 播放中把 videoSeekForward 改绑成 U（与设置页同一条写穿路径：
//      updateBindingWithReassignments → saveShortcutRegistry）；
//   ③ 按 U → 位置应推进；按 D → 位置**不该**再推进；
//   ④ 退出视频页再重开，重复 ③（改绑是否跨页面生命周期生效）。
//
// 运行：fushi/ 下
//   .\tool\run_windows_itest.ps1 integration_test/video_shortcut_rebind_live_itest.dart
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_preferences.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi_core/fushi_core.dart';

import 'test_helpers.dart';

const String _kVideoFixture = r'D:\hibiki_video_test\sample.mp4';
const String _kVideoBookUid = 'video/shortcut-rebind-itest-sample';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'probe: video shortcut rebind applies without restart',
    (WidgetTester tester) async {
      final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        errors.add(details);
        debugPrint('[rebind] ${details.exceptionAsString()}');
      };
      FushiShortcutRegistry? registry;
      try {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue);
        await tester.pump(const Duration(seconds: 2));

        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp).first),
        );
        final AppModel appModel = container.read(appProvider);
        registry = appModel.shortcutRegistry;
        final VideoBookRepository repo = VideoBookRepository(appModel.database);

        final File fixture = File(_kVideoFixture);
        expect(
          fixture.existsSync(),
          isTrue,
          reason: '测试视频 $_kVideoFixture 应存在',
        );
        await repo.saveVideoBook(
          VideoBooksCompanion(
            bookUid: const Value(_kVideoBookUid),
            title: const Value('rebind itest'),
            videoPath: Value(fixture.absolute.path),
          ),
        );

        final NavigatorState navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );

        VideoFushiTestHooks hooks() =>
            tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
                as VideoFushiTestHooks;

        Future<void> openVideo() async {
          unawaited(
            navigator.push<void>(
              MaterialPageRoute<void>(
                builder: (_) =>
                    VideoFushiPage(bookUid: _kVideoBookUid, repo: repo),
              ),
            ),
          );
          bool ready = false;
          for (int i = 0; i < 60; i++) {
            await tester.pump(const Duration(milliseconds: 250));
            if (find.byType(VideoFushiPage).evaluate().isNotEmpty &&
                hooks().debugPositionMs != null) {
              ready = true;
              break;
            }
          }
          expect(ready, isTrue, reason: 'video controller should load');
          await tester.pump(const Duration(seconds: 1));
          final FocusNode videoNode = tester
              .widget<Video>(find.byType(Video))
              .focusNode!;
          for (int i = 0; i < 20 && !videoNode.hasFocus; i++) {
            videoNode.requestFocus();
            await tester.pump(const Duration(milliseconds: 150));
          }
          debugPrint(
            '[rebind] videoNode.hasFocus=${videoNode.hasFocus} '
            'primaryFocus=${FocusManager.instance.primaryFocus?.debugLabel}',
          );
        }

        Future<void> closeVideo() async {
          navigator.pop();
          for (int i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 250));
            if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
          }
          expect(find.byType(VideoFushiPage), findsNothing);
          await tester.pump(const Duration(seconds: 1));
        }

        /// 按一次 [key]，返回位置变化量（ms）。先暂停播放，避免自然推进混淆判据。
        Future<int> deltaAfterPress(LogicalKeyboardKey key) async {
          final int before = hooks().debugPositionMs!;
          await tester.sendKeyEvent(key);
          for (int i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 200));
          }
          final int after = hooks().debugPositionMs!;
          debugPrint('[rebind] press ${key.keyLabel}: $before -> $after');
          return after - before;
        }

        // 暂停，让位置只由 seek 改变。videoTogglePlayPause 默认含 Space；这里直接
        // 用 hooks 不可得，走快捷键 P（默认也绑 togglePlayPause）。
        Future<void> ensurePaused() async {
          // 观察两次采样：若在动就按 P。
          final int a = hooks().debugPositionMs!;
          await tester.pump(const Duration(milliseconds: 600));
          final int b = hooks().debugPositionMs!;
          if (b != a) {
            await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
            await tester.pump(const Duration(milliseconds: 600));
          }
          final int c = hooks().debugPositionMs!;
          await tester.pump(const Duration(milliseconds: 600));
          final int d = hooks().debugPositionMs!;
          debugPrint('[rebind] paused check: $a,$b -> $c,$d');
          expect(d, c, reason: '应已暂停（位置不再自然推进）');
        }

        await openVideo();
        await ensurePaused();

        // ① 基线：默认 D 推进。
        final int baseD = await deltaAfterPress(LogicalKeyboardKey.keyD);
        expect(baseD > 0, isTrue, reason: '基线：默认键 D 应推进播放位置');
        final int baseU = await deltaAfterPress(LogicalKeyboardKey.keyU);
        expect(baseU, 0, reason: '基线：U 未绑定，不该改位置');

        // ② 改绑（与设置页同路径）：videoSeekForward ← 仅 U。
        registry.updateBindingWithReassignments(
          ShortcutAction.videoSeekForward,
          const ShortcutBindingSet(
            keyboardBindings: <InputBinding>[
              InputBinding(key: LogicalKeyboardKey.keyU),
            ],
          ),
        );
        await saveShortcutRegistry(registry, ReaderFushiSource.instance);
        debugPrint(
          '[rebind] registry now: '
          '${registry.bindingsFor(ShortcutAction.videoSeekForward)}',
        );

        // ③ 同一页面内。
        final int liveU = await deltaAfterPress(LogicalKeyboardKey.keyU);
        final int liveD = await deltaAfterPress(LogicalKeyboardKey.keyD);
        debugPrint('[rebind] same-page: U=$liveU D=$liveD');

        // ④ 重开页面。
        await closeVideo();
        await openVideo();
        await ensurePaused();
        final int reopenU = await deltaAfterPress(LogicalKeyboardKey.keyU);
        final int reopenD = await deltaAfterPress(LogicalKeyboardKey.keyD);
        debugPrint('[rebind] reopened: U=$reopenU D=$reopenD');
        await closeVideo();

        debugPrint(
          '[rebind] RESULT same-page U>0=${liveU > 0} D==0=${liveD == 0}; '
          'reopened U>0=${reopenU > 0} D==0=${reopenD == 0}',
        );
        expect(liveU > 0, isTrue, reason: '同页：新键 U 应立即生效');
        expect(liveD, 0, reason: '同页：旧键 D 应立即失效');
        expect(reopenU > 0, isTrue, reason: '重开：新键 U 应生效');
        expect(reopenD, 0, reason: '重开：旧键 D 应失效');

        expect(
          errors,
          isEmpty,
          reason: errors.map((e) => e.exceptionAsString()).join('\n'),
        );
      } finally {
        FlutterError.onError = oldHandler;
        try {
          if (registry != null) {
            registry.resetScopeToDefaults(
              ShortcutScope.video,
              defaultTargetPlatform,
            );
            await saveShortcutRegistry(registry, ReaderFushiSource.instance);
          }
          final ProviderContainer container = ProviderScope.containerOf(
            tester.element(find.byType(MaterialApp).first),
          );
          final FushiDatabase db = container.read(appProvider).database;
          await (db.delete(
            db.videoBooks,
          )..where((VideoBooks t) => t.bookUid.equals(_kVideoBookUid))).go();
        } catch (_) {}
      }
    },
    skip: !Platform.isWindows,
  );
}
