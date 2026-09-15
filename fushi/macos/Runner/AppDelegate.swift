import ApplicationServices
import Cocoa
import FlutterMacOS
import macos_window_utils

@main
class AppDelegate: FlutterAppDelegate, FlutterStreamHandler {
  private var activeSecurityScopedURLs: [String: URL] = [:]
  private var challengeBrowser: FushiChallengeBrowser?
  private var globalLookupOverlay: GlobalLookupOverlayController?
  /// Dart 最后一次表达的查词输入法语言。app 重新回到前台时按它再切回去——否则
  /// 用户 Cmd-Tab 出去一趟回来，查词页面还开着但输入法已经不是他选的那个了。
  private var desiredLookupImeTag: String?

  override func applicationDidResignActive(_ notification: Notification) {
    // 离开前台就把用户的输入法放回去：切的是系统全局输入源，留着会漏到别的 app。
    LookupImeLanguage.restore()
    super.applicationDidResignActive(notification)
  }

  override func applicationDidBecomeActive(_ notification: Notification) {
    super.applicationDidBecomeActive(notification)
    if let tag = desiredLookupImeTag {
      LookupImeLanguage.setLanguage(tag)
    }
  }
  private var pendingSourceUrls: [String] = []
  private var sourceUrlEventSink: FlutterEventSink?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let windowController =
        mainFlutterWindow?.contentViewController as? MacOSWindowUtilsViewController {
      let controller = windowController.flutterViewController
      let sourceUrlChannel = FlutterEventChannel(
        name: "app.fushi.reader/source_urls/stream",
        binaryMessenger: controller.engine.binaryMessenger)
      sourceUrlChannel.setStreamHandler(self)
      challengeBrowser = FushiChallengeBrowser(
        binaryMessenger: controller.engine.binaryMessenger
      ) { [weak self] in self?.mainFlutterWindow }
      let channel = FlutterMethodChannel(
        name: "app.fushi/data_root_access",
        binaryMessenger: controller.engine.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleDataRootAccess(call, result: result)
      }

      // TODO-1030 M1 -- macOS Accessibility (AX) foreground-selection context
      // capture channel. Symmetric to the Windows UIA channel of the same name
      // (windows/runner/flutter_window.cpp RegisterForegroundSelectionChannel):
      // Dart (selection_capture_ffi.dart) calls `captureContext` when the global
      // lookup pref opts into context capture, and reuses the shared pure-Dart
      // sentence trimmer. A failure returns null so Dart falls back to the
      // clipboard capture (never break the existing lookup path).
      let foregroundSelectionChannel = FlutterMethodChannel(
        name: "app.fushi.reader/foreground_selection",
        binaryMessenger: controller.engine.binaryMessenger)
      foregroundSelectionChannel.setMethodCallHandler { call, result in
        AppDelegate.handleForegroundSelection(call, result: result)
      }

      // 查词输入框的输入法语言。macOS 的输入源是系统全局状态，所以除了「切过去」
      // 还必须「切回来」——页面走掉时 Dart 发 null，app 失去前台时我们自己还原
      // （见 applicationDidResignActive）。
      let lookupImeChannel = FlutterMethodChannel(
        name: "app.fushi.reader/lookup_ime",
        binaryMessenger: controller.engine.binaryMessenger)
      lookupImeChannel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "setLanguage":
          let tag = call.arguments as? String
          self?.desiredLookupImeTag = (tag?.isEmpty ?? true) ? nil : tag
          result(LookupImeLanguage.setLanguage(tag))
        case "probe":
          result(LookupImeLanguage.probeInfo())
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      // App-external global lookup overlay (macOS counterpart of the Windows
      // GlobalLookupWindow + RegisterGlobalLookupChannel): same
      // `app.fushi.reader/global_lookup` MethodChannel contract, hosted by a
      // non-activating NSPanel + WKWebView. See GlobalLookupOverlay.swift.
      globalLookupOverlay = GlobalLookupOverlayController(
        binaryMessenger: controller.engine.binaryMessenger
      ) { [weak self] in self?.mainFlutterWindow }
    } else {
      NSLog("[Fushi] macOS Flutter controller unavailable; custom channels were not registered")
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    // Launch Services may deliver before the engine/channel exists. Keep source
    // links until Dart subscribes; other schemes/hosts still reach plugins.
    var remainingUrls: [URL] = []
    for url in urls {
      guard url.scheme?.lowercased() == "fushi",
        url.host?.lowercased() == "source" else {
        remainingUrls.append(url)
        continue
      }
      if let sink = sourceUrlEventSink {
        sink(url.absoluteString)
      } else {
        pendingSourceUrls.append(url.absoluteString)
      }
    }
    if !remainingUrls.isEmpty {
      super.application(application, open: remainingUrls)
    }
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sourceUrlEventSink = events
    let pending = pendingSourceUrls
    pendingSourceUrls.removeAll()
    for url in pending {
      events(url)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sourceUrlEventSink = nil
    return nil
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    for url in activeSecurityScopedURLs.values {
      url.stopAccessingSecurityScopedResource()
    }
    activeSecurityScopedURLs.removeAll()
    super.applicationWillTerminate(notification)
  }

  private func handleDataRootAccess(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(
        code: "bad_args",
        message: "Missing data root access arguments",
        details: nil))
      return
    }

    switch call.method {
    case "createBookmark":
      guard let path = args["path"] as? String, !path.isEmpty else {
        result(FlutterError(code: "bad_path", message: "Missing path", details: nil))
        return
      }
      do {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
          if didStart {
            url.stopAccessingSecurityScopedResource()
          }
        }
        let data = try url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil)
        result(data.base64EncodedString())
      } catch {
        result(FlutterError(
          code: "bookmark_failed",
          message: "Failed to create data root bookmark",
          details: error.localizedDescription))
      }

    case "startAccessingBookmark":
      guard let encoded = args["bookmark"] as? String,
            let data = Data(base64Encoded: encoded) else {
        result(FlutterError(code: "bad_bookmark", message: "Invalid bookmark", details: nil))
        return
      }
      do {
        var stale = false
        let url = try URL(
          resolvingBookmarkData: data,
          options: [.withSecurityScope],
          relativeTo: nil,
          bookmarkDataIsStale: &stale)
        let key = url.path
        if activeSecurityScopedURLs[key] == nil {
          let ok = url.startAccessingSecurityScopedResource()
          guard ok else {
            result(FlutterError(
              code: "access_denied",
              message: "Failed to access security-scoped data root",
              details: key))
            return
          }
          activeSecurityScopedURLs[key] = url
        }
        result(["path": key, "stale": stale])
      } catch {
        result(FlutterError(
          code: "resolve_failed",
          message: "Failed to resolve data root bookmark",
          details: error.localizedDescription))
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // TODO-1030 M1 -- macOS AX foreground-selection context capture handler.
  // The cross-process Accessibility read can block, so it runs off the main
  // thread and the FlutterResult is completed back on the main (platform)
  // thread. On any miss it replies nil so Dart falls back to the clipboard
  // capture. Static so the channel closure never retains the AppDelegate.
  private static func handleForegroundSelection(
    _ call: FlutterMethodCall, result: @escaping FlutterResult
  ) {
    guard call.method == "captureContext" else {
      // captureSelection / isAccessibilityTrusted / requestAccessibilityTrust
      // (the clipboard-style fallback + the settings-page permission action)
      // live in SelectionCaptureMac.swift on this same channel.
      if MacSelectionCapture.handle(call, result: result) {
        return
      }
      result(FlutterMethodNotImplemented)
      return
    }
    let args = call.arguments as? [String: Any]
    let maxExpand = (args?["maxExpand"] as? Int) ?? ForegroundSelectionCapture.defaultExpand
    DispatchQueue.global(qos: .userInitiated).async {
      let start = DispatchTime.now()
      let capture = ForegroundSelectionCapture.capture(maxExpand: maxExpand)
      let elapsedMs = Int(
        (DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
      DispatchQueue.main.async {
        guard let capture = capture else {
          // No AX text / no permission / non-text focus: Dart falls back.
          result(nil)
          return
        }
        // Privacy: never carry body text into logs here; only the map crosses
        // the channel. Offsets are UTF-16 code units (NSString), matching Dart
        // String indexing and the Windows UIA path.
        result([
          "contextText": capture.contextText,
          "selStart": capture.selStart,
          "selLen": capture.selLen,
          "elapsedMs": elapsedMs,
        ])
      }
    }
  }
}

// TODO-1030 M1 -- Accessibility (AX) foreground-selection context capture, the
// macOS counterpart to windows/runner/foreground_selection.cpp. Reads the
// SYSTEM-WIDE focused UI element, its selected text, and the selection range,
// then expands +/- maxExpand characters via the parameterized
// kAXStringForRange attribute to grab the surrounding neighbourhood. The pure
// sentence trimming stays in Dart (sentence_extraction.dart), shared with the
// reader and the Windows path.
//
// FAIL-OPEN CONTRACT: every failure path returns nil (never throws, never
// prompts). Without Accessibility trust (AXIsProcessTrusted() == false) we
// cannot read other apps, so we bail immediately -- no nagging permission
// dialog on every hotkey, no crash; the caller silently falls back to the
// clipboard capture. Offsets are UTF-16 code units (NSString length), the unit
// Dart String indexing uses.
//
// SANDBOX NOTE (updated 2026-09-14): the app is NOT sandboxed any more (both
// Runner/*.entitlements dropped com.apple.security.app-sandbox for the
// all-platform auto-update, docs/specs/2026-06-04-all-platform-auto-update-
// design.md §5), so cross-process AX reads work as soon as the user grants
// Accessibility trust in System Settings > Privacy & Security. The settings
// page offers that grant via `requestAccessibilityTrust` (SelectionCaptureMac
// .swift); this hotkey-path capture itself still never prompts.
enum ForegroundSelectionCapture {
  // Mirrors kForegroundContextExpand in foreground_selection.h (Windows): the
  // max characters to grab PAST the selection on EACH side. Bounded for privacy
  // (never scrape a whole document) and latency.
  static let defaultExpand: Int = 600

  struct Result {
    let contextText: String
    let selStart: Int
    let selLen: Int
  }

  static func capture(maxExpand: Int) -> Result? {
    // Fail-open gate: no Accessibility trust -> cannot read other apps text.
    // Do NOT prompt here (AXIsProcessTrusted, not the prompting *WithOptions
    // variant) so a hotkey never spawns a permission dialog.
    guard AXIsProcessTrusted() else { return nil }

    let systemWide = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
      let focusedValue = focusedRef,
      CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
    else {
      return nil
    }
    let focused = focusedValue as! AXUIElement

    // The selected text itself (the lookup query). Empty/absent -> nothing to
    // look up, bail so the clipboard fallback can try instead.
    var selTextRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        focused, kAXSelectedTextAttribute as CFString, &selTextRef) == .success,
      let selText = selTextRef as? String, !selText.isEmpty
    else {
      return nil
    }
    let selTextLen = (selText as NSString).length

    // The selection range {location, length} inside the focused element text.
    // Without a usable range we still return the bare selection as the whole
    // context (sentence extraction treats it as one sentence).
    var selRangeRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        focused, kAXSelectedTextRangeAttribute as CFString, &selRangeRef) == .success,
      let selRangeValue = selRangeRef,
      CFGetTypeID(selRangeValue) == AXValueGetTypeID()
    else {
      return Result(contextText: selText, selStart: 0, selLen: selTextLen)
    }
    var selRange = CFRange()
    guard AXValueGetValue(selRangeValue as! AXValue, .cfRange, &selRange) else {
      return Result(contextText: selText, selStart: 0, selLen: selTextLen)
    }

    // Total character count, to clamp the expansion window to the buffer.
    var total = selRange.location + selRange.length
    var totalRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(
      focused, kAXNumberOfCharactersAttribute as CFString, &totalRef) == .success,
      let n = totalRef as? Int
    {
      total = n
    }

    let clampedExpand = max(0, maxExpand)
    let ctxStart = max(0, selRange.location - clampedExpand)
    let ctxEnd = min(total, selRange.location + selRange.length + clampedExpand)
    let ctxLength = max(0, ctxEnd - ctxStart)

    // kAXStringForRange (parameterized) -> the expanded context window. When the
    // element does not support ranged text, fall back to the bare selection.
    var ctxRange = CFRange(location: ctxStart, length: ctxLength)
    guard let ctxRangeValue = AXValueCreate(.cfRange, &ctxRange) else {
      return Result(contextText: selText, selStart: 0, selLen: selTextLen)
    }
    var ctxTextRef: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        focused, kAXStringForRangeParameterizedAttribute as CFString, ctxRangeValue,
        &ctxTextRef) == .success,
      let ctxText = ctxTextRef as? String, !ctxText.isEmpty
    else {
      return Result(contextText: selText, selStart: 0, selLen: selTextLen)
    }

    // Re-base the selection into the returned context window and clamp
    // defensively (odd AX offsets never crash the Dart consumer -- worst case
    // the whole buffer is treated as one sentence).
    let ctxTextLen = (ctxText as NSString).length
    var reSelStart = selRange.location - ctxStart
    if reSelStart < 0 { reSelStart = 0 }
    if reSelStart > ctxTextLen { reSelStart = ctxTextLen }
    var reSelLen = selRange.length
    if reSelStart + reSelLen > ctxTextLen { reSelLen = ctxTextLen - reSelStart }
    if reSelLen < 0 { reSelLen = 0 }

    return Result(contextText: ctxText, selStart: reSelStart, selLen: reSelLen)
  }
}
