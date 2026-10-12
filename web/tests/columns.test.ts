// @vitest-environment jsdom
import { expect, it } from "vitest";
import { parseColumns, columnMarkup } from "../src/columns";
import { renderHTML } from "../src/editor";
it("preserves column source offsets and arbitrary positive ratios", () => {
  const content = ["# A\n\n**bold**\n", "```js\nconst x=1\n```\n", "tail\n"];
  const text =
    "before\n\n" + columnMarkup(content, [2.3, 1, 4.7]) + "\n\nafter";
  const [block] = parseColumns(text);
  expect(block.ratios).toEqual([2.3, 1, 4.7]);
  expect(block.columns.map((c) => text.slice(c.from, c.to))).toEqual(content);
  expect(text.slice(block.from, block.to)).toBe(block.original);
});
it("ignores tags inside fenced code and rejects unfinished blocks", () => {
  const example = columnMarkup(["A\n", "B\n"]);
  expect(parseColumns("```html\n" + example + "\n```")).toEqual([]);
  const [block] = parseColumns(columnMarkup(["```html\n</md>\n```\n", "B\n"]));
  expect(block.columns[0].text).toContain("</md>");
  expect(parseColumns(example.replace("</div>", ""))).toEqual([]);
});
it("renders child Markdown and sanitizes unsafe markup", () => {
  const html = renderHTML(
    columnMarkup(["# A\n\n**bold**\n", "<script>alert(1)</script>\n"]),
  );
  expect(html).toContain("<h1>A</h1>");
  expect(html).toContain("<strong>bold</strong>");
  expect(html).not.toContain("<md>");
  expect(html).not.toContain("<script>");
});

it("keeps empty and nested column content separate from container delimiters", () => {
  const nested = columnMarkup(["inner A", "inner B"]);
  const [block] = parseColumns(columnMarkup(["", nested, "tail"]));
  expect(block.columns.map((c) => c.text)).toEqual(["", nested, "tail"]);
  expect(
    parseColumns(block.columns[1].text)[0].columns.map((c) => c.text),
  ).toEqual(["inner A", "inner B"]);
});
