import SwiftUI

struct OfflineStudyView: View {
    let url: URL
    let title: String
    let currentPage: Int
    let onPage: (Int) -> Void
    let onSaveNote: (String) throws -> Void
    var onSaveCards: (([StudyCard]) async throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var service = OfflineStudyService()
    @State private var currentPageOnly = false
    @State private var section = StudySection.summary
    @State private var material: StudyMaterial?
    @State private var answer: StudyAnswer?
    @State private var question = ""
    @AppStorage("Paperdesk.preferOnDeviceStudy") private var preferOnDevice = false
    @State private var modelAvailability = StudyModelAvailability(
        isAvailable: false, explanation: "Checking the on-device model…")
    @State private var answeredQuestion = ""
    @State private var revealed = Set<String>()
    @State private var progress = 0.0
    @State private var busy = false
    @State private var status: String?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()

    enum StudySection: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case terms = "Terms"
        case cards = "Cards"
        case ask = "Ask"
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.headline).foregroundStyle(.secondary)
                        Text("On-device study")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(
                            "Summaries use selected source passages. Ask can use Apple’s local model to choose concise, source-verified quotations. Check the page links for context."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    StudyNavigation(
                        section: $section, currentPageOnly: $currentPageOnly,
                        currentPage: currentPage)

                    if busy {
                        VStack(alignment: .leading, spacing: 10) {
                            ProgressView(
                                material == nil
                                    ? "Reading local text…"
                                    : preferOnDevice && modelAvailability.isAvailable
                                        ? "Answering on this device…" : "Finding relevant passages…",
                                value: progress)
                            Button("Stop", role: .cancel) { stop() }
                        }.accessibilityElement(children: .contain)
                    }
                    if let failure {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Study unavailable", systemImage: "exclamationmark.triangle").font(
                                .headline)
                            Text(failure).foregroundStyle(.secondary)
                            Button("Try again") { prepare() }
                        }
                    }
                    if let material {
                        Text(
                            "\(material.pagesRead) of \(material.totalPages) pages processed\(material.usedOCR ? " · Includes saved OCR" : "")"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        if material.wasLimited {
                            Label(
                                "Limited context: up to 250 pages, 300,000 characters and 1,600 passages. Use Current page for a page outside this selection.",
                                systemImage: "info.circle"
                            )
                            .font(.callout).foregroundStyle(.secondary)
                        }
                        if material.passages.isEmpty {
                            ContentUnavailableView(
                                "No study text yet", systemImage: "text.viewfinder",
                                description: Text(
                                    "This selection has no usable text passages. Return to the reader and choose Recognize text, then reopen Study."
                                ))
                        } else {
                            studyContent(material)
                        }
                    } else if !busy && failure == nil {
                        ContentUnavailableView(
                            "Study materials", systemImage: "book",
                            description: Text("Prepare study materials from the PDF and any valid saved OCR.")
                        )
                        Button("Prepare study materials") { prepare() }.paperdeskProminentAction()
                    }
                    if let status {
                        Text(status).font(.callout).foregroundStyle(.secondary).accessibilityLabel(status)
                    }
                }
                .padding(16)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background { PaperdeskBackdrop() }
            .navigationTitle("Offline Study")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 520, idealWidth: 760, minHeight: 560)
        #endif
        .paperdeskActions()
        .onAppear { prepare() }
        .task { modelAvailability = await service.modelAvailability() }
        .onChange(of: currentPageOnly) { _, _ in prepare() }
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder private func studyContent(_ material: StudyMaterial) -> some View {
        switch section {
        case .summary:
            Text("Selected key passages").font(.headline)
            ForEach(material.summary) { passage in passageView(passage) }
            Button("Save summary to document notes", systemImage: "square.and.arrow.down") {
                save("Extractive summary", passages: material.summary)
            }
        case .terms:
            Text("Terms in context").font(.headline)
            Text("Frequent content words with supporting excerpts; these are not generated definitions.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(material.terms) { term in
                VStack(alignment: .leading, spacing: 10) {
                    Text(term.term).font(.headline)
                    passageView(term.passage)
                }
            }
        case .cards:
            Text("Recall, then reveal").font(.headline)
            if let onSaveCards {
                Button("Add cards to review queue", systemImage: "rectangle.stack.badge.plus") {
                    Task {
                        do {
                            try await onSaveCards(material.cards)
                            status = "Cards added to the study workspace review queue."
                        } catch { status = error.localizedDescription }
                    }
                }
            }
            ForEach(material.cards) { card in
                VStack(alignment: .leading, spacing: 12) {
                    Text(card.prompt).font(.headline)
                    Button(revealed.contains(card.id) ? "Hide answer" : "Reveal answer") {
                        if revealed.contains(card.id) {
                            revealed.remove(card.id)
                        } else {
                            revealed.insert(card.id)
                        }
                    }
                    .accessibilityLabel(
                        "\(revealed.contains(card.id) ? "Hide" : "Reveal") answer for \(card.term)")
                    if revealed.contains(card.id) { passageView(card.answer) }
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(.background)
                .overlay(alignment: .bottom) { Divider() }
            }
            Button("Save flashcards to document notes", systemImage: "square.and.arrow.down") {
                do {
                    let text = material.cards.map {
                        "\($0.prompt)\n\($0.answer.text)\nPage \($0.answer.pageIndex + 1)"
                    }.joined(separator: "\n\n")
                    try onSaveNote("\n\nOffline Study · Extractive flashcards\n\(text)")
                    status = "Flashcards saved to this document’s local notes."
                } catch { status = "Could not save: \(error.localizedDescription)" }
            }
        case .ask:
            Text("Ask this document").font(.headline)
            Toggle("Use on-device AI", isOn: $preferOnDevice)
                .disabled(!modelAvailability.isAvailable || busy)
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .accessibilityLabel("Use on-device AI for document answers")
                .accessibilityHint("Uses only Apple’s local model. Extractive answers are the fallback.")
            Text(modelAvailability.explanation).font(.caption).foregroundStyle(.secondary)
            if preferOnDevice && modelAvailability.isAvailable {
                Text(
                    "AI chooses concise quotations from up to three retrieved passages. Every displayed quotation is checked against its cited source."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            TextField("Ask about a specific topic in the text", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...5)
                .accessibilityLabel("Question about this document")
                .onChange(of: question) { _, value in
                    if value.count > 400 { question = String(value.prefix(400)) }
                }
            Button(
                preferOnDevice && modelAvailability.isAvailable
                    ? "Answer on device" : "Find supporting passages", systemImage: "text.magnifyingglass"
            ) { ask(material) }
            .paperdeskProminentAction()
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let answer {
                Text(answeredQuestion).font(.headline)
                if let notice = answer.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                if answer.hasAnswer {
                    Label(
                        answer.mode == .onDevice
                            ? "On-device AI · Verified source quotations"
                            : "Extractive answer · Source passages", systemImage: "quote.opening"
                    ).font(.subheadline)
                    Text(
                        "These quotations may not answer every part of your question. Missing details have not been inferred."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    ForEach(answer.passages) { passage in passageView(passage) }
                    Button("Save answer to document notes") {
                        save(
                            "Question: \(answeredQuestion)\n\(answer.mode.rawValue) · Source quotations",
                            passages: answer.passages)
                    }
                } else {
                    ContentUnavailableView(
                        "No supported answer found", systemImage: "questionmark.bubble",
                        description: Text(
                            "No passage in the processed text matches enough of this question. Try specific document terms, another page, or recognize scanned text first."
                        ))
                }
            }
        }
    }

    private func passageView(_ passage: StudyPassage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("“\(passage.text)”").textSelection(.enabled)
            Button("Page \(passage.pageIndex + 1)", systemImage: "doc.text") {
                onPage(passage.pageIndex)
                dismiss()
            }
            .font(.callout)
            .accessibilityLabel("Read source on page \(passage.pageIndex + 1)")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func prepare() {
        task?.cancel()
        generation = UUID()
        let token = generation
        let selectedPage = currentPageOnly ? currentPage : nil
        material = nil
        answer = nil
        revealed = []
        failure = nil
        status = nil
        busy = true
        progress = 0
        task = Task {
            do {
                let result = try await service.prepare(url: url, pageIndex: selectedPage) { value in
                    await MainActor.run { if generation == token { progress = value } }
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                material = result
                busy = false
            } catch is CancellationError {
                if generation == token {
                    busy = false
                    status = "Study preparation stopped."
                }
            } catch {
                if generation == token {
                    busy = false
                    failure = error.localizedDescription
                }
            }
        }
    }

    private func ask(_ material: StudyMaterial) {
        task?.cancel()
        let token = UUID()
        generation = token
        let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        progress = 0
        answer = nil
        status = nil
        let useModel = preferOnDevice
        task = Task {
            do {
                let result = try await service.answer(query, in: material, preferOnDevice: useModel) {
                    value in
                    await MainActor.run { if generation == token { progress = value } }
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                answer = result
                answeredQuestion = query
                progress = 1
                busy = false
            } catch is CancellationError {
                if generation == token {
                    busy = false
                    status = "Question stopped."
                }
            } catch {
                if generation == token {
                    busy = false
                    status = error.localizedDescription
                }
            }
        }
    }

    private func stop() {
        task?.cancel()
        generation = UUID()
        busy = false
        status = "Stopped. No answer was generated."
    }

    private func save(_ heading: String, passages: [StudyPassage]) {
        do {
            let body = passages.map { "\($0.text)\nPage \($0.pageIndex + 1)" }.joined(separator: "\n\n")
            try onSaveNote("\n\nOffline Study · \(heading)\n\(body)")
            status = "Saved to this document’s local notes."
        } catch { status = "Could not save: \(error.localizedDescription)" }
    }
}

private struct StudyNavigation: View {
    @Binding var section: OfflineStudyView.StudySection
    @Binding var currentPageOnly: Bool
    let currentPage: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Study scope", selection: $currentPageOnly) {
                Text("Whole document").tag(false)
                Text("Page \(currentPage + 1)").tag(true)
            }
            .pickerStyle(.menu)
            ViewThatFits(in: .horizontal) {
                sectionPicker.pickerStyle(.segmented)
                sectionPicker.pickerStyle(.menu)
            }
        }
    }

    private var sectionPicker: some View {
        Picker("Study section", selection: $section) {
            ForEach(OfflineStudyView.StudySection.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
    }
}
