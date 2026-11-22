import re

from markdown_it import MarkdownIt
from mdformat.renderer import RenderContext, RenderTreeNode
from mdformat.renderer._util import get_list_marker_type, is_tight_list


def update_mdit(mdit: MarkdownIt) -> None:
    pass


def _ordered_list(node: RenderTreeNode, context: RenderContext) -> str:
    """Numbers the items from the list's own start, each indented to its marker.

    ```markdown
    9. ninth
       continued under its text
    10. tenth
        continued under its text
    ```
    """
    marker_type = get_list_marker_type(node)
    block_separator = "\n" if is_tight_list(node) else "\n\n"
    starting_number = node.attrs.get("start", 1)
    rendered_items = []
    for item_index, item in enumerate(node.children):
        marker = f"{starting_number + item_index}{marker_type}"
        content_indent = " " * (len(marker) + 1)
        with context.indented(len(content_indent)):
            first_line, *following_lines = item.render(context).split("\n")
        lines = [f"{marker} {first_line}" if first_line else marker]
        lines += [content_indent + line if line else "" for line in following_lines]
        rendered_items.append("\n".join(lines))
    return block_separator.join(rendered_items)


def _thematic_break(node: RenderTreeNode, context: RenderContext) -> str:
    return "---"


_empty_cell = re.compile(r"(?<!\\)\|  (?=\|)")


def _delimiter_cell(cell: str) -> str:
    cell = cell.strip()
    left = ":" if cell.startswith(":") else "-"
    right = ":" if len(cell) > 1 and cell.endswith(":") else "-"
    return f"{left}-{right}"


def _table(text: str, node: RenderTreeNode, context: RenderContext) -> str:
    header, delimiter, *rows = text.split("\n")
    delimiter_cells = delimiter.strip().strip("|").split("|")
    delimiter = "|" + "|".join(_delimiter_cell(cell) for cell in delimiter_cells) + "|"
    return "\n".join(_empty_cell.sub("| ", line) for line in [header, delimiter, *rows])


# mdformat's own write `01.` to `10.`, 70 underscores and `| -- | -- |`.
RENDERERS = {"ordered_list": _ordered_list, "hr": _thematic_break}
POSTPROCESSORS = {"table": _table}
