local util = require("util")

local ArticleContent = {}
local DEFAULT_PAGE_MARGIN_VERTICAL = 8
local DEFAULT_PAGE_MARGIN_HORIZONTAL = 12

local VOID_MEDIA_PATTERN = {
    img = "图片",
    image = "图片",
    video = "视频",
    audio = "音频",
    iframe = "嵌入内容",
    object = "嵌入内容",
    embed = "嵌入内容",
    svg = "图片",
    figure = "图片",
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
    source = true,
    track = true,
    canvas = true,
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

local function isMeaningfulPlaceholderText(text)
    text = trim(text)
    if text == "" then
        return false
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
    local pattern = name .. [[%s*=%s*(['"])(.-)%1]]
    local value = attrs:match(pattern)
    if value then
        return value
    end
    pattern = name .. [[%s*=%s*([^%s>]+)]]
    value = attrs:match(pattern)
    if value then
        return value
    end
    return nil
end

local function buildMediaPlaceholder(tag, attrs, body)
    local kind = VOID_MEDIA_PATTERN[tag] or "媒体"
    local candidates = {
        getAttr(attrs, "alt"),
        getAttr(attrs, "title"),
        getAttr(attrs, "aria-label"),
        body,
    }
    local text
    for i = 1, #candidates do
        local candidate = stripTags(candidates[i])
        if isMeaningfulPlaceholderText(candidate) then
            text = candidate
            break
        end
    end
    if text and text ~= "" then
        return string.format('<p class="media-placeholder">[%s：%s]</p>', kind, escapeHtml(text))
    end
    return string.format('<p class="media-placeholder">[%s]</p>', kind)
end

local function dropBlocks(html)
    for tag in pairs(DROP_BLOCK_TAGS) do
        html = html:gsub("<" .. tag .. "[^>]*>.-</" .. tag .. "%s*>", "")
        html = html:gsub("<" .. tag .. "[^>]*/%s*>", "")
    end
    return html
end

local function replaceMedia(html)
    html = html:gsub("<img([^>]*)/?>", function(attrs)
        return buildMediaPlaceholder("img", attrs, nil)
    end)
    for tag in pairs(VOID_MEDIA_PATTERN) do
        if tag ~= "img" then
            html = html:gsub("<" .. tag .. "([^>]*)>(.-)</" .. tag .. "%s*>", function(attrs, body)
                return buildMediaPlaceholder(tag, attrs, body)
            end)
            html = html:gsub("<" .. tag .. "([^>]*)/?>", function(attrs)
                return buildMediaPlaceholder(tag, attrs, nil)
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
    -- Avoid nesting placeholders like "[图片：[图片]]" when alt/title text is itself a placeholder.
    sanitized = sanitized:gsub("(%[图片：)%s*%[图片%]%s*(%])", "[图片]")
    sanitized = sanitized:gsub("(%[视频：)%s*%[视频%]%s*(%])", "[视频]")
    sanitized = sanitized:gsub("(%[音频：)%s*%[音频%]%s*(%])", "[音频]")
    sanitized = sanitized:gsub("(%[嵌入内容：)%s*%[嵌入内容%]%s*(%])", "[嵌入内容]")
    return sanitized
end

ArticleContent.DEFAULT_CSS_TEMPLATE = [[
@page {
    margin: %dpx %dpx %dpx %dpx;
}

html, body {
    margin: 0;
    padding: 0;
}

body {
    line-height: 1.4;
}
p, blockquote, ul, ol, pre {
    margin: 0 0 0.5em 0;
}
h1, h2, h3, h4, h5, h6 {
    margin: 0.6em 0 0.25em 0;
    font-weight: bold;
}
h1 { font-size: 1.55em; }
h2 { font-size: 1.35em; }
h3 { font-size: 1.2em; }
h4, h5, h6 { font-size: 1.05em; }
blockquote {
    margin-left: 0.7em;
    padding-left: 0.45em;
}
ul, ol {
    margin-left: 0.1em;
    padding-left: 1em;
}
li {
    margin: 0.08em 0;
}
pre, code {
    white-space: pre-wrap;
    font-family: monospace;
}
pre {
    padding: 0.3em 0.45em;
}
hr {
    margin: 0.55em 0;
}
.media-placeholder {
    margin: 0.35em 0;
    font-style: italic;
}
]]

function ArticleContent.getDefaultCss()
    return string.format(
        ArticleContent.DEFAULT_CSS_TEMPLATE,
        DEFAULT_PAGE_MARGIN_VERTICAL,
        DEFAULT_PAGE_MARGIN_HORIZONTAL,
        DEFAULT_PAGE_MARGIN_VERTICAL,
        DEFAULT_PAGE_MARGIN_HORIZONTAL
    )
end

ArticleContent.DEFAULT_CSS = ArticleContent.getDefaultCss()

return ArticleContent
