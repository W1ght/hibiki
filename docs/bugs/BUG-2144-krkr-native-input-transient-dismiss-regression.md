## BUG-2144 · KiriKiri 将瞬时 provider 非 ownership 当撤权，导致点击穿透与选区消失
- **报告**：2026-09-02（用户：）
- **真实性**：✅ 真 bug。`22a7bd0b9:native/galgame_hook/hook/adapters/kirikiri_adapter.inc:5570` 把复合瞬时查询 `OwnsReadyProvider()` 的任意 false 当成稳定撤权；该查询在 admission seqlock 暂不可读、provider handoff/retire pending 或 Ready/Active 瞬态时都可能为 false，并不具备永久撤权语义。false 随即经同提交的 `fushiLookupSetNativeInputReady(0)` 推进 submit fence 并执行 `Dismiss()`，违反现有资源/动画恢复不得触碰 Layer、fence、route 的不变式；同提交的 `fushiLookupProbe(true)` 又直接返回 false 给 KAG，造成点击穿透。用户真机同时观察到这两个确定由该提交新增的行为。具体是哪一个瞬时 conjunct 在该游戏的人物资源变化帧触发，尚无运行时 trace，不能臆断为同值 admission 重写。
- **[x] ① 已修复** — `43b38e8ab` 完整回退 `22a7bd0b9`；代码树已验证与 SGRE 基线 `17ad55d8f` 完全一致，保留 `cd7c47580/a27f2287e/17ad55d8f`，恢复 KRKR 原有点击与跨人物资源变化的视觉生命周期。（本提交）
- **[ ] ② 未加专用自动化测试** — 回退后现有 KRKR source guard 126 项、x86/x64 geometry registry、lookup IPC、KiriKiri launch-profile 测试均通过，双架构 hook/helper 与 Windows Debug 包增量构建成功；但现有测试不能执行真实 TJS 的 writer-held/provider 瞬态并断言 KAG 返回值、`CardSeq`、hover 与 dismiss fence 全部保持，因此不冒充已覆盖本次真机回归。
- **实机回归**：回退测试包位于 `fushi/build_codex/windows/x64/runner/Debug/fushi.exe`，已关闭构建时锁文件的旧 Debug Fushi 进程并安装新 helper；仍需用户重新启动并复测点击与人物资源变化。
- **备注**：回退是正确止血，不是原始风险准入问题的终局修复。后续必须把稳定的 host 风险授权、瞬时 provider readiness、provider 已执行 arm/disarm ack 分成不同代际；不确定态沿用最后 applied 状态，禁止新 submit 与销毁当前视觉也必须拆开，只有真实 session disable、明确撤权、换句或用户 dismiss 才能退休视觉事务。
