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
```

Client:
```julia
julia> using TinyRPC

julia> raspberry_pi = connect("192.168.0.173", 2020)

julia> @remote pi read(`uname -a`, String)
"Linux raspberrypi 5.4.51+ #1333 Mon Aug 10 16:38:02 BST 2020 armv6l GNU/Linux\n"

julia> @remote pi rand(UInt, 5)
5-element Array{UInt64,1}:
 0x3d6555e980075ade
 0x28e453c8348db9dd
 0xf82d7356f2b4e2a9
 0x4ac67cf676b0188a
 0xb5fcb87edf5935bb

julia> @remote pi write("/sys/class/gpio/gpio10/direction", "out")

julia> @remote pi write("/sys/class/gpio/gpio10/value", "1")
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

export @remote



using Sockets
using Serialization

include("RemotePtr.jl")


function tinyrpc_eval(io, expr, condition)
    result = try
        Main.eval(expr)
    catch err
        err
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
        @show err
        close(io)
    end
end


"""
    TinyRPC.listen(;[port=2020])::Tuple{TCPServer, Vector{TCPSocket}}

Start TinyRPC server on TCP port.

Returns the listening TCPServer and a Vector of connected clients.

```
julia> server, clients = TinyRPC.listen()
julia> while isempty(clients) sleep(1) end
julia> @remote clients[1] println("Hello")
```
"""
function listen(;port=2020)

    server = Sockets.listen(IPv4(0), port)
    clients = Sockets.TCPSocket[]

    @show typeof(server)

    @async try
        while true
            io = accept(server)
            push!(clients, io)
            @async tinyrpc_rx_loop(io)
        end
    catch err
        @show err
        close(server)
    end

    return (server, clients)
end


"""
    TinyRPC.connect(host;[port=2020])::TCPSocket

Connect to TinyRPC server.

```
julia> io = TinyRPC.connect("localhost")
julia> @remote io println("Hello")
```
"""
function connect(host; port=2020)
    io = Sockets.connect(host, port)
    @async tinyrpc_rx_loop(io)
    io
end


"""
    remote(io, f, args...)

Execute `f(args...)` on remote node connected by `io`.
"""
function remote(io, f, args...)
    expr = :($f($(args...)))
    @show expr
    b = IOBuffer()
    serialize(b, expr)

    call_complete = Ref(Condition())
    serialize(b, RemotePtr(call_complete))
    write(io, take!(b))

    GC.@preserve call_complete wait(call_complete[])
end


"""
    @remote io, f(args...)

Execute `f(args...)` on remote node connected by `io`.
"""
macro remote(io, expr)
    @assert expr.head == :call
    f = QuoteNode(expr.args[1])
    args = expr.args[2:end]
    :(remote($(esc(io)), $f, $(args...)))
end


end # module TinyRPC
