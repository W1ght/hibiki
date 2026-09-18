# 媒体服务器（Jellyfin / Emby）接入模型重构

- 日期：2026-09-18
- 分支：`claude/media-server-refactor`
- 触发：用户反馈五条——系列被拍平又被折成组、是否该单开栏目、远端字幕用不了、系列与全屏没分页、iOS 播放闪退。

## 结论

旧接入是「互联 host 远端占位卡」抽象的第四个实现：单服务器、不落库、把整台服务器拍平成
Movie/Episode 叶子清单一次性拉进 60 秒内存缓存，再混排进本地墙。五条症状全是这一个模型的
直接后果。本次不重写 `JellyfinApi` 与播放 / 字幕 / 进度上报（它们是健康的），只换接入模型：

1. **独立「媒体服务器」栏目**，按服务器自己的树浏览：服务器 → 媒体库 → 条目（分页）→
   剧 → 季 → 集 → 播放。客户端永远只持有当前屏幕那一页。
2. **多服务器配置**（`sync_jellyfin_servers` 列表键），旧单值键读路径一次性迁移。
3. **混排改显式 opt-in**：`jellyfin_show_in_library` 默认 false；开了才走旧的
   `RemoteVideoSource.listRemoteVideos()` 全量清单路径，且仍受 BUG-1891 的
   `jellyfin_auto_list_videos` 闸门管。
4. **止血**（独立于模型，已先行合入）：远端封面恒缩放解码 + URL 带 `maxWidth=720`、
   默认字幕下载失败不再判成播放失败、mpv 网络预读移动端分档、剧集面板 entries memo、
   合集详情页过闸门、系列墙 / 全部视频列表懒构建、枚举熔断改跨轮总额。

## 契约

`fushi/lib/src/media/video/media_server/media_server_browser.dart` —— `MediaServerBrowser`。

| 方法 | Jellyfin / Emby 端点 | 失败语义 |
|---|---|---|
| `listLibraries` | `/Users/{uid}/Views`（只留视频域） | 抛 |
| `listChildren(parentId, startIndex, limit, sort)` | `/Users/{uid}/Items?ParentId=` | 抛 |
| `listSeasons` / `listEpisodes` | `/Shows/{id}/Seasons` / `/Shows/{id}/Episodes` | 失败回退通用 `/Items` 树（飞牛兼容） |
| `listResume` / `listNextUp` / `listLatest` | `/Items/Resume` / `/Shows/NextUp` / `/Items/Latest` | 空 + debugPrint |
| `search` | `/Items?SearchTerm=&Recursive=true`，Movie / Series 单值各一轮 | 抛 |
| `itemDetail` | `/Users/{uid}/Items/{id}` | 抛，调用方拿清单项回退 |
| `coverUrl` / `libraryCoverUrl` | `/Items/{id}/Images/{kind}?maxWidth=&quality=90` | — |
| `toRemoteVideoInfo` | 叶子 → 既有播放页 DTO | 非叶子抛 ArgumentError |

要点：
- 翻页**只认** `MediaServerPage.nextStartIndex`：实现侧会把 Audio / Book 等非视频域类型滤掉，
  `startIndex + items.length` 会把下一页前几条重复取回。
- `IncludeItemTypes` / `SortBy` 一律单值（BUG-2254：飞牛不认逗号多值）。
- 清单请求一律不带 `Fields=MediaSources`（BUG-1891）；重字段在单条目消费点补。
- 能力判据沿用本仓口径：`client is MediaServerBrowser`。互联 / 云盘 / URL 直链拿不到该能力。
- `playbackClient` 就是同一个 `JellyfinVideoClient` 实例；播放、字幕、断点、Stopped 上报全部
  沿用 `RemoteVideoClient` 既有契约，不另造播放路径。

## 与本地库的关系

- 媒体服务器条目**不落库**。下载入库（`downloadRemoteVideo`）才进 `video_books`，这条路径不变。
- 混排开关关闭时，`home_video_page` 的远端源解析链 `互联 ?? Jellyfin ?? 云盘` 跳过 Jellyfin。
- 旧的「按剧名折成 playlist 合集」逻辑保留在混排路径，独立栏目不用它——那边剧的身份是
  Series GUID，不再靠字符串匹配。

## 未验证

- 没有对着真 Jellyfin / Emby / 飞牛服务器复测；`/Shows/*`、`SearchTerm`、`SortBy=DateCreated`
  等在飞牛上是否可用未知（有回退 / 即空兜底）。
- iOS 真机内存曲线未测；止血四项（封面缩放、预读分档、面板 memo、清单不再全量）按代码路径
  推断能显著降低 jetsam 风险，量级需真机 profile。
- 设置页与新栏目未看像素，只有 widget 行为测试。

## 后续

- Plex 等第二家实现照 `MediaServerBrowser` 写 client + 设置分区即可，页面零改动。
- 若要让下载回来的远端视频归属到来源，需给 `VideoBooks` 加统一来源引用
  （`sourceKind` + `sourceId`），把本地扫描根与远端源在「来源」概念上打通——独立议题。
- 7 个平行 Kind 值域已漂移（漫画不在 `MediaKind` 里），加新媒体类型前先补齐漫画的登记。
