import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';
import 'package:fushi_engine/sync/video_remote_session_core.dart';

/// A normalized list sentence, retaining its own subtitle clock.
final class VideoRemoteCue {
  const VideoRemoteCue({
    required this.id,
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.delayMs,
    required this.track,
  });
  final String id;
  final String text;
  final int startMs;
  final int endMs;
  final int delayMs;
  final String track;
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'text': text,
    'startMs': startMs,
    'endMs': endMs,
    'delayMs': delayMs,
    'track': track,
  };
}

/// App-owned callbacks; the HTTP layer never sees media paths or widget state.
final class VideoRemotePlaybackBinding {
  const VideoRemotePlaybackBinding({
    required this.identity,
    required this.title,
    required this.bookUid,
    required this.sectionIndex,
    required this.cues,
    required this.state,
    required this.command,
    required this.mine,
    required this.openFavorite,
    required this.addListener,
    required this.removeListener,
    this.favoritesChanged,
  });
  final String Function() identity;
  final String Function() title;
  final String Function() bookUid;
  final int Function() sectionIndex;
  final List<VideoRemoteCue> Function() cues;
  final Map<String, Object?> Function() state;
  final Future<void> Function(String, Map<String, dynamic>) command;
  final Future<Map<String, Object?>> Function(
    VideoRemoteCue,
    Map<String, dynamic>,
  )
  mine;
  final Future<void> Function(FavoriteSentence) openFavorite;
  final void Function(VoidCallback) addListener;
  final void Function(VoidCallback) removeListener;
  final Future<void> Function()? favoritesChanged;
}

/// One selected desktop player, one authenticated controller and fixed drafts.
final class VideoRemoteHost implements VideoRemoteService {
  VideoRemoteHost({
    required FavoriteSentenceRepository Function() favorites,
    Stream<String?> Function()? favoriteChanges,
    DateTime Function()? now,
  }) : _favorites = favorites,
       _favoriteChanges = favoriteChanges,
       _now = now ?? DateTime.now {
    _core = VideoRemoteSessionCore(now: _now, onLeaseExpired: _expireLookup);
  }
  final FavoriteSentenceRepository Function() _favorites;
  final Stream<String?> Function()? _favoriteChanges;
  StreamSubscription<String?>? _favoriteSubscription;
  final DateTime Function() _now;
  late final VideoRemoteSessionCore _core;
  VideoRemotePlaybackBinding? _binding;
  String? _identity;
  String _sessionId = '';
  int _serial = 0;
  int _subtitleVersion = 0;
  int _favoriteVersion = 0;
  String? _playbackError;
  List<VideoRemoteCue> _cues = const <VideoRemoteCue>[];
  Map<String, VideoRemoteCue> _cueMap = <String, VideoRemoteCue>{};
  Map<String, Object?> _lastState = <String, Object?>{};
  DateTime? _lastPublish;
  _RemoteLookup? _lookup;
  final Map<String, _RemoteMineTask> _tasks = <String, _RemoteMineTask>{};
  Future<void> _mutationTail = Future<void>.value();

  void register(VideoRemotePlaybackBinding binding) {
    final VideoRemotePlaybackBinding? old = _binding;
    if (old != null) {
      old.removeListener(_changed);
    }
    _binding = binding;
    _identity = null;
    _playbackError = null;
    _lookup = null;
    binding.addListener(_changed);
    _refresh();
    _publish();
  }

  void unregister(VideoRemotePlaybackBinding binding) {
    if (!identical(binding, _binding)) {
      return;
    }
    binding.removeListener(_changed);
    _binding = null;
    _identity = null;
    _lookup = null;
    _cues = const <VideoRemoteCue>[];
    _cueMap.clear();
    _sessionId = '';
    _publish();
  }

  void reportError(String code) {
    _playbackError = code;
    _publish();
  }

  void _refresh() {
    final VideoRemotePlaybackBinding? binding = _binding;
    if (binding == null) {
      return;
    }
    final String identity = binding.identity();
    final List<VideoRemoteCue> next = binding.cues();
    if (identity != _identity) {
      _identity = identity;
      _sessionId = '${_now().microsecondsSinceEpoch}_${++_serial}';
      _lookup = null;
      _subtitleVersion++;
      _cues = next;
      _cueMap = <String, VideoRemoteCue>{
        for (final VideoRemoteCue cue in next) cue.id: cue,
      };
    } else if (!identical(next, _cues)) {
      _subtitleVersion++;
      // Track/clock changes invalidate the draft and its resume permission.
      // Never schedule an asynchronous play that can overtake the next lookup.
      _lookup = null;
      _cues = next;
      _cueMap = <String, VideoRemoteCue>{
        for (final VideoRemoteCue cue in next) cue.id: cue,
      };
    }
  }

  void _changed() {
    // No phone subscribed: do not compute transcript views on every video tick.
    if (_core.owner == null) {
      return;
    }
    final String oldSession = _sessionId;
    final int oldVersion = _subtitleVersion;
    _refresh();
    final Map<String, Object?> state = _binding?.state() ?? <String, Object?>{};
    final bool immediate =
        oldSession != _sessionId ||
        oldVersion != _subtitleVersion ||
        state['playing'] != _lastState['playing'] ||
        state['speed'] != _lastState['speed'] ||
        state['controlRevision'] != _lastState['controlRevision'];
    if (immediate ||
        _lastPublish == null ||
        _now().difference(_lastPublish!) >= const Duration(seconds: 1)) {
      _publish();
    }
  }

  Map<String, Object?> _snapshot() => <String, Object?>{
    'available': _binding != null, 'revision': _core.revision,
    'sessionId': _sessionId, 'subtitleVersion': _subtitleVersion,
    'favoriteVersion': _favoriteVersion, 'title': _binding?.title() ?? '',
    if (_playbackError != null) 'error': _playbackError,
    // Public library identity only, never local paths or signed media URLs.
    'identity': _binding?.bookUid() ?? '', 'cueCount': _cues.length,
    'sectionIndex': _binding?.sectionIndex(),
    ...?_binding?.state(),
  };

  void _publish() {
    _lastState = _binding?.state() ?? <String, Object?>{};
    _lastPublish = _now();
    _core.publish('state', _snapshot());
  }

  VideoRemotePlaybackBinding _requireSession(Map<String, dynamic> body) {
    _refresh();
    final VideoRemotePlaybackBinding? binding = _binding;
    if (binding == null) {
      throw const VideoRemoteException(409, 'no_video');
    }
    if (body['sessionId'] != _sessionId) {
      throw const VideoRemoteException(409, 'session_changed');
    }
    if (body['subtitleVersion'] != _subtitleVersion) {
      throw const VideoRemoteException(409, 'subtitles_changed');
    }
    return binding;
  }

  VideoRemoteCue _requireCue(Map<String, dynamic> body) {
    final VideoRemoteCue? cue = _cueMap[body['cueId']];
    if (cue == null) {
      throw const VideoRemoteException(404, 'cue_missing');
    }
    return cue;
  }

  @override
  Future<Map<String, Object?>> handle(
    String operation,
    Map<String, dynamic> body,
    String peerId,
  ) async {
    if (operation == 'snapshot') {
      await _core.acquire(peerId);
      _favoriteSubscription ??= _favoriteChanges?.call().listen((String? _) {
        _favoriteVersion++;
        final Future<void> Function()? changed = _binding?.favoritesChanged;
        if (changed != null) {
          unawaited(
            changed().catchError((Object error, StackTrace stack) {
              debugPrint(
                'Video remote favorite cache refresh failed: $error\n$stack',
              );
            }),
          );
        }
        _publish();
      });
      _refresh();
      return _snapshot();
    }
    await _core.assertOwner(peerId);
    if (operation == 'events') {
      return _core.events(
        _integer(body, 'afterRevision', 0),
        waitMs: _integer(body, 'waitMs', 25000).clamp(0, 25000),
      );
    }
    if (operation == 'subtitles') {
      _requireSession(body);
      final int offset = _integer(body, 'offset', 0).clamp(0, _cues.length);
      final int limit = _integer(body, 'limit', 200).clamp(1, 200);
      final List<FavoriteSentence> favorites = await _favorites().getAll();
      _requireSession(body);
      return <String, Object?>{
        'offset': offset,
        'total': _cues.length,
        'subtitleVersion': _subtitleVersion,
        'cues': _cues
            .skip(offset)
            .take(limit)
            .map(
              (VideoRemoteCue cue) => <String, Object?>{
                ...cue.toJson(),
                'favorited': favorites.any(
                  (FavoriteSentence favorite) => _matches(favorite, cue),
                ),
              },
            )
            .toList(),
      };
    }
    if (operation == 'favorites') {
      return _listFavorites(body);
    }
    if (operation == 'mineStatus') {
      _RemoteMineTask? task = _tasks[body['taskId']];
      if (task == null && body['requestId'] is String) {
        for (final _RemoteMineTask candidate in _tasks.values) {
          if (candidate.peerId == peerId &&
              candidate.requestId == body['requestId']) {
            task = candidate;
            break;
          }
        }
      }
      if (task == null || task.peerId != peerId) {
        throw const VideoRemoteException(404, 'task_missing');
      }
      return task.toJson();
    }
    if (!videoRemoteOperations.contains(operation)) {
      throw const VideoRemoteException(404, 'unknown_operation');
    }
    final String requestId = body['requestId'] is String
        ? body['requestId'] as String
        : '';
    final String fingerprint = _fingerprint(operation, body);
    if (operation == 'mine') {
      // Mining outlives the generic request journal. Preserve retry identity
      // while the accepted task is still available to mineStatus.
      for (final _RemoteMineTask task in _tasks.values) {
        if (task.peerId == peerId && task.requestId == requestId) {
          if (task.fingerprint != fingerprint) {
            throw const VideoRemoteException(409, 'request_id_conflict');
          }
          return task.toJson();
        }
      }
    }
    return _core.runIdempotent(
      peerId,
      requestId,
      () => _serialize(() async {
        // Queued commands revalidate their owner/session at execution time.
        await _core.assertOwner(peerId);
        return _mutate(operation, body, peerId);
      }),
      fingerprint: fingerprint,
    );
  }

  Future<Map<String, Object?>> _serialize(
    Future<Map<String, Object?>> Function() action,
  ) {
    final Future<Map<String, Object?>> result = _mutationTail.then(
      (_) => action(),
    );
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<Map<String, Object?>> _mutate(
    String operation,
    Map<String, dynamic> body,
    String peerId,
  ) async {
    final int leaseGeneration = _core.leaseGeneration;
    if (operation == 'disconnect') {
      await _expireLookup(peerId);
      _core.release(peerId);
      return <String, Object?>{'ok': true};
    }
    if (operation == 'lookupEnd') {
      final _RemoteLookup? lookup = _lookup;
      if (lookup != null &&
          lookup.peerId == peerId &&
          body['contextId'] == lookup.id) {
        _lookup = null;
        await _resume(lookup);
      }
      return <String, Object?>{'ok': true};
    }
    if (operation == 'favoritesRemove') {
      final Object? ids = body['ids'];
      if (ids is! List ||
          ids.length > 200 ||
          ids.any((Object? id) => id is! String)) {
        throw const VideoRemoteException(400, 'invalid_favorites');
      }
      final FavoriteSentenceRepository repo = _favorites();
      final List<FavoriteSentence> all = await repo.getAll();
      for (final FavoriteSentence favorite in all) {
        if (favorite.source == kFavoriteSentenceSourceVideo &&
            ids.contains(favorite.id)) {
          await repo.removeById(favorite.id);
        }
      }
      _favoriteVersion++;
      _publish();
      return <String, Object?>{'ok': true, 'favoriteVersion': _favoriteVersion};
    }
    if (operation == 'openFavorite') {
      final List<FavoriteSentence> all = await _favorites().getAll();
      final FavoriteSentence favorite = all.firstWhere(
        (FavoriteSentence favorite) =>
            favorite.id == body['id'] &&
            favorite.source == kFavoriteSentenceSourceVideo,
        orElse: () => throw const VideoRemoteException(404, 'favorite_missing'),
      );
      final VideoRemotePlaybackBinding? binding = _binding;
      if (binding == null) {
        throw const VideoRemoteException(409, 'no_video');
      }
      _lookup = null;
      await binding.openFavorite(favorite);
      _refresh();
      _publish();
      return <String, Object?>{'ok': true};
    }
    if (operation == 'mine') {
      final String fingerprint = _fingerprint(operation, body);
      final _RemoteLookup? lookup = _lookup;
      _refresh();
      if (lookup == null ||
          lookup != _lookup ||
          lookup.peerId != peerId ||
          lookup.id != body['contextId'] ||
          lookup.sessionId != _sessionId ||
          lookup.subtitleVersion != _subtitleVersion) {
        throw const VideoRemoteException(409, 'lookup_expired');
      }
      final Object? fields = body['fields'];
      if (fields is! Map<String, dynamic>) {
        throw const VideoRemoteException(400, 'invalid_fields');
      }
      if (_tasks.values.any(
        (_RemoteMineTask task) => task.status == 'running',
      )) {
        throw const VideoRemoteException(429, 'mining_busy');
      }
      if (_tasks.length >= 128) {
        _tasks.remove(_tasks.keys.first);
      }
      // The original peer/request can query this task after the draft closes.
      final String id = 'mine_${++_serial}';
      final _RemoteMineTask task = _RemoteMineTask(
        id,
        peerId,
        body['requestId'] as String,
        fingerprint,
      );
      _tasks[id] = task;
      final VideoRemotePlaybackBinding binding = lookup.binding;
      final Future<Map<String, Object?>> work =
          Future<Map<String, Object?>>.sync(
            () => binding.mine(lookup.cue, fields),
          );
      unawaited(
        work.then<void>(
          (Map<String, Object?> result) {
            task.result = result;
            task.status = result['success'] == true ? 'succeeded' : 'failed';
            if (task.status == 'failed') {
              task.error = result['error']?.toString() ?? 'mining_failed';
            }
            _core.publish('mine', task.toJson());
          },
          onError: (Object error, StackTrace stack) {
            task.status = 'failed';
            task.error = 'mining_failed';
            debugPrint('Video remote mining failed: $error\n$stack');
            _core.publish('mine', task.toJson());
          },
        ),
      );
      return task.toJson();
    }
    final VideoRemotePlaybackBinding binding = _requireSession(body);
    if (operation == 'command') {
      final String action = body['action']?.toString() ?? '';
      if (!<String>{'play', 'pause', 'seek', 'seekCue'}.contains(action)) {
        throw const VideoRemoteException(400, 'invalid_action');
      }
      _lookup = null; // Explicit playback intent supersedes automatic resume.
      final Map<String, dynamic> command = <String, dynamic>{};
      if (action == 'seekCue') {
        final VideoRemoteCue cue = _requireCue(body);
        command['positionMs'] = (cue.startMs + cue.delayMs).clamp(0, 1 << 30);
      } else if (action == 'seek') {
        command['positionMs'] = _integer(
          body,
          'positionMs',
          0,
        ).clamp(0, 1 << 30);
      }
      await binding.command(action, command);
      _publish();
      return <String, Object?>{'ok': true};
    }
    final VideoRemoteCue cue = _requireCue(body);
    if (operation == 'lookupBegin') {
      final _RemoteLookup? previous = _lookup;
      if (previous != null) {
        _lookup = null;
        await _resume(previous);
        await _core.assertOwner(peerId);
        _requireLease(peerId, leaseGeneration);
        _requireSession(body);
      }
      final Map<String, Object?> before = binding.state();
      final bool wasPlaying = before['playing'] == true;
      final int beforeControl =
          (before['controlRevision'] as num?)?.toInt() ?? 0;
      if (wasPlaying) {
        await binding.command('pause', <String, dynamic>{});
      }
      final int control =
          (binding.state()['controlRevision'] as num?)?.toInt() ?? 0;
      final _RemoteLookup lookup = _RemoteLookup(
        'lookup_${++_serial}',
        peerId,
        body['sessionId'] as String,
        body['subtitleVersion'] as int,
        binding,
        cue,
        wasPlaying && control == beforeControl + 1,
        control,
      );
      try {
        await _core.assertOwner(peerId);
        _requireLease(peerId, leaseGeneration);
        _requireSession(body);
        if (!identical(binding, _binding)) {
          throw const VideoRemoteException(409, 'session_changed');
        }
      } catch (_) {
        // Expiry/host stop can clean up before an in-flight pause completes.
        // Undo only that pause, subject to the same local intent safeguards.
        await _resume(lookup);
        rethrow;
      }
      _lookup = lookup;
      _publish();
      return <String, Object?>{
        'contextId': lookup.id,
        'cue': cue.toJson(),
        'sentence': cue.text,
      };
    }
    if (operation == 'favoriteSet') {
      if (body['favorited'] is! bool) {
        throw const VideoRemoteException(400, 'invalid_favorite');
      }
      final FavoriteSentenceRepository repo = _favorites();
      final List<FavoriteSentence> all = await repo.getAll();
      await _core.assertOwner(peerId);
      _requireLease(peerId, leaseGeneration);
      _requireSession(body);
      if (!identical(binding, _binding)) {
        throw const VideoRemoteException(409, 'session_changed');
      }
      final List<FavoriteSentence> matches = all
          .where((FavoriteSentence favorite) => _matches(favorite, cue))
          .toList();
      if (body['favorited'] == true && matches.isEmpty) {
        await repo.add(
          FavoriteSentence(
            text: cue.text,
            bookTitle: binding.title(),
            createdAt: _now(),
            bookKey: binding.bookUid(),
            sectionIndex: binding.sectionIndex(),
            normCharOffset: cue.startMs,
            normCharLength: cue.endMs - cue.startMs,
            source: kFavoriteSentenceSourceVideo,
            dateKey: _now().toIso8601String().substring(0, 10),
          ),
        );
      } else if (body['favorited'] == false) {
        for (final FavoriteSentence favorite in matches) {
          await repo.removeById(favorite.id);
        }
      }
      _favoriteVersion++;
      _publish();
      return <String, Object?>{
        'favorited': body['favorited'],
        'favoriteVersion': _favoriteVersion,
      };
    }
    throw const VideoRemoteException(404, 'unknown_operation');
  }

  void _requireLease(String peerId, int leaseGeneration) {
    if (_core.owner != peerId || _core.leaseGeneration != leaseGeneration) {
      throw const VideoRemoteException(409, 'controller_lease_lost');
    }
  }

  bool _matches(FavoriteSentence favorite, VideoRemoteCue cue) =>
      favorite.source == kFavoriteSentenceSourceVideo &&
      favorite.bookKey == _binding?.bookUid() &&
      favorite.text == cue.text &&
      (favorite.sectionIndex == null ||
          favorite.sectionIndex == _binding?.sectionIndex()) &&
      (favorite.normCharOffset == null ||
          favorite.normCharOffset == cue.startMs);

  Future<Map<String, Object?>> _listFavorites(Map<String, dynamic> body) async {
    final String query = (body['query']?.toString() ?? '').toLowerCase();
    final List<FavoriteSentence> all = (await _favorites().getAll())
        .where(
          (FavoriteSentence favorite) =>
              favorite.source == kFavoriteSentenceSourceVideo &&
              (body['currentOnly'] != true ||
                  (favorite.bookKey == _binding?.bookUid() &&
                      (favorite.sectionIndex == null ||
                          favorite.sectionIndex ==
                              _binding?.sectionIndex()))) &&
              (query.isEmpty ||
                  favorite.text.toLowerCase().contains(query) ||
                  favorite.bookTitle.toLowerCase().contains(query)),
        )
        .toList();
    final int offset = _integer(body, 'offset', 0).clamp(0, all.length);
    final int limit = _integer(body, 'limit', 200).clamp(1, 200);
    return <String, Object?>{
      'total': all.length,
      'favoriteVersion': _favoriteVersion,
      'items': all
          .skip(offset)
          .take(limit)
          .map(
            (FavoriteSentence favorite) => <String, Object?>{
              'id': favorite.id,
              'text': favorite.text,
              'title': favorite.bookTitle,
              'bookUid': favorite.bookKey,
              'sectionIndex': favorite.sectionIndex,
              'startMs': favorite.normCharOffset,
            },
          )
          .toList(),
    };
  }

  Future<void> _expireLookup(String peerId) async {
    await _favoriteSubscription?.cancel();
    _favoriteSubscription = null;
    final _RemoteLookup? lookup = _lookup;
    if (lookup == null || lookup.peerId != peerId) {
      return;
    }
    _lookup = null;
    await _resume(lookup);
  }

  Future<void> _resume(_RemoteLookup lookup) async {
    _refresh();
    if (!lookup.resume ||
        !identical(lookup.binding, _binding) ||
        lookup.sessionId != _sessionId ||
        lookup.subtitleVersion != _subtitleVersion ||
        lookup.binding.identity() != _identity) {
      return;
    }
    final Map<String, Object?> state = lookup.binding.state();
    if (state['playing'] == false &&
        state['controlRevision'] == lookup.controlRevision) {
      await lookup.binding.command('play', <String, dynamic>{});
      _publish();
    }
  }

  Future<void> dispose() async {
    await releaseController();
    _binding?.removeListener(_changed);
    _binding = null;
    _core.dispose();
  }

  /// Hosting can be stopped and restarted while the local player stays open.
  Future<void> releaseController() async {
    final String? owner = _core.owner;
    if (owner == null) {
      return;
    }
    await _expireLookup(owner);
    _core.release(owner);
  }
}

int _integer(Map<String, dynamic> body, String key, int fallback) {
  final Object? value = body[key];
  if (value == null) {
    return fallback;
  }
  if (value is! int) {
    throw const VideoRemoteException(400, 'invalid_number');
  }
  return value;
}

Object? _canonical(Object? value) {
  if (value is Map<String, dynamic>) {
    final List<String> keys = value.keys.toList()..sort();
    return <String, Object?>{
      for (final String key in keys) key: _canonical(value[key]),
    };
  }
  if (value is List) {
    return value.map(_canonical).toList();
  }
  return value;
}

String _fingerprint(String operation, Map<String, dynamic> body) => sha256
    .convert(utf8.encode(jsonEncode(<Object?>[operation, _canonical(body)])))
    .toString();

final class _RemoteLookup {
  const _RemoteLookup(
    this.id,
    this.peerId,
    this.sessionId,
    this.subtitleVersion,
    this.binding,
    this.cue,
    this.resume,
    this.controlRevision,
  );
  final String id, peerId, sessionId;
  final int subtitleVersion, controlRevision;
  final VideoRemotePlaybackBinding binding;
  final VideoRemoteCue cue;
  final bool resume;
}

final class _RemoteMineTask {
  _RemoteMineTask(this.id, this.peerId, this.requestId, this.fingerprint);
  final String id, peerId, requestId, fingerprint;
  String status = 'running';
  Map<String, Object?>? result;
  String? error;
  Map<String, Object?> toJson() => <String, Object?>{
    'taskId': id,
    'status': status,
    if (result != null) 'result': result,
    if (error != null) 'error': error,
  };
}
