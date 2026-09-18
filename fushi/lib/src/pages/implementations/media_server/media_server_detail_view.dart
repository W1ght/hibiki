import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart';
import 'package:fushi/utils.dart';

/// 剧 / 电影详情：封面 + 标题 + 类型 / 年份 / 时长 / 评分 + 播放 + 简介；剧再加
/// 季标签（单季不显示）与当前季的集列表（分页，一页 100）。
///
/// 数据分三档：[MediaServerBrowser.itemDetail] 失败就拿清单里那条 best-effort
/// 回退（与 `RemoteVideoDetailFetch` 同款口径）；[MediaServerBrowser.listSeasons]
/// 失败当单季（整部剧一列）；集清单失败显示错误 + 重试。
class MediaServerDetailView extends StatefulWidget {
  const MediaServerDetailView({
    required this.session,
    required this.item,
    this.initialSeasonId,
    super.key,
  });

  final MediaServerSession session;

  /// 清单里的那条（Movie 或 Series）；详情取回前先用它画。
  final MediaServerItem item;

  /// 进来时选中的季（从季卡 / 集卡进来时带）；null = 第一季。
  final String? initialSeasonId;

  @override
  State<MediaServerDetailView> createState() => _MediaServerDetailViewState();
}

class _MediaServerDetailViewState extends State<MediaServerDetailView> {
  final ScrollController _scrollController = ScrollController();

  late MediaServerItem _detail = widget.item;
  List<MediaServerItem> _seasons = const <MediaServerItem>[];
  String? _seasonId;

  List<MediaServerItem> _episodes = const <MediaServerItem>[];
  int _nextStartIndex = 0;
  bool _hasMore = false;
  bool _episodesLoading = false;
  bool _episodesLoadingMore = false;
  Object? _episodesError;

  /// 换季 +1；旧季的响应回来时丢掉。
  int _generation = 0;

  MediaServerBrowser get _browser => widget.session.browser;

  bool get _isSeries => widget.item.type == MediaServerItemType.series;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(_loadDetail());
    if (_isSeries) unawaited(_loadSeasons());
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 400) {
      unawaited(_loadMoreEpisodes());
    }
  }

  Future<void> _loadDetail() async {
    try {
      final MediaServerItem detail = await _browser.itemDetail(widget.item.id);
      if (!mounted) return;
      setState(() => _detail = detail);
    } catch (e) {
      debugPrint('[media-server] item detail failed: $e');
    }
  }

  Future<void> _loadSeasons() async {
    List<MediaServerItem> seasons;
    try {
      seasons = await _browser.listSeasons(widget.item.id);
    } catch (e) {
      debugPrint('[media-server] seasons failed: $e');
      seasons = const <MediaServerItem>[];
    }
    if (!mounted) return;
    String? initial;
    if (seasons.isNotEmpty) {
      final String? wanted = widget.initialSeasonId;
      initial = seasons.any((MediaServerItem s) => s.id == wanted)
          ? wanted
          : seasons.first.id;
    }
    setState(() {
      _seasons = seasons;
      _seasonId = initial;
    });
    unawaited(_reloadEpisodes());
  }

  Future<void> _reloadEpisodes() async {
    final int generation = ++_generation;
    setState(() {
      _episodes = const <MediaServerItem>[];
      _nextStartIndex = 0;
      _hasMore = false;
      _episodesLoading = true;
      _episodesLoadingMore = false;
      _episodesError = null;
    });
    try {
      final MediaServerPage page = await _browser.listEpisodes(
        seriesId: widget.item.id,
        seasonId: _seasonId,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _episodes = List<MediaServerItem>.unmodifiable(page.items);
        _nextStartIndex = page.nextStartIndex;
        _hasMore = page.hasMore;
        _episodesLoading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _episodesError = e;
        _episodesLoading = false;
      });
    }
  }

  Future<void> _loadMoreEpisodes() async {
    if (_episodesLoading || _episodesLoadingMore || !_hasMore) return;
    final int generation = _generation;
    setState(() => _episodesLoadingMore = true);
    try {
      final MediaServerPage page = await _browser.listEpisodes(
        seriesId: widget.item.id,
        seasonId: _seasonId,
        startIndex: _nextStartIndex,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _episodes = List<MediaServerItem>.unmodifiable(<MediaServerItem>[
          ..._episodes,
          ...page.items,
        ]);
        _nextStartIndex = page.nextStartIndex;
        _hasMore = page.hasMore;
        _episodesLoadingMore = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      debugPrint('[media-server] more episodes failed: $e');
      setState(() {
        _episodesLoadingMore = false;
        _hasMore = false;
      });
    }
  }

  void _selectSeason(String seasonId) {
    if (seasonId == _seasonId) return;
    setState(() => _seasonId = seasonId);
    unawaited(_reloadEpisodes());
  }

  void _playEpisode(MediaServerItem episode) {
    widget.session.playItem(context, episode, siblings: _episodes);
  }

  /// 「播放」：电影直接播；剧播当前季第一个没看完的集（都看完就第一集）。
  void _playPrimary() {
    if (!_isSeries) {
      widget.session.playItem(context, _detail);
      return;
    }
    if (_episodes.isEmpty) return;
    final MediaServerItem target = _episodes.firstWhere(
      (MediaServerItem e) => !e.played,
      orElse: () => _episodes.first,
    );
    _playEpisode(target);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 本视图是嵌套 Navigator 里的一条路由：没有 Scaffold 就没有 Material 祖先。
    return Scaffold(
      body: Column(
        children: <Widget>[
          FushiPageHeader(
            title: _detail.name,
            compact: true,
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          Expanded(
            child: CustomScrollView(
              key: PageStorageKey<String>(
                '${widget.session.serverId}-detail-${widget.item.id}',
              ),
              controller: _scrollController,
              slivers: <Widget>[
                SliverToBoxAdapter(child: _buildHeader(tokens)),
                if (_isSeries) ...<Widget>[
                  if (_seasons.length > 1)
                    SliverToBoxAdapter(child: _buildSeasonChips(tokens)),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        tokens.spacing.page,
                        tokens.spacing.card,
                        tokens.spacing.page,
                        tokens.spacing.gap,
                      ),
                      child: Text(
                        t.video_episode_list,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ),
                  ..._buildEpisodeSlivers(tokens),
                ],
                SliverToBoxAdapter(
                  child: SizedBox(height: tokens.spacing.section),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(FushiDesignTokens tokens) {
    final ImageProvider? image = mediaServerCoverImage(_browser, _detail);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final List<String> meta = <String>[
      if (_detail.productionYear != null) '${_detail.productionYear}',
      _isSeries ? t.series : t.collection_relation_movie,
      if (!_isSeries &&
          formatMediaServerDuration(_detail.durationMs).isNotEmpty)
        formatMediaServerDuration(_detail.durationMs),
      if (_isSeries && _detail.episodeCount != null)
        t.collection_hero_total_episodes(count: _detail.episodeCount!),
      if (_detail.communityRating != null)
        '★ ${_detail.communityRating!.toStringAsFixed(1)}',
    ];
    final String? overview = _detail.overview?.trim();
    final bool canPlay = !_isSeries || _episodes.isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 140,
                child: ClipRRect(
                  borderRadius: FushiBorderRadius.card,
                  child: AspectRatio(
                    aspectRatio: 2 / 3,
                    child: image == null
                        ? ShelfCoverPlaceholder(
                            icon: _isSeries
                                ? Icons.tv_outlined
                                : Icons.movie_outlined,
                          )
                        : PortraitCoverImage(
                            image: image,
                            errorBuilder: (_) => const ShelfCoverPlaceholder(
                              icon: Icons.broken_image_outlined,
                            ),
                          ),
                  ),
                ),
              ),
              SizedBox(width: tokens.spacing.card),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _detail.name,
                      style: textTheme.headlineSmall,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: tokens.spacing.gap / 2),
                    Text(meta.join(' · '), style: tokens.type.metadata),
                    if (_detail.genres.isNotEmpty) ...<Widget>[
                      SizedBox(height: tokens.spacing.gap),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: <Widget>[
                          for (final String genre in _detail.genres)
                            FushiTagChip(label: genre),
                        ],
                      ),
                    ],
                    SizedBox(height: tokens.spacing.card),
                    FilledButton.icon(
                      key: const ValueKey<String>('media-server-detail-play'),
                      onPressed: canPlay ? _playPrimary : null,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(t.play),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (overview != null && overview.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.card),
            Text(overview, style: textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }

  Widget _buildSeasonChips(FushiDesignTokens tokens) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.card,
        tokens.spacing.page,
        0,
      ),
      child: Wrap(
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: <Widget>[
          for (final MediaServerItem season in _seasons)
            ChoiceChip(
              key: ValueKey<String>('media-server-season-${season.id}'),
              label: Text(
                season.seasonNumber != null
                    ? t.collection_group_season(n: season.seasonNumber!)
                    : season.name,
              ),
              selected: season.id == _seasonId,
              onSelected: (_) => _selectSeason(season.id),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildEpisodeSlivers(FushiDesignTokens tokens) {
    if (_episodesLoading && _episodes.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(tokens.spacing.card),
            child: Center(child: adaptiveIndicator(context: context)),
          ),
        ),
      ];
    }
    if (_episodesError != null && _episodes.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: FushiPlaceholderMessage(
            icon: Icons.cloud_off_outlined,
            message: t.media_server_items_load_failed,
            detail: '$_episodesError',
            action: FilledButton.icon(
              key: const ValueKey<String>('media-server-episodes-retry'),
              onPressed: () => unawaited(_reloadEpisodes()),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(t.retry),
            ),
          ),
        ),
      ];
    }
    if (_episodes.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: FushiPlaceholderMessage(
            icon: Icons.tv_off_outlined,
            message: t.video_episode_list_empty,
          ),
        ),
      ];
    }
    final String prefix = widget.session.serverId;
    return <Widget>[
      SliverList.builder(
        itemCount: _episodes.length,
        itemBuilder: (BuildContext context, int index) {
          final MediaServerItem episode = _episodes[index];
          return _EpisodeRow(
            key: ValueKey<String>('media-server-episode-${episode.id}'),
            browser: _browser,
            episode: episode,
            focusId: FushiFocusId('$prefix-episode-${episode.id}'),
            onTap: () => _playEpisode(episode),
          );
        },
      ),
      if (_episodesLoadingMore)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(tokens.spacing.card),
            child: Center(child: adaptiveIndicator(context: context)),
          ),
        ),
    ];
  }
}

/// 一集：横版缩略图（有 thumb 用 thumb，否则主图）+ `S01E02 · 集名` + 时长 +
/// 已看勾 / 断点进度条。
class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.browser,
    required this.episode,
    required this.onTap,
    this.focusId,
    super.key,
  });

  final MediaServerBrowser browser;
  final MediaServerItem episode;
  final VoidCallback onTap;
  final FushiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? image = mediaServerCoverImage(
      browser,
      episode,
      kind: episode.hasThumb
          ? MediaServerImageKind.thumb
          : MediaServerImageKind.primary,
    );
    final double? progress = mediaServerProgress(episode);
    final String code = episode.episodeCode;
    final String duration = formatMediaServerDuration(episode.durationMs);
    return FushiListItem(
      focusId: focusId,
      onTap: onTap,
      titleMaxLines: 2,
      leading: SizedBox(
        width: 96,
        child: ClipRRect(
          borderRadius: FushiBorderRadius.chip,
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (image == null)
                  const ShelfCoverPlaceholder(
                    icon: Icons.tv_outlined,
                    iconSize: 20,
                  )
                else
                  PortraitCoverImage(
                    image: image,
                    landscapeSlot: true,
                    errorBuilder: (_) => const ShelfCoverPlaceholder(
                      icon: Icons.broken_image_outlined,
                      iconSize: 20,
                    ),
                  ),
                if (progress != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor: Colors.black.withValues(alpha: 0.35),
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      title: Text(code.isEmpty ? episode.name : '$code · ${episode.name}'),
      subtitle: duration.isEmpty ? null : Text(duration),
      trailing: episode.played
          ? Icon(
              Icons.check_circle_rounded,
              color: Theme.of(context).colorScheme.primary,
            )
          : const Icon(Icons.play_arrow_rounded),
    );
  }
}
