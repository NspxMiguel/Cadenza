import SwiftUI

/// The documents, and a way to read them without leaving the app.
///
/// They live here as text rather than as files in the bundle for one reason: a
/// privacy policy that cannot be displayed because a resource failed to copy is
/// worse than useless. Compiled in, they are always there. The published copies
/// under `docs/legal/` are generated from these same strings — run the app with
/// `CADENZA_EMIT_LEGAL=<pasta>` — so the two cannot drift apart.
enum LegalDocument: String, CaseIterable, Identifiable {
    case privacy, terms, licences

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: "Política de Privacidade"
        case .terms: "Termos de Uso"
        case .licences: "Licenças e créditos"
        }
    }

    var symbol: String {
        switch self {
        case .privacy: "hand.raised"
        case .terms: "doc.text"
        case .licences: "text.book.closed"
        }
    }

    /// The file name the published copy takes.
    var fileName: String {
        switch self {
        case .privacy: "privacidade.md"
        case .terms: "termos.md"
        case .licences: "licencas.md"
        }
    }

    var markdown: String {
        switch self {
        case .privacy: LegalText.privacy
        case .terms: LegalText.terms
        case .licences: LegalText.licences
        }
    }

    /// Writes every document to a folder, for publishing. Called from the app
    /// delegate when `CADENZA_EMIT_LEGAL` is set.
    static func emit(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for document in allCases {
            let file = directory.appendingPathComponent(document.fileName)
            try? document.markdown.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Reading them

struct LegalSheet: View {
    @State var document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $document) {
                    ForEach(LegalDocument.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)

                Spacer()
                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                MarkdownDocument(text: document.markdown)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A legal document that cannot be copied is a legal document nobody
            // can quote back at you.
            .textSelection(.enabled)
        }
        .frame(width: 720, height: 620)
    }
}

/// Enough Markdown to render these documents properly.
///
/// SwiftUI's own `Text(.init(markdown))` handles emphasis and links but treats
/// a heading as literal hashes and a list as literal hyphens, which turns a
/// long document into a wall. This walks the source line by line and gives each
/// block the shape it asks for; inline formatting is still handed to
/// `AttributedString`, which does that part well.
struct MarkdownDocument: View {
    let text: String

    private enum Block: Identifiable {
        case title(String), heading(String), subheading(String)
        case paragraph(String), bullet(String), rule
        var id: String {
            switch self {
            case .title(let s): "t\(s)"
            case .heading(let s): "h\(s)"
            case .subheading(let s): "s\(s)"
            case .paragraph(let s): "p\(s)"
            case .bullet(let s): "b\(s)"
            case .rule: "rule\(UUID().uuidString)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .title(let value):
                    inline(value).font(.cadenzaTitle(25)).padding(.bottom, 10)
                case .heading(let value):
                    inline(value).font(.title3.weight(.semibold))
                        .padding(.top, 20).padding(.bottom, 6)
                case .subheading(let value):
                    inline(value).font(.headline)
                        .padding(.top, 13).padding(.bottom, 4)
                case .paragraph(let value):
                    inline(value).padding(.bottom, 9)
                        .fixedSize(horizontal: false, vertical: true)
                case .bullet(let value):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(value).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 5)
                case .rule:
                    Divider().padding(.vertical, 14)
                }
            }
        }
    }

    private func inline(_ source: String) -> Text {
        // `.inlineOnlyPreservingWhitespace` keeps the parser from swallowing the
        // line into a block it would then refuse to render.
        let parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(parsed ?? AttributedString(source))
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            switch true {
            case line.isEmpty:
                flush()
            case line.hasPrefix("### "):
                flush(); result.append(.subheading(String(line.dropFirst(4))))
            case line.hasPrefix("## "):
                flush(); result.append(.heading(String(line.dropFirst(3))))
            case line.hasPrefix("# "):
                flush(); result.append(.title(String(line.dropFirst(2))))
            case line == "---" || line == "***":
                flush(); result.append(.rule)
            case line.hasPrefix("- ") || line.hasPrefix("* "):
                flush(); result.append(.bullet(String(line.dropFirst(2))))
            default:
                paragraph.append(line)
            }
        }
        flush()
        return result
    }
}
