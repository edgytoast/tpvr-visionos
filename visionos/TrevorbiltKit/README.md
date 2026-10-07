# TrevorbiltKit

The launcher every Trevorbilt Vision Pro port shares: the brand (colours, Space Mono and Roboto,
the badge, buttons, cards and chips), the centred header, the mode cards and their drawings, the
input ornament, the controls guide's pieces, the Ports tab (the AVP Ports Index) and About. Each
port supplies only what's its own: its title, modes, which inputs each mode plays with, its
game-files card, its controls mapping, credits and licences.

`ControllerCallouts(rig:controls:)` draws a DualSense-style pad, an Xbox-style pad or a pair of
Sense-style hand controllers (our own illustrations, no maker's artwork or logos) with a callout on each
control that does something: the connected controller's own SF Symbol for it (GameController's
`sfSymbolsName`, or `GlyphControl.neutralSymbol(_:for:)`, the drawing's family's, with nothing
connected), what it does and its name, joined to its button by a dotted line. Controls are named
alike everywhere (`leftStick`, `a`, `rightTrigger`...). `ControllerDiagram` puts
numbered markers on a port's own drawing (SHAR's hands), from an image and an anchors JSON.

For a port whose hands aren't its own (SHAR's are the show's yellow, drawn into its own app), the
kit has hands: `ControllerArt.hands` (both, open, with each fingertip's anchor) and
`ControllerArt.hand(_:)` (a `HandPose`, for a `ControlItem`'s `pose` in the legend). Each hand is
drawn to tint and takes a skin tone from Crayola's Colors of the World crayons (`SkinTone`, the 24
skin tones), picked at random each time the drawing appears, never fixed to a hand. Put
`.randomHandTones()` on the page so the pair and the legend's poses share a left hand's tone and a
right hand's; without it, each drawing picks its own. Crayola publishes no colour values: the names
and values are those of Wikipedia's "List of Crayola crayon colors"
([revision 1377149575](https://en.wikipedia.org/w/index.php?title=List_of_Crayola_crayon_colors&oldid=1377149575#Colors_of_the_World),
28 September 2026), approximations; Crayola and Colors of the World are trademarks of Crayola LLC,
named here only to say where the tones come from. The drawings come from SHAR's
`scripts/make-hand-art.py`.

It's vendored into each port as a local Swift package (a path dependency), so everything the app
runs is in the port's own repository. The code is MIT (`LICENSE`); the fonts are under the SIL Open
Font License 1.1 (`Resources/Fonts/OFL-*.txt`); the brand assets are not licensed
(`Resources/Brand/NOTICE.md`).
