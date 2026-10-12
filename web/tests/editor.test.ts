// @vitest-environment jsdom
import { describe, it, expect, beforeAll, afterEach } from "vitest";
import { SourceBuffer, parseTable, tablePatches } from "../src/source";
import { MarkdownEditor } from "../src/editor";
import { columnMarkup } from "../src/columns";
import { EditorView } from "@codemirror/view";
import { forceParsing } from "@codemirror/language";
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

it("mounts valid child columns inside an unsupported legacy wrapper", async () => {
  const nested = columnMarkup(["# Left", "# Right"]);
  const raw =
    '<div class="columns">\n<md>\n' +
    nested +
    "\n</md>\n<md>\nlegacy\n</md>\n</div>";
  const { ed, disk } = create(raw);
  await Promise.resolve();
  expect(ed.view.dom.querySelectorAll(".column-pane")).toHaveLength(2);
  expect(disk()).toBe(raw);
});

// 即使表格尚未进入视口，也必须保留其块替换，避免滚动改变高度模型。
describe("table preview layout", () => {
  it("keeps offscreen table block decorations while inline styles stay viewport scoped", () => {
    const prefix = "Paragraph before the table.\n\n".repeat(350);
    const table = "| Head | Value |\n| --- | --- |\n| A | B |";
    const { ed } = create(prefix + table + "\n\nAfter");
    forceParsing(ed.view, ed.view.state.doc.length, 1000);
    const blocks: { from: number; to: number }[] = [];
    for (const decorations of ed.view.state.facet(EditorView.decorations)) {
      if (typeof decorations === "function") continue;
      decorations.between(0, ed.view.state.doc.length, (from, to, value) => {
        if (value.spec.block && value.spec.widget?.kind === "table")
          blocks.push({ from, to });
      });
    }
    expect(prefix.length).toBeGreaterThan(8000);
    expect(blocks).toEqual([
      { from: prefix.length, to: prefix.length + table.length },
    ]);
    expect(ed.view.state.doc.toString()).toBe(prefix + table + "\n\nAfter");
  });
});

describe.each([false, true])("move lines (source mode: %s)", (sourceMode) => {
  it("moves the current line with Alt+arrows and restores source and caret on undo", () => {
    const raw = "first\r\nsecond\r\nthird";
    const { ed, disk } = create(raw);
    if (sourceMode) ed.toggle();
    ed.view.dispatch({ selection: { anchor: 8 } });
    const up = new KeyboardEvent("keydown", {
      key: "ArrowUp",
      altKey: true,
      bubbles: true,
      cancelable: true,
    });
    ed.view.contentDOM.dispatchEvent(up);
    expect(up.defaultPrevented).toBe(true);
    expect(disk()).toBe("second\r\nfirst\r\nthird");
    expect(ed.view.state.selection.main.head).toBe(2);
    ed.undo();
    expect(disk()).toBe(raw);
    expect(ed.view.state.selection.main.head).toBe(8);
    const down = new KeyboardEvent("keydown", {
      key: "ArrowDown",
      altKey: true,
      bubbles: true,
      cancelable: true,
    });
    ed.view.contentDOM.dispatchEvent(down);
    expect(down.defaultPrevented).toBe(true);
    expect(disk()).toBe("first\r\nthird\r\nsecond");
    ed.undo();
    expect(disk()).toBe(raw);
  });

  it("moves selected lines together and consumes the shortcut at document boundaries", () => {
    const { ed, disk } = create("first\nsecond\nthird\nlast");
    if (sourceMode) ed.toggle();
    ed.view.dispatch({ selection: { anchor: 6, head: 19 } });
    const up = new KeyboardEvent("keydown", {
      key: "ArrowUp",
      altKey: true,
      bubbles: true,
      cancelable: true,
    });
    ed.view.contentDOM.dispatchEvent(up);
    expect(disk()).toBe("second\nthird\nfirst\nlast");
    const boundary = new KeyboardEvent("keydown", {
      key: "ArrowUp",
      altKey: true,
      bubbles: true,
      cancelable: true,
    });
    ed.view.contentDOM.dispatchEvent(boundary);
    expect(boundary.defaultPrevented).toBe(true);
    expect(disk()).toBe("second\nthird\nfirst\nlast");
    ed.undo();
    expect(disk()).toBe("first\nsecond\nthird\nlast");
  });
});

describe("embedded diff editor", () => {
  it("syncs edits, formatting, sorting and undo without recreating either editor", async () => {
    const { diffMarkup, parseDiffs } = await import("../src/diff");
    const raw =
      "# Before\n\n" + diffMarkup('{"z":1,"a":2}', '{"z":3}') + "\n\nAfter";
    const { ed, disk } = create(raw);
    await new Promise((resolve) => setTimeout(resolve, 20));
    const widget = ed.view.dom.querySelector(".md-diff")!;
    const left = EditorView.findFromDOM(
      widget.querySelector(".cm-merge-a") as HTMLElement,
    )!;
    const right = EditorView.findFromDOM(
      widget.querySelector(".cm-merge-b") as HTMLElement,
    )!;
    expect(left).toBeTruthy();
    expect(right).toBeTruthy();
    left.dispatch({
      changes: { from: 0, to: left.state.doc.length, insert: '{"b":2,"a":1}' },
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(parseDiffs(ed.view.state.doc.toString())[0].left).toBe(
      '{"b":2,"a":1}',
    );
    expect(ed.view.dom.querySelector(".md-diff")).toBe(widget);
    ed.undo();
    expect(disk()).toBe(raw);
    expect(left.state.doc.toString()).toBe('{"z":1,"a":2}');
    (
      widget.querySelector(
        '[aria-label="左侧JSON 键排序"]',
      ) as HTMLButtonElement
    ).click();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(parseDiffs(ed.view.state.doc.toString())[0].left).toBe(
      '{\n  "a": 2,\n  "z": 1\n}',
    );
    expect(right.state.doc.toString()).toBe('{"z":3}');
    ed.undo();
    expect(disk()).toBe(raw);
    right.dispatch({
      changes: { from: 0, to: right.state.doc.length, insert: "not json" },
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    (
      widget.querySelector(
        '[aria-label="右侧格式化 JSON"]',
      ) as HTMLButtonElement
    ).click();
    expect(right.state.doc.toString()).toBe("not json");
    expect(widget.querySelector('[role="status"]')!.textContent).not.toBe("");
    ed.undo();
    expect(disk()).toBe(raw);
    ed.toggle();
    expect(ed.view.dom.querySelector(".md-diff")).toBeNull();
    ed.toggle();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(ed.view.dom.querySelector(".md-diff")).toBeTruthy();
  });
});

it("edits a diff inside a column and restores it through document undo", async () => {
  const { diffMarkup, parseDiffs } = await import("../src/diff");
  const raw = columnMarkup([diffMarkup("left", "right"), "Other column"]);
  const { ed, disk } = create(raw);
  await new Promise((resolve) => setTimeout(resolve, 30));
  const element = ed.view.dom.querySelector(
    ".md-diff .cm-merge-a",
  ) as HTMLElement;
  const left = EditorView.findFromDOM(element)!;
  expect(left).toBeTruthy();
  left.dispatch({
    changes: { from: 0, to: left.state.doc.length, insert: "changed" },
  });
  await new Promise((resolve) => setTimeout(resolve, 20));
  expect(parseDiffs(ed.view.state.doc.toString())[0].left).toBe("changed");
  expect(disk()).toContain("Other column");
  ed.undo();
  await new Promise((resolve) => setTimeout(resolve, 20));
  expect(disk()).toBe(raw);
  expect(left.state.doc.toString()).toBe("left");
});

it("searches each diff side independently, including native-menu find routing", async () => {
  const { diffMarkup } = await import("../src/diff");
  const {
    searchPanelOpen,
    SearchQuery,
    setSearchQuery,
    findNext,
    closeSearchPanel,
  } = await import("@codemirror/search");
  const raw = diffMarkup("alpha one\nalpha two", "beta one\nbeta two");
  const { ed, disk } = create(raw);
  await new Promise((resolve) => setTimeout(resolve, 20));
  const widget = ed.view.dom.querySelector(".md-diff")!;
  const left = EditorView.findFromDOM(
    widget.querySelector(".cm-merge-a") as HTMLElement,
  )!;
  const right = EditorView.findFromDOM(
    widget.querySelector(".cm-merge-b") as HTMLElement,
  )!;
  left.focus();
  ed.find();
  expect(searchPanelOpen(left.state)).toBe(true);
  expect(searchPanelOpen(right.state)).toBe(false);
  expect(searchPanelOpen(ed.view.state)).toBe(false);
  left.dispatch({
    effects: setSearchQuery.of(new SearchQuery({ search: "alpha" })),
  });
  expect(findNext(left)).toBe(true);
  expect(
    left.state.sliceDoc(
      left.state.selection.main.from,
      left.state.selection.main.to,
    ),
  ).toBe("alpha");
  closeSearchPanel(left);
  (
    widget.querySelector('[aria-label="右侧查找"]') as HTMLButtonElement
  ).click();
  expect(searchPanelOpen(right.state)).toBe(true);
  expect(searchPanelOpen(left.state)).toBe(false);
  right.dispatch({
    effects: setSearchQuery.of(new SearchQuery({ search: "beta" })),
  });
  expect(findNext(right)).toBe(true);
  expect(
    right.state.sliceDoc(
      right.state.selection.main.from,
      right.state.selection.main.to,
    ),
  ).toBe("beta");
  expect(disk()).toBe(raw);
});
