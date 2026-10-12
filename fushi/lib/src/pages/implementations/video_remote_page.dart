import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, ScrollDirection;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/sync_backend.dart' show SyncAuthError;
import 'package:fushi/src/sync/video_remote_client.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:http/http.dart' as http;

class VideoRemotePage extends StatefulWidget {
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
  State<VideoRemotePage> createState() => _VideoRemotePageState();
}

class _VideoRemotePageState extends State<VideoRemotePage>
    with WidgetsBindingObserver {
  late final VideoRemoteClient _client = VideoRemoteClient(
    repository: widget.repository,
    peer: widget.peer,
    httpClient: widget.httpClient,
  );
  late http.Client _dictionaryHttp = widget.httpClient ?? http.Client();
  late FushiRemoteLookupClient _lookup = _createLookup();
  final ScrollController _scroll = ScrollController();
  Map<String, dynamic> _state = <String, dynamic>{};
  List<Map<String, dynamic>> _cues = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _favorites = <Map<String, dynamic>>[];
  final Set<String> _selected = <String>{};
  final Set<String> _starred = <String>{};
  bool _foreground = true, _polling = false, _follow = true, _all = false;
  int _tab = 0, _active = -1, _revision = 0, _generation = 0;
  int _favoriteGeneration = 0;
  String _query = '', _error = '';
  Timer? _clock;
  Timer? _retry;
  int _retryAttempt = 0;
  Future<void> _disconnecting = Future<void>.value();
  Route<dynamic>? _lookupPageRoute;
  NavigatorState? _lookupNavigator;
  bool _openingLookup = false;
  Map<String, dynamic>? _favoriteTarget;
  Completer<Map<String, dynamic>>? _favoriteCueWaiter;
  String? _cueSessionId;
  int? _cueSubtitleVersion;
  String? _cueLoadKey;
  Future<List<Map<String, dynamic>>>? _cueLoad;
  DateTime _anchor = DateTime.now();
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
        _closeLookup();
        _dictionaryHttp.close();
        _client.cancelPending();
        _disconnecting = _disconnecting.then((_) => _disconnect());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  @override
  void dispose() {
    _foreground = false;
    final Completer<Map<String, dynamic>>? waiter = _favoriteCueWaiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(const VideoRemoteError('lookup_cancelled'));
    }
    _dictionaryHttp.close();
    _client.cancelPending();
    _generation++;
    _clock?.cancel();
    _retry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    unawaited(_disconnect());
    super.dispose();
  }

  Future<void> _disconnect() async {
    final VideoRemoteClient cleanup = VideoRemoteClient(
      repository: widget.repository,
      peer: widget.peer,
      httpClient: widget.httpClient,
    );
    try {
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

  void _closeLookup() {
    final Completer<Map<String, dynamic>>? waiter = _favoriteCueWaiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(const VideoRemoteError('lookup_cancelled'));
    }
    final Route<dynamic>? route = _lookupPageRoute;
    final NavigatorState? navigator = _lookupNavigator;
    if (route != null && route.isActive && navigator != null) {
      navigator.popUntil((Route<dynamic> candidate) => candidate == route);
    }
    _lookupPageRoute = null;
    _lookupNavigator = null;
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
    if (_follow && _tab == 0) _recenter();
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

  /// Rows have no fixed height (long lines and the theme text size wrap), so
  /// the current row is located through its own render object. A row that is
  /// not built yet is first approached by the average laid-out row height.
  void _recenter() {
    if (_active < 0 || _active >= _cues.length || !_scroll.hasClients) return;
    final ScrollPosition position = _scroll.position;
    final BuildContext? row = GlobalObjectKey(_cues[_active]).currentContext;
    final RenderObject? render = row?.findRenderObject();
    if (render == null || !render.attached) {
      final double average =
          (position.maxScrollExtent + position.viewportDimension) /
          _cues.length;
      position.jumpTo(
        (_active * average - position.viewportDimension / 3).clamp(
          0.0,
          position.maxScrollExtent,
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_follow || _tab != 0) return;
        final BuildContext? built = _active >= 0 && _active < _cues.length
            ? GlobalObjectKey(_cues[_active]).currentContext
            : null;
        if (built != null) {
          unawaited(Scrollable.ensureVisible(built, alignment: 1 / 3));
        }
      });
      return;
    }
    final double target = RenderAbstractViewport.of(render)
        .getOffsetToReveal(render, 1 / 3)
        .offset
        .clamp(0.0, position.maxScrollExtent);
    if ((position.pixels - target).abs() > position.viewportDimension / 3) {
      unawaited(
        _scroll.animateTo(
          target,
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  Future<void> _command(String action, [String? cueId]) => _guard(() async {
    await _client.call('command', <String, dynamic>{
      ..._session,
      'requestId': _client.requestId(),
      'action': action,
      if (cueId != null) 'cueId': cueId,
    });
    await _apply(await _client.snapshot());
  });
  Future<void> _loadFavorites() async {
    final int lifecycle = _generation;
    final int generation = ++_favoriteGeneration;
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    int total = 0;
    do {
      final Map<String, dynamic> result = await _client
          .call('favorites', <String, dynamic>{
            'query': _query,
            'currentOnly': !_all,
            'sessionId': _state['sessionId'],
            'offset': items.length,
            'limit': 200,
          });
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
    if (_query.isNotEmpty || _all) {
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
        _selected.retainWhere(
          (String id) => items.any(
            (Map<String, dynamic> item) => item['id'].toString() == id,
          ),
        );
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
  Future<void> _lookupCue(Map<String, dynamic> cue, [String? selectedWord]) =>
      _guard(() async {
        if (_openingLookup || !_foreground) return;
        _openingLookup = true;
        final int generation = _generation;
        try {
          final Map<String, dynamic> begun = await _client.call(
            'lookupBegin',
            <String, dynamic>{
              ..._session,
              'cueId': cue['id'],
              'requestId': _client.requestId(),
            },
          );
          final String contextId = begun['contextId'].toString();
          try {
            if (!mounted || !_foreground || generation != _generation) return;
            _lookupPageRoute = ModalRoute.of(context);
            _lookupNavigator = Navigator.of(context);
            await showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (BuildContext context) => _VideoLookupSheet(
                client: _client,
                lookup: _lookup,
                contextId: contextId,
                sentence: (begun['sentence'] ?? cue['text']).toString(),
                initialTerm: selectedWord ?? cue['text'].toString(),
              ),
            );
          } finally {
            _lookupPageRoute = null;
            _lookupNavigator = null;
            if (mounted && _foreground && generation == _generation) {
              await _client.call('lookupEnd', <String, dynamic>{
                'contextId': contextId,
                'requestId': _client.requestId(),
              });
            }
          }
        } finally {
          _openingLookup = false;
        }
      });

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
  }) => _guard(() async {
    final int generation = _generation;
    if (_favoriteCueWaiter != null) return;
    if (lookup) {
      final Map<String, dynamic>? cue = _favoriteCue(favorite);
      if (cue != null) {
        await _lookupCue(cue);
        return;
      }
    }
    final bool? confirmed = await showDialog<bool>(
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
        await _lookupCue(cue);
      }
    }
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_state['title']?.toString() ?? t.video_remote_title),
      actions: <Widget>[
        FushiIconButtonControl(
          tooltip: t.video_remote_retry,
          onPressed: () => unawaited(_start()),
          icon: const Icon(FushiIcons.refresh),
        ),
      ],
    ),
    body: Column(
      children: <Widget>[
        if (_error.isNotEmpty)
          MaterialBanner(
            content: Text(_error),
            actions: <Widget>[
              FushiTextButton(
                onPressed: () => unawaited(_start()),
                child: Text(t.video_remote_retry),
              ),
            ],
          ),
        if (_state['available'] != true)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(t.video_remote_waiting),
          ),
        Expanded(
          child: FushiEntranceScope(
            replayKey: _tab,
            child: _tab == 0
                ? NotificationListener<UserScrollNotification>(
                    onNotification: (UserScrollNotification notification) {
                      if (notification.direction != ScrollDirection.idle &&
                          _follow) {
                        setState(() => _follow = false);
                      }
                      return false;
                    },
                    child: ListView.builder(
                      controller: _scroll,
                      itemCount: _cues.length,
                      itemBuilder: (BuildContext context, int index) {
                        final Map<String, dynamic> cue = _cues[index];
                        return FushiStaggeredEntrance(
                          key: GlobalObjectKey(cue),
                          index: index,
                          child: FushiListItem(
                            selected: index == _active,
                            title: SubtitleTranscriptText(
                              text: cue['text'].toString(),
                              keyboardLookup: true,
                              style:
                                  Theme.of(context).textTheme.titleMedium ??
                                  const TextStyle(),
                              onLookup: (int index, Rect anchor) => unawaited(
                                _lookupCue(
                                  cue,
                                  subtitleTranscriptLookupSpan(
                                    cue['text'].toString(),
                                    index,
                                  ).term,
                                ),
                              ),
                            ),
                            onTap: () => unawaited(_lookupCue(cue)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                FushiIconButtonControl(
                                  tooltip: t.play,
                                  onPressed: () => unawaited(
                                    _command('seekCue', cue['id'].toString()),
                                  ),
                                  icon: const Icon(FushiIcons.replay),
                                ),
                                FushiIconButtonControl(
                                  tooltip: t.video_remote_favorites,
                                  onPressed: () => unawaited(_star(cue)),
                                  icon: Icon(
                                    _starred.contains(cue['id'].toString())
                                        ? FushiIcons.filled(FushiIcons.star)
                                        : FushiIcons.star,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  )
                : Column(
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: FushiTextField(
                              labelText: t.search,
                              onSubmitted: (String value) {
                                _query = value;
                                unawaited(_guard(_loadFavorites));
                              },
                            ),
                          ),
                          FushiSwitch(
                            value: _all,
                            onChanged: (bool value) {
                              setState(() => _all = value);
                              unawaited(_guard(_loadFavorites));
                            },
                          ),
                          Text(t.video_remote_all),
                        ],
                      ),
                      if (_selected.isNotEmpty)
                        FushiTextButton.icon(
                          onPressed: () => unawaited(
                            _guard(() async {
                              final List<String> ids = _selected.toList();
                              for (
                                int offset = 0;
                                offset < ids.length;
                                offset += 200
                              ) {
                                final List<String> batch = ids.sublist(
                                  offset,
                                  (offset + 200).clamp(0, ids.length),
                                );
                                await _client.call(
                                  'favoritesRemove',
                                  <String, dynamic>{
                                    'ids': batch,
                                    'requestId': _client.requestId(),
                                  },
                                );
                                if (mounted) {
                                  setState(() => _selected.removeAll(batch));
                                }
                              }
                              await _loadFavorites();
                            }),
                          ),
                          icon: const Icon(FushiIcons.delete),
                          label: Text(t.video_remote_remove),
                        ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _favorites.length,
                          itemBuilder: (BuildContext context, int index) {
                            final Map<String, dynamic> favorite =
                                _favorites[index];
                            final String id = favorite['id'].toString();
                            return FushiStaggeredEntrance(
                              index: index,
                              child: FushiCheckboxListTile(
                                value: _selected.contains(id),
                                onChanged: (bool? value) => setState(() {
                                  if (value == true) {
                                    _selected.add(id);
                                  } else {
                                    _selected.remove(id);
                                  }
                                }),
                                title: GestureDetector(
                                  onTap: () => unawaited(
                                    _openFavorite(favorite, lookup: true),
                                  ),
                                  child: Text(favorite['text'].toString()),
                                ),
                                subtitle: Text(favorite['title'].toString()),
                                secondary: FushiIconButtonControl(
                                  tooltip: t.play,
                                  onPressed: () =>
                                      unawaited(_openFavorite(favorite)),
                                  icon: const Icon(FushiIcons.play),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        if (_tab == 0 && !_follow)
          FushiTextButton(
            onPressed: () {
              setState(() => _follow = true);
              _recenter();
            },
            child: Text(t.video_remote_current),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            FushiIconButtonControl(
              tooltip: t.video_remote_previous,
              onPressed: _primaryNeighbor(-1) >= 0
                  ? () => unawaited(
                      _command(
                        'seekCue',
                        _cues[_primaryNeighbor(-1)]['id'].toString(),
                      ),
                    )
                  : null,
              icon: const Icon(FushiIcons.skipPrevious),
            ),
            FushiIconButtonControl(
              tooltip: _state['playing'] == true ? t.pause : t.play,
              onPressed: _state['available'] == true
                  ? () => unawaited(
                      _command(_state['playing'] == true ? 'pause' : 'play'),
                    )
                  : null,
              icon: Icon(
                _state['playing'] == true ? FushiIcons.pause : FushiIcons.play,
              ),
            ),
            FushiIconButtonControl(
              tooltip: t.video_remote_next,
              onPressed: _primaryNeighbor(1) >= 0
                  ? () => unawaited(
                      _command(
                        'seekCue',
                        _cues[_primaryNeighbor(1)]['id'].toString(),
                      ),
                    )
                  : null,
              icon: const Icon(FushiIcons.skipNext),
            ),
          ],
        ),
      ],
    ),
    bottomNavigationBar: BottomNavigationBar(
      currentIndex: _tab,
      onTap: (int value) {
        setState(() => _tab = value);
        if (value == 1) unawaited(_guard(_loadFavorites));
      },
      items: <BottomNavigationBarItem>[
        BottomNavigationBarItem(
          icon: const Icon(FushiIcons.subtitles),
          label: t.video_remote_subtitles,
        ),
        BottomNavigationBarItem(
          icon: const Icon(FushiIcons.star),
          label: t.video_remote_favorites,
        ),
      ],
    ),
  );
}

class _VideoLookupSheet extends StatefulWidget {
  const _VideoLookupSheet({
    required this.client,
    required this.lookup,
    required this.contextId,
    required this.sentence,
    required this.initialTerm,
  });
  final VideoRemoteClient client;
  final FushiRemoteLookupClient lookup;
  final String contextId, sentence, initialTerm;
  @override
  State<_VideoLookupSheet> createState() => _VideoLookupSheetState();
}

class _VideoLookupSheetState extends State<_VideoLookupSheet> {
  // Owned by this State: the sheet's exit animation still builds the field
  // after showModalBottomSheet returns, so the caller must not dispose it.
  late final TextEditingController _term = TextEditingController(
    text: widget.initialTerm,
  );
  List<DictionaryEntry> _entries = <DictionaryEntry>[];
  String _status = '';
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  @override
  void dispose() {
    _term.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => _busy = true);
    try {
      final DictionarySearchResult? result = await widget.lookup
          .searchDictionary(
            term: _term.text,
            wildcards: false,
            maximumTerms: 20,
          );
      if (mounted) {
        setState(() {
          _entries = result?.entries ?? <DictionaryEntry>[];
          _status = _entries.isEmpty ? t.video_remote_no_results : '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = videoRemoteErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _mine(DictionaryEntry entry) async {
    final _VideoMineFields? fields = await showDialog<_VideoMineFields>(
      context: context,
      builder: (BuildContext context) => _VideoMineDialog(
        initial: _VideoMineFields(
          expression: entry.word,
          reading: entry.reading,
          glossary: entry.plainMeaning,
          sentence: widget.sentence,
        ),
      ),
    );
    if (fields == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final String requestId = widget.client.requestId();
      Map<String, dynamic> task;
      try {
        task = await widget.client.call('mine', <String, dynamic>{
          'contextId': widget.contextId,
          'requestId': requestId,
          'fields': <String, dynamic>{
            'rawFields': <String, String>{
              'expression': fields.expression,
              'reading': fields.reading,
              'glossary': fields.glossary,
            },
            'sentence': fields.sentence,
          },
        });
      } on VideoRemoteError catch (e) {
        // Only a request that got no response may still have been accepted;
        // a host rejection (lookup_expired, mining_busy, ...) is the real
        // outcome and must not be masked by a task_missing status lookup.
        if (e.statusCode != null) rethrow;
        task = await widget.client.call('mineStatus', <String, dynamic>{
          'requestId': requestId,
        });
      }
      while (mounted &&
          (task['status'] == 'queued' || task['status'] == 'running')) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        task = await widget.client.call('mineStatus', <String, dynamic>{
          'taskId': task['taskId'],
        });
      }
      if (mounted) {
        setState(
          () => _status = task['status'] == 'succeeded'
              ? t.video_remote_mined
              : videoRemoteErrorText(
                  VideoRemoteError(
                    (task['error'] ?? 'mining_failed').toString(),
                  ),
                ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _status = videoRemoteErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: Column(
          children: <Widget>[
            Text(widget.sentence, maxLines: 3),
            Row(
              children: <Widget>[
                Expanded(
                  child: FushiTextField(
                    controller: _term,
                    labelText: t.search,
                    onSubmitted: (_) => unawaited(_search()),
                  ),
                ),
                FushiIconButtonControl(
                  tooltip: t.search,
                  onPressed: _busy ? null : () => unawaited(_search()),
                  icon: const Icon(FushiIcons.search),
                ),
              ],
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_status.isNotEmpty) Text(_status),
            Expanded(
              child: ListView.builder(
                itemCount: _entries.length,
                itemBuilder: (BuildContext context, int index) {
                  final DictionaryEntry entry = _entries[index];
                  return FushiListItem(
                    title: Text('${entry.word} ${entry.reading}'),
                    subtitle: Text(
                      '${entry.dictionaryName}\n${entry.plainMeaning}',
                    ),
                    onTap: _busy ? null : () => unawaited(_mine(entry)),
                  );
                },
              ),
            ),
            FushiTextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: Text(t.dialog_close),
            ),
          ],
        ),
      ),
    ),
  );
}

class _VideoMineFields {
  const _VideoMineFields({
    required this.expression,
    required this.reading,
    required this.glossary,
    required this.sentence,
  });
  final String expression, reading, glossary, sentence;
}

/// Card preview form. Its controllers live in this State so the dialog's exit
/// animation never builds a disposed controller.
class _VideoMineDialog extends StatefulWidget {
  const _VideoMineDialog({required this.initial});
  final _VideoMineFields initial;
  @override
  State<_VideoMineDialog> createState() => _VideoMineDialogState();
}

class _VideoMineDialogState extends State<_VideoMineDialog> {
  late final TextEditingController _expression = TextEditingController(
    text: widget.initial.expression,
  );
  late final TextEditingController _reading = TextEditingController(
    text: widget.initial.reading,
  );
  late final TextEditingController _glossary = TextEditingController(
    text: widget.initial.glossary,
  );
  late final TextEditingController _sentence = TextEditingController(
    text: widget.initial.sentence,
  );

  @override
  void dispose() {
    _expression.dispose();
    _reading.dispose();
    _glossary.dispose();
    _sentence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t.video_remote_mine),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final MapEntry<String, TextEditingController> field
              in <String, TextEditingController>{
                t.video_remote_expression: _expression,
                t.video_remote_reading: _reading,
                t.video_remote_meaning: _glossary,
                t.video_remote_sentence: _sentence,
              }.entries)
            FushiTextField(
              controller: field.value,
              labelText: field.key,
              maxLines: null,
            ),
        ],
      ),
    ),
    actions: <Widget>[
      FushiTextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t.cancel),
      ),
      FushiTextButton(
        onPressed: () => Navigator.pop(
          context,
          _VideoMineFields(
            expression: _expression.text,
            reading: _reading.text,
            glossary: _glossary.text,
            sentence: _sentence.text,
          ),
        ),
        child: Text(t.video_remote_mine),
      ),
    ],
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
