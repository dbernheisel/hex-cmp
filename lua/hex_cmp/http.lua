--- HTTP abstraction layer for hex-cmp.
---
--- On Neovim >= 0.12, uses the built-in vim.net.request() for native HTTP.
--- On older versions, falls back to shelling out to curl via vim.system().
---@class hex_cmp.Http
local M = {}

--- Whether the native Neovim HTTP client is available (0.12+).
--- vim.net.request(url, opts?, callback?) shells out to curl internally
--- but provides a nicer Lua API with retry support.
---@type boolean
M.has_native = vim.fn.has('nvim-0.12') == 1
  and type(vim.net) == 'table'
  and type(vim.net.request) == 'function'

--- Perform an async GET request and return parsed JSON via callback.
---@param url string
---@param headers? table<string, string> Additional headers
---@param callback fun(data: any?, err: string?)
function M.get(url, headers, callback)
  if M.has_native then
    M._get_native(url, headers, callback)
  else
    M._get_curl(url, headers, callback)
  end
end

--- Native HTTP implementation using vim.net.request (Neovim 0.12+).
--- Signature: vim.net.request(url, opts?, on_response?)
--- The response callback receives (err?: string, response?: {body: string}).
--- Note: vim.net.request does not support custom headers — they are ignored here.
---@param url string
---@param headers? table<string, string> Ignored (vim.net.request doesn't support headers)
---@param callback fun(data: any?, err: string?)
function M._get_native(url, headers, callback)
  vim.net.request(url, {}, function(err, response)
    vim.schedule(function()
      if err then
        callback(nil, 'HTTP request failed: ' .. tostring(err))
        return
      end
      if not response or not response.body or response.body == '' then
        callback(nil, 'empty response')
        return
      end
      local ok, data = pcall(vim.json.decode, response.body)
      if not ok then
        callback(nil, 'JSON decode failed: ' .. tostring(data))
        return
      end
      callback(data, nil)
    end)
  end)
end

--- Curl fallback implementation using vim.system().
---@param url string
---@param headers? table<string, string>
---@param callback fun(data: any?, err: string?)
function M._get_curl(url, headers, callback)
  local cmd = { 'curl', '-sS' }
  if headers then
    for k, v in pairs(headers) do
      table.insert(cmd, '-H')
      table.insert(cmd, k .. ': ' .. v)
    end
  end
  table.insert(cmd, url)

  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, 'curl exited with code ' .. result.code .. ': ' .. (result.stderr or ''))
        return
      end
      if not result.stdout or result.stdout == '' then
        callback(nil, 'empty response')
        return
      end
      local ok, data = pcall(vim.json.decode, result.stdout)
      if not ok then
        callback(nil, 'JSON decode failed: ' .. tostring(data))
        return
      end
      callback(data, nil)
    end)
  end)
end

--- Check connectivity to hex.pm API (for health checks).
--- Uses native HTTP on 0.12+, curl otherwise.
---@return boolean reachable
function M.check_connectivity()
  local test_url = 'https://hex.pm/api/packages?search=name:phoenix&per_page=1'

  if M.has_native then
    -- Synchronous check using native HTTP
    local ok = false
    local done = false

    vim.net.request(test_url, {}, function(err, response)
      if not err and response and response.body and response.body ~= '' then
        ok = true
      end
      done = true
    end)

    -- Wait up to 5 seconds
    vim.wait(5000, function() return done end, 50)
    return ok
  else
    local result = vim.system(
      { 'curl', '-sS', '-o', '/dev/null', '-w', '%{http_code}', test_url },
      { text = true }
    ):wait(5000)
    return result.code == 0 and result.stdout == '200'
  end
end

return M
