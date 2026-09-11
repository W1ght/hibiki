import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_resume_reconcile.dart';

/// BUG-2462：重开书时正文保存位置落后于有声书位置（退书后台续听 / 锁屏听完 / 换端
/// 听过），一按播放就从旧页被拽到音频处、中间几十页瞬间翻过。
///
/// ① 纯判据：音频位置比正文位置新出宽限（退出时两个 flush 的时间戳天然差几百毫秒，
///    不能判成「音频更新」）；cue 派生位置与保存位置隔得够远才换起点（同一页内保留
///    带精确锚的保存位置）。
/// ② 源码守卫：开书保存位置分支必须先问 `_audioPositionOutranksSaved`（只读时间戳、
///    不等音频槽），判真才 `await audioSlotFuture` 再 `_audioCueStartOutrankingSaved`
///    → `_applyAudioCueStart`；判据里必须看「跟随音频」开关；无保存位置的老路
///    `_restoreFromCurrentAudioCue` 与新路共用 `_positionFromCurrentAudioCue`。
void main() {
  group('audiobookPositionIsNewer', () {
    test('音频比正文新出宽限以上才算', () {
      expect(
        audiobookPositionIsNewer(audioUpdatedAt: 10000, readerUpdatedAt: 5000),
        isTrue,
      );
      expect(
        audiobookPositionIsNewer(
          audioUpdatedAt: 10000,
          readerUpdatedAt: 10000 - kAudiobookResumeGraceMs,
        ),
        isFalse,
        reason: '恰好等于宽限不算（退出 flush 顺序造成的毫秒级差距）',
      );
      expect(
        audiobookPositionIsNewer(audioUpdatedAt: 10700, readerUpdatedAt: 10000),
        isFalse,
        reason: '退书时 reader 先 flush 正文、再 flush 音频，差几百毫秒是常态',
      );
      expect(
        audiobookPositionIsNewer(audioUpdatedAt: 5000, readerUpdatedAt: 10000),
        isFalse,
        reason: '正文更新（用户静读到前面去了）不动',
      );
    });

    test('任一时间戳缺失（旧数据 0）判否', () {
      expect(
        audiobookPositionIsNewer(audioUpdatedAt: 0, readerUpdatedAt: 5000),
        isFalse,
      );
      expect(
        audiobookPositionIsNewer(audioUpdatedAt: 99999, readerUpdatedAt: 0),
        isFalse,
      );
    });
  });

  group('readerPositionsFarApart', () {
    test('不同章即远', () {
      expect(
        readerPositionsFarApart(
          savedSection: 3,
          savedProgress: 0.9,
          audioSection: 4,
          audioProgress: 0.0,
          chapterChars: 8000,
        ),
        isTrue,
      );
    });

    test('同章按 Δprogress × 章字数折成字与阈值比', () {
      // 8000 字的章：5% = 400 字（一页内）→ 不远；10% = 800 字 → 远。
      expect(
        readerPositionsFarApart(
          savedSection: 0,
          savedProgress: 0.10,
          audioSection: 0,
          audioProgress: 0.15,
          chapterChars: 8000,
        ),
        isFalse,
      );
      expect(
        readerPositionsFarApart(
          savedSection: 0,
          savedProgress: 0.10,
          audioSection: 0,
          audioProgress: 0.20,
          chapterChars: 8000,
        ),
        isTrue,
      );
      expect(
        readerPositionsFarApart(
          savedSection: 0,
          savedProgress: 0.60,
          audioSection: 0,
          audioProgress: 0.10,
          chapterChars: 8000,
        ),
        isTrue,
        reason: '音频在后面（后台回听）同样算远，谁新谁赢不分方向',
      );
    });

    test('章字数未知时退回万分比阈值', () {
      expect(
        readerPositionsFarApart(
          savedSection: 0,
          savedProgress: 0.0,
          audioSection: 0,
          audioProgress: kAudiobookResumeMinDistanceChars / 10000.0,
          chapterChars: 0,
        ),
        isTrue,
      );
      expect(
        readerPositionsFarApart(
          savedSection: 0,
          savedProgress: 0.0,
          audioSection: 0,
          audioProgress: 0.01,
          chapterChars: 0,
        ),
        isFalse,
      );
    });
  });

  group('源码守卫：开书保存位置分支的对账接线', () {
    final String page = File(
      'lib/src/pages/implementations/reader_fushi_page.dart',
    ).readAsStringSync();
    final String audio = File(
      'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
    ).readAsStringSync();

    test('保存位置分支：先问时间戳判据，判真才等槽、再按 cue 推起点', () {
      final int branch = page.indexOf(
        'saved.sectionIndex < _book!.chapters.length) {',
      );
      expect(branch, greaterThanOrEqualTo(0));
      final String body = page.substring(branch, branch + 2200);
      final int ask = body.indexOf('await _audioPositionOutranksSaved(saved)');
      final int slot = body.indexOf('await audioSlotFuture;', ask);
      final int start = body.indexOf(
        '_audioCueStartOutrankingSaved(saved)',
        slot,
      );
      final int apply = body.indexOf('_applyAudioCueStart(fromAudio', start);
      final int keep = body.indexOf(
        '_initialCharOffset = saved.charOffset ?? -1;',
        apply,
      );
      expect(ask, greaterThanOrEqualTo(0), reason: '必须先问时间戳判据');
      expect(slot, greaterThan(ask), reason: '判真后才等音频槽（槽不挡首屏）');
      expect(start, greaterThan(slot));
      expect(apply, greaterThan(start));
      expect(keep, greaterThan(apply), reason: '判否走原保存位置分支（精确锚）');
    });

    test('时间戳判据只读 pref、看跟随开关，不碰音频槽', () {
      final int s = audio.indexOf(
        'Future<bool> _audioPositionOutranksSaved(ReaderPosition saved)',
      );
      expect(s, greaterThanOrEqualTo(0));
      final String body = audio.substring(s, audio.indexOf('\n  }\n', s));
      expect(body, contains('resolvePrefsKey(widget.bookKey)'));
      expect(body, contains('readPositionUpdatedAtMs(key)'));
      expect(body, contains('audiobookPositionIsNewer('));
      expect(body, contains('readFollowAudio(key)'));
      expect(body, isNot(contains('audioSlotFuture')));
      expect(body, isNot(contains('_resolveAudioSlot')));
    });

    test('cue 起点判据：不精确且同章不换；远才换', () {
      final int s = audio.indexOf(
        'AudioCueStart? _audioCueStartOutrankingSaved(ReaderPosition saved)',
      );
      expect(s, greaterThanOrEqualTo(0));
      final String body = audio.substring(s, audio.indexOf('\n  }\n', s));
      expect(
        body,
        contains(
          'if (!pos.precise && pos.chapter == saved.sectionIndex) return null;',
        ),
      );
      expect(body, contains('readerPositionsFarApart('));
    });

    test('无保存位置的老路与新路共用同一个 cue → 起点推导', () {
      expect(
        '_positionFromCurrentAudioCue()'.allMatches(audio).length,
        3,
        reason:
            '定义一次 + _restoreFromCurrentAudioCue / '
            '_audioCueStartOutrankingSaved 各调一次',
      );
      expect(
        audio,
        contains("_applyAudioCueStart(pos, reason: 'no saved position')"),
      );
      final int apply = audio.indexOf('void _applyAudioCueStart(');
      final String body = audio.substring(
        apply,
        audio.indexOf('\n  }\n', apply),
      );
      expect(body, contains('_initialCharOffset = -1;'), reason: 'cue 派生无精确锚');
      expect(body, contains('_lastProgressCharOffset = -1;'));
    });
  });
}
