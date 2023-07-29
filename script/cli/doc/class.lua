local Utils = require("cli.doc.utils")
local Symbol = require("cli.doc.symbol")

---@class Class.Field
---@field Name string
---@field Type string
---@field Comment string
---@field Visibility parser.visibleType

---@class Class : Symbol
---@field Name string
---@field Comments string[]
---@field PackagePath string[]
---@field Symbols Symbol[]
---@field SymbolsByType table<SymbolType, Symbol[]>
---@field ExplicitFields Class.Field[]
---@field Extends string[]
local Class = {
    PACKAGE_PATH_PATTERN = "([^_%.]+)",
}
Utils.Inherit(Class, Symbol)

---@param name string
---@return Class
function Class.Create(name)
    ---@type Class
    local instance = {
        Type = "Class",
        Name = name,
        Comments = {},
        Symbols = {},
        SymbolsByType = {},
        PackagePath = {},
        ExplicitFields = {},
        Extends = {},
    }
    Utils.Inherit(instance, Class)

    instance:_InitializePackagePath()

    instance.SourceClass = instance:GetRootPackage() -- TODO change to second last?

    return instance
end

---@param symbol Symbol
function Class:AddSymbol(symbol)
    table.insert(self.Symbols, symbol)

    self.SymbolsByType[symbol.Type] = self.SymbolsByType[symbol.Type] or {}
    table.insert(self.SymbolsByType[symbol.Type], symbol)
end

---@param field Class.Field
function Class:AddField(field)
    table.insert(self.ExplicitFields, field)
end

---@param comment string
function Class:AddComment(comment)
    table.insert(self.Comments, comment)
end

---Adds an extension to the class (inheritance).
---@param extendName string
function Class:AddExtend(extendName)
    if not Utils.ContainsValue(self.Extends, extendName) then
        table.insert(self.Extends, extendName)
    end
end

---Returns the classes's symbols, optionally filtered by type.
---@param symbolType SymbolType?
---@return Symbol[]
function Class:GetSymbols(symbolType)
    return symbolType == nil and self.Symbols or (self.SymbolsByType[symbolType] or {})
end

---@return string
function Class:GetRootPackage()
    return self.PackagePath[1]
end

---@param packageDivider string
function Class:GetPackage(packageDivider)
    return Utils.JoinStrings(Utils.TableSub(self.PackagePath, #self.PackagePath-1), packageDivider)
end

function Class:_InitializePackagePath()
    for match in self.Name:gmatch(Class.PACKAGE_PATH_PATTERN) do
        table.insert(self.PackagePath, match)
    end
end

return Class