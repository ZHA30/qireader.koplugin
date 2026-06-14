local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../i18n/po.lua")

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local ArticleContent = require("qireader.articlecontent")
local Screen = Device.screen
local T = require("ffi/util").template

local QiArticleDetailWidget = InputContainer:extend{
    controller = nil,
    entry = nil,
    title = "",
    html = "",
    css = ArticleContent.DEFAULT_CSS,
    closing = false,
    in_search = false,
    active_dialog = nil,
}

function QiArticleDetailWidget:init()
    self.width = Screen:getWidth() - Screen:scaleBySize(30)
    self.height = Screen:getHeight() - Screen:scaleBySize(30)
    self.align = "center"
    self.region = Geom:new{
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.ShowMenu = { { "Menu" } }
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

    local content_height = self.height - self.titlebar:getHeight() - Screen:scaleBySize(52)
    self.scroll_widget = ScrollHtmlWidget:new{
        html_body = self.html,
        css = self.css,
        default_font_size = Screen:scaleBySize(22),
        width = self.width - Size.padding.default * 2,
        height = content_height,
        dialog = self,
        highlight_text_selection = true,
        on_clear_search = function()
            self.in_search = false
            self.scroll_widget:setTapScrollEnabled(true)
            self:updateFindButtonLabel()
        end,
    }

    self.button_table = ButtonTable:new{
        width = self.width - Size.padding.default * 2,
        zero_sep = true,
        buttons = {{
            {
                text = self.entry and self.entry.is_read_later and _("Later: On") or _("Later"),
                callback = function()
                    self:toggleReadLater()
                end,
            },
            {
                id = "find",
                text = _("Find"),
                callback = function()
                    if self.in_search then
                        self:findNext()
                    else
                        self:showFindDialog()
                    end
                end,
                hold_callback = function()
                    if self.in_search then
                        self:showFindDialog()
                    end
                end,
            },
            {
                text = _("Close"),
                callback = function()
                    self:onClose()
                end,
            },
        }},
        show_parent = self,
    }

    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            self.titlebar,
            FrameContainer:new{
                padding = Size.padding.default,
                margin = 0,
                bordersize = 0,
                background = Blitbuffer.COLOR_WHITE,
                self.scroll_widget,
            },
            self.button_table,
        },
    }

    self[1] = self.frame
end

function QiArticleDetailWidget:updateFindButtonLabel()
    local button = self.button_table:getButtonById("find")
    if button then
        button:setText(self.in_search and _("Find next") or _("Find"), button.width)
        button:refresh()
    end
end

function QiArticleDetailWidget:refreshLaterButton()
    local later_button = self.button_table.layout and self.button_table.layout[1] and self.button_table.layout[1][1]
    if later_button and later_button.setText then
        local label = self.entry and self.entry.is_read_later and _("Later: On") or _("Later")
        later_button:setText(label, later_button.width)
        later_button:refresh()
    end
end

function QiArticleDetailWidget:toggleReadLater()
    if not self.controller or not self.entry then
        return
    end
    self.controller:toggleReadLater(self.entry)
    self:refreshLaterButton()
end

function QiArticleDetailWidget:showFindDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Enter text to search for"),
        input = self.search_value,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        if self.active_dialog == dialog then
                            self.active_dialog = nil
                        end
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Find"),
                    is_enter_default = true,
                    callback = function()
                        self.search_value = dialog:getInputText()
                        if self.active_dialog == dialog then
                            self.active_dialog = nil
                        end
                        UIManager:close(dialog)
                        self:findFirst()
                    end,
                },
            },
        },
    }
    self.active_dialog = dialog
    UIManager:show(dialog)
    dialog:onShowKeyboard(true)
end

function QiArticleDetailWidget:findFirst()
    if not self.search_value or self.search_value == "" then
        return
    end
    local content_widget = self.scroll_widget and self.scroll_widget.htmlbox_widget
    if not content_widget then
        return
    end
    local found = content_widget:findText(self.search_value)
    if found then
        self.in_search = true
        self.scroll_widget:setTapScrollEnabled(false)
        self.scroll_widget:_updateScrollBar()
        UIManager:setDirty(self.scroll_widget, function()
            return "partial", self.scroll_widget.dimen
        end)
    else
        self.controller:showTransientMessage(T(_("No matches for '%1' were found."), self.search_value))
        if self.in_search then
            content_widget:clearSearch(true)
        end
    end
    self:updateFindButtonLabel()
end

function QiArticleDetailWidget:findNext()
    local content_widget = self.scroll_widget and self.scroll_widget.htmlbox_widget
    if not content_widget then
        return
    end
    content_widget:findTextNextPage(1)
    self.scroll_widget:_updateScrollBar()
    UIManager:setDirty(self.scroll_widget, function()
        return "partial", self.scroll_widget.dimen
    end)
end

function QiArticleDetailWidget:showMenuDialog()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {{
            {
                text = _("Find"),
                callback = function()
                    if self.active_dialog == dialog then
                        self.active_dialog = nil
                    end
                    UIManager:close(dialog)
                    self:showFindDialog()
                end,
                align = "left",
            },
        }},
        shrink_unneeded_width = true,
        anchor = function()
            return self.titlebar and self.titlebar.left_button and self.titlebar.left_button.image.dimen or nil
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
    if self.active_dialog then
        UIManager:close(self.active_dialog)
        self.active_dialog = nil
    end
    if self.controller then
        self.controller:onArticleDetailClosed(self)
    else
        UIManager:close(self)
    end
end

function QiArticleDetailWidget:onCloseWidget()
    self.closing = true
    self.active_dialog = nil
end

return QiArticleDetailWidget
