import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Native media/WebView callbacks cannot be exercised in a headless unit
/// test. Guard their shared persistence boundaries as well as the runtime
/// manga database test in manga_fushi_page_test.dart.
void main() {
  final String video = File(
    'lib/src/pages/implementations/video_fushi_page.dart',
  ).readAsStringSync();
  final String manga = File(
    'lib/src/media/manga/reader/manga_fushi_page.dart',
  ).readAsStringSync();
  final String episode = File(
    'lib/src/pages/implementations/video_fushi/episode.part.dart',
  ).readAsStringSync();

  test('video persistence and study collection reject review before writing', () {
    for (final String signature in <String>[
      'Future<void> _persistPosition(String uid, int posMs) async {',
      'Future<void> _persistRemotePosition(String uid, int posMs) async {',
      'void _ensureWatchTracker(VideoPlayerController controller, String title) {',
    ]) {
      expect(
        video,
        contains('$signature\n    if (_sourceReviewActive) return;'),
      );
    }
    final int stop = video.indexOf(
      'Future<void> _reportRemotePlaybackStopped(',
    );
    final int stopGuard = video.indexOf(
      'if (_sourceReviewActive) return;',
      stop,
    );
    final int stopRequest = video.indexOf(
      'stopClient.stopRemoteVideoPlayback(',
      stop,
    );
    expect(stopGuard, greaterThan(stop));
    expect(stopGuard, lessThan(stopRequest));
  });

  test(
    'review rejects external negotiation before opening a playback session',
    () {
      final int load = video.indexOf('Future<void> _loadRemoteEpisode(');
      final int policy = video.indexOf('if (_sourceReviewActive)', load);
      final int request = video.indexOf(
        'await client.remoteVideoStreamUrls(',
        load,
      );
      expect(policy, greaterThan(load));
      expect(policy, lessThan(request));
      expect(video.substring(policy, request), contains('return;'));
      expect(video, contains('autoPlay: !_sourceReviewActive'));
      final int streamBook = video.indexOf('if (isStreamVideoBook(row))');
      final int earlyGuard = video.indexOf(
        'if (_sourceReviewActive)',
        streamBook,
      );
      final int webpagePlayer = video.indexOf(
        'WebVideoFushiPage.neutralized(',
        streamBook,
      );
      expect(earlyGuard, greaterThan(streamBook));
      expect(earlyGuard, lessThan(webpagePlayer));
      expect(video.substring(earlyGuard, webpagePlayer), contains('return;'));
    },
  );

  test(
    'review completion never advances and manual episode changes keep session',
    () {
      expect(
        episode,
        contains(
          'void _handlePlaybackCompleted() {\n    if (_sourceReviewActive) return;',
        ),
      );
      expect(episode, contains('sourceReviewSession: _sourceReviewSession'));
    },
  );

  test('video external navigation never pops a covering dialog', () {
    final int close = video.indexOf(
      'Future<bool> _closeForExternalNavigation()',
    );
    final int modalGuard = video.indexOf('if (route == null ||', close);
    final int pause = video.indexOf('await controller?.pause();', close);
    final int pop = video.indexOf('navigator.pop();', close);
    expect(modalGuard, greaterThan(close));
    expect(modalGuard, lessThan(pause));
    expect(video.substring(modalGuard, pause), contains('return false;'));
    expect(
      video.substring(close, pop),
      contains('if (!route.isCurrent) return false;'),
    );
  });

  test(
    'manga review gates positions, chapter state and the reading ledger',
    () {
      for (final String signature in <String>[
        'void _noteVisiblePages() {',
        'void _ensureStudyClock(FushiDatabase db) {',
        'Future<void> _persistPosition(int page, double fraction) async {',
        'Future<void> _saveCurrentChapterState({int? readAt}) async {',
        'Future<void> _flushReadingStats() async {',
      ]) {
        expect(
          manga,
          contains('$signature\n    if (_sourceReviewActive) return;'),
        );
      }
      expect(manga, contains('entry.copyWith(currentChapterIndex: index)'));
      expect(manga, contains('chapter.key == widget.sourceReview!.chapterId'));
      expect(manga, contains('_readLedger.reset();'));
    },
  );
}
