local FocusManager = require("ui/widget/focusmanager")
local pagination_methods = require("qireader.articlelist.pagination")
local view_methods = require("qireader.articlelist.view")

local QiArticleListWidget = FocusManager:extend{
    controller = nil,
    title = "",
    target = nil,
    show_page = 1,
    pages = 1,
    loaded_pages = nil,
    loaded_chunks = nil,
    preloading_chunks = nil,
    has_more = false,
    loading = false,
    closing = false,
    active_dialog = nil,
    detail_widget = nil,
    pending_request = nil,
    pending_request_chunk_index = nil,
    remote_batch_size = 50,
    preload_pages_before_end = 2,
}

local function installMethods(target, methods)
    for name, value in pairs(methods) do
        target[name] = value
    end
end

installMethods(QiArticleListWidget, pagination_methods)
installMethods(QiArticleListWidget, view_methods)

return QiArticleListWidget
