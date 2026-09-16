// 探针：视频页查词后 Win32 键盘焦点 / 鼠标捕获落在哪个 HWND（热槽 vs 小内存模式对照）。
//
// 用户报告（2026-09-16）：Windows 看番时「进视频界面以后随机卡死：导航条消失后视频仍在播，
// 但键鼠都无法操作」，开小内存模式后消失。小内存模式对视频页唯一差异 = 是否常驻一个
// 屏外隐藏的查词热槽 WebView2（composition 模式，宿主是主窗口的隐藏 owned 顶层窗
// `CustomPlatformView`，内含 `Chrome_WidgetWin_0`）。本探针在真 app 上走原始路径并逐步
// 打印 Win32 真值：GetFocus / GetCapture / GetActiveWindow / GUITHREADINFO，以及 Flutter
// 侧 primaryFocus，用来判定「键鼠失灵」是否是 OS 焦点 / 捕获被隐藏 WebView2 窗口拿走。
//
// 运行（fushi/ 下）：
//   .\tool\run_windows_itest.ps1 integration_test/video_warm_slot_win32_focus_probe_itest.dart -Visible
//
// 2026-09-16 两轮结论（BUG-2572，未复现）：热槽 / 小内存两态下 GetFocus 恒 FLUTTERVIEW、
// GetCapture 恒空、OS 空格键都能到 Flutter，暂停态 5s 空闲帧数与 CPU 无差异；投给
// FLUTTERVIEW 的 WM_MOUSEMOVE 两态都唤不起控制条（离屏 no-activate 窗口里该注入路径
// 本身不通，阳性对照失败），鼠标链路仍待前台真机验证。这是复现脚手架，不是回归测试。
import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

import 'helpers/library_fixture.dart';
import 'helpers/media_fixtures.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

// ── Win32 FFI ────────────────────────────────────────────────────────────────

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final int Function() _getFocus = _user32
    .lookupFunction<IntPtr Function(), int Function()>('GetFocus');
final int Function() _getCapture = _user32
    .lookupFunction<IntPtr Function(), int Function()>('GetCapture');
final int Function() _getActiveWindow = _user32
    .lookupFunction<IntPtr Function(), int Function()>('GetActiveWindow');
final int Function() _getForegroundWindow = _user32
    .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
final int Function() _getCurrentThreadId = _kernel32
    .lookupFunction<Uint32 Function(), int Function()>('GetCurrentThreadId');
final int Function(int, Pointer<Utf16>, int) _getClassNameW = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Int32),
      int Function(int, Pointer<Utf16>, int)
    >('GetClassNameW');
final int Function(int, Pointer<Uint32>) _getWindowThreadProcessId = _user32
    .lookupFunction<
      Uint32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetWindowThreadProcessId');
final int Function(int, int) _getAncestor = _user32
    .lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>(
      'GetAncestor',
    );
final int Function(int, int) _getWindow = _user32
    .lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>(
      'GetWindow',
    );
final int Function(int) _isWindowVisible = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'IsWindowVisible',
    );
final int Function(int, Pointer<_Rect>) _getWindowRect = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<_Rect>),
      int Function(int, Pointer<_Rect>)
    >('GetWindowRect');
final int Function(int, Pointer<_GuiThreadInfo>) _getGUIThreadInfo = _user32
    .lookupFunction<
      Int32 Function(Uint32, Pointer<_GuiThreadInfo>),
      int Function(int, Pointer<_GuiThreadInfo>)
    >('GetGUIThreadInfo');
final int Function(int, int, int, int) _postMessageW = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
      int Function(int, int, int, int)
    >('PostMessageW');

final class _Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

final class _GuiThreadInfo extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int flags;
  @IntPtr()
  external int hwndActive;
  @IntPtr()
  external int hwndFocus;
  @IntPtr()
  external int hwndCapture;
  @IntPtr()
  external int hwndMenuOwner;
  @IntPtr()
  external int hwndMoveSize;
  @IntPtr()
  external int hwndCaret;
  external _Rect rcCaret;
}

String _cls(int hwnd) {
  if (hwnd == 0) return 'NULL';
  final Pointer<Utf16> buf = calloc<Uint16>(256).cast<Utf16>();
  try {
    final int n = _getClassNameW(hwnd, buf, 256);
    return n > 0 ? buf.toDartString(length: n) : '?';
  } finally {
    calloc.free(buf);
  }
}

/// `0x1234(Chrome_WidgetWin_0 <root:CustomPlatformView vis=0 (x,y)-(x,y)>)`
String _hw(int hwnd) {
  if (hwnd == 0) return 'NULL';
  final int root = _getAncestor(hwnd, 2); // GA_ROOT
  final Pointer<_Rect> r = calloc<_Rect>();
  try {
    _getWindowRect(root, r);
    final int owner = _getWindow(root, 4); // GW_OWNER
    return '0x${hwnd.toRadixString(16)}(${_cls(hwnd)} <root:${_cls(root)} '
        'vis=${_isWindowVisible(root)} owner=${_cls(owner)} '
        '(${r.ref.left},${r.ref.top})-(${r.ref.right},${r.ref.bottom})>)';
  } finally {
    calloc.free(r);
  }
}

void _dumpWin32(String tag) {
  final Pointer<_GuiThreadInfo> info = calloc<_GuiThreadInfo>();
  try {
    info.ref.cbSize = sizeOf<_GuiThreadInfo>();
    final int ok = _getGUIThreadInfo(_getCurrentThreadId(), info);
    debugPrint(
      '[win32] $tag tid=${_getCurrentThreadId()} guiInfoOk=$ok\n'
      '[win32]   GetFocus=${_hw(_getFocus())}\n'
      '[win32]   GetCapture=${_hw(_getCapture())}\n'
      '[win32]   GetActiveWindow=${_hw(_getActiveWindow())}\n'
      '[win32]   Foreground=${_hw(_getForegroundWindow())}\n'
      '[win32]   gti.active=${_hw(info.ref.hwndActive)} '
      'gti.focus=${_hw(info.ref.hwndFocus)} '
      'gti.capture=${_hw(info.ref.hwndCapture)}',
    );
  } finally {
    calloc.free(info);
  }
}

final int Function(
  int,
  Pointer<_FileTime>,
  Pointer<_FileTime>,
  Pointer<_FileTime>,
  Pointer<_FileTime>,
)
_getProcessTimes = _kernel32
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Pointer<_FileTime>,
        Pointer<_FileTime>,
        Pointer<_FileTime>,
        Pointer<_FileTime>,
      ),
      int Function(
        int,
        Pointer<_FileTime>,
        Pointer<_FileTime>,
        Pointer<_FileTime>,
        Pointer<_FileTime>,
      )
    >('GetProcessTimes');
final int Function() _getCurrentProcess = _kernel32
    .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');

final class _FileTime extends Struct {
  @Uint32()
  external int low;
  @Uint32()
  external int high;
  int get value => (high << 32) | low;
}

/// 进程累计 CPU 时间（user + kernel，毫秒）。
int _processCpuMs() {
  final Pointer<_FileTime> c = calloc<_FileTime>(4);
  try {
    _getProcessTimes(_getCurrentProcess(), c, c + 1, c + 2, c + 3);
    return ((c + 2).ref.value + (c + 3).ref.value) ~/ 10000;
  } finally {
    calloc.free(c);
  }
}

/// 把一条真实 Win32 `WM_MOUSEMOVE` 投给 Flutter 视图 HWND（客户区物理像素坐标）：
/// 走引擎 → 框架 hover → media_kit `MouseRegion.onHover` 的完整链路，是 OS 鼠标移动
/// 在 app 内的真实投递形态（只绕过 OS 层的窗口命中）。
void _postMouseMove(int hwnd, int x, int y) {
  const int wmMouseMove = 0x0200;
  _postMessageW(hwnd, wmMouseMove, 0, (y << 16) | (x & 0xFFFF));
}

int _flutterViewThread(int hwnd) {
  final Pointer<Uint32> pid = calloc<Uint32>();
  try {
    return _getWindowThreadProcessId(hwnd, pid);
  } finally {
    calloc.free(pid);
  }
}

// ── 测试本体 ──────────────────────────────────────────────────────────────────

const int _kMouseDevice = 7;
const int _kMousePointer = 91;

Future<void> _injectClick(WidgetTester tester, Offset pos) async {
  final GestureBinding gb = GestureBinding.instance;
  gb.handlePointerEvent(
    PointerHoverEvent(
      position: pos,
      kind: PointerDeviceKind.mouse,
      device: _kMouseDevice,
    ),
  );
  await tester.pump(const Duration(milliseconds: 60));
  gb.handlePointerEvent(
    PointerDownEvent(
      position: pos,
      kind: PointerDeviceKind.mouse,
      device: _kMouseDevice,
      pointer: _kMousePointer,
      buttons: kPrimaryMouseButton,
    ),
  );
  await tester.pump(const Duration(milliseconds: 90));
  gb.handlePointerEvent(
    PointerUpEvent(
      position: pos,
      kind: PointerDeviceKind.mouse,
      device: _kMouseDevice,
      pointer: _kMousePointer,
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _injectHover(WidgetTester tester, Offset pos) async {
  GestureBinding.instance.handlePointerEvent(
    PointerHoverEvent(
      position: pos,
      kind: PointerDeviceKind.mouse,
      device: _kMouseDevice,
    ),
  );
  await tester.pump(const Duration(milliseconds: 120));
}

/// 屏内（left < 视口宽）的弹窗 WebView；热槽停在屏外故不算。
Rect? _visiblePopupRect(WidgetTester tester) {
  final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
  for (final Element e in find.byType(DictionaryPopupWebView).evaluate()) {
    final RenderObject? ro = e.renderObject;
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) continue;
    final Rect r = ro.localToGlobal(Offset.zero) & ro.size;
    if (r.left < screen.width && r.width > 10 && r.height > 10) return r;
  }
  return null;
}

Future<void> _runScenario(
  WidgetTester tester, {
  required String tag,
  required AppModel appModel,
  required VideoBookRepository repo,
  required String bookUid,
  required bool lowMemory,
}) async {
  await appModel.setLowMemoryMode(lowMemory);
  await tester.pump(const Duration(milliseconds: 300));
  debugPrint('[probe:$tag] lowMemoryMode=${appModel.lowMemoryMode}');

  final NavigatorState navigator = tester.state<NavigatorState>(
    find.byType(Navigator).first,
  );
  unawaited(
    navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VideoFushiPage(bookUid: bookUid, repo: repo),
      ),
    ),
  );

  VideoFushiTestHooks hooks() =>
      tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
          as VideoFushiTestHooks;

  bool ready = false;
  for (int i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (find.byType(VideoFushiPage).evaluate().isNotEmpty &&
        hooks().debugPositionMs != null) {
      ready = true;
      break;
    }
  }
  expect(ready, isTrue, reason: '[$tag] video controller should load');
  await hooks().debugPlay();
  await tester.pump(const Duration(seconds: 3));

  final FocusNode videoNode = tester
      .widget<Video>(find.byType(Video))
      .focusNode!;
  for (int i = 0; i < 20 && !videoNode.hasFocus; i++) {
    videoNode.requestFocus();
    await tester.pump(const Duration(milliseconds: 150));
  }
  final int flutterViewHwnd = _getFocus();
  debugPrint(
    '[probe:$tag] flutterView thread='
    '${_flutterViewThread(flutterViewHwnd)} dartThread=${_getCurrentThreadId()} '
    'popupWebViews=${find.byType(DictionaryPopupWebView).evaluate().length} '
    'videoNode.hasFocus=${videoNode.hasFocus} '
    'primary=${FocusManager.instance.primaryFocus?.debugLabel}',
  );
  _dumpWin32('[$tag] 0.before-lookup');

  // Enter 进字幕光标 → Enter 对光标字查词（videoEnterCaret 默认键）。
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  Rect? popupRect;
  for (int i = 0; i < 40 && popupRect == null; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    popupRect = _visiblePopupRect(tester);
  }
  debugPrint(
    '[probe:$tag] popupRect=$popupRect '
    'popupWebViews=${find.byType(DictionaryPopupWebView).evaluate().length} '
    'primary=${FocusManager.instance.primaryFocus?.debugLabel}',
  );
  expect(popupRect, isNotNull, reason: '[$tag] lookup popup should open');
  await tester.pump(const Duration(seconds: 2));
  _dumpWin32('[$tag] 1.popup-open');

  // 把一次真实鼠标点击经 fork 转发进 WebView2（用户在弹窗里点词 / 滚动前的常规动作）。
  await _injectClick(tester, popupRect!.center);
  await tester.pump(const Duration(milliseconds: 800));
  debugPrint(
    '[probe:$tag] after click: '
    'primary=${FocusManager.instance.primaryFocus?.debugLabel} '
    'videoNode.hasFocus=${videoNode.hasFocus}',
  );
  _dumpWin32('[$tag] 2.after-click-into-webview2');

  // Esc 关弹窗（热槽模式：停到屏外保留；小内存模式：销毁）。
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  for (int i = 0; i < 20 && _visiblePopupRect(tester) != null; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  // 光标环若仍在，再按一次 Esc 退出光标态。
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump(const Duration(seconds: 1));
  debugPrint(
    '[probe:$tag] after dismiss: visiblePopup=${_visiblePopupRect(tester)} '
    'popupWebViews=${find.byType(DictionaryPopupWebView).evaluate().length} '
    'primary=${FocusManager.instance.primaryFocus?.debugLabel} '
    'videoNode.hasFocus=${videoNode.hasFocus} '
    'controlsVisible=${hooks().debugControlsVisible} '
    'playing=${hooks().debugIsPlaying}',
  );
  _dumpWin32('[$tag] 3.after-dismiss');

  // 等控制条自动隐藏（2s），再看 OS 鼠标移动（真 WM_MOUSEMOVE）能否唤回、以及 OS 焦点
  // 窗口收到空格会不会到 Flutter（把 WM_KEYDOWN 投给 GetFocus() —— OS 对真实按键的投递目标）。
  await tester.pump(const Duration(seconds: 4));
  debugPrint(
    '[probe:$tag] after idle: controlsVisible=${hooks().debugControlsVisible}',
  );
  final Rect videoRect = tester.getRect(find.byType(Video));
  final double dpr = tester.view.devicePixelRatio;
  Future<bool> osMouseWake(String why) async {
    final Offset c = videoRect.center;
    for (int i = 0; i < 4; i++) {
      _postMouseMove(
        flutterViewHwnd,
        ((c.dx + i * 6 - 9) * dpr).round(),
        ((c.dy + (i.isEven ? 4 : -4)) * dpr).round(),
      );
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.pump(const Duration(milliseconds: 400));
    final bool visible = hooks().debugControlsVisible;
    debugPrint('[probe:$tag] OS-mousemove ($why): controlsVisible=$visible');
    return visible;
  }

  await _injectHover(tester, videoRect.center + const Offset(3, 3));
  await tester.pump(const Duration(milliseconds: 300));
  debugPrint(
    '[probe:$tag] after flutter-hover: '
    'controlsVisible=${hooks().debugControlsVisible}',
  );
  final bool wakeAfterDismiss = await osMouseWake('after dismiss');

  // 空闲帧率 / CPU：视频暂停、无动画时，热槽（隐藏 WebView2 + WGC 泵）是否仍在驱动帧。
  await hooks().debugPause();
  await tester.pump(const Duration(seconds: 3));
  int frames = 0;
  void onTimings(List<FrameTiming> t) => frames += t.length;
  SchedulerBinding.instance.addTimingsCallback(onTimings);
  final int cpu0 = _processCpuMs();
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < const Duration(seconds: 5)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
  }
  final int cpu1 = _processCpuMs();
  SchedulerBinding.instance.removeTimingsCallback(onTimings);
  debugPrint(
    '[probe:$tag] idle(paused) 5s: frames=$frames '
    'cpuMs=${cpu1 - cpu0} playing=${hooks().debugIsPlaying}',
  );
  await hooks().debugPlay();

  // 长空闲后再试 OS 鼠标唤醒（模拟「看了一会儿导航条消失后动鼠标」）。
  for (int i = 0; i < 20; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
  debugPrint(
    '[probe:$tag] after 20s idle: controlsVisible=${hooks().debugControlsVisible} '
    'playing=${hooks().debugIsPlaying}',
  );
  final bool wakeAfterIdle = await osMouseWake('after 20s idle');
  debugPrint(
    '[probe:$tag] SUMMARY wakeAfterDismiss=$wakeAfterDismiss '
    'wakeAfterIdle=$wakeAfterIdle',
  );

  final bool playingBefore = hooks().debugIsPlaying;
  final int focusHwnd = _getFocus();
  const int wmKeyDown = 0x0100, wmKeyUp = 0x0101, vkSpace = 0x20;
  _postMessageW(focusHwnd, wmKeyDown, vkSpace, 0x00390001);
  _postMessageW(focusHwnd, wmKeyUp, vkSpace, 0xC0390001);
  await tester.pump(const Duration(milliseconds: 1500));
  debugPrint(
    '[probe:$tag] OS-space to GetFocus=${_hw(focusHwnd)}: '
    'playing $playingBefore -> ${hooks().debugIsPlaying}',
  );
  _postMessageW(flutterViewHwnd, wmKeyDown, vkSpace, 0x00390001);
  _postMessageW(flutterViewHwnd, wmKeyUp, vkSpace, 0xC0390001);
  await tester.pump(const Duration(milliseconds: 1500));
  debugPrint(
    '[probe:$tag] OS-space to FLUTTERVIEW=${_hw(flutterViewHwnd)}: '
    'playing now ${hooks().debugIsPlaying}',
  );
  _dumpWin32('[$tag] 4.end');

  navigator.pop();
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'probe: win32 focus/capture after video lookup (warm slot vs low memory)',
    (WidgetTester tester) async {
      final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        errors.add(details);
        debugPrint('[probe] flutter error: ${details.exceptionAsString()}');
      };
      try {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue);
        await tester.pump(const Duration(seconds: 2));
        final AppModel appModel = await readyAppModel(tester);
        expect(await seedDictionary(tester), isTrue, reason: 'dictionary seed');

        final Directory tmp = await getTemporaryDirectory();
        final Directory dir = Directory(
          '${tmp.path}${Platform.pathSeparator}warmslot_probe',
        )..createSync(recursive: true);
        final String videoPath =
            '${dir.path}${Platform.pathSeparator}probe.mp4';
        if (!File(videoPath).existsSync()) {
          await generateTestVideo(
            outPath: videoPath,
            duration: const Duration(seconds: 90),
          );
        }
        File(
          '${dir.path}${Platform.pathSeparator}probe.srt',
        ).writeAsStringSync('1\n00:00:00,000 --> 00:01:29,000\n猫が好きです\n\n');

        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp).first),
        );
        final AppModel model = container.read(appProvider);
        expect(identical(model, appModel), isTrue);
        final VideoBookRepository repo = VideoBookRepository(appModel.database);
        const String bookUid = 'video/warmslot-probe';
        await repo.saveVideoBook(
          VideoBooksCompanion(
            bookUid: const Value(bookUid),
            title: const Value('warm slot probe'),
            videoPath: Value(videoPath),
          ),
        );

        await _runScenario(
          tester,
          tag: 'warm',
          appModel: appModel,
          repo: repo,
          bookUid: bookUid,
          lowMemory: false,
        );
        await _runScenario(
          tester,
          tag: 'lowmem',
          appModel: appModel,
          repo: repo,
          bookUid: bookUid,
          lowMemory: true,
        );
        await appModel.setLowMemoryMode(false);
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
  );
}
