import AppKit
import WebKit

// 在原生拖放层读取真实文件 URL；图片等其他拖放继续交给 WebKit 编辑区。
final class DocumentWebView: WKWebView {
    var onOpenDocuments: (([URL]) -> Void)?

    private func documentURLs(_ pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) && !$0.hasDirectoryPath }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !documentURLs(sender.draggingPasteboard).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !documentURLs(sender.draggingPasteboard).isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if !documentURLs(sender.draggingPasteboard).isEmpty { return true }
        return super.prepareForDragOperation(sender)
    }

    func openDroppedDocuments(from pasteboard: NSPasteboard) -> Bool {
        openDroppedDocuments(urls: documentURLs(pasteboard))
    }

    func openDroppedDocuments(urls: [URL]) -> Bool {
        let documents = urls.filter { $0.isFileURL && ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) && !$0.hasDirectoryPath }
        guard !documents.isEmpty, let onOpenDocuments else { return false }
        onOpenDocuments(documents)
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if openDroppedDocuments(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }
}
