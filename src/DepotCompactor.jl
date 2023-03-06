module DepotCompactor

using FileWatching: mkpidlock

export compact_depots, collect_depot_resources, collect_shared_resources

"""
    compact_depots(dest_depot::String, src_depots::Vector{String})

Given a set of source depots, find common packages and artifacts between all source
and destination depots, moving common resources into the destination depot in order to
reduce duplication across depots in a stacked depot context.
"""
function compact_depots(dest_depot::String, src_depots::Vector{String}; ref_depots::Vector{String} = src_depots)
    # `dest_depot` must always be in the `ref_depots`:
    push!(ref_depots, dest_depot)

    # Uniqufiy things
    src_depots = unique(abspath.(src_depots))
    ref_depots = unique(abspath.(ref_depots))

    # Searching across the entire set of depots, find any resources that are shared
    # between any two source depots, or any source depot and the destination depot:
    shared_resources = collect_shared_resources(src_depots, ref_depots)

    mkpidlock(joinpath(dest_depot, "compacting.lock")) do
        # For each source depot, check to see if each shared resource exists:
        for src_depot in src_depots
            for resource in shared_resources
                src_resource = joinpath(src_depot, resource)
                if isdir(src_resource)
                    # If it does not exist in `dest_depot`, we need to copy it in:
                    dest_resource = joinpath(dest_depot, resource)
                    if !isdir(dest_resource)
                        mkpath(dirname(dest_resource))
                        move_resource(src_resource, dest_resource)
                    else
                        # If it does exist, delete it.  We delete by moving the
                        # src_resource to a new name, then deleting it, so that
                        # there is no moment in time where an incomplete
                        # resource tree is present at the correct file path.
                        delete_resource(src_resource)
                    end
                end
            end
        end
    end
end

"""
    move_resource(src::String, dest::String)

Move a directory from `src` to `dest` in as transactional a manner as possible.
Using this method should ensure that there is never a moment in time where
`src` or `dest` contain a partially-copied resource.  This is ensured by using
transactional methods to move from `src` to `dest`, possibly performing a non-
transactional copy from `src` to a directory on the same filesystem as `dest`,
but then performing a transactional rename as the final step.

If this is not possible, an `IOError` will be thrown.
"""
function move_resource(src::String, dest::String)
    # First, try to `jl_fs_rename`, this only works if the underlying
    # filesystem allows it:
    err = @ccall jl_fs_rename(src::Cstring, dest::Cstring)::Int32
    if err < 0
        # If it doesn't, fall back to `cp()` to a temporary directory within
        # the same parent directory, then rename to the final name:
        temp_dir = mktempdir(dirname(dest); cleanup=false)
        try
            cp(src, temp_dir; force=true)

            # If we still can't `jl_fs_rename()`, something is very wrong.
            err = @ccall jl_fs_rename(temp_dir::Cstring, dest::Cstring)::Int32
            if err < 0
                throw(Base.IOError("Unable to rename to target '$(dest)'", err))
            end
        finally
            rm(temp_dir; force=true, recursive=true)
        end
    end
end


"""
    delete_resource(src::String)

Deletes a resource in as transactional a manner as possible.  Using this method
should ensure that there is no point in time where `src` exists with half of 
its contents deleted; it will instead first be transactionally moved to a
different path, then deleted.

If this is not possible, an `IOError` will be thrown.
"""
function delete_resource(src::String)
    temp_dir = mktempdir(dirname(src); cleanup=false)
    rm(temp_dir)
    try
        err = @ccall jl_fs_rename(src::Cstring, temp_dir::Cstring)::Int32
        if err < 0
            throw(Base.IOError("Unable to rename to target '$(temp_dir)'", err))
        end
    finally
        rm(temp_dir; force=true, recursive=true)
    end
end

function collect_depot_packages(depot::String)
    # depot-relative package path list
    depot = abspath(depot)
    packages = String[]
    packagedir = abspath(depot, "packages")
    if isdir(packagedir)
        for name in readdir(packagedir)
            if !isdir(joinpath(packagedir, name))
                continue
            end

            for slug in readdir(joinpath(packagedir, name))
                pkg_dir = joinpath(packagedir, name, slug)
                if !isdir(pkg_dir)
                    continue
                end

                push!(packages, pkg_dir[length(depot)+2:end])
            end
        end
    end
    return packages
end

function collect_depot_artifacts(depot::String)
    # depot-relative artifact path list
    depot = abspath(depot)
    artifacts = String[]
    arts_dir = abspath(depot, "artifacts")
    if isdir(arts_dir)
        for art_dir in readdir(arts_dir; join=true)
            if isdir(art_dir)
                push!(artifacts, art_dir[length(depot)+2:end])
            end
        end
    end
    return artifacts
end

"""
    collect_depot_resources(depot::String)

Return the list of depot-relative paths to packages and artifacts contained
within the given `depot`.
"""
function collect_depot_resources(depot::String)
    return vcat(collect_depot_packages(depot), collect_depot_artifacts(depot))
end

"""
    collect_shared_resources(depots::Vector{String}, ref_depots = depots)

Given a set of depots, use `collect_depot_resources()` to get a list of packages
and artifacts used in each depot, then examine pairwise-intersections between the
`depots` `ref_depots` to find resources contained in `depots` that are also
contained in one of `ref_depots`.
"""
function collect_shared_resources(depots::Vector{String}, ref_depots::Vector{String} = depots)
    # Having duplicate depots here is fairly catastrophic; let's eliminate that possibilty
    depots = unique(abspath.(depots))
    ref_depots = unique(abspath.(ref_depots))

    # Get resource lists
    resources = Dict(depot => collect_depot_resources(depot) for depot in depots)
    ref_resources = Dict(depot => collect_depot_resources(depot) for depot in ref_depots)

    # We need to collect resources that are shared by any pairwise combination of our depots:
    shared_resources = Set{String}()
    for (d1, d2) in Iterators.filter(((d1, d2),) -> d1 != d2, Iterators.product(depots, ref_depots))
        for r in intersect(resources[d1], ref_resources[d2])
            push!(shared_resources, r)
        end
    end
    
    return sort(collect(shared_resources))
end

end # module
