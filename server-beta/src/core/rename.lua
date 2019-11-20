local files    = require 'files'
local searcher = require 'searcher'
local guide    = require 'parser.guide'
local proto    = require 'proto'
local define   = require 'proto.define'

local Forcing

local function askForcing(str)
    if TEST then
        return true
    end
    if Forcing == false then
        return false
    end
    local version = files.globalVersion
    -- TODO
    local item = proto.awaitRequest('window/showMessageRequest', {
        type    = define.MessageType.Warning,
        message = '不是有效的标识符，是否强制替换？',
        actions = {
            {
                title = '强制替换',
            },
            {
                title = '取消',
            },
        }
    })
    if version ~= files.globalVersion then
        Forcing = false
        proto.notify('window/showMessage', {
            type    = define.MessageType.Warning,
            message = '文件发生了变化，替换取消。'
        })
        return false
    end
    if not item then
        Forcing = false
        return false
    end
    if item.title == '强制替换' then
        Forcing = true
        return true
    else
        Forcing = false
        return false
    end
end

local function askForMultiChange(results)
    if TEST then
        return true
    end
    local uris = {}
    for _, result in ipairs(results) do
        local uri = result.uri
        if not uris[uri] then
            uris[uri] = 0
            uris[#uris+1] = uri
        end
        uris[uri] = uris[uri] + 1
    end
    if #uris <= 1 then
        return true
    end

    local fileList = {}
    for _, uri in ipairs(uris) do
        fileList[#fileList+1] = ('%s (%d)'):format(uri, uris[uri])
    end

    local version = files.globalVersion
    -- TODO
    local item = proto.awaitRequest('window/showMessageRequest', {
        type    = define.MessageType.Warning,
        message = ('将修改以下 %d 个文件，共 %d 处。\r\n%s'):format(
            #uris,
            #results,
            table.concat(fileList, '\r\n')
        ),
        actions = {
            {
                title = '继续',
            },
            {
                title = '放弃',
            },
        }
    })
    if version ~= files.globalVersion then
        proto.notify('window/showMessage', {
            type    = define.MessageType.Warning,
            message = '文件发生了变化，替换取消。'
        })
        return false
    end
    if item and item.title == '继续' then
        return true
    end
    return false
end

local function isValidName(str)
    return str:match '^[%a_][%w_]*$'
end

local function ofLocal(source, newname, callback)
    if not isValidName(newname) and not askForcing(newname) then
        return false
    end
    callback(source, source.start, source.finish, newname)
    if source.ref then
        for _, ref in ipairs(source.ref) do
            callback(ref, ref.start, ref.finish, newname)
        end
    end
end

local esc = {
    ["'"]  = [[\']],
    ['"']  = [[\"]],
    ['\r'] = [[\r]],
    ['\n'] = [[\n]],
}

local function toString(quo, newstr)
    if quo == "'" then
        return quo .. newstr:gsub([=[['\r\n]]=], esc) .. quo
    elseif quo == '"' then
        return quo .. newstr:gsub([=[["\r\n]]=], esc) .. quo
    else
        if newstr:find([[\r]], 1, true) then
            return toString('"', newstr)
        end
        local eqnum = #quo - 2
        local fsymb = ']' .. ('='):rep(eqnum) .. ']'
        if not newstr:find(fsymb, 1, true) then
            return quo .. newstr .. fsymb
        end
        for i = 0, 100 do
            local fsymb = ']' .. ('='):rep(i) .. ']'
            if not newstr:find(fsymb, 1, true) then
                local ssymb = '[' .. ('='):rep(i) .. '['
                return ssymb .. newstr .. fsymb
            end
        end
        return toString('"', newstr)
    end
end

local function renameField(source, newname, callback)
    if isValidName(newname) then
        callback(source, source.start, source.finish, newname)
        return true
    end
    local parent = source.parent
    if parent.type == 'setfield'
    or parent.type == 'getfield' then
        local dot = parent.dot
        local newstr = '[' .. toString('"', newname) .. ']'
        callback(source, dot.start, source.finish, newstr)
    elseif parent.type == 'tablefield' then
        local newstr = '[' .. toString('"', newname) .. ']'
        callback(source, source.start, source.finish, newstr)
    elseif parent.type == 'getmethod' then
        if not askForcing(newname) then
            return false
        end
        callback(source, source.start, source.finish, newname)
    elseif parent.type == 'setmethod' then
        local uri = guide.getRoot(source).uri
        local text = files.getText(uri)
        local func = parent.value
        -- function mt:name () end --> mt['newname'] = function (self) end
        local newstr = string.format('%s[%s] = function '
            , text:sub(parent.start, parent.node.finish)
            , toString('"', newname)
        )
        callback(source, func.start, parent.finish, newstr)
        local pl = text:find('(', parent.finish, true)
        if pl then
            if func.args then
                callback(source, pl + 1, pl, 'self, ')
            else
                callback(source, pl + 1, pl, 'self')
            end
        end
    end
    return true
end

local function renameGlobal(source, newname, callback)
    if isValidName(newname) then
        callback(source, source.start, source.finish, newname)
        return true
    end
    local newstr = '_ENV[' .. toString('"', newname) .. ']'
    -- function name () end --> _ENV['newname'] = function () end
    if source.value and source.value.type == 'function'
    and source.value.start < source.start then
        callback(source, source.value.start, source.finish, newstr .. ' = function ')
        return true
    end
    callback(source, source.start, source.finish, newstr)
    return true
end

local function ofField(source, newname, callback)
    return searcher.eachRef(source, function (info)
        local src = info.source
        if     src.type == 'tablefield'
        or     src.type == 'getfield'
        or     src.type == 'setfield' then
            src = src.field
        elseif src.type == 'tableindex'
        or     src.type == 'getindex'
        or     src.type == 'setindex' then
            src = src.index
        elseif src.type == 'getmethod'
        or     src.type == 'setmethod' then
            src = src.method
        end
        if src.type == 'string' then
            local quo = src[2]
            local text = toString(quo, newname)
            callback(src, src.start, src.finish, text)
            return
        elseif src.type == 'field'
        or     src.type == 'method' then
            local suc = renameField(src, newname, callback)
            if not suc then
                return false
            end
        elseif src.type == 'setglobal'
        or     src.type == 'getglobal' then
            local suc = renameGlobal(src, newname, callback)
            if not suc then
                return false
            end
        end
    end)
end

local function rename(source, newname, callback)
    if source.type == 'label'
    or source.type == 'goto' then
        if not isValidName(newname) and not askForcing(newname)then
            return false
        end
        searcher.eachRef(source, function (info)
            callback(info.source, info.source.start, info.source.finish, newname)
        end)
    elseif source.type == 'local' then
        return ofLocal(source, newname, callback)
    elseif source.type == 'setlocal'
    or     source.type == 'getlocal' then
        return ofLocal(source.node, newname, callback)
    elseif source.type == 'field'
    or     source.type == 'method'
    or     source.type == 'tablefield'
    or     source.type == 'string'
    or     source.type == 'setglobal'
    or     source.type == 'getglobal' then
        return ofField(source, newname, callback)
    end
    return true
end

local function prepareRename(source)
    if source.type == 'label'
    or source.type == 'goto'
    or source.type == 'local'
    or source.type == 'setlocal'
    or source.type == 'getlocal'
    or source.type == 'field'
    or source.type == 'method'
    or source.type == 'tablefield'
    or source.type == 'setglobal'
    or source.type == 'getglobal' then
        return source, source[1]
    elseif source.type == 'string' then
        local parent = source.parent
        if not parent then
            return nil
        end
        if parent.type == 'setindex'
        or parent.type == 'getindex'
        or parent.type == 'tableindex' then
            return source, source[1]
        end
        return nil
    end
    return nil
end

local m = {}

function m.rename(uri, pos, newname)
    local ast = files.getAst(uri)
    if not ast then
        return nil
    end
    local results = {}

    guide.eachSourceContain(ast.ast, pos, function(source)
        rename(source, newname, function (target, start, finish, text)
            results[#results+1] = {
                start  = start,
                finish = finish,
                text   = text,
                uri    = guide.getRoot(target).uri,
            }
        end)
    end)

    if Forcing == false then
        Forcing = nil
        return nil
    end

    if #results == 0 then
        return nil
    end

    if not askForMultiChange(results) then
        return nil
    end

    return results
end

function m.prepareRename(uri, pos)
    local ast = files.getAst(uri)
    if not ast then
        return nil
    end

    local result
    guide.eachSourceContain(ast.ast, pos, function(source)
        local res, text = prepareRename(source)
        if res then
            result = {
                start  = source.start,
                finish = source.finish,
                text   = text,
            }
        end
    end)

    return result
end

return m
