part of '../video_fushi_page.dart';

/// Reuses the subtitle panel's representative-row rules outside its widget.
/// Only subtitle/track changes rebuild rows; position ticks read the cache.
class _VideoRemoteCueCache {
  List<AudioCue>? _primary;
  List<AudioCue>? _secondary;
  String? _key;
  int _primaryLength = -1;
  int _secondaryLength = -1;
  List<VideoRemoteCue> _rows = <VideoRemoteCue>[];

  List<VideoRemoteCue> read(
    VideoPlayerController controller,
    String? primarySource,
    String? secondarySource,
  ) {
    final String key =
        '$primarySource|$secondarySource|${controller.delayMs}|'
        '${controller.effectiveSecondaryDelayMs}';
    if (identical(_primary, controller.cues) &&
        identical(_secondary, controller.secondaryCues) &&
        _primaryLength == controller.cues.length &&
        _secondaryLength == controller.secondaryCues.length &&
        _key == key) {
      return _rows;
    }
    _primary = controller.cues;
    _secondary = controller.secondaryCues;
    _primaryLength = controller.cues.length;
    _secondaryLength = controller.secondaryCues.length;
    _key = key;
    _rows =
        <VideoRemoteCue>[
          ..._trackRows(controller.cues, 'primary', controller.delayMs),
          ..._trackRows(
            controller.secondaryCues,
            'secondary',
            controller.effectiveSecondaryDelayMs,
          ),
        ]..sort((VideoRemoteCue a, VideoRemoteCue b) {
          final int time = (a.startMs + a.delayMs).compareTo(
            b.startMs + b.delayMs,
          );
          return time != 0 ? time : a.id.compareTo(b.id);
        });
    return _rows;
  }

  List<VideoRemoteCue> _trackRows(
    List<AudioCue> cues,
    String track,
    int delay,
  ) {
    final rows = subtitleTranscriptRows(cues);
    return <VideoRemoteCue>[
      for (final int rawIndex in rows.indexes)
        VideoRemoteCue(
          id: '$track:$rawIndex',
          text: (rows.mergedByRep[rawIndex] ?? cues[rawIndex]).text,
          startMs: (rows.mergedByRep[rawIndex] ?? cues[rawIndex]).startMs,
          endMs: (rows.mergedByRep[rawIndex] ?? cues[rawIndex]).endMs,
          delayMs: delay,
          track: track,
        ),
    ];
  }
}

extension _VideoRemoteControl on _VideoFushiPageState {
  void _unregisterVideoRemote() {
    final VideoRemotePlaybackBinding? binding = _videoRemoteBinding;
    if (binding != null) appModel.videoRemoteHost.unregister(binding);
    _videoRemoteBinding = null;
  }

  void _registerVideoRemote(VideoPlayerController controller) {
    _unregisterVideoRemote();
    final VideoRemotePlaybackBinding binding = VideoRemotePlaybackBinding(
      identity: () =>
          '$_activeBookUid|$_currentEpisode|$_currentVideoPath|'
          '${controller.miningSource}',
      title: () => _videoMiningDocumentTitle() ?? '',
      bookUid: () => _activeBookUid,
      sectionIndex: () => _favoriteSectionIndex ?? 0,
      cues: () => _videoRemoteCueCache.read(
        controller,
        _currentSubtitleSource,
        _currentSecondarySubtitleSource,
      ),
      state: () => <String, Object?>{
        'positionMs': controller.positionMs ?? 0,
        'durationMs': controller.durationMs ?? 0,
        'playing': controller.isPlaying,
        'speed': controller.speed,
        'controlRevision': controller.remoteControlRevision,
        'primaryTrack': controller.activeSubtitleTrackId,
        'secondaryTrack': controller.secondaryCues.isNotEmpty
            ? 'secondary'
            : null,
        'primaryDelayMs': controller.delayMs,
        'secondaryDelayMs': controller.effectiveSecondaryDelayMs,
      },
      command: (String action, Map<String, dynamic> body) async {
        switch (action) {
          case 'play':
            await controller.play();
          case 'pause':
            await controller.pause();
          case 'seek':
          case 'seekCue':
            final int position = (body['positionMs'] as num).toInt();
            await controller.seekMs(
              position.clamp(0, controller.durationMs ?? position),
            );
            if (action == 'seekCue') await controller.play();
          default:
            throw ArgumentError.value(action, 'action');
        }
      },
      mine: _mineRemoteVideoCue,
      openFavorite: _openRemoteVideoFavorite,
      addListener: controller.addListener,
      removeListener: controller.removeListener,
      favoritesChanged: _refreshFavoritedCueCache,
    );
    _videoRemoteBinding = binding;
    appModel.videoRemoteHost.register(binding);
  }

  Future<Map<String, Object?>> _mineRemoteVideoCue(
    VideoRemoteCue cue,
    Map<String, dynamic> request,
  ) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null || !mounted) {
      throw StateError('Video session closed');
    }
    if (controller.isBlurayNavigationSession &&
        (!controller.discMiningAvailable || _discLearningBlocked)) {
      throw StateError(
        controller.discMiningUnavailableReason ?? 'Disc extraction unavailable',
      );
    }
    final Map<String, String> fields = <String, String>{
      for (final MapEntry<dynamic, dynamic> entry
          in (request['rawFields'] as Map).entries)
        entry.key.toString(): entry.value.toString(),
    };
    if ((fields['expression'] ?? '').trim().isEmpty) {
      throw ArgumentError('A dictionary expression is required');
    }
    final AudioPlaybackRange padded = padSentenceRange(
      AudioPlaybackRange(
        audioFileIndex: 0,
        startMs: cue.startMs,
        endMs: cue.endMs,
      ),
      cues: cue.track == 'secondary'
          ? controller.secondaryCues
          : controller.cues,
      headPadMs: appModel.miningAudioHeadPadMs,
      tailPadMs: appModel.miningAudioTailPadMs,
    );
    final String sentence = request['sentence'] as String? ?? cue.text;
    final VideoMiningHistorySnapshot history =
        VideoMiningHistorySnapshot.capture(
          fields: fields,
          sentence: sentence,
          documentTitle: _title ?? _activeBookUid,
          bookKey: _activeBookUid,
          sectionIndex: _favoriteSectionIndex,
          cueStartMs: cue.startMs,
          cueEndMs: cue.endMs,
          dateKey: statTodayKey(),
        );
    final FushiDatabase historyDb = appModel.database;
    String? error;
    final MinePopupResult result = await _mineVideoCard(
      fields: fields,
      clipStartMs: miningClipTimeMs(padded.startMs, cue.delayMs),
      clipEndMs: miningClipTimeMs(padded.endMs, cue.delayMs),
      stillFrameAtMs: miningClipTimeMs(cue.startMs, cue.delayMs),
      sentence: sentence,
      cueSentence: cue.text,
      silent: true,
      forceForeground: true,
      forceSubtitleStart: true,
      localOnly: true,
      onFailure: (String code) => error = code,
    );
    if (result.ankiConnect) {
      await _recordMinedSentenceForVideo(history, result.noteId, db: historyDb);
    }
    return <String, Object?>{
      ...result.toJson(),
      'success': result.ankiConnect,
      if (error != null) 'error': error,
    };
  }

  Future<void> _openRemoteVideoFavorite(FavoriteSentence favorite) async {
    final String? uid = favorite.bookKey;
    if (uid == null || uid.isEmpty) {
      throw StateError('Favorite has no video source');
    }
    if (uid == _activeBookUid &&
        _isRemote &&
        (favorite.sectionIndex ?? 0) != (_favoriteSectionIndex ?? 0)) {
      final int episode = favorite.sectionIndex ?? 0;
      if (episode < 0 || episode >= _episodes.length) {
        throw StateError('Favorite episode is unavailable');
      }
      await _controller?.pause();
      if (!mounted) throw StateError('Video session closed');
      await _loadRemoteEpisode(
        episode,
        startIntent: EpisodeStartIntent.explicitCue,
        initialPositionMsOverride: favorite.normCharOffset,
      );
      if (_controller == null || _failed) {
        throw StateError('Favorite episode failed to load');
      }
      await _openRemoteVideoFavorite(favorite);
      return;
    }
    if (uid == _activeBookUid &&
        (favorite.sectionIndex ?? 0) == (_favoriteSectionIndex ?? 0)) {
      final VideoPlayerController? controller = _controller;
      if (controller == null) throw StateError('Video session closed');
      final List<VideoRemoteCue> rows = _videoRemoteCueCache.read(
        controller,
        _currentSubtitleSource,
        _currentSecondarySubtitleSource,
      );
      final List<VideoRemoteCue> candidates = rows
          .where(
            (VideoRemoteCue item) =>
                (favorite.normCharOffset == null ||
                    item.startMs == favorite.normCharOffset) &&
                item.text.trim() == favorite.text.trim(),
          )
          .toList();
      if (candidates.isEmpty && favorite.normCharOffset != null) {
        candidates.addAll(
          rows.where(
            (VideoRemoteCue item) => item.startMs == favorite.normCharOffset,
          ),
        );
      }
      if (candidates.length > 1) {
        throw StateError('Favorite subtitle track is ambiguous');
      }
      final VideoRemoteCue? cue = candidates.firstOrNull;
      if (cue == null) throw StateError('Favorite subtitle is unavailable');
      await controller.seekMs(miningClipTimeMs(cue.startMs, cue.delayMs));
      await controller.play();
      return;
    }
    final VideoBookRow? row = await widget.repo.getByBookUid(uid);
    if (row == null) throw StateError('Favorite video source is unavailable');
    if (await isLocalVideoResourceMissing(row.videoPath)) {
      throw StateError('Favorite video file is unavailable');
    }
    final Map<String, int> collections = await appModel.database
        .getPrimaryCollectionIdByEntry();
    if (!context.mounted) throw StateError('Video session closed');
    final PageRoute<void>? oldFullscreenRoute = _videoFullscreenRoute;
    final NavigatorState navigator = Navigator.of(context);
    final NavigatorState rootNavigator = Navigator.of(
      context,
      rootNavigator: true,
    );
    final Route<Object?>? currentRoute = ModalRoute.of(context);
    final EpisodeSwitchPlan plan = resolveEpisodeSwitchPlan(
      fullscreenRouteActive: oldFullscreenRoute?.isActive ?? false,
      ownsHandedOverNativeFullscreen: _ownsHandedOverNativeFullscreen,
      hasCurrentRoute: currentRoute != null,
    );
    await _controller?.pause();
    if (!context.mounted) throw StateError('Video session closed');
    final Route<void> route = adaptivePageRoute<void>(
      context: context,
      builder: (_) => VideoFushiPage.neutralized(
        bookUid: uid,
        repo: widget.repo,
        playlistCollectionId: collections[MediaKind.video.compositeKey(uid)],
        initialRemoteFavorite: favorite,
        initialEpisodeIndex: favorite.sectionIndex,
        initialSubtitleListVisible: false,
        initialFullscreen: plan.handOverNativeFullscreen,
      ),
    );
    _unregisterVideoRemote();
    if (plan.mode == EpisodeSwitchMode.replace) {
      unawaited(navigator.pushReplacement<void, void>(route));
      return;
    }
    _ownsHandedOverNativeFullscreen = false;
    _didInitialFullscreen = true;
    unawaited(navigator.push<void>(route));
    if (oldFullscreenRoute != null && oldFullscreenRoute.isActive) {
      rootNavigator.removeRoute<void>(oldFullscreenRoute);
    }
    navigator.removeRoute<Object?>(currentRoute!);
  }
}
