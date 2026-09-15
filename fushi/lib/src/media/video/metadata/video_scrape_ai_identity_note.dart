/// 「这条作品是 AI 判定的」在刮削运行记录里的落地形态。
///
/// 运行记录（`video_source_scrape_runs.summary_json`）只有 warnings/errors 两个
/// 自由文本清单，没有结构化的「判定来源」列，也不为此加 DB 列：AI 判定作为一条
/// warning 记进去，message 用固定前缀 `ai:matched` 编码置信度与理由，UI 侧再用
/// [parseVideoScrapeAiIdentityNote] 还原成可翻译的文案。
library;

import 'package:fushi/src/ai/ai_video_identity_assistant.dart';

/// 标记前缀。整条 message 形如
/// `ai:matched confidence=0.93 reason=标题与年份完全一致`。
const String kVideoScrapeAiIdentityNotePrefix = 'ai:matched';

final RegExp _notePattern = RegExp(
  '^$kVideoScrapeAiIdentityNotePrefix confidence=([0-9.]+)(?: reason=(.*))?\$',
  dotAll: true,
);

/// 已解析的 AI 判定标记。
class VideoScrapeAiIdentityNote {
  const VideoScrapeAiIdentityNote({
    required this.confidence,
    required this.reason,
  });

  final double confidence;
  final String reason;

  int get confidencePercent => (confidence * 100).round();
}

/// 把 AI 判定编码成运行记录里的一条 message。
String encodeVideoScrapeAiIdentityNote(AiVideoIdentityDecision decision) {
  final String confidence = decision.confidence.toStringAsFixed(2);
  final String reason = decision.reason.trim();
  return reason.isEmpty
      ? '$kVideoScrapeAiIdentityNotePrefix confidence=$confidence'
      : '$kVideoScrapeAiIdentityNotePrefix confidence=$confidence reason=$reason';
}

/// 从运行记录 message 还原 AI 判定；不是这种标记回 null。
VideoScrapeAiIdentityNote? parseVideoScrapeAiIdentityNote(String message) {
  final RegExpMatch? match = _notePattern.firstMatch(message.trim());
  if (match == null) {
    return null;
  }
  final double? confidence = double.tryParse(match.group(1)!);
  if (confidence == null) {
    return null;
  }
  return VideoScrapeAiIdentityNote(
    confidence: confidence.clamp(0, 1).toDouble(),
    reason: (match.group(2) ?? '').trim(),
  );
}
