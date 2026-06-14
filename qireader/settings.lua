-- luacheck: globals G_reader_settings

local Settings = {}

Settings.defaults = {
    api_base = "https://www.qireader.com/api",
    cookie = nil,
    user = nil,
    subscriptions_version = nil,
    show_unread_only = false,
    article_show_unread_only = false,
    article_order_oldest_first = false,
    article_mark_read_on_page_turn = false,
    article_items_per_page = 5,
    article_title_font_size = 18,
}

local function cloneDefaults()
    local copy = {}
    for key, value in pairs(Settings.defaults) do
        copy[key] = value
    end
    return copy
end

function Settings.load()
    local settings = G_reader_settings:readSetting("qireader", cloneDefaults())
    for key, value in pairs(Settings.defaults) do
        if settings[key] == nil then
            settings[key] = value
        end
    end
    return settings
end

function Settings.save(settings)
    G_reader_settings:saveSetting("qireader", settings)
end

function Settings.clearSession(settings)
    settings.cookie = nil
    settings.user = nil
    settings.subscriptions_version = nil
end

return Settings
