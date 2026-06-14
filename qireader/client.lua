local JSON = require("json")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")

local Client = {}
Client.__index = Client

local function addCookieValue(values, value)
    if type(value) ~= "string" then
        return
    end
    local cookie = value:match("^[^;]+")
    if cookie and cookie ~= "" then
        values[#values + 1] = cookie
    end
end

local function joinCookie(headers)
    if not headers then return nil end
    local values = {}
    for key, value in pairs(headers) do
        if type(key) == "string" and key:lower() == "set-cookie" then
            if type(value) == "table" then
                for i = 1, #value do
                    addCookieValue(values, value[i])
                end
            elseif type(value) == "string" then
                addCookieValue(values, value)
            end
        end
    end
    if #values == 0 then return nil end
    return table.concat(values, "; ")
end

local function encodeQuery(query)
    if not query then return "" end
    local parts = {}
    for key, value in pairs(query) do
        if type(value) == "table" then
            for i = 1, #value do
                local item = value[i]
                table.insert(parts, socket_url.escape(key) .. "=" .. socket_url.escape(tostring(item)))
            end
        elseif value ~= nil then
            table.insert(parts, socket_url.escape(key) .. "=" .. socket_url.escape(tostring(value)))
        end
    end
    if #parts == 0 then return "" end
    return "?" .. table.concat(parts, "&")
end

local function appendQuery(url, query)
    local encoded_query = encodeQuery(query)
    if encoded_query == "" then
        return url
    end
    if url:find("?", 1, true) then
        return url .. "&" .. encoded_query:sub(2)
    end
    return url .. encoded_query
end

local function decodeJson(body)
    if not body or body == "" then return nil end
    local ok, decoded = pcall(JSON.decode, body, JSON.decode.simple)
    if ok then
        return decoded
    end
end

function Client.new(settings)
    return setmetatable({
        settings = settings,
        api_base = settings.api_base or "https://www.qireader.com/api",
    }, Client)
end

function Client:request(method, path, options)
    options = options or {}
    local body
    local use_session = options.use_session ~= false
    local headers = {
        ["Accept"] = "application/json",
    }
    if use_session then
        headers["X-Api-Version"] = "21.0.0"
    end
    if use_session and self.settings.cookie then
        headers["Cookie"] = self.settings.cookie
    end
    if options.headers then
        for key, value in pairs(options.headers) do
            if value ~= nil then
                headers[key] = value
            end
        end
    end
    if options.body then
        body = JSON.encode(options.body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
    end

    local sink = {}
    local url = appendQuery(options.url or (self.api_base .. (path or "")), options.query)
    local request = {
        url = url,
        method = method,
        headers = headers,
        sink = ltn12.sink.table(sink),
    }
    if body then
        request.source = ltn12.source.string(body)
    end

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, request_result, code, response_headers, status = pcall(https.request, request)
    socketutil:reset_timeout()
    if not ok then
        return {
            code = 0,
            status = tostring(request_result),
            headers = nil,
            body = "",
            json = nil,
            cookie = nil,
        }
    end
    code, response_headers, status = socket.skip(1, request_result, code, response_headers, status)

    local response_body = table.concat(sink)
    local json = decodeJson(response_body)
    local cookie = use_session and joinCookie(response_headers) or nil
    if use_session and cookie then
        self.settings.cookie = cookie
    end

    return {
        code = tonumber(code) or 0,
        status = status,
        headers = response_headers,
        body = response_body,
        json = json,
        cookie = cookie,
    }
end

function Client:login(email, password)
    return self:request("POST", "/session", {
        body = {
            email = email,
            password = password,
        },
    })
end

return Client
