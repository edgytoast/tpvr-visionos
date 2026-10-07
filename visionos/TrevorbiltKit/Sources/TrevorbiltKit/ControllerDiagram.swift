import SwiftUI
import UIKit

/// A drawing (a port's own, like SHAR's hands, or the kit's) and where each of its controls is,
/// from generated art: an image and `<name>-anchors`, a JSON data asset of {"width", "height",
/// "anchors": {control: [x, y]}} in the drawing's coordinates. Controllers have their own view:
/// ControllerCallouts.
///
/// The kit's own hands (`hands`, `hand(_:)`) are drawn to tint: a layer a hand, its skin white,
/// multiplied by a skin tone picked at random each time it appears (`SkinTone`, `HandTones`), and
/// any marks (the touch spark, the motion arrows) over it, untinted. A port's own art is drawn as
/// it is.
public struct ControllerArt {
    /// A layer of the drawing; `hand`, the hand whose tone it takes (nil: drawn as it is).
    public struct Layer {
        public let image: Image
        public let hand: Hand?
    }

    public let layers: [Layer]
    public let size: CGSize
    public let anchors: [String: CGPoint]

    /// A port's own drawing, drawn as it is.
    public init(named name: String, bundle: Bundle) {
        self.init(layers: [Layer(image: Image(name, bundle: bundle), hand: nil)], anchors: name + "-anchors", drawing: name, bundle: bundle)
    }

    /// Both of the kit's hands, open, palms towards you, the left on the left: with where each
    /// fingertip, thumb and palm is (leftIndex, rightThumb, rightPalm...), for ControllerDiagram.
    public static let hands = ControllerArt(
        layers: [Layer(image: Image("hands-pair-left", bundle: .module), hand: .left),
                 Layer(image: Image("hands-pair-right", bundle: .module), hand: .right)],
        anchors: "hands-pair-anchors", drawing: "hands-pair-left", bundle: .module)

    /// One of the kit's hand poses, for a legend (ControlItem's `pose`).
    public static func hand(_ pose: HandPose) -> ControllerArt {
        var layers = [Layer(image: Image(pose.rawValue, bundle: .module), hand: pose.hand)]
        if pose.hasMarks { layers.append(Layer(image: Image(pose.rawValue + "-marks", bundle: .module), hand: nil)) }
        return ControllerArt(layers: layers, anchors: nil, drawing: pose.rawValue, bundle: .module)
    }

    /// `drawing`: an image of it, whose size it takes when there are no anchors to give one.
    private init(layers: [Layer], anchors name: String?, drawing: String, bundle: Bundle) {
        self.layers = layers
        struct Anchors: Decodable { let width: Double; let height: Double; let anchors: [String: [Double]] }
        if let name, let data = NSDataAsset(name: name, bundle: bundle)?.data,
           let decoded = try? JSONDecoder().decode(Anchors.self, from: data) {
            size = CGSize(width: decoded.width, height: decoded.height)
            anchors = decoded.anchors.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        } else {
            size = UIImage(named: drawing, in: bundle, with: nil)?.size ?? CGSize(width: 480, height: 300)
            anchors = [:]
        }
    }
}

/// The kit's hand poses (`ControllerArt.hand(_:)`): the thumb touching a finger, some moved like a
/// stick (move: four ways; steer, turn: side to side), a fist with either hand, a swing.
public enum HandPose: String, CaseIterable, Sendable {
    case pinchIndexLeft = "hand-pinch-index-left", pinchIndexRight = "hand-pinch-index-right"
    case pinchMiddleLeft = "hand-pinch-middle-left", pinchMiddleRight = "hand-pinch-middle-right"
    case pinchMiddleLeftMove = "hand-pinch-middle-left-move", pinchMiddleLeftSteer = "hand-pinch-middle-left-steer"
    case pinchRingLeft = "hand-pinch-ring-left", pinchRingRight = "hand-pinch-ring-right"
    case pinchLittleLeft = "hand-pinch-little-left", pinchLittleRightTurn = "hand-pinch-little-right-turn"
    case fistLeft = "hand-fist-left", fistRight = "hand-fist-right", swingRight = "hand-swing-right"

    public var hand: Hand { rawValue.contains("-left") ? .left : .right }
    /// A spark where the thumb touches, or motion arrows or lines: all but the fists.
    var hasMarks: Bool { self != .fistLeft && self != .fistRight }
}

/// A ControllerArt drawn: its layers stacked, each hand's tinted with its tone, the page's
/// (`randomHandTones()`) or, with none, its own, picked at random each time it appears.
public struct ControllerArtImage: View {
    private let art: ControllerArt
    @Environment(\.handTones) private var pageTones
    @State private var ownTones = HandTones.random()
    @State private var shown = false

    public init(_ art: ControllerArt) {
        self.art = art
    }

    public var body: some View {
        let tones = pageTones ?? ownTones
        ZStack {
            ForEach(art.layers.indices, id: \.self) { index in
                let layer = art.layers[index]
                if let hand = layer.hand {
                    layer.image.resizable().colorMultiply(tones[hand].color)
                } else {
                    layer.image.resizable()
                }
            }
        }
        .aspectRatio(art.size, contentMode: .fit)
        .onAppear {
            if shown { ownTones = .random() }
            shown = true
        }
    }
}

/// One control in a guide: its number on a drawing and in the legend, what it does, how, and
/// which control does it (`anchor`; nil for what no control does, like a swing of the hand).
/// `also`: other controls that do it too, each with what to show there ("Run (hold click)").
/// `symbol`: the connected controller's own symbol for it (sfSymbolsName); `image`: a picture of
/// it instead (a port's own hand pose); `pose`: one of the kit's, tinted.
public struct ControlItem: Identifiable {
    public let number: Int
    public let action: String
    public let how: String
    public let anchor: String?
    public let also: [String: String]
    public let symbol: String?
    public let image: Image?
    public let pose: ControllerArt?

    public var id: Int { number }

    public init(_ number: Int, _ action: String, _ how: String, anchor: String?, also: [String: String] = [:],
                symbol: String? = nil, image: Image? = nil, pose: ControllerArt? = nil) {
        self.number = number
        self.action = action
        self.how = how
        self.anchor = anchor
        self.also = also
        self.symbol = symbol
        self.image = image
        self.pose = pose
    }
}

/// The drawing with a numbered orange marker on each control. Markers that share a control stack
/// downwards from it (along a finger, on the hands).
public struct ControllerDiagram: View {
    private let art: ControllerArt
    private let items: [ControlItem]
    private let markerSize: CGFloat

    /// `markerSize`: the markers' diameter. Markers that would overlap are nudged apart, so any
    /// drawing at any size keeps them readable.
    public init(art: ControllerArt, items: [ControlItem], markerSize: CGFloat = 22) {
        self.art = art
        self.items = items
        self.markerSize = markerSize
    }

    public var body: some View {
        ControllerArtImage(art)
            .overlay {
                GeometryReader { geometry in
                    let points = positions(scale: geometry.size.width / art.size.width)
                    ForEach(points, id: \.number) { marker in
                        TrevorbiltMarker(marker.number, size: markerSize)
                            .position(marker.point)
                    }
                }
            }
            .accessibilityHidden(true)
    }

    /// Where each marker goes at `scale`: on its control (stacked downwards when controls share
    /// one), then pushed apart from any it would overlap, a little at a time, both moving.
    private func positions(scale: CGFloat) -> [(number: Int, point: CGPoint)] {
        var byAnchor: [String: [ControlItem]] = [:]
        for item in items {
            if let anchor = item.anchor, art.anchors[anchor] != nil { byAnchor[anchor, default: []].append(item) }
        }
        var placed = byAnchor.sorted { $0.key < $1.key }.flatMap { anchor, shared in
            shared.enumerated().map { index, item in
                let point = art.anchors[anchor]!
                return (number: item.number, point: CGPoint(x: point.x * scale, y: point.y * scale + CGFloat(index) * (markerSize + 2)))
            }
        }
        let clearance = markerSize + 2
        for _ in 0..<12 {
            var moved = false
            for i in placed.indices {
                for j in placed.indices where j > i {
                    let dx = placed[j].point.x - placed[i].point.x, dy = placed[j].point.y - placed[i].point.y
                    let distance = (dx * dx + dy * dy).squareRoot()
                    guard distance < clearance else { continue }
                    let (ux, uy) = distance > 0.01 ? (dx / distance, dy / distance) : (1, 0)
                    let push = (clearance - distance) / 2
                    placed[i].point.x -= ux * push; placed[i].point.y -= uy * push
                    placed[j].point.x += ux * push; placed[j].point.y += uy * push
                    moved = true
                }
            }
            if !moved { break }
        }
        return placed
    }
}

/// The legend for a diagram: a tile per control, stacked (beside the drawing), each with its
/// number, what it does and how, and the controller's own symbol (or a picture) when there is one.
public struct ControlsLegend: View {
    private let items: [ControlItem]

    public init(items: [ControlItem]) {
        self.items = items
    }

    public var body: some View {
        VStack(spacing: 5) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    TrevorbiltMarker(item.number, size: 24)
                    if let pose = item.pose {
                        ControllerArtImage(pose).frame(width: 24, height: 28).accessibilityHidden(true)
                    } else if let image = item.image {
                        image.resizable().scaledToFit().frame(width: 24, height: 28).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.action).font(.tbBody(13, weight: .bold, relativeTo: .headline))
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let symbol = item.symbol {
                                Image(systemName: symbol).symbolRenderingMode(.hierarchical).accessibilityHidden(true)
                            }
                            Text(item.how).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.tbBody(12, relativeTo: .caption))
                        .foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.number). \(item.action): \(item.how)")
            }
        }
    }
}
