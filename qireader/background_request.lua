local buffer = require("string.buffer")
local ffiutil = require("ffi/util")
local UIManager = require("ui/uimanager")

local BackgroundRequest = {}
BackgroundRequest.__index = BackgroundRequest

local function newJob(client_settings, request_spec)
    local pid, read_fd = ffiutil.runInSubProcess(function(_pid, write_fd)
        local Client = require("qireader.client")
        local client = Client.new{
            api_base = client_settings.api_base,
            cookie = client_settings.cookie,
        }
        local results = table.pack(client:request(
            request_spec.method,
            request_spec.path,
            {
                query = request_spec.query,
                body = request_spec.body,
            }
        ))
        local ok, encoded = pcall(buffer.encode, results)
        if ok then
            ffiutil.writeToFD(write_fd, encoded, true)
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
            ffiutil.writeToFD(write_fd, fallback, true)
        end
    end, true)

    if not pid then
        return nil, read_fd
    end

    return setmetatable({
        pid = pid,
        read_fd = read_fd,
        cancelled = false,
        collected = false,
    }, BackgroundRequest)
end

function BackgroundRequest.new(client_settings, request_spec)
    return newJob(client_settings, request_spec)
end

function BackgroundRequest:cancel()
    if self.cancelled or self.collected or not self.pid then
        return
    end
    self.cancelled = true
    ffiutil.terminateSubProcess(self.pid)
end

function BackgroundRequest:_closeReadFD()
    if self.read_fd then
        ffiutil.readAllFromFD(self.read_fd)
        self.read_fd = nil
    end
end

function BackgroundRequest:collectLater(delay)
    if not self.pid then
        return
    end
    delay = delay or 1
    local pid = self.pid
    local read_fd = self.read_fd
    UIManager:scheduleIn(delay, function()
        if ffiutil.isSubProcessDone(pid) then
            if read_fd then
                ffiutil.readAllFromFD(read_fd)
            end
        else
            UIManager:scheduleIn(delay, function()
                if ffiutil.isSubProcessDone(pid) and read_fd then
                    ffiutil.readAllFromFD(read_fd)
                end
            end)
        end
    end)
end

function BackgroundRequest:poll()
    if self.collected or not self.pid then
        return true, nil, "closed"
    end

    local subprocess_done = ffiutil.isSubProcessDone(self.pid)
    local stuff_to_read = self.read_fd and ffiutil.getNonBlockingReadSize(self.read_fd) ~= 0

    if not subprocess_done and not stuff_to_read then
        return false
    end

    self.collected = true
    local response
    if stuff_to_read then
        local payload = ffiutil.readAllFromFD(self.read_fd)
        self.read_fd = nil
        local ok, decoded = pcall(buffer.decode, payload)
        if ok and decoded and decoded[1] then
            response = decoded[1]
        else
            response = {
                code = 0,
                status = "decode failed",
                body = "",
                json = nil,
                cookie = nil,
            }
        end
        if not subprocess_done then
            self:collectLater()
        end
    else
        self:_closeReadFD()
        response = nil
    end

    if self.cancelled then
        return true, response, "cancelled"
    end
    return true, response
end

return BackgroundRequest
