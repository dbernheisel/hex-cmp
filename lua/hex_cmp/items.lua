--- Shared formatting and item-building functions for hex-cmp.
---
--- Used by init.lua (blink.cmp source), native.lua (0.12+ LSP), and hover.lua.
---@class hex_cmp.Items
local M = {}

--- Format a number with comma grouping (e.g. 1234567 -> "1,234,567").
---@param n integer
---@return string
function M.format_number(n)
  local s = tostring(n)
  return s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
end

---@class hex_cmp.ParsedVersion
---@field major integer
---@field minor integer
---@field patch integer

--- Parse a version string like "1.7.4" into {major, minor, patch} numbers.
---@param version_str string
---@return hex_cmp.ParsedVersion?
function M.parse_version(version_str)
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
---@param cursor_before_line string Text before cursor on the current line
---@return string?
function M.extract_package_query(cursor_before_line)
  return cursor_before_line:match('{:(%w[%w_]*)$')
    or cursor_before_line:match(':%s*(%w[%w_]*)$')
    or cursor_before_line:match(':(%w*)$')
end

--- Build completion items for a list of hex packages.
---@param packages hex_cmp.HexPackage[]
---@return lsp.CompletionItem[]
function M.make_package_items(packages)
  local items = {}
  for _, pkg in ipairs(packages) do
    local doc_parts = {}
    if pkg.meta and pkg.meta.description then
      table.insert(doc_parts, pkg.meta.description)
    end
    if pkg.downloads and pkg.downloads.all then
      table.insert(doc_parts, M.format_number(pkg.downloads.all) .. ' downloads')
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

--- Build completion items from release versions (~> versions first, then exact).
---@param releases hex_cmp.HexRelease[]
---@param retirements? table<string, hex_cmp.HexRetirement>
---@return lsp.CompletionItem[]
function M.make_version_items(releases, retirements)
  local items = {}
  local seen_tilde = {}
  local tilde_idx = 0

  -- First pass: collect ~> versions (sorted first)
  for _, rel in ipairs(releases) do
    local v = rel.version
    local retirement_info = retirements and retirements[v]
    local retired = retirement_info ~= nil and retirement_info ~= vim.NIL

    local parsed = M.parse_version(v)
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

---@class hex_cmp.DepOpt
---@field label string
---@field insertText string
---@field detail string
---@field documentation? string

--- Static opts for dep tuple position 3.
---@type hex_cmp.DepOpt[]
M.DEP_OPTS = {
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

--- Build dep opts into completion items.
---@return lsp.CompletionItem[]
function M.make_opts_items()
  local items = {}
  for i, opt in ipairs(M.DEP_OPTS) do
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
function M.build_hover_content(pkg)
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
      dl[#dl + 1] = M.format_number(pkg.downloads.all) .. ' total'
    end
    if pkg.downloads.recent then
      dl[#dl + 1] = M.format_number(pkg.downloads.recent) .. ' recent'
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

--- Build an LSP SignatureHelp response for a package.
---@param pkg hex_cmp.HexPackage
---@param active_param integer 0-indexed active parameter (0=app, 1=requirement, 2=opts)
---@return lsp.SignatureHelp
function M.build_signature_help(pkg, active_param)
  local doc_parts = {}
  if pkg.meta and pkg.meta.description then
    table.insert(doc_parts, pkg.meta.description)
  end
  if pkg.latest_stable_version then
    table.insert(doc_parts, '**Latest:** ' .. pkg.latest_stable_version)
  end
  if pkg.downloads and pkg.downloads.all then
    table.insert(doc_parts, '**Downloads:** ' .. M.format_number(pkg.downloads.all))
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
  }
end

return M
