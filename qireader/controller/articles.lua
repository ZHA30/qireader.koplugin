local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local ArticleContent = require("qireader.articlecontent")
local ArticleImage = require("qireader.articleimage")
local QiArticleDetailWidget = require("qireader.articledetail")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local methods = {}

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

local function buildArticleContent(entry, response)
    local content = response.json.result[1].content or entry.summary or ""
    local formatted, media_refs = ArticleContent.format(entry, content)
    local title = entry.title or _("Untitled")
    return formatted, title, media_refs
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
    self:refreshReadLaterWidgets()
end

function methods:loadReadLaterTagId(callback)
    if self.readlater_tag_id then
        if callback then
            callback(self.readlater_tag_id)
        end
        return
    end
    if callback then
        self.readlater_tag_callbacks = self.readlater_tag_callbacks or {}
        self.readlater_tag_callbacks[#self.readlater_tag_callbacks + 1] = callback
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
            self:cancelPendingJob("readlater_tag")
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
    if self.article_detail_widget then
        UIManager:close(self.article_detail_widget)
        self.article_detail_widget = nil
    end
    UIManager:close(widget)
end

function methods:onArticleDetailClosed(widget)
    if self.article_detail_widget == widget then
        self.article_detail_widget = nil
    end
    UIManager:close(widget)
end

function methods:markPageRead(page)
    if not page or not page.entries or #page.entries == 0 then
        return
    end
    local unread_ids = {}
    for i = 1, #page.entries do
        local entry = page.entries[i]
        if entry.status == 0 then
            table.insert(unread_ids, entry.id)
        end
    end
    if #unread_ids == 0 then
        return
    end
    for i = 1, #page.entries do
        page.entries[i].status = 1
    end
    local job = self:createBackgroundRequest({
        method = "PUT",
        path = "/markers/reads",
        body = {
            type = "entries",
            entryIds = unread_ids,
        },
    })
    if not job then
        return
    end
    local function poll()
        local done, response = job:poll()
        if not done then
            UIManager:scheduleIn(0.1, poll)
            return
        end
        self:applyResponseSession(response)
        if response and response.code == 401 then
            self:handleUnauthorized()
        end
    end
    poll()
end

function methods:maybeMarkArticlePageRead(page)
    local first_entry = page and page.entries and page.entries[1] or nil
    local target = first_entry and first_entry.target or nil
    if not page or self:getArticleSetting(target, "mark_read_on_page_turn") ~= true then
        return
    end
    self:markPageRead(page)
end

function methods:toggleReadLater(entry, widget)
    if NetworkMgr and NetworkMgr.willRerunWhenOnline
        and NetworkMgr:willRerunWhenOnline(function()
            self:toggleReadLater(entry, widget)
        end) then
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
                self:cancelPendingJob(job_key)
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

function methods:openArticleImage(ref, widget)
    ArticleImage.open(self, ref, widget)
end

function methods:openArticleContent(target, entry, detail_widget)
    if NetworkMgr and NetworkMgr.willRerunWhenOnline
        and NetworkMgr:willRerunWhenOnline(function()
            self:openArticleContent(target, entry, detail_widget)
        end) then
        return
    end
    local job_token = self:nextJobToken("article_content")
    local job = self:createBackgroundRequest({
        method = "GET",
        path = "/entry-contents",
        query = {
            streamId = target.stream_id,
            entryIds = { entry.id },
        },
    })
    if not job then
        self:showTransientMessage(_("Cannot load article content."))
        return
    end
    self:registerPendingJob("article_content", job)
    local function poll()
        if self.state == "closed"
            or not self:isJobTokenCurrent("article_content", job_token)
            or self.pending_jobs.article_content ~= job then
            self:cancelPendingJob("article_content")
            return
        end
        local done, response, err = job:poll()
        if not done then
            UIManager:scheduleIn(0.1, poll)
            return
        end
        self:clearPendingJob("article_content", job)
        if err == "cancelled" then
            return
        end
        if self.state == "closed" or not self:isJobTokenCurrent("article_content", job_token) then
            return
        end
        self:applyResponseSession(response)
        if not response then
            self:showTransientMessage(_("Cannot load article content."))
            return
        end
        if response.code == 401 then
            self:handleUnauthorized()
            return
        end
        if response.code ~= 200 or not response.json or not response.json.result or not response.json.result[1] then
            self:showTransientMessage(_("Cannot load article content."))
            return
        end
        local formatted, title, media_refs = buildArticleContent(entry, response)
        if detail_widget
            and detail_widget.updateArticleDetail
            and not detail_widget.closing
            and self.article_detail_widget == detail_widget then
            detail_widget:updateArticleDetail(entry, formatted, title, media_refs)
            return
        end
        if self.article_widget then
            self.article_widget:showArticleDetail(entry, formatted, media_refs)
            return
        end
        local content_widget = QiArticleDetailWidget:new{
            controller = self,
            entry = entry,
            title = title,
            html = formatted,
            media_refs = media_refs,
            on_close_article = function(closed_widget)
                self:onArticleDetailClosed(closed_widget)
            end,
        }
        self.article_detail_widget = content_widget
        UIManager:show(content_widget)
    end
    poll()
end

return methods
