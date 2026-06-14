local BackgroundRequest = require("qireader.background_request")
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
        article_detail_widget = nil,
        readlater_tag_id = nil,
        pending_jobs = {},
        job_tokens = {},
    }, Controller)
end

function Controller:nextJobToken(key)
    self.job_tokens[key] = (self.job_tokens[key] or 0) + 1
    return self.job_tokens[key]
end

function Controller:isJobTokenCurrent(key, token)
    return self.job_tokens[key] == token
end

function Controller:invalidateAllJobTokens()
    self.job_tokens = {}
end

function Controller:createBackgroundRequest(request_spec)
    return BackgroundRequest.new({
        api_base = self.settings.api_base,
        cookie = self.settings.cookie,
    }, request_spec)
end

function Controller:registerPendingJob(key, job)
    if self.pending_jobs[key] and self.pending_jobs[key].cancel then
        self.pending_jobs[key]:cancel()
    end
    self.pending_jobs[key] = job
end

function Controller:clearPendingJob(key, job)
    if job and self.pending_jobs[key] ~= job then
        return
    end
    self.pending_jobs[key] = nil
end

function Controller:cancelPendingJob(key)
    local job = self.pending_jobs[key]
    if job and job.cancel then
        job:cancel()
    end
    self.pending_jobs[key] = nil
end

function Controller:cancelAllPendingJobs()
    for key, job in pairs(self.pending_jobs) do
        if job and job.cancel then
            job:cancel()
        end
        self.pending_jobs[key] = nil
    end
end

function Controller:applyResponseSession(response)
    if response and response.cookie and response.cookie ~= "" then
        self.settings.cookie = response.cookie
    end
end

installMethods(Controller, article_settings_methods)
installMethods(Controller, article_methods)
installMethods(Controller, menu_methods)
installMethods(Controller, session_methods)
installMethods(Controller, subscription_methods)

return Controller
