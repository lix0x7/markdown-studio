import { parseDiffs, renderDiffHTML } from "./diff";
import { DiffWidget } from "./diff-widget";
import {
  EditorState,
  Transaction,
  StateField,
  StateEffect,
  Compartment,
  type Extension,
  type Range,
} from "@codemirror/state";
import {
  EditorView,
  Decoration,
  WidgetType,
  ViewPlugin,
  keymap,
  dropCursor,
  type DecorationSet,
} from "@codemirror/view";
import {
  history,
  historyKeymap,
  defaultKeymap,
  moveLineUp,
  moveLineDown,
  indentWithTab,
  undo,
  redo,
  invertedEffects,
  isolateHistory,
} from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { javascript } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { python } from "@codemirror/lang-python";
import { StreamLanguage } from "@codemirror/language";
import { swift } from "@codemirror/legacy-modes/mode/swift";
import { go } from "@codemirror/legacy-modes/mode/go";
import {
  syntaxTree,
  syntaxHighlighting,
  defaultHighlightStyle,
  bracketMatching,
} from "@codemirror/language";
import {
  search,
  searchKeymap,
  highlightSelectionMatches,
  openSearchPanel,
} from "@codemirror/search";
import { marked } from "marked";
import DOMPurify from "dompurify";
import {
  SourceBuffer,
  minimalPatch,
  parseTable,
  type Patch,
  type TableModel,
} from "./source";
import { request } from "./bridge";
import { parseColumns, columnMarkup, type ColumnBlock } from "./columns";
import { clipboardTable } from "./clipboard-table";

export const mode = new Compartment();
const previewFocus = StateEffect.define<boolean>();
const viewport = StateEffect.define<{ from: number; to: number }>();
export const renderHTML = (text: string): string => {
  const blocks = parseColumns(text);
  if (blocks.length) {
    let at = 0,
      html = "";
    for (const block of blocks) {
      html += renderHTML(text.slice(at, block.from));
      html +=
        `<div class="columns-render" style="display:grid;gap:24px;grid-template-columns:${block.ratios.map((n) => `minmax(0,${n}fr)`).join(" ")}">` +
        block.columns
          .map((c) => `<section>${renderHTML(c.text)}</section>`)
          .join("") +
        "</div>";
      at = block.to;
    }
    return html + renderHTML(text.slice(at));
  }
  const diffs = parseDiffs(text);
  if (diffs.length) {
    let at = 0,
      html = "";
    for (const block of diffs) {
      html += renderHTML(text.slice(at, block.from)) + renderDiffHTML(block);
      at = block.to;
    }
    return html + renderHTML(text.slice(at));
  }
  return DOMPurify.sanitize(
    marked.parse(text, { async: false, gfm: true }) as string,
    { FORBID_TAGS: ["style", "script", "iframe"], FORBID_ATTR: ["style"] },
  );
};
const editorInstances = new WeakMap<EditorView, MarkdownEditor>();
let draggedImage:
  | {
      editor: MarkdownEditor;
      doc: EditorState["doc"];
      from: number;
      to: number;
      text: string;
    }
  | undefined;
type ColumnUI = {
  block: ColumnBlock;
  children: MarkdownEditor[];
  syncing: boolean;
  disposed: boolean;
  observer: ResizeObserver;
  refresh: () => void;
};
const columnUIs = new WeakMap<HTMLElement, ColumnUI>();
class ColumnsWidget extends WidgetType {
  constructor(readonly block: ColumnBlock) {
    super();
  }
  eq(other: ColumnsWidget) {
    return (
      this.block.from === other.block.from &&
      this.block.original === other.block.original
    );
  }
  toDOM(view: EditorView) {
    const el = document.createElement("div");
    el.className = "md-columns";
    const grid = document.createElement("div");
    grid.className = "columns-grid";
    const toolbar = document.createElement("div");
    toolbar.className = "columns-toolbar";
    el.append(toolbar, grid);
    const observer = new ResizeObserver(() => view.requestMeasure());
    observer.observe(el);
    const ui: ColumnUI = {
      block: this.block,
      children: [],
      syncing: false,
      disposed: false,
      observer,
      refresh: () => {},
    };
    columnUIs.set(el, ui);
    const replace = (text: string) =>
      view.dispatch({
        changes: { from: ui.block.from, to: ui.block.to, insert: text },
        annotations: isolateHistory.of("full"),
        userEvent: "input.columns",
      });
    const add = document.createElement("button");
    add.textContent = "添加分栏";
    add.onclick = () =>
      replace(
        columnMarkup(
          [...ui.block.columns.map((c) => c.text), "\n"],
          [...ui.block.ratios, 1],
        ),
      );
    const flatten = document.createElement("button");
    flatten.textContent = "取消分栏";
    flatten.onclick = () =>
      replace(ui.block.columns.map((c) => c.text).join("\n"));
    toolbar.append(add, flatten);
    const separators: HTMLButtonElement[] = [];
    ui.refresh = () => {
      grid.style.gridTemplateColumns = ui.block.ratios
        .map((r) => `minmax(0, ${r}fr)`)
        .join(" 10px ");
      separators.forEach((button, i) =>
        button.setAttribute(
          "aria-valuenow",
          String(
            Math.round(
              (ui.block.ratios[i] /
                (ui.block.ratios[i] + ui.block.ratios[i + 1])) *
                100,
            ),
          ),
        ),
      );
    };
    this.block.columns.forEach((_, i) => {
      if (i) {
        const divider = document.createElement("button");
        divider.className = "column-divider";
        divider.setAttribute("role", "separator");
        divider.setAttribute("aria-label", `调整第 ${i}、${i + 1} 栏比例`);
        divider.setAttribute("aria-orientation", "vertical");
        divider.setAttribute("aria-valuemin", "1");
        divider.setAttribute("aria-valuemax", "99");
        let drag: {
          x: number;
          left: number;
          right: number;
          pixels: number;
        } | null = null;
        // 同步标准 HTML 布局与编辑器比例。
        const commit = (ratios: number[]) =>
          replace(
            columnMarkup(
              ui.block.columns.map((c) => c.text),
              ratios,
            ),
          );
        divider.onpointerdown = (e) => {
          if (e.button !== 0) return;
          e.preventDefault();
          const panes = grid.querySelectorAll<HTMLElement>(
            ":scope > .column-pane",
          );
          drag = {
            x: e.clientX,
            left: ui.block.ratios[i - 1],
            right: ui.block.ratios[i],
            pixels: panes[i - 1].clientWidth + panes[i].clientWidth,
          };
          divider.setPointerCapture(e.pointerId);
        };
        let ratios: number[] = [];
        divider.onpointermove = (e) => {
          if (!drag) return;
          const total = drag.left + drag.right;
          const left = Math.max(
            total * 0.01,
            Math.min(
              total * 0.99,
              drag.left + ((e.clientX - drag.x) / drag.pixels) * total,
            ),
          );
          ratios = [...ui.block.ratios];
          ratios[i - 1] = Number(left.toFixed(6));
          ratios[i] = Number((total - left).toFixed(6));
          grid.style.gridTemplateColumns = ratios
            .map((r) => `minmax(0, ${r}fr)`)
            .join(" 10px ");
        };
        divider.onpointerup = (e) => {
          if (!drag) return;
          drag = null;
          divider.releasePointerCapture(e.pointerId);
          if (ratios.length) commit(ratios);
          ratios = [];
        };
        divider.onpointercancel = () => {
          drag = null;
          ratios = [];
          ui.refresh();
        };
        divider.onkeydown = (e) => {
          if (!["ArrowLeft", "ArrowRight"].includes(e.key)) return;
          e.preventDefault();
          const values = [...ui.block.ratios],
            total = values[i - 1] + values[i];
          values[i - 1] = Math.max(
            total * 0.01,
            Math.min(
              total * 0.99,
              values[i - 1] + (e.key === "ArrowRight" ? 1 : -1) * total * 0.02,
            ),
          );
          values[i] = total - values[i - 1];
          commit(values);
        };
        separators.push(divider);
        grid.append(divider);
      }
      const pane = document.createElement("div");
      pane.className = "column-pane editor-host";
      grid.append(pane);
    });
    ui.refresh();
    // 子编辑器挂载后复用稳定实例，输入只映射内容区间，不重建 DOM 或打断输入法。
    queueMicrotask(() => {
      if (ui.disposed) return;
      const owner = editorInstances.get(view)!;
      const panes = grid.querySelectorAll<HTMLElement>(":scope > .column-pane");
      ui.block.columns.forEach((column, i) => {
        const child = new MarkdownEditor(panes[i], column.text, {
          ...owner.callbacks,
          outline: () => {},
          change: () => {
            if (ui.syncing) return;
            queueMicrotask(() => {
              if (ui.disposed) return;
              const model = ui.block.columns[i];
              const text = child.view.state.doc.toString();
              const patch = minimalPatch(model.text, text, model.from);
              if (patch)
                view.dispatch({
                  changes: patch,
                  annotations: isolateHistory.of("full"),
                  userEvent: "input.columns",
                });
            });
          },
        });
        child.parentEditor = owner;
        child.removeEmptyColumn = () => {
          // 等当前键盘事件结束后替换结构，保留其他栏原文和比例，并定位到相邻栏。
          queueMicrotask(() => {
            if (ui.disposed) return;
            const contents = ui.children.map((c) =>
              c.view.state.doc.toString(),
            );
            if (contents[i].trim()) return;
            contents.splice(i, 1);
            const ratios = ui.block.ratios.filter((_, index) => index !== i);
            const text =
              contents.length === 1
                ? contents[0]
                : columnMarkup(contents, ratios);
            const from = ui.block.from;
            owner.anchorHistory(from);
            replace(text);
            const target =
              contents.length === 1
                ? from
                : from + parseColumns(text)[0].columns[Math.max(0, i - 1)].from;
            owner.jump(target);
          });
        };
        panes[i].addEventListener("focusin", () => {
          owner.activeChild = child;
        });
        ui.children.push(child);
      });
      view.requestMeasure();
    });
    return el;
  }
  updateDOM(el: HTMLElement) {
    const ui = columnUIs.get(el)!;
    if (ui.block.columns.length !== this.block.columns.length) return false;
    ui.block = this.block;
    ui.refresh();
    ui.syncing = true;
    ui.children.forEach((child, i) => {
      const patch = minimalPatch(
        child.view.state.doc.toString(),
        this.block.columns[i].text,
      );
      if (patch)
        child.view.dispatch({
          changes: patch,
          annotations: Transaction.addToHistory.of(false),
        });
    });
    ui.syncing = false;
    return true;
  }
  destroy(el: HTMLElement) {
    const ui = columnUIs.get(el);
    if (!ui) return;
    ui.disposed = true;
    ui.observer.disconnect();
    ui.children.forEach((c) => c.destroy());
  }
  ignoreEvent() {
    return true;
  }
}
class BlockWidget extends WidgetType {
  private tableObservers = new WeakMap<HTMLElement, ResizeObserver>();
  constructor(
    readonly text: string,
    readonly kind: string,
    readonly from: number,
  ) {
    super();
  }
  eq(other: BlockWidget) {
    return (
      other.text === this.text &&
      other.kind === this.kind &&
      other.from === this.from
    );
  }
  toDOM(view: EditorView) {
    const el = document.createElement("div");
    el.className = "md-widget md-" + this.kind;
    el.innerHTML = renderHTML(this.text);
    if (this.kind === "table") {
      // 横向滚动限定在表格内部，编辑按钮保持在可见容器右侧。
      const scroll = document.createElement("div");
      scroll.className = "table-scroll";
      scroll.tabIndex = 0;
      scroll.setAttribute("role", "region");
      scroll.setAttribute("aria-label", "表格，可左右滚动");
      scroll.append(...Array.from(el.childNodes));
      el.append(scroll);
      // 按内容自然宽度判断是否需要突破正文栏，避免小表格被拉满屏幕。
      const table = scroll.querySelector("table")!;
      const observer = new ResizeObserver(() => {
        const content = view.contentDOM;
        const style = getComputedStyle(content);
        const available =
          content.clientWidth -
          parseFloat(style.paddingLeft) -
          parseFloat(style.paddingRight);
        table.style.minWidth = "0";
        const naturalWidth = table.getBoundingClientRect().width;
        table.style.minWidth = "";
        const wide = naturalWidth > available + 1;
        if (el.classList.contains("md-table-wide") !== wide) {
          el.classList.toggle("md-table-wide", wide);
          view.requestMeasure();
        }
      });
      observer.observe(view.contentDOM);
      observer.observe(table);
      this.tableObservers.set(el, observer);
      const button = document.createElement("button");
      button.className = "table-edit";
      button.textContent = "编辑表格";
      button.setAttribute("aria-label", "编辑此表格");
      el.prepend(button);
      button.onclick = () =>
        view.dom.dispatchEvent(
          new CustomEvent("edit-table", {
            bubbles: true,
            detail: parseTable(this.text, this.from),
          }),
        );
      el.querySelector("table")?.addEventListener("dblclick", () =>
        button.click(),
      );
    }
    el.querySelectorAll("img").forEach((img) => {
      const path = img.getAttribute("src") ?? "";
      img.removeAttribute("src");
      img.alt = img.alt || "图片";
      request<string>("imageURL", { path })
        .then((url) => {
          img.onload = () => view.requestMeasure();
          img.src = url;
        })
        .catch(() => {
          el.classList.add("image-error");
          img.alt = "图片不可用：" + path;
        });
    });
    if (this.kind === "image") {
      const img = el.querySelector("img")!;
      img.draggable = true;
      img.addEventListener("dragstart", (event) => {
        if (!event.dataTransfer) return;
        const origin = editorInstances.get(view)!.documentPosition(this.from);
        draggedImage = {
          ...origin,
          doc: origin.editor.view.state.doc,
          to: origin.from + this.text.length,
          text: this.text,
        };
        event.dataTransfer.clearData();
        event.dataTransfer.setData("text/plain", this.text);
        event.dataTransfer.setData(
          "application/x-markdown-studio-image",
          "move",
        );
        event.dataTransfer.effectAllowed = "move";
        event.stopPropagation();
      });
      img.addEventListener("dragend", () => {
        draggedImage = undefined;
      });
      const original = document.createElement("div");
      original.innerHTML = renderHTML(this.text);
      const source = original.querySelector("img")!;
      let figure = original.querySelector("figure");
      const toolbar = document.createElement("div");
      toolbar.className = "image-toolbar";
      toolbar.setAttribute("role", "toolbar");
      toolbar.setAttribute("aria-label", "图片布局");
      // 只在操作完成后写回一次事务；标准 HTML 属性保留图片引用、对齐和尺寸。
      const commit = () => {
        const caption = figure?.querySelector("figcaption");
        if (caption)
          caption.setAttribute("align", source.getAttribute("align") ?? "left");
        view.dispatch({
          changes: {
            from: this.from,
            to: this.from + this.text.length,
            insert: figure?.outerHTML ?? source.outerHTML,
          },
          annotations: isolateHistory.of("full"),
          userEvent: "input.image",
        });
        view.requestMeasure();
      };
      for (const [align, label] of [
        ["left", "左对齐"],
        ["center", "居中"],
        ["right", "右对齐"],
      ]) {
        const button = document.createElement("button");
        button.textContent = label;
        button.title = label;
        button.setAttribute("aria-label", "图片" + label);
        button.onclick = () => {
          source.setAttribute("align", align);
          commit();
        };
        toolbar.append(button);
      }
      const edit = document.createElement("button");
      edit.textContent = "编辑引用";
      edit.onclick = () => {
        view.dispatch({ selection: { anchor: this.from + 1 } });
        view.focus();
      };
      toolbar.append(edit);
      const captionEditor = document.createElement("form");
      captionEditor.className = "image-caption-editor";
      captionEditor.hidden = true;
      const captionInput = document.createElement("input");
      captionInput.setAttribute("aria-label", "图片说明内容");
      captionInput.placeholder = "输入图片说明，留空可移除";
      captionInput.value =
        figure?.querySelector("figcaption")?.textContent ?? "";
      const saveCaption = document.createElement("button");
      saveCaption.type = "submit";
      saveCaption.textContent = "确定";
      const cancelCaption = document.createElement("button");
      cancelCaption.type = "button";
      cancelCaption.textContent = "取消";
      cancelCaption.onclick = () => {
        captionEditor.hidden = true;
        view.requestMeasure();
      };
      captionEditor.append(captionInput, saveCaption, cancelCaption);
      captionEditor.onsubmit = (event) => {
        event.preventDefault();
        const text = captionInput.value.trim();
        if (text) {
          if (!figure) {
            figure = document.createElement("figure");
            figure.append(source);
          }
          let caption = figure.querySelector("figcaption");
          if (!caption) {
            caption = document.createElement("figcaption");
            figure.append(caption);
          }
          caption.textContent = text;
        } else {
          figure = null;
        }
        commit();
      };
      captionEditor.onkeydown = (event) => {
        event.stopPropagation();
        if (event.key === "Escape") {
          event.preventDefault();
          captionEditor.hidden = true;
          view.requestMeasure();
        }
      };
      const captionButton = document.createElement("button");
      captionButton.textContent = "图片说明";
      captionButton.setAttribute("aria-label", "设置图片说明");
      captionButton.onclick = () => {
        captionInput.value =
          figure?.querySelector("figcaption")?.textContent ?? "";
        captionEditor.hidden = false;
        captionInput.focus();
        view.requestMeasure();
      };
      const remove = document.createElement("button");
      remove.textContent = "删除";
      remove.setAttribute("aria-label", "删除图片");
      remove.onclick = () => {
        view.dispatch({
          changes: {
            from: this.from,
            to: this.from + this.text.length,
            insert: "",
          },
          selection: { anchor: this.from },
          annotations: isolateHistory.of("full"),
          userEvent: "delete.image",
        });
        view.focus();
      };
      toolbar.append(captionButton, remove);
      el.append(toolbar, captionEditor);
      const handle = document.createElement("button");
      handle.className = "image-resize";
      handle.setAttribute("aria-label", "锁定比例调整图片大小");
      handle.title = "拖动缩放（锁定比例）";
      handle.textContent = "↘";
      const frame = document.createElement("div");
      frame.className = "image-frame";
      frame.dataset.align = source.getAttribute("align") ?? "left";
      img.replaceWith(frame);
      frame.append(img, handle);
      let start: { x: number; y: number; width: number; ratio: number } | null =
        null;
      handle.onpointerdown = (e) => {
        e.preventDefault();
        const rect = img.getBoundingClientRect();
        start = {
          x: e.clientX,
          y: e.clientY,
          width: rect.width,
          ratio: rect.width / rect.height,
        };
        handle.setPointerCapture(e.pointerId);
      };
      handle.onpointermove = (e) => {
        if (!start) return;
        const delta =
          Math.abs(e.clientX - start.x) >= Math.abs(e.clientY - start.y)
            ? e.clientX - start.x
            : (e.clientY - start.y) * start.ratio;
        const width = Math.round(
          Math.max(32, Math.min(el.clientWidth, start.width + delta)),
        );
        img.style.width = width + "px";
        img.style.height = "auto";
        view.requestMeasure();
      };
      handle.onpointerup = (e) => {
        if (!start) return;
        source.setAttribute(
          "width",
          String(Math.round(img.getBoundingClientRect().width)),
        );
        source.setAttribute(
          "height",
          String(Math.round(img.getBoundingClientRect().width / start.ratio)),
        );
        start = null;
        handle.releasePointerCapture(e.pointerId);
        commit();
      };
      handle.onpointercancel = () => {
        start = null;
        img.style.width = "";
        view.requestMeasure();
      };
    }
    return el;
  }
  destroy(dom: HTMLElement) {
    this.tableObservers.get(dom)?.disconnect();
  }
  ignoreEvent() {
    return true;
  }
}
// 行内样式限制在视口附近；影响文档高度的表格替换不随滚动增删。
function buildDecorations(
  state: EditorState,
  range: { from: number; to: number },
  focused = true,
): DecorationSet {
  const out: Range<Decoration>[] = [];
  const source = state.doc.toString();
  const columns = parseColumns(source);
  const diffs = parseDiffs(source).filter(
    (block) =>
      !columns.some(
        (column) => block.from >= column.from && block.to <= column.to,
      ),
  );
  for (const block of diffs)
    out.push(
      Decoration.replace({
        widget: new DiffWidget(block, (view) => {
          const owner = editorInstances.get(view)!;
          return {
            anchor: (at) => owner.anchorHistory(at),
            undo: () => owner.undo(),
            redo: () => owner.redo(),
          };
        }),
        block: true,
      }).range(block.from, block.to),
    );
  for (const block of columns)
    if (block.to >= range.from && block.from <= range.to)
      out.push(
        Decoration.replace({
          widget: new ColumnsWidget(block),
          block: true,
        }).range(block.from, block.to),
      );
  const seen = new Set<string>();
  const active = state.selection.main;
  const first = state.doc.lineAt(active.from).from,
    last = state.doc.lineAt(active.to).to;
  const editing = (from: number, to: number) => from <= last && to >= first;
  const line = (at: number, cls: string) => {
    const p = state.doc.lineAt(at).from,
      key = p + cls;
    if (!seen.has(key)) {
      seen.add(key);
      out.push(Decoration.line({ class: cls }).range(p));
    }
  };
  const mark = (from: number, to: number, cls: string) => {
    if (to > from) out.push(Decoration.mark({ class: cls }).range(from, to));
  };
  const hide = (from: number, to: number) => {
    if (to > from) out.push(Decoration.replace({}).range(from, to));
  };
  // 表格预览与源码高度不同，若随视口移除替换，会让高度估算和滚动位置反复修正。
  syntaxTree(state).iterate({
    enter(n) {
      if (columns.some((block) => n.from >= block.from && n.to <= block.to))
        return false;
      if (n.name === "Table" && !editing(n.from, n.to))
        out.push(
          Decoration.replace({
            widget: new BlockWidget(
              state.sliceDoc(n.from, n.to),
              "table",
              n.from,
            ),
            block: true,
          }).range(n.from, n.to),
        );
      // 只进入可能包含表格的块级容器，避免遍历整篇文档的行内节点。
      return [
        "Document",
        "Blockquote",
        "BulletList",
        "OrderedList",
        "ListItem",
      ].includes(n.name);
    },
  });
  syntaxTree(state).iterate({
    from: range.from,
    to: Math.min(range.to, state.doc.length),
    enter(n) {
      const name = n.name,
        from = n.from;
      if (
        name !== "Document" &&
        diffs.some((block) => n.from >= block.from && n.to <= block.to)
      )
        return false;
      let to = n.to;
      if (columns.some((block) => from >= block.from && n.to <= block.to))
        return false;
      if (name === "Table") {
        if (!editing(from, to)) return false;
        for (
          let i = state.doc.lineAt(Math.max(from, range.from)).number;
          i <=
          state.doc.lineAt(Math.min(to, range.to, state.doc.length)).number;
          i++
        )
          line(state.doc.line(i).from, "md-table-source");
        return false;
      }
      if (
        name === "Image" ||
        (name === "HTMLBlock" &&
          /^(?:<img\b[^>]*>|<figure>\s*<img\b[^>]*>\s*<figcaption(?:\s[^>]*)?>[^]*?<\/figcaption>\s*<\/figure>)\s*$/.test(
            state.sliceDoc(from, to),
          ))
      ) {
        if (name === "HTMLBlock") to = state.doc.lineAt(from).to;
        const l = state.doc.lineAt(from);
        if (!(focused && editing(from, to)) && l.from === from && l.to === to) {
          out.push(
            Decoration.replace({
              widget: new BlockWidget(state.sliceDoc(from, to), "image", from),
              block: true,
            }).range(from, to),
          );
          return false;
        }
      }
      if (/^ATXHeading[1-6]$/.test(name)) {
        line(from, "md-heading md-h" + name.slice(-1));
      }
      if (name === "Blockquote") {
        for (
          let i = state.doc.lineAt(Math.max(from, range.from)).number;
          i <=
          state.doc.lineAt(Math.min(to, range.to, state.doc.length)).number;
          i++
        )
          line(state.doc.line(i).from, "md-quote");
      }
      if (name === "FencedCode") {
        for (
          let i = state.doc.lineAt(Math.max(from, range.from)).number;
          i <=
          state.doc.lineAt(Math.min(to, range.to, state.doc.length)).number;
          i++
        )
          line(state.doc.line(i).from, "md-code-line");
      }
      if (name === "HorizontalRule" && !editing(from, to)) {
        line(from, "md-rule");
        mark(from, to, "md-invisible");
        return false;
      }
      // 仅装饰无序列表标记，保留原字符宽度和文本坐标，避免影响点击及选区。
      if (name === "ListMark" && /^[-+*]$/.test(state.sliceDoc(from, to))) {
        mark(from, to, "md-bullet-mark");
      }
      if (name === "StrongEmphasis") mark(from, to, "md-strong");
      if (name === "Emphasis") mark(from, to, "md-em");
      if (name === "Strikethrough") mark(from, to, "md-strike");
      if (name === "InlineCode") mark(from, to, "md-inline-code");
      if (name === "Link") mark(from, to, "md-link");
      if (
        [
          "HeaderMark",
          "EmphasisMark",
          "StrikethroughMark",
          "CodeMark",
          "QuoteMark",
        ].includes(name) &&
        !editing(from, to)
      ) {
        // 围栏保留为轻量语言标记，隐藏行内符号不改变文本坐标。
        if (n.node.parent?.name !== "FencedCode") hide(from, to);
        else mark(from, to, "md-fence-mark");
      }
      if (name === "Link" && !editing(from, to)) {
        const source = state.sliceDoc(from, to);
        const m = /^\[([^\]]+)\]\((.+)\)$/.exec(source);
        if (m) {
          hide(from, from + 1);
          hide(from + 1 + m[1].length, to);
        }
        return false;
      }
    },
  });
  return Decoration.set(out, true);
}
const previewField = StateField.define<{
  focused: boolean;
  range: { from: number; to: number };
  decorations: DecorationSet;
}>({
  create(state) {
    const range = { from: 0, to: 8000 };
    return {
      focused: true,
      range,
      decorations: buildDecorations(state, range),
    };
  },
  update(value, tr) {
    let range = value.range,
      focused = value.focused;
    for (const e of tr.effects) {
      if (e.is(viewport)) range = e.value;
      if (e.is(previewFocus)) focused = e.value;
    }
    if (
      tr.docChanged ||
      tr.selection ||
      range !== value.range ||
      focused !== value.focused ||
      syntaxTree(tr.startState) !== syntaxTree(tr.state)
    )
      return {
        focused,
        range,
        decorations: buildDecorations(tr.state, range, focused),
      };
    return value;
  },
  provide: (f) => EditorView.decorations.from(f, (v) => v.decorations),
});
const previewViewport = ViewPlugin.fromClass(
  class {
    timer = 0;
    constructor(view: EditorView) {
      this.schedule(view);
    }
    update(u: any) {
      if (u.viewportChanged) this.schedule(u.view);
    }
    schedule(view: EditorView) {
      cancelAnimationFrame(this.timer);
      this.timer = requestAnimationFrame(() => {
        const from = Math.max(0, view.viewport.from - 1000),
          to = Math.min(view.state.doc.length, view.viewport.to + 1000);
        const current = view.state.field(previewField).range;
        if (from !== current.from || to !== current.to)
          view.dispatch({ effects: viewport.of({ from, to }) });
      });
    }
    destroy() {
      cancelAnimationFrame(this.timer);
    }
  },
);
// Base64 图片源码按行横向滚动；独立于预览扩展，源码模式和分栏内同样生效。
const base64ImageLines = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = this.build(view);
    }
    update(update: import("@codemirror/view").ViewUpdate) {
      if (update.docChanged || update.viewportChanged)
        this.decorations = this.build(update.view);
    }
    build(view: EditorView) {
      const lines = new Set<number>();
      const decorations: Range<Decoration>[] = [];
      for (const range of view.visibleRanges) {
        for (let pos = range.from; pos <= range.to;) {
          const line = view.state.doc.lineAt(pos);
          if (
            !lines.has(line.from) &&
            /(?:!\[[^\]]*\]\(\s*<?|<img\b[^>]*\bsrc\s*=\s*["'])data:image\/[^,\s]+;base64,/i.test(
              line.text,
            )
          ) {
            decorations.push(
              Decoration.line({ class: "md-base64-line" }).range(line.from),
            );
          }
          lines.add(line.from);
          pos = line.to + 1;
        }
      }
      return Decoration.set(decorations, true);
    }
  },
  { decorations: (plugin) => plugin.decorations },
);
const preview: Extension = [
  previewField,
  previewViewport,
  // 失焦时选区仍保留在源码行，需单独通知预览恢复图片，而非等待下一次光标移动。
  EditorView.domEventHandlers({
    focus: (_event, view) => {
      view.dispatch({ effects: previewFocus.of(true) });
    },
    blur: (_event, view) => {
      view.dispatch({ effects: previewFocus.of(false) });
    },
  }),
];
const restoreEndings = StateEffect.define<string[]>();
// 撤销历史保存换行元数据，让混合 CRLF/LF 的跨行删除也可精确恢复。
const endingsField = StateField.define<string[]>({
  create: () => [],
  update(value, tr) {
    for (const e of tr.effects) if (e.is(restoreEndings)) return e.value;
    return value;
  },
});
export type EditorCallbacks = {
  change: (patches: Patch[], raw: string) => void;
  outline: (items: { title: string; level: number; from: number }[]) => void;
  command: (name: string) => void;
  table: (model: TableModel) => void;
  image: (files: File[]) => void;
};
export class MarkdownEditor {
  parentEditor?: MarkdownEditor;
  removeEmptyColumn?: () => void;
  activeChild?: MarkdownEditor;
  active(): MarkdownEditor {
    return this.activeChild?.view.dom.isConnected
      ? this.activeChild.active()
      : this;
  }
  view: EditorView;
  buffer: SourceBuffer;
  sourceMode = false;
  headings: { title: string; level: number; from: number }[] = [];
  outlineTimer: ReturnType<typeof setTimeout> | undefined;
  constructor(
    parent: HTMLElement,
    raw: string,
    readonly callbacks: EditorCallbacks,
  ) {
    this.buffer = new SourceBuffer(raw);
    this.view = new EditorView({
      parent,
      state: EditorState.create({
        doc: this.buffer.normalized(),
        extensions: [
          EditorState.phrases.of({
            Find: "查找",
            Replace: "替换",
            next: "下一个",
            previous: "上一个",
            all: "全选匹配",
            "match case": "区分大小写",
            regexp: "正则表达式",
            "by word": "全词匹配",
            replace: "替换",
            "replace all": "全部替换",
            close: "关闭",
            "No matches": "没有匹配项",
          }),
          history(),
          // 使用浏览器原生选区，避免独立选区层被代码块背景遮住。
          dropCursor(),
          bracketMatching(),
          highlightSelectionMatches(),
          search({ top: true }),
          markdown({
            base: markdownLanguage,
            codeLanguages: (info) => {
              const lang = info.toLowerCase();
              if (["js", "javascript", "ts", "typescript"].includes(lang))
                return javascript({
                  typescript: lang === "ts" || lang === "typescript",
                }).language;
              if (lang === "json") return json().language;
              if (["py", "python"].includes(lang)) return python().language;
              if (lang === "swift") return StreamLanguage.define(swift);
              if (lang === "go") return StreamLanguage.define(go);
              return null;
            },
            pasteURLAsLink: false,
          }),
          syntaxHighlighting(defaultHighlightStyle),
          endingsField.init(() => this.buffer.endings),
          invertedEffects.of((tr) =>
            tr.docChanged
              ? [restoreEndings.of(tr.startState.field(endingsField))]
              : [],
          ),
          EditorState.transactionExtender.of((tr) => {
            if (!tr.docChanged || tr.effects.some((e) => e.is(restoreEndings)))
              return null;
            const prev = tr.startState.field(endingsField);
            let result = [...prev];
            const changes: { a: number; b: number; count: number }[] = [];
            tr.changes.iterChanges((a, b, _c, _d, insert) => {
              changes.push({
                a: tr.startState.doc.lineAt(a).number - 1,
                b: tr.startState.doc.lineAt(b).number - 1,
                count: insert.lines - 1,
              });
            });
            for (const c of changes.reverse())
              result.splice(
                c.a,
                c.b - c.a,
                ...Array(c.count).fill(this.buffer.preferred),
              );
            return { effects: restoreEndings.of(result) };
          }),
          keymap.of([
            { key: "Alt-ArrowUp", run: moveLineUp, preventDefault: true },
            { key: "Alt-ArrowDown", run: moveLineDown, preventDefault: true },
            {
              key: "Backspace",
              run: () => {
                if (
                  !this.removeEmptyColumn ||
                  this.view.composing ||
                  this.view.state.doc.toString().trim()
                )
                  return false;
                this.removeEmptyColumn();
                return true;
              },
            },
            {
              key: "Mod-s",
              run: () => {
                callbacks.command("save");
                return true;
              },
            },
            {
              key: "Mod-Shift-s",
              run: () => {
                callbacks.command("saveAs");
                return true;
              },
            },
            { key: "Mod-b", run: () => this.wrap("**") },
            { key: "Mod-i", run: () => this.wrap("*") },
            {
              key: "Mod-k",
              run: () => {
                callbacks.command("link");
                return true;
              },
            },
            {
              key: "Mod-Shift-m",
              run: () => {
                callbacks.command("mode");
                return true;
              },
            },
            ...Array.from({ length: 6 }, (_, i) => ({
              key: "Mod-" + (i + 1),
              run: () => this.prefix("#".repeat(i + 1) + " "),
            })),
            ...searchKeymap,
            {
              key: "Mod-z",
              run: () => {
                this.undo();
                return true;
              },
            },
            {
              key: "Mod-Shift-z",
              run: () => {
                this.redo();
                return true;
              },
            },
            ...historyKeymap,
            ...defaultKeymap,
            indentWithTab,
          ]),
          EditorView.lineWrapping,
          base64ImageLines,
          EditorView.contentAttributes.of({
            "aria-label": "Markdown 编辑区",
            spellcheck: "false",
            autocapitalize: "off",
          }),
          mode.of(preview),
          EditorView.updateListener.of((u) => {
            if (u.docChanged) {
              for (const tr of u.transactions)
                if (tr.docChanged) {
                  const changes: Patch[] = [];
                  tr.changes.iterChanges((a, b, _c, _d, s) =>
                    changes.push({ from: a, to: b, insert: s.toString() }),
                  );
                  const patches = this.buffer.apply(
                    changes,
                    tr.state.field(endingsField),
                  );
                  callbacks.change(patches, this.buffer.raw);
                }
              clearTimeout(this.outlineTimer);
              this.outlineTimer = setTimeout(() => this.outline(), 180);
            }
          }),
          EditorView.domEventHandlers({
            dblclick: (event, view) => {
              if (
                event.button !== 0 ||
                event.metaKey ||
                event.ctrlKey ||
                event.altKey ||
                event.shiftKey
              )
                return false;
              const target = event.target as HTMLElement;
              if (
                !view.scrollDOM.contains(target) ||
                target.closest(".md-widget, .cm-gutters, button, a, input")
              )
                return false;
              const content = view.contentDOM.getBoundingClientRect();
              if (event.clientX < content.left || event.clientX > content.right)
                return false;
              // 只接管文字之外的空白；实际字符上的双击继续交给 CodeMirror 选词。
              const lineDOM = target.closest(".cm-line");
              if (lineDOM) {
                const walker = document.createTreeWalker(
                  lineDOM,
                  NodeFilter.SHOW_TEXT,
                );
                const range = document.createRange();
                for (
                  let node = walker.nextNode();
                  node;
                  node = walker.nextNode()
                ) {
                  range.selectNodeContents(node);
                  for (const rect of range.getClientRects()) {
                    if (
                      event.clientX >= rect.left &&
                      event.clientX <= rect.right &&
                      event.clientY >= rect.top &&
                      event.clientY <= rect.bottom
                    )
                      return false;
                  }
                }
              }
              const pos = view.posAtCoords(
                { x: event.clientX, y: event.clientY },
                false,
              );
              if (pos === null) return false;
              const line = view.state.doc.lineAt(pos);
              const first = view.coordsAtPos(0),
                last = view.coordsAtPos(view.state.doc.length);
              let at = line.to,
                count = 1,
                anchor = at + 1;
              if (first && event.clientY < first.top) {
                at = 0;
                anchor = 0;
              } else if (last && event.clientY > last.bottom) {
                at = view.state.doc.length;
                count = Math.max(
                  1,
                  Math.ceil(
                    (event.clientY - last.bottom) / view.defaultLineHeight,
                  ),
                );
                anchor = at + count;
              }
              event.preventDefault();
              view.dispatch({
                changes: { from: at, insert: "\n".repeat(count) },
                selection: { anchor },
                userEvent: "input",
                scrollIntoView: true,
              });
              view.focus();
              return true;
            },
            paste: (event, view) => {
              const selection = view.state.selection.main;
              let node = syntaxTree(view.state).resolveInner(
                selection.from,
                -1,
              );
              let inCode = false;
              for (let n: typeof node | null = node; n; n = n.parent) {
                if (["FencedCode", "CodeBlock", "InlineCode"].includes(n.name))
                  inCode = true;
              }
              const table =
                !inCode &&
                clipboardTable(
                  event.clipboardData?.getData("text/html") ?? "",
                  event.clipboardData?.getData("text/plain") ?? "",
                );
              if (table) {
                event.preventDefault();
                const insert = "\n\n" + table + "\n\n";
                view.dispatch({
                  changes: { from: selection.from, to: selection.to, insert },
                  selection: { anchor: selection.from + insert.length },
                  userEvent: "input.paste",
                  scrollIntoView: true,
                });
                return true;
              }
              const files = Array.from(event.clipboardData?.files ?? []).filter(
                (f) => f.type.startsWith("image/"),
              );
              if (files.length) {
                event.preventDefault();
                callbacks.image(files);
                return true;
              }
              return false;
            },
            drop: (event, view) => {
              const files = Array.from(event.dataTransfer?.files ?? []).filter(
                (f) => f.type.startsWith("image/"),
              );
              if (files.length) {
                event.preventDefault();
                const pos = view.posAtCoords({
                  x: event.clientX,
                  y: event.clientY,
                });
                if (pos !== null) view.dispatch({ selection: { anchor: pos } });
                callbacks.image(files);
                return true;
              }
              return false;
            },
          }),
        ],
      }),
    });
    editorInstances.set(this.view, this);
    // 在浏览器及 CodeMirror 默认复制行为之前，按根文档坐标原子移动图片（包括跨分栏）。
    this.view.dom.addEventListener(
      "dragover",
      (event) => {
        if (!draggedImage) return;
        event.preventDefault();
        if (event.dataTransfer) event.dataTransfer.dropEffect = "move";
      },
      true,
    );
    this.view.dom.addEventListener(
      "drop",
      (event) => {
        if (
          !draggedImage ||
          (event.target as Element).closest(".cm-editor") !== this.view.dom
        )
          return;
        event.preventDefault();
        event.stopImmediatePropagation();
        const image = draggedImage;
        draggedImage = undefined;
        const pos = this.view.posAtCoords({
          x: event.clientX,
          y: event.clientY,
        });
        if (pos === null) return;
        const target = this.documentPosition(pos);
        const root = target.editor;
        if (root !== image.editor || root.view.state.doc !== image.doc) return;
        if (target.from >= image.from && target.from <= image.to) return;
        const insert = "\n\n" + image.text + "\n\n";
        const changes = root.view.state.changes(
          [
            { from: image.from, to: image.to },
            { from: target.from, insert },
          ].sort((a, b) => a.from - b.from),
        );
        root.view.dispatch({
          changes,
          selection: { anchor: changes.mapPos(target.from, -1) },
          annotations: isolateHistory.of("full"),
          userEvent: "move.image",
          scrollIntoView: true,
        });
        root.view.focus();
      },
      true,
    );
    this.view.contentDOM.addEventListener("focus", () => {
      this.activeChild = undefined;
    });
    this.view.dom.addEventListener("edit-table", (event) => {
      event.stopPropagation();
      callbacks.table((event as CustomEvent).detail);
    });
    this.view.dom.addEventListener("click", (event) => {
      if ((event.target as Element).closest(".cm-editor") !== this.view.dom)
        return;
      const mouse = event as MouseEvent;
      if (!(mouse.metaKey || mouse.ctrlKey)) return;
      const pos = this.view.posAtCoords({ x: mouse.clientX, y: mouse.clientY });
      if (pos === null) return;
      let node = syntaxTree(this.view.state).resolveInner(pos, 1);
      while (node.parent && node.name !== "Link") node = node.parent;
      if (node.name === "Link") {
        const m = /\]\((.*)\)$/.exec(
          this.view.state.sliceDoc(node.from, node.to),
        );
        if (m) {
          const path = m[1].replace(/^<|>$/g, "");
          if (path.startsWith("#")) {
            let anchor = path.slice(1);
            try {
              anchor = decodeURIComponent(anchor);
            } catch {}
            const seen = new Map<string, number>();
            for (const h of this.headings) {
              const base = h.title
                .toLowerCase()
                .replace(/[^\p{L}\p{N}_\s-]/gu, "")
                .trim()
                .replace(/\s+/g, "-");
              const count = seen.get(base) ?? 0;
              seen.set(base, count + 1);
              if (anchor === (count ? base + "-" + count : base)) {
                this.jump(h.from);
                break;
              }
            }
          } else
            void request("openLink", { path }).catch((e) =>
              window.nativeEvent("error", e.message),
            );
        }
      }
    });
    this.outline();
  }
  outline() {
    const items: { title: string; level: number; from: number }[] = [];
    let fence = "",
      offset = 0;
    // 大纲在输入停止后扫描文本，避免等待视口之外的后台语法解析。
    for (const text of this.view.state.doc.toString().split("\n")) {
      const marker = /^ {0,3}(`{3,}|~{3,})/.exec(text)?.[1];
      if (marker) {
        if (!fence) fence = marker;
        else if (
          marker[0] === fence[0] &&
          marker.length >= fence.length &&
          text.trim() === marker
        )
          fence = "";
      } else if (!fence) {
        const m = /^ {0,3}(#{1,6})[ \t]+(.+?)(?:[ \t]+#+)?[ \t]*$/.exec(text);
        if (m) items.push({ title: m[2], level: m[1].length, from: offset });
      }
      offset += text.length + 1;
    }
    this.headings = items;
    this.callbacks.outline(items);
  }
  apply(patches: Patch[]) {
    this.view.dispatch({ changes: patches, userEvent: "input" });
    this.view.focus();
  }
  wrap(marker: string) {
    const { from, to } = this.view.state.selection.main,
      doc = this.view.state.doc;
    const n = marker.length;
    if (
      from >= n &&
      doc.sliceString(from - n, from) === marker &&
      doc.sliceString(to, to + n) === marker
    ) {
      this.view.dispatch({
        changes: [
          { from: from - n, to: from, insert: "" },
          { from: to, to: to + n, insert: "" },
        ],
        selection: { anchor: from - n, head: to - n },
        userEvent: "input",
      });
    } else
      this.view.dispatch({
        changes: [
          { from, insert: marker },
          { from: to, insert: marker },
        ],
        selection: { anchor: from + n, head: to + n },
        userEvent: "input",
      });
    this.view.focus();
    return true;
  }
  prefix(prefix: string) {
    const s = this.view.state.selection.main,
      doc = this.view.state.doc;
    const changes = [];
    for (
      let n = doc.lineAt(s.from).number;
      n <= doc.lineAt(s.to > s.from ? s.to - 1 : s.to).number;
      n++
    ) {
      const l = doc.line(n),
        m = /^(?:#{1,6}\s+|>\s?|[-*+]\s+|\d+[.)]\s+)/.exec(l.text);
      changes.push({
        from: l.from,
        to: l.from + (m?.[0].length ?? 0),
        insert: prefix,
      });
    }
    this.apply(changes);
    return true;
  }
  toggle() {
    this.sourceMode = !this.sourceMode;
    const top = this.view.scrollDOM.scrollTop;
    this.view.dispatch({
      effects: mode.reconfigure(this.sourceMode ? [] : preview),
    });
    this.view.dom.classList.toggle("is-source", this.sourceMode);
    this.view.scrollDOM.scrollTop = top;
    this.view.focus();
  }
  // 将嵌套分栏内的位置映射到根文档，使跨栏移动共用一条撤销记录。
  documentPosition(from: number): { editor: MarkdownEditor; from: number } {
    const parent = this.parentEditor;
    if (!parent) return { editor: this, from };
    for (const el of parent.view.dom.querySelectorAll<HTMLElement>(
      ".md-columns",
    )) {
      const ui = columnUIs.get(el)!;
      const index = ui.children.indexOf(this);
      if (index >= 0)
        return parent.documentPosition(ui.block.columns[index].from + from);
    }
    throw new Error("Column editor is detached from its document");
  }
  jump(from: number) {
    this.view.dispatch({
      selection: { anchor: from },
      effects: EditorView.scrollIntoView(from, { y: "start", yMargin: 40 }),
    });
    this.view.focus();
    // 大纲定位落在分栏内时，将焦点和源文位置映射到对应子编辑器。
    if (!this.sourceMode)
      requestAnimationFrame(() => {
        for (const el of this.view.dom.querySelectorAll<HTMLElement>(
          ".md-columns",
        )) {
          if (el.closest(".cm-editor") !== this.view.dom) continue;
          const ui = columnUIs.get(el)!;
          const index = ui.block.columns.findIndex(
            (c) => from >= c.from && from <= c.to,
          );
          if (index < 0 || !ui.children[index]) continue;
          ui.children[index].jump(from - ui.block.columns[index].from);
          break;
        }
      });
  }
  find() {
    openSearchPanel(this.view);
  }
  // 表格组件不会移动正文光标；提交前将撤销锚点定位到表格附近，并映射到父分栏。
  anchorHistory(from: number) {
    this.view.dispatch({ selection: { anchor: from } });
    const parent = this.parentEditor;
    if (!parent) return;
    for (const el of parent.view.dom.querySelectorAll<HTMLElement>(
      ".md-columns",
    )) {
      const ui = columnUIs.get(el);
      const index = ui?.children.indexOf(this) ?? -1;
      if (index < 0) continue;
      parent.anchorHistory(ui!.block.columns[index].from + from);
      break;
    }
  }
  undo() {
    if (this.parentEditor) {
      this.parentEditor.undo();
      return;
    }
    const focused = this.active();
    undo(this.view);
    (focused.view.dom.isConnected ? focused.view : this.view).focus();
  }
  redo() {
    if (this.parentEditor) {
      this.parentEditor.redo();
      return;
    }
    const focused = this.active();
    redo(this.view);
    (focused.view.dom.isConnected ? focused.view : this.view).focus();
  }
  destroy() {
    clearTimeout(this.outlineTimer);
    this.view.destroy();
  }
}
