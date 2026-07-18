//
//  PageNavigatorSidebar.swift
//  BeanNotes
//

import SwiftData
import SwiftUI
import UIKit

private enum PageNavigatorDisplayMode: String {
    case compact
    case preview

    var toggled: Self {
        self == .compact ? .preview : .compact
    }

    var toggleIconName: String {
        self == .compact ? "rectangle.grid.1x2" : "list.bullet"
    }

    var toggleAccessibilityLabel: String {
        self == .compact ? "Show page previews" : "Show compact page list"
    }

    var accessibilityValue: String {
        self == .compact ? "Compact list" : "Preview list"
    }
}

struct PageNavigatorSidebar: View {
    var pages: [NotePage]
    var selectedPageID: UUID?
    var theme: BeanNotesTheme
    var showsThemeArtwork: Bool
    var previewRevision: Int
    var selectPage: (NotePage) -> Void
    var dismiss: () -> Void

    @AppStorage("pageNavigatorDisplayMode") private var displayModeRaw = PageNavigatorDisplayMode.preview.rawValue

    private var displayMode: PageNavigatorDisplayMode {
        PageNavigatorDisplayMode(rawValue: displayModeRaw) ?? .preview
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Pages")
                    .font(.title3.bold())

                Spacer()

                Text("\(pages.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button {
                    displayModeRaw = displayMode.toggled.rawValue
                } label: {
                    Image(systemName: displayMode.toggleIconName)
                        .font(.subheadline.bold())
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .background(.thinMaterial, in: Circle())
                .accessibilityLabel(displayMode.toggleAccessibilityLabel)
                .accessibilityValue(displayMode.accessibilityValue)
                .accessibilityHint("Switch the page navigator view")
                .accessibilityIdentifier("editor.pageNavigator.displayMode")

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.subheadline.bold())
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .background(.thinMaterial, in: Circle())
                .accessibilityLabel("Close page navigator")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: displayMode == .preview ? 14 : 8) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            pageButton(
                                page,
                                number: index + 1,
                                displayMode: displayMode
                            )
                                .id(page.id)
                        }
                    }
                    .padding(16)
                }
                .onAppear {
                    scrollToSelection(using: proxy, animated: false)
                }
                .onChange(of: selectedPageID) { _, _ in
                    scrollToSelection(using: proxy, animated: true)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Divider()
        }
        .shadow(color: .black.opacity(0.18), radius: 20, x: -8, y: 0)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.pageNavigator")
    }

    @ViewBuilder
    private func pageButton(
        _ page: NotePage,
        number: Int,
        displayMode: PageNavigatorDisplayMode
    ) -> some View {
        switch displayMode {
        case .compact:
            compactPageButton(page, number: number)
        case .preview:
            previewPageButton(page, number: number)
        }
    }

    private func previewPageButton(_ page: NotePage, number: Int) -> some View {
        let isSelected = selectedPageID == page.id

        return Button {
            selectPage(page)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                PageNavigatorThumbnail(
                    page: page,
                    theme: theme,
                    showsThemeArtwork: showsThemeArtwork,
                    previewRevision: previewRevision
                )
                .frame(maxWidth: .infinity)
                .frame(height: 164)

                HStack(spacing: 8) {
                    Text("Page \(number)")
                        .font(.headline)

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.accentColor)
                    }
                }
            }
            .padding(10)
            .background(
                isSelected ? theme.accentColor.opacity(0.14) : Color.secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? theme.accentColor : Color.secondary.opacity(0.14),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(number) preview")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint("Move to page \(number)")
        .accessibilityIdentifier("editor.pageNavigator.page.\(number)")
    }

    private func compactPageButton(_ page: NotePage, number: Int) -> some View {
        let isSelected = selectedPageID == page.id

        return Button {
            selectPage(page)
        } label: {
            HStack(spacing: 12) {
                Text("\(number)")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? theme.accentColor : .secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        isSelected ? theme.accentColor.opacity(0.16) : Color.secondary.opacity(0.1),
                        in: Circle()
                    )

                Text("Page \(number)")
                    .font(.headline)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isSelected ? theme.accentColor.opacity(0.14) : Color.secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? theme.accentColor : Color.secondary.opacity(0.14),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(number)")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint("Move to page \(number)")
        .accessibilityIdentifier("editor.pageNavigator.page.\(number)")
    }

    private func scrollToSelection(using proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedPageID else { return }
        if animated {
            withAnimation(.snappy) {
                proxy.scrollTo(selectedPageID, anchor: .center)
            }
        } else {
            proxy.scrollTo(selectedPageID, anchor: .center)
        }
    }
}

private struct PageNavigatorThumbnail: View {
    @Environment(\.modelContext) private var modelContext

    var page: NotePage
    var theme: BeanNotesTheme
    var showsThemeArtwork: Bool
    var previewRevision: Int

    @State private var image: UIImage?

    private let storage = LocalStorageService()
    private let thumbnailService = ThumbnailService()

    var body: some View {
        ZStack {
            theme.previewBackground

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                NoteBackgroundSurface(background: page.background, pageID: page.id)
                    .aspectRatio(pageAspectRatio, contentMode: .fit)
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: previewRequestID) {
            await loadPreview()
        }
    }

    private var pageAspectRatio: CGFloat {
        page.pageSize.width / max(page.pageSize.height, 1)
    }

    private var previewRequestID: String {
        let contentRevision = NotePageRenderSnapshot.contentRevision(for: page)
        return "\(page.id.uuidString)-\(contentRevision)-\(theme.rawValue)-\(showsThemeArtwork)-\(previewRevision)"
    }

    @MainActor
    private func loadPreview() async {
        if let storedURL = currentThumbnailURL() {
            image = await ImageMemoryCache.shared.imageInBackground(
                at: storedURL,
                maxPixelSize: 480
            )
        }

        do {
            let url = try await thumbnailService.generateThumbnailInBackground(
                for: page,
                theme: theme,
                showsBeanArtwork: showsThemeArtwork,
                maxDimension: 320
            )
            try Task.checkCancellation()
            image = await ImageMemoryCache.shared.imageInBackground(
                at: url,
                maxPixelSize: 480
            )
            try Task.checkCancellation()
            try modelContext.save()
        } catch is CancellationError {
            return
        } catch {
            // Keep the page background or last saved thumbnail as a reliable fallback.
        }
    }

    private func currentThumbnailURL() -> URL? {
        guard let relativePath = page.thumbnailFileName,
              ThumbnailService.isCurrentThumbnailPath(
                  relativePath,
                  pageID: page.id,
                  theme: theme,
                  contentRevision: NotePageRenderSnapshot.contentRevision(for: page),
                  showsBeanArtwork: showsThemeArtwork
              ) else {
            return nil
        }

        return try? storage.validatedURL(forRelativePath: relativePath)
    }
}
