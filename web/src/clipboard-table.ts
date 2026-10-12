import DOMPurify from "dompurify";

// 优先读取 HTML 表格；合并单元格保留左上角内容，其余位置补空。
export function clipboardTable(html: string, text: string): string | null {
  let rows: string[][] = [];
  if (html) {
    const doc = new DOMParser().parseFromString(
      DOMPurify.sanitize(html),
      "text/html",
    );
    const table = doc.querySelector("table");
    if (table) {
      const remaining = doc.body.cloneNode(true) as HTMLElement;
      remaining
        .querySelectorAll("table,style,script")
        .forEach((el) => el.remove());
      if (remaining.textContent?.trim()) return null;
      if (doc.querySelectorAll("table").length !== 1) return null;
      Array.from(table.rows).forEach((tr, r) => {
        rows[r] ??= [];
        let c = 0;
        for (const cell of Array.from(tr.cells)) {
          while (rows[r][c] !== undefined) c++;
          cell.querySelectorAll("br").forEach((br) => br.replaceWith("\n"));
          const value = cell.textContent?.trim() ?? "";
          for (
            let dr = 0;
            dr < Math.min(cell.rowSpan || 1, table.rows.length - r);
            dr++
          ) {
            rows[r + dr] ??= [];
            for (let dc = 0; dc < cell.colSpan; dc++)
              rows[r + dr][c + dc] = dr === 0 && dc === 0 ? value : "";
          }
          c += cell.colSpan;
        }
      });
    }
  }
  // TSV 支持 Excel 引号转义和单元格内换行；普通文本交回编辑器处理。
  if (!rows.length) {
    if (!text.includes("\t")) return null;
    const input = text.replace(/\r\n?/g, "\n");
    let row: string[] = [],
      cell = "",
      quoted = false;
    for (let i = 0; i < input.length; i++) {
      const ch = input[i];
      if (ch === '"' && (quoted || !cell)) {
        if (quoted && input[i + 1] === '"') {
          cell += '"';
          i++;
        } else quoted = !quoted;
      } else if (!quoted && (ch === "\t" || ch === "\n")) {
        row.push(cell);
        cell = "";
        if (ch === "\n") {
          rows.push(row);
          row = [];
        }
      } else cell += ch;
    }
    if (quoted) return null;
    if (cell || row.length || !input.endsWith("\n")) {
      row.push(cell);
      rows.push(row);
    }
    if (!rows.some((r) => r.length > 1)) return null;
  }
  if (!rows.length) return null;
  const width = Math.max(...rows.map((r) => r.length));
  const lines = rows.map(
    (row) =>
      "| " +
      Array.from({ length: width }, (_, c) =>
        (row[c] ?? "")
          .replace(/&/g, "&amp;")
          .replace(/</g, "&lt;")
          .replace(/>/g, "&gt;")
          .replace(/[\\|`*_[\]]/g, "\\$&")
          .replace(/\n/g, "<br>"),
      ).join(" | ") +
      " |",
  );
  lines.splice(1, 0, "| " + Array(width).fill("---").join(" | ") + " |");
  return lines.join("\n");
}
