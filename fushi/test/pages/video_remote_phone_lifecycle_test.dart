import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:fushi/src/pages/implementations/video_remote_page.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';

/// 弹框布局读到的那几项偏好；本机词典查询在遥控页里必须一次都不发生。
class _RemotePageAppModel extends AppModel {
  _RemotePageAppModel() : super(testPlatformServices());

  int localSearches = 0;

  @override
  int get maximumTerms => 10;
  @override
  double get popupMaxWidth => 360;
  @override
  double get popupMaxHeight => 360;
  @override
  double get dictionaryFontSize => 16;
  @override
  bool get popupBottomDocked => false;
  @override
  double get appUiScale => 1.0;
  @override
  bool get lowMemoryMode => false;
  @override
  List<String> get enabledAudioSources => const <String>[];
  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}
  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}
  @override
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async {
    localSearches++;
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

void main() {
  setUpAll(installFakeInAppWebViewPlatform);
  const FushiClientUrl peer = FushiClientUrl(
    url: 'http://phone-test:8765',
    hostId: 'phone-test',
    token: 'paired-token',
  );
  late FushiDatabase database;
  late SyncRepository repository;
  late _PhoneHost host;
  late _RemotePageAppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    repository = SyncRepository(database);
    await repository.setFushiClientUrls(<FushiClientUrl>[peer]);
    host = _PhoneHost();
    appModel = _RemotePageAppModel();
  });
  tearDown(() async => database.close());

  VideoRemotePageState page(WidgetTester tester) =>
      tester.state<VideoRemotePageState>(find.byType(VideoRemotePage));

  int count(String operation) =>
      host.operations.where((String op) => op == operation).length;

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWith((Ref ref) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            home: VideoRemotePage(
              repository: repository,
              peer: peer,
              httpClient: host.client,
            ),
          ),
        ),
      ),
    );
    await _wait(tester, () => page(tester).rows.isNotEmpty);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    host.releaseEvents();
    await _flush(tester);
    host.client.close();
  }

  testWidgets(
    'history lookup confirms a different episode despite identical text and time',
    (WidgetTester tester) async {
      await open(tester);
      unawaited(page(tester).setFavoritesAllVideos(true));
      await _wait(tester, () => page(tester).favorites.isNotEmpty);
      unawaited(
        page(tester).openFavorite(page(tester).favorites.single, lookup: true),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(host.lookups, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, t.cancel));
      await tester.pumpAndSettle();
      expect(host.operations, isNot(contains('openFavorite')));
      await close(tester);
    },
  );

  testWidgets(
    'history lookup waits for the target player event after route replacement',
    (WidgetTester tester) async {
      await open(tester);
      unawaited(page(tester).setFavoritesAllVideos(true));
      await _wait(tester, () => page(tester).favorites.isNotEmpty);
      unawaited(
        page(tester).openFavorite(page(tester).favorites.single, lookup: true),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, t.play).last);
      await _wait(tester, () => host.operations.contains('openFavorite'));
      await _flush(tester);
      expect(host.lookups, isEmpty);
      expect(find.text(t.video_remote_waiting), findsWidgets);
      host.publish(available: true, section: 1);
      await _wait(tester, () => host.lookups.isNotEmpty);
      expect(host.lookups.single['sessionId'], 'episode-1');
      expect(host.lookups.single['cueId'], 'cue-1');
      await close(tester);
    },
  );

  testWidgets(
    'background closes the lookup popup, ends the lookup and resume waits for disconnect',
    (WidgetTester tester) async {
      await open(tester);
      unawaited(page(tester).openLookup(page(tester).rows.first, 0));
      await _wait(tester, () => page(tester).lookupOpen);
      expect(host.lookups, hasLength(1));
      expect(host.operations, contains('dictionary'));
      expect(appModel.localSearches, 0);
      host.disconnectGate = Completer<void>();
      final int snapshots = count('snapshot');
      // iOS control centre / banners only reach `inactive`: keep the lease.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _flush(tester);
      expect(count('disconnect'), 0);
      expect(page(tester).lookupOpen, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _wait(tester, () => count('disconnect') > 0);
      await _flush(tester);
      expect(page(tester).lookupOpen, isFalse);
      // The lookup context ends (the computer resumes only its own pause)
      // before the lease is released.
      expect(host.ended, <String>['lookup-1']);
      expect(
        host.operations.lastIndexOf('lookupEnd'),
        lessThan(host.operations.lastIndexOf('disconnect')),
      );
      expect(count('disconnect'), 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _flush(tester);
      expect(count('snapshot'), snapshots);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);
      expect(count('disconnect'), 1);
      expect(count('snapshot'), snapshots);
      host.disconnectGate!.complete();
      await _wait(tester, () => count('snapshot') > snapshots);
      expect(host.operations, isNot(contains('mine')));
      await close(tester);
    },
  );

  testWidgets(
    'the lookup context lives as long as the popup stack and follows the tapped line',
    (WidgetTester tester) async {
      host.dualTrack = true;
      await open(tester);
      final VideoRemotePageState state = page(tester);
      unawaited(state.openLookup(state.rows[1], 0));
      await _wait(tester, () => state.lookupOpen);
      expect(host.lookups.single['cueId'], 'primary-1');
      // Same line again: the context is reused, the computer is not re-paused.
      unawaited(state.openLookup(state.rows[1], 2));
      await _wait(tester, () => count('dictionary') >= 2);
      await _flush(tester);
      expect(count('lookupBegin'), 1);
      // Another line while open: end the old context, then begin the new one.
      unawaited(state.openLookup(state.rows[2], 0));
      await _wait(tester, () => count('lookupBegin') == 2);
      expect(host.ended, <String>['lookup-1']);
      expect(
        host.operations.lastIndexOf('lookupEnd'),
        lessThan(host.operations.lastIndexOf('lookupBegin')),
      );
      expect(host.lookups.last['cueId'], 'primary-2');
      await _wait(tester, () => state.lookupOpen);
      state.closeLookup();
      await _wait(tester, () => host.ended.length == 2);
      expect(host.ended.last, 'lookup-2');
      expect(state.lookupOpen, isFalse);
      expect(appModel.localSearches, 0);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets('mining goes to the computer bound to the lookup context', (
    WidgetTester tester,
  ) async {
    await open(tester);
    final VideoRemotePageState state = page(tester);
    unawaited(state.openLookup(state.rows.first, 0));
    await _wait(tester, () => state.lookupOpen);
    late MinePopupResult result;
    await tester.runAsync(() async {
      result = await state.onMineEntry(<String, String>{
        'expression': '猫',
        'reading': 'ねこ',
        'glossary': 'cat',
        'sentence': 'Shared sentence',
      });
    });
    expect(result.queued, isTrue);
    expect(host.mines.single['contextId'], 'lookup-1');
    final Map<String, dynamic> fields =
        host.mines.single['fields'] as Map<String, dynamic>;
    expect(fields['rawFields'], containsPair('expression', '猫'));
    expect(fields['sentence'], 'Shared sentence');
    expect(host.operations, contains('mineStatus'));
    // Local Anki / favorites entry points stay disabled on the phone.
    expect(await state.checkDuplicate('猫', 'ねこ'), isFalse);
    expect(
      await state.onFavoriteEntry(<String, String>{'expression': '猫'}),
      isFalse,
    );
    state.closeLookup();
    await _wait(tester, () => host.ended.isNotEmpty);
    await close(tester);
  });

  testWidgets(
    'dual subtitles highlight and skip along the primary track only',
    (WidgetTester tester) async {
      host.dualTrack = true;
      await open(tester);
      await _wait(tester, () => page(tester).currentRowIndex >= 0);
      final VideoRemotePageState state = page(tester);
      // Rows interleave both tracks; the current line is the primary one.
      expect(state.currentRowIndex, 1);
      expect(state.isPrimaryRow(state.rows[0]), isFalse);
      expect(state.previousRowIndex, -1);
      expect(state.nextRowIndex, 2);
      unawaited(state.nextRow());
      await _wait(tester, () => host.commands.isNotEmpty);
      expect(host.commands.single['cueId'], 'primary-2');
      await close(tester);
    },
  );

  test('remote errors are localized and never show raw exception text', () {
    expect(
      videoRemoteErrorText(const VideoRemoteError('controller_busy')),
      t.video_remote_error_controller_busy,
    );
    expect(
      videoRemoteErrorText(
        const VideoRemoteError('favorite_source_unavailable', statusCode: 409),
      ),
      t.video_remote_error_favorite_source_unavailable,
    );
    expect(
      videoRemoteErrorText(
        const VideoRemoteError('paired_peer_required', statusCode: 403),
      ),
      t.video_remote_error_pairing_rejected,
    );
    expect(
      videoRemoteErrorText(SyncAuthError('Video remote auth rejected')),
      t.video_remote_error_pairing_rejected,
    );
    expect(
      videoRemoteErrorText(
        const VideoRemoteError('brand_new', statusCode: 409),
      ),
      t.video_remote_error_unknown(code: 'brand_new'),
    );
    expect(
      videoRemoteErrorText(const VideoRemoteError('HTTP 404', statusCode: 404)),
      t.video_remote_unsupported,
    );
    expect(
      videoRemoteErrorText(const VideoRemoteError('lookup_cancelled')),
      '',
    );
  });

  testWidgets(
    'episode change during subtitle paging recovers from stale session',
    (WidgetTester tester) async {
      host.rejectFirstSubtitles = true;
      await open(tester);
      expect(
        host.operations.where((String op) => op == 'snapshot').length,
        greaterThanOrEqualTo(2),
      );
      unawaited(page(tester).openLookup(page(tester).rows.first, 0));
      await _wait(tester, () => host.lookups.isNotEmpty);
      expect(host.lookups.single['sessionId'], 'episode-1');
      await close(tester);
    },
  );
}

Future<void> _flush(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 5)),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (int i = 0; i < 80 && !ready(); i++) {
    await _flush(tester);
  }
  expect(ready(), isTrue);
}

final class _PhoneHost {
  final List<String> operations = <String>[];
  final List<Map<String, dynamic>> lookups = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> commands = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> mines = <Map<String, dynamic>>[];
  final List<String> ended = <String>[];
  final List<Completer<http.Response>> _events = <Completer<http.Response>>[];
  late final MockClient client = MockClient(_handle);
  Completer<void>? disconnectGate;
  bool available = true, rejectFirstSubtitles = false, dualTrack = false;
  int section = 0, revision = 1;

  Map<String, dynamic> get state => <String, dynamic>{
    'available': available,
    'revision': revision,
    'sessionId': available ? 'episode-$section' : '',
    'subtitleVersion': section + 1,
    'favoriteVersion': 1,
    'identity': 'shared-book',
    'sectionIndex': section,
    'title': 'Episode $section',
    'cueCount': available ? cues.length : 0,
    'playing': false,
    'positionMs': 1500,
    'durationMs': 10000,
    'speed': 1.0,
  };
  Map<String, dynamic> get cue => <String, dynamic>{
    'id': 'cue-$section',
    'text': 'Shared sentence',
    'startMs': 1000,
    'endMs': 3000,
    'delayMs': 0,
    'track': 'primary',
  };

  /// Dual-track lists interleave both tracks by time; the secondary line at
  /// the same instant sorts first here on purpose.
  List<Map<String, dynamic>> get cues => dualTrack
      ? <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'secondary-1',
            'text': 'Translated sentence',
            'startMs': 1000,
            'endMs': 3000,
            'delayMs': 0,
            'track': 'secondary',
          },
          <String, dynamic>{...cue, 'id': 'primary-1'},
          <String, dynamic>{
            'id': 'primary-2',
            'text': 'Next sentence',
            'startMs': 4000,
            'endMs': 6000,
            'delayMs': 0,
            'track': 'primary',
          },
        ]
      : <Map<String, dynamic>>[cue];
  Map<String, dynamic> get favorite => <String, dynamic>{
    'id': 'episode-one-favorite',
    'text': 'Shared sentence',
    'title': 'Episode 1',
    'bookUid': 'shared-book',
    'sectionIndex': 1,
    'startMs': 1000,
  };
  http.Response _response(Map<String, dynamic> body, [int status = 200]) =>
      http.Response(jsonEncode(body), status);

  Future<http.Response> _handle(http.Request request) async {
    final String operation = request.url.path.split('/').last;
    operations.add(operation);
    final Map<String, dynamic> body =
        jsonDecode(request.body) as Map<String, dynamic>;
    switch (operation) {
      case 'snapshot':
        return _response(state);
      case 'events':
        final Completer<http.Response> event = Completer<http.Response>();
        _events.add(event);
        return event.future;
      case 'subtitles':
        if (rejectFirstSubtitles) {
          rejectFirstSubtitles = false;
          section = 1;
          revision++;
          return _response(<String, dynamic>{'error': 'session_changed'}, 409);
        }
        return _response(<String, dynamic>{'total': cues.length, 'cues': cues});
      case 'favorites':
        final bool include = body['currentOnly'] != true || section == 1;
        return _response(<String, dynamic>{
          'total': include ? 1 : 0,
          'items': <Map<String, dynamic>>[if (include) favorite],
        });
      case 'openFavorite':
        available = false;
        revision++;
        return _response(<String, dynamic>{'ok': true});
      case 'lookupBegin':
        lookups.add(body);
        return _response(<String, dynamic>{
          'contextId': 'lookup-${lookups.length}',
          'sentence': 'Shared sentence',
        });
      case 'dictionary':
        return _response(<String, dynamic>{
          'type': 'dictionaryResult',
          'result': <String, dynamic>{
            'searchTerm': 'Shared sentence',
            'entries': <dynamic>[],
          },
        });
      case 'lookupEnd':
        ended.add(body['contextId'].toString());
        return _response(<String, dynamic>{'ok': true});
      case 'mine':
        mines.add(body);
        return _response(<String, dynamic>{
          'taskId': 'mine_1',
          'status': 'running',
        });
      case 'mineStatus':
        return _response(<String, dynamic>{
          'taskId': 'mine_1',
          'status': 'succeeded',
          'result': <String, dynamic>{'ankiConnect': true, 'success': true},
        });
      case 'command':
        commands.add(body);
        return _response(<String, dynamic>{'ok': true});
      case 'disconnect':
        await disconnectGate?.future;
        releaseEvents();
        return _response(<String, dynamic>{'ok': true});
      default:
        return _response(<String, dynamic>{'ok': true});
    }
  }

  void publish({required bool available, required int section}) {
    this.available = available;
    this.section = section;
    revision++;
    final List<Completer<http.Response>> pending = <Completer<http.Response>>[
      ..._events,
    ];
    _events.clear();
    for (final Completer<http.Response> event in pending) {
      event.complete(
        _response(<String, dynamic>{
          'revision': revision,
          'events': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'state',
              'revision': revision,
              'payload': state,
            },
          ],
        }),
      );
    }
  }

  void releaseEvents() {
    final List<Completer<http.Response>> pending = <Completer<http.Response>>[
      ..._events,
    ];
    _events.clear();
    for (final Completer<http.Response> event in pending) {
      event.complete(
        _response(<String, dynamic>{
          'revision': revision,
          'events': <dynamic>[],
        }),
      );
    }
  }
}
