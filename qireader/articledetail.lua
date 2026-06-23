local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../i18n/po.lua")

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Icons = require("qireader.icons")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ArticleContent = require("qireader.articlecontent")
local interaction_methods = require("qireader.articledetail.interactions")
local view_module = require("qireader.articledetail.view")
local Screen = Device.screen
local DETAIL_ACTION_ICON_SIZE = Icons.size.detail

local function repaintWidget(widget)
    if widget and widget.dimen and widget.dimen.x and widget.dimen.y then
        UIManager:widgetRepaint(widget, widget.dimen.x, widget.dimen.y)
        UIManager:setDirty(nil, function()
            return "ui", widget.dimen
        end)
    end
end

local PluginIconButton = Button:extend{
    icon_name = nil,
    icon_state = nil,
    disabled_icon_name = nil,
    disabled_icon_state = nil,
    bordersize = 0,
    margin = 0,
    padding = Size.padding.buttontable,
}

function PluginIconButton:init()
    if self.text then
        return Button.init(self)
    end

    if self.enabled_func then
        self.enabled = self.enabled_func() == true
    end

    if not self.padding_h then
        self.padding_h = self.padding
    end
    if not self.padding_v then
        self.padding_v = self.padding
    end

    local outer_pad_width = 2 * self.padding_h + 2 * self.margin + 2 * self.bordersize
    local current_icon_name = self.icon_name
    local current_icon_state = self.icon_state
    if not self.enabled and self.disabled_icon_name then
        current_icon_name = self.disabled_icon_name
        current_icon_state = self.disabled_icon_state
    end
    self._current_icon_name = current_icon_name
    self._current_icon_state = current_icon_state
    self._current_icon_dim = not self.enabled
    self.label_widget = Icons.widget(current_icon_name, {
        state = current_icon_state,
        width = self.icon_width or DETAIL_ACTION_ICON_SIZE,
        height = self.icon_height or DETAIL_ACTION_ICON_SIZE,
        dim = not self.enabled,
    })
    self._min_needed_width = (self.icon_width or DETAIL_ACTION_ICON_SIZE) + outer_pad_width

    local widget_size = self.label_widget:getSize()
    local label_container_height = self.height or widget_size.h
    local inner_width
    if self.width then
        inner_width = self.width - outer_pad_width
    else
        inner_width = widget_size.w
    end

    self.label_container = CenterContainer:new{
        dimen = Geom:new{
            w = inner_width,
            h = label_container_height,
        },
        self.label_widget,
    }

    local background_color, border_color, radius
    if self.background then
        background_color = self.background
        border_color = background_color
        radius = self.radius or Size.radius.button
    else
        background_color = Blitbuffer.COLOR_WHITE
        radius = self.radius
    end
    self.frame = FrameContainer:new{
        margin = self.margin,
        show_parent = self.show_parent,
        bordersize = self.bordersize,
        background = background_color,
        color = border_color,
        radius = radius,
        padding_top = self.padding_v,
        padding_bottom = self.padding_v,
        padding_left = self.padding_h,
        padding_right = self.padding_h,
        self.label_container,
    }
    if self.preselect then
        self.frame.invert = true
    end
    self.dimen = self.frame:getSize()
    self[1] = self.frame
    self.ges_events = {
        TapSelectButton = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
        HoldSelectButton = {
            GestureRange:new{
                ges = "hold",
                range = self.dimen,
            },
        },
        HoldReleaseSelectButton = {
            GestureRange:new{
                ges = "hold_release",
                range = self.dimen,
            },
        },
    }
end

function PluginIconButton:onTapSelectButton(arg, ges)
    local callback = self.callback
    if callback then
        self.callback = function()
            callback(ges)
        end
    end
    local ok, handled = xpcall(function()
        return Button.onTapSelectButton(self, arg, ges)
    end, debug.traceback)
    self.callback = callback
    if not ok then
        error(handled)
    end
    return handled
end

function PluginIconButton:refreshIcon()
    if self.enabled_func then
        self.enabled = self.enabled_func() == true
    end
    local current_icon_name = self.icon_name
    local current_icon_state = self.icon_state
    if not self.enabled and self.disabled_icon_name then
        current_icon_name = self.disabled_icon_name
        current_icon_state = self.disabled_icon_state
    end
    local current_icon_dim = not self.enabled
    if self._current_icon_name == current_icon_name
        and self._current_icon_state == current_icon_state
        and self._current_icon_dim == current_icon_dim then
        return false
    end
    self._current_icon_name = current_icon_name
    self._current_icon_state = current_icon_state
    self._current_icon_dim = current_icon_dim
    local old_icon = self.label_widget
    self.label_widget = Icons.widget(current_icon_name, {
        state = current_icon_state,
        width = self.icon_width or DETAIL_ACTION_ICON_SIZE,
        height = self.icon_height or DETAIL_ACTION_ICON_SIZE,
        dim = current_icon_dim,
    })
    if self.label_container then
        self.label_container[1] = self.label_widget
    end
    if old_icon and old_icon.free then
        old_icon:free()
    end
    repaintWidget(self)
    return true
end

local ArticleBottomBar = InputContainer:extend{
    width = nil,
    show_parent = nil,
    owner = nil,
}

function ArticleBottomBar:init()
    local button_height = Screen:scaleBySize(40)
    local sep_width = Size.line.medium
    local button_width = math.floor((self.width - sep_width * 5) / 6)

    self.prev_button = PluginIconButton:new{
        width = button_width,
        height = button_height,
        icon_name = "article-prev",
        disabled_icon_name = "article-prev-disabled",
        icon_width = DETAIL_ACTION_ICON_SIZE,
        icon_height = DETAIL_ACTION_ICON_SIZE,
        enabled_func = function()
            return self.owner:canGoPrevArticle()
        end,
        callback = function()
            self.owner:goToPrevArticle()
        end,
        show_parent = self.show_parent,
    }
    local fulltext_icon_state = nil
    if self.owner:isFullTextLoaded() then
        fulltext_icon_state = "active"
    elseif self.owner:isFullTextLoading() then
        fulltext_icon_state = "disabled"
    end
    self.full_text_button = PluginIconButton:new{
        enabled_func = function()
            return not self.owner:isFullTextLoading()
        end,
        icon_name = "fulltext",
        icon_state = fulltext_icon_state,
        disabled_icon_name = "fulltext",
        disabled_icon_state = "disabled",
        icon_width = DETAIL_ACTION_ICON_SIZE,
        icon_height = DETAIL_ACTION_ICON_SIZE,
        callback = function()
            self.owner:loadFullText()
        end,
        width = button_width,
        height = button_height,
        show_parent = self.show_parent,
    }
    self.tags_button = PluginIconButton:new{
        icon_name = "tag",
        icon_state = self.owner:hasArticleTags() and "active" or nil,
        disabled_icon_name = "tag",
        icon_width = DETAIL_ACTION_ICON_SIZE,
        icon_height = DETAIL_ACTION_ICON_SIZE,
        callback = function(ges)
            self.owner:showTagsDialog(ges)
        end,
        width = button_width,
        height = button_height,
        show_parent = self.show_parent,
    }
    local read_later_icon_state = nil
    if self.owner:isReadLaterActive() then
        read_later_icon_state = "active"
    end
    self.read_later_button = PluginIconButton:new{
        icon_name = "read-later",
        icon_state = read_later_icon_state,
        disabled_icon_name = "read-later",
        icon_width = DETAIL_ACTION_ICON_SIZE,
        icon_height = DETAIL_ACTION_ICON_SIZE,
        callback = function()
            self.owner:toggleReadLater()
        end,
        width = button_width,
        height = button_height,
        show_parent = self.show_parent,
    }
    self.next_button = PluginIconButton:new{
        width = button_width,
        height = button_height,
        icon_name = "article-next",
        disabled_icon_name = "article-next-disabled",
        icon_width = DETAIL_ACTION_ICON_SIZE,
        icon_height = DETAIL_ACTION_ICON_SIZE,
        enabled_func = function()
            return self.owner:canGoNextArticle()
        end,
        callback = function()
            self.owner:goToNextArticle()
        end,
        show_parent = self.show_parent,
    }
    self.close_button = PluginIconButton:new{
        icon_name = "article-close",
        disabled_icon_name = "article-close",
        icon_width = DETAIL_ACTION_ICON_SIZE,
        icon_height = DETAIL_ACTION_ICON_SIZE,
        callback = function()
            self.owner:onClose()
        end,
        width = button_width,
        height = button_height,
        show_parent = self.show_parent,
    }
    local vertical_sep = function(height)
        return LineWidget:new{
            background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{
                w = sep_width,
                h = height,
            },
        }
    end
    local row_height = self.prev_button:getSize().h
    self.group = HorizontalGroup:new{
        align = "center",
        self.prev_button,
        vertical_sep(row_height),
        self.full_text_button,
        vertical_sep(row_height),
        self.tags_button,
        vertical_sep(row_height),
        self.read_later_button,
        vertical_sep(row_height),
        self.next_button,
        vertical_sep(row_height),
        self.close_button,
    }
    self.container = VerticalGroup:new{
        width = self.width,
        LineWidget:new{
            background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{
                w = self.width,
                h = sep_width,
            },
        },
        VerticalSpan:new{
            width = Size.span.vertical_default,
        },
        self.group,
        VerticalSpan:new{
            width = Size.span.vertical_default,
        },
    }
    self[1] = self.container
    self.dimen = self.container:getSize()
end

function ArticleBottomBar:refreshButtonStates()
    local fulltext_icon_state = nil
    if self.owner:isFullTextLoaded() then
        fulltext_icon_state = "active"
    elseif self.owner:isFullTextLoading() then
        fulltext_icon_state = "disabled"
    end
    self.full_text_button.icon_state = fulltext_icon_state
    self.tags_button.icon_state = self.owner:hasArticleTags() and "active" or nil
    self.read_later_button.icon_state = self.owner:isReadLaterActive() and "active" or nil

    local changed = false
    changed = self.prev_button:refreshIcon() or changed
    changed = self.full_text_button:refreshIcon() or changed
    changed = self.tags_button:refreshIcon() or changed
    changed = self.read_later_button:refreshIcon() or changed
    changed = self.next_button:refreshIcon() or changed
    changed = self.close_button:refreshIcon() or changed
    return changed
end

function ArticleBottomBar:getButtonById(id)
    if id == "full_text" then
        return self.full_text_button
    elseif id == "tags" then
        return self.tags_button
    elseif id == "read_later" then
        return self.read_later_button
    end
    return nil
end

local DEFAULT_FONT_SIZE = view_module.default_font_size
local DEFAULT_FONT_FILE = view_module.default_font_file

local QiArticleDetailWidget = InputContainer:extend{
    controller = nil,
    entry = nil,
    title = "",
    html = "",
    css = ArticleContent.DEFAULT_CSS,
    closing = false,
    active_dialog = nil,
    font_face = DEFAULT_FONT_FILE,
    font_size = DEFAULT_FONT_SIZE,
    full_text_state = "idle",
    full_text_entry_id = nil,
    full_text_original = nil,
    pending_content_entry_id = nil,
    on_prev_article = nil,
    on_next_article = nil,
    on_close_article = nil,
    has_prev_article = nil,
    has_next_article = nil,
    owner_widget = nil,
}

function QiArticleDetailWidget:init()
    self:loadViewSettings()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self.width = screen_w - Screen:scaleBySize(30)
    self.height = screen_h - Screen:scaleBySize(30)
    self.align = "center"
    self.region = Geom:new{
        w = screen_w,
        h = screen_h,
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.ShowMenu = { { "Menu" } }
    end
    if Device:isTouchDevice() then
        local range = Geom:new{
            w = screen_w,
            h = screen_h,
        }
        self.ges_events = {
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = range,
                },
            },
            Swipe = {
                GestureRange:new{
                    ges = "swipe",
                    range = range,
                },
            },
            MultiSwipe = {
                GestureRange:new{
                    ges = "multiswipe",
                    range = range,
                },
            },
            HoldStartText = {
                GestureRange:new{
                    ges = "hold",
                    range = range,
                },
            },
            HoldPanText = {
                GestureRange:new{
                    ges = "hold_pan",
                    range = range,
                },
            },
            HoldReleaseText = {
                GestureRange:new{
                    ges = "hold_release",
                    range = range,
                },
                args = function(text, hold_duration)
                    self:handleTextSelection(text, hold_duration)
                end,
            },
            ForwardingTouch = { GestureRange:new{ ges = "touch", range = range } },
            ForwardingPan = { GestureRange:new{ ges = "pan", range = range } },
            ForwardingPanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        }
    end

    self.titlebar = TitleBar:new{
        width = self.width,
        align = "left",
        with_bottom_line = true,
        title = self.title,
        title_multilines = false,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function()
            self:showMenuDialog()
        end,
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
    }

    self.button_table = self:createBottomBar()
    self:refreshFullTextButtonStyle()
    self.scroll_widget = self:createScrollWidget()
    self.content_frame = FrameContainer:new{
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.scroll_widget,
    }

    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            self.titlebar,
            CenterContainer:new{
                dimen = Geom:new{
                    w = self.width,
                    h = self.content_frame:getSize().h,
                },
                self.content_frame,
            },
            CenterContainer:new{
                dimen = Geom:new{
                    w = self.width,
                    h = self.button_table:getSize().h,
                },
                self.button_table,
            },
        },
    }

    self.movable = MovableContainer:new{
        ignore_events = {
            "swipe", "hold", "hold_release", "hold_pan",
            "touch", "pan", "pan_release",
        },
        is_movable_with_keys = false,
        self.frame,
    }
    self[1] = WidgetContainer:new{
        align = self.align,
        dimen = self.region,
        self.movable,
    }
end

function QiArticleDetailWidget:createBottomBar()
    return ArticleBottomBar:new{
        width = self.width,
        owner = self,
        show_parent = self,
    }
end

function QiArticleDetailWidget:refreshBottomButtons()
    if not self.button_table then
        return
    end
    local old_bar = self.button_table
    self.button_table = self:createBottomBar()
    if self.frame and self.frame[1] and self.frame[1][3] and self.frame[1][3][1] then
        self.frame[1][3][1] = self.button_table
        self.frame[1][3].dimen.h = self.button_table:getSize().h
    end
    if old_bar and old_bar.free then
        old_bar:free()
    end
end

function QiArticleDetailWidget:refreshBottomButtonStates()
    if self.button_table and self.button_table.refreshButtonStates then
        return self.button_table:refreshButtonStates()
    end
    self:refreshBottomButtons()
    if self.movable or self.frame then
        UIManager:setDirty(self, function()
            return "partial", self.movable and self.movable.dimen or self.frame.dimen
        end)
    end
    return true
end

function QiArticleDetailWidget:updateArticleDetail(entry, html, title)
    local current_entry_id = self.entry and self.entry.id or nil
    local next_entry = entry or self.entry
    local next_entry_id = next_entry and next_entry.id or nil
    if current_entry_id ~= next_entry_id then
        self:resetFullTextState(next_entry_id)
    end
    self.entry = entry or self.entry
    self.html = html or self.html
    self.title = title or (entry and entry.title) or self.title
    self.pending_content_entry_id = nil
    if self.titlebar then
        self.titlebar:setTitle(self.title)
    end
    self:refreshBottomButtons()
    self:rebuildContent()
end

local function installMethods(target, methods)
    for name, value in pairs(methods) do
        target[name] = value
    end
end

installMethods(QiArticleDetailWidget, view_module.methods)
installMethods(QiArticleDetailWidget, interaction_methods)

return QiArticleDetailWidget
