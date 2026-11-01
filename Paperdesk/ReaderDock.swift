import SwiftUI

struct ReaderDock: View {
    let model: ReaderModel
    let onJump: () -> Void

    var body: some View {
        PaperdeskGlassGroup {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    pageControls
                    zoomControls
                }
                VStack(spacing: 12) {
                    pageControls
                    zoomControls
                }
            }
            .padding(8)
            .paperdeskChrome()
        }
        .paperdeskActions()
        .controlSize(.regular)
        .padding(8)
        .frame(maxWidth: .infinity)
        .disabled(model.document == nil)
    }

    private var pageControls: some View {
        HStack(spacing: 8) {
            Button("Previous page", systemImage: "chevron.left") { model.go(model.page - 1) }
                .labelStyle(.iconOnly)
                .disabled(model.page <= 0)
            Button(action: onJump) {
                Text("\(model.page + 1) / \(model.document?.pageCount ?? 0)")
                    .monospacedDigit()
            }
            .accessibilityLabel("Page \(model.page + 1). Jump to page")
            Button("Next page", systemImage: "chevron.right") { model.go(model.page + 1) }
                .labelStyle(.iconOnly)
                .disabled(model.page + 1 >= (model.document?.pageCount ?? 0))
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button("Zoom out", systemImage: "minus.magnifyingglass") { model.view.zoomOut(nil) }
                .labelStyle(.iconOnly)
            Button("Fit page") { model.view.autoScales = true }
            Button("Zoom in", systemImage: "plus.magnifyingglass") { model.view.zoomIn(nil) }
                .labelStyle(.iconOnly)
        }
    }
}
