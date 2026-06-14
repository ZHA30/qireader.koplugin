local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../i18n/po.lua")

local util = require("util")

local ArticleContent = {}

local MEDIA_TAGS = {
    { tag = "figure", label = "Image", paired = true, void = false },
    { tag = "picture", label = "Image", paired = true, void = false },
    { tag = "video", label = "Video", paired = true, void = true },
    { tag = "audio", label = "Audio", paired = true, void = true },
    { tag = "iframe", label = "Embedded content", paired = true, void = true },
    { tag = "object", label = "Embedded content", paired = true, void = true },
    { tag = "embed", label = "Embedded content", paired = false, void = true },
    { tag = "svg", label = "Image", paired = true, void = true },
    { tag = "canvas", label = "Image", paired = true, void = true },
    { tag = "image", label = "Image", paired = false, void = true },
    { tag = "img", label = "Image", paired = false, void = true },
}

local MEDIA_PLACEHOLDER_LABEL_IDS = {
    "Image",
    "Video",
    "Audio",
    "Embedded content",
    "Media",
}

local DROP_BLOCK_TAGS = {
    script = true,
    style = true,
    noscript = true,
    form = true,
    button = true,
    input = true,
    textarea = true,
    select = true,
    option = true,
}

local TEXT_TAGS = {
    p = true,
    div = true,
    section = true,
    article = true,
    main = true,
    header = true,
    footer = true,
    aside = true,
    h1 = true,
    h2 = true,
    h3 = true,
    h4 = true,
    h5 = true,
    h6 = true,
    blockquote = true,
    ul = true,
    ol = true,
    li = true,
    strong = true,
    b = true,
    em = true,
    i = true,
    pre = true,
    code = true,
    hr = true,
    br = true,
    span = true,
    a = true,
}

local IMAGE_FILE_EXTENSIONS = {
    jpg = true,
    jpeg = true,
    png = true,
    gif = true,
    webp = true,
    svg = true,
    tif = true,
    tiff = true,
    bmp = true,
}

local function trim(text)
    if not text then
        return ""
    end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalizeWhitespace(text)
    text = text or ""
    text = text:gsub("\r\n?", "\n")
    text = text:gsub("\u{00A0}", " ")
    text = text:gsub("[\t\f\v ]+", " ")
    text = text:gsub(" *\n *", "\n")
    return text
end

local function stripTags(text)
    text = text or ""
    text = text:gsub("<!%-%-.-%-%->", "")
    text = text:gsub("<[^>]+>", "")
    text = util.htmlEntitiesToUtf8(text)
    return trim(normalizeWhitespace(text))
end

local function escapeHtml(text)
    return util.htmlEscape(text or "")
end

local function escapePattern(text)
    return (text:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function asciiCasePattern(text)
    return (text:gsub(".", function(char)
        if char:match("%a") then
            return "[" .. char:lower() .. char:upper() .. "]"
        end
        return escapePattern(char)
    end))
end

local function startsWithMediaPlaceholder(text)
    text = trim(text)
    if text == "" then
        return false
    end
    for i = 1, #MEDIA_PLACEHOLDER_LABEL_IDS do
        local label = escapePattern(_(MEDIA_PLACEHOLDER_LABEL_IDS[i]))
        if text:match("^%[" .. label .. "%s*%]") then
            return true
        end
        if text:match("^%[" .. label .. "%s*" .. escapePattern(":")) then
            return true
        end
        local localized_colon = _(":")
        if localized_colon ~= ":" and text:match("^%[" .. label .. "%s*" .. escapePattern(localized_colon)) then
            return true
        end
    end
    return false
end

local function isLikelyMediaFilename(text)
    text = trim(util.htmlEntitiesToUtf8(text or ""))
    if text == "" then
        return false
    end
    local value = text:lower()
    if value:match("^https?://") or value:match("^//") or value:match("^data:image/") then
        return true
    end
    value = value:gsub("[#?].*$", "")
    value = value:gsub("/+$", "")
    value = value:match("([^/]+)$") or value
    if value:match("%s") then
        return false
    end
    local ext = value:match("%.([%w]+)$")
    return ext and IMAGE_FILE_EXTENSIONS[ext] == true or false
end

local function isMeaningfulPlaceholderText(text)
    text = trim(text)
    if text == "" then
        return false
    end
    if startsWithMediaPlaceholder(text) or isLikelyMediaFilename(text) then
        return false
    end
    for i = 1, #MEDIA_PLACEHOLDER_LABEL_IDS do
        if text == _(MEDIA_PLACEHOLDER_LABEL_IDS[i]) then
            return false
        end
    end
    -- Ignore broken alt/title payloads that collapse to punctuation only.
    if text:match('^[%s"\'`´“”‘’.,:;!%?%-%[%]%(%){}_/\\|<>~@#$%^&*+=]+$') then
        return false
    end
    return true
end

local function getAttr(attrs, name)
    if not attrs or not name then
        return nil
    end
    local attr_name = asciiCasePattern(name)
    local value = attrs:match(attr_name .. [[%s*=%s*"(.-)"]])
        or attrs:match(attr_name .. [[%s*=%s*'(.-)']])
    if value then
        return value
    end
    value = attrs:match(attr_name .. [[%s*=%s*([^%s>]+)]])
    if value then
        return value
    end
    return nil
end

local function addCandidate(candidates, value)
    if value and value ~= "" then
        candidates[#candidates + 1] = value
    end
end

local function addTextCandidates(candidates, attrs)
    if not attrs then
        return
    end
    addCandidate(candidates, getAttr(attrs, "alt"))
    addCandidate(candidates, getAttr(attrs, "aria-label"))
end

local function addBodyCandidates(candidates, body)
    if not body then
        return
    end
    local pieces = {}
    local function addPiece(value)
        value = stripTags(value)
        if isMeaningfulPlaceholderText(value) then
            pieces[#pieces + 1] = value
        end
    end

    for nested_attrs in body:gmatch("<[%w:_-]+([^>]*)>") do
        addPiece(getAttr(nested_attrs, "alt"))
        addPiece(getAttr(nested_attrs, "aria-label"))
    end

    addPiece(body)

    if #pieces > 0 then
        addCandidate(candidates, table.concat(pieces, " "))
    end
end

local function buildMediaPlaceholder(label_id, attrs, body)
    local kind = _(label_id or "Media")
    local candidates = {}
    addTextCandidates(candidates, attrs)
    addBodyCandidates(candidates, body)

    local text
    for i = 1, #candidates do
        local candidate = stripTags(candidates[i])
        if isMeaningfulPlaceholderText(candidate) then
            text = candidate
            break
        end
    end
    local placeholder_text
    if text and text ~= "" then
        placeholder_text = string.format(_("[%s: %s]"), kind, escapeHtml(text))
    else
        placeholder_text = string.format("[%s]", kind)
    end
    return string.format('<p class="media-placeholder">%s</p>', placeholder_text)
end

local function dropBlocks(html)
    for tag in pairs(DROP_BLOCK_TAGS) do
        html = html:gsub("<" .. tag .. "[^>]*>.-</" .. tag .. "%s*>", "")
        html = html:gsub("<" .. tag .. "[^>]*/%s*>", "")
    end
    return html
end

local function replaceMedia(html)
    for i = 1, #MEDIA_TAGS do
        local spec = MEDIA_TAGS[i]
        local tag = asciiCasePattern(spec.tag)
        if spec.paired then
            html = html:gsub("<" .. tag .. "([^>]*)>(.-)</" .. tag .. "%s*>", function(attrs, body)
                return buildMediaPlaceholder(spec.label, attrs, body)
            end)
        end
        if spec.void then
            html = html:gsub("<" .. tag .. "([^>]*)/?>", function(attrs)
                return buildMediaPlaceholder(spec.label, attrs)
            end)
        end
    end
    return html
end

local function sanitizeAnchors(html)
    html = html:gsub("<a([^>]*)>(.-)</a%s*>", function(_attrs, body)
        return body
    end)
    return html
end

local function sanitizeOpenTag(tag, attrs)
    tag = tag:lower()
    if not TEXT_TAGS[tag] then
        return ""
    end
    if tag == "a" then
        return "<a>"
    end
    if tag == "p" and attrs and attrs:match('class%s*=%s*["\'][^"\']*media%-placeholder[^"\']*["\']') then
        return '<p class="media-placeholder">'
    end
    if tag == "p" and attrs and attrs:match('class%s*=%s*["\'][^"\']*meta%-line[^"\']*["\']') then
        return '<p class="meta-line">'
    end
    if tag == "section" and attrs and attrs:match('class%s*=%s*["\'][^"\']*article%-meta[^"\']*["\']') then
        return '<section class="article-meta">'
    end
    if tag == "hr" then
        return "<hr/>"
    end
    if tag == "br" then
        return "<br/>"
    end
    return "<" .. tag .. ">"
end

local function sanitizeCloseTag(tag)
    tag = tag:lower()
    if not TEXT_TAGS[tag] or tag == "hr" or tag == "br" then
        return ""
    end
    return "</" .. tag .. ">"
end

local function sanitizeTags(html)
    html = html:gsub("<!DOCTYPE.-[>\n]", "")
    html = html:gsub("<!%-%-.-%-%->", "")
    html = html:gsub("<%?xml.-%?>", "")
    html = html:gsub("<([%w:_-]+)([^>]*)/?>", function(tag, attrs)
        if attrs and attrs:match("/%s*$") then
            local open = sanitizeOpenTag(tag, attrs)
            if open == "<hr/>" or open == "<br/>" or open == "" then
                return open
            end
            return open .. sanitizeCloseTag(tag)
        end
        return sanitizeOpenTag(tag, attrs)
    end)
    html = html:gsub("</([%w:_-]+)%s*>", function(tag)
        return sanitizeCloseTag(tag)
    end)
    return html
end

local function normalizeHtml(html)
    html = html or ""
    html = normalizeWhitespace(html)
    html = html:gsub("<body[^>]*>", "")
    html = html:gsub("</body%s*>", "")
    html = html:gsub("<html[^>]*>", "")
    html = html:gsub("</html%s*>", "")
    html = html:gsub("<head[^>]*>.-</head%s*>", "")
    html = html:gsub("<title[^>]*>.-</title%s*>", "")
    html = html:gsub("<meta[^>]*>", "")
    return html
end

local function collapseBreaks(html)
    html = html:gsub("(<br%s*/>%s*)+", "<br/>")
    html = html:gsub("(%s*<hr%s*/>%s*)+", "<hr/>")
    html = html:gsub("%s+</p>", "</p>")
    html = html:gsub("<p>%s+", "<p>")
    html = html:gsub("%s+</li>", "</li>")
    html = html:gsub("<li>%s+", "<li>")
    html = html:gsub("(%s*<p>%s*</p>%s*)+", "")
    return trim(html)
end

function ArticleContent.format(_entry, content)
    local raw = content or ""
    local sanitized = normalizeHtml(raw)
    sanitized = dropBlocks(sanitized)
    sanitized = replaceMedia(sanitized)
    sanitized = sanitizeAnchors(sanitized)
    sanitized = sanitizeTags(sanitized)
    sanitized = collapseBreaks(sanitized)

    if sanitized == "" then
        local fallback = util.htmlToPlainTextIfHtml(raw)
        fallback = escapeHtml(normalizeWhitespace(fallback))
        fallback = fallback:gsub("\n\n+", "</p><p>")
        fallback = fallback:gsub("\n", "<br/>")
        sanitized = "<p>" .. fallback .. "</p>"
    end
    return sanitized
end

ArticleContent.DEFAULT_CSS_TEMPLATE = [[
@page {
    margin: 0.35em 0.6em 0.45em 0.6em;
}

html, body {
    margin: 0;
    padding: 0;
}

body {
    line-height: 1.45;
}
p, div, section, article, main, header, footer, aside,
blockquote, ul, ol, pre {
    margin: 0;
}

p + *, div + *, section + *, article + *, main + *,
blockquote + *, ul + *, ol + *, pre + * {
    margin-top: 0.62em;
}

h1, h2, h3, h4, h5, h6 {
    font-weight: bold;
    line-height: 1.25;
    margin: 0.75em 0 0.35em 0;
}
h1 {
    font-size: 1.35em;
    margin-top: 0.2em;
}
h2 { font-size: 1.22em; }
h3 { font-size: 1.12em; }
h4, h5, h6 { font-size: 1.05em; }

.article-meta, .meta-line, header, footer, aside {
    font-size: 0.86em;
    line-height: 1.35;
}

blockquote {
    margin-left: 0.45em;
    padding-left: 0.6em;
    border-left: 0.08em solid #777;
}

ul, ol {
    padding-left: 1.45em;
}

li {
    margin: 0.15em 0;
}

li p, li div {
    margin: 0.15em 0;
}

pre, code {
    white-space: pre-wrap;
    font-family: monospace;
}

pre {
    padding: 0.35em 0.45em;
    border: 0.05em solid #999;
}

code {
    font-size: 0.92em;
}

hr {
    margin: 0.8em 0;
}

a {
    color: black;
}

.media-placeholder {
    margin: 0.75em 0;
    font-size: 0.9em;
    font-style: italic;
    text-align: center;
}
]]

function ArticleContent.getDefaultCss()
    return ArticleContent.DEFAULT_CSS_TEMPLATE
end

ArticleContent.DEFAULT_CSS = ArticleContent.getDefaultCss()

return ArticleContent
