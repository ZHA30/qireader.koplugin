local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Settings = require("qireader.settings")
local UIManager = require("ui/uimanager")

local function responseError(response)
    if not response then
        return _("No response")
    end
    if response.code and response.code > 0 then
        return string.format("%s %s", tostring(response.code), response.status or "")
    end
    return response.status or _("Network request failed")
end

local function resetSubscriptions(controller)
    controller.groups = {}
    controller.ungrouped = {}
    controller.ungrouped_unread_count = 0
    controller.subscriptions = {}
end

local function clearSession(controller)
    Settings.clearSession(controller.settings)
    controller.save_settings()
    resetSubscriptions(controller)
end

local methods = {}

function methods:close()
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

function methods:showTransientMessage(text)
    self.last_message = text
    UIManager:show(InfoMessage:new{
        text = text,
    })
end

function methods:handleUnauthorized()
    clearSession(self)
    if self.article_widget then
        UIManager:close(self.article_widget)
        self.article_widget = nil
    end
    self:showGroupsPage()
    self:showTransientMessage(_("Session expired. Please log in again from Account."))
end

function methods:open()
    if NetworkMgr:willRerunWhenOnline(function() self:open() end) then
        return
    end
    self:openHome()
end

function methods:closeActiveDialog()
    if self.active_dialog then
        UIManager:close(self.active_dialog)
        self.active_dialog = nil
    end
end

function methods:closeLoginDialog()
    if self.login_dialog then
        UIManager:close(self.login_dialog)
        self.login_dialog = nil
    end
end

function methods:showLoginDialog()
    self:closeLoginDialog()
    local is_logged_in = self.settings.cookie ~= nil
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
                    text = _("Log out"),
                    enabled = is_logged_in,
                    callback = function()
                        local fields = dialog:getFields()
                        self.login_fields.email = fields[1] or ""
                        UIManager:close(dialog)
                        if self.login_dialog == dialog then
                            self.login_dialog = nil
                        end
                        clearSession(self)
                        self.login_fields.password = ""
                        self:showGroupsPage()
                    end,
                },
                {
                    text = _("Log in"),
                    enabled = not is_logged_in,
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

function methods:login(email, password)
    self.state = "loading"
    self:showLoading(_("Logging in..."))
    local response = self.client:login(email, password)
    if self.state == "closed" then
        return
    end
    if response.code ~= 200 or not response.json or not response.json.result then
        clearSession(self)
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

function methods:openHome()
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
        clearSession(self)
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

return methods
