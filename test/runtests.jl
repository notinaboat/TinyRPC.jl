using Test
using TinyRPC

count = 0

function foo(x)
    global count
    count += x
    x
end

function bar(; extra="")
    return "BAR$extra"
end

echo(x) = x
echo(args...) = args

function delay()
    @info("delay start")
    sleep(2)
    @info("delay end")
    7
end



@testset "TinyRPC" begin

    port = 2000 + rand(UInt8)

    server, clients = TinyRPC.listen(;port=port)

    io = TinyRPC.connect("localhost"; port=port)

    r = TinyRPC.@remote io vcat([1, 2, 3], 4, 5, 6)
    @test r == [1, 2, 3, 4, 5, 6]

    r = TinyRPC.remote_call(io, :vcat, [1, 2, 3], 4, 5, 6)
    @test r == [1, 2, 3, 4, 5, 6]

    @show clients
    @show clients[1]
    r = TinyRPC.@remote clients[1] vcat([1, 2, 3], 4, 5, 6)
    @test r == [1, 2, 3, 4, 5, 6]

    r = TinyRPC.remote_call(clients[1], :vcat, [1, 2, 3], 4, 5, 6)
    @test r == [1, 2, 3, 4, 5, 6]

    global count
    count = 0
    r = TinyRPC.@remote io foo(7)
    @test r == 7
    @test count == 7

    r = TinyRPC.remote_call(io, :foo, 7)
    @test r == 7
    @test count == 14

    r = TinyRPC.@remote clients[1] foo(2)
    @test r == 2
    @test count == 16

    @test TinyRPC.remote_call(io, :bar) == "BAR"

    @test TinyRPC.remote_call(io, :echo, 7) == 7

    @test TinyRPC.remote_call(io, :echo, 1, 2, 3) == (1, 2, 3)

    @test TinyRPC.remote_call(io, :echo, :FOO) == :FOO

    @test TinyRPC.remote_call(io, :echo, "BAR") == "BAR"

    the_err = nothing
    @async try
        TinyRPC.remote_call(io, :delay)
    catch err
        @info "remote_call error", err
        the_err = err
    end
    sleep(0.2)
    close(io.io)
    sleep(0.2)
    @test the_err isa EOFError

    @test TinyRPC.remote_call(io, :echo, "BAR") == "BAR"
    @test TinyRPC.remote_call(io, :echo, 1, 2, 3) == (1, 2, 3)

    @test TinyRPC.remote_call(io, :bar) == "BAR"
    @test TinyRPC.remote_call(io, :bar; extra="_MORE") == "BAR_MORE"
end


module AMod

    using TinyRPC
    using Test

    module TheMod
        export mod_foo, mod_bar
        mod_foo(x) = "foo $x"
        mod_bar() = "bar"
    end

    port = 2001 + rand(UInt8)
    server, clients = TinyRPC.listen(;port=port, mod=TheMod)
    io = TinyRPC.connect("localhost"; port=port)

    TinyRPC.@remote_using io :TheMod

    @testset "TinyRPC remote_using" begin

        @test mod_bar() == "bar"
        @test mod_foo(8) == "foo 8"
        @test mod_foo("bar") == "foo bar"
    end
end
