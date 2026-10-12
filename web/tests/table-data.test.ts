import { expect, it } from "vitest";
import { sortTable, pasteTable, insertTable } from "../src/table-data";
it("sorts numeric data as whole rows, keeps the header and empty values last", () => {
  const d = {
    aligns: ["right", "left"],
    rows: [
      ["数量", "名称"],
      ["10", "a"],
      ["-2.5", "b"],
      ["", "c"],
      ["2", "d"],
      ["2", "e"],
    ],
  };
  expect(sortTable(d, 0, false).rows.map((r) => r[1])).toEqual([
    "名称",
    "b",
    "d",
    "e",
    "a",
    "c",
  ]);
  expect(sortTable(d, 0, true).rows.map((r) => r[1])).toEqual([
    "名称",
    "a",
    "d",
    "e",
    "b",
    "c",
  ]);
  expect(d.rows[1]).toEqual(["10", "a"]);
});
it("sorts text with natural number ordering", () => {
  const d = { aligns: ["left"], rows: [["标题"], ["item10"], ["item2"]] };
  expect(sortTable(d, 0, false).rows).toEqual([
    ["标题"],
    ["item2"],
    ["item10"],
  ]);
});
it("expands pasted rectangles while retaining surrounding cells and alignments", () => {
  const d = {
    aligns: ["center", "right"],
    rows: [
      ["A", "B"],
      ["keep", "old"],
    ],
  };
  const next = pasteTable(d, 1, 1, [
    ["中\n文", ""],
    ["a|b", "tail"],
  ]);
  expect(next.rows).toEqual([
    ["A", "B", ""],
    ["keep", "中\n文", ""],
    ["", "a|b", "tail"],
  ]);
  expect(next.aligns).toEqual(["center", "right", "left"]);
  expect(d.rows[1][1]).toBe("old");
});

it("inserts N rows or columns without changing existing cells or alignment", () => {
  const draft = {
    rows: [
      ["A", "B"],
      ["a", "b"],
    ],
    aligns: ["right", "center"],
  };
  const rows = insertTable(draft, "rows", 1, 3);
  expect(rows.rows).toEqual([
    ["A", "B"],
    ["", ""],
    ["", ""],
    ["", ""],
    ["a", "b"],
  ]);
  expect(rows.rows[1]).not.toBe(rows.rows[2]);
  const columns = insertTable(draft, "columns", 1, 2);
  expect(columns.rows).toEqual([
    ["A", "", "", "B"],
    ["a", "", "", "b"],
  ]);
  expect(columns.aligns).toEqual(["right", "left", "left", "center"]);
  expect(insertTable(draft, "columns", 0, 1).rows[0]).toEqual(["", "A", "B"]);
  expect(insertTable(draft, "rows", 2, 1).rows[2]).toEqual(["", ""]);
  expect(draft.rows).toEqual([
    ["A", "B"],
    ["a", "b"],
  ]);
  for (const count of [0, -1, 1.5, 1001, NaN])
    expect(() => insertTable(draft, "rows", 1, count)).toThrow();
});
