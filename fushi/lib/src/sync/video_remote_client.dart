import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:http/http.dart' as http;
import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';

class VideoRemoteError implements Exception {
  const VideoRemoteError(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

/// All operations are bound to one paired host, including its credential and pin.
class VideoRemoteClient {
  VideoRemoteClient({
    required SyncRepository repository,
    required this.peer,
    http.Client? httpClient,
  }) : _repository = repository,
       _injected = httpClient;
  final FushiClientUrl peer;
  final SyncRepository _repository;
  final http.Client? _injected;
  final List<http.Client> _clients = <http.Client>[];
  final Map<String, http.Client> _pinned = <String, http.Client>{};
  InterconnectPostTransport? _current;
  InterconnectPostTransport get _transport =>
      _current ??= InterconnectPostTransport(
        repo: _repository,
        httpClient: _own(_injected ?? http.Client()),
        pinnedClientFactory: (String pin) => _BorrowedRemoteClient(
          _pinned.putIfAbsent(
            pin,
            () => _own(
              createPinnedHttpPackageClient(
                expectedFingerprint: pin,
                connectionTimeout: kInterconnectConnectTimeout,
              ),
            ),
          ),
        ),
      );
  http.Client _own(http.Client client) {
    late final _OwnedRemoteClient owned;
    owned = _OwnedRemoteClient(client, () => _clients.remove(owned));
    _clients.add(owned);
    return owned;
  }

  void cancelPending() {
    for (final http.Client client in List<http.Client>.from(_clients)) {
      client.close();
    }
    _clients.clear();
    _pinned.clear();
    _current = null;
  }

  int _sequence = 0;
  String requestId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
  Future<Map<String, dynamic>> call(
    String operation, [
    Map<String, dynamic> body = const <String, dynamic>{},
  ]) async {
    VideoRemoteError? rejection;
    final InterconnectPostOutcome response = await _transport.post(
      path: '/api/video-remote/$operation',
      body: body,
      timeout: const Duration(seconds: 35),
      onlyCandidate: peer,
      authErrorMessage: 'Video remote authentication rejected',
      onRejectedResponse: (int status, Map<String, dynamic>? json) {
        rejection = VideoRemoteError(
          (json?['error'] ?? json?['message'] ?? 'HTTP $status').toString(),
          statusCode: status,
        );
      },
    );
    if (response.json != null) return response.json!;
    if (rejection != null) throw rejection!;
    throw const VideoRemoteError('Paired video remote is unreachable');
  }

  Future<Map<String, dynamic>> snapshot() => call('snapshot');
  Future<Map<String, dynamic>> events(int revision) => call(
    'events',
    <String, dynamic>{'afterRevision': revision, 'waitMs': 25000},
  );
  Future<Map<String, dynamic>> disconnect() =>
      call('disconnect', <String, dynamic>{'requestId': requestId()});
}

class _BorrowedRemoteClient extends http.BaseClient {
  _BorrowedRemoteClient(this.inner);
  final http.Client inner;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      inner.send(request);
  @override
  void close() {}
}

class _OwnedRemoteClient extends http.BaseClient {
  _OwnedRemoteClient(this.inner, this.onClosed);
  final http.Client inner;
  final void Function() onClosed;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      inner.send(request);
  @override
  void close() {
    inner.close();
    onClosed();
  }
}
