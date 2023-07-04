local Inherit = require("cli.doc.utils").Inherit

---@class Symbol
---@field Type SymbolType
---@field SourceClass string
local Symbol = {}

---@param data Symbol
---@return Symbol
function Symbol.Create(data)
    Inherit(data, Symbol)
    return data
end

return Symbol