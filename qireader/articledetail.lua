local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../i18n/po.lua")

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FontChooser = require("ui/widget/fontchooser")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Notification = require("ui/widget/notification")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local SpinWidget = require("ui/widget/spinwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ArticleContent = require("qireader.articlecontent")
local FontList = require("fontlist")
local Settings = require("qireader.settings")
local T = require("ffi/util").template
local Screen = Device.screen

local DEFAULT_FONT_SIZE = Settings.article_detail_defaults.font_size
local DEFAULT_FONT_FILE = Settings.article_detail_defaults.font_face
local CUSTOM_FONT_FAMILY = "QiReaderArticleFont"
local DETAIL_SCROLL_BAR_WIDTH = Screen:scaleBySize(4)
local DETAIL_TEXT_SCROLL_SPAN = Screen:scaleBySize(4)

local function escapeCssString(text)
    return (text or ""):gsub("\\", "\\\\"):gsub("'", "\\'")
end

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
    on_prev_article = nil,
    on_next_article = nil,
    on_close_article = nil,
    has_prev_article = nil,
    has_next_article = nil,
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

function QiArticleDetailWidget:ensureFontsLoaded()
    if self._font_list_loaded then
        return
    end
    FontList:getFontList()
    self._font_list_loaded = true
end

function QiArticleDetailWidget:normalizeFontFace()
    self:ensureFontsLoaded()
    if self.font_face and FontChooser.isFontRegistered(self.font_face) then
        return
    end
    if FontChooser.isFontRegistered(DEFAULT_FONT_FILE) then
        self.font_face = DEFAULT_FONT_FILE
        return
    end
    self.font_face = FontList:getFontList()[1]
end

function QiArticleDetailWidget:loadViewSettings()
    local settings = self.controller and self.controller.settings or nil
    local article_detail = settings and settings.article_detail or nil
    if type(article_detail) == "table" then
        if type(article_detail.font_size) == "number" then
            self.font_size = article_detail.font_size
        end
        if type(article_detail.font_face) == "string" and article_detail.font_face ~= "" then
            self.font_face = article_detail.font_face
        end
    end
    self:normalizeFontFace()
end

function QiArticleDetailWidget:saveViewSettings()
    if not self.controller or type(self.controller.settings) ~= "table" then
        return
    end
    if type(self.controller.settings.article_detail) ~= "table" then
        self.controller.settings.article_detail = {}
    end
    self.controller.settings.article_detail.font_size = self.font_size
    self.controller.settings.article_detail.font_face = self.font_face
    self.controller.settings.article_detail.margin_top = nil
    self.controller.settings.article_detail.margin_bottom = nil
    self.controller.settings.article_detail.margin_left = nil
    self.controller.settings.article_detail.margin_right = nil
    self.controller.settings.article_detail.margin_vertical = nil
    self.controller.settings.article_detail.margin_horizontal = nil
    if self.controller.save_settings then
        self.controller.save_settings()
    end
end

function QiArticleDetailWidget:setFontSize(font_size)
    if self.font_size == font_size then
        return
    end
    self.font_size = font_size
    self:saveViewSettings()
    self:rebuildContent()
end

function QiArticleDetailWidget:setFontFace(font_face)
    if not font_face or font_face == "" then
        return
    end
    if self.font_face == font_face then
        return
    end
    self.font_face = font_face
    self:normalizeFontFace()
    self:saveViewSettings()
    self:rebuildContent()
end

function QiArticleDetailWidget:getCurrentFontLabel()
    self:ensureFontsLoaded()
    return FontChooser.getFontNameText(self.font_face) or self.font_face or DEFAULT_FONT_FILE
end

function QiArticleDetailWidget:getBaseCss()
    if self.css and self.css ~= ArticleContent.DEFAULT_CSS then
        return self.css
    end
    return ArticleContent.getDefaultCss()
end

function QiArticleDetailWidget:getEffectiveCss()
    local font_css = ""
    local font_family = "serif"
    if self.font_face then
        font_css = string.format(
            "@font-face { font-family: '%s'; src: url('%s'); }\n",
            CUSTOM_FONT_FAMILY,
            escapeCssString(self.font_face)
        )
        font_family = string.format("'%s', serif", CUSTOM_FONT_FAMILY)
    end
    return string.format(
        "%s\n%sbody { font-family: %s; }\npre, code { font-family: %s; }\n",
        self:getBaseCss(),
        font_css,
        font_family,
        font_family
    )
end

function QiArticleDetailWidget:getContentHeight()
    local button_height = self.button_table and self.button_table:getSize().h or 0
    return self.height - self.titlebar:getHeight() - button_height
end

function QiArticleDetailWidget:createScrollWidget()
    return ScrollHtmlWidget:new{
        html_body = self.html,
        css = self:getEffectiveCss(),
        default_font_size = Screen:scaleBySize(self.font_size),
        width = self.width,
        height = self:getContentHeight(),
        scroll_bar_width = DETAIL_SCROLL_BAR_WIDTH,
        text_scroll_span = DETAIL_TEXT_SCROLL_SPAN,
        dialog = self,
        highlight_text_selection = true,
    }
end

function QiArticleDetailWidget.getReadLaterButtonText()
    return _("Later")
end

function QiArticleDetailWidget:isReadLaterActive()
    return self.entry and self.entry.is_read_later == true or false
end

function QiArticleDetailWidget:canGoPrevArticle()
    if self.has_prev_article then
        return self.has_prev_article(self.entry) == true
    end
    return false
end

function QiArticleDetailWidget:canGoNextArticle()
    if self.has_next_article then
        return self.has_next_article(self.entry) == true
    end
    return false
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
                id = "read_later",
                text = QiArticleDetailWidget.getReadLaterButtonText(),
                background = self:isReadLaterActive() and Blitbuffer.COLOR_LIGHT_GRAY or nil,
                callback = function()
                    self:toggleReadLater()
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
end

function QiArticleDetailWidget:updateArticleDetail(entry, html, title)
    self.entry = entry or self.entry
    self.html = html or self.html
    self.title = title or (entry and entry.title) or self.title
    if self.titlebar then
        self.titlebar:setTitle(self.title)
    end
    self:refreshBottomButtons()
    self:rebuildContent()
end

function QiArticleDetailWidget:getScrollRatio()
    if not self.scroll_widget or not self.scroll_widget.htmlbox_widget then
        return 0
    end
    local page_count = self.scroll_widget.htmlbox_widget.page_count or 0
    if page_count <= 0 then
        return 0
    end
    return math.max(0, (self.scroll_widget.htmlbox_widget.page_number - 1) / page_count)
end

function QiArticleDetailWidget:rebuildContent()
    if not self.scroll_widget or not self.content_frame then
        return
    end
    local old_widget = self.scroll_widget
    local ratio = self:getScrollRatio()
    self.scroll_widget = self:createScrollWidget()
    self.content_frame[1] = self.scroll_widget
    if ratio > 0 then
        self.scroll_widget:scrollToRatio(ratio)
    end
    if old_widget.free then
        old_widget:free()
    end
    if self.movable and self.movable.alpha then
        self.movable.alpha = nil
    end
    UIManager:setDirty(self, function()
        return "partial", self.movable and self.movable.dimen or self.frame.dimen
    end)
end

function QiArticleDetailWidget:closeActiveDialog()
    if self.active_dialog then
        UIManager:close(self.active_dialog)
        self.active_dialog = nil
    end
end

function QiArticleDetailWidget:toggleReadLater()
    if not self.controller or not self.entry then
        return
    end
    self.controller:toggleReadLater(self.entry)
    self:refreshBottomButtons()
    UIManager:setDirty(self, function()
        return "partial", self.movable and self.movable.dimen or self.frame.dimen
    end)
end

function QiArticleDetailWidget:goToPrevArticle()
    if self.on_prev_article then
        self.on_prev_article(self.entry, self)
    end
end

function QiArticleDetailWidget:goToNextArticle()
    if self.on_next_article then
        self.on_next_article(self.entry, self)
    end
end

function QiArticleDetailWidget:showFontDialog()
    self:ensureFontsLoaded()
    local widget
    widget = FontChooser:new{
        title = _("Font"),
        font_file = self.font_face,
        default_font_file = DEFAULT_FONT_FILE,
        keep_shown_on_apply = true,
        callback = function(file)
            self:setFontFace(file)
        end,
        close_callback = function()
            if self.active_dialog == widget then
                self.active_dialog = nil
            end
        end,
    }
    self.active_dialog = widget
    UIManager:show(widget)
end

function QiArticleDetailWidget:showMenuDialog()
    self:closeActiveDialog()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {{
            {
                text_func = function()
                    return string.format(_("Font size: %d"), self.font_size)
                end,
                callback = function()
                    if self.active_dialog == dialog then
                        self.active_dialog = nil
                    end
                    UIManager:close(dialog)
                    local widget
                    widget = SpinWidget:new{
                        title_text = _("Font size"),
                        value = self.font_size,
                        value_min = 12,
                        value_max = 30,
                        default_value = DEFAULT_FONT_SIZE,
                        keep_shown_on_apply = true,
                        callback = function(spin)
                            self:setFontSize(spin.value)
                        end,
                        close_callback = function()
                            if self.active_dialog == widget then
                                self.active_dialog = nil
                            end
                        end,
                    }
                    self.active_dialog = widget
                    UIManager:show(widget)
                end,
                align = "left",
            }},
            {{
                text_func = function()
                    return T(_("Font: %1"), BD.wrap(self:getCurrentFontLabel()))
                end,
                callback = function()
                    if self.active_dialog == dialog then
                        self.active_dialog = nil
                    end
                    UIManager:close(dialog)
                    self:showFontDialog()
                end,
                align = "left",
            },
        }},
        shrink_unneeded_width = true,
        anchor = function()
            return self.titlebar and self.titlebar.left_button and self.titlebar.left_button.image.dimen or nil
        end,
        on_close = function()
            if self.active_dialog == dialog then
                self.active_dialog = nil
            end
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

function QiArticleDetailWidget:onClose()
    if self.closing then
        return
    end
    self.closing = true
    self:closeActiveDialog()
    if self.on_close_article then
        self.on_close_article(self)
        return true
    end
    if self.controller then
        self.controller:onArticleDetailClosed(self)
    else
        UIManager:close(self)
    end
    return true
end

function QiArticleDetailWidget:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.movable and self.movable.dimen or self.frame.dimen
    end)
    return true
end

function QiArticleDetailWidget:onShowMenu()
    self:showMenuDialog()
    return true
end

function QiArticleDetailWidget:onTapClose(_arg, ges_ev)
    if self.movable and self.movable.dimen and ges_ev.pos:notIntersectWith(self.movable.dimen) then
        self:onClose()
        return true
    end
    return false
end

function QiArticleDetailWidget:onMultiSwipe()
    self:onClose()
    return true
end

function QiArticleDetailWidget:onSwipe(arg, ges)
    if self.content_frame and self.content_frame.dimen and ges.pos:intersectWith(self.content_frame.dimen) then
        local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
        if direction == "west" then
            self.scroll_widget:scrollText(1)
            return true
        elseif direction == "east" then
            self.scroll_widget:scrollText(-1)
            return true
        else
            UIManager:setDirty(nil, "full")
            return false
        end
    end
    return self.movable:onMovableSwipe(arg, ges)
end

function QiArticleDetailWidget:onHoldStartText(ignored_arg, ges)
    return self.movable:onMovableHold(ignored_arg, ges)
end

function QiArticleDetailWidget:onHoldPanText(ignored_arg, ges)
    if self.movable._touch_pre_pan_was_inside then
        return self.movable:onMovableHoldPan(ignored_arg, ges)
    end
end

function QiArticleDetailWidget:onHoldReleaseText(ignored_arg, ges)
    return self.movable:onMovableHoldRelease(ignored_arg, ges)
end

function QiArticleDetailWidget:onForwardingTouch(arg, ges)
    if not self.content_frame or not self.content_frame.dimen then
        return self.movable:onMovableTouch(arg, ges)
    end
    if not ges.pos:intersectWith(self.content_frame.dimen) then
        return self.movable:onMovableTouch(arg, ges)
    end
    self.movable._touch_pre_pan_was_inside = false
end

function QiArticleDetailWidget:onForwardingPan(arg, ges)
    if self.movable._touch_pre_pan_was_inside or self.movable._moving then
        return self.movable:onMovablePan(arg, ges)
    end
end

function QiArticleDetailWidget:onForwardingPanRelease(arg, ges)
    if ges.from_mousewheel and ges.relative and ges.relative.y then
        if ges.relative.y < 0 then
            self.scroll_widget:onScrollDown()
        elseif ges.relative.y > 0 then
            self.scroll_widget:onScrollUp()
        end
        return true
    end
    return self.movable:onMovablePanRelease(arg, ges)
end

function QiArticleDetailWidget:handleTextSelection(text)
    if Device:hasClipboard() then
        Device.input.setClipboardText(text)
        UIManager:show(Notification:new{
            text = _("Selection copied to clipboard."),
        })
    end
    if self.scroll_widget and self.scroll_widget.htmlbox_widget then
        self.scroll_widget.htmlbox_widget:scheduleClearHighlightAndRedraw()
    end
end

function QiArticleDetailWidget:onCloseWidget()
    self.closing = true
    self.active_dialog = nil
    UIManager:setDirty(nil, function()
        return "partial", self.movable and self.movable.dimen or self.frame.dimen
    end)
end

return QiArticleDetailWidget
