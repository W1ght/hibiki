## BUG-2386 · 词典查词把同释义真实词条误判为重定向别名删除
- **报告**：2026-09-09（用户指出 BUG-1665 把定义字节相同误当成重定向关系，可能吞掉日语连用形名词。）
- **真实性**：✅ 已用生产 `fushi/assets/transforms/ja.json` 复现，与本次截图的缺盘原因（BUG-2385）独立。
- **根因**：`native/fushidicts/fushidicts_src/lookup.cpp:124` 原先仅按同词典的压缩 glossary 指针/长度相同，删除未变形命中的对应释义。导入器对普通相同释义也共享 blob，所以该判据只能证明存储复用，不能证明 MDX `@@@LINK=` 或 StarDict `.syn` 的真实别名关系。词典给「行き遅れ」和「行き遅れる」相同定义时，真实名词条目会被删空并从结果集消失。
- **复现**：扩展现有 native 行为测试，用实际日语规则分别导入普通 SimpleEntry、无重定向的 MDX 和 Yomitan ZIP；三种真实名词命中均被旧逻辑删除。另验证 alias 指向其他同释义词时，旧逻辑同样错误地将它折叠到非目标 lemma。构建成功后 CTest 执行 1 个测试程序并失败，包含 8 个失败断言；不是编译失败或零测试执行。旧四个测试只是 `write_simple_dict` 模拟同释义，并未提供真正 MDX 重定向证据。
- **[x] ① 已修复** — `fe0304d46a`：MDX `@@@LINK=`、StarDict `.syn` 的实际 canonical target 经 importer 写到逐记录 `redirects.bin`，查询侧仅对目标词头一致且同词典同 blob 的 glossary 折叠。普通同释义词条不受影响。sidecar 与现有 `.fushidicts_1` marker 内容绑定本次导入 ID，拒绝覆盖恢复旧包后遗留的 sidecar；v1/v2 记录布局与 FFI 不变。`.syn` 保留原 `.idx` 序号，避免坏 entry 跳过后错认目标。
- **[x] ② 已加自动化测试** — `fe0304d46a`，`native/fushidicts/tests/mdx_redirect_lemma_lookup_test.cpp` 共 20 个行为 case，覆盖实际 MDX alias、三种日语独立词条、真实目标匹配、链式 alias、未知来源旧库、同 headword 混合词条、重导入、损坏 sidecar、旧 marker/异导入 ID/旧 Hoshi 包覆盖降级、StarDict `.syn` 与坏索引边界。Windows clean build 后 14/14 相邻 CTest 通过（退出码 0，1.47 秒）；独立新 FFI DLL 在本机实际 v1 数据上两组只读查询也通过。证据 `.codex-test/redirect-defect/clean-final-{build,ctest,probe}.log`。
- **构建验证**：一次增量 DLL 的 AV 已排除为 Ninja 没有记录头依赖，旧 `popup_json.cpp.obj` 使用旧 `GlossaryEntry` 布局。仅重编该对象即可消除；最终 `chcp 65001`、重新 configure、`--clean-first` 重编 91 步并复核依赖记录恢复，未把缓存产物问题归咎于词典或跳过真实失败。
- **备注**：旧词典没有记录重定向来源时必须保留全部真实命中，不能为了避免重导继续猜测别名。这可能令旧英文词典重新显示别名和原形，重新导入后才具备精确折叠依据。
