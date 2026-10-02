import 'dart:convert';
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_engine/media/audiobook/asr_live_match.dart';
import 'package:test/test.dart';

/// 转录弹层「边转边匹配」：读正被追加的段文件、对正文匹配、出匹配率与已匹配字数。
void main() {
  const List<EpubSection> sections = <EpubSection>[
    EpubSection(
      index: 0,
      href: 'c1.xhtml',
      text: '今日はいい天気ですね。散歩に行きましょう。',
    ),
    EpubSection(
      index: 1,
      href: 'c2.xhtml',
      text: '公園で猫を見つけました。とても可愛かったです。',
    ),
  ];

  AsrTranscribedSegment seg(int startMs, String text) {
    final List<String> tokens = text.split('');
    return AsrTranscribedSegment(
      audioFileIndex: 0,
      startMs: startMs,
      endMs: startMs + 1000,
      tokens: tokens,
      tokenTimesMs: List<int>.generate(tokens.length, (int i) => startMs + i),
    );
  }

  late Directory jobDir;
  setUp(() => jobDir = Directory.systemTemp.createTempSync('asr_live_'));
  tearDown(() => jobDir.deleteSync(recursive: true));

  void writeSegments(List<AsrTranscribedSegment> segs, {String tail = ''}) {
    final StringBuffer sb = StringBuffer();
    for (final AsrTranscribedSegment s in segs) {
      sb.writeln(jsonEncode(s.toJson()));
    }
    sb.write(tail);
    File('${jobDir.path}/${AsrJobFiles.segments}')
        .writeAsStringSync(sb.toString());
  }

  test('还没有段：null（弹层显示「正在匹配」而不是 0%）', () async {
    expect(
      await computeAsrLiveMatch(jobDirPath: jobDir.path, sections: sections),
      isNull,
    );
  });

  test('已转出的段按正文匹配：匹配率与已匹配字数', () async {
    // 落盘顺序是按段长成批的，不是时间序：构建 cue 时按起点重排。
    writeSegments(<AsrTranscribedSegment>[
      seg(5000, '公園で猫を見つけました'),
      seg(0, '今日はいい天気ですね'),
    ]);
    final AsrLiveMatchStats? s = await computeAsrLiveMatch(
      jobDirPath: jobDir.path,
      sections: sections,
    );
    expect(s, isNotNull);
    expect(s!.totalCues, greaterThan(0));
    expect(s.matchedCues, s.totalCues);
    expect(s.matchRate, 1.0);
    final int total = sections
        .map((EpubSection e) => AudioTextNormalizer.normalize(e.text).length)
        .reduce((int a, int b) => a + b);
    expect(s.totalChars, total);
    expect(
      s.matchedChars,
      AudioTextNormalizer.normalize('今日はいい天気ですね公園で猫を見つけました').length,
    );
    expect(s.charFraction, closeTo(s.matchedChars / total, 1e-9));
  });

  test('末尾写了一半的行（任务正在追加）被丢弃，不抛', () async {
    writeSegments(
      <AsrTranscribedSegment>[seg(0, '今日はいい天気ですね')],
      tail: '{"f":0,"s":5000,"e":60',
    );
    final AsrLiveMatchStats? s = await computeAsrLiveMatch(
      jobDirPath: jobDir.path,
      sections: sections,
    );
    expect(s, isNotNull);
    expect(s!.matchedCues, s.totalCues);
  });
}
