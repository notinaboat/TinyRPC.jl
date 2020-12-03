# TinyRPC.jl

Simple Julia RPC protocol for situations where [`addprocs`](https://docs.julialang.org/en/v1/stdlib/Distributed) won't work. e.g. communication between machines with different architectures.

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
"Linux raspberrypi 5.4.51+ #1333 Mon Aug 10 16:38:02 BST 2020 armv6l GNU/Linux
"

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

julia> TinyRPC.remote_eval(rpi, :(1 + sum([$x,2])))
10
```

## Opaque result pointers

Get a pointer to a large array on the remote node. Use it to access a few elements.

```julia
julia> rp = TinyRPC.remote_eval_ptr(rpi, :([i for i in 1:1_000_000]))
TinyRPC.RemotePtr{Array{Float64,1}}(0x00000000a66fe370, 0xbe910fa8)

julia> TinyRPC.remote_eval(rpi, :( ($rp[])[500:503]))
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
julia> TinyRPC.remote_include(rpi, """
    x = 7
    x * 2
""")
14
```

## Protocol

```
A -> B: serialize(io, ::Expr), serialize(io, ::RemotePtr{Condition})
```

A sends B an expression to evaluate and a pointer to a Condition to be notified when the result is ready.

A's task waits on the Condition.

B deserializes the expression and evaluates it.

```
B -> A: serialize(io, ::RemotePtr{Condition}), serialize(io, result)
```

B sends the Condition pointer back to A along with the result of the expression.

A notifies the the waiting task and passes it the result.

