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
            NSApp.activate(ignoringOtherApps: true)
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
        ed.view.dispatch({selection:{anchor:ed.view.state.doc.length}});
        const editorPaste=new DataTransfer();
        editorPaste.setData('text/html','<table><tr><th>Name</th><th>Value</th></tr><tr><td>Alpha</td><td>42</td></tr></table>');
        editorPaste.setData('text/plain','Name\tValue\nAlpha\t42');
        ed.view.contentDOM.dispatchEvent(new ClipboardEvent('paste',{clipboardData:editorPaste,bubbles:true,cancelable:true}));
        check(ed.buffer.raw.includes('| Name | Value |') && ed.buffer.raw.includes('| --- | --- |'),'Editor paste converts clipboard HTML into Markdown table');
        ed.undo();check(ed.buffer.raw===saved,'Pasted Markdown table undoes in one step');
        ed.view.dispatch({selection:{anchor:0},scrollIntoView:true});
        const nextFrame=()=>new Promise(r=>{const timeout=setTimeout(r,100);requestAnimationFrame(()=>requestAnimationFrame(()=>{clearTimeout(timeout);r();}));});
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
        // 用真实布局验证横向滚动和超长文本的宽度上限。
        const compactTable=document.querySelector('.md-table');
        const contentStyle=getComputedStyle(ed.view.contentDOM);
        const readingWidth=ed.view.contentDOM.clientWidth-parseFloat(contentStyle.paddingLeft)-parseFloat(contentStyle.paddingRight);
        check(!!compactTable && !compactTable.classList.contains('md-table-wide'),'Small table stays in the reading column');
        check(Math.abs(compactTable.getBoundingClientRect().width-readingWidth)<2,'Small table width matches surrounding paragraphs');
        const wideFixture='\n\n| Alpha | Beta | Gamma |\n| --- | --- | --- |\n| '+('unbroken'.repeat(180))+' | '+('中文内容'.repeat(80))+' | tail |\n\n';
        const wideEnd=ed.view.state.doc.length;
        ed.view.dispatch({changes:{from:wideEnd,insert:wideFixture},selection:{anchor:0},userEvent:'input'});
        ed.view.dispatch({selection:{anchor:ed.view.state.doc.length},scrollIntoView:true});
        await nextFrame();await nextFrame();
        const tableScroll=[...document.querySelectorAll('.table-scroll')].at(-1);
        const wideTable=tableScroll.querySelector('table');
        const writingWidth=document.querySelector('.editor-host').getBoundingClientRect().width;
        check(Math.abs(tableScroll.getBoundingClientRect().width-(writingWidth-48))<2,'Table viewport fills editor width with side gutters');
        const paragraphWidth=ed.view.contentDOM.getBoundingClientRect().width;
        check(paragraphWidth<=796,'Normal writing column retains its reading width');
        check(wideTable.getBoundingClientRect().width<=window.innerWidth*2+2,'Preview table stays within twice the window width');
        check(tableScroll.scrollWidth>tableScroll.clientWidth,'Wide preview table overflows its own scroll container');
        tableScroll.scrollLeft=120;
        check(tableScroll.scrollLeft>0,'Preview table scrolls horizontally');
        check(ed.view.scrollDOM.scrollWidth<=ed.view.scrollDOM.clientWidth+2,'Wide table does not widen the document');
        ed.undo();check(ed.buffer.raw===saved,'Table layout does not alter Markdown source');
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
        // 验证列结构操作、选中列跟随和 F2 原位编辑。
        const tableButton=label=>[...drawer.querySelectorAll('button')].find(b=>b.textContent===label);
        check(tableButton('删除行').disabled && tableButton('上移行').disabled,'Header row cannot be deleted or moved');
        tableButton('下方插入行').click();await nextFrame();
        check(drawer.querySelector('.table-drawer-footer').textContent.includes('3 行'),'Insert row below selection');
        setCell('new row');await nextFrame();
        tableButton('下移行').click();await nextFrame();
        check(document.querySelector('input[aria-label="当前单元格内容"]').value==='new row' && drawer.querySelector('.table-formula span').textContent.includes('第 3 行'),'Moved row remains selected');
        tableButton('上移行').click();await nextFrame();
        tableButton('上方插入行').click();await nextFrame();
        check(document.querySelector('input[aria-label="当前单元格内容"]').value==='','Insert row above selection selects new row');
        tableButton('删除行').click();await nextFrame();
        for(let i=0;i<6;i++){api.command('undo');await nextFrame();}
        check(drawer.querySelector('.table-drawer-footer').textContent.includes('2 行') && document.querySelector('input[aria-label="当前单元格内容"]').value==='a','Undo restores all row operations and header');
        tableButton('右移列').click();await nextFrame();
        check(document.querySelector('input[aria-label="当前单元格内容"]').value==='a','Moved column remains selected');
        check(document.querySelector('select[aria-label="当前列对齐方式"]').value==='left','Column alignment moves with its data');
        tableButton('左侧插入列').click();await nextFrame();
        check(drawer.querySelector('.table-drawer-footer').textContent.includes('3 列'),'Insert column at selected position');
        check(document.querySelector('input[aria-label="当前单元格内容"]').value==='','Inserted column is selected');
        tableButton('删除列').click();await nextFrame();
        check(drawer.querySelector('.table-drawer-footer').textContent.includes('2 列'),'Delete selected column');
        api.command('undo');await nextFrame();api.command('undo');await nextFrame();api.command('undo');await nextFrame();
        check(document.querySelector('input[aria-label="当前单元格内容"]').value==='a','Undo restores original column order');
        canvas.focus();
        canvas.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}));await nextFrame();
        canvas.dispatchEvent(new KeyboardEvent('keydown',{key:'F2',bubbles:true,cancelable:true}));await nextFrame();
        for(let wait=0;wait<20 && !document.querySelector('#portal textarea,#portal input');wait++) await new Promise(r=>setTimeout(r,25));
        const cellEditor=document.querySelector('#portal textarea,#portal input');
        check(!!cellEditor,'F2 opens in-cell text editor');
        cellEditor.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));await nextFrame();
        // 撤销/重做一次恢复首个单元格，继续既有单元格提交验证。
        api.command('redo');await nextFrame();api.command('undo');await nextFrame();
        // 使用隔离剪贴板验证网格事件，避免改动用户系统剪贴板。
        const clipboardDescriptor=Object.getOwnPropertyDescriptor(navigator,'clipboard');
        Object.defineProperty(navigator,'clipboard',{configurable:true,value:{}});
        try {
          canvas.focus();
          const pasted='数量\t名称\t备注\n10\t十\tA\n2\t二\tB\n\t空\tC';
          const pasteData=new DataTransfer();pasteData.setData('text/plain',pasted);
          canvas.dispatchEvent(new ClipboardEvent('paste',{clipboardData:pasteData,bubbles:true,cancelable:true}));await nextFrame();
          check(drawer.querySelector('.table-drawer-footer').textContent.includes('4 行 × 3 列'),'Rectangle paste expands rows and columns');
          const copied=new DataTransfer();
          canvas.dispatchEvent(new ClipboardEvent('copy',{clipboardData:copied,bubbles:true,cancelable:true}));await nextFrame();
          check(copied.getData('text/plain')===pasted,'Selected rectangle copies as TSV');
          tableButton('升序排列').click();await nextFrame();
          canvas.focus();const ascending=new DataTransfer();canvas.dispatchEvent(new ClipboardEvent('copy',{clipboardData:ascending,bubbles:true,cancelable:true}));await nextFrame();
          check(ascending.getData('text/plain')==='数量\t名称\t备注\n2\t二\tB\n10\t十\tA\n\t空\tC','Ascending sort keeps header and sorts whole numeric rows');
          tableButton('降序排列').click();await nextFrame();
          canvas.focus();const descending=new DataTransfer();canvas.dispatchEvent(new ClipboardEvent('copy',{clipboardData:descending,bubbles:true,cancelable:true}));await nextFrame();
          check(descending.getData('text/plain')===pasted,'Descending sort keeps empty values last');
          api.command('undo');await nextFrame();api.command('undo');await nextFrame();api.command('undo');await nextFrame();
          check(drawer.querySelector('.table-drawer-footer').textContent.includes('2 行 × 2 列'),'Paste and sorts each undo in one step');
          check(ed.buffer.raw===saved,'Undo of clipboard and sorting restores original source');
        } finally {
          if(clipboardDescriptor) Object.defineProperty(navigator,'clipboard',clipboardDescriptor);
          else delete navigator.clipboard;
        }
        setCell('renamed');await nextFrame();
        check(ed.buffer.raw===saved.replace('| a  |','| renamed  |'),'Table cell edits immediately sync to source');
        check((await api.request('ready')).text===ed.buffer.raw,'Live table edit reaches native document');
        api.command('undo');await nextFrame();
        check(document.querySelector('input[aria-label="当前单元格内容"]').value==='a','Table undo restores cell');
        api.command('redo');await nextFrame();
        check(document.querySelector('input[aria-label="当前单元格内容"]').value==='renamed','Table redo restores draft cell');
        [...drawer.querySelectorAll('button')].find(b=>b.textContent==='关闭').click();await nextFrame();
        check(ed.buffer.raw===saved.replace('| a  |','| renamed  |'),'Closing table retains synchronized cell changes');
        ed.undo();check(ed.buffer.raw===saved,'Applied table changes undo as one document edit');
        ed.view.dispatch({selection:{anchor:tableStart+2}});api.command('table');await nextFrame();await nextFrame();
        setCell('live');await nextFrame();drawer=document.querySelector('.table-drawer');
        [...drawer.querySelectorAll('button')].find(b=>b.textContent==='关闭').click();await nextFrame();
        check(ed.buffer.raw===saved.replace('| a  |','| live  |') && !document.querySelector('.table-drawer'),'Closing live table requires no apply or discard confirmation');
        ed.undo();check(ed.buffer.raw===saved,'Document undo reverses live table edit after close');
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
                self.columns()
            }
        }
    }
    func columns() {
        let script = #"""
        const api=window.editorAPI, ed=api.editor;
        // 性能测试使用独立编辑器写入宿主，恢复主编辑器对应的原生文本基线。
        const nativeBefore=await api.request('ready');
        await api.request('change',{patches:[{from:0,to:nativeBefore.text.length,insert:ed.buffer.raw}]});
        const pause=()=>new Promise(r=>setTimeout(r,100));
        const source='# Before\n\n<div class="columns" data-ratios="2,1,1">\n<md>\n# Left\n\nleft text\n</md>\n<md>\n## Middle\n\n| A | B |\n| --- | --- |\n| x | y |\n</md>\n<md>\n## Right\n\nright text\n</md>\n</div>\n\nAfter';
        ed.view.dispatch({changes:{from:0,to:ed.view.state.doc.length,insert:source},selection:{anchor:0},scrollIntoView:true});await pause();await pause();
        let panes=[...document.querySelectorAll('.column-pane')];
        if(panes.length!==3)throw new Error('Three column editors did not mount');
        const widths=panes.map(p=>p.getBoundingClientRect().width);
        if(Math.abs(widths[0]/widths[1]-2)>0.1)throw new Error('Initial column ratio incorrect');
        panes[0].querySelector('.cm-content').focus();
        const child=ed.active();
        if(child===ed)throw new Error('Active column routing failed');
        child.view.dispatch({changes:{from:child.view.state.doc.length,insert:'追加内容\n'},userEvent:'input'});await pause();
        if(!ed.buffer.raw.includes('追加内容') || (await api.request('ready')).text!==ed.buffer.raw)throw new Error('Column edits did not sync to native document');
        if(panes[0]!==document.querySelector('.column-pane'))throw new Error('Typing replaced active column DOM');
        ed.undo();await pause();
        if(ed.view.state.doc.toString()!==source)throw new Error('Column undo did not restore source: '+ed.view.state.doc.toString().slice(0,80));
        const divider=document.querySelector('.column-divider');
        divider.setPointerCapture=()=>{};divider.releasePointerCapture=()=>{};
        divider.dispatchEvent(new PointerEvent('pointerdown',{clientX:300,button:0,pointerId:1,bubbles:true}));
        divider.dispatchEvent(new PointerEvent('pointermove',{clientX:340,pointerId:1,bubbles:true}));
        divider.dispatchEvent(new PointerEvent('pointerup',{clientX:340,pointerId:1,bubbles:true}));await pause();
        const ratios=/data-ratios="([^"]+)"/.exec(ed.buffer.raw)[1].split(',').map(Number);
        if(ratios[0]<=2 || ratios[1]>=1 || ratios[2]!==1 || Math.abs(ratios[0]+ratios[1]-3)>0.00001)throw new Error('Drag did not preserve adjacent pair total and third column');
        if(!ed.buffer.raw.includes('right text'))throw new Error('Resize changed column content');
        ed.undo();await pause();if(ed.view.state.doc.toString()!==source)throw new Error('Ratio drag undo failed');
        panes=[...document.querySelectorAll('.column-pane')];panes[1].querySelector('.cm-content').focus();
        const middle=ed.active();middle.view.dispatch({selection:{anchor:middle.view.state.doc.toString().indexOf('| A')+2}});
        api.command('table');await pause();await pause();
        const cell=document.querySelector('input[aria-label="当前单元格内容"]');
        cell.focus();Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(cell,'Nested');cell.dispatchEvent(new Event('input',{bubbles:true}));cell.blur();await pause();
        if(!ed.buffer.raw.includes('| Nested | B |'))throw new Error('Column table changes targeted the wrong editor');
        document.querySelector('[aria-label="关闭表格编辑器"]').click();await pause();
        ed.undo();await pause();if(ed.view.state.doc.toString()!==source)throw new Error('Column table undo failed');
        [...document.querySelectorAll('.columns-toolbar button')].find(b=>b.textContent==='添加分栏').click();await pause();await pause();
        if(document.querySelectorAll('.column-pane').length!==4)throw new Error('Add column failed');
        ed.undo();await pause();await pause();
        [...document.querySelectorAll('.columns-toolbar button')].find(b=>b.textContent==='取消分栏').click();await pause();
        if(ed.buffer.raw.includes('<md>') || !ed.buffer.raw.includes('left text') || !ed.buffer.raw.includes('right text'))throw new Error('Unwrap columns lost content');
        ed.undo();await pause();await pause();
        ed.jump(ed.view.state.doc.toString().indexOf('## Right'));await pause();
        if(ed.active()===ed || !ed.active().view.state.doc.toString().includes('right text'))throw new Error('Outline did not focus column editor');
        const nested='<div class="columns">\n<md>\nInner A\n</md>\n<md>\nInner B\n</md>\n</div>';
        const nestedSource=source.replace('left text',nested);
        ed.view.dispatch({changes:{from:0,to:ed.view.state.doc.length,insert:nestedSource},selection:{anchor:0},scrollIntoView:true});await pause();await pause();
        if(document.querySelectorAll('.column-pane').length!==5)throw new Error('Nested columns did not mount');
        document.querySelector('.column-pane .column-pane .cm-content').focus();
        const inner=ed.active();inner.view.dispatch({changes:{from:inner.view.state.doc.length,insert:' nested edit'}});await pause();await pause();
        if(!ed.buffer.raw.includes('Inner A nested edit') || (await api.request('ready')).text!==ed.buffer.raw)throw new Error('Nested column edit did not sync');
        ed.undo();await pause();await pause();
        if(ed.view.state.doc.toString()!==nestedSource)throw new Error('Nested column undo failed');
        return 'Three columns, nested editing, native sync, stable DOM, adjacent resizing, outline, add, unwrap and undo';
        """#
        host?.web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.fail(String(describing: (error as NSError).userInfo))
            case .success(let value): print("PASS: \(value)"); self.images()
            }
        }
    }
    func images() {
        let script = #"""
        const api=window.editorAPI, ed=api.editor;
        const prefs=await api.request('getPreferences');
        const data='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
        try {
          await api.request('setImagePasteMode',{mode:'directory'});
          const ref=await api.request('importImage',{name:'fixture.png',data});
          if(ref.includes('/') || ref.startsWith('data:'))throw new Error('Image not saved beside document');
          const url=await api.request('imageURL',{path:ref});
          const image=new Image();image.src=url;await image.decode();
          if(!image.naturalWidth)throw new Error('Local image decode failed');
          await api.request('setImagePasteMode',{mode:'base64'});
          const embedded=await api.request('importImage',{name:'fixture.png',data});
          if(embedded!=='data:image/png;base64,'+data)throw new Error('Base64 image mismatch');
          if(await api.request('imageURL',{path:embedded})!==embedded)throw new Error('Base64 image resolution failed');
          const text='# Image test\n\n<img src="'+embedded+'" alt="fixture" width="128" height="128">\n\nEnd';
          ed.view.dispatch({changes:{from:0,to:ed.view.state.doc.length,insert:text},selection:{anchor:0},scrollIntoView:true});
          const frame=()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
          await frame();await frame();
          let widget=document.querySelector('.md-image');
          if(!widget)throw new Error('HTML image preview missing');
          await widget.querySelector('img').decode();await frame();
          widget.querySelector('[aria-label="图片居中"]').click();await frame();
          if(!ed.buffer.raw.includes('align="center"'))throw new Error('Image alignment was not saved');
          widget=document.querySelector('.md-image');
          await widget.querySelector('img').decode();await frame();
          const handle=widget.querySelector('.image-resize');
          // 合成事件没有真实 pointer capture，单独验证拖拽处理器的尺寸计算与提交。
          handle.setPointerCapture=()=>{};handle.releasePointerCapture=()=>{};
          handle.dispatchEvent(new PointerEvent('pointerdown',{clientX:100,clientY:100,pointerId:1,bubbles:true}));
          handle.dispatchEvent(new PointerEvent('pointermove',{clientX:140,clientY:100,pointerId:1,bubbles:true}));
          handle.dispatchEvent(new PointerEvent('pointerup',{clientX:140,clientY:100,pointerId:1,bubbles:true}));await frame();
          if(!ed.buffer.raw.includes('width="168" height="168"'))throw new Error('Image proportional resize failed: '+ed.buffer.raw.slice(-120));
          ed.undo();await frame();
          if(!ed.buffer.raw.includes('width="128" height="128"'))throw new Error('Image resize undo failed');
          api.command('settings');await frame();
          if(!document.querySelector('.settings-field select'))throw new Error('Global settings panel missing');
          const widthSelect=document.querySelector('select[aria-label="页面宽度"]');
          if(!widthSelect || widthSelect.options.length!==3)throw new Error('Page width options missing');
          const app=document.querySelector('.app'), oldWidth=app.style.width, sourceBeforeWidth=ed.buffer.raw;
          app.style.width='1700px';
          try {
            const widths=[];
            for(const mode of ['default','wide','full']) {
              Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(widthSelect,mode);
              widthSelect.dispatchEvent(new Event('change',{bubbles:true}));await frame();await frame();
              if((await api.request('getPreferences')).pageWidth!==mode || app.dataset.pageWidth!==mode)throw new Error('Page width did not persist or apply: '+mode);
              widths.push(ed.view.contentDOM.getBoundingClientRect().width);
            }
            if(Math.abs(widths[0]-796)>1 || Math.abs(widths[1]-1100)>1 || widths[2]<=widths[1])throw new Error('Page widths incorrect: '+widths);
            if(ed.buffer.raw!==sourceBeforeWidth)throw new Error('Page width changed document content');
            await api.request('setPageWidth',{mode:'default'});await frame();
            if(app.dataset.pageWidth!=='default' || widthSelect.value!=='default')throw new Error('Native preference broadcast not applied');
          } finally {
            app.style.width=oldWidth;
            await api.request('setPageWidth',{mode:prefs.pageWidth ?? 'default'});await frame();
          }
          document.querySelector('[aria-label="关闭"]').click();
          return ref+'; base64, alignment, proportional resize, undo, settings and page widths passed';
        } finally { await api.request('setImagePasteMode',{mode:prefs.imagePasteMode ?? 'directory'}); }

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
