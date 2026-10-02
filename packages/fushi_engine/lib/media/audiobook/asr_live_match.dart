import 'dart:io';
import 'dart:isolate';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:meta/meta.dart';

/// 转录进行中的「边转边匹配」快照：把已落盘的转录段对全书正文跑一遍与导入
/// 同口径的匹配（第一遍 Dice + 锚点间隙回填），给转录弹层显示匹配率与已匹配
/// 的正文字数。
///
/// 只是预览：不落库、不重切、不换正文。真正的对齐仍由「使用字幕」后的导入链路
/// （`alignAndPersistAudiobook`）做，它会探测多档搜索窗口，最终数字可能略高。
@immutable
class AsrLiveMatchStats {
  const AsrLiveMatchStats({
    required this.matchedCues,
    required this.totalCues,
    required this.matchedChars,
    required this.totalChars,
  });

  final int matchedCues;
  final int totalCues;

  /// 命中 cue 覆盖的正文字数（规范化后：假名 / 汉字 / 字母数字，不含标点）。
  final int matchedChars;

  /// 全书正文字数（同一规范化口径）。
  final int totalChars;

  double get matchRate => totalCues == 0 ? 0 : matchedCues / totalCues;

  double get charFraction =>
      totalChars == 0 ? 0 : (matchedChars / totalChars).clamp(0.0, 1.0);
}

/// 纯函数：由匹配结果算统计（可测，不碰文件）。
AsrLiveMatchStats asrLiveMatchStatsOf({
  required List<EpubSection> sections,
  required MatchResult result,
}) {
  int matchedChars = 0;
  for (final CueMatch m in result.matches) {
    if (!m.matched) continue;
    final int len = m.normCharEnd - m.normCharStart;
    if (len > 0) matchedChars += len;
  }
  int totalChars = 0;
  for (final EpubSection s in sections) {
    totalChars += AudioTextNormalizer.normalize(s.text).length;
  }
  return AsrLiveMatchStats(
    matchedCues: result.matchedCues,
    totalCues: result.totalCues,
    matchedChars: matchedChars,
    totalChars: totalChars,
  );
}

/// 读 [jobDirPath] 里已落盘的转录段、拼成 cue、对 [sections] 匹配，全在后台
/// isolate 里做（段文件几千行 JSON + 全书匹配，不能占 UI isolate）。还没有任何
/// 段时返回 null。
///
/// 段文件正被转录任务追加也安全：`loadSegments` 会丢弃末尾写了一半的行。
/// 时间轴偏移不影响匹配（匹配只看文本顺序，cue 构建按文件序 + 起点排序），
/// 所以这里不需要各文件时长。
Future<AsrLiveMatchStats?> computeAsrLiveMatch({
  required String jobDirPath,
  required List<EpubSection> sections,
  double similarityThreshold = kAsrSuggestedSimilarityThreshold,
}) {
  return Isolate.run(() async {
    final List<AsrTranscribedSegment> segments =
        await AsrTranscribeJob.loadSegments(Directory(jobDirPath));
    if (segments.isEmpty) return null;
    final List<AsrCue> asrCues = const AsrCueBuilder().build(segments);
    final List<AudioCue> cues = <AudioCue>[
      for (int i = 0; i < asrCues.length; i++)
        AudioCue()
          ..bookKey = ''
          ..chapterHref = ''
          ..sentenceIndex = i
          ..textFragmentId = ''
          ..text = asrCues[i].text
          ..startMs = asrCues[i].startMs
          ..endMs = asrCues[i].endMs
          ..audioFileIndex = 0,
    ];
    if (cues.isEmpty) return null;
    final MatchResult result = EpubCueMatcher.match(
      sections: sections,
      cues: cues,
      similarityThreshold: similarityThreshold,
    );
    return asrLiveMatchStatsOf(sections: sections, result: result);
  });
}
