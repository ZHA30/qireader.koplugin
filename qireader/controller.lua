local Client = require("qireader.client")
local article_settings_methods = require("qireader.controller.article_settings")
local article_methods = require("qireader.controller.articles")
local menu_methods = require("qireader.controller.menu")
local session_methods = require("qireader.controller.session")
local subscription_methods = require("qireader.controller.subscriptions")

local Controller = {}
Controller.__index = Controller

local function installMethods(target, methods)
    for name, value in pairs(methods) do
        target[name] = value
    end
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

installMethods(Controller, article_settings_methods)
installMethods(Controller, article_methods)
installMethods(Controller, menu_methods)
installMethods(Controller, session_methods)
installMethods(Controller, subscription_methods)

return Controller
