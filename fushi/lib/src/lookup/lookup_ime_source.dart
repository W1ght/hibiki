/// 查词输入法的两种表达方式：**按语言**和**指定具体输入法**。
///
/// 为什么需要第二种：按语言只能说「切到日语」，**切到哪个日语输入法由系统决定**。
/// 各端实测（2026-09-15）：
///
/// - **Windows**：现代 TSF 输入法根本不注册 HKL（微信输入法 / 微软拼音 / 微软五笔 /
///   日语 MS-IME 的 `hkl` 全是 0），整个语言共用该语言的键盘布局 HKL。所以按语言
///   连「切到系统自带那个」都指定不了——Windows 按「该语言上次用的」自己挑。
/// - **macOS**：同一语言有多个输入源时按枚举顺序取第一个，顺序由系统定、API 不承诺，
///   第三方输入法排在后面就永远轮不到。
/// - **iOS / Android**：公开 API 的天花板就是表达语言（iOS `UITextInputMode` 只暴露
///   `primaryLanguage`；Android 自 9 起切换 API 在调用方进程里直接是 no-op）。这两端
///   [LookupImeSource.selectable] 恒 false，指定了也只是**信息展示**。
library;

import 'package:flutter/foundation.dart';

/// 系统里一个可枚举的输入法 / 输入源。
///
/// [id] 是**平台专属**的（Windows 是 `CLSID:GUID` 组合，macOS 是
/// `kTISPropertyInputSourceID`，Android 是扁平化 ComponentName），所以持久化时必须
/// 连平台一起记，见 `PreferencesRepository.lookupImeSourcePlatform`。
@immutable
class LookupImeSource {
  const LookupImeSource({
    required this.id,
    required this.name,
    required this.languages,
    required this.selectable,
  });

  /// 平台专属标识。跨平台无意义，绝不跨端比较。
  final String id;

  /// 人类可读名（系统给的，跟随系统语言，**不要试图翻译**）。
  final String name;

  /// 该输入源声明的语言（BCP-47 或平台原生写法，交给
  /// `lookupImeLanguageMatches` 归一化比较）。
  final List<String> languages;

  /// 我们能不能真的切到它。false = 只能展示（Android 全部如此；macOS 上
  /// `selCap=false` 的输入法父项也是，那种切过去必然失败）。
  final bool selectable;

  /// 原生侧回来的一条记录；字段不全或 id 为空时返回 null（宁可少一条，
  /// 也不要往列表里塞一个点了没反应的条目）。
  static LookupImeSource? fromMap(Map<Object?, Object?> raw) {
    final Object? id = raw['id'];
    final Object? name = raw['name'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;
    final Object? languages = raw['languages'];
    return LookupImeSource(
      id: id,
      name: name,
      languages: languages is List<Object?>
          ? languages.whereType<String>().toList(growable: false)
          : const <String>[],
      // 没说就是不能选：错报「能选」会让用户点了没反应且无从知道为什么。
      selectable: raw['selectable'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LookupImeSource &&
      other.id == id &&
      other.name == name &&
      other.selectable == selectable &&
      listEquals(other.languages, languages);

  @override
  int get hashCode => Object.hash(id, name, selectable, Object.hashAll(languages));

  @override
  String toString() =>
      'LookupImeSource($id, $name, $languages, selectable: $selectable)';
}

/// 「此刻查词框想要什么输入法」。
///
/// 两个字段都可以有值：[sourceId] 是首选，原生侧发现它已经不在系统里（用户卸载了
/// 那个输入法）时回落到 [language]。回落判断放在原生侧而不是 Dart——只有原生侧知道
/// 当前系统里到底装了什么，Dart 再问一次就是多一轮竞态。
@immutable
class LookupImeRequest {
  const LookupImeRequest({this.language, this.sourceId});

  /// 什么都不要（= 还原用户原来的输入法）。
  static const LookupImeRequest none = LookupImeRequest();

  final String? language;
  final String? sourceId;

  bool get isEmpty =>
      (language == null || language!.isEmpty) &&
      (sourceId == null || sourceId!.isEmpty);

  /// 归一化：空串一律当 null，省得 `''` 和 null 被当成两个不同的请求反复刷 channel。
  LookupImeRequest get normalized => LookupImeRequest(
    language: (language == null || language!.isEmpty) ? null : language,
    sourceId: (sourceId == null || sourceId!.isEmpty) ? null : sourceId,
  );

  Map<String, Object?> toArguments() => <String, Object?>{
    'language': language,
    'sourceId': sourceId,
  };

  @override
  bool operator ==(Object other) =>
      other is LookupImeRequest &&
      other.language == language &&
      other.sourceId == sourceId;

  @override
  int get hashCode => Object.hash(language, sourceId);

  @override
  String toString() => 'LookupImeRequest(language: $language, source: $sourceId)';
}

/// 当前平台的标识，用来给 [LookupImeSource.id] 划定作用域。
///
/// 用 [defaultTargetPlatform] 而不是 `dart:io` 的 `Platform`：前者在 widget 测试里可以
/// 用 `debugDefaultTargetPlatformOverride` 改写，后者不行——「macOS 的 id 恢复到
/// Windows 上要当没设过」这条不变量得能被测试钉住。
String get lookupImePlatformKey {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return 'windows';
    case TargetPlatform.macOS:
      return 'macos';
    case TargetPlatform.linux:
      return 'linux';
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.iOS:
      return 'ios';
    case TargetPlatform.fuchsia:
      return 'fuchsia';
  }
}
