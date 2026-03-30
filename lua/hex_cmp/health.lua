---@class hex_cmp.Health
local M = {}

local http = require('hex_cmp.http')

--- Run :checkhealth hex_cmp diagnostics.
M.check = function()
  vim.health.start('hex-cmp')

  -- Check Neovim version
  local has_012 = vim.fn.has('nvim-0.12') == 1
  if has_012 then
    vim.health.ok('Neovim >= 0.12 (native HTTP and inline completion available)')
  elseif vim.fn.has('nvim-0.10') == 1 then
    vim.health.ok('Neovim >= 0.10')
    vim.health.info('Upgrade to Neovim 0.12 for native HTTP and built-in completion (no blink.cmp needed)')
  else
    vim.health.error('Neovim >= 0.10 required', 'Upgrade Neovim to 0.10 or later')
  end

  -- Check HTTP transport
  if http.has_native then
    vim.health.ok('Native HTTP available (vim.net.request)')
  elseif vim.fn.executable('curl') == 1 then
    vim.health.ok('curl found on PATH (fallback transport)')
  else
    vim.health.error('No HTTP transport available', {
      'Upgrade to Neovim 0.12 for native HTTP support, or install curl',
    })
  end

  -- Check tree-sitter-elixir
  local ts_ok = pcall(vim.treesitter.language.inspect, 'elixir')
  if ts_ok then
    vim.health.ok('tree-sitter-elixir parser installed')
  else
    vim.health.error(
      'tree-sitter-elixir parser not installed',
      'Run :TSInstall elixir (requires nvim-treesitter)'
    )
  end

  -- Check completion framework
  if has_012 then
    vim.health.ok('Neovim 0.12 built-in completion available')
    local blink_ok = pcall(require, 'blink.cmp')
    if blink_ok then
      vim.health.info('blink.cmp also installed (hex_cmp/init.lua blink source still works)')
    end
  else
    local blink_ok = pcall(require, 'blink.cmp')
    local cmp_ok = pcall(require, 'cmp')
    if blink_ok then
      vim.health.ok('blink.cmp installed')
    elseif cmp_ok then
      vim.health.warn('nvim-cmp detected (hex-cmp is built for blink.cmp)', 'Consider using saghen/blink.compat or switching to blink.cmp')
    else
      vim.health.error('No completion framework found', 'Install saghen/blink.cmp or upgrade to Neovim 0.12')
    end
  end

  -- Check hex.pm API connectivity
  local reachable = http.check_connectivity()
  if reachable then
    vim.health.ok('hex.pm API reachable')
  else
    vim.health.warn(
      'hex.pm API not reachable (completions will use cache if available)',
      'Check your internet connection'
    )
  end
end

return M
