using Logging

struct ChannelLogger <: AbstractLogger
    c::Channel{Tuple}
    timestamp::Bool
    ChannelLogger(;timestamp=true) = new(Channel{Tuple}(1000), timestamp)
end

const collect_max = 10

function collect_channel(c::AbstractChannel{T}) where T
    v = Vector{T}()
    push!(v, take!(c))
    while !isempty(c) && length(v) < collect_max
        push!(v, take!(c))
    end
    return v
end

Base.collect(l::ChannelLogger) = collect_channel(l.c)
Base.take!(l::ChannelLogger) = take!(l.c)
Base.isready(l::ChannelLogger) = isready(l.c)
Base.isempty(l::ChannelLogger) = isempty(l.c)
drain!(l::ChannelLogger) = while !isempty(l) ; take!(l) ; end

Logging.shouldlog(::ChannelLogger, args...) = true
Logging.min_enabled_level(::ChannelLogger) = Logging.Debug
Logging.catch_exceptions(::ChannelLogger) = false

log_squash(v::Union{Integer,Float64,Bool}) = v
log_squash(v) = string(v)

function Logging.handle_message(l::ChannelLogger,
                                level, message, _module, group, id, file, line;
                                timestamp=nothing, kw...) 

    # To avoid feedback loops,
    # don't put TinyRPC Debug logs in the remote logging channel
    if _module == TinyRPC && level < Logging.Info
        return
    end

    # Dump oldest etries if the buffer is full.
    if length(l.c.data) >= l.c.sz_max
        take!(l.c)
    end

    # Convert the kw args into a Vector.
    kwv = Pair{Symbol,Any}[Symbol(k) => log_squash(v) for (k, v) in kw]

    # Add a timestamp.
    if l.timestamp && timestamp == nothing
        timestamp == time()
    end
    if timestamp != nothing
        push!(kwv, :timestamp => timestamp)
    end


    # Convert args to basic types.
    put!(l.c, ((LogLevel(level),
                string(message),
                string(_module),
                string(group),
                Symbol(id),
                string(file),
                Int32(line)),
                kwv))
end
