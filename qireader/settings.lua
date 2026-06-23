-- luacheck: globals G_reader_settings

local Settings = {}

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = deepCopy(item)
    end
    return copy
end

Settings.article_defaults = {
    show_unread_only = false,
    order_oldest_first = false,
    mark_read_on_page_turn = false,
    items_per_page = 5,
    title_font_size = 18,
}

Settings.article_detail_defaults = {
    font_size = 22,
    font_face = "./fonts/noto/NotoSans-Regular.ttf",
}

Settings.cache_defaults = {
    enabled = true,
    size_mb = 20,
    subscriptions_ttl = 86400,
    unread_counts_ttl = 300,
    stream_ttl = 900,
    content_ttl = 2592000,
    readlater_tag_ttl = 86400,
    tags_ttl = 86400,
    fulltext_ttl = 2592000,
    stream_preload_pages_before_end = 2,
}

Settings.defaults = {
    api_base = "https://www.qireader.com/api",
    cookie = nil,
    user = nil,
    show_unread_only = false,
    stream_cache_generation = 0,
    cache = deepCopy(Settings.cache_defaults),
    article_settings = {
        global = deepCopy(Settings.article_defaults),
        custom = {},
    },
    article_detail = deepCopy(Settings.article_detail_defaults),
}

local function mergeDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then
                target[key] = deepCopy(value)
            else
                mergeDefaults(target[key], value)
            end
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

local function migrateArticleSettings(settings)
    local article_settings = settings.article_settings
    if type(article_settings) ~= "table" then
        article_settings = {}
        settings.article_settings = article_settings
    end
    if type(article_settings.global) ~= "table" then
        article_settings.global = {}
    end
    local global_settings = article_settings.global
    if global_settings.show_unread_only == nil then
        global_settings.show_unread_only = settings.article_show_unread_only
    end
    if global_settings.order_oldest_first == nil then
        global_settings.order_oldest_first = settings.article_order_oldest_first
    end
    if global_settings.mark_read_on_page_turn == nil then
        global_settings.mark_read_on_page_turn = settings.article_mark_read_on_page_turn
    end
    if global_settings.items_per_page == nil then
        global_settings.items_per_page = settings.article_items_per_page
    end
    if global_settings.title_font_size == nil then
        global_settings.title_font_size = settings.article_title_font_size
    end
    if type(article_settings.custom) ~= "table" then
        article_settings.custom = {}
    end
    for target_key, entry in pairs(article_settings.custom) do
        if type(entry) ~= "table" then
            article_settings.custom[target_key] = deepCopy(global_settings)
        end
    end
    settings.article_show_unread_only = nil
    settings.article_order_oldest_first = nil
    settings.article_mark_read_on_page_turn = nil
    settings.article_items_per_page = nil
    settings.article_title_font_size = nil
end

local function cleanupDeprecatedSettings(settings)
    settings.subscriptions_version = nil
    local article_detail = settings.article_detail
    if type(article_detail) == "table" then
        article_detail.margin_top = nil
        article_detail.margin_bottom = nil
        article_detail.margin_left = nil
        article_detail.margin_right = nil
        article_detail.margin_vertical = nil
        article_detail.margin_horizontal = nil
    end
end

function Settings.load()
    local settings = G_reader_settings:readSetting("qireader", deepCopy(Settings.defaults))
    migrateArticleSettings(settings)
    mergeDefaults(settings, Settings.defaults)
    cleanupDeprecatedSettings(settings)
    return settings
end

function Settings.save(settings)
    G_reader_settings:saveSetting("qireader", settings)
end

function Settings.clearSession(settings)
    settings.cookie = nil
    settings.user = nil
end

return Settings
