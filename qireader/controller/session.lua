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
    controller.subscriptions = {}
    controller.tags = {}
    controller.readlater_tag = nil
    controller.readlater_tag_id = nil
end

local function clearSession(controller)
    controller:clearCache()
    Settings.clearSession(controller.settings)
    controller.expanded_tags = false
    controller.readlater_tag = nil
    controller.readlater_tag_id = nil
    controller.readlater_tag_callbacks = nil
    controller.settings.stream_cache_generation = 0
    controller.save_settings()
    resetSubscriptions(controller)
end

local methods = {}

function methods:close()
    self.state = "closed"
    self:invalidateAllJobTokens()
    self:cancelAllPendingJobs()
    self.readlater_tag_callbacks = nil
    if self.article_widget then
        UIManager:close(self.article_widget)
        self.article_widget = nil
    end
    if self.article_detail_widget then
        UIManager:close(self.article_detail_widget)
        self.article_detail_widget = nil
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

function methods.showTransientMessage(_self, text)
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
    self:openHome({ force_loading = true })
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

function methods:startSubscriptionsLoad(options)
    options = options or {}
    local token = self:nextJobToken("subscriptions")
    local subscriptions_job = self:createBackgroundRequest({
        method = "GET",
        path = "/subscriptions",
    })
    if not subscriptions_job then
        if self:showGroupsFromCache() then
            return
        end
        self:showError(_("Cannot load subscriptions: ") .. _("Network request failed"), function()
            self:showGroupsFromCache()
        end)
        return
    end
    self:registerPendingJob("subscriptions", subscriptions_job)

    local function finalizeFailure(response)
        self:clearPendingJob("subscriptions", subscriptions_job)
        self.state = "groups"
        if self:showGroupsFromCache() then
            return
        end
        self:showError(_("Cannot load subscriptions: ") .. responseError(response), function()
            self:showGroupsFromCache()
        end)
    end

    local function pollUnreadCounts(subscriptions_response, tags_response)
        local unread_job = self:createBackgroundRequest({
            method = "GET",
            path = "/markers/unread/counts",
        })
        if not unread_job then
            self:clearPendingJob("subscriptions", subscriptions_job)
            self.state = "groups"
            self:showGroups(
                subscriptions_response.json,
                tags_response,
                self:readCache(self:cacheKey("unread_counts"), self:getCacheTtl("unread_counts"), true),
                options
            )
            return
        end
        self:registerPendingJob("unread_counts", unread_job)

        local function pollUnread()
            if self.state == "closed"
                or not self:isJobTokenCurrent("subscriptions", token)
                or self.pending_jobs.unread_counts ~= unread_job then
                self:cancelPendingJob("unread_counts", unread_job)
                return
            end
            local done, unread_response = unread_job:poll()
            if not done then
                UIManager:scheduleIn(0.1, pollUnread)
                return
            end
            self:clearPendingJob("unread_counts", unread_job)
            self:applyResponseSession(unread_response)
            if unread_response and unread_response.code == 401 then
                self:handleUnauthorized()
                return
            end
            local unread_json = unread_response and unread_response.code == 200 and unread_response.json or nil
            if unread_json then
                self:writeCache(self:cacheKey("unread_counts"), unread_json)
            else
                unread_json = self:readCache(
                    self:cacheKey("unread_counts"),
                    self:getCacheTtl("unread_counts"),
                    true
                )
            end
            self.state = "groups"
            self:showGroups(subscriptions_response.json, tags_response, unread_json, options)
        end

        pollUnread()
    end

    local function pollTags(subscriptions_response)
        local tags_job = self:createBackgroundRequest({
            method = "GET",
            path = "/tags",
        })
        if not tags_job then
            pollUnreadCounts(
                subscriptions_response,
                self:readCache(self:cacheKey("tags"), self:getCacheTtl("tags"), true)
            )
            return
        end
        self:registerPendingJob("tags", tags_job)

        local function poll()
            if self.state == "closed"
                or not self:isJobTokenCurrent("subscriptions", token)
                or self.pending_jobs.tags ~= tags_job then
                self:cancelPendingJob("tags", tags_job)
                return
            end
            local done, tags_response = tags_job:poll()
            if not done then
                UIManager:scheduleIn(0.1, poll)
                return
            end
            self:clearPendingJob("tags", tags_job)
            self:applyResponseSession(tags_response)
            if tags_response and tags_response.code == 401 then
                self:handleUnauthorized()
                return
            end
            local tags_json = tags_response and tags_response.code == 200 and tags_response.json or nil
            if tags_json then
                self:writeCache(self:cacheKey("tags"), tags_json)
            else
                tags_json = self:readCache(self:cacheKey("tags"), self:getCacheTtl("tags"), true)
            end
            pollUnreadCounts(subscriptions_response, tags_json)
        end

        poll()
    end

    local function pollSubscriptions()
        if self.state == "closed"
            or not self:isJobTokenCurrent("subscriptions", token)
            or self.pending_jobs.subscriptions ~= subscriptions_job then
            self:cancelPendingJob("subscriptions", subscriptions_job)
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
        self:writeCache(self:cacheKey("subscriptions"), response.json)
        pollTags(response)
    end

    pollSubscriptions()
end

function methods:startUnreadCountsLoad()
    if not self.subscriptions or #self.subscriptions == 0 then
        return false
    end
    local token = self:nextJobToken("unread_counts")
    local unread_job = self:createBackgroundRequest({
        method = "GET",
        path = "/markers/unread/counts",
    })
    if not unread_job then
        return false
    end
    self:registerPendingJob("unread_counts", unread_job)

    local function pollUnread()
        if self.state == "closed"
            or not self:isJobTokenCurrent("unread_counts", token)
            or self.pending_jobs.unread_counts ~= unread_job then
            self:cancelPendingJob("unread_counts", unread_job)
            return
        end
        local done, unread_response = unread_job:poll()
        if not done then
            UIManager:scheduleIn(0.1, pollUnread)
            return
        end
        self:clearPendingJob("unread_counts", unread_job)
        self:applyResponseSession(unread_response)
        if unread_response and unread_response.code == 401 then
            self:handleUnauthorized()
            return
        end
        local unread_json = unread_response and unread_response.code == 200 and unread_response.json or nil
        if unread_json then
            self:writeCache(self:cacheKey("unread_counts"), unread_json)
            self:applyUnreadCounts(unread_json, {
                refresh_existing = true,
            })
        end
    end

    pollUnread()
    return true
end

function methods:openHome(options)
    options = options or {}
    if not self.settings.cookie then
        self:showGroupsFromCache()
        return
    end
    local cached_subscriptions, subscriptions_cache_fresh = self:getSubscriptionsCacheState()
    local cached_tags, tags_cache_fresh = self:getTagsCacheState()
    local has_cache = self:showGroupsFromCache()
    if not NetworkMgr:isOnline() then
        return
    end
    local should_force_full_load = options.force_loading == true
    local should_refresh_subscriptions = should_force_full_load
        or not has_cache
        or not cached_subscriptions
        or not subscriptions_cache_fresh
        or not cached_tags
        or not tags_cache_fresh
    if should_force_full_load or not has_cache then
        self.state = "loading"
        self:showLoading(_("Loading"))
    end
    if should_refresh_subscriptions then
        self:startSubscriptionsLoad({
            silent = (not should_force_full_load) and has_cache,
            refresh_existing = has_cache,
        })
        return
    end
    self:startUnreadCountsLoad()
end

return methods
