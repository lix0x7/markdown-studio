import { expect, it } from "vitest";
import { sortTable, pasteTable } from "../src/table-data";
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
