/***************************************************************************************************
 * Copyright (c) 2017 - 2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 * list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 **************************************************************************************************/

/**
This example shows how to run matrix multiplication kernels using functions and data structures
provided by CUTLASS using tensor cores; which we run on a NVIDIA Turing GPU.

Writing a single high performance matrix multiplication kernel is hard but do-able. Whereas writing
high performance kernels at scale which works for multiple problem sizes with good abstractions is
really hard. CUTLASS solves this problem by providing simplified abstractions to compose
multiple sections of gemm kernel. When used properly, the kernels can hit peak performance of GPU
easily.

CUTLASS divides a kernel into hierarchical composable sections. Which means, at each thread, warp
and thread-block level, they compute on their own tile-size with higher level of tile sizes being
composed from lower level ones. Multiple thread-tiles (tile size each thread computes) can be used
to form warp-tiles (tile size each warp computes) and multiple warp tiles can be used to compute
threadblock-tile (tile size computed by a threadblock).

In thie example, we split variable initialization into
1. Setting up data properties : describes how matrices are laid out in the memory and how the kernel
can view them (logical to physical mapping)
2. Setting up computation properties : describes how the above set matrices will be used to compute
output of matrix multiplication.

First, we setup the data types of matrices A, B, C and D along with alpha, beta as the equation for
GEMM is D = alpha * A * B + beta * C. In CUTLASS, the kernels first compute A * B and leaves the
rest of the computation to end of the kernel as alpha * X + beta * C is a simple element-wise
operation on X (A * B) and C. We call this as epilogue of kernel. Hence, we setup data types for
alpha and beta to be equal to ElementComputeEpilogue = int32_t. As we want to use MMA instructions
on Turing and they support 8-bit signed integer (int8_t), we use data type for elements in input
matrix A and B as int8_t. Volta also supports accumulation of partial dot product to int32_t, which
can store wider range of numbers, we use it as data type of output matrix elements and accumulation.
We convey this to CUTLASS kernel by initializing template variables ElementAccumulator (int32_t),
ElementComputeEpilogue (int32_t), ElementInputA (int8_t), ElementInputB (int8_t), ElementOutput
(int32_t). Communicating just the data type is not enough. As the data is laid out linearly in
memory, we have to convey the layout of matrices. We do that by initializing template variable
LayoutInputA to column major cutlass variable, LayoutInputB to row major and LayoutOutput to row
major. Next, we setup rules to comptue alpha * X + beta * C which is called epilogue of the kernel.
We initialize template variable EpilogueOp, which takes the data type of output ElementOutput
(int32_t), the number of elements per vector memory access (16), data type of accumulator (int32_t)
and data type of computation of linear combination (alpha * X + beta * C).

Now that we setup the properties of data, we have to setup properties of computation.

Second, we create template variables of tile sizes for thread-block, warp and mma-op to 128x256x64,
64x64x16, 8x8x16 (MxNxK) respectively. When passed to instantiate CUTLASS GEMM kernel, it internally
deduce the amount of threads needed per thread-block, amount of shared memory, storing data in
bank-conflict free manner, and ton of other variables required to compose, intialize and launch a
high performance GEMM kernel. This is the beauty of CUTLASS, it relieves developer from
understanding and coding complicated hardware optimizations which can easily go wrong.

CUTLASS also supports multiple MMA pipelines in a threadblock. What are MMA pipelines? MMA pipelines
constitute the whole process of loading input data from global memory to shared memory, loading data
from shared memory to registers, doing matrix multiplication, store to global memory. The below flow
sequence shows a typical mma pipeline.

matrix in global memory -> registers -> tile in shared memory -> registers -> mma -> registers ->
output to global memory

The problem with single pipeline is, each stage is synchronous which means, each stage has to wait
until the previous finished executing. There are stages in the pipeline which do not have fixed
latency, for example, the loads from global memory and shared memory. Therefore, we can add one more
pipeline with a phase shift in mma kernel to hide latency from global and shared memory loads.
Finally, the pipeline in a kernel looks like

(1) matrix in global memory -> (2) registers -> (3) tile in shared memory -> (4) registers -> (5)
mma -> (6) registers -> (7) output to global memory (1) <null> -> (2) <null> -> (3) matrix in global
memory -> (4) registers -> (5) tile in shared memory -> (6) registers -> (7) mma -> (8) registers ->
(9) output to global memory

This way, you can hide the second global memoroy load latency by doing computation on already loaded
input data.

There are few more template variables initialized such as, which threadblock tile of output matrix
is done which threadblock launched on an SM, CUDA SM architecture of GPU you want to run on.

These are all put together to create a template variable which describes CUTLASS GEMM kernel using
cutlass::gemm::device::Gemm template.

The next step is to intialize physical data, instantiate and initialize CUTLASS kernel and run it.
We use CUTLASS utilities to initialize, fill, compare matrices as they are simple and doesn't come
in the way of learning CUTLASS.

Once all the matrices are initialized and filled with data, create arguments tuple to launch CUTLASS
kernel which takes problem size (M = 5120, N = 4096 and K = 4096), matrices, alpha, beta and the
important one, split k-dimension factor. Along with that, we query CUTLASS if any scratch-space
memory required by the kernel we instantiated. If yes, we create it and pass it along with other
arguments created to intialize CUTLASS kernel then, the kernel is launched.

In this example, we later on launch a reference gemm kernel (from CUTLASS utilities) to compare if
the output from CUTLASS kernel is same as reference GEMM kernel.
*/

#include <iostream>
#include <vector>
#include <string>
#include <cstdlib>

#include <cuda_runtime.h>

#include "cutlass/cutlass.h"
#include "device/gemm.h"
// #include "cutlass/gemm/device/gemm.h"
#include "cutlass/util/host_tensor.h"
#include "cutlass/util/reference/device/gemm.h"
#include "cutlass/util/reference/host/tensor_compare.h"
#include "cutlass/util/reference/host/tensor_copy.h"
#include "cutlass/util/reference/host/tensor_fill.h"
#include "cutlass/util/tensor_view_io.h"
#include "helper.h"

const int M_GLOBAL = M_GLOBAL_VAL;
const int K_GLOBAL = K_GLOBAL_VAL;
const int N_GLOBAL = N_GLOBAL_VAL;

#define BLOCK_SIZE_N 64
#define BLOCK_SIZE_K 64

#define checkCudaErrors(func)                                                      \
    {                                                                              \
        cudaError_t e = (func);                                                    \
        if (e != cudaSuccess)                                                      \
            printf("%s %d CUDA: %s\n", __FILE__, __LINE__, cudaGetErrorString(e)); \
    }

// The code section below describes datatype for input, output matrices and computation between
// elements in input matrices.
// using ElementAccumulator = float;                 // <- data type of accumulator
// using ElementComputeEpilogue = float;  // <- data type of epilogue operations
// using ElementInputA = cutlass::half_t;                       // <- data type of elements in input matrix A
// using ElementInputB = cutlass::half_t;                       // <- data type of elements in input matrix B
// using ElementOutput = cutlass::half_t;                      // <- data type of elements in output matrix D

using ElementComputeEpilogue = float; // <- data type of epilogue operations
using ElementAccumulator = int32_t;
using ElementInputA = int8_t;
using ElementInputB = int8_t;
using ElementOutput = int32_t;

// The code section below describes matrix layout of input and output matrices. Column Major for
// Matrix A, Row Major for Matrix B and Row Major for Matrix C
using LayoutInputA = cutlass::layout::RowMajor;
using LayoutInputB = cutlass::layout::ColumnMajor;
using LayoutOutput = cutlass::layout::RowMajor;

// This code section describes whether you want to use tensor cores or regular SIMT cores on GPU SM
using MMAOp = cutlass::arch::OpClassTensorOp;

// This code section describes CUDA SM architecture number
using SmArch = cutlass::arch::Sm75;

// This code section describes the tile size a thread block will compute
using ShapeMMAThreadBlock =
    cutlass::gemm::GemmShape<128, BLOCK_SIZE_N, BLOCK_SIZE_K>; // <- threadblock tile M = 128, N = 256, K = 64
// This code section describes tile size a warp will compute
using ShapeMMAWarp = cutlass::gemm::GemmShape<32, 32, BLOCK_SIZE_K>; // <- warp tile M = 64, N = 64, K = 64
// This code section describes the size of MMA op
using ShapeMMAOp = cutlass::gemm::GemmShape<8, 8, 16>; // <- MMA Op tile M = 8, N = 8, K = 16

// This code section describes how threadblocks are scheduled on GPU
using SwizzleThreadBlock = cutlass::gemm::threadblock::GemmIdentityThreadblockSwizzle<>; // <- ??

// This code section describes the epilogue part of the kernel
using EpilogueOp = cutlass::epilogue::thread::LinearCombination<
    ElementOutput,                                    // <- data type of output matrix
    128 / cutlass::sizeof_bits<ElementOutput>::value, // <- the number of elements per vectorized
                                                      // memory access. For a byte, it's 16
                                                      // elements. This becomes the vector width of
                                                      // math instructions in the epilogue too
    ElementAccumulator,                               // <- data type of accumulator
    ElementComputeEpilogue>;                          // <- data type for alpha/beta in linear combination function

// Number of pipelines you want to use
constexpr int NumStages = 2;

using Gemm = cutlass::gemm::device::Gemm_Sparse<ElementInputA,
                                                LayoutInputA,
                                                ElementInputB,
                                                LayoutInputB,
                                                ElementOutput,
                                                LayoutOutput,
                                                ElementAccumulator,
                                                MMAOp,
                                                SmArch,
                                                ShapeMMAThreadBlock,
                                                ShapeMMAWarp,
                                                ShapeMMAOp,
                                                EpilogueOp,
                                                SwizzleThreadBlock,
                                                NumStages>;

int run(float sparsity_ratio)
{

    const int length_m = M_GLOBAL;
    const int length_n = N_GLOBAL;
    const int length_k = K_GLOBAL;

    // Create a tuple of problem size for matrix multiplication
    cutlass::gemm::GemmCoord problem_size(length_m, length_n, length_k);

    int block_tile_n_num = (length_n + BLOCK_SIZE_N - 1) / BLOCK_SIZE_N;
    int block_tile_k_num = (length_k + BLOCK_SIZE_K - 1) / BLOCK_SIZE_K;
    int nnz_block = block_tile_k_num * block_tile_n_num;

    std::vector<std::vector<int>> valid_block_pos(block_tile_k_num, std::vector<int>(block_tile_n_num, 1));

    for (int n = 0; n < block_tile_n_num; n += 1)
    {
        for (int k = 0; k < block_tile_k_num; k += 1)
        {
            float r = static_cast<float>(rand()) / static_cast<float>(RAND_MAX);
            if (r <= sparsity_ratio)
            {
                valid_block_pos[k][n] = 0;
                --nnz_block;
            }
        }
    }

    // Initialize tensors using CUTLASS helper functions
    cutlass::HostTensor<ElementInputA, LayoutInputA> tensor_a(
        problem_size.mk()); // <- Create matrix A with dimensions M x K
    cutlass::HostTensor<ElementInputB, LayoutInputB> tensor_b(
        problem_size.kn()); // <- Create matrix B with dimensions K x N
    cutlass::HostTensor<ElementOutput, LayoutOutput> tensor_c(
        problem_size.mn()); // <- Create matrix C with dimensions M x N
    cutlass::HostTensor<ElementOutput, LayoutOutput> tensor_d(
        problem_size.mn()); // <- Create matrix D with dimensions M x N used to store output from
                            // CUTLASS kernel
    cutlass::HostTensor<ElementOutput, LayoutOutput> tensor_ref_d(
        problem_size.mn()); // <- Create matrix D with dimensions M x N used to store output from
                            // reference kernel

    // Fill input and output matrices on host using CUTLASS helper functions
    cutlass::reference::host::TensorFillRandomUniform(
        tensor_a.host_view(),
        1,
        ElementInputA(4),
        ElementInputA(-4),
        0); // <- Fill matrix A on host with uniform-distribution random data
    cutlass::reference::host::TensorFillRandomUniform(
        tensor_b.host_view(),
        1,
        ElementInputB(4),
        ElementInputB(-4),
        0); // <- Fill matrix B on host with uniform-distribution random data
    cutlass::reference::host::TensorFillRandomUniform(
        tensor_c.host_view(),
        1,
        ElementOutput(4),
        ElementOutput(-4),
        0); // <- Fill matrix C on host with uniform-distribution random data
    cutlass::reference::host::TensorFill(
        tensor_d.host_view()); // <- fill matrix D on host with zeros
    cutlass::reference::host::TensorFill(
        tensor_ref_d.host_view()); // <- fill matrix D for reference on host with zeros

    // Sparsify matrix B
    size_t row_size = sizeof(int) * (block_tile_n_num + 2);
    size_t col_size = sizeof(int) * nnz_block;
    int *row_ptr, *col_ptr, *d_row_ptr, *d_col_ptr;
    row_ptr = (int *)malloc(row_size);
    col_ptr = (int *)malloc(col_size);

    int nnz_block_count = 0;
    for (int n = 0; n < block_tile_n_num; n += 1)
    {
        row_ptr[n] = nnz_block_count;
        for (int k = 0; k < block_tile_k_num; k += 1)
        {
            if (valid_block_pos[k][n] == 0)
            {
                int k_start = k * BLOCK_SIZE_K;
                int k_end = min((k + 1) * BLOCK_SIZE_K, length_k);
                int n_start = n * BLOCK_SIZE_N;
                int n_end = min((n + 1) * BLOCK_SIZE_N, length_n);
                for (int k_iter = k_start; k_iter < k_end; k_iter += 1)
                {
                    for (int n_iter = n_start; n_iter < n_end; n_iter += 1)
                    {
                        tensor_b.at({k_iter, n_iter}) = ElementInputB(0);
                    }
                }
            }
            else
            {
                col_ptr[nnz_block_count] = k;
                nnz_block_count += 1;
            }
        }
    }
    row_ptr[block_tile_n_num] = nnz_block_count;
    row_ptr[block_tile_n_num + 1] = nnz_block_count;

    cudaMalloc(&d_row_ptr, row_size);
    cudaMalloc(&d_col_ptr, col_size);
    checkCudaErrors(cudaMemcpy(d_row_ptr, row_ptr, row_size, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(d_col_ptr, col_ptr, col_size, cudaMemcpyHostToDevice));

    // Copy data from host to GPU
    tensor_a.sync_device();
    tensor_b.sync_device();
    tensor_c.sync_device();
    tensor_d.sync_device();
    tensor_ref_d.sync_device();

    // Initialize alpha and beta for dot product computation
    ElementComputeEpilogue alpha = ElementComputeEpilogue(1);
    ElementComputeEpilogue beta = ElementComputeEpilogue(0);

    // Split K dimension into 1 partitions
    int split_k_slices = 1;

    // Create a tuple of gemm kernel arguments. This is later passed as arguments to launch
    // instantiated CUTLASS kernel
    typename Gemm::Arguments arguments{problem_size,          // <- problem size of matrix multiplication
                                       tensor_a.device_ref(), // <- reference to matrix A on device
                                       tensor_b.device_ref(), // <- reference to matrix B on device
                                       tensor_c.device_ref(), // <- reference to matrix C on device
                                       tensor_d.device_ref(), // <- reference to matrix D on device
                                       d_row_ptr,
                                       d_col_ptr,
                                       {alpha, beta},   // <- tuple of alpha and beta
                                       split_k_slices}; // <- k-dimension split factor

    // Using the arguments, query for extra workspace required for matrix multiplication computation
    size_t workspace_size = Gemm::get_workspace_size(arguments);

    // Allocate workspace memory
    cutlass::device_memory::allocation<uint8_t> workspace(workspace_size);

    // Instantiate CUTLASS kernel depending on templates
    Gemm gemm_op;

    // Check the problem size is supported or not
    cutlass::Status status = gemm_op.can_implement(arguments);
    CUTLASS_CHECK(status);

    // Initialize CUTLASS kernel with arguments and workspace pointer
    status = gemm_op.initialize(arguments, workspace.get());
    CUTLASS_CHECK(status);

    // Launch initialized CUTLASS kernel
    status = gemm_op();
    CUTLASS_CHECK(status);

    // Create instantiation for device reference gemm kernel
    cutlass::reference::device::Gemm<ElementInputA,
                                     LayoutInputA,
                                     ElementInputB,
                                     LayoutInputB,
                                     ElementOutput,
                                     LayoutOutput,
                                     ElementComputeEpilogue,
                                     ElementComputeEpilogue>
        gemm_device;

    // Launch device reference gemm kernel
    gemm_device(problem_size,
                alpha,
                tensor_a.device_ref(),
                tensor_b.device_ref(),
                beta,
                tensor_c.device_ref(),
                tensor_ref_d.device_ref());

    // Wait for kernels to finish
    cudaDeviceSynchronize();

    // Copy output data from CUTLASS and reference kernel to host for comparison
    tensor_d.sync_host();
    tensor_ref_d.sync_host();

    // Check if output from CUTLASS kernel and reference kernel are equal or not
    bool passed = cutlass::reference::host::TensorEquals(
        tensor_d.host_view(),
        tensor_ref_d.host_view());

    /*
    for (int i = 0; i < problem_size.m(); ++i) {
      for (int j = 0; j < problem_size.n(); ++j) {
        printf("tensor_ref_d: %d, tensor_d: %d\n", tensor_ref_d.at({i, j}), tensor_d.at({i, j}));
      }
    }
    */

    std::cout << (passed ? "Passed" : "Failed") << std::endl;

    cudaEvent_t start, stop;
    checkCudaErrors(cudaEventCreate(&start));
    checkCudaErrors(cudaEventCreate(&stop));
    float msecTotal = 0;
    int nIter = 100;

    checkCudaErrors(cudaEventRecord(start));
    for (int i = 0; i < nIter; i += 1)
        status = gemm_op();
    checkCudaErrors(cudaEventRecord(stop));
    checkCudaErrors(cudaEventSynchronize(stop));
    checkCudaErrors(cudaEventElapsedTime(&msecTotal, start, stop));

    float msecPerMatrixMul = msecTotal / nIter;

    printf("block sparse kernel conv Time= %.3f msec\n", msecPerMatrixMul);

    return (passed ? 0 : -1);
}

int main(int argc, char **argv)
{
    bool notSupported = false;

    float sparsity_ratio = std::stof(argv[1]);

    // Turing Tensor Core operations exposed with mma.sync and ldmatrix are first available
    // in CUDA 10.2.
    //
    // CUTLASS must be compiled with CUDA 10.2 Toolkit to run these examples.
    if (!(__CUDACC_VER_MAJOR__ > 10 || (__CUDACC_VER_MAJOR__ == 10 && __CUDACC_VER_MINOR__ >= 2)))
    {
        std::cerr << "Turing Tensor Core operations must be compiled with CUDA 10.2 Toolkit or later." << std::endl;
        notSupported = true;
    }

    cudaDeviceProp props;

    cudaError_t error = cudaGetDeviceProperties(&props, 0);
    if (error != cudaSuccess)
    {
        std::cerr << "cudaGetDeviceProperties() returned an error: " << cudaGetErrorString(error) << std::endl;
        return -1;
    }

    if (!((props.major * 10 + props.minor) >= 75))
    {
        std::cerr << "Turing Tensor Core operations must be run on a machine with compute capability at least 75."
                  << std::endl;

        notSupported = true;
    }

    if (notSupported)
    {
        // Returning zero so this test passes on older Toolkits. Its actions are no-op.
        return 0;
    }

    return run(sparsity_ratio);
}
