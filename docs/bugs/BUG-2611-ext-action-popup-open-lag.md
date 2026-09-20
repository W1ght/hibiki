## BUG-2611 · 浏览器扩展点工具栏图标弹出制卡队列很卡很慢
- **报告**：2026-09-20（用户：「浏览器插件 点击调出界面很卡很慢」，附截图：Chrome 工具栏上钉住的 Fushi 扩展图标 + 拼图菜单）
- **真实性**：❌ 未复现（沿真实代码路径 + 真 Chrome 153 实测，扩展侧没有可归因的耗时点；见下）
- **[ ] ① 未修复** — 无扩展侧根因可修；等用户按「下一步取证」回报后再定
- **[ ] ② 未加自动化测试** — 同上
- **备注**：取证脚本留在 `D:\hibiki-tmp\cft\`（`probe_popup.mjs` / `probe_uia.ps1` / `trace_popup.mjs` / `parse_ldb_log.py`），Chrome for Testing 153 在 `D:\hibiki-tmp\cft\chrome\`

### 沿真实代码路径的静态排查（全部很轻）

点图标弹出的是 `tools/browser-extension/vendor/action-popup.html`（manifest `action.default_popup`），启动只做：

1. 同步装 6 个脚本（`locales/en.js` 31 KB、`i18n.js`、`theme-palette.js`、`theme.js`、`connection-diagnostics.js`、`vendor/action-popup.js` 23 KB）+ `theme.css` 3.5 KB；没有 popup.js / content.css 那些大文件。
2. `theme.js` / `i18n.js`：各一次 `chrome.storage.local.get`（按键读）+ 一次 `fetch('locales/zh-CN.json')`（29 KB 本地资源）。
3. `action-popup.js`：`storage.local.get` 三次（`fushiQueue` / `fushiNfBatch` / `subtitleOverlayEnabled` 等）、`chrome.tabs.query` 一次、向 SW 发 `connectionStatus force:true`。
4. SW 侧 `diagnoseConnection(true)`（`background.js:180`）= 一次 `POST /api/extension/status` 到本机 19633；app 端 `_handleExtensionStatus`（`fushi/lib/src/sync/yomitan_api_server.dart:469`）只读 body + 三个 provider 闭包 + 拼 JSON，`_onExtensionReport` 只写一个 `ValueNotifier`。
5. 内容脚本没有高频写 `chrome.storage.local`（会惊动所有扩展上下文的 `onChanged`）：`subtitleOverlayPosition` 只在拖拽松手时写、`popupSizeFromApp` 同值不写、`fushiLookupPerfLogs` 每次查词 250 ms 防抖写一次（25 KB）。

### 真 Chrome 实测（2026-09-20，本机；Chrome for Testing 153.0.8010.52 加载用户 Chrome 实际用的那份副本 `%APPDATA%\Fushi\Fushi\fushi-browser-extension`，`fushi.exe`（Debug 构建，12:32 启动）在跑）

- **真鼠标点击工具栏图标**（UIA 定位按钮 + SendInput，最贴近用户路径）：popup target 出现 **+100–210 ms**，popup 文档 DCL **22–37 ms**，首帧 **60–108 ms**，连接行落定与中文文案就位在 attach 后 ≤5 ms；SW 空闲 45 s 后再点一样快。
- `chrome.action.openPopup()` API 路径：热态 ~350–400 ms；Chrome **刚启动**那一次 2–7 s，但对照的最小扩展（只有空 popup.html）首开同样 7.1 s → 是 Chrome/机器层冷启动成本，与本扩展无关。
- Chrome trace（`Tracing.start` 抓 openPopup）：每次开 popup 都用一个新的渲染进程（`ChildProcessLauncher` → 184 ms `RenderProcessHostImpl::Init`），GPU 首帧光栅化 `RasterDecoderImpl::DoEndRasterCHROMIUM` 166 ms + `DawnPlatformImpl::RunWorkerTask` 152 ms——这两项是 Chrome 对任何扩展 popup 的固有成本；扩展常驻页面（offscreen / options）不能让 popup 复用进程（实验三种模式都新起进程、耗时相同）。
- SW `diagnoseConnection(true)` 往返 2–11 ms（Debug 构建 app）。
- 用户真实 Chrome profile 里本扩展（`ifoknaollndjmcmefhdfiiagieiohkgn`，已钉住）的状态：`Local Extension Settings` 仅 496 KB、今日总共 96 次写；站点权限没有被扣留（`withholding_permissions=false`，host 全授，排除「点击时才注入 22 个内容脚本」这条会让点击变卡的路径）；app 内置指纹与已加载副本一致（`fushiReloadedForBuild` 已落、探针里 `connected` 且无 `fushiUpdateStale`），排除自更新 `runtime.reload()` 把刚开的 popup 杀掉。

### 未能覆盖的环境差异（用户机器上此刻的状态）

- 40 个扩展已装、21 个钉在工具栏、27 个 chrome.exe 进程；内存 commit 44.4 / 63.7 GB、空闲物理内存 3.2 / 32 GB；机器常年并发跑多个 agent（node 36 个、claude 9 个、dart、Docker、WSL）。这种状态下「新起渲染进程 + GPU 首帧」被拉到秒级是 Chrome 层面的，且会对**所有**扩展 popup 一视同仁。
- 无法接管用户正在运行的 Chrome 实例（同一 user-data-dir 不能起第二个实例），干净 profile 下复现不出。

### 下一步取证（给用户）

1. 同一时刻点旁边任何一个别的扩展图标（截图里的青蛙 / ChatGPT 等）：**一样卡** → Chrome/机器层，不是 Fushi；**只有 Fushi 卡** → 回报当时所在网页（Netflix / YouTube / 普通页）与 popup 里显示的连接行文案，再用 `chrome://extensions` → Fushi → 「检查视图：弹出式窗口」的 Performance 面板录一次点开过程。
2. 检查 `chrome://gpu` 硬件加速是否正常（trace 里 GPU 光栅化是 popup 首帧的大头）。
