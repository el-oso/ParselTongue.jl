# API Reference

```@meta
CurrentModule = ParselTongue
```

## Exporting functions

```@docs
@pyfunc
@pymodule
```

## Custom exceptions

```@docs
@pyerror
```

## Opaque handle types

```@docs
@pyhandle
@pymethod
PtHandle
```

Scalar fields of a `@pyhandle` type are automatically exposed as read-only Python
attributes (`p.x`); no annotation is required. `@pymethod` attaches a Python
dunder (`__repr__` or `__str__`) implemented by a Julia function.

## Building

```@docs
build_extension
build_wheel
build_multi_wheel
build_runtime_wheel
```

## Diagnostics

```@docs
startup_benchmark
bundle_size_report
```

## Boundary type system

```@docs
PyBoundary
Mut
c_abi_type
from_c
to_c
@boundary
```

## Boundary types

```@docs
PtVarArgs
PyCallable
```

## Index

```@index
```
