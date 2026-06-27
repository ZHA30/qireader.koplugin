local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../i18n/po.lua")

local buffer = require("string.buffer")
local DataStorage = require("datastorage")
local ffiutil = require("ffi/util")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local util = require("util")

local Background = {}
Background.__index = Background

local DEFAULT_TIMEOUT_SECONDS = 45
local RESULT_DIR = DataStorage:getDataDir() .. "/cache/qireader-background"
local job_counter = 0
local result_dir_cleaned = false

local function timeoutResponse()
    return {
        code = 0,
        status = _("Request timeout"),
        body = "",
        json = nil,
        cookie = nil,
    }
end

local function errorResponse(status)
    return {
        code = 0,
        status = status or _("Decode failed"),
        body = "",
        json = nil,
        cookie = nil,
    }
end

local function newResultPath()
    if not result_dir_cleaned then
        ffiutil.purgeDir(RESULT_DIR)
        result_dir_cleaned = true
    end
    if not util.makePath(RESULT_DIR) then
        return nil, "failed creating result directory"
    end
    job_counter = job_counter + 1
    return string.format("%s/%d-%d.dat", RESULT_DIR, os.time(), job_counter)
end

local function writeResult(path, value)
    local handle = io.open(path, "wb")
    if not handle then
        return false
    end
    handle:write(value)
    handle:close()
    return true
end

local function readResult(path)
    local handle = io.open(path, "rb")
    if not handle then
        return nil
    end
    local payload = handle:read("*a")
    handle:close()
    os.remove(path)
    return payload
end

local function newJob(client_settings, request_spec)
    local result_path, result_path_error = newResultPath()
    if not result_path then
        return nil, result_path_error or _("Failed creating result directory")
    end

    local pid, err = ffiutil.runInSubProcess(function()
        local ok, results = xpcall(function()
            local Client = require("qireader.client")
            local client = Client.new{
                api_base = client_settings.api_base,
                cookie = client_settings.cookie,
            }
            return table.pack(client:request(
                request_spec.method,
                request_spec.path,
                {
                    url = request_spec.url,
                    query = request_spec.query,
                    body = request_spec.body,
                    headers = request_spec.headers,
                    use_session = request_spec.use_session,
                }
            ))
        end, debug.traceback)
        if not ok then
            results = {
                n = 1,
                errorResponse(tostring(results)),
            }
        end
        local encoded_ok, encoded = pcall(buffer.encode, results)
        if encoded_ok then
            writeResult(result_path, encoded)
        else
            local fallback = buffer.encode({
                n = 1,
                {
                    code = 0,
                    status = tostring(encoded),
                    body = "",
                    json = nil,
                    cookie = nil,
                },
            })
            writeResult(result_path, fallback)
        end
    end)

    if not pid then
        os.remove(result_path)
        logger.warn("QiReader background request failed to start:", err)
        return nil, err
    end

    return setmetatable({
        pid = pid,
        result_path = result_path,
        started_at = os.time(),
        timeout_seconds = tonumber(request_spec.timeout) or DEFAULT_TIMEOUT_SECONDS,
        cancelled = false,
        collected = false,
        collect_scheduled = false,
    }, Background)
end

function Background.new(client_settings, request_spec)
    return newJob(client_settings, request_spec)
end

function Background:cancel()
    if self.cancelled or self.collected or not self.pid then
        return
    end
    self.cancelled = true
    ffiutil.terminateSubProcess(self.pid)
    self:collectLater()
end

function Background:isTimedOut()
    return self.timeout_seconds > 0 and os.time() - self.started_at >= self.timeout_seconds
end

function Background:_removeResult()
    if self.result_path then
        os.remove(self.result_path)
        self.result_path = nil
    end
end

function Background:collectLater(delay)
    if self.collect_scheduled or not self.pid then
        return
    end
    delay = delay or 1
    self.collect_scheduled = true
    local function collect()
        if not self.pid then
            self.collect_scheduled = false
            return
        end
        if ffiutil.isSubProcessDone(self.pid) then
            self:_removeResult()
            self.pid = nil
            self.collected = true
            self.collect_scheduled = false
            return
        end
        UIManager:scheduleIn(delay, collect)
    end
    UIManager:scheduleIn(delay, collect)
end

function Background:poll()
    if self.collected or not self.pid then
        return true, nil, "closed"
    end

    local subprocess_done = ffiutil.isSubProcessDone(self.pid)

    if not subprocess_done and self:isTimedOut() then
        self:cancel()
        return true, timeoutResponse(), "timeout"
    end

    if not subprocess_done then
        return false
    end

    self.collected = true
    local response
    if self.result_path then
        local payload = readResult(self.result_path)
        self.result_path = nil
        local ok, decoded = pcall(buffer.decode, payload)
        if ok and decoded and decoded[1] then
            response = decoded[1]
        else
            logger.warn("QiReader background request returned invalid payload:", payload and #payload or "nil")
            response = errorResponse(payload and _("Decode failed") or _("No response"))
        end
    else
        logger.warn("QiReader background request missing result path")
        response = errorResponse(_("No response"))
    end
    self.pid = nil

    if self.cancelled then
        return true, response, "cancelled"
    end
    return true, response
end

return Background
