
local Utils = {}

function Utils.Inherit(instance, tbl)
    setmetatable(instance, {
        __index = tbl,
    })
end

---Joins two strings together.
---@param str1 string
---@param str2 string
---@param separator string? Defaults to ` `
---@overload fun(str:string[], separator:string?)
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

return Utils