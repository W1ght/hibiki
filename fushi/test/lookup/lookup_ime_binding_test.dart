import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/lookup_ime_binding.dart';
import 'package:fushi/src/lookup/lookup_ime_channel.dart';

/// 输入法语言绑定的行为契约。最要紧的是**还原**：桌面端切的是系统全局输入法，
/// 漏掉一次还原，用户去别的应用打字就会发现自己在打日语。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('app.fushi.reader/lookup_ime');
  late List<Object?> sent;

  setUp(() {
    sent = <Object?>[];
    LookupImeChannel.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'setLanguage') {
            sent.add(call.arguments);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('attach 立刻告知语言——iOS 要在任何聚焦之前就设好', () async {
    final LookupImeBinding binding = LookupImeBinding(languageOf: () => 'ja');
    binding.attach();
    await Future<void>.delayed(Duration.zero);
    expect(sent, <Object?>['ja']);
  });

  test('detach 必须还原，否则系统输入法留在我们切过去的语言上', () async {
    final LookupImeBinding binding = LookupImeBinding(languageOf: () => 'ja');
    binding.attach();
    await Future<void>.delayed(Duration.zero);
    binding.detach();
    await Future<void>.delayed(Duration.zero);
    expect(sent, <Object?>['ja', null]);
  });

  testWidgets('焦点离开查词框就还原，回来再设上', (WidgetTester tester) async {
    final FocusNode focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      Focus(focusNode: focusNode, child: const SizedBox.shrink()),
    );

    final LookupImeBinding binding = LookupImeBinding(languageOf: () => 'ja');
    binding.attach(focusNode: focusNode);
    await tester.pump();
    expect(sent, <Object?>['ja'], reason: 'attach 时先设上');

    focusNode.requestFocus();
    await tester.pump();
    expect(sent, <Object?>['ja'], reason: '已经是这个语言了，不该重复打扰系统');

    focusNode.unfocus();
    await tester.pump();
    expect(sent, <Object?>['ja', null], reason: '焦点离开查词框必须还原——桌面端切的是系统全局输入法');

    focusNode.requestFocus();
    await tester.pump();
    expect(sent, <Object?>['ja', null, 'ja'], reason: '回到查词框再设上');
  });

  test('未设置语言时发 null，不发空串', () async {
    final LookupImeBinding binding = LookupImeBinding(languageOf: () => null);
    binding.attach();
    await Future<void>.delayed(Duration.zero);
    // 去重：null 是初始状态，什么都不该发。
    expect(sent, isEmpty);
  });

  test('每次同步都重新取值——用户可能在查词页面开着时改了设置', () async {
    String? current = 'ja';
    final LookupImeBinding binding = LookupImeBinding(
      languageOf: () => current,
    );
    binding.attach();
    await Future<void>.delayed(Duration.zero);
    current = 'ko';
    binding.detach();
    await Future<void>.delayed(Duration.zero);
    binding.attach();
    await Future<void>.delayed(Duration.zero);
    expect(sent, <Object?>['ja', null, 'ko']);
  });
}
