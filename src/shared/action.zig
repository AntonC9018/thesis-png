fn MaybeConst(Self: type, Result: type) type
{
    const info = @typeInfo(Self);
    if (info.Pointer.is_const)
    {
        return *const Result;
    }
    else
    {
        return *Result;
    }
}

pub fn InitiableThroughPointer(ActionType: type) type
{
    return struct
    {
        key: *ActionType,
        initialized: *bool,

        const Self = @This();

        pub fn keyPointer(self: anytype) MaybeConst(@TypeOf(self), ActionType)
        {
            return self.key;
        }
        pub fn initializedPointer(self: anytype) MaybeConst(@TypeOf(self), bool)
        {
            return self.initialized;
        }
    };
}

pub fn Initiable(KeyType: type) type
{
    return struct
    {
        key: KeyType,
        initialized: bool = false,

        const Self = @This();

        pub fn keyPointer(self: anytype) MaybeConst(@TypeOf(self), KeyType)
        {
            return &self.key;
        }
        pub fn initializedPointer(self: anytype) MaybeConst(@TypeOf(self), bool)
        {
            return &self.initialized;
        }
        pub fn reset(self: *Self, key: KeyType) void
        {
            self.initialized = false;
            self.key = key;
        }
    };
}

pub fn initState(
    returnOnInit: bool,
    initialized: *bool) !void
{
    if (initialized.*)
    {
        return;
    }

    initialized.* = true;

    if (returnOnInit)
    {
        return error.StateInitialized;
    }
}

pub fn initStateForAction(
    context: anytype,
    returnOnInit: bool,
    // see common.Initiable
    action: anytype,
    // fn(*const Context, @TypeOf(action.key)) anyerror!void
    initialize: anytype) !void
{
    if (@typeInfo(@TypeOf(action)) != .Pointer)
    {
        @compileLog("Action must be passed by reference");
    }

    if (action.initializedPointer().*)
    {
        return;
    }

    if (@hasDecl(@TypeOf(initialize), "execute"))
    {
        try initialize.execute();
    }
    else if (@TypeOf(initialize) != void)
    {
        try initialize(context, action.keyPointer());
    }

    action.initializedPointer().* = true;

    if (returnOnInit)
    {
        return error.StateInitialized;
    }
}
