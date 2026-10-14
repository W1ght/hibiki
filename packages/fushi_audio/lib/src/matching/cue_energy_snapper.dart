import 'dart:math' as math;
import 'dart:typed_data';

import '../audiobook/audiobook_model.dart';

/// 把**紧挨着**的两条 cue 之间的切点吸到真实的停顿（能量谷）上（设备端转录产物
/// 专用，重切之后、落库之前跑）。
///
/// 重切器在正文句号处新加的切点取「下一句首 token − 150 ms」，而 RNN-T 的发射
/// 时刻相对真实发声前后漂 −440 ~ +340 ms：同一个切点既是前句终点又是后句起点，
/// 常数补偿只能把误差从一侧推到另一侧（春物 2 卷整本实测提前量 150 → 0 ms，
/// 起点提前嫌疑反而 441 → 463）。这里改用声学证据：在切点 ±[windowMs] 内找
/// 「足够长、离原切点不远」的低能量谷，前句收在谷起点 + [tailMs]，后句从谷终点
/// − [leadMs] 起。
///
/// 只动时间，不动文本、区间与条数——覆盖率与阅读器定位不受影响。缺包络（旧任务、
/// 非转录产物）、找不到谷、或吸附后任一侧短于 [minDurationMs] 时该切点原样保留。
class CueEnergySnapper {
  const CueEnergySnapper({
    this.frameMs = 20,
    this.maxGapMs = 400,
    this.windowMs = 600,
    this.minValleyMs = 120,
    this.distancePenalty = 0.5,
    this.tailMs = 80,
    this.leadMs = 40,
    this.minDurationMs = 500,
    this.floorMarginDb = 16,
    this.minThresholdDb = -50,
    this.maxThresholdDb = -30,
    this.tokenGuardMs = 200,
  });

  /// 包络帧长（与转录时写入的一致）。
  final int frameMs;

  /// 两条 cue 之间空隙超过此值就不算「紧挨着」（那是 VAD 已经切开的停顿）。
  final int maxGapMs;

  /// 在原切点前后多远内找谷。
  final int windowMs;

  /// 谷的最短长度：塞音闭塞只有几十毫秒，不算句间停顿。
  final int minValleyMs;

  /// 选谷打分 = 谷长 − 此系数 × 谷中心离原切点的距离（都按毫秒）。
  final double distancePenalty;

  /// 前句终点在谷起点之后留的余韵。
  final int tailMs;

  /// 后句起点在谷终点之前提前的量。
  final int leadMs;

  /// 吸附后两侧 cue 都不得短于此值，否则不动。
  final int minDurationMs;

  /// 门限 = 附近 ±15 s 电平第 10 百分位（底噪）+ 此值，夹到
  /// [[minThresholdDb], [maxThresholdDb]]。下限比能量 VAD（−55）高：−45 ~ −55 dB
  /// 的气声/混响尾巴听感上已是静音，按 −55 判会把前句终点推迟进停顿里。
  final double floorMarginDb;
  final double minThresholdDb;
  final double maxThresholdDb;

  /// 后句新起点不晚于它首 token 发射时刻 + 此值（RNN-T 首 token 一般早于开口，
  /// 比它还晚很多就是吸错了谷、会吃掉字头）。
  final int tokenGuardMs;

  static const int _floorBlockFrames = 250;
  static const int _floorSpanFrames = 750;

  /// [energyDb]：从时间 0 起每 [frameMs] 一帧的电平（整数 dBFS，0 = 未知，按有声
  /// 处理）。就地修改 [cues] 的起止时间，返回挪动的切点数。
  int snap(List<AudioCue> cues, Int8List energyDb) {
    final int n = energyDb.length;
    if (n == 0 || cues.length < 2) return 0;
    final Float64List threshold = _thresholds(energyDb);
    bool quiet(int f) {
      final int v = energyDb[f];
      return v != 0 && v < threshold[f];
    }

    final int minValley = (minValleyMs / frameMs).ceil();
    int moved = 0;
    for (int i = 0; i + 1 < cues.length; i++) {
      final AudioCue cur = cues[i];
      final AudioCue next = cues[i + 1];
      if (cur.audioFileIndex != next.audioFileIndex) continue;
      final int gap = next.startMs - cur.endMs;
      if (gap < 0 || gap > maxGapMs) continue;
      final int b = (cur.endMs + next.startMs) ~/ 2;
      final int f0 = math.max(0, (b - windowMs) ~/ frameMs);
      final int f1 = math.min(n, (b + windowMs) ~/ frameMs);
      int best = -1;
      int bestLen = 0;
      double bestScore = 0;
      int f = f0;
      while (f < f1) {
        if (!quiet(f)) {
          f++;
          continue;
        }
        // 窗口只限定谷落在哪，谷本身量到真实的两端（不被窗口边截断）。
        int s = f;
        while (s > 0 && quiet(s - 1)) {
          s--;
        }
        while (f < n && quiet(f)) {
          f++;
        }
        final int len = f - s;
        if (len < minValley) continue;
        final double center = (s + f) * frameMs / 2;
        final double score =
            len * frameMs - distancePenalty * (center - b).abs();
        if (best < 0 || score > bestScore) {
          best = s;
          bestLen = len;
          bestScore = score;
        }
      }
      if (best < 0) continue;
      final int valleyStart = best * frameMs;
      final int valleyEnd = (best + bestLen) * frameMs;
      final int end = math.min(valleyStart + tailMs, valleyEnd);
      final int start = math.max(
        math.max(valleyEnd - leadMs, valleyStart),
        end,
      );
      if (end - cur.startMs < minDurationMs ||
          next.endMs - start < minDurationMs) {
        continue;
      }
      final int? firstToken = _firstTokenMs(next);
      if (firstToken != null && start > firstToken + tokenGuardMs) continue;
      _shiftStart(next, start);
      cur.endMs = end;
      moved++;
    }
    return moved;
  }

  /// 每帧的门限（按 [_floorBlockFrames] 一块算一次局部底噪）。未知帧不参与。
  Float64List _thresholds(Int8List db) {
    final int n = db.length;
    final Float64List out = Float64List(n);
    final List<int> window = <int>[];
    for (int b0 = 0; b0 < n; b0 += _floorBlockFrames) {
      final int lo = math.max(0, b0 - _floorSpanFrames);
      final int hi = math.min(n, b0 + _floorBlockFrames + _floorSpanFrames);
      window.clear();
      for (int k = lo; k < hi; k++) {
        if (db[k] != 0) window.add(db[k]);
      }
      double t = maxThresholdDb;
      if (window.isNotEmpty) {
        window.sort();
        final double floor = window[((window.length - 1) * 10 / 100).round()]
            .toDouble();
        t = (floor + floorMarginDb).clamp(minThresholdDb, maxThresholdDb);
      }
      final int end = math.min(n, b0 + _floorBlockFrames);
      for (int k = b0; k < end; k++) {
        out[k] = t;
      }
    }
    return out;
  }

  static int? _firstTokenMs(AudioCue cue) {
    final CueTokenTiming? t = cue.tokenTiming;
    if (t == null || t.isEmpty) return null;
    return cue.startMs + t.offsetsMs.first;
  }

  /// 挪起点时 token 偏移（相对起点）一起平移，绝对发射时刻不变。
  static void _shiftStart(AudioCue cue, int start) {
    final CueTokenTiming? t = cue.tokenTiming;
    final int delta = start - cue.startMs;
    cue.startMs = start;
    if (t == null || t.isEmpty || delta == 0) return;
    cue.tokenTiming = CueTokenTiming(
      tokens: t.tokens,
      offsetsMs: List<int>.unmodifiable(
        t.offsetsMs.map((int o) => math.max(0, o - delta)),
      ),
    );
  }
}
