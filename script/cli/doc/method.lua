local Inherit = require("cli.doc.utils").Inherit
local Symbol = require("cli.doc.symbol")

---@class Method.Descriptor
---@field Name string
---@field SourceClass string
---@field Comments string[]
---@field Parameters Method.Parameter[]
---@field Returns Method.Return[]
---@field Static boolean
---@field Context ScriptContext
---@field Visibility parser.visibleType

---@class Method.Parameter
---@field Name string
---@field Type string
---@field Comment string?

---@class Method.Return
---@field Types string
---@field Comment string?

---@class Method : Symbol, Method.Descriptor
local Method = {}
Inherit(Method, Symbol)

---@param descriptor Method.Descriptor
---@return Method
function Method.Create(descriptor)
    ---@type Alias
    local instance = {
        Type = "Method",
    }
    Inherit(instance, Method)

    for k,v in pairs(descriptor) do
        instance[k] = v
    end

    return instance
end

return Method