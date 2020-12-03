# FIXME temporary copy/paste from:
# https://github.com/FluxML/MacroTools.jl/blob/master/src/utils.jl#L55-L87

isexpr(x::Expr) = true
isexpr(x) = false
isexpr(x::Expr, ts...) = x.head in ts
isexpr(x, ts...) = any(T->isa(T, Type) && isa(x, T), ts)

isline(ex) = isexpr(ex, :line) || isa(ex, LineNumberNode)

rmlines(x) = x
function rmlines(x::Expr)
  # Do not strip the first argument to a macrocall, which is
  # required.
  if x.head == :macrocall && length(x.args) >= 2
    Expr(x.head, x.args[1], nothing, filter(x->!isline(x), x.args[3:end])...)
  else
    Expr(x.head, filter(x->!isline(x), x.args)...)
  end
end

striplines(ex) = prewalk(rmlines, ex)

walk(x, inner, outer) = outer(x)
walk(x::Expr, inner, outer) = outer(Expr(x.head, map(inner, x.args)...))
prewalk(f, x)  = walk(f(x), x -> prewalk(f, x), identity)
