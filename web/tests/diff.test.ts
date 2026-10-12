import { describe, it, expect } from "vitest";
import {
  diffMarkup,
  parseDiffs,
  formatDiffJSON,
  renderDiffHTML,
} from "../src/diff";

describe("diff source", () => {
  it("roundtrips arbitrary code and locates multiple blocks", () => {
    const left = "```js\n<script>alert(1)</script>\n```\n😀\n",
      right = '{"text":"</md>"}';
    const markup = diffMarkup(left, right);
    const blocks = parseDiffs(
      "before\n" + markup + "\n\n" + diffMarkup("", "new"),
    );
    expect(blocks).toHaveLength(2);
    expect(blocks[0]).toMatchObject({
      from: 7,
      to: 7 + markup.length,
      left,
      right,
      original: markup,
    });
    expect(blocks[1].left).toBe("");
  });
  it("ignores examples inside other fences and malformed data", () => {
    expect(parseDiffs("````text\n" + diffMarkup("a", "b") + "\n````")).toEqual(
      [],
    );
    expect(parseDiffs('```md-diff\n{"left":1,"right":"b"}\n```')).toEqual([]);
    expect(parseDiffs("```md-diff\n{\n```")).toEqual([]);
  });
  it("sorts nested object keys without reordering arrays or losing special keys", () => {
    const source =
      '{"z":[{"b":1,"a":2},3,1],"__proto__":{"z":0,"a":1},"a":null}';
    const sorted = formatDiffJSON(source, true);
    expect(sorted.indexOf('"a": null')).toBeLessThan(sorted.indexOf('"z": ['));
    expect(JSON.parse(sorted)).toEqual(JSON.parse(source));
    expect(sorted).toContain('"a": 2,\n      "b": 1');
    expect(() => formatDiffJSON("{bad}", true)).toThrow();
  });
  it("exports escaped code and highlighted changes", () => {
    const html = renderDiffHTML(
      parseDiffs(diffMarkup("<script>old</script>", "<script>new</script>"))[0],
    );
    expect(html).not.toContain("<script>");
    expect(html).toContain("&lt;script&gt;");
    expect(html).toContain("<mark");
    expect(html).toContain("old");
    expect(html).toContain("new");
  });
});

it("preserves long integer tokens while formatting and sorting JSON", () => {
  const source = '{"z":900719925474099312345,"a":[1e30,12345678901234567890]}';
  for (const sort of [false, true]) {
    const result = formatDiffJSON(source, sort);
    expect(result).toContain("900719925474099312345");
    expect(result).toContain("12345678901234567890");
    expect(result).toContain("1e30");
  }
});
