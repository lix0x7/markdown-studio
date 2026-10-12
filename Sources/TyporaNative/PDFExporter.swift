import AppKit
import MarkdownCore

// 使用 AppKit 的富文本排版与打印分页生成 PDF，不嵌入浏览器编辑器。
enum PDFExporter {
    static func write(_ text: String, title: String, base: URL?, to url: URL) throws {
        try HTMLExporter.validateLocalImages(text, base: base)
        let html = HTMLExporter.document(text, title: title, base: base)
        let attributed = try NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 499, height: 1))
        view.isRichText = true; view.textContainerInset = NSSize(width: 0, height: 0)
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(attributed)
        view.textContainer?.containerSize = NSSize(width: 499, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let height = view.layoutManager?.usedRect(for: view.textContainer!).height ?? 1
        view.frame.size.height = max(1, height + 20)
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842); info.topMargin = 48; info.bottomMargin = 48; info.leftMargin = 48; info.rightMargin = 48
        info.horizontalPagination = .fit; info.verticalPagination = .automatic; info.isVerticallyCentered = false; info.isHorizontallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url.absoluteURL
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false; operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "TyporaNative", code: 3, userInfo: [NSLocalizedDescriptionKey: "PDF 导出失败，请检查目标文件夹权限。"])
        }
    }
}
