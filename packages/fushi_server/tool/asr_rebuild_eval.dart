// 离线评测：segments.jsonl（转录检查点，或候选模型按同格式产出的替身）
// → AsrCueBuilder → transcript.srt + tokens sidecar → 与 app 相同的对齐收尾链
// → transcript.aligned.srt。不跑 ASR、不碰数据库，用于 cue 构建 / 匹配层 A/B。
//
//   dart run tool/asr_rebuild_eval.dart <epub> <segments.jsonl> <输出作业目录> [extractDir]
import 'dart:convert';
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final String epub = args[0];
  final String segmentsPath = args[1];
  final String jobDir = args[2];
  final String extractDir = args.length > 3
      ? args[3]
      : p.join(Directory.systemTemp.path, 'asr_rebuild_eval_$pid');
  Directory(jobDir).createSync(recursive: true);
  final List<AsrTranscribedSegment> segments = <AsrTranscribedSegment>[
    for (final String line in File(segmentsPath).readAsLinesSync())
      if (line.trim().isNotEmpty)
        AsrTranscribedSegment.fromJson(
          (jsonDecode(line) as Map<Object?, Object?>).cast<String, Object?>(),
        ),
  ];
  final List<AsrCue> asrCues = const AsrCueBuilder().build(segments);
  final String srt = p.join(jobDir, AsrJobFiles.srt);
  File(srt).writeAsStringSync(serializeAsrCuesToSrt(asrCues));
  File(p.join(jobDir, AsrJobFiles.cueTokens))
      .writeAsStringSync(serializeAsrCueTokens(asrCues));
  File(p.join(jobDir, AsrJobFiles.state)).writeAsStringSync('{}');

  final Stopwatch sw = Stopwatch()..start();
  final List<EpubSection> sections = epubSectionsFromBook(
    EpubParser.parseSyncFromPath(epub, extractDir),
  );
  final List<AudioCue> cues = await parseCuesForFormat(File(srt), 'eval', 0);
  final bool timing = await attachAsrCueTokenTiming(cues, srt);
  final ProbeResult probe = await EpubCueMatcher.probeInIsolate(
    sections: sections,
    cues: cues,
  );
  final MatchResult result = probe.bestResult ??
      await EpubCueMatcher.matchInIsolate(sections: sections, cues: cues);
  final ({List<AudioCue> cues, MatchResult result}) done =
      await finalizeAlignedCues(
    sections: sections,
    cues: cues,
    result: result,
    subtitlePath: srt,
    hasTokenTiming: timing,
  );
  stdout.writeln(
    'segments=${segments.length} asrCues=${asrCues.length} '
    'final=${done.cues.length} matched=${done.result.matchedCues}/'
    '${done.result.totalCues} window=${probe.best?.key} timing=$timing '
    'align=${sw.elapsedMilliseconds}ms',
  );
}
