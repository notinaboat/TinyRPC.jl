module TinyRPC

using Sockets
using Serialization



"""
    listen(;[port=2020])

Start eval server on TCP port...
"""
function listen(;port=2020)

    server = listen(IPv4(0), port)

    @async while true
        io = accept(server)
        @async while isopen(io)

            result = try
                eval(deserialize(io))
            catch err
                @show err
                err
            end

            try
                serialize(io, result)
            catch
                @show err
                close(io)
            end
        end
    end

    return server
end


"""
    remote(io, f, args...)

Execute `f(args...)` on remote node connected by `io`.
"""
function remote(io, f, args...)
    expr = :($f($(args...)))
    serialize(io, expr)
    deserialize(io)
end


"""
    @remote io, f(args...)

Execute `f(args...)` on remote node connected by `io`.
"""
macro remote(io, expr)
    @assert expr.head == :call
    f = QuoteNode(expr.args[1])
    args = expr.args[2:end]
    :(remote($io, $f, $(args...)))
end


end # module
