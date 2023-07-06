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
function Docs.GetClassDocs(className)
    local class = Docs.Exporter.Classes[className]
    local writer = Writer.Create()

    writer:AddLine(string.format("# %s Class", className))

    -- TODO write class comments?

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
        if method.Visibility ~= 'private' then
            writer:Merge(Docs.GetMethodDocs(method))
        end
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
    for _,comment in ipairs(class.Comments) do
        writer:AddLine(comment)
    end

    -- Write fields
    for _,field in ipairs(class.ExplicitFields) do
        writer:AddLine(Paragraph(Utils.JoinStrings({
            Color(Bold(Italics("@field")), Docs.PARAMETER_COLOR),
            Bold(field.Name),
            Code(field.Type),
            field.Comment
        }), {["margin-bottom"] = "0px"}))
    end

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
    writer:AddMultilineCode(string.format("function %s%s%s(%s)%s%s", method.SourceClass, method.Static and "." or ":", method.Name, Utils.JoinStrings(params, ", "), signatureComment, returnLabel))

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
            end

            content = content:gsub(
                "<doc " .. docType .. "=\"" .. symbolName .. "\">(.+)</doc>",
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

return Docs