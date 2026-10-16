import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:path/path.dart' as p;

/// 插图表的盘上缓存（BUG-3370）。
///
/// [EpubBook.images] 要把每一章 XHTML 整章解析一遍，长篇一次几百毫秒到秒级；歌词模式
/// 插图、阅读器插图册与书架插图库每次打开都要它。一本书导入后插图集合不变，所以算一次
/// 落盘，之后按章节文件指纹（大小 + 修改时间）判有效、直接读回。章节文件被换掉（在线小说
/// 占位页 → 正文）指纹随之变，自动重算。
///
/// 缓存放在 support 根下的独立目录，不放进书的解压目录：解压目录会被原样重打包成 .epub
/// 发给互联 / 云同步的对端、整树进备份，派生缓存不该混进书里。书挪了位置（换数据根）或
/// 缓存被清掉只是下次重算一次。
///
/// [EpubBook.images] 的扫描语义（字数口径、位置换算、`sharesLineWithText` 判据等）一旦
/// 改动，必须把 [kEpubImageIndexCacheVersion] 加一，否则旧缓存会继续顶替新结果。
const int kEpubImageIndexCacheVersion = 1;

/// support 根下的缓存目录名。
const String kEpubImageIndexCacheDirName = 'epub_image_index';

/// [cacheDir] 里属于解压目录 [extractDir] 的插图表缓存文件（按规范化路径的 sha1 命名）。
File epubImageIndexCacheFile(Directory cacheDir, String extractDir) {
  final String key = sha1
      .convert(utf8.encode(p.canonicalize(extractDir)))
      .toString();
  return File(p.join(cacheDir.path, '$key.json'));
}

/// 生产路径：`<support>/epub_image_index/<sha1>.json`。读全局 [enginePaths]，只能在
/// 根 isolate 调用（后台 isolate 里装配点不在）；没装配时返回 null = 不缓存。
Future<File?> epubImageIndexCacheFileFor(String extractDir) async {
  try {
    final Directory root = await enginePaths.supportRootDirectory();
    return epubImageIndexCacheFile(
      Directory(p.join(root.path, kEpubImageIndexCacheDirName)),
      extractDir,
    );
  } on Object {
    return null;
  }
}

/// [book] 的章节文件指纹。任一章没有盘上文件（eager 章节：DB 回退、测试构造）时
/// 返回 null——无从判断是否过期，不缓存。
String? epubImageIndexFingerprint(EpubBook book) {
  final StringBuffer out = StringBuffer()
    ..write('v$kEpubImageIndexCacheVersion|')
    ..write(book.coverHref ?? '');
  for (final EpubChapter chapter in book.chapters) {
    final String? path = chapter.filePath;
    if (path == null) return null;
    final FileStat stat = FileStat.statSync(path);
    out
      ..write('|')
      ..write(chapter.href)
      ..write(':')
      ..write(stat.size)
      ..write(':')
      ..write(stat.modified.millisecondsSinceEpoch);
  }
  return out.toString();
}

/// 取 [book] 的插图表，优先读 [cacheFile]（指纹一致才用），否则扫描整本书并把结果写回
/// [cacheFile]。读到的结果经 [EpubBook.adoptImages] 回填，同一实例之后再读不重算。
///
/// 读写失败（权限、磁盘满、内容损坏）一律当未命中处理：退回现算，绝不因缓存出错丢插图。
/// 同步执行，供后台 isolate 调用。
List<EpubImageRef> loadEpubImagesWithCache(EpubBook book, File cacheFile) {
  if (book.hasImages) return book.images;
  final String? fingerprint = epubImageIndexFingerprint(book);
  if (fingerprint != null) {
    final List<EpubImageRef>? cached = _readCache(cacheFile, fingerprint);
    if (cached != null) {
      book.adoptImages(cached);
      return book.images;
    }
  }
  final List<EpubImageRef> images = book.images;
  if (fingerprint != null) _writeCache(cacheFile, fingerprint, images);
  return images;
}

List<EpubImageRef>? _readCache(File file, String fingerprint) {
  try {
    if (!file.existsSync()) return null;
    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['fingerprint'] != fingerprint) return null;
    final Object? list = decoded['images'];
    if (list is! List<dynamic>) return null;
    return <EpubImageRef>[
      for (final dynamic entry in list)
        EpubImageRef.fromJson(entry as Map<String, dynamic>),
    ];
  } on Object {
    return null;
  }
}

void _writeCache(File file, String fingerprint, List<EpubImageRef> images) {
  final File tmp = File('${file.path}.tmp');
  try {
    file.parent.createSync(recursive: true);
    tmp.writeAsStringSync(
      jsonEncode(<String, Object>{
        'fingerprint': fingerprint,
        'images': <Map<String, Object>>[
          for (final EpubImageRef ref in images) ref.toJson(),
        ],
      }),
      flush: true,
    );
    tmp.renameSync(file.path);
  } on Object {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } on Object {
      // 尽力清理；缓存是派生物，写不出来只是下次再算。
    }
  }
}
