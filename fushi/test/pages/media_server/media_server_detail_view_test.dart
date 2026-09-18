import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_detail_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/utils.dart';

import 'fake_media_server_browser.dart';

/// 剧详情：季标签切换重拉集；点集时播放请求的 members 是当前季**已加载的全部集**、
/// index 是点中的下标；单季不显示季标签；电影简版详情「播放」直接播。
void main() {
  late FakeMediaServerBrowser browser;
  late List<MediaServerPlayRequest> played;

  const MediaServerItem series = MediaServerItem(
    id: 's1',
    name: 'Series s1',
    type: MediaServerItemType.series,
  );
  const MediaServerItem seasonOne = MediaServerItem(
    id: 'sea1',
    name: 'Season 1',
    type: MediaServerItemType.season,
    seriesId: 's1',
    seasonNumber: 1,
  );
  const MediaServerItem seasonTwo = MediaServerItem(
    id: 'sea2',
    name: 'Season 2',
    type: MediaServerItemType.season,
    seriesId: 's1',
    seasonNumber: 2,
  );

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    browser = FakeMediaServerBrowser();
    played = <MediaServerPlayRequest>[];
  });

  Widget harness(MediaServerItem item, {String? initialSeasonId}) {
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: MediaServerDetailView(
            session: MediaServerSession(
              browser: browser,
              play: (BuildContext _, MediaServerPlayRequest request) =>
                  played.add(request),
            ),
            item: item,
            initialSeasonId: initialSeasonId,
          ),
        ),
      ),
    );
  }

  Iterable<FakePageRequest> episodeRequests() =>
      browser.requests.where((FakePageRequest r) => r.kind == 'episodes');

  testWidgets('双季：季标签切换重拉该季集清单', (WidgetTester tester) async {
    browser.seasons['s1'] = <MediaServerItem>[seasonOne, seasonTwo];
    browser.episodes['s1|sea1'] = fakeEpisodes(
      seriesId: 's1',
      seasonId: 'sea1',
      seasonNumber: 1,
      count: 3,
    );
    browser.episodes['s1|sea2'] = fakeEpisodes(
      seriesId: 's1',
      seasonId: 'sea2',
      seasonNumber: 2,
      count: 2,
    );

    await tester.pumpWidget(harness(series));
    await tester.pumpAndSettle();

    expect(episodeRequests().single.seasonId, 'sea1', reason: '缺省第一季');
    expect(
      find.byKey(const ValueKey<String>('media-server-episode-sea1-ep1')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-season-sea2')),
    );
    await tester.pumpAndSettle();

    expect(episodeRequests().last.seasonId, 'sea2');
    expect(episodeRequests().last.startIndex, 0, reason: '换季从第一页重来');
    expect(
      find.byKey(const ValueKey<String>('media-server-episode-sea2-ep2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-server-episode-sea1-ep1')),
      findsNothing,
      reason: '旧季的集不能残留',
    );
  });

  testWidgets('点集：members = 当前季已加载全部集，index = 点中下标', (
    WidgetTester tester,
  ) async {
    browser.seasons['s1'] = <MediaServerItem>[seasonOne, seasonTwo];
    browser.episodes['s1|sea1'] = fakeEpisodes(
      seriesId: 's1',
      seasonId: 'sea1',
      seasonNumber: 1,
      count: 4,
    );
    browser.episodes['s1|sea2'] = fakeEpisodes(
      seriesId: 's1',
      seasonId: 'sea2',
      seasonNumber: 2,
      count: 3,
    );

    // 详情头 + 季标签之下的第三集在 600 高视口里会落到屏外，tap 不到。
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(harness(series, initialSeasonId: 'sea2'));
    await tester.pumpAndSettle();
    expect(
      episodeRequests().single.seasonId,
      'sea2',
      reason: 'initialSeasonId 命中就从那一季起',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-episode-sea2-ep3')),
    );
    await tester.pumpAndSettle();

    expect(played, hasLength(1));
    final MediaServerPlayRequest request = played.single;
    expect(request.info.id, 'sea2-ep3');
    expect(request.members.map((m) => m.id).toList(), <String>[
      'sea2-ep1',
      'sea2-ep2',
      'sea2-ep3',
    ], reason: '同伴是当前季全部集、按集号序');
    expect(request.initialIndex, 2);
    expect(request.hasCollection, isTrue);
  });

  testWidgets('单季不显示季标签；详情失败回退清单条目', (WidgetTester tester) async {
    browser.seasons['s1'] = <MediaServerItem>[seasonOne];
    browser.episodes['s1|sea1'] = fakeEpisodes(
      seriesId: 's1',
      seasonId: 'sea1',
      seasonNumber: 1,
      count: 1,
    );

    await tester.pumpWidget(harness(series));
    await tester.pumpAndSettle();

    expect(find.byType(ChoiceChip), findsNothing);
    expect(browser.itemDetailCalls, 1);
    expect(
      find.text('Series s1'),
      findsWidgets,
      reason: 'itemDetail 抛时仍用清单那条画',
    );
  });

  testWidgets('电影简版详情：简介 + 播放，播放直接出请求且不带同伴', (WidgetTester tester) async {
    const MediaServerItem movie = MediaServerItem(
      id: 'm1',
      name: 'Movie m1',
      type: MediaServerItemType.movie,
      productionYear: 2001,
    );
    browser.details['m1'] = const MediaServerItem(
      id: 'm1',
      name: 'Movie m1',
      type: MediaServerItemType.movie,
      productionYear: 2001,
      overview: '一段简介',
      communityRating: 7.5,
    );

    await tester.pumpWidget(harness(movie));
    await tester.pumpAndSettle();

    expect(find.text('一段简介'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(episodeRequests(), isEmpty, reason: '电影不拉集');

    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-detail-play')),
    );
    await tester.pumpAndSettle();
    expect(played.single.info.id, 'm1');
    expect(played.single.hasCollection, isFalse);
  });
}
