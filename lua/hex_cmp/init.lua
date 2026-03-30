--- hex-cmp: hex.pm package completion for Elixir mix.exs files.
---
--- On Neovim 0.12+, uses built-in LSP completion and native HTTP.
--- On older versions, serves as a blink.cmp source (module = "hex_cmp")
--- with curl for HTTP.
---
--- Quick start (Neovim 0.12+, no blink.cmp needed):
---
---   require('hex_cmp').setup()
---
--- Quick start (pre-0.12 with blink.cmp):
---
---   -- In your blink.cmp providers:
---   hex = { name = "hex", module = "hex_cmp", async = true }
---   -- For hover, in your LSP on_attach:
---   require('hex_cmp').attach(bufnr)

--- Apply configuration to cache and API modules.
---@param opts? { cache_ttl?: integer, max_results?: integer }
local function setup(opts)
  opts = opts or {}
  if opts.cache_ttl then
    require('hex_cmp.cache').setup({ ttl = opts.cache_ttl })
  end
  if opts.max_results then
    require('hex_cmp.api').setup({ max_results = opts.max_results })
  end

  -- On Neovim 0.12+, auto-attach to mix.exs buffers for native completion
  if vim.fn.has('nvim-0.12') == 1 then
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

-- On pre-0.12, return the blink.cmp source with setup/attach mixed in,
-- so module = "hex_cmp" keeps working. On 0.12+, return a plain setup module.
if vim.fn.has('nvim-0.12') == 1 then
  return { setup = setup, attach = attach }
else
  local source = require('hex_cmp.blink')
  source.setup = setup
  source.attach = attach
  return source
end
