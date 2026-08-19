#include <boost/context/detail/fcontext.hpp>

#include <cstddef>

struct PhpContextData {
  void *handle;
  void *transfer;
};

extern "C" void *make_fcontext(void *stackPointer, std::size_t size,
                               void (*entry)(PhpContextData)) {
  using boost::context::detail::transfer_t;
  auto boostEntry = reinterpret_cast<void (*)(transfer_t)>(entry);
  return boost::context::detail::make_fcontext(stackPointer, size, boostEntry);
}

extern "C" PhpContextData jump_fcontext(void *target, void *transfer) {
  auto result = boost::context::detail::jump_fcontext(target, transfer);
  return {result.fctx, result.data};
}
