/// Physical Android UI talks to the isolated Windows player's LAN listener.
/// The Windows fixture uses real mpv/ffmpeg and an isolated FakeAnkiConnect.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:fushi/src/pages/implementations/video_remote_page.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_client.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi_core/fushi_core.dart';

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const String hostUrl = String.fromEnvironment('VIDEO_REMOTE_HOST_URL');
  const String token = 'video-remote-integration-paired-token';
  const int soakSeconds = int.fromEnvironment('VIDEO_REMOTE_SOAK_SECONDS');
  testWidgets('Android controls real fullscreen Windows player over LAN', (
    WidgetTester tester,
  ) async {
    expect(
      hostUrl,
      isNotEmpty,
      reason: 'Start the isolated Windows hold fixture',
    );
    expect(Platform.isAndroid, isTrue, reason: 'This validates Android UI');
    LocaleSettings.setLocale(AppLocale.en);
    final FushiDatabase database = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    final SyncRepository repository = SyncRepository(database);
    final FushiClientUrl peer = FushiClientUrl(
      url: hostUrl,
      hostId: 'isolated-windows-video',
      token: token,
    );
    final VideoRemoteClient probe = VideoRemoteClient(
      repository: repository,
      peer: peer,
    );
    addTearDown(() async {
      probe.cancelPending();
      await database.close();
    });
    await tester.runAsync(
      () => repository.setFushiClientUrls(<FushiClientUrl>[peer]),
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: VideoRemotePage(repository: repository, peer: peer),
        ),
      ),
    );
    await _wait(
      tester,
      () => find.byType(SubtitleTranscriptText).evaluate().isNotEmpty,
    );
    final FocusDriver driver = FocusDriver(tester);
    expect(
      await driver.focusWidget(find.byTooltip(t.video_remote_favorites).first),
      isTrue,
    );
    await driver.activate();
    await _waitRemote(
      tester,
      probe,
      'favorites',
      (Map<String, dynamic> value) => (value['items'] as List).any(
        (dynamic item) => item['text'] == '猫がいる',
      ),
    );
    final ObserveShot initial = await captureFlutterFrame(
      tester,
      'lan-phone-subtitles',
    );
    expect(initial.saved && initial.nonBlank, isTrue);
    expect(
      await driver.focusWidget(find.byType(SubtitleTranscriptText).first),
      isTrue,
    );
    await driver.activate();
    await _wait(tester, () => find.text('猫 ねこ').evaluate().isNotEmpty);
    await _waitRemote(
      tester,
      probe,
      'snapshot',
      (Map<String, dynamic> value) => value['playing'] == false,
    );
    expect(
      await driver.focusWidget(find.widgetWithText(FushiListItem, '猫 ねこ')),
      isTrue,
    );
    await driver.activate();
    await _wait(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
    // The desktop surrogate already mined 猫. A unique field avoids duplicates
    // while retaining the actual selected sentence/audio/image extraction.
    await tester.enterText(
      find.widgetWithText(FushiTextField, t.video_remote_expression),
      'remote_phone_cat',
    );
    expect(
      await driver.focusWidget(
        find.widgetWithText(FushiTextButton, t.video_remote_mine),
      ),
      isTrue,
    );
    await driver.activate();
    await _wait(
      tester,
      () => find.text(t.video_remote_mined).evaluate().isNotEmpty,
      seconds: 120,
    );
    final ObserveShot mined = await captureFlutterFrame(
      tester,
      'lan-phone-mined',
    );
    expect(mined.saved && mined.nonBlank, isTrue);
    expect(
      await driver.focusWidget(
        find.widgetWithText(FushiTextButton, t.dialog_close),
      ),
      isTrue,
    );
    await driver.activate();
    await _waitRemote(
      tester,
      probe,
      'snapshot',
      (Map<String, dynamic> value) => value['playing'] == true,
    );
    expect(
      await driver.focusWidget(find.text(t.video_remote_favorites)),
      isTrue,
    );
    await driver.activate();
    await _wait(
      tester,
      () => find.byType(FushiCheckboxListTile).evaluate().isNotEmpty,
    );
    expect(
      await driver.focusWidget(find.byType(FushiCheckboxListTile).first),
      isTrue,
    );
    await driver.activate();
    expect(
      await driver.focusWidget(
        find.widgetWithText(FushiTextButton, t.video_remote_remove),
      ),
      isTrue,
    );
    await driver.activate();
    await _waitRemote(
      tester,
      probe,
      'favorites',
      (Map<String, dynamic> value) => (value['items'] as List).isEmpty,
    );
    expect(
      await driver.focusWidget(find.text(t.video_remote_subtitles)),
      isTrue,
    );
    await driver.activate();
    debugPrint(
      '[video-remote-lan] Android UI learning and favorites passed; FakeAnkiConnect=true',
    );

    if (soakSeconds > 0) {
      final List<int> rasterUs = <int>[];
      int slowFrames = 0;
      void record(List<FrameTiming> frames) {
        for (final FrameTiming frame in frames) {
          rasterUs.add(frame.rasterDuration.inMicroseconds);
          if (frame.totalSpan.inMicroseconds > 16667) slowFrames++;
        }
      }

      SchedulerBinding.instance.addTimingsCallback(record);
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
      final Stopwatch wall = Stopwatch()..start();
      try {
        while (wall.elapsed.inSeconds < soakSeconds) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(seconds: 1)),
          );
          await tester.pump();
        }
      } finally {
        SchedulerBinding.instance.removeTimingsCallback(record);
      }
      rasterUs.sort();
      debugPrint(
        '[video-remote-lan] soak seconds=${wall.elapsed.inSeconds} '
        'frames=${rasterUs.length} slowFrames=$slowFrames '
        'rasterP95Us=${rasterUs.isEmpty ? 0 : rasterUs[((rasterUs.length - 1) * .95).floor()]}',
      );
      // One UI style, USB charging and profile/debug builds are distinct evidence.
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
  }, timeout: const Timeout(Duration(minutes: 45)));
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() ready, {
  int seconds = 30,
}) async {
  final Stopwatch wall = Stopwatch()..start();
  while (!ready() && wall.elapsed.inSeconds < seconds) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue);
}

Future<void> _waitRemote(
  WidgetTester tester,
  VideoRemoteClient client,
  String operation,
  bool Function(Map<String, dynamic>) ready,
) async {
  Map<String, dynamic> value = <String, dynamic>{};
  final Stopwatch wall = Stopwatch()..start();
  do {
    value = (await tester.runAsync(() => client.call(operation)))!;
    if (ready(value)) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  } while (wall.elapsed.inSeconds < 30);
  expect(ready(value), isTrue, reason: '$operation: $value');
}
