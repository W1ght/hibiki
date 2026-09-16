/// 把「查词输入框期望的输入法语言」告诉原生侧。
///
/// 为什么是**页面级**而不是焦点级：iOS 的 `textInputMode` 是在输入框成为第一响应者
/// **之前**被读的（Hoshi Reader iOS 为此特意等转场动画结束才抢焦点）。焦点变化 →
/// Dart listener → method channel → 原生，这条链能不能赶在那次读取之前到位是没有保证
/// 的；查词页面则在任何输入框拿到焦点之前很久就 mount 了，时序上稳。
///
/// 代价是粒度粗：页面存续期间，这一页里**所有**输入框都会拿到这个语言提示。查词页面
/// 上除了查词框没有别的输入框，所以目前没有实际影响；将来若要细到单个输入框，得换成
/// 「焦点 + 原生侧按第一响应者身份判定」，不是把这层改细就行。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/lookup/lookup_ime_language.dart';
import 'package:fushi/src/lookup/lookup_ime_source.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

class LookupImeChannel {
  const LookupImeChannel._();

  static const MethodChannel _channel = FushiChannels.lookupIme;

  /// 上一次真正发出去的值，避免同一页反复重建时刷 channel。
  static LookupImeRequest? _lastSent;

  /// 谁还在要什么，按登记顺序排——最后登记的赢。
  ///
  /// 不能只记「上一次发了什么」：桌面上词典主页的搜索框可能正聚焦着（已经切到日语），
  /// 这时打开再关掉弹窗词典，弹窗一句 null 就会把还活着的主页那份也还原掉。注销一个
  /// 请求者之后必须回落到仍然活跃的那个，而不是无条件还原。
  static final Map<Object, LookupImeRequest> _requests =
      <Object, LookupImeRequest>{};

  @visibleForTesting
  static void resetForTesting() {
    _lastSent = null;
    _requests.clear();
  }

  /// 以 [owner] 的名义提出要求；[req] 为 null / 空 = 撤回这个请求者的要求。
  static Future<void> request(Object owner, LookupImeRequest? req) async {
    // 先移除再放回：Map 按插入顺序排，这样重新表达的请求会排到末尾（最后的赢）。
    _requests.remove(owner);
    final LookupImeRequest? normalized = req?.normalized;
    if (normalized != null && !normalized.isEmpty) {
      _requests[owner] = normalized;
    }
    await apply(_requests.isEmpty ? null : _requests.values.last);
  }

  /// 撤回 [owner] 的请求，回落到仍然活跃的那个请求者（没有就还原）。
  static Future<void> release(Object owner) => request(owner, null);

  /// 直接下发一个请求（null / 空 = 不表达偏好，原生侧还原）。
  ///
  /// 常规路径请用 [request]/[release]——它们能处理多个查词入口交叠的情况。
  ///
  /// [LookupImeRequest.sourceId] 与 [LookupImeRequest.language] 一起发下去，由**原生侧**
  /// 决定回落：指定的输入法还在就用它，被用户卸载了就退回按语言匹配。回落判断不放在
  /// Dart——只有原生侧知道此刻系统里装了什么，Dart 再问一次就是多一轮竞态。
  ///
  /// 没有原生实现的平台（目前 Linux）会抛 [MissingPluginException]，这里咽掉：少一次
  /// 输入法切换不该让查词页面开不出来。
  static Future<void> apply(LookupImeRequest? req) async {
    final LookupImeRequest? normalized =
        (req == null || req.normalized.isEmpty) ? null : req.normalized;
    if (normalized == _lastSent) return;
    _lastSent = normalized;
    try {
      final String? status = await _channel.invokeMethod<String>(
        'setLookupIme',
        (normalized ?? LookupImeRequest.none).toArguments(),
      );
      // `"failed"` 是原生侧**正常返回**的一态（不是 PlatformException），所以这里得
      // 自己把去重缓存清掉——否则同一个请求再发一次会被上面那行合并掉，用户重新
      // 聚焦查词框也永远不会重试。`"unavailable"` 不清：那是稳定结论（系统里就是
      // 没装），重试只是白跑。
      if (status == 'failed') _lastSent = null;
    } on MissingPluginException {
      // 该平台还没接原生侧。
    } on PlatformException catch (error) {
      debugPrint('[lookup-ime] setLookupIme failed: $error');
      _lastSent = null;
    }
  }

  /// 只表达语言的便捷形式（集成测试与不支持指定输入法的路径用）。
  static Future<void> setLanguage(String? tag) =>
      apply(LookupImeRequest(language: tag));

  /// 系统里可枚举到的输入法。
  ///
  /// 返回空 list 有两种含义，调用方**不需要**区分：这个平台不支持枚举（iOS——
  /// `UITextInputMode` 公开面只有 `primaryLanguage`，拿不到名字也认不出是哪一家），
  /// 或者确实一个都没枚举到。两种情况 UI 都该退回「只能按语言选」。
  static Future<List<LookupImeSource>> listSources() async {
    try {
      final List<Object?>? raw = await _channel.invokeMethod<List<Object?>>(
        'listInputMethods',
      );
      if (raw == null) return const <LookupImeSource>[];
      return raw
          .whereType<Map<Object?, Object?>>()
          .map(LookupImeSource.fromMap)
          .whereType<LookupImeSource>()
          .toList(growable: false);
    } on MissingPluginException {
      return const <LookupImeSource>[];
    } on PlatformException catch (error) {
      debugPrint('[lookup-ime] listInputMethods failed: $error');
      return const <LookupImeSource>[];
    }
  }

  /// 拉起系统的「选择输入法」弹窗（只有 Android 有）。
  ///
  /// 这是 Android 上**普通应用唯一合法的切输入法入口**——自 Android 9 起
  /// `InputMethodManager.setInputMethod` 在调用方进程里直接是 no-op（token registry 是
  /// 进程内 WeakHashMap，只有输入法服务自己能往里放），不是权限差一点。代价是它**全局
  /// 生效**且要用户动手，所以只能做成显式动作，不能塞进自动路径。
  ///
  /// 返回 false = 这个平台没有这个入口，或系统拒绝了（非前台等）。
  static Future<bool> showSystemPicker() async {
    try {
      return await _channel.invokeMethod<bool>('showInputMethodPicker') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('[lookup-ime] showInputMethodPicker failed: $error');
      return false;
    }
  }

  /// 把用户选的语言**存**给原生查词界面用，不切换任何输入法。
  ///
  /// Android 的悬浮词典与弹窗词典搜索框是原生 EditText（不是 Flutter TextField，
  /// 吃不到 hintLocales 参数），而且它们可能在任何 Flutter 查词页面打开之前就被拉
  /// 起——所以不能等 [request]，必须在偏好变更时和启动时各存一次。
  ///
  /// 桌面/iOS 没有实现这个方法（它们靠 [request] 真的切输入法），静默跳过。
  static Future<void> persistForNativeSurfaces(String? tag) async {
    try {
      await _channel.invokeMethod<void>('persistLanguage', tag ?? '');
    } on MissingPluginException {
      // 该平台没有原生查词输入框需要这个值。
    } on PlatformException catch (error) {
      debugPrint('[lookup-ime] persistLanguage failed: $error');
    }
  }

  /// 系统里有没有这个语言的输入法可用。
  ///
  /// 拿不到原生探针时返回 true（「没有证据说不可用」）：Android 走的是
  /// `hintLocales` 提示，本来就不需要我们判断有没有装；Linux 还没接原生侧。宁可
  /// 不提示，也不要对着一个其实能用的语言报「不可用」。
  static Future<bool> isLanguageAvailable(String tag) async {
    if (tag.isEmpty) return true;
    final Map<String, Object?>? info = await probe();
    if (info == null) return true;
    final List<Object?>? enabled = info['enabledLanguages'] as List<Object?>?;
    if (enabled == null) return true;
    return enabled.any(
      (Object? candidate) =>
          candidate is String && lookupImeLanguageMatches(tag, candidate),
    );
  }

  /// 原生侧探针：`installed` / `desired` / `resolveCount` / `lastResolved` /
  /// `activeInputModes`。用来分辨「属性没被调用」与「调用了但系统没采纳返回值」——
  /// 这两种失败的修法完全不同。没有原生实现时返回 null。
  static Future<Map<String, Object?>?> probe() async {
    try {
      final Map<Object?, Object?>? raw = await _channel
          .invokeMethod<Map<Object?, Object?>>('probe');
      if (raw == null) return null;
      return raw.map(
        (Object? key, Object? value) =>
            MapEntry<String, Object?>(key?.toString() ?? '', value),
      );
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('[lookup-ime] probe failed: $error');
      return null;
    }
  }
}
