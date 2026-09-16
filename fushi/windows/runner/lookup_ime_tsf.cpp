#include "lookup_ime_tsf.h"

#include <objbase.h>
#include <oleauto.h>

#include <algorithm>

#ifndef TF_IPP_FLAG_ENABLED
#define TF_IPP_FLAG_ACTIVE 0x00000001
#define TF_IPP_FLAG_ENABLED 0x00000002
#endif
#ifndef TF_IPPMF_FORPROCESS
#define TF_IPPMF_FORPROCESS 0x10000000
#endif

namespace {

// 人类可读名。TSF 只给 INPUTPROCESSOR 的描述；纯键盘布局的
// `GetLanguageProfileDescription` 在本机直接返回 E_FAIL，只能用区域显示名兜底
// （语言栏那边写「英语(美国) - 美式键盘」，布局自己那半截要走注册表 KLID 反查，
// 为一条兜底项不值得——同语言装了两套布局时两条会同名，届时再说）。
std::wstring ProfileDisplayName(ITfInputProcessorProfiles* profiles,
                                const TF_INPUTPROCESSORPROFILE& raw) {
  if (profiles != nullptr) {
    BSTR description = nullptr;
    const HRESULT hr = profiles->GetLanguageProfileDescription(
        raw.clsid, raw.langid, raw.guidProfile, &description);
    if (SUCCEEDED(hr) && description != nullptr) {
      std::wstring name(description, SysStringLen(description));
      SysFreeString(description);
      if (!name.empty()) {
        return name;
      }
    } else if (description != nullptr) {
      SysFreeString(description);
    }
  }
  wchar_t buffer[256] = {};
  if (GetLocaleInfoW(MAKELCID(raw.langid, SORT_DEFAULT),
                     LOCALE_SLOCALIZEDDISPLAYNAME, buffer, 256) > 0) {
    return buffer;
  }
  return BcpTagOfLangId(raw.langid);
}

bool IsKeyboardCategory(const TF_INPUTPROCESSORPROFILE& raw) {
  // 键盘布局型 profile 的 catid 是 GUID_NULL（本机实测），所以只能按类型放行。
  if (raw.dwProfileType == TF_PROFILETYPE_KEYBOARDLAYOUT) {
    return true;
  }
  // `!= FALSE` 会被 MSVC /W4 判成 C4805（bool 与 int 混用），而 /WX 下那是致命的。
  if (IsEqualGUID(raw.catid, GUID_TFCAT_TIP_KEYBOARD)) {
    return true;
  }
  return false;
}

ImeProfile ToImeProfile(ITfInputProcessorProfiles* profiles,
                        const TF_INPUTPROCESSORPROFILE& raw) {
  ImeProfile profile;
  profile.kind = raw.dwProfileType == TF_PROFILETYPE_KEYBOARDLAYOUT
                     ? ImeProfileKind::kKeyboardLayout
                     : ImeProfileKind::kInputProcessor;
  profile.langid = raw.langid;
  profile.clsid = raw.clsid;
  profile.profile = raw.guidProfile;
  profile.hkl = raw.hkl;
  profile.name = ProfileDisplayName(profiles, raw);
  return profile;
}

}  // namespace

std::wstring BcpTagOfLangId(LANGID langid) {
  if (langid == 0) return std::wstring();
  wchar_t buffer[LOCALE_NAME_MAX_LENGTH] = {};
  const int written = LCIDToLocaleName(MAKELCID(langid, SORT_DEFAULT), buffer,
                                       LOCALE_NAME_MAX_LENGTH, 0);
  if (written <= 0) return std::wstring();
  return buffer;
}

TsfInputProcessorProfiles::~TsfInputProcessorProfiles() {
  // 兜底而已；生产路径必须由 FlutterWindow::OnDestroy() 先调 Shutdown()，
  // 原因见头文件（栈上的 FlutterWindow 析构在 CoUninitialize 之后）。
  Shutdown();
}

void TsfInputProcessorProfiles::Shutdown() {
  if (manager_ != nullptr) {
    manager_->Release();
    manager_ = nullptr;
  }
  if (profiles_ != nullptr) {
    profiles_->Release();
    profiles_ = nullptr;
  }
  // 拆完就不再重建：窗口都没了，谁再问都该是"不可用"。
  attempted_ = true;
}

bool TsfInputProcessorProfiles::EnsureAvailable() {
  if (manager_ != nullptr) return true;
  if (attempted_) return false;
  attempted_ = true;
  HRESULT hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_ITfInputProcessorProfiles,
                                reinterpret_cast<void**>(&profiles_));
  if (FAILED(hr) || profiles_ == nullptr) {
    profiles_ = nullptr;
    return false;
  }
  hr = profiles_->QueryInterface(IID_ITfInputProcessorProfileMgr,
                                 reinterpret_cast<void**>(&manager_));
  if (FAILED(hr) || manager_ == nullptr) {
    manager_ = nullptr;
    profiles_->Release();
    profiles_ = nullptr;
    return false;
  }
  return true;
}

std::vector<ImeProfile> TsfInputProcessorProfiles::EnumerateEnabled() {
  std::vector<ImeProfile> result;
  if (!EnsureAvailable()) return result;

  // langid=0 = 一次列全，不用先 GetLanguageList 再按语言各列一遍（那样会把
  // langid=0 的非键盘 TIP 在每个语言下重复吐一次）。
  IEnumTfInputProcessorProfiles* enumerator = nullptr;
  if (FAILED(manager_->EnumProfiles(0, &enumerator)) || enumerator == nullptr) {
    return result;
  }
  std::vector<std::wstring> seen_ids;
  TF_INPUTPROCESSORPROFILE raw;
  ULONG fetched = 0;
  while (enumerator->Next(1, &raw, &fetched) == S_OK && fetched == 1) {
    if (raw.langid == 0) continue;
    if ((raw.dwFlags & TF_IPP_FLAG_ENABLED) == 0) continue;
    if (!IsKeyboardCategory(raw)) continue;
    ImeProfile profile = ToImeProfile(profiles_, raw);
    const std::wstring id = EncodeImeProfileId(profile);
    if (id.empty()) continue;
    if (std::find(seen_ids.begin(), seen_ids.end(), id) != seen_ids.end()) {
      continue;
    }
    seen_ids.push_back(id);
    result.push_back(std::move(profile));
  }
  enumerator->Release();
  return result;
}

bool TsfInputProcessorProfiles::ActiveProfile(ImeProfile* out) {
  if (out == nullptr) return false;
  if (!EnsureAvailable()) return false;
  TF_INPUTPROCESSORPROFILE raw = {};
  if (FAILED(manager_->GetActiveProfile(GUID_TFCAT_TIP_KEYBOARD, &raw))) {
    return false;
  }
  ImeProfile profile = ToImeProfile(profiles_, raw);
  if (EncodeImeProfileId(profile).empty()) {
    // 认不出身份的基线还不如没有：还原时会往一个记不住的东西上切。
    return false;
  }
  *out = std::move(profile);
  return true;
}

bool TsfInputProcessorProfiles::Activate(const ImeProfile& profile) {
  if (!EnsureAvailable()) return false;
  const bool keyboard = profile.kind == ImeProfileKind::kKeyboardLayout;
  const DWORD type = keyboard ? TF_PROFILETYPE_KEYBOARDLAYOUT
                              : TF_PROFILETYPE_INPUTPROCESSOR;
  const GUID null_guid = {};
  const HRESULT hr = manager_->ActivateProfile(
      type, profile.langid, keyboard ? null_guid : profile.clsid,
      keyboard ? null_guid : profile.profile, keyboard ? profile.hkl : nullptr,
      TF_IPPMF_FORPROCESS);
  return SUCCEEDED(hr);
}

bool TsfInputProcessorProfiles::ActivateThunk(const ImeProfile& profile,
                                              void* context) {
  auto* self = static_cast<TsfInputProcessorProfiles*>(context);
  return self != nullptr && self->Activate(profile);
}
