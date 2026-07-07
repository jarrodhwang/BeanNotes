//
//  ContentView.swift
//  BeanNotes
//
//  Created by Jarrod on 2026-07-02.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    static let welcomeSeenKey = "hasSeenBeanNotesWelcome"
    static let welcomeContentVersionKey = "beanNotesWelcomeContentVersion"
    static let currentWelcomeContentVersion = 9

    @AppStorage(AppTheme.storageKey) private var appThemeRaw = AppTheme.system.rawValue
    @AppStorage(BeanNotesTheme.storageKey) private var beanNotesThemeRaw = BeanNotesTheme.standard.rawValue
    @AppStorage(Self.welcomeSeenKey) private var hasSeenWelcome = false
    @AppStorage(Self.welcomeContentVersionKey) private var seenWelcomeContentVersion = 0

    @State private var isShowingWelcome = false

    private var beanNotesTheme: BeanNotesTheme {
        BeanNotesTheme(rawValue: beanNotesThemeRaw) ?? .standard
    }

    var body: some View {
        LibraryView()
            .environment(\.beanNotesTheme, beanNotesTheme)
            .tint(beanNotesTheme.accentColor)
            .background(beanNotesTheme.appBackground.ignoresSafeArea())
            .preferredColorScheme((AppTheme(rawValue: appThemeRaw) ?? .system).colorScheme)
            .onAppear {
                guard Self.shouldShowWelcome(
                    hasSeenWelcome: hasSeenWelcome,
                    seenContentVersion: seenWelcomeContentVersion
                ) else { return }
                isShowingWelcome = true
            }
            .sheet(
                isPresented: $isShowingWelcome,
                onDismiss: markWelcomeSeen
            ) {
                WelcomeToBeanNotesView(
                    theme: beanNotesTheme,
                    mode: hasSeenWelcome ? .featureUpdate : .firstRun
                ) {
                    isShowingWelcome = false
                    markWelcomeSeen()
                }
            }
    }

    static func shouldShowWelcome(hasSeenWelcome: Bool, seenContentVersion: Int) -> Bool {
        !hasSeenWelcome || seenContentVersion < currentWelcomeContentVersion
    }

    private func markWelcomeSeen() {
        hasSeenWelcome = true
        seenWelcomeContentVersion = Self.currentWelcomeContentVersion
    }
}

private struct WelcomeToBeanNotesView: View {
    enum Mode {
        case firstRun
        case featureUpdate
    }

    var theme: BeanNotesTheme
    var mode: Mode
    var dismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 22) {
                    welcomeImage(size: imageSize(for: proxy.size))

                    VStack(spacing: 10) {
                        Text(mode.title)
                            .font(.largeTitle.weight(.bold))
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(mode.subtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 440)
                    }

                    featureBadges

                    featureHighlights

                    Button(action: dismiss) {
                        Text(mode.buttonTitle)
                            .font(.headline)
                            .frame(maxWidth: 300)
                            .frame(height: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accentColor)
                    .padding(.top, 2)
                }
                .padding(.horizontal, horizontalPadding(for: proxy.size.width))
                .padding(.vertical, 30)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.cardBackground)
    }

    private func welcomeImage(size: CGFloat) -> some View {
        Image("BeanWelcomeImage")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: min(size * 0.24, 36), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: min(size * 0.24, 36), style: .continuous)
                    .stroke(.white.opacity(0.72), lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 10)
            .accessibilityLabel("Bean")
    }

    private var featureHighlights: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(mode.highlights, id: \.title) { highlight in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(highlight.title)
                            .font(.subheadline.weight(.semibold))

                        Text(highlight.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: highlight.systemImage)
                        .foregroundStyle(theme.accentColor)
                        .frame(width: 26)
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: 430, alignment: .leading)
    }

    private var featureBadges: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                featureBadge("Local", systemImage: "lock.shield")
                featureBadge("Pencil Guard", systemImage: "hand.raised")
                featureBadge("Precision Ink", systemImage: "scope")
            }

            VStack(spacing: 10) {
                featureBadge("Local", systemImage: "lock.shield")
                featureBadge("Pencil Guard", systemImage: "hand.raised")
                featureBadge("Zoom Detail", systemImage: "magnifyingglass")
            }
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(theme.accentColor)
    }

    private func featureBadge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
    }

    private func imageSize(for size: CGSize) -> CGFloat {
        min(154, max(96, min(size.width, size.height) * 0.28))
    }

    private func horizontalPadding(for width: CGFloat) -> CGFloat {
        width < 380 ? 22 : 36
    }
}

private extension WelcomeToBeanNotesView.Mode {
    struct Highlight {
        var title: String
        var detail: String
        var systemImage: String
    }

    var title: String {
        switch self {
        case .firstRun:
            "Welcome to BeanNotes"
        case .featureUpdate:
            "New in BeanNotes"
        }
    }

    var subtitle: String {
        switch self {
        case .firstRun:
            "A private note space for handwritten ideas, PDFs, images, and study notes."
        case .featureUpdate:
            "Drawing input can now stay Apple Pencil-only for clean scrolling, or switch to Pencil or Finger for quick markups."
        }
    }

    var buttonTitle: String {
        switch self {
        case .firstRun:
            "Start Writing"
        case .featureUpdate:
            "Continue Writing"
        }
    }

    var highlights: [Highlight] {
        [
            Highlight(
                title: "Drawing input mode",
                detail: "Keep fingers for page navigation, or enable finger drawing from Settings when you need it.",
                systemImage: "hand.raised"
            ),
            Highlight(
                title: "Light-touch ink controls",
                detail: "Precision width mode and nudges stay available for finer handwriting and diagrams.",
                systemImage: "scope"
            ),
            Highlight(
                title: "Vector-first drawing",
                detail: "PencilKit strokes stay editable and crisp while BeanNotes refreshes page rendering as you zoom.",
                systemImage: "scribble"
            )
        ]
    }
}

#Preview {
    ContentView()
        .modelContainer(
            for: [
                NotebookFolder.self,
                NoteDocument.self,
                NotePage.self,
                Attachment.self
            ],
            inMemory: true
        )
}
