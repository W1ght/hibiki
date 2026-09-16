// 真机探针：**直接驱动生产代码**（runner/lookup_ime_selection.cpp +
// runner/lookup_ime_tsf.cpp），证明
//   (1) 能枚举出人类可读的输入法列表 + 稳定 id
//   (2) 能按 id 切到**指定的那一个**（微信输入法 vs 微软拼音 —— 同一语言，
//       HKL 路线结构上做不到的那件事）
//   (3) 能还原
//   (4) 切换对**另一个进程**的影响（另起一个干净子进程读它自己的状态）
//   (5) 失去 / 重获前台后，选择还在不在 —— 这条决定 WM_ACTIVATE 语义
//
// **不接进 CMake**：它要抢前台、会改本机输入法状态，不能随构建跑。COM 那层
// （lookup_ime_tsf.cpp）没法单测，这两个探针就是它唯一的可复现证据。手动跑：
//
//   cd fushi/windows/runner/tests/probes
//   clang++ -std=c++17 -o lookup_ime_probe.exe lookup_ime_probe.cpp \
//     ../../lookup_ime_selection.cpp ../../lookup_ime_tsf.cpp \
//     -lole32 -loleaut32 -luuid
//   ./lookup_ime_probe.exe     # 退出码 0 = 跑完并且已还原到基线
//
// 本机没有 MSVC 命令行，用 llvm-mingw 的 clang++。跑完**一定**确认最后一行
// RESTORED_TO_BASELINE=1，否则用户的输入法被留在了错的地方。
#define _WIN32_WINNT 0x0A00

#include <windows.h>

#include <cstdarg>
#include <cstdio>
#include <string>
#include <vector>

#include "../../lookup_ime_selection.h"
#include "../../lookup_ime_tsf.h"

static FILE* g_out = nullptr;
static HWND g_wnd = nullptr;
static DWORD g_wnd_tid = 0;
static DWORD g_foreign_tid = 0;
static HWND g_foreign_wnd = nullptr;

static std::string Utf8(const std::wstring& w) {
  if (w.empty()) return {};
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0,
                              nullptr, nullptr);
  std::string s((size_t)n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr,
                      nullptr);
  return s;
}

static void Out(const char* fmt, ...) {
  char buf[8192];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  if (g_out) {
    fputs(buf, g_out);
    fflush(g_out);
  }
  fputs(buf, stdout);
  fflush(stdout);
}

static void Pump(int ms) {
  DWORD end = GetTickCount() + (DWORD)ms;
  MSG m;
  while (GetTickCount() < end) {
    while (PeekMessageW(&m, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&m);
      DispatchMessageW(&m);
    }
    Sleep(20);
  }
}

static bool ForceForeground(HWND h) {
  HWND fg = GetForegroundWindow();
  DWORD ftid = GetWindowThreadProcessId(fg, nullptr);
  DWORD mine = GetCurrentThreadId();
  AttachThreadInput(mine, ftid, TRUE);
  BringWindowToTop(h);
  ShowWindow(h, SW_SHOW);
  SetForegroundWindow(h);
  SetActiveWindow(h);
  AttachThreadInput(mine, ftid, FALSE);
  Pump(400);
  return GetForegroundWindow() == h;
}

// ---------------------------------------------------------------------------
// --sample：一个**全新的干净进程**，只打印它自己看到的 TSF 当前 profile 与 HKL。
// 用来证明 FORPROCESS 没有泄到别的进程 / 没有改会话默认。
// ---------------------------------------------------------------------------
static int RunSample() {
  SetConsoleOutputCP(CP_UTF8);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  TsfInputProcessorProfiles tsf;
  ImeProfile active;
  const bool ok = tsf.ActiveProfile(&active);
  printf("CHILD pid=%lu activeOk=%d active=\"%s\" id=%s hkl(self)=0x%08llX\n",
         (unsigned long)GetCurrentProcessId(), ok ? 1 : 0,
         ok ? Utf8(active.name).c_str() : "(none)",
         ok ? Utf8(EncodeImeProfileId(active)).c_str() : "(none)",
         (unsigned long long)(UINT_PTR)GetKeyboardLayout(0));
  fflush(stdout);
  // Release 必须排在 CoUninitialize 之前，否则段错误（生产侧同样的坑，见
  // lookup_ime_tsf.h / FlutterWindow::OnDestroy）。
  tsf.Shutdown();
  CoUninitialize();
  return 0;
}

static void RunChildSample(const char* label) {
  wchar_t self[MAX_PATH] = {};
  GetModuleFileNameW(nullptr, self, MAX_PATH);
  std::wstring cmd = L"\"";
  cmd += self;
  cmd += L"\" --sample";
  SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
  HANDLE r = nullptr, w = nullptr;
  if (!CreatePipe(&r, &w, &sa, 0)) return;
  SetHandleInformation(r, HANDLE_FLAG_INHERIT, 0);
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdOutput = w;
  si.hStdError = w;
  si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  PROCESS_INFORMATION pi{};
  std::vector<wchar_t> mutable_cmd(cmd.begin(), cmd.end());
  mutable_cmd.push_back(0);
  if (!CreateProcessW(nullptr, mutable_cmd.data(), nullptr, nullptr, TRUE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
    CloseHandle(r);
    CloseHandle(w);
    Out("    [%s] child spawn FAILED err=%lu\n", label, GetLastError());
    return;
  }
  CloseHandle(w);
  std::string text;
  char buf[512];
  DWORD got = 0;
  while (ReadFile(r, buf, sizeof(buf) - 1, &got, nullptr) && got > 0) {
    buf[got] = 0;
    text += buf;
  }
  CloseHandle(r);
  WaitForSingleObject(pi.hProcess, 3000);
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
  while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
    text.pop_back();
  }
  Out("    [%s] %s\n", label, text.c_str());
}

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
  return DefWindowProcW(h, m, w, l);
}

static TsfInputProcessorProfiles g_tsf;

static void Snapshot(const char* label) {
  ImeProfile active;
  const bool ok = g_tsf.ActiveProfile(&active);
  Out("  [%s]\n", label);
  Out("    GetActiveProfile ok=%d name=\"%s\"\n      id=%s\n", ok ? 1 : 0,
      ok ? Utf8(active.name).c_str() : "(none)",
      ok ? Utf8(EncodeImeProfileId(active)).c_str() : "(none)");
  Out("    GetKeyboardLayout(windowThread)=0x%08llX  "
      "GetKeyboardLayout(foreignProcThread %lu)=0x%08llX\n",
      (unsigned long long)(UINT_PTR)GetKeyboardLayout(g_wnd_tid),
      (unsigned long)g_foreign_tid,
      (unsigned long long)(UINT_PTR)GetKeyboardLayout(g_foreign_tid));
}

int main(int argc, char** argv) {
  if (argc > 1 && std::string(argv[1]) == "--sample") {
    return RunSample();
  }
  SetConsoleOutputCP(CP_UTF8);
  g_out = fopen("lookup_ime_probe.txt", "wb");

  // 前台是别人的窗口时记下它的线程，用来采样"另一个进程"。
  g_foreign_wnd = GetForegroundWindow();
  g_foreign_tid = GetWindowThreadProcessId(g_foreign_wnd, nullptr);
  DWORD foreign_pid = 0;
  GetWindowThreadProcessId(g_foreign_wnd, &foreign_pid);

  // 生产里 method channel handler 跑在 platform 线程 = 窗口线程，这里照做：
  // 窗口、消息循环、CoInitializeEx、所有 TSF 调用全在同一个线程上。
  WNDCLASSW wc{};
  wc.lpfnWndProc = WndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"FushiLookupImeProbe";
  RegisterClassW(&wc);
  g_wnd = CreateWindowExW(0, L"FushiLookupImeProbe", L"fushi lookup ime probe",
                          WS_OVERLAPPEDWINDOW, 100, 100, 420, 200, nullptr,
                          nullptr, wc.hInstance, nullptr);
  g_wnd_tid = GetCurrentThreadId();
  // 一个真的输入框，让 TSF 有东西可附着。
  HWND edit = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_BORDER,
                              10, 10, 380, 28, g_wnd, nullptr, wc.hInstance,
                              nullptr);

  HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  Out("window/platform thread tid=%lu hwnd=%p CoInitializeEx hr=0x%08lX\n",
      (unsigned long)g_wnd_tid, (void*)g_wnd, (unsigned long)hr);
  Out("foreign sample thread tid=%lu pid=%lu (whatever was foreground)\n",
      (unsigned long)g_foreign_tid, (unsigned long)foreign_pid);
  Out("(no ITfThreadMgr created -- production doesn't create one either)\n\n");

  const bool fg = ForceForeground(g_wnd);
  SetFocus(edit);
  Pump(400);
  Out("ForceForeground=%d\n\n", fg ? 1 : 0);

  // ---- 1) 枚举 ----
  Out("== TsfInputProcessorProfiles::EnumerateEnabled() ==\n");
  std::vector<ImeProfile> profiles = g_tsf.EnumerateEnabled();
  for (size_t i = 0; i < profiles.size(); ++i) {
    const ImeProfile& p = profiles[i];
    Out("  [%zu] name=\"%s\"\n       id=%s\n       lang=%s kind=%s\n", i,
        Utf8(p.name).c_str(), Utf8(EncodeImeProfileId(p)).c_str(),
        Utf8(BcpTagOfLangId(p.langid)).c_str(),
        p.kind == ImeProfileKind::kKeyboardLayout ? "keyboardLayout"
                                                  : "inputProcessor");
  }
  Out("  count=%zu\n\n", profiles.size());
  if (profiles.empty()) {
    Out("FATAL: nothing enumerated\n");
    return 2;
  }

  // 找出本机的关键目标。
  std::wstring zh_first, zh_second, ja_id;
  for (const ImeProfile& p : profiles) {
    const std::wstring id = EncodeImeProfileId(p);
    if (p.kind != ImeProfileKind::kInputProcessor) continue;
    if (p.langid == 0x0804) {
      if (zh_first.empty()) {
        zh_first = id;
      } else if (zh_second.empty()) {
        zh_second = id;
      }
    }
    if (p.langid == 0x0411 && ja_id.empty()) ja_id = id;
  }
  Out("targets: zh#1=%s\n         zh#2=%s\n         ja  =%s\n\n",
      Utf8(zh_first).c_str(), Utf8(zh_second).c_str(), Utf8(ja_id).c_str());

  ImeProfile baseline;
  const bool has_baseline = g_tsf.ActiveProfile(&baseline);
  Snapshot("BASELINE");
  RunChildSample("BASELINE child");
  Out("\n");

  LookupImeSwitcher switcher(&TsfInputProcessorProfiles::ActivateThunk, &g_tsf);

  // ---- 2) 按 id 切到**指定的**同语言输入法（两个 zh 轮流切）----
  if (!zh_first.empty() && !zh_second.empty()) {
    Out("A) setLookupIme(sourceId=zh#2) -- same language, DIFFERENT IME\n");
    LookupImeUpdate u =
        switcher.Activate(zh_second, L"zh-Hans", baseline, profiles);
    Out("   update=%d\n", (int)u);
    Pump(500);
    Snapshot("after A");
    RunChildSample("after A child");

    Out("\nB) setLookupIme(sourceId=zh#1) -- back to the other zh IME\n");
    ImeProfile now;
    g_tsf.ActiveProfile(&now);
    u = switcher.Activate(zh_first, L"zh-Hans", now, profiles);
    Out("   update=%d\n", (int)u);
    Pump(500);
    Snapshot("after B");
  } else {
    Out("A/B SKIPPED: fewer than two zh input processors enabled\n");
  }

  // ---- 3) 切到日语（跨语言）----
  Out("\nC) setLookupIme(sourceId=ja)\n");
  LookupImeUpdate u = switcher.Activate(ja_id, L"ja", baseline, profiles);
  Out("   update=%d\n", (int)u);
  Pump(500);
  Snapshot("after C");
  RunChildSample("after C child");

  // ---- 5) 失活 / 重获前台后，FORPROCESS 的选择还在不在 ----
  Out("\nD) give the foreground away and take it back (WM_ACTIVATE round trip)\n");
  if (g_foreign_wnd != nullptr) {
    DWORD mine = GetCurrentThreadId();
    AttachThreadInput(mine, g_foreign_tid, TRUE);
    SetForegroundWindow(g_foreign_wnd);
    AttachThreadInput(mine, g_foreign_tid, FALSE);
  }
  Pump(1200);
  Out("   (deactivated; fg is ours=%d)\n",
      GetForegroundWindow() == g_wnd ? 1 : 0);
  Snapshot("while inactive");
  ForceForeground(g_wnd);
  SetFocus(edit);
  Pump(800);
  Out("   (reactivated; fg is ours=%d)\n",
      GetForegroundWindow() == g_wnd ? 1 : 0);
  Snapshot("after reactivation");

  // ---- 4) 回落：id 不认识时按语言 ----
  Out("\nE) setLookupIme(sourceId=<uninstalled>, language=ja) -- fallback\n");
  switcher.Restore();
  Pump(400);
  ImeProfile now2;
  g_tsf.ActiveProfile(&now2);
  u = switcher.Activate(L"tsf:0411:{DEADBEEF-0000-0000-0000-000000000000}:"
                        L"{00000000-0000-0000-0000-000000000000}",
                        L"ja", now2, profiles);
  Out("   update=%d\n", (int)u);
  Pump(500);
  Snapshot("after E");

  // ---- 6) 键盘布局型 profile：ActivateProfile 的参数形状与 TIP 不同
  //         （clsid/guidProfile 传 GUID_NULL、hkl 传实值），单独验一次 ----
  std::wstring layout_id;
  for (const ImeProfile& p : profiles) {
    if (p.kind == ImeProfileKind::kKeyboardLayout) {
      layout_id = EncodeImeProfileId(p);
      break;
    }
  }
  if (!layout_id.empty()) {
    Out("\nF) setLookupIme(sourceId=<keyboard layout>) -- %s\n",
        Utf8(layout_id).c_str());
    ImeProfile now3;
    g_tsf.ActiveProfile(&now3);
    u = switcher.Activate(layout_id, L"", now3, profiles);
    Out("   update=%d\n", (int)u);
    Pump(500);
    Snapshot("after F");
  } else {
    Out("\nF SKIPPED: no enabled keyboard-layout profile\n");
  }

  // ---- 7) 还原 ----
  Out("\nRESTORE\n");
  u = switcher.Restore();
  Out("   update=%d\n", (int)u);
  Pump(800);
  Snapshot("AFTER RESTORE");
  RunChildSample("AFTER RESTORE child");
  Out("  baseline was ok=%d name=\"%s\" id=%s\n", has_baseline ? 1 : 0,
      Utf8(baseline.name).c_str(),
      Utf8(EncodeImeProfileId(baseline)).c_str());

  ImeProfile final_profile;
  const bool final_ok = g_tsf.ActiveProfile(&final_profile);
  const bool restored =
      final_ok && has_baseline &&
      EncodeImeProfileId(final_profile) == EncodeImeProfileId(baseline);
  Out("\nRESTORED_TO_BASELINE=%d\n", restored ? 1 : 0);

  // 把前台还给原来的窗口，别把用户的焦点留在探针上。
  if (g_foreign_wnd != nullptr) {
    DWORD mine = GetCurrentThreadId();
    AttachThreadInput(mine, g_foreign_tid, TRUE);
    SetForegroundWindow(g_foreign_wnd);
    AttachThreadInput(mine, g_foreign_tid, FALSE);
  }
  DestroyWindow(g_wnd);
  Pump(200);
  g_tsf.Shutdown();  // 必须先于 CoUninitialize，见 lookup_ime_tsf.h
  CoUninitialize();
  if (g_out) fclose(g_out);
  return restored ? 0 : 3;
}
