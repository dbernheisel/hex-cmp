--- Native LSP completion and hover provider for Neovim >= 0.12.
---
--- Provides an in-process LSP server that handles textDocument/completion,
--- textDocument/inlineCompletion, textDocument/hover, and textDocument/signatureHelp,
--- eliminating the need for blink.cmp and the separate hover module.
---
--- Typically called via `require('hex_cmp').attach(bufnr)` which auto-detects
--- the Neovim version. Can also be used directly:
---
---   require('hex_cmp.native').attach(bufnr)
---@class hex_cmp.Native
local M = {}

local treesitter = require('hex_cmp.treesitter')
local api = require('hex_cmp.api')
local items = require('hex_cmp.items')
local hover = require('hex_cmp.hover')

--- Create the in-process LSP server function for Neovim 0.12+.
--- Provides: completion, inlineCompletion, hover, and signatureHelp.
---@return fun(dispatchers: vim.lsp.rpc.Dispatchers): vim.lsp.rpc.PublicClient
local function make_server()
  return function(dispatchers)
    local closing = false
    local srv_request_id = 0

    return {
      request = function(method, params, callback)
        srv_request_id = srv_request_id + 1

        if method == 'initialize' then
          callback(nil, {
            capabilities = {
              completionProvider = {
                triggerCharacters = { '{', ':', '"', '.', ' ' },
                resolveProvider = false,
              },
              inlineCompletionProvider = true,
              hoverProvider = true,
              signatureHelpProvider = {
                triggerCharacters = { '{', ',' },
                retriggerCharacters = { ',' },
              },
            },
          })

        elseif method == 'textDocument/completion' then
          local uri = params.textDocument.uri
          local bufnr = vim.uri_to_bufnr(uri)
          local row = params.position.line
          local col = params.position.character

          local ctx = treesitter.get_context(bufnr)
          if not ctx or ctx.position == 0 then
            callback(nil, { isIncomplete = false, items = {} })
            return true, srv_request_id
          end

          if ctx.position == 1 then
            local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
            local line = lines[1] or ''
            local query = items.extract_package_query(line:sub(1, col))

            if not query or #query < 1 then
              callback(nil, { isIncomplete = true, items = {} })
              return true, srv_request_id
            end

            api.search_packages(query, function(packages)
              callback(nil, { isIncomplete = true, items = items.make_package_items(packages) })
            end)

          elseif ctx.position == 2 then
            local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
            local line = lines[1] or ''
            if not line:sub(1, col):match(',%s+') then
              callback(nil, { isIncomplete = false, items = {} })
              return true, srv_request_id
            end

            if not ctx.package_name or ctx.package_name == '' then
              callback(nil, { isIncomplete = false, items = {} })
              return true, srv_request_id
            end

            api.get_package(ctx.package_name, function(pkg)
              if not pkg or not pkg.releases then
                callback(nil, { isIncomplete = false, items = {} })
                return
              end
              callback(nil, { isIncomplete = false, items = items.make_version_items(pkg.releases, pkg.retirements) })
            end)

          elseif ctx.position >= 3 then
            callback(nil, { isIncomplete = false, items = items.make_opts_items() })
          else
            callback(nil, { isIncomplete = false, items = {} })
          end

        elseif method == 'textDocument/inlineCompletion' then
          local uri = params.textDocument.uri
          local bufnr = vim.uri_to_bufnr(uri)
          local row = params.position.line
          local col = params.position.character

          local ctx = treesitter.get_context(bufnr)
          if not ctx or ctx.position == 0 then
            callback(nil, { items = {} })
            return true, srv_request_id
          end

          -- Inline completion: suggest the most likely next item as ghost text
          if ctx.position == 2 and ctx.package_name and ctx.package_name ~= '' then
            local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
            local line = lines[1] or ''
            if line:sub(1, col):match(',%s*$') then
              api.get_package(ctx.package_name, function(pkg)
                if not pkg or not pkg.releases or #pkg.releases == 0 then
                  callback(nil, { items = {} })
                  return
                end

                -- Suggest the latest stable ~> version
                local latest = pkg.releases[1]
                local parsed = items.parse_version(latest.version)
                if parsed then
                  local suggestion = string.format('"~> %d.%d"', parsed.major, parsed.minor)
                  callback(nil, {
                    items = {
                      {
                        insertText = suggestion,
                        range = {
                          start = { line = row, character = col },
                          ['end'] = { line = row, character = col },
                        },
                      },
                    },
                  })
                else
                  callback(nil, { items = {} })
                end
              end)
              return true, srv_request_id
            end
          end

          callback(nil, { items = {} })

        elseif method == 'textDocument/hover' then
          hover.handle(params, callback)

        elseif method == 'textDocument/signatureHelp' then
          local uri = params.textDocument.uri
          local bufnr = vim.uri_to_bufnr(uri)

          local ctx = treesitter.get_context(bufnr)
          if not ctx or ctx.position == 0 then
            callback(nil, nil)
            return true, srv_request_id
          end

          local pkg_name = ctx.package_name
          if not pkg_name or pkg_name == '' then
            callback(nil, nil)
            return true, srv_request_id
          end

          api.get_package(pkg_name, function(pkg)
            if not pkg then
              callback(nil, nil)
              return
            end
            local active_param = math.min(ctx.position - 1, 2)
            callback(nil, items.build_signature_help(pkg, active_param))
          end)

        elseif method == 'shutdown' then
          callback(nil, nil)
        else
          callback(nil, nil)
        end

        return true, srv_request_id
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

--- Attach the native hex-cmp LSP server to a buffer.
--- Provides completion, inline completion, hover, and signature help.
---@param bufnr integer Buffer number to attach to
function M.attach(bufnr)
  local client_id = vim.lsp.start({
    name = 'hex-cmp',
    cmd = make_server(),
    root_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':h'),
  }, {
    bufnr = bufnr,
  })

  -- Enable Neovim's built-in LSP completion for this buffer
  if client_id and vim.lsp.completion and vim.lsp.completion.enable then
    vim.lsp.completion.enable(true, client_id, bufnr, {
      autotrigger = true,
    })
  end
end

--- Check if native mode is available (Neovim 0.12+).
---@return boolean
function M.available()
  return vim.fn.has('nvim-0.12') == 1
end

return M
