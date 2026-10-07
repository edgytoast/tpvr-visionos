import CoreText
import SwiftUI
import UIKit

// The Trevorbilt brand, from its style guide: orange is the accent and appears on every screen, but
// sparingly; dark green grounds it; the secondary colours only support. Headers are Space Mono,
// everything else Roboto, both bundled (SIL Open Font License 1.1, Resources/Fonts).
public enum Trevorbilt {
    public static let orange = Color(red: 0xED / 255, green: 0x70 / 255, blue: 0x14 / 255)
    public static let darkGreen = Color(red: 0x0F / 255, green: 0x1A / 255, blue: 0x14 / 255)
    public static let green = Color(red: 0x2D / 255, green: 0x4F / 255, blue: 0x3A / 255)
    public static let sage = Color(red: 0x7E / 255, green: 0x9B / 255, blue: 0x86 / 255)
    public static let slate = Color(red: 0x4A / 255, green: 0x6B / 255, blue: 0x8A / 255)
    public static let gray = Color(red: 0x4A / 255, green: 0x4F / 255, blue: 0x4C / 255)
    public static let lightGray = Color(red: 0x70 / 255, green: 0x78 / 255, blue: 0x75 / 255)
    /// Orange for the odd word on glass (a tagline), where the brand orange is too dark to read:
    /// light enough for about two thirds of white's contrast. Warnings and links stay white, with
    /// the orange on their icon.
    public static let orangeTint = Color(red: 0xFF / 255, green: 0xCB / 255, blue: 0xA4 / 255)

    public static let website = URL(string: "https://trevorbilt.com")!

    /// Registers the bundled fonts for this process. Call once, early (the app's init): Info.plist's
    /// UIAppFonts can't see a package's resources.
    public static func registerFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true
        let urls = ["SpaceMono-Regular", "SpaceMono-Bold", "Roboto-Variable"].compactMap {
            Bundle.module.url(forResource: $0, withExtension: "ttf", subdirectory: "Fonts")
        }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { errors, _ in
            for error in errors as? [CFError] ?? [] { print("[TrevorbiltKit] a font didn't register: \(error)") }
            return true
        }
    }
    private static var fontsRegistered = false

    /// The badge: never recoloured or stretched, with clear space of a quarter of its height.
    public static var badge: Image { brandImage("trevorbilt-badge") }

    public static func brandImage(_ name: String) -> Image {
        if let path = Bundle.module.path(forResource: name, ofType: "png", inDirectory: "Brand"),
           let image = UIImage(contentsOfFile: path) {
            return Image(uiImage: image)
        }
        return Image(systemName: "questionmark.square.dashed")
    }
}

public extension Font {
    /// Space Mono, for headers, scaling with Dynamic Type like `style`.
    static func tbHeader(_ size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom(bold ? "SpaceMono-Bold" : "SpaceMono-Regular", size: size, relativeTo: style)
    }

    /// Roboto, for everything that isn't a header. No light weights: they're hard to read in a headset.
    static func tbBody(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Roboto", size: size, relativeTo: style).weight(weight)
    }
}

/// The one primary action on a screen: an orange capsule with a dark green label (5.9:1), or
/// while it can't be pressed, glass grey with a dim label (orange only when it does something).
/// `width` nil fills the width.
public struct TrevorbiltPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    private let width: CGFloat?

    public init(width: CGFloat? = nil) {
        self.width = width
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.tbBody(18, weight: .bold, relativeTo: .title3))
            .foregroundStyle(isEnabled ? AnyShapeStyle(Trevorbilt.darkGreen) : AnyShapeStyle(.white.opacity(0.55)))
            .padding(.horizontal, 24)
            .frame(maxWidth: width == nil ? .infinity : nil, minHeight: 56)
            .frame(width: width)
            .background(isEnabled ? AnyShapeStyle(Trevorbilt.orange) : AnyShapeStyle(.white.opacity(0.12)), in: .capsule)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(.hoverEffect, .capsule)
            .hoverEffect(.lift)
    }
}

/// Everything else you can press: a glass capsule, 44 pt tall (visionOS's 60 pt target counts the
/// space around it).
public struct TrevorbiltSecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.tbBody(14, weight: .medium, relativeTo: .body))
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(.white.opacity(configuration.isPressed ? 0.2 : 0.1), in: .capsule)
            .contentShape(.hoverEffect, .capsule)
            .hoverEffect(.highlight)
    }
}

/// A card you can press, and that may be the selected one: it lifts on gaze, and when selected
/// wears an orange ring and sits a little forward of the others.
public struct TrevorbiltTileButtonStyle: ButtonStyle {
    private let selected: Bool
    private let cornerRadius: CGFloat

    public init(selected: Bool = false, cornerRadius: CGFloat = 18) {
        self.selected = selected
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .background(.white.opacity(selected ? 0.14 : 0.07), in: shape)
            .overlay {
                shape.strokeBorder(selected ? AnyShapeStyle(Trevorbilt.orange) : AnyShapeStyle(.white.opacity(0.1)),
                                   lineWidth: selected ? 2 : 1)
            }
            .contentShape(.hoverEffect, shape)
            .contentShape(shape)
            .hoverEffect(.lift)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .shadow(color: .black.opacity(selected ? 0.3 : 0), radius: 10, y: 4)
            .offset(z: selected ? 8 : 0)
            .animation(.smooth(duration: 0.25), value: selected)
    }
}

/// A group of related content on the window's glass: a shade brighter than it, with a hairline edge.
public struct TrevorbiltCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat
    private let alignment: Alignment

    public init(padding: CGFloat = 16, alignment: Alignment = .leading, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.padding = padding
        self.alignment = alignment
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: alignment)
            .background(.white.opacity(0.07), in: shape)
            .overlay { shape.strokeBorder(.white.opacity(0.1), lineWidth: 1) }
    }
}

/// A heading in Space Mono with the brand's mixed weights: "how to **play**".
public struct TrevorbiltHeading: View {
    private let regular: String
    private let bold: String
    private let size: CGFloat

    public init(_ regular: String, bold: String, size: CGFloat = 24) {
        self.regular = regular
        self.bold = bold
        self.size = size
    }

    public var body: some View {
        Text("\(Text(regular).font(.tbHeader(size, relativeTo: .title)))\(Text(bold).font(.tbHeader(size, bold: true, relativeTo: .title)))")
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A small heading over a group, in Space Mono capitals: "PLAY AS".
public struct TrevorbiltSectionTitle: View {
    private let text: String
    private let alignment: Alignment

    public init(_ text: String, alignment: Alignment = .center) {
        self.text = text
        self.alignment = alignment
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.tbHeader(11, bold: true, relativeTo: .caption))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: alignment)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A choice among a few, as a row of capsules: the selected one wears the orange ring.
public struct TrevorbiltChip: View {
    private let title: String
    private let selected: Bool
    private let action: () -> Void

    public init(_ title: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.tbBody(13, weight: selected ? .bold : .medium, relativeTo: .callout))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(.white.opacity(selected ? 0.16 : 0.07), in: .capsule)
                .overlay { Capsule().strokeBorder(selected ? AnyShapeStyle(Trevorbilt.orange) : AnyShapeStyle(.white.opacity(0.1)),
                                                  lineWidth: selected ? 2 : 1) }
                .contentShape(.hoverEffect, .capsule)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A numbered marker on a drawing, and beside its line in the legend.
public struct TrevorbiltMarker: View {
    private let number: Int
    private let size: CGFloat

    public init(_ number: Int, size: CGFloat = 22) {
        self.number = number
        self.size = size
    }

    public var body: some View {
        Text("\(number)")
            .font(.tbHeader(size * 0.5, bold: true, relativeTo: .callout))
            .foregroundStyle(Trevorbilt.darkGreen)
            .frame(width: size, height: size)
            .background(Trevorbilt.orange, in: .circle)
            .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5) }
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .accessibilityHidden(true)
    }
}

/// A row that wraps onto more lines when it runs out of width, each line centred (or leading).
public struct TrevorbiltFlow: Layout {
    private let alignment: HorizontalAlignment
    private let spacing: CGFloat

    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat = 10) {
        self.alignment = alignment
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
        // Fill a finite width (lines centre in it); with none, take what the longest line needs.
        let proposed = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        return CGSize(width: proposed ?? width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = alignment == .leading ? bounds.minX : bounds.minX + (bounds.width - line.width) / 2
            for index in line.indices {
                let size = Self.size(of: subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var lines: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = Self.size(of: subviews[index], width: width)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width && !current.indices.isEmpty {
                lines.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }

    /// Its own size, but never wider than the row: one too wide (large text) wraps or truncates.
    private static func size(of subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}

/// A sheet's content: Done at the top, then the content, centred. Sized to fit it, or with
/// `height`, that tall, scrolling what doesn't fit.
public struct SheetContent<Content: View>: View {
    private let done: () -> Void
    private let width: CGFloat
    private let height: CGFloat?
    private let content: Content

    public init(width: CGFloat = 520, height: CGFloat? = nil, done: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.done = done
        self.width = width
        self.height = height
        self.content = content()
    }

    public var body: some View {
        Group {
            if let height {
                ScrollView { column }.frame(width: width, height: height)
            } else {
                column.frame(width: width)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button("Done", action: done)
                .buttonStyle(TrevorbiltSecondaryButtonStyle())
                .padding(12)
        }
        .presentationSizing(.fitted)
    }

    private var column: some View {
        VStack(spacing: 14) {
            content
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .padding(.bottom, 24)
    }
}
