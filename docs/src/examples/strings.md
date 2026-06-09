# Strings

The `strx` example (`examples/strx/`) shows `String` arguments and returns.

## The Julia source

```julia
# strx.jl
using ParselTongue

@pymodule strx begin
    @pyfunc greet(name::String)::String = "Hello, " * name * "!"
    @pyfunc shout(s::String)::String = uppercase(s)
    @pyfunc strlen(s::String)::Int64 = Int64(length(s))
end
```

## Build it

```julia
using ParselTongue
build_wheel("strx.jl")
```

```bash
pip install dist/strx-0.1.0-*.whl
```

## Use it from Python

```python
>>> import strx
>>> strx.greet("World")
'Hello, World!'
>>> strx.shout("hello")
'HELLO'
>>> strx.strlen("café")     # Julia length counts characters, not bytes
4
```

## How strings cross the boundary

- **Arguments** arrive as a borrowed, NUL-terminated UTF-8 buffer (valid for the
  duration of the call) and are copied into a Julia `String`.
- **Returns** are copied into a freshly `malloc`'d C buffer; the CPython shim
  builds a Python `str` from it and immediately frees the buffer. Julia
  allocates, C frees — so there is no dependence on Julia GC timing across the
  call boundary.

This pattern was stress-tested with hundreds of thousands of calls returning
varying-length strings without leaks or crashes.
