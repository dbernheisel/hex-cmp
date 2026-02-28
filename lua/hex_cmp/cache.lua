---@class hex_cmp.CacheConfig
---@field cache_dir? string Override cache directory
---@field ttl integer TTL in seconds (default 600)

---@class hex_cmp.CacheEntry
---@field data any Cached data
---@field timestamp integer Unix timestamp when cached

---@class hex_cmp.Cache
local M = {}

---@type hex_cmp.CacheConfig
local defaults = {
  cache_dir = nil, -- set lazily to vim.fn.stdpath('cache') .. '/hex-cmp'
  ttl = 1800,
}

---@type hex_cmp.CacheConfig
local config = vim.deepcopy(defaults)

---@return string
local function get_cache_dir()
  if not config.cache_dir then
    config.cache_dir = vim.fn.stdpath('cache') .. '/hex-cmp'
  end
  return config.cache_dir
end

--- Sanitize a cache key into a safe filename.
---@param key string
---@return string
local function key_to_filename(key)
  return key:gsub('[^%w_-]', '_') .. '.json'
end

---@param opts? hex_cmp.CacheConfig
function M.setup(opts)
  config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
end

--- Get a cached value by key.
---@param key string
---@return any? data Cached data, or nil on miss
---@return boolean is_stale True if TTL has expired
function M.get(key)
  local dir = get_cache_dir()
  local path = dir .. '/' .. key_to_filename(key)
  local f = io.open(path, 'r')
  if not f then
    return nil, false
  end
  local content = f:read('*a')
  f:close()

  local ok, entry = pcall(vim.json.decode, content)
  if not ok or type(entry) ~= 'table' or not entry.timestamp or not entry.data then
    return nil, false
  end

  local age = os.time() - entry.timestamp
  if age > config.ttl then
    return entry.data, true -- stale
  end
  return entry.data, false -- fresh
end

--- Store a value in the cache.
---@param key string
---@param data any
---@return boolean success
function M.set(key, data)
  local dir = get_cache_dir()
  vim.fn.mkdir(dir, 'p')
  local path = dir .. '/' .. key_to_filename(key)
  local entry = vim.json.encode({ data = data, timestamp = os.time() })
  local f = io.open(path, 'w')
  if not f then
    return false
  end
  f:write(entry)
  f:close()
  return true
end

return M
