local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
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
    local is_tag_stream = self.controller.isArticleTagTarget
        and self.controller:isArticleTagTarget(self.target)
    local oldest_first = (not is_tag_stream)
        and self.controller:getArticleSetting(self.target, "order_oldest_first") == true
    local unread_only = self.controller:getArticleSetting(self.target, "show_unread_only") == true
    local query = {
        count = self:getRemoteBatchSize(),
        articleOrder = oldest_first and 1 or 0,
        unreadOnly = unread_only and true or nil,
    }
    if is_tag_stream then
        query.id = self:getStreamId()
        query.unreadOnly = unread_only
    end
    if cursor then
        if oldest_first then
            query.newerThan = cursor
        else
            query.olderThan = cursor
        end
    end
    return query
end

function methods:getStreamCacheKey(query)
    local cursor_name = ""
    local cursor_value = ""
    if query.olderThan then
        cursor_name = "olderThan"
        cursor_value = query.olderThan
    elseif query.newerThan then
        cursor_name = "newerThan"
        cursor_value = query.newerThan
    end
    return self.controller:cacheKey(
        "stream",
        self.controller:getStreamCacheGeneration(),
        self:getStreamId(),
        query.count or "",
        query.articleOrder or "",
        query.unreadOnly and "1" or "0",
        cursor_name,
        cursor_value
    )
end

function methods:loadChunkFromCache(chunk_index, query)
    local cache_key = self:getStreamCacheKey(query)
    local result = self.controller:readCache(
        cache_key,
        self.controller:getCacheTtl("stream"),
        true
    )
    if not result then
        return nil, cache_key
    end
    self.loaded_chunks[chunk_index] = self.controller:normalizeArticlePage(self.target, result)
    self:rebuildLoadedPages()
    return self.loaded_chunks[chunk_index], cache_key
end

function methods:writeChunkCache(cache_key, result)
    if result then
        self.controller:writeCache(cache_key, result)
    end
end

function methods:getStreamId()
    return self.target.stream_id
end

function methods:getLastLoadedChunkIndex()
    local chunk_index = 0
    while self.loaded_chunks[chunk_index + 1] do
        chunk_index = chunk_index + 1
    end
    return chunk_index
end

function methods:getNextLoadableChunkIndex()
    local last_chunk_index = self:getLastLoadedChunkIndex()
    if last_chunk_index == 0 then
        return 1
    end
    local last_chunk = self.loaded_chunks[last_chunk_index]
    if last_chunk and last_chunk.has_more then
        return last_chunk_index + 1
    end
    return nil
end

function methods:getLoadedEntries()
    local entries = {}
    local chunk_index = 1
    while self.loaded_chunks[chunk_index] do
        local chunk_entries = self.loaded_chunks[chunk_index].entries or {}
        for i = 1, #chunk_entries do
            entries[#entries + 1] = chunk_entries[i]
        end
        chunk_index = chunk_index + 1
    end
    return entries
end

function methods:rebuildLoadedPages()
    self:setupItemMetrics()
    self.loaded_pages = {}
    local entries = self:getLoadedEntries()
    local per_page = math.max(1, self:getEffectivePerPage())
    local last_chunk_index = self:getLastLoadedChunkIndex()
    local last_chunk = self.loaded_chunks[last_chunk_index]
    local has_more = last_chunk and last_chunk.has_more == true or false
    local page = 0
    local start_index = 1
    while start_index <= #entries do
        page = page + 1
        local end_index = math.min(#entries, start_index + per_page - 1)
        local page_entries = {}
        for i = start_index, end_index do
            page_entries[#page_entries + 1] = entries[i]
        end
        self.loaded_pages[page] = {
            entries = page_entries,
            has_more = end_index < #entries or has_more,
            next_cursor = last_chunk and last_chunk.next_cursor or nil,
            page_start_index = start_index,
            page_end_index = end_index,
        }
        start_index = end_index + 1
    end
    self.pages = math.max(1, page)
    local last_page = self.loaded_pages[self.pages]
    self.has_more = last_page and last_page.has_more or has_more
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

function methods:clearPendingFetch()
    if self.pending_request and self.pending_request.cancel then
        self.pending_request:cancel()
    end
    if self.pending_request_chunk_index and self.preloading_chunks then
        self.preloading_chunks[self.pending_request_chunk_index] = nil
    end
    self.pending_request = nil
    self.pending_request_chunk_index = nil
    self.pending_request_background = nil
    self.loading = false
end

function methods:finishPendingFetch()
    if self.pending_request_chunk_index and self.preloading_chunks then
        self.preloading_chunks[self.pending_request_chunk_index] = nil
    end
    self.pending_request = nil
    self.pending_request_chunk_index = nil
    self.pending_request_background = nil
end

function methods:startChunkFetch(chunk_index, options, callback)
    options = options or {}
    if self.closing or self.loaded_chunks[chunk_index] then
        return false, "skip"
    end
    if not self:canLoadChunk(chunk_index) then
        return false, "blocked"
    end

    local query = self:buildStreamQuery(self:getChunkCursor(chunk_index))
    local cache_key
    if not options.force_remote then
        local cached_chunk
        cached_chunk, cache_key = self:loadChunkFromCache(chunk_index, query)
        if cached_chunk then
            if not options.background then
                self.loading = false
            end
            if NetworkMgr:isOnline() then
                self:refreshChunkFromRemote(chunk_index, query, cache_key)
            end
            callback(cached_chunk, nil)
            return true, nil
        end
    else
        cache_key = self:getStreamCacheKey(query)
    end

    if self.pending_request then
        if not options.background and self.pending_request_background then
            self:clearPendingFetch()
        else
            return false, "busy"
        end
    end

    if options.background and not NetworkMgr:isOnline() then
        return false, "offline"
    end

    local job = self.controller:createBackgroundRequest({
        method = "GET",
        path = "/streams/" .. tostring(self:getStreamId()),
        query = query,
    })
    if not job then
        return false, "error"
    end

    self.pending_request = job
    self.pending_request_chunk_index = chunk_index
    self.pending_request_background = options.background == true
    if options.background then
        self.preloading_chunks[chunk_index] = true
    else
        self.loading = true
    end

    local function poll()
        if self.closing or self.pending_request ~= job then
            if self.pending_request == job then
                self:clearPendingFetch()
            end
            return
        end

        local done, response, err = job:poll()
        if not done then
            UIManager:scheduleIn(0.1, poll)
            return
        end

        if options.background then
            self.preloading_chunks[chunk_index] = nil
        else
            self.loading = false
        end
        self:finishPendingFetch()

        if self.closing then
            callback(nil, "closed")
            return
        end
        if err == "cancelled" then
            callback(nil, "closed")
            return
        end
        self.controller:applyResponseSession(response)
        if response and response.code == 401 then
            self.controller:handleUnauthorized()
            callback(nil, "unauthorized")
            return
        end
        if not response or response.code ~= 200 or not response.json or not response.json.result then
            callback(nil, "error")
            return
        end

        self:writeChunkCache(cache_key, response.json.result)
        self.loaded_chunks[chunk_index] = self.controller:normalizeArticlePage(self.target, response.json.result)
        self:rebuildLoadedPages()
        callback(self.loaded_chunks[chunk_index], nil)
    end

    poll()
    return true, nil
end

function methods:refreshChunkFromRemote(chunk_index, query, cache_key)
    if self.closing or self.pending_request or not NetworkMgr:isOnline() then
        return
    end
    local job = self.controller:createBackgroundRequest({
        method = "GET",
        path = "/streams/" .. tostring(self:getStreamId()),
        query = query,
    })
    if not job then
        return
    end
    self.pending_request = job
    self.pending_request_chunk_index = chunk_index
    self.pending_request_background = true
    self.preloading_chunks[chunk_index] = true

    local function poll()
        if self.closing or self.pending_request ~= job then
            if self.pending_request == job then
                self:clearPendingFetch()
            end
            return
        end
        local done, response, err = job:poll()
        if not done then
            UIManager:scheduleIn(0.1, poll)
            return
        end
        self:finishPendingFetch()
        if self.closing or err == "cancelled" then
            return
        end
        self.controller:applyResponseSession(response)
        if response and response.code == 401 then
            self.controller:handleUnauthorized()
            return
        end
        if not response or response.code ~= 200 or not response.json or not response.json.result then
            return
        end
        self:writeChunkCache(cache_key, response.json.result)
        self.loaded_chunks[chunk_index] = self.controller:normalizeArticlePage(self.target, response.json.result)
        self:rebuildLoadedPages()
        self:refresh()
    end

    poll()
end

function methods:fetchChunk(chunk_index, options, callback)
    options = options or {}
    callback = callback or function() end
    local started, err = self:startChunkFetch(chunk_index, options, function(chunk, fetch_err)
        if not options.background then
            self:refresh()
        end
        callback(chunk, fetch_err)
    end)
    if not started then
        return nil, err
    end
    return nil, nil
end

function methods:maybePreloadNextChunk()
    if self.closing or self.loading or self.pending_request or not self.has_more then
        return false
    end
    if not self.loaded_pages[self.show_page] then
        return false
    end
    local remaining_pages = self.pages - self.show_page
    local preload_pages = math.max(0, self.preload_pages_before_end or 0)
    if remaining_pages > preload_pages then
        return false
    end
    local chunk_index = self:getNextLoadableChunkIndex()
    if not chunk_index or self.loaded_chunks[chunk_index] or self.preloading_chunks[chunk_index] then
        return false
    end

    local err = select(2, self:fetchChunk(chunk_index, { background = true }, function(_chunk, fetch_err)
        if self.closing then
            return
        end
        if fetch_err then
            return
        end
        self:refresh()
        self:maybePreloadNextChunk()
    end))
    return err == nil
end

function methods:loadPage(page, options)
    options = options or {}
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
    if self.pending_request then
        if self.pending_request_background then
            self:clearPendingFetch()
        else
            return
        end
    end
    local chunk_index = self:getNextLoadableChunkIndex()
    if not chunk_index then
        return
    end
    self.show_page = page
    self.loading = true
    self:refreshFooter()
    self:refresh()
    local err = select(2, self:fetchChunk(chunk_index, {
        force_remote = options.force_remote,
    }, function(_chunk, callback_err)
        if self.closing then
            return
        end
        if callback_err then
            self.show_page = previous_page_number
            if callback_err == "error" then
                self.controller:showTransientMessage(_("Cannot load articles."))
            end
            self:refresh()
            return
        end
        if not self.loaded_pages[self.show_page] and self.show_page > self.pages then
            self.show_page = previous_page_number
        end
        if previous_page_number ~= self.show_page then
            self.controller:maybeMarkArticlePageRead(previous_page)
        end
        self:refresh()
        self:maybePreloadNextChunk()
    end))
    if err == "blocked" or err == "busy" then
        self.show_page = previous_page_number
        self.loading = false
        self:refresh()
        return
    end
    if err and err ~= "skip" then
        self.show_page = previous_page_number
        self.loading = false
        self:refresh()
        return
    end
end

function methods:reloadFromFirstPage()
    self:reloadLayoutOnly()
end

function methods:reloadLayoutOnly()
    self:rebuildLoadedPages()
    self:refresh()
end

function methods:reloadFromRemote()
    self:clearPendingFetch()
    self.loaded_pages = {}
    self.loaded_chunks = {}
    self.show_page = 1
    self.pages = 1
    self.has_more = false
    self:loadPage(1, { force_remote = true })
end

return methods
