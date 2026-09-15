## BUG-2552 · 查词主页 initState 经 LookupImeBinding 触发 ref.watch，debug 下打开查词 tab 崩溃
- **报告**：2026-09-15（用户：W1ght）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/home_dictionary_page.dart:105`（修前）——
  `_imeBinding` 的 `languageOf` 闭包取的是 `appModel`，而 `fushi/lib/src/pages/base_page.dart:37`
  的 `appModel` getter 在 `mounted` 时走 `ref.watch(appProvider)`。
  `LookupImeBinding.attach()`（`fushi/lib/src/lookup/lookup_ime_binding.dart:30`）在
  `initState` 里**同步**调一次 `languageOf()`，于是 `ref.watch` 发生在 build 之外。
  Flutter 当场抛：
  `dependOnInheritedWidgetOfExactType<UncontrolledProviderScope>() ... was called before`
  `_HomeDictionaryPageState.initState() completed.`，栈顶 `home_dictionary_page.dart:157`
  （`_imeBinding.attach(focusNode: _searchFocusNode)`）。
  影响面：debug 构建下打开查词 tab 直接红屏；另两个查词入口
  （`popup_dictionary_page.dart:79` / `floating_dict_page.dart:40`）用的是 `ref.read`，不受影响。
  引入于查词输入法语言功能（develop `5a15d25245`，上游 PR #1494）。
- **[x] ① 已修复** — `languageOf` 改取 `appModelNoUpdate`（`base_page.dart:51`，即 `initState`
  里 `ref.read` 缓存下来的同一个 `AppModel` 实例）。这里本来也不该 watch：输入法语言变了只需
  下次同步时读到新值，不需要整页重建。提交 `af3eb7ddb8`。
- **[x] ② 已加自动化测试** — 无需新建：`fushi/test/pages/home_dictionary_pending_on_mount_test.dart`
  等 **5 个真挂载 `HomeDictionaryPage` 的 suite** 就是天然复现，修前全红、修后 37 条全绿
  （`home_dictionary_{pending_on_mount,pull_preserve_query,pull_to_sync,search_error,standalone_route}_test.dart`）。
  把 `languageOf` 改回 `appModel` 即再红。
- **备注**：这条是**合入时漏跑测试**造成的，不是测试缺失——按功能域挑相邻测试永远挑不到
  `test/pages/home_dictionary_*`。教训同
  `dart run tool/tests_for_changes.dart --include-dart --explain <改的文件>` 的既有纪律：
  改 `fushi/lib/**` 时用反查而不是猜。同批还修了上游 PR #1494 里
  `fushi/macos/Runner/AppDelegate.swift` 被重放吃掉两个 `}` 的问题（该缺陷只在 PR 分支上，
  develop 侧大括号平衡，故不单开一条）。
