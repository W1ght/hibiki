import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

/// 探针（不入 PR）：裸 TextField，经测试钩子投 NSEvent 键，配合 FUSHI_IMK_PROBE 打点。
const MethodChannel _input = MethodChannel('app.fushi.test/input');
const Map<String, int> _kVk = <String, int>{
  'a': 0, 'h': 4, 'i': 34, 'n': 45, 'o': 31,
};

Future<dynamic> _call(String m, [Map<String, Object?> a = const {}]) =>
    _input.invokeMethod<dynamic>(m, a);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('IME key path probe', (WidgetTester tester) async {
    final TextEditingController c = TextEditingController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 400, child: TextField(controller: c)),
        ),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    await _call('activate');
    await tester.pump(const Duration(milliseconds: 800));
    tester.state<EditableTextState>(find.byType(EditableText)).requestKeyboard();
    await tester.pump(const Duration(milliseconds: 800));
    for (final String ch in 'nihao'.split('')) {
      await _call('key', {'keyCode': _kVk[ch]!, 'chars': ch});
    }
    await _call('key', {'keyCode': 49, 'chars': ' '});
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    debugPrint('[ime-probe] final="${c.value.text}|${c.value.composing}"');
    // 留出时间给真人 / HID 助手在此窗口里打字（WAIT_MS）。
    const int waitMs = int.fromEnvironment('WAIT_MS');
    for (int i = 0; i < waitMs ~/ 250; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    debugPrint('[ime-probe] after-wait="${c.value.text}|${c.value.composing}"');
  });
}
