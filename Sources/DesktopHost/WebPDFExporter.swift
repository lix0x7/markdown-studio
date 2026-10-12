import AppKit
import WebKit
import PDFKit

// 按浏览器实际文本行和表格行确定分页边界，再生成保留矢量文字的 A4 PDF。
final class WebPDFExporter: NSObject, WKNavigationDelegate {
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 1000))
    let destination: URL
    let completion: (Error?) -> Void
    let output = NSMutableData()
    var context: CGContext?
    var breaks: [Double] = []
    var pageIndex = 0
    init(html: String, destination: URL, completion: @escaping (Error?) -> Void) {
        self.destination = destination; self.completion = completion
        super.init(); view.navigationDelegate = self
        view.loadHTMLString(html, baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = #"""
        await document.fonts.ready;
        const style=document.createElement('style');style.textContent='body{margin:0!important;padding:0!important;max-width:none!important}article{margin:0!important}';document.head.append(style);
        const spans=[];const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
        while(walker.nextNode()){
          if(!walker.currentNode.textContent.trim())continue;
          const range=document.createRange();range.selectNodeContents(walker.currentNode);
          for(const r of range.getClientRects())if(r.height>0)spans.push({top:r.top+scrollY,bottom:r.bottom+scrollY});
        }
        for(const el of document.querySelectorAll('tr,img,pre,h1,h2,h3,h4,h5,h6')){const r=el.getBoundingClientRect();if(r.height<1000)spans.push({top:r.top+scrollY,bottom:r.bottom+scrollY})}
        const height=Math.max(document.body.scrollHeight,...spans.map(r=>r.bottom));
        const pageHeight=758*760/511;const breaks=[0];let start=0;
        while(start<height){let end=Math.min(height,start+pageHeight);
          for(let i=0;i<20;i++){const crossing=spans.filter(r=>r.top<end&&r.bottom>end&&r.top>start+1);if(!crossing.length)break;end=Math.min(...crossing.map(r=>r.top))}
          if(end<=start+1)end=Math.min(height,start+pageHeight);
          breaks.push(end);start=end;
        }
        return breaks;
        """#
        view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.completion(error)
            case .success(let value):
                guard let values = value as? [Double], values.count > 1,
                      let consumer = CGDataConsumer(data: self.output as CFMutableData) else { self.completion(Host.error("无法计算 PDF 分页。")); return }
                self.breaks = values
                var box = CGRect(x: 0, y: 0, width: 595, height: 842)
                self.context = CGContext(consumer: consumer, mediaBox: &box, nil)
                self.renderPage()
            }
        }
    }
    func renderPage() {
        guard let context else { completion(Host.error("无法创建 PDF。")); return }
        guard pageIndex + 1 < breaks.count else {
            context.closePDF()
            do { try (output as Data).write(to: destination, options: .atomic); completion(nil) }
            catch { completion(error) }
            return
        }
        let height = breaks[pageIndex + 1] - breaks[pageIndex]
        let config = WKPDFConfiguration(); config.rect = CGRect(x: 0, y: breaks[pageIndex], width: 760, height: height)
        view.createPDF(configuration: config) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.completion(error)
            case .success(let bytes):
                guard let document = PDFDocument(data: bytes), let page = document.page(at: 0)?.pageRef else { self.completion(Host.error("无法生成 PDF 页面。")); return }
                let box = page.getBoxRect(.mediaBox), scale = 511 / box.width
                context.beginPDFPage(nil); context.saveGState()
                context.translateBy(x: 42 - box.minX * scale, y: 800 - box.height * scale - box.minY * scale)
                context.scaleBy(x: scale, y: scale); context.drawPDFPage(page)
                context.restoreGState(); context.endPDFPage()
                self.pageIndex += 1; self.renderPage()
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { completion(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { completion(error) }
}
