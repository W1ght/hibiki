## BUG-2473 · WebKit 上 BUG-2459 的 line-box-contain 把嵌套 inline / 空行行盒压成零高：目录列叠印、空行消失
- **报告**：2026-09-12（用户：「mac 端無職転生 22 实测，章节列表贴在一起」，截图为目录页 17 条章节标题全部叠印在同一列）
- **真实性**：✅ 真 bug（WebKit 专属，BUG-2459 的修法引入的回归）。根因 `fushi/lib/src/reader/reader_content_styles.dart:196`（`_webKitLineBoxCss` 对 iOS / macOS 发出 `html { -webkit-line-box-contain: block replaced !important }`）。
  - 机制：EPUB 的 XHTML 被当 `text/html` 端上且多数没有 `<!DOCTYPE>`（`document.compatMode === "BackCompat"`，quirks 模式）。quirks 模式下 WebKit 只给「根 inline 盒里直接有文本节点」的行加块级 strut；`block replaced` 又把所有 inline 盒的贡献剔掉。于是凡是一行的文字**全部**住在 inline 盒里（`<p><a><span>…</span></a></p>`、`<p><span>…</span></p>`、`<p><em>…</em></p>`，甚至 `<p><span><ruby>…</ruby></span></p>`）或只有 `<br/>` 的空行，行盒高度为 0——段落块轴尺寸 0，下一段直接叠上来。
  - Mac 隐藏 runner 真书取证（`reader_mushoku22_layout_probe_itest.dart`，`[m22] SUMMARY` 行）：目录页 p-toc-002 在 `block replaced` 下 17/18 个 `<p>` 宽 0（截图与用户一致）；正文 p-002 的 63/2006 个 `<p>` 宽 0（其中 57 个是 `<p><br/></p>` 空行——段落间距在 Mac 上整体消失）；切回 `block inline replaced` 后目录 0/18、正文 6/2006（那 6 个是真空 `<p></p>`）。合成段落逐类实测：`bare` 36.3 / `span1` 0 / `span2` 0 / `a1` 0 / `a-span` 0 / `br` 0 / `mixed`（根级有文本）36.3 / `ruby` 36.3 / `span-ruby` 0 / `em-span` 0 / `nbsp` 36.3。Windows（Blink 不解析该属性）全部正常。
  - 为什么不能靠 `:has(ruby)` 收窄：`<span><ruby>…</ruby></span>` 这种行在带注音的段落里照样归零（`scoped` 候选实测 `span-ruby` = 0）。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：BUG-2459 要解决的「WebKit 首行含注音的段落被撑高 ≈0.215em」仍然成立，修法要换：不再碰 line-box-contain（它在 quirks 模式下是把整条行盒的 strut 一并剔掉），改为只把 `<rt>` 注音盒自身在流中的高度扣掉（见 ① 与 BUG-2459 的追记）。
