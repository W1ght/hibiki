import ObjectiveC
import UIKit

/// 查词输入框的输入法语言（iOS）。
///
/// iOS 不让应用切换系统输入法，能做的只有告诉键盘「这个输入框期望哪种语言」——
/// 靠 `UIResponder.textInputMode` 返回 `UITextInputMode.activeInputModes` 里匹配的
/// 那一项（用户必须已在系统里装了那种键盘，否则只能回退）。Hoshi Reader iOS 就是
/// 这么做的（`CustomSearchField.swift`：自己的 UITextField 子类 override 该属性）。
///
/// 我们没有自己的 UITextField：Flutter 的第一响应者是引擎私有类
/// `FlutterTextInputView`。它自己不实现 `textInputMode`（继承 UIResponder 的默认
/// 实现），所以这里用 runtime 给它**新增**一个实现，而不是 swizzle 交换——
/// `class_addMethod` 在该类已自带实现时会返回 false，我们就原样退出，绝不覆盖引擎
/// 自己的行为。类名找不到（引擎改名/换实现）同样静默退出：少一次键盘语言切换，
/// 不该让输入功能出问题。
///
/// 已知风险（spike 要验的就是这条）：flutter/flutter#53614 报告过 iOS 13 起
/// swizzle 这个属性「方法还会被调用，但返回值被忽略」。Hoshi 在自己的子类上是有效
/// 的，差别可能在于谁拥有第一响应者、以及取值时机（`textInputMode` 在
/// becomeFirstResponder **之前**被读——Hoshi 特意等转场动画结束才抢焦点）。
enum LookupImeLanguage {
  /// 期望的语言（BCP-47 主子标签，如 `ja`）。nil = 不表达偏好，走系统默认。
  static var desiredLanguage: String?

  /// 命中次数与最后一次返回值——spike 阶段用来分辨「没被调用」和
  /// 「被调用了但系统没采纳」，这两种失败的修法完全不同。
  private(set) static var resolveCount: Int = 0
  private(set) static var lastResolved: String?

  private static var installed = false

  /// 用户是不是在查词框里**自己**换过键盘。
  ///
  /// 换过之后我们就不再强推 [resolveInputMode] 的结果，把选择权交还给系统的
  /// 「记住这个输入上下文用的键盘」机制（见 [contextIdentifier]）。这是 iOS 上
  /// **第三方键盘用户唯一能被照顾到的路径**：`UITextInputMode` 公开面只有
  /// `primaryLanguage`，我们认不出 Gboard / Simeji 是哪一家，更选不中它们；但只要
  /// 用户自己在查词框里切过去一次，系统就会在这个上下文里一直用它。
  ///
  /// 落 `UserDefaults` 而不是只留在内存：这条偏好的意义就是**跨启动**记住。
  private static let overrideDefaultsKey = "app.fushi.lookupIme.userOverrode"
  private static var userOverrode: Bool {
    get { UserDefaults.standard.bool(forKey: overrideDefaultsKey) }
    set { UserDefaults.standard.set(newValue, forKey: overrideDefaultsKey) }
  }

  /// 查词输入上下文的身份。
  ///
  /// `UIResponder.textInputContextIdentifier` 非 nil 时，系统会**按这个身份记住用户
  /// 上次用的键盘**，下次进同一个上下文自动用回来（Apple DTS 推荐的正是这条；他们
  /// 同时明说「把整个 app 的输入法换掉更像是用户的决定，所以平台不提供那种 API」）。
  /// 常量字符串即可——我们只有查词这一个上下文。
  static let contextIdentifier = "app.fushi.lookup"

  /// 给 `FlutterTextInputView` 装上 `textInputMode` 与 `textInputContextIdentifier`。
  /// 在 app 启动时调一次。
  @discardableResult
  static func install() -> Bool {
    if installed { return true }
    guard let cls = NSClassFromString("FlutterTextInputView") else {
      NSLog("[lookup-ime] FlutterTextInputView not found; skipping")
      return false
    }
    let selector = #selector(getter: UIResponder.textInputMode)
    let block: @convention(block) (AnyObject) -> UITextInputMode? = { _ in
      resolveInputMode()
    }
    let added = class_addMethod(
      cls,
      selector,
      imp_implementationWithBlock(block),
      "@@:"
    )
    if !added {
      // 引擎自己实现了这个属性——它比我们更懂该返回什么，让位。
      NSLog("[lookup-ime] FlutterTextInputView already implements textInputMode; skipping")
      return false
    }
    // 同样用**新增**而不是交换：引擎自己实现了就让位。装不上只是少了「记住用户
    // 选的键盘」，`textInputMode` 那条路不受影响，所以不因此返回 false。
    let contextSelector = #selector(getter: UIResponder.textInputContextIdentifier)
    let contextBlock: @convention(block) (AnyObject) -> NSString? = { _ in
      // 没有任何偏好时返回 nil = 完全不介入，维持系统默认行为。
      desiredLanguage == nil ? nil : contextIdentifier as NSString
    }
    if !class_addMethod(
      cls,
      contextSelector,
      imp_implementationWithBlock(contextBlock),
      "@@:"
    ) {
      NSLog("[lookup-ime] FlutterTextInputView already implements textInputContextIdentifier")
    }
    observeUserKeyboardSwitch()
    installed = true
    return true
  }

  /// 盯着「当前输入法变了」：如果变成的不是我们指定的那个，说明是**用户自己换的**，
  /// 此后不再强推。
  ///
  /// 只在有偏好时才记账——没偏好时我们本来就不介入，用户换键盘与我们无关。
  private static func observeUserKeyboardSwitch() {
    NotificationCenter.default.addObserver(
      forName: UITextInputMode.currentInputModeDidChangeNotification,
      object: nil,
      queue: .main
    ) { _ in
      guard desiredLanguage != nil, !userOverrode else { return }
      guard let current = UITextInputMode.current?.primaryLanguage else { return }
      // 和我们最后一次返回的那个一致 = 这次变化就是我们造成的，不算用户覆盖。
      if current != lastResolved {
        userOverrode = true
        NSLog("[lookup-ime] user picked \(current) in the lookup field; deferring to it")
      }
    }
  }

  /// 仅测试可见：把「用户覆盖」状态清掉，让探针能重复跑。
  static func resetUserOverrideForTesting() {
    userOverrode = false
  }

  /// 仅探针可见：当前是否处于「让位给用户选择」的状态。
  static var isDeferringToUser: Bool { userOverrode }

  /// 在已启用的输入法里找期望语言；找不到返回 nil = 让系统自己决定。
  private static func resolveInputMode() -> UITextInputMode? {
    resolveCount += 1
    guard let wanted = desiredLanguage, !wanted.isEmpty else {
      lastResolved = nil
      return nil
    }
    if userOverrode {
      // 用户在查词框里自己换过键盘。返回 nil = 不指定，由系统按
      // `textInputContextIdentifier` 记住的那个来——那才可能是他装的第三方键盘。
      lastResolved = nil
      return nil
    }
    for mode in UITextInputMode.activeInputModes {
      guard let language = mode.primaryLanguage else { continue }
      // 前缀匹配：系统给的是 `ja-JP` / `zh-Hans` 这类完整标签。
      if language == wanted || language.hasPrefix("\(wanted)-") {
        lastResolved = language
        return mode
      }
    }
    lastResolved = nil
    return nil
  }
}
