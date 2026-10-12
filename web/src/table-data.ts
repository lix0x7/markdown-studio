export type TableDraft = { rows: string[][]; aligns: string[] };

// 排序只移动数据行；表头固定，空值始终置底，相等键保持原顺序。
export function sortTable(
  draft: TableDraft,
  column: number,
  descending: boolean,
): TableDraft {
  const collator = new Intl.Collator("zh-CN", {
    numeric: true,
    sensitivity: "base",
  });
  const body = draft.rows.slice(1).sort((a, b) => {
    const left = a[column].trim(),
      right = b[column].trim();
    if (!left || !right) return !left && !right ? 0 : !left ? 1 : -1;
    const numeric = Number(left),
      other = Number(right);
    const order =
      Number.isFinite(numeric) && Number.isFinite(other)
        ? numeric - other
        : collator.compare(left, right);
    return descending ? -order : order;
  });
  return { ...draft, rows: [draft.rows[0], ...body] };
}

// 保留粘贴区域外的内容，并按需补足行列；整次粘贴由调用方记为一个撤销步骤。
export function pasteTable(
  draft: TableDraft,
  column: number,
  row: number,
  values: readonly (readonly string[])[],
): TableDraft {
  const width = Math.max(
    draft.aligns.length,
    column + Math.max(...values.map((r) => r.length)),
  );
  const height = Math.max(draft.rows.length, row + values.length);
  const rows = Array.from({ length: height }, (_, r) =>
    Array.from({ length: width }, (_, c) => draft.rows[r]?.[c] ?? ""),
  );
  values.forEach((line, r) =>
    line.forEach((value, c) => {
      rows[row + r][column + c] = value;
    }),
  );
  const aligns = Array.from(
    { length: width },
    (_, c) => draft.aligns[c] ?? "left",
  );
  return { rows, aligns };
}
