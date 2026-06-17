using ParselTongue

# Deliberately trim-unsafe: inferencebarrier returns Any, so `+` is a dynamic dispatch
# that juliac --trim=safe rejects. Used to verify ParselTongue surfaces an actionable,
# source-mapped TrimFailure (not the raw verifier dump).
@pymodule trimbad begin
    @pyfunc dyn(n::Int64)::Int64 = Base.inferencebarrier(n) + 1
end
