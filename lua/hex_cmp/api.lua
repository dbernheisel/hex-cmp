local cache = require('hex_cmp.cache')
local http = require('hex_cmp.http')

---@class hex_cmp.ApiConfig
---@field max_results integer Max search results (default 50)
---@field user_agent string HTTP User-Agent header

---@class hex_cmp.HexPackage
---@field name string Package name
---@field latest_stable_version? string
---@field latest_version? string
---@field meta? hex_cmp.HexMeta
---@field downloads? hex_cmp.HexDownloads
---@field releases? hex_cmp.HexRelease[]
---@field retirements? table<string, hex_cmp.HexRetirement>

---@class hex_cmp.HexMeta
---@field description? string
---@field licenses? string[]
---@field links? table<string, string>

---@class hex_cmp.HexDownloads
---@field all? integer
---@field recent? integer

---@class hex_cmp.HexRelease
---@field version string
---@field inserted_at? string ISO 8601 timestamp
---@field has_docs? boolean

---@class hex_cmp.HexRetirement
---@field reason? string
---@field message? string

---@class hex_cmp.Api
local M = {}

---@type hex_cmp.ApiConfig
local defaults = {
  max_results = 50,
  user_agent = 'hex-cmp-nvim (https://github.com/dbernheisel/hex-cmp)',
}

---@type hex_cmp.ApiConfig
local config = vim.deepcopy(defaults)

---@param opts? hex_cmp.ApiConfig
function M.setup(opts)
  config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
end

---@param str string
---@return string
local function url_encode(str)
  return str:gsub('[^%w_.-~]', function(c)
    return string.format('%%%02X', string.byte(c))
  end)
end

--- Perform an async GET request against the hex.pm API and return parsed JSON.
--- Uses native HTTP on Neovim 0.12+, falls back to curl on older versions.
---@param url string
---@param callback fun(data: any?, err: string?)
local function fetch(url, callback)
  http.get(url, { ['User-Agent'] = config.user_agent }, callback)
end

--- Search hex.pm packages by name prefix.
---@param query string
---@param callback fun(packages: hex_cmp.HexPackage[])
function M.search_packages(query, callback)
  if not query or query == '' then
    callback({})
    return
  end

  local cache_key = 'search_' .. query
  local cached, is_stale = cache.get(cache_key)
  if cached and not is_stale then
    callback(cached)
    return
  end

  local url = string.format(
    'https://hex.pm/api/packages?search=name:%s*&sort=downloads&per_page=%d',
    url_encode(query),
    config.max_results
  )

  fetch(url, function(data, err)
    if data and type(data) == 'table' then
      cache.set(cache_key, data)
      callback(data)
    elseif cached then
      callback(cached)
    else
      if err then
        vim.notify('[hex-cmp] ' .. err, vim.log.levels.WARN)
      end
      callback({})
    end
  end)
end

--- Get a specific package's details (including all releases).
---@param name string
---@param callback fun(package: hex_cmp.HexPackage?)
function M.get_package(name, callback)
  if not name or name == '' then
    callback(nil)
    return
  end

  local cache_key = 'pkg_' .. name
  local cached, is_stale = cache.get(cache_key)
  if cached and not is_stale then
    callback(cached)
    return
  end

  local url = 'https://hex.pm/api/packages/' .. url_encode(name)

  fetch(url, function(data, err)
    if data and type(data) == 'table' and data.name then
      cache.set(cache_key, data)
      callback(data)
    elseif cached then
      callback(cached)
    else
      callback(nil)
    end
  end)
end

return M
