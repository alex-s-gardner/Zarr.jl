import JSON
import OffsetArrays: OffsetArray
import DiskArrays: AbstractDiskArray
import DiskArrays

"""
Number of tasks to use for async reading of chunks. Warning: setting this to very high values can lead to a large memory footprint. 
"""
const concurrent_io_tasks = Ref(50)

getfillval(::Type{T}, t::String) where {T <: Number} = parse(T, t)
getfillval(::Type{T}, t::Union{T,Nothing}) where {T} = t

struct SenMissArray{T,N} <: AbstractArray{Union{T,Missing},N}
  x::Array{T,N}
  senval::T
end
SenMissArray(x::Array{T,N},v) where {T,N} = SenMissArray{T,N}(x,convert(T,v))
Base.size(x::SenMissArray) = size(x.x)
senval(x::SenMissArray) = x.senval
function Base.getindex(x::SenMissArray,i::Int)
  v = x.x[i]
  isequal(v,senval(x)) ? missing : v
end
Base.setindex!(x::SenMissArray,v,i::Int) = x.x[i] = v
Base.setindex!(x::SenMissArray,::Missing,i::Int) = x.x[i] = senval(x)
Base.IndexStyle(::Type{<:SenMissArray})=Base.IndexLinear()

# Struct representing a Zarr Array in Julia, note that
# chunks(chunk size) and size are always in Julia column-major order
# Currently this is not an AbstractArray, because indexing single elements is
# would be really slow, although most AbstractArray interface functions are implemented
struct ZArray{T, N, C<:Compressor, S<:AbstractStore} <: AbstractDiskArray{T,N}
  metadata::Metadata{T, N, C}
  storage::S
  path::String
  attrs::Dict
  writeable::Bool
end

Base.eltype(::ZArray{T}) where {T} = T
Base.ndims(::ZArray{<:Any,N}) where {N} = N
Base.size(z::ZArray) = z.metadata.shape[]
Base.size(z::ZArray,i) = z.metadata.shape[][i]
Base.length(z::ZArray) = prod(z.metadata.shape[])
Base.lastindex(z::ZArray,n) = size(z,n)
Base.lastindex(z::ZArray{<:Any,1}) = size(z,1)

function Base.show(io::IO,z::ZArray)
  print(io, "ZArray{", eltype(z) ,"} of size ",join(string.(size(z)), " x "))
end
function Base.show(io::IO,::MIME"text/plain",z::ZArray)
  print(io, "ZArray{", eltype(z) ,"} of size ",join(string.(size(z)), " x "))
end

"""
    zname(z::ZArray)

Extract the name of a Zarr array from the object
"""
zname(z::ZArray) = zname(path(z))

function zname(s::String)
  spl = split(rstrip(s,'/'),'/')
  isempty(last(spl)) ? "root" : last(spl)
end


"""
storagesize(z::ZArray)

Returns the size of the compressed data stored in the ZArray `z` in bytes
"""
storagesize(z::ZArray) = storagesize(storage(z),path(z))

"""
storageratio(z::ZArray)

Returns the ratio of the size of the uncompressed data in `z` and the size of the compressed data.
"""
storageratio(z::ZArray) = length(z)*sizeof(eltype(z))/storagesize(z)

storageratio(z::ZArray{<:Vector}) = "unknown"

nobytes(z::ZArray) = length(z)*sizeof(eltype(z))
nobytes(z::ZArray{<:Vector}) = "unknown"
nobytes(z::ZArray{<:String}) = "unknown"

zinfo(z::ZArray) = zinfo(stdout,z)
function zinfo(io::IO,z::ZArray)
  ninit = sum(chunkindices(z)) do i
    isinitialized(storage(z),path(z),i)
  end
  allinfos = [
  "Type" => "ZArray",
  "Data type" => eltype(z),
  "Shape" => size(z),
  "Chunk Shape" => z.metadata.chunks,
  "Order" => z.metadata.order,
  "Read-Only" => !iswriteable(z),
  "Compressor" => z.metadata.compressor,
  "Filters" => z.metadata.filters, 
  "Store type" => storage(z),
  "No. bytes"  => nobytes(z),
  "No. bytes stored" => storagesize(z),
  "Storage ratio" => storageratio(z),
  "Chunks initialized" => "$(ninit)/$(length(chunkindices(z)))"
  ]
  foreach(allinfos) do ii
    println(io,rpad(ii[1],20),": ",ii[2])
  end
end

function ZArray(s::T, mode="r",path="";fill_as_missing=false) where T <: AbstractStore
  metadata = getmetadata(s,path,fill_as_missing)
  attrs    = getattrs(s,path)
  writeable = mode == "w"
  startswith(path,"/") && error("Paths should never start with a leading '/'")
  ZArray{eltype(metadata), length(metadata.shape[]), typeof(metadata.compressor), T}(
  metadata, s, path, attrs, writeable)
end


"""
trans_ind(r, bs)

For a given index and blocksize determines which chunks of the Zarray will have to
be accessed.
"""
trans_ind(r::AbstractUnitRange, bs) = fld1(first(r),bs):fld1(last(r),bs)
trans_ind(r::Integer, bs) = fld1(r,bs)

function boundint(r1, s2, o2)
  r2 = range(o2+1,length=s2)
  f1, f2  = first(r1), first(r2)
  l1, l2  = last(r1),last(r2)
  UnitRange(f1 > f2 ? f1 : f2, l1 < l2 ? l1 : l2)
end

function getchunkarray(z::ZArray{>:Missing})
  # temporary workaround to use strings as data values
  inner = fill(z.metadata.fill_value, z.metadata.chunks)
  a = SenMissArray(inner,z.metadata.fill_value)
end
_zero(T) = zero(T)
_zero(T::Type{<:MaxLengthString}) = T("")
_zero(T::Type{ASCIIChar}) = ASCIIChar(0)
_zero(::Type{<:Vector{T}}) where T = T[]
getchunkarray(z::ZArray) = fill(_zero(eltype(z)), z.metadata.chunks)

maybeinner(a::Array) = a
maybeinner(a::SenMissArray) = a.x
resetbuffer!(fv,a::Array) = fv === nothing || fill!(a,fv)
resetbuffer!(_,a::SenMissArray) = fill!(a,missing)

# Function to read or write from a zarr array. Could be refactored
# using type system to get rid of the `if readmode` statements.
function readblock!(aout::AbstractArray{<:Any,N}, z::ZArray{<:Any, N}, r::CartesianIndices{N}) where {N}
  
  output_base_offsets = map(i->first(i)-1,r.indices)
  # Determines which chunks are affected
  blockr = CartesianIndices(map(trans_ind, r.indices, z.metadata.chunks))
  # Allocate array of the size of a chunks where uncompressed data can be held
  #bufferdict = IdDict((current_task()=>getchunkarray(z),))
  a = getchunkarray(z)
  # Now loop through the chunks
  c = Channel{Pair{eltype(blockr),Union{Nothing,Vector{UInt8}}}}(channelsize(storage(z)))
  
  task = @async begin
    read_items!($storage(z),c, $path(z), $blockr)
  end
  bind(c,task)

  try 
    for i in 1:length(blockr)
      
      bI,chunk_compressed = take!(c)
      
      current_chunk_offsets = map((s,i)->s*(i-1),size(a),Tuple(bI))

      indranges    = map(boundint,r.indices,size(a),current_chunk_offsets)
      
      uncompress_to_output!(aout,output_base_offsets,z,chunk_compressed,current_chunk_offsets,a,indranges)
      nothing
    end
  finally
    close(c)
  end
  aout
end

function writeblock!(ain::AbstractArray{<:Any,N}, z::ZArray{<:Any, N}, r::CartesianIndices{N}) where {N}
  
  iswriteable(z) || error("Can not write to read-only ZArray")

  input_base_offsets = map(i->first(i)-1,r.indices)
  # Determines which chunks are affected
  blockr = CartesianIndices(map(trans_ind, r.indices, z.metadata.chunks))
  # Allocate array of the size of a chunks where uncompressed data can be held
  #bufferdict = IdDict((current_task()=>getchunkarray(z),))
  a = getchunkarray(z)
  # Now loop through the chunks
  readchannel = Channel{Pair{eltype(blockr),Union{Nothing,Vector{UInt8}}}}(channelsize(storage(z)))
  
  readtask = @async begin 
    read_items!(storage(z),readchannel, path(z), blockr)
  end
  bind(readchannel,readtask)

  writechannel = Channel{Pair{eltype(blockr),Union{Nothing,Vector{UInt8}}}}(channelsize(storage(z)))

  writetask = @async begin
    write_items!(storage(z),writechannel,path(z),blockr)
  end
  bind(writechannel,writetask)
  
  try 
    for i in 1:length(blockr)
      
      bI,chunk_compressed = take!(readchannel)
      
      current_chunk_offsets = map((s,i)->s*(i-1),size(a),Tuple(bI))

      indranges    = map(boundint,r.indices,size(a),current_chunk_offsets)

      if isnothing(chunk_compressed) || (length.(indranges) != size(a))
        resetbuffer!(z.metadata.fill_value,a)
      end

      curchunk = if length.(indranges) != size(a)
        view(a,dotminus.(indranges,current_chunk_offsets)...)
      else
        a
      end
      
      if chunk_compressed !== nothing
        uncompress_raw!(a,z,chunk_compressed)
      end

      curchunk .= view(ain,dotminus.(indranges,input_base_offsets)...)

      put!(writechannel,bI=>compress_raw(maybeinner(a),z))
      nothing
    end
  finally
    close(readchannel)
    close(writechannel)
  end
  ain
end

DiskArrays.readblock!(a::ZArray,aout,i::AbstractUnitRange...) = readblock!(aout,a,CartesianIndices(i))
DiskArrays.writeblock!(a::ZArray,v,i::AbstractUnitRange...) = writeblock!(v,a,CartesianIndices(i))
DiskArrays.haschunks(::ZArray) = DiskArrays.Chunked()
DiskArrays.eachchunk(a::ZArray) = DiskArrays.GridChunks(a,a.metadata.chunks)

"""
uncompress_raw!(a::DenseArray{T},z::ZArray{T,N},i::CartesianIndex{N})

Read the chunk specified by `i` from the Zarray `z` and write its content to `a`
"""
function uncompress_raw!(a,z::ZArray{<:Any,N},curchunk) where N
  if curchunk === nothing
    fill!(a, z.metadata.fill_value)
  else
    zuncompress!(a, curchunk, z.metadata.compressor, z.metadata.filters)
  end
  a
end

dotminus(x,y) = x.-y

function uncompress_to_output!(aout,output_base_offsets,z,chunk_compressed,current_chunk_offsets,a,indranges)
  
  uncompress_raw!(a,z,chunk_compressed)
  
  if length.(indranges) == size(a)
    aout[dotminus.(indranges, output_base_offsets)...] = ndims(a) == 0 ? a[1] : a
  else
    curchunk = a[dotminus.(indranges,current_chunk_offsets)...]
    aout[dotminus.(indranges, output_base_offsets)...] = curchunk
  end
end

function compress_raw(a,z)
  length(a) == prod(z.metadata.chunks) || throw(DimensionMismatch("Array size does not equal chunk size"))
  if !all(isequal(z.metadata.fill_value),a)
    dtemp = UInt8[]
    zcompress!(dtemp,a,z.metadata.compressor, z.metadata.filters)
    dtemp
  else
    nothing
  end
end



"""
zcreate(T, dims...;kwargs)

Creates a new empty zarr array with element type `T` and array dimensions `dims`. The following keyword arguments are accepted:

* `path=""` directory name to store a persistent array. If left empty, an in-memory array will be created
* `name=""` name of the zarr array, defaults to the directory name
* `storagetype` determines the storage to use, current options are `DirectoryStore` or `DictStore`
* `chunks=dims` size of the individual array chunks, must be a tuple of length `length(dims)`
* `fill_value=nothing` value to represent missing values
* `fill_as_missing=false` set to `true` shall fillvalue s be converted to `missing`s
* `filters`=filters to be applied
* `compressor=BloscCompressor()` compressor type and properties
* `attrs=Dict()` a dict containing key-value pairs with metadata attributes associated to the array
* `writeable=true` determines if the array is opened in read-only or write mode
"""
function zcreate(::Type{T}, dims::Integer...;
  name="",
  path=nothing,
  kwargs...
  ) where T
  if path===nothing
    store = DictStore()
  else
    store = DirectoryStore(joinpath(path,name))
  end
  zcreate(T, store, dims...; kwargs...)
end

function zcreate(::Type{T},storage::AbstractStore,
  dims...;
  path = "",
  chunks=dims,
  fill_value=nothing,
  fill_as_missing=false,
  compressor=BloscCompressor(),
  filters = filterfromtype(T), 
  attrs=Dict(),
  writeable=true,
  ) where T
  
  length(dims) == length(chunks) || throw(DimensionMismatch("Dims must have the same length as chunks"))
  N = length(dims)
  C = typeof(compressor)
  T2 = (fill_value === nothing || !fill_as_missing) ? T : Union{T,Missing}
  metadata = Metadata{T2, N, C, typeof(filters)}(
  2,
  dims,
  chunks,
  typestr(T),
  compressor,
  fill_value,
  'C',
  filters,
  )
  
  isemptysub(storage,path) || error("$storage $path is not empty")
  
  writemetadata(storage, path, metadata)
  
  writeattrs(storage, path, attrs)
  
  ZArray{T2, N, typeof(compressor), typeof(storage)}(
  metadata, storage, path, attrs, writeable)
end

filterfromtype(::Type{<:Any}) = nothing

function filterfromtype(::Type{<:AbstractArray{T}}) where T
  #Here we have to apply the vlenarray filter
  (VLenArrayFilter{T}(),)
end

filterfromtype(::Type{<:Union{<:AbstractString, Union{<:AbstractString, Missing}}}) = (VLenUTF8Filter(),)
filterfromtype(::Type{<:Union{MaxLengthString, Union{MaxLengthString, Missing}}}) = nothing

#Not all Array types can be mapped directly to a valid ZArray encoding.
#Here we try to determine the correct element type
to_zarrtype(::AbstractArray{T}) where T = T
to_zarrtype(a::AbstractArray{<:Date}) = DateTime64{Dates.Day}
to_zarrtype(a::AbstractArray{<:DateTime}) = DateTime64{Dates.Millisecond}

function ZArray(a::AbstractArray, args...; kwargs...)
  z = zcreate(to_zarrtype(a), args..., size(a)...; kwargs...)
  z[:]=a
  z
end

"""
chunkindices(z::ZArray)

Returns the Cartesian Indices of the chunks of a given ZArray
"""
chunkindices(z::ZArray) = CartesianIndices(map((s, c) -> 1:ceil(Int, s/c), z.metadata.shape[], z.metadata.chunks))

"""
zzeros(T, dims...; kwargs... )

Creates a zarr array and initializes all values with zero. Accepts the same keyword arguments as `zcreate`
"""
function zzeros(T,dims...;kwargs...)
  z = zcreate(T,dims...;kwargs...)
  as = zeros(T, z.metadata.chunks...)
  data_encoded = compress_raw(as,z)
  p = path(z)
  for i in chunkindices(z)
    storage(z)[p,i] = data_encoded
  end
  z
end

#Resizing Zarr arrays
"""
resize!(z::ZArray{T,N}, newsize::NTuple{N})

Resizes a `ZArray` to the new specified size. If the size along any of the
axes is decreased, unused chunks will be deleted from the store.
"""
function Base.resize!(z::ZArray{T,N}, newsize::NTuple{N}) where {T,N}
  any(<(0), newsize) && throw(ArgumentError("Size must be positive"))
  oldsize = z.metadata.shape[]
  z.metadata.shape[] = newsize
  #Check if array was shrunk
  if any(map(<,newsize, oldsize))
    prune_oob_chunks(storage(z),path(z),oldsize,newsize, z.metadata.chunks)
  end
  writemetadata(storage(z), path(z), z.metadata)
  nothing
end
Base.resize!(z::ZArray, newsize::Integer...) = resize!(z,newsize)

"""
append!(z::ZArray{<:Any, N},a;dims = N)

Appends an AbstractArray to an existinng `ZArray` along the dimension dims. The
size of the `ZArray` is increased accordingly and data appended.

Example:

````julia
z=zzeros(Int,5,3)
append!(z,[1,2,3],dims=1) #Add a new row
append!(z,ones(Int,6,2)) #Add two new columns
z[:,:]
````
"""
function Base.append!(z::ZArray{<:Any, N},a;dims = N) where N
  #Determine how many entries to add to axis
  otherdims = sort!(setdiff(1:N,dims))
  othersize = size(z)[otherdims]
  if ndims(a)==N
    nadd = size(a,dims)
    size(a)[otherdims]==othersize || throw(DimensionMismatch("Array to append does not have the correct size, expected: $(othersize)"))
  elseif ndims(a)==N-1
    size(a)==othersize || throw(DimensionMismatch("Array to append does not have the correct size, expected: $(othersize)"))
    nadd = 1
  else
    throw(DimensionMismatch("Number of dimensions of array must be either $N or $(N-1)"))
  end
  oldsize = size(z)
  newsize = ntuple(i->i==dims ? oldsize[i]+nadd : oldsize[i], N)
  resize!(z,newsize)
  appendinds = ntuple(i->i==dims ? (oldsize[i]+1:newsize[i]) : Colon(),N)
  z[appendinds...] = a
  nothing
end

function prune_oob_chunks(s::AbstractStore,path,oldsize, newsize, chunks)
  dimstoshorten = findall(map(<,newsize, oldsize))
  for idim in dimstoshorten
    delrange = (fld1(newsize[idim],chunks[idim])+1):(fld1(oldsize[idim],chunks[idim]))
    allchunkranges = map(i->1:fld1(oldsize[i],chunks[i]),1:length(oldsize))
    r = (allchunkranges[1:idim-1]..., delrange, allchunkranges[idim+1:end]...)
    for cI in CartesianIndices(r)
      delete!(s,path,cI)
    end
  end
end
