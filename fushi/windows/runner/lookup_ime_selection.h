#ifndef RUNNER_LOOKUP_IME_SELECTION_H_
#define RUNNER_LOOKUP_IME_SELECTION_H_

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

// 查词输入框的输入法（Windows / TSF）。用户在设置里选了**具体输入法**（或只选了
// 语言），打开查词页面时切过去，离开时切回来。
//
// 为什么不是 HKL：现代 TSF 输入法根本不注册 HKL。本机实测（2026-09-16）
// `GetKeyboardLayoutList` 只返回 3 个纯键盘布局（zh-CN / en-US / ja-JP），
// 微信输入法 / 微软拼音 / 微软五笔 / 日语 MS-IME 的 `hkl` 与 `hklSubstitute`
// **全是 0x00000000**，整个语言共用该语言的布局 HKL。按 HKL 连「切到哪个中文
// 输入法」都表达不了，只能经 `ITfInputProcessorProfileMgr`。
//
// 本文件是**纯逻辑**：id 编解码、回落决策、还原记账。真正的 COM 调用在
// lookup_ime_tsf.h，这样这套状态机能随每次 Windows runner 构建被 gate 测试真跑
// （tests/lookup_ime_selection_test.cpp）。
//
// 三条硬约束：
//
// 1) 只在**已启用**（`TF_IPP_FLAG_ENABLED`）的 profile 里找，绝不注册/启用新的。
//    `TF_IPPMF_ENABLEPROFILE` / `DISABLEPROFILE` 改的是持久注册状态 = 替用户改系统
//    配置，查词功能不该做。找不到就什么都不做（kUnavailable）。
//
// 2) 激活一律用 `TF_IPPMF_FORPROCESS`（见 lookup_ime_tsf.h）。它是唯一**能用**的
//    作用域：`dwFlags=0` 直接 `E_INVALIDARG`（TSF 没有 per-thread 模式），
//    `TF_IPPMF_ENABLEPROFILE`/`DISABLEPROFILE` 改的是持久注册状态（= 替用户改系统
//    配置）。但它**不等于进程隔离**——见第 3 条。
//
// 3) 必须记住进入查词前的 profile，并在离开查词 / 窗口失活时还原。
//
//    别信「FORPROCESS 就不会漏到别的应用」：本机 A/B 实测（2026-09-16，
//    .codex-tmp/probe_lookup_ime/probe_leak.cpp）——
//      A 组 切日语后**不还原**就把前台交给别的窗口 → 那个进程线程的 HKL 变成
//        0x04110411（真的漏了）；期间新起的任何进程也直接是日语。
//      B 组 切日语后**先还原再**交出前台 → 对方全程 0x08040804。
//    早先「另一进程 HKL 全程不变」的观察只覆盖了「对方一直待在后台」这一种情形。
//    所以还原不是可选项，是这套东西不坑用户的唯一前提。
//
//    残留（还原挡不住的）：查词框开着时**新启动**的进程会直接落在查词语言上。
//    那取决于用户系统的「允许为每个应用窗口使用不同的输入法」开关，不在本进程
//    能控制的范围内。

// 一个可切换的输入法 profile。字段对应 TSF 的 `TF_INPUTPROCESSORPROFILE`，但只留
// 我们真正用得上的那几个，好让纯逻辑测试能凭空造出来。
enum class ImeProfileKind {
  kKeyboardLayout,  // TF_PROFILETYPE_KEYBOARDLAYOUT：只有 hkl 有意义
  kInputProcessor,  // TF_PROFILETYPE_INPUTPROCESSOR：只有 clsid + profile 有意义
};

struct ImeProfile {
  ImeProfileKind kind = ImeProfileKind::kInputProcessor;
  LANGID langid = 0;
  GUID clsid = {};    // INPUTPROCESSOR 专用
  GUID profile = {};  // INPUTPROCESSOR 专用（guidProfile）
  HKL hkl = nullptr;  // KEYBOARDLAYOUT 专用
  std::wstring name;  // 人类可读名，系统给的
};

// ---------------------------------------------------------------------------
// id 编码格式（Dart 侧当成不透明字符串持久化，见 lookup_ime_source.dart）
//
//   输入法：  tsf:<LANGID>:<CLSID>:<GUIDPROFILE>
//   键盘布局：hkl:<LANGID>:<HKL 低 32 位>
//
// 其中 LANGID 是 4 位十六进制、HKL 是 8 位十六进制，GUID 是 `StringFromGUID2` 的
// 标准大括号形式。十六进制**一律大写**（与 `StringFromGUID2` 一致），解码时不区分
// 大小写，所以旧版本写下的小写 id 照样认。例：
//
//   tsf:0804:{86598FB9-66A2-463E-B9C2-AEB906D477AD}:{607FDF85-FCC8-4DBD-A365-41296F980C9C}
//   hkl:0409:F0010409
//
// LANGID 必须编进去：`ActivateProfile` 要它，而 clsid+guidProfile 这一对在多语言
// 输入法上会重复出现（同一个 TIP 注册到多个语言）。
// ---------------------------------------------------------------------------

// GUID ↔ `{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}`。自己实现而不是调
// `StringFromGUID2`/`CLSIDFromString`，是为了让这一层**零 COM 依赖**：gate 测试
// 才能在不初始化 COM、不链 ole32 的情况下真跑。
std::wstring FormatGuid(const GUID& guid);
bool ParseGuid(const std::wstring& text, GUID* out);

// 编码这个 profile 的稳定 id。字段不足以唯一标识时返回空串（调用方必须把空串当成
// 「这条不能给用户选」——点了没反应比少一条更糟）。
std::wstring EncodeImeProfileId(const ImeProfile& profile);

// 解开的 id。`hkl` 只留低 32 位：Win64 上 HKL 是 32 位值符号扩展进指针的
// （en-US 布局在本机就是 0xFFFFFFFFF0010409），比较低 32 位才稳。
struct ImeProfileId {
  ImeProfileKind kind = ImeProfileKind::kInputProcessor;
  LANGID langid = 0;
  GUID clsid = {};
  GUID profile = {};
  uint32_t hkl = 0;
};

// 解码。格式不认识返回 false——调用方据此回落到按语言匹配，而不是报错。
bool DecodeImeProfileId(const std::wstring& id, ImeProfileId* out);

// 活的 profile 是不是 id 指的那个。**按字段比**而不是把两边 id 编成字符串比：
// 持久化下来的 id 可能来自旧版本（大小写/写法漂移），按字段比不受影响。
bool ImeProfileMatchesId(const ImeProfile& profile, const ImeProfileId& id);

// BCP-47 标签（ja / zh-Hans / ko / en…）是否匹配某个 profile 的 LANGID。
//
// 主语言经 Win32 LocaleNameToLCID 解析，不自带映射表。sublang 只对中文比较——
// 简繁是两套输入法，装了拼音打不出繁体；其它语言的 sublang 只是地区变体
// （en-GB 还是 en-US 都能打英文），强行比较只会让匹配失败。
bool LanguageTagMatchesLangId(const std::wstring& tag, LANGID langid);

// ---------------------------------------------------------------------------
// 回落决策
// ---------------------------------------------------------------------------

enum class ImeResolutionKind {
  kNone,      // 什么都没匹配上
  kSourceId,  // 指定的那个输入法还在
  kLanguage,  // 按语言匹配到的（source_id 为空，或指定的那个已经不在了）
};

struct ImeResolution {
  ImeResolutionKind kind = ImeResolutionKind::kNone;
  size_t index = 0;  // 仅 kind != kNone 时有意义
};

// `source_id` 优先；解不开或系统里已经没有（用户卸载了那个输入法）就回落到按
// `language` 匹配；再找不到才 kNone。
//
// 按语言匹配时**优先真正的输入法**（INPUTPROCESSOR），没有才退回键盘布局：
// 「切到日语」的用户要的是日语输入法，不是直接打罗马字的 JP 键盘布局。
ImeResolution ResolveLookupImeProfile(const std::wstring& source_id,
                                      const std::wstring& language,
                                      const std::vector<ImeProfile>& profiles);

// ---------------------------------------------------------------------------
// 状态机
// ---------------------------------------------------------------------------

enum class LookupImeUpdate {
  kUnchanged,    // 已经是这个状态
  kApplied,      // 真切了
  kUnavailable,  // 系统里没有能满足这个请求的输入法——什么都没做
  kFailed,       // 平台调用失败
};

using ActivateImeProfileFn = bool (*)(const ImeProfile& profile, void* context);

class LookupImeSwitcher {
 public:
  LookupImeSwitcher() = default;
  explicit LookupImeSwitcher(ActivateImeProfileFn fn, void* context = nullptr)
      : activate_(fn), context_(context) {}

  // 切到 `source_id` / `language` 表达的输入法。`current` 是调用时系统正在用的
  // profile（第一次切换前会被记下来，用于还原）；`profiles` 是已启用清单。
  // 两个请求字段都为空 = Restore()。
  LookupImeUpdate Activate(const std::wstring& source_id,
                           const std::wstring& language,
                           const ImeProfile& current,
                           const std::vector<ImeProfile>& profiles);

  // 还原到进入查词前的 profile。没切过就什么都不做。
  LookupImeUpdate Restore();

  bool active() const { return active_; }
  const ImeProfile& baseline() const { return baseline_; }
  const std::wstring& applied_id() const { return applied_id_; }

 private:
  ActivateImeProfileFn activate_ = nullptr;
  void* context_ = nullptr;
  bool active_ = false;
  ImeProfile baseline_;
  std::wstring baseline_id_;
  std::wstring applied_id_;
};

#endif  // RUNNER_LOOKUP_IME_SELECTION_H_
