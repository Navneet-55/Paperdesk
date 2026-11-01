import SwiftUI
import PDFKit

/// A moving window bounds both SwiftUI row state and raster work regardless of document length.
struct ReaderThumbnailRail: View {
    let url: URL
    let pageCount: Int
    let currentPage: Int
    let onPage: (Int) -> Void
    private var pages: Range<Int> { max(0, currentPage - 12)..<min(pageCount, currentPage + 13) }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if pages.lowerBound > 0 {
                        Button("Earlier") { onPage(max(0, currentPage - 12)) }
                    }
                    ForEach(pages, id: \.self) { page in
                        ReaderThumbnail(url: url, page: page, selected: page == currentPage) { onPage(page) }
                            .id(page)
                    }
                    if pages.upperBound < pageCount {
                        Button("Later") { onPage(min(pageCount - 1, currentPage + 12)) }
                    }
                }.padding(6)
            }
            .onChange(of: currentPage) { _, page in proxy.scrollTo(page, anchor: .center) }
            .onAppear { proxy.scrollTo(currentPage, anchor: .center) }
        }
    }
}

private struct ReaderThumbnail: View {
    let url: URL
    let page: Int
    let selected: Bool
    let action: () -> Void
    @State private var data: Data?
    @State private var label: String?
    var body: some View {
        Button(action: action) {
            VStack {
                Group {
                    #if os(macOS)
                    if let data, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
                    else { Image(systemName: "doc").resizable().scaledToFit().padding(20) }
                    #else
                    if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() }
                    else { Image(systemName: "doc").resizable().scaledToFit().padding(20) }
                    #endif
                }.frame(height: 100)
                Text(label ?? String(page + 1)).font(.caption2)
            }.padding(4)
                .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page + 1)")
        .accessibilityValue(label ?? String(page + 1))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: url) {
            label = await PDFPageToolsThumbnailCache.shared.label(url: url, index: page)
            data = try? await PDFPageToolsThumbnailCache.shared.thumbnail(
                row: PDFPageToolsRow(id: page, sourceURL: url, sourceIndex: page, label: ""))
        }
        .onDisappear { data = nil }
    }
}

struct CompanionReader: View {
    let title: String
    @State private var model: ReaderModel
    init(url: URL, title: String, initialPage: Int) {
        self.title = title
        _model = State(initialValue: ReaderModel(url: url, page: initialPage))
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                Button { model.go(max(0, model.page - 1)) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous comparison page")
                    .disabled(model.loading || model.document == nil || model.page <= 0)
                Text(model.document?.page(at: model.page)?.label ?? String(model.page + 1)).monospacedDigit()
                Button { model.go(min((model.document?.pageCount ?? 1) - 1, model.page + 1)) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next comparison page")
                    .disabled(model.loading || model.document == nil || model.page + 1 >= (model.document?.pageCount ?? 0))
                Button("Reload") { Task { await model.reload() } }
            }.font(.caption).padding(8).background(.background)
            Text("Read-only copy · Reload to see saved edits").font(.caption2).foregroundStyle(.secondary)
            if model.loading { ProgressView("Opening comparison PDF…") }
            else { PDFCanvas(model: model) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .task {
            await model.load()
            for await _ in NotificationCenter.default.notifications(named: .PDFViewPageChanged, object: model.view) {
                if let page = model.view.currentPage, let document = model.document {
                    model.page = document.index(for: page)
                    await model.loadJournalPage(page)
                }
            }
        }
        .onDisappear { model.stop() }
    }
}
