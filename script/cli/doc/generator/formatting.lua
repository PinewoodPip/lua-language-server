local Utils = require("cli.doc.utils")

local Formatting = {}

---@param str string
---@return string
function Formatting.Bold(str)
    return "<b>" .. str .. "</b>"
end

---@param str string
---@return string
function Formatting.Italics(str)
    return "<i>" .. str .. "</i>"
end

---@param str string
---@param color string In hex.
---@return string
function Formatting.Color(str, color)
    return string.format("<span style=\"color:#%s;\">", color) .. str .. "</span>"
end

---@param str string
---@return string
function Formatting.Code(str)
    return "<code>" .. str .. "</code>"
end

---@param str any
---@param style table<string, string>
---@return string
function Formatting.Paragraph(str, style)
    local parsedStyle = {}
    for k,v in pairs(style) do
        table.insert(parsedStyle, string.format("%s:%s", k, v))
    end
    return string.format("<p style=\"%s;\">", Utils.JoinStrings(parsedStyle, ";")) .. str .. "</p>"
end

---@param msgType "Info"|"Warning"|"Error"
---@param header string
---@param body string?
---@return string
function Formatting.Message(msgType, header, body)
    local msg = string.format("!!! %s \"%s\"", msgType, header)
    if body then
        msg = msg .. "\n    " .. body
    end
    return msg
end

return Formatting