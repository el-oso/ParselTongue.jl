using ParselTongue

@pymodule strlistx begin
    # Vector{String} arg: Python list[str] → Julia Vector{String}
    @pyfunc join_words(ws::Vector{String})::String = join(ws, " ")

    # Vector{String} return: Julia Vector{String} → Python list[str]
    @pyfunc words(s::String)::Vector{String} = String.(split(s))

    # NamedTuple return: Julia NamedTuple → Python dict
    @pyfunc describe(v::Vector{Float64})::NamedTuple{(:min, :max, :mean, :n),
                                                      Tuple{Float64, Float64, Float64, Int64}} =
        (min=minimum(v), max=maximum(v), mean=sum(v)/length(v), n=Int64(length(v)))
end
