//
//  BeanMascotViews.swift
//  BeanNotes
//

import SwiftUI

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

    private var imageWidth: CGFloat { horizontalSizeClass == .compact ? 92 : 126 }
    private var imageHeight: CGFloat { horizontalSizeClass == .compact ? 126 : 172 }
    private var containerWidth: CGFloat { horizontalSizeClass == .compact ? 116 : 154 }
    private var containerHeight: CGFloat { horizontalSizeClass == .compact ? 158 : 202 }

    var body: some View {
        VStack(spacing: -4) {
            Text("Bean stopped by")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                }

            Image("BeanWelcomeImage")
                .resizable()
                .scaledToFit()
                .frame(width: imageWidth, height: imageHeight, alignment: .bottom)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 7)
        }
        .frame(width: containerWidth, height: containerHeight, alignment: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
