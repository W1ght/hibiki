import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_image_index_cache.dart';

/// BUG-3370：插图表算一次落盘，之后按章节文件指纹（大小 + 修改时间）读回，不再整书
/// 解析 XHTML；章节文件换掉就重算，缓存坏了退回现算，无盘上文件的书不缓存。
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('epub-image-index-'));
  tearDown(() => dir.deleteSync(recursive: true));

  File chapterFile(int i) => File('${dir.path}/ch$i.xhtml');

  // 书的解压目录是 dir/book；缓存目录与它分开（生产在 support 根下）。
  String bookDir() => '${dir.path}/book';

  File cacheFileFor() =>
      epubImageIndexCacheFile(Directory('${dir.path}/cache'), bookDir());

  test('the cache lives outside the book directory, one file per book', () {
    final File a = cacheFileFor();
    expect(
      a.path.startsWith(bookDir()),
      isFalse,
      reason: 'the extract dir is repackaged into .epub for sync peers',
    );
    expect(
      epubImageIndexCacheFile(
        Directory('${dir.path}/cache'),
        '${dir.path}/other',
      ).path,
      isNot(a.path),
    );
  });

  void writeChapter(int i, String body) =>
      chapterFile(i).writeAsStringSync('<html><body>$body</body></html>');

  EpubBook lazyBook(int chapters) => EpubBook(
    title: 'T',
    chapters: <EpubChapter>[
      for (int i = 0; i < chapters; i++)
        EpubChapter.lazy(
          id: 'c$i',
          href: 'ch$i.xhtml',
          mediaType: 'application/xhtml+xml',
          filePath: chapterFile(i).path,
        ),
    ],
  );

  List<String> srcs(List<EpubImageRef> refs) =>
      refs.map((EpubImageRef r) => r.src).toList();

  test('first load scans and writes the cache; the next book reads it back '
      'without parsing', () {
    writeChapter(0, '<img src="a.png"/><p>文字</p><img src="b.png"/>');
    writeChapter(1, '<p>本文</p><img src="c.png"/>');
    final File cache = cacheFileFor();

    final List<EpubImageRef> first = loadEpubImagesWithCache(
      lazyBook(2),
      cache,
    );
    expect(srcs(first), <String>['a.png', 'b.png', 'c.png']);
    expect(cache.existsSync(), isTrue);

    // 换成同字节数、同修改时间的内容：指纹不变，能读出旧图名就说明没有重新解析。
    final DateTime mtime = chapterFile(0).lastModifiedSync();
    writeChapter(0, '<img src="x.png"/><p>文字</p><img src="y.png"/>');
    chapterFile(0).setLastModifiedSync(mtime);

    final EpubBook reopened = lazyBook(2);
    final List<EpubImageRef> second = loadEpubImagesWithCache(reopened, cache);
    expect(srcs(second), <String>['a.png', 'b.png', 'c.png']);
    expect(reopened.hasImages, isTrue, reason: 'adopted into the instance');
    for (int i = 0; i < first.length; i++) {
      expect(second[i].chapterIndex, first[i].chapterIndex);
      expect(second[i].orderInBook, first[i].orderInBook);
      expect(second[i].revealKey, first[i].revealKey);
      expect(second[i].normCharOffset, first[i].normCharOffset);
      expect(second[i].charOffset, first[i].charOffset);
      expect(second[i].sharesLineWithText, first[i].sharesLineWithText);
    }
  });

  test('a replaced chapter file invalidates the cache', () {
    writeChapter(0, '<img src="a.png"/>');
    final File cache = cacheFileFor();
    expect(srcs(loadEpubImagesWithCache(lazyBook(1), cache)), <String>[
      'a.png',
    ]);

    // 在线小说占位页 → 正文：文件内容与大小都变了。
    writeChapter(0, '<p>正文已经到了</p><img src="real.png"/>');
    expect(srcs(loadEpubImagesWithCache(lazyBook(1), cache)), <String>[
      'real.png',
    ]);
  });

  test('a corrupt cache falls back to scanning and is rewritten', () {
    writeChapter(0, '<img src="a.png"/>');
    final File cache = cacheFileFor();
    cache.parent.createSync(recursive: true);
    cache.writeAsStringSync('{not json');
    expect(srcs(loadEpubImagesWithCache(lazyBook(1), cache)), <String>[
      'a.png',
    ]);
    expect(cache.readAsStringSync(), contains('a.png'));
  });

  test('a book without on-disk chapters is never cached', () {
    final EpubBook eager = EpubBook(
      title: 'T',
      chapters: <EpubChapter>[
        EpubChapter(
          id: 'c0',
          href: 'ch0.xhtml',
          mediaType: 'application/xhtml+xml',
          html: '<html><body><img src="a.png"/></body></html>',
        ),
      ],
    );
    expect(epubImageIndexFingerprint(eager), isNull);
    final File cache = cacheFileFor();
    expect(srcs(loadEpubImagesWithCache(eager, cache)), <String>['a.png']);
    expect(cache.existsSync(), isFalse);
  });

  test('the fingerprint carries the scan version', () {
    writeChapter(0, '<img src="a.png"/>');
    expect(
      epubImageIndexFingerprint(lazyBook(1)),
      startsWith('v$kEpubImageIndexCacheVersion|'),
    );
  });
}
