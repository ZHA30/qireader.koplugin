local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../i18n/po.lua")

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Screen = Device.screen
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local util = require("util")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local ARTICLE_SEPARATOR_COLOR = Blitbuffer.COLOR_DARK_GRAY
local ARTICLE_DIM_TEXT_COLOR = Blitbuffer.COLOR_GRAY_3
local ARTICLE_ACTION_COLOR = Blitbuffer.COLOR_BLACK
local ARTICLE_ACTION_DIM_COLOR = Blitbuffer.COLOR_DARK_GRAY

local QiArticleItemWidget = InputContainer:extend{
    width = nil,
    height = nil,
    item = nil,
    title_font_size = 18,
    onToggleReadLater = nil,
    onOpenArticle = nil,
}

function QiArticleItemWidget:init()
    self.dimen = Geom:new{
        w = self.width,
        h = self.height,
    }
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
    }
    self:rebuild()
end

function QiArticleItemWidget:rebuild()
    local item = self.item
    local title_face = Font:getFace("smalltfont", self.title_font_size)
    local subtitle_face = Font:getFace("x_smallinfofont")
    local button_padding_v = Size.padding.small
    local button_padding_h = Size.padding.default
    local row_width = self.width
    local row_height = self.height
    local horizontal_padding = Size.padding.large
    local action_gap = Size.span.horizontal_default
    local button_font_size = TextWidget:getFontSizeToFitHeight(
        "cfont",
        math.max(Screen:scaleBySize(24), row_height - button_padding_v * 2),
        button_padding_v
    )
    button_font_size = math.max(12, math.min(button_font_size, 20))
    local action_width = math.max(Screen:scaleBySize(56), math.floor(row_width * 0.16))
    local title_probe = TextWidget:new{
        text = " ",
        face = title_face,
    }
    local subtitle_probe = TextWidget:new{
        text = " ",
        face = subtitle_face,
    }
    local title_line_height = title_probe:getSize().h
    local subtitle_height = subtitle_probe:getSize().h
    title_probe:free()
    subtitle_probe:free()
    local vertical_padding = Size.padding.small
    local subtitle_gap = Size.padding.small
    local text_color = item.status == 0 and Blitbuffer.COLOR_BLACK or ARTICLE_DIM_TEXT_COLOR
    local action_color = item.is_read_later and ARTICLE_ACTION_DIM_COLOR or ARTICLE_ACTION_COLOR
    local title_area_height = math.max(
        title_line_height,
        row_height - subtitle_height - subtitle_gap - vertical_padding * 2
    )
    local action_button = Button:new{
        text = _("Later"),
        width = action_width,
        radius = Size.radius.button,
        bordersize = Size.border.button,
        padding_v = button_padding_v,
        padding_h = button_padding_h,
        text_font_size = button_font_size,
        text_font_bold = false,
        callback = function()
            if self.onToggleReadLater then
                self.onToggleReadLater(item)
            end
        end,
        show_parent = self,
    }
    action_button.label_widget.fgcolor = action_color
    action_button.frame.color = action_color
    local action_button_width = action_button:getSize().w
    local content_width = math.max(
        10,
        row_width - horizontal_padding * 2 - action_gap - action_button_width
    )
    local title_widget = TextBoxWidget:new{
        text = item.title or _("Untitled"),
        face = title_face,
        width = content_width,
        height = title_area_height,
        height_adjust = true,
        line_height = 0.15,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        fgcolor = text_color,
    }
    local subtitle_widget = TextBoxWidget:new{
        text = string.format("%s | %s", item.date_text or "", item.source_title or ""),
        face = subtitle_face,
        width = content_width,
        height = subtitle_height,
        height_adjust = true,
        line_height = 0.1,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        fgcolor = text_color,
    }

    local text_stack = VerticalGroup:new{
        align = "left",
        title_widget,
        VerticalSpan:new{ width = subtitle_gap },
        subtitle_widget,
    }
    local text_block = LeftContainer:new{
        dimen = Geom:new{ w = content_width, h = row_height - vertical_padding * 2 },
        text_stack,
    }
    local action_block = CenterContainer:new{
        dimen = Geom:new{ w = action_button_width, h = row_height },
        action_button,
    }

    self[1] = FrameContainer:new{
        width = row_width,
        height = row_height,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = horizontal_padding },
            text_block,
            HorizontalSpan:new{ width = action_gap },
            action_block,
            HorizontalSpan:new{ width = horizontal_padding },
        },
    }
end

function QiArticleItemWidget:onTap()
    if self.onOpenArticle then
        self.onOpenArticle(self.item)
    end
    return true
end

local QiArticleListWidget = FocusManager:extend{
    controller = nil,
    title = "",
    target = nil,
    show_page = 1,
    pages = 1,
    loaded_pages = nil,
    loaded_chunks = nil,
    preloading_chunks = nil,
    has_more = false,
    loading = false,
    closing = false,
    remote_batch_size = 50,
    preload_pages_before_end = 1,
}

function QiArticleListWidget:init()
    self.loaded_pages = {}
    self.loaded_chunks = {}
    self.preloading_chunks = {}
    self.layout = {}
    self.dimen = Geom:new{
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
        self.key_events.ShowMenu = { { "Menu" } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{
                ges = "swipe",
                range = self.dimen,
            },
        }
    end

    self.title_bar = TitleBar:new{
        width = self.dimen.w,
        align = "center",
        title = self.title,
        title_face = Font:getFace("smallinfofontbold"),
        bottom_line_color = ARTICLE_SEPARATOR_COLOR,
        with_bottom_line = true,
        bottom_line_h_padding = Size.padding.large,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function()
            self:showMenuDialog()
        end,
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
    }

    self.footer_line = LineWidget:new{
        dimen = Geom:new{ w = self.dimen.w, h = Size.line.thick },
        background = ARTICLE_SEPARATOR_COLOR,
    }
    self.footer_group = HorizontalGroup:new{}
    self.footer_container = BottomContainer:new{
        dimen = self.dimen:copy(),
    }
    self.footer_height = Screen:scaleBySize(40)
    self.items_group = VerticalGroup:new{
        align = "left",
    }
    self:refreshFooter()
    self.main_group = VerticalGroup:new{
        self.title_bar,
        self.items_group,
    }

    self[1] = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        OverlapGroup:new{
            dimen = self.dimen:copy(),
            FrameContainer:new{
                padding = 0,
                bordersize = 0,
                background = Blitbuffer.COLOR_WHITE,
                self.main_group,
            },
            self.footer_container,
        },
    }
    self.layout = {
        { self.title_bar.left_button, self.title_bar.right_button },
        { self.footer_first_button, self.footer_prev_button, self.footer_next_button },
    }

    self:loadPage(1)
end

function QiArticleListWidget:resetLayoutCaches()
    if self.items_group and self.items_group.resetLayout then
        self.items_group:resetLayout()
    end
    if self.footer_group and self.footer_group.resetLayout then
        self.footer_group:resetLayout()
    end
    if self.main_group and self.main_group.resetLayout then
        self.main_group:resetLayout()
    end
end

function QiArticleListWidget:getPerPage()
    return self.controller.settings.article_items_per_page or 5
end

function QiArticleListWidget:getRemoteBatchSize()
    return self.remote_batch_size or 50
end

function QiArticleListWidget:getPagesPerChunk()
    local per_page = math.max(1, self:getPerPage())
    local remote_batch = math.max(per_page, self:getRemoteBatchSize())
    return math.max(1, math.ceil(remote_batch / per_page))
end

function QiArticleListWidget:getTitleFontSize()
    return self.controller.settings.article_title_font_size or 18
end

function QiArticleListWidget:getAvailableHeight()
    return self.dimen.h - self.title_bar:getHeight() - (self.footer_height or Screen:scaleBySize(40))
end

function QiArticleListWidget:setupItemMetrics()
    local per_page = math.max(1, self:getPerPage())
    local content_height = math.max(0, self:getAvailableHeight())
    local gap_count = math.max(0, per_page - 1)
    local item_spacing = per_page > 1 and Size.padding.small or 0
    local item_height
    if gap_count > 0 then
        item_height = math.floor((content_height - item_spacing * gap_count) / per_page)
        if item_height < 1 then
            item_spacing = 0
            item_height = math.floor(content_height / per_page)
        end
    else
        item_height = math.floor(content_height / per_page)
    end

    self.item_width = self.dimen.w - Size.padding.large * 2
    self.item_height = math.max(1, item_height)
    self.item_spacing = item_spacing

    local used_height = self.item_height * per_page + self.item_spacing * gap_count
    local remaining = math.max(0, content_height - used_height)
    self.item_top_spacing = math.floor(remaining / 2)
    self.item_bottom_spacing = remaining - self.item_top_spacing
end

function QiArticleListWidget:buildStreamQuery(cursor)
    local query = {
        count = self:getRemoteBatchSize(),
        articleOrder = self.controller.settings.article_order_oldest_first and 1 or 0,
        unreadOnly = self.controller.settings.article_show_unread_only and true or nil,
    }
    if cursor then
        if self.controller.settings.article_order_oldest_first then
            query.newerThan = cursor
        else
            query.olderThan = cursor
        end
    end
    return query
end

function QiArticleListWidget:getStreamId()
    return self.target.stream_id
end

function QiArticleListWidget:getChunkIndexForPage(page)
    return math.floor((page - 1) / self:getPagesPerChunk()) + 1
end

function QiArticleListWidget:getPageOffsetInChunk(page)
    local per_page = math.max(1, self:getPerPage())
    local chunk_index = self:getChunkIndexForPage(page)
    local first_page = (chunk_index - 1) * self:getPagesPerChunk() + 1
    return (page - first_page) * per_page
end

function QiArticleListWidget:buildPageFromChunk(page)
    local chunk_index = self:getChunkIndexForPage(page)
    local chunk = self.loaded_chunks[chunk_index]
    if not chunk then
        return nil
    end
    local per_page = math.max(1, self:getPerPage())
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

function QiArticleListWidget:rebuildLoadedPages()
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

function QiArticleListWidget:getChunkCursor(chunk_index)
    if chunk_index <= 1 then
        return nil
    end
    local previous_chunk = self.loaded_chunks[chunk_index - 1]
    return previous_chunk and previous_chunk.next_cursor or nil
end

function QiArticleListWidget:canLoadChunk(chunk_index)
    if chunk_index <= 1 then
        return true
    end
    return self.loaded_chunks[chunk_index - 1] ~= nil
end

function QiArticleListWidget:fetchChunk(chunk_index, options)
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

function QiArticleListWidget:maybePreloadNextChunk()
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

function QiArticleListWidget:loadPage(page)
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

function QiArticleListWidget:refreshFooter()
    self.footer_group:clear()
    local button_width = math.floor(self.dimen.w * 0.12)
    local center_width = math.floor(self.dimen.w * 0.32)
    self.footer_first_button = Button:new{
        icon = "chevron.first",
        width = button_width,
        bordersize = 0,
        radius = 0,
        callback = function() self:goToPage(1) end,
        show_parent = self,
    }
    self.footer_prev_button = Button:new{
        icon = "chevron.left",
        width = button_width,
        bordersize = 0,
        radius = 0,
        callback = function() self:prevPage() end,
        show_parent = self,
    }
    self.footer_next_button = Button:new{
        icon = "chevron.right",
        width = button_width,
        bordersize = 0,
        radius = 0,
        callback = function() self:nextPage() end,
        show_parent = self,
    }
    local page_text = self.loading and _("Loading...") or string.format(_("Page %d of %d"), self.show_page, self.pages)
    self.footer_page_button = Button:new{
        text = page_text,
        width = center_width,
        bordersize = 0,
        radius = 0,
        text_font_face = "pgfont",
        text_font_bold = false,
        show_parent = self,
    }
    self.footer_page_button:disableWithoutDimming()

    table.insert(self.footer_group, self.footer_first_button)
    table.insert(self.footer_group, self.footer_prev_button)
    table.insert(self.footer_group, self.footer_page_button)
    table.insert(self.footer_group, self.footer_next_button)

    local can_go_prev = self.show_page > 1
    local can_go_next = self.loaded_pages[self.show_page + 1] ~= nil or self.has_more
    self.footer_first_button:enableDisable(can_go_prev)
    self.footer_prev_button:enableDisable(can_go_prev)
    self.footer_next_button:enableDisable(can_go_next)

    local footer = VerticalGroup:new{
        self.footer_line,
        self.footer_group,
    }
    self.footer_height = footer:getSize().h
    self.footer_container[1] = footer
    self.layout = {
        { self.title_bar.left_button, self.title_bar.right_button },
        { self.footer_first_button, self.footer_prev_button, self.footer_next_button },
    }
end

function QiArticleListWidget:refreshItems()
    self.items_group:clear()
    self:setupItemMetrics()
    local page = self.loaded_pages[self.show_page]
    local item_height = self.item_height
    if not page or #page.entries == 0 then
        table.insert(self.items_group, VerticalSpan:new{ width = Size.padding.large })
        table.insert(self.items_group, CenterContainer:new{
            dimen = Geom:new{ w = self.dimen.w, h = item_height },
            TextWidget:new{
                text = self.loading and _("Loading...") or _("No articles."),
                face = Font:getFace("x_smallinfofont"),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        })
        return
    end
    if self.item_top_spacing > 0 then
        table.insert(self.items_group, VerticalSpan:new{ width = self.item_top_spacing })
    end
    for i = 1, #page.entries do
        local item = page.entries[i]
        table.insert(self.items_group, QiArticleItemWidget:new{
            width = self.item_width,
            height = item_height,
            item = item,
            title_font_size = self:getTitleFontSize(),
            onToggleReadLater = function(entry)
                self.controller:toggleReadLater(entry, self)
            end,
            onOpenArticle = function(entry)
                self.controller:openArticleContent(self.target, entry)
            end,
        })
        if i < #page.entries and self.item_spacing > 0 then
            table.insert(self.items_group, CenterContainer:new{
                dimen = Geom:new{ w = self.item_width, h = self.item_spacing },
                LineWidget:new{
                    dimen = Geom:new{ w = self.item_width, h = math.max(1, Size.line.thin) },
                    background = ARTICLE_SEPARATOR_COLOR,
                },
            })
        end
    end
    if self.item_bottom_spacing > 0 then
        table.insert(self.items_group, VerticalSpan:new{ width = self.item_bottom_spacing })
    end
end

function QiArticleListWidget:refresh()
    if self.closing then
        return
    end
    self:refreshFooter()
    self:refreshItems()
    self:resetLayoutCaches()
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function QiArticleListWidget:nextPage()
    local next_page = self.show_page + 1
    if self.loaded_pages[next_page] or self.has_more then
        self:loadPage(next_page)
        return true
    end
    return false
end

function QiArticleListWidget:prevPage()
    if self.show_page <= 1 then
        return false
    end
    self:loadPage(self.show_page - 1)
    return true
end

function QiArticleListWidget:goToPage(page)
    if page < 1 then
        page = 1
    end
    if page == self.show_page then
        return
    end
    if self.loaded_pages[page] or page == self.pages + 1 then
        self:loadPage(page)
    end
end

function QiArticleListWidget:onSwipe(_, ges)
    if not ges or not ges.direction then
        return false
    end
    if ges.direction == "west" then
        return self:nextPage()
    elseif ges.direction == "east" then
        return self:prevPage()
    end
    return false
end

function QiArticleListWidget:onNextPage()
    return self:nextPage()
end

function QiArticleListWidget:onPrevPage()
    return self:prevPage()
end

function QiArticleListWidget:onShowMenu()
    self:showMenuDialog()
    return true
end

function QiArticleListWidget:onClose()
    if self.closing then
        return
    end
    self.closing = true
    if self.controller then
        self.controller:onArticleListClosed(self)
    else
        UIManager:close(self)
    end
end

function QiArticleListWidget:showMenuDialog()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {{
                text = self.controller.settings.article_show_unread_only
                    and _("Unread only: On")
                    or _("Unread only: Off"),
                callback = function()
                    UIManager:close(dialog)
                    self.controller:toggleArticleUnreadOnly(self)
                end,
                align = "left",
            }},
            {{
                text = self.controller.settings.article_order_oldest_first
                    and _("Oldest first: On")
                    or _("Oldest first: Off"),
                callback = function()
                    UIManager:close(dialog)
                    self.controller:toggleArticleOrder(self)
                end,
                align = "left",
            }},
            {{
                text = self.controller.settings.article_mark_read_on_page_turn
                    and _("Mark on page turn: On")
                    or _("Mark on page turn: Off"),
                callback = function()
                    UIManager:close(dialog)
                    self.controller:toggleMarkReadOnPageTurn(self)
                end,
                align = "left",
            }},
            {{
                text = string.format(_("Items per page: %d"), self:getPerPage()),
                callback = function()
                    UIManager:close(dialog)
                    self.controller:showArticleNumberPicker(
                        self,
                        "article_items_per_page",
                        _("Items per page"),
                        {
                            value_min = 1,
                            value_max = 20,
                            default_value = 5,
                            on_apply = function(widget)
                                self.controller:refreshArticleWidgetLayout(widget)
                            end,
                        }
                    )
                end,
                align = "left",
            }},
            {{
                text = string.format(_("Title font size: %d"), self:getTitleFontSize()),
                callback = function()
                    UIManager:close(dialog)
                    self.controller:showArticleNumberPicker(
                        self,
                        "article_title_font_size",
                        _("Title font size"),
                        {
                            value_min = 12,
                            value_max = 48,
                            default_value = 18,
                            on_apply = function(widget)
                                self.controller:refreshArticleWidgetLayout(widget)
                            end,
                        }
                    )
                end,
                align = "left",
            }},
        },
        shrink_unneeded_width = true,
        anchor = function()
            return self.title_bar and self.title_bar.left_button and self.title_bar.left_button.image.dimen or nil
        end,
    }
    UIManager:show(dialog)
end

function QiArticleListWidget:onCloseWidget()
    self.closing = true
end

function QiArticleListWidget:reloadFromFirstPage()
    self:reloadLayoutOnly()
end

function QiArticleListWidget:reloadLayoutOnly()
    self:rebuildLoadedPages()
    self:refresh()
end

function QiArticleListWidget:reloadFromRemote()
    self.loaded_pages = {}
    self.loaded_chunks = {}
    self.show_page = 1
    self.pages = 1
    self.has_more = false
    self:loadPage(1)
end

function QiArticleListWidget.showText(_, title, text)
    UIManager:show(TextViewer:new{
        title = title,
        text = util.htmlToPlainTextIfHtml(text or ""),
        text_type = "book_info",
    })
end

return QiArticleListWidget
