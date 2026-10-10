#pragma once

// Window mode: the PS VR2 Sense controllers as one gamepad. Outside a Full Space visionOS gives an
// app no controller tracking, but GameController still reports each half's buttons, triggers and
// stick, so the two halves are joined into one SDL virtual gamepad that Dusklight reads like any
// other (and its menus too), laid out as a gamepad held in two hands:
//
//   right half  Cross A, Circle B, R2 R (analog), R1 Z, Options Start, stick C-stick
//   left half   Square X, Triangle Y, L2 L (analog, targeting), stick the main stick
//   D-pad       L1 up (item ring), Create left (map), L3 down, R3 right
//
// It takes player 1 unless a real gamepad has it, and gives player 1 up to a gamepad that arrives:
// in the window a gamepad plays whenever one is on.

union SDL_Event;

namespace dusk::visionos::sense_pad {

// Game thread, once a frame in window mode. Attaches the gamepad while a Sense controller is
// connected, detaches it when none is.
void update();

// Game thread, once a frame in every mode. SDL also opens each Sense half as a gamepad of its own,
// which nothing should play (the VR mod reads the halves through the OpenXR provider, Window mode
// through the joined gamepad): they lose their player slots. And a real gamepad that arrives on a
// slot past player 1 while no other real gamepad has player 1 (the joined pad gives it up), or is
// left there when the joined pad goes, takes it, once, so a later choice in Settings › Input stands. In Full, a half on player 1 doubled the
// Sense buttons with the original game's, and a gamepad connected after the halves landed on a
// slot nothing read.
void tidy_ports();

// SDL's own view of a Sense half (its MFi driver lists each as a gamepad): the game's UI skips
// these events, or each press arrived twice (the half's, then the joined pad's).
bool ignores(const SDL_Event& event);

}  // namespace dusk::visionos::sense_pad
