--- Tree-sitter (markdown + markdown_inline) -> intermediate representation.
---
--- The IR is a flat list of block tables. Every block carries:
---   type    one of: "heading" | "paragraph" | "code_block" | "list_item"
---           | "table" | "rule" | "raw"
---   quote   blockquote nesting depth (0 = not quoted)
---   indent  extra indent level for blocks nested inside list items
---
--- Inline content is a list of segments: { text, style?, url? } where style is
--- one of "bold" | "italic" | "bold_italic" | "code" | "link" | "strikethrough".
local M = {}

---------------------------------------------------------------------------
-- Source helpers
---------------------------------------------------------------------------

local function node_bytes(node)
  local _, _, sb = node:start()
  local _, _, eb = node:end_()
  return sb, eb
end

--- Raw source slice for a node (no whitespace normalization).
local function get_text(src, node)
  local sb, eb = node_bytes(node)
  return src:sub(sb + 1, eb)
end

--- Collapse newlines (plus any blockquote markers / indentation that follow
--- them) into a single space. Used for inline/flow text only.
local function clean(text)
  return (text:gsub("\r", ""):gsub("\n[>%s]*", " "))
end

--- Strip up to `n` leading indent-ish characters (spaces, tabs, `>`).
local function dedent(line, n)
  local i = 0
  while i < n do
    local c = line:sub(i + 1, i + 1)
    if c == " " or c == "\t" or c == ">" then
      i = i + 1
    else
      break
    end
  end
  return line:sub(i + 1)
end

---------------------------------------------------------------------------
-- Inline extraction (markdown_inline tree -> segments)
---------------------------------------------------------------------------

local function with(set, key)
  local copy = { bold = set.bold, italic = set.italic, code = set.code, strike = set.strike, link = set.link }
  copy[key] = true
  return copy
end

local function style_of(set)
  if set.code then
    return "code"
  elseif set.link then
    return "link"
  elseif set.bold and set.italic then
    return "bold_italic"
  elseif set.bold then
    return "bold"
  elseif set.italic then
    return "italic"
  elseif set.strike then
    return "strikethrough"
  end
  return nil
end

local function push(out, text, set, url)
  text = clean(text)
  if text == "" then
    return
  end
  local style = style_of(set)
  local last = out[#out]
  if last and last.style == style and last.url == url then
    last.text = last.text .. text
  else
    out[#out + 1] = { text = text, style = style, url = url }
  end
end

local skip_types = {
  emphasis_delimiter = true,
  code_span_delimiter = true,
}

local function find_child(node, type_name)
  for child in node:iter_children() do
    if child:type() == type_name then
      return child
    end
  end
end

local extract

extract = function(node, src, set, url, out)
  local node_start, node_end = node_bytes(node)
  local pos = node_start
  for child in node:iter_children() do
    local cs, ce = node_bytes(child)
    if cs > pos then
      push(out, src:sub(pos + 1, cs), set, url)
    end
    local t = child:type()
    if skip_types[t] then -- delimiters: no output
    elseif t == "strong_emphasis" then
      extract(child, src, with(set, "bold"), url, out)
    elseif t == "emphasis" then
      extract(child, src, with(set, "italic"), url, out)
    elseif t == "strikethrough" then
      extract(child, src, with(set, "strike"), url, out)
    elseif t == "code_span" then
      extract(child, src, with(set, "code"), url, out)
    elseif t == "inline_link" or t == "image" then
      local text_node = find_child(child, t == "image" and "image_description" or "link_text")
      local dest = find_child(child, "link_destination")
      local u = dest and get_text(src, dest) or nil
      if text_node then
        extract(text_node, src, with(set, "link"), u, out)
      elseif u then
        push(out, u, with(set, "link"), u)
      end
    elseif t == "uri_autolink" or t == "email_autolink" then
      local raw = get_text(src, child):gsub("^<", ""):gsub(">$", "")
      push(out, raw, with(set, "link"), raw)
    elseif t == "shortcut_link" or t == "full_reference_link" or t == "collapsed_reference_link" then
      local text_node = find_child(child, "link_text")
      if text_node then
        extract(text_node, src, with(set, "link"), url, out)
      else
        push(out, get_text(src, child), set, url)
      end
    elseif t == "backslash_escape" then
      push(out, get_text(src, child):sub(2), set, url)
    elseif t == "hard_line_break" then
      push(out, " ", set, url)
    else
      -- html_tag, entity_reference, latex, unknown: keep raw text
      push(out, get_text(src, child), set, url)
    end
    pos = ce
  end
  if node_end > pos then
    push(out, src:sub(pos + 1, node_end), set, url)
  end
end

--- Resolve the injected markdown_inline root for a block-side node and turn
--- it into a segment list. Falls back to the raw node text on lookup miss.
local function inline_segments(ctx, node)
  local out = {}
  if not node then
    return out
  end
  local sr, sc = node:start()
  local root = ctx.inline_index[sr .. ":" .. sc]
  if root then
    extract(root, ctx.src, {}, nil, out)
  else
    push(out, get_text(ctx.src, node), {}, nil)
  end
  return out
end

--- Trim leading whitespace of the first segment and trailing whitespace of
--- the last one (used for table cells).
local function trim_segments(segments)
  if segments[1] then
    segments[1].text = segments[1].text:gsub("^%s+", "")
  end
  if segments[#segments] then
    segments[#segments].text = segments[#segments].text:gsub("%s+$", "")
  end
  return vim.tbl_filter(function(seg)
    return seg.text ~= ""
  end, segments)
end

---------------------------------------------------------------------------
-- Block walk
---------------------------------------------------------------------------

local ignore_types = {
  block_continuation = true,
  block_quote_marker = true,
  minus_metadata = true,
  plus_metadata = true,
  link_reference_definition = true,
  fenced_code_block_delimiter = true,
}

local function emit(ctx, block, quote, indent)
  block.quote = quote
  block.indent = indent
  ctx.out[#ctx.out + 1] = block
end

local handle, walk

walk = function(node, ctx, quote, indent)
  for child in node:iter_children() do
    handle(child, ctx, quote, indent)
  end
end

--- Split code content into dedented lines. `bsc` is the start column of the
--- enclosing block (its indentation), `sc` the start column of the content
--- node itself.
local function code_lines(ctx, node, bsc)
  local _, sc = node:start()
  local raw = get_text(ctx.src, node):gsub("\n$", "")
  if raw == "" then
    return {}
  end
  local lines = {}
  for line in vim.gsplit(raw, "\n", { plain = true }) do
    if #lines == 0 then
      lines[#lines + 1] = dedent(line, math.max(0, bsc - sc))
    else
      lines[#lines + 1] = dedent(line, bsc)
    end
  end
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  return lines
end

--- Remove the largest common leading whitespace (indented code blocks).
local function strip_common_indent(lines)
  local min_indent
  for _, line in ipairs(lines) do
    if line:match("%S") then
      local indent = #line:match("^[ \t]*")
      min_indent = math.min(min_indent or indent, indent)
    end
  end
  if not min_indent or min_indent == 0 then
    return lines
  end
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = line:sub(min_indent + 1)
  end
  return out
end

local function parse_table_row(ctx, row_node)
  local cells = {}
  for cell in row_node:iter_children() do
    if cell:type() == "pipe_table_cell" then
      cells[#cells + 1] = trim_segments(inline_segments(ctx, cell))
    end
  end
  return cells
end

local function handle_list(node, ctx, quote, depth)
  for item in node:iter_children() do
    if item:type() == "list_item" then
      local marker, checkbox
      local ordered = false
      for c in item:iter_children() do
        local ct = c:type()
        if ct:match("^list_marker") then
          marker = vim.trim(get_text(ctx.src, c))
          ordered = ct == "list_marker_dot" or ct == "list_marker_parenthesis"
        elseif ct == "task_list_marker_checked" then
          checkbox = "checked"
        elseif ct == "task_list_marker_unchecked" then
          checkbox = "unchecked"
        end
      end
      local emitted_head = false
      local function head(inline)
        emit(ctx, {
          type = "list_item",
          depth = depth,
          ordered = ordered,
          marker = marker,
          checkbox = checkbox,
          inline = inline or {},
        }, quote, depth)
        emitted_head = true
      end
      for c in item:iter_children() do
        local ct = c:type()
        if ct:match("^list_marker") or ct:match("^task_list_marker") or ignore_types[ct] then -- skip
        elseif ct == "paragraph" and not emitted_head then
          head(inline_segments(ctx, find_child(c, "inline")))
        elseif ct == "list" then
          if not emitted_head then
            head()
          end
          handle_list(c, ctx, quote, depth + 1)
        else
          if not emitted_head then
            head()
          end
          handle(c, ctx, quote, depth + 1)
        end
      end
      if not emitted_head then
        head()
      end
    end
  end
end

handle = function(node, ctx, quote, indent)
  local t = node:type()
  if ignore_types[t] then
    return
  end
  if t == "section" then
    walk(node, ctx, quote, indent)
  elseif t == "atx_heading" then
    local level = 1
    local inline
    for c in node:iter_children() do
      local ct = c:type()
      local l = ct:match("^atx_h(%d)_marker$")
      if l then
        level = tonumber(l)
      elseif ct == "inline" then
        inline = c
      end
    end
    emit(ctx, { type = "heading", level = level, inline = inline_segments(ctx, inline) }, quote, indent)
  elseif t == "setext_heading" then
    local level = 2
    local inline
    for c in node:iter_children() do
      local ct = c:type()
      if ct == "setext_h1_underline" then
        level = 1
      elseif ct == "paragraph" then
        inline = find_child(c, "inline")
      end
    end
    emit(ctx, { type = "heading", level = level, inline = inline_segments(ctx, inline) }, quote, indent)
  elseif t == "paragraph" then
    emit(ctx, { type = "paragraph", inline = inline_segments(ctx, find_child(node, "inline")) }, quote, indent)
  elseif t == "fenced_code_block" then
    local _, bsc = node:start()
    local lang
    local lines = {}
    for c in node:iter_children() do
      local ct = c:type()
      if ct == "info_string" then
        local lang_node = find_child(c, "language")
        lang = lang_node and get_text(ctx.src, lang_node) or vim.trim(get_text(ctx.src, c)):match("^%S+")
      elseif ct == "code_fence_content" then
        lines = code_lines(ctx, c, bsc)
      end
    end
    emit(ctx, { type = "code_block", lang = lang, lines = lines }, quote, indent)
  elseif t == "indented_code_block" then
    local _, bsc = node:start()
    emit(ctx, { type = "code_block", lang = nil, lines = strip_common_indent(code_lines(ctx, node, bsc)) }, quote, indent)
  elseif t == "list" then
    handle_list(node, ctx, quote, indent)
  elseif t == "block_quote" then
    walk(node, ctx, quote + 1, indent)
  elseif t == "thematic_break" then
    emit(ctx, { type = "rule" }, quote, indent)
  elseif t == "pipe_table" then
    local header, rows, align = nil, {}, {}
    for c in node:iter_children() do
      local ct = c:type()
      if ct == "pipe_table_header" then
        header = parse_table_row(ctx, c)
      elseif ct == "pipe_table_delimiter_row" then
        for dc in c:iter_children() do
          if dc:type() == "pipe_table_delimiter_cell" then
            local left = find_child(dc, "pipe_table_align_left") ~= nil
            local right = find_child(dc, "pipe_table_align_right") ~= nil
            align[#align + 1] = (left and right) and "center" or (right and "right") or (left and "left") or "none"
          end
        end
      elseif ct == "pipe_table_row" then
        rows[#rows + 1] = parse_table_row(ctx, c)
      end
    end
    emit(ctx, { type = "table", header = header or {}, align = align, rows = rows }, quote, indent)
  else
    -- html_block and anything unknown: raw text fallback
    local raw = get_text(ctx.src, node):gsub("\n$", "")
    emit(ctx, { type = "raw", lines = vim.split(raw, "\n", { plain = true }) }, quote, indent)
  end
end

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

local function parse_with(parser, src)
  local ok, trees = pcall(parser.parse, parser, true)
  if not ok or not trees or not trees[1] then
    return nil, "failed to parse markdown"
  end

  -- Index injected markdown_inline trees by the start position of their
  -- region so block nodes can look up their inline tree.
  local inline_index = {}
  local ok_children, children = pcall(parser.children, parser)
  local inline_ltree = ok_children and children and children["markdown_inline"] or nil
  if inline_ltree then
    for _, tree in pairs(inline_ltree:trees()) do
      local root = tree:root()
      local sr, sc = root:start()
      inline_index[sr .. ":" .. sc] = root
    end
  end

  local ctx = { src = src, inline_index = inline_index, out = {} }
  walk(trees[1]:root(), ctx, 0, 0)
  return ctx.out
end

--- Parse a buffer.
---@param bufnr integer|nil buffer handle (0/nil = current)
---@return table|nil blocks, string|nil error
function M.parse(bufnr)
  bufnr = bufnr or 0
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown")
  if not ok or not parser then
    return nil, "tree-sitter markdown parser is not available"
  end
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n")
  return parse_with(parser, src)
end

--- Parse a markdown string (used by tests and tooling).
---@param src string
---@return table|nil blocks, string|nil error
function M.parse_string(src)
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, "markdown")
  if not ok or not parser then
    return nil, "tree-sitter markdown parser is not available"
  end
  return parse_with(parser, src)
end

return M
