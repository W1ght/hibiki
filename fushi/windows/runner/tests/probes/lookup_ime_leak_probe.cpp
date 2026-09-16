// 对照实验：TF_IPPMF_FORPROCESS 到底泄不泄到别的进程？
//
// 背景：改造前的假设是「FORPROCESS 不外泄到别的进程（实测另一进程 HKL 全程不变）」。
// lookup_ime_probe 跑出来的 D) 段与之矛盾——把前台交还给别的窗口之后，那个进程
// 线程的 HKL 变成了 0x04110411。本文件把它拆成 A/B 两组，判「restore 到底还需不
// 需要」。
//
// 结论（2026-09-16 实测）：需要。A 组（切了不还原就交出前台）泄漏，B 组（先还原
// 再交出前台）不泄漏。所以 flutter_window.cpp 的 WM_ACTIVATE 还原一段留着。早先
// 「不外泄」的观察只覆盖了「对方一直待在后台」这一种情形。
//
// 同样**不接进 CMake**（抢前台 + 改本机输入法状态）。手动跑：
//   cd fushi/windows/runner/tests/probes
//   clang++ -std=c++17 -o lookup_ime_leak_probe.exe lookup_ime_leak_probe.cpp \
//     ../../lookup_ime_selection.cpp ../../lookup_ime_tsf.cpp \
//     -lole32 -loleaut32 -luuid
//   ./lookup_ime_leak_probe.exe   # 退出码 0 = 跑完并且已还原到基线
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
static HWND g_edit = nullptr;
static DWORD g_wnd_tid = 0;
static DWORD g_foreign_tid = 0;
static HWND g_foreign_wnd = nullptr;
static TsfInputProcessorProfiles g_tsf;

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

static void GiveForegroundAway() {
  if (g_foreign_wnd == nullptr) return;
  DWORD mine = GetCurrentThreadId();
  AttachThreadInput(mine, g_foreign_tid, TRUE);
  BringWindowToTop(g_foreign_wnd);
  SetForegroundWindow(g_foreign_wnd);
  SetActiveWindow(g_foreign_wnd);
  AttachThreadInput(mine, g_foreign_tid, FALSE);
  Pump(1500);
}

static int RunSample() {
  SetConsoleOutputCP(CP_UTF8);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  TsfInputProcessorProfiles tsf;
  ImeProfile active;
  const bool ok = tsf.ActiveProfile(&active);
  printf("freshProcess active=\"%s\" hkl=0x%08llX",
         ok ? Utf8(active.name).c_str() : "(none)",
         (unsigned long long)(UINT_PTR)GetKeyboardLayout(0));
  fflush(stdout);
  // Release 必须排在 CoUninitialize 之前，否则段错误（生产侧同样的坑，见
  // lookup_ime_tsf.h / FlutterWindow::OnDestroy）。
  tsf.Shutdown();
  CoUninitialize();
  return 0;
}

static void ChildSample(const char* label) {
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
  PROCESS_INFORMATION pi{};
  std::vector<wchar_t> mutable_cmd(cmd.begin(), cmd.end());
  mutable_cmd.push_back(0);
  if (!CreateProcessW(nullptr, mutable_cmd.data(), nullptr, nullptr, TRUE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
    CloseHandle(r);
    CloseHandle(w);
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
  Out("      %s: %s\n", label, text.c_str());
}

static void Sample(const char* label) {
  ImeProfile active;
  const bool ok = g_tsf.ActiveProfile(&active);
  Out("    %-28s ours(active)=\"%s\" ourHkl=0x%08llX  FOREIGN "
      "hkl(tid %lu)=0x%08llX\n",
      label, ok ? Utf8(active.name).c_str() : "(none)",
      (unsigned long long)(UINT_PTR)GetKeyboardLayout(g_wnd_tid),
      (unsigned long)g_foreign_tid,
      (unsigned long long)(UINT_PTR)GetKeyboardLayout(g_foreign_tid));
}

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
  return DefWindowProcW(h, m, w, l);
}

int main(int argc, char** argv) {
  if (argc > 1 && std::string(argv[1]) == "--sample") return RunSample();
  SetConsoleOutputCP(CP_UTF8);
  g_out = fopen("lookup_ime_leak_probe.txt", "wb");

  g_foreign_wnd = GetForegroundWindow();
  g_foreign_tid = GetWindowThreadProcessId(g_foreign_wnd, nullptr);

  WNDCLASSW wc{};
  wc.lpfnWndProc = WndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"FushiLookupImeLeakProbe";
  RegisterClassW(&wc);
  g_wnd = CreateWindowExW(0, L"FushiLookupImeLeakProbe", L"leak probe",
                          WS_OVERLAPPEDWINDOW, 120, 120, 420, 180, nullptr,
                          nullptr, wc.hInstance, nullptr);
  g_edit = CreateWindowExW(0, L"EDIT", L"",
                           WS_CHILD | WS_VISIBLE | WS_BORDER, 10, 10, 380, 28,
                           g_wnd, nullptr, wc.hInstance, nullptr);
  g_wnd_tid = GetCurrentThreadId();
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  ForceForeground(g_wnd);
  SetFocus(g_edit);
  Pump(400);

  std::vector<ImeProfile> profiles = g_tsf.EnumerateEnabled();
  ImeProfile baseline;
  if (!g_tsf.ActiveProfile(&baseline)) {
    Out("FATAL no baseline\n");
    return 2;
  }
  std::wstring ja_id;
  for (const ImeProfile& p : profiles) {
    if (p.langid == 0x0411 && p.kind == ImeProfileKind::kInputProcessor) {
      ja_id = EncodeImeProfileId(p);
    }
  }
  Out("baseline=\"%s\"  ja=%s\n  foreign tid=%lu\n\n",
      Utf8(baseline.name).c_str(), Utf8(ja_id).c_str(),
      (unsigned long)g_foreign_tid);
  Sample("start");
  ChildSample("fresh process at start");

  LookupImeSwitcher switcher(&TsfInputProcessorProfiles::ActivateThunk, &g_tsf);

  Out("\n== GROUP A: 切到日语，**不还原**就把前台交出去 ==\n");
  switcher.Activate(ja_id, L"ja", baseline, profiles);
  Pump(600);
  Sample("after activate (fg=ours)");
  ChildSample("fresh process while ja active");
  GiveForegroundAway();
  Sample("after giving fg away");
  ChildSample("fresh process after fg away");
  Out("    >>> FOREIGN hkl 变成 0x0411 = 泄到了别的应用\n");

  Out("\n== 清场：拿回前台并还原 ==\n");
  ForceForeground(g_wnd);
  SetFocus(g_edit);
  Pump(400);
  switcher.Restore();
  Pump(600);
  Sample("after restore (fg=ours)");
  GiveForegroundAway();
  Sample("after giving fg away");
  ForceForeground(g_wnd);
  SetFocus(g_edit);
  Pump(400);

  Out("\n== GROUP B: 切到日语，**先还原再**把前台交出去（= WM_ACTIVATE 语义）==\n");
  switcher.Activate(ja_id, L"ja", baseline, profiles);
  Pump(600);
  Sample("after activate (fg=ours)");
  switcher.Restore();  // WA_INACTIVE 时做的事
  Pump(600);
  Sample("after restore (still fg=ours)");
  GiveForegroundAway();
  Sample("after giving fg away");
  ChildSample("fresh process after fg away");
  Out("    >>> FOREIGN hkl 若仍是基线 = 还原确实挡住了泄漏\n");

  ForceForeground(g_wnd);
  SetFocus(g_edit);
  Pump(400);
  switcher.Restore();
  Pump(400);
  ImeProfile final_profile;
  const bool ok = g_tsf.ActiveProfile(&final_profile);
  const bool restored = ok && EncodeImeProfileId(final_profile) ==
                                  EncodeImeProfileId(baseline);
  Out("\nFINAL ours=\"%s\" RESTORED_TO_BASELINE=%d\n",
      ok ? Utf8(final_profile.name).c_str() : "(none)", restored ? 1 : 0);
  GiveForegroundAway();
  Sample("final foreign");
  ChildSample("final fresh process");

  DestroyWindow(g_wnd);
  Pump(200);
  g_tsf.Shutdown();  // 必须先于 CoUninitialize，见 lookup_ime_tsf.h
  CoUninitialize();
  if (g_out) fclose(g_out);
  return restored ? 0 : 3;
}
