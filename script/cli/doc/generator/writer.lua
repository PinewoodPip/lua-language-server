local Utils = require("cli.doc.utils")

---@class DocGenerator.Writer
---@field Lines string[]
local Writer = {}

---@return DocGenerator.Writer
function Writer.Create()
    ---@type DocGenerator.Writer
    local instance = {
        Lines = {},
    }
    Utils.Inherit(instance, Writer)
    return instance
end

---@param line string
function Writer:AddLine(line)
    table.insert(self.Lines, line)
end

function Writer:AddMultilineCode(str)
    self:AddLine("```lua\n" .. str .. "\n```")
end

---@param otherWriter DocGenerator.Writer
function Writer:Merge(otherWriter)
    for _,line in ipairs(otherWriter.Lines) do
        self:AddLine(line)
    end
end

function Writer.__tostring(self)
    return Utils.JoinStrings(self.Lines, "\n\n") -- Single line break is ignored in markdown
end

return Writer