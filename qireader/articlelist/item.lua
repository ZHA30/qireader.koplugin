local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Icons = require("qireader.icons")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local ARTICLE_SEPARATOR_COLOR = Blitbuffer.COLOR_DARK_GRAY
local ARTICLE_DIM_TEXT_COLOR = Blitbuffer.COLOR_GRAY_3
local ARTICLE_ITEM_HORIZONTAL_PADDING = Size.padding.large
local ARTICLE_ITEM_VERTICAL_PADDING = Size.padding.small
local ARTICLE_ITEM_SUBTITLE_GAP = Size.padding.small
local ARTICLE_ITEM_ACTION_GAP = Size.span.horizontal_default
local ARTICLE_ITEM_MIN_CONTENT_WIDTH = 10
local ARTICLE_BUTTON_MIN_HEIGHT = Screen:scaleBySize(24)
local ARTICLE_STATUS_MIN_WIDTH = Screen:scaleBySize(18)
local ARTICLE_BUTTON_MAX_FONT_SIZE = 20
local ARTICLE_BUTTON_MIN_FONT_SIZE = 12
local ARTICLE_ICON_SIZE = Icons.size.list
local ARTICLE_STATUS_ICON_SIZE = math.max(1, math.floor(ARTICLE_ICON_SIZE * 0.75))
local ARTICLE_STATUS_SIDE_PADDING = math.max(0, ARTICLE_ITEM_HORIZONTAL_PADDING - Screen:scaleBySize(6))
local ARTICLE_STATUS_GAP = math.max(0, ARTICLE_ITEM_ACTION_GAP - Screen:scaleBySize(4))

local function repaintWidget(widget)
    if widget and widget.dimen and widget.dimen.x and widget.dimen.y then
        UIManager:widgetRepaint(widget, widget.dimen.x, widget.dimen.y)
        UIManager:setDirty(nil, function()
            return "ui", widget.dimen
        end)
    end
end

local ArticleContentTapArea = InputContainer:extend{
    width = nil,
    height = nil,
    callback = nil,
}

function ArticleContentTapArea:init()
    self.dimen = Geom:new{
        w = self.width,
        h = self.height,
    }
    self.ges_events = {
        TapOpenArticle = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
    }
end

local ArticleActionIconButton = InputContainer:extend{
    width = nil,
    height = nil,
    callback = nil,
    icon_name = "read-later",
    icon_state = nil,
    background_color = Blitbuffer.COLOR_WHITE,
}

function ArticleActionIconButton:init()
    self.icon = Icons.widget(self.icon_name, {
        state = self.icon_state,
        size = ARTICLE_ICON_SIZE,
    })
    self.frame = FrameContainer:new{
        width = self.width,
        height = self.height,
        padding = 0,
        margin = 0,
        radius = Size.radius.button,
        bordersize = 0,
        background = self.background_color,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            self.icon,
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        TapSelectAction = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
    }
end

function ArticleActionIconButton:onTapSelectAction(_arg, ges)
    if self.callback then
        self.callback(ges)
    end
    return true
end

function ArticleActionIconButton:setIconState(icon_state, options)
    if self.icon_state == icon_state then
        return false
    end
    self.icon_state = icon_state
    local old_icon = self.icon
    self.icon = Icons.widget(self.icon_name, {
        state = self.icon_state,
        size = ARTICLE_ICON_SIZE,
    })
    if self.frame and self.frame[1] then
        self.frame[1][1] = self.icon
    end
    if old_icon and old_icon.free then
        old_icon:free()
    end
    if not options or options.repaint ~= false then
        repaintWidget(self)
    end
    return true
end

local ArticleStatusIcon = InputContainer:extend{
    width = nil,
    height = nil,
    icon_name = "article-unread",
    callback = nil,
}

function ArticleStatusIcon:init()
    self.icon = Icons.widget(self.icon_name, { size = ARTICLE_STATUS_ICON_SIZE })
    self.icon_container = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        self.icon,
    }
    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.icon_container,
    }
    self.dimen = self[1]:getSize()
    self.ges_events = {
        TapToggleStatus = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
    }
end

function ArticleStatusIcon:onTapToggleStatus()
    if self.callback then
        self.callback()
    end
    return true
end

function ArticleStatusIcon:setIconName(icon_name, options)
    if self.icon_name == icon_name then
        return false
    end
    self.icon_name = icon_name
    local old_icon = self.icon
    self.icon = Icons.widget(self.icon_name, { size = ARTICLE_STATUS_ICON_SIZE })
    if self.icon_container then
        self.icon_container[1] = self.icon
    end
    if old_icon and old_icon.free then
        old_icon:free()
    end
    if not options or options.repaint ~= false then
        repaintWidget(self)
    end
    return true
end

function ArticleContentTapArea:onTapOpenArticle()
    if self.callback then
        self.callback()
    end
    return true
end

local function measureTextBoxLineHeight(face, line_height)
    local probe = TextBoxWidget:new{
        text = " ",
        face = face,
        width = Screen:scaleBySize(120),
        height = Screen:scaleBySize(120),
        height_adjust = true,
        line_height = line_height,
    }
    local height = probe:getSize().h
    probe:free()
    return height
end

local function getButtonFontSizeForHeight(row_height, padding_v)
    local button_font_size = TextWidget:getFontSizeToFitHeight(
        "cfont",
        math.max(ARTICLE_BUTTON_MIN_HEIGHT, row_height - padding_v * 2),
        padding_v
    )
    return math.max(ARTICLE_BUTTON_MIN_FONT_SIZE, math.min(button_font_size, ARTICLE_BUTTON_MAX_FONT_SIZE))
end

local function getArticleRowMetrics(row_width, row_height, title_font_size)
    local title_face = Font:getFace("smalltfont", title_font_size)
    local subtitle_face = Font:getFace("x_smallinfofont")
    local button_padding_v = Size.padding.small
    local button_padding_h = Size.padding.default
    local title_line_height = measureTextBoxLineHeight(title_face, 0.15)
    local subtitle_height = measureTextBoxLineHeight(subtitle_face, 0.1)
    local button_font_size = getButtonFontSizeForHeight(row_height, button_padding_v)
    local status_width = math.max(ARTICLE_STATUS_MIN_WIDTH, math.floor(row_width * 0.05))
    local action_width = status_width

    return {
        title_face = title_face,
        subtitle_face = subtitle_face,
        title_line_height = title_line_height,
        subtitle_height = subtitle_height,
        button_padding_v = button_padding_v,
        button_padding_h = button_padding_h,
        button_font_size = button_font_size,
        status_width = status_width,
        action_width = action_width,
        horizontal_padding = ARTICLE_ITEM_HORIZONTAL_PADDING,
        status_side_padding = ARTICLE_STATUS_SIDE_PADDING,
        vertical_padding = ARTICLE_ITEM_VERTICAL_PADDING,
        subtitle_gap = ARTICLE_ITEM_SUBTITLE_GAP,
        action_gap = ARTICLE_ITEM_ACTION_GAP,
        status_gap = ARTICLE_STATUS_GAP,
    }
end

local function getArticleButtonHeight(metrics)
    local action_button = Button:new{
        text = _("RIT"),
        width = metrics.action_width,
        radius = Size.radius.button,
        bordersize = Size.border.button,
        padding_v = metrics.button_padding_v,
        padding_h = metrics.button_padding_h,
        text_font_size = metrics.button_font_size,
        text_font_bold = false,
    }
    local action_button_height = action_button:getSize().h
    action_button:free()
    return action_button_height
end

local function canArticleRowFit(row_width, row_height, title_font_size)
    local metrics = getArticleRowMetrics(row_width, row_height, title_font_size)
    local text_block_height = row_height - metrics.vertical_padding * 2
    local title_area_height = text_block_height - metrics.subtitle_gap - metrics.subtitle_height
    if title_area_height < metrics.title_line_height then
        return false
    end
    return row_height >= getArticleButtonHeight(metrics)
end

local QiArticleItemWidget = InputContainer:extend{
    width = nil,
    height = nil,
    item = nil,
    title_font_size = 18,
    left_action = "read_state",
    right_action = "read_later",
    onToggleReadState = nil,
    onToggleReadLater = nil,
    onShowTags = nil,
    onOpenArticle = nil,
}

function QiArticleItemWidget:init()
    self.dimen = Geom:new{
        w = self.width,
        h = self.height,
    }
    self:rebuild()
end

function QiArticleItemWidget:rebuild()
    local item = self.item
    local row_width = self.width
    local row_height = self.height
    local metrics = getArticleRowMetrics(row_width, row_height, self.title_font_size)
    local text_color = item.status == 0 and Blitbuffer.COLOR_BLACK or ARTICLE_DIM_TEXT_COLOR
    local subtitle_color = ARTICLE_DIM_TEXT_COLOR
    local button_height = getArticleButtonHeight(metrics)
    local left_button
    if self.left_action == "read_later" then
        left_button = ArticleActionIconButton:new{
            width = metrics.status_width,
            height = button_height,
            icon_name = "read-later",
            icon_state = item.is_read_later and "active" or nil,
            callback = function()
                if self.onToggleReadLater then
                    self.onToggleReadLater(item)
                end
            end,
            show_parent = self,
        }
    else
        left_button = ArticleStatusIcon:new{
            width = metrics.status_width,
            height = button_height,
            icon_name = item.status == 0 and "article-unread" or "article-read",
            callback = function()
                if self.onToggleReadState then
                    self.onToggleReadState(item)
                end
            end,
        }
    end
    local right_button
    if self.right_action == "tags" then
        right_button = ArticleActionIconButton:new{
            width = metrics.action_width,
            height = button_height,
            icon_name = "tag",
            icon_state = item.has_tags and "active" or nil,
            callback = function(ges)
                if self.onShowTags then
                    self.onShowTags(item, ges)
                end
            end,
            show_parent = self,
        }
    else
        right_button = ArticleActionIconButton:new{
            width = metrics.action_width,
            height = button_height,
            icon_name = "read-later",
            icon_state = item.is_read_later and "active" or nil,
            callback = function()
                if self.onToggleReadLater then
                    self.onToggleReadLater(item)
                end
            end,
            show_parent = self,
        }
    end
    local left_button_width = left_button:getSize().w
    local right_button_width = right_button:getSize().w
    self.left_button = left_button
    self.right_button = right_button
    local content_width = math.max(
        ARTICLE_ITEM_MIN_CONTENT_WIDTH,
        row_width
            - metrics.status_side_padding
            - metrics.horizontal_padding
            - left_button_width
            - right_button_width
            - metrics.status_gap
            - metrics.action_gap
    )
    local text_block_height = math.max(1, row_height - metrics.vertical_padding * 2)
    local subtitle_area_height = metrics.subtitle_height
    local title_area_height = math.max(
        metrics.title_line_height,
        text_block_height - metrics.subtitle_gap - subtitle_area_height
    )
    local title_widget = TextBoxWidget:new{
        text = item.title or _("Untitled"),
        face = metrics.title_face,
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
        face = metrics.subtitle_face,
        width = content_width,
        height = subtitle_area_height,
        height_adjust = true,
        line_height = 0.1,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        fgcolor = subtitle_color,
    }
    local title_block = CenterContainer:new{
        dimen = Geom:new{ w = content_width, h = title_area_height },
        ignore_if_over = "height",
        title_widget,
    }
    local subtitle_block = LeftContainer:new{
        dimen = Geom:new{ w = content_width, h = subtitle_area_height },
        subtitle_widget,
    }
    local text_overlay = OverlapGroup:new{
        dimen = Geom:new{ w = content_width, h = text_block_height },
        allow_mirroring = false,
        title_block,
        VerticalGroup:new{
            overlap_offset = { 0, title_area_height },
            align = "left",
            VerticalSpan:new{ width = metrics.subtitle_gap },
            subtitle_block,
        },
    }
    local text_content = LeftContainer:new{
        dimen = Geom:new{ w = content_width, h = text_block_height },
        text_overlay,
    }
    local text_block = ArticleContentTapArea:new{
        width = content_width,
        height = row_height,
        callback = function()
            if self.onOpenArticle then
                self.onOpenArticle(item)
            end
        end,
        CenterContainer:new{
            dimen = Geom:new{ w = content_width, h = row_height },
            text_content,
        },
    }
    local status_block = CenterContainer:new{
        dimen = Geom:new{ w = left_button_width, h = row_height },
        left_button,
    }
    local action_block = CenterContainer:new{
        dimen = Geom:new{ w = right_button_width, h = row_height },
        right_button,
    }

    self[1] = FrameContainer:new{
        width = row_width,
        height = row_height,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = metrics.status_side_padding },
            status_block,
            HorizontalSpan:new{ width = metrics.status_gap },
            text_block,
            HorizontalSpan:new{ width = metrics.action_gap },
            action_block,
            HorizontalSpan:new{ width = metrics.horizontal_padding },
        },
    }
end

function QiArticleItemWidget:refreshActionButtons(options)
    local item = self.item
    local changed = false
    if not item then
        return false
    end
    if self.left_button then
        if self.left_action == "read_later" and self.left_button.setIconState then
            changed = self.left_button:setIconState(item.is_read_later and "active" or nil, options) or changed
        elseif self.left_button.setIconName then
            local icon_name = item.status == 0 and "article-unread" or "article-read"
            changed = self.left_button:setIconName(icon_name, options) or changed
        end
    end
    if self.right_button then
        if self.right_action == "tags" and self.right_button.setIconState then
            changed = self.right_button:setIconState(item.has_tags and "active" or nil, options) or changed
        elseif self.right_button.setIconState then
            changed = self.right_button:setIconState(item.is_read_later and "active" or nil, options) or changed
        end
    end
    return changed
end

return {
    Widget = QiArticleItemWidget,
    canArticleRowFit = canArticleRowFit,
    separator_color = ARTICLE_SEPARATOR_COLOR,
}
