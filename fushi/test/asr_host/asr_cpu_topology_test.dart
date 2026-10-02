/// Android 端 ASR 线程按大小核拓扑分配：纯函数规划 + sysfs 读取。
///
/// 回归点：ORT 不设 intra-op 时按全部核心起线程池，大小核手机上大核每个算子都
/// 等小核；天玑 900（2×A78 + 6×A55）实测见 `asr_cpu_topology.dart` 的说明。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/asr_host/asr_cpu_topology.dart';

void main() {
  group('planAsrCpuThreads', () {
    test('2 大 + 6 小（天玑 900）：编码器 2 线程，搜索 1×1', () {
      final AsrCpuThreadPlan plan = planAsrCpuThreads(<int>[
        2000000, 2000000, 2000000, 2000000, 2000000, 2000000, //
        2600000, 2600000,
      ]);
      expect(plan.performanceCores, 2);
      expect(plan.encoderThreads, 2);
      expect(plan.greedySessions, 1);
      expect(plan.greedyThreads, 1);
    });

    test('1+3+4 三簇（骁龙 8 系）：只去掉最低频簇', () {
      final AsrCpuThreadPlan plan = planAsrCpuThreads(<int>[
        1800000, 1800000, 1800000, 1800000, //
        2500000, 2500000, 2500000, 3200000,
      ]);
      expect(plan.performanceCores, 4);
      expect(plan.encoderThreads, 4);
      expect(plan.greedyThreads, 2);
    });

    test('同构多核：全算性能核，编码器封顶', () {
      final AsrCpuThreadPlan plan =
          planAsrCpuThreads(List<int>.filled(12, 2400000));
      expect(plan.performanceCores, 12);
      expect(plan.encoderThreads, 6);
    });

    test('读不到频率表：保守按 4 个性能核', () {
      final AsrCpuThreadPlan plan = planAsrCpuThreads(const <int>[]);
      expect(plan.performanceCores, 4);
      expect(plan.encoderThreads, 4);
    });
  });

  group('readCpuMaxFrequenciesKhz', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('cpu_topo_'));
    tearDown(() => root.deleteSync(recursive: true));

    void core(String name, String? khz) {
      final Directory d = Directory('${root.path}/$name/cpufreq')
        ..createSync(recursive: true);
      if (khz != null) {
        File('${d.path}/cpuinfo_max_freq').writeAsStringSync(khz);
      }
    }

    test('逐核读出，忽略非 cpuN 目录', () {
      core('cpu0', '2000000\n');
      core('cpu1', '2600000\n');
      Directory('${root.path}/cpufreq').createSync();
      Directory('${root.path}/cpuidle').createSync();
      expect(
        readCpuMaxFrequenciesKhz(root: root.path)..sort(),
        <int>[2000000, 2600000],
      );
    });

    test('任一核读不到就整体返回空表（半张表比不知道更糟）', () {
      core('cpu0', '2000000');
      core('cpu1', null);
      expect(readCpuMaxFrequenciesKhz(root: root.path), isEmpty);
    });

    test('根目录不存在：空表', () {
      expect(
        readCpuMaxFrequenciesKhz(root: '${root.path}/missing'),
        isEmpty,
      );
    });
  });
}
