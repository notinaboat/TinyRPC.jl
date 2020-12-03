"""
# TinyRPC.jl

Simple Julia RPC protocol for situations where
[`addprocs`](https://docs.julialang.org/en/v1/stdlib/Distributed)
won't work. e.g. communication between machines with different architectures.


## Installation

```julia
pkg> add https://github.com/notinaboat/TinyRPC.jl
```


## Simple example


Server:
```julia
julia> using TinyRPC: remote

julia> server, clients = TinyRPC.listen(port=2020)

julia> while isempty(clients) sleep(1) end

julia> remote(clients[1], println)("Hello")
```

Client:
```julia
julia> using TinyRPC: remote

julia> rpi = TinyRPC.connect("raspberrypi.local"; port=2020)

julia> TinyRPC.remote(rpi, read)(`uname -a`, String)
"Linux raspberrypi 5.4.51+ #1333 Mon Aug 10 16:38:02 BST 2020 armv6l GNU/Linux\n"

julia> rpi_rand = TinyRPC.remote(rpi, rand)

julia> rpi_rand(UInt, 5)
5-element Array{UInt64,1}:
 0x3d6555e980075ade
 0x28e453c8348db9dd
 0xf82d7356f2b4e2a9
 0x4ac67cf676b0188a
 0xb5fcb87edf5935bb

julia> rpi_write = TinyRPC.remote(rpi, write)

julia> rpi_write("/sys/class/gpio/gpio10/direction", "out")

julia> rpi_write("/sys/class/gpio/gpio10/value", "1")
```

## Execute a Julia expression on a remote node.

```
julia> x = 7

julia> TinyRPC.remote_eval(rpi, :(1 + sum([\$x,2])))
10
```


## Opaque result pointers

Get a pointer to a large array on the remote node.
Use it to access a few elements.

```julia
julia> rp = TinyRPC.remote_eval_ptr(rpi, :([i for i in 1:1_000_000]))
TinyRPC.RemotePtr{Array{Float64,1}}(0x00000000a66fe370, 0xbe910fa8)

julia> TinyRPC.remote_eval(rpi, :( (\$rp[])[500:503]))
4-element Array{Int64,1}:
 500
 501
 502
 503

julia> rp[]
ERROR: ArgumentError: RemotePtr not valid on this node.

julia> TinyRPC.free(rpi, rp)
```

## Execute Julia code from a String.

```
julia> TinyRPC.remote_include(rpi, \"\"\"
    x = 7
    x * 2
\"\"\")
14
```

## Protocol

    A -> B: serialize(io, ::Expr), serialize(io, ::RemotePtr{Condition})

A sends B an expression to evaluate and a pointer to a Condition
to be notified when the result is ready.

A's task waits on the Condition.

B deserializes the expression and evaluates it.

    B -> A: serialize(io, ::RemotePtr{Condition}), serialize(io, result)

B sends the Condition pointer back to A along with the result of the expression.

A notifies the the waiting task and passes it the result.
"""
module TinyRPC



using Sockets
using Serialization

include("RemotePtr.jl")
include("macroutils.jl") # See "FIXME" below...


struct TinyRPCSocket
    io::Sockets.TCPSocket
    name::String
    mod::Module
    refs::Dict{RemotePtr,Ref}
    parent::Vector{TinyRPCSocket}
    function TinyRPCSocket(io, mod, parent=[])
        name = getnameinfo(getpeername(io)[1])
        new(io, name, mod, Dict{RemotePtr,Ref}(), parent)
    end
end

Base.isopen(io::TinyRPCSocket) = isopen(io.io)
Base.write(io::TinyRPCSocket, x) = write(io.io, x)
Serialization.serialize(io::TinyRPCSocket, x) = serialize(io.io, x)
Serialization.deserialize(io::TinyRPCSocket) = deserialize(io.io)
function Base.close(io::TinyRPCSocket)
    empty!(io.refs)
    filter!(x->x!=io, io.parent)
    close(io.io)
end


function tinyrpc_eval(io, expr, condition)
    result = try
        io.mod.eval(:(let _io=$io; $expr end))
    catch err
        b = IOBuffer()
        showerror(b, err, catch_backtrace())
        ErrorException("TinyRPC eval error: " * String(take!(b)))
    end
    b = IOBuffer()
    serialize(b, condition)
    serialize(b, result)
    write(io, take!(b))
end


function tinyrpc_rx_loop(io)
    try
        while isopen(io)
            a = deserialize(io)
            b = deserialize(io)
            if a isa Expr
                @async tinyrpc_eval(io, a, b)
            else
                @assert a isa RemotePtr
                notify(a[], b)
            end
        end
    catch err
        if err isa EOFError
            println("TinyRPC Disconnected: ", io.name)
        else
            showerror(stdout, err, catch_backtrace())
        end
        close(io)
    end
end


"""
    TinyRPC.listen(; port=2020, mod=Main)

Start TinyRPC server on TCP port.

Returns `::Tuple{TCPServer, Vector{TinyRPCSocket}}`
the listening TCPServer and a Vector of connected clients.

If `mod=` is specified then remote calls from the client are evaluated in
that local module.
```
julia> server, clients = TinyRPC.listen()
julia> while isempty(clients) sleep(1) end
julia> @remote clients[1] println("Hello")
```
"""
function listen(;port=2020, mod=Main)

    server = Sockets.listen(IPv4(0), port)
    clients = TinyRPCSocket[]

    @async try
        while true
            tcp = accept(server)
            io = TinyRPCSocket(tcp, mod, clients)
            println("TinyRPC Connected: ", io.name)
            push!(clients, io)
            @async tinyrpc_rx_loop(io)
        end
    catch err
        showerror(stdout, err, catch_backtrace())
        close(server)
    end

    return (server, clients)
end


"""
    TinyRPC.connect(host; port=2020, mod=Main)::TCPSocket

Connect to TinyRPC server.

If `mod=` is specified then remote callbacks from the server are evaluated
that local module.

```
julia> io = TinyRPC.connect("localhost")
julia> @remote io println("Hello")
```
"""
function connect(host; port=2020, mod=Main)
    io = TinyRPCSocket(Sockets.connect(host, port), mod)
    @async tinyrpc_rx_loop(io)
    io
end


"""
    remote_call(io, f, args...)

Execute `f(args...)` on remote TinyRPC node connected by `io`.
"""
remote_call(io, f, args...) = remote_eval(io, :($f($(args...))))


"""
    remote_inclue(io, string)

Evaluate `string` as Julia expression on remote TinyRPC node connected by `io`.
"""
remote_include(io, expr) = remote_eval(io, :(include_string(_io.mod,$expr)))


"""
    remote_eval(io, expr)

Evaluate `expr` on remote TinyRPC node connected by `io`.
"""
function remote_eval(io, expr)

    b = IOBuffer()
    serialize(b, expr)

    call_complete = Ref(Condition())
    serialize(b, RemotePtr(call_complete))
    write(io, take!(b))

    result = GC.@preserve call_complete wait(call_complete[])
    if result isa Exception
        throw(result)
    end
    result
end


"""
    remote_eval_ptr(io, expr)::RemotePtr

Evaluate `expr` on remote TinyRPC node connected by `io`.
Wrap the result in an opaque `RemotePtr`.
See: [`free`](@ref)
"""
function remote_eval_ptr(io, expr)
    remote_eval(io, striplines(:(begin
        r = Ref($expr)
        rp = TinyRPC.RemotePtr(r)
        _io.refs[rp] = r
        rp
    end)))
end
# FIXME
# Striplines is needed because LinNumberNode ueses Int instead of Int32:
# https://github.com/JuliaLang/julia/blob/2e3364e02f1dc3777926590c5484e7342bc0285d/src/jltypes.c#L2061

"""
    free(::RemotePtr)

Release a RemotePtr returned by [`remote_eval_ptr`](@ref).
"""
function free(io, rp)
    remote_eval(io, striplines(:( delete!(_io.refs, $rp); nothing )))
end


"""
    remote(io, f) -> Function

Return an anonymous function that executes function f
on remote TinyRPC node connected by `io`
"""
remote(io, f) = (args...)->remote_call(io, f, args...)


"""
    @remote(io, f(args...))

Execute `f(args...)` on remote node connected by `io`.
"""
macro remote(io, expr)
    @assert expr.head == :call
    f = QuoteNode(expr.args[1])
    args = expr.args[2:end]
    :(remote_call($(esc(io)), $f, $(args...)))
end


end # module TinyRPC
