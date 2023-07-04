local Inherit = require("cli.doc.utils").Inherit
local Symbol = require("cli.doc.symbol")
local Class = require("cli.doc.class")

---@class Alias : Symbol
---@field Name string
---@field AliasedTypes string[]
---@field PackagePath string[]
local Alias = {}
Inherit(Alias, Symbol)

---@param name string
---@param aliasedTypes string[]
---@return Alias
function Alias.Create(name, aliasedTypes)
    ---@type Alias
    local instance = {
        Type = "Alias",
        Name = name,
        AliasedTypes = {},
        PackagePath = {},
    }
    Inherit(instance, Alias)

    Class._InitializePackagePath(instance) -- TODO improve
    instance.SourceClass = Class.GetRootPackage(instance)

    for _,aliasedType in ipairs(aliasedTypes) do
        instance:AddType(aliasedType)
    end

    return instance
end

---@param typeName string
function Alias:AddType(typeName)
    table.insert(self.AliasedTypes, typeName)
end

---@return boolean
function Alias:IsGlobal()
    return #self.PackagePath == 1
end

return Alias