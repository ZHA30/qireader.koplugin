local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local CheckButton = require("ui/widget/checkbutton")
local CheckMark = require("ui/widget/checkmark")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local NetworkMgr = require("ui/network/manager")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local methods = {}
local TAG_POPOVER_MAX_HEIGHT_RATIO = 0.8

local function getTagIdKey(tag_id)
    if tag_id == nil then
        return nil
    end
    return tostring(tag_id)
end

local function copyTagIds(tag_ids)
    local copied = {}
    for i = 1, #(tag_ids or {}) do
        copied[i] = tag_ids[i]
    end
    return copied
end

local function tagIdsContain(tag_ids, tag_id)
    local tag_id_key = getTagIdKey(tag_id)
    if not tag_id_key then
        return false
    end
    for i = 1, #(tag_ids or {}) do
        if getTagIdKey(tag_ids[i]) == tag_id_key then
            return true
        end
    end
    return false
end

local function addTagId(tag_ids, tag_id)
    if tagIdsContain(tag_ids, tag_id) then
        return tag_ids
    end
    tag_ids[#tag_ids + 1] = tag_id
    return tag_ids
end

local function removeTagId(tag_ids, tag_id)
    local tag_id_key = getTagIdKey(tag_id)
    local filtered = {}
    for i = 1, #(tag_ids or {}) do
        if getTagIdKey(tag_ids[i]) ~= tag_id_key then
            filtered[#filtered + 1] = tag_ids[i]
        end
    end
    return filtered
end

local function makeRegularTagIdSet(tags)
    local tag_ids = {}
    for i = 1, #(tags or {}) do
        local tag = tags[i]
        local tag_id_key = getTagIdKey(tag and tag.id)
        if tag_id_key then
            tag_ids[tag_id_key] = true
        end
    end
    return tag_ids
end

local function hasRegularTag(tag_ids, regular_tag_ids, readlater_tag_id)
    local readlater_tag_id_key = getTagIdKey(readlater_tag_id)
    local has_regular_tags = next(regular_tag_ids or {}) ~= nil
    for i = 1, #(tag_ids or {}) do
        local tag_id_key = getTagIdKey(tag_ids[i])
        if has_regular_tags then
            if regular_tag_ids[tag_id_key] then
                return true
            end
        elseif tag_id_key and tag_id_key ~= readlater_tag_id_key then
            return true
        end
    end
    return false
end

local function getReadLaterFlag(entry, tag_id)
    if not entry or tag_id == nil then
        return false
    end
    return tagIdsContain(entry.tag_ids or {}, tag_id)
end

local function measureTextWidth(text, face)
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = face,
    }
    local width = widget:getSize().w
    widget:free()
    return width
end

local function getTagsPopoverWidth(tags, checkmark_width)
    local screen_limit = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
    local min_width = math.min(screen_limit, Screen:scaleBySize(120))
    local item_face = Font:getFace("smallinfofont")
    local max_text_width = 0
    for i = 1, #(tags or {}) do
        local tag = tags[i]
        max_text_width = math.max(max_text_width, measureTextWidth(tag and tag.label or _("Untitled"), item_face))
    end

    local desired_width = max_text_width
        + checkmark_width
        + Size.padding.large * 3
        + Size.border.window * 2
    return math.max(min_width, math.min(screen_limit, desired_width))
end

local TagPopover = InputContainer:extend{
    modal = true,
    entry = nil,
    tags = nil,
    selected = nil,
    anchor = nil,
    width = nil,
    controller = nil,
    owner_widget = nil,
}

function TagPopover:init()
    self.tags = self.tags or {}
    self.selected = self.selected or {}
    self.dimen = Screen:getSize()
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    local row_width = self.width - Size.padding.large * 2 - Size.border.window * 2
    local rows = VerticalGroup:new{
        align = "left",
    }
    for i = 1, #self.tags do
        local tag = self.tags[i]
        local tag_id_key = getTagIdKey(tag and tag.id)
        if tag_id_key then
            local check_button
            check_button = CheckButton:new{
                text = tag.label or _("Untitled"),
                checked = self.selected[tag_id_key] == true,
                parent = self,
                show_parent = self,
                width = row_width,
                single_line = true,
                callback = function()
                    if self.controller and self.controller.toggleArticleTag then
                        self.controller:toggleArticleTag(self.entry, tag, check_button)
                    end
                end,
            }
            table.insert(rows, check_button)
            if i < #self.tags then
                table.insert(rows, VerticalSpan:new{ width = Size.padding.large })
            end
        end
    end

    local max_content_height = math.floor(Screen:getHeight() * TAG_POPOVER_MAX_HEIGHT_RATIO)
        - Size.padding.large * 2
        - Size.border.window * 2
    local content = rows
    local rows_height = rows:getSize().h
    if rows_height > max_content_height then
        self.cropping_widget = ScrollableContainer:new{
            dimen = Geom:new{
                w = row_width + ScrollableContainer:getScrollbarWidth(),
                h = max_content_height,
            },
            show_parent = self,
            rows,
        }
        content = self.cropping_widget
    end

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.large,
        content,
    }
    self.movable = MovableContainer:new{
        anchor = self.anchor,
        ignore_events = { "hold", "hold_release" },
        frame,
    }
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        self.movable,
    }
end

function TagPopover:getAddedWidgetAvailableWidth()
    return self.width - Size.padding.large * 2 - Size.border.window * 2
end

function TagPopover:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.movable.dimen
    end)
end

function TagPopover:onCloseWidget()
    self.closing = true
    if self.owner_widget and self.owner_widget.active_dialog == self then
        self.owner_widget.active_dialog = nil
    end
    UIManager:setDirty(nil, function()
        return "flashui", self.movable and self.movable.dimen or self.dimen
    end)
end

function TagPopover:onClose()
    UIManager:close(self)
    return true
end

function TagPopover:onTapClose(_arg, ges)
    if not ges or not ges.pos or not self.movable or not self.movable.dimen then
        return false
    end
    if ges.pos:notIntersectWith(self.movable.dimen) then
        self:onClose()
        return true
    end
    return false
end

local function refreshDetailWidget(widget)
    if not widget or widget.closing then
        return
    end
    if widget.refreshBottomButtonStates then
        widget:refreshBottomButtonStates()
    elseif widget.refreshBottomButtons then
        widget:refreshBottomButtons()
        UIManager:setDirty(widget, function()
            return "partial", widget.movable and widget.movable.dimen or widget.frame.dimen
        end)
    end
end

function methods:syncReadLaterEntry(entry)
    if not entry then
        return
    end
    entry.is_read_later = getReadLaterFlag(entry, self.readlater_tag_id)
end

function methods:syncArticleTagEntry(entry)
    if not entry then
        return
    end
    self:syncReadLaterEntry(entry)
    entry.has_tags = hasRegularTag(entry.tag_ids or {}, makeRegularTagIdSet(self.tags), self.readlater_tag_id)
end

function methods:refreshArticleTagWidgets()
    if self.article_widget and self.article_widget.loaded_chunks then
        local loaded_chunks = self.article_widget.loaded_chunks
        for chunk_index in pairs(loaded_chunks) do
            local chunk = loaded_chunks[chunk_index]
            local entries = chunk and chunk.entries or nil
            if entries then
                for i = 1, #entries do
                    self:syncArticleTagEntry(entries[i])
                end
            end
        end
        if not self.article_widget.closing and self.article_widget.refreshVisibleArticleButtons then
            self.article_widget:refreshVisibleArticleButtons({
                repaint = not self.article_detail_widget,
            })
        end
    end
    if self.article_detail_widget and self.article_detail_widget.entry then
        self:syncArticleTagEntry(self.article_detail_widget.entry)
        if not self.article_detail_widget.closing then
            refreshDetailWidget(self.article_detail_widget)
        end
    end
end

function methods:refreshReadLaterWidgets()
    self:refreshArticleTagWidgets()
end

function methods:applyReadLaterState(entry, tag_id)
    if not entry then
        return
    end
    entry.tag_ids = entry.tag_ids or {}
    if getReadLaterFlag(entry, tag_id) then
        entry.tag_ids = removeTagId(entry.tag_ids, tag_id)
    else
        entry.tag_ids = addTagId(entry.tag_ids, tag_id)
    end
    self:syncArticleTagEntry(entry)
    self:invalidateStreamCache()
    self:refreshArticleTagWidgets()
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
                self:refreshArticleTagWidgets()
                finish(self.readlater_tag_id)
                return
            end
        end
        finish(nil, "missing")
    end
    poll()
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

function methods:applyArticleTagState(entry, tag_id, enabled)
    local entry_id = entry and entry.id
    if not entry_id then
        return false
    end
    local changed = false
    local function applyToEntry(item)
        if not item or item.id ~= entry_id then
            return
        end
        item.tag_ids = copyTagIds(item.tag_ids)
        local has_tag = tagIdsContain(item.tag_ids, tag_id)
        if enabled and not has_tag then
            item.tag_ids = addTagId(item.tag_ids, tag_id)
            changed = true
        elseif not enabled and has_tag then
            item.tag_ids = removeTagId(item.tag_ids, tag_id)
            changed = true
        end
        self:syncArticleTagEntry(item)
    end
    applyToEntry(entry)
    if self.article_widget and self.article_widget.loaded_chunks then
        local loaded_chunks = self.article_widget.loaded_chunks
        for chunk_index in pairs(loaded_chunks) do
            local chunk = loaded_chunks[chunk_index]
            local entries = chunk and chunk.entries or nil
            if entries then
                for i = 1, #entries do
                    applyToEntry(entries[i])
                end
            end
        end
    end
    if self.article_detail_widget and self.article_detail_widget.entry then
        applyToEntry(self.article_detail_widget.entry)
    end
    return changed
end

function methods:toggleArticleTag(entry, tag, check_button)
    local tag_id = tag and tag.id
    if not entry or not entry.id or tag_id == nil then
        if check_button and not (check_button.parent and check_button.parent.closing) then
            check_button:toggleCheck()
        end
        return
    end
    local enabled = check_button and check_button.checked == true
    if not NetworkMgr:isOnline() then
        if check_button and not (check_button.parent and check_button.parent.closing) then
            check_button:toggleCheck()
        end
        self:showTransientMessage(_("Cannot update tags."))
        return
    end
    local job_key = "article_tag:" .. tostring(entry.id) .. ":" .. tostring(tag_id)
    if self.pending_jobs[job_key] then
        if check_button and not (check_button.parent and check_button.parent.closing) then
            check_button:toggleCheck()
        end
        self:showTransientMessage(_("Loading..."))
        return
    end

    local job_token = self:nextJobToken(job_key)
    local function finish(err)
        if err and check_button and not (check_button.parent and check_button.parent.closing) then
            check_button:toggleCheck()
        end
        if err == "unauthorized" then
            self:handleUnauthorized()
        elseif err then
            self:showTransientMessage(_("Cannot update tags."))
        end
    end
    local job = self:createBackgroundRequest({
        method = enabled and "PUT" or "DELETE",
        path = enabled
            and ("/entries/" .. tostring(entry.id) .. "/tags/" .. tostring(tag_id))
            or ("/entries/feed/" .. tostring(entry.id) .. "/tags/" .. tostring(tag_id)),
        body = {
            entryType = "feed",
            entryId = entry.id,
            tagId = tag_id,
        },
    })
    if not job then
        finish("error")
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
            finish("error")
            return
        end
        if response.code == 401 then
            finish("unauthorized")
            return
        end
        if response.code < 200 or response.code >= 300 then
            finish("error")
            return
        end
        if self:applyArticleTagState(entry, tag_id, enabled) then
            self:invalidateStreamCache()
            self:refreshArticleTagWidgets()
        end
    end
    poll()
end

local function getGestureAnchor(ges)
    local pos = ges and ges.pos
    if not pos then
        return nil
    end
    return Geom:new{
        x = pos.x,
        y = pos.y,
        w = 1,
        h = 1,
    }
end

function methods:showArticleTagsDialog(entry, widget, ges)
    if not entry or not entry.id then
        return
    end
    local tags = self.tags or {}
    if #tags == 0 then
        self:showTransientMessage(_("No tags."))
        return
    end
    if widget and widget.closeActiveDialog then
        widget:closeActiveDialog()
    end
    local selected = {}
    for i = 1, #tags do
        local tag = tags[i]
        local tag_id_key = getTagIdKey(tag and tag.id)
        if tag_id_key then
            selected[tag_id_key] = tagIdsContain(entry.tag_ids or {}, tag.id)
        end
    end
    local checkmark_width = CheckMark:new{ checked = true }:getSize().w
    local dialog = TagPopover:new{
        controller = self,
        owner_widget = widget,
        entry = entry,
        tags = tags,
        selected = selected,
        anchor = getGestureAnchor(ges),
        width = getTagsPopoverWidth(tags, checkmark_width),
    }
    if widget then
        widget.active_dialog = dialog
    end
    UIManager:show(dialog)
end

return methods
