local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local Settings = require("qireader.settings")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")

local ARTICLE_SETTINGS_SCHEMA = {
    "show_unread_only",
    "order_oldest_first",
    "mark_read_on_page_turn",
    "items_per_page",
    "title_font_size",
}
local TAG_STREAM_PREFIX = "tag-"

local function copyArticleSettings(source)
    local result = {}
    for i = 1, #ARTICLE_SETTINGS_SCHEMA do
        local key = ARTICLE_SETTINGS_SCHEMA[i]
        result[key] = source[key]
    end
    return result
end

local function isArticleTagTarget(target)
    if not target then
        return false
    end
    if target.kind == "tag" or target.kind == "readlater" then
        return true
    end
    local stream_id = target.stream_id and tostring(target.stream_id) or ""
    return stream_id:sub(1, #TAG_STREAM_PREFIX) == TAG_STREAM_PREFIX
end

local function requiresArticleRemoteReload(target, left, right)
    if isArticleTagTarget(target) then
        return left.show_unread_only ~= right.show_unread_only
    end
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

local methods = {}

function methods:getArticleSettingsRoot()
    if type(self.settings.article_settings) ~= "table" then
        self.settings.article_settings = {}
    end
    local root = self.settings.article_settings
    if type(root.global) ~= "table" then
        root.global = copyArticleSettings(Settings.article_defaults)
    end
    if type(root.custom) ~= "table" then
        root.custom = {}
    end
    return root
end

function methods:getGlobalArticleSettings()
    local root = self:getArticleSettingsRoot()
    return root.global
end

function methods:getArticleCustomEntry(target)
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

function methods:isArticleCustomSettingsEnabled(target)
    return self:getArticleCustomEntry(target) ~= nil
end

function methods:getEffectiveArticleSettings(target)
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

function methods:getArticleSettingsScopeText(target)
    if self:isArticleCustomSettingsEnabled(target) then
        return _("Config: Custom")
    end
    return _("Config: Global")
end

function methods.isArticleTagTarget(_self, target)
    return isArticleTagTarget(target)
end

function methods:getArticleSetting(target, key)
    if self:isArticleTagTarget(target)
        and (
            key == "show_unread_only"
            or key == "order_oldest_first"
            or key == "mark_read_on_page_turn"
        ) then
        return false
    end
    local settings = self:getEffectiveArticleSettings(target)
    return settings and settings[key] or nil
end

function methods:setArticleSetting(target, key, value)
    local target_key = getArticleTargetKey(target)
    if target_key and self:isArticleCustomSettingsEnabled(target) then
        self:getArticleSettingsRoot().custom[target_key][key] = value
    else
        self:getGlobalArticleSettings()[key] = value
    end
    self.save_settings()
end

function methods:refreshArticleWidgetBySettingsDiff(widget, previous_settings, next_settings)
    local target = widget and widget.target or nil
    if requiresArticleRemoteReload(target, previous_settings, next_settings) then
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

function methods:toggleArticleSettingsScope(target, widget)
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

function methods:refreshArticleWidget(widget)
    if self.article_widget and not widget then
        widget = self.article_widget
    end
    if widget and widget.reloadFromRemote then
        widget:reloadFromRemote()
    end
end

function methods:refreshArticleWidgetLayout(widget)
    if self.article_widget and not widget then
        widget = self.article_widget
    end
    if widget and widget.reloadLayoutOnly then
        widget:reloadLayoutOnly()
    end
end

function methods:clearCachedData()
    if self.article_widget and self.article_widget.clearPendingFetch then
        self.article_widget:clearPendingFetch()
    end
    if self.cancelArticleContentLoads then
        self:cancelArticleContentLoads(self.article_widget and self.article_widget.target or nil)
    end
    if self.article_detail_widget and self.cancelArticleFullText then
        self:cancelArticleFullText(self.article_detail_widget.entry)
    end
    self.content_prefetch_queue = {}
    if self.resetCacheStorage then
        self:resetCacheStorage()
    else
        self:clearCache()
    end
    if self.resetStreamCacheGeneration then
        self:resetStreamCacheGeneration(0)
    else
        self.settings.stream_cache_generation = 0
    end
    if self.save_settings then
        self.save_settings()
    end
    if self.showTransientMessage then
        self:showTransientMessage(_("Cache cleared."))
    end
end

function methods:toggleArticleUnreadOnly(target, widget)
    if self:isArticleTagTarget(target) then
        return
    end
    local current_value = self:getArticleSetting(target, "show_unread_only") == true
    self:setArticleSetting(target, "show_unread_only", not current_value)
    self:refreshArticleWidget(widget)
end

function methods:toggleArticleOrder(target, widget)
    if self:isArticleTagTarget(target) then
        return
    end
    local current_value = self:getArticleSetting(target, "order_oldest_first") == true
    self:setArticleSetting(target, "order_oldest_first", not current_value)
    self:refreshArticleWidget(widget)
end

function methods:toggleMarkReadOnPageTurn(target, widget)
    if self:isArticleTagTarget(target) then
        return
    end
    local current_value = self:getArticleSetting(target, "mark_read_on_page_turn") == true
    self:setArticleSetting(target, "mark_read_on_page_turn", not current_value)
    if widget then
        widget:refresh()
    end
end

function methods:showArticleNumberPicker(target, widget, setting_key, title, options)
    options = options or {}
    local current_value = self:getArticleSetting(target, setting_key) or options.default_value
    local spin_widget
    spin_widget = SpinWidget:new{
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
        close_callback = function()
            if widget and widget.active_dialog == spin_widget then
                widget.active_dialog = nil
            end
        end,
    }
    if widget then
        widget:closeActiveDialog()
        widget.active_dialog = spin_widget
    end
    UIManager:show(spin_widget)
end

return methods
