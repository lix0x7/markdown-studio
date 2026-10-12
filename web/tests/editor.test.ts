// @vitest-environment jsdom
import { describe, it, expect, beforeAll, afterEach } from "vitest";
import { SourceBuffer, parseTable, tablePatches } from "../src/source";
import { MarkdownEditor } from "../src/editor";
import { columnMarkup } from "../src/columns";
import { isolateHistory } from "@codemirror/commands";
const editors: MarkdownEditor[] = [];
beforeAll(() => {
  globalThis.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  } as any;
  Range.prototype.getClientRects = () => [] as any;
  Range.prototype.getBoundingClientRect = () => ({
    x: 0,
    y: 0,
    width: 0,
    height: 0,
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    toJSON() {},
  });
});
afterEach(() => {
  editors.splice(0).forEach((e) => e.destroy());
  document.body.innerHTML = "";
});
function create(raw: string) {
  const div = document.createElement("div");
  document.body.append(div);
  let disk = raw;
  const ed = new MarkdownEditor(div, raw, {
    change: (patches) => {
      for (const p of [...patches].sort((a, b) => b.from - a.from))
        disk = disk.slice(0, p.from) + p.insert + disk.slice(p.to);
    },
    outline: () => {},
    command: () => {},
    table: () => {},
    image: () => {},
  });
  editors.push(ed);
  return { ed, disk: () => disk };
}
describe("source fidelity", () => {
  it("preserves mixed endings, trailing spaces and Unicode outside edits", () => {
    const b = new SourceBuffer("head  \r\n中😀old\nlast\r");
    const at = b.normalized().indexOf("old");
    b.apply([{ from: at, to: at + 3, insert: "new" }]);
    expect(b.raw).toBe("head  \r\n中😀new\nlast\r");
  });
  it("uses document newline style only for inserted lines", () => {
    const b = new SourceBuffer("a\r\nb\nc");
    b.apply([{ from: 3, to: 3, insert: "\nnew" }]);
    expect(b.raw).toBe("a\r\nb\r\nnew\nc");
  });
  it("formats and undoes with exact original bytes", () => {
    const { ed, disk } = create("# Title\r\n\nplain 😀 text  \r");
    const from = ed.view.state.doc.toString().indexOf("plain");
    ed.view.dispatch({ selection: { anchor: from, head: from + 5 } });
    ed.wrap("**");
    expect(disk()).toBe("# Title\r\n\n**plain** 😀 text  \r");
    ed.undo();
    expect(disk()).toBe("# Title\r\n\nplain 😀 text  \r");
    ed.redo();
    expect(disk()).toContain("**plain**");
  });
  it("restores mixed newline metadata after multi-line deletion undo", () => {
    const raw = "a\r\nb\nc\rd\r\ne";
    const { ed, disk } = create(raw);
    ed.view.dispatch({
      changes: { from: 1, to: 7, insert: "X" },
      annotations: isolateHistory.of("full"),
      userEvent: "input",
    });
    ed.undo();
    expect(disk()).toBe(raw);
    ed.redo();
    expect(disk()).toBe("aX\r\ne");
  });
  it("does not alter source when switching preview modes", () => {
    const raw = "# t\r\n\n**bold**\r\n";
    const { ed, disk } = create(raw);
    ed.toggle();
    ed.toggle();
    expect(disk()).toBe(raw);
  });
  it("supports grouped typing and grouped undo", () => {
    const { ed, disk } = create("a\r\nb\nc");
    ed.view.dispatch({
      changes: { from: 1, insert: "x" },
      userEvent: "input.type",
    });
    ed.view.dispatch({
      changes: { from: 2, insert: "y" },
      userEvent: "input.type",
    });
    ed.undo();
    expect(disk()).toBe("a\r\nb\nc");
  });
});
describe("table range edits", () => {
  it("changes one cell without rewriting surrounding spacing", () => {
    const text = "| a  | b |\n| :--- | ---: |\n| old   | value |";
    const table = parseTable(text, 8)!;
    const patches = tablePatches(
      table,
      [
        ["a", "b"],
        ["new", "value"],
      ],
      table.aligns,
    );
    expect(patches).toEqual([
      {
        from: 8 + text.indexOf("old"),
        to: 8 + text.indexOf("old") + 3,
        insert: "new",
      },
    ]);
  });
  it("changes only the targeted alignment marker", () => {
    const t = parseTable("| a | b |\n| :--- | ---: |\n| c | d |")!;
    const p = tablePatches(
      t,
      t.rows.map((r) => r.map((c) => c.value)),
      ["left", "center"],
    );
    expect(p).toHaveLength(1);
    expect(p[0].insert).toBe(":---:");
  });
  it("parses escaped pipes and code cells", () => {
    const t = parseTable("| a | b |\n| --- | --- |\n| a\\|b | `x|y` |")!;
    expect(t.rows[1].map((c) => c.value)).toEqual(["a\\|b", "`x|y`"]);
  });
  it("limits structural modifications to current table", () => {
    const t = parseTable("| a | b |\n| --- | --- |\n| c | d |", 20)!;
    const p = tablePatches(
      t,
      [
        ["a", "b"],
        ["c", "d"],
        ["e", "f"],
      ],
      t.aligns,
    );
    expect(p.every((c) => c.from >= 20 && c.to <= t.to)).toBe(true);
  });
});

describe("additional editor invariants", () => {
  it("restores grouped newlines without normalizing old lines", () => {
    const raw = "a\r\nb\nc\rd";
    const { ed, disk } = create(raw);
    ed.view.dispatch({
      changes: { from: 1, insert: "\n" },
      userEvent: "input.type",
    });
    ed.view.dispatch({
      changes: { from: 2, insert: "\n" },
      userEvent: "input.type",
    });
    ed.undo();
    expect(disk()).toBe(raw);
    ed.redo();
    expect(disk()).toBe("a\r\n\r\n\r\nb\nc\rd");
  });
  it("preserves front matter and unsupported syntax in rendering", () => {
    const raw =
      '---\r\ntitle: keep  \r\n---\n\n$unknown$\n<div data-x="x">keep</div>';
    const { ed, disk } = create(raw);
    ed.toggle();
    ed.toggle();
    expect(disk()).toBe(raw);
  });
  it("updates nested list formatting without rewriting neighbors", () => {
    const raw = "start  \r\n  - nested\r\nlast";
    const { ed, disk } = create(raw);
    const from = ed.view.state.doc.toString().indexOf("nested");
    ed.view.dispatch({ selection: { anchor: from, head: from + 6 } });
    ed.wrap("**");
    expect(disk()).toBe("start  \r\n  - **nested**\r\nlast");
  });
});

describe("unordered list presentation", () => {
  it("renders bullet markers while preserving nested source and ordered lists", () => {
    const raw =
      "- first\r\n  - nested\r\n+ second\r\n* third\r\n\r\n1. ordered\r\n\r\n```text\r\n- code\r\n```";
    const { ed, disk } = create(raw);
    expect(
      [...ed.view.dom.querySelectorAll(".md-bullet-mark")].map(
        (el) => el.textContent,
      ),
    ).toEqual(["-", "-", "+", "*"]);
    expect(disk()).toBe(raw);
    ed.toggle();
    expect(ed.view.dom.querySelector(".md-bullet-mark")).toBeNull();
    expect(disk()).toBe(raw);
    ed.toggle();
    expect(ed.view.dom.querySelectorAll(".md-bullet-mark")).toHaveLength(4);
  });
});

// jsdom 不做布局，固定落点；保留真实 DOM 事件、编辑事务、原文同步和撤销链路。
function moveImage(source: HTMLElement, target: MarkdownEditor, at: number) {
  const data = {
    clearData() {},
    setData() {},
    effectAllowed: "",
    dropEffect: "",
  };
  const start = new Event("dragstart", { bubbles: true, cancelable: true });
  Object.defineProperty(start, "dataTransfer", { value: data });
  source.dispatchEvent(start);
  expect(data.effectAllowed).toBe("move");
  target.view.posAtCoords = () => at;
  const drop = new Event("drop", { bubbles: true, cancelable: true });
  Object.defineProperty(drop, "dataTransfer", { value: data });
  target.view.contentDOM.dispatchEvent(drop);
  expect(drop.defaultPrevented).toBe(true);
}

it("moves image source in both directions without copying and undoes in one step", () => {
  for (const image of [
    "![alt](fixture.png)",
    '<figure><img src="data:image/png;base64,AAAA" width="128" height="64" align="right"><figcaption>说明</figcaption></figure>',
  ]) {
    const raw = "# Start\n\nBefore\n\n" + image + "\n\nAfter";
    const { ed, disk } = create(raw);
    for (const at of [raw.length, 0]) {
      moveImage(ed.view.dom.querySelector(".md-image img")!, ed, at);
      const moved = ed.view.state.doc.toString();
      expect(moved.split(image)).toHaveLength(2);
      expect(
        at === 0
          ? moved.startsWith("\n\n" + image)
          : moved.endsWith(image + "\n\n"),
      ).toBe(true);
      expect(disk()).toBe(moved);
      ed.undo();
      expect(disk()).toBe(raw);
      ed.redo();
      expect(disk()).toBe(moved);
      ed.undo();
    }
    moveImage(
      ed.view.dom.querySelector(".md-image img")!,
      ed,
      raw.indexOf(image),
    );
    expect(disk()).toBe(raw);
  }
});

it("moves an image between columns with a single document undo", async () => {
  const image = "![alt](fixture.png)";
  const raw =
    "# Start\n\n" + columnMarkup(["# Left\n\n" + image, "# Right\n\nTarget"]);
  const { ed, disk } = create(raw);
  await Promise.resolve();
  const panes = ed.view.dom.querySelectorAll<HTMLElement>(
    ".column-pane .cm-content",
  );
  panes[1].focus();
  const right = ed.active();
  expect(right).not.toBe(ed);
  moveImage(
    ed.view.dom.querySelector(".md-image img")!,
    right,
    right.view.state.doc.length,
  );
  const moved = ed.view.state.doc.toString();
  expect(moved.split(image)).toHaveLength(2);
  expect(moved.indexOf(image)).toBeGreaterThan(moved.indexOf("Target"));
  ed.undo();
  expect(disk()).toBe(raw);
});

it("restores long base64 image previews after leaving reference editing", () => {
  const image =
    "![image.png](<data:image/png;base64," + "A".repeat(150000) + ">)";
  const raw = "# Before\n\n" + image + "\n\nAfter\n";
  const { ed } = create(raw);
  ed.view.dispatch({ selection: { anchor: raw.indexOf(image) + 2 } });
  expect(ed.view.dom.querySelector(".md-image")).toBeNull();
  ed.view.dispatch({ selection: { anchor: raw.indexOf("After") } });
  expect(ed.view.dom.querySelector(".md-image")).not.toBeNull();
  expect(ed.buffer.raw).toBe(raw);
});

it("restores an image preview when reference editing loses focus", async () => {
  const raw =
    "# Before\n\n![image](<data:image/png;base64," +
    "A".repeat(150000) +
    ">)\n\nAfter";
  const { ed } = create(raw);
  ed.view.focus();
  ed.view.dispatch({ selection: { anchor: raw.indexOf("![image]") + 2 } });
  expect(ed.view.dom.querySelector(".md-image")).toBeNull();
  await new Promise((resolve) => setTimeout(resolve, 30));
  const outside = document.createElement("button");
  document.body.append(outside);
  outside.focus();
  await new Promise((resolve) => setTimeout(resolve, 30));
  expect(ed.view.dom.querySelector(".md-image")).not.toBeNull();
  expect(ed.buffer.raw).toBe(raw);
});
