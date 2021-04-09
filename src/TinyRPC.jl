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
julia> using TinyRPC

julia> server, clients = TinyRPC.listen(port=2020)

julia> while isempty(clients) sleep(1) end

julia> TinyRPC.remote(clients[1], println)("Hello")
```

Client:
```julia
julia> using TinyRPC

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
using Retry
using ZeroConf


include("RemotePtr.jl")
include("ChannelLogger.jl")
include("macroutils.jl") # See "FIXME" below...


mutable struct TinyRPCSocket
    io::Sockets.TCPSocket
    host::String
    port::UInt16
    mod::Module
    refs::Dict{RemotePtr,Ref}
    waiting::Dict{Ref{Condition}, Any}
    parent::Union{Nothing,Vector{TinyRPCSocket}}
    function TinyRPCSocket(io::IO, mod, parent)
        host, port = getpeername(io)
        new(io,
            getnameinfo(host), port,
            mod,
            Dict{RemotePtr,Ref}(),
            Set{Ref{Condition}}(),
            parent)
    end
    TinyRPCSocket(host, port, mod) =
        TinyRPCSocket(Sockets.connect(host, port), mod, nothing)
end

isclient(io::TinyRPCSocket) = io.parent == nothing

struct TinyRPCError
    msg::String
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
Base.show(io::IO, s::TinyRPCSocket) =
    print(io, "TinyRPCSocket(", s.host, ",", s.port, ",", s.mod, ") ",
              length(s.waiting), " waiting.")

function tinyrpc_eval(io, expr, condition)
    result = try
        if expr isa Tuple{Symbol,Tuple}
            f, (args, kw) = expr
            getfield(io.mod, f)(args...; kw...)
        else
            @assert expr isa Expr
            io.mod.eval(:(let _io=$io; $expr end))
        end
    catch err
        b = IOBuffer()
        showerror(b, err, catch_backtrace())
        TinyRPCError("TinyRPC eval error: " * String(take!(b)))
    end
    try
        b = IOBuffer()
        serialize(b, condition)
        serialize(b, result)
        write(io, take!(b))
    catch err
        for c in keys(io.waiting)
            notify(c[], err; error=true)
        end
        close(io)
        if err isa Base.IOError
            @warn err
        else
            exception=(err, catch_backtrace())
            @error "Error sending TinyRPC message." exception
        end
    end
    nothing
end


function tinyrpc_rx_loop(io)
    try
        while isopen(io)
            a = deserialize(io)
            b = deserialize(io)
            if a isa RemotePtr
                call_complete = a[]
                notify(call_complete, b)
            else
                @async tinyrpc_eval(io, a, b)
            end
        end
    catch err
        if err isa EOFError
            @warn "Disconnected: $io"
            for c in keys(io.waiting)
                notify(c[], err; error=true)
            end
        else
            exception=(err, catch_backtrace())
            @error "Error reading TinyRPC message" exception io.waiting
        end
        close(io)
    end
end

function tinyrpc_tx(io, expr)

    @repeat 8 try

        if !isopen(io.io)
            @info "Reconnecting $io"
            io.io = Sockets.connect(io.host, io.port)
            @async tinyrpc_rx_loop(io)
        end

        b = IOBuffer()
        serialize(b, expr)

        call_complete = Ref(Condition())
        io.waiting[call_complete] = expr
        result = try
            serialize(b, RemotePtr(call_complete))
            write(io, take!(b))
            wait(call_complete[])
        finally
            delete!(io.waiting, call_complete)
        end

        if result isa TinyRPCError
            throw(ErrorException(result.msg))
        end
        return result

    catch err
        @delay_retry if isclient(io) && err isa Base.IOError
            close(io.io)
        end
    end
end


"""
    TinyRPC.listen(; port=2020, mod=Main, service_name=nothing)

Start TinyRPC server on TCP port.

Returns `::Tuple{TCPServer, Vector{TinyRPCSocket}}`
the listening TCPServer and a Vector of connected clients.

If `mod=` is specified then remote calls from the client are evaluated in
that local module.

If `service_name` is specified a DNS-SD Service is registered.
```
julia> server, clients = TinyRPC.listen()
julia> while isempty(clients) sleep(1) end
julia> @remote clients[1] println("Hello")
```
"""
function listen(;port=2020, mod=Main, service_name=nothing)

    if service_name == nothing
        server = Sockets.listen(IPv4(0), port)
    else
        port, server = Sockets.listenany(IPv4(0), port)
    end
    clients = TinyRPCSocket[]

    @async try
        while true
            tcp = accept(server)
            io = TinyRPCSocket(tcp, mod, clients)
            @info "Connected: $io"
            push!(clients, io)
            @async tinyrpc_rx_loop(io)
        end
    catch err
        showerror(stdout, err, catch_backtrace())
        close(server)
    end

    if service_name != nothing
        register_dns_service(service_name, "_tinyrpc._tcp", port)
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
    io = TinyRPCSocket(host, port, mod)
    @async tinyrpc_rx_loop(io)
    io
end


"""
    TinyRPC.connect(host; port=2020, mod=Main)::TCPSocket

Connect to TinyRPC server using DNS-SD `service_name`.
"""
function connect_service(service_name=nothing; mod=Main)
    services = dns_service_browse("_tinyrpc._tcp")
    while isopen(services)
        name, (host, port) = take!(services)
        if name == service_name
            close(services)
            return connect(host; port=port, mod=mod)
        end
    end
    throw(ErrorExcpetion("DNS Service \"$service_name\" not found."))
end


"""
    remote_call(io, f, args...)

Execute `f(args...)` on remote TinyRPC node connected by `io`.
"""
remote_call(io, f, args...; kw...) = tinyrpc_tx(io, (f, (args, kw)))


"""
    remote_inclue(io, string)

Evaluate `string` as Julia expression on remote TinyRPC node connected by `io`.
"""
remote_include(io, expr) = remote_eval(io, :(include_string(_io.mod,$expr)))


"""
    remote_eval(io, expr)

Evaluate `expr` on remote TinyRPC node connected by `io`.
"""
remote_eval(io, expr::Expr) = tinyrpc_tx(io, striplines(expr)) # FIXME
# Striplines is needed because LinNumberNode ueses Int instead of Int32:
# https://github.com/JuliaLang/julia/blob/2e3364e02f1dc3777926590c5484e7342bc0285d/src/jltypes.c#L2061
# https://github.com/JuliaLang/julia/commit/77fc71c604f3d28cb62ec6b8c7104e0a497f2106#diff-882927c6e612596e22406ae0d06adcee88a9ec05e8b61ad81b48942e2cb266e9R2191


"""
    remote_eval_ptr(io, expr)::RemotePtr

Evaluate `expr` on remote TinyRPC node connected by `io`.
Wrap the result in an opaque `RemotePtr`.
See: [`free`](@ref)
"""
function remote_eval_ptr(io, expr)
    remote_eval(io, (:(begin
        r = Ref($expr)
        rp = TinyRPC.RemotePtr(r)
        _io.refs[rp] = r
        rp
    end)))
end


"""
    free(::RemotePtr)

Release a RemotePtr returned by [`remote_eval_ptr`](@ref).
"""
function free(io, rp)
    remote_eval(io, :( delete!(_io.refs, $rp); nothing ))
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


function remote_names(io, mod)
    filter(x->x != mod, remote_eval(io, Expr(:call, :names, mod)))
end

macro remote_using(io, mod)
    esc(quote
        for f in TinyRPC.remote_names($io, $mod)
            call = :(TinyRPC.remote_call($$io, $(Meta.quot(f)), args...; kw...))
            @debug "remote_using: $f() => $($io)"
            eval(:($f(args...; kw...) = $call))
        end
    end)
end


end # module TinyRPC
