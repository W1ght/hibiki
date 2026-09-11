/// BUG-2462：开书时「正文保存位置」与「有声书播放位置」的对账判据（纯函数）。
///
/// 两个位置各自独立落库：正文位置只在阅读器页活着时随滚动 / 跟随 reveal 写
/// （`reader_positions.updatedAt`），音频位置由会话每秒写（`audiobook_pos_<key>` +
/// `audiobook_pos_at_<key>`）。退书后台续听、锁屏听完一章、换端听过——音频跑远了，
/// 正文还停在退出那一刻；重开书正文按旧位置恢复，一按播放就被拽到音频处，中间几十
/// 页瞬间翻过（用户 2026-09-12：「可能落在当前进度前面但是有声书在后面，一旦播放就
/// 会跨了很多页」）。
///
/// 判据：**谁新谁赢**——音频位置比正文位置新出 [kAudiobookResumeGraceMs] 以上，且
/// 用户开着「跟随音频」（关着就是有意让正文与音频分离，不动），且音频 cue 推出的正文
/// 位置与保存位置隔得够远（[readerPositionsFarApart]），起点才改从当前音频 cue 推。
/// 隔得近（同一页内）保留保存位置：它带精确字符锚（BUG-162），cue 派生只有分数。
library;

/// 音频位置必须比正文位置新出这么多才算「音频跑到前面去了」。退书时 reader 先
/// flush 正文位置、再 flush 音频位置（`_syncAndFlushPosition`，探针预算 600ms），
/// 两个时间戳天然差几百毫秒；对齐退出的书不能被这点抖动判成音频更新。
const int kAudiobookResumeGraceMs = 3000;

/// cue 派生位置与保存位置的最小「隔得够远」距离（字）。约一页手机屏正文：一页
/// 之内两种起点显示的是同一页，换成 cue 派生只会丢精确锚。
const int kAudiobookResumeMinDistanceChars = 600;

/// 音频位置是否比正文位置新出宽限以上。任一时间戳缺失（0 = 旧数据没写过）判否。
bool audiobookPositionIsNewer({
  required int audioUpdatedAt,
  required int readerUpdatedAt,
  int graceMs = kAudiobookResumeGraceMs,
}) {
  if (audioUpdatedAt <= 0 || readerUpdatedAt <= 0) return false;
  return audioUpdatedAt - readerUpdatedAt > graceMs;
}

/// cue 派生位置 `(audioSection, audioProgress)` 与保存位置 `(savedSection,
/// savedProgress)` 是否隔得够远：不同章即远；同章按 `|Δprogress| × 章字数` 折成字
/// 与 [minDistanceChars] 比，章字数未知（≤ 0）时退回分数阈值 `minDistanceChars /
/// 10000`（与 `normCharOffset` 万分比同基）。
bool readerPositionsFarApart({
  required int savedSection,
  required double savedProgress,
  required int audioSection,
  required double audioProgress,
  required int chapterChars,
  int minDistanceChars = kAudiobookResumeMinDistanceChars,
}) {
  if (savedSection != audioSection) return true;
  final double delta = (audioProgress - savedProgress).abs();
  if (chapterChars > 0) return delta * chapterChars >= minDistanceChars;
  return delta >= minDistanceChars / 10000.0;
}
