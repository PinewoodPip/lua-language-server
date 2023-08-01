local lclient  = require 'lclient'
local furi     = require 'file-uri'
local ws       = require 'workspace'
local files    = require 'files'
local util     = require 'utility'
local jsonb    = require 'json-beautify'
local lang     = require 'language'
local config   = require 'config.config'
local await    = require 'await'
local vm       = require 'vm'
local guide    = require 'parser.guide'
local getDesc  = require 'core.hover.description'
local getLabel = require 'core.hover.label'
local doc2md   = require 'cli.doc2md'
local progress = require 'progress'
local fs       = require 'bee.filesystem'

local Utils = require("cli.doc.utils")
local Package = require("cli.doc.package")
local Symbol = require("cli.doc.symbol")
local Class = require("cli.doc.class")
local Alias = require("cli.doc.alias")
local Enum = require("cli.doc.enum")
local Method = require("cli.doc.method")

local docgen = require("cli.update-docs")

local export = {}

---@alias SymbolType "Event"|"Hook"|"Alias"|"Class"|"Enum"|"Method"
---@alias tuple {[1]:string, [2]:any}
---@alias ScriptContext "Shared"|"Server"|"Client"

---@class Event : Symbol
---@field Name string
---@field EventType string
---@field Legacy boolean

---@class Hook : Event

---------------------------------------------
-- EXPORTER
---------------------------------------------

---@class Exporter
local Exporter = {
    Symbols = {}, ---@type Symbol[] Excludes Aliases and Classes
    Classes = {}, ---@type table<string, Class>
    Packages = {}, ---@type table<string, Package>
    Aliases = {}, ---@type table<string, Alias>
    Enums = {}, ---@type table<string, Enum>
    _ClassFields = {}, ---@type table<string, Class.Field[]>
    _ClassComments = {}, ---@type table<string, string[]>
    _VisitedObjects = {}, ---@type table<parser.object, true>
}

---Adds a symbol.
---@param symbol Symbol
function Exporter.AddSymbol(symbol)
    table.insert(Exporter.Symbols, symbol)
end

---Adds a class.
---Does nothing if the class was already added.
---@param name string
---@return Class
function Exporter.AddClass(name)
    local class = Exporter.Classes[name]
    if not class and not Exporter.Aliases[name] then
        class = Class.Create(name)
        local usesLegacyNaming = not name:match("%.")

        Exporter.Classes[class.Name] = class

        -- Also register packages
        for i=1,#class.PackagePath-1,1 do
            local path = Utils.TableSub(class.PackagePath, i)
            path = Utils.JoinStrings(path, usesLegacyNaming and "_" or ".")

            Exporter.Packages[path] = Exporter.Packages[path] or Package.Create(path)
        end
    end
    return class
end

---@param className string
---@param field Class.Field
function Exporter.AddClassField(className, field)
    Exporter._ClassFields[className] = Exporter._ClassFields[className] or {}
    local fields = Exporter._ClassFields[className]
    table.insert(fields, field)
end

---@param className string
---@param comment string
function Exporter.AddClassComment(className, comment)
    Exporter._ClassComments[className] = Exporter._ClassComments[className] or {}
    local comments = Exporter._ClassComments[className]
    table.insert(comments, comment)
end

---Adds a class extend.
---@param className string
---@param extendName string
function Exporter.AddClassExtend(className, extendName)
    local class = Exporter.Classes[className] or Exporter.AddClass(className)
    class:AddExtend(extendName)
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

---@param name string
---@param tuples tuple[]
function Exporter.AddEnum(name, tuples)
    Exporter.Enums[name] = Enum.Create(name, tuples)
end

---@param descriptor Method.Descriptor
function Exporter.AddMethod(descriptor)
    Exporter.AddSymbol(Method.Create(descriptor))
end

---Links classes with their symbols, and packages with their subclasses
function Exporter._Link()
    for _,symbol in ipairs(Exporter.Symbols) do
        local class = Exporter.Classes[symbol.SourceClass]
        class:AddSymbol(symbol)
    end
    for _,class in pairs(Exporter.Classes) do
        local package = Exporter.Packages[class:GetPackage("_")] or Exporter.Packages[class:GetPackage(".")]

        if package then
            package:AddClass(class)
        end
    end
    for className,fields in pairs(Exporter._ClassFields) do
        local class = Exporter.Classes[className]
        for _,field in ipairs(fields) do
            class:AddField(field)
        end
    end
    for className,comments in pairs(Exporter._ClassComments) do
        local class = Exporter.Classes[className]
        for _,field in ipairs(comments) do
            class:AddComment(field)
        end
    end
    for _,alias in pairs(Exporter.Aliases) do
        if not alias:IsGlobal() then
            local class = Exporter.Classes[alias.SourceClass]
            if class then -- TODO
                class:AddSymbol(alias)
            end
        end
    end
    for _,enum in pairs(Exporter.Enums) do
        local class = Exporter.Classes[enum.SourceClass]
        if class then
            class:AddSymbol(enum)
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

    -- Remove Symbols table from classes to avoid data duplication
    -- This will remove them from the exporter too - TODO fix?
    for _,class in pairs(output.Classes) do
        class.Symbols = nil
    end

    for _,alias in pairs(Exporter.Aliases) do
        if alias:IsGlobal() then
            output.GlobalAliases[alias.Name] = alias
        end
    end

    util.saveFile(filePath, jsonb.beautify(output))
    docgen.Update(Exporter)
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

        if set.type == "doc.class" then
            local className = set.class[1]

            -- Add class comments
            for _,commentNode in ipairs(set.bindComments) do -- TODO merge lines if they start with lowercase?
                Exporter.AddClassComment(className, commentNode.comment.text:match("^-(.+)"))
            end

            -- Add extends
            for _,extend in ipairs(set.extends or {}) do
                if extend.type == "doc.extends.name" then
                    Exporter.AddClassExtend(className, extend[1])
                elseif extend.type == "doc.type.table" then
                    -- Unsupported. The types of the fields appear to be in extends.
                else
                    warn("Unsupported extend type", extend.type)
                end
            end
        elseif set.type == "doc.alias" then -- Register aliases
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
        elseif set.type == "doc.enum" then -- Register enums
            local enumValueNodes = set.bindSource
            local enumPairs = {} ---@type tuple[]
            for _,enumValue in ipairs(enumValueNodes) do
                local tuple = {
                    enumValue.field and enumValue.field[1] or enumValue.index[1],
                    enumValue.value[1],
                }
                table.insert(enumPairs, tuple)
            end
            Exporter.AddEnum(set.enum[1], enumPairs)
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
            local class = source.class.class[1]
            local fieldName
            if source.field.type == 'doc.field.name' then
                fieldName = source.field[1]
            else -- Non-string index
                fieldName = ('[%s]'):format(vm.getInfer(source.field):view(ws.rootUri))
            end

            ---@type Class.Field
            local field = {
                Name = fieldName,
                Type = source.field.parent.originalComment.text:match("-@field [^ ]+ ([^ ]+)"),
                Comment = source.field.parent.originalComment.text:match("-@field [^ ]+ [^ ]+ (.+)"),
                Visibility = Utils.GetVisibilityFromName(fieldName),
            }
            if not Exporter._VisitedObjects[source] then
                Exporter.AddClassField(class, field)
                Exporter._VisitedObjects[source] = true
            end
            return
        end
        if (source.type == "setmethod" or source.type == "setfield") and source.parent.docs and source.value.type == "function" then
            ---@cast source parser.object
            local method = source.method or source.field
            local methodName = method[1]
            local class = nil
            if source.node.type == "getglobal" then
                local globalName = source.node[1]
                for _,v in ipairs(source.parent.docs) do
                    if v.class and v.bindSource and v.bindSource[1] == globalName then
                        class = v.class[1]
                        break
                    end
                end
            else
                class = source.node.node.bindDocs[1].class[1]
            end
            if not class then return end -- TODO check if there are edgecases?
            local sourceFile = guide.getUri(source)

            local comments = {} ---@type string[]
            local params = {} ---@type Method.Parameter[]
            local returns = {} ---@type Method.Return[]
            local visibility = Utils.GetVisibilityFromName(methodName)
            local deprecationComment = nil

            -- Check for explicit visibility tags
            for _,v in ipairs(source.bindDocs or {}) do
                if v.type == "doc.private" then
                    visibility = "private"
                elseif v.type == "doc.protected" then
                    visibility = "protected"
                end -- TODO are there others?
            end

            for _,v in ipairs(source.value.bindDocs or {}) do -- bindDocs is not present for sets without any documentation
                if v.visible then
                    visibility = v.visible
                end
                if v.comment and not v.param then
                    table.insert(comments, v.comment.text:match("^-(.+)$"))
                end
                if v.param then
                    ---@type Method.Parameter
                    local paramType
                    local originalComment = v.originalComment.text
                    paramType = originalComment:match("^-@param [^ ]+ (fun%(.+%))") or originalComment:match("^-@param [^ ]+ ([^ ]+)")

                    local param = { -- TODO is it always just one node for these?
                        Name = v.param[1],
                        Type = paramType,
                        Comment = v.comment and v.comment.text, -- doc.tailcomment
                    }
                    table.insert(params, param)
                end
                if v.returns then
                    local line = v.originalComment.text
                    local types = line:match("^-@return ([^-]+)")
                    local comment = v.comment and v.comment.text
                    ---@type Method.Return
                    local returnEntry = {
                        Types = types,
                        Comment = comment,
                    }

                    table.insert(returns, returnEntry)
                end
            end
            for _,v in ipairs(source.bindDocs or {}) do
                if v.type == "doc.deprecated" then
                    deprecationComment = v.comment and v.comment.text or ""
                end
            end

            -- Check context
            local context = "Shared" ---@type ScriptContext
            if sourceFile:match("Client") then
                context = "Client"
            elseif sourceFile:match("Server") then
                context = "Server"
            end

            ---@type Method.Descriptor
            local descriptor = {
                Name = methodName,
                SourceClass = class,
                Comments = comments,
                Parameters = params,
                Returns = returns,
                Static = source.type == "setfield",
                Context = context,
                Visibility = visibility,
                DeprecationComment = deprecationComment,
            }
            if not Exporter._VisitedObjects[source] then
                Exporter._VisitedObjects[source] = true
                Exporter.AddMethod(descriptor)
            end
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
            collectVars(global, results)
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
