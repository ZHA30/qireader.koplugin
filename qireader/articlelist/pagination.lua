local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local Device = require("device")
local Size = require("ui/size")
local item_module = require("qireader.articlelist.item")
local Screen = Device.screen

local methods = {}

function methods:getPerPage()
    return self.controller:getArticleSetting(self.target, "items_per_page") or 5
end

function methods:getEffectivePerPage()
    return self.effective_per_page or math.max(1, self:getPerPage())
end

function methods:getRemoteBatchSize()
    return self.remote_batch_size or 50
end

function methods:getPagesPerChunk()
    local per_page = math.max(1, self:getEffectivePerPage())
    local remote_batch = math.max(per_page, self:getRemoteBatchSize())
    return math.max(1, math.ceil(remote_batch / per_page))
end

function methods:getTitleFontSize()
    return self.controller:getArticleSetting(self.target, "title_font_size") or 18
end

function methods:getAvailableHeight()
    return self.dimen.h - self.title_bar:getHeight() - (self.footer_height or Screen:scaleBySize(40))
end

function methods:setupItemMetrics()
    local requested_per_page = math.max(1, self:getPerPage())
    local content_height = math.max(0, self:getAvailableHeight())
    local item_width = self.dimen.w - Size.padding.large * 2
    local effective_per_page = requested_per_page
    local item_spacing = requested_per_page > 1 and Size.padding.small or 0
    local item_height = 0

    while effective_per_page > 1 do
        local gap_count = math.max(0, effective_per_page - 1)
        local spacing = effective_per_page > 1 and item_spacing or 0
        local candidate_height = math.floor((content_height - spacing * gap_count) / effective_per_page)
        if item_module.canArticleRowFit(item_width, candidate_height, self:getTitleFontSize()) then
            item_height = candidate_height
            item_spacing = spacing
            break
        end
        effective_per_page = effective_per_page - 1
    end

    if item_height < 1 then
        effective_per_page = math.max(1, effective_per_page)
        local gap_count = math.max(0, effective_per_page - 1)
        item_spacing = effective_per_page > 1 and Size.padding.small or 0
        item_height = math.floor((content_height - item_spacing * gap_count) / effective_per_page)
        if item_height < 1 then
            item_spacing = 0
            item_height = math.floor(content_height / effective_per_page)
        end
    end

    local gap_count = math.max(0, effective_per_page - 1)

    self.item_width = item_width
    self.item_height = math.max(1, item_height)
    self.item_spacing = item_spacing
    self.effective_per_page = effective_per_page

    local used_height = self.item_height * effective_per_page + self.item_spacing * gap_count
    local remaining = math.max(0, content_height - used_height)
    self.item_top_spacing = math.floor(remaining / 2)
    self.item_bottom_spacing = remaining - self.item_top_spacing
end

function methods:buildStreamQuery(cursor)
    local oldest_first = self.controller:getArticleSetting(self.target, "order_oldest_first") == true
    local unread_only = self.controller:getArticleSetting(self.target, "show_unread_only") == true
    local query = {
        count = self:getRemoteBatchSize(),
        articleOrder = oldest_first and 1 or 0,
        unreadOnly = unread_only and true or nil,
    }
    if cursor then
        if oldest_first then
            query.newerThan = cursor
        else
            query.olderThan = cursor
        end
    end
    return query
end

function methods:getStreamId()
    return self.target.stream_id
end

function methods:getChunkIndexForPage(page)
    return math.floor((page - 1) / self:getPagesPerChunk()) + 1
end

function methods:getPageOffsetInChunk(page)
    local per_page = math.max(1, self:getEffectivePerPage())
    local chunk_index = self:getChunkIndexForPage(page)
    local first_page = (chunk_index - 1) * self:getPagesPerChunk() + 1
    return (page - first_page) * per_page
end

function methods:buildPageFromChunk(page)
    local chunk_index = self:getChunkIndexForPage(page)
    local chunk = self.loaded_chunks[chunk_index]
    if not chunk then
        return nil
    end
    local per_page = math.max(1, self:getEffectivePerPage())
    local start_index = self:getPageOffsetInChunk(page) + 1
    if start_index > #chunk.entries then
        return nil
    end
    local end_index = math.min(#chunk.entries, start_index + per_page - 1)
    local entries = {}
    for i = start_index, end_index do
        entries[#entries + 1] = chunk.entries[i]
    end
    return {
        entries = entries,
        has_more = end_index < #chunk.entries or chunk.has_more,
        next_cursor = chunk.next_cursor,
        chunk_index = chunk_index,
        page_start_index = start_index,
        page_end_index = end_index,
    }
end

function methods:rebuildLoadedPages()
    self:setupItemMetrics()
    self.loaded_pages = {}
    local page = 1
    while true do
        local built = self:buildPageFromChunk(page)
        if not built then
            break
        end
        self.loaded_pages[page] = built
        page = page + 1
    end
    self.pages = math.max(1, page - 1)
    local last_page = self.loaded_pages[self.pages]
    self.has_more = last_page and last_page.has_more or false
    if self.show_page > self.pages then
        self.show_page = self.pages
    end
end

function methods:getChunkCursor(chunk_index)
    if chunk_index <= 1 then
        return nil
    end
    local previous_chunk = self.loaded_chunks[chunk_index - 1]
    return previous_chunk and previous_chunk.next_cursor or nil
end

function methods:canLoadChunk(chunk_index)
    if chunk_index <= 1 then
        return true
    end
    return self.loaded_chunks[chunk_index - 1] ~= nil
end

function methods:fetchChunk(chunk_index, options)
    options = options or {}
    if self.closing or self.loaded_chunks[chunk_index] then
        return nil, "skip"
    end
    if not self:canLoadChunk(chunk_index) then
        return nil, "blocked"
    end
    if options.background then
        if self.loading or self.preloading_chunks[chunk_index] then
            return nil, "busy"
        end
        self.preloading_chunks[chunk_index] = true
    else
        if self.loading then
            return nil, "busy"
        end
        self.loading = true
    end

    local response = self.controller.client:getStream(
        self:getStreamId(),
        self:buildStreamQuery(self:getChunkCursor(chunk_index))
    )

    if options.background then
        self.preloading_chunks[chunk_index] = nil
    else
        self.loading = false
    end

    if self.closing then
        return nil, "closed"
    end
    if response.code == 401 then
        self.controller:handleUnauthorized()
        return nil, "unauthorized"
    end
    if response.code ~= 200 or not response.json or not response.json.result then
        return nil, "error"
    end

    self.loaded_chunks[chunk_index] = self.controller:normalizeArticlePage(self.target, response.json.result)
    self:rebuildLoadedPages()
    return self.loaded_chunks[chunk_index], nil
end

function methods:maybePreloadNextChunk()
    if self.loading or self.closing then
        return
    end
    local current_page = self.loaded_pages[self.show_page]
    if not current_page then
        return
    end
    local current_chunk_index = current_page.chunk_index
    local next_chunk_index = current_chunk_index + 1
    if self.loaded_chunks[next_chunk_index] or self.preloading_chunks[next_chunk_index] then
        return
    end
    if not current_page.has_more then
        return
    end
    local pages_per_chunk = self:getPagesPerChunk()
    local first_page_in_chunk = (current_chunk_index - 1) * pages_per_chunk + 1
    local last_page_in_chunk = first_page_in_chunk + pages_per_chunk - 1
    local trigger_page = math.max(first_page_in_chunk, last_page_in_chunk - (self.preload_pages_before_end or 1))
    if self.show_page < trigger_page then
        return
    end
    local _, err = self:fetchChunk(next_chunk_index, { background = true })
    if not err then
        self:refresh()
    end
end

function methods:loadPage(page)
    if self.closing then
        return
    end
    local previous_page_number = self.show_page
    local previous_page = self.loaded_pages[previous_page_number]
    if self.loaded_pages[page] then
        local changed = previous_page_number ~= page
        self.show_page = page
        if changed then
            self.controller:maybeMarkArticlePageRead(previous_page)
        end
        self:refresh()
        self:maybePreloadNextChunk()
        return
    end
    if self.loading then
        return
    end
    local chunk_index = self:getChunkIndexForPage(page)
    self.show_page = page
    self:refreshFooter()
    local _, err = self:fetchChunk(chunk_index)
    if err == "blocked" or err == "busy" then
        self.show_page = previous_page_number
        self:refresh()
        return
    end
    if err then
        self.show_page = previous_page_number
        if err == "error" then
            self.controller:showTransientMessage(_("Cannot load articles."))
        end
        self:refresh()
        return
    end
    if previous_page_number ~= page then
        self.controller:maybeMarkArticlePageRead(previous_page)
    end
    self:refresh()
    self:maybePreloadNextChunk()
end

function methods:reloadFromFirstPage()
    self:reloadLayoutOnly()
end

function methods:reloadLayoutOnly()
    self:rebuildLoadedPages()
    self:refresh()
end

function methods:reloadFromRemote()
    self.loaded_pages = {}
    self.loaded_chunks = {}
    self.show_page = 1
    self.pages = 1
    self.has_more = false
    self:loadPage(1)
end

return methods
