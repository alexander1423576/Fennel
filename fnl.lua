-- fnl.lua

--[[
Copyright (c) 2016 Calvin Rose
Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
]]

-- Make global variables local.
local setmetatable = setmetatable
local getmetatable = getmetatable
local type = type
local assert = assert
local select = select
local pairs = pairs
local ipairs = ipairs
local unpack = unpack or table.unpack

local SYMBOL_MT = { 'SYMBOL' }
local LIST_MT = { 'LIST' }

-- Load code with an environment in all recent Lua versions
local function loadCode(code, environment)
    environment = environment or _ENV or _G
    if setfenv and loadstring then
        local f = assert(loadstring(code))
        setfenv(f, environment)
        return f
    else
        return assert(load(code, nil, "t", environment))
    end
end

-- Create a new list
local function list(...)
    local t = {...}
    t.n = select('#', ...)
    return setmetatable(t, LIST_MT)
end

-- Create a new symbol
local function sym(str)
    return setmetatable({ str }, SYMBOL_MT)
end

-- Checks if an object is a List. Returns the object if is a List.
local function isList(x)
    return type(x) == 'table' and getmetatable(x) == LIST_MT and x
end

-- Checks if an object is a symbol. Returns the object if it is a symbol.
local function isSym(x)
    return type(x) == 'table' and getmetatable(x) == SYMBOL_MT and x
end

-- Checks if an object any kind of table, EXCEPT list or symbol
local function isTable(x)
    return type(x) == 'table' and
        getmetatable(x) ~= LIST_MT and getmetatable(x) ~= SYMBOL_MT and x
end

-- Append b to list a. Return a. If b is a list and not 'force', append all
-- elements of b to a.
local function listAppend(a, b)
    assert(isList(a), 'expected list')
    assert(isList(b), 'expected list')
    for i = 1, b.n do
        a[a.n + i] = b[i]
    end
    a.n = b.n + a.n
    return a
end

-- Turn a list like table of values into a non-sequence table by
-- assigning successive elements as key-value pairs. mapify {1, 'a', 'b', true}
-- should become {[1] = 'a', ['b'] = true}
local function mapify(tab)
    local max = 0
    for k, v in pairs(tab) do
        if type(k) == 'number' then
            max = max > k and max or k
        end
    end
    local ret = {}
    for i = 1, max, 2 do
        if tab[i] ~= nil then
            ret[tab[i]] = tab[i + 1]
        end
    end
    return ret
end

local READER_INDEX = { length = math.huge }
local READER_MT = {__index = READER_INDEX}

function READER_INDEX:sub(a, b)
    assert(a and b, 'reader sub requires two arguments')
    assert(a > 0 and b > 0, 'no non-zero sub support')
    a, b = a - self.offset, b - self.offset
    return self.buffer:sub(a, b)
end

function READER_INDEX:free(index)
    local dOffset = index - self.offset
    if dOffset < 1 then
        return
    end
    self.offset = index
    self.buffer = self.buffer:sub(dOffset + 1)
end

function READER_INDEX:getMore()
    local chunk = self.more()
    self.buffer = self.buffer .. chunk
end

function READER_INDEX:byte(i)
    i = i or 1
    local index = i - self.offset
    assert(index > 0, 'index below buffer range')
    while index > #self.buffer do
        self:getMore()
    end
    return self.buffer:byte(index)
end

-- Create a reader. A reader emulates a subset of the string api
-- in order to allow streams to be parsed as if the were strings.
local function createReader(more)
    return setmetatable({
        more = more or io.read,
        buffer = '',
        offset = 0
    }, READER_MT)
end

-- Table of delimiter bytes - (, ), [, ], {, }
-- Opener keys have closer as the value, and closers keys
-- have true as their value.
local delims = {
    [40] = 41,        -- (
    [41] = true,      -- )
    [91] = 93,        -- [
    [93] = true,      -- ]
    [123] = 125,      -- {
    [125] = true      -- }
}

-- Parser
-- Parse a string into an AST. The ast is a list-like table consiting of
-- strings, symbols, numbers, booleans, nils, and other ASTs. Each AST has
-- a value 'n' for length, as ASTs can have nils which do not cooperate with
-- Lua's semantics for table length.
-- Returns an AST containing multiple expressions. For example, "(+ 1 2) (+ 3 4)"
-- would parse and return a single AST containing two sub trees.
local function parseSequence(str, dispatch, index, opener)
    index = index or 1
    local seqLen = 0
    local values = {}
    local strlen = str.length or #str
    local function free(i)
        if str.free then
            str:free(i)
        end
    end
    local function onWhitespace(includeParen)
        local b = str:byte(index)
        if not b then return false end
        return b == 32 or (b >= 9 and b <= 13) or
            (includeParen and delims[b])
    end
    local function readValue()
        local start = str:byte(index)
        local stringStartIndex = index
        -- Check if quoted string
        if start == 34 or start == 39 then
            local last, current
            repeat
                index = index + 1
                current, last = str:byte(index), current
            until index >= strlen or (current == start and last ~= 92)
            local raw = str:sub(stringStartIndex, index)
            local loadFn = loadCode(('return %s'):format(raw))
            index = index + 1
            return loadFn()
        else -- non-quoted string - symbol, number, or nil
            while not onWhitespace(true) do
                index = index + 1
            end
            local rawSubstring = str:sub(stringStartIndex, index - 1)
            if rawSubstring == 'nil' then return nil end
            if rawSubstring == 'true' then return true end
            if rawSubstring == 'false' then return false end
            return tonumber(rawSubstring) or sym(rawSubstring)
        end
    end
    while index < strlen do
        while index < strlen and onWhitespace() do
            index = index + 1
        end
        local b = str:byte(index)
        if not b then break end
        free(index - 1)
        local value, vlen
        if type(delims[b]) == 'number' then -- Opening delimiter
            value, index, vlen  = parseSequence(str, nil, index + 1, b)
            if b == 40 then
                value.n = vlen
                value = setmetatable(value, LIST_MT)
            elseif b == 123 then
                value = mapify(value)
            end
        elseif delims[b] then -- Closing delimiter
            if delims[opener] ~= b then
                error('unexpected delimiter ' .. string.char(b))
            end
            index = index + 1
            break
        else -- Other values
            value = readValue()
        end
        seqLen = seqLen + 1
        if dispatch then
            dispatch(value)
        else
            values[seqLen] = value
        end
    end
    return values, index, seqLen
end

-- Parse a string and return an AST, along with its length as the second return value.
local function parse(str, dispatch)
    local values, _, len = parseSequence(str, dispatch)
    values.n = len
    return setmetatable(values, LIST_MT), len
end

-- Serializer

local toStrings = {}

-- Serialize an AST into a string that can be read back again with the parser.
local function astToString(ast)
    return (toStrings[type(ast)] or tostring)(ast)
end

function toStrings.table(tab)
    if isSym(tab) then
        return tab[1]
    elseif isList(tab) then
        local buffer = {}
        for i = 1, tab.n do
            buffer[i] = astToString(tab[i])
        end
        return '(' .. table.concat(buffer, ' ') .. ')'
    else
        local buffer = {}
        for k, v in pairs(tab) do
            buffer[#buffer + 1] = astToString(k)
            buffer[#buffer + 1] = astToString(v)
        end
        return '{' .. table.concat(buffer, ' ') .. '}'
    end
end

function toStrings.string(str)
    local ret = ("%q"):format(str):gsub('\n', 'n'):gsub("[\128-\255]", function(c)
        return "\\" .. c:byte()
    end)
    return ret
end

function toStrings.number(num)
    return ('%.17g'):format(num)
end

-- Expand a macro until it is no longer expandable.
-- Does not recursively expand sub expressions
local function macroExpand(ast, macros)
    if not isList(ast) then return ast end
    while true do
        local first = assert(isSym(ast[1]), 'expected symbol in macro expansion')
        local macro = macros[first]
        if macro then
            ast = macro(unpack(ast, 2))
        else
            break
        end
    end
    return assert(isList(ast), 'expected list')
end

-- Compilation

-- Special Forms
local SPECIALS = {}

-- Creat a new Scope, optionally under a parent scope. Scopes are compile time constructs
-- that are responsible for keeping track of local variables, name mangling, and macros.
-- They are accessible to user code via the '*compiler' special form (may change). They
-- use metatables to implmenent nesting via inheritance.
local function makeScope(parent)
    return {
        unmanglings = setmetatable({}, {
            __index = parent and parent.unmanglings
        }),
        manglings = setmetatable({}, {
            __index = parent and parent.manglings
        }),
        macros = setmetatable({}, {
            __index = parent and parent.macros
        }),
        specials = setmetatable({}, {
            __index = parent and parent.specials or SPECIALS
        }),
        parent = parent,
        vararg = parent and parent.vararg,
        depth = parent and ((parent.depth or 0) + 1) or 0
    }
end

local GLOBAL_SCOPE = makeScope()

local luaKeywords = {
    'and',
    'break',
    'do',
    'else',
    'elseif',
    'end',
    'false',
    'for',
    'function',
    'if',
    'in',
    'local',
    'nil',
    'not',
    'or',
    'repeat',
    'return',
    'then',
    'true',
    'until',
    'while'
}
for i, v in ipairs(luaKeywords) do
    luaKeywords[v] = i
end

-- Creates a symbol from a string by mangling it.
-- ensures that the generated symbol is unique
-- if the input string is unique in the scope.
local function stringMangle(str, scope, acceptVararg)
    if str == '...' then
        if acceptVararg or scope.vararg then
            return str
        else
            error 'vararg not expected'
        end
    end
    if scope.manglings[str] then
        return scope.manglings[str]
    end
    local append = 0
    local mangling = str
    if luaKeywords[mangling] or mangling:match('^[^%w_]') then
        mangling = '_' .. mangling
    end
    mangling = mangling:gsub('[^0-9a-zA-Z_]', function(c)
        return tonumber(c:byte(), 36)
    end)
    local raw = mangling
    while scope.unmanglings[mangling] do
        mangling = raw .. append
        append = append + 1
    end
    scope.unmanglings[mangling] = str
    scope.manglings[str] = mangling
    return mangling
end

-- Generates a unique symbol in the scope.
local function gensym(scope)
    local mangling, append = nil, 0
    repeat
        mangling = '_' .. append
        append = append + 1
    until not scope.unmanglings[mangling]
    scope.unmanglings[mangling] = true
    return mangling
end

-- Convert a literal in the AST to a Lua string. Note that this is very different from astToString,
-- which converts and AST into a MLP readable string.
local function literalToString(x, scope)
    if isSym(x) then return stringMangle(x[1], scope) end
    if type(x) == 'number' then return ('%.17g'):format(x) end
    if type(x) == 'string' then return toStrings.string(x) end
    if type(x) == 'table' then
        local buffer = {}
        for i = 1, #x do -- Write numeric keyed values.
            buffer[#buffer + 1] = literalToString(x[i])
        end
        for k, v in pairs(x) do -- Write other keys.
            if type(k) ~= 'number' or math.floor(k) ~= k or k < 1 or k > #x then
                buffer[#buffer + 1] = ('[%s] = %s'):format(literalToString(k), literalToString(v))
            end
        end
        return '{' .. table.concat(buffer, ', ') ..'}'
    end
    return tostring(x)
end

-- Forward declaration
local compileTossRest

-- Compile an AST expression in the scope into parent, a tree
-- of lines that is eventually compiled into Lua code. Also
-- returns some information about the evaluation of the compiled expression,
-- which can be used by the calling function. Macros
-- are resolved here, as well as special forms in that order.
-- the 'ast' param is the root AST to compile
-- the 'scope' param is the scope in which we are compiling
-- the 'parent' param is the table of lines that we are compiling into.
-- add lines to parent by appending strings. Add indented blocks by appending
-- tables of more lines.
local function compileExpr(ast, scope, parent)
    ast = macroExpand(ast, scope.macros)
    local head = {}
    if isList(ast) then
        local len = ast.n
        -- Test for special form
        local first = ast[1]
        if isSym(first) then -- Resolve symbol
            first = first[1]
        end
        local special = scope.specials[first]
        if special and isSym(ast[1]) then
            local ret = special(ast, scope, parent)
            ret = ret or {}
            ret.expr = ret.expr or list()
            return ret
        else
            local fargs = list()
            local fcall = compileTossRest(ast[1], scope, parent).expr[1]
            for i = 2, len do
                if i == len then
                    listAppend(fargs, compileExpr(ast[i], scope, parent).expr)
                else
                    listAppend(fargs, compileTossRest(ast[i], scope, parent).expr)
                end
            end
            head.validStatement = true
            head.singleEval = true
            head.sideEffects = true
            head.expr = list(('%s(%s)'):format(fcall, table.concat(fargs, ', ')))
            head.unknownExprCount = true
        end
    else
        head.expr = list(literalToString(ast, scope))
    end
    return head
end

-- Compile an AST, and ensure that the expression
-- is fully executed in it scope. compileExpr doesn't necesarrily
-- compile all of its code into parent, and might return some code
-- to the calling function to allow inlining.
local function compileDo(ast, scope, parent)
    local tail = compileExpr(ast, scope, parent)
    if tail.expr.n > 0 and tail.sideEffects then
        local stringExpr = table.concat(tail.expr, ', ')
        if tail.validStatement then
            parent[#parent + 1] = stringExpr
        else
            parent[#parent + 1] = ('do local _ = %s end'):format(stringExpr)
        end
    end
end

-- Toss out the later expressions (non first) in the tail. Also
-- sets the empty expression to 'nil'.
-- This ensures exactly one return value for most manipulations.
local function tossRest(tail, scope, parent)
    if tail.expr.n == 0 then
        tail.expr[1] = 'nil'
    else
        -- Ensure proper order of evaluation
        -- The first AST MUST be evaluated first.
        if tail.expr.n > 1 then
            local s = gensym(scope)
            parent[#parent + 1] = ('local %s = %s'):format(s, tail.expr[1])
            tail.expr[1] = s
            tail = { -- Remove non expr keys
                expr = tail.expr,
                scoped = true
            }
        end
        for i = 2, tail.expr.n do
            parent[#parent + 1] = ('do local _ = %s end'):format(tail.expr[i])
            tail.expr[i] = nil -- Not strictly necesarry
        end
    end
    tail.expr.n = 1
    return tail
end

-- Compile a sub expression, and return a tail that contains exactly one expression.
function compileTossRest(ast, scope, parent)
    return tossRest(compileExpr(ast, scope, parent), scope, parent)
end

-- Helper for flattening a tree of Lua source lines.
local function flattenChunk(chunk, tab)
    if type(chunk) == 'string' then
        return chunk
    end
    tab = tab or '  ' -- 2 spaces
    for i = 1, #chunk do
        chunk[i] = tab .. flattenChunk(chunk[i], tab):gsub('\n', '\n' .. tab)
    end
    return table.concat(chunk, '\n')
end

-- Flatten a tree of Lua source code lines.
-- Tab is what is used to indent a block. By default it is two spaces.
local function rootFlatten(chunk, tab)
    for i = 1, #chunk do
        chunk[i] = flattenChunk(chunk[i], tab)
    end
    return table.concat(chunk, '\n')
end

-- Convert an ast into a chunk of Lua source code by compiling it and flattening.
-- Optionally appends a return statement at the end to return the last statement.
local function transpile(ast, scope, options)
    scope = scope or GLOBAL_SCOPE
    local root = {}
    local head = compileExpr(ast, scope, root)
    if head.expr.n > 0 then
        local expr = table.concat(head.expr, ', ')
        if options.returnTail then
            root[#root + 1] = 'return ' .. expr
        elseif head.sideEffects then
            if head.validStatement then
                root[#root + 1] = expr
            else
                root[#root + 1] = ('do local _ = %s end'):format(expr)
            end
        end
    end
    return rootFlatten(root, options.tab)
end

-- The fn special declares a function. Syntax is similar to other lisps;
-- (fn optional-name [arg ...] (body))
-- Further decoration such as docstrings, meta info, and multibody functions a possibility.
SPECIALS['fn'] = function(ast, scope, parent)
    local fScope = makeScope(scope)
    local index = 2
    local fnName = isSym(ast[index])
    if fnName then
        fnName = stringMangle(fnName[1], scope)
        index = index + 1
    else
        fnName = gensym(scope)
    end
    local argList = assert(isTable(ast[index]), 'expected vector arg list [a b ...]')
    local argNameList = {}
    for i = 1, #argList do
        argNameList[i] = stringMangle(assert(isSym(argList[i]),
            'expected symbol for function parameter')[1], fScope, i == #argList)
    end
    fScope.vararg = argNameList[#argNameList] == '...'
    local fChunk = {}
    for i = index + 1, ast.n - 1 do
        compileDo(ast[i], fScope, fChunk)
    end
    local tail = compileExpr(ast[ast.n], fScope, fChunk)
    local expr = table.concat(tail.expr, ', ')
    fChunk[#fChunk + 1] = 'return ' .. expr
    parent[#parent + 1] = ('local function %s(%s)')
        :format(fnName, table.concat(argNameList, ', '))
    parent[#parent + 1] = fChunk
    parent[#parent + 1] = 'end'
    return {
        expr = list(fnName),
        scoped = true
    }
end

-- Wrapper for table access
SPECIALS['.'] = function(ast, scope, parent)
    local lhs = compileTossRest(ast[2], scope, parent)
    local rhs = compileTossRest(ast[3], scope, parent)
    return {
        expr = list(('%s[%s]'):format(lhs.expr[1], rhs.expr[1])),
        scoped = lhs.scoped or rhs.scoped,
        singleEval = true,
        sideEffects = true
    }
end

local function defineSetterSpecial(name, prefix)
    local formatString = ('%s%%s = %%s'):format(prefix)
    SPECIALS[name] = function(ast, scope, parent)
        local vars = {}
        for i = 2, math.max(2, ast.n - 1) do
            local s = assert(isSym(ast[i]))
            vars[i - 1] = stringMangle(s[1], scope)
        end
        varname = table.concat(vars, ', ')
        local assign = table.concat(compileExpr(ast[ast.n], scope, parent).expr, ', ')
        if assign == '' then
            assign = 'nil'
        end
        parent[#parent + 1] = formatString:format(varname, assign)
    end
end

-- Simple wrapper for declaring local vars.
defineSetterSpecial('var', 'local ')
-- Simple wrapper for setting local vars.
defineSetterSpecial('set', '')

-- Add a comment to the generated code.
SPECIALS['--'] = function(ast, scope, parent)
    for i = 2, ast.n do
        local com = ast[i]
        assert(type(com) == 'string', 'expected string comment')
        parent[#parent + 1] = '-- ' .. com:gsub('\n', '\n-- ')
    end
end

-- Executes a series of statements. Unlike do, evaultes to nil.
-- this simplifies the resulting Lua code.
SPECIALS['block'] = function(ast, scope, parent)
    local subScope = makeScope(scope)
    parent[#parent + 1] = 'do'
    local chunk = {}
    for i = 2, ast.n do
        compileDo(ast[i], subScope, chunk)
    end
    parent[#parent + 1] = chunk
    parent[#parent + 1] = 'end'
end

-- Unlike most expressions and specials, 'values' resolves with multiple
-- values, one for each argument, allowing multiple return values. The last
-- expression, can return multiple arguments as well, allowing for more than the number
-- of expected arguments.
SPECIALS['values'] = function(ast, scope, parent)
    local returnValues = list()
    local scoped, sideEffects, singleEval, unknownExprCount = false, false, false, false
    for i = 2, ast.n do
        local tail
        if i == ast.n then
            tail = compileExpr(ast[i], scope, parent)
        else
            tail = compileTossRest(ast[i], scope, parent)
        end
        listAppend(returnValues, tail.expr)
        if tail.scoped then scoped = true end
        if tail.sideEffects then sideEffects = true end
        if tail.singleEval then singleEval = true end
    end
    local ret = {
        scoped = scoped,
        sideEffects = sideEffects,
        singleEval = singleEval,
        expr = returnValues,
        unknownExprCount = unknownExprCount
    }
    return ret
end

-- Executes a series of statements in order. Returns the result of the last statment.
SPECIALS['do'] = function(ast, scope, parent)
    local subScope = makeScope(scope)
    local chunk = {}
    local len = ast.n
    for i = 2, len - 1 do
        compileDo(ast[i], subScope, chunk)
    end
    local tail = compileExpr(ast[len], subScope, chunk)
    local expr, sideEffects, singleEval, validStatement, unknownExprCounti, scoped =
        tail.expr, tail.sideEffects, tail.singleEval, tail.validStatement, tail.unknownExprCount, tail.scoped
    if tail.unknownExprCount then -- Use imediately invoked closure to wrap instead of do ... end
        chunk[#chunk + 1] = ('return %s'):format(table.concat(expr, ', '))
        local s = gensym(scope)
        -- Use CPS to make varargs accesible to inner function scope.
        local farg = scope.vararg and '...' or ''
        parent[#parent + 1] = ('local function %s(%s)'):format(s, farg)
        parent[#parent + 1] = chunk
        parent[#parent + 1] = 'end'
        expr = list(s .. ('(%s)'):format(farg))
        singleEval = true
        scoped = true
        sideEffects = true
        unknownExprCount = true
        validStatement = true
    else -- Use do ... end
        if expr.n > 0 and tail.scoped then
            singleEval, sideEffects, validStatement = false, false, false
            local syms = {n = expr.n}
            for i = 1, expr.n do
                syms[i] = gensym(scope)
            end
            local s = table.concat(syms, ', ')
            parent[#parent + 1] = 'local ' .. s
            chunk[#chunk + 1] = ('%s = %s'):format(s, table.concat(tail.expr, ', '))
            expr = setmetatable(syms, LIST_MT)
        end
        parent[#parent + 1] = 'do'
        parent[#parent + 1] = chunk
        parent[#parent + 1] = 'end'
    end
    return {
        scoped = scoped,
        expr = expr,
        sideEffects = sideEffects,
        singleEval = singleEval,
        validStatement = validStatement,
        unknownExprCount = unknownExprCount
    }
end

-- Special form for branching - covers all situations with if, elseif, and else.
-- Not meant to be used in most user code, targeted by macros.
SPECIALS['*branch'] = function(ast, scope, parent)
    -- First condition
    local condition = compileTossRest(ast[2], scope, parent)
    parent[#parent + 1] = 'if ' .. condition.expr[1] .. ' then'
    local len = ast.n or #asr
    local subScope = makeScope(scope)
    local subChunk = {}
    local i = 3
    while i <= len do
        local subAst = ast[i]
        if isSym(subAst) and subAst[1] == '*branch' then
            parent[#parent + 1] = subChunk
            subChunk = {}
            i = i + 1
            local nextSym = ast[i]
            assert(isSym(nextSym), 'expected symbol after branch')
            local symVal = nextSym[1]
            subScope = makeScope(scope)
            if symVal == 'else' then
                parent[#parent + 1] = 'else'
            elseif symVal == 'elseif' then
                i = i + 1
                condition = compileTossRest(ast[i], scope, parent)
                parent[#parent + 1] = 'elseif ' .. condition.expr[1] .. ' then'
            else
                error('expected \'else\' or \'elseif\' after \'branch\'.')
            end
        else
            compileDo(ast[i], subScope, subChunk)
        end
        i = i + 1
    end
    parent[#parent + 1] = subChunk
    parent[#parent + 1] = 'end'
end

SPECIALS['*while'] = function(ast, scope, parent)
    local condition = compileTossRest(ast[2], scope, parent)
    parent[#parent + 1] = 'while ' .. condition.expr[1] .. ' do'
    local len = ast.n or #asr
    local subScope = makeScope(scope)
    local subChunk = {}
    for i = 3, len do
        compileDo(ast[i], subScope, subChunk)
    end
    parent[#parent + 1] = subChunk
    parent[#parent + 1] = 'end'
end

SPECIALS['*dowhile'] = function(ast, scope, parent)
    local condition = compileTossRest(ast[2], scope, parent)
    parent[#parent + 1] = 'repeat'
    local subScope = makeScope(scope)
    local subChunk = {}
    for i = 3, ast.n do
        compileDo(ast[i], subScope, subChunk)
    end
    parent[#parent + 1] = subChunk
    parent[#parent + 1] = 'until ' .. condition.expr[1]
end

SPECIALS['*for'] = function(ast, scope, parent)
    local bindingSym = assert(isSym(ast[2]), 'expected symbol in *for')
    local ranges = assert(isTable(ast[3]), 'expected list table in *for')
    local rangeArgs = {}
    for i = 1, math.min(#ranges, 3) do
        rangeArgs[i] = compileTossRest(ranges[i], scope, parent).expr[1]
    end
    parent[#parent + 1] = ('for %s = %s do')
        :format(literalToString(bindingSym, scope), table.concat(rangeArgs, ', '))
    local chunk = {}
    local subScope = makeScope(scope)
    for i = 4, ast.n do
        compileDo(ast[i], subScope, chunk)
    end
    parent[#parent + 1] = chunk
    parent[#parent + 1] = 'end'
end

-- Do wee need this? Is there a more elegnant way to comile with break?
SPECIALS['*break'] = function(ast, scope, parent)
    parent[#parent + 1] = 'break'
end

local function defineArithmeticSpecial(name, unaryPrefix)
    local paddedOp = ' ' .. name .. ' '
    SPECIALS[name] = function(ast, scope, parent)
        local len = ast.n or #ast
        local head = {}
        if len == 0 then
            head.expr = list(unaryPrefix or '0')
        else
            local operands = list()
            local subSingleEval, sideEffects, scoped = false, false, false
            for i = 2, len do
                local subTree
                if i == len then
                    subTree = compileExpr(ast[i], scope, parent)
                else
                    subTree = compileTossRest(ast[i], scope, parent)
                end
                listAppend(operands, subTree.expr)
                if subTree.singleEval then subSingleEval = true end
                if subTree.sideEffects then sideEffects = true end
                if subTree.scoped then scoped = true end
            end
            head.sideEffects = sideEffects
            head.scoped = scoped
            if #operands == 1 and unaryPrefix then
                head.singleEval = true
                head.expr = list('(' .. unaryPrefix .. paddedOp .. operands[1] .. ')')
            else
                head.singleEval = #operands > 1 or subSingleEval
                head.expr = list('(' .. table.concat(operands, paddedOp) .. ')')
            end
        end
        return head
    end
end

defineArithmeticSpecial('+')
defineArithmeticSpecial('..')
defineArithmeticSpecial('^')
defineArithmeticSpecial('-', '')
defineArithmeticSpecial('*')
defineArithmeticSpecial('%')
defineArithmeticSpecial('/', 1)
defineArithmeticSpecial('or')
defineArithmeticSpecial('and')

local function defineComparatorSpecial(name, realop)
    local op = realop or name
    SPECIALS[name] = function(ast, scope, parent)
        local lhs = compileTossRest(ast[2], scope, parent)
        local rhs = compileTossRest(ast[3], scope, parent)
        return {
            sideEffects = lhs.sideEffects or rhs.sideEffects,
            singleEval = true,
            expr = list(('((%s) %s (%s))'):format(lhs.expr[1], op, rhs.expr[1])),
            scoped = lhs.scoped or rhs.scoped
        }
    end
end

defineComparatorSpecial('>')
defineComparatorSpecial('<')
defineComparatorSpecial('>=')
defineComparatorSpecial('<=')
defineComparatorSpecial('=', '==')
defineComparatorSpecial('~=')

local function defineUnarySpecial(op, realop)
    SPECIALS[op] = function(ast, scope, parent)
        local tail = compileTossRest(ast[2], scope, parent)
        return {
            singleEval = true,
            sideEffects = tail.sideEffects,
            expr = list((realop or op) .. tail.expr[1]),
            scoped = tail.scoped
        }
    end
end

defineUnarySpecial('not', 'not ')
defineUnarySpecial('#')

local function compileAst(ast, options)
    options = options or {}
    local scope = options.scope or makeScope(GLOBAL_SCOPE)
    return transpile(ast, scope, options)
end

local function compile(str, options)
    options = options or {}
    local asts, len = parse(str)
    local scope = options.scope or makeScope(GLOBAL_SCOPE)
    local bodies = {}
    for i = 1, len do
        local source = transpile(asts[i], scope, {
            returnTail = i == len
        })
        bodies[#bodies + 1] = source
    end
    return table.concat(bodies, '\n')
end

local function eval(str, options)
    options = options or {}
    local luaSource = compile(str, options)
    local loader = loadCode(luaSource, options.env)
    return loader()
end

-- Implements a simple repl
local function repl(options)
    local defaultPrompt = '>> '
    options = options or {}
    local env = options.env or setmetatable({}, {
        __index = _ENV or _G
    })
    while true do
        io.write(env._P or defaultPrompt)
        local reader = createReader(function()
            return io.read() .. '\n'
        end)
        local ok, err = pcall(parse, reader, function(x)
            x = list(sym('print'), x)
            local luaSource = compileAst(x, {
                returnTail = true
            })
            local loader, err = loadCode(luaSource, env)
            if err then
                print(err)
            else
                loader()
                io.write(env._P or defaultPrompt)
                io.flush()
            end
        end)
        if not ok then
            print(err)
        end
    end
end

SPECIALS['*compiler'] = function(ast, scope, parent)
    local source = ast[2]
    local luaSource = compileAst(source)
    luaSource = 'local _S, _M, _C, _A, __COMPILER_ENV__ = ...\n' .. luaSource
    local loader = loadCode(luaSource)
    loader(scope, scope.macros, parent, ast, true)
end

return {
    parse = parse,
    astToString = astToString,
    compile = compile,
    compileAst = compileAst,
    list = list,
    sym = sym,
    scope = makeScope,
    gensym = gensym,
    createReader = createReader,
    eval = eval,
    repl = repl
}
