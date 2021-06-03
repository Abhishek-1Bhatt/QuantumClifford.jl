"""
Generate a Pauli operator by using operators from a given the Stabilizer.

**It assumes the stabilizer is already canonicalized.** It modifies
the Pauli operator in place, generating it in reverse, up to a phase.
That phase is left in the modified operator, which should be the identity up to a phase.
Returns the new operator and the list of indices denoting the elements of
`stabilizer` that were used for the generation.

```jldoctest
julia> ghz = S"XXXX
               ZZII
               IZZI
               IIZZ";

julia> canonicalize!(ghz)
+ XXXX
+ Z__Z
+ _Z_Z
+ __ZZ

julia> generate!(P"-ZIZI", ghz)
(- ____, [2, 4])
```

When the Pauli operator can not be generated by the given tableau, `nothing` is returned.

```jldoctest
julia> generate!(P"XII",canonicalize!(S"ZII")) === nothing
true

julia> generate!(P"XII",canonicalize!(S"XII")) === nothing
false
```
"""
function generate!(pauli::PauliOperator{Tz,Tv}, stabilizer::Stabilizer{Tzv,Tm}; phases::Bool=true, saveindices::Bool=true) where {Tz<:AbstractArray{UInt8,0}, Tzv<:AbstractVector{UInt8}, Tme<:Unsigned, Tv<:AbstractVector{Tme}, Tm<:AbstractMatrix{Tme}} # TODO there is stuff that can be abstracted away here and in canonicalize!
    rows, columns = size(stabilizer)
    xzs = stabilizer.xzs
    xs = @view xzs[:,1:end÷2]
    zs = @view xzs[:,end÷2+1:end]
    lowbit = Tme(0x1)
    zerobit = Tme(0x0)
    px,pz = xview(pauli), zview(pauli)
    used_indices = Int[]
    used = 0
    # remove Xs
    while (i=unsafe_bitfindnext_(px,1)) !== nothing
        jbig = _div(Tme,i-1)+1
        jsmall = lowbit<<_mod(Tme,i-1)
        candidate = findfirst(e->e&jsmall!=zerobit, # TODO some form of reinterpret might be faster than equality check
                              xs[used+1:end,jbig])
        if isnothing(candidate)
            return nothing
        else
            used += candidate
        end
        # TODO, this is just a long explicit way to write it... learn more about broadcast
        phases && (pauli.phase[] = prodphase(pauli,stabilizer,used))
        pauli.xz .⊻= @view xzs[used,:]
        saveindices && push!(used_indices, used)
    end
    # remove Zs
    while (i=unsafe_bitfindnext_(pz,1)) !== nothing
        jbig = _div(Tme,i-1)+1
        jsmall = lowbit<<_mod(Tme,i-1)
        candidate = findfirst(e->e&jsmall!=zerobit, # TODO some form of reinterpret might be faster than equality check
                              zs[used+1:end,jbig])
        if isnothing(candidate)
            return nothing
        else
            used += candidate
        end
        # TODO, this is just a long explicit way to write it... learn more about broadcast
        phases && (pauli.phase[] = prodphase(pauli,stabilizer,used))
        pauli.xz .⊻= @view xzs[used,:]
        saveindices && push!(used_indices, used)
    end
    if saveindices
        return pauli, used_indices
    else
        return pauli
    end
end

"""
$TYPEDSIGNATURES

Project the state of a Stabilizer on the two eigenspaces of a Pauli operator.

Assumes the input is a valid stabilizer.
The projection is done inplace on that stabilizer and it does not modify the
projection operator.

It returns

 - a stabilizer that might not be in canonical form
 - the index of the row where the non-commuting operator was (that row is now equal to `pauli`; its phase is not updated and for a faithful measurement simulation it needs to be randomized by the user)
 - and the result of the projection if there was no non-commuting operator (`nothing` otherwise)

If `keep_result==false` that result of the projection in case of anticommutation
is not computed, sparing a canonicalization operation.

Here is an example of a projection destroying entanglement:

```jldoctest
julia> ghz = S"XXXX
               ZZII
               IZZI
               IIZZ";

julia> canonicalize!(ghz)
+ XXXX
+ Z__Z
+ _Z_Z
+ __ZZ

julia> state, anticom_index, result = project!(ghz, P"ZIII");

julia> state
+ Z___
+ Z__Z
+ _Z_Z
+ __ZZ

julia> canonicalize!(state)
+ Z___
+ _Z__
+ __Z_
+ ___Z

julia> anticom_index, result
(1, nothing)
```

And an example of projection consistent with the stabilizer state.

```jldoctest
julia> s = S"ZII
             IXI
             IIY";

julia> canonicalize!(s)
+ _X_
+ __Y
+ Z__

julia> state, anticom_index, result = project!(s, P"-ZII");

julia> state
+ _X_
+ __Y
+ Z__

julia> anticom_index, result
(0, 0x02)
```

While not the best choice, `Stabilizer` can be used for mixed states,
simply by providing an incomplete tableau. In that case it is possible
to attempt to project on an operator that can not be generated by the
provided stabilizer operators. In that case we have both `anticom_index==0`
and `result===nothing`.

```jldoctest
julia> s = S"XZI
             IZI";

julia> project!(s, P"IIX")
(+ X__
+ _Z_, 0, nothing)
```

If we had used [`MixedStabilizer`](@ref) we would have added the projector
to the list of stabilizers.

```jldoctest
julia> s = one(MixedStabilizer, 2, 3)
Rank 2 stabilizer
+ Z__
+ _Z_

julia> project!(s, P"IIX")
(Rank 3 stabilizer
+ Z__
+ _Z_
+ __X, 0, nothing)
```

However, [`MixedDestabilizer`](@ref) would
be an even better choice as it has \$\\mathcal{O}(n^2)\$ complexity
instead of the \$\\mathcal{O}(n^3)\$ complexity of `*Stabilizer`.

```jldoctest
julia> s = one(MixedDestabilizer, 2, 3)
Rank 2 stabilizer
+ X__
+ _X_
━━━━━
+ __X
━━━━━
+ Z__
+ _Z_
━━━━━
+ __Z

julia> project!(s, P"IIX")
(Rank 3 stabilizer
+ X__
+ _X_
+ __Z
═════
+ Z__
+ _Z_
+ __X
═════
, 0, nothing)
```

See the "Datastructure Choice" section in the documentation for more details.
"""
function project!(stabilizer::Stabilizer,pauli::PauliOperator;keep_result::Bool=true,phases::Bool=true)
    anticommutes = 0
    n = size(stabilizer,1)
    for i in 1:n  # The explicit loop is faster than anticommutes = findfirst(row->comm(pauli,stabilizer,row)!=0x0, 1:n); both do not allocate.
        if comm(pauli,stabilizer,i)!=0x0
            anticommutes = i
            break
        end
    end
    if anticommutes == 0
        if keep_result
            canonicalize!(stabilizer; phases=phases) # O(n^3)
            gen = generate!(copy(pauli), stabilizer, phases=phases) # O(n^2)
            result = isnothing(gen) ? nothing : gen[1].phase[]
        else
            result = nothing
        end
    else
        for i in anticommutes+1:n
            if comm(pauli,stabilizer,i)!=0
                rowmul!(stabilizer, i, anticommutes; phases=phases)
            end
        end
        stabilizer[anticommutes] = pauli
        result = nothing
    end
    stabilizer, anticommutes, result
end

"""
$TYPEDSIGNATURES
"""
function project!(d::Destabilizer,pauli::PauliOperator;keep_result::Bool=true,phases::Bool=true)
    anticommutes = 0
    stabilizer = stabilizerview(d)
    destabilizer = destabilizerview(d)
    n = size(stabilizer,1)
    for i in 1:n # The explicit loop is faster than anticommutes = findfirst(row->comm(pauli,stabilizer,row)!=0x0, 1:r); both do not allocate.
        if comm(pauli,stabilizer,i)!=0x0
            anticommutes = i
            break
        end
    end
    if anticommutes == 0
        if n != nqubits(stabilizer)
            throw(BadDataStructure("`Destabilizer` can not efficiently (faster than n^3) detect whether you are projecting on a stabilized or a logical operator. Switch to one of the `Mixed*` data structures.",
                                   :project!,
                                   :Destabilizer))
        end
        if keep_result
            new_pauli = zero(pauli)
            new_pauli.phase[] = pauli.phase[]
            for i in 1:n
                if comm(pauli,destabilizer,i)!=0
                    # TODO, this is just a long explicit way to write it... learn more about broadcast
                    phases && (new_pauli.phase[] = prodphase(stabilizer, new_pauli, i))
                    new_pauli.xz .⊻= @view stabilizer.xzs[i,:]
                end
            end
            result = new_pauli.phase[]
        else
            result = nothing
        end
    else
        for i in anticommutes+1:n
            if comm(pauli,stabilizer,i)!=0
                rowmul!(stabilizer, i, anticommutes; phases=phases)
            end
        end
        for i in 1:n
            if i!=anticommutes && comm(pauli,destabilizer,i)!=0
                rowmul!(d.tab, i, n+anticommutes; phases=false)
            end
        end
        destabilizer[anticommutes] = stabilizer[anticommutes]
        stabilizer[anticommutes] = pauli
        result = nothing
    end
    d, anticommutes, result
end

"""
$TYPEDSIGNATURES

When using project on `MixedStabilizer` it automates some of the extra steps
we encounter when implicitly using the `Stabilizer` datastructure to represent
mixed states. Namely, it helps when the projector is not among the list of
stabilizers:

```jldoctest
julia> s = S"XZI
             IZI";

julia> ms = MixedStabilizer(s)
Rank 2 stabilizer
+ X__
+ _Z_

julia> project!(ms, P"IIY")
(Rank 3 stabilizer
+ X__
+ _Z_
+ __Y, 0, nothing)
```
"""
function project!(ms::MixedStabilizer,pauli::PauliOperator;keep_result::Bool=true,phases::Bool=true)
    _, anticom_index, res = project!(stabilizerview(ms), pauli; keep_result=keep_result, phases=phases)
    Tme = eltype(pauli.xz)
    if anticom_index==0 && isnothing(res)
        ms.tab[ms.rank+1] = pauli
        if keep_result
            ms.rank += 1
        else
            canonicalize!(@view ms.tab[1:ms.rank+1]; phases=phases)
            if ~all(==(Tme(0)), @view ms.tab.xzs[ms.rank+1,:])
                ms.rank += 1
            end
        end
    end
    ms, anticom_index, res
end

function anticomm_update_rows(tab,pauli,r,n,anticommutes,phases) # TODO Ensure there are no redundant `comm` checks that can be skipped
    chunks = size(tab.xzs,2)
    for i in r+1:n
        if comm(pauli,tab,i)!=0
            rowmul!(tab, i, n+anticommutes; phases=phases)
        end
    end
    for i in n+anticommutes+1:2n
        if comm(pauli,tab,i)!=0
            rowmul!(tab, i, n+anticommutes; phases=phases)
        end
    end
    for i in 1:r
        if i!=anticommutes && comm(pauli,tab,i)!=0
            rowmul!(tab, i, n+anticommutes; phases=false)
        end
    end
end

"""
$TYPEDSIGNATURES
"""
function project!(d::MixedDestabilizer,pauli::PauliOperator;keep_result::Bool=true,phases::Bool=true)
    anticommutes = 0
    tab = d.tab
    stabilizer = stabilizerview(d)
    destabilizer = destabilizerview(d)
    r = d.rank
    n = nqubits(d)
    for i in 1:r # The explicit loop is faster than anticommutes = findfirst(row->comm(pauli,stabilizer,row)!=0x0, 1:r); both do not allocate.
        if comm(pauli,stabilizer,i)!=0x0
            anticommutes = i
            break
        end
    end
    if anticommutes == 0
        anticomlog = 0
        for i in r+1:n # The explicit loop is faster than findfirst.
            if comm(pauli,tab,i)!=0x0
                anticomlog = i
                break
            end
        end
        if anticomlog==0
            for i in n+r+1:2*n # The explicit loop is faster than findfirst.
                if comm(pauli,tab,i)!=0x0
                    anticomlog = i
                    break
                end
            end
        end
        if anticomlog!=0
            if anticomlog<=n
                rowswap!(tab, r+1+n, anticomlog)
                n!=r+1 && anticomlog!=r+1 && rowswap!(tab, r+1, anticomlog+n)
            else
                rowswap!(tab, r+1, anticomlog-n)
                rowswap!(tab, r+1+n, anticomlog)
            end
            anticomm_update_rows(tab,pauli,r+1,n,r+1,phases)
            d.rank += 1
            tab[r+1] = tab[n+r+1]
            tab[n+r+1] = pauli
            result = nothing
        else
            if keep_result
                new_pauli = zero(pauli)
                new_pauli.phase[] = pauli.phase[]
                for i in 1:r
                    if comm(pauli,destabilizer,i)!=0
                        # TODO, this is just a long explicit way to write it... learn more about broadcast
                        phases && (new_pauli.phase[] = prodphase(stabilizer, new_pauli, i))
                        new_pauli.xz .⊻= @view stabilizer.xzs[i,:]
                    end
                end
                result = new_pauli.phase[]
            else
                result = nothing
            end
        end
    else
        anticomm_update_rows(tab,pauli,r,n,anticommutes,phases)
        destabilizer[anticommutes] = stabilizer[anticommutes]
        stabilizer[anticommutes] = pauli
        result = nothing
    end
    d, anticommutes, result
end

"""
$TYPEDSIGNATURES

Trace out a qubit.
""" # TODO all of these should raise an error if length(qubits)>rank
function traceout!(s::Stabilizer, qubits; phases=true, rank=false)
    _,i = canonicalize_rref!(s,qubits;phases=phases)
    idpaulis = zero(PauliOperator,nqubits(s))
    for j in i+1:size(s,1)
        s[j] = idpaulis # TODO - this can be done without creating/allocating an idpaulis object
    end
    if rank return (s, i) else return s end
end

"""
$TYPEDSIGNATURES
"""
function traceout!(s::Union{MixedStabilizer, MixedDestabilizer}, qubits; phases=true, rank=false)
    _,i = canonicalize_rref!(s,qubits;phases=phases)
    s.rank = i
    if rank return (s, i) else return s end
end
