import Carbon
import Cocoa

/// 查词输入框的输入法（macOS）。
///
/// macOS 的输入法是**系统全局**状态（TISSelectInputSource 切的是整个系统的当前输入
/// 源），所以和 Windows 一样有两条硬约束：
///
/// 1) 只在**已启用**的输入源里找（TISCreateInputSourceList 第二参 false）。用户没
///    启用的输入源不该被我们替他打开——那是改系统配置。
/// 2) 必须记住原来的输入源并还原，否则用户切到别的 app 打字也会是日语。
///
/// ## 为什么要能「指定具体输入源」而不只是指定语言
///
/// 按语言匹配只能说「切到日语」，切到**哪个**日语输入法由枚举顺序决定，而
/// `TISCreateInputSourceList` 的顺序由系统定、API 不承诺。第三方输入法（实测：
/// 腾讯微信输入法 `com.tencent.inputmethod.wetype.pinyin`，TIS 对它和 Apple 自带的
/// 零区别对待）排在后面就永远轮不到。所以 setLookupIme 收 `sourceId`（=
/// `kTISPropertyInputSourceID`）作首选，`language` 只作它失效时的回落。
///
/// 唯一标识必须用 `kTISPropertyInputSourceID` 而**不是 bundleID**：一个输入法的父项
/// 与它所有 mode 子项共享同一个 bundleID，bundleID 定位不到「能被选中的那一个」。
/// sourceID 由 IME bundle 的 `Info.plist` `ComponentInputModeDict` 确定性推导，不含
/// 随机量，跨重启稳定，可以直接持久化到偏好里。
///
/// ## 实测出来的三条坑（2026-09-16，macOS 27）
///
/// - **枚举污染**：同一进程里只要调过一次 `TISCreateInputSourceList(filter, true)`
///   （列全部**已安装**），此后所有 `false` 调用会被**永久**污染（实测 5 条变 9 条，
///   多出来的 4 条实际选不中，返回 -50）。所以本文件任何地方都不得传 true。
/// - **父项切不动**：`kTISTypeKeyboardInputMethodModeEnabled` 类型的父项（如
///   `com.apple.inputmethod.Kotoeri.RomajiTyping`、`com.tencent.inputmethod.wetype`）
///   也带 languages，会被语言匹配命中，但它们 `selCap == false`，
///   `TISSelectInputSource` 返回 -50。只有 `kTISTypeKeyboardInputMode` 子项和
///   `kTISTypeKeyboardLayout` 能真的被选中。旧实现完全没做 type/selCap 过滤，靠的是
///   「那台机器上每个 IME 的 mode 子项恰好排在父项前面」——是运气不是保证。
/// - **`IsEnabled` / `IsSelectCapable` 单独任何一个都不能预测能否切换**。可靠判据是
///   「在从未调用过 all:true 的进程里出现在 `TISCreateInputSourceList(filter, false)`
///   里 **且** selCap == true 且 type 属于上面两种」——即 `isSelectable(_:)`。
///
/// 另：别读 `~/Library/Preferences/com.apple.HIToolbox.plist`，它和 TIS 的实时视图
/// 不一致，TIS 才是真相。也绝不调 `TISEnableInputSource`——那是替用户改系统配置。
///
/// 沙盒说明：沙盒下 TISSelectInputSource 有「菜单栏图标变了、实际没切」的已知问题。
/// 本 app 的 Release.entitlements 为了自动更新已经去掉 app-sandbox，正好避开；
/// 如果哪天沙盒回来了，这条路要重新验证。
enum LookupImeLanguage {
  /// 进入查词前的输入源，用于还原。nil = 当前没切过。
  private static var previousSource: TISInputSource?
  private static var appliedSource: TISInputSource?

  static var isActive: Bool { appliedSource != nil }

  /// 切到请求的输入源。两个参数都空 = 还原。
  ///
  /// 优先级：`sourceId` 命中 → 用它；`sourceId` 落空（用户卸载/停用了那个输入法）
  /// → 回落按 `language` 匹配；都落空 → "unavailable"。回落判断只能在这里做，
  /// Dart 侧再问一次系统就是多一轮竞态。
  ///
  /// 返回 "applied" / "unchanged" / "unavailable" / "failed"，语义与 Windows 侧一致。
  @discardableResult
  static func apply(language: String?, sourceId: String?) -> String {
    let tag = nonEmpty(language)
    let wantedId = nonEmpty(sourceId)
    guard tag != nil || wantedId != nil else {
      return restore()
    }
    guard let target = resolveTarget(tag: tag, sourceId: wantedId) else {
      // 指定的输入法不在（或没启用），语言也没有对应输入法。静默不动——绝不替他启用。
      return "unavailable"
    }
    if let applied = appliedSource, sameSource(applied, target) {
      return "unchanged"
    }
    if previousSource == nil {
      // 第一次切换才记原输入源：查词页面之间来回跳时，原输入源必须一直是
      // 「进入查词前」那个，而不是上一次我们自己切过去的那个。
      previousSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }
    guard TISSelectInputSource(target) == noErr else {
      return "failed"
    }
    appliedSource = target
    return "applied"
  }

  @discardableResult
  static func restore() -> String {
    guard appliedSource != nil else {
      return "unchanged"
    }
    defer {
      appliedSource = nil
      previousSource = nil
    }
    guard let previous = previousSource else {
      // 记不住原输入源时不乱猜一个切过去。
      return "unchanged"
    }
    return TISSelectInputSource(previous) == noErr ? "applied" : "failed"
  }

  /// 解析「这次要切到哪个输入源」。只在**可选中**的集合里找，见 `isSelectable(_:)`。
  static func resolveTarget(tag: String?, sourceId: String?) -> TISInputSource? {
    let candidates = selectableSources()
    if let sourceId,
      let exact = candidates.first(where: { self.sourceId(of: $0) == sourceId })
    {
      return exact
    }
    guard let tag else { return nil }
    return firstSource(matching: tag, among: candidates)
  }

  /// 已启用且可选中的输入源里，主语言匹配 tag 的第一个。
  static func enabledKeyboardSource(matching tag: String) -> TISInputSource? {
    return firstSource(matching: tag, among: selectableSources())
  }

  /// 给设置页列「可以指定的输入法」。
  ///
  /// 只列**已启用**的（第二参 false，理由见类型注释的「枚举污染」），并且**必须**
  /// 滤掉 `selCap == false` 的父项——父项与它的 mode 子项 LocalizedName 完全相同，
  /// 不滤就会出现两条一模一样的「微信输入法」，用户点到父项那条会静默失败（-50）。
  static func listInputSources() -> [[String: Any]] {
    var result: [[String: Any]] = []
    for source in selectableSources() {
      guard let id = sourceId(of: source), !id.isEmpty else { continue }
      guard let name = localizedName(of: source), !name.isEmpty else { continue }
      result.append([
        "id": id,
        "name": name,
        "languages": languages(of: source),
        // 走到这里的都过了 isSelectable，恒 true；保留字段是为了跨端形状一致
        // （Android / iOS 那边是恒 false 的信息展示）。
        "selectable": true,
      ])
    }
    return result
  }

  /// 探针：给集成测试分辨「没装这个语言」和「装了但没切成功」。
  static func probeInfo() -> [String: Any] {
    let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    return [
      "installed": true,
      "active": isActive,
      "currentLanguages": current.map(languages(of:)) ?? [],
      // 与切换路径同一口径：不可选中的父项声明的语言不算「可用」，否则设置页会
      // 对着一个点了必然失败的语言显示「可用」。
      "enabledLanguages": selectableSources().flatMap(languages(of:)),
    ]
  }

  // MARK: - 输入源枚举与过滤

  private static func enabledKeyboardSources() -> [TISInputSource] {
    let filter =
      [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource]
      as CFDictionary
    // 第二参 false = 只要**已启用**的，不含仅安装未启用的。
    // 绝对不能传 true：一次 true 会永久污染本进程后续所有 false 调用（见类型注释）。
    guard
      let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
        as? [TISInputSource]
    else {
      return []
    }
    return list
  }

  /// 真的能被 `TISSelectInputSource` 选中的输入源。
  ///
  /// 两道门缺一不可：type 必须是 mode 子项或键盘布局（父项
  /// `kTISTypeKeyboardInputMethodModeEnabled` 恒 -50），且 selCap 为真。
  private static func isSelectable(_ source: TISInputSource) -> Bool {
    guard let type = stringProperty(source, kTISPropertyInputSourceType) else {
      return false
    }
    guard
      type == (kTISTypeKeyboardInputMode as String)
        || type == (kTISTypeKeyboardLayout as String)
    else {
      return false
    }
    return boolProperty(source, kTISPropertyInputSourceIsSelectCapable)
  }

  private static func isKeyboardLayout(_ source: TISInputSource) -> Bool {
    return stringProperty(source, kTISPropertyInputSourceType)
      == (kTISTypeKeyboardLayout as String)
  }

  private static func selectableSources() -> [TISInputSource] {
    return enabledKeyboardSources().filter(isSelectable)
  }

  /// 按语言找输入源：**真输入法优先，纯键盘布局垫底**。
  ///
  /// 为什么要这条排序：`com.apple.keylayout.ABC` 这种纯键盘布局声明了 **95 种语言**
  /// （en, ca, da, de, es, fr, it, nl, pt, sv, id, ms…）而且恒排在枚举最前面。不排序
  /// 的话，用户选「德语」会静默切到一个只是能打拉丁字母的键盘布局，而不是德语输入
  /// 法——症状是「切了但输入法没变」，比报 unavailable 还难查。现在设置页只开放 5 种
  /// 语言所以碰不到，但那是定时炸弹。用两轮遍历而不是给每个源算权重再排序，是为了
  /// 保住系统枚举顺序在同一档内的原样（同档内仍是第一个赢）。
  private static func firstSource(
    matching tag: String, among candidates: [TISInputSource]
  ) -> TISInputSource? {
    for wantLayout in [false, true] {
      for source in candidates where isKeyboardLayout(source) == wantLayout {
        for language in languages(of: source)
        where matches(tag: tag, sourceLanguage: language) {
          return source
        }
      }
    }
    return nil
  }

  // MARK: - 属性读取

  private static func languages(of source: TISInputSource) -> [String] {
    guard
      let pointer = TISGetInputSourceProperty(
        source, kTISPropertyInputSourceLanguages)
    else {
      return []
    }
    return Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue()
      as? [String] ?? []
  }

  private static func stringProperty(
    _ source: TISInputSource, _ key: CFString!
  ) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, key) else {
      return nil
    }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
  }

  private static func boolProperty(
    _ source: TISInputSource, _ key: CFString!
  ) -> Bool {
    guard let pointer = TISGetInputSourceProperty(source, key) else {
      return false
    }
    return CFBooleanGetValue(
      Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
  }

  private static func sourceId(of source: TISInputSource) -> String? {
    return stringProperty(source, kTISPropertyInputSourceID)
  }

  private static func localizedName(of source: TISInputSource) -> String? {
    return stringProperty(source, kTISPropertyLocalizedName)
  }

  private static func sameSource(_ a: TISInputSource, _ b: TISInputSource) -> Bool {
    return sourceId(of: a) == sourceId(of: b)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  /// BCP-47 标签与输入源语言是否算同一种。
  ///
  /// 中文简繁要分开（装了拼音打不出繁体）；其它语言只比主语言，地区变体不挑
  /// （en-GB 还是 en-US 都能打英文）。
  static func matches(tag: String, sourceLanguage: String) -> Bool {
    let wanted = tag.lowercased()
    let candidate = sourceLanguage.lowercased()
    guard let wantedPrimary = wanted.split(separator: "-").first,
      let candidatePrimary = candidate.split(separator: "-").first,
      wantedPrimary == candidatePrimary
    else {
      return false
    }
    if wantedPrimary != "zh" {
      return true
    }
    let wantedScript = chineseScript(of: wanted)
    if wantedScript == 0 {
      return true
    }
    return wantedScript == chineseScript(of: candidate)
  }

  /// 0 = 没说，1 = 简体，2 = 繁体。
  private static func chineseScript(of tag: String) -> Int {
    if tag.contains("hans") || tag.contains("-cn") || tag.contains("-sg") {
      return 1
    }
    if tag.contains("hant") || tag.contains("-tw") || tag.contains("-hk")
      || tag.contains("-mo")
    {
      return 2
    }
    return 0
  }
}
