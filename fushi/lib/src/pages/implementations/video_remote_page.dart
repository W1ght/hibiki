import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/lookup_overlay_navigator.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/video/video_remote_control_layout.dart';
import 'package:fushi/src/models/preferences_repository.dart'
    show PreferencesRepository;
import 'package:fushi/src/pages/implementations/video_remote/video_remote_control_editor.dart'
    show showVideoRemoteControlEditor;
import 'package:fushi/src/pages/implementations/video_remote/video_remote_models.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_scaffold.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart'
    show shouldShowLookupDismissBarrier;
import 'package:fushi/src/pages/implementations/dictionary_popup_resource_source.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show DictionaryPopupWebViewState, MinePopupResult;
import 'package:fushi/src/sync/sync_backend.dart' show SyncAuthError;
import 'package:fushi/src/sync/video_remote_client.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/app_ui_scale.dart'
    show FushiAppUiScaleNeutralizer;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/lookup_audio_playback.dart'
    show playResolvedLookupAudio;
import 'package:fushi/src/utils/misc/lookup_dismiss_barrier.dart';
import 'package:fushi/src/utils/overlay_entry_lifecycle.dart';
import 'package:fushi_anki/fushi_anki.dart' show AnkiOpenWordOutcome;
import 'package:fushi_core/fushi_core.dart'
    show kStatSourceVideo, mimeTypeForFilePath;
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:http/http.dart' as http;

/// 手机字幕遥控器：字幕列表 + 收藏 + 在手机上查电脑的词典 / 制卡。
///
/// 查词与视频侧栏是**同一个**弹框（[DictionaryPageMixin] → `DictionaryPopupLayer`
/// → popup.js），嵌套查词 / 原地跳转 / 热槽都由 mixin 承担；本页只换三样东西：
/// 数据源（钉住的那台电脑，[searchPopupDictionary]）、词典资源（那台电脑的样式 /
/// 媒体 / 发音，[popupResourceSource]）、制卡（经遥控协议交给那台电脑的 Anki，
/// [onMineEntry]）。会打到手机本机 Anki / 数据库的入口一律禁用。
class VideoRemotePage extends ConsumerStatefulWidget {
  const VideoRemotePage({
    required this.repository,
    required this.peer,
    this.httpClient,
    super.key,
  });
  final SyncRepository repository;
  final FushiClientUrl peer;
  final http.Client? httpClient;
  @override
  ConsumerState<VideoRemotePage> createState() => VideoRemotePageState();
}

/// 本页的状态与行为：协议、会话与查词在这里；画面是 `video_remote/` 下的
/// [VideoRemoteScaffold]（纯展示），build 把快照投影成它的不可变数据、把它的
/// 回调接回下面这些命令。跟随当前句 / 页签 / 收藏搜索与多选归脚手架自己管。
///
/// * 字幕：[rows]（主副轨按时间交错）/ [currentRowIndex] / [isPrimaryRow] /
///   [previousRowIndex] / [nextRowIndex]。
/// * 播放：[available] / [playing] / [title] / [playbackState] / [positionMs] /
///   [play] / [pause] / [togglePlay] / [seekTo] / [seekToRow] / [previousRow] /
///   [nextRow]。
/// * 收藏：[favorites] / [isRowFavorited] / [toggleRowFavorite] /
///   [favoritesAllVideos] / [setFavoritesAllVideos] / [removeFavorites] /
///   [openFavorite]。
/// * 查词：[openLookup]（行 + 被点字的 grapheme 下标 + 可选锚点）/ [closeLookup] /
///   [lookupOpen]。
/// * 连接：[errorText] / [reconnect]。
class VideoRemotePageState extends ConsumerState<VideoRemotePage>
    with WidgetsBindingObserver, DictionaryPageMixin {
  late final VideoRemoteClient _client = VideoRemoteClient(
    repository: widget.repository,
    peer: widget.peer,
    httpClient: widget.httpClient,
  );
  late http.Client _dictionaryHttp = widget.httpClient ?? http.Client();
  late FushiRemoteLookupClient _lookup = _createLookup();
  Map<String, dynamic> _state = <String, dynamic>{};
  List<Map<String, dynamic>> _cues = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _favorites = <Map<String, dynamic>>[];
  final Set<String> _starred = <String>{};
  bool _foreground = true, _polling = false, _all = false;
  bool _favoritesLoading = false;
  int _active = -1, _revision = 0, _generation = 0;
  VideoRemoteTab _tab = VideoRemoteTab.transcript;

  /// 脚手架行号 → [_cues] 里的主轨行（每次 build 由 [_projectTranscript] 重算）。
  List<Map<String, dynamic>> _lineRows = <Map<String, dynamic>>[];

  /// 最近一次按下的全局位置：查词弹框贴着它落下。
  Offset? _lastPointer;

  /// 控制卡进度条的读口（本地按速度推算播放头，见 [_position]）。
  late final _RemoteClock _playbackClock = _RemoteClock(this);
  int _favoriteGeneration = 0;
  String _error = '';
  Timer? _clock;
  Timer? _retry;
  int _retryAttempt = 0;
  Future<void> _disconnecting = Future<void>.value();
  Map<String, dynamic>? _favoriteTarget;
  Completer<Map<String, dynamic>>? _favoriteCueWaiter;
  String? _cueSessionId;
  int? _cueSubtitleVersion;
  String? _cueLoadKey;
  Future<List<Map<String, dynamic>>>? _cueLoad;
  DateTime _anchor = DateTime.now();

  // ── 查词会话 ───────────────────────────────────────────────────────────
  /// 弹框栈。手机端查词弹框与视频侧栏同一套（见类注释）。
  final DictionaryPopupController _popup = DictionaryPopupController(
    lowMemory: false,
    onLookupStackDepthChanged: recordLookupStackDepth,
  );

  /// 电脑端这次查词的上下文（`lookupBegin` 回的 contextId）：整个弹框栈（含嵌套
  /// 查词）共用一个；栈全部关掉才 `lookupEnd`（电脑只恢复自己造成的暂停）。
  String? _lookupContextId;

  /// 上下文绑定的行与字幕会话：点了别的行或字幕会话变了就不能再复用它。
  String? _lookupCueId, _lookupSessionId;
  int? _lookupSubtitleVersion;

  /// 每次 [openLookup] / 关栈自增：在途的 `lookupBegin` 回来时据此判断自己是否已过期。
  int _lookupSerial = 0;

  /// 弹框来自电脑：样式 / 媒体 / 发音都问那台电脑（见 [popupResourceSource]）。
  late final RemoteDictionaryPopupResources _resources =
      RemoteDictionaryPopupResources(
        fetchStyles: () => _lookup.dictionaryStyles(),
        fetchMedia: (String dictionary, String path) async {
          final RemoteDictionaryMedia? media = await _lookup.dictionaryMedia(
            dictionary: dictionary,
            path: path,
          );
          return media == null
              ? null
              : DictionaryPopupMedia(
                  bytes: media.bytes,
                  contentType: media.contentType,
                );
        },
        fetchWordAudio: (String expression, String reading) =>
            _lookup.lookupAudioUrl(expression: expression, reading: reading),
      );

  /// 弹框挂在根 Overlay（盖过 AppBar / 底栏，与视频页、首页词典同范式）。
  OverlayEntry? _popupOverlayEntry;
  bool _overlayInert = false;

  /// 只在第一次查词时读：没查过词的页面不该为了字幕列表去初始化 AppModel 依赖。
  late final AppModel _appModel = ref.read(appProvider);

  @override
  AppModel get mixinAppModel => _appModel;

  @override
  ThemeData get mixinTheme => Theme.of(context);

  @override
  String get dictionarySourceType => kStatSourceVideo;

  @override
  DictionaryPopupResourceSource? get popupResourceSource => _resources;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clock = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _highlight(),
    );
    unawaited(_start());
  }

  /// The dictionary hop is bound to the same host, credential and pin.
  FushiRemoteLookupClient _createLookup() => FushiRemoteLookupClient(
    repo: widget.repository,
    onlyCandidate: widget.peer,
    httpClient: _client.guardPlaintext(_dictionaryHttp),
    pinnedClientFactory: _client.pinnedClientFactory,
  );

  /// Only `paused` / `detached` release the remote: `inactive` (iOS control
  /// centre, incoming-call banner, app switcher peek) and `hidden` are
  /// transitional and must not drop the lease or resume the computer. One
  /// background period sends exactly one disconnect; `resumed` reconnects.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_foreground) return;
        _foreground = true;
        _generation++;
        _dictionaryHttp = widget.httpClient ?? http.Client();
        _lookup = _createLookup();
        _clock?.cancel();
        _clock = Timer.periodic(
          const Duration(milliseconds: 250),
          (_) => _highlight(),
        );
        unawaited(_start());
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (!_foreground) return;
        _foreground = false;
        _generation++;
        _clock?.cancel();
        _retry?.cancel();
        _cancelFavoriteWait();
        final String? lookupContext = _dropLookupSession();
        _dictionaryHttp.close();
        _client.cancelPending();
        _disconnecting = _disconnecting.then(
          (_) => _disconnect(lookupContextId: lookupContext),
        );
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  @override
  void dispose() {
    _foreground = false;
    _overlayInert = true;
    _cancelFavoriteWait();
    // 先摘根 Overlay 浮层：entry 一旦移除就不会再用失效的 State 重建。
    final OverlayEntry? entry = _popupOverlayEntry;
    if (entry != null) {
      removeAndDisposeOwnedOverlayEntry(entry);
      _popupOverlayEntry = null;
    }
    final String? lookupContext = _lookupContextId;
    _lookupContextId = null;
    _lookupSerial++;
    _popup.dispose();
    _dictionaryHttp.close();
    _client.cancelPending();
    _generation++;
    _clock?.cancel();
    _retry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_disconnect(lookupContextId: lookupContext));
    super.dispose();
  }

  @override
  void deactivate() {
    _overlayInert = true;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _overlayInert = false;
  }

  /// [lookupContextId] 非空时先结束这次查词（电脑恢复本次查词造成的暂停），再释放
  /// 控制权。用一次性 client：页面自己的 client 此刻已 [VideoRemoteClient.cancelPending]。
  Future<void> _disconnect({String? lookupContextId}) async {
    final VideoRemoteClient cleanup = VideoRemoteClient(
      repository: widget.repository,
      peer: widget.peer,
      httpClient: widget.httpClient,
    );
    try {
      if (lookupContextId != null) {
        try {
          await cleanup.call('lookupEnd', <String, dynamic>{
            'contextId': lookupContextId,
            'requestId': cleanup.requestId(),
          });
        } catch (e, stack) {
          // 释放控制权仍要继续：断开后电脑按租约清掉这次查词上下文。
          ErrorLogService.instance.log('VideoRemote.lookupEnd', e, stack);
        }
      }
      await cleanup.disconnect();
    } catch (_) {
      // A disconnected device releases its lookup ownership through the host lease.
    } finally {
      cleanup.cancelPending();
    }
  }

  Future<void> _guard(Future<void> Function() action) async {
    final int generation = _generation;
    try {
      if (mounted) setState(() => _error = '');
      await action();
    } catch (e) {
      if (mounted && _foreground && generation == _generation) {
        final String text = videoRemoteErrorText(e);
        if (text.isNotEmpty) setState(() => _error = text);
      }
    }
  }

  Future<void> _start() async {
    if (_polling || !_foreground || !mounted) return;
    _polling = true;
    final int generation = _generation;
    Object? failure;
    try {
      // A background disconnect must finish before reacquiring this peer's lease.
      await _disconnecting;
      if (!mounted || !_foreground || generation != _generation) return;
      _revision = 0;
      final Map<String, dynamic> initial = await _client.snapshot();
      if (!mounted || !_foreground || generation != _generation) return;
      await _apply(initial);
      _retryAttempt = 0;
      while (mounted && _foreground && generation == _generation) {
        final Map<String, dynamic> response = await _client.events(_revision);
        if (!mounted || !_foreground || generation != _generation) break;
        if (response['reset'] == true) {
          final Map<String, dynamic> reset = await _client.snapshot();
          if (!mounted || !_foreground || generation != _generation) break;
          await _apply(reset);
        } else {
          for (final dynamic event
              in response['events'] as List? ?? <dynamic>[]) {
            if (event['type'] == 'state') {
              if ((event['revision'] as num).toInt() >= _revision) {
                await _apply(<String, dynamic>{
                  ...Map<String, dynamic>.from(event['payload'] as Map),
                  'revision': event['revision'],
                });
              }
            }
          }
        }
        _revision = (response['revision'] as num?)?.toInt() ?? _revision;
      }
    } catch (e, stackTrace) {
      failure = e;
      if (mounted && _foreground && generation == _generation) {
        await _guard(() async => Error.throwWithStackTrace(e, stackTrace));
      }
    } finally {
      _polling = false;
      if (mounted && _foreground && generation != _generation) {
        unawaited(_start());
      }
    }
    if (mounted && _foreground && generation != _generation) {
      return;
    } else if (mounted &&
        _foreground &&
        failure is VideoRemoteError &&
        (failure.statusCode == null ||
            <String>{
              'session_changed',
              'subtitles_changed',
              'controller_lease_lost',
            }.contains(failure.message))) {
      _retry?.cancel();
      _retry = Timer(
        Duration(seconds: 2 << (_retryAttempt++).clamp(0, 2)),
        () => unawaited(_start()),
      );
    }
  }

  Map<String, dynamic> get _session => <String, dynamic>{
    'sessionId': _state['sessionId'],
    'subtitleVersion': _state['subtitleVersion'],
  };
  Future<void> _apply(Map<String, dynamic> value) async {
    final int generation = _generation;
    final int revision = (value['revision'] as num?)?.toInt() ?? _revision;
    if (!mounted || !_foreground || revision < _revision) return;
    final bool changed =
        value['sessionId'] != _cueSessionId ||
        value['subtitleVersion'] != _cueSubtitleVersion;
    final bool favoritesChanged =
        value['favoriteVersion'] != _state['favoriteVersion'];
    setState(() {
      _state = value;
      if (value['error'] != null) {
        _error = videoRemoteErrorText(
          VideoRemoteError(value['error'].toString()),
        );
      }
      _anchor = DateTime.now();
      _revision = (value['revision'] as num?)?.toInt() ?? _revision;
      if (changed) {
        _cues = <Map<String, dynamic>>[];
        _starred.clear();
        _active = -1;
      }
    });
    if (changed) {
      final Map<String, dynamic> session = Map<String, dynamic>.from(_session);
      final String key =
          '$generation|${session['sessionId']}|${session['subtitleVersion']}';
      if (_cueLoadKey != key) {
        _cueLoadKey = key;
        _cueLoad = _loadCues(session, value, generation);
      }
      late final List<Map<String, dynamic>> cues;
      try {
        cues = await _cueLoad!;
      } finally {
        if (_cueLoadKey == key) {
          _cueLoadKey = null;
          _cueLoad = null;
        }
      }
      if (mounted &&
          _foreground &&
          generation == _generation &&
          _state['sessionId'] == session['sessionId'] &&
          _state['subtitleVersion'] == session['subtitleVersion']) {
        setState(() {
          _cues = cues;
          _cueSessionId = session['sessionId'] as String?;
          _cueSubtitleVersion = (session['subtitleVersion'] as num?)?.toInt();
          _starred
            ..clear()
            ..addAll(
              cues
                  .where((Map<String, dynamic> c) => c['favorited'] == true)
                  .map((Map<String, dynamic> c) => c['id'].toString()),
            );
          _active = -1;
        });
      }
    }
    if (favoritesChanged || changed) await _loadFavorites();
    _highlight();
    _checkFavoriteReady();
  }

  Future<List<Map<String, dynamic>>> _loadCues(
    Map<String, dynamic> session,
    Map<String, dynamic> value,
    int generation,
  ) async {
    if (value['available'] != true) return <Map<String, dynamic>>[];
    // Chunks are cached per (sessionId, subtitleVersion) inside the client, so
    // a reconnect or an interrupted load only fetches what is still missing.
    final List<Map<String, dynamic>>? cues = await _client.subtitles(
      sessionId: session['sessionId'].toString(),
      subtitleVersion: (session['subtitleVersion'] as num?)?.toInt() ?? 0,
      expectedTotal: (value['cueCount'] as num?)?.toInt() ?? 0,
      active: () => mounted && _foreground && generation == _generation,
    );
    return cues ?? <Map<String, dynamic>>[];
  }

  void _cancelFavoriteWait() {
    final Completer<Map<String, dynamic>>? waiter = _favoriteCueWaiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(const VideoRemoteError('lookup_cancelled'));
    }
  }

  /// Dual-subtitle lists interleave both tracks by time; the current line and
  /// previous/next navigation follow the primary track only, so a secondary
  /// line at the same instant never steals the highlight or a skip.
  static bool _isPrimary(Map<String, dynamic> cue) =>
      cue['track'] != 'secondary';

  static int _cueStart(Map<String, dynamic> cue) =>
      (cue['startMs'] as num).toInt() +
      ((cue['delayMs'] as num?)?.toInt() ?? 0);

  static int _cueEnd(Map<String, dynamic> cue) =>
      (cue['endMs'] as num).toInt() + ((cue['delayMs'] as num?)?.toInt() ?? 0);

  double get _position {
    final num base = _state['positionMs'] as num? ?? 0;
    final double speed = (_state['speed'] as num?)?.toDouble() ?? 1;
    return base.toDouble() +
        (_state['playing'] == true
            ? DateTime.now().difference(_anchor).inMilliseconds * speed
            : 0);
  }

  void _highlight() {
    if (!mounted || !_foreground || _cues.isEmpty) return;
    final double position = _position;
    final int index = _cues.indexWhere(
      (Map<String, dynamic> c) =>
          _isPrimary(c) && position >= _cueStart(c) && position < _cueEnd(c),
    );
    if (index == _active) return;
    setState(() => _active = index);
  }

  /// The neighbouring primary line in [direction] (-1 / 1) from the current
  /// line, or from the playhead when it sits between lines; -1 when none.
  int _primaryNeighbor(int direction) {
    if (_active >= 0) {
      for (
        int i = _active + direction;
        i >= 0 && i < _cues.length;
        i += direction
      ) {
        if (_isPrimary(_cues[i])) return i;
      }
      return -1;
    }
    final double position = _position;
    int found = -1;
    for (int i = 0; i < _cues.length; i++) {
      final Map<String, dynamic> cue = _cues[i];
      if (!_isPrimary(cue)) continue;
      if (direction > 0 && _cueStart(cue) > position) return i;
      if (direction < 0 && _cueEnd(cue) <= position) found = i;
    }
    return found;
  }

  Future<void> _command(String action, {String? cueId, int? positionMs}) =>
      _guard(() async {
        await _client.call('command', <String, dynamic>{
          ..._session,
          'requestId': _client.requestId(),
          'action': action,
          if (cueId != null) 'cueId': cueId,
          if (positionMs != null) 'positionMs': positionMs,
        });
        await _apply(await _client.snapshot());
      });
  Future<void> _loadFavorites() async {
    final int lifecycle = _generation;
    final int generation = ++_favoriteGeneration;
    if (mounted) setState(() => _favoritesLoading = true);
    try {
      await _fetchFavorites(lifecycle, generation);
    } finally {
      if (mounted && generation == _favoriteGeneration) {
        setState(() => _favoritesLoading = false);
      }
    }
  }

  Future<void> _fetchFavorites(int lifecycle, int generation) async {
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    int total = 0;
    do {
      final Map<String, dynamic> result = await _client.call(
        'favorites',
        <String, dynamic>{
          // 搜索在收藏组件里本地做（与媒体搜索同一归一化口径）。
          'query': '',
          'currentOnly': !_all,
          'sessionId': _state['sessionId'],
          'offset': items.length,
          'limit': 200,
        },
      );
      if (generation != _favoriteGeneration ||
          !mounted ||
          !_foreground ||
          lifecycle != _generation) {
        return;
      }
      final List<dynamic> page = result['items'] as List? ?? <dynamic>[];
      items.addAll(
        page.map((dynamic e) => Map<String, dynamic>.from(e as Map)),
      );
      total = (result['total'] as num?)?.toInt() ?? items.length;
      if (page.isEmpty) break;
    } while (items.length < total);
    final List<Map<String, dynamic>> current = <Map<String, dynamic>>[];
    if (_all) {
      int count = 0;
      do {
        final Map<String, dynamic> page = await _client
            .call('favorites', <String, dynamic>{
              'query': '',
              'currentOnly': true,
              'sessionId': _state['sessionId'],
              'offset': current.length,
              'limit': 200,
            });
        if (generation != _favoriteGeneration ||
            !mounted ||
            !_foreground ||
            lifecycle != _generation) {
          return;
        }
        final List<dynamic> entries = page['items'] as List? ?? <dynamic>[];
        current.addAll(
          entries.map((dynamic e) => Map<String, dynamic>.from(e as Map)),
        );
        count = (page['total'] as num?)?.toInt() ?? current.length;
        if (entries.isEmpty) break;
      } while (current.length < count);
    } else {
      current.addAll(items);
    }
    if (mounted && generation == _favoriteGeneration) {
      setState(() {
        _favorites = items;
        {
          _starred.clear();
          for (final Map<String, dynamic> cue in _cues) {
            if (current.any(
              (Map<String, dynamic> item) =>
                  item['bookUid'] == _state['identity'] &&
                  item['text'] == cue['text'] &&
                  item['startMs'] == cue['startMs'],
            )) {
              _starred.add(cue['id'].toString());
            }
          }
        }
      });
    }
  }

  Future<void> _star(Map<String, dynamic> cue) => _guard(() async {
    final String id = cue['id'].toString();
    final bool value = !_starred.contains(id);
    await _client.call('favoriteSet', <String, dynamic>{
      ..._session,
      'cueId': id,
      'favorited': value,
      'requestId': _client.requestId(),
    });
    if (mounted) {
      setState(() {
        if (value) {
          _starred.add(id);
        } else {
          _starred.remove(id);
        }
      });
    }
    await _loadFavorites();
  });
  // ── 对外接口（`video_remote/` 展示组件只经这里读状态、发命令） ─────────────

  /// 字幕行（主副轨按时间交错）。每行 `{id, text, startMs, endMs, delayMs, track}`。
  List<Map<String, dynamic>> get rows =>
      UnmodifiableListView<Map<String, dynamic>>(_cues);

  /// 当前句（只认主轨）在 [rows] 里的下标；播放头落在两句之间时为 -1。
  int get currentRowIndex => _active;

  /// 副轨行不参与当前句与上一句 / 下一句。
  bool isPrimaryRow(Map<String, dynamic> row) => _isPrimary(row);

  /// 上一句 / 下一句主轨行的下标，没有为 -1。
  int get previousRowIndex => _primaryNeighbor(-1);
  int get nextRowIndex => _primaryNeighbor(1);

  /// 电脑上报的播放快照（`available` / `playing` / `positionMs` / `title` …）。
  Map<String, dynamic> get playbackState =>
      UnmodifiableMapView<String, dynamic>(_state);
  bool get available => _state['available'] == true;
  bool get playing => _state['playing'] == true;
  String? get title => _state['title']?.toString();

  /// 本地按速度推算的当前播放位置（毫秒）。
  double get positionMs => _position;

  Future<void> play() => _command('play');
  Future<void> pause() => _command('pause');
  Future<void> togglePlay() => _command(playing ? 'pause' : 'play');

  /// 跳到 [position]（拖进度条 / ±10 秒）。
  Future<void> seekTo(Duration position) =>
      _command('seek', positionMs: position.inMilliseconds.clamp(0, 1 << 30));

  /// 跳到 [row] 句首并播放。
  Future<void> seekToRow(Map<String, dynamic> row) =>
      _command('seekCue', cueId: row['id'].toString());

  Future<void> previousRow() {
    final int index = previousRowIndex;
    return index < 0 ? Future<void>.value() : seekToRow(_cues[index]);
  }

  Future<void> nextRow() {
    final int index = nextRowIndex;
    return index < 0 ? Future<void>.value() : seekToRow(_cues[index]);
  }

  /// 收藏列表（当前视频或全部视频，见 [favoritesAllVideos]），已按 [favoritesQuery] 过滤。
  List<Map<String, dynamic>> get favorites =>
      UnmodifiableListView<Map<String, dynamic>>(_favorites);
  bool isRowFavorited(Map<String, dynamic> row) =>
      _starred.contains(row['id'].toString());
  Future<void> toggleRowFavorite(Map<String, dynamic> row) => _star(row);

  bool get favoritesAllVideos => _all;
  Future<void> setFavoritesAllVideos(bool all) {
    setState(() => _all = all);
    return _guard(_loadFavorites);
  }

  /// 批量取消收藏（每批最多 200 条）。
  Future<void> removeFavorites(Set<String> ids) => _guard(() async {
    final List<String> all = ids.toList();
    for (int offset = 0; offset < all.length; offset += 200) {
      final List<String> batch = all.sublist(
        offset,
        (offset + 200).clamp(0, all.length),
      );
      await _client.call('favoritesRemove', <String, dynamic>{
        'ids': batch,
        'requestId': _client.requestId(),
      });
    }
    await _loadFavorites();
  });

  /// 在电脑上打开收藏（跨视频先确认）；[lookup] 为真时打开后直接查这句。
  Future<void> openFavorite(
    Map<String, dynamic> favorite, {
    bool lookup = false,
  }) => _openFavorite(favorite, lookup: lookup);

  /// 当前要给用户看的错误（已本地化，空串 = 无）。
  String get errorText => _error;

  /// 手动重连（重新取快照与事件流）。
  Future<void> reconnect() => _start();

  // ── 查词 ───────────────────────────────────────────────────────────────

  /// 弹框栈里是否有东西在显示（含搜索期占位）。
  bool get lookupOpen => _popup.hasVisiblePopup || _popup.isSearchingUi;

  /// 查词入口：在 [row] 的第 [charOffset] 个 grapheme 处查词（行点击传 0 = 从句首
  /// 最长匹配）。[anchor] 是被点文字的全局矩形，弹框贴着它；缺省贴整行。
  ///
  /// 会话规则：弹框栈与电脑端的一次查词上下文一一对应。第一次点字 `lookupBegin`
  /// （电脑暂停）；弹框开着时再点同一行沿用上下文；点了别的行先 `lookupEnd` 旧的再
  /// `lookupBegin` 新的；整个栈关掉（[_popAt] 收口）才 `lookupEnd`。
  Future<void> openLookup(
    Map<String, dynamic> row,
    int charOffset, {
    Rect? anchor,
  }) => _guard(() async {
    if (!_foreground || !mounted) return;
    final String text = row['text'].toString();
    final String span = subtitleTranscriptLookupSpan(text, charOffset).term;
    final String term = span.isNotEmpty ? span : text.trim();
    if (term.isEmpty) return;
    final int serial = ++_lookupSerial;
    final int generation = _generation;
    final String cueId = row['id'].toString();
    final Rect selection = anchor == null || anchor == Rect.zero
        ? _fallbackAnchor()
        : anchor;
    if (!_lookupBoundTo(cueId)) {
      final String? previous = _lookupContextId;
      _clearLookupContext();
      if (previous != null) await _sendLookupEnd(previous);
      final Map<String, dynamic> begun = await _client.call(
        'lookupBegin',
        <String, dynamic>{
          ..._session,
          'cueId': cueId,
          'requestId': _client.requestId(),
        },
      );
      final String contextId = begun['contextId'].toString();
      if (serial != _lookupSerial ||
          !mounted ||
          !_foreground ||
          generation != _generation) {
        // 等电脑回话期间用户已关栈 / 换了行 / 切到后台：这次上下文作废。后台时
        // 断开流程会结束它，这里只处理前台的情形。
        if (mounted && _foreground && generation == _generation) {
          await _sendLookupEnd(contextId);
        }
        return;
      }
      _lookupContextId = contextId;
      _lookupCueId = cueId;
      _lookupSessionId = _state['sessionId']?.toString();
      _lookupSubtitleVersion = (_state['subtitleVersion'] as num?)?.toInt();
    }
    _ensureWarmPopup();
    await pushNestedPopup(
      query: term,
      selectionRect: selection,
      controller: _popup,
      replaceStack: true,
      // 顶层查词原地复用常驻热槽 WebView（BUG-094）；低内存无热槽时清栈重建。
      reuseWarmSlot: true,
      autoRead: true,
    );
    // 搜索期间用户可能已把栈关掉（那时上下文已结束）；这里只补「查完发现栈已空」。
    _endLookupIfClosed();
  });

  /// 关掉整个弹框栈（返回键 / 外部调用）。电脑端上下文随之结束。
  void closeLookup() {
    if (_popup.entries.isEmpty && _lookupContextId == null) return;
    _popAt(0);
  }

  /// 当前上下文是否就是 [cueId] 这一行、且字幕会话没变——是才能复用。
  bool _lookupBoundTo(String cueId) =>
      _lookupContextId != null &&
      _lookupCueId == cueId &&
      _lookupSessionId == _state['sessionId']?.toString() &&
      _lookupSubtitleVersion == (_state['subtitleVersion'] as num?)?.toInt();

  void _clearLookupContext() {
    _lookupContextId = null;
    _lookupCueId = null;
    _lookupSessionId = null;
    _lookupSubtitleVersion = null;
  }

  Future<void> _sendLookupEnd(String contextId) async {
    await _client.call('lookupEnd', <String, dynamic>{
      'contextId': contextId,
      'requestId': _client.requestId(),
    });
  }

  /// 弹框栈关闭的**唯一**收口：barrier 点外面 / 横滑、X、返回键、[closeLookup]
  /// 都走这里。关的只是嵌套的一层（栈里还有可见层）或还在搜索时不结束上下文。
  void _popAt(int index) {
    if (index >= 0) popNestedPopupAt(index, _popup);
    _endLookupIfClosed();
  }

  void _endLookupIfClosed() {
    if (!mounted || _popup.hasVisiblePopup || _popup.isSearchingUi) return;
    final String? contextId = _lookupContextId;
    if (contextId == null) return;
    _lookupSerial++;
    _clearLookupContext();
    unawaited(_guard(() => _sendLookupEnd(contextId)));
  }

  /// 后台：收起弹框栈并交出要结束的上下文（由断开流程用一次性 client 发
  /// `lookupEnd`，见 [_disconnect]）。
  String? _dropLookupSession() {
    final String? contextId = _lookupContextId;
    _lookupSerial++;
    _clearLookupContext();
    if (mounted && _popup.entries.isNotEmpty) {
      setState(() => _popup.dismissAt(0));
    }
    return contextId;
  }

  /// 常驻热槽（BUG-094）：第一次查词时才 seed——那时 AppModel 一定已初始化。
  void _ensureWarmPopup() {
    _popup.lowMemory = mixinAppModel.lowMemoryMode;
    _popup.seedWarmSlot();
  }

  /// 没有按下点（键盘查词）时：贴在字幕列表当前句所在的高度（横屏在右栏）。
  Rect _fallbackAnchor() {
    final Size screen = MediaQuery.sizeOf(context);
    final double x = screen.width > screen.height
        ? screen.width * 0.68
        : screen.width / 2;
    return Rect.fromCenter(
      center: Offset(x, screen.height * 0.42),
      width: 24,
      height: 24,
    );
  }

  void _reportLookupError(Object error) {
    if (!mounted || !_foreground) return;
    final String text = videoRemoteErrorText(error);
    if (text.isNotEmpty) setState(() => _error = text);
  }

  // ── DictionaryPageMixin 注入点：数据源 / 发音 / 制卡都去钉住的那台电脑 ─────

  @override
  Future<DictionarySearchResult> searchPopupDictionary({
    required String term,
    required int maximumTerms,
  }) async {
    final DictionarySearchResult? found;
    try {
      found = await _lookup.searchDictionary(
        term: term,
        wildcards: true,
        maximumTerms: maximumTerms,
      );
    } catch (e) {
      // 电脑不可达 / 配对被拒：横幅报原因，弹框按「没查到」收尾（不留半截搜索态）。
      _reportLookupError(e);
      return DictionarySearchResult(searchTerm: term);
    }
    final DictionarySearchResult result =
        found ?? DictionarySearchResult(searchTerm: term);
    try {
      // 渲染前备好那台电脑的词典样式；缺了只是难看，不挡结果。
      await _resources.prefetchStyles(result);
    } catch (e, stack) {
      ErrorLogService.instance.log('VideoRemote.dictionaryStyles', e, stack);
    }
    return result;
  }

  @override
  Future<bool> playPopupWordAudio(
    String expression,
    String reading,
    DictionaryPopupWebViewState? popupState,
  ) async {
    final String? ref;
    try {
      ref = await _resources.wordAudioRef(expression, reading);
    } catch (e, stack) {
      ErrorLogService.instance.log('VideoRemote.wordAudio', e, stack);
      return false;
    }
    return playResolvedLookupAudio(
      ref,
      label: expression,
      playInWebView: popupState?.playWordAudioUrl,
    );
  }

  /// 制卡交给电脑：用电脑本地的 Anki 配置，素材从电脑正在播的视频按本次查词绑定的
  /// 字幕句抽取。网络失败（没拿到任何响应）时才按 requestId 回查任务——电脑明确
  /// 拒绝（lookup_expired / mining_busy …）就是结局，不能被 task_missing 盖掉。
  @override
  Future<MinePopupResult> onMineEntry(Map<String, String> fields) async {
    final String? contextId = _lookupContextId;
    final int generation = _generation;
    if (contextId == null) {
      _showMineFailure(const VideoRemoteError('lookup_expired'));
      return const MinePopupResult();
    }
    FushiToast.showMine(
      msg: t.card_mining_pending,
      status: MineToastStatus.pending,
    );
    try {
      final Map<String, dynamic> task = await _runRemoteMine(
        contextId,
        await _portableMineFields(fields),
        generation,
      );
      return _mineResult(task);
    } catch (e) {
      _showMineFailure(e);
      return const MinePopupResult();
    }
  }

  Future<Map<String, dynamic>> _runRemoteMine(
    String contextId,
    Map<String, String> fields,
    int generation,
  ) async {
    final String requestId = _client.requestId();
    final String sentence = fields['sentence'] ?? '';
    Map<String, dynamic> task;
    try {
      task = await _client.call('mine', <String, dynamic>{
        'contextId': contextId,
        'requestId': requestId,
        'fields': <String, dynamic>{
          'rawFields': fields,
          // 空句子不发：电脑端用本次查词绑定的字幕句。
          if (sentence.isNotEmpty) 'sentence': sentence,
        },
      });
    } on VideoRemoteError catch (e) {
      if (e.statusCode != null) rethrow;
      task = await _client.call('mineStatus', <String, dynamic>{
        'requestId': requestId,
      });
    }
    while (task['status'] == 'queued' || task['status'] == 'running') {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted || !_foreground || generation != _generation) {
        throw const VideoRemoteError('lookup_cancelled');
      }
      task = await _client.call('mineStatus', <String, dynamic>{
        'taskId': task['taskId'],
      });
    }
    return task;
  }

  MinePopupResult _mineResult(Map<String, dynamic> task) {
    if (task['status'] == 'succeeded') {
      FushiToast.showMine(
        msg: t.video_remote_mined,
        status: MineToastStatus.added,
      );
      // 卡已在电脑的 Anki 里，但手机查不了那边的重（查重入口已禁用）：按「已收下」
      // 画 ✓，不让弹窗回查本机 Anki 再把按钮翻回「+」。
      return const MinePopupResult.queued();
    }
    final Object? result = task['result'];
    if (result is Map && result['duplicate'] == true) {
      FushiToast.showMine(
        msg: t.card_duplicate,
        status: MineToastStatus.duplicate,
      );
      return const MinePopupResult(duplicate: true);
    }
    _showMineFailure(
      VideoRemoteError((task['error'] ?? 'mining_failed').toString()),
    );
    return const MinePopupResult();
  }

  void _showMineFailure(Object error) {
    final String text = videoRemoteErrorText(error);
    if (text.isEmpty) return;
    FushiToast.showMine(msg: text, status: MineToastStatus.failed);
  }

  /// 弹窗给的单词音频引用若是手机本地文件（钉扎 HTTPS 下电脑发音被物化到本机缓存），
  /// 电脑打不开它：内联成 `data:` URI 带过去；超过上限或已不存在就不带音频。
  Future<Map<String, String>> _portableMineFields(
    Map<String, String> fields,
  ) async {
    final String audio = fields['audio'] ?? '';
    if (audio.isEmpty ||
        audio.startsWith('data:') ||
        audio.startsWith('http://') ||
        audio.startsWith('https://')) {
      return fields;
    }
    final String path = audio.startsWith('file://')
        ? Uri.parse(audio).toFilePath()
        : audio;
    final File file = File(path);
    if (!await file.exists() ||
        await file.length() > _kMaxInlineWordAudioBytes) {
      return <String, String>{...fields, 'audio': ''};
    }
    final String mime = mimeTypeForFilePath(path, fallback: 'audio/mpeg');
    return <String, String>{
      ...fields,
      'audio': 'data:$mime;base64,${base64Encode(await file.readAsBytes())}',
    };
  }

  static const int _kMaxInlineWordAudioBytes = 4 * 1024 * 1024;

  // 以下入口默认打到**手机本机**的 Anki / 收藏库，而卡与收藏都在电脑上：一律禁用，
  // 弹框随之退回「+ / ✓」两态。词收藏没有遥控协议（遥控只有按字幕句收藏）。

  @override
  Future<bool> checkDuplicate(String expression, String reading) async => false;

  @override
  Future<int?> findOverwriteTargetNoteId(
    String expression,
    String reading,
  ) async => null;

  @override
  Future<MinePopupResult> onUpdateEntry(
    int noteId,
    Map<String, String> fields,
  ) async => const MinePopupResult();

  @override
  Future<MinePopupResult> onMinedCardAction(Map<String, String> fields) async =>
      const MinePopupResult();

  @override
  Future<AnkiOpenWordOutcome> onOpenInAnki(
    String expression,
    String reading,
  ) async => AnkiOpenWordOutcome.failed;

  @override
  Future<bool> onFavoriteEntry(Map<String, String> fields) async => false;

  @override
  Future<bool> onFavoriteCheck(String expression, String reading) async =>
      false;

  // ── 根 Overlay 浮层 ────────────────────────────────────────────────────

  void _syncPopupOverlay() {
    if (!mounted) return;
    if (_popup.entries.isEmpty) {
      final OverlayEntry? entry = _popupOverlayEntry;
      if (entry != null) {
        removeAndDisposeOwnedOverlayEntry(entry);
        _popupOverlayEntry = null;
      }
      return;
    }
    final OverlayEntry? existing = _popupOverlayEntry;
    if (existing != null) {
      if (existing.mounted) existing.markNeedsBuild();
      return;
    }
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(builder: _buildPopupOverlay);
    _popupOverlayEntry = entry;
    overlay.insert(entry);
  }

  /// 浮层子树：dismiss barrier + 搜索期占位 + 各层弹框 + 停驻层。每个子项都接了
  /// 对话框隐藏计数（守卫 `lookup_overlay_dialog_gate_guard_test.dart`）。
  Widget _buildPopupOverlay(BuildContext overlayContext) {
    if (!mounted || _overlayInert) return const SizedBox.shrink();
    return LookupOverlayNavigator(
      child: FushiAppUiScaleNeutralizer(
        child: Theme(
          data:
              mixinAppModel.overrideDictionaryTheme ?? Theme.of(overlayContext),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              if (!mounted || _overlayInert) return const SizedBox.shrink();
              final Size screen = Size(
                constraints.maxWidth,
                constraints.maxHeight,
              );
              return Stack(
                // 隐藏热槽停在屏幕右外侧预热（BUG-135），不能裁。
                clipBehavior: Clip.none,
                children: <Widget>[
                  if (shouldShowLookupDismissBarrier(
                    hasVisiblePopup: _popup.hasVisiblePopup,
                    isSearching: _popup.isSearchingUi,
                    hiddenByDialog: lookupPopupHiddenByDialog,
                  ))
                    Positioned.fill(
                      child: LookupDismissBarrier(
                        onTapDismiss: (_) => _popAt(0),
                        onSwipeDismiss: () => _popAt(_popup.lastVisibleIndex),
                        swipeEnabled:
                            ReaderFushiSource.instance.enableSwipeToClose,
                        touchSwipeEnabled:
                            ReaderFushiSource.instance.enableTouchSwipeToClose,
                        sensitivity:
                            ReaderFushiSource.instance.dismissSwipeSensitivity,
                        onNonPrimaryButtonDown:
                            onDismissBarrierNonPrimaryButton,
                      ),
                    ),
                  if (_popup.isSearchingUi && _popup.pendingRect != null)
                    buildPopupLoadingPlaceholder(
                      rect: _popup.pendingRect!,
                      screen: screen,
                    ),
                  for (int i = 0; i < _popup.entries.length; i++)
                    _buildNestedPopupLayer(i, screen),
                  ...buildParkedRealmLayers(screen: screen, controller: _popup),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildNestedPopupLayer(int index, Size screen) =>
      buildNestedPopupLayer(
        index: index,
        screen: screen,
        controller: _popup,
        // 嵌套查词共用同一个电脑端上下文：只压子层，不再 lookupBegin。
        onPush: (String text, Rect rect) => pushNestedPopup(
          query: text,
          selectionRect: rect,
          controller: _popup,
        ),
        onPop: _popAt,
        autoReadOnNavigate: true,
      );

  bool _isFavoriteSession(Map<String, dynamic> favorite) =>
      _state['available'] == true &&
      favorite['bookUid'] == _state['identity'] &&
      (favorite['sectionIndex'] ?? 0) == (_state['sectionIndex'] ?? 0) &&
      _cueSessionId == _state['sessionId'] &&
      _cueSubtitleVersion == _state['subtitleVersion'];

  Map<String, dynamic>? _favoriteCue(Map<String, dynamic> favorite) {
    if (!_isFavoriteSession(favorite)) return null;
    final List<Map<String, dynamic>> matches = _cues
        .where(
          (Map<String, dynamic> cue) =>
              cue['text'] == favorite['text'] &&
              cue['startMs'] == favorite['startMs'],
        )
        .toList();
    if (matches.length > 1) {
      throw const VideoRemoteError('favorite_subtitle_ambiguous');
    }
    return matches.firstOrNull;
  }

  void _checkFavoriteReady() {
    final Completer<Map<String, dynamic>>? waiter = _favoriteCueWaiter;
    final Map<String, dynamic>? favorite = _favoriteTarget;
    if (waiter == null || waiter.isCompleted || favorite == null) return;
    try {
      if (_state['error'] != null) {
        throw VideoRemoteError(_state['error'].toString());
      }
      final Map<String, dynamic>? cue = _favoriteCue(favorite);
      if (cue != null) waiter.complete(cue);
    } catch (e, stack) {
      waiter.completeError(e, stack);
    }
  }

  Future<Map<String, dynamic>> _waitForFavoriteCue(
    Map<String, dynamic> favorite,
  ) async {
    final Completer<Map<String, dynamic>> waiter =
        Completer<Map<String, dynamic>>();
    _favoriteTarget = favorite;
    _favoriteCueWaiter = waiter;
    _checkFavoriteReady();
    try {
      return await waiter.future.timeout(
        const Duration(seconds: 35),
        onTimeout: () =>
            throw const VideoRemoteError('favorite_subtitle_unavailable'),
      );
    } finally {
      if (identical(waiter, _favoriteCueWaiter)) {
        _favoriteCueWaiter = null;
        _favoriteTarget = null;
      }
    }
  }

  Future<void> _openFavorite(
    Map<String, dynamic> favorite, {
    bool lookup = false,
    int charOffset = 0,
  }) => _guard(() async {
    final int generation = _generation;
    if (_favoriteCueWaiter != null) return;
    if (lookup) {
      final Map<String, dynamic>? cue = _favoriteCue(favorite);
      if (cue != null) {
        await openLookup(cue, charOffset);
        return;
      }
    }
    // 根 Overlay 上的查词浮层排在对话框路由之上：对话框期间整栈让位。
    final bool? confirmed = await runWithLookupPopupHidden<bool?>(
      () => showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text(t.video_remote_open_favorite),
          content: Text(favorite['title'].toString()),
          actions: <Widget>[
            FushiTextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t.cancel),
            ),
            FushiTextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t.play),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true ||
        !mounted ||
        !_foreground ||
        generation != _generation) {
      return;
    }
    await _client.call('openFavorite', <String, dynamic>{
      'id': favorite['id'],
      'requestId': _client.requestId(),
    });
    await _apply(await _client.snapshot());
    if (lookup) {
      if (!mounted || !_foreground || generation != _generation) return;
      final Map<String, dynamic> cue = await _waitForFavoriteCue(favorite);
      if (mounted && _foreground && generation == _generation) {
        await openLookup(cue, charOffset);
      }
    }
  });
  @override
  Widget build(BuildContext context) {
    // 弹框挂在根 Overlay：本页每次重建（mixin 改栈后都会 setState）后同步过去。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPopupOverlay());
    final _TranscriptProjection projection = _projectTranscript();
    _lineRows = projection.rows;
    return PopScope(
      // 弹框开着时返回键先关弹框（逐层），不退出遥控页。
      canPop: !lookupOpen,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        final int top = _popup.lastVisibleIndex;
        _popAt(top >= 0 ? top : 0);
      },
      // 记下按下点：字幕组件只回「第几行第几个字」，弹框贴着手指落下的位置。
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (PointerDownEvent event) =>
            _lastPointer = event.position,
        child: Scaffold(
          body: VideoRemoteScaffold(
            nowPlaying: _nowPlaying(),
            lines: projection.lines,
            activeIndex: projection.activeLine,
            favorites: _favoriteEntries(),
            favoritesScope: _all
                ? VideoRemoteFavoritesScope.allVideos
                : VideoRemoteFavoritesScope.currentVideo,
            favoritesLoading: _favoritesLoading,
            controlLayout: _controlLayout(),
            clock: _playbackClock,
            notice: _notice(),
            initialTab: _tab,
            onTabChanged: (VideoRemoteTab tab) {
              _tab = tab;
              if (tab == VideoRemoteTab.favorites) {
                unawaited(_guard(_loadFavorites));
              }
            },
            isControlEnabled: _controlEnabled,
            transcriptReplayKey:
                '${_state['sessionId']}|${_state['subtitleVersion']}',
            callbacks: VideoRemoteCallbacks(
              onBack: () => unawaited(Navigator.of(context).maybePop()),
              onControl: (VideoRemoteControlItem item) =>
                  unawaited(_onControl(item)),
              onLookup: (int line, int charOffset) {
                if (line < 0 || line >= _lineRows.length) return;
                unawaited(
                  openLookup(
                    _lineRows[line],
                    charOffset,
                    anchor: _pointerAnchor(),
                  ),
                );
              },
              onLineTap: (int line) => _withLine(line, seekToRow),
              onReplayLine: (int line) => _withLine(line, seekToRow),
              onToggleFavoriteLine: (int line) =>
                  _withLine(line, toggleRowFavorite),
              // 制卡要先选词：打开这一句的查词弹框，在弹框里点 ＋。
              onMineLine: (int line) => _withLine(
                line,
                (Map<String, dynamic> row) => openLookup(row, 0),
              ),
              onFavoritesScopeChanged: (VideoRemoteFavoritesScope scope) =>
                  unawaited(
                    setFavoritesAllVideos(
                      scope == VideoRemoteFavoritesScope.allVideos,
                    ),
                  ),
              onOpenFavorite: (VideoRemoteFavoriteEntry entry) {
                final Map<String, dynamic>? favorite = _favoriteById(entry.id);
                if (favorite != null) unawaited(openFavorite(favorite));
              },
              onLookupFavorite: (VideoRemoteFavoriteEntry entry, int offset) {
                final Map<String, dynamic>? favorite = _favoriteById(entry.id);
                if (favorite == null) return;
                unawaited(
                  _openFavorite(favorite, lookup: true, charOffset: offset),
                );
              },
              onRemoveFavorites: (Set<String> ids) =>
                  unawaited(removeFavorites(ids)),
              onRefresh: () => unawaited(reconnect()),
              onSeek: available ? (Duration to) => unawaited(seekTo(to)) : null,
              onCustomizeControls: _prefs == null
                  ? null
                  : () => unawaited(
                      runWithLookupPopupHidden<void>(
                        () => showVideoRemoteControlEditor(
                          context,
                          prefs: _prefs,
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 展示投影：协议快照 → `video_remote/` 的不可变数据 ─────────────────────

  /// 脚手架的行（只放主轨）与 [_cues] 里对应行的映射；副轨挂成 secondaryText。
  _TranscriptProjection _projectTranscript() {
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    final List<VideoRemoteTranscriptLine> lines = <VideoRemoteTranscriptLine>[];
    final List<Map<String, dynamic>> secondary = <Map<String, dynamic>>[
      for (final Map<String, dynamic> cue in _cues)
        if (!_isPrimary(cue)) cue,
    ];
    int activeLine = -1;
    for (int i = 0; i < _cues.length; i++) {
      final Map<String, dynamic> cue = _cues[i];
      if (!_isPrimary(cue)) continue;
      if (i == _active) activeLine = rows.length;
      final int start = _cueStart(cue), end = _cueEnd(cue);
      final List<String> translations = <String>[
        for (final Map<String, dynamic> other in secondary)
          if (_cueStart(other) < end && _cueEnd(other) > start)
            other['text'].toString(),
      ];
      rows.add(cue);
      lines.add(
        VideoRemoteTranscriptLine(
          id: cue['id'].toString(),
          text: cue['text'].toString(),
          start: Duration(milliseconds: start),
          end: Duration(milliseconds: end),
          secondaryText: translations.isEmpty ? null : translations.join('\n'),
          favorited: _starred.contains(cue['id'].toString()),
        ),
      );
    }
    return _TranscriptProjection(rows, lines, activeLine);
  }

  void _withLine(
    int line,
    Future<void> Function(Map<String, dynamic> row) action,
  ) {
    if (line < 0 || line >= _lineRows.length) return;
    unawaited(action(_lineRows[line]));
  }

  VideoRemoteNowPlaying _nowPlaying() {
    final Map<String, dynamic>? current = _active >= 0 && _active < _cues.length
        ? _cues[_active]
        : null;
    return VideoRemoteNowPlaying(
      title: _state['title']?.toString() ?? '',
      hostName: widget.peer.deviceName,
      isPlaying: playing,
      speed: (_state['speed'] as num?)?.toDouble() ?? 1,
      currentFavorited:
          current != null && _starred.contains(current['id'].toString()),
    );
  }

  List<VideoRemoteFavoriteEntry> _favoriteEntries() =>
      <VideoRemoteFavoriteEntry>[
        for (final Map<String, dynamic> favorite in _favorites)
          VideoRemoteFavoriteEntry(
            id: favorite['id'].toString(),
            text: favorite['text'].toString(),
            videoTitle: favorite['title']?.toString() ?? '',
            start: Duration(
              milliseconds: (favorite['startMs'] as num?)?.toInt() ?? 0,
            ),
            isCurrentVideo:
                favorite['bookUid'] == _state['identity'] &&
                (favorite['sectionIndex'] ?? 0) ==
                    (_state['sectionIndex'] ?? 0),
          ),
      ];

  Map<String, dynamic>? _favoriteById(String id) {
    for (final Map<String, dynamic> favorite in _favorites) {
      if (favorite['id'].toString() == id) return favorite;
    }
    return null;
  }

  VideoRemoteNotice? _notice() {
    if (_error.isNotEmpty) {
      return VideoRemoteNotice(
        kind: _error == t.video_remote_error_unreachable
            ? VideoRemoteNoticeKind.disconnected
            : VideoRemoteNoticeKind.error,
        message: _error,
        actionLabel: t.video_remote_retry,
        onAction: () => unawaited(reconnect()),
      );
    }
    if (!available) {
      return VideoRemoteNotice(
        kind: VideoRemoteNoticeKind.waiting,
        message: t.video_remote_waiting,
      );
    }
    return null;
  }

  /// 按钮布局读偏好（偏好仓库未就绪时用出厂布局）。
  PreferencesRepository? get _prefs =>
      mixinAppModel.isPreferencesReady ? mixinAppModel.prefsRepo : null;

  VideoRemoteControlLayout _controlLayout() =>
      _prefs?.videoRemoteControlLayout ?? VideoRemoteControlLayout.defaults;

  /// 遥控协议没有倍速与电脑端字幕显隐命令：这两个按钮置灰而不是点了没反应。
  bool _controlEnabled(VideoRemoteControlItem item) => switch (item) {
    VideoRemoteControlItem.speed ||
    VideoRemoteControlItem.subtitleVisibility => false,
    VideoRemoteControlItem.previousCue => previousRowIndex >= 0,
    VideoRemoteControlItem.nextCue => nextRowIndex >= 0,
    VideoRemoteControlItem.replayCue ||
    VideoRemoteControlItem.favorite ||
    VideoRemoteControlItem.mine => _active >= 0,
    _ => available,
  };

  Future<void> _onControl(VideoRemoteControlItem item) async {
    final Map<String, dynamic>? current = _active >= 0 && _active < _cues.length
        ? _cues[_active]
        : null;
    switch (item) {
      case VideoRemoteControlItem.playPause:
        await togglePlay();
      case VideoRemoteControlItem.previousCue:
        await previousRow();
      case VideoRemoteControlItem.nextCue:
        await nextRow();
      case VideoRemoteControlItem.replayCue:
        if (current != null) await seekToRow(current);
      case VideoRemoteControlItem.favorite:
        if (current != null) await toggleRowFavorite(current);
      case VideoRemoteControlItem.mine:
        // 制卡要先选词：打开当前句的查词弹框。
        if (current != null) await openLookup(current, 0);
      case VideoRemoteControlItem.seekBack:
        await seekTo(Duration(milliseconds: positionMs.round() - 10000));
      case VideoRemoteControlItem.seekForward:
        await seekTo(Duration(milliseconds: positionMs.round() + 10000));
      case VideoRemoteControlItem.followCurrent:
      case VideoRemoteControlItem.speed:
      case VideoRemoteControlItem.subtitleVisibility:
        // followCurrent 由脚手架自己处理；另两个没有协议命令（已置灰）。
        break;
    }
  }

  /// 查词弹框的锚点：手指刚按下的位置（字幕组件只回行号与字号）；键盘查词
  /// 没有按下点时贴字幕列表的当前句高度。
  Rect _pointerAnchor() {
    final Offset? pointer = _lastPointer;
    if (pointer != null) {
      return Rect.fromCenter(center: pointer, width: 24, height: 24);
    }
    return _fallbackAnchor();
  }
}

/// [VideoRemotePageState._projectTranscript] 的结果。
class _TranscriptProjection {
  const _TranscriptProjection(this.rows, this.lines, this.activeLine);

  final List<Map<String, dynamic>> rows;
  final List<VideoRemoteTranscriptLine> lines;
  final int activeLine;
}

/// 控制卡进度条的读口：位置按电脑上报的快照 + 本地速度推算。
class _RemoteClock implements FushiPlaybackClock {
  _RemoteClock(this._page);

  final VideoRemotePageState _page;

  @override
  Duration get position =>
      Duration(milliseconds: math.max(0, _page.positionMs.round()));

  @override
  Duration get duration => Duration(
    milliseconds: (_page.playbackState['durationMs'] as num?)?.toInt() ?? 0,
  );
}

/// Localized text for a video remote failure. Host error codes map to their
/// own messages; unknown codes keep the code visible so reports stay useful.
/// Raw exception text (including [SyncAuthError.toString]) is never shown.
/// Returns an empty string for silent outcomes such as a cancelled lookup.
String videoRemoteErrorText(Object error) {
  if (error is SyncAuthError) return t.video_remote_error_pairing_rejected;
  if (error is VideoRemotePinRefused) {
    return t.video_remote_error_certificate_mismatch;
  }
  // 查词走同一台电脑的词典端点：全部候选传输层失败 = 电脑不可达。
  if (error is RemoteLookupUnreachableError) {
    return t.video_remote_error_unreachable;
  }
  if (error is! VideoRemoteError) {
    return t.video_remote_error_unknown(code: error.runtimeType.toString());
  }
  final String code = error.message;
  switch (code) {
    case 'lookup_cancelled':
      return '';
    case 'controller_busy':
      return t.video_remote_error_controller_busy;
    case 'controller_lease_lost':
      return t.video_remote_error_controller_lease_lost;
    case 'session_changed':
    case 'subtitles_changed':
    case 'cue_missing':
      return t.video_remote_error_subtitles_changed;
    case 'favorite_missing':
      return t.video_remote_error_favorite_missing;
    case 'favorite_ambiguous':
    case 'favorite_subtitle_ambiguous':
      return t.video_remote_error_favorite_ambiguous;
    case 'favorite_source_unavailable':
    case 'favorite_subtitle_unavailable':
      return t.video_remote_error_favorite_source_unavailable;
    case 'favorite_subtitle_missing':
      return t.video_remote_error_favorite_subtitle_missing;
    case 'video_extraction_unavailable':
      return t.video_remote_error_video_extraction_unavailable;
    case 'lookup_expired':
      return t.video_remote_error_lookup_expired;
    case 'mining_busy':
      return t.video_remote_error_mining_busy;
    case 'mining_failed':
      return t.video_remote_error_mining_failed;
    case 'requests_busy':
      return t.video_remote_error_requests_busy;
    case 'no_video':
      return t.video_remote_error_no_video;
    case 'remote_closed':
      return t.video_remote_error_remote_closed;
    case 'task_missing':
      return t.video_remote_error_task_missing;
    case 'internal_error':
      return t.video_remote_error_internal_error;
    case 'paired_peer_required':
      return t.video_remote_error_pairing_rejected;
    case VideoRemoteError.unreachableCode:
      return t.video_remote_error_unreachable;
    case VideoRemoteError.certificateMismatchCode:
      return t.video_remote_error_certificate_mismatch;
    case 'invalid_action':
    case 'invalid_argument':
    case 'invalid_favorite':
    case 'invalid_favorites':
    case 'invalid_fields':
    case 'invalid_json':
    case 'invalid_number':
    case 'invalid_peer':
    case 'invalid_request_id':
    case 'invalid_revision':
    case 'request_id_conflict':
    case 'unknown_operation':
      return t.video_remote_error_invalid_request(code: code);
  }
  // An old host without the endpoint answers a bare 404/405.
  if (error.statusCode == 404 || error.statusCode == 405) {
    return t.video_remote_unsupported;
  }
  return t.video_remote_error_unknown(code: code);
}
