local fs  = require 'bee.filesystem'

local Utils = {}

function Utils.Inherit(instance, tbl)
    setmetatable(instance, {
        __index = tbl,
        __tostring = tbl.__tostring,
    })
end

---Joins two strings together.
---@param str1 string
---@param str2 string
---@param separator string? Defaults to ` `
---@overload fun(str:string[], separator:string?):string
---@return string
function Utils.JoinStrings(str1, str2, separator)
    if type(str1) == "table" then separator = str2 end
    separator = separator or " "
    local newString

    if type(str1) == "table" then
        newString = ""

        for i,str in ipairs(str1) do
            newString = newString .. str

            if i ~= #str1 then
                newString = newString .. separator
            end
        end
    else
        newString = str1 .. separator .. str2
    end

    return newString
end

---Creates a sublist table.
---@param tbl any[]
---@param len integer
---@return any[]
function Utils.TableSub(tbl, len)
    local newtbl = {}
    for i=1,len,1 do
        table.insert(newtbl, tbl[i])
    end
    return newtbl
end

---@param tbl1 any[]
---@param tbl2 any[]
---@return any[] -- New table
function Utils.TableConcat(tbl1, tbl2)
    local newtbl = {}
    for _,v in ipairs(tbl1) do
        table.insert(newtbl, v)
    end
    for _,v in ipairs(tbl2) do
        table.insert(newtbl, v)
    end
    return newtbl
end

---@generic T
---@param tbl T[]
---@param predicate fun(v:T):boolean Should return `true` for entries to be kept.
---@return T[] -- New table.
function Utils.FilterList(tbl, predicate)
    local newtbl = {}
    for _,v in ipairs(tbl) do
        if predicate(v) then
            table.insert(newtbl, v)
        end
    end
    return newtbl
end

---@param rootPath fs.path
---@return fs.path[]
function Utils.Walk(rootPath)
    local files = {} ---@type fs.path[]
    for path,_ in fs.pairs(rootPath) do
        if fs.is_directory(path) then
            files = Utils.TableConcat(files, Utils.Walk(path))
        else
            table.insert(files, path)
        end
    end
    return files
end

---@param fieldName string
---@return parser.visibleType
function Utils.GetVisibilityFromName(fieldName)
    local visibility = "public" ---@type parser.visibleType
    if fieldName:match("^__") then
        visibility = 'protected'
    elseif fieldName:match("^_") then
        visibility = 'private'
    end
    return visibility
end

---Returns whether a table contains a value.
---@param tbl table
---@param value any
function Utils.ContainsValue(tbl, value)
    for _,v in pairs(tbl) do
        if v == value then
            return true
        end
    end
    return false
end

return Utils