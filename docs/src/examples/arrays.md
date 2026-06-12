# Arrays & NumPy

The `arrx` example (`examples/arrx/`) exposes 1-D numeric arrays. Inputs are
zero-copy from any Python buffer; outputs come back as `numpy.ndarray`.

## The Julia source

```julia
# arrx.jl
using ParselTongue

@pymodule arrx begin
    @pyfunc sum_f64(v::Vector{Float64})::Float64 = sum(v)
    @pyfunc scale_f64(v::Vector{Float64}, k::Float64)::Vector{Float64} = v .* k
    @pyfunc cumsum_i64(v::Vector{Int64})::Vector{Int64} = cumsum(v)
    @pyfunc dot_f32(a::Vector{Float32}, b::Vector{Float32})::Float32 = sum(a .* b)
end
```

## Build it

```julia
using ParselTongue
build_wheel("arrx.jl")
```

```bash
pip install dist/arrx-0.1.0-*.whl
```

## Use it from Python

Inputs accept anything that exports the buffer protocol — NumPy arrays,
`array.array`, `memoryview` — with no copy:

```python
>>> import arrx, numpy as np
>>> x = np.array([1.0, 2.0, 3.0, 4.0])
>>> arrx.sum_f64(x)
10.0
>>> arrx.scale_f64(x, 10.0)
array([10., 20., 30., 40.])           # returns an ndarray
>>> arrx.cumsum_i64(np.array([5, 5, 5], dtype=np.int64))
array([ 5, 10, 15])
>>> arrx.dot_f32(np.array([1,2,3], np.float32), np.array([4,5,6], np.float32))
32.0
```

It works without NumPy too — `array.array` for input, and array returns degrade
to a `memoryview`:

```python
>>> import arrx, array
>>> arrx.sum_f64(array.array("d", [1.0, 2.0, 3.0]))
6.0
```

## NumPy is transparent, never a build dependency

- **Input:** the shim calls `PyObject_GetBuffer`, giving a pointer + length that
  Julia views zero-copy with `unsafe_wrap`. The element **size** is checked, so a
  `float32` array passed where `Float64` is expected raises `TypeError`.
- **Output:** the result is copied into a Python `bytearray`, then — *at runtime*
  — the shim imports NumPy (if available) and calls `numpy.frombuffer` to return
  an `ndarray`. If NumPy is not importable, it returns a `memoryview` instead.
  NumPy is declared only as an optional extra; it is never needed to *build* the
  extension.

## N-dimensional arrays

Matrices and tensors work too. The **argument type** picks the row/column-major
policy (both zero-copy):

```julia
@pymodule la begin
    # logical view: NumPy's shape and indexing (A[i,j] == a[i,j]); great for loops
    @pyfunc rowsums(A::AbstractMatrix{Float64})::Vector{Float64} = vec(sum(A, dims=2))
    # dense Array: BLAS-friendly, but a C-order input arrives transposed
    @pyfunc tr(A::Matrix{Float64})::Float64 = sum(i -> A[i,i], 1:size(A,1))
end
```

```python
>>> import numpy as np, la
>>> A = np.array([[1., 2., 3.], [4., 5., 6.]])   # shape (2, 3), C-order
>>> la.rowsums(A)                                # AbstractMatrix → natural shape
array([ 6., 15.])
```

A returned array always comes back in **natural** shape. See
[Boundary Types → N-D arrays](/guide/boundary-types#N-D-arrays-the-dual-policy)
for the policy rationale, and the [Statistics / scientific example](/examples/scientific)
for matmul, complex, in-place, and tuple returns together.
