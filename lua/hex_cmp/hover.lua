local treesitter = require('hex_cmp.treesitter')
local api = require('hex_cmp.api')

---@class hex_cmp.Hover
local M = {}

--- Format a number with comma grouping (e.g. 1234567 -> "1,234,567").
---@param n integer
---@return string
local function format_number(n)
  local s = tostring(n)
  return s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
end

--- Build markdown hover content for a hex package.
---@param pkg hex_cmp.HexPackage
---@return string
local function build_hover_content(pkg)
  local parts = { '# ' .. pkg.name }

  if pkg.meta and pkg.meta.description then
    parts[#parts + 1] = pkg.meta.description
  end

  if pkg.latest_stable_version then
    parts[#parts + 1] = '**Latest:** ' .. pkg.latest_stable_version
  end

  if pkg.downloads then
    local dl = {}
    if pkg.downloads.all then
      dl[#dl + 1] = format_number(pkg.downloads.all) .. ' total'
    end
    if pkg.downloads.recent then
      dl[#dl + 1] = format_number(pkg.downloads.recent) .. ' recent'
    end
    if #dl > 0 then
      parts[#parts + 1] = '**Downloads:** ' .. table.concat(dl, ', ')
    end
  end

  if pkg.meta and pkg.meta.licenses and #pkg.meta.licenses > 0 then
    parts[#parts + 1] = '**License:** ' .. table.concat(pkg.meta.licenses, ', ')
  end

  if pkg.meta and pkg.meta.links then
    for name, url in pairs(pkg.meta.links) do
      parts[#parts + 1] = '[' .. name .. '](' .. url .. ')'
    end
  end

  return table.concat(parts, '\n\n')
end

--- Create the in-process LSP server function.
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
          local uri = params.textDocument.uri
          local bufnr = vim.uri_to_bufnr(uri)

          local ctx = treesitter.get_context(bufnr)
          if not ctx or not ctx.package_name or ctx.package_name == '' then
            callback(nil, nil)
            return true, request_id
          end

          api.get_package(ctx.package_name, function(pkg)
            if not pkg then
              callback(nil, nil)
              return
            end

            callback(nil, {
              contents = {
                kind = 'markdown',
                value = build_hover_content(pkg),
              },
            })
          end)
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

--- Attach the hex-cmp hover LSP to a buffer.
--- Call from your LSP on_attach or an autocmd:
---
---   require('hex_cmp.hover').attach(bufnr)
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
