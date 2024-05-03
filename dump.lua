--@module = true
--tatoyoda600
local help = [====[

dump
=============
Dumps the contents of an object in memory to a file. Can also load in previous dumps to compare them.
Depth of the dump can be specified (Defaults to 5). Limiting the scope of the dump is always recommended.
The object to dump is provided by the return value of provided lua code (If the code contains spaces, surround it in quotes).
All outputs are provided in a format made to be readable in gui/gm-editor.
A 'progress.txt' file is created in 'Dwarf Fortress/hack' to see the progress even if the game freezes or the console is closed.

Warnings:
- Setting a high depth on a large object may lead to multi-gigabyte dumps. These can take multiple hours and cause your OS to think Dwarf Fortress isn't responding (Check the progress file for information about the progress of the dump).
- Huge objects may use up all of a computer's RAM, leading to app or system crashes.
- Large files might not be openable in text editors, this does not necessarily mean the file is corrupted/broken, most text editors just can't open files over 2GB, so check its limits.


Usage
-----

    dump --help
    dump [object] --gmeditor
    dump [object] --depth [num]
    dump [object] --name [file name]
    dump --load [file name]
    dump --load [file name] --compare [file name]


Examples
--------

"dump df.global.plotinfo.main.fortress_entity --depth 8 --gmeditor"
    Dumps your fortress' data, up to 8 levels deep, to a file and opens up the dump in gui/gm-editor.

"dump {data='Nothing'} --name nothing"
    Dumps the provided object to a file named 'dump-nothing-[n]', with [n] being the first number that prevents file conflicts.

"dump --load dump-1 --compare dump-named-1 --gmeditor"
    Dumps the difference in data between the 'dump-1.json' and 'dump-named-1.json' dumps, then opens the result in gui/gm-editor.


Notes
-----

Dumps and the progress log are created in the 'Dwarf Fortress/hack' directory.
While creating a dump, a '.txt' is created and written to in real time, then after it finishes the data is dumped to a JSON file.
The '.txt' file can't be loaded or used for anything, but is meant to be more readable and quicker to generate than the JSON.
When looking at the progress log in a text editor, new logs will most likely not show up until the file is reopened.
In personal tests, dumping 'df.global.world' at a depth of 10 took around 5hrs and generated a 3GB txt file and a 15GB JSON file (Lower depths are highly recommended).


]====]

local argparse = require('argparse')
local gmeditor = reqscript('gui/gm-editor')
---@type tatoutils
local tatoutils = reqscript('tatoutils')

local DEFAULT_DEPTH = 5
local ARRAY_GROUPING = 100
local INDENT = "    "
local FILE_PATH = "hack"
local FILE_PREFIX = "dump"
local FILE_SUFFIX = ".txt"
local JSON_SUFFIX = ".json"
local SEPARATOR = "|~ValueHere~|"
local JSON_CHILDREN_POINT = 30

---@type file*
local dumpFile

---@type file*
local progressFile

---@type string|nil
local fileName

---@class ArrayGroup: df.class
---@field count integer
---@field value any
ArrayGroup = defclass(ArrayGroup)
ArrayGroup.ATTRS {
    count = 0,
    value = DEFAULT_NIL
}

function ArrayGroup:__tostring()
    return "("..self.count.."x "..tostring(self.value)..")"
end

--Modified version of the one in 'gui/gm-editor'
--  Displays enums and ref ids in the gm-editor style
local function getStringValue(obj)
    local text = tostring(obj.value)
    local meta = getmetatable(obj)
    local enum = meta._type
    if enum and enum._kind == "enum-type" then
        text = text.." ("..tostring(enum[obj.value])..")"
    end
    if meta.ref_target then
        text = text.. " (ref-target: "..getmetatable(meta.ref_target)..")"
    end
    return text
end

---@param obj any
---@return table
local function restoreToString(obj)
    --If the object is a container type
    local obj_type = type(obj)
    if obj_type == "table" or obj_type == "userdata" then
        --Preserve the object's tostring override
        setmetatable(obj, { __tostring = tatoutils.metatableToString, _json__tostring = tostring(obj) })

        --For each child object
        for k,v in pairs(obj) do
            --Preserve their tostring overrides too
            obj[k] = restoreToString(v)
        end
    end

    return obj
end

---@generic T
---@param arr `T`[]
---@param amount integer
---@return { start_idx: integer, end_idx: integer, count: integer, group_count: integer, groups: { start_idx: integer, end_idx: integer, count: integer, value: any }[] }
local function groupArrayByAmount(arr, amount)
    local next, t = pairs(arr)
    local counterStart = next(t)
    local counter = 0
    local curValue = t[counterStart]

    array_info = { start_idx = counterStart, end_idx = counterStart + #arr - 1, count = #arr, group_count = 0, groups = {} }
    for k,v in next, t do
        if curValue == v then
            counter = counter + 1
        else
            if counter >= amount then
                table.insert(array_info.groups, { start_idx = counterStart, end_idx = counterStart + counter - 1, count = counter, value = curValue })
            end
            curValue = v
            counter = 1
            counterStart = k
        end
    end
    if counter >= amount then
        table.insert(array_info.groups, { start_idx = counterStart, end_idx = counterStart + counter - 1, count = counter, value = curValue })
    end
    array_info.group_count = #array_info.groups

    return array_info
end

---@param text string?
local function appendToDumpFile(text)
    --Write the text to the file
    tatoutils.appendToFile(dumpFile, text)
end

---@param text string
local function writeProgress(text)
    --Write the text to the file immediately, without waiting for the next batch write, in case of crashes
    print(text)
    tatoutils.writeImmediate(progressFile, text)
end

---@param main_value any
local function progressWriter(main_value)
    local prog_start_time = os.time()
    local prog_count = 0
    local prog_cur_count = 0
    pcall(function()
        for _,_ in pairs(main_value) do
            prog_count = prog_count + 1
        end
    end)

    --Function to run after processing main_value
    return function()
        writeProgress("=========================================\n"..tostring(main_value).." -> ("..(os.difftime(os.time(), prog_start_time)).."s)\n")
    end,

    --Function to pass down to main_value's children
    function(value)
        local prog_before = os.time()

        --Function to run after processing value
        return function()
            --Increase the current progress, and write that to the file
            prog_cur_count = prog_cur_count + 1
            writeProgress(prog_cur_count.." / "..prog_count.." ("..(os.difftime(os.time(), prog_start_time)).."s | +"..(os.difftime(os.time(), prog_before)).."s) | "..tostring(value).."\n")
        end,

        --Function to pass down to value's children
        function (val)
            local prog_before = os.time()

            --Function to run after processing val
            return function()
                --If over 10s have passed
                local diff = os.difftime(os.time(), prog_before)
                if diff > 10 then
                    --Write to the file the amount of time that's passed and the object's name
                    writeProgress("\t[("..(os.difftime(os.time(), prog_start_time)).."s | +"..diff.."s) | "..tostring(val).."]\n")
                end
            end,

            --Function to pass down to val's children
            function (v)
                local prog_before = os.time()
                local prog_timer = os.time()

                --Function to run after processing v
                return function()
                    --If over 5s have passed
                    local diff = os.difftime(os.time(), prog_before)
                    if diff > 5 then
                        --Write to the file the amount of time that's passed and the object's name
                        writeProgress("\t\t[("..(os.difftime(os.time(), prog_start_time)).."s | +"..diff.."s) | "..tostring(v).."]\n")
                    end
                end,
                --Function to pass down to v's children
                function (v2)

                    --Function to run after processing v2
                    return function()
                        --If over 30s have passed
                        local diff = os.difftime(os.time(), prog_timer)
                        if diff > 30 then
                            --Write to the file the amount of time that's passed
                            writeProgress("\t\t\t[("..(os.difftime(os.time(), prog_start_time)).."s | +"..diff.."s)]\n")
                            prog_timer = os.time()
                        end
                    end,
                    --Don't pass a function down to v2's children
                    nil
                end
            end
        end
    end
end

---@param obj1 any
---@param obj2 any
---@return table
local function difference(obj1, obj2)
    return setmetatable({ value = restoreToString(obj1), compare = restoreToString(obj2) }, { __tostring = tatoutils.metatableToString, _json__tostring = tostring(obj1):sub(1,8).." -> "..tostring(obj2):sub(1,8) })
end

---@param value any
---@param parent_stack table[]
---@param max_depth integer
---@param array_info? { start_idx: integer, end_idx: integer, count: integer, group_count: integer, groups: { start_idx: integer, end_idx: integer, count: integer, value: any }[] }
---@param progress_func? fun(value: any): function|nil
---@return any
local function transcribeTable(value, parent_stack, max_depth, array_info, progress_func)
    local transcribe_start = os.time()
    local output = {}

    --Add this table to the current parent stack
    local indent_lvl = 0
    local new_parent_stack = {}
    for k,v in pairs(parent_stack) do
        new_parent_stack[k] = v
        indent_lvl = indent_lvl + 1
    end
    indent_lvl = indent_lvl + 1
    new_parent_stack[tatoutils.rawtostring(value)] = indent_lvl

    --Preserve as much metatable info as possible
    --  Can't access the full metatable since '__metatable' is set
    --  Can't bypass '__metatable' since all the objects are userdata, and you need C functions to interact with them
    local meta = { __key_order = {}, __pairs = tatoutils.orderedPairs }
    local value_metatable = getmetatable(value)
    if value_metatable then
        if type(value_metatable) == "table" then
            for k,v in pairs(value_metatable) do
                meta[k] = v
            end
            if not meta.__name then
                meta.__name = tostring(value)
            end
        else
            pcall(function() meta.__name = getmetatable(value) end)
            pcall(function() meta._type = value._type end)
            pcall(function() meta._kind = value._kind end)
            pcall(function() meta.ref_target = value.ref_target end)
        end

        --If it's an array get the length
        local length = tatoutils.getArrayLength(value)
        if length then
            --Put the length of the array between the type's brackets
            meta.__name = ((tostring(value):match('<(.+):') or type(value)):match('.*%[') or meta.__name.."[")..length.."]"
        end
        pcall(function() meta.__tostring = function (t) return "<"..tatoutils.rawtostring(t)..">" end end)
    end
    setmetatable(output, meta)

    --Open brackets
    appendToDumpFile(array_info and "[" or "{")

    --Since arrays are all printed on 1 line, indent beforehand
    if array_info then
        tatoutils.writeLine(dumpFile, "", indent_lvl, INDENT)
    end

    --Iterate through the keys
    local first_item = true
    local cur_group = 1
    for k,v in pairs(value) do
        --Get the type name
        local vtype = type(v)
        local type_name = (tostring(v):match('<(.+):') or vtype)

        --Handle array value groups, if there are array groups and they haven't all been handled yet
        --  Array value groups are custom groupings for reducing large amounts of identical consecutive array values
        local inGroup = false
        if array_info and array_info.group_count >= cur_group then
            local group = array_info.groups[cur_group]

            --If the current group has been left
            if k > group.end_idx then
                --Advance to the next group
                cur_group = cur_group + 1
                group = array_info.groups[cur_group]
            end

            --If the group exists
            if group then
                --Check whether the current index is within the group
                inGroup = k >= group.start_idx and k <= group.end_idx

                --If entering the group for the first time
                if inGroup and k == group.start_idx then
                    --If it isn't the first item (First item already has an indent)
                    if not first_item then
                        --Add an empty line to separate this item from the next
                        tatoutils.writeLine(dumpFile, "", indent_lvl, INDENT)
                    end

                    --Format the group's value before adding it to the file 
                    local group_value = tostring(group.value):gsub('.*: ', ""):gsub(">", "")
                    if vtype == "string" then
                        group_value = "\""..group_value.."\""
                    end
                    output[k] = ArrayGroup{ count = group.count, value = group.value }
                    table.insert(meta.__key_order, k)
                    appendToDumpFile(group.count.."x("..type_name..": "..group_value.."),")

                    --If there is another value after the end of the current group
                    if array_info.end_idx ~= group.end_idx then
                        --Add a new line
                        tatoutils.writeLine(dumpFile, "", indent_lvl, INDENT)

                    --If the group lasts until the end of the array
                    else
                        --exit array early
                        break
                    end
                end
            end
        end

        --If there are no array value groups, or the current value isn't in one
        if not array_info or not inGroup or array_info.group_count < cur_group then
            --If the item is a function
            if vtype == "function" then
                --Print it out looking like a function
                output[k] = tostring(v)
                table.insert(meta.__key_order, k)
                tatoutils.writeLine(dumpFile, k.."(),", indent_lvl, INDENT)

            --If the item is a table
            elseif vtype == "table" or vtype == "userdata" then
                --If it's an array get the length
                local length = tatoutils.getArrayLength(v)
                if length then
                    --Put the length of the array between the type's brackets
                    type_name = (type_name:match('.*%[') or type_name.."[")..length.."]"
                end

                --If this is an item of an array
                if array_info then
                    --If it isn't the first item (First item already has an indent)
                    if not first_item then
                        --Add an empty line to separate this item from the next
                        tatoutils.writeLine(dumpFile, "", indent_lvl, INDENT)
                    end
                else
                    --Write the key and type
                    tatoutils.writeLine(dumpFile, k.." <"..type_name..">: ", indent_lvl, INDENT)
                end

                --If the table is already in the parent stack
                local raw_string = tatoutils.rawtostring(v)
                if new_parent_stack[raw_string] then
                    --Handle recursion
                    local recursion_info = "Recursion: "..raw_string.." ("..(indent_lvl - new_parent_stack[raw_string])..")"
                    output[k] = recursion_info
                    table.insert(meta.__key_order, k)
                    appendToDumpFile(recursion_info..",")

                --If the parent stack hasn't exceeded the max depth
                elseif indent_lvl < max_depth then
                    if length then
                        --Transcribe the value, with added array information
                        output[k] = transcribe(v, new_parent_stack, max_depth, groupArrayByAmount(v, ARRAY_GROUPING), progress_func)
                    else
                        --Transcribe the value
                        output[k] = transcribe(v, new_parent_stack, max_depth, nil, progress_func)
                    end
                    table.insert(meta.__key_order, k)

                --If the max depth has been reached
                else
                    --Print the table's address
                    local address_info = "\""..(tostring(v):match("^<(.*)>") or tostring(v) or "nil").."\""
                    --local address_info = tostring(v):gsub('.*: ', ""):sub(1, -2) --Just the address part

                    --If the table has an id, print that too
                    local appendId = function ()
                        local id = v.id
                        if id and type(id) ~= "table" and type(id) ~= "userdata" then
                            address_info = address_info.." (ID: "..tostring(id)..")"
                        end
                    end
                    pcall(appendId)

                    output[k] = address_info
                    table.insert(meta.__key_order, k)
                    appendToDumpFile(address_info..",")
                end

            --If this item isn't a table
            else
                --If this is an item of an array
                if array_info then
                    --Add a space to separate this item from the next
                    appendToDumpFile(" ")
                else
                    --Write the key and type
                    tatoutils.writeLine(dumpFile, k.." <"..type_name..">: ", indent_lvl, INDENT)
                end

                local val = transcribe(v, new_parent_stack, max_depth, nil, progress_func)

                --Some DFHack data types are automatically converted into primites when using 'obj.key' notation
                --  By using 'obj:_field(key)' you can get the true userdata object and extract its metadata
                if value._field then
                    val = { value = v }
                    local vdata = value:_field(k)
                    local vmeta = {}
                    pcall(function() vmeta.__name = getmetatable(vdata) end)
                    pcall(function() vmeta._type = vdata._type
                        val.type = tostring(vmeta._type)
                        val.kind = vmeta._type._kind
                        val.last_item = vmeta._type._last_item
                    end)
                    pcall(function() vmeta._kind = vdata._kind end)
                    pcall(function() vmeta.ref_target = vdata.ref_target end)
                    pcall(function() vmeta.__tostring = getStringValue end)
                    setmetatable(val, vmeta)
                end

                output[k] = val
                table.insert(meta.__key_order, k)
            end
        end
        first_item = false
    end

    --Close brackets
    tatoutils.writeLine(dumpFile, array_info and "]," or "},", indent_lvl - 1, INDENT)

    --If transcribing this object took longer than the amount specified
    if os.difftime(os.time(), transcribe_start) > JSON_CHILDREN_POINT then
        --Set the flag to convert this object's children to JSON separately
        meta._json_children = true
    end
    return output
end

---@param value any
---@param parent_stack table[]
---@param max_depth integer
---@param array_info? { start_idx: integer, end_idx: integer, count: integer, group_count: integer, groups: { start_idx: integer, end_idx: integer, count: integer, value: any }[] }
---@param progress_func? fun(value: any): function, function|nil
---@return any
function transcribe(value, parent_stack, max_depth, array_info, progress_func)
    local output = value
    local this_func = nil
    if progress_func then
        this_func, progress_func = progress_func(value)
    end

    --If the value is a table
    if type(value) == "table" or type(value) == "userdata" then

        --Check if light usertable (C pointer thing), which can't be read
        if tatoutils.isLightUserdata(value) then
            --Write it as string since it can't be read
            appendToDumpFile(tostring(value))
            output = tostring(value)

        --If not a light usertable
        else
            --Transcribe as a table
            output = transcribeTable(value, parent_stack, max_depth, array_info, progress_func)
        end

    --If the value is a string
    elseif type(value) == "string" then
        --print the string in between quotation marks
        appendToDumpFile("\""..tostring(value).."\",")

    --If the value is any other type
    else
        --Print it normally
        appendToDumpFile(tostring(value)..",")
    end

    if this_func then
        this_func()
    end

    return output
end

---@param name string
---@param obj any
---@param max_depth number
---@return any
function dump(name, obj, max_depth)
    fileName = fileName or tatoutils.getFileName(FILE_PATH, FILE_PREFIX..(name and ("-"..name) or ""), FILE_SUFFIX)
    local file_name = fileName..FILE_SUFFIX
    dumpFile = assert(tatoutils.createFile(file_name), "Error opening file")
    writeProgress("Dumping to file: "..dfhack.getDFPath().."\\"..file_name.."\n")

    local output = dfhack.with_suspend(transcribe, obj, {}, max_depth, nil, progressWriter)

    dumpFile:close()
    return output
end

---@param name string
---@return any
function loadDump(name)
    local file_name = FILE_PATH.."\\"..name..JSON_SUFFIX
    writeProgress("Loading file: "..dfhack.getDFPath().."\\"..file_name.."\n")
    local success, output = tatoutils.loadJSONFile(file_name)
    return success and output or {}
end

---@param obj1 any
---@param obj2 any
---@return any
function compare(obj1, obj2)
    --Compare the 2, returning a table that only contains the differences
    local obj_type = type(obj1)

    --If the types are the same (If the types are different then they're clearly different)
    if obj_type == type(obj2) then
        local light_obj1 = tatoutils.isLightUserdata(obj1)
        local light_obj2 = tatoutils.isLightUserdata(obj2)

        --If either of them are light userdata (Unreadable)
        if light_obj1 or light_obj2 then
            --If they're both light userdata
            if light_obj1 and light_obj2 then
                --Skip, nothing to compare
                return nil
            end

        --If they're container types
        elseif obj_type == "table" or obj_type == "userdata" then
            local output = {}
            local keys = {}
            local key_count = 0
            local has_diff = false

            --Check if obj1 and obj2 have a common base to their string equivalent
            --  (Basically the type name in most cases)
            local string_obj1 = tostring(obj1):match('^([^:%[]+)')
            local string_obj2 = tostring(obj2):match('^([^:%[]+)')
            if string_obj1 and string_obj1 == string_obj2 then
                --Check if obj1 and obj2 have brackets with different values in between them
                local brackets_obj1 = tostring(obj1):match('%[(%d+)%]')
                local brackets_obj2 = tostring(obj2):match('%[(%d+)%]')
                if brackets_obj1 ~= brackets_obj2 then
                    --Reestablish the brackets, but show the change in values
                    string_obj1 = string_obj1.."["..tostring(brackets_obj1).." -> "..tostring(brackets_obj2).."]"

                --If they both have brackets with the same value
                elseif brackets_obj1 and brackets_obj1 == brackets_obj2 then
                    --Reestablish the brackets and value
                    string_obj1 = string_obj1.."["..tostring(brackets_obj1).."]"
                end

                --If the string starts with a '<'
                if string_obj1:sub(1,1) == '<' then
                    --Add the ending '>', since it'll most probably have been cut off
                    string_obj1 = string_obj1..">"
                end

                --Set the output's tostring to the result, so that it displays nice in gm-editor
                setmetatable(output, { __tostring = tatoutils.metatableToString, _json__tostring = string_obj1 })
            end

            --Loop through and compare all of obj1 with obj2
            for k,v in pairs(obj1) do
                key_count = key_count + 1
                keys[k] = true
                output[k] = compare(v, obj2[k])
                has_diff = has_diff or output[k] ~= nil
                obj1[k] = nil
                obj2[k] = nil
            end

            --All of obj2 that wasn't compared must be keys that are unique to obj2, and thus different
            for k,v in pairs(obj2) do
                if v then
                    key_count = key_count + 1
                    keys[k] = true
                    output[k] = compare(nil, v)
                    has_diff = true
                    obj2[k] = nil
                end
            end

            --If the object was a DFHack primitive
            if (key_count == 1 or key_count == 2 and keys["type"]) and keys["value"] then
                --Return the result of the value field comparison directly, instead of adding an unnecessary layer
                --  (DFHack primitives are actually tables that just have a value field, and sometimes a type field too)
                output = output["value"]
            end

            --If there were any differences
            if has_diff then
                --Return the differences
                return output
            else
                return nil
            end

        --If they're functions
        elseif obj_type == "function" then
            --Skip functions, there's not really anything to compare
            return nil

        --If they're regular primitive types
        else
            --If they're the same, then there's no difference
            if obj1 == obj2 then
                return nil
            end
        end
    end

    --Return a difference object containing the 2
    return difference(obj1, obj2)
end

---@param obj any
---@param indent? integer
---@return boolean
function encodeChildJSON(obj, indent)
    local prog_start_time = os.time()
    indent = (indent and indent >= 0) and indent or 0
    local indent_text = ""
    for _=1,indent do
        indent_text = indent_text.."\t"
    end
    writeProgress(indent_text.."Attempting to convert the children to JSON separately ("..(os.difftime(os.time(), prog_start_time)).."s)\n")

    --Get obj's base structure without the children's data
    local base_obj = {}
    for k,_ in pairs(obj) do
        base_obj[k] = SEPARATOR
    end
    local meta = getmetatable(obj) or {}
    meta._json_children = true
    setmetatable(base_obj, meta)

    --Convert obj's base structure to JSON
    local success,json_base_obj = tatoutils.toJSON(base_obj)
    if success then
        --Get the order of the keys in the base structure's JSON
        local json_base_keys = {}
        for str in json_base_obj:gmatch("\"([^\"]-)\": \""..SEPARATOR.."\"") do
            table.insert(json_base_keys, str)
        end
        local key_count = #json_base_keys

        --If the object has children to encode as JSON
        if key_count > 0 then
            --Split the base structure's JSON into the pieces that go between each child's data
            local split_base_obj = {}
            for str in json_base_obj:gmatch("(.-)\""..SEPARATOR.."\"") do
                table.insert(split_base_obj, str)
            end
            table.insert(split_base_obj, json_base_obj:match(".*\""..SEPARATOR.."\"(.-)$"))

            writeProgress(indent_text.."Writing child data to JSON file ("..(os.difftime(os.time(), prog_start_time)).."s)\n")
            local prog_before = os.time()

            --Go through all of obj's children, following the order of the keys in the base structure's JSON
            local split_index = 1
            for _,key in pairs(json_base_keys) do
                for k,v in pairs(obj) do
                    if tostring(k) == key then
                        --Add the base structure JSON piece that goes before this child to the JSON file
                        appendToDumpFile(split_base_obj[split_index])

                        local encoded = false
                        --If the child object was marked for having their children converted into JSON separately
                        if (type(v) == "table" or type(v) == "userdata") and not tatoutils.isLightUserdata(v) and getmetatable(v)._json_children then
                            --Convert each child of obj into JSON separately
                            if encodeChildJSON(v, indent + 1) then
                                encoded = true
                            else
                                writeProgress(indent_text.."Failed to JSON-ify the child data separately ("..(os.difftime(os.time(), prog_start_time)).."s)\n")
                            end
                        end

                        if not encoded then
                            --Convert the child data to JSON
                            local succ,json_data = tatoutils.toJSON(v, false)
                            if succ then
                                --Add the child data to the JSON file (Escaping characters to preserve values)
                                appendToDumpFile(json_data)
                            else
                                --Cancel this process and convert to JSON the regular way
                                return false
                            end
                        end

                        --Log the completion of writing this child's data to the JSON file
                        writeProgress(indent_text..split_index.." / "..key_count.." ("..(os.difftime(os.time(), prog_start_time)).."s | +"..(os.difftime(os.time(), prog_before)).."s) | Wrote "..k.." data to JSON file\n")
                        split_index = split_index + 1
                        prog_before = os.time()
                        break
                    end
                end
            end

            --Add the ending base structure JSON piece to the JSON file
            appendToDumpFile(split_base_obj[split_index])
            return true
        end
    end

    return false
end

---@param obj any
---@param name string
function toJSON(obj, name)
    fileName = fileName or tatoutils.getFileName(FILE_PATH, FILE_PREFIX..(name and ("-"..name) or ""), JSON_SUFFIX)
    local file_name = fileName..JSON_SUFFIX
    local prog_start_time = os.time()

    --If obj is a table
    if (type(obj) == "table" or type(obj) == "userdata") and not tatoutils.isLightUserdata(obj) then
        --Create the JSON file
        dumpFile = assert(tatoutils.createFile(file_name), "Error opening file")
        writeProgress("Dumping to file: "..dfhack.getDFPath().."\\"..file_name.."\n")

        --Convert each child of obj into JSON separately to conserve memory
        if encodeChildJSON(obj) then
            dumpFile:close()
            writeProgress("JSON-ified the child data separately ("..(os.difftime(os.time(), prog_start_time)).."s)\n")
            return
        end
        dumpFile:close()
        writeProgress("Failed to JSON-ify the child data separately ("..(os.difftime(os.time(), prog_start_time)).."s)\n")
    end

    --Convert to JSON file regularly
    writeProgress("Attempting to convert the entire object to JSON at once\n")
    local prog_before = os.time()
    tatoutils.toJSONFile(obj, file_name)
    writeProgress("Wrote entire object to JSON file ("..(os.difftime(os.time(), prog_start_time)).."s | +"..(os.difftime(os.time(), prog_before)).."s)\n")
end

function main(...)
    local args = {...}
    local positionals = argparse.processArgsGetopt(args, {
        { 'h', 'help', handler = function() args.help = true end },
        { 'd', 'depth', hasArg = true, handler = function(arg) args.depth = tonumber(arg) end },
        { 'n', 'name', hasArg = true, handler = function(arg) args.name = arg:gsub(".json", ""):gsub(".txt", "") end },
        { nil, 'gmeditor', handler = function() args.gmeditor = true end },
        { nil, 'compare', hasArg = true, handler = function(arg) args.compare = arg end },
        { nil, 'load', hasArg = true, handler = function(arg) args.load = arg:gsub(".json", ""):gsub(".txt", "") end}
    })

    if args.help or not (positionals[1] or args.load) then
        print(help)
        return
    end

    --Since the console gets closed and the game regularly freezes, writing to a file is the only way to get info out and visible
    fileName = FILE_PATH.."\\progress"
    local file_name = fileName..FILE_SUFFIX
    progressFile = assert(tatoutils.createFile(file_name), "Error opening file")
    print("Writing progress to "..dfhack.getDFPath().."\\"..file_name)
    fileName = nil

    for k,v in pairs(positionals) do
        positionals[k] = v:gsub(".json", ""):gsub(".txt", "")
    end

    local loaded = nil
    local output = nil

    if not args.depth then
        args.depth = DEFAULT_DEPTH
    end

    if args.load and (args.compare or args.gmeditor) then
        loaded = loadDump(args.load)
    end

    if positionals[1] then
        output = dump(args.name, tatoutils.eval(positionals[1]), args.depth)
    else
        output = loaded
    end

    if args.compare and output then
        --Load up the comparison file and compare it against the dump
        local other = loadDump(args.compare)
        writeProgress("Comparing "..(args.load or ("`"..positionals[1].."`")).." with "..args.compare.."\n")
        output = dump(args.name, compare(output, other), 100)
        --output = compare(output, other)
    end

    --If any output was generated
    if output then
        --If anything new was done, instead of just loading in a previous dump
        if positionals[1] or args.compare then
            --Convert the dump to JSON format
            toJSON(output, args.name)
        end

        if args.gmeditor then
            --Opens up the gm-editor with the results of the dump
            writeProgress("Opening gui/gm-editor with the resulting data\n")
            gmeditor.GmScreen{freeze = true, target = output}:show()
        end
    end
    writeProgress("Finished")
    progressFile:close()
end

if not dfhack_flags.module then
    main(...)
end
