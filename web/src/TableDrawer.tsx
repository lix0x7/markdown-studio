import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import * as Dropdown from "@radix-ui/react-dropdown-menu";
import * as Dialog from "@radix-ui/react-dialog";
import DataEditor, {
  GridCellKind,
  CompactSelection,
  type GridSelection,
  type GridCell,
  type Item,
} from "@glideapps/glide-data-grid";
import "@glideapps/glide-data-grid/dist/index.css";
import {
  X,
  ArrowCounterClockwise,
  ArrowClockwise,
} from "@phosphor-icons/react";
import type { TableModel } from "./source";

import { sortTable, pasteTable, type TableDraft as Draft } from "./table-data";
type ColumnAction =
  "before" | "after" | "delete" | "left" | "right" | "ascending" | "descending";
export default function TableDrawer({
  table,
  close,
  apply,
}: {
  table: TableModel;
  close: () => void;
  apply: (rows: string[][], aligns: string[]) => void;
}) {
  const initial = useMemo<Draft>(
    () => ({
      rows: table.rows.map((r) => r.map((c) => c.value)),
      aligns: [...table.aligns],
    }),
    [table],
  );
  const [draft, setDraft] = useState(initial),
    [widths, setWidths] = useState<number[]>([]),
    [discard, setDiscard] = useState(false);
  const [selection, setSelection] = useState<GridSelection>({
    columns: CompactSelection.empty(),
    rows: CompactSelection.empty(),
    current: {
      cell: [0, 0],
      range: { x: 0, y: 0, width: 1, height: 1 },
      rangeStack: [],
    },
  });
  const [columnMenu, setColumnMenu] = useState<{
    column: number;
    x: number;
    y: number;
  } | null>(null);
  const [history, setHistory] = useState<Draft[]>([]),
    [future, setFuture] = useState<Draft[]>([]);
  const current = useRef(draft);
  current.current = draft;
  const [root, setRoot] = useState<HTMLDivElement | null>(null),
    [size, setSize] = useState({ width: 600, height: 400 });
  const [dark, setDark] = useState(
    matchMedia("(prefers-color-scheme: dark)").matches,
  );
  useEffect(() => {
    const media = matchMedia("(prefers-color-scheme: dark)"),
      change = () => setDark(media.matches);
    media.addEventListener("change", change);
    return () => media.removeEventListener("change", change);
  }, []);
  useEffect(() => {
    const observer = new ResizeObserver(([entry]) =>
      setSize({
        width: Math.floor(entry.contentRect.width),
        height: Math.floor(entry.contentRect.height),
      }),
    );
    if (root) observer.observe(root);
    return () => observer.disconnect();
  }, [root]);
  const row = Math.min(
      selection.rows.first() ?? selection.current?.cell[1] ?? 0,
      draft.rows.length - 1,
    ),
    column = Math.min(
      selection.columns.first() ?? selection.current?.cell[0] ?? 0,
      draft.aligns.length - 1,
    );
  const dirty = JSON.stringify(draft) !== JSON.stringify(initial);
  const dismiss = () => {
    if (dirty) setDiscard(true);
    else close();
  };
  // 所有表格操作只修改抽屉草稿；批量粘贴与行列操作各保存一个历史步骤。
  const update = useCallback((next: Draft) => {
    if (JSON.stringify(next) === JSON.stringify(current.current)) return;
    const previous = current.current;
    setHistory((h) => [...h, previous].slice(-100));
    setFuture([]);
    current.current = next;
    setDraft(next);
  }, []);
  const undo = () => {
    if (!history.length) return;
    const previous = history[history.length - 1];
    const present = current.current;
    setFuture((f) => [present, ...f]);
    setHistory((h) => h.slice(0, -1));
    current.current = previous;
    setDraft(previous);
    setWidths([]);
    setSelection({
      columns: CompactSelection.empty(),
      rows: CompactSelection.empty(),
      current: {
        cell: [0, 0],
        range: { x: 0, y: 0, width: 1, height: 1 },
        rangeStack: [],
      },
    });
  };
  const redo = () => {
    if (!future.length) return;
    const present = current.current;
    setHistory((h) => [...h, present]);
    current.current = future[0];
    setDraft(future[0]);
    setWidths([]);
    setFuture((f) => f.slice(1));
    setSelection({
      columns: CompactSelection.empty(),
      rows: CompactSelection.empty(),
      current: {
        cell: [0, 0],
        range: { x: 0, y: 0, width: 1, height: 1 },
        rangeStack: [],
      },
    });
  };
  useEffect(() => {
    const handler = (e: Event) => {
      if ((e as CustomEvent).detail === "undo") undo();
      else redo();
    };
    window.addEventListener("table-command", handler);
    return () => window.removeEventListener("table-command", handler);
  });
  const getCell = useCallback(
    ([col, row]: Item): GridCell => ({
      kind: GridCellKind.Text,
      data: draft.rows[row]?.[col] ?? "",
      displayData: draft.rows[row]?.[col] ?? "",
      allowOverlay: true,
      allowWrapping: true,
      contentAlign: draft.aligns[col] as "left" | "center" | "right",
      themeOverride: row === 0 ? { baseFontStyle: "600 13px" } : undefined,
    }),
    [draft],
  );
  const columns = useMemo(
    () =>
      draft.aligns.map((_, i) => ({
        id: String(i),
        title: "列 " + (i + 1),
        hasMenu: true,
        width: widths[i] ?? 200,
      })),
    [draft.aligns, widths],
  );
  const editCells = useCallback(
    (edits: readonly { location: Item; value: GridCell }[]) => {
      const d = current.current,
        rows = d.rows.map((r) => [...r]);
      for (const {
        location: [c, r],
        value,
      } of edits) {
        if (value.kind === GridCellKind.Text && rows[r] && c < d.aligns.length)
          rows[r][c] = value.data;
      }
      update({ ...d, rows });
      return true;
    },
    [update],
  );
  const structural = (rows: string[][], aligns = draft.aligns) => {
    update({ rows, aligns });
    setSelection({
      columns: CompactSelection.empty(),
      rows: CompactSelection.empty(),
      current: {
        cell: [0, 0],
        range: { x: 0, y: 0, width: 1, height: 1 },
        rangeStack: [],
      },
    });
  };
  // 列结构变更同时移动表头、数据、对齐和列宽，并保留操作后的选中位置。
  const moveColumn = (from: number, to: number) => {
    if (from === to) return;
    const order = draft.aligns.map((_, i) => i);
    order.splice(to, 0, order.splice(from, 1)[0]);
    update({
      rows: draft.rows.map((r) => order.map((i) => r[i])),
      aligns: order.map((i) => draft.aligns[i]),
    });
    setWidths(order.map((i) => widths[i] ?? 200));
    setSelection({
      columns: CompactSelection.fromSingleSelection(to),
      rows: CompactSelection.empty(),
    });
  };
  const changeColumn = (action: ColumnAction, at = column) => {
    setColumnMenu(null);
    if (action === "ascending" || action === "descending") {
      update(sortTable(current.current, at, action === "descending"));
      return;
    }
    if (action === "left" || action === "right") {
      moveColumn(at, at + (action === "left" ? -1 : 1));
      return;
    }
    const index = action === "after" ? at + 1 : at;
    const rows = draft.rows.map((r) => [...r]),
      aligns = [...draft.aligns];
    const nextWidths = draft.aligns.map((_, i) => widths[i] ?? 200);
    if (action === "delete") {
      rows.forEach((r) => r.splice(index, 1));
      aligns.splice(index, 1);
      nextWidths.splice(index, 1);
    } else {
      rows.forEach((r) => r.splice(index, 0, ""));
      aligns.splice(index, 0, "left");
      nextWidths.splice(index, 0, 200);
    }
    update({ rows, aligns });
    setWidths(nextWidths);
    setSelection({
      columns: CompactSelection.fromSingleSelection(
        Math.min(index, aligns.length - 1),
      ),
      rows: CompactSelection.empty(),
    });
  };
  const columnActions: {
    action: ColumnAction;
    label: string;
    disabled: boolean;
  }[] = [
    { action: "ascending", label: "升序排列", disabled: draft.rows.length < 3 },
    {
      action: "descending",
      label: "降序排列",
      disabled: draft.rows.length < 3,
    },
    { action: "before", label: "左侧插入列", disabled: false },
    { action: "after", label: "右侧插入列", disabled: false },
    { action: "delete", label: "删除列", disabled: draft.aligns.length === 1 },
    { action: "left", label: "左移列", disabled: column === 0 },
    {
      action: "right",
      label: "右移列",
      disabled: column === draft.aligns.length - 1,
    },
  ];
  return (
    <Dialog.Root
      open
      onOpenChange={(open) => {
        if (!open) dismiss();
      }}
    >
      <Dialog.Portal>
        <Dialog.Overlay className="overlay table-drawer-overlay" />
        <Dialog.Content
          className="table-drawer"
          onInteractOutside={(e) => e.preventDefault()}
          onEscapeKeyDown={(e) => {
            if (document.querySelector("#portal input,#portal textarea")) {
              e.preventDefault();
              return;
            }
            e.preventDefault();
            dismiss();
          }}
        >
          <header className="table-drawer-header">
            <div>
              <Dialog.Title>编辑表格</Dialog.Title>
              <Dialog.Description>
                首行为表头 · F2 / 双击编辑 · Enter / Tab 连续编辑 · 拖动列头排序
                · 右键列头操作 · 框选后 ⌘C / ⌘V 复制粘贴
              </Dialog.Description>
            </div>
            <button
              className="tool"
              aria-label="关闭表格编辑器"
              onClick={dismiss}
            >
              <X />
            </button>
          </header>
          <div className="table-drawer-toolbar">
            <button
              onClick={() =>
                structural([
                  ...draft.rows.slice(0, row + 1),
                  Array(draft.aligns.length).fill(""),
                  ...draft.rows.slice(row + 1),
                ])
              }
            >
              添加行
            </button>
            <button
              disabled={row === 0}
              onClick={() => structural(draft.rows.filter((_, i) => i !== row))}
            >
              删除行
            </button>
            {columnActions.map(({ action, label, disabled }) => (
              <button
                key={action}
                disabled={disabled}
                onClick={() => changeColumn(action)}
              >
                {label}
              </button>
            ))}
            <select
              aria-label="当前列对齐方式"
              value={draft.aligns[column]}
              onChange={(e) =>
                update({
                  ...draft,
                  aligns: draft.aligns.map((v, i) =>
                    i === column ? e.target.value : v,
                  ),
                })
              }
            >
              <option value="left">左对齐</option>
              <option value="center">居中</option>
              <option value="right">右对齐</option>
            </select>
            <span className="divider" />
            <button
              aria-label="撤销表格修改"
              disabled={!history.length}
              onClick={undo}
            >
              <ArrowCounterClockwise />
            </button>
            <button
              aria-label="重做表格修改"
              disabled={!future.length}
              onClick={redo}
            >
              <ArrowClockwise />
            </button>
          </div>
          <div className="table-formula">
            <span>
              第 {row + 1} 行 / 第 {column + 1} 列
            </span>
            <input
              aria-label="当前单元格内容"
              key={`${row}:${column}:${draft.rows[row]?.[column]}`}
              defaultValue={draft.rows[row]?.[column] ?? ""}
              onBlur={(e) => {
                const rows = current.current.rows.map((r) => [...r]);
                if (rows[row]) rows[row][column] = e.target.value;
                update({ ...current.current, rows });
              }}
              onKeyDown={(e) => {
                if (e.key === "Enter") e.currentTarget.blur();
              }}
            />
          </div>
          <div className="table-canvas" ref={setRoot}>
            <DataEditor
              width={size.width}
              height={size.height}
              columns={columns}
              keybindings={{
                activateCell: "F2|Enter|shift+Enter",
                downFill: true,
                rightFill: true,
              }}
              onColumnMoved={moveColumn}
              onHeaderMenuClick={(col, bounds) => {
                setSelection({
                  columns: CompactSelection.fromSingleSelection(col),
                  rows: CompactSelection.empty(),
                });
                setColumnMenu({
                  column: col,
                  x: bounds.x,
                  y: bounds.y + bounds.height,
                });
              }}
              onHeaderContextMenu={(col, event) => {
                event.preventDefault();
                setSelection({
                  columns: CompactSelection.fromSingleSelection(col),
                  rows: CompactSelection.empty(),
                });
                setColumnMenu({
                  column: col,
                  x: event.bounds.x,
                  y: event.bounds.y + event.bounds.height,
                });
              }}
              rows={draft.rows.length}
              getCellContent={getCell}
              getCellsForSelection={true}
              onCellsEdited={editCells}
              onPaste={(target, values) => {
                if (!values.length || !values.some((r) => r.length))
                  return false;
                const [col, row] = target;
                update(pasteTable(current.current, col, row, values));
                setSelection({
                  columns: CompactSelection.empty(),
                  rows: CompactSelection.empty(),
                  current: {
                    cell: target,
                    range: {
                      x: col,
                      y: row,
                      width: Math.max(...values.map((r) => r.length)),
                      height: values.length,
                    },
                    rangeStack: [],
                  },
                });
                return false;
              }}
              gridSelection={selection}
              onGridSelectionChange={setSelection}
              onColumnResize={(_, width, index) =>
                setWidths((w) => {
                  const copy = [...w];
                  copy[index] = width;
                  return copy;
                })
              }
              rowMarkers="number"
              rowHeight={40}
              headerHeight={36}
              smoothScrollX
              smoothScrollY
              theme={
                dark
                  ? {
                      bgCell: "#232725",
                      bgCellMedium: "#2a302b",
                      bgHeader: "#1e221f",
                      bgHeaderHasFocus: "#31483a",
                      bgHeaderHovered: "#31483a",
                      textDark: "#e0e8e2",
                      textMedium: "#bcc8be",
                      textHeader: "#e0e8e2",
                      borderColor: "#3c4840",
                      accentColor: "#86b99a",
                      accentLight: "#31483a",
                    }
                  : {
                      accentColor: "#3d7259",
                      accentLight: "#e5eee7",
                      bgHeader: "#f4f5f3",
                      bgCell: "#ffffff",
                      textDark: "#303532",
                      borderColor: "#e8ebe6",
                    }
              }
            />
          </div>
          <footer className="table-drawer-footer">
            <span>
              {draft.rows.length} 行 × {draft.aligns.length} 列
              {dirty ? " · 未应用修改" : ""}
            </span>
            {discard ? (
              <>
                <span role="alert">放弃本次表格修改？</span>
                <button onClick={() => setDiscard(false)}>继续编辑</button>
                <button onClick={close}>放弃修改</button>
              </>
            ) : (
              <>
                <button onClick={dismiss}>取消</button>
                <button
                  className="primary"
                  onClick={() =>
                    apply(current.current.rows, current.current.aligns)
                  }
                >
                  应用修改
                </button>
              </>
            )}
          </footer>
          <Dropdown.Root
            open={columnMenu !== null}
            onOpenChange={(open) => {
              if (!open) setColumnMenu(null);
            }}
          >
            <Dropdown.Trigger
              aria-label="列操作菜单"
              style={{
                position: "fixed",
                left: Math.min(columnMenu?.x ?? 0, window.innerWidth - 170),
                top: columnMenu?.y ?? 0,
                width: 1,
                height: 1,
                padding: 0,
                border: 0,
              }}
            />
            <Dropdown.Content
              className="table-column-menu"
              side="bottom"
              align="start"
              onCloseAutoFocus={(e) => e.preventDefault()}
            >
              {columnActions.map(({ action, label, disabled }) => (
                <Dropdown.Item
                  key={action}
                  disabled={disabled}
                  onSelect={() => changeColumn(action, columnMenu?.column)}
                >
                  {label}
                </Dropdown.Item>
              ))}
            </Dropdown.Content>
          </Dropdown.Root>
          <div id="portal" className="glide-portal" />
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
