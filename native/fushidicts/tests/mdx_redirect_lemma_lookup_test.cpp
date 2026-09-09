// BUG-2386: keep BUG-1665 redirect behavior without its unsafe blob heuristic.
// Real @@@LINK= records must collapse only when the resolved target is the
// deinflected lemma. Equal definition bytes alone are not redirect evidence:
// ordinary Japanese noun/verb entries can intentionally share a definition.
// All redirect cases import genuine MDX fixtures, and the Japanese cases load
// the application's production ja.json continuative rules.
//
// Usage: mdx_redirect_lemma_lookup_test  (no args) -> exit 0 PASS.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "fushidicts/deinflector.hpp"
#include "fushidicts/importer.hpp"
#include "fushidicts/lookup.hpp"
#include "fushidicts/popup_json.hpp"
#include "fushidicts/query.hpp"
#include "mdx_fixture.hpp"
#include "zip_fixture.hpp"

namespace {

int g_fail = 0;

void fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  ++g_fail;
}

// Minimal English-like descriptor: verb condition + third-person "s" ->
// "" suffix transform (the same shape as assets/transforms/en.json).
const std::string kEnTransforms =
    "{\"language\":\"en\",\"conditions\":{"
    "\"v\":{\"name\":\"Verb\",\"isDictionaryForm\":true,\"subConditions\":[]}"
    "},\"transforms\":{\"3ps\":{\"name\":\"3ps\",\"description\":\"\",\"rules\":["
    "{\"type\":\"suffix\",\"fromSuffix\":\"s\",\"toSuffix\":\"\","
    "\"conditionsIn\":[\"v\"],\"conditionsOut\":[\"v\"]}]}}}";

std::string dump_results(const std::vector<LookupResult>& results) {
  std::string s;
  for (const LookupResult& r : results) {
    s += "[" + r.term.expression + " glossaries=" + std::to_string(r.term.glossaries.size()) + "] ";
  }
  return s;
}

// Writes a simple dict (the storage MDX/StarDict/DSL imports share) and
// returns its on-disk path, or "" on failure.
std::string write_dict(const char* title, const std::vector<SimpleEntry>& entries) {
  const std::string out_dir = fushi_test::temp_dir() + "/fushi_redirect_lemma_out";
  ImportResult r = dictionary_importer::write_simple_dict(title, entries, out_dir);
  if (!r.success) {
    std::fprintf(stderr, "FAIL write_simple_dict(%s): %s\n", title,
                 r.errors.empty() ? "(no error)" : r.errors.front().c_str());
    ++g_fail;
    return "";
  }
  return out_dir + "/" + r.title;
}

std::string write_mdx(const char* title, const std::vector<std::pair<std::string, std::string>>& entries) {
  const std::string base = fushi_test::temp_dir() + "/fushi_redirect_mdx";
  std::filesystem::create_directories(std::filesystem::u8path(base));
  const std::string path = base + "/" + title + ".mdx";
  const auto bytes = mdx_fixture::build_mdx_plain(title, entries);
  {
    std::ofstream file(std::filesystem::u8path(path), std::ios::binary);
    file.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    if (!file) {
      fail("cannot write MDX fixture");
      return "";
    }
  }
  const auto imported = dictionary_importer::import(path, base + "/out");
  if (!imported.success) {
    fail(imported.errors.empty() ? "MDX import failed" : imported.errors.front().c_str());
    return "";
  }
  return base + "/out/" + imported.title;
}

// 1) The redirect alias collapses into the lemma: only "belong" survives, and
//    it records the inflected surface as `matched`.
void expect_alias_collapses_into_lemma(const std::string& dict) {
  if (dict.empty()) return;

  DictionaryQuery q;
  q.add_term_dict(dict);
  Deinflector d;
  d.load_transforms_json(kEnTransforms);
  Lookup lk(q, d);

  std::vector<LookupResult> results = lk.lookup("belongs", 16);
  bool has_lemma = false;
  bool has_alias = false;
  for (const LookupResult& r : results) {
    if (r.term.expression == "belong") {
      has_lemma = true;
      if (r.matched != "belongs") fail("alias-collapse: lemma result must keep matched=belongs");
      if (r.deinflected != "belong") fail("alias-collapse: lemma result must record deinflected=belong");
    }
    if (r.term.expression == "belongs") has_alias = true;
  }
  if (!has_lemma) fail("alias-collapse: lemma entry 'belong' missing from results");
  if (has_alias) fail("alias-collapse: redirect alias 'belongs' must be dropped");
  if (!results.empty() && results.front().term.expression != "belong") {
    std::fprintf(stderr, "FAIL alias-collapse: first result must be the lemma; got %s\n",
                 dump_results(results).c_str());
    ++g_fail;
  }
}

void case_alias_collapses_into_lemma() {
  expect_alias_collapses_into_lemma(write_mdx(
      "RedirectDict", {{"belong", "to be in the right place"},
                       {"belongs", "@@@LINK=belong"}}));
}

// 2) A genuinely distinct inflected entry (different definition bytes -> its
//    own blob) is NOT a redirect and must survive, still ranked first.
void case_distinct_inflected_entry_kept() {
  const std::string dict = write_dict(
      "DistinctDict", {{"lead", "to guide"}, {"leads", "plural of lead (metal strips)"}});
  if (dict.empty()) return;

  DictionaryQuery q;
  q.add_term_dict(dict);
  Deinflector d;
  d.load_transforms_json(kEnTransforms);
  Lookup lk(q, d);

  std::vector<LookupResult> results = lk.lookup("leads", 16);
  bool has_exact = false;
  bool has_lemma = false;
  for (const LookupResult& r : results) {
    if (r.term.expression == "leads") has_exact = true;
    if (r.term.expression == "lead") has_lemma = true;
  }
  if (!has_exact) fail("distinct: real inflected entry 'leads' must be kept");
  if (!has_lemma) fail("distinct: lemma 'lead' must still be found via deinflection");
  if (!results.empty() && results.front().term.expression != "leads") {
    std::fprintf(stderr, "FAIL distinct: exact entry must still rank first; got %s\n",
                 dump_results(results).c_str());
    ++g_fail;
  }
}

// 3) Spelling-variant redirect (colour -> color): no deinflection rule reaches
//    "color", so there is no lemma hit and the alias MUST keep working.
void case_spelling_variant_untouched() {
  const std::string dict =
      write_mdx("VariantDict", {{"color", "a hue"}, {"colour", "@@@LINK=color"}});
  if (dict.empty()) return;

  DictionaryQuery q;
  q.add_term_dict(dict);
  Deinflector d;
  d.load_transforms_json(kEnTransforms);
  Lookup lk(q, d);

  std::vector<LookupResult> results = lk.lookup("colour", 16);
  bool has_variant = false;
  for (const LookupResult& r : results) {
    if (r.term.expression == "colour") has_variant = true;
  }
  if (!has_variant) fail("variant: 'colour' redirect entry must still be found");
}

// 4) Per-glossary granularity across dictionaries: dictA redirects "belongs"
//    to belong's bytes, dictB defines "belongs" in its own right. The merged
//    "belongs" result must lose ONLY dictA's copied glossary.
void case_cross_dict_keeps_real_glossary() {
  const std::string dict_a = write_mdx(
      "CrossRedirectDict", {{"belong", "to be in the right place"},
                            {"belongs", "@@@LINK=belong"}});
  const std::string dict_b =
      write_dict("CrossRealDict", {{"belongs", "third-person entry of its own"}});
  if (dict_a.empty() || dict_b.empty()) return;

  DictionaryQuery q;
  q.add_term_dict(dict_a);
  q.add_term_dict(dict_b);
  Deinflector d;
  d.load_transforms_json(kEnTransforms);
  Lookup lk(q, d);

  std::vector<LookupResult> results = lk.lookup("belongs", 16);
  const LookupResult* exact = nullptr;
  const LookupResult* lemma = nullptr;
  for (const LookupResult& r : results) {
    if (r.term.expression == "belongs") exact = &r;
    if (r.term.expression == "belong") lemma = &r;
  }
  if (lemma == nullptr) fail("cross-dict: lemma 'belong' missing");
  if (exact == nullptr) {
    fail("cross-dict: 'belongs' with a real dictB glossary must survive");
  } else {
    if (exact->term.glossaries.size() != 1) {
      std::fprintf(stderr, "FAIL cross-dict: 'belongs' must keep exactly dictB's glossary, got %zu\n",
                   exact->term.glossaries.size());
      ++g_fail;
    } else if (exact->term.glossaries.front().dict_name != "CrossRealDict") {
      std::fprintf(stderr, "FAIL cross-dict: surviving glossary must be CrossRealDict's, got %s\n",
                   exact->term.glossaries.front().dict_name.c_str());
      ++g_fail;
    }
  }
}

// Real Japanese dictionary forms can deliberately share a definition without
// either one being a redirect. The production continuative rule reaches the
// verb from the noun; sharing storage must not erase the direct noun entry.
void expect_japanese_shared_definition_kept(const std::string& dict) {
  if (dict.empty()) return;
  std::ifstream transforms(std::filesystem::u8path(FUSHI_JA_TRANSFORMS), std::ios::binary);
  if (!transforms) {
    fail("Japanese shared definition: cannot load production ja.json");
    return;
  }
  const std::string json((std::istreambuf_iterator<char>(transforms)), std::istreambuf_iterator<char>());
  DictionaryQuery q;
  q.add_term_dict(dict);
  Deinflector d;
  d.load_transforms_json(json);
  Lookup lk(q, d);
  const auto results = lk.lookup("行き遅れ", 16);
  const std::string popup_json = build_popup_json(results, 16);
  bool has_noun = false;
  bool has_verb = false;
  for (const auto& r : results) {
    if (r.term.expression == "行き遅れ" && r.matched == "行き遅れ" && r.trace.empty()) has_noun = true;
    if (r.term.expression == "行き遅れる" && r.matched == "行き遅れ" && !r.trace.empty()) has_verb = true;
  }
  if (!has_noun) fail("Japanese shared definition: real noun 行き遅れ was erased");
  if (popup_json.find("\"expression\":\"行き遅れ\"") == std::string::npos) {
    fail("Japanese shared definition: exact noun missing from popup JSON");
  }
  if (!has_verb) fail("Japanese shared definition: production continuative rule did not reach 行き遅れる");
  if (!results.empty() && results.front().term.expression != "行き遅れ") {
    fail("Japanese shared definition: exact noun must rank before deinflected verb");
  }
}

void case_japanese_shared_definition_kept() {
  expect_japanese_shared_definition_kept(write_dict(
      "JapaneseSharedDefinition", {{"行き遅れ", "noun and verb share this definition"},
                                    {"行き遅れる", "noun and verb share this definition"}}));
}

void case_japanese_mdx_real_entries_kept() {
  expect_japanese_shared_definition_kept(write_mdx(
      "JapaneseRealMdxEntries", {{"行き遅れ", "noun and verb share this definition"},
                                {"行き遅れる", "noun and verb share this definition"}}));
}

void case_japanese_yomitan_real_entries_kept() {
  const std::string path = fushi_test::write_zip("redirect_japanese_yomitan", {
      {"index.json", R"({"title":"JapaneseYomitanEntries","format":3,"revision":"test"})"},
      {"term_bank_1.json", R"([["行き遅れ","いきおくれ","","",0,["shared definition"],1,""],
                               ["行き遅れる","いきおくれる","","v1",0,["shared definition"],2,""]])"}});
  if (path.empty()) {
    fail("cannot write Yomitan fixture");
    return;
  }
  const std::string output = fushi_test::temp_dir() + "/fushi_redirect_yomitan";
  const auto imported = dictionary_importer::import(path, output);
  if (!imported.success) {
    fail(imported.errors.empty() ? "Yomitan import failed" : imported.errors.front().c_str());
    return;
  }
  expect_japanese_shared_definition_kept(output + "/" + imported.title);
}

void expect_english_exact_kept(const std::string& dict, const char* label) {
  if (dict.empty()) return;
  DictionaryQuery q;
  q.add_term_dict(dict);
  Deinflector d;
  d.load_transforms_json(kEnTransforms);
  Lookup lk(q, d);
  const auto results = lk.lookup("belongs", 16);
  bool has_exact = false;
  bool has_lemma = false;
  for (const auto& r : results) {
    if (r.term.expression == "belongs" && r.trace.empty()) has_exact = true;
    if (r.term.expression == "belong" && !r.trace.empty()) has_lemma = true;
  }
  if (!has_exact || !has_lemma) {
    std::fprintf(stderr, "FAIL %s: real exact entry and lemma must survive; got %s\n",
                 label, dump_results(results).c_str());
    ++g_fail;
  }
}

// A boolean "is alias" plus shared bytes is still insufficient: the alias can
// point somewhere else that happens to reuse the lemma's definition.
void case_redirect_to_other_shared_definition_kept() {
  expect_english_exact_kept(write_mdx(
      "OtherRedirectTarget", {{"belong", "shared definition"},
                              {"belongs", "@@@LINK=ownership"},
                              {"ownership", "shared definition"}}), "other redirect target");
}

void case_english_shared_definition_without_provenance_kept() {
  expect_english_exact_kept(write_dict(
      "EnglishNoProvenance", {{"belong", "shared definition"},
                              {"belongs", "shared definition"}}), "no redirect provenance");
}

void case_chained_redirect_collapses_into_lemma() {
  expect_alias_collapses_into_lemma(write_mdx(
      "ChainedRedirectDict", {{"belong", "to be in the right place"},
                              {"belongs", "@@@LINK=belongAlias"},
                              {"belongAlias", "@@@LINK=belong"}}));
}

// Dictionaries imported before provenance existed cannot recover whether an
// equal-blob entry was an alias. Removing only the optional metadata simulates
// that on-disk format; the exact entry must survive after a fresh query load.
void case_existing_dictionary_without_provenance_kept() {
  const std::string dict = write_mdx(
      "ExistingRedirectDict", {{"belong", "shared definition"},
                               {"belongs", "@@@LINK=belong"}});
  if (dict.empty()) return;
  const auto metadata = std::filesystem::u8path(dict + "/redirects.bin");
  if (!std::filesystem::remove(metadata)) {
    fail("existing dictionary: new MDX import must write redirect provenance");
    return;
  }
  expect_english_exact_kept(dict, "existing dictionary without provenance");
}

void case_reimport_does_not_reuse_old_provenance() {
  const std::string original = write_mdx(
      "ReimportRedirectDict", {{"belong", "shared definition"},
                               {"belongs", "@@@LINK=belong"}});
  if (original.empty()) return;
  expect_alias_collapses_into_lemma(original);
  const std::string replacement = write_mdx(
      "ReimportRedirectDict", {{"belong", "shared definition"},
                               {"belongs", "shared definition"}});
  expect_english_exact_kept(replacement, "reimport must not reuse old provenance");
}

void case_invalid_provenance_keeps_dictionary_entries() {
  const std::string dict = write_mdx(
      "InvalidRedirectMetadata", {{"belong", "shared definition"},
                                  {"belongs", "@@@LINK=belong"}});
  if (dict.empty()) return;
  expect_alias_collapses_into_lemma(dict);
  const auto metadata = std::filesystem::u8path(dict + "/redirects.bin");
  {
    std::ofstream file(metadata, std::ios::binary | std::ios::trunc);
    file << "FUSHIRD1";  // Valid magic, truncated before the mandatory lengths.
    if (!file) {
      fail("cannot truncate test redirect metadata");
      return;
    }
  }
  expect_english_exact_kept(dict, "truncated redirect metadata");
}

void case_old_empty_marker_ignores_leftover_provenance() {
  const std::string dict = write_mdx(
      "OldMarkerRedirectDict", {{"belong", "shared definition"},
                                {"belongs", "@@@LINK=belong"}});
  if (dict.empty()) return;
  expect_alias_collapses_into_lemma(dict);
  {
    std::ofstream marker(std::filesystem::u8path(dict + "/.fushidicts_1"),
                         std::ios::binary | std::ios::trunc);
    if (!marker) { fail("cannot write old empty completion marker"); return; }
  }
  expect_english_exact_kept(dict, "old empty marker ignores leftover provenance");
}

void case_mismatched_import_nonce_ignores_leftover_provenance() {
  const std::string old_dict = write_mdx(
      "OldNonceRedirectDict", {{"belong", "shared definition"},
                               {"belongs", "@@@LINK=belong"}});
  const std::string new_dict = write_mdx(
      "NewNonceRedirectDict", {{"belong", "shared definition"},
                               {"belongs", "@@@LINK=belong"}});
  if (old_dict.empty() || new_dict.empty()) return;
  expect_alias_collapses_into_lemma(old_dict);
  expect_alias_collapses_into_lemma(new_dict);
  const auto read_blobs = [](const std::string& dir) {
    std::ifstream file(std::filesystem::u8path(dir + "/blobs.bin"), std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
  };
  if (read_blobs(old_dict) != read_blobs(new_dict)) {
    fail("nonce fixture must have identical dictionary blobs");
    return;
  }
  std::filesystem::copy_file(std::filesystem::u8path(old_dict + "/redirects.bin"),
                             std::filesystem::u8path(new_dict + "/redirects.bin"),
                             std::filesystem::copy_options::overwrite_existing);
  expect_english_exact_kept(new_dict, "other import nonce ignores leftover provenance");
}

void case_legacy_marker_ignores_new_marker_and_provenance() {
  const std::string dict = write_mdx(
      "LegacyOverlayRedirectDict", {{"belong", "shared definition"},
                                    {"belongs", "@@@LINK=belong"}});
  if (dict.empty()) return;
  expect_alias_collapses_into_lemma(dict);
  {
    std::ofstream marker(std::filesystem::u8path(dict + "/.hoshidicts_1"),
                         std::ios::binary | std::ios::trunc);
    if (!marker) { fail("cannot write legacy completion marker"); return; }
  }
  expect_english_exact_kept(dict, "legacy overlay ignores leftover new marker and provenance");
}

// A dictionary can define a headword independently and also carry a redirect
// with the same key and bytes. Only that redirect record may be collapsed.
void case_same_headword_independent_glossary_kept() {
  const std::string dict = write_mdx(
      "MixedSameHeadword", {{"belong", "shared definition"},
                            {"belongs", "shared definition"},
                            {"belongs", "@@@LINK=belong"}});
  expect_english_exact_kept(dict, "same headword independent glossary");
  if (dict.empty()) return;
  DictionaryQuery q;
  q.add_term_dict(dict);
  Deinflector d;
  d.load_transforms_json(kEnTransforms);
  Lookup lk(q, d);
  for (const auto& r : lk.lookup("belongs", 16)) {
    if (r.term.expression == "belongs" && r.term.glossaries.size() != 1) {
      fail("same headword: only the independent glossary must survive");
    }
  }
}

std::string write_stardict(const char* title, bool invalid_prefix_record = false,
                          bool synonym_targets_synonym = false) {
  const std::string base = fushi_test::temp_dir() + "/fushi_redirect_stardict";
  std::filesystem::create_directories(std::filesystem::u8path(base));
  const std::string prefix = base + "/" + title;
  const std::string definition = "to be in the right place";
  std::vector<uint8_t> idx;
  if (invalid_prefix_record) {
    const std::string invalid = "broken";
    idx.insert(idx.end(), invalid.begin(), invalid.end());
    idx.push_back(0);
    mdx_fixture::put_be32(idx, static_cast<uint32_t>(definition.size() + 1));
    mdx_fixture::put_be32(idx, 1);
  }
  const std::string lemma = "belong";
  idx.insert(idx.end(), lemma.begin(), lemma.end());
  idx.push_back(0);
  mdx_fixture::put_be32(idx, 0);
  mdx_fixture::put_be32(idx, static_cast<uint32_t>(definition.size()));
  std::vector<uint8_t> syn = {'b', 'e', 'l', 'o', 'n', 'g', 's', 0};
  mdx_fixture::put_be32(syn, invalid_prefix_record ? 1 : 0);
  if (synonym_targets_synonym) {
    const std::string invalid_alias = "belonged";
    syn.insert(syn.end(), invalid_alias.begin(), invalid_alias.end());
    syn.push_back(0);
    // Index 1 exists only after appending the first synonym. A .syn index must
    // refer to an original .idx record, so this second synonym is invalid.
    mdx_fixture::put_be32(syn, 1);
  }
  const std::string ifo = std::string("StarDict's dict ifo file\nversion=2.4.2\nbookname=") + title +
                          "\nwordcount=" + (invalid_prefix_record ? "2" : "1") +
                          "\nsynwordcount=" + (synonym_targets_synonym ? "2" : "1") +
                          "\nidxfilesize=" + std::to_string(idx.size()) + "\nsametypesequence=m\n";
  const auto write_bytes = [&](const char* extension, const char* data, size_t size) {
    std::ofstream file(std::filesystem::u8path(prefix + extension), std::ios::binary);
    file.write(data, static_cast<std::streamsize>(size));
    if (!file) fail("cannot write StarDict fixture");
  };
  write_bytes(".ifo", ifo.data(), ifo.size());
  write_bytes(".idx", reinterpret_cast<const char*>(idx.data()), idx.size());
  write_bytes(".dict", definition.data(), definition.size());
  write_bytes(".syn", reinterpret_cast<const char*>(syn.data()), syn.size());
  const auto imported = dictionary_importer::import(prefix + ".ifo", base + "/out");
  if (!imported.success) {
    fail(imported.errors.empty() ? "StarDict import failed" : imported.errors.front().c_str());
    return "";
  }
  return base + "/out/" + imported.title;
}

void case_stardict_synonym_collapses_into_lemma() {
  expect_alias_collapses_into_lemma(write_stardict("SynonymDict"));
}

void case_stardict_invalid_record_preserves_target_ordinal() {
  expect_alias_collapses_into_lemma(write_stardict("SynonymAfterInvalidRecord", true));
}

void case_stardict_synonym_cannot_target_appended_synonym() {
  const std::string dict = write_stardict("SynonymCannotTargetSynonym", false, true);
  expect_alias_collapses_into_lemma(dict);
  if (dict.empty()) return;
  DictionaryQuery q;
  q.add_term_dict(dict);
  if (!q.query("belonged").empty()) fail("StarDict: .syn ordinal must only address original .idx records");
}

}  // namespace

int main() {
  case_alias_collapses_into_lemma();
  case_distinct_inflected_entry_kept();
  case_spelling_variant_untouched();
  case_cross_dict_keeps_real_glossary();
  case_japanese_shared_definition_kept();
  case_japanese_mdx_real_entries_kept();
  case_japanese_yomitan_real_entries_kept();
  case_redirect_to_other_shared_definition_kept();
  case_english_shared_definition_without_provenance_kept();
  case_chained_redirect_collapses_into_lemma();
  case_existing_dictionary_without_provenance_kept();
  case_reimport_does_not_reuse_old_provenance();
  case_invalid_provenance_keeps_dictionary_entries();
  case_old_empty_marker_ignores_leftover_provenance();
  case_mismatched_import_nonce_ignores_leftover_provenance();
  case_legacy_marker_ignores_new_marker_and_provenance();
  case_same_headword_independent_glossary_kept();
  case_stardict_synonym_collapses_into_lemma();
  case_stardict_invalid_record_preserves_target_ordinal();
  case_stardict_synonym_cannot_target_appended_synonym();

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS: 20 redirect and independent-entry cases\n");
  return 0;
}
