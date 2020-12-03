using Test
using TinyRPC

count = 0

function foo(x)
    global count
    count += x
    x
end


@testset "TinyRPC" begin

    port = 2000 + rand(UInt8)

    server, clients = TinyRPC.listen(;port=port)

    io = TinyRPC.connect("localhost"; port=port)

    r = TinyRPC.@remote io vcat([1, 2, 3], 4, 5, 6)
    @test r == [1, 2, 3, 4, 5, 6]
    @show clients
    @show clients[1]
    r = TinyRPC.@remote clients[1] vcat([1, 2, 3], 4, 5, 6)
    @test r == [1, 2, 3, 4, 5, 6]

    global count
    count = 0
    r = TinyRPC.@remote io foo(7)
    @test r == 7
    @test count == 7

    r = TinyRPC.@remote clients[1] foo(2)
    @test r == 2
    @test count == 9
end
