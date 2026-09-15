import 'package:flutter/material.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/utils.dart';

/// 悬浮球展开后可放的按钮。顺序即 [values] 顺序（弧上从上到下固定按此排，用户只挑
/// 「放不放」，不排顺序——三键传输语义上退下进，乱序反而误触）。
///
/// 球本身是 `ReaderFloatingBall`（`lib/src/reader/reader_floating_ball.dart`），
/// 只吃 [ReaderHeaderAction]；这里负责「哪些键 + 每颗键按下去干什么」。
enum AudiobookFloatingBallAction {
  seekBack('seek_back'),
  prev('prev'),
  playPause('play_pause'),
  next('next'),
  seekForward('seek_forward'),
  follow('follow'),
  settings('settings');

  const AudiobookFloatingBallAction(this.id);

  /// 持久化 id（偏好里逗号拼接）。
  final String id;

  /// 默认三键：上一句 / 播放暂停 / 下一句。
  static const List<AudiobookFloatingBallAction> defaults =
      <AudiobookFloatingBallAction>[prev, playPause, next];

  /// 把逗号拼接的偏好值解回动作列表：未知 id 丢弃、重复去重、顺序归一到
  /// [values] 顺序；解出来一个都没有（空串 / 全是旧 id）回默认三键，悬浮球
  /// 不会因为一条坏偏好变成空壳。
  static List<AudiobookFloatingBallAction> decode(String raw) {
    final Set<String> ids = raw
        .split(',')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toSet();
    final List<AudiobookFloatingBallAction> out = <AudiobookFloatingBallAction>[
      for (final AudiobookFloatingBallAction a in values)
        if (ids.contains(a.id)) a,
    ];
    return out.isEmpty ? defaults : out;
  }

  static String encode(Iterable<AudiobookFloatingBallAction> actions) {
    final Set<AudiobookFloatingBallAction> set = actions.toSet();
    return <String>[
      for (final AudiobookFloatingBallAction a in values)
        if (set.contains(a)) a.id,
    ].join(',');
  }
}

/// 一颗悬浮球按钮的动作描述：语义与底栏播放条 [AudiobookPlayBar] 逐颗对齐——
/// 上一句 / 下一句跟随「跳转方式」偏好（0 = 按句，N = 按 N 秒），播放键按运行态
/// 换图标（页面在播放态翻转时重建 chrome）。
ReaderHeaderAction audiobookFloatingBallHeaderAction(
  AudiobookFloatingBallAction action, {
  required AudiobookPlayerController controller,
  required int skipActionSeconds,
  required VoidCallback onOpenSettings,
}) {
  switch (action) {
    case AudiobookFloatingBallAction.seekBack:
      return ReaderHeaderAction(
        icon: Icons.replay_10_outlined,
        label: '-10s',
        semanticsId: 'hibiki.reader.floating_ball.seek_back',
        onPressed: () => controller.seekRelative(-10),
      );
    case AudiobookFloatingBallAction.seekForward:
      return ReaderHeaderAction(
        icon: Icons.forward_10_outlined,
        label: '+10s',
        semanticsId: 'hibiki.reader.floating_ball.seek_forward',
        onPressed: () => controller.seekRelative(10),
      );
    case AudiobookFloatingBallAction.prev:
      return ReaderHeaderAction(
        icon: skipActionSeconds == 0
            ? Icons.skip_previous_outlined
            : Icons.fast_rewind_outlined,
        label: skipActionSeconds == 0
            ? t.prev_sentence
            : '-${skipActionSeconds}s',
        semanticsId: 'hibiki.reader.floating_ball.prev',
        onPressed: () => skipActionSeconds == 0
            ? controller.skipToPrevCue()
            : controller.seekRelative(-skipActionSeconds),
      );
    case AudiobookFloatingBallAction.next:
      return ReaderHeaderAction(
        icon: skipActionSeconds == 0
            ? Icons.skip_next_outlined
            : Icons.fast_forward_outlined,
        label: skipActionSeconds == 0
            ? t.next_sentence
            : '+${skipActionSeconds}s',
        semanticsId: 'hibiki.reader.floating_ball.next',
        onPressed: () => skipActionSeconds == 0
            ? controller.skipToNextCue()
            : controller.seekRelative(skipActionSeconds),
      );
    case AudiobookFloatingBallAction.playPause:
      final bool playing = controller.isPlaying;
      return ReaderHeaderAction(
        icon: playing ? Icons.pause_outlined : Icons.play_arrow_outlined,
        label: playing ? t.pause : t.play,
        semanticsId: 'hibiki.reader.floating_ball.play_pause',
        onPressed: controller.togglePlayPause,
      );
    case AudiobookFloatingBallAction.follow:
      final bool on = controller.followAudio.value;
      return ReaderHeaderAction(
        icon: on ? Icons.link : Icons.link_off,
        label: on ? t.follow_audio_on_tooltip : t.follow_audio_off_tooltip,
        semanticsId: 'hibiki.reader.floating_ball.follow',
        onPressed: () => controller.setFollowAudio(!on),
      );
    case AudiobookFloatingBallAction.settings:
      return ReaderHeaderAction(
        icon: Icons.tune_outlined,
        label: t.settings,
        semanticsId: 'hibiki.reader.floating_ball.settings',
        onPressed: onOpenSettings,
      );
  }
}

/// 设置面板里给每个动作用的静态标签（chip 文案），与按钮 tooltip 同源。
String audiobookFloatingBallActionLabel(
  AudiobookFloatingBallAction action, {
  required int skipActionSeconds,
}) {
  switch (action) {
    case AudiobookFloatingBallAction.seekBack:
      return '-10s';
    case AudiobookFloatingBallAction.seekForward:
      return '+10s';
    case AudiobookFloatingBallAction.prev:
      return skipActionSeconds == 0
          ? t.prev_sentence
          : '-${skipActionSeconds}s';
    case AudiobookFloatingBallAction.next:
      return skipActionSeconds == 0
          ? t.next_sentence
          : '+${skipActionSeconds}s';
    case AudiobookFloatingBallAction.playPause:
      return '${t.play} / ${t.pause}';
    case AudiobookFloatingBallAction.follow:
      return t.audiobook_follow_audio;
    case AudiobookFloatingBallAction.settings:
      return t.settings;
  }
}

/// 设置面板 chip 用的图标。
IconData audiobookFloatingBallActionIcon(AudiobookFloatingBallAction action) {
  switch (action) {
    case AudiobookFloatingBallAction.seekBack:
      return Icons.replay_10_outlined;
    case AudiobookFloatingBallAction.seekForward:
      return Icons.forward_10_outlined;
    case AudiobookFloatingBallAction.prev:
      return Icons.skip_previous_outlined;
    case AudiobookFloatingBallAction.next:
      return Icons.skip_next_outlined;
    case AudiobookFloatingBallAction.playPause:
      return Icons.play_arrow_outlined;
    case AudiobookFloatingBallAction.follow:
      return Icons.link;
    case AudiobookFloatingBallAction.settings:
      return Icons.tune_outlined;
  }
}

/// 悬浮球按钮集合的设置行：一排 FilterChip，顺序固定为 [values]；至少留一个
/// （最后一个不可取消）。设置页与书内面板共用（走 schema 的 SettingsCustomItem）。
class AudiobookFloatingBallActionsRow extends StatelessWidget {
  const AudiobookFloatingBallActionsRow({
    required this.selected,
    required this.skipActionSeconds,
    required this.onChanged,
    super.key,
  });

  final List<AudiobookFloatingBallAction> selected;
  final int skipActionSeconds;
  final ValueChanged<Set<AudiobookFloatingBallAction>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AdaptiveSettingsRow(
          title: t.reader_floating_ball_actions,
          subtitle: t.reader_floating_ball_actions_hint,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              for (final AudiobookFloatingBallAction action
                  in AudiobookFloatingBallAction.values)
                FilterChip(
                  key: ValueKey<String>('floating_ball_action_${action.id}'),
                  avatar: Icon(
                    audiobookFloatingBallActionIcon(action),
                    size: 18,
                  ),
                  label: Text(
                    audiobookFloatingBallActionLabel(
                      action,
                      skipActionSeconds: skipActionSeconds,
                    ),
                  ),
                  selected: selected.contains(action),
                  onSelected: (bool on) {
                    final Set<AudiobookFloatingBallAction> next = selected
                        .toSet();
                    if (on) {
                      next.add(action);
                    } else if (next.length > 1) {
                      next.remove(action);
                    } else {
                      return;
                    }
                    onChanged(next);
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}
