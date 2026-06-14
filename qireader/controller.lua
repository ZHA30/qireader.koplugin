-- luacheck: globals G_reader_settings

local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../i18n/po.lua")

local Blitbuffer = require("ffi/blitbuffer")
local QiArticleListWidget = require("qireader.articlelist")
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
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local util = require("util")
local Screen = Device.screen

local Controller = {}
Controller.__index = Controller

local ARTICLE_SETTINGS_SCHEMA = {
    "show_unread_only",
    "order_oldest_first",
    "mark_read_on_page_turn",
    "items_per_page",
    "title_font_size",
}

local function responseError(response)
    if not response then
        return _("No response")
    end
    if response.code and response.code > 0 then
        return string.format("%s %s", tostring(response.code), response.status or "")
    end
    return response.status or _("Network request failed")
end

local function copyTable(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        if type(value) == "table" then
            copy[key] = copyTable(value)
        else
            copy[key] = value
        end
    end
    return copy
end

local function copyArticleSettings(source)
    local result = {}
    for i = 1, #ARTICLE_SETTINGS_SCHEMA do
        local key = ARTICLE_SETTINGS_SCHEMA[i]
        result[key] = source[key]
    end
    return result
end

local function requiresArticleRemoteReload(left, right)
    return left.show_unread_only ~= right.show_unread_only
        or left.order_oldest_first ~= right.order_oldest_first
end

local function requiresArticleLayoutReload(left, right)
    return left.items_per_page ~= right.items_per_page
        or left.title_font_size ~= right.title_font_size
end

local function getArticleTargetKey(target)
    if not target or not target.stream_id then
        return nil
    end
    return tostring(target.stream_id)
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
            is_all = category.label == "!all",
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
    local all_group = nil
    for i = 1, #categories do
        local category = categories[i]
        local group = groups[category.id]
        table.sort(group.subscriptions, function(left, right)
            return (left.title or "") < (right.title or "")
        end)
        if group.is_all then
            all_group = group
        else
            table.insert(ordered, group)
        end
    end
    if all_group then
        table.insert(ordered, 1, all_group)
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
        article_widget = nil,
        readlater_tag_id = nil,
    }, Controller)
end

function Controller:getArticleSettingsRoot()
    if type(self.settings.article_settings) ~= "table" then
        self.settings.article_settings = {}
    end
    local root = self.settings.article_settings
    if type(root.global) ~= "table" then
        root.global = copyTable(Settings.article_defaults)
    end
    if type(root.custom) ~= "table" then
        root.custom = {}
    end
    return root
end

function Controller:getGlobalArticleSettings()
    local root = self:getArticleSettingsRoot()
    return root.global
end

function Controller:getArticleCustomEntry(target)
    local target_key = getArticleTargetKey(target)
    if not target_key then
        return nil
    end
    local root = self:getArticleSettingsRoot()
    local entry = root.custom[target_key]
    if type(entry) ~= "table" then
        return nil
    end
    return entry
end

function Controller:isArticleCustomSettingsEnabled(target)
    return self:getArticleCustomEntry(target) ~= nil
end

function Controller:getEffectiveArticleSettings(target)
    local global_settings = self:getGlobalArticleSettings()
    if not target then
        return global_settings
    end
    local entry = self:getArticleCustomEntry(target)
    if entry then
        return entry
    end
    return global_settings
end

function Controller:getArticleSettingsScopeText(target)
    if self:isArticleCustomSettingsEnabled(target) then
        return _("Config: Custom")
    end
    return _("Config: Global")
end

function Controller:getArticleSetting(target, key)
    local settings = self:getEffectiveArticleSettings(target)
    return settings and settings[key] or nil
end

function Controller:setArticleSetting(target, key, value)
    local target_key = getArticleTargetKey(target)
    if target_key and self:isArticleCustomSettingsEnabled(target) then
        self:getArticleSettingsRoot().custom[target_key][key] = value
    else
        self:getGlobalArticleSettings()[key] = value
    end
    self.save_settings()
end

function Controller:refreshArticleWidgetBySettingsDiff(widget, previous_settings, next_settings)
    if requiresArticleRemoteReload(previous_settings, next_settings) then
        self:refreshArticleWidget(widget)
        return
    end
    if requiresArticleLayoutReload(previous_settings, next_settings) then
        self:refreshArticleWidgetLayout(widget)
        return
    end
    if widget then
        widget:refresh()
    end
end

function Controller:toggleArticleSettingsScope(target, widget)
    local previous_settings = copyArticleSettings(self:getEffectiveArticleSettings(target))
    local target_key = getArticleTargetKey(target)
    if not target_key then
        return
    end
    local root = self:getArticleSettingsRoot()
    if root.custom[target_key] then
        root.custom[target_key] = nil
    else
        root.custom[target_key] = copyArticleSettings(previous_settings)
    end
    self.save_settings()
    local next_settings = copyArticleSettings(self:getEffectiveArticleSettings(target))
    self:refreshArticleWidgetBySettingsDiff(widget, previous_settings, next_settings)
end

function Controller:close()
    self.state = "closed"
    if self.article_widget then
        UIManager:close(self.article_widget)
        self.article_widget = nil
    end
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

function Controller:showTransientMessage(text)
    self.last_message = text
    UIManager:show(InfoMessage:new{
        text = text,
    })
end

function Controller:handleUnauthorized()
    Settings.clearSession(self.settings)
    self.save_settings()
    self.groups = {}
    self.ungrouped = {}
    self.ungrouped_unread_count = 0
    self.subscriptions = {}
    if self.article_widget then
        UIManager:close(self.article_widget)
        self.article_widget = nil
    end
    self:showGroupsPage()
    self:showTransientMessage(_("Session expired. Please log in again from Account."))
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
    if not row then
        return
    end
    self:ensureReadLaterTagId()
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

function Controller:ensureReadLaterTagId()
    if self.readlater_tag_id then
        return self.readlater_tag_id
    end
    local response = self.client:getTags()
    if response.code ~= 200 or not response.json or not response.json.result then
        return nil
    end
    local tags = response.json.result.tags or {}
    for i = 1, #tags do
        local tag = tags[i]
        if tag.label == "!readlater" then
            self.readlater_tag_id = tag.id
            return self.readlater_tag_id
        end
    end
    return nil
end

function Controller.buildArticleTarget(_, row)
    if row.type == "group" and row.group then
        local group = row.group
        local stream_id
        if group.is_all then
            stream_id = "category-" .. tostring(group.id)
        else
            stream_id = "category-" .. tostring(group.id)
        end
        return {
            kind = "group",
            title = group.is_all and _("All") or (group.label or _("Untitled")),
            stream_id = stream_id,
            group = group,
        }
    elseif row.type == "subscription" and row.subscription then
        local subscription = row.subscription
        return {
            kind = "subscription",
            title = subscription.title or subscription.feedUrl or tostring(subscription.id or ""),
            stream_id = "subscription-" .. tostring(subscription.id),
            subscription = subscription,
            group = row.group,
        }
    end
end

function Controller:getSubscriptionTitleByFeedId(feed_id)
    local subscriptions = self.subscriptions or {}
    for i = 1, #subscriptions do
        local subscription = subscriptions[i]
        if subscription.feedId == feed_id or subscription.id == feed_id then
            return subscription.title or subscription.feedUrl or tostring(subscription.id or "")
        end
    end
    return tostring(feed_id or "")
end

function Controller:normalizeArticlePage(target, result)
    local entries = result.entries or {}
    local normalized = {
        entries = {},
        has_more = result.hasMore == true,
        next_cursor = nil,
    }
    local readlater_tag_id = self.readlater_tag_id
    for i = 1, #entries do
        local entry = entries[i]
        local tag_ids = entry.tagIds or {}
        local is_read_later = false
        if readlater_tag_id then
            for j = 1, #tag_ids do
                if tag_ids[j] == readlater_tag_id then
                    is_read_later = true
                    break
                end
            end
        end
        table.insert(normalized.entries, {
            id = entry.id,
            title = entry.title or _("Untitled"),
            status = entry.status or 0,
            timestamp = entry.timestamp,
            published_at = entry.publishedAt,
            summary = entry.summary,
            source_feed_id = entry.origin and entry.origin.feedId or nil,
            source_title = self:getSubscriptionTitleByFeedId(entry.origin and entry.origin.feedId or nil),
            date_text = self:formatArticleDate(entry.publishedAt),
            tag_ids = tag_ids,
            is_read_later = is_read_later,
            raw = entry,
            target = target,
        })
    end
    if #entries > 0 then
        normalized.next_cursor = entries[#entries].timestamp
    end
    return normalized
end

function Controller.formatArticleDate(self, published_at)
    if not self then
        return "--"
    end
    if not published_at then
        return "--"
    end
    local timestamp = tonumber(published_at)
    local seconds = timestamp and math.floor(timestamp / 1000) or nil
    if not seconds then
        return "--"
    end
    local now = os.time()
    if seconds > now then
        seconds = now
    end

    local article_day = os.date("*t", seconds)
    local now_day = os.date("*t", now)
    local article_day_start = os.time{
        year = article_day.year,
        month = article_day.month,
        day = article_day.day,
        hour = 0,
        min = 0,
        sec = 0,
    }
    local today_start = os.time{
        year = now_day.year,
        month = now_day.month,
        day = now_day.day,
        hour = 0,
        min = 0,
        sec = 0,
    }
    local elapsed = now - seconds

    if article_day_start == today_start then
        if elapsed < 3600 then
            local minutes = math.max(1, math.floor(elapsed / 60))
            return string.format("%dm", minutes)
        end
        local hours = math.max(1, math.floor(elapsed / 3600))
        return string.format("%dh", hours)
    end

    if article_day_start == today_start - 86400 then
        return _("Yesterday")
    end

    return os.date("%m-%d", seconds)
end

function Controller:onArticleListClosed(widget)
    if self.article_widget == widget then
        self.article_widget = nil
    end
    UIManager:close(widget)
end

function Controller:refreshArticleWidget(widget)
    if self.article_widget and not widget then
        widget = self.article_widget
    end
    if widget and widget.reloadFromRemote then
        widget:reloadFromRemote()
    end
end

function Controller:refreshArticleWidgetLayout(widget)
    if self.article_widget and not widget then
        widget = self.article_widget
    end
    if widget and widget.reloadLayoutOnly then
        widget:reloadLayoutOnly()
    end
end

function Controller:toggleArticleUnreadOnly(target, widget)
    local current_value = self:getArticleSetting(target, "show_unread_only") == true
    self:setArticleSetting(target, "show_unread_only", not current_value)
    self:refreshArticleWidget(widget)
end

function Controller:toggleArticleOrder(target, widget)
    local current_value = self:getArticleSetting(target, "order_oldest_first") == true
    self:setArticleSetting(target, "order_oldest_first", not current_value)
    self:refreshArticleWidget(widget)
end

function Controller:toggleMarkReadOnPageTurn(target, widget)
    local current_value = self:getArticleSetting(target, "mark_read_on_page_turn") == true
    self:setArticleSetting(target, "mark_read_on_page_turn", not current_value)
    if widget then
        widget:refresh()
    end
end

function Controller:showArticleNumberPicker(target, widget, setting_key, title, options)
    options = options or {}
    local current_value = self:getArticleSetting(target, setting_key) or options.default_value
    local spin_widget = SpinWidget:new{
        title_text = title,
        value = current_value,
        value_min = options.value_min,
        value_max = options.value_max,
        default_value = options.default_value,
        keep_shown_on_apply = true,
        callback = function(spin)
            self:setArticleSetting(target, setting_key, spin.value)
            if options.on_apply then
                options.on_apply(widget)
            end
        end,
    }
    UIManager:show(spin_widget)
end

function Controller:markPageRead(page)
    if not page or not page.entries or #page.entries == 0 then
        return
    end
    local unread_ids = {}
    for i = 1, #page.entries do
        local entry = page.entries[i]
        if entry.status == 0 then
            table.insert(unread_ids, entry.id)
        end
    end
    if #unread_ids == 0 then
        return
    end
    local response = self.client:markEntriesRead(unread_ids)
    if response.code ~= 200 then
        return
    end
    for i = 1, #page.entries do
        page.entries[i].status = 1
    end
end

function Controller:maybeMarkArticlePageRead(page)
    local first_entry = page and page.entries and page.entries[1] or nil
    local target = first_entry and first_entry.target or nil
    if not page or self:getArticleSetting(target, "mark_read_on_page_turn") ~= true then
        return
    end
    self:markPageRead(page)
end

function Controller:toggleReadLater(entry, widget)
    local tag_id = self:ensureReadLaterTagId()
    if not tag_id then
        self:showTransientMessage(_("Cannot resolve read-later tag."))
        return
    end
    local response
    if entry.is_read_later then
        response = self.client:removeEntryTag(entry.id, tag_id, "feed")
    else
        response = self.client:addEntryTag(entry.id, tag_id, "feed")
    end
    if response.code == 401 then
        self:handleUnauthorized()
        return
    end
    if response.code ~= 200 then
        self:showTransientMessage(_("Cannot update read-later state."))
        return
    end
    entry.is_read_later = not entry.is_read_later
    if entry.is_read_later then
        table.insert(entry.tag_ids, tag_id)
    else
        local filtered = {}
        for i = 1, #entry.tag_ids do
            if entry.tag_ids[i] ~= tag_id then
                table.insert(filtered, entry.tag_ids[i])
            end
        end
        entry.tag_ids = filtered
    end
    if widget then
        widget:refresh()
    end
end

function Controller:openArticleContent(target, entry)
    local response = self.client:getEntryContents(target.stream_id, { entry.id })
    if response.code == 401 then
        self:handleUnauthorized()
        return
    end
    if response.code ~= 200 or not response.json or not response.json.result or not response.json.result[1] then
        self:showTransientMessage(_("Cannot load article content."))
        return
    end
    local content = response.json.result[1].content or entry.summary or ""
    if self.article_widget then
        self.article_widget:showText(entry.title, content)
    else
        UIManager:show(InfoMessage:new{
            text = util.htmlToPlainTextIfHtml(content),
        })
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
    local perpage = self.menu and self.menu.perpage
        or G_reader_settings:readSetting("items_per_page")
        or Menu.items_per_page_default
    local state_w = math.max(Screen:scaleBySize(36), Menu.getItemFontSize(perpage) * 2)
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

return Controller
