#include <torch/csrc/WindowsTorchApiMacro.h>
#include <ATen/core/ivalue.h>
#include <torch/csrc/jit/pickle.h>
#include <torch/csrc/jit/pickler.h>


namespace torch {
namespace jit {

void pickle_stream(
    std::function<void(const char*, size_t)> writer,
    const IValue& ivalue,
    std::vector<at::Tensor>* tensor_table) {
  Pickler pickler(std::move(writer), tensor_table);

  if (tensor_table == nullptr) {
    // No tensor table provided, so tensors will be stored directly in the blob.
    // Add torch.save metadata so these tensors can be de-serialized later
    pickler.torchSaveStart();
  }

  pickler.protocol();
  pickler.pushIValue(ivalue);
  pickler.stop();

  if (tensor_table == nullptr) {
    // No tensor table provided, so tensors will be stored directly in the blob.
    // Add torch.save metadata so these tensors can be de-serialized later
    pickler.torchSaveStop();
  }
}

std::vector<char> pickle(
    const IValue& ivalue,
    std::vector<at::Tensor>* tensor_table) {
  std::vector<char> data;

  pickle_stream(
      [&](const char* bytes, size_t len) {
        data.insert(data.end(), bytes, bytes + len);
      },
      ivalue,
      tensor_table);

  return data;
}

std::vector<IValue> unpickle(
    std::function<const char*(size_t)> reader,
    std::function<bool()> bounds_checker,
    std::vector<at::Tensor>* tensor_table,
    ClassResolver class_resolver) {
  Unpickler unpickler(
      std::move(reader),
      std::move(bounds_checker),
      tensor_table,
      std::move(class_resolver));
  return unpickler.parse_ivalue_list();
}

std::vector<IValue> unpickle(
    const char* data,
    size_t size,
    std::vector<at::Tensor>* tensor_table,
    ClassResolver class_resolver) {
  size_t bytes_read = 0;
  return unpickle(
      [&](size_t len) {
        const char* to_read = data + bytes_read;
        bytes_read += len;
        return to_read;
      },
      [&]() {
        return bytes_read < size;
      },
      tensor_table,
      std::move(class_resolver));
}

} // namespace jit
} // namespace torch
