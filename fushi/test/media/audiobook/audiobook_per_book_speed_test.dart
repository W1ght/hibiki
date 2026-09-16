import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_channel.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// 有声书倍速**按书独立**（一本一个 `audiobook_speed_<bookKey>`）的行为守卫。
///
/// 链路：`AudiobookRepository.readSpeed/updateSpeed`（按 bookKey 读写 pref）→
/// `AudiobookSessionLauncher` 把它装成 `SessionPrefs.speed` / `onSpeedPersist`
/// （接线由 audio_persist_wiring_static_test 钉）→ `AudiobookSession.start` 传给
/// `AudiobookPlayerController.load(initialSpeed:)`。这里钉住三件运行期事实：
///  - 仓储层两本书各存各的，未写过的书回退 1.0；
///  - 切书后新控制器拿到的是**目标书**的倍速（不是上一本书残留，也不是全局值），
///    且 `play()` 激活真实平台时会把该倍速下发（`load` 用 `preload: false`，倍速
///    在 idle 平台上只记在 just_audio 状态里，靠激活时重放才真正生效）；
///  - `setSpeed` 只落到当前书的持久化回调，`load` 应用初值不触发持久化。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Audiobook ab(String key) => Audiobook()
    ..bookKey = key
    ..audioPaths = const <String>[]
    ..audioRoot = null
    ..alignmentFormat = 'srt'
    ..alignmentPath = '';

  File makeFile(String name) {
    final File f = File('${Directory.systemTemp.path}/$name');
    if (!f.existsSync()) f.writeAsBytesSync(const <int>[0]);
    addTearDown(() {
      if (f.existsSync()) f.deleteSync();
    });
    return f;
  }

  _FakePlatform installPlatform() {
    const MethodChannel ch = MethodChannel('com.ryanheise.audio_session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null);
    });
    final JustAudioPlatform prev = JustAudioPlatform.instance;
    final _FakePlatform platform = _FakePlatform();
    JustAudioPlatform.instance = platform;
    addTearDown(() => JustAudioPlatform.instance = prev);
    return platform;
  }

  setUp(() {
    FloatingLyricChannel.platformOverride = false;
  });
  tearDown(() {
    FloatingLyricChannel.platformOverride = null;
  });

  AudiobookSession makeSession() {
    return AudiobookSession(
      audioHandler: () => null,
      showFloatingLyric: () => false,
      showMediaNotification: () => false,
      floatingLyricContextLines: () => 0,
      floatingLyricStyle: () => const FloatingLyricStyle(
        fontSize: 16,
        textColor: 0,
        bgColor: 0,
        buttonTextColor: 0,
        buttonBgColor: 0,
        highlightColor: 0,
        activeColor: 0,
      ),
      floatingLyricClickLookup: () => false,
      onFloatingLyricLookup: (_, __, ___) {},
      controlStreams: AudioControlStreams(
        playStream: const Stream<void>.empty(),
        seekStream: const Stream<Duration>.empty(),
        skipNextStream: const Stream<void>.empty(),
        skipPreviousStream: const Stream<void>.empty(),
        toggleFloatingLyricStream: const Stream<void>.empty(),
      ),
    );
  }

  /// 起一本书：倍速初值 [speed]，该书的 onSpeedPersist 写进 [persisted]。
  Future<AudiobookPlayerController> startBook(
    AudiobookSession session,
    String key, {
    required double speed,
    required List<double> persisted,
  }) async {
    final AudiobookPlayerController? controller = await session.start(
      info: SessionBookInfo(
        bookKey: key,
        audiobook: ab(key),
        title: 'Book $key',
        mediaIdentifier: 'fushi://book/$key',
      ),
      audioFiles: <File>[makeFile('hibiki-speed-$key.mp3')],
      prefs: SessionPrefs(
        followAudio: true,
        delayMs: 0,
        speed: speed,
        positionMs: 0,
        imagePauseSec: 0,
        volume: 1.0,
      ),
      persist: SessionPersistCallbacks(
        onPositionWrite: (_, __) async {},
        onDelayPersist: (_) async {},
        onSpeedPersist: (double v) async => persisted.add(v),
        onVolumePersist: (_) async {},
        onImagePausePersist: (_) async {},
        onFollowAudioPersist: (_) async {},
      ),
    );
    return controller!;
  }

  test('AudiobookRepository persists speed per book and round-trips', () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('hibiki_speed_test_');
    addTearDown(() async {
      await dir.delete(recursive: true);
    });
    final FushiDatabase db = FushiDatabase(dir.path);
    addTearDown(db.close);
    final AudiobookRepository repo = AudiobookRepository(db);

    // 未写过时回退默认 1.0。
    expect(await repo.readSpeed('book-A'), 1.0);

    await repo.updateSpeed(bookKey: 'book-A', speed: 1.8);
    await repo.updateSpeed(bookKey: 'book-B', speed: 1.25);

    expect(await repo.readSpeed('book-A'), closeTo(1.8, 1e-9));
    expect(await repo.readSpeed('book-B'), closeTo(1.25, 1e-9));
    // 不串味：改 B 不动 A，未写过的第三本仍是默认。
    expect(await repo.readSpeed('book-C'), 1.0);
    expect(await db.getPref('audiobook_speed_book-A'), '1.8',
        reason: '持久化键必须带 bookKey 后缀（一本一键），不是全局单键');

    await repo.updateSpeed(bookKey: 'book-A', speed: 1.0);
    expect(await repo.readSpeed('book-A'), 1.0);
    expect(await repo.readSpeed('book-B'), closeTo(1.25, 1e-9));
  });

  test('switching books applies each book\'s own stored speed', () async {
    final _FakePlatform platform = installPlatform();
    final AudiobookSession session = makeSession();
    addTearDown(session.dispose);
    final List<double> persistedA = <double>[];
    final List<double> persistedB = <double>[];

    // 书 A 存了 1.8x：load 后控制器即报 1.8，play 激活平台时真正下发 1.8。
    final AudiobookPlayerController a =
        await startBook(session, 'a', speed: 1.8, persisted: persistedA);
    expect(a.speed, closeTo(1.8, 1e-9));
    await a.play();
    expect(platform.players.last.speeds, contains(closeTo(1.8, 1e-9)),
        reason: 'preload:false 下倍速只记在 just_audio 状态里，'
            '必须在 play 激活平台时重放到平台，否则「存了没生效」');
    expect(persistedA, isEmpty, reason: 'load 应用初值不是用户操作，不得回写');

    // 切到书 B（从未设过倍速 → 1.0）：不得继承 A 的 1.8。
    final AudiobookPlayerController b =
        await startBook(session, 'b', speed: 1.0, persisted: persistedB);
    expect(identical(a, b), isFalse);
    expect(b.speed, closeTo(1.0, 1e-9),
        reason: '每本书各用各的倍速：B 没设过就是 1.0，不是 A 的 1.8');
    await b.play();
    expect(platform.players.last.speeds.where((double s) => s != 1.0), isEmpty,
        reason: 'B 的平台实例不得收到 A 的 1.8');

    // 切回 A：仍是 A 自己的 1.8。
    final AudiobookPlayerController a2 =
        await startBook(session, 'a', speed: 1.8, persisted: persistedA);
    expect(a2.speed, closeTo(1.8, 1e-9));
    expect(persistedA, isEmpty);
    expect(persistedB, isEmpty);
  });

  test('setSpeed persists to the active book only', () async {
    installPlatform();
    final AudiobookSession session = makeSession();
    addTearDown(session.dispose);
    final List<double> persistedA = <double>[];
    final List<double> persistedB = <double>[];

    await startBook(session, 'a', speed: 1.8, persisted: persistedA);
    final AudiobookPlayerController b =
        await startBook(session, 'b', speed: 1.0, persisted: persistedB);

    await b.setSpeed(1.5);
    await Future<void>.delayed(Duration.zero);
    expect(b.speed, closeTo(1.5, 1e-9));
    expect(persistedB, <double>[1.5]);
    expect(persistedA, isEmpty, reason: '改 B 的倍速不能写到 A 的键上');

    // 同值（容差内）不重复回写。
    await b.setSpeed(1.5);
    await Future<void>.delayed(Duration.zero);
    expect(persistedB, <double>[1.5]);
  });
}

class _FakePlatform extends JustAudioPlatform {
  final List<_FakePlayer> players = <_FakePlayer>[];

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final _FakePlayer player = _FakePlayer(request.id);
    players.add(player);
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    for (final _FakePlayer p in players) {
      if (p.id == request.id) await p.dispose(DisposeRequest());
    }
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
      DisposeAllPlayersRequest request) async {
    for (final _FakePlayer p in players) {
      await p.dispose(DisposeRequest());
    }
    return DisposeAllPlayersResponse();
  }
}

class _FakePlayer extends AudioPlayerPlatform {
  _FakePlayer(super.id);
  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();

  /// 平台实际收到的 setSpeed 值（按调用顺序）。
  final List<double> speeds = <double>[];

  void emit(int ms, ProcessingStateMessage state, {required bool playing}) {
    _events.add(PlaybackEventMessage(
      processingState: state,
      updateTime: DateTime.now(),
      updatePosition: Duration(milliseconds: ms),
      bufferedPosition: Duration(milliseconds: ms),
      duration: const Duration(seconds: 100),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    emit(request.initialPosition?.inMilliseconds ?? 0,
        ProcessingStateMessage.ready,
        playing: false);
    return LoadResponse(duration: const Duration(seconds: 100));
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();
  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();
  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    emit(request.position?.inMilliseconds ?? 0, ProcessingStateMessage.ready,
        playing: false);
    return SeekResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
          SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse();
  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
              SetAutomaticallyWaitsToMinimizeStallingRequest request) async =>
          SetAutomaticallyWaitsToMinimizeStallingResponse();
  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
              SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest
                  request) async =>
          SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();
  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();
  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
          SetPreferredPeakBitRateRequest request) async =>
      SetPreferredPeakBitRateResponse();
  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();
  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse();
  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
          SetSkipSilenceRequest request) async =>
      SetSkipSilenceResponse();
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    speeds.add(request.speed);
    return SetSpeedResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();
  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(
          SetWebCrossOriginRequest request) async =>
      SetWebCrossOriginResponse();
  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    if (!_events.isClosed) await _events.close();
    return DisposeResponse();
  }
}
