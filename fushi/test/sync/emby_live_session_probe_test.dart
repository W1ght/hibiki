// 真 Emby 会话探针（BUG-2591）：用 Fushi 的真实客户端代码（JellyfinApi /
// JellyfinVideoClient）打一台真 Emby，逐步核对服务器眼里的会话状态。
//
// 默认跳过；跑法：
//   flutter test test/sync/emby_live_session_probe_test.dart --no-pub \
//     --dart-define=FUSHI_EMBY_URL=http://127.0.0.1:8096 \
//     --dart-define=FUSHI_EMBY_USER=fushi --dart-define=FUSHI_EMBY_PASS=fushi123
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo, RemoteVideoStreamUrls;
import 'package:http/http.dart' as http;

const String _serverUrl = String.fromEnvironment('FUSHI_EMBY_URL');
const String _username = String.fromEnvironment('FUSHI_EMBY_USER');
const String _password = String.fromEnvironment('FUSHI_EMBY_PASS');

/// 记录每个请求的方法 / 路径 / 状态码 / 响应体前 300 字，探针输出用。
class _LoggingClient extends http.BaseClient {
  _LoggingClient(this._inner);

  final http.Client _inner;
  final List<String> log = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final http.StreamedResponse res = await _inner.send(request);
    final List<int> bytes = await res.stream.toBytes();
    String body = utf8.decode(bytes, allowMalformed: true);
    if (body.length > 300) body = '${body.substring(0, 300)}…';
    final String path = request.url.path +
        (request.url.hasQuery ? '?${request.url.query}' : '');
    final String line =
        '${request.method} $path → ${res.statusCode} ${body.replaceAll('\n', ' ')}';
    log.add(line);
    // ignore: avoid_print
    print('[probe] $line');
    return http.StreamedResponse(
      http.ByteStream.fromBytes(bytes),
      res.statusCode,
      contentLength: bytes.length,
      request: request,
      headers: res.headers,
      reasonPhrase: res.reasonPhrase,
    );
  }
}

Future<Map<String, dynamic>> _getJson(
  http.Client client,
  String url,
  Map<String, String> headers,
) async {
  final http.Response res = await client.get(Uri.parse(url), headers: headers);
  return jsonDecode(res.body) as Map<String, dynamic>;
}

Future<List<dynamic>> _getJsonList(
  http.Client client,
  String url,
  Map<String, String> headers,
) async {
  final http.Response res = await client.get(Uri.parse(url), headers: headers);
  return jsonDecode(res.body) as List<dynamic>;
}

void main() {
  test(
    'real Emby: Start / Progress / pause / Stopped are visible in /Sessions',
    () async {
      final _LoggingClient client = _LoggingClient(http.Client());
      final String deviceId = 'probe-${DateTime.now().millisecondsSinceEpoch}';
      final JellyfinApi api = JellyfinApi(
        serverUrl: _serverUrl,
        deviceId: deviceId,
        client: client,
      );
      final JellyfinAuthResult auth =
          await api.authenticateByName(_username, _password);
      final JellyfinVideoClient videoClient =
          JellyfinVideoClient(api: api, userId: auth.userId);
      final Map<String, String> headers = <String, String>{
        'X-Emby-Token': auth.accessToken,
      };

      List<RemoteVideoInfo> videos = const <RemoteVideoInfo>[];
      for (int i = 0; i < 30 && videos.isEmpty; i++) {
        videos = await videoClient.listRemoteVideos();
        if (videos.isEmpty) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      expect(videos, isNotEmpty, reason: '库扫描后应有可播条目');
      final RemoteVideoInfo video = videos.first;
      // ignore: avoid_print
      print(
          '[probe] playing ${video.id} ${video.title} dur=${video.durationMs}');

      final RemoteVideoStreamUrls urls =
          await videoClient.remoteVideoStreamUrls(video.id);
      // ignore: avoid_print
      print(
          '[probe] streamUrl=${urls.streamUrl.replaceAll(RegExp('api_key=[^&]+'), 'api_key=***')}');

      await videoClient.startRemoteVideoPlayback(video.id, 0);
      await videoClient.putRemoteVideoPosition(
        video.id,
        15000,
        DateTime.now().millisecondsSinceEpoch,
      );

      Future<Map<String, dynamic>?> mySession() async {
        final List<dynamic> sessions = await _getJsonList(
          client,
          '$_serverUrl/emby/Sessions',
          headers,
        );
        for (final dynamic s in sessions) {
          final Map<String, dynamic> m = s as Map<String, dynamic>;
          if (m['DeviceId'] == deviceId) return m;
        }
        return null;
      }

      Map<String, dynamic>? session = await mySession();
      // ignore: avoid_print
      print(
          '[probe] after Start+Progress: session=${session == null ? 'NONE' : jsonEncode(<String, Object?>{
                  'Client': session['Client'],
                  'NowPlayingItem': (session['NowPlayingItem']
                      as Map<String, dynamic>?)?['Name'],
                  'PlayState': session['PlayState'],
                })}');
      expect(session, isNotNull, reason: '服务器应有本设备的会话');
      expect(session!['NowPlayingItem'], isNotNull,
          reason: 'Start 后服务器应知道本设备正在播');

      await videoClient.setRemoteVideoPlaybackPaused(
        video.id,
        16000,
        paused: true,
      );
      session = await mySession();
      // ignore: avoid_print
      print('[probe] after pause: PlayState=${session?['PlayState']}');
      expect((session?['PlayState'] as Map<String, dynamic>?)?['IsPaused'],
          isTrue);

      await videoClient.setRemoteVideoPlaybackPaused(
        video.id,
        16000,
        paused: false,
      );

      // 97% 处停止 → 服务器应判「看完」（MaxResumePct 默认 90）。
      final int stopAt = ((video.durationMs ?? 60000) * 0.97).round();
      await videoClient.stopRemoteVideoPlayback(video.id, stopAt);
      final Map<String, dynamic> item = await _getJson(
        client,
        '$_serverUrl/emby/Users/${auth.userId}/Items/${video.id}',
        headers,
      );
      // ignore: avoid_print
      print('[probe] after Stopped: UserData=${item['UserData']}');
      expect((item['UserData'] as Map<String, dynamic>)['Played'], isTrue,
          reason: 'Stopped 于 97% 处应标记已播放');
      session = await mySession();
      // ignore: avoid_print
      print(
          '[probe] after Stopped: NowPlayingItem=${session?['NowPlayingItem']}');
      expect(session?['NowPlayingItem'], isNull,
          reason: 'Stopped 后服务器不该再显示本设备在播');
    },
    skip: _serverUrl.isEmpty ? 'FUSHI_EMBY_URL 未设' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
