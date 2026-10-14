import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:test/test.dart';

/// 20 ms 一帧的包络：默认全是语音（−20 dB），[silences] 里的毫秒区间是静音（−70）。
Int8List _energy(int totalMs, List<(int, int)> silences) {
  final Int8List e = Int8List(totalMs ~/ 20)..fillRange(0, totalMs ~/ 20, -20);
  for (final (int a, int b) in silences) {
    e.fillRange(a ~/ 20, b ~/ 20, -70);
  }
  return e;
}

AudioCue _cue(int start, int end, {int? firstTokenAt}) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = ''
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = 'x'
  ..startMs = start
  ..endMs = end
  ..audioFileIndex = 0
  ..tokenTiming = firstTokenAt == null
      ? null
      : CueTokenTiming(
          tokens: <String>['x'],
          offsetsMs: <int>[firstTokenAt - start],
        );

void main() {
  const CueEnergySnapper snapper = CueEnergySnapper();

  test('紧挨着的切点吸到停顿：前句收在谷起点 + 80，后句从谷终点 − 40 起', () {
    // 真实停顿在 [2300, 2700)，token 推算的切点在 2000。
    final List<AudioCue> cues = <AudioCue>[_cue(0, 2000), _cue(2000, 5000)];
    final int moved = snapper.snap(
      cues,
      _energy(6000, <(int, int)>[(2300, 2700)]),
    );
    expect(moved, 1);
    expect(cues[0].endMs, 2380);
    expect(cues[1].startMs, 2660);
  });

  test('附近没有足够长的停顿（只有 60 ms 的塞音闭塞）：不动', () {
    final List<AudioCue> cues = <AudioCue>[_cue(0, 2000), _cue(2000, 5000)];
    expect(snapper.snap(cues, _energy(6000, <(int, int)>[(2000, 2060)])), 0);
    expect(cues[0].endMs, 2000);
    expect(cues[1].startMs, 2000);
  });

  test('两条 cue 之间已有 VAD 切开的大空隙：不动', () {
    final List<AudioCue> cues = <AudioCue>[_cue(0, 2000), _cue(2600, 5000)];
    expect(snapper.snap(cues, _energy(6000, <(int, int)>[(2100, 2500)])), 0);
  });

  test('谷远在后句首 token 之后：吸过去会吃掉字头，不动', () {
    final List<AudioCue> cues = <AudioCue>[
      _cue(0, 2000),
      _cue(2000, 5000, firstTokenAt: 2050),
    ];
    expect(snapper.snap(cues, _energy(6000, <(int, int)>[(2400, 2600)])), 0);
    expect(cues[1].startMs, 2000);
  });

  test('吸附后一侧短于 500 ms：不动', () {
    final List<AudioCue> cues = <AudioCue>[_cue(0, 2000), _cue(2000, 2800)];
    expect(snapper.snap(cues, _energy(3000, <(int, int)>[(2300, 2500)])), 0);
  });

  test('包络未知（0）的帧按有声处理，不会凭空造谷', () {
    final List<AudioCue> cues = <AudioCue>[_cue(0, 2000), _cue(2000, 5000)];
    expect(snapper.snap(cues, Int8List(300)), 0);
  });
}
