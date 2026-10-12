// @vitest-environment jsdom
import { expect, it } from "vitest";
import { clipboardTable } from "../src/clipboard-table";
it("converts Excel TSV with quoted multiline cells and trailing empty columns", () => {
  expect(clipboardTable("", 'A\tB\r\n"one\ntwo"\t\r\n')).toBe(
    "| A | B |\n| --- | --- |\n| one<br>two |  |",
  );
});
it("prefers HTML and expands merged cells", () => {
  expect(
    clipboardTable(
      '<table><tr><th colspan="2">Title</th></tr><tr><td>A<br>B</td><td>C</td></tr></table>',
      "fallback",
    ),
  ).toBe("| Title |  |\n| --- | --- |\n| A<br>B | C |");
});
it("keeps ordinary and mixed article content unchanged", () => {
  expect(clipboardTable("", "normal\ntext")).toBeNull();
  expect(
    clipboardTable("<p>Keep this</p><table><tr><td>A</td></tr></table>", ""),
  ).toBeNull();
});
it("escapes cell markup and pipes", () => {
  expect(clipboardTable("", "A\tB\nx|y\t<script>")).toContain(
    "x\\|y | &lt;script&gt;",
  );
});
