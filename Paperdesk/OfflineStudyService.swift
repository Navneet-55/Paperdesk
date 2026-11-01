import Foundation
import NaturalLanguage
import PDFKit

struct StudyPassage: Identifiable, Sendable, Equatable {
    let id: String
    let pageIndex: Int
    let text: String
}

struct StudyTerm: Identifiable, Sendable, Equatable {
    var id: String { term }
    let term: String
    let passage: StudyPassage
}

struct StudyCard: Identifiable, Sendable, Equatable {
    var id: String { term }
    let term: String
    let prompt: String
    let answer: StudyPassage
}

struct StudyMaterial: Sendable {
    let passages: [StudyPassage]
    let summary: [StudyPassage]
    let terms: [StudyTerm]
    let cards: [StudyCard]
    let pagesRead: Int
    let totalPages: Int
    let wasLimited: Bool
    let usedOCR: Bool
}

struct StudyAnswer: Sendable {
    let passages: [StudyPassage]
    var mode: StudyAnswerMode = .extractive
    var notice: String? = nil
    var hasAnswer: Bool { !passages.isEmpty }
}

/// Deterministic extraction with optional on-device selection of verified source quotations.
/// Document text is untrusted data; extraction and ranking stay off the main actor.
actor OfflineStudyService {
    private let generator: any StudyAnswerGenerating
    init(generator: any StudyAnswerGenerating = SystemStudyGenerator()) { self.generator = generator }

    func modelAvailability() async -> StudyModelAvailability { await generator.availability() }
    static let maxPages = 250
    static let maxCharacters = 300_000
    static let maxPassages = 1_600
    static let maxPageCharacters = 20_000

    func prepare(
        url: URL, pageIndex: Int? = nil,
        progress: @Sendable (Double) async -> Void
    ) async throws -> StudyMaterial {
        try Task.checkCancellation()
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else {
            throw DocumentTextError.unreadablePDF
        }
        let before = try stamp(url)
        let count = pdf.pageCount
        if let pageIndex, !(0..<count).contains(pageIndex) { throw DocumentTextError.invalidPage(pageIndex) }
        let requested = pageIndex.map { [$0] } ?? Array(0..<min(count, Self.maxPages))
        var limited = pageIndex == nil && count > Self.maxPages
        let sidecar = DocumentTextService.indexURL(for: url)
        let sidecarSize = (try? sidecar.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // Do not decode an arbitrarily large OCR JSON file just to make a study context.
        var index: OCRIndex?
        if sidecarSize <= 16 * 1024 * 1024 {
            index = try await DocumentTextService().cachedIndex(url: url)
        } else {
            limited = true
        }
        if let pageIndex,
            let cached = try await DocumentTextService().cachedPage(url: url, pageIndex: pageIndex)
        {
            if index == nil { index = OCRIndex(version: 1, fingerprint: "", pageCount: count, pages: []) }
            index?.pages.removeAll { $0.pageIndex == pageIndex }
            index?.pages.append(cached)
        }
        let ocr = Dictionary((index?.pages ?? []).map { ($0.pageIndex, $0) }, uniquingKeysWith: { a, _ in a })
        var passages: [StudyPassage] = []
        var remaining = Self.maxCharacters
        var pagesRead = 0
        var usedOCR = false
        for (offset, number) in requested.enumerated() {
            try Task.checkCancellation()
            let extracted: (String, Bool, Bool) = autoreleasepool {
                guard let page = pdf.page(at: number) else { return ("", false, false) }
                let native = page.string ?? ""
                var text = String(native.prefix(Self.maxPageCharacters))
                var clipped = native.count > Self.maxPageCharacters
                var addedOCR = false
                if let recognized = ocr[number] {
                    for box in recognized.boxes {
                        if text.count >= Self.maxPageCharacters {
                            clipped = true
                            break
                        }
                        if !DocumentTextService.hasNativeText(box.text, covering: [box], on: page) {
                            text += "\n" + String(box.text.prefix(Self.maxPageCharacters - text.count))
                            addedOCR = true
                        }
                    }
                }
                return (text, addedOCR, clipped)
            }
            let text = String(extracted.0.prefix(max(0, remaining)))
            limited = limited || extracted.2 || text.count < extracted.0.count
            usedOCR = usedOCR || extracted.1
            remaining -= text.count
            passages += Self.split(text, pageIndex: number, limit: Self.maxPassages - passages.count)
            pagesRead += 1
            await progress(Double(offset + 1) / Double(requested.count))
            if remaining <= 0 || passages.count >= Self.maxPassages {
                limited = true
                break
            }
        }
        try Task.checkCancellation()
        guard try stamp(url) == before else { throw DocumentTextError.incompatibleIndex }
        return try Self.material(
            passages: passages, pagesRead: pagesRead, totalPages: count,
            wasLimited: limited, usedOCR: usedOCR)
    }

    private func stamp(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    static func split(_ text: String, pageIndex: Int, limit: Int) -> [StudyPassage] {
        guard limit > 0 else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [StudyPassage] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // Keep OCR paragraphs manageable without synthesizing or paraphrasing facts.
            for line in text[range].split(separator: "\n") {
                let sentence = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard sentence.count >= 25 else { continue }
                result.append(
                    StudyPassage(
                        id: "\(pageIndex)-\(result.count)", pageIndex: pageIndex,
                        text: String(sentence.prefix(1_200))))
                if result.count >= limit { return false }
            }
            return !Task.isCancelled
        }
        return result
    }

    static func material(
        passages: [StudyPassage], pagesRead: Int, totalPages: Int,
        wasLimited: Bool = false, usedOCR: Bool = false
    ) throws -> StudyMaterial {
        let bounded = Array(passages.prefix(maxPassages))
        var frequency: [String: Int] = [:]
        var tokens: [Set<String>] = []
        for passage in bounded {
            try Task.checkCancellation()
            let words = Set(keywords(passage.text))
            tokens.append(words)
            for word in words { frequency[word, default: 0] += 1 }
        }
        let ranked = bounded.indices.sorted { left, right in
            func score(_ index: Int) -> Double {
                let words = tokens[index]
                return words.reduce(0.0) { $0 + log1p(Double(frequency[$1, default: 0])) }
                    / sqrt(Double(max(1, words.count)))
            }
            let a = score(left)
            let b = score(right)
            return a == b ? left < right : a > b
        }
        var seen = Set<String>()
        let summary = ranked.compactMap { index -> StudyPassage? in
            let passage = bounded[index]
            return seen.insert(passage.text.lowercased()).inserted ? passage : nil
        }.prefix(6)
        let topTerms = frequency.keys.sorted {
            let a = frequency[$0, default: 0]
            let b = frequency[$1, default: 0]
            return a == b ? $0 < $1 : a > b
        }.prefix(12)
        let terms = topTerms.compactMap { term -> StudyTerm? in
            guard let index = ranked.first(where: { tokens[$0].contains(term) }) else { return nil }
            return StudyTerm(term: term, passage: bounded[index])
        }
        let cards = terms.prefix(8).map { term in
            StudyCard(
                term: term.term, prompt: "What does this document say about “\(term.term)”?",
                answer: term.passage)
        }
        return StudyMaterial(
            passages: bounded, summary: Array(summary), terms: terms, cards: cards,
            pagesRead: pagesRead, totalPages: totalPages, wasLimited: wasLimited, usedOCR: usedOCR)
    }

    func answer(_ question: String, in material: StudyMaterial) throws -> StudyAnswer {
        try Task.checkCancellation()
        let terms = Set(Self.keywords(String(question.prefix(400))))
        guard !terms.isEmpty else { return StudyAnswer(passages: []) }
        var scored: [(Int, Double)] = []
        for (index, passage) in material.passages.enumerated() {
            try Task.checkCancellation()
            let words = Set(Self.keywords(passage.text))
            let matched = terms.intersection(words)
            let coverage = Double(matched.count) / Double(terms.count)
            // A related word alone is insufficient for a multi-concept question.
            if coverage >= 0.67 {
                scored.append((index, coverage + Double(matched.count) / Double(max(1, words.count))))
            }
        }
        scored.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        var seen = Set<String>()
        let selected = scored.compactMap { entry -> StudyPassage? in
            let passage = material.passages[entry.0]
            return seen.insert(passage.text.lowercased()).inserted ? passage : nil
        }.prefix(3)
        return StudyAnswer(passages: Array(selected))
    }

    /// At most three retrieved excerpts, 2,700 UTF-8 bytes total, and a 400-byte question.
    /// Each request gets a fresh session, so conversation history cannot grow or leak between PDFs.
    func answer(
        _ question: String, in material: StudyMaterial, preferOnDevice: Bool,
        progress: @Sendable (Double) async -> Void = { _ in }
    ) async throws -> StudyAnswer {
        let fallback = try answer(question, in: material)
        guard preferOnDevice, fallback.hasAnswer else { return fallback }
        await progress(0.25)
        let availability = await generator.availability()
        guard availability.isAvailable else {
            return StudyAnswer(passages: fallback.passages, notice: availability.explanation)
        }
        let sources = Self.boundedSources(fallback.passages)
        guard !sources.isEmpty else { return fallback }
        let query = Self.utf8Prefix(question, bytes: 400)
        do {
            let generator = generator
            let selections = try await withThrowingTaskGroup(of: [StudyModelSelection].self) { group in
                group.addTask { try await generator.generate(question: query, sources: sources) }
                group.addTask {
                    try await Task.sleep(for: .seconds(45))
                    throw StudyModelError.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
            try Task.checkCancellation()
            await progress(0.9)
            guard let verified = Self.verifiedSelections(selections, sources: sources), !verified.isEmpty
            else {
                return StudyAnswer(
                    passages: fallback.passages,
                    notice: "The local model did not return a verifiable answer. Showing extractive passages."
                )
            }
            return StudyAnswer(passages: verified, mode: .onDevice)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return StudyAnswer(
                passages: fallback.passages,
                notice: "The local model could not complete this answer. Showing extractive passages.")
        }
    }

    static func boundedSources(_ passages: [StudyPassage]) -> [StudyPassage] {
        passages.prefix(3).map {
            StudyPassage(id: $0.id, pageIndex: $0.pageIndex, text: utf8Prefix($0.text, bytes: 900))
        }
    }

    static func utf8Prefix(_ text: String, bytes: Int) -> String {
        var result = ""
        var remaining = bytes
        for character in text {
            let length = String(character).utf8.count
            guard length <= remaining else { break }
            result.append(character)
            remaining -= length
        }
        return result
    }

    /// Fail closed: never show model-written facts or model-written page numbers.
    /// Whitespace normalization tolerates PDF line wrapping without changing the words.
    static func verifiedSelections(_ selections: [StudyModelSelection], sources: [StudyPassage])
        -> [StudyPassage]?
    {
        guard selections.count <= 3 else { return nil }
        var seen = Set<String>()
        var result: [StudyPassage] = []
        for selection in selections {
            guard selection.sourceID.hasPrefix("S"),
                let index = Int(selection.sourceID.dropFirst()), index > 0, index <= sources.count
            else { return nil }
            let source = sources[index - 1]
            let quote = selection.quote.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let text = source.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard quote.count >= 15, quote.utf8.count <= 900, text.contains(quote) else { return nil }
            if seen.insert(selection.sourceID + quote).inserted {
                result.append(
                    StudyPassage(
                        id: "\(source.id)-answer-\(result.count)", pageIndex: source.pageIndex, text: quote))
            }
        }
        return result
    }

    private static let stopwords: Set<String> = Set(
        """
        a an the and or but if then than that this these those to of in on at for from with by as is are was were be been being it its they them their we our you your he she his her not no do does did have has had can could would should may might will shall about into over under between through during after before also such more most some any all each other which what when where why how who whom explain describe summarize tell please document page says say said use using used
        """.split(separator: " ").map(String.init))

    static func keywords(_ text: String) -> [String] {
        let normalized = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        var words: [String] = []
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            let word = String(normalized[range])
            if word.count >= 3, !stopwords.contains(word),
                word.unicodeScalars.contains(where: CharacterSet.letters.contains)
            {
                words.append(word)
            }
            return words.count < 500
        }
        return words
    }
}
