using Logging

struct ChannelLogger <: AbstractLogger
    c::Channel{Tuple}
    ChannelLogger() = new(Channel{Tuple}(1000))
end

Base.take!(l::ChannelLogger) = take!(l.c)
Base.isready(l::ChannelLogger) = isready(l.c)

Logging.shouldlog(::ChannelLogger, args...) = true
Logging.min_enabled_level(::ChannelLogger) = Logging.Debug
Logging.catch_exceptions(::ChannelLogger) = false

function Logging.handle_message(l::ChannelLogger, args...; kw...) 
    if length(l.c.data) >= l.c.sz_max
        take!(l.c)
    end
    put!(l.c, (args, kw))
end
