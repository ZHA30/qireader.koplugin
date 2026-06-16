local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local QiArticleDetailWidget = require("qireader.articledetail")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local item_module = require("qireader.articlelist.item")
local Screen = Device.screen

local methods = {}

function methods:init()
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
        bottom_line_color = item_module.separator_color,
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
        background = item_module.separator_color,
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

function methods:resetLayoutCaches()
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

function methods:refreshFooter()
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
    local can_go_next = self.loaded_pages[self.show_page + 1] ~= nil
        or self.has_more
        or self:canMarkCurrentPageReadOnForwardBoundary()
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

function methods:refreshItems()
    self.items_group:clear()
    self:setupItemMetrics()
    local page = self.loaded_pages[self.show_page]
    local item_height = self.item_height
    if not page or #page.entries == 0 then
        table.insert(self.items_group, CenterContainer:new{
            dimen = Geom:new{
                w = self.dimen.w,
                h = self.dimen.h - self.title_bar:getHeight() - self.footer_height,
            },
            TextWidget:new{
                text = self.loading and _("Loading") or _("Empty"),
                face = Font:getFace("smallinfofontbold"),
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
        table.insert(self.items_group, item_module.Widget:new{
            width = self.item_width,
            height = item_height,
            item = item,
            title_font_size = self:getTitleFontSize(),
            onToggleReadState = function(entry)
                self.controller:toggleArticleReadState(entry)
            end,
            onToggleReadLater = function(entry)
                self.controller:toggleReadLater(entry, self)
            end,
            onOpenArticle = function(entry)
                self:prefetchArticleContentsAfterEntry(entry)
                self.controller:openArticleContent(self.target, entry)
            end,
        })
        if i < #page.entries and self.item_spacing > 0 then
            table.insert(self.items_group, CenterContainer:new{
                dimen = Geom:new{ w = self.item_width, h = self.item_spacing },
                LineWidget:new{
                    dimen = Geom:new{ w = self.item_width, h = math.max(1, Size.line.thin) },
                    background = item_module.separator_color,
                },
            })
        end
    end
    if self.item_bottom_spacing > 0 then
        table.insert(self.items_group, VerticalSpan:new{ width = self.item_bottom_spacing })
    end
end

function methods:refresh()
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

function methods:canMarkCurrentPageReadOnForwardBoundary()
    return self.controller
        and self.controller.canMarkArticlePageRead
        and self.controller:canMarkArticlePageRead(self.loaded_pages[self.show_page])
end

function methods:markCurrentPageReadOnForwardBoundary()
    if not self.controller or not self.controller.maybeMarkArticlePageRead then
        return false
    end
    if self.controller:maybeMarkArticlePageRead(self.loaded_pages[self.show_page]) then
        self:refresh()
        return true
    end
    return false
end

function methods:nextPage()
    local next_page = self.show_page + 1
    if self.loaded_pages[next_page] or self.has_more then
        self:loadPage(next_page)
        return true
    end
    return self:markCurrentPageReadOnForwardBoundary()
end

function methods:prevPage()
    if self.show_page <= 1 then
        return false
    end
    self:loadPage(self.show_page - 1)
    return true
end

function methods:goToPage(page)
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

function methods:onSwipe(_arg, ges)
    if not ges or not ges.direction then
        return false
    end
    if ges.direction == "west" then
        return self:nextPage()
    elseif ges.direction == "east" then
        return self:prevPage()
    elseif ges.direction == "south" then
        if self.loading then
            return true
        end
        if self.pending_request and self.pending_request_background then
            self:clearPendingFetch()
        elseif self.pending_request then
            return true
        end
        self:reloadFromRemote()
        return true
    end
    return false
end

function methods:onNextPage()
    return self:nextPage()
end

function methods:onPrevPage()
    return self:prevPage()
end

function methods:onShowMenu()
    self:showMenuDialog()
    return true
end

function methods:onClose()
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

function methods:closeActiveDialog()
    if self.active_dialog then
        local dialog = self.active_dialog
        self.active_dialog = nil
        UIManager:close(dialog)
    end
end

function methods:closeDetailWidget()
    if self.detail_widget then
        local detail_widget = self.detail_widget
        self.detail_widget = nil
        if self.controller and self.controller.article_detail_widget == detail_widget then
            self.controller.article_detail_widget = nil
        end
        if self.controller and self.controller.cancelArticleFullText then
            self.controller:cancelArticleFullText(detail_widget.entry)
        end
        UIManager:close(detail_widget)
    end
end

function methods:showMenuDialog()
    self:closeActiveDialog()
    local dialog
    local function closeDialog()
        if self.active_dialog == dialog then
            self.active_dialog = nil
        end
        UIManager:close(dialog)
    end
    local buttons = {
        {{
            text = self.controller:getArticleSettingsScopeText(self.target),
            callback = function()
                closeDialog()
                self.controller:toggleArticleSettingsScope(self.target, self)
            end,
            align = "left",
        }},
        {{
            text = self.controller:getArticleSetting(self.target, "show_unread_only")
                and _("Unread only: On")
                or _("Unread only: Off"),
            callback = function()
                closeDialog()
                self.controller:toggleArticleUnreadOnly(self.target, self)
            end,
            align = "left",
        }},
        {{
            text = self.controller:getArticleSetting(self.target, "order_oldest_first")
                and _("Oldest first: On")
                or _("Oldest first: Off"),
            callback = function()
                closeDialog()
                self.controller:toggleArticleOrder(self.target, self)
            end,
            align = "left",
        }},
        {{
            text = self.controller:getArticleSetting(self.target, "mark_read_on_page_turn")
                and _("Mark on page turn: On")
                or _("Mark on page turn: Off"),
            callback = function()
                closeDialog()
                self.controller:toggleMarkReadOnPageTurn(self.target, self)
            end,
            align = "left",
        }},
        {{
            text = string.format(_("Items per page: %d"), self:getPerPage()),
            callback = function()
                closeDialog()
                self.controller:showArticleNumberPicker(
                    self.target,
                    self,
                    "items_per_page",
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
    }
    table.insert(buttons, {{
        text = string.format(_("Title font size: %d"), self:getTitleFontSize()),
        callback = function()
            closeDialog()
            self.controller:showArticleNumberPicker(
                self.target,
                self,
                "title_font_size",
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
    }})
    dialog = ButtonDialog:new{
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = function()
            return self.title_bar and self.title_bar.left_button and self.title_bar.left_button.image.dimen or nil
        end,
        tap_close_callback = function()
            if self.active_dialog == dialog then
                self.active_dialog = nil
            end
        end,
    }
    self.active_dialog = dialog
    UIManager:show(dialog)
end

function methods:showArticleDetail(entry, html)
    self:closeDetailWidget()
    local detail_widget = QiArticleDetailWidget:new{
        controller = self.controller,
        owner_widget = self,
        entry = entry,
        title = entry and entry.title or self.title or _("Untitled"),
        html = html,
        on_prev_article = function(current_entry, widget)
            self:showAdjacentArticleDetail(current_entry, -1, widget)
        end,
        on_next_article = function(current_entry, widget)
            self:showAdjacentArticleDetail(current_entry, 1, widget)
        end,
        on_close_article = function(widget)
            if self.detail_widget == widget then
                self.detail_widget = nil
            end
            if self.controller and self.controller.article_detail_widget == widget then
                self.controller.article_detail_widget = nil
            end
            self.controller:onArticleDetailClosed(widget)
        end,
        has_prev_article = function(current_entry)
            return self:canShowAdjacentArticle(current_entry, -1)
        end,
        has_next_article = function(current_entry)
            return self:canShowAdjacentArticle(current_entry, 1)
        end,
    }
    self.detail_widget = detail_widget
    if self.controller then
        self.controller.article_detail_widget = detail_widget
    end
    UIManager:show(detail_widget)
end

function methods:getLoadedEntryIndex(entry)
    local entries = self:getLoadedEntries()
    local entry_id = entry and entry.id or nil
    if not entry then
        return nil, entries
    end
    for i = 1, #entries do
        if entries[i] == entry or (entry_id ~= nil and entries[i].id == entry_id) then
            return i, entries
        end
    end
    return nil, entries
end

function methods:getLoadedPageForEntryIndex(entry_index)
    if not entry_index then
        return nil
    end
    for page_number = 1, self.pages do
        local page = self.loaded_pages[page_number]
        if page
            and page.page_start_index
            and page.page_end_index
            and entry_index >= page.page_start_index
            and entry_index <= page.page_end_index then
            return page_number
        end
    end
    return nil
end

function methods:getContentPrefetchLimit()
    local cache_settings = self.controller and self.controller.settings and self.controller.settings.cache or {}
    return math.max(1, tonumber(cache_settings.content_prefetch_count) or 3)
end

function methods:getContentPrefetchEntriesFromIndex(start_index, max_entries)
    local entries = self:getLoadedEntries()
    local prefetch_entries = {}
    start_index = math.max(1, tonumber(start_index) or 1)
    max_entries = math.max(1, tonumber(max_entries) or self:getContentPrefetchLimit())
    for i = start_index, #entries do
        prefetch_entries[#prefetch_entries + 1] = entries[i]
        if #prefetch_entries >= max_entries then
            return prefetch_entries
        end
    end
    return prefetch_entries
end

function methods:getContentPrefetchEntries()
    local entries = {}
    local cache_settings = self.controller and self.controller.settings and self.controller.settings.cache or {}
    local page_count = math.max(1, tonumber(cache_settings.content_prefetch_pages) or 1)
    local max_entries = self:getContentPrefetchLimit()
    local last_page = math.min(self.pages or self.show_page, self.show_page + page_count - 1)
    for page_number = self.show_page, last_page do
        local page = self.loaded_pages[page_number]
        local page_entries = page and page.entries or {}
        for i = 1, #page_entries do
            entries[#entries + 1] = page_entries[i]
            if #entries >= max_entries then
                return entries
            end
        end
    end
    return entries
end

function methods:prefetchVisibleArticleContents()
    if self.closing or not self.controller or not self.controller.prefetchArticleContents then
        return
    end
    self.controller:prefetchArticleContents(self.target, self:getContentPrefetchEntries(), self)
end

function methods:prefetchArticleContentsAfterEntry(entry)
    if self.closing or not self.controller or not self.controller.prefetchArticleContents then
        return
    end
    local entry_index = self:getLoadedEntryIndex(entry)
    if not entry_index then
        return
    end
    self.controller:prefetchArticleContents(
        self.target,
        self:getContentPrefetchEntriesFromIndex(entry_index + 1),
        self
    )
end

function methods:syncArticleListPageToEntryIndex(entry_index, force_refresh)
    local page_number = self:getLoadedPageForEntryIndex(entry_index)
    if not page_number then
        return
    end
    local page_changed = page_number ~= self.show_page
    local previous_page = self.loaded_pages[self.show_page]
    if page_changed then
        self.show_page = page_number
        if self.controller then
            self.controller:maybeMarkArticlePageRead(previous_page)
        end
    end
    if page_changed or force_refresh then
        self:refresh()
        self:maybePreloadNextChunk()
        self:prefetchVisibleArticleContents()
    end
end

function methods:getAdjacentLoadedArticle(entry, offset)
    local index, entries = self:getLoadedEntryIndex(entry)
    if not index then
        return nil, nil, entries
    end
    local adjacent_index = index + offset
    return entries[adjacent_index], adjacent_index, entries
end

function methods:canLoadNextAdjacentArticle(entry)
    local index, entries = self:getLoadedEntryIndex(entry)
    return index ~= nil and index == #entries and self.has_more == true
end

function methods:canShowAdjacentArticle(entry, offset)
    local adjacent_entry = self:getAdjacentLoadedArticle(entry, offset)
    if adjacent_entry then
        return true
    end
    return offset > 0 and self:canLoadNextAdjacentArticle(entry)
end

function methods:openAdjacentLoadedArticle(current_entry, offset, widget, force_refresh)
    if widget and widget.closing then
        return false
    end
    local next_entry, next_index = self:getAdjacentLoadedArticle(current_entry, offset)
    if not next_entry or not self.controller then
        return false
    end
    self:syncArticleListPageToEntryIndex(next_index, force_refresh)
    self:prefetchArticleContentsAfterEntry(next_entry)
    self.controller:openArticleContent(self.target, next_entry, widget)
    return true
end

function methods:loadNextAdjacentArticle(current_entry, widget)
    if widget and (widget.closing or self.detail_widget ~= widget) then
        return
    end
    if self.loading then
        if self.controller then
            self.controller:showTransientMessage(_("Loading..."))
        end
        return
    end
    if self.pending_request and self.pending_request_background then
        self:clearPendingFetch()
    elseif self.pending_request then
        if self.controller then
            self.controller:showTransientMessage(_("Loading..."))
        end
        return
    end
    local chunk_index = self:getNextLoadableChunkIndex()
    if not chunk_index then
        return
    end
    local current_entry_id = current_entry and current_entry.id or nil
    local err = select(2, self:fetchChunk(chunk_index, { background = true }, function(_chunk, fetch_err)
        if self.closing
            or not widget
            or widget.closing
            or self.detail_widget ~= widget
            or not widget.entry
            or (current_entry_id and widget.entry.id ~= current_entry_id) then
            return
        end
        if fetch_err then
            self:refresh()
            if fetch_err == "error" and self.controller then
                self.controller:showTransientMessage(_("Cannot load articles."))
            end
            return
        end
        if not self:openAdjacentLoadedArticle(current_entry, 1, widget, true) then
            self:refresh()
            if widget.refreshBottomButtons then
                widget:refreshBottomButtons()
            end
        end
    end))
    if err == "busy" then
        if self.controller then
            self.controller:showTransientMessage(_("Loading..."))
        end
    elseif err == "skip" then
        self:openAdjacentLoadedArticle(current_entry, 1, widget)
    elseif err and err ~= "blocked" then
        if self.controller then
            self.controller:showTransientMessage(_("Cannot load articles."))
        end
    end
end

function methods:showAdjacentArticleDetail(current_entry, offset, widget)
    if self:openAdjacentLoadedArticle(current_entry, offset, widget) then
        return
    end
    if offset > 0 and self:canLoadNextAdjacentArticle(current_entry) then
        self:loadNextAdjacentArticle(current_entry, widget)
    end
end

function methods:onCloseWidget()
    self.closing = true
    self:clearPendingFetch()
    self:closeActiveDialog()
    self:closeDetailWidget()
    if self.controller and self.controller.article_widget == self then
        self.controller.article_widget = nil
    end
end

return methods
