---@class hex_cmp.Health
local M = {}

--- Run :checkhealth hex_cmp diagnostics.
M.check = function()
  vim.health.start('hex-cmp')

  -- Check Neovim version
  if vim.fn.has('nvim-0.10') == 1 then
    vim.health.ok('Neovim >= 0.10')
  else
    vim.health.error('Neovim >= 0.10 required', 'Upgrade Neovim to 0.10 or later')
  end

  -- Check curl
  if vim.fn.executable('curl') == 1 then
    vim.health.ok('curl found on PATH')
  else
    vim.health.error('curl not found on PATH', 'Install curl')
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
  local blink_ok = pcall(require, 'blink.cmp')
  local cmp_ok = pcall(require, 'cmp')
  if blink_ok then
    vim.health.ok('blink.cmp installed')
  elseif cmp_ok then
    vim.health.warn('nvim-cmp detected (hex-cmp is built for blink.cmp)', 'Consider using saghen/blink.compat or switching to blink.cmp')
  else
    vim.health.error('No completion framework found', 'Install saghen/blink.cmp')
  end

  -- Check hex.pm API connectivity
  local result = vim.system(
    { 'curl', '-sS', '-o', '/dev/null', '-w', '%{http_code}', 'https://hex.pm/api/packages?search=name:phoenix&per_page=1' },
    { text = true }
  ):wait(5000)

  if result.code == 0 and result.stdout == '200' then
    vim.health.ok('hex.pm API reachable')
  else
    vim.health.warn(
      'hex.pm API not reachable (completions will use cache if available)',
      'Check your internet connection'
    )
  end
end

return M
