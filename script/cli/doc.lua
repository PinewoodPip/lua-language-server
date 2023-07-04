local lclient  = require 'lclient'
local furi     = require 'file-uri'
local ws       = require 'workspace'
local files    = require 'files'
local util     = require 'utility'
local jsonb    = require 'json-beautify'
local lang     = require 'language'
local define   = require 'proto.define'
local config   = require 'config.config'
local await    = require 'await'
local vm       = require 'vm'
local guide    = require 'parser.guide'
local getDesc  = require 'core.hover.description'
local getLabel = require 'core.hover.label'
local doc2md   = require 'cli.doc2md'
local progress = require 'progress'
local fs       = require 'bee.filesystem'

local export = {}

---@alias SymbolType "Event"|"Hook"|"Alias"|"Class"

---@class Event : Symbol
---@field Name string
---@field EventType string
---@field Legacy boolean

---@class Hook : Event

local function Inherit(instance, tbl)
    setmetatable(instance, {
        __index = tbl,
    })
end

---------------------------------------------
-- PACKAGE
---------------------------------------------

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

---------------------------------------------
-- SYMBOL
---------------------------------------------

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

---------------------------------------------
-- CLASS
---------------------------------------------

---@class Class : Symbol
---@field Name string
---@field PackagePath string[]
---@field Symbols Symbol[]
---@field SymbolsByType table<SymbolType, Symbol[]>
local Class = {
    PACKAGE_PATH_PATTERN = "([^_%.]+)",
}
Inherit(Class, Symbol)

---@param name string
---@return Class
function Class.Create(name)
    ---@type Class
    local instance = {
        Type = "Class",
        Name = name,
        Symbols = {},
        SymbolsByType = {},
        PackagePath = {},
    }
    Inherit(instance, Class)

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

function Class:_InitializePackagePath()
    for match in self.Name:gmatch(Class.PACKAGE_PATH_PATTERN) do
        table.insert(self.PackagePath, match)
    end
end

---------------------------------------------
-- ALIAS
---------------------------------------------

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

---------------------------------------------
-- EXPORTER
---------------------------------------------

local Exporter = {
    Symbols = {}, ---@type Symbol[] Excludes Aliases and Classes
    Classes = {}, ---@type table<string, Class>
    Packages = {}, ---@type table<string, Package>
    Aliases = {}, ---@type table<string, Alias>
}

---Adds a symbol.
---@param symbol Symbol
function Exporter.AddSymbol(symbol)
    table.insert(Exporter.Symbols, symbol)
end

---Adds a class.
---Does nothing if the class was already added.
---@param name string
function Exporter.AddClass(name)
    if not Exporter.Classes[name] then
        local class = Class.Create(name)
        local rootPackage = class.PackagePath[1]

        Exporter.Packages[rootPackage] = Package.Create(rootPackage) -- Also register package
        Exporter.Classes[class.Name] = class
    end
end

---@param name string
---@param aliasedTypes string[]
function Exporter.AddAlias(name, aliasedTypes)
    local alias = Alias.Create(name, aliasedTypes)
    local existingAlias = Exporter.Aliases[name]

    -- Merge aliases if there are multiple under the same name
    if existingAlias then
        for _,aliasedType in ipairs(alias.AliasedTypes) do
            existingAlias:AddType(aliasedType)
        end
    else
        Exporter.Aliases[name] = alias
    end
end

---Links classes with their symbols, and packages with their subclasses
function Exporter._Link()
    for _,symbol in ipairs(Exporter.Symbols) do
        local class = Exporter.Classes[symbol.SourceClass]
        class:AddSymbol(symbol)
    end
    for _,class in pairs(Exporter.Classes) do
        local package = Exporter.Packages[class:GetRootPackage()]
        package:AddClass(class)
    end
    for _,alias in pairs(Exporter.Aliases) do
        if not alias:IsGlobal() then
            local class = Exporter.Classes[alias.SourceClass]
            if class then -- TODO
                class:AddSymbol(alias)
            end
        end
    end
end

---@param filePath string
function Exporter.Export(filePath)
    local output = {
        Packages = {}, ---@type table<string, Package>
        Classes = {}, ---@type table<string, Class>
        GlobalAliases = {}, ---@type table<string, Alias>
    }
    Exporter._Link()

    output.Packages = Exporter.Packages
    output.Classes = Exporter.Classes

    for _,alias in pairs(Exporter.Aliases) do
        if alias:IsGlobal() then
            output.GlobalAliases[alias.Name] = alias
        end
    end

    util.saveFile(filePath, jsonb.beautify(output))
end

---------------------------------------------

---@async
local function packObject(source, mark)
    if type(source) ~= 'table' then
        return source
    end
    if not mark then
        mark = {}
    end
    if mark[source] then
        return
    end
    mark[source] = true
    local new = {}
    if (#source > 0 and next(source, #source) == nil)
    or source.type == 'funcargs' then
        new = {}
        for i = 1, #source do
            new[i] = packObject(source[i], mark)
        end
    else
        for k, v in pairs(source) do
            if k == 'type'
            or k == 'name'
            or k == 'start'
            or k == 'finish'
            or k == 'types' then
                new[k] = packObject(v, mark)
            end
        end
        if source.type == 'function' then
            new['args'] = packObject(source.args, mark)
            local _, _, max = vm.countReturnsOfFunction(source)
            if max > 0 then
                new.returns = {}
                for i = 1, max do
                    local rtn = vm.getReturnOfFunction(source, i)
                    new.returns[i] = packObject(rtn)
                end
            end
            new['view'] = getLabel(source, source.parent.type == 'setmethod')
        end
        if source.type == 'local'
        or source.type == 'self' then
            new['name'] = source[1]
        end
        if source.type == 'function.return' then
            new['desc'] = source.comment and getDesc(source.comment)
        end
        if source.type == 'doc.type.table' then
            new['fields'] = packObject(source.fields, mark)
        end
        if source.type == 'doc.field.name'
        or source.type == 'doc.type.arg.name' then
            new['[1]'] = packObject(source[1], mark)
            new['view'] = source[1]
        end
        if source.type == 'doc.type.function' then
            new['args'] = packObject(source.args, mark)
            if source.returns then
                new['returns'] = packObject(source.returns, mark)
            end
        end
        if source.bindDocs then
            new['desc'] = getDesc(source)
        end
        new['view'] = new['view'] or vm.getInfer(source):view(ws.rootUri)
    end
    return new
end

---@async
local function getExtends(source)
    if source.type == 'doc.class' then
        if not source.extends then
            return nil
        end
        return packObject(source.extends)
    end
    if source.type == 'doc.alias' then
        if not source.extends then
            return nil
        end
        return packObject(source.extends)
    end
end

---@async
---@param global vm.global
---@param results table
local function collectTypes(global, results)
    if guide.isBasicType(global.name) then -- Ignore built-in types
        return
    end
    local result = {
        name    = global.name,
        type    = 'type',
        desc    = nil,
        defines = {},
        fields  = {},
    }
    for _, set in ipairs(global:getSets(ws.rootUri)) do -- For each assignment of the global?
        local uri = guide.getUri(set)
        if files.isLibrary(uri) then -- Ignore built-in libraries?
            goto CONTINUE
        end
        result.defines[#result.defines+1] = {
            type    = set.type,
            file    = guide.getUri(set), -- File of the symbol
            start   = set.start, -- Position within file, in characters?
            finish  = set.finish,
            extends = getExtends(set),
        }
        result.desc = result.desc or getDesc(set)

        -- Register aliases
        if set.type == "doc.alias" then
            local aliasName = set.alias[1]
            local types = {
                set._typeCache["doc.type.string"] or {},
                set._typeCache["doc.type.name"] or {},
            }
            local aliasedTypes = {}

            for _,typeSet in ipairs(types) do
                for _,type in ipairs(typeSet) do
                    table.insert(aliasedTypes, type[1])
                end
            end

            Exporter.AddAlias(aliasName, aliasedTypes)
        end

        ::CONTINUE::
    end
    if #result.defines == 0 then
        return
    end
    table.sort(result.defines, function (a, b)
        if a.file ~= b.file then
            return a.file < b.file
        end
        return a.start < b.start
    end)
    results[#results+1] = result

    -- Register class
    if global.cate == "type" then
        Exporter.AddClass(global.name)
    end

    ---@async
    ---@diagnostic disable-next-line: not-yieldable
    vm.getClassFields(ws.rootUri, global, vm.ANY, function (source)
        if source.type == 'doc.field' then
            ---@cast source parser.object
            if files.isLibrary(guide.getUri(source)) then
                return
            end
            local field = {}
            result.fields[#result.fields+1] = field
            if source.field.type == 'doc.field.name' then
                field.name = source.field[1]
            else
                field.name = ('[%s]'):format(vm.getInfer(source.field):view(ws.rootUri))
            end
            field.type    = source.type
            field.file    = guide.getUri(source)
            field.start   = source.start
            field.finish  = source.finish
            field.desc    = getDesc(source)
            field.extends = packObject(source.extends)
            return
        end
        if source.type == 'setfield'
        or source.type == 'setmethod' then
            ---@cast source parser.object
            if files.isLibrary(guide.getUri(source)) then
                return
            end
            local field = {}
            result.fields[#result.fields+1] = field
            field.name    = (source.field or source.method)[1]
            field.type    = source.type
            field.file    = guide.getUri(source)
            field.start   = source.start
            field.finish  = source.finish
            field.desc    = getDesc(source)
            field.extends = packObject(source.value)
            return
        end
        if source.type == 'tableindex' then
            ---@cast source parser.object
            if source.index.type ~= 'string' then -- Only consider assignments via string key
                return
            end
            if files.isLibrary(guide.getUri(source)) then
                return
            end
            local field = {}
            result.fields[#result.fields+1] = field
            field.name    = source.index[1]
            field.type    = source.type
            field.file    = guide.getUri(source)
            field.start   = source.start
            field.finish  = source.finish
            field.desc    = getDesc(source)
            field.extends = packObject(source.value)
            return
        end
        if source.type == "tablefield" then
            ---@cast source parser.object
            local fieldName = source.field[1]

            -- Add Event and Hook symbols (currently essentially the same class)
            if fieldName == "Events" or fieldName == "Hooks" then
                local sourceClassName = source.parent.parent.bindDocs[1].class[1]

                for _,event in ipairs(source.value) do
                    local eventDoc = event.bindDocs[1]
                    local docTypeNames = eventDoc._typeCache["doc.type.name"]
                    local isLegacyType = #docTypeNames == 1
                    local eventType
                    if isLegacyType then
                        eventType = docTypeNames[1][1]
                    else
                        eventType = docTypeNames[2][1]
                    end

                    ---@type Event|Hook
                    local symbol = {
                        SourceClass = sourceClassName,
                        Name = event.field[1], -- Field assignment
                        EventType = eventType,
                        Type = fieldName:sub(1, #fieldName - 1)
                    }
                    Exporter.AddSymbol(Symbol.Create(symbol))
                end
            end
            return
        end
    end)
    table.sort(result.fields, function (a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        if a.file ~= b.file then
            return a.file < b.file
        end
        return a.start < b.start
    end)
end

---@async
---@param global vm.global
---@param results table
local function collectVars(global, results)
    local result = {
        name    = global:getCodeName(),
        type    = 'variable',
        desc    = nil,
        defines = {},
    }
    for _, set in ipairs(global:getSets(ws.rootUri)) do
        if set.type == 'setglobal'
        or set.type == 'setfield'
        or set.type == 'setmethod'
        or set.type == 'setindex' then
            result.defines[#result.defines+1] = {
                type    = set.type,
                file    = guide.getUri(set),
                start   = set.start,
                finish  = set.finish,
                extends = packObject(set.value),
            }
            result.desc = result.desc or getDesc(set)
        end
    end
    if #result.defines == 0 then
        return
    end
    table.sort(result.defines, function (a, b)
        if a.file ~= b.file then
            return a.file < b.file
        end
        return a.start < b.start
    end)
    results[#results+1] = result
end

---@async
---@param callback fun(i, max)
function export.export(outputPath, callback)
    local results = {}
    local globals = vm.getAllGlobals()

    local max = 0
    for _ in pairs(globals) do
        max = max + 1
    end
    local i = 0
    for _, global in pairs(globals) do
        if global.cate == 'variable' then
            -- collectVars(global, results)
        elseif global.cate == 'type' then
            collectTypes(global, results)
        end
        i = i + 1
        callback(i, max)
    end

    table.sort(results, function (a, b)
        return a.name < b.name
    end)

    local docPath = outputPath .. '/doc.json'
    jsonb.supportSparseArray = true
    util.saveFile(docPath, jsonb.beautify(results))

    local mdPath = doc2md.buildMD(outputPath)

    outputPath = outputPath .. "/output.json"
    Exporter.Export(outputPath)

    return docPath, mdPath
end

---@async
---@param outputPath string
function export.makeDoc(outputPath)
    ws.awaitReady(ws.rootUri)

    local expandAlias = config.get(ws.rootUri, 'Lua.hover.expandAlias')
    config.set(ws.rootUri, 'Lua.hover.expandAlias', false)
    local _ <close> = function ()
        config.set(ws.rootUri, 'Lua.hover.expandAlias', expandAlias)
    end

    await.sleep(0.1)

    local prog <close> = progress.create(ws.rootUri, '正在生成文档...', 0)
    local docPath, mdPath = export.export(outputPath, function (i, max)
        prog:setMessage(('%d/%d'):format(i, max))
        prog:setPercentage((i) / max * 100)
    end)

    return docPath, mdPath
end

function export.runCLI()
    lang(LOCALE)

    if type(DOC) ~= 'string' then
        print(lang.script('CLI_CHECK_ERROR_TYPE', type(DOC)))
        return
    end

    local rootUri = furi.encode(fs.absolute(fs.path(DOC)):string())
    if not rootUri then
        print(lang.script('CLI_CHECK_ERROR_URI', DOC))
        return
    end

    print('root uri = ' .. rootUri)

    util.enableCloseFunction()

    local lastClock = os.clock()

    ---@async
    lclient():start(function (client)
        client:registerFakers()

        client:initialize {
            rootUri = rootUri,
        }

        io.write(lang.script('CLI_DOC_INITING'))

        config.set(nil, 'Lua.diagnostics.enable', false)
        config.set(nil, 'Lua.hover.expandAlias', false)

        ws.awaitReady(rootUri)
        await.sleep(0.1)

        local docPath, mdPath = export.export(LOGPATH, function (i, max)
            if os.clock() - lastClock > 0.2 then
                lastClock = os.clock()
                local output = '\x0D'
                            .. ('>'):rep(math.ceil(i / max * 20))
                            .. ('='):rep(20 - math.ceil(i / max * 20))
                            .. ' '
                            .. ('0'):rep(#tostring(max) - #tostring(i))
                            .. tostring(i) .. '/' .. tostring(max)
                io.write(output)
            end
        end)

        io.write('\x0D')

        print(lang.script('CLI_DOC_DONE'
            , ('[%s](%s)'):format(files.normalize(docPath), furi.encode(docPath))
            , ('[%s](%s)'):format(files.normalize(mdPath),  furi.encode(mdPath))
        ))
    end)
end

return export
