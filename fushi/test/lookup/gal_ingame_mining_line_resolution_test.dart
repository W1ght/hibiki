import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/sync/texthooker_service.dart';

// BUG-2081：内嵌查词命中的 textGeneration 是原生几何 provider 的命中序（hit_seq），
// 与文本行的 sourceSequence（Luna 发布序）不同空间；seq 精配落空后必须退回整行文本
// 定位，而不是 fail closed 让制卡静默失败。

TexthookerLineEntry _line(
  String id,
  String text, {
  int? sourceSequence,
}) {
  return TexthookerLineEntry(
    id: id,
    text: text,
    source: TexthookerLineSource.engineHook,
    receivedAt: DateTime.fromMillisecondsSinceEpoch(0),
    sourceSequence: sourceSequence,
  );
}

void main() {
  group('resolveIngameMiningLineId', () {
    final List<TexthookerLineEntry> lines = <TexthookerLineEntry>[
      _line('a-0', '「では契約は完了、ということでいいのかな」', sourceSequence: 11),
      _line('a-1', '「……」', sourceSequence: 12),
      _line('a-2', '「始めるとしよう。真理の探求を」', sourceSequence: 13),
    ];

    test('几何命中序与文本行序不同空间时，按整行文本命中最新 occurrence', () {
      // textGeneration=4 是几何 hit_seq，不等于任何 sourceSequence(11/12/13)。
      final String? id = resolveIngameMiningLineId(
        line: '「始めるとしよう。真理の探求を」',
        textGeneration: 4,
        lines: lines,
      );
      expect(id, 'a-2');
    });

    test('seq 与 sourceSequence 同源时精配仍命中（同源零回归）', () {
      final String? id = resolveIngameMiningLineId(
        line: '别的文本无所谓',
        textGeneration: 12,
        lines: lines,
      );
      expect(id, 'a-1');
    });

    test('净句完整相等优先于包含，且忽略空白差异', () {
      final List<TexthookerLineEntry> withWhitespace = <TexthookerLineEntry>[
        _line('b-0', '「始めるとしよう。\n真理の探求を」', sourceSequence: 1),
      ];
      final String? id = resolveIngameMiningLineId(
        line: '「始めるとしよう。真理の探求を」',
        textGeneration: 999,
        lines: withWhitespace,
      );
      expect(id, 'b-0');
    });

    test('textGeneration 为 null（无几何序）时同样按文本定位', () {
      final String? id = resolveIngameMiningLineId(
        line: '「始めるとしよう。真理の探求を」',
        textGeneration: null,
        lines: lines,
      );
      expect(id, 'a-2');
    });

    test('短串（<8 净字）不走包含兜底，避免误绑助词/人名', () {
      final List<TexthookerLineEntry> shortLines = <TexthookerLineEntry>[
        _line('c-0', 'これはとても長い一文の台詞である', sourceSequence: 1),
      ];
      final String? id = resolveIngameMiningLineId(
        line: 'とても',
        textGeneration: 7,
        lines: shortLines,
      );
      expect(id, isNull);
    });

    test('长净句的双向包含兜底：传感器行比文本行多一层姓名', () {
      final List<TexthookerLineEntry> nameLines = <TexthookerLineEntry>[
        _line('d-0', '「ありがとう。ここ数百年、悪魔というものが定義されて以降」', sourceSequence: 5),
      ];
      // 点击命中的整行只有正文，是文本行的严格子串（净字远超 8）。
      final String? id = resolveIngameMiningLineId(
        line: 'ここ数百年、悪魔というものが定義されて以降',
        textGeneration: 4,
        lines: nameLines,
      );
      expect(id, 'd-0');
    });

    test('空行列表返回 null', () {
      final String? id = resolveIngameMiningLineId(
        line: 'なんでもいい',
        textGeneration: 1,
        lines: const <TexthookerLineEntry>[],
      );
      expect(id, isNull);
    });

    test('文本对不上任何行时返回 null（不硬塞最新行）', () {
      final String? id = resolveIngameMiningLineId(
        line: 'この文はどの行にも存在しない完全に別の一文',
        textGeneration: 4,
        lines: lines,
      );
      expect(id, isNull);
    });
  });
}
