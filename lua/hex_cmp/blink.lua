--- blink.cmp source for hex.pm package completion.
---
--- Configure in blink.cmp:
---
---   hex = { name = "hex", module = "hex_cmp.blink", async = true }
---
---@class hex_cmp.BlinkSource : blink.cmp.Source
local source = {}

local treesitter = require('hex_cmp.treesitter')
local api = require('hex_cmp.api')
local items = require('hex_cmp.items')

---@type blink.cmp.CompletionResponse
local EMPTY = { is_incomplete_forward = false, is_incomplete_backward = false, items = {} }

---@param opts? table Provider opts from sources.providers.hex.opts
---@param _config? table Full provider config
---@return hex_cmp.BlinkSource
function source.new(opts, _config)
  local self = setmetatable({}, { __index = source })
  opts = opts or {}
  require('hex_cmp').setup(opts)
  return self
end

--- Only enable in mix.exs buffers with treesitter-elixir available.
---@return boolean
function source:enabled()
  local bufname = vim.api.nvim_buf_get_name(0)
  if not bufname:match('mix%.exs$') then
    return false
  end
  return treesitter.has_parser()
end

---@return string[]
function source:get_trigger_characters()
  return { '{', ':', '"', '.', ' ' }
end

---@param ctx blink.cmp.Context
---@param callback fun(response?: blink.cmp.CompletionResponse)
---@return fun()? cancel Cancel function
function source:get_completions(ctx, callback)
  local ts_ctx = treesitter.get_context(ctx.bufnr)

  if not ts_ctx or ts_ctx.position == 0 then
    callback(EMPTY)
    return
  end

  if ts_ctx.position == 1 then
    -- Package name completion
    local cursor_before = ctx.line:sub(1, ctx.cursor[2])
    local query = items.extract_package_query(cursor_before)

    if not query or #query < 1 then
      callback({ is_incomplete_forward = true, is_incomplete_backward = false, items = {} })
      return
    end

    api.search_packages(query, function(packages)
      callback({ is_incomplete_forward = true, is_incomplete_backward = false, items = items.make_package_items(packages) })
    end)

  elseif ts_ctx.position == 2 then
    -- Version completion — only after space following comma, not on the comma itself
    local cursor_before = ctx.line:sub(1, ctx.cursor[2])
    if not cursor_before:match(',%s+') then
      callback(EMPTY)
      return
    end

    if not ts_ctx.package_name or ts_ctx.package_name == '' then
      callback(EMPTY)
      return
    end

    api.get_package(ts_ctx.package_name, function(pkg)
      if not pkg or not pkg.releases then
        callback(EMPTY)
        return
      end
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items.make_version_items(pkg.releases, pkg.retirements) })
    end)

  elseif ts_ctx.position >= 3 then
    -- Opts completion
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items.make_opts_items() })

  else
    callback(EMPTY)
  end
end

---@param item blink.cmp.CompletionItem
---@param callback fun(resolved_item: blink.cmp.CompletionItem)
function source:resolve(item, callback)
  callback(item)
end

---@return { trigger_characters: string[], retrigger_characters: string[] }
function source:get_signature_help_trigger_characters()
  return { trigger_characters = { '{', ',' }, retrigger_characters = { ',' } }
end

--- Build an LSP SignatureHelp response for the current dep tuple.
---@param ctx blink.cmp.SignatureHelpContext
---@param callback fun(signature_help: lsp.SignatureHelp?)
function source:get_signature_help(ctx, callback)
  local ts_ctx = treesitter.get_context(ctx.bufnr)
  if not ts_ctx or ts_ctx.position == 0 then
    callback(nil)
    return
  end

  local pkg_name = ts_ctx.package_name
  if not pkg_name or pkg_name == '' then
    callback(nil)
    return
  end

  api.get_package(pkg_name, function(pkg)
    if not pkg then
      callback(nil)
      return
    end

    local active_param = math.min(ts_ctx.position - 1, 2) -- 0-indexed, clamp to 0-2
    callback(items.build_signature_help(pkg, active_param))
  end)
end

return source
