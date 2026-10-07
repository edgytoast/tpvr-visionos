import SwiftUI

/// The top of every launcher, centred: the badge, the port's name in Space Mono with its signature
/// mixed weights ("SHAR **VR**"), what it is, and who made it.
public struct TrevorbiltHeader: View {
    private let title: String
    private let boldTitle: String
    private let subtitle: String
    private let byline: String

    public init(title: String, boldTitle: String, subtitle: String, byline: String = "An unofficial port by Trevorbilt") {
        self.title = title
        self.boldTitle = boldTitle
        self.subtitle = subtitle
        self.byline = byline
    }

    public var body: some View {
        VStack(spacing: 4) {
            // The badge, never stretched, with clear space of at least a quarter of its height.
            Trevorbilt.badge
                .resizable()
                .scaledToFit()
                .frame(width: 76)
                .padding(.bottom, 8)
                .accessibilityLabel("Trevorbilt")
            Text("\(Text(title).font(.tbHeader(35, relativeTo: .largeTitle)))\(Text(boldTitle).font(.tbHeader(35, bold: true, relativeTo: .largeTitle)))")
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.tbBody(15, weight: .medium, relativeTo: .title3))
                .multilineTextAlignment(.center)
            Link(destination: Trevorbilt.website) {
                Text(byline)
                    .font(.tbBody(12, relativeTo: .footnote))
                    .foregroundStyle(.white.opacity(0.8))
                    .underline()
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(.hoverEffect, .capsule)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityHint("Opens trevorbilt.com")
        }
        .frame(maxWidth: .infinity)
    }
}

/// A state at a glance: a tinted symbol, a headline and one line saying what to do about it.
public struct StatusHeadline: View {
    public enum Tone {
        case ready, missing, problem, working
    }

    private let tone: Tone
    private let title: String
    private let detail: String

    public init(_ tone: Tone, title: String, detail: String) {
        self.tone = tone
        self.title = title
        self.detail = detail
    }

    private var symbol: String {
        switch tone {
        case .ready: "checkmark.circle.fill"
        case .missing: "tray.and.arrow.down.fill"
        case .problem: "exclamationmark.triangle.fill"
        case .working: "arrow.down.circle.fill"
        }
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 22))
                .foregroundStyle(tone == .problem ? AnyShapeStyle(Trevorbilt.orangeTint) : AnyShapeStyle(.primary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.tbBody(15, weight: .bold, relativeTo: .headline))
                Text(detail)
                    .font(.tbBody(13, relativeTo: .subheadline))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
