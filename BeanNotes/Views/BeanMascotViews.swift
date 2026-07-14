//
//  BeanMascotViews.swift
//  BeanNotes
//

import SwiftUI

struct BeanVisit: Identifiable, Equatable {
    enum Placement: CaseIterable, Equatable {
        case topLeading
        case top
        case topTrailing
        case leading
        case trailing
        case bottomLeading
        case bottom
        case bottomTrailing

        var alignment: Alignment {
            switch self {
            case .topLeading: .topLeading
            case .top: .top
            case .topTrailing: .topTrailing
            case .leading: .leading
            case .trailing: .trailing
            case .bottomLeading: .bottomLeading
            case .bottom: .bottom
            case .bottomTrailing: .bottomTrailing
            }
        }

        var entranceEdge: Edge {
            switch self {
            case .topLeading, .leading, .bottomLeading: .leading
            case .top, .topTrailing: .top
            case .trailing, .bottomTrailing: .trailing
            case .bottom: .bottom
            }
        }
    }

    enum Artwork: CaseIterable {
        case cozyPortrait
        case curiousAvatar
        case littleBadge

        var imageName: String {
            switch self {
            case .cozyPortrait:
                "BeanWelcomeImage"
            case .curiousAvatar:
                "BeanTabAvatar"
            case .littleBadge:
                "BeanBadge"
            }
        }

        var maximumImageHeight: CGFloat {
            switch self {
            case .cozyPortrait:
                172
            case .curiousAvatar, .littleBadge:
                128
            }
        }
    }

    let id: UUID
    let reason: BeanVisitPolicy.VisitReason
    let artwork: Artwork
    let placement: Placement
    let saying: BeanVisitPolicy.Saying

    static func make(reason: BeanVisitPolicy.VisitReason) -> BeanVisit {
        BeanVisit(
            id: UUID(),
            reason: reason,
            artwork: Artwork.allCases.randomElement() ?? .cozyPortrait,
            placement: Placement.allCases.randomElement() ?? .bottomTrailing,
            saying: reason.randomSaying()
        )
    }
}

struct BeanAvatarView: View {
    var size: CGFloat

    var body: some View {
        Image("BeanTabAvatar")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.78), lineWidth: max(1, size * 0.045))
            }
            .shadow(color: .black.opacity(0.14), radius: size * 0.09, y: size * 0.04)
            .accessibilityHidden(true)
    }
}

struct BeanBadgeView: View {
    var size: CGFloat

    var body: some View {
        Image("BeanBadge")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .stroke(.white.opacity(0.68), lineWidth: max(1, size * 0.045))
            }
            .shadow(color: .black.opacity(0.12), radius: size * 0.08, y: size * 0.035)
            .accessibilityHidden(true)
    }
}

struct BeanThemeHintView: View {
    var message: String

    var body: some View {
        HStack(spacing: 10) {
            BeanAvatarView(size: 34)

            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct BeanPetVisitView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var visit: BeanVisit

    private var imageWidth: CGFloat { horizontalSizeClass == .compact ? 94 : 128 }
    private var imageHeight: CGFloat {
        min(
            horizontalSizeClass == .compact ? 126 : 172,
            visit.artwork.maximumImageHeight
        )
    }
    private var containerWidth: CGFloat { horizontalSizeClass == .compact ? 168 : 212 }
    private var containerHeight: CGFloat { horizontalSizeClass == .compact ? 190 : 232 }

    var body: some View {
        VStack(spacing: 5) {
            VStack(spacing: 2) {
                Text(visit.saying.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(visit.saying.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            }

            Image(visit.artwork.imageName)
                .resizable()
                .scaledToFit()
                .frame(width: imageWidth, height: imageHeight, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 7)
        }
        .frame(width: containerWidth, height: containerHeight, alignment: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct BeanVisitOverlayView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var visit: BeanVisit?

    var body: some View {
        ZStack {
            if let visit {
                BeanPetVisitView(visit: visit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: visit.placement.alignment)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .transition(transition(for: visit))
                    .zIndex(4)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func transition(for visit: BeanVisit) -> AnyTransition {
        accessibilityReduceMotion
            ? .opacity
            : .move(edge: visit.placement.entranceEdge).combined(with: .opacity)
    }
}
