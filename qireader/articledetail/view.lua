local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local FontChooser = require("ui/widget/fontchooser")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local UIManager = require("ui/uimanager")
local ArticleContent = require("qireader.articlecontent")
local FontList = require("fontlist")
local Settings = require("qireader.settings")
local Screen = require("device").screen

local DEFAULT_FONT_SIZE = Settings.article_detail_defaults.font_size
local DEFAULT_FONT_FILE = Settings.article_detail_defaults.font_face
local CUSTOM_FONT_FAMILY = "QiReaderArticleFont"
local DETAIL_SCROLL_BAR_WIDTH = Screen:scaleBySize(4)
local DETAIL_TEXT_SCROLL_SPAN = Screen:scaleBySize(4)

local function escapeCssString(text)
    return (text or ""):gsub("\\", "\\\\"):gsub("'", "\\'")
end

local methods = {}

function methods:ensureFontsLoaded()
    if self._font_list_loaded then
        return
    end
    FontList:getFontList()
    self._font_list_loaded = true
end

function methods:normalizeFontFace()
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

function methods:loadViewSettings()
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

function methods:saveViewSettings()
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

function methods:setFontSize(font_size)
    if self.font_size == font_size then
        return
    end
    self.font_size = font_size
    self:saveViewSettings()
    self:rebuildContent()
end

function methods:setFontFace(font_face)
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

function methods:getCurrentFontLabel()
    self:ensureFontsLoaded()
    return FontChooser.getFontNameText(self.font_face) or self.font_face or DEFAULT_FONT_FILE
end

function methods:getBaseCss()
    if self.css and self.css ~= ArticleContent.DEFAULT_CSS then
        return self.css
    end
    return ArticleContent.getDefaultCss()
end

function methods:getEffectiveCss()
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

function methods:getContentHeight()
    local button_height = self.button_table and self.button_table:getSize().h or 0
    return self.height - self.titlebar:getHeight() - button_height
end

function methods:createScrollWidget()
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
        html_link_tapped_callback = function(link)
            self:onHtmlLinkTapped(link)
        end,
    }
end

function methods:getScrollRatio()
    if not self.scroll_widget or not self.scroll_widget.htmlbox_widget then
        return 0
    end
    local page_count = self.scroll_widget.htmlbox_widget.page_count or 0
    if page_count <= 0 then
        return 0
    end
    return math.max(0, (self.scroll_widget.htmlbox_widget.page_number - 1) / page_count)
end

function methods:rebuildContent()
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

return {
    methods = methods,
    default_font_size = DEFAULT_FONT_SIZE,
    default_font_file = DEFAULT_FONT_FILE,
}
