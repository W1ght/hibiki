import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_dialog_page.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:path/path.dart' as path;

import '../helpers/test_platform_services.dart';

class _DictionaryFilesAppModel extends AppModel {
  _DictionaryFilesAppModel(this.resourceRoot, this.entries)
      : super(testPlatformServices()) {
    populateDictionaryFormats();
  }

  final Directory resourceRoot;
  final List<Dictionary> entries;
  int visibilityChanges = 0;

  @override
  List<Dictionary> get dictionaries => entries;

  @override
  List<Dictionary> get termDictionaries => entries;

  @override
  bool isDictionaryInstalledOnDisk(String name) =>
      Directory(path.join(resourceRoot.path, name)).existsSync();

  @override
  bool get autoUpdateDictionaries => false;

  @override
  DictionaryUpdateInterval get dictionaryUpdateInterval =>
      DictionaryUpdateInterval.weekly;

  @override
  DateTime? get lastDictionaryUpdateAt => null;

  @override
  void toggleDictionaryHidden(Dictionary dictionary) {
    visibilityChanges++;
    dictionary.hiddenLanguages = dictionary.isHidden(JapaneseLanguage.instance)
        ? <String>[]
        : <String>[JapaneseLanguage.instance.languageCode];
    notifyListeners();
  }

  void refreshFiles() => notifyListeners();
}

Widget _wrap(_DictionaryFilesAppModel appModel) => ProviderScope(
      overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
      child: TranslationProvider(
        child: MaterialApp(home: const DictionaryDialogPage()),
      ),
    );

Finder _row(String name) => find.widgetWithText(FushiCard, name);

Switch _visibilitySwitch(WidgetTester tester, String name) =>
    tester.widget<Switch>(
      find.descendant(of: _row(name), matching: find.byType(Switch)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  for (final double width in <double>[360, 1200]) {
    testWidgets(
      'BUG-2385 missing files are visible and cannot be enabled ($width)',
      (WidgetTester tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final Directory root = Directory.systemTemp.createTempSync(
          'dict-missing-',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final Dictionary dictionary = Dictionary(
          name: '三省堂国語辞典　第八版',
          formatKey: YomichanFormat.instance.uniqueKey,
          order: 7,
          metadata: <String, String>{'revision': 'sankoku8;2023-07-19'},
        );
        final String savedMetadata = dictionary.toJson();
        final _DictionaryFilesAppModel appModel = _DictionaryFilesAppModel(
          root,
          <Dictionary>[dictionary],
        );

        await tester.pumpWidget(_wrap(appModel));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text(dictionary.name), findsOneWidget);
        expect(find.text('sankoku8;2023-07-19'), findsOneWidget);
        expect(find.text(t.dictionary_files_missing), findsOneWidget);
        final Switch missingSwitch = _visibilitySwitch(tester, dictionary.name);
        expect(missingSwitch.value, isFalse);
        expect(missingSwitch.onChanged, isNull);
        expect(appModel.visibilityChanges, 0);
        expect(dictionary.toJson(), savedMetadata);

        // Re-import restores the resources, so the next page rebuild must recover
        // the saved enabled state without rewriting metadata or toggling visibility.
        Directory(path.join(root.path, dictionary.name)).createSync();
        appModel.refreshFiles();
        await tester.pump();

        expect(find.text(t.dictionary_files_missing), findsNothing);
        final Switch restoredSwitch = _visibilitySwitch(
          tester,
          dictionary.name,
        );
        expect(restoredSwitch.value, isTrue);
        expect(restoredSwitch.onChanged, isNotNull);
        expect(appModel.visibilityChanges, 0);
        expect(dictionary.toJson(), savedMetadata);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'BUG-2385 restoring files preserves an existing hidden preference',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final Directory root = Directory.systemTemp.createTempSync(
        'dict-hidden-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final Dictionary dictionary = Dictionary(
        name: 'Hidden dictionary',
        formatKey: YomichanFormat.instance.uniqueKey,
        order: 3,
        hiddenLanguages: <String>[JapaneseLanguage.instance.languageCode],
      );
      final String savedMetadata = dictionary.toJson();
      final _DictionaryFilesAppModel appModel = _DictionaryFilesAppModel(
        root,
        <Dictionary>[dictionary],
      );
      await tester.pumpWidget(_wrap(appModel));
      await tester.pump();

      expect(find.text(t.dictionary_files_missing), findsOneWidget);
      expect(_visibilitySwitch(tester, dictionary.name).onChanged, isNull);
      Directory(path.join(root.path, dictionary.name)).createSync();
      appModel.refreshFiles();
      await tester.pump();

      expect(find.text(t.dictionary_files_missing), findsNothing);
      final Switch restoredSwitch = _visibilitySwitch(tester, dictionary.name);
      expect(restoredSwitch.value, isFalse);
      expect(restoredSwitch.onChanged, isNotNull);
      expect(appModel.visibilityChanges, 0);
      expect(dictionary.toJson(), savedMetadata);
      expect(tester.takeException(), isNull);
    },
  );
}
