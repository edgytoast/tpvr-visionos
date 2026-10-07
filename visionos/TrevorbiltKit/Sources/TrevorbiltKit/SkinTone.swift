import SwiftUI

/// A skin tone for a drawn hand: one of the 24 skin-tone crayons in Crayola's Colors of the World
/// set (2020), so the hands in a port's guide can be anyone's. Never fixed to a hand: each is
/// picked at random whenever the drawing appears (see `HandTones`).
///
/// Crayola publishes no colour values for its crayons. The names and values here are those of the
/// "Colors of the World Crayons" table in Wikipedia's "List of Crayola crayon colors" (revision
/// 1377149575, 28 September 2026: https://en.wikipedia.org/w/index.php?title=List_of_Crayola_crayon_colors&oldid=1377149575),
/// approximations of the crayons. The set's eight hair and eye colours aren't skin tones and
/// aren't here.
public struct SkinTone: Hashable, Sendable {
    public let name: String
    /// 0xRRGGBB, sRGB.
    public let rgb: UInt32

    public init(_ name: String, _ rgb: UInt32) {
        self.name = name
        self.rgb = rgb
    }

    public var color: Color {
        Color(.sRGB, red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    /// The 24, in the table's order: the almond, golden and rose families, each deepest first.
    public static let colorsOfTheWorld: [SkinTone] = [
        SkinTone("Deepest Almond", 0x513529), SkinTone("Extra Deep Almond", 0x6E5046),
        SkinTone("Very Deep Almond", 0x88605E), SkinTone("Deep Almond", 0x986A5A),
        SkinTone("Medium Deep Almond", 0xAC8065), SkinTone("Medium Almond", 0xD19C7D),
        SkinTone("Light Medium Almond", 0xE0B5A4), SkinTone("Light Almond", 0xE6B9B3),
        SkinTone("Very Light Almond", 0xE6D2D3), SkinTone("Extra Light Almond", 0xEEE6CF),
        SkinTone("Extra Deep Golden", 0x5F452E), SkinTone("Deep Golden", 0x8D5B28),
        SkinTone("Medium Deep Golden", 0xA16B4F), SkinTone("Medium Golden", 0xDEA26C),
        SkinTone("Light Medium Golden", 0xF0C9A2), SkinTone("Light Golden", 0xEDDBC7),
        SkinTone("Very Light Golden", 0xF0DFCF),
        SkinTone("Extra Deep Rose", 0x6C4D4B), SkinTone("Very Deep Rose", 0x8F6C68),
        SkinTone("Deep Rose", 0xB86F69), SkinTone("Medium Deep Rose", 0xEE8E99),
        SkinTone("Light Medium Rose", 0xF4AFB2), SkinTone("Light Rose", 0xFAC7C3),
        SkinTone("Very Light Rose", 0xF7E1E3),
    ]

    public static func random() -> SkinTone { colorsOfTheWorld.randomElement()! }
}

/// Which hand a drawing (or a layer of one) is.
public enum Hand: Sendable {
    case left, right
}

/// The tone of each hand on a page: each picked on its own, at random.
public struct HandTones: Equatable, Sendable {
    public var left: SkinTone
    public var right: SkinTone

    public init(left: SkinTone, right: SkinTone) {
        self.left = left
        self.right = right
    }

    public static func random() -> HandTones { HandTones(left: .random(), right: .random()) }

    public subscript(hand: Hand) -> SkinTone { hand == .left ? left : right }
}

extension EnvironmentValues {
    /// The tones a page's tintable hands take (`randomHandTones()`); with none, each drawing picks
    /// its own.
    @Entry public var handTones: HandTones?
}

extension View {
    /// Gives every tintable hand drawing inside a skin tone for each hand, left and right, picked
    /// afresh at random each time this appears: so on a page, the pair and the poses in its legend
    /// share a left hand's tone and a right hand's.
    public func randomHandTones() -> some View {
        modifier(RandomHandTones())
    }
}

private struct RandomHandTones: ViewModifier {
    @State private var tones = HandTones.random()
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .environment(\.handTones, tones)
            // Fresh ones each time it's back in view (the first time, those it started with).
            .onAppear {
                if shown { tones = .random() }
                shown = true
            }
    }
}
