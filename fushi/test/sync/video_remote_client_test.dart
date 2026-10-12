import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/video_remote_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late FushiDatabase database;
  late SyncRepository repository;
  const FushiClientUrl selected = FushiClientUrl(
    url: 'http://selected:8765',
    token: 'secret',
    hostId: 'selected',
  );
  setUp(() async {
    database = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    repository = SyncRepository(database);
    await repository.setFushiClientUrls(const <FushiClientUrl>[
      selected,
      FushiClientUrl(url: 'http://other:8765', token: 'other', hostId: 'other'),
    ]);
  });
  tearDown(() async {
    await database.close();
  });
  test(
    'remote rejection preserves host error and never reaches other device',
    () async {
      final List<String> reached = <String>[];
      final VideoRemoteClient client = VideoRemoteClient(
        repository: repository,
        peer: selected,
        httpClient: MockClient((http.Request request) async {
          reached.add(request.url.host);
          return http.Response(
            jsonEncode(<String, dynamic>{'error': 'stale_session'}),
            409,
          );
        }),
      );
      await expectLater(
        client.snapshot(),
        throwsA(
          isA<VideoRemoteError>()
              .having(
                (VideoRemoteError e) => e.message,
                'message',
                'stale_session',
              )
              .having((VideoRemoteError e) => e.statusCode, 'status', 409),
        ),
      );
      expect(reached, <String>['selected']);
      client.cancelPending();
    },
  );
  test(
    'poll sends revision and bounded wait with paired credentials',
    () async {
      final VideoRemoteClient client = VideoRemoteClient(
        repository: repository,
        peer: selected,
        httpClient: MockClient((http.Request request) async {
          expect(request.url.path, '/api/video-remote/events');
          expect(jsonDecode(request.body), <String, dynamic>{
            'afterRevision': 42,
            'waitMs': 25000,
          });
          expect(
            request.headers['Authorization'],
            'Basic ${base64Encode(utf8.encode('hibiki:secret'))}',
          );
          return http.Response('{"revision":43,"events":[]}', 200);
        }),
      );
      expect((await client.events(42))['revision'], 43);
      client.cancelPending();
    },
  );
}
