local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "i18n/po.lua")
local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Controller = require("qireader.controller")
local Settings = require("qireader.settings")

local QiReader = WidgetContainer:extend{
    name = "qireader",
    is_doc_only = false,
    settings_key = "qireader",
}

function QiReader:isFileManagerContext()
    return self.ui and self.ui.document == nil
end

function QiReader:ensureController()
    if not self.settings then
        self.settings = Settings.load()
    end
    if not self.controller then
        self.controller = Controller.new{
            plugin = self,
            settings = self.settings,
            save_settings = function()
                self:saveSettings()
            end,
        }
    end
    return self.controller
end

function QiReader:init()
    if not self:isFileManagerContext() then
        return
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function QiReader:onDispatcherRegisterActions()
    Dispatcher:registerAction(self.name .. "_open", {
        category = "none",
        event = "OpenQiReader",
        title = _("QiReader"),
        filemanager = true,
    })
end

function QiReader:onOpenQiReader()
    if not self:isFileManagerContext() then
        return
    end
    self:ensureController():open()
end

function QiReader:saveSettings()
    if self.settings then
        Settings.save(self.settings)
    end
end

function QiReader:addToMainMenu(menu_items)
    if not self:isFileManagerContext() then
        return
    end
    menu_items.qireader_open = {
        text = _("QiReader"),
        sorting_hint = "search",
        callback = function()
            self:onOpenQiReader()
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

function QiReader.deletePluginSettings()
    require("qireader.cache").deleteStorage()
end

return QiReader
