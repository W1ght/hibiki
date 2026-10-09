import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show HomePage, HomeTab;
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart' show readyAppModel, seedDictionary;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-3131 取证探针（真 HID 键，经系统当前输入法）。
///
/// 键盘不走进程内合成：调 Mac 上已获辅助功能授权的 `~/dev/MlifHelper.app`
/// 经 `CGEvent.post(tap: .cghidEventTap)` 投 HID 键，事件从 WindowServer 进来，
/// 走真实的 NSTextInputContext → IMK 输入法链路。
const MethodChannel _input = MethodChannel('app.fushi.test/input');
const Key _kField = ValueKey<String>('home_dictionary_search_field');
const String _kInputSource = String.fromEnvironment(
  'INPUT_SOURCE',
  defaultValue: 'com.apple.keylayout.ABC',
);

final List<String> _textInputLog = <String>[];

Future<Map<Object?, Object?>> _call(
  String method, [
  Map<String, Object?> args = const <String, Object?>{},
]) async {
  final dynamic raw = await _input.invokeMethod<dynamic>(method, args);
  return (raw as Map<Object?, Object?>).cast<Object?, Object?>();
}

String _helper() => '${Platform.environment['HOME']}/dev/MlifHelper.app';

Future<String> _helperRun(List<String> args) async {
  await Process.run('open', <String>['-g', '-W', '-n', _helper(), '--args', ...args]);
  return File(
    '${Platform.environment['HOME']}/dev/mlif-helper.out',
  ).readAsStringSync().trim();
}

/// 投 HID 键（虚拟键码），每键间隔 [gapMs]。helper 跑完才返回；期间 Flutter 照常出帧。
Future<void> _hidKeys(WidgetTester tester, List<int> codes, {int gapMs = 150}) async {
  final Future<String> run = _helperRun(<String>['keys', '$gapMs', codes.join(',')]);
  bool done = false;
  run.then((_) => done = true);
  while (!done) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

String _fieldText(WidgetTester tester) {
  final Finder editable = find.descendant(
    of: find.byKey(_kField),
    matching: find.byType(EditableText),
  );
  return tester.widget<EditableText>(editable.first).controller.text;
}

Future<void> _settle(WidgetTester tester, [int quarters = 8]) async {
  for (int i = 0; i < quarters; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _report(WidgetTester tester, String label) async {
  final Map<Object?, Object?> r = await _call('responder', <String, Object?>{
    'clear': true,
  });
  debugPrint(
    '[hid-probe] $label text="${_fieldText(tester)}" '
    'fr=${r['firstResponder']} key=${r['isKey']} active=${r['isActive']} '
    'ctxCurrent=${r['contextIsCurrent']} curClient=${r['currentContextClient']} '
    'primaryFocus=${FocusManager.instance.primaryFocus?.debugLabel ?? FocusManager.instance.primaryFocus}',
  );
  for (final Object? line in (r['log'] as List<Object?>? ?? <Object?>[])) {
    debugPrint('[hid-probe]   FR-CHANGE $line');
  }
  for (final String line in _textInputLog) {
    debugPrint('[hid-probe]   TI $line');
  }
  _textInputLog.clear();
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('BUG-3131 HID probe', timeout: const Timeout(Duration(minutes: 12)), (
    WidgetTester tester,
  ) async {
    await runFushiItest(
      label: 'hid-probe',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue);
        await readyAppModel(tester);
        expect(await seedDictionary(tester), isTrue);
        HomePage.debugSelectTab!(HomeTab.dictionaries);
        await _settle(tester, 4);

        // 记下 framework → engine 的 TextInput 消息（setClient / show / hide / clearClient）。
        const JSONMethodCodec codec = JSONMethodCodec();
        binding.defaultBinaryMessenger.allMessagesHandler =
            (String channel, MessageHandler? handler, ByteData? message) {
          if (channel == 'flutter/textinput' && message != null) {
            try {
              final MethodCall call = codec.decodeMethodCall(message);
              if (call.method != 'TextInput.setEditableSizeAndTransform' &&
                  call.method != 'TextInput.setCaretRect' &&
                  call.method != 'TextInput.setMarkedTextRect' &&
                  call.method != 'TextInput.setStyle') {
                _textInputLog.add(
                  '${DateTime.now().millisecondsSinceEpoch % 100000} ${call.method}',
                );
              }
            } catch (_) {}
          }
          return binding.defaultBinaryMessenger.delegate.send(channel, message);
        };
        addTearDown(
          () => binding.defaultBinaryMessenger.allMessagesHandler = null,
        );

        debugPrint('[hid-probe] select: ${await _helperRun(<String>['select', _kInputSource])}');
        await _call('activate');
        await tester.pump(const Duration(milliseconds: 800));
        final Rect rect = tester.getRect(find.byKey(_kField).first);
        final Map<Object?, Object?> click = await _call('click', <String, Object?>{
          'x': rect.center.dx,
          'y': rect.center.dy,
        });
        await _settle(tester, 4);
        debugPrint('[hid-probe] click -> $click');
        final EditableTextState editable = tester.state<EditableTextState>(
          find
              .descendant(
                of: find.byKey(_kField),
                matching: find.byType(EditableText),
              )
              .first,
        );
        if (!editable.widget.focusNode.hasFocus) {
          debugPrint('[hid-probe] click missed the field; requestKeyboard()');
          editable.requestKeyboard();
          await _settle(tester, 4);
        }
        await _report(tester, 'focused');

        // 用户录屏的序列：test → 出结果；ststst → 未找到；退格删光 → 空态。
        const int t = 17, e = 14, s = 1, del = 51, ret = 36, shift = 56;
        final List<(String, List<int>)> imeSteps = <(String, List<int>)>[
          ('ime-test-commit', <int>[t, e, s, t, ret]),
          ('ime-st-commit', <int>[s, t, ret]),
          ('ime-s-commit', <int>[s, ret]),
          ('del-7', <int>[del, del, del, del, del, del, del]),
          ('ime-te-commit', <int>[t, e, ret]),
          ('ime-s-only', <int>[s]),
        ];
        final List<(String, List<int>)> shiftSteps = <(String, List<int>)>[
          ('shift-toggle', <int>[shift]),
          ('type-test', <int>[t, e, s, t]),
          ('type-st', <int>[s, t]),
          ('type-s', <int>[s]),
          ('del-7', <int>[del, del, del, del, del, del, del]),
          ('type-te', <int>[t, e]),
          ('shift-toggle-back', <int>[shift]),
        ];
        const String mode = String.fromEnvironment('STEPS');
        for (final (String label, List<int> codes) in mode == 'ime'
            ? imeSteps
            : mode == 'shift'
            ? shiftSteps
            : <(String, List<int>)>[
          ('type-te', <int>[t, e]),
          ('type-st', <int>[s, t]),
          ('type-s', <int>[s]),
          ('type-tst', <int>[t, s, t]),
          ('type-s2', <int>[s]),
          ('del-4', <int>[del, del, del, del]),
          ('del-4b', <int>[del, del, del, del]),
          ('del-2', <int>[del, del]),
          ('type-te-again', <int>[t, e]),
        ]) {
          await _hidKeys(tester, codes);
          await _settle(tester, 8);
          await _report(tester, label);
        }
      },
    );
  });
}
