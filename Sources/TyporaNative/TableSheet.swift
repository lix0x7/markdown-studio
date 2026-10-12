import AppKit
import MarkdownCore

final class TableSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 430), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    private let table = NSTableView()
    private let alignment = NSPopUpButton()
    private let columnChoice = NSPopUpButton()
    private let original: MarkdownTable
    private var model: MarkdownTable
    private let onApply: ([TextEdit]) -> Void
    private var currentRow = 0
    private var currentColumn = 0

    // 表格窗口维护临时模型，点击应用后才按原始位置生成正文编辑。
    init(model: MarkdownTable, onApply: @escaping ([TextEdit]) -> Void) {
        self.model = model; original = model; self.onApply = onApply
        super.init()
        panel.title = "编辑表格 · Tab 切换单元格"
        panel.minSize = NSSize(width: 640, height: 320)
        let root = NSView(); panel.contentView = root
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        table.delegate = self; table.dataSource = self; table.rowHeight = 32
        table.target = self; table.action = #selector(beginCellEditing)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        scroll.documentView = table
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 8
        for (title, action) in [("＋ 行", #selector(addRow)), ("− 行", #selector(removeRow)), ("＋ 列", #selector(addColumn)), ("− 列", #selector(removeColumn))] {
            controls.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        columnChoice.target = self; columnChoice.action = #selector(selectColumn)
        alignment.addItems(withTitles: ["左对齐", "居中", "右对齐"]); alignment.target = self; alignment.action = #selector(changeAlignment)
        controls.addArrangedSubview(columnChoice); controls.addArrangedSubview(alignment)
        let footer = NSStackView(); footer.orientation = .horizontal; footer.spacing = 12
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "应用", target: self, action: #selector(apply)); apply.keyEquivalent = "\r"
        footer.addArrangedSubview(cancel); footer.addArrangedSubview(apply)
        for view in [scroll, controls, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: root.topAnchor, constant: 16), controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        rebuildColumns()
    }
    func present(on window: NSWindow) { window.beginSheet(panel) }
    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let col = Int(id) else { return nil }
        let field = NSTextField(string: model.rows[row][col])
        field.isBordered = false; field.drawsBackground = false; field.font = .systemFont(ofSize: 13, weight: row == 0 ? .semibold : .regular)
        field.isEditable = true; field.isSelectable = true
        field.delegate = self; field.identifier = NSUserInterfaceItemIdentifier("\(row):\(col)")
        return field
    }
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let parts = field.identifier!.rawValue.split(separator: ":").compactMap { Int($0) }
        currentRow = parts[0]; currentColumn = parts[1]
        columnChoice.selectItem(at: currentColumn); selectColumn()
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        update(field)
    }
    private func update(_ field: NSTextField) {
        let parts = field.identifier!.rawValue.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, parts[0] < model.rows.count, parts[1] < model.alignments.count else { return }
        let value = field.stringValue.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        model.rows[parts[0]][parts[1]] = MarkdownTable.escapedCell(value)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertTab(_:)) || commandSelector == #selector(NSResponder.insertBacktab(_:)), let field = control as? NSTextField else { return false }
        update(field)
        let position = field.identifier!.rawValue.split(separator: ":").compactMap { Int($0) }
        currentRow = position[0]; currentColumn = position[1]
        let delta = commandSelector == #selector(NSResponder.insertTab(_:)) ? 1 : -1
        let count = model.alignments.count, next = currentRow * count + currentColumn + delta
        guard next >= 0 else { return true }
        if next >= model.rows.count * count { model.rows.append(Array(repeating: "", count: count)); table.reloadData() }
        let row = next / count, col = next % count
        table.scrollRowToVisible(row)
        if let nextField = table.view(atColumn: col, row: row, makeIfNecessary: true) as? NSTextField { nextField.selectText(nil) }
        return true
    }
    @objc private func beginCellEditing() {
        let row = table.clickedRow, column = table.clickedColumn
        guard row >= 0, column >= 0 else { return }
        currentRow = row; currentColumn = column
        columnChoice.selectItem(at: column); selectColumn()
        if let field = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField { field.selectText(nil) }
    }
    private func rebuildColumns() {
        for column in table.tableColumns { table.removeTableColumn(column) }
        for col in model.alignments.indices {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(col)))
            column.isEditable = true
            column.title = "列 \(col + 1)"; column.width = max(150, 660 / CGFloat(model.alignments.count)); column.minWidth = 80
            table.addTableColumn(column)
        }
        columnChoice.removeAllItems(); columnChoice.addItems(withTitles: model.alignments.indices.map { "列 \($0 + 1)" })
        currentColumn = min(currentColumn, model.alignments.count - 1)
        columnChoice.selectItem(at: currentColumn); selectColumn(); table.reloadData()
    }
    @objc private func selectColumn() {
        currentColumn = columnChoice.indexOfSelectedItem
        alignment.selectItem(at: ["left", "center", "right"].firstIndex(of: model.alignments[currentColumn]) ?? 0)
    }
    @objc private func changeAlignment() { model.alignments[currentColumn] = ["left", "center", "right"][alignment.indexOfSelectedItem] }
    @objc private func addRow() { panel.makeFirstResponder(nil); model.rows.insert(Array(repeating: "", count: model.alignments.count), at: min(currentRow + 1, model.rows.count)); table.reloadData() }
    @objc private func removeRow() {
        panel.makeFirstResponder(nil)
        guard currentRow > 0, model.rows.count > 1 else { NSSound.beep(); return }
        model.rows.remove(at: currentRow); currentRow = min(currentRow, model.rows.count - 1); table.reloadData()
    }
    @objc private func addColumn() { panel.makeFirstResponder(nil); for row in model.rows.indices { model.rows[row].insert("", at: currentColumn + 1) }; model.alignments.insert("left", at: currentColumn + 1); rebuildColumns() }
    @objc private func removeColumn() { panel.makeFirstResponder(nil); guard model.alignments.count > 1 else { return }; for row in model.rows.indices { model.rows[row].remove(at: currentColumn) }; model.alignments.remove(at: currentColumn); rebuildColumns() }
    @objc private func cancel() { panel.sheetParent?.endSheet(panel) }
    @objc private func apply() { panel.makeFirstResponder(nil); onApply(model.edits(comparedTo: original)); panel.sheetParent?.endSheet(panel) }
}
