#include <ATen/AccumulateType.h>
#include <ATen/native/Pool.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/cuda/CUDAApplyUtils.cuh>
#include <ATen/cuda/detail/TensorInfo.cuh>
#include <ATen/cuda/detail/IndexUtils.cuh>
#include <ATen/cuda/detail/KernelUtils.h>
#include <THC/THCNumerics.cuh>
#include <c10/macros/Macros.h>


namespace at {
namespace native {
namespace {

__device__ inline int min(int a, int b) {
  return a <= b ? a : b;
}

__device__ inline int max(int a, int b) {
  return a >= b ? a : b;
}

template <typename scalar_t, typename accscalar_t>
__global__ void avg_pool3d_cuda_update_output(
  PackedTensorAccessor<scalar_t, 4> input,
  PackedTensorAccessor<scalar_t, 4> output,
  int kT, int kH, int kW,
  int dT, int dH, int dW,
  int padT, int padH, int padW,
  bool count_include_pad,
  int offsetZ)
{
  int oCol   = blockIdx.x * blockDim.x + threadIdx.x;
  int oRow   = blockIdx.y * blockDim.y + threadIdx.y;
  int oFrame = (blockIdx.z + offsetZ) % output.size(1); // output frame/time
  int slice  = (blockIdx.z + offsetZ) / output.size(1); // output slice/feature

  if (oRow < output.size(2) && oCol < output.size(3))
  {
    accscalar_t sum = 0.0;

    int tstart = oFrame * dT - padT;
    int hstart = oRow   * dH - padH;
    int wstart = oCol   * dW - padW;
    int tend = min(tstart + kT, input.size(1) + padT);
    int hend = min(hstart + kH, input.size(2) + padH);
    int wend = min(wstart + kW, input.size(3) + padW);
    int pool_size = (tend - tstart) * (hend - hstart) * (wend - wstart);
    tstart = max(tstart, 0);
    hstart = max(hstart, 0);
    wstart = max(wstart, 0);
    tend = min(tend, input.size(1));
    hend = min(hend, input.size(2));
    wend = min(wend, input.size(3));

    accscalar_t divide_factor;
    if (count_include_pad)
      divide_factor = static_cast<accscalar_t>(pool_size);
    else
      divide_factor = static_cast<accscalar_t>((tend - tstart) * (hend - hstart) * (wend - wstart));

    int ti, hi, wi;
    for (ti = tstart; ti < tend; ++ti)
    {
      for (hi = hstart; hi < hend; ++hi)
      {
        for (wi = wstart; wi < wend; ++wi)
        {
          scalar_t val = input[slice][ti][hi][wi];
          sum += val;
        }
      }
    }

    output[slice][oFrame][oRow][oCol] = ScalarConvert<accscalar_t, scalar_t>::to(sum / divide_factor);
  }
}

// Inner-most loop size (kW) passed as template parameter for
// performance reasons.
//
template<int KERNEL_WIDTH, typename scalar_t, typename accscalar_t>
__global__ void avg_pool3d_cuda_update_output(
  PackedTensorAccessor<scalar_t, 4> input,
  PackedTensorAccessor<scalar_t, 4> output,
  int kT, int kH,
  int dT, int dH, int dW,
  int padT, int padH, int padW,
  bool count_include_pad,
  int offsetZ)
{
  int oCol   = blockIdx.x * blockDim.x + threadIdx.x;
  int oRow   = blockIdx.y * blockDim.y + threadIdx.y;
  int oFrame = (blockIdx.z + offsetZ) % output.size(1); // output frame/time
  int slice  = (blockIdx.z + offsetZ) / output.size(1); // output slice/feature

  if (oRow < output.size(2) && oCol < output.size(3))
  {
    accscalar_t sum = 0.0;

    int tstart = oFrame * dT - padT;
    int hstart = oRow   * dH - padH;
    int wstart = oCol   * dW - padW;
    int tend = min(tstart + kT, input.size(1) + padT);
    int hend = min(hstart + kH, input.size(2) + padH);
    int wend = min(wstart + KERNEL_WIDTH, input.size(3) + padW);
    int pool_size = (tend - tstart) * (hend - hstart) * (wend - wstart);
    tstart = max(tstart, 0);
    hstart = max(hstart, 0);
    wstart = max(wstart, 0);
    tend = min(tend, input.size(1));
    hend = min(hend, input.size(2));
    wend = min(wend, input.size(3));

    accscalar_t divide_factor;
    if (count_include_pad)
      divide_factor = static_cast<accscalar_t>(pool_size);
    else
      divide_factor = static_cast<accscalar_t>((tend - tstart) * (hend - hstart) * (wend - wstart));

    int ti, hi, wi;
    for (ti = tstart; ti < tend; ++ti)
    {
      for (hi = hstart; hi < hend; ++hi)
      {
        for (wi = wstart; wi < wend; ++wi)
        {
          scalar_t val = input[slice][ti][hi][wi];
          sum += val;
        }
      }
    }

    output[slice][oFrame][oRow][oCol] = ScalarConvert<accscalar_t, scalar_t>::to(sum / divide_factor);
  }
}

template <typename scalar_t, typename accscalar_t>
__global__ void avg_pool3d_single_backward_out_frame_stride1(
  PackedTensorAccessor<scalar_t, 4> gradOutput,
  PackedTensorAccessor<scalar_t, 4> gradInput,
  int kT, int kH, int kW,
  accscalar_t normFactor,
  int offsetZ)
{
  int iCol   = blockIdx.x * blockDim.x + threadIdx.x;
  int iRow   = blockIdx.y * blockDim.y + threadIdx.y;
  int iFrame = (blockIdx.z + offsetZ) % gradInput.size(1); // input frame/time
  int slice  = (blockIdx.z + offsetZ) / gradInput.size(1); // input slice/feature

  // guard against over-tiled threads
  if (iRow < gradInput.size(2) && iCol < gradInput.size(3))
  {
    accscalar_t sum = 0.0;
    scalar_t *gOut = &gradOutput[slice][max(0, iFrame - kT + 1)]
      [max(0, iRow - kH + 1)][max(0, iCol - kW + 1)];
    int frameOffset = 0;
    for (int oFrame  = max(0, iFrame - kT + 1);
         oFrame < min(iFrame + 1, gradOutput.size(1));
         ++oFrame)
    {
      int rowOffset = frameOffset;
      for (int oRow = max(0, iRow - kH + 1);
           oRow < min(iRow + 1, gradOutput.size(2));
           ++oRow)
      {
        int colOffset = rowOffset;
        for (int oCol = max(0, iCol - kW + 1);
             oCol < min(iCol + 1, gradOutput.size(3));
             ++oCol)
        {
          sum += gOut[colOffset];
          ++colOffset;
        }
        rowOffset += gradOutput.size(3);
      }
      frameOffset += gradOutput.size(2) * gradOutput.size(3);
    }
    gradInput[slice][iFrame][iRow][iCol] = ScalarConvert<accscalar_t, scalar_t>::to(sum * normFactor);
  }
}

template <typename scalar_t, typename accscalar_t>
__global__ void avg_pool3d_cuda_update_grad_input_atomic(
  PackedTensorAccessor<scalar_t, 4> gradOutput,
  PackedTensorAccessor<scalar_t, 4> gradInput,
  int kT, int kH, int kW,
  int dT, int dH, int dW,
  int padT, int padH, int padW,
  bool count_include_pad,
  int offsetZ)
{
  int oCol   = blockIdx.x * blockDim.x + threadIdx.x;
  int oRow   = blockIdx.y * blockDim.y + threadIdx.y;
  int oFrame = (blockIdx.z + offsetZ) % gradOutput.size(1); // gradOutput frame/time
  int slice  = (blockIdx.z + offsetZ) / gradOutput.size(1); // gradOutput slice/feature

  // guard against over-tiled threads
  if (oRow < gradOutput.size(2) && oCol < gradOutput.size(3))
  {
    int tstart = oFrame * dT - padT;
    int hstart = oRow   * dH - padH;
    int wstart = oCol   * dW - padW;
    int tend = min(tstart + kT, gradInput.size(1) + padT);
    int hend = min(hstart + kH, gradInput.size(2) + padH);
    int wend = min(wstart + kW, gradInput.size(3) + padW);
    int pool_size = (tend - tstart) * (hend - hstart) * (wend - wstart);
    tstart = max(tstart, 0);
    hstart = max(hstart, 0);
    wstart = max(wstart, 0);
    tend = min(tend, gradInput.size(1));
    hend = min(hend, gradInput.size(2));
    wend = min(wend, gradInput.size(3));

    accscalar_t divide_factor;
    if (count_include_pad)
      divide_factor = static_cast<accscalar_t>(pool_size);
    else
      divide_factor = static_cast<accscalar_t>((tend - tstart) * (hend - hstart) * (wend - wstart));

    scalar_t val = ScalarConvert<accscalar_t, scalar_t>::to(
      ScalarConvert<scalar_t, accscalar_t>::to(gradOutput[slice][oFrame][oRow][oCol]) / divide_factor);
    for (int iFrame = tstart; iFrame < tend; ++iFrame)
    {
      for (int iRow = hstart; iRow < hend; ++iRow)
      {
        for (int iCol = wstart; iCol < wend; ++iCol)
        {
          atomicAdd(&gradInput[slice][iFrame][iRow][iCol], val);
        }
      }
    }
  }
}

template <typename scalar_t, typename accscalar_t>
__global__ void avg_pool3d_cuda_update_grad_input(
  PackedTensorAccessor<scalar_t, 4> gradOutput,
  PackedTensorAccessor<scalar_t, 4> gradInput,
  int kT, int kH, int kW,
  int dT, int dH, int dW,
  int padT, int padH, int padW,
  bool count_include_pad, int offsetZ)
{
  int oCol   = blockIdx.x * blockDim.x + threadIdx.x;
  int oRow   = blockIdx.y * blockDim.y + threadIdx.y;
  int oFrame = (blockIdx.z + offsetZ) % gradOutput.size(1); // gradOutput frame/time
  int slice  = (blockIdx.z + offsetZ) / gradOutput.size(1); // gradOutput slice/feature

  // guard against over-tiled threads
  if (oRow < gradOutput.size(2) && oCol < gradOutput.size(3))
  {
    int tstart = oFrame * dT - padT;
    int hstart = oRow   * dH - padH;
    int wstart = oCol   * dW - padW;
    int tend = min(tstart + kT, gradInput.size(1) + padT);
    int hend = min(hstart + kH, gradInput.size(2) + padH);
    int wend = min(wstart + kW, gradInput.size(3) + padW);
    int pool_size = (tend - tstart) * (hend - hstart) * (wend - wstart);
    tstart = max(tstart, 0);
    hstart = max(hstart, 0);
    wstart = max(wstart, 0);
    tend = min(tend, gradInput.size(1));
    hend = min(hend, gradInput.size(2));
    wend = min(wend, gradInput.size(3));

    accscalar_t divide_factor;
    if (count_include_pad)
      divide_factor = static_cast<accscalar_t>(pool_size);
    else
      divide_factor = static_cast<accscalar_t>((tend - tstart) * (hend - hstart) * (wend - wstart));

    scalar_t val = ScalarConvert<accscalar_t, scalar_t>::to(
      ScalarConvert<scalar_t, accscalar_t>::to(gradOutput[slice][oFrame][oRow][oCol]) / divide_factor);
    for (int iFrame = tstart; iFrame < tend; ++iFrame)
    {
      for (int iRow = hstart; iRow < hend; ++iRow)
      {
        for (int iCol = wstart; iCol < wend; ++iCol)
        {
          gradInput[slice][iFrame][iRow][iCol] = val;
        }
      }
    }
  }
}

#define LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(KW) case KW: \
  avg_pool3d_cuda_update_output<KW, scalar_t, accscalar_t>  \
    <<<grid, block, 0, at::cuda::getCurrentCUDAStream()>>>( \
       work_input.packed_accessor<scalar_t, 4>(),           \
       work_output.packed_accessor<scalar_t, 4>(),          \
       kT, kH,                                              \
       dT, dH, dW,                                          \
       padT, padH, padW,                                    \
       count_include_pad,                                   \
       offsetZ);                                            \
  break

void avg_pool3d_out_cuda_template(
  Tensor& output,
  const Tensor& input,
  IntArrayRef kernel_size,
  IntArrayRef stride,
  IntArrayRef padding,
  bool ceil_mode,
  bool count_include_pad)
{
  TensorArg output_arg{ output, "output", 1 };
  TensorArg input_arg{ input, "input", 2 };

  checkAllSameGPU("avg_pool3d_out_cuda", {output_arg, input_arg});

  // #20866 [JIT] stride.empty() is passed through
  // #20866 [LIBTORCH] IntegrationTest.MNIST: padding.size() == 1
  TORCH_INTERNAL_ASSERT(kernel_size.size() == 3 &&
                        (stride.empty() || stride.size() == 3) &&
                        (padding.size() == 1 || padding.size() == 3),
    "avg_pool3d: all IntArrayRef sizes must be 3");

  TORCH_CHECK((input.ndimension() == 4 || input.ndimension() == 5),
    "non-empty 4D or 5D (batch mode) tensor expected for input");

  const int kT = safe_downcast<int, int64_t>(kernel_size[0]);
  const int kH = safe_downcast<int, int64_t>(kernel_size[1]);
  const int kW = safe_downcast<int, int64_t>(kernel_size[2]);

  const int dT = stride.empty() ? kT : safe_downcast<int, int64_t>(stride[0]);
  const int dH = stride.empty() ? kH : safe_downcast<int, int64_t>(stride[1]);
  const int dW = stride.empty() ? kW : safe_downcast<int, int64_t>(stride[2]);

  const int padT = safe_downcast<int, int64_t>(padding[0]);
  const int padH = padding.size() == 1 ? padT : safe_downcast<int, int64_t>(padding[1]);
  const int padW = padding.size() == 1 ? padT : safe_downcast<int, int64_t>(padding[2]);

  const int64_t nbatch = input.ndimension() == 5 ? input.size(-5) : 1;
  const int64_t nslices = input.size(-4);
  const int64_t itime = input.size(-3);
  const int64_t iheight = input.size(-2);
  const int64_t iwidth = input.size(-1);

  const int64_t otime = pooling_output_shape<int64_t>(itime, kT, padT, dT, 1, ceil_mode);
  const int64_t oheight = pooling_output_shape<int64_t>(iheight, kH, padH, dH, 1, ceil_mode);
  const int64_t owidth = pooling_output_shape<int64_t>(iwidth, kW, padW, dW, 1, ceil_mode);

  pool3d_shape_check(
    input,
    nslices,
    kT, kH, kW,
    dT, dH, dW,
    padT, padH, padW,
    1, 1, 1,
    itime, iheight, iwidth,
    otime, oheight, owidth,
    /*check_input_size=*/ true);

  if (input.ndimension() == 4) {
    output.resize_({ nslices, otime, oheight, owidth});
  }
  else {
    output.resize_({nbatch, nslices, otime, oheight, owidth});
  }

  Tensor work_input = input.contiguous();
  Tensor work_output = output;
  if (input.ndimension() == 5) {
    // Collapse batch and feature dimensions.
    work_input = work_input.reshape({nbatch * nslices, itime, iheight, iwidth});
    work_output = work_output.reshape({nbatch * nslices, otime, oheight, owidth});
  }

  AT_DISPATCH_FLOATING_TYPES_AND_HALF(
    input.scalar_type(),
    "avg_pool3d_out_cuda",
    [&] {
      using accscalar_t = acc_type<scalar_t, true>;
      int64_t totalZ = otime * nslices * nbatch;
      int64_t offsetZ = 0;
      dim3 block(32, 8);

      while (totalZ > 0) {
        dim3 grid(cuda::ATenCeilDiv(owidth, static_cast<int64_t>(block.x)),
                  cuda::ATenCeilDiv(oheight, static_cast<int64_t>(block.y)),
                  totalZ > 65535 ? 65535 : totalZ);

        switch (kW) {
          LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(1);
          LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(2);
          LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(3);
          LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(4);
          LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(5);
          LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(6);
          LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(7);
        default:
          avg_pool3d_cuda_update_output<scalar_t, accscalar_t>
            <<<grid, block, 0, at::cuda::getCurrentCUDAStream()>>>(
               work_input.packed_accessor<scalar_t, 4>(),
               work_output.packed_accessor<scalar_t, 4>(),
               kT, kH, kW,
               dT, dH, dW,
               padT, padH, padW,
               count_include_pad,
               offsetZ);
            break;
        }

        TORCH_CHECK(cudaGetLastError() == cudaSuccess,
          "avg_pool3d_out_cuda failed with error code ",
          cudaGetLastError());

        totalZ -= 65535;
        offsetZ += 65535;
      }
    }
  );
}

#undef LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH

void avg_pool3d_backward_out_cuda_template(
  Tensor& gradInput,
  const Tensor& gradOutput,
  const Tensor& input,
  IntArrayRef kernel_size,
  IntArrayRef stride,
  IntArrayRef padding,
  bool ceil_mode,
  bool count_include_pad)
{
  TensorArg gradInput_arg{ gradInput, "gradInput", 1 };
  TensorArg gradOutput_arg{ gradOutput, "gradOutput", 2 };
  TensorArg input_arg{ input, "input", 3 };

  checkAllSameGPU("avg_pool3d_backward_out_cuda",
                  {gradInput_arg, gradOutput_arg, input_arg});

  // #20866 [JIT] stride.empty() is passed through
  // #20866 [LIBTORCH] IntegrationTest.MNIST: padding.size() == 1
  TORCH_INTERNAL_ASSERT(kernel_size.size() == 3 &&
                        (stride.empty() || stride.size() == 3) &&
                        (padding.size() == 1 || padding.size() == 3),
    "avg_pool3d: all IntArrayRef sizes must be 3");

  TORCH_CHECK((input.ndimension() == 4 || input.ndimension() == 5),
    "non-empty 4D or 5D (batch mode) tensor expected for input");

  TORCH_CHECK((gradOutput.ndimension() == 4 || gradOutput.ndimension() == 5),
    "non-empty 4D or 5D (batch mode) tensor expected for gradOutput");

  // Resize and initialize result tensor.
  gradInput.resize_as_(input);
  gradInput.zero_();

  const int kT = safe_downcast<int, int64_t>(kernel_size[0]);
  const int kH = safe_downcast<int, int64_t>(kernel_size[1]);
  const int kW = safe_downcast<int, int64_t>(kernel_size[2]);

  const int dT = stride.empty() ? kT : safe_downcast<int, int64_t>(stride[0]);
  const int dH = stride.empty() ? kH : safe_downcast<int, int64_t>(stride[1]);
  const int dW = stride.empty() ? kW : safe_downcast<int, int64_t>(stride[2]);

  const int padT = safe_downcast<int, int64_t>(padding[0]);
  const int padH = padding.size() == 1 ? padT : safe_downcast<int, int64_t>(padding[1]);
  const int padW = padding.size() == 1 ? padT : safe_downcast<int, int64_t>(padding[2]);

  const int64_t nbatch = input.ndimension() == 5 ? input.size(-5) : 1;
  const int64_t nslices = input.size(-4);
  const int64_t itime = input.size(-3);
  const int64_t iheight = input.size(-2);
  const int64_t iwidth = input.size(-1);

  const int64_t otime = gradOutput.size(-3);
  const int64_t oheight = gradOutput.size(-2);
  const int64_t owidth = gradOutput.size(-1);

  /* XXX shape check behavior from TH */
  const int64_t otime_for_shape_check = pooling_output_shape<int64_t>(itime, kT, padT, dT, 1, ceil_mode);
  const int64_t oheight_for_shape_check = pooling_output_shape<int64_t>(iheight, kH, padH, dH, 1, ceil_mode);
  const int64_t owidth_for_chape_check = pooling_output_shape<int64_t>(iwidth, kW, padW, dW, 1, ceil_mode);

  const bool kernelsOverlap = (dT < kT) || (dH < kH) || (dW < kW);

  avg_pool3d_backward_shape_check(
    input,
    gradOutput,
    nslices,
    kT, kH, kW,
    dT, dH, dW,
    padT, padH, padW,
    itime, iheight, iwidth,
    otime, oheight, owidth);

  Tensor work_grad_input = gradInput;
  Tensor work_grad_output = gradOutput.contiguous();

  if (input.ndimension() == 5) {
    // Collapse batch and feature dimensions.
    work_grad_input = work_grad_input.reshape({nbatch * nslices, itime, iheight, iwidth});
    work_grad_output = work_grad_output.reshape({nbatch * nslices, otime, oheight, owidth});
  }


  // Optimizing for stride 1 is probably only of limited value, but this
  // specialization yields 3x speedup over the atomicAdd implementation.
  // Padding must be 0, otherwise, pool size may change.
  if (dT == 1 && dH == 1 && dW == 1 && padT == 0 && padH == 0 && padW == 0) {
    AT_DISPATCH_FLOATING_TYPES_AND_HALF(input.scalar_type(),
      "avg_pool3d_backward_out_frame_stride1",
      [&] {
        using accscalar_t = acc_type<scalar_t, true>;
        int64_t totalZ = itime * nslices * nbatch;
        int64_t offsetZ = 0;
        dim3 block(32, 8);

        while (totalZ > 0) {
          dim3 grid(cuda::ATenCeilDiv(iwidth, static_cast<int64_t>(block.x)),
                    cuda::ATenCeilDiv(iheight, static_cast<int64_t>(block.y)),
                    totalZ > 65535 ? 65535 : totalZ);

          avg_pool3d_single_backward_out_frame_stride1<scalar_t, accscalar_t>
            <<<grid, block, 0, at::cuda::getCurrentCUDAStream()>>>(
              work_grad_output.packed_accessor<scalar_t, 4>(),
              work_grad_input.packed_accessor<scalar_t, 4>(),
              kT, kH, kW,
              1.0f/(kT * kH * kW),
              offsetZ);

          TORCH_CHECK(cudaGetLastError() == cudaSuccess,
            "avg_pool3d_backward_out_frame failed with error code ",
            cudaGetLastError());

          totalZ -= 65535;
          offsetZ += 65535;
        }
      }
    );
  }
  else {
    AT_DISPATCH_FLOATING_TYPES_AND_HALF(input.scalar_type(),
      "avg_pool3d_backward_out_frame",
      [&] {
        using accscalar_t = acc_type<scalar_t, true>;
        int64_t totalZ = otime * nslices * nbatch;
        int64_t offsetZ = 0;
        dim3 block(32, 8);

        while (totalZ > 0) {
          dim3 grid(cuda::ATenCeilDiv(owidth, static_cast<int64_t>(block.x)),
                    cuda::ATenCeilDiv(oheight, static_cast<int64_t>(block.y)),
                    totalZ > 65535 ? 65535 : totalZ);

          if (kernelsOverlap) {
            avg_pool3d_cuda_update_grad_input_atomic<scalar_t, accscalar_t>
              <<<grid, block, 0, at::cuda::getCurrentCUDAStream()>>>(
                 work_grad_output.packed_accessor<scalar_t, 4>(),
                 work_grad_input.packed_accessor<scalar_t, 4>(),
                 kT, kH, kW,
                 dT, dH, dW,
                 padT, padH, padW,
                 count_include_pad,
                 offsetZ);
          }
          else {
            avg_pool3d_cuda_update_grad_input<scalar_t, accscalar_t>
              <<<grid, block, 0, at::cuda::getCurrentCUDAStream()>>>(
                 work_grad_output.packed_accessor<scalar_t, 4>(),
                 work_grad_input.packed_accessor<scalar_t, 4>(),
                 kT, kH, kW,
                 dT, dH, dW,
                 padT, padH, padW,
                 count_include_pad,
                 offsetZ);
          }

          TORCH_CHECK(cudaGetLastError() == cudaSuccess,
            "avg_pool3d_backward_out_frame failed with error code ",
            cudaGetLastError());

          totalZ -= 65535;
          offsetZ += 65535;
        }
      }
    );
  }
}

} // namespace

Tensor& avg_pool3d_out_cuda(
  Tensor& output,
  const Tensor& input,
  IntArrayRef kernel_size,
  IntArrayRef stride,
  IntArrayRef padding,
  bool ceil_mode,
  bool count_include_pad)
{
  avg_pool3d_out_cuda_template(
    output,
    input,
    kernel_size,
    stride,
    padding,
    ceil_mode,
    count_include_pad);
  return output;
}

Tensor avg_pool3d_cuda(
  const Tensor& input,
  IntArrayRef kernel_size,
  IntArrayRef stride,
  IntArrayRef padding,
  bool ceil_mode,
  bool count_include_pad)
{
  Tensor output = at::empty({0}, input.options());
  avg_pool3d_out_cuda_template(
    output,
    input,
    kernel_size,
    stride,
    padding,
    ceil_mode,
    count_include_pad);
  return output;
}

Tensor& avg_pool3d_backward_out_cuda(
  Tensor& gradInput,
  const Tensor& gradOutput_,
  const Tensor& input,
  IntArrayRef kernel_size,
  IntArrayRef stride,
  IntArrayRef padding,
  bool ceil_mode,
  bool count_include_pad)
{
  avg_pool3d_backward_out_cuda_template(
    gradInput,
    gradOutput_,
    input,
    kernel_size,
    stride,
    padding,
    ceil_mode,
    count_include_pad);
  return gradInput;
}

Tensor avg_pool3d_backward_cuda(
  const Tensor& gradOutput_,
  const Tensor& input,
  IntArrayRef kernel_size,
  IntArrayRef stride,
  IntArrayRef padding,
  bool ceil_mode,
  bool count_include_pad)
{
  auto gradInput = at::zeros_like(input);
  avg_pool3d_backward_out_cuda_template(
    gradInput,
    gradOutput_,
    input,
    kernel_size,
    stride,
    padding,
    ceil_mode,
    count_include_pad);
  return gradInput;
}

} // at::native
} // at
