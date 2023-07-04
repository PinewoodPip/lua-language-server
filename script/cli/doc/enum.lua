local Utils = require("cli.doc.utils")
local Symbol = require("cli.doc.symbol")
local Class = require("cli.doc.class")

---@class Enum : Symbol
---@field Name string
---@field Tuples tuple[]
---@field PackagePath string[]
local Enum = {}
Utils.Inherit(Enum, Symbol)

---@param name string
---@param tuples tuple[]
---@return Enum
function Enum.Create(name, tuples)
    ---@type Enum
    local instance = {
        Type = "Enum",
        Name = name,
        Tuples = tuples,
        PackagePath = {},
    }
    Utils.Inherit(instance, Symbol)

    Class._InitializePackagePath(instance) -- TODO improve
    instance.SourceClass = Class.GetRootPackage(instance)

    return instance
end

return Enum