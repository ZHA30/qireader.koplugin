-- luacheck: globals G_reader_settings

local _dir = (debug.getinfo(1, "S").source:match("^@(.+/)") or "./")

local function parsePO(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local translations, msgid, msgstr = {}, nil, nil
    local in_msgid, in_msgstr = false, false

    local function flush()
        if msgid and msgstr and msgid ~= "" and msgstr ~= "" then
            translations[msgid] = msgstr
        end
        msgid, msgstr = nil, nil
        in_msgid, in_msgstr = false, false
    end

    local function unescape(text)
        return text:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\")
    end

    for raw_line in file:lines() do
        local line = raw_line:match("^%s*(.-)%s*$")
        if line == "" then
            flush()
        elseif not line:match("^#") and line:match('^msgid%s+"') then
            flush()
            msgid = unescape(line:match('^msgid%s+"(.*)"') or "")
            in_msgid, in_msgstr = true, false
        elseif line:match('^msgstr%s+"') then
            msgstr = unescape(line:match('^msgstr%s+"(.*)"') or "")
            in_msgid, in_msgstr = false, true
        elseif line:match('^"') then
            local continued = unescape(line:match('^"(.*)"') or "")
            if in_msgid and msgid then
                msgid = msgid .. continued
            elseif in_msgstr and msgstr then
                msgstr = msgstr .. continued
            end
        end
    end

    flush()
    file:close()
    return translations
end

local lang = G_reader_settings and G_reader_settings:readSetting("language")
    or os.getenv("LANGUAGE")
    or os.getenv("LANG")
    or "en"
lang = lang:match("^([a-zA-Z_]+)") or "en"

local translations
if not lang:match("^en_?") and lang ~= "C" then
    translations = parsePO(_dir .. lang .. ".po")
    if not translations then
        local prefix = lang:match("^([a-zA-Z]+)")
        if prefix ~= lang then
            translations = parsePO(_dir .. prefix .. ".po")
        end
    end
end

local ko_gettext = require("gettext")
if translations then
    return function(msgid)
        return translations[msgid] or ko_gettext(msgid)
    end
end

return ko_gettext
