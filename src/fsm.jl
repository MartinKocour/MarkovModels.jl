# SPDX-License-Identifier: MIT

const PdfIndex = Union{Int,Nothing}
const Label = Union{AbstractString,Nothing}

mutable struct State{T<:Semifield}
    id::Int
    initweight::T
    finalweight::T
    pdfindex::PdfIndex
    label::Label
end

isinit(s::State{T}) where T = s.initweight ≠ zero(T)
isfinal(s::State{T}) where T = s.finalweight ≠ zero(T)
islabeled(s::State) = ! isnothing(s.label)
isemitting(s::State)  = ! isnothing(s.pdfindex)
setinit!(s::State{T}, weight::T = one(T)) where T = s.initweight = weight
setfinal!(s::State{T}, weight::T = one(T)) where T = s.finalweight = weight

mutable struct Arc{T<:Semifield}
    dest::State
    weight::T
end

"""
    struct FSM{T<:Semifield}
        states # vector of states
        arcs # Dict state -> vector of arcs
    end

Probabilistic finite state machine.
"""
struct FSM{T<:Semifield}
    states::Vector{State{T}}
    arcs::Dict{State, Vector{Arc{T}}}
end
FSM{T}() where T = FSM{T}(State{T}[], Dict{State, Vector{Arc{T}}}())
FSM() = FSM{LogSemifield{Float64}}()

states(fsm::FSM) = fsm.states
arcs(fsm::FSM{T}, state::State{T}) where T = get(fsm.arcs, state, Arc{T}[])
@deprecate links(fsm, state) arcs(fsm, state)

function addstate!(fsm::FSM{T}; initweight = zero(T), finalweight = zero(T),
                   pdfindex = nothing, label = nothing) where T
    s = State(length(fsm.states)+1, initweight, finalweight, pdfindex, label)
    push!(fsm.states, s)
    s
end

function addarc!(fsm::FSM{T}, src::State{T}, dest::State{T}, weight::T = one(T)) where T
    list = get(fsm.arcs, src, Arc{T}[])
    arc = Arc{T}(dest, weight)
    push!(list, arc)
    fsm.arcs[src] = list
    arc
end
@deprecate link!(fsm, src, dest) addarc!(fsm, src, dest)
@deprecate link!(fsm, src, dest, weight) addarc!(fsm, src, dest, weight)

function Base.show(io::IO, fsm::FSM)
    nstates = length(fsm.states)
    narcs = sum(length, values(fsm.arcs))
    print(io, "$(typeof(fsm)) # states: $nstates # arcs: $narcs")
end

function Base.show(io::IO, ::MIME"image/svg+xml", fsm::FSM)
    dotpath, dotfile = mktemp()
    svgpath, svgfile = mktemp()

    write(dotfile, "Digraph {\n")
    write(dotfile, "rankdir=LR;")

    for s in states(fsm)
        name = "$(s.id)"
        label = islabeled(s) ? "$(s.label)" : "ϵ"
        label *= isemitting(s) ? ":$(s.pdfindex)" : ":ϵ"
        if s.initweight ≠ zero(typeof(s.initweight))
            weight = round(convert(Float64, s.initweight), digits = 3)
            label *= "/$(weight)"
        end
        if s.finalweight ≠ zero(typeof(s.finalweight))
            weight = round(convert(Float64, s.finalweight), digits = 3)
            label *= "/$(weight)"
        end
        attrs = "shape=" * (isfinal(s) ? "doublecircle" : "circle")
        attrs *= " penwidth=" * (isinit(s) ? "2" : "1")
        attrs *= " label=\"" * label * "\""
        attrs *= " style=filled fillcolor=" * (isemitting(s) ? "lightblue" : "none")
        write(dotfile, "$name [ $attrs ];\n")
    end

    for src in states(fsm)
        for arc in arcs(fsm, src)
            weight = round(convert(Float64, arc.weight), digits = 3)
            srcname = "$(src.id)"
            destname = "$(arc.dest.id)"
            write(dotfile, "$srcname -> $destname [ label=\"$(weight)\" ];\n")
        end
    end
    write(dotfile, "}\n")
    close(dotfile)
    run(`dot -Tsvg $(dotpath) -o $(svgpath)`)

    xml = read(svgfile, String)
    write(io, xml)

    close(svgfile)

    rm(dotpath)
    rm(svgpath)
end

#======================================================================
FSM operations
======================================================================#

"""
    union(fsm1, fsm2, ...)

Merge all the fsms into a single one.
"""
function Base.union(fsm1::FSM{T}, fsm2::FSM{T}) where T
    allstates = union(states(fsm1), states(fsm2))
    newfsm = FSM{T}()

    smap = Dict()
    for state in allstates
        smap[state] = addstate!(newfsm, label = state.label,
                                pdfindex = state.pdfindex,
                                initweight = state.initweight,
                                finalweight = state.finalweight)
    end

    for src in states(fsm1)
        for arc in arcs(fsm1, src)
            arc!(newfsm, smap[src], smap[arc.dest], arc.weight)
        end
    end

    for src in states(fsm2)
        for arc in arcs(fsm2, src)
            addarc!(newfsm, smap[src], smap[arc.dest], arc.weight)
        end
    end

    newfsm
end
Base.union(f::FSM{T}, o::FSM{T}...) where T = foldl(union, o, init = f)

"""
    renormalize!(fsm)

Ensure the that all the weights of all the outgoing arcs leaving a
state sum up to 1.
"""
function renormalize!(fsm::FSM{T}) where T
    total = zero(T)
    for s in filter(isinit, states(fsm)) total += s.initweight end
    for s in filter(isinit, states(fsm)) s.initweight /= total end

    for src in states(fsm)
        total = src.finalweight
        for arc in arcs(fsm, src) total += arc.weight end
        for arc in arcs(fsm, src) arc.weight /= total end
        src.finalweight /= total
    end

    fsm
end

"""
    replace(fsm, subfsms, delim = "!")

Replace the state in `fsm` wiht a sub-fsm from `subfsms`. The pairing
is done with the last tone of `label` of the state, i.e. the state
with label `a!b!c` will be replaced by `subfsms[c]`. States that don't
have matching labels are left untouched.
"""
function Base.replace(fsm::FSM{T}, subfsms::Dict, delim = "!") where T
    newfsm = FSM{T}()

    matchlabel = label -> split(label, delim)[end]

    smap_in = Dict()
    smap_out = Dict()
    for s in states(fsm)
        if matchlabel(s.label) in keys(subfsms)
            smap = Dict()
            for cs in states(subfsms[matchlabel(s.label)])
                label = "$(s.label)$(delim)$(cs.label)"
                ns = addstate!(newfsm, pdfindex = cs.pdfindex, label = label,
                               initweight = s.initweight * cs.initweight,
                               finalweight = s.finalweight * cs.finalweight)
                smap[cs] = ns

                if isinit(cs) smap_in[s] = ns end
                if isfinal(cs) smap_out[s] = ns end
            end

            for cs in states(subfsms[matchlabel(s.label)])
                for arc in arcs(subfsms[matchlabel(s.label)], cs)
                    addarc!(newfsm, smap[cs], smap[arc.dest], arc.weight)
                end
            end

        else
            ns = addstate!(newfsm, pdfindex = s.pdfindex, label = s.label,
                           initweight = s.initweight, finalweight = s.finalweight)
            smap_in[s] = ns
            smap_out[s] = ns
        end
    end

    for osrc in states(fsm)
        for arc in arcs(fsm, osrc)
            src = smap_out[osrc]
            dest = smap_in[arc.dest]
            arc!(newfsm, src, dest, arc.weight)
        end
    end

    newfsm
end

function _unique_labels(statelist, T, step; init = true)
    labels = Dict()
    for (s, w) in statelist
        lstates, iw, fw, tw = get(labels, (s.label, step), (Set(), zero(T), zero(T), zero(T)))
        push!(lstates, s)
        labels[(s.label, step)] = (lstates, iw+s.initweight, fw+s.finalweight, tw+w)
    end

    # Inverse the map so that the set of states is the key.
    retval = Dict()
    for (key, value) in labels
        retval[value[1]] = (key[1], value[2], value[3], value[4], init)
    end
    retval
end

"""
    determinize(fsm)

Determinize the FSM w.r.t. the state labels.
"""
function determinize(fsm::FSM{T}) where T
    newfsm = FSM{T}()
    smap = Dict()
    newarcs = Dict()

    initstates = [(s, zero(T)) for s in filter(isinit, collect(states(fsm)))]
    queue = _unique_labels(initstates, T, 0, init = true)
    while ! isempty(queue)
        key, value = pop!(queue)
        lstates = key
        label, iw, fw, tw, init = value
        step = 0

        if key ∉ keys(smap)
            if init
                s = addstate!(newfsm, label = label, initweight = iw, finalweight = fw)
            else
                s = addstate!(newfsm, label = label, finalweight = fw)
            end
            smap[key] = s
        end

        nextstates = []
        for ls in lstates
            for arc in arcs(fsm, ls)
                push!(nextstates, (arc.dest, arc.weight))
            end
        end

        nextlabels = _unique_labels(nextstates, T, step+1, init = false)
        for (key2, value2) in nextlabels
            w = get(newarcs, (key,key2), zero(T))
            newarcs[(key,key2)] = w+value2[end]
        end
        queue = merge(queue, nextlabels)
    end

    for (key, value) in newarcs
        src = smap[key[1]]
        dest = smap[key[2]]
        weight = value
        addarc!(newfsm, src, dest, weight)
    end

    newfsm
end

"""
    transpose(fsm)

Reverse the direction of the arcs.
"""
function Base.transpose(fsm::FSM{T}) where T
    newfsm = FSM{T}()
    smap = Dict()
    for s in states(fsm)
        ns = addstate!(newfsm, label = s.label, initweight = s.finalweight,
                       finalweight = s.initweight, pdfindex = s.pdfindex)
        smap[s] = ns
    end

    for src in states(fsm)
        for arc in arcs(fsm, src)
            arc!(newfsm, smap[arc.dest], smap[src], arc.weight)
        end
    end

    newfsm
end

"""
    minimize(fsm)

Return a minimal equivalent fsm.
"""
minimize(fsm::FSM{T}) where T = (transpose ∘ determinize ∘ transpose ∘ determinize)(fsm)

