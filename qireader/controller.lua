local Background = require("qireader.background")
local Cache = require("qireader.cache")
local settings_methods = require("qireader.controller.settings")
local article_methods = require("qireader.controller.articles")
local tag_methods = require("qireader.controller.tags")
local menu_methods = require("qireader.controller.menu")
local session_methods = require("qireader.controller.session")
local subscription_methods = require("qireader.controller.subscriptions")
local UIManager = require("ui/uimanager")

local Controller = {}
Controller.__index = Controller
local STREAM_CACHE_GENERATION_SAVE_DELAY = 2

local function installMethods(target, methods)
    for name, value in pairs(methods) do
        target[name] = value
    end
end

function Controller.new(args)
    return setmetatable({
        plugin = args.plugin,
        settings = args.settings,
        save_settings = args.save_settings,
        login_fields = {
            email = "",
            password = "",
        },
        groups = nil,
        ungrouped = nil,
        subscriptions = nil,
        subscription_by_feed_id = nil,
        subscription_by_id = nil,
        subscription_title_by_feed_id = nil,
        subscription_title_by_id = nil,
        tags = nil,
        regular_tag_ids = nil,
        tags_popover_width = nil,
        tags_popover_signature = nil,
        expanded_groups = {},
        expanded_tags = false,
        state = "closed",
        active_dialog = nil,
        login_dialog = nil,
        article_widget = nil,
        article_detail_widget = nil,
        readlater_tag = nil,
        readlater_tag_id = nil,
        readlater_tag_callbacks = nil,
        pending_jobs = {},
        job_tokens = {},
        pending_read_entry_ids = {},
        pending_unread_entry_ids = {},
        marker_outbox_flush_scheduled = false,
        content_prefetch_queue = {},
        stream_cache_generation = tonumber(args.settings.stream_cache_generation) or 0,
        stream_cache_generation_dirty = false,
        stream_cache_generation_save_scheduled = false,
        cache = Cache.new(args.settings.cache),
    }, Controller)
end

function Controller:nextJobToken(key)
    self.job_tokens[key] = (self.job_tokens[key] or 0) + 1
    return self.job_tokens[key]
end

function Controller:isJobTokenCurrent(key, token)
    return self.job_tokens[key] == token
end

function Controller:invalidateJobToken(key)
    self.job_tokens[key] = (self.job_tokens[key] or 0) + 1
end

function Controller:invalidateAllJobTokens()
    for key in pairs(self.job_tokens) do
        self:invalidateJobToken(key)
    end
end

function Controller:createBackgroundRequest(request_spec)
    return Background.new({
        api_base = self.settings.api_base,
        cookie = self.settings.cookie,
    }, request_spec)
end

function Controller:registerPendingJob(key, job)
    if self.pending_jobs[key] and self.pending_jobs[key].cancel then
        self.pending_jobs[key]:cancel()
    end
    self.pending_jobs[key] = job
end

function Controller:clearPendingJob(key, job)
    if job and self.pending_jobs[key] ~= job then
        return
    end
    self.pending_jobs[key] = nil
end

function Controller:cancelPendingJob(key, job)
    local pending_job = self.pending_jobs[key]
    if job and pending_job ~= job then
        if job.cancel then
            job:cancel()
        end
        return
    end
    self:invalidateJobToken(key)
    if pending_job and pending_job.cancel then
        pending_job:cancel()
    end
    self.pending_jobs[key] = nil
end

function Controller:cancelAllPendingJobs()
    for key, job in pairs(self.pending_jobs) do
        self:invalidateJobToken(key)
        if job and job.cancel then
            job:cancel()
        end
        self.pending_jobs[key] = nil
    end
    self.content_prefetch_queue = {}
    self.pending_read_entry_ids = {}
    self.pending_unread_entry_ids = {}
    self.marker_outbox_flush_scheduled = false
end

function Controller:applyResponseSession(response)
    if response and response.cookie and response.cookie ~= "" then
        self.settings.cookie = response.cookie
    end
end

function Controller:getCacheUserId()
    local user = self.settings.user
    if type(user) ~= "table" or user.id == nil or user.id == "" then
        return nil
    end
    return tostring(user.id)
end

function Controller:cacheKey(kind, ...)
    if not self.cache or not self.cache:isEnabled() then
        return nil
    end
    local user_id = self:getCacheUserId()
    if not user_id then
        return nil
    end
    return self.cache:key(kind, "v1", self.settings.api_base or "", user_id, ...)
end

function Controller:readCache(key, ttl, allow_stale)
    if not self.cache then
        return nil
    end
    return self.cache:get(key, ttl, allow_stale)
end

function Controller:writeCache(key, payload)
    if self.cache then
        return self.cache:put(key, payload)
    end
    return false
end

function Controller:removeCache(key)
    if self.cache then
        self.cache:remove(key)
    end
end

function Controller:clearCache()
    if self.cache then
        self.cache:clear()
    end
end

function Controller:getCacheTtl(name)
    local cache_settings = self.settings.cache or {}
    return cache_settings[name .. "_ttl"]
end

function Controller:getStreamCacheGeneration()
    if self.stream_cache_generation ~= nil then
        return tonumber(self.stream_cache_generation) or 0
    end
    self.stream_cache_generation = tonumber(self.settings.stream_cache_generation) or 0
    return self.stream_cache_generation
end

function Controller:flushStreamCacheGeneration()
    if not self.stream_cache_generation_dirty then
        return false
    end
    self.settings.stream_cache_generation = self:getStreamCacheGeneration()
    self.stream_cache_generation_dirty = false
    if self.save_settings then
        self.save_settings()
    end
    return true
end

function Controller:resetStreamCacheGeneration(value)
    self.stream_cache_generation = tonumber(value) or 0
    self.settings.stream_cache_generation = self.stream_cache_generation
    self.stream_cache_generation_dirty = false
    self.stream_cache_generation_save_scheduled = false
end

function Controller:invalidateStreamCache()
    self.stream_cache_generation = self:getStreamCacheGeneration() + 1
    self.settings.stream_cache_generation = self.stream_cache_generation
    self.stream_cache_generation_dirty = true
    if self.stream_cache_generation_save_scheduled then
        return
    end
    self.stream_cache_generation_save_scheduled = true
    UIManager:scheduleIn(STREAM_CACHE_GENERATION_SAVE_DELAY, function()
        self.stream_cache_generation_save_scheduled = false
        self:flushStreamCacheGeneration()
    end)
end

installMethods(Controller, settings_methods)
installMethods(Controller, article_methods)
installMethods(Controller, tag_methods)
installMethods(Controller, menu_methods)
installMethods(Controller, session_methods)
installMethods(Controller, subscription_methods)

return Controller
