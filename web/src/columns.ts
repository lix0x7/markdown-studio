export type ColumnBlock = {
  from: number;
  to: number;
  openEnd: number;
  ratios: number[];
  columns: { from: number; to: number; text: string }[];
  original: string;
};

// 仅识别独占一行的 div.columns / md 标记，代码围栏内的示例不参与结构解析。
export function parseColumns(text: string): ColumnBlock[] {
  if (!text.includes("columns")) return [];
  const lines = text.split("\n"),
    blocks: ColumnBlock[] = [];
  let offset = 0,
    fence = "",
    block: {
      from: number;
      openEnd: number;
      ratios: string;
      columns: ColumnBlock["columns"];
      content: number | null;
      depth: number;
    } | null = null;
  for (const line of lines) {
    const start = offset;
    offset += line.length + 1;
    const marker = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (fence) {
      if (
        marker &&
        marker[1][0] === fence[0] &&
        marker[1].length >= fence.length &&
        !marker[2].trim()
      )
        fence = "";
      continue;
    }
    if (marker) {
      fence = marker[1];
      continue;
    }
    const open = /^ {0,3}<div\b([^>]*)>\s*$/.exec(line);
    if (
      !block &&
      open &&
      /\bclass=["'][^"']*\bcolumns\b[^"']*["']/.test(open[1])
    ) {
      block = {
        from: start,
        openEnd: start + line.length,
        ratios: /\bdata-ratios=["']([^"']*)["']/.exec(open[1])?.[1] ?? "",
        columns: [],
        content: null,
        depth: 0,
      };
    } else if (block && /^\s*<md>\s*$/.test(line)) {
      if (block.content === null) block.content = offset;
      block.depth++;
    } else if (block && /^\s*<\/md>\s*$/.test(line) && block.content !== null) {
      if (--block.depth > 0) continue;
      // 结束标记前的换行属于容器，避免空栏输入时向编辑器强制补换行。
      const end = Math.max(block.content, start - 1);
      block.columns.push({
        from: block.content,
        to: end,
        text: text.slice(block.content, end),
      });
      block.content = null;
    } else if (
      block &&
      /^\s*<\/div>\s*$/.test(line) &&
      block.content === null
    ) {
      if (block.columns.length >= 2) {
        const ratios = block.ratios.split(",").map(Number);
        blocks.push({
          from: block.from,
          to: start + line.length,
          openEnd: block.openEnd,
          ratios:
            ratios.length === block.columns.length &&
            ratios.every((n) => Number.isFinite(n) && n > 0)
              ? ratios
              : block.columns.map(() => 1),
          columns: block.columns,
          original: text.slice(block.from, start + line.length),
        });
      }
      block = null;
    }
  }
  return blocks;
}
export function columnMarkup(
  contents: string[],
  ratios = contents.map(() => 1),
): string {
  return (
    `<div class="columns" data-ratios="${ratios.join(",")}" style="display:grid;grid-template-columns:${ratios.map((r) => `minmax(0,${r}fr)`).join(" ")};gap:24px;align-items:start">\n` +
    contents
      .map(
        (text) =>
          `<section style="min-width:0;overflow-wrap:anywhere;white-space:pre-wrap">\n<md>\n${text}\n</md>\n</section>`,
      )
      .join("\n") +
    "\n</div>"
  );
}
