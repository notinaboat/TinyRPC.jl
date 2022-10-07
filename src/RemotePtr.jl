const UIntPtr = Sys.WORD_SIZE == 64 ? UInt64 : UInt32

cookie = UInt32(0)


"""
    RemotePtr(ref::Ref{T})

Serializable pointer to a Julia object.

```
julia> c = RemotePtr(Ref(7))
julia> c[]
7
```

The Julia `serialize` function [stores pointers as zero](https://github.com/JuliaLang/julia/blob/08a233ddac2c0bcb07ca8a66792e8305a6124d3c/stdlib/Serialization/src/Serialization.jl#L727-L728).

RemotePtr converts a pointer to UInt64 so that it survives serialization.
A serialized RemotePtr can be stored in a file, or sent to a remote process.
A random cookie ensures that a pointer can only be dereferenced by
the process that created it.
"""
struct RemotePtr{T}
    p::UInt64
    cookie::UInt32
    function RemotePtr(o::Ref{T}) where T
        global cookie
        if cookie == 0
            cookie = rand(UInt32)
        end
        new{T}(convert(UInt64, pointer_from_objref(o)), cookie)
    end
end


function Base.getindex(rp::RemotePtr{T}) where T
    rp.cookie == cookie ||
        throw(ArgumentError("RemotePtr not valid on this node."))
    p = convert(Ptr{Ref{T}}, convert(UIntPtr, rp.p))
    ref = unsafe_pointer_to_objref(p)
    ref isa Ref{T} ||
        throw(ArgumentError("RemotePtr type error: $(typeof(ref)) != Ref{$T}"))
    ref[]
end
