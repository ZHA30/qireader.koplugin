local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local ArticleContent = require("qireader.articlecontent")
local QiArticleDetailWidget = require("qireader.articledetail")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local methods = {}
local ARTICLE_CONTENT_JOB_KEY = "article_content"
local CONTENT_PREFETCH_JOB_PREFIX = "article_content_prefetch:"
local PAGE_READ_MARK_JOB_PREFIX = "page_mark_read:"
local READ_MARK_JOB_PREFIX = "article_mark_read:"
local FULL_TEXT_API_URL = "https://nettools3.oxyry.com/text"
local FULL_TEXT_JOB_PREFIX = "article_full_text:"

local function copyEntries(entries)
    local copied = {}
    for i = 1, #(entries or {}) do
        copied[i] = entries[i]
    end
    return copied
end

local function getReadLaterFlag(entry, tag_id)
    if not entry or not tag_id then
        return false
    end
    local tag_ids = entry.tag_ids or {}
    for i = 1, #tag_ids do
        if tag_ids[i] == tag_id then
            return true
        end
    end
    return false
end

local function refreshDetailWidget(widget)
    if widget and not widget.closing and widget.refreshBottomButtons then
        widget:refreshBottomButtons()
        UIManager:setDirty(widget, function()
            return "partial", widget.movable and widget.movable.dimen or widget.frame.dimen
        end)
    end
end

local function hasContentPayload(payload)
    return type(payload) == "table"
        and type(payload.content) == "string"
        and payload.content ~= ""
end

local function buildArticleContent(entry, payload)
    local content = payload and payload.content or entry.summary or ""
    local formatted = ArticleContent.format(entry, content)
    local title = entry.title or (payload and payload.title) or _("Untitled")
    return formatted, title
end

local function buildFullTextContent(entry, payload)
    local content = payload and payload.content or nil
    if type(content) ~= "string" or content == "" then
        return nil
    end
    local formatted = ArticleContent.format(entry, content)
    local title = entry.title or (payload and payload.title) or _("Untitled")
    return formatted, title
end

local function isCurrentDetailWidget(controller, entry, widget)
    return widget
        and not widget.closing
        and widget.entry
        and widget.entry.id == entry.id
        and widget.updateArticleDetail
        and controller.article_detail_widget == widget
end

local function setFullTextState(widget, state, entry_id)
    if widget and not widget.closing and widget.setFullTextState then
        widget:setFullTextState(state, entry_id)
    end
end

local function buildEntryIdsJobKey(prefix, entry_ids)
    local parts = {}
    for i = 1, #entry_ids do
        parts[i] = tostring(entry_ids[i])
    end
    return prefix .. table.concat(parts, ",")
end

local function mapArticleContentPayloads(entries, response)
    local result = response and response.json and response.json.result or {}
    local by_id = {}
    local mapped = {}
    for i = 1, #result do
        local item = result[i]
        if type(item) == "table" and item.id ~= nil then
            by_id[tostring(item.id)] = item
        end
    end
    for i = 1, #entries do
        local entry = entries[i]
        local payload = by_id[tostring(entry.id)] or result[i]
        if hasContentPayload(payload) then
            mapped[tostring(entry.id)] = payload
        end
    end
    return mapped
end

local function getArticlePageTarget(page)
    local first_entry = page and page.entries and page.entries[1] or nil
    return first_entry and first_entry.target or nil
end

local function articlePageHasUnreadEntries(page)
    if not page or not page.entries then
        return false
    end
    for i = 1, #page.entries do
        if page.entries[i].status == 0 then
            return true
        end
    end
    return false
end

function methods:getArticleContentCacheKey(target, entry)
    if not target or not target.stream_id or not entry or not entry.id then
        return nil
    end
    return self:cacheKey("content", target.stream_id, entry.id)
end

function methods:getCachedArticleContent(target, entry)
    return self:readCache(
        self:getArticleContentCacheKey(target, entry),
        self:getCacheTtl("content"),
        not NetworkMgr:isOnline()
    )
end

function methods:cacheArticleContent(target, entry, payload)
    if not hasContentPayload(payload) then
        return
    end
    self:writeCache(self:getArticleContentCacheKey(target, entry), {
        id = payload.id or entry.id,
        title = payload.title,
        content = payload.content,
    })
end

function methods:getFullTextCacheKey(entry)
    if not entry or not entry.url or entry.url == "" then
        return nil
    end
    return self:cacheKey("fulltext", entry.url, "keep-classes=1")
end

function methods:getCachedFullText(entry)
    return self:readCache(
        self:getFullTextCacheKey(entry),
        self:getCacheTtl("fulltext"),
        not NetworkMgr:isOnline()
    )
end

function methods:cacheFullText(entry, payload)
    if hasContentPayload(payload) then
        self:writeCache(self:getFullTextCacheKey(entry), payload)
    end
end

function methods:requestArticleContents(target, entries, job_key, options, callback)
    options = options or {}
    callback = callback or function() end
    if not target or not target.stream_id or not entries or #entries == 0 then
        callback({}, nil)
        return
    end
    if options.background and not NetworkMgr:isOnline() then
        callback(nil, "offline")
        return
    end
    local entry_ids = {}
    for i = 1, #entries do
        local entry = entries[i]
        if entry and entry.id then
            entry_ids[#entry_ids + 1] = entry.id
        end
    end
    if #entry_ids == 0 then
        callback({}, nil)
        return
    end
    local job_token = self:nextJobToken(job_key)
    local job = self:createBackgroundRequest({
        method = "GET",
        path = "/entry-contents",
        query = {
            streamId = target.stream_id,
            entryIds = entry_ids,
        },
    })
    if not job then
        callback(nil, "error")
        return
    end
    self:registerPendingJob(job_key, job)
    local function poll()
        if self.state == "closed"
            or not self:isJobTokenCurrent(job_key, job_token)
            or self.pending_jobs[job_key] ~= job then
            self:cancelPendingJob(job_key, job)
            callback(nil, "cancelled")
            return
        end
        local done, response, err = job:poll()
        if not done then
            UIManager:scheduleIn(0.1, poll)
            return
        end
        self:clearPendingJob(job_key, job)
        if err == "cancelled" then
            callback(nil, "cancelled")
            return
        end
        if self.state == "closed" or not self:isJobTokenCurrent(job_key, job_token) then
            callback(nil, "cancelled")
            return
        end
        self:applyResponseSession(response)
        if response and response.code == 401 then
            self:handleUnauthorized()
            callback(nil, "unauthorized")
            return
        end
        if not response or response.code ~= 200 or not response.json or not response.json.result then
            callback(nil, "error")
            return
        end
        callback(mapArticleContentPayloads(entries, response), nil)
    end
    poll()
end

local function isContentPrefetchOwnerCurrent(controller, target, owner_widget)
    if controller.state == "closed" then
        return false
    end
    if owner_widget then
        return not owner_widget.closing
            and owner_widget.target == target
            and controller.article_widget == owner_widget
    end
    return true
end

function methods:queueArticleContentPrefetch(job_key, target, entries, owner_widget)
    self.content_prefetch_queue = self.content_prefetch_queue or {}
    self.content_prefetch_queue[job_key] = {
        target = target,
        entries = copyEntries(entries),
        owner_widget = owner_widget,
    }
end

function methods:clearQueuedArticleContentPrefetch(target)
    if not self.content_prefetch_queue or not target or not target.stream_id then
        return
    end
    self.content_prefetch_queue[CONTENT_PREFETCH_JOB_PREFIX .. tostring(target.stream_id)] = nil
end

function methods:runQueuedArticleContentPrefetch(job_key)
    local queue = self.content_prefetch_queue
    local queued = queue and queue[job_key] or nil
    if not queued then
        return
    end
    queue[job_key] = nil
    if not isContentPrefetchOwnerCurrent(self, queued.target, queued.owner_widget) then
        return
    end
    self:prefetchArticleContents(queued.target, queued.entries, queued.owner_widget)
end

function methods:prefetchArticleContents(target, entries, owner_widget)
    if not target or not target.stream_id or not entries then
        return
    end
    if not NetworkMgr:isOnline() then
        return
    end
    if not self.cache or not self.cache:isEnabled() then
        return
    end
    if not isContentPrefetchOwnerCurrent(self, target, owner_widget) then
        return
    end
    local missing_entries = {}
    for i = 1, #entries do
        local entry = entries[i]
        if entry and entry.id and not self:getCachedArticleContent(target, entry) then
            missing_entries[#missing_entries + 1] = entry
        end
    end
    if #missing_entries == 0 then
        return
    end
    local job_key = CONTENT_PREFETCH_JOB_PREFIX .. tostring(target.stream_id)
    if self.pending_jobs[job_key] then
        self:queueArticleContentPrefetch(job_key, target, missing_entries, owner_widget)
        return
    end
    self:requestArticleContents(target, missing_entries, job_key, { background = true }, function(payloads, err)
        if err or not payloads then
            if self.content_prefetch_queue then
                self.content_prefetch_queue[job_key] = nil
            end
            return
        end
        if not isContentPrefetchOwnerCurrent(self, target, owner_widget) then
            if self.content_prefetch_queue then
                self.content_prefetch_queue[job_key] = nil
            end
            return
        end
        for i = 1, #missing_entries do
            local entry = missing_entries[i]
            self:cacheArticleContent(target, entry, payloads[tostring(entry.id)])
        end
        self:runQueuedArticleContentPrefetch(job_key)
    end)
end

function methods:showArticleContent(_target, entry, payload, detail_widget)
    self:markArticleRead(entry)
    local formatted, title = buildArticleContent(entry, payload)
    if detail_widget
        and detail_widget.updateArticleDetail
        and not detail_widget.closing
        and self.article_detail_widget == detail_widget then
        detail_widget:updateArticleDetail(entry, formatted, title)
        return
    end
    if self.article_widget then
        self.article_widget:showArticleDetail(entry, formatted)
        return
    end
    local content_widget = QiArticleDetailWidget:new{
        controller = self,
        entry = entry,
        title = title,
        html = formatted,
        on_close_article = function(closed_widget)
            self:onArticleDetailClosed(closed_widget)
        end,
    }
    self.article_detail_widget = content_widget
    UIManager:show(content_widget)
end

function methods:cancelArticleContentLoads(target)
    self:cancelPendingJob(ARTICLE_CONTENT_JOB_KEY)
    if target and target.stream_id then
        self:cancelPendingJob(CONTENT_PREFETCH_JOB_PREFIX .. tostring(target.stream_id))
        self:clearQueuedArticleContentPrefetch(target)
    end
end

function methods:isArticleContentOwnerCurrent(target, detail_widget, owner_widget)
    if self.state == "closed" then
        return false
    end
    if detail_widget then
        return detail_widget.entry
            and not detail_widget.closing
            and detail_widget.updateArticleDetail
            and self.article_detail_widget == detail_widget
    end
    if owner_widget then
        return not owner_widget.closing
            and self.article_widget == owner_widget
            and owner_widget.target == target
    end
    return true
end

function methods:syncReadLaterEntry(entry)
    if not entry then
        return
    end
    entry.is_read_later = getReadLaterFlag(entry, self.readlater_tag_id)
end

function methods:refreshReadLaterWidgets()
    if self.article_widget and self.article_widget.loaded_chunks then
        local loaded_chunks = self.article_widget.loaded_chunks
        for chunk_index in pairs(loaded_chunks) do
            local chunk = loaded_chunks[chunk_index]
            local entries = chunk and chunk.entries or nil
            if entries then
                for i = 1, #entries do
                    self:syncReadLaterEntry(entries[i])
                end
            end
        end
        if not self.article_widget.closing then
            self.article_widget:refresh()
        end
    end
    if self.article_detail_widget and self.article_detail_widget.entry then
        self:syncReadLaterEntry(self.article_detail_widget.entry)
        if not self.article_detail_widget.closing then
            refreshDetailWidget(self.article_detail_widget)
        end
    end
end

function methods:applyReadLaterState(entry, tag_id)
    if not entry then
        return
    end
    entry.tag_ids = entry.tag_ids or {}
    if getReadLaterFlag(entry, tag_id) then
        local filtered = {}
        for i = 1, #entry.tag_ids do
            if entry.tag_ids[i] ~= tag_id then
                filtered[#filtered + 1] = entry.tag_ids[i]
            end
        end
        entry.tag_ids = filtered
    else
        entry.tag_ids[#entry.tag_ids + 1] = tag_id
    end
    self:syncReadLaterEntry(entry)
    self:invalidateStreamCache()
    self:refreshReadLaterWidgets()
end

function methods:loadReadLaterTagId(callback)
    if self.readlater_tag_id then
        if callback then
            callback(self.readlater_tag_id)
        end
        return
    end
    local cached_tag_id = self:readCache(
        self:cacheKey("readlater_tag"),
        self:getCacheTtl("readlater_tag"),
        not NetworkMgr:isOnline()
    )
    if cached_tag_id then
        self.readlater_tag_id = cached_tag_id
        if callback then
            callback(cached_tag_id)
        end
        return
    end
    if callback then
        self.readlater_tag_callbacks = self.readlater_tag_callbacks or {}
        self.readlater_tag_callbacks[#self.readlater_tag_callbacks + 1] = callback
    end
    if not NetworkMgr:isOnline() then
        local callbacks = self.readlater_tag_callbacks or {}
        self.readlater_tag_callbacks = nil
        for i = 1, #callbacks do
            callbacks[i](nil, "offline")
        end
        return
    end
    if self.pending_jobs.readlater_tag then
        return
    end
    local job = self:createBackgroundRequest({
        method = "GET",
        path = "/tags",
    })
    if not job then
        local callbacks = self.readlater_tag_callbacks or {}
        self.readlater_tag_callbacks = nil
        for i = 1, #callbacks do
            callbacks[i](nil, "error")
        end
        return
    end
    local token = self:nextJobToken("readlater_tag")
    self:registerPendingJob("readlater_tag", job)
    local function finish(tag_id, err)
        local callbacks = self.readlater_tag_callbacks or {}
        self.readlater_tag_callbacks = nil
        for i = 1, #callbacks do
            callbacks[i](tag_id, err)
        end
    end
    local function poll()
        if self.state == "closed"
            or not self:isJobTokenCurrent("readlater_tag", token)
            or self.pending_jobs.readlater_tag ~= job then
            self:cancelPendingJob("readlater_tag", job)
            finish(nil, "cancelled")
            return
        end
        local done, response, err = job:poll()
        if not done then
            UIManager:scheduleIn(0.1, poll)
            return
        end
        self:clearPendingJob("readlater_tag", job)
        if err == "cancelled" then
            finish(nil, "cancelled")
            return
        end
        self:applyResponseSession(response)
        if not response then
            finish(nil, "error")
            return
        end
        if response.code == 401 then
            self:handleUnauthorized()
            finish(nil, "unauthorized")
            return
        end
        if response.code ~= 200 or not response.json or not response.json.result then
            finish(nil, "error")
            return
        end
        local tags = response.json.result.tags or {}
        for i = 1, #tags do
            local tag = tags[i]
            if tag.label == "!readlater" then
                self.readlater_tag_id = tag.id
                self:writeCache(self:cacheKey("readlater_tag"), tag.id)
                self:refreshReadLaterWidgets()
                finish(self.readlater_tag_id)
                return
            end
        end
        finish(nil, "missing")
    end
    poll()
end

function methods:onArticleListClosed(widget)
    if self.article_widget == widget then
        self.article_widget = nil
    end
    self:cancelArticleContentLoads(widget and widget.target or nil)
    if widget and widget.closeDetailWidget then
        widget:closeDetailWidget()
    elseif self.article_detail_widget then
        self:cancelArticleFullText(self.article_detail_widget.entry)
        UIManager:close(self.article_detail_widget)
        self.article_detail_widget = nil
    end
    UIManager:close(widget)
    UIManager:nextTick(function()
        self:refreshSubscriptionsAfterArticleListClosed()
    end)
end

function methods:refreshSubscriptionsAfterArticleListClosed()
    if self.state == "closed" or not self.menu then
        return
    end
    local had_local_changes = self.subscriptions_dirty == true
    if had_local_changes then
        self.subscriptions_dirty = false
        self:refreshGroupsPage()
    end
    if had_local_changes or not self.settings.cookie or not NetworkMgr:isOnline() then
        return
    end
    local cached_subscriptions, subscriptions_cache_fresh = self:getSubscriptionsCacheState()
    local cached_tags, tags_cache_fresh = self:getTagsCacheState()
    if cached_subscriptions and subscriptions_cache_fresh and cached_tags and tags_cache_fresh then
        self:startUnreadCountsLoad()
        return
    end
    self.state = "loading"
    if self.setGroupsPlaceholderState then
        self:setGroupsPlaceholderState("loading", _("Loading"))
    end
    if self.updateGroupsPlaceholder then
        self:updateGroupsPlaceholder()
    end
    self:startSubscriptionsLoad({
        silent = true,
        refresh_existing = true,
    })
end

function methods:onArticleDetailClosed(widget)
    if self.article_detail_widget == widget then
        self.article_detail_widget = nil
    end
    self:cancelPendingJob(ARTICLE_CONTENT_JOB_KEY)
    self:cancelArticleFullText(widget and widget.entry or nil)
    UIManager:close(widget)
end

function methods:markPageRead(page)
    if not NetworkMgr:isOnline() then
        return false
    end
    if not page or not page.entries or #page.entries == 0 then
        return false
    end
    local unread_ids = {}
    local unread_entries = {}
    for i = 1, #page.entries do
        local entry = page.entries[i]
        if entry.status == 0 then
            table.insert(unread_ids, entry.id)
            table.insert(unread_entries, entry)
        end
    end
    if #unread_ids == 0 then
        return false
    end
    for i = 1, #page.entries do
        page.entries[i].status = 1
    end
    self:adjustSubscriptionUnreadCounts(unread_entries, -1)
    self:invalidateStreamCache()
    local job = self:createBackgroundRequest({
        method = "PUT",
        path = "/markers/reads",
        body = {
            type = "entries",
            entryIds = unread_ids,
        },
    })
    if not job then
        return true
    end
    local job_key = buildEntryIdsJobKey(PAGE_READ_MARK_JOB_PREFIX, unread_ids)
    local job_token = self:nextJobToken(job_key)
    self:registerPendingJob(job_key, job)
    local function poll()
        if self.state == "closed"
            or not self:isJobTokenCurrent(job_key, job_token)
            or self.pending_jobs[job_key] ~= job then
            self:cancelPendingJob(job_key, job)
            return
        end
        local done, response, err = job:poll()
        if not done then
            UIManager:scheduleIn(0.1, poll)
            return
        end
        self:clearPendingJob(job_key, job)
        if err == "cancelled" then
            return
        end
        if self.state == "closed" or not self:isJobTokenCurrent(job_key, job_token) then
            return
        end
        self:applyResponseSession(response)
        if response and response.code == 401 then
            self:handleUnauthorized()
        end
    end
    poll()
    return true
end

function methods:maybeMarkArticlePageRead(page)
    local target = getArticlePageTarget(page)
    if not page
        or self:isArticleTagTarget(target)
        or self:getArticleSetting(target, "mark_read_on_page_turn") ~= true then
        return false
    end
    return self:markPageRead(page)
end

function methods:canMarkArticlePageRead(page)
    local target = getArticlePageTarget(page)
    return NetworkMgr:isOnline()
        and not self:isArticleTagTarget(target)
        and self:getArticleSetting(target, "mark_read_on_page_turn") == true
        and articlePageHasUnreadEntries(page)
end

function methods:applyArticleReadState(entry)
    if not entry or not entry.id then
        return false
    end
    local entry_id = entry.id
    local changed = false
    if entry.status == 0 then
        entry.status = 1
        changed = true
    end
    if self.article_widget and self.article_widget.loaded_chunks then
        local loaded_chunks = self.article_widget.loaded_chunks
        for chunk_index in pairs(loaded_chunks) do
            local chunk = loaded_chunks[chunk_index]
            local entries = chunk and chunk.entries or nil
            if entries then
                for i = 1, #entries do
                    local item = entries[i]
                    if item.id == entry_id and item.status == 0 then
                        item.status = 1
                        changed = true
                    end
                end
            end
        end
        if changed and not self.article_widget.closing then
            self.article_widget:refresh()
        end
    end
    if self.article_detail_widget
        and self.article_detail_widget.entry
        and self.article_detail_widget.entry.id == entry_id
        and self.article_detail_widget.entry.status == 0 then
        self.article_detail_widget.entry.status = 1
        changed = true
    end
    if changed then
        self:adjustSubscriptionUnreadCounts({ entry }, -1)
        self:invalidateStreamCache()
    end
    return changed
end

function methods:markArticleRead(entry)
    if not NetworkMgr:isOnline() then
        return
    end
    if not self:applyArticleReadState(entry) then
        return
    end
    local job_key = READ_MARK_JOB_PREFIX .. tostring(entry.id)
    local job_token = self:nextJobToken(job_key)
    local job = self:createBackgroundRequest({
        method = "PUT",
        path = "/markers/reads",
        body = {
            type = "entries",
            entryIds = { entry.id },
        },
    })
    if not job then
        return
    end
    self:registerPendingJob(job_key, job)
    local function poll()
        if self.state == "closed"
            or not self:isJobTokenCurrent(job_key, job_token)
            or self.pending_jobs[job_key] ~= job then
            self:cancelPendingJob(job_key, job)
            return
        end
        local done, response, err = job:poll()
        if not done then
            UIManager:scheduleIn(0.1, poll)
            return
        end
        self:clearPendingJob(job_key, job)
        if err == "cancelled" then
            return
        end
        if self.state == "closed" or not self:isJobTokenCurrent(job_key, job_token) then
            return
        end
        self:applyResponseSession(response)
        if response and response.code == 401 then
            self:handleUnauthorized()
        end
    end
    poll()
end

function methods:markArticleUnread(entry)
    if not NetworkMgr:isOnline() or not entry or not entry.id or entry.status == 0 then
        return
    end

    entry.status = 0
    if self.article_widget and not self.article_widget.closing then
        self.article_widget:refresh()
    end
    if self.article_detail_widget
        and self.article_detail_widget.entry
        and self.article_detail_widget.entry.id == entry.id then
        self.article_detail_widget.entry.status = 0
    end
    self:adjustSubscriptionUnreadCounts({ entry }, 1)
    self:invalidateStreamCache()

    local job_key = READ_MARK_JOB_PREFIX .. tostring(entry.id) .. ":unread"
    local job_token = self:nextJobToken(job_key)
    local job = self:createBackgroundRequest({
        method = "DELETE",
        path = "/markers/reads",
        body = {
            type = "entries",
            entryIds = { entry.id },
        },
    })
    if not job then
        return
    end
    self:registerPendingJob(job_key, job)
    local function poll()
        if self.state == "closed"
            or not self:isJobTokenCurrent(job_key, job_token)
            or self.pending_jobs[job_key] ~= job then
            self:cancelPendingJob(job_key, job)
            return
        end
        local done, response, err = job:poll()
        if not done then
            UIManager:scheduleIn(0.1, poll)
            return
        end
        self:clearPendingJob(job_key, job)
        if err == "cancelled" then
            return
        end
        if self.state == "closed" or not self:isJobTokenCurrent(job_key, job_token) then
            return
        end
        self:applyResponseSession(response)
        if response and response.code == 401 then
            self:handleUnauthorized()
        end
    end
    poll()
end

function methods:toggleArticleReadState(entry)
    if not NetworkMgr:isOnline() then
        return
    end
    if not entry then
        return
    end
    if entry.status == 0 then
        self:markArticleRead(entry)
    else
        self:markArticleUnread(entry)
    end
end

function methods:toggleReadLater(entry, widget)
    if not NetworkMgr:isOnline() then
        self:showTransientMessage(_("Cannot update read-later state."))
        return
    end
    self:loadReadLaterTagId(function(tag_id, tag_err)
        if not tag_id then
            if tag_err ~= "cancelled" and tag_err ~= "unauthorized" then
                self:showTransientMessage(_("Cannot resolve read-later tag."))
            end
            return
        end
        local job_key = "toggle_read_later:" .. tostring(entry.id)
        local job_token = self:nextJobToken(job_key)
        local job = self:createBackgroundRequest({
            method = entry.is_read_later and "DELETE" or "PUT",
            path = entry.is_read_later
                and ("/entries/feed/" .. tostring(entry.id) .. "/tags/" .. tostring(tag_id))
                or ("/entries/" .. tostring(entry.id) .. "/tags/" .. tostring(tag_id)),
            body = {
                entryType = "feed",
                entryId = entry.id,
                tagId = tag_id,
            },
        })
        if not job then
            self:showTransientMessage(_("Cannot update read-later state."))
            return
        end
        self:registerPendingJob(job_key, job)
        local function poll()
            if self.state == "closed"
                or not self:isJobTokenCurrent(job_key, job_token)
                or self.pending_jobs[job_key] ~= job then
                self:cancelPendingJob(job_key, job)
                return
            end
            local done, response, err = job:poll()
            if not done then
                UIManager:scheduleIn(0.1, poll)
                return
            end
            self:clearPendingJob(job_key, job)
            if err == "cancelled" then
                return
            end
            if self.state == "closed" or not self:isJobTokenCurrent(job_key, job_token) then
                return
            end
            self:applyResponseSession(response)
            if not response then
                self:showTransientMessage(_("Cannot update read-later state."))
                return
            end
            if response.code == 401 then
                self:handleUnauthorized()
                return
            end
            if response.code ~= 200 then
                self:showTransientMessage(_("Cannot update read-later state."))
                return
            end
            self:applyReadLaterState(entry, tag_id)
            if widget and widget ~= self.article_detail_widget and widget.refreshBottomButtons then
                refreshDetailWidget(widget)
            end
        end
        poll()
    end)
end

function methods:cancelArticleFullText(entry)
    if entry and entry.id then
        self:cancelPendingJob(FULL_TEXT_JOB_PREFIX .. tostring(entry.id))
    end
end

function methods:loadArticleFullText(entry, detail_widget)
    if not entry or not entry.url or entry.url == "" then
        setFullTextState(detail_widget, "error", entry and entry.id or nil)
        self:showTransientMessage(_("Cannot load full article."))
        return
    end
    if not isCurrentDetailWidget(self, entry, detail_widget) then
        return
    end
    local cached_payload = self:getCachedFullText(entry)
    if cached_payload then
        local formatted, title = buildFullTextContent(entry, cached_payload)
        if formatted then
            detail_widget:updateArticleDetail(entry, formatted, title)
            setFullTextState(detail_widget, "loaded", entry.id)
            return
        end
    end
    if NetworkMgr and NetworkMgr.willRerunWhenOnline
        and NetworkMgr:willRerunWhenOnline(function()
            self:loadArticleFullText(entry, detail_widget)
        end) then
        return
    end
    if not isCurrentDetailWidget(self, entry, detail_widget) then
        return
    end

    local job_key = FULL_TEXT_JOB_PREFIX .. tostring(entry.id)
    local job_token = self:nextJobToken(job_key)
    setFullTextState(detail_widget, "loading", entry.id)

    local job = self:createBackgroundRequest({
        method = "GET",
        url = FULL_TEXT_API_URL,
        query = {
            url = entry.url,
            ["keep-classes"] = "1",
        },
        headers = {
            ["Referer"] = "https://www.qireader.com/",
        },
        use_session = false,
    })
    if not job then
        setFullTextState(detail_widget, "error", entry.id)
        self:showTransientMessage(_("Cannot load full article."))
        return
    end
    self:registerPendingJob(job_key, job)

    local function poll()
        if self.state == "closed"
            or not self:isJobTokenCurrent(job_key, job_token)
            or self.pending_jobs[job_key] ~= job
            or not isCurrentDetailWidget(self, entry, detail_widget) then
            self:cancelPendingJob(job_key, job)
            return
        end
        local done, response, err = job:poll()
        if not done then
            UIManager:scheduleIn(0.1, poll)
            return
        end
        self:clearPendingJob(job_key, job)
        if err == "cancelled" then
            return
        end
        if self.state == "closed"
            or not self:isJobTokenCurrent(job_key, job_token)
            or not isCurrentDetailWidget(self, entry, detail_widget) then
            return
        end
        if not response or response.code ~= 200 then
            setFullTextState(detail_widget, "error", entry.id)
            self:showTransientMessage(_("Cannot load full article."))
            return
        end
        self:cacheFullText(entry, response.json)
        local formatted, title = buildFullTextContent(entry, response.json)
        if not formatted then
            setFullTextState(detail_widget, "error", entry.id)
            self:showTransientMessage(_("Cannot load full article."))
            return
        end
        detail_widget:updateArticleDetail(entry, formatted, title)
        setFullTextState(detail_widget, "loaded", entry.id)
    end
    poll()
end

function methods:openArticleContent(target, entry, detail_widget, owner_widget)
    if detail_widget
        and detail_widget.entry
        and entry
        and detail_widget.entry.id ~= entry.id then
        self:cancelArticleFullText(detail_widget.entry)
        if detail_widget.setFullTextState then
            detail_widget:setFullTextState("idle", detail_widget.entry.id)
        end
    end
    owner_widget = owner_widget or (detail_widget and detail_widget.owner_widget) or self.article_widget
    if not self:isArticleContentOwnerCurrent(target, detail_widget, owner_widget) then
        return
    end
    if not entry or not entry.id then
        return
    end
    local cached_payload = self:getCachedArticleContent(target, entry)
    if cached_payload then
        self:showArticleContent(target, entry, cached_payload, detail_widget)
        return
    end
    if NetworkMgr and NetworkMgr.willRerunWhenOnline
        and NetworkMgr:willRerunWhenOnline(function()
            self:openArticleContent(target, entry, detail_widget, owner_widget)
        end) then
        return
    end
    local missing_entries = { entry }
    self:requestArticleContents(target, missing_entries, ARTICLE_CONTENT_JOB_KEY, nil, function(payloads, err)
        if err == "cancelled" or err == "unauthorized" then
            return
        end
        if not self:isArticleContentOwnerCurrent(target, detail_widget, owner_widget) then
            return
        end
        if err or not payloads then
            self:showTransientMessage(_("Cannot load article content."))
            return
        end
        self:cacheArticleContent(target, entry, payloads[tostring(entry.id)])
        local payload = payloads[tostring(entry.id)] or self:getCachedArticleContent(target, entry)
        if not payload then
            self:showTransientMessage(_("Cannot load article content."))
            return
        end
        self:showArticleContent(target, entry, payload, detail_widget)
    end)
end

return methods
