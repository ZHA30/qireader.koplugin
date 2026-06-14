local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local ArticleContent = require("qireader.articlecontent")
local QiArticleDetailWidget = require("qireader.articledetail")
local UIManager = require("ui/uimanager")

local methods = {}

function methods:ensureReadLaterTagId()
    if self.readlater_tag_id then
        return self.readlater_tag_id
    end
    local response = self.client:getTags()
    if response.code ~= 200 or not response.json or not response.json.result then
        return nil
    end
    local tags = response.json.result.tags or {}
    for i = 1, #tags do
        local tag = tags[i]
        if tag.label == "!readlater" then
            self.readlater_tag_id = tag.id
            return self.readlater_tag_id
        end
    end
    return nil
end

function methods:onArticleListClosed(widget)
    if self.article_widget == widget then
        self.article_widget = nil
    end
    UIManager:close(widget)
end

function methods.onArticleDetailClosed(_, widget)
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
    local response = self.client:markEntriesRead(unread_ids)
    if response.code ~= 200 then
        return
    end
    for i = 1, #page.entries do
        page.entries[i].status = 1
    end
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
    local tag_id = self:ensureReadLaterTagId()
    if not tag_id then
        self:showTransientMessage(_("Cannot resolve read-later tag."))
        return
    end
    local response
    if entry.is_read_later then
        response = self.client:removeEntryTag(entry.id, tag_id, "feed")
    else
        response = self.client:addEntryTag(entry.id, tag_id, "feed")
    end
    if response.code == 401 then
        self:handleUnauthorized()
        return
    end
    if response.code ~= 200 then
        self:showTransientMessage(_("Cannot update read-later state."))
        return
    end
    entry.is_read_later = not entry.is_read_later
    if entry.is_read_later then
        table.insert(entry.tag_ids, tag_id)
    else
        local filtered = {}
        for i = 1, #entry.tag_ids do
            if entry.tag_ids[i] ~= tag_id then
                table.insert(filtered, entry.tag_ids[i])
            end
        end
        entry.tag_ids = filtered
    end
    if widget then
        widget:refresh()
    end
end

function methods:openArticleContent(target, entry, detail_widget)
    local response = self.client:getEntryContents(target.stream_id, { entry.id })
    if response.code == 401 then
        self:handleUnauthorized()
        return
    end
    if response.code ~= 200 or not response.json or not response.json.result or not response.json.result[1] then
        self:showTransientMessage(_("Cannot load article content."))
        return
    end
    local content = response.json.result[1].content or entry.summary or ""
    local formatted = ArticleContent.format(entry, content)
    local title = entry.title or _("Untitled")
    if detail_widget and detail_widget.updateArticleDetail then
        detail_widget:updateArticleDetail(entry, formatted, title)
        return
    end
    if self.article_widget then
        self.article_widget:showArticleDetail(entry, formatted)
    else
        UIManager:show(QiArticleDetailWidget:new{
            controller = self,
            entry = entry,
            title = title,
            html = formatted,
        })
    end
end

return methods
