import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';

void main() {
  late FushiDatabase db;
  late FavoriteSentenceRepository favorites;
  late VideoRemoteHost host;
  late _Player player;
  late DateTime now;
  late Map<String, Object?> snapshot;
  int serial = 0;

  Future<Map<String, Object?>> call(
    String operation, [
    Map<String, dynamic> data = const <String, dynamic>{},
  ]) => host.handle(operation, <String, dynamic>{
    'sessionId': snapshot['sessionId'],
    'subtitleVersion': snapshot['subtitleVersion'],
    'requestId': 'request_${++serial}',
    ...data,
  }, 'phone');

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    favorites = _BlockingFavorites(db);
    now = DateTime(2026, 10, 12);
    player = _Player();
    host = VideoRemoteHost(favorites: () => favorites, now: () => now);
    host.register(player.binding);
    snapshot = await host.handle('snapshot', <String, dynamic>{}, 'phone');
  });
  tearDown(() async {
    await host.dispose();
    await db.close();
  });

  test('lookup pauses and only resumes playback it owns', () async {
    final Map<String, Object?> lookup = await call(
      'lookupBegin',
      <String, dynamic>{'cueId': 'primary'},
    );
    expect(player.playing, false);
    expect(player.commands, <String>['pause']);
    await call('lookupEnd', <String, dynamic>{
      'contextId': lookup['contextId'],
    });
    expect(player.playing, true);
    expect(player.commands, <String>['pause', 'play']);

    player.playing = false;
    player.notify();
    final Map<String, Object?> paused = await call(
      'lookupBegin',
      <String, dynamic>{'cueId': 'primary'},
    );
    await call('lookupEnd', <String, dynamic>{
      'contextId': paused['contextId'],
    });
    expect(player.playing, false);
    expect(player.commands, <String>['pause', 'play']);
  });

  test(
    'reported error clears after the next successful operation or session',
    () async {
      host.reportError('favorite_source_unavailable');
      Map<String, Object?> state = await host.handle(
        'snapshot',
        <String, dynamic>{},
        'phone',
      );
      expect(state['error'], 'favorite_source_unavailable');
      // A rejected operation does not acknowledge the failure.
      await expectLater(
        call('command', <String, dynamic>{'action': 'bogus'}),
        throwsA(isA<VideoRemoteException>()),
      );
      state = await host.handle('snapshot', <String, dynamic>{}, 'phone');
      expect(state['error'], 'favorite_source_unavailable');
      await call('command', <String, dynamic>{'action': 'pause'});
      state = await host.handle('snapshot', <String, dynamic>{}, 'phone');
      expect(state.containsKey('error'), isFalse);
      final Map<String, Object?> events = await call(
        'events',
        <String, dynamic>{'afterRevision': 0, 'waitMs': 0},
      );
      final Map<String, Object?> last =
          ((events['events']! as List).last as Map)['payload']!
              as Map<String, Object?>;
      expect(last.containsKey('error'), isFalse);

      host.reportError('favorite_subtitle_ambiguous');
      player.identity = 'episode-two';
      player.notify();
      state = await host.handle('snapshot', <String, dynamic>{}, 'phone');
      expect(state.containsKey('error'), isFalse);
    },
  );

  test('adapter failure codes reach the mining task', () async {
    final Map<String, Object?> lookup = await call(
      'lookupBegin',
      <String, dynamic>{'cueId': 'primary'},
    );
    final Map<String, Object?> accepted = await call('mine', <String, dynamic>{
      'contextId': lookup['contextId'],
      'fields': <String, dynamic>{'term': '言葉'},
    });
    player.mining.completeError(
      const VideoRemoteException(409, 'video_extraction_unavailable'),
    );
    await Future<void>.delayed(Duration.zero);
    final Map<String, Object?> status = await call(
      'mineStatus',
      <String, dynamic>{'taskId': accepted['taskId']},
    );
    expect(status['status'], 'failed');
    expect(status['error'], 'video_extraction_unavailable');
  });

  test(
    'desktop toggle on the real player controller cancels lookup resume',
    () async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      player.revisionSource = () => controller.remoteControlRevision;
      player.onCommand = (String action) async {
        if (action == 'pause') await controller.pause();
        if (action == 'play') await controller.play();
      };
      final Map<String, Object?> lookup = await call(
        'lookupBegin',
        <String, dynamic>{'cueId': 'primary'},
      );
      expect(player.playing, false);
      // The desktop shortcut / subtitle-list paths use togglePlayPause().
      // Toggling twice returns to paused without any state the phone owns.
      await controller.togglePlayPause();
      player.playing = true;
      await controller.togglePlayPause();
      player.playing = false;
      await call('lookupEnd', <String, dynamic>{
        'contextId': lookup['contextId'],
      });
      expect(player.playing, false);
      expect(player.commands, <String>['pause']);

      // Every other public transport entry is an explicit intent as well.
      for (final Future<void> Function() intent in <Future<void> Function()>[
        controller.play,
        controller.pause,
        controller.playOrPause,
        controller.togglePlayPause,
        () => controller.seekMs(1000),
        () => controller.seekRelative(1000),
        () async => controller.notifyExternalSeek(500),
      ]) {
        final int before = controller.remoteControlRevision;
        await intent();
        expect(controller.remoteControlRevision, greaterThan(before));
      }
    },
  );

  test('snapshot includes the selected episode identity', () {
    expect(snapshot['identity'], 'book-one');
    expect(snapshot['sectionIndex'], 0);
  });

  test('favorite read cannot attach an old cue to a changed session', () async {
    final _BlockingFavorites repo = favorites as _BlockingFavorites;
    repo.readStarted = Completer<void>();
    repo.readGate = Completer<void>();
    final Completer<void> gate = repo.readGate!;
    final Future<Map<String, Object?>> pending = call(
      'favoriteSet',
      <String, dynamic>{'cueId': 'primary', 'favorited': true},
    );
    final Future<void> rejected = expectLater(
      pending,
      throwsA(
        isA<VideoRemoteException>().having(
          (VideoRemoteException error) => error.code,
          'code',
          'session_changed',
        ),
      ),
    );
    await repo.readStarted!.future;
    player.identity = 'episode-two';
    player.sectionIndex = 1;
    player.notify();
    gate.complete();
    await rejected;
    expect(await FavoriteSentenceRepository(db).getAll(), isEmpty);
  });

  test(
    'favorite read cannot write after the controller lease is released',
    () async {
      final _BlockingFavorites repo = favorites as _BlockingFavorites;
      repo.readStarted = Completer<void>();
      repo.readGate = Completer<void>();
      final Completer<void> gate = repo.readGate!;
      final Future<void> rejected = expectLater(
        call('favoriteSet', <String, dynamic>{
          'cueId': 'primary',
          'favorited': true,
        }),
        throwsA(
          isA<VideoRemoteException>().having(
            (VideoRemoteException error) => error.code,
            'code',
            'controller_lease_lost',
          ),
        ),
      );
      await repo.readStarted!.future;
      await host.releaseController();
      gate.complete();
      await rejected;
      expect(await FavoriteSentenceRepository(db).getAll(), isEmpty);
    },
  );

  test(
    'expiry during an in-flight lookup pause restores only that pause',
    () async {
      player.pauseStarted = Completer<void>();
      player.pauseGate = Completer<void>();
      final Future<void> rejected = expectLater(
        call('lookupBegin', <String, dynamic>{'cueId': 'primary'}),
        throwsA(
          isA<VideoRemoteException>().having(
            (VideoRemoteException error) => error.code,
            'code',
            'controller_lease_lost',
          ),
        ),
      );
      await player.pauseStarted!.future;
      now = now.add(const Duration(seconds: 36));
      await host.handle('snapshot', <String, dynamic>{}, 'second-phone');
      player.pauseGate!.complete();
      await rejected;
      expect(player.playing, true);
      expect(player.commands, <String>['pause', 'play']);
    },
  );

  test(
    'release and reacquire by the same peer invalidates an in-flight pause',
    () async {
      player.pauseStarted = Completer<void>();
      player.pauseGate = Completer<void>();
      final Future<void> rejected = expectLater(
        call('lookupBegin', <String, dynamic>{'cueId': 'primary'}),
        throwsA(
          isA<VideoRemoteException>().having(
            (VideoRemoteException error) => error.code,
            'code',
            'controller_lease_lost',
          ),
        ),
      );
      await player.pauseStarted!.future;
      await host.releaseController();
      await host.handle('snapshot', <String, dynamic>{}, 'phone');
      player.pauseGate!.complete();
      await rejected;
      expect(player.playing, true);
    },
  );

  test(
    'a local pause during pending lookup prevents expiry recovery play',
    () async {
      player.pauseStarted = Completer<void>();
      player.pauseGate = Completer<void>();
      final Future<void> rejected = expectLater(
        call('lookupBegin', <String, dynamic>{'cueId': 'primary'}),
        throwsA(isA<VideoRemoteException>()),
      );
      await player.pauseStarted!.future;
      final Future<void> localPause = player.command(
        'pause',
        <String, dynamic>{},
      );
      now = now.add(const Duration(seconds: 36));
      await host.handle('snapshot', <String, dynamic>{}, 'second-phone');
      player.pauseGate!.complete();
      await localPause;
      await rejected;
      expect(player.playing, false);
      expect(player.commands, <String>['pause', 'pause']);
    },
  );

  test('manual playback intent cancels automatic resume', () async {
    final Map<String, Object?> lookup = await call(
      'lookupBegin',
      <String, dynamic>{'cueId': 'primary'},
    );
    await player.command('pause', <String, dynamic>{});
    await call('lookupEnd', <String, dynamic>{
      'contextId': lookup['contextId'],
    });
    expect(player.playing, false);
    expect(player.commands, <String>['pause', 'pause']);
  });

  test('old session and changed subtitle clock reject stale cues', () async {
    player.identity = 'episode-two';
    player.notify();
    await expectLater(
      call('command', <String, dynamic>{
        'action': 'seekCue',
        'cueId': 'primary',
      }),
      throwsA(
        isA<VideoRemoteException>().having(
          (VideoRemoteException e) => e.code,
          'code',
          'session_changed',
        ),
      ),
    );
    expect(player.seekMs, isNull);
    snapshot = await host.handle('snapshot', <String, dynamic>{}, 'phone');
    player.cues = List<VideoRemoteCue>.of(player.cues);
    player.notify();
    await expectLater(
      call('command', <String, dynamic>{
        'action': 'seekCue',
        'cueId': 'primary',
      }),
      throwsA(
        isA<VideoRemoteException>().having(
          (VideoRemoteException e) => e.code,
          'code',
          'subtitles_changed',
        ),
      ),
    );
  });

  test('secondary cue seeks with its own delay', () async {
    await call('command', <String, dynamic>{
      'action': 'seekCue',
      'cueId': 'secondary',
    });
    expect(player.seekMs, 4500);
    expect(player.playing, true);
  });

  test(
    '35 second lease expiry restores owned pause before handing over',
    () async {
      await call('lookupBegin', <String, dynamic>{'cueId': 'primary'});
      now = now.add(const Duration(seconds: 36));
      await host.handle('snapshot', <String, dynamic>{}, 'second-phone');
      expect(player.playing, true);
      await expectLater(
        call('favorites'),
        throwsA(isA<VideoRemoteException>()),
      );
    },
  );

  test(
    'mining retry invokes extraction/write once and task remains queryable',
    () async {
      final Map<String, Object?> lookup = await call(
        'lookupBegin',
        <String, dynamic>{'cueId': 'secondary'},
      );
      final Map<String, dynamic> request = <String, dynamic>{
        'requestId': 'one-mine',
        'contextId': lookup['contextId'],
        'fields': <String, dynamic>{'term': '言葉'},
      };
      final Map<String, Object?> first = await call('mine', request);
      final Map<String, Object?> retry = await call('mine', request);
      expect(first['taskId'], retry['taskId']);
      expect(player.mineCalls, 1);
      expect(player.minedCue!.id, 'secondary');
      expect(player.minedCue!.delayMs, 1500);
      await call('lookupEnd', <String, dynamic>{
        'contextId': lookup['contextId'],
      });
      player.mining.complete(<String, Object?>{'success': true, 'noteId': 123});
      await Future<void>.delayed(Duration.zero);
      final Map<String, Object?> result = await call(
        'mineStatus',
        <String, dynamic>{'taskId': first['taskId']},
      );
      expect(result['status'], 'succeeded');
      expect((result['result']! as Map)['noteId'], 123);
    },
  );

  test(
    'favorites persist in real DB, repeated set is idempotent and bulk remove deletes',
    () async {
      await call('favoriteSet', <String, dynamic>{
        'cueId': 'primary',
        'favorited': true,
      });
      await call('favoriteSet', <String, dynamic>{
        'cueId': 'primary',
        'favorited': true,
      });
      final List<FavoriteSentence> stored = await FavoriteSentenceRepository(
        db,
      ).getAll();
      expect(stored, hasLength(1));
      expect(stored.single.bookKey, 'book-one');
      expect(stored.single.source, kFavoriteSentenceSourceVideo);
      expect(stored.single.normCharOffset, 1000);
      expect(stored.single.dateKey, FushiDatabase.statDateKeyOf(now));
      final Map<String, Object?> list = await call(
        'favorites',
        <String, dynamic>{'query': '一番'},
      );
      expect(list['total'], 1);
      await call('favoritesRemove', <String, dynamic>{
        'ids': <String>[stored.single.id],
      });
      expect(await FavoriteSentenceRepository(db).getAll(), isEmpty);
    },
  );

  test(
    'retained mining task deduplicates after generic request eviction',
    () async {
      final Map<String, Object?> lookup = await call(
        'lookupBegin',
        <String, dynamic>{'cueId': 'primary'},
      );
      final Map<String, dynamic> request = <String, dynamic>{
        'requestId': 'retained-mine',
        'contextId': lookup['contextId'],
        'fields': <String, dynamic>{'term': '言葉'},
      };
      final Map<String, Object?> accepted = await call('mine', request);
      player.mining.complete(<String, Object?>{'success': true, 'noteId': 123});
      await Future<void>.delayed(Duration.zero);
      for (int index = 0; index < 128; index++) {
        await call('lookupEnd', <String, dynamic>{
          'contextId': 'other-context',
        });
      }
      await expectLater(
        call('mine', <String, dynamic>{
          ...request,
          'fields': <String, dynamic>{'term': '別の言葉'},
        }),
        throwsA(
          isA<VideoRemoteException>().having(
            (VideoRemoteException error) => error.code,
            'code',
            'request_id_conflict',
          ),
        ),
      );
      final Map<String, Object?> retry = await call('mine', request);
      expect(retry['taskId'], accepted['taskId']);
      expect(retry['status'], 'succeeded');
      expect(player.mineCalls, 1);
    },
  );
}

final class _BlockingFavorites extends FavoriteSentenceRepository {
  _BlockingFavorites(FushiDatabase db) : super(db);
  Completer<void>? readStarted;
  Completer<void>? readGate;

  @override
  Future<List<FavoriteSentence>> getAll() async {
    final Completer<void>? gate = readGate;
    if (gate != null) {
      readGate = null;
      readStarted!.complete();
      await gate.future;
    }
    return super.getAll();
  }
}

final class _Player {
  String identity = 'episode-one';
  int sectionIndex = 0;
  bool playing = true;
  int controlRevision = 0;
  int Function()? revisionSource;
  Future<void> Function(String action)? onCommand;
  int? seekMs;
  int mineCalls = 0;
  VideoRemoteCue? minedCue;
  final List<String> commands = <String>[];
  final List<VoidCallback> listeners = <VoidCallback>[];
  final Completer<Map<String, Object?>> mining =
      Completer<Map<String, Object?>>();
  Completer<void>? pauseStarted;
  Completer<void>? pauseGate;
  List<VideoRemoteCue> cues = const <VideoRemoteCue>[
    VideoRemoteCue(
      id: 'primary',
      text: '一番の言葉',
      startMs: 1000,
      endMs: 2000,
      delayMs: 0,
      track: 'primary',
    ),
    VideoRemoteCue(
      id: 'secondary',
      text: '第二の言葉',
      startMs: 3000,
      endMs: 4000,
      delayMs: 1500,
      track: 'secondary',
    ),
  ];

  late final VideoRemotePlaybackBinding binding = VideoRemotePlaybackBinding(
    identity: () => identity,
    title: () => 'Test video',
    bookUid: () => 'book-one',
    sectionIndex: () => sectionIndex,
    cues: () => cues,
    state: () => <String, Object?>{
      'playing': playing,
      'positionMs': seekMs ?? 0,
      'speed': 1.0,
      'controlRevision': revisionSource?.call() ?? controlRevision,
    },
    command: command,
    mine: (VideoRemoteCue cue, Map<String, dynamic> fields) {
      mineCalls++;
      minedCue = cue;
      return mining.future;
    },
    openFavorite: (FavoriteSentence favorite) async {
      seekMs = favorite.normCharOffset;
      notify();
    },
    addListener: listeners.add,
    removeListener: listeners.remove,
  );

  Future<void> command(String action, Map<String, dynamic> data) async {
    commands.add(action);
    controlRevision++;
    await onCommand?.call(action);
    if (action == 'pause') {
      playing = false;
      if (pauseStarted != null && !pauseStarted!.isCompleted) {
        pauseStarted!.complete();
      }
      await pauseGate?.future;
    }
    if (action == 'play' || action == 'seekCue') playing = true;
    if (data['positionMs'] is int) seekMs = data['positionMs'] as int;
    notify();
  }

  void notify() {
    for (final VoidCallback listener in List<VoidCallback>.of(listeners)) {
      listener();
    }
  }
}
