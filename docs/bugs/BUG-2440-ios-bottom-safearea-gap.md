## BUG-2440 · iOS 页面底部安全区留下一条不可用空白，滚动内容被硬切
- **报告**：2026-09-10（用户：录屏，设置 › 查词 详情页）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/fushi_material_components.dart:2261`（`FushiPageScaffold` 的 `body: SafeArea(...)` 默认 `bottom: true`）与 `:2358`（`FushiToolScaffold` 同款）。
  - 现象：iPhone（home indicator 34pt）上页面底部有一条纯背景色空白，滚动内容在这条线被硬切——卡片边框、文字被切一半，且怎么滚都进不去。
  - 机制：`SafeArea` 把 body 的 viewport 上界硬切在 home indicator 之上，同时通过 `MediaQuery.removePadding` 把 `padding.bottom` 清零；于是
    `settings/material_settings_renderer.dart:152`、`:95`、`settings/settings_home_page.dart:205`、`settings/cupertino_settings_renderer.dart:145` 这几处**已经写好的** `mediaPadding.bottom` 全部恒为 0（死代码）——作者本就打算让滚动内容滚过安全区、由内容 padding 兜底，被外层 `SafeArea` 掐掉了。
  - 复现（widget 测试，无需真机）：`size 402×874` + `padding.bottom: 34` 下渲染 `FushiPageScaffold(body: ListView)`，list 底边 = 840 而非 874。
  - 本仓既有范式一致：BUG-383 / BUG-1783 都把 `SafeArea` 拿掉、改走显式 `Padding`，理由同样是「SafeArea 与内容自己的 inset 重复/打架」。
- **[x] ① 已修复** — `fushi_material_components.dart` 两处脚手架 body 的 `SafeArea` 改 `bottom: false`，底部 inset 交给 body 自己消费（`ListView`/`GridView` 的 `padding == null` 由 Flutter 自动取 `MediaQuery.padding`；`CustomScrollView` 与尾部有固定元素的 body 显式 `Padding`）。提交见下。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_page_scaffold_bottom_inset_test.dart`：注入 34pt 底部安全区，断言 body 铺满到屏幕底、且滚动到底时最后一项完整可见不被压住。
- **备注**：桌面/Android 无手势条时 `padding.bottom == 0`，改动为空操作。
