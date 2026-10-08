# Chunk-sized scratch arrays, reused from one read to the next. A read that decodes many chunks on several
# threads would otherwise allocate megabytes per chunk, and the garbage collector rather than the decoding
# would set its pace. A buffer is held only for the duration of one read; at most `SCRATCH_PER_SHAPE` are
# kept per element type and shape, and none beyond `SCRATCH_MAX_BYTES` in all.
const SCRATCH_LOCK = ReentrantLock()
const SCRATCH = Dict{Tuple{DataType,Tuple},Vector{Any}}()
const SCRATCH_BYTES = Ref(0)
const SCRATCH_PER_SHAPE = 32
const SCRATCH_MAX_BYTES = 512 * 1024^2

function take_scratch(::Type{T}, dims::NTuple{N,Int}) where {T,N}
    a = @lock SCRATCH_LOCK begin
        free = get(SCRATCH, (T, dims), nothing)
        if free === nothing || isempty(free)
            nothing
        else
            SCRATCH_BYTES[] -= sizeof(T) * prod(dims)
            pop!(free)
        end
    end
    return a === nothing ? Array{T,N}(undef, dims) : a::Array{T,N}
end

function give_scratch!(a::Array{T}) where {T}
    isbitstype(T) || return nothing
    @lock SCRATCH_LOCK begin
        free = get!(() -> Any[], SCRATCH, (T, size(a)))
        if length(free) < SCRATCH_PER_SHAPE && SCRATCH_BYTES[] + sizeof(a) <= SCRATCH_MAX_BYTES
            push!(free, a)
            SCRATCH_BYTES[] += sizeof(a)
        end
    end
    return nothing
end
give_scratch!(::Any) = nothing
