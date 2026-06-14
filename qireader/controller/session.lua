local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Settings = require("qireader.settings")
local Trapper = require("ui/trapper")
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
    controller.readlater_tag_id = nil
    controller.readlater_tag_callbacks = nil
    controller.save_settings()
    resetSubscriptions(controller)
end

local methods = {}

function methods:close()
    self.state = "closed"
    self:invalidateAllJobTokens()
    self:cancelAllPendingJobs()
    if self.article_detail_widget then
        UIManager:close(self.article_detail_widget)
        self.article_detail_widget = nil
    end
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
    self:invalidateAllJobTokens()
    self:cancelAllPendingJobs()
    clearSession(self)
    if self.article_detail_widget then
        UIManager:close(self.article_detail_widget)
        self.article_detail_widget = nil
    end
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
    if NetworkMgr:willRerunWhenOnline(function() self:login(email, password) end) then
        return
    end
    self.state = "loading"
    self:showLoading(_("Logging in..."))
    local request_token = self:nextJobToken("login")
    Trapper:wrap(function()
        local completed, response = Trapper:dismissableRunInSubprocess(function()
            local Client = require("qireader.client")
            local client = Client.new{
                api_base = self.settings.api_base,
                cookie = self.settings.cookie,
            }
            return client:login(email, password)
        end, _("Logging in..."))
        if self.state == "closed" or not self:isJobTokenCurrent("login", request_token) then
            return
        end
        if not completed then
            self.state = "closed"
            self:showGroupsPage()
            return
        end
        self:applyResponseSession(response)
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
    end)
end

function methods:startSubscriptionsLoad()
    local token = self:nextJobToken("subscriptions")
    local subscriptions_job = self:createBackgroundRequest({
        method = "GET",
        path = "/subscriptions",
    })
    if not subscriptions_job then
        self:showError(_("Cannot load subscriptions: ") .. _("Network request failed"), function()
            self:showGroupsFromCache()
        end)
        return
    end
    self:registerPendingJob("subscriptions", subscriptions_job)

    local function finalizeFailure(response)
        self:clearPendingJob("subscriptions", subscriptions_job)
        self.state = "groups"
        self:showError(_("Cannot load subscriptions: ") .. responseError(response), function()
            self:showGroupsFromCache()
        end)
    end

    local function pollUnreadCounts(subscriptions_response)
        local unread_job = self:createBackgroundRequest({
            method = "GET",
            path = "/markers/unread/counts",
        })
        if not unread_job then
            self:clearPendingJob("subscriptions", subscriptions_job)
            self.state = "groups"
            self:showGroups(subscriptions_response.json, nil)
            return
        end
        self:registerPendingJob("unread_counts", unread_job)

        local function pollUnread()
            if self.state == "closed"
                or not self:isJobTokenCurrent("subscriptions", token)
                or self.pending_jobs.unread_counts ~= unread_job then
                self:cancelPendingJob("unread_counts")
                return
            end
            local done, unread_response = unread_job:poll()
            if not done then
                UIManager:scheduleIn(0.1, pollUnread)
                return
            end
            self:clearPendingJob("unread_counts", unread_job)
            local unread_json = unread_response and unread_response.code == 200 and unread_response.json or nil
            self.state = "groups"
            self:showGroups(subscriptions_response.json, unread_json)
        end

        pollUnread()
    end

    local function pollSubscriptions()
        if self.state == "closed"
            or not self:isJobTokenCurrent("subscriptions", token)
            or self.pending_jobs.subscriptions ~= subscriptions_job then
            self:cancelPendingJob("subscriptions")
            return
        end
        local done, response = subscriptions_job:poll()
        if not done then
            UIManager:scheduleIn(0.1, pollSubscriptions)
            return
        end
        self:clearPendingJob("subscriptions", subscriptions_job)
        self:applyResponseSession(response)
        if response and response.code == 401 then
            clearSession(self)
            self.state = "groups"
            self:showGroupsPage()
            UIManager:show(InfoMessage:new{
                text = _("Session expired. Please log in again from Account."),
            })
            return
        end
        if not response or response.code ~= 200 or not response.json then
            finalizeFailure(response)
            return
        end
        pollUnreadCounts(response)
    end

    pollSubscriptions()
end

function methods:openHome()
    if not self.settings.cookie then
        self:showGroupsFromCache()
        return
    end
    if NetworkMgr:willRerunWhenOnline(function() self:openHome() end) then
        return
    end
    self.state = "loading"
    self:showLoading(_("Loading subscriptions..."))
    self:startSubscriptionsLoad()
end

return methods
