local treesitter = require('hex_cmp.treesitter')
local api = require('hex_cmp.api')
local cache_mod = require('hex_cmp.cache')

---@class hex_cmp.Source : blink.cmp.Source
local source = {}

---@type blink.cmp.CompletionResponse
local EMPTY = { is_incomplete_forward = false, is_incomplete_backward = false, items = {} }

---@param opts? table Provider opts from sources.providers.hex.opts
---@param _config? table Full provider config
---@return hex_cmp.Source
function source.new(opts, _config)
  local self = setmetatable({}, { __index = source })
  opts = opts or {}
  if opts.cache_ttl then
    cache_mod.setup({ ttl = opts.cache_ttl })
  end
  if opts.max_results then
    api.setup({ max_results = opts.max_results })
  end
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

--- Format a number with comma grouping (e.g. 1234567 -> "1,234,567").
---@param n integer
---@return string
local function format_number(n)
  local s = tostring(n)
  return s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
end

--- Extract the search query from the line text for package name completion.
---@param cursor_before_line string
---@return string?
local function extract_package_query(cursor_before_line)
  return cursor_before_line:match('{:(%w[%w_]*)$')
    or cursor_before_line:match(':%s*(%w[%w_]*)$')
    or cursor_before_line:match(':(%w*)$')
end

--- Format a package search result into a completion item.
---@param pkg hex_cmp.HexPackage
---@return blink.cmp.CompletionItem
local function format_package_item(pkg)
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

  return {
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

---@class hex_cmp.ParsedVersion
---@field major integer
---@field minor integer
---@field patch integer

--- Parse a version string like "1.7.4" into {major, minor, patch} numbers.
---@param version_str string
---@return hex_cmp.ParsedVersion?
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

--- Format releases into completion items (~> versions first, then exact).
---@param releases hex_cmp.HexRelease[]
---@param retirements? table<string, hex_cmp.HexRetirement> Map of version string to retirement info
---@return blink.cmp.CompletionItem[]
local function format_version_items(releases, retirements)
  local items = {}
  local seen_tilde = {}
  local tilde_idx = 0

  -- First pass: collect ~> versions (sorted first)
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
        table.insert(items, {
          label = '"' .. tilde .. '"',
          insertText = '"' .. tilde .. '"',
          filterText = tilde,
          kind = 12, -- Value
          detail = 'latest: ' .. v,
          sortText = string.format('%05d', tilde_idx),
        })
      end
    end
  end

  -- Second pass: exact versions (sorted after ~> versions)
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

    ---@type lsp.MarkupContent?
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

    table.insert(items, {
      label = '"' .. v .. '"',
      insertText = '"' .. v .. '"',
      filterText = v,
      kind = 12, -- Value
      detail = #detail_parts > 0 and table.concat(detail_parts, ' | ') or nil,
      sortText = string.format('%05d', tilde_idx + i),
      deprecated = retired or nil,
      documentation = doc,
    })
  end

  return items
end

---@class hex_cmp.DepOpt
---@field label string
---@field insertText string
---@field detail string
---@field documentation? string

--- Static opts for dep tuple position 3.
---@type hex_cmp.DepOpt[]
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
  -- Path
  { label = 'path:', insertText = 'path: ""', detail = 'Path dependency' },
  { label = 'in_umbrella:', insertText = 'in_umbrella: true', detail = 'Umbrella path dep', documentation = 'Sets path to `"../#{app}"`' },
  -- Hex
  { label = 'hex:', insertText = 'hex: ""', detail = 'Hex package name', documentation = 'Defaults to app name' },
  { label = 'repo:', insertText = 'repo: "hexpm"', detail = 'Hex repository' },
  -- Git
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

--- Format dep opts into completion items.
---@return blink.cmp.CompletionItem[]
local function format_opts_items()
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
    local query = extract_package_query(cursor_before)

    if not query or #query < 1 then
      callback({ is_incomplete_forward = true, is_incomplete_backward = false, items = {} })
      return
    end

    api.search_packages(query, function(packages)
      local items = {}
      for _, pkg in ipairs(packages) do
        table.insert(items, format_package_item(pkg))
      end
      callback({ is_incomplete_forward = true, is_incomplete_backward = false, items = items })
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
      local items = format_version_items(pkg.releases, pkg.retirements)
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
    end)

  elseif ts_ctx.position >= 3 then
    -- Opts completion
    local items = format_opts_items()
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })

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

    local label = '{app, requirement, opts}'
    local active_param = math.min(ts_ctx.position - 1, 2) -- 0-indexed, clamp to 0-2

    callback({
      activeSignature = 0,
      signatures = {
        {
          label = label,
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
                '**General:**',
                '- `:only` - limit to specific environments (e.g. `only: :test`)',
                '- `:targets` - limit to specific targets (e.g. `targets: :host`)',
                '- `:optional` - mark as optional dependency',
                '- `:runtime` - whether included in runtime applications (default `true`)',
                '- `:override` - override definitions from other dependencies',
                '- `:app` - set `false` to skip reading the app file',
                '- `:env` - environment to run the dependency in',
                '- `:compile` - custom compile command',
                '- `:manager` - `:mix`, `:rebar3`, or `:make`',
                '- `:system_env` - environment variables for loading/compiling',
                '',
                '**Path:**',
                '- `:path` - the path for the dependency',
                '- `:in_umbrella` - when `true`, sets a path dependency pointing to `"../#{app}"`',
                '',
                '**Hex:**',
                '- `:hex` - the hex package name (defaults to app name)',
                '- `:repo` - repository to fetch from (default `"hexpm"`)',
                '- `:warn_if_outdated` - warn if a more recent version is published on Hex.pm',
                '',
                '**Git:**',
                '- `:git` - the Git repository URI',
                '- `:github` - shortcut for GitHub repos, uses `:git`',
                '- `:ref` - the reference to checkout (branch, SHA, or tag)',
                '- `:branch` - the Git branch to checkout',
                '- `:tag` - the Git tag to checkout',
                '- `:submodules` - when `true`, initialize submodules',
                '- `:sparse` - checkout a single directory as the dependency',
                '- `:subdir` - search for the project in a subdirectory of the checkout',
                '- `:depth` - shallow clone depth (positive integer, typically `1`)',
              }, '\n'),
            },
          },
          activeParameter = active_param,
        },
      },
    })
  end)
end

return source
