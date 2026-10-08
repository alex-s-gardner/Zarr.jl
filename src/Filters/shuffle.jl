#=
# Shuffle compression

This file implements the shuffle compressor.
=#

struct ShuffleFilter <: Filter{UInt8, UInt8}
    elementsize::Csize_t
end

ShuffleFilter(; elementsize = 4) = ShuffleFilter(elementsize)

function _do_shuffle!(dest::AbstractVector{UInt8}, source::AbstractVector{UInt8}, elementsize::Csize_t)
    count = fld(length(source), elementsize) # elementsize is in bytes, so this works
    for i in 0:(count-1)
        offset = i * elementsize
        for byte_index in 0:(elementsize-1)
            j = byte_index * count + i
            dest[j+1] = source[offset + byte_index+1]
        end
    end
end

function _do_unshuffle!(dest::AbstractVector{UInt8}, source::AbstractVector{UInt8}, elementsize::Csize_t)
    count = fld(length(source), elementsize) # elementsize is in bytes, so this works
    for i in 0:(elementsize-1)
        offset = i * count
        for byte_index in 0:(count-1)
            j = byte_index * elementsize + i
            dest[j+1] = source[offset + byte_index+1]
        end
    end
end

function zencode(a::AbstractArray, c::ShuffleFilter)
    if c.elementsize <= 1 # no shuffling needed if elementsize is 1
        return a
    end
    source = reinterpret(UInt8, vec(a))
    dest = Vector{UInt8}(undef, length(source))
    _do_shuffle!(dest, source, c.elementsize)
    return dest
end

function zdecode(a::AbstractArray, c::ShuffleFilter)
    if c.elementsize <= 1 # no shuffling needed if elementsize is 1
        return a
    end
    source = reinterpret(UInt8, vec(a))
    dest = Vector{UInt8}(undef, length(source))
    _do_unshuffle!(dest, source, c.elementsize)
    return dest
end

# A shuffle undone straight into `data`'s bytes, which saves the shuffled copy and the copy out of it.
function zuncompress!(data::DenseArray, compressed, c, f::Tuple{ShuffleFilter})
    isbitstype(eltype(data)) || return invoke(zuncompress!, Tuple{Any,Any,Any,Any}, data, compressed, c, f)
    only(f).elementsize > 1 || return invoke(zuncompress!, Tuple{Any,Any,Any,Any}, data, compressed, c, f)
    nbytes = sizeof(eltype(data)) * length(data)
    shuffled = take_scratch(UInt8, (nbytes,))
    try
        zuncompress_into!(shuffled, compressed, c) ||
            return invoke(zuncompress!, Tuple{Any,Any,Any,Any}, data, compressed, c, f)
        _do_unshuffle!(reinterpret(UInt8, vec(data)), shuffled, only(f).elementsize)
    finally
        give_scratch!(shuffled)
    end
    return data
end

function getfilter(::Type{ShuffleFilter}, d::Dict)
    return ShuffleFilter(d["elementsize"])
end

function JSON.lower(c::ShuffleFilter)
    return Dict("id" => "shuffle", "elementsize" => Int64(c.elementsize))
end

filterdict["shuffle"] = ShuffleFilter
#=

# Tests


    
=#