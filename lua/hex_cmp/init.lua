--- hex-cmp: hex.pm package completion for Elixir mix.exs files.
---
--- On Neovim 0.12+, works standalone with built-in LSP completion.
--- On older versions, serves as a blink.cmp source (module = "hex_cmp").
--- Also works with blink.cmp on 0.12+ (blink handles completion, native
--- server is skipped to avoid conflicts).
---
--- Quick start (Neovim 0.12+, no blink.cmp needed):
---
---   { 'dbernheisel/hex-cmp' }
---
--- Quick start (any version with blink.cmp):
---
---   -- In your blink.cmp providers:
---   hex = { name = "hex", module = "hex_cmp", async = true }

--- Apply optional configuration to cache and API modules.
---@param opts? { cache_ttl?: integer, max_results?: integer }
local function setup(opts)
  opts = opts or {}
  if opts.cache_ttl then
    require('hex_cmp.cache').setup({ ttl = opts.cache_ttl })
  end
  if opts.max_results then
    require('hex_cmp.api').setup({ max_results = opts.max_results })
  end
end

--- Attach hex-cmp to a buffer.
---
--- On Neovim 0.12+, starts the native LSP server (completion + inline
--- completion + hover + signature help). On older versions, starts the
--- hover-only LSP server.
---@param bufnr integer Buffer number to attach to
local function attach(bufnr)
  if vim.fn.has('nvim-0.12') == 1 then
    require('hex_cmp.native').attach(bufnr)
  else
    require('hex_cmp.hover').attach(bufnr)
  end
end

-- On Neovim 0.12+ without blink.cmp, auto-attach to mix.exs buffers for native completion.
-- When blink.cmp is present, it handles completion via the blink source instead.
if vim.fn.has('nvim-0.12') == 1 and not pcall(require, 'blink.cmp') then
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'elixir',
    group = vim.api.nvim_create_augroup('hex-cmp', { clear = true }),
    callback = function(ev)
      local bufname = vim.api.nvim_buf_get_name(ev.buf)
      if bufname:match('mix%.exs$') then
        require('hex_cmp.native').attach(ev.buf)
      end
    end,
  })
end

-- Always return the blink.cmp source with setup/attach mixed in,
-- so module = "hex_cmp" works whether or not blink.cmp is installed.
local source = require('hex_cmp.blink')
source.setup = setup
source.attach = attach
return source
