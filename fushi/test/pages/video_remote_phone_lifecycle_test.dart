import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/video_remote_page.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const FushiClientUrl peer = FushiClientUrl(
    url: 'http://phone-test:8765',
    hostId: 'phone-test',
    token: 'paired-token',
  );
  late FushiDatabase database;
  late SyncRepository repository;
  late _PhoneHost host;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    repository = SyncRepository(database);
    await repository.setFushiClientUrls(<FushiClientUrl>[peer]);
    host = _PhoneHost();
  });
  tearDown(() async => database.close());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: VideoRemotePage(
            repository: repository,
            peer: peer,
            httpClient: host.client,
          ),
        ),
      ),
    );
    await _wait(tester, () => find.byType(FushiListItem).evaluate().isNotEmpty);
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
      await tester.tap(find.text(t.video_remote_favorites).last);
      await _wait(tester, () => find.byType(FushiSwitch).evaluate().isNotEmpty);
      tester.widget<FushiSwitch>(find.byType(FushiSwitch)).onChanged!(true);
      await _wait(
        tester,
        () => find.byType(FushiCheckboxListTile).evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Shared sentence'));
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
      await tester.tap(find.text(t.video_remote_favorites).last);
      await _wait(tester, () => find.byType(FushiSwitch).evaluate().isNotEmpty);
      tester.widget<FushiSwitch>(find.byType(FushiSwitch)).onChanged!(true);
      await _wait(
        tester,
        () => find.byType(FushiCheckboxListTile).evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Shared sentence'));
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
    'background dismisses the draft and resume waits for disconnect before snapshot',
    (WidgetTester tester) async {
      await open(tester);
      tester.widget<FushiListItem>(find.byType(FushiListItem).first).onTap!();
      await _wait(
        tester,
        () => find.text(t.video_remote_no_results).evaluate().isNotEmpty,
      );
      host.disconnectGate = Completer<void>();
      final int snapshots = host.operations
          .where((String op) => op == 'snapshot')
          .length;
      await tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await _wait(tester, () => host.operations.contains('disconnect'));
      await tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await _flush(tester);
      expect(find.text(t.video_remote_no_results), findsNothing);
      expect(
        host.operations.where((String op) => op == 'snapshot').length,
        snapshots,
      );
      host.disconnectGate!.complete();
      await _wait(
        tester,
        () =>
            host.operations.where((String op) => op == 'snapshot').length >
            snapshots,
      );
      expect(host.operations, isNot(contains('mine')));
      await close(tester);
    },
  );

  testWidgets(
    'episode change during subtitle paging recovers from stale session',
    (WidgetTester tester) async {
      host.rejectFirstSubtitles = true;
      await open(tester);
      expect(
        host.operations.where((String op) => op == 'snapshot').length,
        greaterThanOrEqualTo(2),
      );
      tester.widget<FushiListItem>(find.byType(FushiListItem).first).onTap!();
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
  final List<Completer<http.Response>> _events = <Completer<http.Response>>[];
  late final MockClient client = MockClient(_handle);
  Completer<void>? disconnectGate;
  bool available = true, rejectFirstSubtitles = false;
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
    'cueCount': available ? 1 : 0,
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
        return _response(<String, dynamic>{
          'total': 1,
          'cues': <Map<String, dynamic>>[cue],
        });
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
