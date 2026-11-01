import SwiftUI

enum PaperdeskPalette {
    static let teal = Color("BrandAccent")
    static let actionTeal = Color(red: 0.02, green: 0.32, blue: 0.32)
    static let ivory = Color(red: 0.97, green: 0.96, blue: 0.92)
    static let ink = Color(red: 0.08, green: 0.12, blue: 0.14)
}

private struct PaperdeskChrome: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(
                .background,
                in: RoundedRectangle(cornerRadius: 12))
        } else if #available(macOS 26, iOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct PaperdeskGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, iOS 26, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
    }
}

private struct PaperdeskActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.bordered)
    }
}

private struct PaperdeskProminentAction: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if #available(macOS 26, iOS 26, *), !reduceTransparency, contrast != .increased {
            content.tint(PaperdeskPalette.actionTeal).buttonStyle(.glassProminent)
        } else {
            content.tint(PaperdeskPalette.actionTeal).buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    func paperdeskProminentAction() -> some View { modifier(PaperdeskProminentAction()) }
    func paperdeskChrome() -> some View { modifier(PaperdeskChrome()) }
    func paperdeskActions() -> some View { modifier(PaperdeskActionStyle()) }
}

struct PaperdeskBackdrop: View {
    var body: some View {
        Rectangle().fill(.background).ignoresSafeArea()
    }
}

struct PaperdeskHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Paperdesk", systemImage: "books.vertical.fill").font(.headline)
                    Text(
                        "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")"
                    )
                    .foregroundStyle(.secondary)
                }
                Section("Privacy and local storage") {
                    Text(
                        "Your PDFs, notes, OCR and study materials are stored locally. Paperdesk has no accounts, telemetry, advertising, cloud AI or network fallback."
                    )
                    Text(
                        "Optional AI uses Apple’s on-device model when available. Extractive study works without it. The system manages model availability."
                    )
                    Text(
                        "Imports copy your PDF into the library. Exports and backups go only to locations you choose, which may include a file provider. Back up your library before removing the app."
                    )
                    Text(
                        "Searchable exports are derived copies: annotations are flattened and links, forms and bookmarks are omitted. The library original remains editable."
                    )
                }
                Section("Keyboard shortcuts") {
                    LabeledContent("Import PDF", value: "⌘O")
                    LabeledContent("Offline Study", value: "⇧⌘S")
                    LabeledContent("Write on PDF", value: "⇧⌘E")
                    LabeledContent("Answer study question", value: "⌘Return")
                    LabeledContent("Toggle on-device AI in Ask", value: "⇧⌘M")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("About & Help")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .tint(PaperdeskPalette.teal)
        #if os(macOS)
            .frame(minWidth: 480, idealWidth: 560, minHeight: 520)
        #endif
    }
}
