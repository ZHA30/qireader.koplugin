local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../i18n/po.lua")

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ArticleContent = require("qireader.articlecontent")
local interaction_methods = require("qireader.articledetail.interactions")
local view_module = require("qireader.articledetail.view")
local Screen = Device.screen

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
        title_multilines = true,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function()
            self:showMenuDialog()
        end,
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
    }

    self.button_table = self:createButtonTable()
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

function QiArticleDetailWidget:getBottomButtons()
    return {{
            {
                text = _("Previous"),
                enabled_func = function()
                    return self:canGoPrevArticle()
                end,
                callback = function()
                    self:goToPrevArticle()
                end,
            },
            {
                text = _("Next"),
                enabled_func = function()
                    return self:canGoNextArticle()
                end,
                callback = function()
                    self:goToNextArticle()
                end,
            },
            {
                id = "full_text",
                text = self:getFullTextButtonText(),
                enabled = not self:isFullTextLoading(),
                enabled_func = function()
                    return not self:isFullTextLoading()
                end,
                callback = function()
                    self:loadFullText()
                end,
            },
            {
                text = _("Close"),
                callback = function()
                    self:onClose()
                end,
            },
        }}
end

function QiArticleDetailWidget:createButtonTable()
    return ButtonTable:new{
        width = self.width,
        zero_sep = true,
        show_parent = self,
        buttons = self:getBottomButtons(),
    }
end

function QiArticleDetailWidget:refreshBottomButtons()
    if not self.button_table then
        return
    end
    self.button_table.buttons = self:getBottomButtons()
    self.button_table:free()
    self.button_table:init()
    self:refreshFullTextButtonStyle()
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
