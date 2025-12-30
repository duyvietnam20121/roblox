--!strict
--[[
    Rust 1.85.0 Ownership System for Roblox Studio (FIXED VERSION)
    
    CẤU TRÚC THƯ MỤC (đặt trong ReplicatedStorage):
    
    ReplicatedStorage/
    └── RustLib/
        └── init.lua (file này)
    
    CÁCH SỬ DỤNG:
    local Rust = require(game.ReplicatedStorage.RustLib)
    local value = Rust.Box.new(100)
]]

-- ============================================================================
-- Box<T> - Heap allocated value (như Box trong Rust)
-- ============================================================================

local Box = {}
Box.__index = Box

function Box.new(value)
    local self = setmetatable({}, Box)
    self._value = value
    self._moved = false
    self._id = tostring(self):gsub("table: ", "")
    return self
end

function Box:take()
    if self._moved then
        error("attempted to use a moved Box", 2)
    end
    
    local value = self._value
    self._value = nil
    self._moved = true
    return value
end

function Box:asRef()
    if self._moved then
        error("attempted to use a moved Box", 2)
    end
    if self._value == nil then
        error("attempted to use a nil Box", 2)
    end
    return self._value
end

function Box:asMut()
    if self._moved then
        error("attempted to use a moved Box", 2)
    end
    if self._value == nil then
        error("attempted to use a nil Box", 2)
    end
    return self._value
end

function Box:unwrap()
    return self:take()
end

function Box:isNone()
    return self._moved or self._value == nil
end

function Box:drop()
    self._value = nil
    self._moved = true
end

function Box:clone()
    if self._moved then
        error("cannot clone moved Box", 2)
    end
    
    local function deepCopy(original)
        if type(original) ~= "table" then
            return original
        end
        local copy = {}
        for k, v in pairs(original) do
            copy[k] = deepCopy(v)
        end
        return copy
    end
    
    return Box.new(deepCopy(self._value))
end

-- ============================================================================
-- Rc<T> - Reference Counted (như Rc trong Rust)
-- ============================================================================

local Rc = {}
Rc.__index = Rc

function Rc.new(value)
    local refCount = {count = 1}
    
    local self = setmetatable({}, Rc)
    self._value = value
    self._refCount = refCount
    self._id = tostring(self):gsub("table: ", "")
    return self
end

function Rc:clone()
    if not self._value and self._refCount.count == 0 then
        error("attempted to clone dropped Rc", 2)
    end
    
    local cloned = setmetatable({}, Rc)
    cloned._value = self._value
    cloned._refCount = self._refCount
    cloned._id = self._id
    
    self._refCount.count = self._refCount.count + 1
    return cloned
end

function Rc:strongCount()
    return self._refCount.count
end

function Rc:asRef()
    if self._refCount.count == 0 then
        error("attempted to use dropped Rc", 2)
    end
    return self._value
end

function Rc:drop()
    if self._refCount.count == 0 then
        return
    end
    
    self._refCount.count = self._refCount.count - 1
    
    if self._refCount.count == 0 then
        self._value = nil
    end
end

function Rc:tryUnwrap()
    if self._refCount.count == 1 then
        local value = self._value
        self:drop()
        return value
    end
    return nil
end

-- ============================================================================
-- RefCell<T> - Interior mutability (như RefCell trong Rust)
-- ============================================================================

local RefCell = {}
RefCell.__index = RefCell

local Ref = {}
Ref.__index = Ref

local RefMut = {}
RefMut.__index = RefMut

function RefCell.new(value)
    local self = setmetatable({}, RefCell)
    self._value = value
    self._borrowState = {
        immutableBorrows = 0,
        mutableBorrow = false,
    }
    return self
end

function RefCell:borrow()
    if self._borrowState.mutableBorrow then
        error("already mutably borrowed", 2)
    end
    
    self._borrowState.immutableBorrows = self._borrowState.immutableBorrows + 1
    
    local ref = setmetatable({}, Ref)
    ref._refCell = self
    ref._dropped = false
    return ref
end

function Ref:get()
    if self._dropped then
        error("attempted to use dropped Ref", 2)
    end
    return self._refCell._value
end

function Ref:clone()
    if self._dropped then
        error("attempted to use dropped Ref", 2)
    end
    return self._refCell:borrow()
end

function Ref:map(f)
    if self._dropped then
        error("attempted to use dropped Ref", 2)
    end
    return f(self._refCell._value)
end

function Ref:drop()
    if not self._dropped then
        self._refCell._borrowState.immutableBorrows = 
            self._refCell._borrowState.immutableBorrows - 1
        self._dropped = true
    end
end

function RefCell:borrowMut()
    if self._borrowState.immutableBorrows > 0 then
        error("already borrowed", 2)
    end
    
    if self._borrowState.mutableBorrow then
        error("already mutably borrowed", 2)
    end
    
    self._borrowState.mutableBorrow = true
    
    local refMut = setmetatable({}, RefMut)
    refMut._refCell = self
    refMut._dropped = false
    return refMut
end

function RefMut:get()
    if self._dropped then
        error("attempted to use dropped RefMut", 2)
    end
    return self._refCell._value
end

function RefMut:set(value)
    if self._dropped then
        error("attempted to use dropped RefMut", 2)
    end
    self._refCell._value = value
end

function RefMut:map(f)
    if self._dropped then
        error("attempted to use dropped RefMut", 2)
    end
    return f(self._refCell._value)
end

function RefMut:drop()
    if not self._dropped then
        self._refCell._borrowState.mutableBorrow = false
        self._dropped = true
    end
end

function RefCell:tryBorrow()
    if self._borrowState.mutableBorrow then
        return nil
    end
    return self:borrow()
end

function RefCell:tryBorrowMut()
    if self._borrowState.immutableBorrows > 0 or self._borrowState.mutableBorrow then
        return nil
    end
    return self:borrowMut()
end

function RefCell:into_inner()
    if self._borrowState.immutableBorrows > 0 or self._borrowState.mutableBorrow then
        error("cannot consume RefCell while borrowed", 2)
    end
    local value = self._value
    self._value = nil
    return value
end

function RefCell:get()
    return self._value
end

function RefCell:set(value)
    if self._borrowState.immutableBorrows > 0 or self._borrowState.mutableBorrow then
        error("cannot modify RefCell while borrowed", 2)
    end
    self._value = value
end

-- ============================================================================
-- Vec<T> - Dynamic array (như Vec trong Rust)
-- ============================================================================

local Vec = {}
Vec.__index = Vec

function Vec.new()
    local self = setmetatable({}, Vec)
    self._data = {}
    return self
end

function Vec.withCapacity(capacity)
    local self = Vec.new()
    table.create(capacity)
    return self
end

function Vec:push(value)
    table.insert(self._data, value)
end

function Vec:pop()
    if #self._data == 0 then
        return nil
    end
    return table.remove(self._data)
end

function Vec:len()
    return #self._data
end

function Vec:isEmpty()
    return #self._data == 0
end

function Vec:get(index)
    if index < 1 or index > #self._data then
        return nil
    end
    return self._data[index]
end

function Vec:set(index, value)
    if index < 1 or index > #self._data then
        error("index out of bounds", 2)
    end
    self._data[index] = value
end

function Vec:iter()
    local i = 0
    return function()
        i = i + 1
        if i <= #self._data then
            return i, self._data[i]
        end
        return nil, nil
    end
end

function Vec:clear()
    table.clear(self._data)
end

function Vec:remove(index)
    if index < 1 or index > #self._data then
        return nil
    end
    return table.remove(self._data, index)
end

function Vec:insert(index, value)
    if index < 1 or index > #self._data + 1 then
        error("index out of bounds", 2)
    end
    table.insert(self._data, index, value)
end

-- ============================================================================
-- Option<T> - Nullable type (như Option trong Rust)
-- ============================================================================

local Option = {}
Option.__index = Option

function Option.Some(value)
    local self = setmetatable({}, Option)
    self._value = value
    self._isSome = true
    return self
end

function Option.None()
    local self = setmetatable({}, Option)
    self._value = nil
    self._isSome = false
    return self
end

function Option:isSome()
    return self._isSome
end

function Option:isNone()
    return not self._isSome
end

function Option:unwrap()
    if not self._isSome then
        error("called `Option:unwrap()` on a `None` value", 2)
    end
    return self._value
end

function Option:unwrapOr(default)
    if self._isSome then
        return self._value
    end
    return default
end

function Option:expect(message)
    if not self._isSome then
        error(message, 2)
    end
    return self._value
end

function Option:map(f)
    if self._isSome then
        return Option.Some(f(self._value))
    end
    return Option.None()
end

-- ============================================================================
-- Result<T, E> - Error handling (như Result trong Rust)
-- ============================================================================

local Result = {}
Result.__index = Result

function Result.Ok(value)
    local self = setmetatable({}, Result)
    self._value = value
    self._error = nil
    self._isOk = true
    return self
end

function Result.Err(error)
    local self = setmetatable({}, Result)
    self._value = nil
    self._error = error
    self._isOk = false
    return self
end

function Result:isOk()
    return self._isOk
end

function Result:isErr()
    return not self._isOk
end

function Result:unwrap()
    if not self._isOk then
        error("called `Result:unwrap()` on an `Err` value: " .. tostring(self._error), 2)
    end
    return self._value
end

function Result:unwrapOr(default)
    if self._isOk then
        return self._value
    end
    return default
end

function Result:expect(message)
    if not self._isOk then
        error(message .. ": " .. tostring(self._error), 2)
    end
    return self._value
end

function Result:unwrapErr()
    if self._isOk then
        error("called `Result:unwrapErr()` on an `Ok` value", 2)
    end
    return self._error
end

-- ============================================================================
-- MAIN MODULE EXPORT
-- ============================================================================

local RustLib = {
    Box = Box,
    Rc = Rc,
    RefCell = RefCell,
    Vec = Vec,
    Option = Option,
    Result = Result,
}

-- ============================================================================
-- EXAMPLES / TESTS
-- ============================================================================

local function runExamples()
    print("=== Rust 1.85.0 Ownership System Demo (FIXED) ===\n")
    
    -- Box example
    print("--- Box<T> Example ---")
    local boxed = Box.new({name = "Roblox", value = 100})
    print("Boxed value:", boxed:asRef().name)
    local unboxed = boxed:unwrap()
    print("Unboxed:", unboxed.name)
    
    local success = pcall(function()
        print(boxed:asRef()) -- Sẽ fail vì đã unwrap
    end)
    print("✓ Cannot use moved Box:", not success)
    
    -- Rc example
    print("\n--- Rc<T> Example ---")
    local rc1 = Rc.new("Shared Data")
    local rc2 = rc1:clone()
    local rc3 = rc1:clone()
    print("Strong count:", rc1:strongCount())
    print("RC1 value:", rc1:asRef())
    print("RC2 value:", rc2:asRef())
    
    rc1:drop()
    print("After drop RC1, count:", rc2:strongCount())
    
    -- RefCell example (FIXED)
    print("\n--- RefCell<T> Example ---")
    local cell = RefCell.new({count = 0})
    
    local ref1 = cell:borrow()
    local ref2 = cell:borrow()
    print("Multiple immutable borrows OK:", ref1:get().count)
    ref1:drop()
    ref2:drop()
    
    local mutRef = cell:borrowMut()
    local value = mutRef:get()
    value.count = 10
    print("After mut borrow:", mutRef:get().count)
    mutRef:drop()
    
    -- Direct access (FIXED)
    print("Direct access:", cell:get().count)
    
    -- Vec example
    print("\n--- Vec<T> Example ---")
    local vec = Vec.new()
    vec:push(1)
    vec:push(2)
    vec:push(3)
    
    print("Vec length:", vec:len())
    for i, v in vec:iter() do
        print(string.format("  [%d] = %d", i, v))
    end
    
    print("Popped:", vec:pop())
    print("New length:", vec:len())
    
    -- Option example
    print("\n--- Option<T> Example ---")
    local some = Option.Some(42)
    local none = Option.None()
    
    print("Some value:", some:unwrap())
    print("None with default:", none:unwrapOr(0))
    
    -- Result example
    print("\n--- Result<T, E> Example ---")
    local function divide(a, b)
        if b == 0 then
            return Result.Err("division by zero")
        end
        return Result.Ok(a / b)
    end
    
    local ok = divide(10, 2)
    local err = divide(10, 0)
    
    print("10 / 2 =", ok:unwrap())
    print("10 / 0 is error:", err:isErr())
    print("10 / 0 with default:", err:unwrapOr(-1))
    
    print("\n=== Demo Complete ===")
end

-- Chạy examples (comment out khi dùng trong production)
runExamples()

return RustLib
