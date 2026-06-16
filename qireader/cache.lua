local CacheSQLite = require("cachesqlite")
local DataStorage = require("datastorage")
local ffiutil = require("ffi/util")
local util = require("util")

local Cache = {}
Cache.__index = Cache

local CACHE_DIR = DataStorage:getDataDir() .. "/cache"
local CACHE_PATH = CACHE_DIR .. "/qireader.sqlite"
local BACKGROUND_RESULT_DIR = CACHE_DIR .. "/qireader-background"

local function escapeComponent(value)
    return tostring(value or "")
        :gsub("%%", "%%25")
        :gsub(":", "%%3A")
        :gsub("\n", "%%0A")
end

local function normalizeSize(size_mb)
    size_mb = tonumber(size_mb) or 20
    if size_mb < 1 then
        size_mb = 1
    end
    return math.floor(size_mb * 1024 * 1024)
end

function Cache.new(settings)
    settings = settings or {}
    local self = setmetatable({
        enabled = settings.enabled ~= false,
        size = normalizeSize(settings.size_mb),
        store = nil,
    }, Cache)
    self:init()
    return self
end

function Cache:init()
    if not self.enabled then
        return
    end
    local ok = util.makePath(CACHE_DIR)
    if not ok then
        self.enabled = false
        return
    end
    local created, store = pcall(CacheSQLite.new, CacheSQLite, {
        db_path = CACHE_PATH,
        size = self.size,
    })
    if not created then
        self.enabled = false
        return
    end
    self.store = store
end

function Cache:isEnabled()
    return self.enabled and self.store ~= nil
end

function Cache.key(_self, ...)
    local parts = {}
    local count = select("#", ...)
    for i = 1, count do
        parts[i] = escapeComponent(select(i, ...))
    end
    return table.concat(parts, ":")
end

function Cache:put(key, payload)
    if not self:isEnabled() or not key or payload == nil then
        return false
    end
    local entry = {
        saved_at = os.time(),
        payload = payload,
    }
    local ok, inserted = pcall(function()
        self.store:remove(key)
        return self.store:insert(key, entry)
    end)
    return ok and inserted == true
end

function Cache:get(key, ttl, allow_stale)
    if not self:isEnabled() or not key then
        return nil
    end
    local ok, entry = pcall(function()
        return self.store:check(key)
    end)
    if not ok or type(entry) ~= "table" then
        return nil
    end
    local saved_at = tonumber(entry.saved_at) or 0
    local payload = entry.payload
    if payload == nil then
        return nil
    end
    if ttl == nil or ttl <= 0 or os.time() - saved_at <= ttl then
        return payload, true
    end
    if allow_stale then
        return payload, false
    end
    return nil
end

function Cache:remove(key)
    if not self:isEnabled() or not key then
        return
    end
    pcall(function()
        self.store:remove(key)
    end)
end

function Cache:clear()
    if not self:isEnabled() then
        return
    end
    pcall(function()
        self.store:clear()
    end)
end

function Cache.deleteStorage()
    os.remove(CACHE_PATH)
    os.remove(CACHE_PATH .. "-wal")
    os.remove(CACHE_PATH .. "-shm")
    ffiutil.purgeDir(BACKGROUND_RESULT_DIR)
end

return Cache
