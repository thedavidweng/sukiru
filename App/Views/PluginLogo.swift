import SwiftUI

/// A plugin's icon: a file inside an installed plugin, or a listing's HTTPS
/// address. SVG and bitmap icons both decode through NSImage; anything else
/// keeps the generic plugin symbol. Decoded icons are kept for the session, so
/// rows scrolling back into view show theirs at once instead of reloading.
struct PluginLogo: View {
    let address: String?
    let size: CGFloat
    @State private var image: NSImage?

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        Group {
            if let image = image ?? address.flatMap({ Self.cache[$0] }) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: address) {
            guard let address else {
                image = nil
                return
            }
            if let cached = Self.cache[address] {
                image = cached
                return
            }
            image = nil
            let loaded: NSImage?
            if address.hasPrefix("/") {
                loaded = await Task.detached(priority: .utility) {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: address)
                    guard let size = attributes?[.size] as? Int, size <= Self.byteLimit else {
                        return nil
                    }
                    return NSImage(contentsOfFile: address)
                }.value
            } else if let url = URL(string: address), url.scheme == "https" {
                loaded = await Self.load(url)
            } else {
                loaded = nil
            }
            if let loaded { Self.cache[address] = loaded }
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    /// Icons are a few kilobytes; a file or body over the limit is discarded.
    private nonisolated static let byteLimit = 1 << 20

    private nonisolated static func load(_ url: URL) async -> NSImage? {
        // A host versions an icon's address instead of changing its bytes, so a stored
        // copy is used as is on later launches and offline.
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            response.expectedContentLength <= byteLimit,
            data.count <= byteLimit
        else { return nil }
        return NSImage(data: data)
    }
}
