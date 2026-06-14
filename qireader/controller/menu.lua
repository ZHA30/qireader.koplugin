-- luacheck: globals G_reader_settings

local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Menu = require("ui/widget/menu")
local QiArticleListWidget = require("qireader.articlelist")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local methods = {}

function methods:showLoading(text)
    self:showMenu(_("QiReader"), {
        {
            text = text,
            select_enabled = false,
        },
    }, _("Loading"))
end

function methods:showError(text, retry_callback)
    self.state = "error"
    self:showMenu(_("QiReader"), {
        {
            text = text,
            select_enabled = false,
        },
        {
            text = _("Back"),
            callback = retry_callback or function()
                self:showGroupsFromCache()
            end,
        },
    }, _("Error"))
end

function methods:showMenu(title, items, subtitle, options)
    options = options or {}
    local left_icon = options.title_bar_left_icon or "appbar.settings"
    local on_left_button_tap = options.onLeftButtonTap or function()
        self:showSettingsDialog()
    end
    if self.menu then
        for key, value in pairs(options) do
            self.menu[key] = value
        end
        self.menu:setTitleBarLeftIcon(left_icon)
        self.menu.onLeftButtonTap = function()
            on_left_button_tap()
        end
        self.menu:switchItemTable(title, items, 1, nil, subtitle or "")
        return
    end
    local menu_options = {
        path = true,
        title = title,
        subtitle = subtitle or "",
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = left_icon,
        onLeftButtonTap = on_left_button_tap,
        onMenuSelect = function(_menu, item, pos)
            if item.callback then
                item.callback(pos)
            end
            return true
        end,
        close_callback = function()
            self:closeLoginDialog()
            if self.active_dialog then
                UIManager:close(self.active_dialog)
                self.active_dialog = nil
            end
            self.menu = nil
            self.state = "closed"
        end,
    }
    for key, value in pairs(options) do
        menu_options[key] = value
    end
    self.menu = Menu:new(menu_options)
    UIManager:show(self.menu)
end

function methods:openArticles(row)
    if not row then
        return
    end
    local target = self:buildArticleTarget(row)
    if not target then
        self:showTransientMessage(_("Cannot open article list."))
        return
    end
    if self.article_widget then
        UIManager:close(self.article_widget)
        self.article_widget = nil
    end
    self.article_widget = QiArticleListWidget:new{
        controller = self,
        title = target.title,
        target = target,
    }
    UIManager:show(self.article_widget)
    self:loadReadLaterTagId()
end

function methods:isUnreadOnly()
    return self.settings.show_unread_only == true
end

function methods:toggleUnreadOnly()
    self.settings.show_unread_only = not self:isUnreadOnly()
    self.save_settings()
    if self.state == "groups" then
        self:showGroupsPage()
    end
end

function methods:getDisplayAccountName()
    local user = self.settings.user
    if not user then
        return _("Not logged in")
    end
    return user.displayName or user.email or _("Logged in")
end

function methods:showSettingsDialog()
    self:closeActiveDialog()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {{
                text = _("Account"),
                callback = function()
                    UIManager:close(dialog)
                    if self.active_dialog == dialog then
                        self.active_dialog = nil
                    end
                    self:showAccountDialog()
                end,
                align = "left",
            }},
            {{
                text = self:isUnreadOnly() and _("Unread only: On") or _("Unread only: Off"),
                callback = function()
                    UIManager:close(dialog)
                    if self.active_dialog == dialog then
                        self.active_dialog = nil
                    end
                    self:toggleUnreadOnly()
                end,
                align = "left",
            }},
        },
        shrink_unneeded_width = true,
        anchor = function()
            return self.menu and self.menu.title_bar and self.menu.title_bar.left_button
                and self.menu.title_bar.left_button.image.dimen or nil
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

function methods:showAccountDialog()
    self:showLoginDialog()
end

function methods:refreshGroupsPage()
    if self.menu then
        self.menu:switchItemTable(_("Subscriptions"), self:buildGroupsPageItems(), -1, true, "")
    end
end

function methods:buildGroupsPageItems()
    local items = {}
    local groups = self.groups or {}
    local ungrouped = self.ungrouped or {}
    local perpage = self.menu and self.menu.perpage
        or G_reader_settings:readSetting("items_per_page")
        or Menu.items_per_page_default
    local item_font_size = self.menu and self.menu.font_size or Menu.getItemFontSize(perpage)
    local button_width = math.max(Screen:scaleBySize(36), item_font_size * 2)
    local state_font_size = math.max(item_font_size, math.floor(item_font_size * 1.1))

    local function makeStateButton(text)
        return Button:new{
            text = text,
            width = button_width,
            text_font_face = "cfont",
            text_font_size = state_font_size,
            text_font_bold = true,
            bordersize = 0,
            padding = 0,
            onTapSelectButton = function() end,
        }
    end

    for i = 1, #groups do
        local group = groups[i]
        local visible_subscriptions = {}
        for j = 1, #group.subscriptions do
            local subscription = group.subscriptions[j]
            if not self:isUnreadOnly() or (subscription.unread_count or 0) > 0 then
                table.insert(visible_subscriptions, subscription)
            end
        end
        if (not self:isUnreadOnly()) or (group.unread_count or 0) > 0 then
            local is_expanded = self.expanded_groups[group.id] == true
            table.insert(items, {
                text = group.is_all and _("All") or group.label or _("Untitled"),
                mandatory = tostring(group.unread_count or 0),
                state = group.is_all and makeStateButton("") or makeStateButton(is_expanded and "▼" or "▶"),
                bold = true,
                dim = (group.unread_count or 0) == 0,
                group = group,
                callback = function(pos)
                    if (not group.is_all) and pos and pos.x <= 0.16 then
                        self.expanded_groups[group.id] = not is_expanded
                        self:refreshGroupsPage()
                    else
                        self:openArticles({ type = "group", group = group })
                    end
                end,
            })
            if is_expanded then
                for j = 1, #visible_subscriptions do
                    local subscription = visible_subscriptions[j]
                    table.insert(items, {
                        text = subscription.title or subscription.feedUrl or tostring(subscription.id or ""),
                        mandatory = tostring(subscription.unread_count or 0),
                        state = makeStateButton(""),
                        bold = false,
                        dim = (subscription.unread_count or 0) == 0,
                        subscription = subscription,
                        callback = function()
                            self:openArticles({ type = "subscription", subscription = subscription, group = group })
                        end,
                    })
                end
            end
        end
    end

    for i = 1, #ungrouped do
        local subscription = ungrouped[i]
        if not self:isUnreadOnly() or (subscription.unread_count or 0) > 0 then
            table.insert(items, {
                text = subscription.title or subscription.feedUrl or tostring(subscription.id or ""),
                mandatory = tostring(subscription.unread_count or 0),
                state = makeStateButton(""),
                bold = false,
                dim = (subscription.unread_count or 0) == 0,
                subscription = subscription,
                callback = function()
                    self:openArticles({ type = "subscription", subscription = subscription })
                end,
            })
        end
    end

    if #items == 0 and self.settings.cookie then
        table.insert(items, {
            text = self:isUnreadOnly() and _("No unread subscriptions.") or _("No subscriptions."),
            select_enabled = false,
        })
    end
    return items
end

function methods:showGroupsPage()
    self.state = "groups"
    local items = self:buildGroupsPageItems()
    local perpage = self.menu and self.menu.perpage
        or G_reader_settings:readSetting("items_per_page")
        or Menu.items_per_page_default
    local state_w = math.max(Screen:scaleBySize(48), Menu.getItemFontSize(perpage) * 2 + Screen:scaleBySize(8))
    self:showMenu(_("Subscriptions"), items, "", {
        state_w = state_w,
        single_line = true,
        align_baselines = true,
        items_padding = math.floor(Size.padding.fullscreen / 2),
        line_color = Blitbuffer.COLOR_BLACK,
        title_bar_left_icon = "appbar.settings",
        onLeftButtonTap = function()
            self:showSettingsDialog()
        end,
    })
end

return methods
