local JSON = require("json")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")

local Client = {}
Client.__index = Client

local function joinCookie(headers)
    if not headers then return nil end
    local values = {}
    for key, value in pairs(headers) do
        if type(key) == "string" and key:lower() == "set-cookie" then
            if type(value) == "table" then
                for i = 1, #value do
                    local cookie = value[i]
                    table.insert(values, cookie:match("^[^;]+"))
                end
            elseif type(value) == "string" then
                table.insert(values, value:match("^[^;]+"))
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
    local headers = {
        ["Accept"] = "application/json",
        ["X-Api-Version"] = "21.0.0",
    }
    if self.settings.cookie then
        headers["Cookie"] = self.settings.cookie
    end
    if options.body then
        body = JSON.encode(options.body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
    end

    local sink = {}
    local request = {
        url = self.api_base .. path .. encodeQuery(options.query),
        method = method,
        headers = headers,
        sink = ltn12.sink.table(sink),
    }
    if body then
        request.source = ltn12.source.string(body)
    end

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, response_headers, status = socket.skip(1, https.request(request))
    socketutil:reset_timeout()

    local response_body = table.concat(sink)
    local json = decodeJson(response_body)
    local cookie = joinCookie(response_headers)
    if cookie then
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

function Client:getCurrentUser()
    return self:request("GET", "/session/user")
end

function Client:getSubscriptions()
    return self:request("GET", "/subscriptions")
end

function Client:getUnreadCounts()
    return self:request("GET", "/markers/unread/counts")
end

function Client:getTags()
    return self:request("GET", "/tags")
end

function Client:getStream(stream_id, query)
    return self:request("GET", "/streams/" .. tostring(stream_id), {
        query = query,
    })
end

function Client:getEntry(entry_id, stream_id)
    return self:request("GET", "/entry/" .. tostring(entry_id), {
        query = {
            streamId = stream_id,
        },
    })
end

function Client:getEntryContents(stream_id, entry_ids)
    return self:request("GET", "/entry-contents", {
        query = {
            streamId = stream_id,
            entryIds = entry_ids,
        },
    })
end

function Client:markEntriesRead(entry_ids)
    return self:request("PUT", "/markers/reads", {
        body = {
            type = "entries",
            entryIds = entry_ids,
        },
    })
end

function Client:markEntryUnread(entry_id)
    return self:request("PUT", "/markers/unread", {
        body = {
            entryId = entry_id,
        },
    })
end

function Client:addEntryTag(entry_id, tag_id, entry_type)
    return self:request("PUT", "/entries/" .. tostring(entry_id) .. "/tags/" .. tostring(tag_id), {
        body = {
            entryType = entry_type or "feed",
            entryId = entry_id,
            tagId = tag_id,
        },
    })
end

function Client:removeEntryTag(entry_id, tag_id, entry_type)
    entry_type = entry_type or "feed"
    local path = "/entries/" .. tostring(entry_type)
        .. "/" .. tostring(entry_id)
        .. "/tags/" .. tostring(tag_id)
    return self:request("DELETE", path, {
        body = {
            entryType = entry_type,
            entryId = entry_id,
            tagId = tag_id,
        },
    })
end

return Client
