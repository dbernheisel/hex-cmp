local treesitter = require('hex_cmp.treesitter')
local api = require('hex_cmp.api')
local items = require('hex_cmp.items')

---@class hex_cmp.Hover
local M = {}

--- Handle a textDocument/hover LSP request for hex packages.
--- Shared implementation used by both the standalone hover server and the native server.
---@param params lsp.HoverParams
---@param callback fun(err: any?, result: lsp.Hover?)
function M.handle(params, callback)
  local uri = params.textDocument.uri
  local bufnr = vim.uri_to_bufnr(uri)

  local ctx = treesitter.get_context(bufnr)
  if not ctx or not ctx.package_name or ctx.package_name == '' then
    callback(nil, nil)
    return
  end

  api.get_package(ctx.package_name, function(pkg)
    if not pkg then
      callback(nil, nil)
      return
    end

    callback(nil, {
      contents = {
        kind = 'markdown',
        value = items.build_hover_content(pkg),
      },
    })
  end)
end

--- Create the in-process LSP server function (hover-only, for pre-0.12).
---@return fun(dispatchers: vim.lsp.rpc.Dispatchers): vim.lsp.rpc.PublicClient
local function make_server()
  return function(dispatchers)
    local closing = false
    local request_id = 0

    return {
      request = function(method, params, callback)
        request_id = request_id + 1

        if method == 'initialize' then
          callback(nil, {
            capabilities = {
              hoverProvider = true,
            },
          })
        elseif method == 'textDocument/hover' then
          M.handle(params, callback)
        elseif method == 'shutdown' then
          callback(nil, nil)
        else
          callback(nil, nil)
        end

        return true, request_id
      end,

      notify = function(method, _params)
        if method == 'exit' then
          dispatchers.on_exit(0, 0)
        end
      end,

      is_closing = function()
        return closing
      end,

      terminate = function()
        closing = true
      end,
    }
  end
end

--- Attach the hex-cmp hover-only LSP to a buffer (pre-0.12 fallback).
---
--- Prefer `require('hex_cmp').attach(bufnr)` which auto-detects
--- Neovim version and uses the native server on 0.12+.
---
--- This starts a lightweight in-process LSP that only provides
--- textDocument/hover for hex packages. It works alongside your
--- existing LSP — vim.lsp.buf.hover() (K) queries all clients.
---@param bufnr integer Buffer number to attach to
function M.attach(bufnr)
  vim.lsp.start({
    name = 'hex-cmp',
    cmd = make_server(),
    root_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':h'),
  }, {
    bufnr = bufnr,
  })
end

return M
