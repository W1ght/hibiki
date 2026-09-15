/// 视频刮削身份消解：在线源给出多个候选时，让 AI 在**已取回的候选**里选唯一命中。
///
/// 边界与 `docs/specs/2026-09-08-scrape-provider-choice.md` 的拒绝规则一致：
/// * AI 不发任何新的资料源请求，只看协调器已经拿到手的候选列表；
/// * 多候选都合理 / 季号对不上 / 集数明显不符 / 一个都不像 → AI 必须回 `null`；
/// * 置信度低于 [kAiVideoIdentityAutoAcceptConfidence] 的判定不自动采用，原样进
///   人工确认 / 待确认；
/// * 没指派提供商（[createPreferencesAiVideoIdentityDecider] 解析出 null）时这一层
///   完全不参与，刮削行为与没有 AI 一模一样。
///
/// 模型回复经 [parseAiVideoIdentityDecision] 本地校验：key 必须在候选集合里，
/// 置信度必须是 0~1 的数字，否则一律降级成「不采用」。
library;

import 'dart:convert';

import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_feature.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_reply_json.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/models/preferences_repository.dart';

/// AI 判定自动采用的置信度门槛（含）。低于它仍走人工确认 / 待确认。
const double kAiVideoIdentityAutoAcceptConfidence = 0.85;

/// 候选简介最多带给模型的字符数：够判断题材/年代，不让 15 条候选把上下文撑爆。
const int kAiVideoIdentitySynopsisMaxChars = 300;

/// 交给模型的示例文件名条数上限。
const int kAiVideoIdentitySampleFileNameLimit = 5;

/// 一条候选作品（来自资料源的已取回结果）。
class AiVideoIdentityCandidate {
  AiVideoIdentityCandidate({
    required this.key,
    required List<String> titles,
    required this.mediaKind,
    this.year,
    this.episodeCount,
    String? synopsis,
  }) : titles = _normalizeTitles(titles),
       synopsis = _clipSynopsis(synopsis);

  /// 候选的稳定键：`<provider>:<externalId>`，与 resolver 合并候选时的去重键同形。
  final String key;

  /// 各语言标题（主标题 + 原名 + 别名），去空去重。
  final List<String> titles;
  final VideoMetadataMediaKind mediaKind;
  final int? year;
  final int? episodeCount;

  /// 简介，已截到 [kAiVideoIdentitySynopsisMaxChars]。
  final String? synopsis;

  /// 去空、trim、保序去重：同一个标题在主标题和别名里各出现一次很常见。
  static List<String> _normalizeTitles(List<String> raw) {
    final Set<String> seen = <String>{};
    return List<String>.unmodifiable(<String>[
      for (final String title in raw)
        if (title.trim().isNotEmpty && seen.add(title.trim())) title.trim(),
    ]);
  }

  static String? _clipSynopsis(String? raw) {
    final String? trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    if (trimmed.length <= kAiVideoIdentitySynopsisMaxChars) {
      return trimmed;
    }
    return '${trimmed.substring(0, kAiVideoIdentitySynopsisMaxChars)}…';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'titles': titles,
    'mediaKind': mediaKind.name,
    if (year != null) 'year': year,
    if (episodeCount != null) 'episodeCount': episodeCount,
    if (synopsis != null) 'synopsis': synopsis,
  };
}

/// 一次身份消解提问：本地目录长什么样 + 有哪些候选。
class AiVideoIdentityQuery {
  AiVideoIdentityQuery({
    required List<String> localTitles,
    required List<AiVideoIdentityCandidate> candidates,
    this.season,
    this.episodeCount,
    this.year,
    List<String> sampleFileNames = const <String>[],
    this.locale = 'en',
  }) : localTitles = List<String>.unmodifiable(localTitles),
       candidates = List<AiVideoIdentityCandidate>.unmodifiable(candidates),
       sampleFileNames = List<String>.unmodifiable(
         sampleFileNames.take(kAiVideoIdentitySampleFileNameLimit),
       );

  /// 文件名解析出的标题 + 父/祖父目录名（已过识别词清洗）。
  final List<String> localTitles;

  /// 本地解析出的季号；null = 未知。
  final int? season;

  /// 本地成员数（合集才有）；null = 单文件或未知。
  final int? episodeCount;

  /// 本地解析出的年份；null = 未知。
  final int? year;

  /// 最多 [kAiVideoIdentitySampleFileNameLimit] 条成员文件名。
  final List<String> sampleFileNames;
  final List<AiVideoIdentityCandidate> candidates;

  /// 让模型写 `reason` 时用的语言标签（如 `zh-CN`）。
  final String locale;

  /// 所有候选 key 的集合，解析回复时做白名单。
  Set<String> get candidateKeys => <String>{
    for (final AiVideoIdentityCandidate candidate in candidates) candidate.key,
  };

  /// 缓存键里的分隔符：控制字符不会出现在标题 / 候选 key 里，拼接不会撞。
  static final String _fieldSeparator = String.fromCharCode(1);
  static final String _recordSeparator = String.fromCharCode(2);

  /// 「同一目录、同一批候选」的缓存键：协调器按它保证一批只问一次。
  String get cacheKey => <String>[
    localTitles.join(_fieldSeparator),
    '$season',
    '$episodeCount',
    '$year',
    candidateKeys.join(_fieldSeparator),
  ].join(_recordSeparator);

  Map<String, Object?> toJson() => <String, Object?>{
    'localTitles': localTitles,
    if (season != null) 'season': season,
    if (episodeCount != null) 'localEpisodeCount': episodeCount,
    if (year != null) 'year': year,
    if (sampleFileNames.isNotEmpty) 'sampleFileNames': sampleFileNames,
    'candidates': <Map<String, Object?>>[
      for (final AiVideoIdentityCandidate candidate in candidates)
        candidate.toJson(),
    ],
  };
}

/// AI 的判定。[key] 为 null 表示「没有唯一命中」。
class AiVideoIdentityDecision {
  const AiVideoIdentityDecision({
    required this.key,
    required this.confidence,
    this.reason = '',
  });

  final String? key;

  /// 0.0 ~ 1.0；解析失败时为 0。
  final double confidence;
  final String reason;

  /// 是否达到自动采用门槛。
  bool get isAutoAcceptable =>
      key != null && confidence >= kAiVideoIdentityAutoAcceptConfidence;

  /// 百分比整数（UI 与运行记录共用）。
  int get confidencePercent => (confidence * 100).round();
}

/// 协调器注入点：给一个提问，回一个判定；null = 本次不问（未指派提供商等）。
typedef AiVideoIdentityDecider =
    Future<AiVideoIdentityDecision?> Function(AiVideoIdentityQuery query);

/// 系统提示：任务是「本地目录对应哪个候选作品」，只回一个 JSON 对象。
String buildAiVideoIdentitySystemPrompt({required String locale}) =>
    '''
You match a local video folder to exactly one of the candidate works returned by
a metadata provider. The candidates were already fetched; you only choose among
them and must not invent other works or identifiers.

Answer with a single JSON object and nothing else:
{"key": "<candidate key or null>", "confidence": <number 0.0-1.0>, "reason": "..."}

Rules:
- "key" must be copied verbatim from one candidate's "key", or be null.
- Return null for "key" whenever any of these holds: several candidates fit the
  local titles equally well; the local season number does not match the
  candidate; the local episode count clearly contradicts the candidate's
  episode count; no candidate plausibly matches; the local titles are only
  episode labels or release-group noise with no identifiable work name.
- Do not pick a sequel, prequel, movie, OVA or spin-off when the local folder
  looks like a different entry of the same franchise.
- "confidence" is your honest probability that the chosen candidate is the
  right work. Use 0.9 or higher only when titles, type, year and season all
  agree; otherwise stay below 0.85.
- Compare titles across languages and romanizations (Japanese, Chinese,
  Korean, English, romaji), ignoring case, punctuation and release-group tags.
- "reason" is one short sentence written in the language with tag "$locale".
''';

/// 用户侧提示：把本地线索和候选一起序列化成 JSON，模型不用猜字段含义。
String buildAiVideoIdentityUserPrompt(AiVideoIdentityQuery query) =>
    const JsonEncoder.withIndent('  ').convert(query.toJson());

/// 解析模型回复。
///
/// key 不在 [allowedKeys] 里 → 视为 null；confidence 不是数字或不在 0~1 → 0。
/// 抠不出 JSON 也回一条 key=null、confidence=0 的判定，调用方不用区分。
AiVideoIdentityDecision parseAiVideoIdentityDecision(
  String reply, {
  required Set<String> allowedKeys,
}) {
  final Map<String, Object?>? decoded = decodeAiJsonObject(reply);
  if (decoded == null) {
    return const AiVideoIdentityDecision(key: null, confidence: 0);
  }
  final Object? rawKey = decoded['key'];
  final String? key = rawKey is String && allowedKeys.contains(rawKey.trim())
      ? rawKey.trim()
      : null;
  final Object? rawConfidence = decoded['confidence'];
  double confidence = 0;
  if (rawConfidence is num &&
      rawConfidence.isFinite &&
      rawConfidence >= 0 &&
      rawConfidence <= 1) {
    confidence = rawConfidence.toDouble();
  }
  final Object? rawReason = decoded['reason'];
  return AiVideoIdentityDecision(
    key: key,
    confidence: key == null ? 0 : confidence,
    reason: rawReason is String ? rawReason.trim() : '',
  );
}

/// 跑一次身份消解。失败原样抛 [AiChatFailure]（文案已脱敏），由调用方决定吞不吞。
Future<AiVideoIdentityDecision> requestAiVideoIdentity({
  required AiChatClient client,
  required AiProviderConfig provider,
  required AiVideoIdentityQuery query,
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(
        buildAiVideoIdentitySystemPrompt(locale: query.locale),
      ),
      AiChatMessage.user(buildAiVideoIdentityUserPrompt(query)),
    ],
    // 回复只有一个小 JSON 对象；给 512 是留给推理型模型偶尔多话。
    maxTokens: 512,
  );
  return parseAiVideoIdentityDecision(reply, allowedKeys: query.candidateKeys);
}

/// 生产装配：每次被问时**现取**偏好里的指派，未指派 / 不可用直接回 null（不发请求）。
///
/// 现取而不是构造期解析，是因为协调器实例在 home_page 里按配置指纹缓存、
/// 生命周期很长；用户在设置页改了指派要立即生效，不能等协调器重建。
/// [clientFactory] 只给测试注入假客户端；生产每次新建、用完即关，不留连接。
AiVideoIdentityDecider createPreferencesAiVideoIdentityDecider(
  PreferencesRepository prefsRepo, {
  AiChatClient Function()? clientFactory,
}) => (AiVideoIdentityQuery query) async {
  final AiProviderConfig? provider = prefsRepo.aiFeatureAssignments.resolve(
    AiFeature.videoIdentify,
    prefsRepo.aiProviders,
  );
  if (provider == null) {
    return null;
  }
  final AiChatClient client = clientFactory?.call() ?? AiChatClient();
  try {
    return await requestAiVideoIdentity(
      client: client,
      provider: provider,
      query: query,
    );
  } finally {
    client.close();
  }
};
