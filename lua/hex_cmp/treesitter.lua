---@class hex_cmp.TreesitterContext
---@field position integer 0 = in deps but not tuple, 1 = package atom, 2 = version, 3+ = opts
---@field package_name? string The package name from the first atom in the tuple

---@class hex_cmp.Treesitter
local M = {}

--- Check if the tree-sitter-elixir parser is available.
---@return boolean
function M.has_parser()
  local ok = pcall(vim.treesitter.language.inspect, 'elixir')
  return ok
end

--- Walk up from a node to find a parent of a given type.
---@param node TSNode
---@param node_type string
---@return TSNode?
local function find_parent(node, node_type)
  local current = node
  while current do
    if current:type() == node_type then
      return current
    end
    current = current:parent()
  end
  return nil
end

--- Check if a `call` node represents `def deps` or `defp deps`.
---@param call_node TSNode
---@param bufnr integer
---@return boolean
local function is_deps_call(call_node, bufnr)
  if call_node:type() ~= 'call' then
    return false
  end

  -- First named child should be identifier "defp" or "def"
  local target = call_node:named_child(0)
  if not target or target:type() ~= 'identifier' then
    return false
  end
  local macro = vim.treesitter.get_node_text(target, bufnr)
  if macro ~= 'defp' and macro ~= 'def' then
    return false
  end

  -- Second named child should be arguments containing "deps"
  local args = call_node:named_child(1)
  if not args or args:type() ~= 'arguments' then
    return false
  end
  local fn_name_node = args:named_child(0)
  if not fn_name_node then
    return false
  end
  local fn_name = vim.treesitter.get_node_text(fn_name_node, bufnr)
  return fn_name == 'deps'
end

--- Determine which positional index (1-based) the cursor occupies within a tuple.
---@param tuple_node TSNode
---@param row integer 0-indexed row
---@param col integer 0-indexed column
---@return integer position 1-based position
local function get_tuple_position(tuple_node, row, col)
  local count = tuple_node:named_child_count()
  for i = 0, count - 1 do
    local child = tuple_node:named_child(i)
    local _, _, er, ec = child:range()
    -- If cursor is before or within this child, it belongs to this position
    if row < er or (row == er and col <= ec) then
      return i + 1
    end
  end
  -- Cursor is past all children — next position
  return count + 1
end

--- Get the completion context for the cursor position.
---
--- Returns nil if not in deps function, otherwise returns a context table:
---   { position = 0 }                       -- in deps list but not in a tuple
---   { position = 1 }                       -- on the package atom (position 1)
---   { position = 2, package_name = "pkg" } -- on the version string (position 2)
---   { position = N, package_name = "pkg" } -- on later positions
---@param bufnr? integer Buffer number (default: current buffer)
---@return hex_cmp.TreesitterContext?
function M.get_context(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'elixir')
  if not ok or not parser then
    return nil
  end

  -- Force a re-parse to get the latest tree
  parser:parse()

  local node = vim.treesitter.get_node({ bufnr = bufnr })
  if not node then
    return nil
  end

  -- Walk up to check if we're inside a defp deps / def deps call
  local in_deps = false
  local current = node
  while current do
    if is_deps_call(current, bufnr) then
      in_deps = true
      break
    end
    current = current:parent()
  end

  if not in_deps then
    return nil
  end

  -- Find the tuple we're inside of (if any)
  local tuple_node = find_parent(node, 'tuple')
  if not tuple_node then
    -- No tuple parent — check if we're inside an ERROR node (incomplete tuple)
    local error_node = find_parent(node, 'ERROR')
    if error_node then
      -- Walk the ERROR node's children to determine position
      local cursor = vim.api.nvim_win_get_cursor(0)
      local row = cursor[1] - 1
      local col = cursor[2]
      local atom_count = 0
      ---@type string?
      local pkg_name = nil

      for child in error_node:iter_children() do
        local sr, sc, _, _ = child:range()
        local before_cursor = (sr < row) or (sr == row and sc < col)

        if child:type() == 'atom' then
          if atom_count == 0 then
            pkg_name = vim.treesitter.get_node_text(child, bufnr):gsub('^:', '')
          end
          atom_count = atom_count + 1
          -- Cursor is on this atom
          if not before_cursor then
            return { position = atom_count }
          end
        elseif child:type() == 'string' or child:type() == 'quoted_content' then
          -- Cursor is on or past a string — position 2+
          return { position = 2, package_name = pkg_name }
        end
      end

      -- Cursor is past the atom children — likely position 2
      if atom_count > 0 then
        return { position = atom_count + 1, package_name = pkg_name }
      end
    end

    return { position = 0 }
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1 -- 0-indexed
  local col = cursor[2]

  local position = get_tuple_position(tuple_node, row, col)

  ---@type hex_cmp.TreesitterContext
  local result = { position = position }

  -- Always read the package name from the first child if it's an atom
  local first_child = tuple_node:named_child(0)
  if first_child and first_child:type() == 'atom' then
    local text = vim.treesitter.get_node_text(first_child, bufnr)
    result.package_name = text:gsub('^:', '')
  end

  return result
end

return M
