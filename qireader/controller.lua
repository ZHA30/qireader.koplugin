local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../i18n/po.lua")

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local Client = require("qireader.client")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Settings = require("qireader.settings")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local Controller = {}
Controller.__index = Controller

local function responseError(response)
    if not response then
        return _("No response")
    end
    if response.code and response.code > 0 then
        return string.format("%s %s", tostring(response.code), response.status or "")
    end
    return response.status or _("Network request failed")
end

local function makeUnreadMap(data)
    local result = data and data.result or {}
    local unread_counts = result.unreadCounts or {}
    local unread_by_subscription_id = {}
    for i = 1, #unread_counts do
        local item = unread_counts[i]
        unread_by_subscription_id[item.subscriptionId] = item.count or 0
    end
    return unread_by_subscription_id
end

local function groupSubscriptions(data, unread_by_subscription_id)
    local result = data.result or {}
    local subscriptions = result.subscriptions or {}
    local categories = result.categories or {}
    local relations = result.subscriptionCategories or {}
    local subscriptions_by_id = {}
    local groups = {}
    local grouped_subscription_ids = {}

    for i = 1, #subscriptions do
        local subscription = subscriptions[i]
        subscription.unread_count = unread_by_subscription_id[subscription.id] or 0
        subscriptions_by_id[subscription.id] = subscription
    end
    for i = 1, #categories do
        local category = categories[i]
        local group = {
            id = category.id,
            label = category.label,
            subscriptions = {},
            unread_count = 0,
        }
        groups[category.id] = group
    end
    for i = 1, #relations do
        local relation = relations[i]
        local group = groups[relation.categoryId]
        local subscription = subscriptions_by_id[relation.subscriptionId]
        if group and subscription then
            table.insert(group.subscriptions, subscription)
            group.unread_count = group.unread_count + (subscription.unread_count or 0)
            if group.label ~= "!all" then
                grouped_subscription_ids[subscription.id] = true
            end
        end
    end

    local ordered = {}
    for i = 1, #categories do
        local category = categories[i]
        local group = groups[category.id]
        if group.label ~= "!all" then
            table.sort(group.subscriptions, function(left, right)
                return (left.title or "") < (right.title or "")
            end)
            table.insert(ordered, group)
        end
    end

    local ungrouped = {}
    local ungrouped_unread_count = 0
    for i = 1, #subscriptions do
        local subscription = subscriptions[i]
        if not grouped_subscription_ids[subscription.id] then
            table.insert(ungrouped, subscription)
            ungrouped_unread_count = ungrouped_unread_count + (subscription.unread_count or 0)
        end
    end
    table.sort(ungrouped, function(left, right)
        return (left.title or "") < (right.title or "")
    end)

    return {
        groups = ordered,
        ungrouped = ungrouped,
        ungrouped_unread_count = ungrouped_unread_count,
        subscriptions = subscriptions,
        version = result.version,
    }
end

function Controller.new(args)
    return setmetatable({
        plugin = args.plugin,
        settings = args.settings,
        save_settings = args.save_settings,
        client = Client.new(args.settings),
        login_fields = {
            email = "",
            password = "",
        },
        groups = nil,
        ungrouped = nil,
        ungrouped_unread_count = 0,
        subscriptions = nil,
        expanded_groups = {},
        state = "closed",
        active_dialog = nil,
        login_dialog = nil,
    }, Controller)
end

function Controller:close()
    self.state = "closed"
    if self.active_dialog then
        UIManager:close(self.active_dialog)
        self.active_dialog = nil
    end
    self:closeLoginDialog()
    if self.menu then
        UIManager:close(self.menu)
        self.menu = nil
    end
end

function Controller:open()
    if NetworkMgr:willRerunWhenOnline(function() self:open() end) then
        return
    end
    self:openHome()
end

function Controller:closeActiveDialog()
    if self.active_dialog then
        UIManager:close(self.active_dialog)
        self.active_dialog = nil
    end
end

function Controller:closeLoginDialog()
    if self.login_dialog then
        UIManager:close(self.login_dialog)
        self.login_dialog = nil
    end
end

function Controller:showLoginDialog()
    self:closeLoginDialog()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("QiReader account"),
        fields = {
            {
                text = self.login_fields.email or "",
                hint = _("Email"),
            },
            {
                text = self.login_fields.password or "",
                hint = _("Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                        if self.login_dialog == dialog then
                            self.login_dialog = nil
                        end
                    end,
                },
                {
                    text = _("Log in"),
                    callback = function()
                        local fields = dialog:getFields()
                        self.login_fields.email = fields[1] or ""
                        self.login_fields.password = fields[2] or ""
                        if self.login_fields.email == "" or self.login_fields.password == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Email and password are required."),
                            })
                            return
                        end
                        UIManager:close(dialog)
                        if self.login_dialog == dialog then
                            self.login_dialog = nil
                        end
                        self:login(self.login_fields.email, self.login_fields.password)
                    end,
                },
            },
        },
    }
    self.login_dialog = dialog
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Controller:login(email, password)
    self.state = "loading"
    self:showLoading(_("Logging in..."))
    local response = self.client:login(email, password)
    if self.state == "closed" then
        return
    end
    if response.code ~= 200 or not response.json or not response.json.result then
        Settings.clearSession(self.settings)
        self.save_settings()
        self:showGroupsPage()
        UIManager:show(InfoMessage:new{
            text = _("Login failed: ") .. responseError(response),
        })
        self:showAccountDialog()
        return
    end
    self.settings.user = response.json.result
    self.login_fields.password = ""
    self.save_settings()
    self:closeLoginDialog()
    self:closeActiveDialog()
    self:openHome()
end

function Controller:openHome()
    if not self.settings.cookie then
        self:showGroupsFromCache()
        return
    end
    self.state = "loading"
    self:showLoading(_("Loading subscriptions..."))
    local response = self.client:getSubscriptions()
    if self.state == "closed" then
        return
    end
    if response.code == 401 then
        Settings.clearSession(self.settings)
        self.save_settings()
        self.groups = {}
        self.ungrouped = {}
        self.ungrouped_unread_count = 0
        self.subscriptions = {}
        self:showGroupsPage()
        UIManager:show(InfoMessage:new{
            text = _("Session expired. Please log in again from Account."),
        })
        return
    end
    if response.code ~= 200 or not response.json then
        self:showError(_("Cannot load subscriptions: ") .. responseError(response), function()
            self:showGroupsFromCache()
        end)
        return
    end
    local unread_response = self.client:getUnreadCounts()
    local unread_json
    if unread_response.code == 200 then
        unread_json = unread_response.json
    end
    self:showGroups(response.json, unread_json)
end

function Controller:showGroups(data, unread_data)
    self.state = "groups"
    local grouped = groupSubscriptions(data, makeUnreadMap(unread_data))
    self.groups = grouped.groups
    self.ungrouped = grouped.ungrouped
    self.ungrouped_unread_count = grouped.ungrouped_unread_count
    self.subscriptions = grouped.subscriptions
    local valid_groups = {}
    for i = 1, #self.groups do
        valid_groups[self.groups[i].id] = true
    end
    for group_id in pairs(self.expanded_groups) do
        if not valid_groups[group_id] then
            self.expanded_groups[group_id] = nil
        end
    end
    self.settings.subscriptions_version = grouped.version
    self.save_settings()

    self:showGroupsPage()
end

function Controller:showGroupsFromCache()
    if self.groups and self.ungrouped and self.subscriptions then
        self:showGroupsPage()
        return
    end
    self.groups = {}
    self.ungrouped = {}
    self.ungrouped_unread_count = 0
    self.subscriptions = {}
    self:showGroupsPage()
end

function Controller:showLoading(text)
    self:showMenu(_("QiReader"), {
        {
            text = text,
            select_enabled = false,
        },
    }, _("Loading"))
end

function Controller:showError(text, retry_callback)
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

function Controller:showMenu(title, items, subtitle, options)
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

function Controller:openArticles(row)
    self.pending_article_target = row
end

function Controller:isUnreadOnly()
    return self.settings.show_unread_only == true
end

function Controller:toggleUnreadOnly()
    self.settings.show_unread_only = not self:isUnreadOnly()
    self.save_settings()
    if self.state == "groups" then
        self:showGroupsPage()
    end
end

function Controller:getDisplayAccountName()
    local user = self.settings.user
    if not user then
        return _("Not logged in")
    end
    return user.displayName or user.email or _("Logged in")
end

function Controller:showSettingsDialog()
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

function Controller:showAccountDialog()
    if self.settings.cookie then
        self:confirmLogout()
    else
        self:showLoginDialog()
    end
end

function Controller:confirmLogout()
    self:closeActiveDialog()
    local dialog
    dialog = ConfirmBox:new{
        text = _("Log out of QiReader?"),
        ok_text = _("Log out"),
        ok_callback = function()
            if self.active_dialog == dialog then
                self.active_dialog = nil
            end
            Settings.clearSession(self.settings)
            self.groups = {}
            self.ungrouped = {}
            self.ungrouped_unread_count = 0
            self.subscriptions = {}
            self.login_fields.password = ""
            self.save_settings()
            self:showGroupsPage()
            UIManager:show(InfoMessage:new{
                text = _("Logged out"),
            })
        end,
        cancel_callback = function()
            if self.active_dialog == dialog then
                self.active_dialog = nil
            end
        end,
    }
    self.active_dialog = dialog
    UIManager:show(dialog)
end

function Controller:refreshGroupsPage()
    if self.menu then
        self.menu:switchItemTable(_("Subscriptions"), self:buildGroupsPageItems(), -1, true, "")
    end
end

function Controller:buildGroupsPageItems()
    local items = {}
    local groups = self.groups or {}
    local ungrouped = self.ungrouped or {}
    local button_width = Screen:scaleBySize(64)
    local function makeStateButton(text)
        return Button:new{
            text = text,
            width = button_width,
            text_font_face = "cfont",
            text_font_size = 30,
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
                text = group.label or _("Untitled"),
                mandatory = tostring(group.unread_count or 0),
                state = makeStateButton(is_expanded and "▼" or "▶"),
                bold = (group.unread_count or 0) > 0,
                group = group,
                callback = function(pos)
                    if pos and pos.x <= 0.16 then
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
                        bold = (subscription.unread_count or 0) > 0,
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
                bold = (subscription.unread_count or 0) > 0,
                subscription = subscription,
                callback = function()
                    self:openArticles({ type = "subscription", subscription = subscription })
                end,
            })
        end
    end
    if #items == 0 then
        table.insert(items, {
            text = self.settings.cookie
                and (self:isUnreadOnly() and _("No unread subscriptions.") or _("No subscriptions."))
                or _("Not logged in"),
            select_enabled = false,
        })
    end
    return items
end

function Controller:showGroupsPage()
    self.state = "groups"
    local items = self:buildGroupsPageItems()
    self:showMenu(_("Subscriptions"), items, "", {
        state_w = Screen:scaleBySize(64),
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

return Controller
