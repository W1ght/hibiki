#include "lookup_ime_selection.h"

#include <algorithm>
#include <cstddef>

namespace {

constexpr size_t kGuidTextLength = 38;  // {8-4-4-4-12}

std::wstring ToLowerAscii(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), [](wchar_t c) {
    return (c >= L'A' && c <= L'Z') ? static_cast<wchar_t>(c - L'A' + L'a') : c;
  });
  return value;
}

bool Contains(const std::wstring& haystack, const wchar_t* needle) {
  return haystack.find(needle) != std::wstring::npos;
}

// 中文简繁：0 = 没说，1 = 简体，2 = 繁体。
int ChineseScriptOfTag(const std::wstring& lower_tag) {
  if (Contains(lower_tag, L"hans")) return 1;
  if (Contains(lower_tag, L"hant")) return 2;
  if (Contains(lower_tag, L"-cn") || Contains(lower_tag, L"-sg")) return 1;
  if (Contains(lower_tag, L"-tw") || Contains(lower_tag, L"-hk") ||
      Contains(lower_tag, L"-mo")) {
    return 2;
  }
  return 0;
}

int ChineseScriptOfSublang(WORD sublang) {
  switch (sublang) {
    case SUBLANG_CHINESE_SIMPLIFIED:
    case SUBLANG_CHINESE_SINGAPORE:
      return 1;
    case SUBLANG_CHINESE_TRADITIONAL:
    case SUBLANG_CHINESE_HONGKONG:
    case SUBLANG_CHINESE_MACAU:
      return 2;
    default:
      return 0;
  }
}

wchar_t HexDigit(unsigned value) {
  return value < 10 ? static_cast<wchar_t>(L'0' + value)
                    : static_cast<wchar_t>(L'A' + (value - 10));
}

void AppendHex(std::wstring& out, uint64_t value, int digits) {
  for (int i = digits - 1; i >= 0; --i) {
    out.push_back(HexDigit(static_cast<unsigned>((value >> (i * 4)) & 0xfu)));
  }
}

bool HexValue(wchar_t c, unsigned* out) {
  if (c >= L'0' && c <= L'9') {
    *out = static_cast<unsigned>(c - L'0');
    return true;
  }
  if (c >= L'a' && c <= L'f') {
    *out = static_cast<unsigned>(c - L'a' + 10);
    return true;
  }
  if (c >= L'A' && c <= L'F') {
    *out = static_cast<unsigned>(c - L'A' + 10);
    return true;
  }
  return false;
}

// 从 text[pos] 起读恰好 digits 个十六进制位，读完把 pos 推到后面。
bool ReadHex(const std::wstring& text, size_t& pos, int digits, uint64_t* out) {
  if (pos + static_cast<size_t>(digits) > text.size()) return false;
  uint64_t value = 0;
  for (int i = 0; i < digits; ++i) {
    unsigned nibble = 0;
    if (!HexValue(text[pos + static_cast<size_t>(i)], &nibble)) return false;
    value = (value << 4) | nibble;
  }
  pos += static_cast<size_t>(digits);
  *out = value;
  return true;
}

bool IsNullGuid(const GUID& guid) {
  if (guid.Data1 != 0 || guid.Data2 != 0 || guid.Data3 != 0) return false;
  for (int i = 0; i < 8; ++i) {
    if (guid.Data4[i] != 0) return false;
  }
  return true;
}

bool GuidEquals(const GUID& a, const GUID& b) {
  if (a.Data1 != b.Data1 || a.Data2 != b.Data2 || a.Data3 != b.Data3) {
    return false;
  }
  for (int i = 0; i < 8; ++i) {
    if (a.Data4[i] != b.Data4[i]) return false;
  }
  return true;
}

uint32_t HklLow32(HKL hkl) {
  return static_cast<uint32_t>(reinterpret_cast<UINT_PTR>(hkl) & 0xffffffffu);
}

// HKL 的低 16 位就是这个布局的输入语言 LANGID。
LANGID LangIdOfProfile(const ImeProfile& profile) {
  if (profile.langid != 0) return profile.langid;
  if (profile.kind == ImeProfileKind::kKeyboardLayout &&
      profile.hkl != nullptr) {
    return static_cast<LANGID>(HklLow32(profile.hkl) & 0xffffu);
  }
  return 0;
}

}  // namespace

std::wstring FormatGuid(const GUID& guid) {
  std::wstring out;
  out.reserve(kGuidTextLength);
  out.push_back(L'{');
  AppendHex(out, guid.Data1, 8);
  out.push_back(L'-');
  AppendHex(out, guid.Data2, 4);
  out.push_back(L'-');
  AppendHex(out, guid.Data3, 4);
  out.push_back(L'-');
  AppendHex(out, guid.Data4[0], 2);
  AppendHex(out, guid.Data4[1], 2);
  out.push_back(L'-');
  for (int i = 2; i < 8; ++i) {
    AppendHex(out, guid.Data4[i], 2);
  }
  out.push_back(L'}');
  return out;
}

bool ParseGuid(const std::wstring& text, GUID* out) {
  if (out == nullptr) return false;
  if (text.size() != kGuidTextLength) return false;
  if (text.front() != L'{' || text.back() != L'}') return false;
  if (text[9] != L'-' || text[14] != L'-' || text[19] != L'-' ||
      text[24] != L'-') {
    return false;
  }
  GUID guid = {};
  size_t pos = 1;
  uint64_t value = 0;
  if (!ReadHex(text, pos, 8, &value)) return false;
  guid.Data1 = static_cast<unsigned long>(value);
  ++pos;  // '-'
  if (!ReadHex(text, pos, 4, &value)) return false;
  guid.Data2 = static_cast<unsigned short>(value);
  ++pos;
  if (!ReadHex(text, pos, 4, &value)) return false;
  guid.Data3 = static_cast<unsigned short>(value);
  ++pos;
  for (int i = 0; i < 2; ++i) {
    if (!ReadHex(text, pos, 2, &value)) return false;
    guid.Data4[i] = static_cast<unsigned char>(value);
  }
  ++pos;
  for (int i = 2; i < 8; ++i) {
    if (!ReadHex(text, pos, 2, &value)) return false;
    guid.Data4[i] = static_cast<unsigned char>(value);
  }
  *out = guid;
  return true;
}

std::wstring EncodeImeProfileId(const ImeProfile& profile) {
  const LANGID langid = LangIdOfProfile(profile);
  if (langid == 0) return std::wstring();
  if (profile.kind == ImeProfileKind::kKeyboardLayout) {
    if (profile.hkl == nullptr) return std::wstring();
    std::wstring out = L"hkl:";
    AppendHex(out, langid, 4);
    out.push_back(L':');
    AppendHex(out, HklLow32(profile.hkl), 8);
    return out;
  }
  // 一个 TIP 至少要有 clsid 才认得出来；guidProfile 全零是允许的（有的 TIP 只注册
  // 一个 profile），照样能唯一定位。
  if (IsNullGuid(profile.clsid)) return std::wstring();
  std::wstring out = L"tsf:";
  AppendHex(out, langid, 4);
  out.push_back(L':');
  out.append(FormatGuid(profile.clsid));
  out.push_back(L':');
  out.append(FormatGuid(profile.profile));
  return out;
}

bool DecodeImeProfileId(const std::wstring& id, ImeProfileId* out) {
  if (out == nullptr) return false;
  ImeProfileId parsed;
  size_t pos = 0;
  if (id.compare(0, 4, L"tsf:") == 0) {
    parsed.kind = ImeProfileKind::kInputProcessor;
    pos = 4;
  } else if (id.compare(0, 4, L"hkl:") == 0) {
    parsed.kind = ImeProfileKind::kKeyboardLayout;
    pos = 4;
  } else {
    return false;
  }
  uint64_t value = 0;
  if (!ReadHex(id, pos, 4, &value)) return false;
  parsed.langid = static_cast<LANGID>(value);
  if (parsed.langid == 0) return false;
  if (pos >= id.size() || id[pos] != L':') return false;
  ++pos;

  if (parsed.kind == ImeProfileKind::kKeyboardLayout) {
    if (!ReadHex(id, pos, 8, &value)) return false;
    if (pos != id.size()) return false;  // 后面还有东西 = 不是我们写的 id
    parsed.hkl = static_cast<uint32_t>(value);
    if (parsed.hkl == 0) return false;
    *out = parsed;
    return true;
  }

  if (id.size() != pos + kGuidTextLength * 2 + 1) return false;
  if (id[pos + kGuidTextLength] != L':') return false;
  if (!ParseGuid(id.substr(pos, kGuidTextLength), &parsed.clsid)) return false;
  if (!ParseGuid(id.substr(pos + kGuidTextLength + 1, kGuidTextLength),
                 &parsed.profile)) {
    return false;
  }
  if (IsNullGuid(parsed.clsid)) return false;
  *out = parsed;
  return true;
}

bool ImeProfileMatchesId(const ImeProfile& profile, const ImeProfileId& id) {
  if (profile.kind != id.kind) return false;
  if (LangIdOfProfile(profile) != id.langid) return false;
  if (id.kind == ImeProfileKind::kKeyboardLayout) {
    return profile.hkl != nullptr && HklLow32(profile.hkl) == id.hkl;
  }
  return GuidEquals(profile.clsid, id.clsid) &&
         GuidEquals(profile.profile, id.profile);
}

bool LanguageTagMatchesLangId(const std::wstring& tag, LANGID langid) {
  if (tag.empty()) {
    return false;
  }
  const LCID lcid = LocaleNameToLCID(tag.c_str(), LOCALE_ALLOW_NEUTRAL_NAMES);
  if (lcid == 0) {
    return false;
  }
  const LANGID wanted = LANGIDFROMLCID(lcid);
  if (PRIMARYLANGID(wanted) != PRIMARYLANGID(langid)) {
    return false;
  }
  if (PRIMARYLANGID(wanted) != LANG_CHINESE) {
    return true;
  }
  // 中文：简繁是两套输入法，装了拼音打不出繁体。标签没说简繁（裸 `zh`）时不挑。
  const int wanted_script = ChineseScriptOfTag(ToLowerAscii(tag));
  if (wanted_script == 0) {
    return true;
  }
  return wanted_script == ChineseScriptOfSublang(SUBLANGID(langid));
}

ImeResolution ResolveLookupImeProfile(
    const std::wstring& source_id,
    const std::wstring& language,
    const std::vector<ImeProfile>& profiles) {
  if (!source_id.empty()) {
    ImeProfileId key;
    if (DecodeImeProfileId(source_id, &key)) {
      for (size_t i = 0; i < profiles.size(); ++i) {
        if (ImeProfileMatchesId(profiles[i], key)) {
          return ImeResolution{ImeResolutionKind::kSourceId, i};
        }
      }
    }
    // 解不开（旧格式 / 别的平台的 id）或系统里已经没有了（用户卸载了那个输入法）。
    // 两种情况都回落到按语言，而不是报错——用户的意图「查词时用日语」还成立。
  }
  if (language.empty()) {
    return ImeResolution{};
  }
  const size_t npos = profiles.size();
  size_t best = npos;
  for (size_t i = 0; i < profiles.size(); ++i) {
    if (!LanguageTagMatchesLangId(language, LangIdOfProfile(profiles[i]))) {
      continue;
    }
    if (profiles[i].kind == ImeProfileKind::kInputProcessor) {
      return ImeResolution{ImeResolutionKind::kLanguage, i};
    }
    if (best == npos) {
      best = i;
    }
  }
  if (best == npos) {
    return ImeResolution{};
  }
  return ImeResolution{ImeResolutionKind::kLanguage, best};
}

LookupImeUpdate LookupImeSwitcher::Activate(
    const std::wstring& source_id,
    const std::wstring& language,
    const ImeProfile& current,
    const std::vector<ImeProfile>& profiles) {
  if (activate_ == nullptr) {
    return LookupImeUpdate::kFailed;
  }
  if (source_id.empty() && language.empty()) {
    return Restore();
  }
  const ImeResolution resolution =
      ResolveLookupImeProfile(source_id, language, profiles);
  if (resolution.kind == ImeResolutionKind::kNone) {
    // 用户选了日语但系统里没有日语输入法。静默不动是对的：我们绝不替他启用一个。
    return LookupImeUpdate::kUnavailable;
  }
  const ImeProfile& target = profiles[resolution.index];
  const std::wstring target_id = EncodeImeProfileId(target);
  if (target_id.empty()) {
    // 编不出 id 的条目本来就不该出现在清单里；真出现了也不往上切——切过去以后
    // 记不住「我切到了什么」，还原记账就散了。
    return LookupImeUpdate::kUnavailable;
  }
  if (active_ && applied_id_ == target_id) {
    return LookupImeUpdate::kUnchanged;
  }
  if (!active_) {
    // 第一次切换才记原 profile——查词页面之间来回跳时，原 profile 必须一直是
    // 「进入查词前」那个，而不是上一次我们自己切过去的那个。
    baseline_ = current;
    baseline_id_ = EncodeImeProfileId(current);
    if (!baseline_id_.empty() && baseline_id_ == target_id) {
      // 用户本来就在用这个输入法。不调平台、也不记成 active_：后面 Restore()
      // 就不会白切一次，中间用户手动换了输入法也还能重新取基线。
      return LookupImeUpdate::kUnchanged;
    }
  }
  if (!activate_(target, context_)) {
    return LookupImeUpdate::kFailed;
  }
  applied_id_ = target_id;
  active_ = true;
  return LookupImeUpdate::kApplied;
}

LookupImeUpdate LookupImeSwitcher::Restore() {
  if (activate_ == nullptr) {
    return LookupImeUpdate::kFailed;
  }
  if (!active_) {
    return LookupImeUpdate::kUnchanged;
  }
  // 记不住原 profile（进入时就读不到）时不乱猜一个切过去，只把状态清掉。
  if (baseline_id_.empty()) {
    active_ = false;
    applied_id_.clear();
    return LookupImeUpdate::kUnchanged;
  }
  if (!activate_(baseline_, context_)) {
    return LookupImeUpdate::kFailed;
  }
  active_ = false;
  applied_id_.clear();
  return LookupImeUpdate::kApplied;
}
