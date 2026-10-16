import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3368：有声书播放跟读期间，阅读位置只能有一个所有者——当前句
/// （`_syncPositionFromCurrentCue`）。
///
/// 旧实现里视口首字也照常落库：跟读把句子放在视口内侧，视口首边残留章首半列，量出
/// 0，于是每推进一句就「句位 / 0」交替落库（真机日志 67 / 0 / 73 / 0 …）；进程恰在 0
/// 时被回收，重开落回章首（真机复现：暂停后重开 `restore from saved position ...
/// charOffset=0`）。
///
/// 两个实时读入口（`_refreshProgress` 与退出 / 切后台的
/// `_syncPositionFromWebViewProgress`）写 `_lastProgress*` 与落库前都必须先过
/// `shouldRevealCurrentCue` 这道门；这里按方法体切出源码钉住。
void main() {
  final String source = File(
    'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
  ).readAsStringSync();

  String methodBody(String signature) {
    final int start = source.indexOf(signature);
    expect(start, isNonNegative, reason: '$signature must exist');
    final int end = source.indexOf('\n  }\n', start);
    expect(end, greaterThan(start), reason: '$signature body must end');
    return source.substring(start, end);
  }

  test('_refreshProgress leaves the position to the cue while following', () {
    final String body = methodBody('Future<void> _refreshProgress() async {');
    final int gate = body.indexOf(
      '_audiobookController?.shouldRevealCurrentCue == true',
    );
    expect(gate, isNonNegative, reason: 'follow gate must be read');
    final int write = body.indexOf('_lastProgressValue = progress;');
    expect(write, greaterThan(gate), reason: 'cache write comes after gate');
    expect(
      body.substring(gate, write),
      contains('if (!cueOwnsPosition) {'),
      reason: 'the cached position must not be written while following',
    );
    expect(
      body,
      contains('if (!cueOwnsPosition) _debouncedSavePosition(progress, '),
      reason: 'the viewport position must not be persisted while following',
    );
  });

  test('exit / lifecycle live read leaves the position to the cue', () {
    final String body = methodBody(
      'Future<void> _syncPositionFromWebViewProgress() async {',
    );
    final int gate = body.indexOf(
      'if (_audiobookController?.shouldRevealCurrentCue != true) {',
    );
    expect(gate, isNonNegative, reason: 'follow gate must guard the write');
    final int write = body.indexOf('_lastProgressValue = snapshot.progress;');
    expect(write, greaterThan(gate), reason: 'cache write sits inside gate');
    expect(
      body.substring(gate, write),
      isNot(contains('\n    }')),
      reason: 'the gated block must still be open at the cache write',
    );
  });
}
