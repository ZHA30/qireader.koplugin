local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local FontChooser = require("ui/widget/fontchooser")
local Notification = require("ui/widget/notification")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local Device = require("device")

local methods = {}

function methods.getReadLaterButtonText()
    return _("Later")
end

function methods:isReadLaterActive()
    return self.entry and self.entry.is_read_later == true or false
end

function methods:canGoPrevArticle()
    if self.has_prev_article then
        return self.has_prev_article(self.entry) == true
    end
    return false
end

function methods:canGoNextArticle()
    if self.has_next_article then
        return self.has_next_article(self.entry) == true
    end
    return false
end

function methods:closeActiveDialog()
    if self.active_dialog then
        UIManager:close(self.active_dialog)
        self.active_dialog = nil
    end
end

function methods:toggleReadLater()
    if not self.controller or not self.entry then
        return
    end
    self.controller:toggleReadLater(self.entry, self)
    self:refreshBottomButtons()
    UIManager:setDirty(self, function()
        return "partial", self.movable and self.movable.dimen or self.frame.dimen
    end)
end

function methods:goToPrevArticle()
    if self.on_prev_article then
        self.on_prev_article(self.entry, self)
    end
end

function methods:goToNextArticle()
    if self.on_next_article then
        self.on_next_article(self.entry, self)
    end
end

function methods:showFontDialog(default_font_file)
    self:ensureFontsLoaded()
    local widget
    widget = FontChooser:new{
        title = _("Font"),
        font_file = self.font_face,
        default_font_file = default_font_file,
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

function methods:showMenuDialog(default_font_size, default_font_file)
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
                        default_value = default_font_size,
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
                    self:showFontDialog(default_font_file)
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

function methods:onClose()
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

function methods:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.movable and self.movable.dimen or self.frame.dimen
    end)
    return true
end

function methods:onShowMenu()
    self:showMenuDialog()
    return true
end

function methods:onTapClose(_arg, ges_ev)
    if self.movable and self.movable.dimen and ges_ev.pos:notIntersectWith(self.movable.dimen) then
        self:onClose()
        return true
    end
    return false
end

function methods:onMultiSwipe()
    self:onClose()
    return true
end

function methods:onSwipe(arg, ges)
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

function methods:onHoldStartText(ignored_arg, ges)
    return self.movable:onMovableHold(ignored_arg, ges)
end

function methods:onHoldPanText(ignored_arg, ges)
    if self.movable._touch_pre_pan_was_inside then
        return self.movable:onMovableHoldPan(ignored_arg, ges)
    end
end

function methods:onHoldReleaseText(ignored_arg, ges)
    return self.movable:onMovableHoldRelease(ignored_arg, ges)
end

function methods:onForwardingTouch(arg, ges)
    if not self.content_frame or not self.content_frame.dimen then
        return self.movable:onMovableTouch(arg, ges)
    end
    if not ges.pos:intersectWith(self.content_frame.dimen) then
        return self.movable:onMovableTouch(arg, ges)
    end
    self.movable._touch_pre_pan_was_inside = false
end

function methods:onForwardingPan(arg, ges)
    if self.movable._touch_pre_pan_was_inside or self.movable._moving then
        return self.movable:onMovablePan(arg, ges)
    end
end

function methods:onForwardingPanRelease(arg, ges)
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

function methods:handleTextSelection(text)
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

function methods:onCloseWidget()
    self.closing = true
    self:closeActiveDialog()
    if self.owner_widget and self.owner_widget.detail_widget == self then
        self.owner_widget.detail_widget = nil
    end
    if self.controller and self.controller.article_detail_widget == self then
        self.controller.article_detail_widget = nil
    end
    UIManager:setDirty(nil, function()
        return "partial", self.movable and self.movable.dimen or self.frame.dimen
    end)
end

return methods
