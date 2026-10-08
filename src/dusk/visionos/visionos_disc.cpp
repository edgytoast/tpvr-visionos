// dusk_visionos_check_disc (visionos_host.h): the launcher's check of a disc image
// before Play. Plain C++, apart from visionos_host.mm: the game's headers define
// BOOL their own way, which clashes with Objective-C's.

#include "dusk/visionos/visionos_host.h"

#include "dusk/iso_validate.hpp"

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <vector>

namespace {

uint32_t be32(const unsigned char* p) {
    return uint32_t{p[0]} << 24 | uint32_t{p[1]} << 16 | uint32_t{p[2]} << 8 | p[3];
}

// Whether a plain GameCube image (.iso, .gcm) holds every file its file table lists. The header
// check above reads only the game's ID, and a copy or download cut short passes it: the game then
// stops at its first read past the end (a fatal error), or reads zeros. Trimmed images, which drop
// only the padding after the last file, are whole by this test. Other formats, and Wii images,
// aren't looked at here.
bool gamecube_image_cut_short(const char* path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) {
        return false;
    }
    const uint64_t length = static_cast<uint64_t>(file.tellg());
    unsigned char header[0x430];
    file.seekg(0);
    if (!file.read(reinterpret_cast<char*>(header), sizeof header)) {
        return length >= 0x20 && be32(header + 0x1C) == 0xC2339F3D;
    }
    if (be32(header + 0x1C) != 0xC2339F3D) {
        return false;  // not a plain GameCube image
    }
    const uint64_t dol = be32(header + 0x420), fst = be32(header + 0x424), fstSize = be32(header + 0x428);
    if (dol >= length || fst + fstSize > length || fstSize < 12 || fstSize > (64u << 20)) {
        return true;
    }
    std::vector<unsigned char> table(fstSize);
    file.seekg(static_cast<std::streamoff>(fst));
    if (!file.read(reinterpret_cast<char*>(table.data()), static_cast<std::streamsize>(fstSize))) {
        return true;
    }
    const uint64_t entries = std::min<uint64_t>(be32(table.data() + 8), fstSize / 12);
    uint64_t end = 0;
    for (uint64_t i = 1; i < entries; ++i) {
        const unsigned char* entry = table.data() + i * 12;
        if (entry[0] == 0) {  // a file: its offset and length
            end = std::max<uint64_t>(end, uint64_t{be32(entry + 4)} + be32(entry + 8));
        }
    }
    return end > length;
}

}  // namespace

extern "C" const char* dusk_visionos_check_disc(const char* path) {
    if (path == nullptr || *path == '\0') {
        return "No disc image.";
    }
    dusk::iso::DiscInfo info{};
    switch (dusk::iso::inspect(path, info)) {
    case dusk::iso::ValidationError::Success:
        if (gamecube_image_cut_short(path)) {
            return "This disc image is incomplete: it ends before the game's files do. Copy it in again.";
        }
        return nullptr;
    case dusk::iso::ValidationError::IOError:
        return "The disc image couldn't be read. Copy it in again.";
    case dusk::iso::ValidationError::InvalidImage:
        return "This file isn't a disc image the game can read, or it's incomplete. Copy it in again.";
    case dusk::iso::ValidationError::WrongGame:
        return "This disc image isn't Twilight Princess.";
    case dusk::iso::ValidationError::WrongVersion:
        return "This Twilight Princess release isn't supported. Use a GameCube disc (GZ2E01, GZ2P01, GZ2J01) or a "
               "Wii disc other than the Korean release.";
    default:
        return "The disc image couldn't be checked. Copy it in again.";
    }
}
