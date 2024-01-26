local Utils = require("cli.doc.utils")
local fs = require("bee.filesystem")
local Formatting = require("cli.doc.generator.formatting")
local Writer = require("cli.doc.generator.writer")
local Bold, Italics, Color, Code, Paragraph, Message = Formatting.Bold, Formatting.Italics, Formatting.Color, Formatting.Code, Formatting.Paragraph, Formatting.Message

---@class DocGenerator
local Docs = {
    PARAMETER_COLOR = "B04A6E",

    Exporter = nil, ---@type Exporter
}

---@param className string
---@return DocGenerator.Writer
function Docs.GetClassDocs(className, includeFields)
    local class = Docs.Exporter.Classes[className]
    local writer = Writer.Create()

    writer:AddLine(string.format("# %s Class", className))

    -- Write extends/inheritance
    if class.Extends[1] then
        writer:AddLine(string.format("Inherits from %s.", Code(Utils.JoinStrings(class.Extends, ", "))))
    end

    -- Write class comments
    for _,comment in ipairs(class.Comments) do
        writer:AddLine(comment)
    end

    if includeFields then
        writer:Merge(Docs.GetClassFieldDocs(className))
    end

    -- Write events, if any
    local events = Utils.TableConcat(class.SymbolsByType["Event"] or {}, class.SymbolsByType["Hook"] or {}) ---@type (Event|Hook)[]
    if #events > 0 then
        writer:AddLine("## Events and Hooks")
        for _,listenable in ipairs(events) do
            writer:Merge(Docs.GetEventDocs(listenable))
        end
    end

    -- Write methods
    writer:AddLine("## Methods")
    local methods = class.SymbolsByType["Method"] or {} ---@type Method[]
    table.sort(methods, function (a, b) -- Sort alphabetically by name
        return a.Name < b.Name
    end)
    for _,method in ipairs(methods) do
        if method.Visibility ~= 'private' and not method:IsDeprecated() then
            writer:Merge(Docs.GetMethodDocs(method))
        end
    end

    return writer
end

---@param className Class|string
---@param writeHeader boolean?
---@return DocGenerator.Writer
function Docs.GetClassFieldDocs(className, writeHeader)
    local writer = Writer.Create()
    local class = type(className) == "table" and className or Docs.Exporter.Classes[className]

    if writeHeader then
        writer:AddLine(string.format("# %s Class", className))
    end

    for _,field in ipairs(class.ExplicitFields) do
        Docs.WriteField(writer, field)
    end

    return writer
end

---@param event Event|Hook
---@return DocGenerator.Writer
function Docs.GetEventDocs(event)
    local writer = Writer.Create()
    local header = string.format("#### %s (%s)", event.Name, event.Type == "Event" and "event" or "hook")
    local class = Docs.Exporter.Classes[event.EventType]

    -- Write header
    writer:AddLine(header)

    -- Write comments
    if event.ShortComment then -- Takes priority over class comments; this is to remove the comment from events that use EmptyEvent.
        writer:AddLine(event.ShortComment)
    else
        for _,comment in ipairs(class.Comments) do
            writer:AddLine(comment)
        end
    end

    -- Write fields
    writer:Merge(Docs.GetClassFieldDocs(class))

    return writer
end

---@param method Method
---@return DocGenerator.Writer
function Docs.GetMethodDocs(method)
    local writer = Writer.Create()
    local header = "##### " .. method.Name
    local params = {}
    for _,param in ipairs(method.Parameters) do
        table.insert(params, param.Name)
    end
    local returns = {}
    local returnComment = ""
    for _,returnType in ipairs(method.Returns) do
        table.insert(returns, returnType.Types)
        if returnType.Comment then
            returnComment = "-- " .. returnType.Comment
        end
    end

    -- Write header
    writer:AddLine(header)

    -- Write signature
    local signatureComment = ""
    if method.Context ~= "Shared" then
        signatureComment = " -- (" .. method.Context .. "-only)"
    end
    local returnLabel = ""
    if #method.Returns > 0 then
        returnLabel = string.format("\n   -> %s%s", Utils.JoinStrings(returns, ", "), returnComment)
    end
    local signature = {}
    if method.Visibility ~= 'public' then -- Write visibility tag
        table.insert(signature, "---@" .. method.Visibility)
    end
    table.insert(signature, string.format("function %s%s%s(%s)%s%s", method.SourceClass, method.Static and "." or ":", method.Name, Utils.JoinStrings(params, ", "), signatureComment, returnLabel))
    writer:AddMultilineCode(Utils.JoinStrings(signature, "\n"))

    -- Write comments
    for _,comment in ipairs(method.Comments) do
        writer:AddLine(comment)
    end

    -- Write detailed params
    for _,param in ipairs(method.Parameters) do
        writer:AddLine(Paragraph(Utils.JoinStrings({
            Color(Bold(Italics("@param")), Docs.PARAMETER_COLOR),
            Bold(param.Name),
            Code(param.Type),
            param.Comment
        }), {["margin-bottom"] = "0px"}))
    end

    return writer
end

---@param data Exporter
function Docs.Update(data)
    Docs.Exporter = data
    local files = Utils.Walk(fs.path(DOCSOUTPUT))
    files = Utils.FilterList(files, function (v)
        return tostring(v:extension()) == ".md"
    end)

    for _,path in ipairs(files) do
        local file = io.open(tostring(path), "r")
        ---@diagnostic disable: need-check-nil
        local content = file:lines("a")()

        for docType, symbolName in content:gmatch("<doc ([^=]+)=\"([^>\"]+)\">") do
            local docs ---@type DocGenerator.Writer
            if docType == "class" then -- TODO add more tags
                docs = Docs.GetClassDocs(symbolName)
            elseif docType == "fields" then
                docs = Docs.GetClassFieldDocs(symbolName, true)
            elseif docType == "classWithFields" then -- TODO rename
                docs = Docs.GetClassDocs(symbolName, true)
            end

            content = content:gsub(
                "<doc " .. docType .. "=\"" .. symbolName .. "\">(.-)</doc>",
                "<doc " .. docType .. "=\"" .. symbolName .. "\">" .. "\n\n" .. tostring(docs) .. "\n" .. "</doc>"
            )
        end

        file:close()
        local outputFile = io.open(tostring(path), "w")
        outputFile:write(content)
        outputFile:close()
        ---@diagnostic enable: need-check-nil
    end
end

---@param writer DocGenerator.Writer
---@param field Class.Field
function Docs.WriteField(writer, field)
    writer:AddLine(Paragraph(Utils.JoinStrings({
        Color(Bold(Italics("@field")), Docs.PARAMETER_COLOR),
        Bold(field.Name),
        Code(field.Type),
        field.Comment
    }), {["margin-bottom"] = "0px"}))
end

return Docs