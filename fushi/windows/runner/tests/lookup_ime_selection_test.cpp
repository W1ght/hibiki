// 断言一律走 Expect()（返回 bool + 打印），不用 assert：NDEBUG 会把 assert 编成空
// 语句，release 下整批断言消失、测试空跑照样"通过"。这里顺手 #undef 掉，免得以后
// 有人往里加 assert 时踩到。与 ime_association_guard_test.cpp 同一写法。
#undef NDEBUG

#include "../lookup_ime_selection.h"

#include <iostream>
#include <string>
#include <vector>

namespace {

struct Recorder {
  std::vector<std::wstring> activated_ids;
  bool fail_next = false;
};

bool Record(const ImeProfile& profile, void* context) {
  auto* rec = static_cast<Recorder*>(context);
  if (rec->fail_next) {
    rec->fail_next = false;
    return false;
  }
  rec->activated_ids.push_back(EncodeImeProfileId(profile));
  return true;
}

// 断言计数：判绿只认退出码 + **实际执行数**，光看一行 "passed" 分不出「全跑了」和
// 「大半断言根本没走到」。
int g_checks = 0;

bool Expect(bool condition, const std::string& message) {
  ++g_checks;
  if (condition) {
    return true;
  }
  std::cerr << "FAIL: " << message << '\n';
  return false;
}

// 本机（2026-09-16）真实枚举到的身份，照抄进来当测试夹具。
GUID Guid(unsigned long d1, unsigned short d2, unsigned short d3,
          unsigned char b0, unsigned char b1, unsigned char b2,
          unsigned char b3, unsigned char b4, unsigned char b5,
          unsigned char b6, unsigned char b7) {
  GUID g;
  g.Data1 = d1;
  g.Data2 = d2;
  g.Data3 = d3;
  g.Data4[0] = b0;
  g.Data4[1] = b1;
  g.Data4[2] = b2;
  g.Data4[3] = b3;
  g.Data4[4] = b4;
  g.Data4[5] = b5;
  g.Data4[6] = b6;
  g.Data4[7] = b7;
  return g;
}

// {86598FB9-66A2-463E-B9C2-AEB906D477AD} 微信输入法（第三方，zh-CN）
const GUID kWeChatClsid = Guid(0x86598FB9, 0x66A2, 0x463E, 0xB9, 0xC2, 0xAE,
                               0xB9, 0x06, 0xD4, 0x77, 0xAD);
const GUID kWeChatProfile = Guid(0x607FDF85, 0xFCC8, 0x4DBD, 0xA3, 0x65, 0x41,
                                 0x29, 0x6F, 0x98, 0x0C, 0x9C);
// {81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E} 微软拼音（同样 zh-CN）
const GUID kPinyinClsid = Guid(0x81D4E9C9, 0x1D3B, 0x41BC, 0x9E, 0x6C, 0x4B,
                               0x40, 0xBF, 0x79, 0xE3, 0x5E);
const GUID kPinyinProfile = Guid(0xFA550B04, 0x5AD7, 0x411F, 0xA5, 0xAC, 0xCA,
                                 0x03, 0x8E, 0xC5, 0x15, 0xD7);
// {03B5835F-F03C-411B-9CE2-AA23E1171E36} 日语 MS-IME
const GUID kJapaneseClsid = Guid(0x03B5835F, 0xF03C, 0x411B, 0x9C, 0xE2, 0xAA,
                                 0x23, 0xE1, 0x17, 0x1E, 0x36);
const GUID kJapaneseProfile = Guid(0xA76C93D9, 0x5523, 0x4E90, 0xAA, 0xFA,
                                   0x4D, 0xB1, 0x12, 0xF9, 0xAC, 0x76);

const LANGID kChineseSimplified = 0x0804;
const LANGID kChineseTraditional = 0x0404;
const LANGID kEnglishUs = 0x0409;
const LANGID kJapanese = 0x0411;
const LANGID kKorean = 0x0412;

ImeProfile Tip(LANGID langid, const GUID& clsid, const GUID& profile,
               const wchar_t* name) {
  ImeProfile p;
  p.kind = ImeProfileKind::kInputProcessor;
  p.langid = langid;
  p.clsid = clsid;
  p.profile = profile;
  p.name = name;
  return p;
}

ImeProfile Layout(LANGID langid, UINT_PTR hkl, const wchar_t* name) {
  ImeProfile p;
  p.kind = ImeProfileKind::kKeyboardLayout;
  p.langid = langid;
  p.hkl = reinterpret_cast<HKL>(hkl);
  p.name = name;
  return p;
}

// 本机的 en-US 布局 HKL：Win64 上 HKL 是 32 位值**符号扩展**进指针的。
HKL SignExtendedHkl(uint32_t value) {
  return reinterpret_cast<HKL>(
      static_cast<INT_PTR>(static_cast<int32_t>(value)));
}

std::vector<ImeProfile> Installed() {
  return {
      Tip(kChineseSimplified, kWeChatClsid, kWeChatProfile, L"微信输入法"),
      Tip(kChineseSimplified, kPinyinClsid, kPinyinProfile, L"微软拼音"),
      Layout(kEnglishUs, 0, L"英语(美国)"),  // hkl 稍后补成符号扩展值
      Tip(kJapanese, kJapaneseClsid, kJapaneseProfile, L"微软输入法"),
  };
}

std::string Narrow(const std::wstring& value) {
  std::string out;
  for (wchar_t c : value) {
    out.push_back(c < 128 ? static_cast<char>(c) : '?');
  }
  return out;
}

}  // namespace

int main() {
  bool passed = true;

  std::vector<ImeProfile> installed = Installed();
  installed[2].hkl = SignExtendedHkl(0xF0010409u);

  const std::wstring kWeChatId =
      L"tsf:0804:{86598FB9-66A2-463E-B9C2-AEB906D477AD}:"
      L"{607FDF85-FCC8-4DBD-A365-41296F980C9C}";
  const std::wstring kPinyinId =
      L"tsf:0804:{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}:"
      L"{FA550B04-5AD7-411F-A5AC-CA038EC515D7}";
  const std::wstring kJapaneseId =
      L"tsf:0411:{03B5835F-F03C-411B-9CE2-AA23E1171E36}:"
      L"{A76C93D9-5523-4E90-AAFA-4DB112F9AC76}";
  const std::wstring kEnglishLayoutId = L"hkl:0409:F0010409";

  // ---- GUID 文本形式必须与 StringFromGUID2 一字不差（id 会被持久化）----
  {
    passed &= Expect(FormatGuid(kWeChatClsid) ==
                         L"{86598FB9-66A2-463E-B9C2-AEB906D477AD}",
                     "FormatGuid matches StringFromGUID2 spelling");
    GUID parsed = {};
    passed &= Expect(ParseGuid(L"{86598FB9-66A2-463E-B9C2-AEB906D477AD}",
                               &parsed) &&
                         FormatGuid(parsed) == FormatGuid(kWeChatClsid),
                     "ParseGuid round-trips");
    passed &= Expect(ParseGuid(L"{86598fb9-66a2-463e-b9c2-aeb906d477ad}",
                               &parsed) &&
                         FormatGuid(parsed) == FormatGuid(kWeChatClsid),
                     "ParseGuid accepts lowercase (older ids on disk)");
    passed &= Expect(!ParseGuid(L"86598FB9-66A2-463E-B9C2-AEB906D477AD",
                                &parsed),
                     "ParseGuid rejects a GUID without braces");
    passed &= Expect(!ParseGuid(L"{86598FB9-66A2-463E-B9C2-AEB906D477A}",
                                &parsed),
                     "ParseGuid rejects a short GUID");
    passed &= Expect(!ParseGuid(L"{86598FB9-66A2-463E-B9C2-AEB906D477AZ}",
                                &parsed),
                     "ParseGuid rejects a non-hex digit");
  }

  // ---- id 编码 ----
  {
    passed &= Expect(EncodeImeProfileId(installed[0]) == kWeChatId,
                     "TIP id is tsf:<langid>:<clsid>:<guidProfile>");
    passed &= Expect(EncodeImeProfileId(installed[2]) == kEnglishLayoutId,
                     "keyboard layout id keeps only the low 32 bits of the HKL");
    passed &= Expect(EncodeImeProfileId(installed[0]) !=
                         EncodeImeProfileId(installed[1]),
                     "two IMEs of the SAME language get different ids "
                     "(the whole point of this feature)");
    // langid 缺省时从 HKL 低 16 位推出来。
    ImeProfile bare_layout;
    bare_layout.kind = ImeProfileKind::kKeyboardLayout;
    bare_layout.hkl = SignExtendedHkl(0xF0010409u);
    passed &= Expect(EncodeImeProfileId(bare_layout) == kEnglishLayoutId,
                     "layout langid falls back to the HKL low word");
    // 身份不全的条目编不出 id（不能给用户选）。
    ImeProfile broken_tip;
    broken_tip.kind = ImeProfileKind::kInputProcessor;
    broken_tip.langid = kJapanese;
    passed &= Expect(EncodeImeProfileId(broken_tip).empty(),
                     "a TIP without a CLSID has no id");
    ImeProfile broken_layout;
    broken_layout.kind = ImeProfileKind::kKeyboardLayout;
    passed &= Expect(EncodeImeProfileId(broken_layout).empty(),
                     "a layout without an HKL has no id");
    ImeProfile no_lang = installed[0];
    no_lang.langid = 0;
    passed &= Expect(EncodeImeProfileId(no_lang).empty(),
                     "a TIP without a LANGID has no id");
  }

  // ---- id 解码（反解是硬要求：存到磁盘上的 id 下次启动要能认回来）----
  {
    ImeProfileId key;
    passed &= Expect(DecodeImeProfileId(kWeChatId, &key) &&
                         key.kind == ImeProfileKind::kInputProcessor &&
                         key.langid == kChineseSimplified,
                     "decodes a TIP id");
    passed &= Expect(ImeProfileMatchesId(installed[0], key),
                     "the decoded TIP id matches its own profile");
    passed &= Expect(!ImeProfileMatchesId(installed[1], key),
                     "the decoded WeChat id does NOT match MS Pinyin");

    passed &= Expect(DecodeImeProfileId(kEnglishLayoutId, &key) &&
                         key.kind == ImeProfileKind::kKeyboardLayout &&
                         key.langid == kEnglishUs && key.hkl == 0xF0010409u,
                     "decodes a layout id");
    passed &= Expect(ImeProfileMatchesId(installed[2], key),
                     "a sign-extended HKL still matches its 32-bit id");
    passed &= Expect(!ImeProfileMatchesId(installed[0], key),
                     "a layout id does not match a TIP");

    // 大小写不敏感：旧版本 / 别处写下的小写 id 照样认回来。
    passed &= Expect(DecodeImeProfileId(
                         L"tsf:0804:{86598fb9-66a2-463e-b9c2-aeb906d477ad}:"
                         L"{607fdf85-fcc8-4dbd-a365-41296f980c9c}",
                         &key) &&
                         ImeProfileMatchesId(installed[0], key),
                     "lowercase ids still resolve");

    // 认不出的一律 false —— 上层据此回落到按语言，而不是当成"找到了"。
    passed &= Expect(!DecodeImeProfileId(L"", &key), "empty id decodes to none");
    passed &= Expect(!DecodeImeProfileId(L"com.apple.inputmethod.Kotoeri", &key),
                     "a macOS input source id is not ours");
    passed &= Expect(!DecodeImeProfileId(L"tsf:0000:{00000000-0000-0000-0000-"
                                         L"000000000000}:{00000000-0000-0000-"
                                         L"0000-000000000000}",
                                         &key),
                     "langid 0 is not a usable id");
    passed &= Expect(!DecodeImeProfileId(L"hkl:0409:00000000", &key),
                     "HKL 0 is not a usable id");
    passed &= Expect(!DecodeImeProfileId(L"hkl:0409:F0010409:extra", &key),
                     "trailing junk invalidates a layout id");
    passed &= Expect(!DecodeImeProfileId(L"hkl:0409", &key),
                     "a truncated layout id is rejected");
  }

  // ---- 语言匹配（沿用 HKL 版的语义，回落路径还要用）----
  {
    passed &= Expect(LanguageTagMatchesLangId(L"ja", kJapanese),
                     "ja matches a Japanese profile");
    passed &= Expect(!LanguageTagMatchesLangId(L"ja", kEnglishUs),
                     "ja must not match an English profile");
    passed &= Expect(LanguageTagMatchesLangId(L"ko", kKorean),
                     "ko matches a Korean profile");
    passed &= Expect(LanguageTagMatchesLangId(L"en", 0x0809),
                     "en matches en-GB (sublang is only a region)");
    passed &= Expect(LanguageTagMatchesLangId(L"zh-Hans", kChineseSimplified),
                     "zh-Hans matches a simplified profile");
    passed &= Expect(!LanguageTagMatchesLangId(L"zh-Hans", kChineseTraditional),
                     "zh-Hans must not match a traditional profile");
    passed &= Expect(LanguageTagMatchesLangId(L"zh-Hant", kChineseTraditional),
                     "zh-Hant matches a traditional profile");
    passed &= Expect(LanguageTagMatchesLangId(L"zh", kChineseSimplified) &&
                         LanguageTagMatchesLangId(L"zh", kChineseTraditional),
                     "bare zh does not discriminate script");
    passed &= Expect(!LanguageTagMatchesLangId(L"", kJapanese),
                     "empty tag matches nothing");
    passed &= Expect(!LanguageTagMatchesLangId(L"nonsense", kJapanese),
                     "garbage tag matches nothing");
  }

  // ---- 回落决策 ----
  {
    // 指定的输入法还在 —— 切它，而不是"该语言的某一个"。
    ImeResolution r = ResolveLookupImeProfile(kPinyinId, L"zh-Hans", installed);
    passed &= Expect(r.kind == ImeResolutionKind::kSourceId && r.index == 1,
                     "an installed sourceId wins over the language");

    // 用户卸载了指定的那个 —— 回落到按语言，不是报 unavailable。
    std::vector<ImeProfile> without_pinyin = installed;
    without_pinyin.erase(without_pinyin.begin() + 1);
    r = ResolveLookupImeProfile(kPinyinId, L"zh-Hans", without_pinyin);
    passed &= Expect(r.kind == ImeResolutionKind::kLanguage && r.index == 0,
                     "an uninstalled sourceId falls back to the language");

    // 别的平台的 id / 旧格式 —— 同样回落，不是硬失败。
    r = ResolveLookupImeProfile(L"com.apple.inputmethod.Kotoeri", L"ja",
                                installed);
    passed &= Expect(r.kind == ImeResolutionKind::kLanguage && r.index == 3,
                     "an unparsable sourceId falls back to the language");

    // sourceId 没了、语言也没装 —— 这才是 unavailable。
    r = ResolveLookupImeProfile(kPinyinId, L"ko", without_pinyin);
    passed &= Expect(r.kind == ImeResolutionKind::kNone,
                     "no sourceId and no language match is unavailable");

    // 只给语言。
    r = ResolveLookupImeProfile(L"", L"ja", installed);
    passed &= Expect(r.kind == ImeResolutionKind::kLanguage && r.index == 3,
                     "language-only request resolves by language");
    r = ResolveLookupImeProfile(L"", L"ko", installed);
    passed &= Expect(r.kind == ImeResolutionKind::kNone,
                     "language-only request with nothing installed is none");

    // 两个都空 —— 没有东西可解（上层把它当成"还原"）。
    r = ResolveLookupImeProfile(L"", L"", installed);
    passed &= Expect(r.kind == ImeResolutionKind::kNone,
                     "an empty request resolves to nothing");

    // 同一语言既有 IME 又有键盘布局时，"切到日语"要的是日语输入法，不是直接打
    // 罗马字的 JP 布局。
    std::vector<ImeProfile> ja_both = {
        Layout(kJapanese, 0x04110411u, L"日语(日本)"),
        Tip(kJapanese, kJapaneseClsid, kJapaneseProfile, L"微软输入法"),
    };
    r = ResolveLookupImeProfile(L"", L"ja", ja_both);
    passed &= Expect(r.kind == ImeResolutionKind::kLanguage && r.index == 1,
                     "language fallback prefers a real IME over a bare layout");
    // 但明确点名布局时仍然给布局。
    r = ResolveLookupImeProfile(L"hkl:0411:04110411", L"ja", ja_both);
    passed &= Expect(r.kind == ImeResolutionKind::kSourceId && r.index == 0,
                     "an explicit layout sourceId still wins");
  }

  // ---- 状态机：切 + 还原 ----
  {
    Recorder rec;
    LookupImeSwitcher switcher(Record, &rec);
    passed &= Expect(switcher.Activate(kJapaneseId, L"ja", installed[0],
                                       installed) ==
                         LookupImeUpdate::kApplied,
                     "activate switches to the requested IME");
    passed &= Expect(rec.activated_ids.size() == 1 &&
                         rec.activated_ids[0] == kJapaneseId,
                     "activate hands the platform exactly that profile");
    passed &= Expect(switcher.active(), "switcher is active after applying");
    passed &= Expect(switcher.Restore() == LookupImeUpdate::kApplied,
                     "restore switches back");
    passed &= Expect(rec.activated_ids.size() == 2 &&
                         rec.activated_ids[1] == kWeChatId,
                     "restore returns to the profile the user had before");
    passed &= Expect(!switcher.active(), "switcher is inactive after restore");
  }

  // ---- 指定具体输入法：切到微信 vs 切到微软拼音必须是两件事 ----
  {
    Recorder rec;
    LookupImeSwitcher switcher(Record, &rec);
    // 用户此刻在微信输入法上，查词要求微软拼音（同一个语言！）。
    passed &= Expect(switcher.Activate(kPinyinId, L"zh-Hans", installed[0],
                                       installed) ==
                         LookupImeUpdate::kApplied,
                     "same-language alternative is a real switch");
    passed &= Expect(rec.activated_ids.back() == kPinyinId,
                     "and it goes to MS Pinyin, not back to WeChat");
    switcher.Restore();
    passed &= Expect(rec.activated_ids.back() == kWeChatId,
                     "restore goes back to WeChat");
  }

  // ---- 查词页面之间来回跳：基线必须一直是"进入查词前"那个 ----
  {
    Recorder rec;
    LookupImeSwitcher switcher(Record, &rec);
    switcher.Activate(kJapaneseId, L"ja", installed[0], installed);
    // 第二次 Activate 时系统当前 profile 已经是日语了（我们刚切的）。
    switcher.Activate(kPinyinId, L"zh-Hans", installed[3], installed);
    passed &= Expect(EncodeImeProfileId(switcher.baseline()) == kWeChatId,
                     "baseline stays the pre-lookup profile");
    switcher.Restore();
    passed &= Expect(rec.activated_ids.back() == kWeChatId,
                     "restore still returns to WeChat");
  }

  // ---- 重复请求同一输入法不该反复打扰系统 ----
  {
    Recorder rec;
    LookupImeSwitcher switcher(Record, &rec);
    switcher.Activate(kJapaneseId, L"ja", installed[0], installed);
    passed &= Expect(switcher.Activate(kJapaneseId, L"ja", installed[3],
                                       installed) ==
                         LookupImeUpdate::kUnchanged,
                     "repeated activate is coalesced");
    passed &= Expect(rec.activated_ids.size() == 1,
                     "repeated activate makes no second platform call");
  }

  // ---- 用户本来就在目标输入法上：不调平台，也不记成 active ----
  {
    Recorder rec;
    LookupImeSwitcher switcher(Record, &rec);
    passed &= Expect(switcher.Activate(kWeChatId, L"zh-Hans", installed[0],
                                       installed) ==
                         LookupImeUpdate::kUnchanged,
                     "already on the requested IME is a no-op");
    passed &= Expect(rec.activated_ids.empty(),
                     "and it makes no platform call");
    passed &= Expect(!switcher.active(),
                     "…so a later restore will not switch anything either");
    passed &= Expect(switcher.Restore() == LookupImeUpdate::kUnchanged,
                     "restore after a no-op activate is a no-op");
    passed &= Expect(rec.activated_ids.empty(), "still no platform call");
  }

  // ---- 系统里没有能满足请求的输入法：什么都不做 ----
  {
    Recorder rec;
    LookupImeSwitcher switcher(Record, &rec);
    passed &= Expect(switcher.Activate(L"", L"ko", installed[0], installed) ==
                         LookupImeUpdate::kUnavailable,
                     "missing language reports unavailable");
    passed &= Expect(rec.activated_ids.empty(),
                     "unavailable makes no platform call");
    passed &= Expect(!switcher.active(), "switcher stays inactive");
  }

  // ---- 没切过就还原 = 什么都不做 ----
  {
    Recorder rec;
    LookupImeSwitcher switcher(Record, &rec);
    passed &= Expect(switcher.Restore() == LookupImeUpdate::kUnchanged,
                     "restore without activate is a no-op");
    passed &= Expect(rec.activated_ids.empty(), "no-op restore makes no call");
  }

  // ---- 空请求 = 撤回 = 还原 ----
  {
    Recorder rec;
    LookupImeSwitcher switcher(Record, &rec);
    switcher.Activate(kJapaneseId, L"ja", installed[0], installed);
    passed &= Expect(switcher.Activate(L"", L"", installed[3], installed) ==
                         LookupImeUpdate::kApplied,
                     "an empty request restores");
    passed &= Expect(rec.activated_ids.back() == kWeChatId,
                     "empty request returns to the pre-lookup profile");
  }

  // ---- 读不到基线时不乱猜：还原只清状态，不往别处切 ----
  {
    Recorder rec;
    LookupImeSwitcher switcher(Record, &rec);
    ImeProfile unknown;  // 全空 = TSF 读不到当前 profile
    switcher.Activate(kJapaneseId, L"ja", unknown, installed);
    passed &= Expect(rec.activated_ids.size() == 1, "it still switches");
    passed &= Expect(switcher.Restore() == LookupImeUpdate::kUnchanged,
                     "restore without a baseline reports unchanged");
    passed &= Expect(rec.activated_ids.size() == 1,
                     "and makes no platform call (never guess a target)");
    passed &= Expect(!switcher.active(), "state is cleared anyway");
  }

  // ---- 平台调用失败时状态不能乱走 ----
  {
    Recorder rec;
    LookupImeSwitcher switcher(Record, &rec);
    rec.fail_next = true;
    passed &= Expect(switcher.Activate(kJapaneseId, L"ja", installed[0],
                                       installed) == LookupImeUpdate::kFailed,
                     "platform failure is reported");
    passed &= Expect(!switcher.active(), "failed activate leaves it inactive");
    // 还原路径失败同理：仍然算 active，下次还能再试。
    switcher.Activate(kJapaneseId, L"ja", installed[0], installed);
    rec.fail_next = true;
    passed &= Expect(switcher.Restore() == LookupImeUpdate::kFailed,
                     "failed restore is reported");
    passed &= Expect(switcher.active(),
                     "failed restore keeps the switcher active so it retries");
  }

  // ---- 没装 activate 回调（生产上 TSF 不可用时）一律 failed，不假装成功 ----
  {
    LookupImeSwitcher switcher;
    passed &= Expect(switcher.Activate(kJapaneseId, L"ja", installed[0],
                                       installed) == LookupImeUpdate::kFailed,
                     "no platform backend reports failure");
    passed &= Expect(switcher.Restore() == LookupImeUpdate::kFailed,
                     "restore without a backend reports failure too");
  }

  if (!passed) {
    std::cerr << "lookup_ime_selection_test FAILED after " << g_checks
              << " checks\n";
    return 1;
  }
  std::cout << "lookup_ime_selection_test passed: " << g_checks << " checks ("
            << Narrow(kWeChatId).substr(0, 8) << "...)\n";
  return 0;
}
