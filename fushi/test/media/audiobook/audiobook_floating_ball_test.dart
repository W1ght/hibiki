import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/media/audiobook/audiobook_floating_ball.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';

/// 悬浮球按钮集合：偏好编解码（未知 id 丢弃、顺序归一、空值回默认三键）与
/// 每颗键到 [ReaderHeaderAction] 的映射（上一句 / 下一句跟随跳转方式、播放键按
/// 运行态换图标）。球本身的几何 / 交互见 test/reader/reader_floating_ball_test.dart。
class _SpyController extends AudiobookPlayerController {
  final List<String> calls = <String>[];
  bool playing = false;

  @override
  bool get isPlaying => playing;

  @override
  Future<void> skipToPrevCue() async => calls.add('prev');

  @override
  Future<void> skipToNextCue() async => calls.add('next');

  @override
  Future<void> togglePlayPause() async => calls.add('toggle');

  @override
  Future<void> seekRelative(int deltaSeconds) async =>
      calls.add('seek$deltaSeconds');
}

void main() {
  // AudiobookPlayerController 构造会碰 MethodChannel，纯 test() 里要先起 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('默认三键 = 上一句 / 播放暂停 / 下一句', () {
    expect(AudiobookFloatingBallAction.defaults, <AudiobookFloatingBallAction>[
      AudiobookFloatingBallAction.prev,
      AudiobookFloatingBallAction.playPause,
      AudiobookFloatingBallAction.next,
    ]);
  });

  test('decode 丢未知 id、去重、按 values 顺序归一；空值回默认', () {
    expect(
      AudiobookFloatingBallAction.decode('next, bogus,prev,next,follow'),
      <AudiobookFloatingBallAction>[
        AudiobookFloatingBallAction.prev,
        AudiobookFloatingBallAction.next,
        AudiobookFloatingBallAction.follow,
      ],
    );
    expect(
      AudiobookFloatingBallAction.decode(''),
      AudiobookFloatingBallAction.defaults,
    );
    expect(
      AudiobookFloatingBallAction.decode('bogus'),
      AudiobookFloatingBallAction.defaults,
    );
  });

  test('encode/decode 往返', () {
    const List<AudiobookFloatingBallAction> all =
        AudiobookFloatingBallAction.values;
    expect(
      AudiobookFloatingBallAction.decode(
        AudiobookFloatingBallAction.encode(all.reversed),
      ),
      all,
    );
  });

  test('映射：三键回调打到控制器；按秒跳时上一句 / 下一句换成快退 / 快进', () {
    final _SpyController c = _SpyController();
    addTearDown(c.dispose);
    ReaderHeaderAction act(AudiobookFloatingBallAction a, {int skip = 0}) =>
        audiobookFloatingBallHeaderAction(
          a,
          controller: c,
          skipActionSeconds: skip,
          onOpenSettings: () => c.calls.add('settings'),
        );
    act(AudiobookFloatingBallAction.prev).onPressed!();
    act(AudiobookFloatingBallAction.playPause).onPressed!();
    act(AudiobookFloatingBallAction.next).onPressed!();
    act(AudiobookFloatingBallAction.settings).onPressed!();
    expect(c.calls, <String>['prev', 'toggle', 'next', 'settings']);
    c.calls.clear();
    expect(
      act(AudiobookFloatingBallAction.prev, skip: 15).icon,
      Icons.fast_rewind_outlined,
    );
    act(AudiobookFloatingBallAction.next, skip: 15).onPressed!();
    expect(c.calls, <String>['seek15']);
    expect(
      act(AudiobookFloatingBallAction.playPause).icon,
      Icons.play_arrow_outlined,
    );
    c.playing = true;
    expect(
      act(AudiobookFloatingBallAction.playPause).icon,
      Icons.pause_outlined,
    );
  });
}
