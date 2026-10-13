local M = {}
local display = vim.fn.strdisplaywidth

-- Pipes inside code spans still need escaping in GFM tables.
function M.cells(line)
  local cells, starts, first, slashes, pipes = {}, {}, 1, 0, 0
  local function push(last)
    local raw = line:sub(first, last)
    cells[#cells + 1] = vim.trim(raw)
    starts[#starts + 1] = first - 1 + #(raw:match("^%s*") or "")
  end
  for i = 1, #line do
    local c = line:sub(i, i)
    if c == "|" and slashes % 2 == 0 then
      push(i - 1)
      first, pipes = i + 1, pipes + 1
    end
    slashes = c == "\\" and slashes + 1 or 0
  end
  if pipes == 0 then
    return nil
  end
  push(#line)
  if line:sub(1, first - 2):match("^%s*|") then
    table.remove(cells, 1)
    table.remove(starts, 1)
  end
  if line:sub(first):match("^%s*$") then
    table.remove(cells)
    table.remove(starts)
  end
  return cells, starts
end

function M.parse(lines)
  local tables, fence, i = {}, nil, 1
  while i <= #lines do
    local indent, run, tail = lines[i]:match("^( *)([`~]+)(.*)$")
    local marker = run and run:sub(1, 1)
    local is_fence = run and #indent <= 3 and #run >= 3 and run == marker:rep(#run)
    if fence then
      if is_fence and marker == fence.char and #run >= fence.size and tail:match("^%s*$") then
        fence = nil
      end
      i = i + 1
    elseif is_fence then
      fence = { char = marker, size = #run }
      i = i + 1
    else
      local headers = M.cells(lines[i])
      local separators = M.cells(lines[i + 1] or "")
      local valid = headers and separators and #headers > 0 and #headers == #separators
      for _, cell in ipairs(separators or {}) do
        valid = valid and cell:match("^:?-+:?$") ~= nil
      end
      if valid then
        local t = { headers = headers, aligns = separators, rows = {}, start = i, finish = i + 1 }
        i = i + 2
        while i <= #lines do
          local cells, starts = M.cells(lines[i])
          if not cells or lines[i]:match("^%s*[`~][`~][`~]") then
            break
          end
          for c = 1, #headers do
            cells[c] = cells[c] or ""
            starts[c] = math.min(starts[c] or #lines[i], math.max(0, #lines[i] - 1))
          end
          t.rows[#t.rows + 1] = { cells = cells, starts = starts, line = i }
          t.finish, i = i, i + 1
        end
        tables[#tables + 1] = t
      else
        i = i + 1
      end
    end
  end
  return tables
end

function M.text(text)
  return (text:gsub("\\|", "|"):gsub("<[bB][rR]%s*/?>", "\n"):gsub("\t", "    "))
end

-- Count screen cells, keeping composing characters with their base character.
local function take(text, width)
  local low, high = 0, vim.fn.strchars(text, 1)
  while low < high do
    local mid = math.ceil((low + high) / 2)
    if display(vim.fn.strcharpart(text, 0, mid, 1)) <= width then
      low = mid
    else
      high = mid - 1
    end
  end
  local part = vim.fn.strcharpart(text, 0, low, 1)
  return part, text:sub(#part + 1)
end

function M.clip(text, width)
  if display(text) <= width then
    return text
  end
  return take(text, math.max(0, width - 1)) .. "…"
end

function M.wrap(text, width, limit)
  width = math.max(2, width)
  local lines = {}
  for _, paragraph in ipairs(vim.split(M.text(text), "\n", { plain = true })) do
    local line = ""
    for word in vim.fn.strtrans(paragraph):gmatch("%S+") do
      if line ~= "" and display(line .. " " .. word) > width then
        lines[#lines + 1], line = line, ""
      end
      while display(word) > width do
        local part, rest = take(word, width)
        lines[#lines + 1], word = part, rest
      end
      if word ~= "" then
        line = line == "" and word or line .. " " .. word
      end
    end
    lines[#lines + 1] = line
  end
  if limit and #lines > limit then
    for n = #lines, limit + 1, -1 do
      lines[n] = nil
    end
    lines[limit] = take(lines[limit], width - 1) .. "…"
  end
  return lines
end

function M.widths(t, visible, width)
  local widths, demands, weights, used = {}, {}, {}, (#visible - 1) * 3
  for index, col in ipairs(visible) do
    local demand, weight = display(M.text(t.headers[col])), 0
    for _, row in ipairs(t.rows) do
      local size = display(M.text(row.cells[col]))
      demand, weight = math.max(demand, size), weight + size
    end
    demands[index] = math.max(2, demand)
    weights[index] = math.max(1, weight / math.max(1, #t.rows))
    widths[index] = math.min(10, demands[index])
    used = used + widths[index]
  end
  if used > width then
    return nil -- The row reader is more useful than columns narrower than ten cells.
  end
  while used < width do
    local best, score = nil, -1
    for index, current in ipairs(widths) do
      local benefit = weights[index] / (current * (current + 1))
      if current < demands[index] and benefit > score then
        best, score = index, benefit
      end
    end
    if not best then
      break
    end
    widths[best], used = widths[best] + 1, used + 1
  end
  return widths
end

-- Rebuild the table as aligned pipe-table lines, keeping indent and alignment markers.
function M.format(t, source_lines)
  local indent = source_lines[1]:match("^%s*")
  local widths, divider = {}, {}
  for col, header in ipairs(t.headers) do
    widths[col] = math.max(3, display(header))
    for _, row in ipairs(t.rows) do
      widths[col] = math.max(widths[col], display(row.cells[col]))
    end
    local align = t.aligns[col] or "---"
    local left = align:sub(1, 1) == ":" and ":" or "-"
    local right = align:sub(-1) == ":" and ":" or "-"
    divider[col] = left .. string.rep("-", widths[col] - 2) .. right
  end
  local function line(cells)
    local parts = {}
    for col, width in ipairs(widths) do
      parts[col] = cells[col] .. string.rep(" ", width - display(cells[col]))
    end
    return indent .. "| " .. table.concat(parts, " | ") .. " |"
  end
  local lines = { line(t.headers), line(divider) }
  for _, row in ipairs(t.rows) do
    lines[#lines + 1] = line(row.cells)
  end
  return lines
end

return M
