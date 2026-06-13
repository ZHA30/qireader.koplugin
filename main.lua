local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "i18n/po.lua")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Controller = require("qireader.controller")
local Settings = require("qireader.settings")

local QiReader = WidgetContainer:extend{
    name = "qireader",
    is_doc_only = false,
    settings_key = "qireader",
}

function QiReader:init()
    self.settings = Settings.load()
    self.controller = Controller.new{
        plugin = self,
        settings = self.settings,
        save_settings = function()
            self:saveSettings()
        end,
    }
    self.ui.menu:registerToMainMenu(self)
end

function QiReader:saveSettings()
    Settings.save(self.settings)
end

function QiReader:addToMainMenu(menu_items)
    menu_items.qireader_open = {
        text = _("QiReader"),
        sorting_hint = "more_tools",
        callback = function()
            self.controller:open()
        end,
    }
end

function QiReader:stopPlugin()
    if self.controller then
        self.controller:close()
    end
end

function QiReader:onCloseWidget()
    if self.controller then
        self.controller:close()
    end
end

return QiReader
