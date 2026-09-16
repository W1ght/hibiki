import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/lookup_ime_channel.dart';
import 'package:fushi/src/lookup/lookup_ime_source.dart';
import 'package:fushi/src/lookup/lookup_ime_source_picker.dart';

/// 「指定具体输入法」这一层的契约。
///
/// 这层的价值全在**不猜**：id 是平台专属的，认不出的记录宁可丢掉也不能塞进列表让
/// 用户点了没反应；平台对不上的持久化值宁可当没设过，也不能拿去跟原生侧对。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LookupImeSource.fromMap', () {
    test('缺 id 或缺 name 的记录一律丢掉', () {
      expect(
        LookupImeSource.fromMap(<Object?, Object?>{'name': '微软拼音'}),
        isNull,
      );
      expect(
        LookupImeSource.fromMap(<Object?, Object?>{'id': 'tsf:0804:x'}),
        isNull,
      );
      expect(
        LookupImeSource.fromMap(<Object?, Object?>{'id': '', 'name': 'x'}),
        isNull,
        reason: '空 id 选不中任何东西，列出来只会让用户点了没反应',
      );
    });

    test('selectable 没说就是不能选', () {
      final LookupImeSource? source = LookupImeSource.fromMap(
        <Object?, Object?>{'id': 'a', 'name': 'b'},
      );
      expect(source, isNotNull);
      expect(
        source!.selectable,
        isFalse,
        reason: '错报「能选」比漏报糟：用户点了没反应且无从知道为什么',
      );
      expect(source.languages, isEmpty);
    });

    test('languages 里的非字符串被剔掉而不是让整条作废', () {
      final LookupImeSource? source = LookupImeSource.fromMap(
        <Object?, Object?>{
          'id': 'a',
          'name': 'b',
          'languages': <Object?>['ja', 42, null, 'en'],
          'selectable': true,
        },
      );
      expect(source!.languages, <String>['ja', 'en']);
      expect(source.selectable, isTrue);
    });
  });

  group('LookupImeRequest', () {
    test('空串与 null 归一成同一个值——否则会反复刷 channel', () {
      expect(
        const LookupImeRequest(language: '', sourceId: '').normalized,
        const LookupImeRequest(),
      );
      expect(const LookupImeRequest(language: '').normalized.isEmpty, isTrue);
    });

    test('toArguments 两个字段都发下去，回落由原生侧决定', () {
      expect(
        const LookupImeRequest(language: 'ja', sourceId: 'x').toArguments(),
        <String, Object?>{'language': 'ja', 'sourceId': 'x'},
      );
    });
  });

  group('平台作用域', () {
    test('各端 key 互不相同——id 跨端比较是无意义的', () {
      final Set<String> keys = <String>{};
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        keys.add(lookupImePlatformKey);
      }
      debugDefaultTargetPlatformOverride = null;
      expect(keys.length, 5);
    });
  });

  group('选择器排序与语言判定', () {
    const LookupImeSource ja = LookupImeSource(
      id: 'ja',
      name: '微软输入法',
      languages: <String>['ja-JP'],
      selectable: true,
    );
    const LookupImeSource zhHans = LookupImeSource(
      id: 'zh',
      name: '微信输入法',
      languages: <String>['zh-Hans'],
      selectable: true,
    );
    const LookupImeSource en = LookupImeSource(
      id: 'en',
      name: 'English (US)',
      languages: <String>['en-US'],
      selectable: true,
    );

    test('中文简繁不互通——装了拼音打不出繁体', () {
      expect(lookupImeSourceSupportsLanguage(zhHans, 'zh-Hans'), isTrue);
      expect(lookupImeSourceSupportsLanguage(zhHans, 'zh-Hant'), isFalse);
      expect(
        lookupImeSourceSupportsLanguage(zhHans, 'zh'),
        isTrue,
        reason: '裸 zh 没说简繁，不该挑',
      );
    });

    test('地区变体不挑——en-GB 和 en-US 都能打英文', () {
      expect(lookupImeSourceSupportsLanguage(en, 'en'), isTrue);
      expect(lookupImeSourceSupportsLanguage(ja, 'ja'), isTrue);
      expect(lookupImeSourceSupportsLanguage(ja, 'ko'), isFalse);
    });

    test('支持目标语言的排前面，其余保持系统给的原顺序', () {
      final List<LookupImeSource> sorted = sortLookupImeSources(
        <LookupImeSource>[en, zhHans, ja],
        'ja',
      );
      expect(sorted.first, ja);
      expect(
        sorted.sublist(1),
        <LookupImeSource>[en, zhHans],
        reason: '不是字母排序——重排会让用户找不到他在系统设置里熟悉的次序',
      );
    });

    test('没有语言偏好时不重排', () {
      expect(
        sortLookupImeSources(<LookupImeSource>[en, zhHans, ja], null),
        <LookupImeSource>[en, zhHans, ja],
      );
    });
  });

  group('channel', () {
    const MethodChannel channel = MethodChannel('app.fushi.reader/lookup_ime');
    late List<MethodCall> calls;
    late String status;

    setUp(() {
      calls = <MethodCall>[];
      status = 'applied';
      LookupImeChannel.resetForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            if (call.method == 'listInputMethods') {
              return <Object?>[
                <Object?, Object?>{
                  'id': 'tsf:0411:{A}:{B}',
                  'name': '微软输入法',
                  'languages': <Object?>['ja-JP'],
                  'selectable': true,
                },
                // 缺 name：原生侧偶发的坏记录，不能进列表。
                <Object?, Object?>{'id': 'broken'},
              ];
            }
            return status;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('listSources 丢掉坏记录而不是整批失败', () async {
      final List<LookupImeSource> sources =
          await LookupImeChannel.listSources();
      expect(sources.length, 1);
      expect(sources.single.name, '微软输入法');
    });

    test('apply 把 language 与 sourceId 一起发下去', () async {
      await LookupImeChannel.apply(
        const LookupImeRequest(language: 'ja', sourceId: 'x'),
      );
      expect(calls.single.method, 'setLookupIme');
      expect(calls.single.arguments, <String, Object?>{
        'language': 'ja',
        'sourceId': 'x',
      });
    });

    test('重复的同一请求被合并，不重复刷 channel', () async {
      await LookupImeChannel.apply(const LookupImeRequest(language: 'ja'));
      await LookupImeChannel.apply(const LookupImeRequest(language: 'ja'));
      expect(calls.length, 1);
    });

    test('"failed" 之后同样的请求要能重试', () async {
      status = 'failed';
      await LookupImeChannel.apply(const LookupImeRequest(language: 'ja'));
      await LookupImeChannel.apply(const LookupImeRequest(language: 'ja'));
      expect(
        calls.length,
        2,
        reason: 'failed 是原生侧正常返回的一态，去重缓存必须清掉才可能重试',
      );
    });

    test('"unavailable" 是稳定结论，不必重试', () async {
      status = 'unavailable';
      await LookupImeChannel.apply(const LookupImeRequest(language: 'ja'));
      await LookupImeChannel.apply(const LookupImeRequest(language: 'ja'));
      expect(
        calls.length,
        1,
        reason: '系统里就是没装，重发只是白跑一轮',
      );
    });

    test('多个查词入口交叠时，注销一个要回落到仍然活跃的那个', () async {
      final Object home = Object();
      final Object popup = Object();
      await LookupImeChannel.request(
        home,
        const LookupImeRequest(language: 'ja'),
      );
      await LookupImeChannel.request(
        popup,
        const LookupImeRequest(language: 'ko'),
      );
      await LookupImeChannel.release(popup);
      expect(
        (calls.last.arguments as Map<Object?, Object?>)['language'],
        'ja',
        reason: '弹窗只能撤回自己那份，不能把主页还开着的一起还原',
      );
    });
  });
}
