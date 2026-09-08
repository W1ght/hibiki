# Windows Galgame 引擎级内嵌查词审计

## Scope

- 日期：2026-09-07。
- 审计基线：`ec7807328a6bd66830885cbb0812fd19770678d0`，分支 `codex/galgame-engine-audit`。
- 范围：`native/galgame_hook/engine-support.yaml`、geometry provider registry、相关引擎 lookup adapter，以及 Windows runner → Flutter 查词消费链。
- 用户目标：把依赖单个游戏或特定版本的适配推进到引擎级，使用户通过 Windows 注入流程后能在游戏原文位置查词；用户明确指定 **Siglus 第一优先**，其后按引擎普及程度逐项推进。
- 本文只记录静态审查结果和实施队列，不修改业务代码，不启动游戏。Siglus 实现在另外的独立 worktree 推进，本文不预告完成或验证结果。
- 下列源码行号均固定于上述审计基线。支持状态的唯一真相源仍为 `native/galgame_hook/engine-support.yaml`；本文是审计快照，不另建支持矩阵真相源。

## Proved：已由代码路径证明

### 当前覆盖面

`engine-support.yaml:16` 起的 lookup_support 共列 16 个引擎；**7 个已有运行时或 exact 几何 provider，9 个仅有 attached_calibrated 降级**。全部 lookup geometry、verified_shield 和 risky_left_click 状态仍是 `implemented_unverified`，不能把代码存在写成跨游戏验证通过。

| 引擎 | lookup provider 快照 | 主要边界 | manifest 行号 |
|---|---|---|---|
| KiriKiri Z | runtime_layout + attached_calibrated | 已接引擎运行时布局；仍需变体与真实会话验证 | 25 |
| Ren'Py | runtime_layout + attached_calibrated | 已接运行时布局；Ren'Py 8 自定义 screen 覆盖仍待验证 | 41 |
| Tyrano / NW.js | attached_calibrated | DOM provider 尚未生产接入 | 57 |
| Unity IL2CPP | attached_calibrated | TMP/UGUI 字符索引与 Canvas 投影尚未生产接入 | 73 |
| Elf / AI6 | attached_calibrated | 缺已接入的 positioned GDI 血缘 | 89 |
| RealLive | attached_calibrated | 缺已接入的 positioned GDI 血缘 | 105 |
| BGI / Ethornell | attached_calibrated | 缺已接入的 positioned GDI/DWrite 血缘 | 121 |
| CatSystem2 | attached_calibrated | 同上 | 137 |
| Malie / LIBP | attached_calibrated | 同上 | 153 |
| QLIE / FilePack | attached_calibrated | 同上 | 169 |
| Artemis / PFS | attached_calibrated | 无唯一追踪到最终呈现的混合文本定位 provider | 185 |
| Siglus | engine_exact_layout + attached_calibrated | 两个已知样本的 SHA/RVA profile 是准入硬门 | 201 |
| Leaf / Aquaplus | engine_exact_layout + attached_calibrated | exact SHA 身份、唯一签名、调用图和 D3D9 ABI 门 | 217 |
| HUNEX / GGE | engine_exact_layout + attached_calibrated | 入口仍有 WoH.exe 标题 profile 硬门 | 233 |
| SGRE | engine_exact_layout + attached_calibrated | 已有未知 hash 的结构签名路径；单一 build 的 E2E 不等于全引擎验证 | 249 |
| SMASH / FZMedia | engine_exact_layout + attached_calibrated | TextLayer 字形还依赖当前窗口尺寸的 layer origin 求解 | 265 |

registry 的合法 provider ID 不等于实现已存在。`native/galgame_hook/hook/geometry_provider_registry.h:64` 明确说明部分条目只预留身份，没有 adapter `OfferReady` 就不能激活。全树生产调用目前只有 KiriKiri、Ren'Py、Siglus、Leaf、SGRE、HUNEX、SMASH；Tyrano DOM、Unity TMP/UGUI、GDI/DWrite 没有对应 `OfferReady`。

### 消费链已经通用

Windows → Flutter 消费端按 provider kind/id/status 接收，不用游戏标题、exe 名或引擎名称再设白名单：

1. 注入侧 registry 在有当前可用布局后 `OfferReady`，独占当前 provider 所有权：`native/galgame_hook/hook/geometry_provider_registry.h:198`。
2. runner 校验 provider、source span、geometry 和当前代数：`fushi/windows/runner/voice_hook_reader.cpp:2485`。
3. Flutter 校验合法 kind/id：`fushi/lib/src/platform/gal_hook_text_overlay_channel.dart:64`；根据 Ready/Active 状态及输入准入决定是否启用：`fushi/lib/src/lookup/gal_attached_text_controller.dart:2109`。
4. `GalIngameLookupController.handleHit` 接收 submit，创建 `GlobalLookupRoute.galCard`，调用既有词典链：`fushi/lib/src/lookup/gal_ingame_lookup_controller.dart:700`、`:724`、`:1271`。
5. 卡片以游戏窗口上的透明 WebView2 composition surface 呈现，特定引擎另有进程内呈现路径；geometry 采集与卡片呈现是两个能力边界。

因此后续目标应是补齐或泛化引擎 provider 的探测、正文索引、坐标、生命周期和输入契约。无需为每个引擎重新实现查词 UI，也不能只放开 Flutter 门控来补偿缺失的坐标。

## Findings

### HBK-AUDIT-001：Siglus 几何准入仍锁定两个样本

- severity：高，直接阻断用户要求的引擎级覆盖。
- status：静态确认；独立 Siglus 实现任务进行中，未在本文验证修复。
- 证据：`native/galgame_hook/hook/adapters/siglus_lookup.h:28` 声明每个 profile 只准入一个测量过的 executable；`:95` 的数组只有 Anemoi 和 Summer Pockets Reflection Blue 两项；`:119`、`:145` 先按摘要与 profile 匹配。`siglus_lookup.inc:410` 未命中 profile 即缓存拒绝，`:1103` 在安装 sensor 前直接返回 false。
- 根因：虽然已有可执行段签名、调用图和 ABI 结构验证，生产入口先要求已知 SHA 与固定 profile，未知但结构兼容的游戏到不了结构判定。
- 影响：增加游戏 exe hash 的方式只能扩大样本白名单；改名、版本更新、补丁或同引擎其他作品不能自动获得 native geometry。
- 修复建议：按引擎结构和实际 ABI 解析 renderer/input/text anchors；已知 SHA 留作一致性证据。未知 hash 也必须经过唯一候选、调用图、边界与 ABI 验证，歧义和不兼容继续拒绝。不能直接删 SHA 判断后继续套旧 RVA、视口、线程或对象偏移。
- 验证：两个旧 profile 保持正确；同 ABI 的未知 hash/重定位样本能由结构解析；零候选、多候选、跨引擎相似字节、错误调用目标和布局不兼容均 fail closed。再按 SOP 做 x86/x64 构建、CTest、replay 及原始路径会话验证。

### HBK-AUDIT-002：HUNEX renderer provider 被 WoH 名称门挡在入口

- severity：高，已有结构探测仍不能覆盖其他同引擎标题。
- status：静态确认，尚未实施。
- 证据：`native/galgame_hook/hook/adapters/hunex_gge_profile.h:11` 固定 `WoH.exe`，`:25` 的 `MatchesHunexGgeTitleProfile` 检查文件名。`hunex_gge_adapter.inc:4497` 用此结果实现 `IsHunexGgeProfileMatched`；`:4326` 在 runtime anchor scan 前要求该条件；`:5337` 的 adapter probe 同样要求该条件。
- 根因：标题身份成为 engine adapter 的资格判断，结构探测只有通过标题门才有机会运行。
- 影响：即使其他 GGE build 具有相同 renderer/input/projection 结构，也不会进入候选扫描。只改文件名不构成支持证明。
- 修复建议：独立 HUNEX 任务将引擎结构识别与 WoH 的资源/音频特例拆开；未知标题只在自身结构满足契约时准入。不得同时把 WoH 私有归档/音频规则推广给整个 GGE 引擎。
- 验证：非 WoH 同结构合成样本、仅改名的无关程序、错误 projection/input anchors、多候选和 ABI 变化；真实游戏再记录字形→客户区投影、点击/Shift、弹卡和关闭事务。

### HBK-AUDIT-003：九个引擎尚无生产原文字形坐标

- severity：高，无法满足零校准原文查词。
- status：能力缺口已由 manifest 与生产调用交叉确认。
- 证据：上表九个仅 attached_calibrated 项；`geometry_provider_registry.h:64` 明确预留身份不等于 provider；`fushi/lib/src/lookup/gal_attached_text_controller.dart:663` 在无 profile 时要求校准，`:681` 按当前窗口挑选 variant。
- 根因：文本 Hook 已能提取台词，并没有同时取得原始 renderer 的字符索引、字形矩形和最终窗口坐标。
- 影响：用户需要手工校准正文区域/字体/布局；窗口宽高比、字体、排版和游戏 UI 变化会使校准不匹配。这是降级机制，不能称为引擎级原始布局支持。
- 修复建议：Tyrano 从 DOM 的 source offset、布局 rect、缩放和可见性取得运行时几何；Unity 以 TMP/UGUI 字符信息和 Canvas/world→screen 投影取得几何；其余逐引擎确认真实 renderer 后接入 positioned API 或 engine layout。每引擎单独任务、worktree 和提交。
- 验证：来源 span、UTF-16 边界、换行/缩放/重绘、代数失效、移窗/调整大小、provider 退役切换、错误线程及跨引擎负向测试。

### HBK-AUDIT-004：现有 GDI Hook 丢弃定位信息，不能直接当 geometry provider

- severity：中，容易造成对已有能力的误判。
- status：静态确认，尚未实施。
- 证据：`native/galgame_hook/hook/adapters/text_render_adapter.inc:319`、`:332`、`:342` 的 ExtTextOutW/TextOutW/DrawTextW detour 只将字符串写入 `FlushLineLocked`，没有将 x/y、lpDx、RECT 或 HDC 的投影关系传给 registry；`:49` 在 Luna 活跃后抑制 GDI 文本环写入。
- 根因：模块是文本兜底采集器，职责与 positioned geometry 不同。
- 影响：API 已 Hook 或能看到文本不证明能命中屏上原文；取消 Luna 让位规则还可能重新引入描边/重复字污染。
- 修复建议：引擎 profile 限定下另建几何观察链，保留有界定位参数，追踪 DC/中间位图到最终游戏窗口的关系，与正文 occurrence 对齐。不能用一个 GDI DLL 名把全部游戏准入，也不能从 GetGlyphOutlineW 的单字 metrics 猜屏幕坐标。
- 验证：UI 与正文、描边重复、离屏 DC、文本与位置异步、坐标变换、跨引擎负例；继续保持 Luna 文本去重契约。

### HBK-AUDIT-005：校准降级不覆盖 ruby、竖排和任意全屏

- severity：中，限制“每个用户注入就能用”的范围。
- status：明确实现边界，未认定为本轮回归。
- 证据：`fushi/lib/src/lookup/gal_hook_text_overlay_controller.dart:1032` 对含 ruby 的行不给 attached source；`fushi/windows/runner/attached_text_surface_window.cpp:1181` 拒绝不支持的 writing mode；`:1949` 用宿主 DirectWrite 重新布局，`:2043` 再推导 hit boxes；`:1572` 拒绝无法覆盖的独占全屏。`attached_overlayability.h:167` 的进程内渲染树 presenter 例外目前只认 KiriKiri。
- 根因：重排版出来的字形框不能证明和游戏实际 ruby/竖排一致；桌面覆盖窗也不保证能盖住独占全屏交换链。
- 影响：即使有文本、有校准或有 native geometry，也可能无安全命中或无卡片呈现。
- 修复建议：支持扩展应来自真实 renderer 的 source span 与 geometry，呈现能力另设证据；保持现有拒绝边界，不用强行显示框冒充原文字形。
- 验证：ruby/竖排目前应拒绝；窗口化/无边框/独占切换时及时清理框和输入事务；如新引擎提供真实可验证布局，再独立增加正向测试。

### HBK-AUDIT-006：DLL 加载不是完整查词就绪条件

- severity：中，涉及支持声明和验收口径。
- status：消费路径确认；没有新增现场复现。
- 证据：`fushi/lib/src/lookup/gal_hook_text_overlay_controller.dart:1020` 要求活跃外部窗口会话；`:638` 只在 activeNative 状态允许 native provider；`gal_attached_text_controller.dart:2073` 要求已验证输入盾或当前 executable 的风险接受；`gal_ingame_lookup_controller.dart:701` 在未开启本地准入时拒绝所有 hit。总开关默认 true：`fushi/lib/src/models/preferences_repository.dart:2249`。
- 根因：采集、窗口身份、IPC、geometry、输入拦截和词典呈现各有生命周期，DLL 已加载只能证明其中一小段。
- 影响：Shift 和左键虽在引擎侧触发不同事件，但进入词典都要经过本地 provider admission；不能宣称“仅注入 DLL、无需 Hibiki 会话和输入条件即可查词”。
- 修复建议：保留完整契约，将失败原因精确归属阶段；引擎改造验收既测 hit，也测卡片实际呈现及关闭后的游戏输入恢复。
- 验证：使用现有 admission/route/epoch 测试，验证 native 先消费点击、Dart 却拒绝 hit 的中间态不会出现；每个新引擎再完成原始路径 E2E。

## 后续按普及度排队的依据与建议

本轮于 2026-09-07 查阅以下第一方公开页面。未发现覆盖这 16 个引擎、同一时间窗口、同一 Windows galgame 口径的可靠统一统计，**以下是工程优先级建议，不是市占率或确定的热门榜单**。

| 第一方来源 | 可证明的普及信号 | 不能推出的结论 |
|---|---|---|
| [Ren'Py 官网](https://www.renpy.org/) | 官网称已有超过 8,000 部视觉小说、游戏及其他作品采用 | 不是当前 Windows 日语 galgame 的份额；作品数量不等于活跃玩家 |
| [Tyrano 官方下载页](https://tyrano.jp/dl) | 官网称超过 20,000 部作品采用；维护 V6，并保留 V5 下载 | 包含 PC/手机/浏览器，不能全部计入 Windows NW.js，也不能与 Ren'Py 数字直接横比 |
| [KiriKiri Z 官网](https://krkrz.github.io/) | 官方定性说明用于许多商业 ADV/novel 游戏 | 未给同口径数量，不能据此编造百分比或与其他引擎做精确名次比较 |

建议执行顺序：

1. **Siglus**：用户明确指定，当前独立任务正在实施引擎结构准入；完成本引擎当前验证门后再切换。
2. **KiriKiri → Ren'Py → Tyrano**：三者有上述官方普及信号。这个组内顺序综合日语商业 ADV 使用场景、已有 provider 可复用程度与新增覆盖代价，不宣称三者实际热门度依次递减。KiriKiri/Ren'Py 先审真实变体是否仍有单样本门；已有实现真正通用时以补验证为主，不为排队而重写。Tyrano 要补生产 DOM geometry。
3. **其余引擎逐个进入样本队列**：BGI、RealLive、CatSystem2、Artemis、Unity、Malie、QLIE、Elf/AI6、Leaf、HUNEX、SGRE、SMASH 本轮没有同口径第一方普及数，暂不强排名。以用户实际库的去重作品覆盖数和可验证 Windows 样本排序，再按一引擎一任务推进。HUNEX 的标题硬门和 Leaf 的 exact 身份门应进入各自任务首轮检查；SGRE 先保留已有未知 hash 结构识别，不能误改回 hash 白名单。

上述公开数据只用于安排工作，不扩大平台范围；全部实现、构建和游戏验证保持 Windows x86/x64 边界。

## Not proved：尚未证明

- 本轮没有运行游戏、注入、Hook 或制卡，因此不新增任何真实会话证据，也不宣布上述问题已修好。
- manifest 中 SGRE 已记载单一 Steam x64 build 的 Shift/左键查词和真卡写入，但同条目也说明输入盾 1,000 次事务门未通过，音频证据未达到源 entry 哈希一致或纯人声分类。只能按条目原有范围引用，不能外推整个引擎。
- 尚未证明任何一条结构泛化能覆盖全部版本、保护壳或自定义 UI。“引擎级”应意味着契约驱动且兼容样本自动准入，不能意味着对无法辨认的结构也强行注入或吞输入。
- 16 个引擎的音频支持等级不能代替 lookup geometry 等级；本文不升级 `engine-support.yaml`。

## 验证记录

- 已完成：规则阅读、manifest 与源码路径交叉定位、生产 `OfferReady` 搜索、Windows runner/Flutter 路由审查、三个第一方普及信号页面核验。
- 本轮仅新增此文档；文档提交门为 `git diff --cached --check`，退出码在提交交接中记录。
- 未运行 Flutter/native 测试、双架构构建和真实游戏验收，因为本轮未改业务代码；这不能给独立 Siglus 实现充当验证证据。
- 后续消费链定向回归入口：`fushi/test/lookup/gal_ingame_lookup_contract_test.dart`、`gal_attached_text_controller_test.dart`、`gal_hook_text_overlay_controller_test.dart`；runner 的 `lookup_hit_validation_test.cpp` 与 `attached_overlayability_test.cpp`。native 引擎改动按 `docs/agent/galgame-hooking.md` 执行生成检查、结构/workflow 测试、replay、x86/x64 构建与 CTest。遵守根规则，本地不跑 Flutter 全量测试。

## Next gate / Next Scope

当前第一个实施边界是 **Siglus 从样本身份准入转为结构准入**。独立任务应先固定原始路径的游戏/进程/组件身份和已通过阶段，验证未知 hash 能否经唯一结构候选获得正确 anchors，并维持两个已知样本和跨引擎负向门。只有这个边界通过，才进入同一原始会话的后续 geometry、点击/Shift、卡片和制卡验证；缺失或阻塞的门保持未验证。

后续审查范围按上文队列逐引擎展开，每项另建独立 worktree 和提交。本文不允许批量删除标题、hash 或线程限制；这些限制必须被可验证的结构和生命周期证据替代。
