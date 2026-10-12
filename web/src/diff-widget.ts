import { search, searchKeymap, openSearchPanel } from "@codemirror/search";
import { EditorView, WidgetType, keymap, lineNumbers } from "@codemirror/view";
import { Transaction } from "@codemirror/state";
import {
  defaultKeymap,
  indentWithTab,
  isolateHistory,
} from "@codemirror/commands";
import { MergeView } from "@codemirror/merge";
import { json } from "@codemirror/lang-json";
import {
  syntaxHighlighting,
  defaultHighlightStyle,
} from "@codemirror/language";
import { diffMarkup, formatDiffJSON, type DiffBlock } from "./diff";
import { minimalPatch } from "./source";

type DiffUI = {
  block: DiffBlock;
  merge?: MergeView;
  syncing: boolean;
  disposed: boolean;
  observer: ResizeObserver;
};
const instances = new WeakMap<HTMLElement, DiffUI>();
type Actions = {
  anchor: (at: number) => void;
  undo: () => void;
  redo: () => void;
};
export class DiffWidget extends WidgetType {
  constructor(
    readonly block: DiffBlock,
    readonly actions: (view: EditorView) => Actions,
  ) {
    super();
  }
  eq(other: DiffWidget) {
    return (
      this.block.from === other.block.from &&
      this.block.original === other.block.original
    );
  }
  toDOM(parent: EditorView) {
    const el = document.createElement("div");
    el.className = "md-diff";
    const header = document.createElement("div");
    header.className = "diff-header";
    const body = document.createElement("div");
    const status = document.createElement("div");
    status.className = "diff-status";
    status.setAttribute("role", "status");
    el.append(header, body, status);
    const ui: DiffUI = {
      block: this.block,
      syncing: false,
      disposed: false,
      observer: new ResizeObserver(() => parent.requestMeasure()),
    };
    instances.set(el, ui);
    ui.observer.observe(el);
    // 延后挂载，保证父编辑器初始化完毕；输入同步回 Markdown 的同一条撤销历史。
    queueMicrotask(() => {
      if (ui.disposed) return;
      const actions = this.actions(parent);
      const extensions = (side: "left" | "right") => [
        lineNumbers(),
        search({ top: true }),
        json(),
        syntaxHighlighting(defaultHighlightStyle),
        EditorView.contentAttributes.of({
          "aria-label": side === "left" ? "Diff 左侧代码" : "Diff 右侧代码",
        }),
        keymap.of([
          {
            key: "Mod-z",
            run: (view) => {
              actions.undo();
              if (view.dom.isConnected) view.focus();
              return true;
            },
          },
          {
            key: "Mod-Shift-z",
            run: (view) => {
              actions.redo();
              if (view.dom.isConnected) view.focus();
              return true;
            },
          },
          ...searchKeymap,
          ...defaultKeymap,
          indentWithTab,
        ]),
        EditorView.updateListener.of((update) => {
          if (!update.docChanged || ui.syncing) return;
          const isolate = update.transactions.some((tr) =>
            tr.isUserEvent("input.diff.format"),
          );
          queueMicrotask(() => {
            if (ui.disposed || !ui.merge) return;
            const markup = diffMarkup(
              ui.merge.a.state.doc.toString(),
              ui.merge.b.state.doc.toString(),
            );
            if (markup === ui.block.original) return;
            actions.anchor(ui.block.from);
            parent.dispatch({
              changes: { from: ui.block.from, to: ui.block.to, insert: markup },
              annotations: isolate ? isolateHistory.of("full") : [],
              userEvent: "input.diff",
            });
          });
        }),
      ];
      ui.merge = new MergeView({
        a: { doc: ui.block.left, extensions: extensions("left") },
        b: { doc: ui.block.right, extensions: extensions("right") },
        parent: body,
        highlightChanges: true,
        gutter: true,
      });
      for (const [index, label] of ["左侧", "右侧"].entries()) {
        const tools = document.createElement("div");
        tools.className = "diff-side-tools";
        const title = document.createElement("span");
        title.textContent = label;
        tools.append(title);
        for (const [name, text] of [
          ["find", "查找"],
          ["copy", "复制"],
          ["format", "格式化 JSON"],
          ["sort", "JSON 键排序"],
        ]) {
          const button = document.createElement("button");
          button.type = "button";
          button.textContent = text;
          button.title = label + text;
          button.setAttribute("aria-label", label + text);
          button.onclick = async () => {
            const view = index === 0 ? ui.merge!.a : ui.merge!.b;
            const source = view.state.doc.toString();
            try {
              if (name === "find") {
                openSearchPanel(view);
              } else if (name === "copy") {
                if (navigator.clipboard?.writeText)
                  await navigator.clipboard.writeText(source);
                else {
                  const input = document.createElement("textarea");
                  input.value = source;
                  input.style.position = "fixed";
                  input.style.opacity = "0";
                  el.append(input);
                  input.select();
                  try {
                    if (!document.execCommand("copy"))
                      throw new Error("复制失败，请选择文本后复制");
                  } finally {
                    input.remove();
                    view.focus();
                  }
                }
                status.textContent = label + "已复制";
              } else {
                const formatted = formatDiffJSON(source, name === "sort");
                view.dispatch({
                  changes: {
                    from: 0,
                    to: view.state.doc.length,
                    insert: formatted,
                  },
                  annotations: Transaction.addToHistory.of(false),
                  userEvent: "input.diff.format",
                });
                status.textContent =
                  label + (name === "sort" ? "已按键排序" : "已格式化");
              }
            } catch (error) {
              status.textContent =
                label +
                "：" +
                (error instanceof Error ? error.message : String(error));
            }
          };
          tools.append(button);
        }
        header.append(tools);
      }
      parent.requestMeasure();
    });
    return el;
  }
  updateDOM(el: HTMLElement) {
    const ui = instances.get(el)!;
    ui.block = this.block;
    if (!ui.merge) return true;
    ui.syncing = true;
    try {
      for (const [view, text] of [
        [ui.merge.a, this.block.left],
        [ui.merge.b, this.block.right],
      ] as const) {
        const patch = minimalPatch(view.state.doc.toString(), text);
        if (patch)
          view.dispatch({
            changes: patch,
            annotations: Transaction.addToHistory.of(false),
          });
      }
    } finally {
      ui.syncing = false;
    }
    return true;
  }
  destroy(el: HTMLElement) {
    const ui = instances.get(el)!;
    ui.disposed = true;
    ui.observer.disconnect();
    ui.merge?.destroy();
  }
  ignoreEvent() {
    return true;
  }
}
