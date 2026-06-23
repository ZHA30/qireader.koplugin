local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local ArticleContent = require("qireader.articlecontent")
local QiArticleDetailWidget = require("qireader.articledetail")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local methods = {}
local ARTICLE_CONTENT_JOB_KEY = "article_content"
local PAGE_READ_MARK_JOB_PREFIX = "page_mark_read:"
local MARKER_OUTBOX_READ_JOB_PREFIX = "marker_outbox_read:"
local MARKER_OUTBOX_UNREAD_JOB_PREFIX = "marker_outbox_unread:"
local MARKER_OUTBOX_FLUSH_DELAY = 2
local FULL_TEXT_API_URL = "https://nettools3.oxyry.com/text"
local FULL_TEXT_JOB_PREFIX = "article_full_text:"

local function hasContentPayload(payload)
    return type(payload) == "table"
        and type(payload.content) == "string"
        and payload.content ~= ""
end

local function sameEntryId(left, right)
    return left ~= nil and right ~= nil and tostring(left) == tostring(right)
end

local function getFormattedContent(payload)
    if type(payload) ~= "table" then
        return nil
    end
    if type(payload.formatted_content) == "string" and payload.formatted_content ~= "" then
        return payload.formatted_content
    end
    return nil
end

local function buildArticleContent(entry, payload)
    local formatted = getFormattedContent(payload)
    if not formatted then
        local content = payload and payload.content or entry.summary or ""
        formatted = ArticleContent.format(entry, content)
    end
    local title = entry.title or (payload and payload.title) or _("Untitled")
    return formatted, title
end

local function buildFullTextContent(entry, payload)
    local formatted = getFormattedContent(payload)
    if not formatted then
        local content = payload and payload.content or nil
        if type(content) ~= "string" or content == "" then
            return nil
        end
        formatted = ArticleContent.format(entry, content)
    end
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
        local payload = by_id[tostring(entry.id)]
        if hasContentPayload(payload) then
            mapped[tostring(entry.id)] = payload
        elseif #entries == 1 and #result == 1 then
            local single_payload = result[1]
            if hasContentPayload(single_payload)
                and (single_payload.id == nil or sameEntryId(single_payload.id, entry.id)) then
                mapped[tostring(entry.id)] = single_payload
            end
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

local function addPendingEntryId(queue, entry_id)
    if not queue or entry_id == nil then
        return
    end
    queue[tostring(entry_id)] = entry_id
end

local function drainPendingEntryIds(queue)
    local entry_ids = {}
    for key, entry_id in pairs(queue or {}) do
        entry_ids[#entry_ids + 1] = entry_id
        queue[key] = nil
    end
    table.sort(entry_ids, function(left, right)
        return tostring(left) < tostring(right)
    end)
    return entry_ids
end

local function hasPendingEntryIds(queue)
    return next(queue or {}) ~= nil
end

function methods:getArticleContentCacheKey(target, entry)
    if not target or not target.stream_id or not entry or not entry.id then
        return nil
    end
    return self:cacheKey("content", target.stream_id, entry.id)
end

function methods:getCachedArticleContent(target, entry)
    local cache_key = self:getArticleContentCacheKey(target, entry)
    local payload, fresh = self:readCache(
        cache_key,
        self:getCacheTtl("content"),
        not NetworkMgr:isOnline()
    )
    if payload and payload.id ~= nil and not sameEntryId(payload.id, entry.id) then
        self:removeCache(cache_key)
        return nil
    end
    return payload, fresh
end

function methods:cacheArticleContent(target, entry, payload)
    if not hasContentPayload(payload) then
        return
    end
    local formatted = getFormattedContent(payload) or ArticleContent.format(entry, payload.content)
    self:writeCache(self:getArticleContentCacheKey(target, entry), {
        id = payload.id or entry.id,
        title = payload.title,
        content = payload.content,
        formatted_content = formatted,
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
        local cached_payload = {
            id = payload.id or entry.id,
            title = payload.title,
            content = payload.content,
            formatted_content = getFormattedContent(payload) or ArticleContent.format(entry, payload.content),
        }
        self:writeCache(self:getFullTextCacheKey(entry), cached_payload)
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

function methods:cancelArticleContentLoads(_target)
    self:cancelPendingJob(ARTICLE_CONTENT_JOB_KEY)
    self:closeActiveDialog()
end

function methods:isArticleContentOwnerCurrent(target, detail_widget, owner_widget, entry)
    if self.state == "closed" then
        return false
    end
    if detail_widget then
        if not detail_widget.entry
            or detail_widget.closing
            or not detail_widget.updateArticleDetail
            or self.article_detail_widget ~= detail_widget then
            return false
        end
        if entry and entry.id then
            local expected_entry_id = detail_widget.pending_content_entry_id
                or (detail_widget.entry and detail_widget.entry.id)
            return sameEntryId(expected_entry_id, entry.id)
        end
        return true
    end
    if owner_widget then
        return not owner_widget.closing
            and self.article_widget == owner_widget
            and owner_widget.target == target
    end
    return true
end

function methods:onArticleListClosed(widget)
    if self.article_widget == widget then
        self.article_widget = nil
    end
    if self.flushMarkerOutbox then
        self:flushMarkerOutbox()
    end
    if self.flushStreamCacheGeneration then
        self:flushStreamCacheGeneration()
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
    self:closeActiveDialog()
    UIManager:close(widget)
end

function methods:sendMarkerOutboxRequest(method, entry_ids, job_prefix)
    if #entry_ids == 0 then
        return true
    end
    local job = self:createBackgroundRequest({
        method = method,
        path = "/markers/reads",
        body = {
            type = "entries",
            entryIds = entry_ids,
        },
    })
    if not job then
        self:showTransientMessage(_("Cannot update read state."))
        return false
    end
    local job_key = buildEntryIdsJobKey(job_prefix, entry_ids)
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
        local response_code = response and response.code or 0
        if response_code == 401 then
            self:handleUnauthorized()
        elseif response_code < 200 or response_code >= 300 then
            self:showTransientMessage(_("Cannot update read state."))
        end
    end
    poll()
    return true
end

function methods:sendMarkerUnreadRequest(entry_id)
    if entry_id == nil then
        return true
    end
    local job = self:createBackgroundRequest({
        method = "PUT",
        path = "/markers/unread",
        body = {
            entryId = entry_id,
        },
    })
    if not job then
        self:showTransientMessage(_("Cannot update read state."))
        return false
    end
    local job_key = buildEntryIdsJobKey(MARKER_OUTBOX_UNREAD_JOB_PREFIX, { entry_id })
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
        local response_code = response and response.code or 0
        if response_code == 401 then
            self:handleUnauthorized()
        elseif response_code < 200 or response_code >= 300 then
            self:showTransientMessage(_("Cannot update read state."))
        end
    end
    poll()
    return true
end

function methods:flushMarkerOutbox()
    self.marker_outbox_flush_scheduled = false
    if self.state == "closed" then
        return false
    end
    if not hasPendingEntryIds(self.pending_read_entry_ids)
        and not hasPendingEntryIds(self.pending_unread_entry_ids) then
        return false
    end
    if not NetworkMgr:isOnline() then
        self:showTransientMessage(_("Cannot update read state."))
        return false
    end
    local read_ids = drainPendingEntryIds(self.pending_read_entry_ids)
    local unread_ids = drainPendingEntryIds(self.pending_unread_entry_ids)
    if #read_ids == 0 and #unread_ids == 0 then
        return false
    end
    if not self:sendMarkerOutboxRequest("PUT", read_ids, MARKER_OUTBOX_READ_JOB_PREFIX) then
        for i = 1, #read_ids do
            addPendingEntryId(self.pending_read_entry_ids, read_ids[i])
        end
    end
    for i = 1, #unread_ids do
        if not self:sendMarkerUnreadRequest(unread_ids[i]) then
            addPendingEntryId(self.pending_unread_entry_ids, unread_ids[i])
        end
    end
    return true
end

function methods:scheduleMarkerOutboxFlush()
    if self.marker_outbox_flush_scheduled then
        return
    end
    self.marker_outbox_flush_scheduled = true
    UIManager:scheduleIn(MARKER_OUTBOX_FLUSH_DELAY, function()
        if self.marker_outbox_flush_scheduled then
            self:flushMarkerOutbox()
        end
    end)
end

function methods:enqueueMarkerWrite(entry_id, read)
    if entry_id == nil then
        return
    end
    self.pending_read_entry_ids = self.pending_read_entry_ids or {}
    self.pending_unread_entry_ids = self.pending_unread_entry_ids or {}
    local entry_id_key = tostring(entry_id)
    if read then
        self.pending_unread_entry_ids[entry_id_key] = nil
        addPendingEntryId(self.pending_read_entry_ids, entry_id)
    else
        self.pending_read_entry_ids[entry_id_key] = nil
        addPendingEntryId(self.pending_unread_entry_ids, entry_id)
    end
    self:scheduleMarkerOutboxFlush()
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
        if changed and not self.article_widget.closing and self.article_widget.refreshEntryButtons then
            self.article_widget:refreshEntryButtons(entry, {
                repaint = not self.article_detail_widget,
            })
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
    self:enqueueMarkerWrite(entry.id, true)
end

function methods:markArticleUnread(entry)
    if not NetworkMgr:isOnline() or not entry or not entry.id or entry.status == 0 then
        return
    end

    entry.status = 0
    if self.article_widget and not self.article_widget.closing and self.article_widget.refreshEntryButtons then
        self.article_widget:refreshEntryButtons(entry, {
            repaint = not self.article_detail_widget,
        })
    end
    if self.article_detail_widget
        and self.article_detail_widget.entry
        and self.article_detail_widget.entry.id == entry.id then
        self.article_detail_widget.entry.status = 0
    end
    self:adjustSubscriptionUnreadCounts({ entry }, 1)
    self:invalidateStreamCache()
    self:enqueueMarkerWrite(entry.id, false)
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

function methods:cancelArticleFullText(entry)
    if entry and entry.id then
        self:cancelPendingJob(FULL_TEXT_JOB_PREFIX .. tostring(entry.id))
    end
    self:closeActiveDialog()
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
    self:showActiveLoading(_("Loading"))

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
        self:closeActiveDialog()
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
            self:closeActiveDialog()
            return
        end
        local done, response, err = job:poll()
        if not done then
            UIManager:scheduleIn(0.1, poll)
            return
        end
        self:clearPendingJob(job_key, job)
        self:closeActiveDialog()
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
    if detail_widget then
        detail_widget.pending_content_entry_id = entry and entry.id or nil
    end
    if not self:isArticleContentOwnerCurrent(target, detail_widget, owner_widget, entry) then
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
    self:showActiveLoading(_("Loading"))
    local missing_entries = { entry }
    self:requestArticleContents(target, missing_entries, ARTICLE_CONTENT_JOB_KEY, nil, function(payloads, err)
        self:closeActiveDialog()
        if err == "cancelled" or err == "unauthorized" then
            return
        end
        if not self:isArticleContentOwnerCurrent(target, detail_widget, owner_widget, entry) then
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
