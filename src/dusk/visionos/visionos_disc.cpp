// dusk_visionos_check_disc (visionos_host.h): the launcher's check of a disc image
// before Play. Plain C++, apart from visionos_host.mm: the game's headers define
// BOOL their own way, which clashes with Objective-C's.

#include "dusk/visionos/visionos_host.h"

#include "dusk/iso_validate.hpp"

extern "C" const char* dusk_visionos_check_disc(const char* path) {
    if (path == nullptr || *path == '\0') {
        return "No disc image.";
    }
    dusk::iso::DiscInfo info{};
    switch (dusk::iso::inspect(path, info)) {
    case dusk::iso::ValidationError::Success:
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
