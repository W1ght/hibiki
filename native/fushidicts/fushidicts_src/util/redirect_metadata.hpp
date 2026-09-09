#pragma once

#include <cstddef>
#include <array>
#include <cstdint>
#include <string_view>

namespace fushi::redirect_metadata {
// Optional sidecar, independent of the v1/v2 blobs.bin record layout. Integers
// use the same native byte order as blobs.bin. Header: magic, 16-byte import ID,
// u64 record-region base, u64 complete blobs.bin size. Entries: u64 relative term-record offset,
// u16 canonical-target UTF-8 byte length, target bytes. An absent/invalid file
// supplies no redirect provenance; readers must never infer it from glossaries.
// The existing .fushidicts_1 marker carries magic + the same import ID. Old
// readers only check marker existence, while new readers can reject a stale
// sidecar left by overlay-restoring a package from a different/legacy import.
using ImportId = std::array<uint32_t, 4>;
inline constexpr std::string_view kFilename = "redirects.bin";
inline constexpr std::string_view kMagic = "FUSHIRD1";
inline constexpr size_t kImportIdSize = sizeof(ImportId);
inline constexpr size_t kHeaderSize = 40;
}
