import AppKit
import WebKit
import PDFKit
import MarkdownCore

// 使用实际 WKWebView 引擎执行编辑事务，并核对宿主文件、草稿和分页 PDF。
final class WebVerification {
    let root: URL
    var host: Host?
    var timer: Timer?
    var exporter: WebPDFExporter?
    var attempts = 0
    let original = "# 重复标题\r\n\r\nplain 中文😀  \n\n| a  | b |\r\n| :--- | ---: |\r\n| old   | value |\r\n\r\n# 重复标题\n"
    init(root: URL) { self.root = root }
    func start() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("roundtrip.md")
            try SourceFile(text: original, encoding: .utf8BOM).data.write(to: file)
            host = try Host(url: file, recovery: RecoveryStore(directory: root.appendingPathComponent("Recovery")))
            host?.showWindow(nil)
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.waitReady() }
        } catch { fail(error.localizedDescription) }
    }
    func waitReady() {
        attempts += 1
        if attempts > 200 { fail("Frontend did not initialize"); return }
        host?.web.evaluateJavaScript("Boolean(window.editorAPI)") { [weak self] value, error in
            guard let self, self.timer != nil, value as? Bool == true else { return }
            self.timer?.invalidate(); self.timer = nil; self.runEditorChecks()
        }
    }
    func runEditorChecks() {
        let script = #"""
        const api=window.editorAPI, ed=api.editor, before=ed.buffer.raw;
        const results=[];
        const check=(pass,label)=>{if(!pass)throw new Error(label);results.push(label)};
        let at=ed.view.state.doc.toString().indexOf('plain');
        ed.view.dispatch({selection:{anchor:at,head:at+5}});ed.wrap('**');
        let native=await api.request('ready');
        check(native.text===before.replace('plain','**plain**'),'UTF-16 patches preserve BOM payload and untouched mixed line endings');
        ed.undo();native=await api.request('ready');check(native.text===before,'Undo restores exact native source');
        ed.toggle();ed.toggle();check(ed.buffer.raw===before,'Preview/source switches leave original bytes unchanged');
        ed.view.dispatch({changes:{from:0,to:ed.view.state.doc.line(3).from,insert:'start\n'},userEvent:'input'});
        ed.undo();native=await api.request('ready');check(native.text===before,'Multiline undo restores mixed newline metadata');
        ed.view.dispatch({selection:{anchor:at,head:at+5}});ed.wrap('**');
        await api.request('ready');
        const saved=ed.buffer.raw;
        const nextFrame=()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
        await nextFrame();
        const lineDOM=ed.view.contentDOM.querySelector('.cm-line');
        const range=document.createRange();range.selectNodeContents(lineDOM);
        const textRect=range.getBoundingClientRect(), lineRect=lineDOM.getBoundingClientRect();
        lineDOM.dispatchEvent(new MouseEvent('dblclick',{bubbles:true,cancelable:true,clientX:textRect.left+3,clientY:(textRect.top+textRect.bottom)/2}));
        check(ed.buffer.raw===saved,'Double click on text leaves content unchanged');
        lineDOM.dispatchEvent(new MouseEvent('dblclick',{bubbles:true,cancelable:true,clientX:lineRect.right-5,clientY:(textRect.top+textRect.bottom)/2}));
        check(ed.view.state.doc.line(ed.view.state.selection.main.head===0?1:ed.view.state.doc.lineAt(ed.view.state.selection.main.head).number).text==='','Double click on blank area inserts an empty line and places caret');
        check(ed.buffer.raw===saved.replace('\r\n','\r\n\r\n'),'Blank line insertion preserves surrounding mixed line endings');
        ed.undo();check(ed.buffer.raw===saved,'Blank line insertion is undoable');
        const fixture='\n```json\n\n\n{\n  "first": "alpha",\n  "second": "beta",\n  "third": 3\n}\n```\n';
        const end=ed.view.state.doc.length;
        ed.view.dispatch({changes:{from:end,insert:fixture},userEvent:'input'});
        const start=end+fixture.indexOf('"first"'),finish=end+fixture.indexOf('"third"');
        ed.view.dispatch({selection:{anchor:start,head:finish},scrollIntoView:true});ed.view.focus();
        await nextFrame();
        const scroller=ed.view.scrollDOM.getBoundingClientRect();
        for(const line of ed.view.contentDOM.querySelectorAll('.md-code-line')) {
          const rect=line.getBoundingClientRect(), y=(rect.top+rect.bottom)/2;
          if(y<=scroller.top || y>=scroller.bottom)continue;
          const actualLine=ed.view.state.doc.lineAt(ed.view.posAtDOM(line,0)).number;
          const hit=ed.view.posAtCoords({x:rect.left+100,y});
          check(hit!==null && ed.view.state.doc.lineAt(hit).number===actualLine,`Code click row matches rendered row ${actualLine}; hit ${hit===null?'null':ed.view.state.doc.lineAt(hit).number}`);
        }
        const expected=ed.view.state.sliceDoc(start,finish);
        check(window.getSelection().toString()===expected,'Native WebKit selection matches multiline code range');
        check(!ed.view.dom.querySelector('.cm-selectionLayer'),'No independent selection layer hidden behind code backgrounds');
        const codeLine=ed.view.contentDOM.querySelector('.md-code-line');
        check(!!codeLine && !['transparent','rgba(0, 0, 0, 0)'].includes(getComputedStyle(codeLine,'::selection').backgroundColor),'Code text has visible native selection color');
        ed.toggle();await nextFrame();
        check(window.getSelection().toString()===expected,'Source mode retains native selected text');
        ed.toggle();ed.undo();check(ed.buffer.raw===saved,'Selection checks do not change saved source');
        const tableStart=ed.view.state.doc.toString().indexOf('| a');
        ed.view.dispatch({selection:{anchor:tableStart+2}});api.command('table');await nextFrame();await nextFrame();
        let drawer=document.querySelector('.table-drawer');
        check(!!drawer && !!drawer.querySelector('canvas'),'Glide canvas mounts inside table drawer');
        check(Math.abs(drawer.getBoundingClientRect().width-window.innerWidth*0.8)<2,'Table drawer occupies 80 percent of window');
        const canvas=drawer.querySelector('canvas'), canvasHost=drawer.querySelector('.table-canvas');
        check(Math.abs(canvas.getBoundingClientRect().width-canvasHost.getBoundingClientRect().width)<24,'Glide canvas fills drawer width after portal mount');
        const setCell=(value)=>{
          const input=document.querySelector('input[aria-label="当前单元格内容"]');
          input.focus();Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(input,value);
          input.dispatchEvent(new Event('input',{bubbles:true}));input.blur();
        };
        setCell('renamed');await nextFrame();
        check(ed.buffer.raw===saved,'Table draft edits do not modify document before applying');
        api.command('undo');await nextFrame();
        check(document.querySelector('input[aria-label="当前单元格内容"]').value==='a','Table undo is isolated from document');
        api.command('redo');await nextFrame();
        check(document.querySelector('input[aria-label="当前单元格内容"]').value==='renamed','Table redo restores draft cell');
        [...drawer.querySelectorAll('button')].find(b=>b.textContent==='应用修改').click();await nextFrame();
        check(ed.buffer.raw===saved.replace('| a  |','| renamed  |'),'Applying Glide edits changes only selected Markdown cell');
        ed.undo();check(ed.buffer.raw===saved,'Applied table changes undo as one document edit');
        ed.view.dispatch({selection:{anchor:tableStart+2}});api.command('table');await nextFrame();await nextFrame();
        setCell('discarded');await nextFrame();drawer=document.querySelector('.table-drawer');
        [...drawer.querySelectorAll('button')].find(b=>b.textContent==='取消').click();await nextFrame();
        [...drawer.querySelectorAll('button')].find(b=>b.textContent==='放弃修改').click();await nextFrame();
        check(ed.buffer.raw===saved && !document.querySelector('.table-drawer'),'Discarding table draft preserves original source');
        const preferences=await api.request('getPreferences');
        try {
          const separator=document.querySelector('[role="separator"][aria-label="调整文档大纲宽度"]');
          separator.dispatchEvent(new KeyboardEvent('keydown',{key:'Home',bubbles:true,cancelable:true}));await nextFrame();
          separator.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true,cancelable:true}));await nextFrame();
          check(Math.abs(document.querySelector('.sidebar').getBoundingClientRect().width-190)<1,'Sidebar separator updates measured width');
          check((await api.request('getPreferences')).sidebarWidth===190,'Sidebar width persists through native preferences');
          separator.dispatchEvent(new KeyboardEvent('keydown',{key:'End',bubbles:true,cancelable:true}));await nextFrame();
          check(document.querySelector('main').getBoundingClientRect().width>=560,'Sidebar maximum preserves writing area');
          check(ed.buffer.raw===saved,'Resizing sidebar leaves document unchanged');
        } finally { await api.request('setSidebarWidth',{width:preferences.sidebarWidth}); }
        await api.request('ready');
        return results;
        """#
        host?.web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, let host = self.host else { return }
            switch result {
            case .failure(let error): self.fail(String(describing: (error as NSError).userInfo))
            case .success(let value):
                for label in value as? [String] ?? [] { print("PASS: \(label)") }
                host.persistDraft()
                do {
                    let records = try host.recovery.records()
                    guard records.first?.source.text == host.source.text else { self.fail("Recovery content mismatch"); return }
                    print("PASS: Native recovery contains latest frontend edits")
                    guard host.save() else { self.fail("Native save failed"); return }
                    let data = try Data(contentsOf: self.root.appendingPathComponent("roundtrip.md"))
                    guard data == SourceFile(text: self.original.replacingOccurrences(of: "plain", with: "**plain**"), encoding: .utf8BOM).data else { self.fail("Byte fidelity mismatch"); return }
                    print("PASS: Saved bytes differ only at selected text and retain BOM")
                    try self.verifyDocumentDrop()
                    self.benchmark()
                } catch { self.fail(String(describing: (error as NSError).userInfo)) }
            }
        }
    }
    // 使用独立拖放剪贴板验证真实路径、多文件及图片回退，避免改动系统剪贴板。
    func verifyDocumentDrop() throws {
        guard let host else { throw Host.error("Missing host") }
        let before = host.source.data
        let first = root.appendingPathComponent("拖入文档.MD")
        let second = root.appendingPathComponent("second.markdown")
        try Data("# 拖入文档\n".utf8).write(to: first)
        try Data("# Second\n".utf8).write(to: second)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var opened: [Host] = []
        var failure: Error?
        host.web.onOpenDocuments = { urls in
            do { for url in urls { opened.append(try Host(url: url, recovery: host.recovery)) } }
            catch { failure = error }
        }
        defer { host.web.onOpenDocuments = nil; opened.forEach { $0.close() } }
        board.writeObjects([first.absoluteURL as NSURL, second.absoluteURL as NSURL])
        let accepted = host.web.openDroppedDocuments(from: board)
        guard accepted, failure == nil,
              opened.count == 2, opened[0].url?.standardizedFileURL == first.standardizedFileURL,
              opened[0].source.text == "# 拖入文档\n", host.source.data == before,
              opened.allSatisfy({ $0.window !== host.window }) else {
            throw Host.error("Document drop failed: accepted=\(accepted), opened=\(opened.count), error=\(String(describing: failure)), paths=\(opened.compactMap { $0.url?.path }), expected=\(first.path)")
        }
        board.clearContents()
        board.writeObjects([root.appendingPathComponent("image.png").absoluteURL as NSURL])
        guard !host.web.openDroppedDocuments(from: board) else { throw Host.error("Image drop intercepted") }
        print("PASS: Native document drop opens separate document hosts and preserves current text; images fall through")
    }
    func benchmark() {
        let text = String(repeating: "# Heading\n\nA paragraph with **bold**, 中文 and `code`.  \n\n```js\nconst x = 42;\n```\n\n", count: 13000)
        let file = root.appendingPathComponent("large.md")
        do { try Data(text.utf8).write(to: file) } catch { fail(error.localizedDescription); return }
        host?.source = SourceFile(text: text); host?.baseline = Data(text.utf8); host?.url = file
        host?.web.callAsyncJavaScript("return await window.editorAPI.benchmark()", arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.fail(String(describing: (error as NSError).userInfo))
            case .success(let stats):
                print("PERFORMANCE: \(stats)"); fflush(stdout)
                self.images()
            }
        }
    }
    func images() {
        let script = #"""
        const api=window.editorAPI;
        const ref=await api.request('importImage',{name:'fixture.png',data:'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='});
        const url=await api.request('imageURL',{path:ref});
        if(!url.startsWith('data:image/png;base64,'))throw new Error('Local asset did not resolve');
        const image=new Image();image.src=url;await image.decode();
        if(!image.naturalWidth)throw new Error('Image could not be decoded');
        return ref;
        """#
        host?.web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.fail(String(describing: (error as NSError).userInfo))
            case .success(let value):
                print("PASS: Image imported beside document and decoded through native bridge: \(value)")
                self.pdf()
            }
        }
    }
    func pdf() {
        let html = "<html><meta charset='utf-8'><style>body{font:16px -apple-system}p{margin:20px}</style><body><h1>中文导出验证</h1>" + (0..<120).map { "<p>分页内容。Selectable paragraph text. Marker\($0)End</p>" }.joined() + "</body></html>"
        exporter = WebPDFExporter(html: html, destination: root.appendingPathComponent("export.pdf")) { [weak self] error in
            guard let self else { return }
            if let error { self.fail(String(describing: (error as NSError).userInfo)); return }
            guard let doc = PDFDocument(url: self.root.appendingPathComponent("export.pdf")), doc.pageCount > 1, (0..<120).allSatisfy({ doc.string?.contains("Marker\($0)End") == true }) else { self.fail("PDF missing content or pagination"); return }
            print("PASS: WebKit PDF has \(doc.pageCount) pages and selectable content")
            self.host?.close(); print("Web verification completed"); fflush(stdout); exit(0)
        }
    }
    func fail(_ text: String) { fputs("FAIL: \(text)\n", stderr); fflush(stderr); exit(1) }
}
