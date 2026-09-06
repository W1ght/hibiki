import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_play_bar.dart';
import 'package:fushi/src/media/audiobook/reader_quick_settings_sheet.dart'
    show ReaderQuickSettingsSheet;
import 'package:fushi_audio/fushi_audio.dart';

import '../../pages/reader_fushi_page_source_corpus.dart';

/// 播放条条尾的「阅读设置」齿轮：
///  ① [AudiobookPlayBar.onOpenSettings] 为 null 时不渲染齿轮（桌面端顶部工具栏已有
///     同名入口，条尾的那颗既重复又开错面板——开的是有声书面板）；传了则照常渲染；
///  ② 页面侧：桌面 chrome 启用时传 null，移动端仍传回调（那里播放条取代了底部
///     设置栏，齿轮是唯一入口）；
///  ③ 阅读器外观抽屉的主题 section 带明暗模式分段选择器（与设置页同一行）。
void main() {
  const Key gear = ValueKey<String>('fushi_reader_audiobook_settings_button');

  Future<void> pump(WidgetTester tester, VoidCallback? onOpenSettings) async {
    final AudiobookPlayerController controller = AudiobookPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 500,
              child: AudiobookPlayBar(
                controller: controller,
                onOpenSettings: onOpenSettings,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('onOpenSettings == null → 没有齿轮', (tester) async {
    await pump(tester, null);
    expect(find.byKey(gear), findsNothing);
    // 其余控件不受影响。
    expect(find.byType(AudiobookFollowAudioButton), findsOneWidget);
  });

  testWidgets('传了回调 → 齿轮照常渲染', (tester) async {
    await pump(tester, () {});
    expect(find.byKey(gear), findsOneWidget);
  });

  group('source guards', () {
    test('页面：桌面 chrome 启用时不给播放条设置回调', () {
      final String source = readReaderPageSource();
      final String bar = source.substring(
        source.indexOf('Widget _buildAudiobookBar()'),
        source.indexOf('Future<void> _changeReaderWindowFullscreen()'),
      );
      expect(
        bar,
        contains(
          'onOpenSettings: _desktopChromeEnabled\n                ? null',
        ),
      );
      expect(
        bar,
        contains("_showAppearanceSheet(initialSubPage: 'audiobook')"),
      );
    });

    test('外观抽屉主题 section 带明暗模式分段选择器', () {
      // 引用类型只为把本守卫钉在真实文件上（改名 / 搬家时编译先红）。
      expect(ReaderQuickSettingsSheet, isNotNull);
      final String source = File(
        'lib/src/media/audiobook/reader_quick_settings_sheet.dart',
      ).readAsStringSync();
      final String section = source.substring(
        source.indexOf('Widget _buildThemeSelectorSection()'),
        source.indexOf('Widget _buildBookCssEditorRow()'),
      );
      expect(section, contains('buildBrightnessSelector(themeContext)'));
      expect(section, contains('buildThemeSelector(themeContext)'));
      // 同一 SettingsContext：换挡后也走 _syncThemeSelection 的词典 / 歌词联动。
      expect(section, contains('_themeSettingsContext()'));
    });
  });
}
