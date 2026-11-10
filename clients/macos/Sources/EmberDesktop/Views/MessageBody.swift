import SwiftUI

/// A message's text as Ember formats it: paragraphs, code, quotes, lists, mentions and link previews.
struct MessageBody: View {
    @Environment(AppState.self) private var state
    let message: Message

    var body: some View {
        RichBlocksView(blocks: state.blocks(for: message))
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == RichTextRenderer.personScheme {
                    state.showPerson(url.absoluteString.replacingOccurrences(of: "\(RichTextRenderer.personScheme):", with: ""))
                    return .handled
                }
                return .systemAction
            })
    }
}

struct RichBlocksView: View {
    let blocks: [RichBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                RichBlockView(block: block)
            }
        }
    }
}

struct RichBlockView: View {
    let block: RichBlock

    var body: some View {
        switch block {
        case let .paragraph(text):
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case let .heading(text):
            Text(text).font(.headline).textSelection(.enabled)
        case let .code(code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
        case let .quote(blocks):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                RichBlocksView(blocks: blocks).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .list(ordered, items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "•").foregroundStyle(.secondary).monospacedDigit()
                        RichBlocksView(blocks: item)
                    }
                }
            }
        case let .preview(preview):
            LinkPreviewCard(preview: preview)
        case .divider:
            Divider()
        }
    }
}

struct LinkPreviewCard: View {
    let preview: LinkPreview

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(Brand.accent.opacity(0.7)).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                if let href = preview.href {
                    Link(preview.title.isEmpty ? href.absoluteString : preview.title, destination: href).font(.callout.bold())
                } else {
                    Text(preview.title).font(.callout.bold())
                }
                if !preview.description.isEmpty {
                    Text(preview.description).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                if let image = preview.image {
                    AsyncImage(url: image) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                        .frame(maxWidth: 320, maxHeight: 180, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 480, alignment: .leading)
    }
}
