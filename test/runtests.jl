using Pkg, DepotCompactor, Test
using Pkg.Types: PackageSpec

function with_depot_path(f::Function, new_path::Vector{String})
    old_depot_path = copy(Base.DEPOT_PATH)
    empty!(Base.DEPOT_PATH)
    append!(Base.DEPOT_PATH, new_path)
    try
        f()
    finally
        empty!(Base.DEPOT_PATH)
        append!(Base.DEPOT_PATH, old_depot_path)
    end
end

# Generate two depots, which share a single package:
function generate_depot(path::String, packages::Vector{PackageSpec})
    rm(path; recursive=true, force=true)
    outside_registries = joinpath(Pkg.depots1(), "registries")
    Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true
    withenv("JULIA_PKG_PRECOMPILE_AUTO" => "false") do
        with_depot_path([path]) do
            # Manually copy in our registries, so that we don't install it again and again
            mkpath(joinpath(path, "registries"))
            for fname in ("General.toml", "General.tar.gz")
                cp(joinpath(outside_registries, fname), joinpath(path, "registries", fname))
            end
            Pkg.activate("@v#.#") do
                if !isempty(packages)
                    Pkg.add(packages)
                end
            end
        end
    end
end

# Function to create test depots
function initialize_depots(dir::String)
    generate_depot(joinpath(dir, "depot1"), [
        PackageSpec(;name="Zstd_jll", version=v"1.5.4"),
        PackageSpec(;name="Nettle"),
    ])
    generate_depot(joinpath(dir, "depot2"), [
        PackageSpec(;name="Zstd_jll", version=v"1.5.4"),
        PackageSpec(;name="Example"),
    ])
    generate_depot(joinpath(dir, "depot3"), [
        PackageSpec(;name="Example"),
        PackageSpec(;name="Nettle_jll"),
    ])
    generate_depot(joinpath(dir, "depot4"), [
        PackageSpec(;name="Scratch"),
    ])
    generate_depot(joinpath(dir, "depot5"), Pkg.Types.PackageSpec[])
    return [
        joinpath(dir, "depot1"),
        joinpath(dir, "depot2"),
        joinpath(dir, "depot3"),
        joinpath(dir, "depot4"),
        joinpath(dir, "depot5"),
    ]
end

@testset "DepotCompactor" begin
    mktempdir() do dir
        # Initialize depots for our tests
        depots = initialize_depots(dir)
        resources = collect_depot_resources.(depots)

        # depot5 is purposefully empty, we'll compact into it in the future:
        @test isempty(resources[5])

        # Check that we can see the resources we expect in each depot
        function check_resource_presences(resource::String, resources::Vector{Vector{String}}, containing_depots = collect(1:length(resources)))
            for depot_idx in 1:length(resources)
                @test any(occursin(resource, r) for r in resources[depot_idx]) == (depot_idx in containing_depots)
            end
        end
        
        check_resource_presences("packages/Zstd_jll", resources, [1, 2])
        check_resource_presences("packages/Example", resources, [2, 3])
        check_resource_presences("packages/Nettle_jll", resources, [1, 3])
        check_resource_presences("packages/Scratch", resources, [4])

        # Check that checking shared resources works as expected:
        check_resource_presences("packages/Zstd_jll", [collect_shared_resources(depots[[1,2]])])
        check_resource_presences("packages/Example", [collect_shared_resources(depots[[2,3]])])
        check_resource_presences("packages/Nettle_jll", [collect_shared_resources(depots[[1,3]])])
        @test isempty(collect_shared_resources(depots[[1,4]]))
        @test isempty(collect_shared_resources(depots[[2,4]]))
        @test isempty(collect_shared_resources(depots[[3,4]]))

        # Test special case of trying to look at shared resources between a depot and itself
        for idx in 1:length(depots)
            @test isempty(collect_shared_resources(depots[[idx,idx]]))
        end

        # Test that compacting into a new depot grabs everything we expect.
        # Note that we compact depots 1 and 2, but while we still use 3 as a reference
        # depot, we don't compact it:
        compact_depots(depots[5], depots[1:2]; ref_depots=depots[1:4])

        resources = collect_depot_resources.(depots)
        @test !isempty(resources[5])

        # Now that we've compacted, these shared resources exist only in 5 and 3:
        check_resource_presences("packages/Zstd_jll", resources, [5])
        check_resource_presences("packages/Example", resources, [3, 5])
        check_resource_presences("packages/Nettle_jll", resources, [3, 5])

        # Non-shared resources exist only in their original locations, they were not compacted.
        check_resource_presences("packages/Scratch", resources, [4])
    end
end
