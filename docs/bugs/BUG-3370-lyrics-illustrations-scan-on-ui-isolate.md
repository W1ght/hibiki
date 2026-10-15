## BUG-3370 · 歌词模式 / 插图册在 UI isolate 上同步扫整本书插图
- **报告**：2026-10-15（排查「更新后打开书变慢」时读代码发现；不是录屏用户的成因，那条是 BUG-3369）
- **真实性**：✅ 代码路径确认、未真机测时。`_prepareLyricsIllustrations`（`fushi/lib/src/pages/implementations/reader_fushi/lyrics.part.dart`，b32be24545 插图功能引入）在第一个 await 之前同步读 `book.images`（`packages/fushi_engine/lib/epub/epub_book.dart` 的 `images` getter：逐章同步读文件 + `parseChapterHtml` 整章解析 + 扫 DOM），整本书跑在 UI isolate 上。上次停在歌词模式的有声书开书时自动进歌词模式（9880325ff1 按书记忆歌词模式），正好落在首章就绪前后，长篇卡界面上百毫秒到秒级。插图册入口 `_openGallery`（`reader_fushi/chrome.part.dart`）同款。
- **[x] ① 已修复** — 新增 `_loadBookImagesOffUiIsolate`（`reader_fushi_page.dart`）：已建好直接返回，否则 `compute` 在书的副本上建插图表，再经新增的 `EpubBook.adoptImages` 回填缓存（与 `parseVolumeBookForPeek` 同一思路），后续读取不再重扫；两处入口改走它，await 后重查 mounted / 代次。
- **[x] ② 已加自动化测试** — `fushi/test/epub/epub_image_list_test.dart`（`adoptImages` 跨 isolate 往返结果一致、已建时 no-op）；`fushi/test/pages/reader_illustrations_off_ui_isolate_guard_test.dart`（两处入口不同步读 `book.images`、经 `_loadBookImagesOffUiIsolate`）。
- **备注**：未真机测量省下的时间。
