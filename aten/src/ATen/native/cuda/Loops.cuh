#pragma once

// This file provides two functions to help write GPU elementwise kernels:
//
//   gpu_kernel(TensorIterator iter, <lambda>)
//   gpu_kernel_with_scalars(TensorIterator iter, <lambda>)
//
// The gpu_kernel_with_scalars generates specializations that support a
// single scalar CPU argument, such as from `cuda_tensor + 5`. The CPU scalar
// is lifted to a kernel parameter instead of copying to device memory.
// This should be  used in conjunction with TensorIterator::allow_cpu_scalars_,
// which is the default for TensorIterator::binary_op. Otherwise, all inputs
// and the output must be on the GPU.
//
// For example, to write a reciprocal kernel for GPU float Tensors:
//
//   gpu_kernel(iter, []GPU_LAMBDA(float a) {
//    return 1.0f / a;
//   });
//
// To write a multiplication kernel for GPU float Tensors where one argument
// may be a CPU scalar:
//
//   gpu_kernel_with_scalars(iter, []GPU_LAMBDA(float a, float b) {
//     return a * b;
//   });
//
// See BinaryOpsKernel.cu for the complete implementation
//

#include <type_traits>

#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/core/Array.h>
#include <ATen/cuda/detail/OffsetCalculator.cuh>
#include <ATen/detail/FunctionTraits.h>
#include <ATen/native/TensorIterator.h>
#include <c10/macros/Macros.h>
#include <c10/util/TypeCast.h>

// Marks a lambda as executable on both the host and device. The __host__
// attribute is important so that we can access static type information from
// the host, even if the function is typically only executed on the device.
#ifndef GPU_LAMBDA
#define GPU_LAMBDA __host__ __device__
#endif

#ifdef __NVCC__
#define ASSERT_HOST_DEVICE_LAMBDA(type) \
  static_assert(__nv_is_extended_host_device_lambda_closure_type(type), \
                #type " must be a __host__ __device__ lambda")
#else
#define ASSERT_HOST_DEVICE_LAMBDA(type)
#endif

static constexpr int launch_size_1d = 512;
static constexpr int launch_size_nd = 128;
static constexpr int launch_bound2 = 4;


namespace at { namespace native {

// NOTE: @zasdfgbnm is currently working on rewriting the gpu loops.
// Some of the old codes has been moved to namespace legacy, and
// new codes will be put into namespace modern. These two namespaces
// will coexists for a while until the rewrite is done. Once the rewrite
// is done, we will remove the legacy and modern namespace and everything
// will be in at::native directly.
namespace legacy {

template<int nt, int vt, typename func_t>
C10_LAUNCH_BOUNDS_2(nt, launch_bound2)
__global__ void elementwise_kernel(int N, func_t f) {
  int tid = threadIdx.x;
  int nv = nt * vt;
  int idx = nv * blockIdx.x + tid;
  #pragma unroll
  for (int i = 0; i < vt; i++) {
    if (idx < N) {
      f(idx);
      idx += nt;
    }
  }
}

template<int N>
static OffsetCalculator<N> make_offset_calculator(const TensorIterator& iter) {
  AT_ASSERT(N == iter.ntensors());
  std::array<const int64_t*, N> strides;
  for (int i = 0; i < N; i++) {
    strides[i] = iter.strides(i).data();
  }
  return OffsetCalculator<N>(iter.ndim(), iter.shape().data(), strides.data());
}

template<int nt, int vt, typename func_t>
static void launch_kernel(int64_t N, const func_t& f) {
  TORCH_INTERNAL_ASSERT(N >= 0 && N <= std::numeric_limits<int32_t>::max());
  if (N == 0) {
    return;
  }
  dim3 block(nt);
  dim3 grid((N + block.x * vt - 1) / (block.x * vt));
  auto stream = at::cuda::getCurrentCUDAStream();
  elementwise_kernel<nt, vt, func_t><<<grid, block, 0, stream>>>(N, f);
  AT_CUDA_CHECK(cudaGetLastError());
}

template <typename traits, typename func_t, typename index_t, size_t... INDEX>
C10_HOST_DEVICE typename traits::result_type
invoke_impl(const func_t &f, char *const C10_RESTRICT data[], const index_t strides[], int i,
            std::index_sequence<INDEX...>) {
  return f(*(typename traits::template arg<INDEX>::type*)(data[INDEX] + i * strides[INDEX])...);
}

template <typename func_t, typename index_t, typename traits = function_traits<func_t>>
C10_HOST_DEVICE typename traits::result_type
invoke(const func_t &f, char *const C10_RESTRICT data[], const index_t strides[], int i) {
  using Indices = std::make_index_sequence<traits::arity>;
  return invoke_impl<traits>(f, data, strides, i, Indices{});
}

template <typename traits, typename func_t, typename index_t, size_t... I>
C10_HOST_DEVICE typename traits::result_type
invoke_impl(const func_t &f, char *const C10_RESTRICT data[], const index_t strides[], const ScalarType dtypes[], int i,
            std::index_sequence<I...>) {
  return f(c10::fetch_and_cast<typename traits::template arg<I>::type>(dtypes[I], data[I] + i * strides[I])...);
}

template <typename func_t, typename index_t, typename traits = function_traits<func_t>>
C10_HOST_DEVICE typename traits::result_type
invoke(const func_t &f, char *const C10_RESTRICT data[], const index_t strides[], const ScalarType dtypes[], int i) {
  using Indices = std::make_index_sequence<traits::arity>;
  return invoke_impl<traits>(f, data, strides, dtypes, i, Indices{});
}

// similar to above code but work on lambda using index for calculation
template <typename traits, typename func_t, typename index_t, size_t... INDEX>
C10_HOST_DEVICE typename traits::result_type
invoke_with_index_impl(const func_t &f, char* const C10_RESTRICT data[], const index_t strides[], int i, int idx,
                       std::index_sequence<INDEX...>) {
  return f(*(typename traits::template arg<INDEX>::type*)(data[INDEX] + i * strides[INDEX])..., idx);
}

template <typename func_t, typename index_t, typename traits = function_traits<func_t>>
C10_HOST_DEVICE typename traits::result_type
invoke_with_index(const func_t &f, char* const C10_RESTRICT data[], const index_t strides[], int i, int idx) {
  // index at last position
  using Indices = std::make_index_sequence<traits::arity-1>;
  return invoke_with_index_impl<traits>(f, data, strides, i, idx, Indices{});
}

template <typename traits, typename func_t, typename index_t, size_t... I>
C10_HOST_DEVICE typename traits::result_type
invoke_with_index_impl(const func_t &f, char* const C10_RESTRICT data[], const index_t strides[], const ScalarType dtypes[],
                       int i, int idx, std::index_sequence<I...>) {
  return f(c10::fetch_and_cast<typename traits::template arg<I>::type>(dtypes[I], data[I] + i * strides[I])..., idx);
}

template <typename func_t, typename index_t, typename traits = function_traits<func_t>>
C10_HOST_DEVICE typename traits::result_type
invoke_with_index(const func_t &f, char* const C10_RESTRICT data[], const index_t strides[], const ScalarType dtypes[],
                  int i, int idx) {
  // index at last position
  using Indices = std::make_index_sequence<traits::arity-1>;
  return invoke_with_index_impl<traits>(f, data, strides, dtypes, i, idx, Indices{});
}

} // namespace legacy

// See the note for namespace legacy above.
namespace modern {

namespace detail {

template <typename func_t, typename array_t, std::size_t... I>
__device__ inline constexpr decltype(auto) invoke_with_array_impl(func_t f, array_t t, std::index_sequence<I...>)
{
    return f(t[I]...);
}
template <typename func_t, typename array_t>
__device__ inline constexpr decltype(auto) invoke_with_array(func_t f, array_t a) {
  constexpr auto arity = function_traits<func_t>::arity;
  return invoke_with_array_impl(f, a, std::make_index_sequence<arity>{});
}

namespace arg_type {

// We need a way to compute the argument type of a function. But
// for nullary function, it does not really have an argument type
// in this case, we still need to return a valid type, but we don't
// really care what type this is.

struct dont_care {};

template <typename func_t, std::size_t arity>
struct arg_type_helper {
  using type = typename function_traits<func_t>::template arg<0>::type;
};

template <typename func_t>
struct arg_type_helper<func_t, 0> {
  using type = dont_care;
};

template <typename func_t>
using type = typename arg_type_helper<func_t, function_traits<func_t>::arity>::type;

}  // namespace arg_type

}  // namespace detail

template<int nt, int vt, typename func_t, typename array_t>
C10_LAUNCH_BOUNDS_1(nt)
__global__ void elementwise_kernel(int N, func_t f, array_t data) {
  // Assumption:
  // 1. all arguments of `f` have the same type, which could be different from the return type of `f`
  // 2. all tensors are contiguous, that is: stride == sizeof(type) for all tensors

  using traits = function_traits<func_t>;
  using return_t = typename traits::result_type;
  using arg_t = detail::arg_type::type<func_t>;
  constexpr int arity = traits::arity;

  // We need to create array to hold all the arguments, for nullary `f`, this means array of size 0.
  // Unfortunately the compiler don't allow us to create array of 0 size, so for this case, we create
  // an array of size 1 and just don't use it.
  constexpr int nargs = traits::arity == 0 ? 1 : traits::arity;

  int tid = threadIdx.x;
  int nv = nt * vt;
  int idx = nv * blockIdx.x + tid;

  // compute base pointers
  return_t *result_base = reinterpret_cast<return_t *>(data[0]) + idx;
  arg_t *args_base[nargs];
  #pragma unroll
  for (int i = 0; i < arity; i++) {
    args_base[i] = reinterpret_cast<arg_t *>(data[i + 1]) + idx;
  }

  // fetch data
  return_t results[vt];
  arg_t args[vt][nargs];
  #pragma unroll
  for (int i = 0; i < vt; i++) {
    if (idx + nt * i < N) {
      #pragma unroll
      for (int j = 0; j < arity; j++) {
        args[i][j] = *(args_base[j] + i * nt);
      }
    }
  }

  // compute
  #pragma unroll
  for (int i = 0; i < vt; i++) {
    if (idx + nt * i < N) {
      results[i] = detail::invoke_with_array<func_t, arg_t[nargs]>(f, args[i]);
    }
  }

  // store data
  #pragma unroll
  for (int i = 0; i < vt; i++) {
    if (idx + nt * i < N) {
      *(result_base + i * nt) = results[i];
    }
  }
}

// TODO (@zasdfgbnm): this function assume trivial 1d and no dynamic casting
template<int nt, int vt, typename func_t, typename array_t>
static void launch_kernel(int64_t N, const func_t& f, array_t data) {
  TORCH_INTERNAL_ASSERT(N >= 0 && N <= std::numeric_limits<int32_t>::max());
  if (N == 0) {
    return;
  }
  dim3 block(nt);
  dim3 grid((N + block.x * vt - 1) / (block.x * vt));
  auto stream = at::cuda::getCurrentCUDAStream();
  elementwise_kernel<nt, vt, func_t, array_t><<<grid, block, 0, stream>>>(N, f, data);
  AT_CUDA_CHECK(cudaGetLastError());
}

} // namespace modern

template <typename func_t>
void gpu_kernel_impl(TensorIterator& iter, const func_t& f) {
  using traits = function_traits<func_t>;
  using arg0_t = typename traits::result_type;
  constexpr int ntensors = traits::arity + 1;

  TORCH_INTERNAL_ASSERT(iter.can_use_32bit_indexing());
  TORCH_INTERNAL_ASSERT(iter.ntensors() == traits::arity + 1);

  at::detail::Array<char*, ntensors> data;
  for (int i = 0; i < ntensors; i++) {
    data[i] = (char*)iter.data_ptr(i);
  }

  at::detail::Array<ScalarType, ntensors> dtypes;
  for (int i = 0; i < ntensors; i++) {
    dtypes[i] = iter.tensor(i).scalar_type();
  }

  int64_t numel = iter.numel();
  if (iter.is_trivial_1d()) {
    auto inner_strides = iter.get_inner_strides();
    at::detail::Array<int, ntensors> strides;
    for (int i = 0; i < ntensors; i++) {
      strides[i] = inner_strides[i];
    }

    if (iter.needs_dynamic_casting()) {
      legacy::launch_kernel<launch_size_1d, 1>(numel, [=]GPU_LAMBDA(int idx) {
        void* out = data[0] + strides[0] * idx;
        arg0_t result = legacy::invoke(f, &data.data[1], &strides.data[1], &dtypes.data[1], idx);
        c10::cast_and_store<arg0_t>(dtypes[0], out, result);
      });
    } else if (iter.has_contiguous_first_dim()) {
      modern::launch_kernel<C10_WARP_SIZE * 2, 4>(numel, f, data);
    } else {
      legacy::launch_kernel<launch_size_1d, 1>(numel, [=]GPU_LAMBDA(int idx) {
        arg0_t* out = (arg0_t*)(data[0] + strides[0] * idx);
        *out = legacy::invoke(f, &data.data[1], &strides.data[1], idx);
      });
    }
  } else {
    auto offset_calc = legacy::make_offset_calculator<traits::arity + 1>(iter);
    if (iter.needs_dynamic_casting()) {
      legacy::launch_kernel<launch_size_nd, launch_bound2>(numel, [=]GPU_LAMBDA(int idx) {
        auto offsets = offset_calc.get(idx);
        void* out = data[0] + offsets[0];
        arg0_t result = legacy::invoke(f, &data.data[1], &offsets.data[1], &dtypes.data[1], 1);
        c10::cast_and_store<arg0_t>(dtypes[0], out, result);
      });
    } else {
      legacy::launch_kernel<launch_size_nd, launch_bound2>(numel, [=]GPU_LAMBDA(int idx) {
        auto offsets = offset_calc.get(idx);
        arg0_t* out = (arg0_t*)(data[0] + offsets[0]);
        *out = legacy::invoke(f, &data.data[1], &offsets.data[1], 1);
      });
    }
  }
}

template <typename func_t>
void gpu_kernel(TensorIterator& iter, const func_t& f) {
  ASSERT_HOST_DEVICE_LAMBDA(func_t);

  for (int arg = 0; arg < iter.ntensors(); arg++) {
    TORCH_INTERNAL_ASSERT(iter.device(arg).is_cuda());
  }

  if (iter.numel() == 0) {
    return;
  }

  if (!iter.can_use_32bit_indexing()) {
    for (auto& sub_iter : iter.with_32bit_indexing()) {
      gpu_kernel(sub_iter, f);
    }
    return;
  }

  gpu_kernel_impl(iter, f);
}

template <typename func_t>
void gpu_kernel_with_scalars(TensorIterator& iter, const func_t& f) {
  ASSERT_HOST_DEVICE_LAMBDA(func_t);
  TORCH_INTERNAL_ASSERT(iter.ntensors() == 3);

  using traits = function_traits<func_t>;
  static_assert(
      traits::arity == 2,
      "gpu_kernel_with_scalars only supports two input arguments");

  if (iter.is_cpu_scalar(1)) {
    using arg1_t = typename traits::template arg<0>::type;
    using arg2_t = typename traits::template arg<1>::type;
    auto a = iter.scalar_value<arg1_t>(1);
    iter.remove_operand(1);
    gpu_kernel(iter, [=]GPU_LAMBDA(arg2_t b) {
      return f(a, b);
    });
  } else if (iter.is_cpu_scalar(2)) {
    using arg1_t = typename traits::template arg<0>::type;
    using arg2_t = typename traits::template arg<1>::type;
    auto b = iter.scalar_value<arg2_t>(2);
    iter.remove_operand(2);
    gpu_kernel(iter, [=]GPU_LAMBDA(arg1_t a) {
      return f(a, b);
    });
  } else {
    gpu_kernel(iter, f);
  }
}

template <typename func_t>
void gpu_kernel_with_index_impl(TensorIterator& iter, const func_t& f) {
  using traits = function_traits<func_t>;
  using arg0_t = typename traits::result_type;
  // need to +1(output) and -1(index)
  constexpr int ntensors = traits::arity;
  TORCH_INTERNAL_ASSERT(iter.ntensors() == traits::arity);

  at::detail::Array<char*, ntensors> data;
  for (int i = 0; i < ntensors; i++) {
    data[i] = (char*)iter.data_ptr(i);
  }

  at::detail::Array<ScalarType, ntensors> dtypes;
  for (int i = 0; i < ntensors; i++) {
    dtypes[i] = iter.tensor(i).scalar_type();
  }

  int64_t numel = iter.numel();
  if (iter.is_trivial_1d()) {
    auto inner_strides = iter.get_inner_strides();
    at::detail::Array<int, ntensors> strides;
    for (int i = 0; i < ntensors; i++) {
      strides[i] = inner_strides[i];
    }

    if (iter.needs_dynamic_casting()) {
      legacy::launch_kernel<launch_size_1d, 1>(numel, [=]GPU_LAMBDA(int idx) {
        void* out = data[0] + strides[0] * idx;
        arg0_t result = legacy::invoke_with_index(f, &data.data[1], &strides.data[1], &dtypes.data[1], idx, idx);
        c10::cast_and_store<arg0_t>(dtypes[0], out, result);
      });
    } else {
      legacy::launch_kernel<launch_size_1d, 1>(numel, [=]GPU_LAMBDA(int idx) {
        arg0_t* out = (arg0_t*)(data[0] + strides[0] * idx);
        *out = legacy::invoke_with_index(f, &data.data[1], &strides.data[1], idx, idx);
      });
    }
  } else {
    auto offset_calc = legacy::make_offset_calculator<traits::arity>(iter);
    if (iter.needs_dynamic_casting()) {
      legacy::launch_kernel<launch_size_nd, launch_bound2>(numel, [=]GPU_LAMBDA(int idx) {
        auto offsets = offset_calc.get(idx);
        void* out = data[0] + offsets[0];
        arg0_t result = legacy::invoke_with_index(f, &data.data[1], &offsets.data[1], &dtypes.data[1], 1, idx);
        c10::cast_and_store<arg0_t>(dtypes[0], out, result);
      });
    } else {
      legacy::launch_kernel<launch_size_nd, launch_bound2>(numel, [=]GPU_LAMBDA(int idx) {
        auto offsets = offset_calc.get(idx);
        arg0_t* out = (arg0_t*)(data[0] + offsets[0]);
        *out = legacy::invoke_with_index(f, &data.data[1], &offsets.data[1], 1, idx);
      });
    }
  }
}

template <typename func_t>
void gpu_kernel_with_index(TensorIterator& iter, const func_t& f) {
  ASSERT_HOST_DEVICE_LAMBDA(func_t);

  for (int arg = 0; arg < iter.ntensors(); arg++) {
    TORCH_INTERNAL_ASSERT(iter.device(arg).is_cuda(), "gpu_kernel_with_index only support cuda tensor.");
  }

  if (iter.numel() == 0) {
    return;
  }

  // Split will change index, thus is not supported
  // The caller should handle the split and pass in different func
  TORCH_INTERNAL_ASSERT(iter.can_use_32bit_indexing(), "gpu_kernel_with_index only support 32-bit indexing.");

  gpu_kernel_with_index_impl(iter, f);
}

}} // namespace at::native
