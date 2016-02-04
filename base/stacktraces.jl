# This file is a part of Julia. License is MIT: http://julialang.org/license

module StackTraces


import Base: hash, ==, show
import Base.Serializer: serialize, deserialize

export StackTrace, StackFrame, stacktrace, catch_stacktrace

"""
    StackFrame

Stack information representing execution context.
"""
immutable StackFrame # this type should be kept platform-agnostic so that profiles can be dumped on one machine and read on another
    "the name of the function containing the execution context"
    func::Symbol
    "the path to the file containing the execution context"
    file::Symbol
    "the line number in the file containing the execution context"
    line::Int
    "the LambdaInfo containing the execution context (if it could be found)"
    linfo::Nullable{LambdaInfo}
    spec_sig
    "true if the code is from C"
    from_c::Bool
    inlined::Bool
    "representation of the pointer to the execution context as returned by `backtrace`"
    pointer::Int64  # Large enough to be read losslessly on 32- and 64-bit machines.
end

StackFrame(func, file, line) = StackFrame(func, Nullable{LambdaInfo}(), file, line, empty_sym, -1, false, 0)

"""
    StackTrace

An alias for `Vector{StackFrame}` provided for convenience; returned by calls to
`stacktrace` and `catch_stacktrace`.
"""
typealias StackTrace Vector{StackFrame}

const empty_sym = symbol("")
const unk_sym = symbol("???")
const UNKNOWN = StackFrame(unk_sym, unk_sym, -1, Nullable{LambdaInfo}(), nothing, false, false, -1) # === lookup(C_NULL)


#=
If the StackFrame has function and line information, we consider two of them the same if
they share the same function/line information. For unknown functions, line == pointer, so we
never actually need to consider the pointer field.
=#
function ==(a::StackFrame, b::StackFrame)
    a.line == b.line && a.from_c == b.from_c && a.func == b.func && a.file == b.file
end

function hash(frame::StackFrame, h::UInt)
    h += 0xf4fbda67fe20ce88 % UInt
    h = hash(frame.line, h)
    h = hash(frame.file, h)
    h = hash(frame.func, h)
end

# provide a custom serializer that skips attempting to serialize the `outer_linfo`
# which is likely to contain complex references, types, and module references
# that may not exist on the receiver end
function serialize(s::SerializationState, frame::StackFrame)
    Serializer.serialize_type(s, typeof(frame))
    serialize(s, frame.func)
    serialize(s, frame.file)
    serialize(s, frame.inlined_file)
    write(s.io, frame.line)
    write(s.io, frame.inlined_line)
    write(s.io, frame.from_c)
    write(s.io, frame.pointer)
end

function deserialize(s::SerializationState, ::Type{StackFrame})
    func = deserialize(s)
    file = deserialize(s)
    inlined_file = deserialize(s)
    line = read(s.io, Int64)
    inlined_line = read(s.io, Int64)
    from_c = read(s.io, Bool)
    pointer = read(s.io, Int64)
    return StackFrame(func, Nullable{LambdaInfo}(), file, line, inlined_file, inlined_line, from_c, pointer)
end


"""
    lookup(pointer::Union{Ptr{Void}, UInt}) -> StackFrame

Given a pointer to an execution context (usually generated by a call to `backtrace`), looks
up stack frame context information.
"""
function lookup(pointer::Ptr{Void})
    infos = ccall(:jl_lookup_code_address, Any, (Ptr{Void}, Cint), pointer - 1, false)
    res = Array(StackFrame, length(infos))
    for i in 1:length(infos)
        info = infos[i]
        if length(info) == 8
            li = info[4] === nothing ? Nullable{LambdaInfo}() : Nullable{LambdaInfo}(info[4])
            res[i] = StackFrame(info[1], info[2], info[3], li, info[5], info[6], info[7], info[8])
        else
            res[i] = UNKNOWN
        end
    end
    res
end

lookup(pointer::UInt) = lookup(convert(Ptr{Void}, pointer))

"""
    stacktrace([trace::Vector{Ptr{Void}},] [c_funcs::Bool=false]) -> StackTrace

Returns a stack trace in the form of a vector of `StackFrame`s. (By default stacktrace
doesn't return C functions, but this can be enabled.) When called without specifying a
trace, `stacktrace` first calls `backtrace`.
"""
function stacktrace(trace::Vector{Ptr{Void}}, c_funcs::Bool=false)
    stack = map(lookup, trace)::StackTrace

    # Remove frames that come from C calls.
    if !c_funcs
        filter!(frame -> !frame.from_c, stack)
    end

    # Remove frame for this function (and any functions called by this function).
    remove_frames!(stack, :stacktrace)
end

stacktrace(c_funcs::Bool=false) = stacktrace(backtrace(), c_funcs)

"""
    catch_stacktrace([c_funcs::Bool=false]) -> StackTrace

Returns the stack trace for the most recent error thrown, rather than the current execution
context.
"""
catch_stacktrace(c_funcs::Bool=false) = stacktrace(catch_backtrace(), c_funcs)

"""
    remove_frames!(stack::StackTrace, name::Symbol)

Takes a `StackTrace` (a vector of `StackFrames`) and a function name (a `Symbol`) and
removes the `StackFrame` specified by the function name from the `StackTrace` (also removing
all frames above the specified function). Primarily used to remove `StackTraces` functions
from the `StackTrace` prior to returning it.
"""
function remove_frames!(stack::StackTrace, name::Symbol)
    splice!(stack, 1:findlast(frame -> frame.func == name, stack))
    return stack
end

function remove_frames!(stack::StackTrace, names::Vector{Symbol})
    splice!(stack, 1:findlast(frame -> frame.func in names, stack))
    return stack
end

function show_spec_linfo(io::IO, frame::StackFrame)
    if isnull(frame.linfo)
        print(io, frame.func !== empty_sym ? frame.func : "?")
    else
        linfo = get(frame.linfo)
        params =
            if isdefined(linfo, 8)
                linfo.(#=specTypes=#8).parameters
            else
                frame.spec_sig
            end
        if params !== nothing
            ft = params[1]
            if ft <: Function && isempty(ft.parameters) &&
                    isdefined(ft.name.module, ft.name.mt.name) &&
                    ft == typeof(getfield(ft.name.module, ft.name.mt.name))
                print(io, ft.name.mt.name)
            elseif isa(ft, DataType) && is(ft.name, Type.name) && isleaftype(ft)
                f = ft.parameters[1]
                print(io, f)
            else
                print(io, "(::", ft, ")")
            end
            first = true
            print(io, '(')
            for i = 2:length(params)
                first || print(io, ", ")
                first = false
                print(io, "::", params[i])
            end
            print(io, ')')
        else
            print(io, linfo.name)
        end
    end
end

function show(io::IO, frame::StackFrame; full_path::Bool=false)
    print(io, " in ")
    show_spec_linfo(io, frame)
    file_info = full_path ? string(frame.file) : basename(string(frame.file))
    print(io, " at ", file_info, ":", frame.line)
    if frame.inlined
        print(io, " [inlined]")
    end
end

end
