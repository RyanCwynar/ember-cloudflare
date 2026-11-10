import AVKit
import SwiftUI

/// A file message's file: a picture inline (click for the viewer), a video with a player, or a file
/// card that downloads with the session's cookie.
struct Attachment: View {
    @Environment(AppState.self) private var state
    let file: StoredFile

    var body: some View {
        if file.isImage, let url = state.api?.absolute(file.previewUrl ?? file.url) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                    .aspectRatio(aspect, contentMode: .fit)
            }
            .frame(maxWidth: 360, maxHeight: 260, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture { state.sheet = .image(file) }
            .help(file.name)
            .contextMenu { Button("Download") { state.download(file) } }
        } else if file.contentType.hasPrefix("video/"), let url = state.api?.absolute(file.url) {
            VideoAttachment(url: url, cookies: state.api.map { HTTPCookieStorage.shared.cookies(for: $0.server) ?? [] } ?? [])
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: 420, maxHeight: 300, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contextMenu { Button("Download") { state.download(file) } }
        } else {
            Button { state.download(file) } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.title2).foregroundStyle(Brand.accent).frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteSize), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: 340)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Download \(file.name)")
        }
    }

    private var aspect: CGFloat {
        guard let w = file.width, let h = file.height, h > 0 else { return 4.0 / 3.0 }
        return CGFloat(w) / CGFloat(h)
    }

    private var symbol: String {
        let type = file.contentType
        if type == "application/pdf" { return "doc.richtext" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type.hasPrefix("text/") { return "doc.text" }
        if type.contains("zip") || type.contains("compressed") { return "doc.zipper" }
        return "doc"
    }
}

/// A video, played with the session's cookie, since files are served only to people signed in.
struct VideoAttachment: View {
    let url: URL
    let cookies: [HTTPCookie]
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                guard player == nil else { return }
                let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: cookies])
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            }
            .onDisappear { player?.pause() }
    }
}

/// A picture at full size, with Download.
struct ImageViewer: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let file: StoredFile

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(file.name).font(.headline).lineLimit(1)
                Spacer()
                Button("Download") { state.download(file) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            AsyncImage(url: state.api?.absolute(file.url)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else if phase.error != nil {
                    Text("Couldn't load the picture.").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
            .background(Color.black.opacity(0.85))
        }
        .frame(minWidth: 640, idealWidth: 960, minHeight: 480, idealHeight: 720)
    }
}

/// A file on its way up, with its progress, or why it failed.
struct UploadRow: View {
    let upload: RoomStore.UploadItem
    let onRetry: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Color.clear.frame(width: 36, height: 1)
            VStack(alignment: .leading, spacing: 4) {
                Label(upload.name, systemImage: "arrow.up.doc").lineLimit(1)
                if let failed = upload.failed {
                    HStack {
                        Text(failed).foregroundStyle(.red)
                        Button("Retry", action: onRetry).buttonStyle(.link)
                        Button("Discard", action: onDiscard).buttonStyle(.link)
                    }
                    .font(.caption)
                } else {
                    ProgressView(value: upload.progress).frame(maxWidth: 260).tint(Brand.accent)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}
