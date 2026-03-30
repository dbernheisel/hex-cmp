--- Native LSP completion and hover provider for Neovim >= 0.12.
---
--- On Neovim 0.12+, this module provides an in-process LSP server that handles
--- textDocument/completion, textDocument/inlineCompletion, and textDocument/hover,
--- eliminating the need for blink.cmp and the separate hover module.
---
--- Usage:
---   require('hex_cmp.native').attach(bufnr)
---
--- This enables vim.lsp.completion (built-in) and inline ghost-text completions,
--- plus hover support, all in one lightweight LSP server.
---@class hex_cmp.Native
local M = {}

local treesitter = require('hex_cmp.treesitter')
local api = require('hex_cmp.api')
local cache_mod = require('hex_cmp.cache')

--- Format a number with comma grouping (e.g. 1234567 -> "1,234,567").
---@param n integer
---@return string
local function format_number(n)
  local s = tostring(n)
  return s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
end

--- Parse a version string like "1.7.4" into {major, minor, patch} numbers.
---@param version_str string
---@return { major: integer, minor: integer, patch: integer }?
local function parse_version(version_str)
  local major, minor, patch = version_str:match('^(%d+)%.(%d+)%.?(%d*)')
  if major then
    return {
      major = tonumber(major),
      minor = tonumber(minor),
      patch = tonumber(patch) or 0,
    }
  end
  return nil
end

--- Extract the search query from the line text for package name completion.
---@param line string
---@param col integer 0-indexed cursor column
---@return string?
local function extract_package_query(line, col)
  local before = line:sub(1, col)
  return before:match('{:(%w[%w_]*)$')
    or before:match(':%s*(%w[%w_]*)$')
    or before:match(':(%w*)$')
end

--- Build package name completion items.
---@param packages hex_cmp.HexPackage[]
---@return lsp.CompletionItem[]
local function make_package_items(packages)
  local items = {}
  for _, pkg in ipairs(packages) do
    local doc_parts = {}
    if pkg.meta and pkg.meta.description then
      table.insert(doc_parts, pkg.meta.description)
    end
    if pkg.downloads and pkg.downloads.all then
      table.insert(doc_parts, format_number(pkg.downloads.all) .. ' downloads')
    end
    if pkg.latest_stable_version then
      table.insert(doc_parts, 'Latest: ' .. pkg.latest_stable_version)
    end

    items[#items + 1] = {
      label = ':' .. pkg.name,
      insertText = ':' .. pkg.name,
      filterText = ':' .. pkg.name,
      kind = 9, -- Module
      detail = pkg.latest_stable_version and ('v' .. pkg.latest_stable_version) or nil,
      documentation = #doc_parts > 0 and {
        kind = 'markdown',
        value = table.concat(doc_parts, '\n\n'),
      } or nil,
    }
  end
  return items
end

--- Build version completion items from releases.
---@param releases hex_cmp.HexRelease[]
---@param retirements? table<string, hex_cmp.HexRetirement>
---@return lsp.CompletionItem[]
local function make_version_items(releases, retirements)
  local items = {}
  local seen_tilde = {}
  local tilde_idx = 0

  for _, rel in ipairs(releases) do
    local v = rel.version
    local retirement_info = retirements and retirements[v]
    local retired = retirement_info ~= nil and retirement_info ~= vim.NIL

    local parsed = parse_version(v)
    if parsed and not retired then
      local tilde = string.format('~> %d.%d', parsed.major, parsed.minor)
      if not seen_tilde[tilde] then
        seen_tilde[tilde] = true
        tilde_idx = tilde_idx + 1
        items[#items + 1] = {
          label = '"' .. tilde .. '"',
          insertText = '"' .. tilde .. '"',
          filterText = tilde,
          kind = 12, -- Value
          detail = 'latest: ' .. v,
          sortText = string.format('%05d', tilde_idx),
        }
      end
    end
  end

  for i, rel in ipairs(releases) do
    local v = rel.version
    local retirement_info = retirements and retirements[v]
    local retired = retirement_info ~= nil and retirement_info ~= vim.NIL

    local detail_parts = {}
    if rel.inserted_at then
      detail_parts[#detail_parts + 1] = rel.inserted_at:sub(1, 10)
    end
    if retired then
      detail_parts[#detail_parts + 1] = 'RETIRED'
    end

    local doc = nil
    if retired and type(retirement_info) == 'table' then
      local doc_parts = {}
      if retirement_info.reason then
        doc_parts[#doc_parts + 1] = '**Retired:** ' .. retirement_info.reason
      end
      if retirement_info.message then
        doc_parts[#doc_parts + 1] = retirement_info.message
      end
      if #doc_parts > 0 then
        doc = { kind = 'markdown', value = table.concat(doc_parts, '\n\n') }
      end
    end

    items[#items + 1] = {
      label = '"' .. v .. '"',
      insertText = '"' .. v .. '"',
      filterText = v,
      kind = 12, -- Value
      detail = #detail_parts > 0 and table.concat(detail_parts, ' | ') or nil,
      sortText = string.format('%05d', tilde_idx + i),
      deprecated = retired or nil,
      documentation = doc,
    }
  end

  return items
end

--- Static dependency option completion items.
---@type { label: string, insertText: string, detail: string, documentation?: string }[]
local DEP_OPTS = {
  { label = 'only:', insertText = 'only: ', detail = 'Limit to environments', documentation = 'e.g. `only: :test` or `only: [:dev, :test]`' },
  { label = 'targets:', insertText = 'targets: ', detail = 'Limit to targets', documentation = 'e.g. `targets: :host`' },
  { label = 'optional:', insertText = 'optional: true', detail = 'Mark as optional' },
  { label = 'runtime:', insertText = 'runtime: false', detail = 'Exclude from runtime apps', documentation = 'Default `true`. Set `false` to not include in applications list.' },
  { label = 'override:', insertText = 'override: true', detail = 'Override other definitions' },
  { label = 'app:', insertText = 'app: false', detail = 'Skip reading app file' },
  { label = 'env:', insertText = 'env: :prod', detail = 'Dependency environment', documentation = 'Default `:prod`' },
  { label = 'compile:', insertText = 'compile: ""', detail = 'Custom compile command' },
  { label = 'manager:', insertText = 'manager: ', detail = ':mix, :rebar3, or :make' },
  { label = 'system_env:', insertText = 'system_env: ', detail = 'Environment variables' },
  { label = 'path:', insertText = 'path: ""', detail = 'Path dependency' },
  { label = 'in_umbrella:', insertText = 'in_umbrella: true', detail = 'Umbrella path dep', documentation = 'Sets path to `"../#{app}"`' },
  { label = 'hex:', insertText = 'hex: ""', detail = 'Hex package name', documentation = 'Defaults to app name' },
  { label = 'repo:', insertText = 'repo: "hexpm"', detail = 'Hex repository' },
  { label = 'git:', insertText = 'git: ""', detail = 'Git repository URI' },
  { label = 'github:', insertText = 'github: ""', detail = 'GitHub shortcut' },
  { label = 'ref:', insertText = 'ref: ""', detail = 'Git ref (branch/SHA/tag)' },
  { label = 'branch:', insertText = 'branch: ""', detail = 'Git branch' },
  { label = 'tag:', insertText = 'tag: ""', detail = 'Git tag' },
  { label = 'submodules:', insertText = 'submodules: true', detail = 'Init submodules' },
  { label = 'sparse:', insertText = 'sparse: ""', detail = 'Sparse checkout directory' },
  { label = 'subdir:', insertText = 'subdir: ""', detail = 'Subdirectory in checkout' },
  { label = 'depth:', insertText = 'depth: 1', detail = 'Shallow clone depth' },
}

--- Build opts completion items.
---@return lsp.CompletionItem[]
local function make_opts_items()
  local items = {}
  for i, opt in ipairs(DEP_OPTS) do
    items[#items + 1] = {
      label = opt.label,
      insertText = opt.insertText,
      filterText = opt.label,
      kind = 14, -- Keyword
      detail = opt.detail,
      sortText = string.format('%05d', i),
      documentation = opt.documentation and {
        kind = 'markdown',
        value = opt.documentation,
      } or nil,
    }
  end
  return items
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

--- Build the signature help response.
---@param pkg hex_cmp.HexPackage
---@param active_param integer 0-indexed
---@return lsp.SignatureHelp
local function build_signature_help(pkg, active_param)
  local doc_parts = {}
  if pkg.meta and pkg.meta.description then
    table.insert(doc_parts, pkg.meta.description)
  end
  if pkg.latest_stable_version then
    table.insert(doc_parts, '**Latest:** ' .. pkg.latest_stable_version)
  end
  if pkg.downloads and pkg.downloads.all then
    table.insert(doc_parts, '**Downloads:** ' .. format_number(pkg.downloads.all))
  end
  if pkg.meta and pkg.meta.links then
    for name, url in pairs(pkg.meta.links) do
      table.insert(doc_parts, string.format('[%s](%s)', name, url))
    end
  end
  if pkg.meta and pkg.meta.licenses and #pkg.meta.licenses > 0 then
    table.insert(doc_parts, '**License:** ' .. table.concat(pkg.meta.licenses, ', '))
  end

  return {
    activeSignature = 0,
    signatures = {
      {
        label = '{app, requirement, opts}',
        documentation = {
          kind = 'markdown',
          value = table.concat(doc_parts, '\n\n'),
        },
        parameters = {
          {
            label = 'app',
            documentation = 'The dependency atom name, e.g. :' .. pkg.name,
          },
          {
            label = 'requirement',
            documentation = 'A version requirement, e.g. "~> 1.0". Follows the Elixir Version module specification.',
          },
          {
            label = 'opts',
            documentation = table.concat({
              'Keyword list of options:',
              '',
              '**General:** `:only`, `:targets`, `:optional`, `:runtime`, `:override`, `:app`, `:env`, `:compile`, `:manager`, `:system_env`',
              '',
              '**Path:** `:path`, `:in_umbrella`',
              '',
              '**Hex:** `:hex`, `:repo`',
              '',
              '**Git:** `:git`, `:github`, `:ref`, `:branch`, `:tag`, `:submodules`, `:sparse`, `:subdir`, `:depth`',
            }, '\n'),
          },
        },
        activeParameter = active_param,
      },
    },
  }
end

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
            local query = extract_package_query(line, col)

            if not query or #query < 1 then
              callback(nil, { isIncomplete = true, items = {} })
              return true, srv_request_id
            end

            api.search_packages(query, function(packages)
              callback(nil, { isIncomplete = true, items = make_package_items(packages) })
            end)

          elseif ctx.position == 2 then
            local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
            local line = lines[1] or ''
            local before = line:sub(1, col)
            if not before:match(',%s+') then
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
              callback(nil, { isIncomplete = false, items = make_version_items(pkg.releases, pkg.retirements) })
            end)

          elseif ctx.position >= 3 then
            callback(nil, { isIncomplete = false, items = make_opts_items() })
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
            local before = line:sub(1, col)
            if before:match(',%s*$') then
              api.get_package(ctx.package_name, function(pkg)
                if not pkg or not pkg.releases or #pkg.releases == 0 then
                  callback(nil, { items = {} })
                  return
                end

                -- Suggest the latest stable ~> version
                local latest = pkg.releases[1]
                local parsed = parse_version(latest.version)
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
          local uri = params.textDocument.uri
          local bufnr = vim.uri_to_bufnr(uri)

          local ctx = treesitter.get_context(bufnr)
          if not ctx or not ctx.package_name or ctx.package_name == '' then
            callback(nil, nil)
            return true, srv_request_id
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
            callback(nil, build_signature_help(pkg, active_param))
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
---
--- On Neovim 0.12+, this provides completion, inline completion, hover,
--- and signature help without needing blink.cmp.
---
--- Usage from your config:
---
---   vim.api.nvim_create_autocmd('BufRead', {
---     pattern = 'mix.exs',
---     callback = function(ev)
---       require('hex_cmp.native').attach(ev.buf)
---     end,
---   })
---
---@param bufnr integer Buffer number to attach to
---@param opts? { cache_ttl?: integer, max_results?: integer } Optional configuration
function M.attach(bufnr, opts)
  opts = opts or {}
  if opts.cache_ttl then
    cache_mod.setup({ ttl = opts.cache_ttl })
  end
  if opts.max_results then
    api.setup({ max_results = opts.max_results })
  end

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
