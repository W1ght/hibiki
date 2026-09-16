#ifndef RUNNER_LOOKUP_IME_TSF_H_
#define RUNNER_LOOKUP_IME_TSF_H_

#include <windows.h>

#include <msctf.h>

#include <string>
#include <vector>

#include "lookup_ime_selection.h"

// `ITfInputProcessorProfileMgr` 的薄封装：枚举 / 读当前 / 激活。纯逻辑（id 编解码、
// 回落、还原记账）在 lookup_ime_selection.h，那边随构建跑 gate 测试；这里只剩不可
// 单测的 COM 调用。
//
// 线程性（实测 2026-09-16，结论不稳定，所以按最保守的用）：`ActivateProfile` 的效果
// **至少**落在调用线程上；是否传播到进程内其它线程两次实验结论相反（前台时全进程
// 生效，非前台时只有调用线程的 `GetKeyboardLayout` 变了）。所以必须在**拥有目标窗口
// 且有消息循环的线程**上调用——我们的 method channel handler 正好跑在 platform 线程
// （= 窗口线程）。不要从别的线程碰这个对象。
//
// 前置条件：调用线程已经 `CoInitializeEx(COINIT_APARTMENTTHREADED)`。
// runner/main.cpp 在 platform 线程上已经做了，**不需要**额外建 `ITfThreadMgr`。
class TsfInputProcessorProfiles {
 public:
  TsfInputProcessorProfiles() = default;
  ~TsfInputProcessorProfiles();

  TsfInputProcessorProfiles(const TsfInputProcessorProfiles&) = delete;
  TsfInputProcessorProfiles& operator=(const TsfInputProcessorProfiles&) =
      delete;

  // 懒创建 COM 对象。失败只试一次（TSF 不在就是不在，每次查词重试没有意义）。
  bool EnsureAvailable();

  // 放掉持有的 COM 接口。**必须在 `CoUninitialize()` 之前调用。**
  //
  // runner/main.cpp 里 `FlutterWindow window` 是 wWinMain 的栈上局部，析构发生在
  // `::CoUninitialize()` **之后**——那时再 Release 会直接段错误（本机复现：
  // tests/probes 下把 Release 挪到 CoUninitialize 之后必崩，挪回去必活）。所以
  // FlutterWindow::OnDestroy() 里显式调这个，不能只靠析构兜底。
  //
  // 调用后本对象进入"不可用"状态，不会再重新创建 COM 对象。
  void Shutdown();

  // 用户语言列表里**已启用**的键盘类 profile，按系统枚举顺序。
  //
  // 三层过滤，每层都对应一种会真正坑到用户的条目：
  //   - `GUID_TFCAT_TIP_KEYBOARD` 之外的 TIP（触控输入更正 / Ink / 语音识别）切过去
  //     根本不是输入法；`EnumProfiles(0)` 会连它们一起吐出来，langid 还是 0。
  //   - 没有 `TF_IPP_FLAG_ENABLED` 的：已注册但用户没把它加进语言列表（本机的微软
  //     五笔、繁中那一堆）。列给用户选 = 列了一堆他没装的东西。
  //   - 编不出稳定 id 的：选了也存不下来。
  std::vector<ImeProfile> EnumerateEnabled();

  // 此刻生效的键盘类 profile。读不到时 *out 保持不动并返回 false。
  //
  // 注意：实测 `GetActiveProfile` 不是干净的全局读（出现过「窗口线程切了、主线程
  // 读到旧值」），**别拿它单独当生效判据**。这里只用它取「进入查词前的基线」，
  // 那个场景下我们本来就没在切。
  bool ActiveProfile(ImeProfile* out);

  // 切到 profile，作用域 `TF_IPPMF_FORPROCESS`。
  //
  // 为什么是 FORPROCESS：剩下几个全不能用——`dwFlags=0` 直接 `E_INVALIDARG`
  // （TSF 没有 per-thread 模式），`TF_IPPMF_FORSESSION` 是显式的会话级切换，
  // `TF_IPPMF_ENABLEPROFILE`/`DISABLEPROFILE` 改的是持久注册状态（= 替用户改系统
  // 配置）。
  //
  // **FORPROCESS 不代表进程隔离。** 本机 A/B 实测（2026-09-16）：切过去之后不还原
  // 就把前台交给别的窗口，那个进程的线程 HKL 会跟着变；先还原再交出前台就不会。
  // 细节与残留见 lookup_ime_selection.h 第 3 条。调用方必须自己负责还原。
  bool Activate(const ImeProfile& profile);

  // 给 LookupImeSwitcher 当 ActivateImeProfileFn 用。
  static bool ActivateThunk(const ImeProfile& profile, void* context);

 private:
  ITfInputProcessorProfiles* profiles_ = nullptr;
  ITfInputProcessorProfileMgr* manager_ = nullptr;
  bool attempted_ = false;
};

// LANGID → BCP-47（`zh-CN` / `ja-JP`…）。取不到返回空串。
std::wstring BcpTagOfLangId(LANGID langid);

#endif  // RUNNER_LOOKUP_IME_TSF_H_
