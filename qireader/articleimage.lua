local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../i18n/po.lua")

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local socket_url = require("socket.url")
local util = require("util")

local ArticleImage = {}

local CACHE_DIR = DataStorage:getDataDir() .. "/cache/qireader/images"
local IMAGE_EXTENSIONS = {
    jpg = true,
    jpeg = true,
    png = true,
    gif = true,
    webp = true,
    svg = true,
    tif = true,
    tiff = true,
}
local IMAGE_EXTENSION_ORDER = {
    "jpg",
    "jpeg",
    "png",
    "gif",
    "webp",
    "svg",
    "tif",
    "tiff",
}
local MIME_EXTENSIONS = {
    ["image/jpeg"] = "jpg",
    ["image/jpg"] = "jpg",
    ["image/png"] = "png",
    ["image/gif"] = "gif",
    ["image/webp"] = "webp",
    ["image/svg+xml"] = "svg",
    ["image/tiff"] = "tif",
}
local MAX_REDIRECTS = 4

local function showMessage(controller, text)
    if controller and controller.showTransientMessage then
        controller:showTransientMessage(text)
        return
    end
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    UIManager:show(InfoMessage:new{ text = text })
end

local function getHeader(headers, name)
    name = name:lower()
    for key, value in pairs(headers or {}) do
        if type(key) == "string" and key:lower() == name then
            if type(value) == "table" then
                return value[1]
            end
            return value
        end
    end
end

local function getUrlExtension(url)
    local path = (url or ""):gsub("[#?].*$", "")
    local ext = util.getFileNameSuffix(path):lower()
    if IMAGE_EXTENSIONS[ext] then
        return ext
    end
end

local function getMimeExtension(headers)
    local content_type = getHeader(headers, "content-type")
    if type(content_type) ~= "string" then
        return nil
    end
    local mime = content_type:lower():match("^%s*([^;%s]+)")
    return mime and MIME_EXTENSIONS[mime] or nil
end

local function detectImageExtension(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local header = file:read(256) or ""
    file:close()
    if header:sub(1, 2) == "\255\216" then
        return "jpg"
    end
    if header:sub(1, 8) == "\137PNG\r\n\026\n" then
        return "png"
    end
    if header:sub(1, 4) == "GIF8" then
        return "gif"
    end
    if header:sub(1, 4) == "RIFF" and header:sub(9, 12) == "WEBP" then
        return "webp"
    end
    local lower_header = header:lower():gsub("^%s+", "")
    if lower_header:match("^<svg") or lower_header:match("^<%?xml") then
        return "svg"
    end
end

local function getCachedPath(cache_key)
    for i = 1, #IMAGE_EXTENSION_ORDER do
        local path = string.format("%s/%s.%s", CACHE_DIR, cache_key, IMAGE_EXTENSION_ORDER[i])
        if lfs.attributes(path, "mode") == "file" then
            return path
        end
    end
end

local function normalizeRedirectUrl(current_url, location)
    if type(location) ~= "string" or location == "" then
        return nil
    end
    local ok, absolute_url = pcall(socket_url.absolute, current_url, location)
    if ok and type(absolute_url) == "string" then
        return absolute_url
    end
    if location:match("^//") then
        return "https:" .. location
    end
    return location
end

local function requestToFile(url, path, referer)
    local http = require("socket.http")
    local https = require("ssl.https")
    local socket = require("socket")
    local socketutil = require("socketutil")

    local current_url = url
    local redirect_count = 0
    while redirect_count < MAX_REDIRECTS do
        redirect_count = redirect_count + 1
        local parsed = socket_url.parse(current_url)
        if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
            return nil, _("Unsupported image URL.")
        end
        os.remove(path)
        local file, file_err = io.open(path, "wb")
        if not file then
            return nil, file_err
        end
        local headers = {
            ["Accept"] = "image/*,*/*;q=0.8",
            ["User-Agent"] = socketutil.USER_AGENT,
        }
        if referer and referer ~= "" then
            headers["Referer"] = referer
        end
        local request = {
            url = current_url,
            method = "GET",
            headers = headers,
            sink = socketutil.file_sink(file),
        }
        local requester = parsed.scheme == "https" and https or http
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local code, response_headers, status = socket.skip(1, requester.request(request))
        socketutil:reset_timeout()
        local numeric_code = tonumber(code)
        if numeric_code and numeric_code >= 300 and numeric_code < 400 then
            local location = getHeader(response_headers, "location")
            local next_url = normalizeRedirectUrl(current_url, location)
            if next_url then
                current_url = next_url
                os.remove(path)
            else
                return nil, status or _("Image download failed.")
            end
        elseif numeric_code and numeric_code >= 200 and numeric_code < 300 then
            return response_headers, nil, current_url
        else
            os.remove(path)
            return nil, status or tostring(code or _("Image download failed."))
        end
    end
    os.remove(path)
    return nil, _("Too many image redirects.")
end

function ArticleImage.downloadToCache(url, referer)
    if type(url) ~= "string" or url == "" then
        return nil, _("Unsupported image URL.")
    end
    local ok, make_path_err = util.makePath(CACHE_DIR)
    if not ok then
        return nil, make_path_err
    end
    local cache_key = md5(url)
    local cached_path = getCachedPath(cache_key)
    if cached_path then
        return cached_path
    end

    local tmp_path = string.format("%s/%s.tmp", CACHE_DIR, cache_key)
    local headers, request_err, final_url = requestToFile(url, tmp_path, referer)
    if not headers then
        return nil, request_err
    end
    local ext = getUrlExtension(final_url) or getMimeExtension(headers) or detectImageExtension(tmp_path)
    if not ext then
        os.remove(tmp_path)
        return nil, _("Unsupported image format.")
    end
    local final_path = string.format("%s/%s.%s", CACHE_DIR, cache_key, ext)
    os.remove(final_path)
    local renamed, rename_err = os.rename(tmp_path, final_path)
    if not renamed then
        os.remove(tmp_path)
        return nil, rename_err
    end
    return final_path
end

function ArticleImage.open(controller, ref, owner_widget)
    if not ref or type(ref.url) ~= "string" or ref.url == "" then
        showMessage(controller, _("Cannot open image."))
        return
    end
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr and NetworkMgr.willRerunWhenOnline
        and NetworkMgr:willRerunWhenOnline(function()
            ArticleImage.open(controller, ref, owner_widget)
        end) then
        return
    end
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local url = ref.url
        local referer = ref.referer
        local completed, path, err = Trapper:dismissableRunInSubprocess(function()
            local ArticleImageWorker = require("qireader.articleimage")
            return ArticleImageWorker.downloadToCache(url, referer)
        end, _("Downloading image..."))
        if not completed then
            showMessage(controller, _("Image download interrupted."))
            return
        end
        if not path then
            showMessage(controller, err or _("Cannot open image."))
            return
        end
        if owner_widget and owner_widget.closing then
            return
        end
        local ImageViewer = require("ui/widget/imageviewer")
        local UIManager = require("ui/uimanager")
        local ok, image_viewer = pcall(function()
            return ImageViewer:new{
                file = path,
                with_title_bar = true,
                title_text = ref.title or _("Image"),
            }
        end)
        if not ok or not image_viewer then
            showMessage(controller, _("Cannot open image."))
            return
        end
        UIManager:show(image_viewer)
    end)
end

return ArticleImage
