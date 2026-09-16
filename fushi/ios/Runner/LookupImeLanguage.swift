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
/// **能做到的上限就是「表达语言」，选不了「是哪一家键盘」。**运行期
/// `class_copyPropertyList(UITextInputMode.self)` 实测公开面只有 `primaryLanguage`
/// 一个属性；能区分系统日语键盘与 Gboard 日语的 `identifier` / `displayName` 全是
/// 私有 API，用了会被审核 2.5.1 拒。第三方键盘用户的出路是把「查词输入法语言」设成
/// **未设置**：那时我们不指定任何键盘，而 [contextIdentifier] 仍然生效，系统就会记住
/// 他自己在查词框里选的那个键盘并一直用它。
///
/// 曾经试过「监听 `currentInputModeDidChangeNotification` 判断用户是不是自己换了键盘，
/// 换了就不再强推」——**这条路是死的，别再走**：① `UITextInputMode.current` 在 Swift
/// 里不可用（iOS 7 起废弃并标 unavailable）；② 唯一的公开替代 `UIResponder.textInputMode`
/// 正是我们自己用 `class_addMethod` 盖住的那个属性，读回来只会读到我们自己的返回值；
/// ③ 实测第一条通知在 `textInputMode` 首次被读**之前**就到（键盘首次弹出时），那时
/// `lastResolved` 还是 nil，任何判据都会把它误判成「用户换的」。
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
      // **恒返回**，与有没有语言偏好无关：没偏好时 resolveInputMode() 返回 nil、
      // 我们不指定任何键盘，这时上下文身份正好让系统去记住用户自己在查词框里用的
      // 那个（含第三方）。这就是「查词输入法语言」设为「未设置」时的实际行为。
      contextIdentifier as NSString
    }
    if !class_addMethod(
      cls,
      contextSelector,
      imp_implementationWithBlock(contextBlock),
      "@@:"
    ) {
      NSLog("[lookup-ime] FlutterTextInputView already implements textInputContextIdentifier")
    }
    installed = true
    return true
  }

  /// 在已启用的输入法里找期望语言；找不到返回 nil = 让系统自己决定。
  private static func resolveInputMode() -> UITextInputMode? {
    resolveCount += 1
    guard let wanted = desiredLanguage, !wanted.isEmpty else {
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
