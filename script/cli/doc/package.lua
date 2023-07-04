local Inherit = require("cli.doc.utils").Inherit

---@class Package
---@field Name string
---@field Classes string[]
local Package = {}

---@param name string
---@return Package
function Package.Create(name)
    ---@type Package
    local instance = {
        Name = name,
        Classes = {},
    }
    Inherit(instance, Package)

    return instance
end

---@param class Class
function Package:AddClass(class)
    table.insert(self.Classes, class.Name)
end

return Package