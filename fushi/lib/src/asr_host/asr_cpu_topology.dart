/// 移动端（Android）按本机 CPU 大小核拓扑给 ASR 分配推理线程。
///
/// 手机是 big.LITTLE：天玑 900 = 2×A78 2.6 GHz + 6×A55 2.0 GHz，骁龙 8 系 =
/// 1+3+4 或 1+4+3，入门芯片常是 2+6。ORT 不设 intra-op 时按**全部核心**起线程池，
/// 每个算子按核数均分、最后在屏障上等最慢的那个——小核拖住大核，而且编码器
/// 会话与贪心搜索会话并发时两个满核线程池互相抢核。所以线程数按「性能核」数分，
/// 小核留给 fbank isolate、ffmpeg 解码与 UI。
///
/// 纯函数 [planAsrCpuThreads] 只吃每核最高频率表，可在任何平台上测；读 sysfs 的
/// [readCpuMaxFrequenciesKhz] 只在 Android 上有意义，读不到就返回空表、规划退回
/// 保守值。
library;

import 'dart:io';

import 'package:meta/meta.dart';

/// 一份线程分配。
@immutable
class AsrCpuThreadPlan {
  const AsrCpuThreadPlan({
    required this.performanceCores,
    required this.encoderThreads,
    required this.greedySessions,
    required this.greedyThreads,
  });

  /// 判定出的性能核数（不含最低频那一簇）。
  final int performanceCores;

  /// 编码器（及其余未显式给线程数的 ASR 会话）的 intra-op 线程数。
  final int encoderThreads;

  /// 贪心 Loop 图会话数与每会话 intra-op 线程数。
  final int greedySessions;
  final int greedyThreads;

  @override
  String toString() =>
      'AsrCpuThreadPlan(perfCores=$performanceCores, encoder=$encoderThreads, '
      'greedy=${greedySessions}x$greedyThreads)';
}

/// 由每核最高频率（kHz，顺序无关）推线程分配。
///
/// 性能核：频率表里有两档及以上时，去掉最低频那一簇；只有一档（同构）时全算。
/// 表为空（读不到 sysfs）按 4 个性能核的保守值处理。
///
/// 编码器拿全部性能核（封顶 [maxEncoderThreads]）：它是整条链路的大头，int8
/// matmul 随核数近线性扩展；贪心搜索每帧只是 N×512 级的小矩阵，1~2 线程就够，
/// 与编码器流水线并发跑。性能核 ≤ 2 时搜索只给 1 线程，避免把编码器挤下大核。
AsrCpuThreadPlan planAsrCpuThreads(
  List<int> maxFrequenciesKhz, {
  int maxEncoderThreads = 6,
}) {
  int performance;
  if (maxFrequenciesKhz.isEmpty) {
    performance = 4;
  } else {
    final int slowest =
        maxFrequenciesKhz.reduce((int a, int b) => a < b ? a : b);
    final int fast = maxFrequenciesKhz.where((int f) => f > slowest).length;
    performance = fast == 0 ? maxFrequenciesKhz.length : fast;
  }
  final int encoder = performance.clamp(1, maxEncoderThreads);
  return AsrCpuThreadPlan(
    performanceCores: performance,
    encoderThreads: encoder,
    greedySessions: 1,
    greedyThreads: performance <= 2 ? 1 : 2,
  );
}

/// 读 `/sys/devices/system/cpu/cpu<N>/cpufreq/cpuinfo_max_freq`。任何一核读不到
/// （离线核、权限、非 Linux 内核）就整体返回空表——半张表会把缺的核当成不存在，
/// 比「不知道」更糟。
List<int> readCpuMaxFrequenciesKhz({String root = '/sys/devices/system/cpu'}) {
  try {
    final List<int> out = <int>[];
    final RegExp cpuDir = RegExp(r'^cpu\d+$');
    for (final FileSystemEntity e in Directory(root).listSync()) {
      final String name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!cpuDir.hasMatch(name)) continue;
      final File f = File('${e.path}/cpufreq/cpuinfo_max_freq');
      if (!f.existsSync()) return const <int>[];
      final int? khz = int.tryParse(f.readAsStringSync().trim());
      if (khz == null || khz <= 0) return const <int>[];
      out.add(khz);
    }
    return out;
  } on FileSystemException {
    return const <int>[];
  }
}

/// 本机的线程分配；只在 Android 上给出（桌面有 GPU 路径与各自调好的默认，
/// iOS 读不到 sysfs）。进程内算一次。
AsrCpuThreadPlan? get androidAsrCpuThreadPlan => _androidPlan;

final AsrCpuThreadPlan? _androidPlan =
    Platform.isAndroid ? planAsrCpuThreads(readCpuMaxFrequenciesKhz()) : null;
