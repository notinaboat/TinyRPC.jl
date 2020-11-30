# TinyRPC.jl

Simple Julia RPC protocol for situations where [`addprocs`](https://docs.julialang.org/en/v1/stdlib/Distributed) won't work. e.g. communication between machines with different architectures.

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
"Linux raspberrypi 5.4.51+ #1333 Mon Aug 10 16:38:02 BST 2020 armv6l GNU/Linux
"

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

