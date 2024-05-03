--@module = true
--tatoyoda600
local utils = require 'utils'
local json = require 'json'

---@class tatoutils
---@field qprint fun(text: string, quiet?: boolean)
---@field getSiteGovernment fun(quiet?: boolean): historical_entity|nil
---@field getCiv fun(quiet?: boolean): historical_entity|nil
---@field getWorldSite fun(quiet?: boolean): world_site|nil
---@field unpause fun()
---@field pause fun()
---@field closeConsole fun()
---@field openConsole fun()
---@field callWithoutPrint fun(parent_context: any, func: function, ...): ...
---@field openConsoleWithPrint fun(string: string)
---@field eval fun(expression: string): any
---@field rawtostring fun(val: any): string
---@field isLightUserdata fun(obj: any): boolean
---@field orderedPairs fun(t: table): `fun(table: table<K, V>, index?: K): K,V`, table
---@field clamp fun(value: number, min: number, max: number): number
---@field hasKey fun(table: table, key: string): boolean
---@field getArrayLength fun(obj: any): integer|nil
---@field prepareJSONData fun(obj: any, is_metatable?: boolean): table
---@field toJSONFile fun(data: any, filePath: string): boolean
---@field toJSON fun(data, pretty?: boolean): boolean, string
---@field metatableToString fun(obj: table): string?
---@field recoverJSONData fun(obj: any): table
---@field loadJSONFile fun(filePath: string): boolean, any
---@field loadJSON fun(json_data: string): boolean, any
---@field fileExists fun(path: string): boolean
---@field getFileName fun(directory: string, name: string, suffix: string): string
---@field createFile fun(file_name: string): file*|nil
---@field appendToFile fun(file: file*, text: string?)
---@field writeImmediate fun(file: file*, text: string?)
---@field writeLine fun(file: file*, value: any, indent_lvl?: integer, indent_text?: string)

---@param text string
---@param quiet? boolean
function qprint(text, quiet)
    if not quiet then
        print(text)
    end
end

--#region Get Data

---@param quiet? boolean
---@return historical_entity|nil
function getSiteGovernment(quiet)
    --Get current site government
    local my_site_gov = df.historical_entity.find(df.global.plotinfo.group_id)
    if not my_site_gov then
        qprint("Error finding current site government", quiet)
        return nil
    end
    return my_site_gov
end

---@param quiet? boolean
---@return historical_entity|nil
function getCiv(quiet)
    --Get current civilization
    local my_civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    if not my_civ then
        qprint("Error finding current civilization", quiet)
        return nil
    end
    return my_civ
end

---@param quiet? boolean
---@return world_site|nil
function getWorldSite(quiet)
    --Get current site
    local my_site = df.world_site.find(df.global.plotinfo.site_id)
    if not my_site then
        qprint("Error finding current site", quiet)
        return nil
    end
    return my_site
end

--#endregion

function unpause()
    dfhack.run_command("lua \"dfhack.timeout(1, 'frames', function() df.global.pause_state = false end)\"")
end

function pause()
    dfhack.run_command("fpause")
end

function closeConsole()
    dfhack.run_command("gui/launcher --minimal")
end

function openConsole()
    dfhack.run_command("gui/launcher")
end

---@param parent_context any --The script/object that contains the function
---@param func function --The function to run without prints
---@param ... any --The parameters for the function
---@return ... --The return value(s) of the function
function callWithoutPrint(parent_context, func, ...)
    --Overriding print, the parent's print, and the environment is overkill
    --  However this makes sure to cover various possible cases

    -- Save the original print functions and environment
    local old_print = print
    local old_parent_print = parent_context.print
    local old_env = _ENV

    -- Replace the print function with a dummy function
    print = function() end
    parent_context.print = function() end

    -- Create a new environment that includes the overridden print function
    _ENV = setmetatable({print = print}, {__index = _G})

    -- Call the function with the provided arguments
    local output = {func(...)}

    -- Restore the original print function and environment
    print = old_print
    parent_context.print = old_parent_print
    _ENV = old_env

    return table.unpack(output)
end

local BREAK_LINE = "\\\\\\\\n"
local APOSTROPHE = "\\\\\\\\'"
local QUOTATION_MARK = "\\\\\\\""

---@param string string
function openConsoleWithPrint(string)
    string = string.gsub(string, "\n", BREAK_LINE)
    string = string.gsub(string, "'", APOSTROPHE)
    string = string.gsub(string, "\"", QUOTATION_MARK)
    dfhack.run_command("gui/launcher \"lua \\\"print('"..string.."')\\\"\"")
end

--Taken straight from gui/gm-editor
---@param expression string
---@return any
function eval(expression)
    local f, err = load("return " .. expression, "expression", "t", utils.df_shortcut_env())
    if err or not f then
        qerror(err or ("Error evaluating expression ("..expression..")"))
        return nil
    end
    return f()
end

local original_tostring = tostring
---@param val any
---@return string
function rawtostring(val)
    local mt = getmetatable(val)
    local __tostring = mt and mt.__tostring
    if __tostring then mt.__tostring = nil end
    local str = original_tostring(val)
    if __tostring then mt.__tostring = __tostring end
    return str
end

---@param obj any
---@return boolean
function isLightUserdata(obj)
    if type(obj) == "userdata" then
        --Check if light usertable (C pointer thing), which can't be read
        local succ, value_next, table = pcall(pairs, obj)
        return not succ or not pcall(value_next, table)
    end
    return false
end

---@generic K, V
---@param t table
---@return fun(table: table<K, V>, index?: K): K, V
---@return table
function orderedPairs(t)
    return function (t, k)
        local order = getmetatable(t).__key_order
        if k then
            for i,j in pairs(order) do
                if j == k then
                    k = i
                    break
                end
            end
        end
        _,k = next(order, k)
        return k, t[k]
    end, t
end

---@param obj any
---@return integer|nil
function getArrayLength(obj)
    if (type(obj) =="table" or type(obj) == "userdata") and not isLightUserdata(obj) then
        --Check if it's an array
        local value_next, table = pairs(obj)
        local first = value_next(table)
        if tonumber(first) then
            local counter = first
            for k,_ in value_next, table do
                if k == counter then
                    counter = counter + 1
                else
                    break
                end
            end
            if #table == counter then
                return #table
            end
        end
    end
    return nil
end

---@param value number
---@param min number
---@param max number
---@return number
function clamp(value, min, max)
    return math.max(math.min(value, max), min)
end

---@param table table
---@param key string
---@return boolean
function hasKey(table, key)
    return table._type._fields[key] ~= nil
end

--#region Files

---@param path string
---@return boolean
function fileExists(path)
    --Check if able to open a file with that name 
    local f = io.open(path, "r")
    return f ~= nil and select(1, io.close(f))
end

---@param directory string
---@param name string
---@param suffix string
---@return string
function getFileName(directory, name, suffix)
    local file_name_base = directory.."\\"..name
    local counter = 1

    --Add a number to the end of the file name
    local file_name = file_name_base.."-"..counter

    --Increase the number until reaching a name that doesn't exist yet
    while fileExists(file_name..suffix) do
        counter = counter + 1
        file_name = file_name_base.."-"..counter
    end

    return file_name
end

---@param file_name string
---@return file*|nil
function createFile(file_name)
    --Create the file
    local file = assert(io.open(file_name, "w"), "Unable to create file")

    --Close it and reopen it in append mode
    file:close()
    return io.open(file_name, "a")
end

---@param file file*
---@param text string?
function appendToFile(file, text)
    --Write the text to the file
    file:write(text or "nil")
end

---@param file file*
---@param text string?
function writeImmediate(file, text)
    appendToFile(file, text)
    file:flush()
end

local INDENT = "    "
---@param file file*
---@param value any
---@param indent_lvl? integer
---@param indent_text? string
function writeLine(file, value, indent_lvl, indent_text)
    --Adds the specified amount of indent
    local indent = ""
    for _=1,(indent_lvl or 0) do
        indent = indent..(indent_text or INDENT)
    end

    --Adds a new line to the file, with the specified indent and value
    appendToFile(file, "\n"..indent..tostring(value))
end

--#endregion

--#region JSON

---@param obj any
---@param is_metatable? boolean
---@return table
function prepareJSONData(obj, is_metatable)
    --If the object is not savable
    if type(obj) == "function" or isLightUserdata(obj) then
        obj = tostring(obj)

    --If the object is a container
    elseif type(obj) == "table" or type(obj) == "userdata" then
        --Since userdata can't be processed by the JSON encoding function, convert it into a table
        local output = { _json__metatable = { __key_order = {} } }

        --If this is not a metatable
        if not is_metatable then
            --Store the metatables of all its children first
            for k,v in pairs(obj) do
                output[k] = prepareJSONData(v, is_metatable)
                table.insert(output._json__metatable.__key_order, k)
            end

            --If it has a metatable
            local meta = getmetatable(obj)
            if meta then
                --Store the metatable
                local success, new_meta = pcall(prepareJSONData, meta, true)
                output._json__metatable = success and new_meta or meta

                --Save the result of the tostring, in order to save overrides, since functions can't be saved
                output._json__metatable._json__tostring = tostring(obj)

                --Remove the metatable's functions, since they can't be saved anyways
                for k,v in pairs(output._json__metatable) do
                    if type(v) == "function" then
                        output._json__metatable[k] = nil
                    end
                end
            end

        --If this is a metatable
        else
            --Store this metatable's children as primitive types to prevent going too deep
            --  Exception: __key_order is saved as a table always, since it shouldn't ever go deeper
            for k,v in pairs(obj) do
                if type(v) == "boolean" or type(v) == "number" or type(v) == "string" then
                    output[k] = v
                elseif k == "__key_order" then
                    output[k] = v
                else
                    output[k] = tostring(v)
                end
                table.insert(output._json__metatable.__key_order, k)
            end

            --If it has a metatable
            local meta = getmetatable(obj)
            if meta then
                --Store this metatable's metatable as primitive types to prevent going too deep
                for k,v in pairs(meta) do
                    if type(v) == "boolean" or type(v) == "number" or type(v) == "string" then
                        output._json__metatable[k] = v
                    else
                        output._json__metatable[k] = tostring(v)
                    end
                end

                output._json__metatable.__pairs = nil

                if meta.__tostring then
                    --Remove the metatable's tostring override, since functions can't be saved anyways
                    output._json__metatable._json__tostring = tostring(obj)
                    output._json__metatable.__tostring = nil
                end
            end
        end

        return output
    end

    return obj
end

---@param data any
---@param filePath string
---@return boolean success
function toJSONFile(data, filePath)
    return safecall(json.encode_file, prepareJSONData(data), filePath)
end

---@param data any
---@param pretty? boolean
---@return boolean success
---@return string json_data
function toJSON(data, pretty)
    return safecall(json.encode, prepareJSONData(data), { pretty = (pretty == nil) or pretty })
end

---@param obj table
---@return string?
function metatableToString(obj)
    return getmetatable(obj)._json__tostring
end

---@param obj any
---@return table
function recoverJSONData(obj)
    --If the object is a container
    if type(obj) == "table" or type(obj) == "userdata" then
        --If it contains a metatable entry
        local meta = obj._json__metatable
        if meta then
            --If the metatable contains a key order
            if meta.__key_order then
                --Go though every key that's supposed to be in the object
                for _,v in pairs(meta.__key_order) do
                    --If the key isn't in the object
                    if obj[v] == nil then
                        --Change the object's key from the string version to the version stored in the key order
                        --  JSON converts all keys to strings, so this is necessary to preserve non-string keys
                        obj[v] = obj[tostring(v)]
                        obj[tostring(v)] = nil
                    end
                end

                --Make it so that pairs(obj) follows the key order
                meta.__pairs = orderedPairs
            end

            --If the original object had a tostring function, restore the result of the tostring
            --  The function itself can't be stored, so this object's tostring will not be correct if values change
            if meta._json__tostring then
                meta.__tostring = metatableToString
            end

            --Apply the metatable, then remove the entry
            setmetatable(obj, meta)
            obj._json__metatable = nil
        end

        --Reapply the metatable of all its children also
        for k,v in pairs(obj) do
            obj[k] = recoverJSONData(v)
        end
    end

    return obj
end

---@param filePath string
---@return boolean success
---@return any result
function loadJSONFile(filePath)
    local success, obj = safecall(json.decode_file, filePath)
    return success, recoverJSONData(obj)
end

---@param json_data string
---@return boolean success
---@return any result
function loadJSON(json_data)
    local success, obj = safecall(json.decode, json_data)
    return success, recoverJSONData(obj)
end

--#endregion
