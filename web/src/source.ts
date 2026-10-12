export type Patch = { from: number; to: number; insert: string };
// 编辑器使用 LF 坐标；单独保留每个原始换行，避免保存时整篇规范化。
export class SourceBuffer {
  raw: string;
  endings: string[];
  preferred: string;
  constructor(raw: string) {
    this.raw = raw;
    this.endings = raw.match(/\r\n|\r|\n/g) ?? [];
    this.preferred = this.endings[0] ?? "\n";
  }
  normalized() {
    return this.raw.replace(/\r\n|\r/g, "\n");
  }
  apply(changes: Patch[], finalEndings?: string[]): Patch[] {
    const breaks: number[] = [];
    let pos = 0;
    for (const line of this.raw.split(/\r\n|\r|\n/).slice(0, -1)) {
      pos += line.length;
      breaks.push(pos);
      pos++;
    }
    const offset = (at: number) => {
      let extra = 0;
      for (let i = 0; i < breaks.length && breaks[i] < at; i++)
        extra += this.endings[i].length - 1;
      return at + extra;
    };
    let delta = 0;
    const mapped = changes.map((c) => {
      const before = breaks.filter((p) => p < c.from).length,
        removed = breaks.filter((p) => p >= c.from && p < c.to).length;
      let index = before + delta;
      const insert = c.insert.replace(
        /\r\n|\r|\n/g,
        () => finalEndings?.[index++] ?? this.preferred,
      );
      delta += (c.insert.match(/\n/g)?.length ?? 0) - removed;
      return { from: offset(c.from), to: offset(c.to), insert };
    });
    for (const c of [...mapped].sort((a, b) => b.from - a.from))
      this.raw = this.raw.slice(0, c.from) + c.insert + this.raw.slice(c.to);
    this.endings = this.raw.match(/\r\n|\r|\n/g) ?? [];
    return mapped;
  }
}
export function minimalPatch(
  old: string,
  value: string,
  offset = 0,
): Patch | null {
  if (old === value) return null;
  let a = 0,
    b = old.length,
    c = value.length;
  while (a < b && a < c && old[a] === value[a]) a++;
  while (b > a && c > a && old[b - 1] === value[c - 1]) {
    b--;
    c--;
  }
  return { from: offset + a, to: offset + b, insert: value.slice(a, c) };
}
export type Cell = { value: string; from: number; to: number };
export function cells(line: string, offset = 0): Cell[] {
  const boundaries: number[] = [];
  let ticks = 0;
  for (let i = 0; i < line.length; i++) {
    if (line[i] === "\\") {
      i++;
      continue;
    }
    if (line[i] === "`") {
      let end = i;
      while (line[end] === "`") end++;
      const n = end - i;
      ticks = ticks === n ? 0 : ticks === 0 ? n : ticks;
      i = end - 1;
      continue;
    }
    if (line[i] === "|" && !ticks) boundaries.push(i);
  }
  if (!boundaries.length) return [];
  const edges = [-1, ...boundaries, line.length];
  const result: Cell[] = [];
  for (let i = 0; i < edges.length - 1; i++) {
    let a = edges[i] + 1,
      b = edges[i + 1];
    if ((i === 0 || i === edges.length - 2) && !line.slice(a, b).trim())
      continue;
    while (a < b && /[ \t]/.test(line[a])) a++;
    while (b > a && /[ \t]/.test(line[b - 1])) b--;
    result.push({ value: line.slice(a, b), from: offset + a, to: offset + b });
  }
  return result;
}
export function escapeCell(value: string) {
  return value.replace(/\r?\n/g, " ").replace(/(?<!\\)\|/g, "\\|");
}
export type TableModel = {
  from: number;
  to: number;
  original: string;
  rows: Cell[][];
  separators: Cell[];
  aligns: string[];
};
export function parseTable(text: string, offset = 0): TableModel | null {
  const lines = text.split("\n");
  if (lines.length < 2) return null;
  const sep = cells(lines[1], offset + lines[0].length + 1);
  if (!sep.length || !sep.every((c) => /^:?-{3,}:?$/.test(c.value)))
    return null;
  let at = offset;
  const rows: Cell[][] = [];
  for (let i = 0; i < lines.length; i++) {
    if (i !== 1) {
      const row = cells(lines[i], at);
      if (row.length !== sep.length) return null;
      rows.push(row);
    }
    at += lines[i].length + 1;
  }
  return {
    from: offset,
    to: offset + text.length,
    original: text,
    rows,
    separators: sep,
    aligns: sep.map((c) =>
      c.value.endsWith(":")
        ? c.value.startsWith(":")
          ? "center"
          : "right"
        : "left",
    ),
  };
}
export function tablePatches(
  table: TableModel,
  rows: string[][],
  aligns: string[],
): Patch[] {
  if (
    rows.length === table.rows.length &&
    aligns.length === table.aligns.length
  ) {
    const patches: Patch[] = [];
    rows.forEach((row, r) =>
      row.forEach((value, c) => {
        const old = table.rows[r][c];
        if (value !== old.value)
          patches.push({
            from: old.from,
            to: old.to,
            insert: escapeCell(value),
          });
      }),
    );
    aligns.forEach((a, c) => {
      if (a !== table.aligns[c]) {
        const old = table.separators[c],
          dash = old.value.replace(/:/g, "");
        patches.push({
          from: old.from,
          to: old.to,
          insert:
            (a === "center" ? ":" : "") + dash + (a !== "left" ? ":" : ""),
        });
      }
    });
    return patches.sort((a, b) => a.from - b.from);
  }
  const output = rows.map(
    (row) => "| " + row.map(escapeCell).join(" | ") + " |",
  );
  output.splice(
    1,
    0,
    "| " +
      aligns
        .map((a) => (a === "center" ? ":---:" : a === "right" ? "---:" : "---"))
        .join(" | ") +
      " |",
  );
  const patch = minimalPatch(table.original, output.join("\n"), table.from);
  return patch ? [patch] : [];
}
