export unroll

type Delay
  name::Symbol
  default::Nullable{Param}
end

Delay(name) = Delay(name, nothing)

function liftloops!(ex, params)
  ex = Flow.normedges(ex)
  hidden = intersect((b.args[1] for b in ex.args), params)
  edges = Dict(h => gensym("edge") for h in hidden)
  declared = Dict(h => false for h in hidden)
  liftvar(s) = get(declared, s, false) ? s : get(edges, s, s)
  for b in ex.args
    b.args[2] = MacroTools.postwalk(liftvar, b.args[2])
    declared[b.args[1]] = true
  end
  for (h, e) in edges
    unshift!(ex.args, :($e = $(Delay(h))($h)))
  end
  return ex
end

function hasloops(model)
  g = graph(model)
  g == nothing && return false
  iscyclic(g) && return true
  result = false
  map(m -> hasloops(m) && (result = true), g)
  return result
end

function atomise(model)
  postwalk(graph(model)) do v
    hasloops(value(v)) || return v
    spliceinputs(atomise(value(v)), inputs(v)...)
  end
end

hiddeninput(n) = vertex(Split(n), inputnode(1))

function unroll!(delay::IVertex, n)
  prewalk!(delay[1]) do v
    v === delay ? hiddeninput(n) : v
  end
end

function break!(g::IVertex)
  g = bumpinputs(g)
  loops = []
  defaults = []
  g = prewalk!(g) do v
    isa(value(v), Delay) || return v
    n = length(loops)+1
    push!(loops, unroll!(v, n))
    push!(defaults, get(value(v).default))
    hiddeninput(n)
  end
  cse(group(group(loops...), g)), defaults
end

function unrollgraph(model, n)
  graph, defaults = break!(atomise(model))
  outputs = [spliceinputs(graph, group(map(constant, defaults)...), inputnode(1))]
  detuple(outputs[end])
  for i = 2:n
    push!(outputs, spliceinputs(graph, outputs[end][1], inputnode(i)))
  end
  state = outputs[end][1]
  outputs = map(x -> x[2], outputs)
  @> group(state, group(outputs...)) detuple
end

type Unrolled <: Model
  model
  graph::IVertex{Any}
  steps::Int
end

graph(u::Unrolled) = u.graph

unroll(model, n) = Unrolled(model, unrollgraph(model, n), n)

@net type Recurrent
  Wxh; Whh; Why
  bh; by
  hidden
  function (x)
    hidden = σ( x * Wxh + hidden * Whh + bh )
    y = hidden * Why + by
  end
end

Recurrent(in::Integer, hidden::Integer, out::Integer; init = initn) =
  Recurrent(initn((in, hidden)), initn((hidden, hidden)), initn((hidden, out)),
            initn(hidden), initn(out), zeros(Float32, hidden)')

# syntax′(x) = syntax(Flow.dl(x), bindconst = true)

# r = Recurrent(10, 30, 20)
# unrollgraph(r,5) |> cse |> syntax′ |> prettify |> display
