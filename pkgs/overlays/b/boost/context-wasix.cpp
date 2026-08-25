// Boost.Context's fcontext ABI implemented with WASIX stackful contexts.
#include <boost/context/detail/fcontext.hpp>
#include <boost/context/stack_traits.hpp>

#include <wasix/context.h>

#include <cstddef>
#include <cstdlib>
#include <limits>
#include <utility>

namespace boost::context {

bool stack_traits::is_unbounded() noexcept { return true; }
std::size_t stack_traits::page_size() noexcept { return 65536; }
std::size_t stack_traits::default_size() noexcept { return 128 * 1024; }
std::size_t stack_traits::minimum_size() noexcept { return 128 * 1024; }
std::size_t stack_traits::maximum_size() noexcept {
  return std::numeric_limits<std::size_t>::max();
}

namespace detail {
namespace {

struct WasixContext {
  wasix_context_id_t id;
  void (*entry)(transfer_t) = nullptr;
  transfer_t incoming{nullptr, nullptr};
  transfer_t (*ontop)(transfer_t) = nullptr;
  void *stackPointer = nullptr;
  bool isMain = false;
};

thread_local WasixContext mainContext{};
thread_local WasixContext *activeContext = nullptr;

__attribute__((always_inline)) inline void *readStackPointer() {
  void *stackPointer;
  __asm__ volatile("global.get __stack_pointer\n"
                   "local.set %0"
                   : "=r"(stackPointer));
  return stackPointer;
}

__attribute__((always_inline)) inline void
writeStackPointer(void *stackPointer) {
  __asm__ volatile("local.get %0\n"
                   "global.set __stack_pointer\n"
                   :
                   : "r"(stackPointer));
}

WasixContext *currentContext() {
  if (!activeContext) {
    mainContext.id = wasix_context_main;
    mainContext.isMain = true;
    activeContext = &mainContext;
  }
  return activeContext;
}

[[noreturn]] void contextEntry() {
  auto *context = currentContext();
  context->entry(context->incoming);
  std::abort();
}

transfer_t switchContext(WasixContext *target, void *data,
                         transfer_t (*ontop)(transfer_t)) {
  auto *source = currentContext();
  target->incoming = {source, data};
  target->ontop = ontop;

  // WASIX switches the control stack. Boost's stack allocator owns the
  // linear-memory stack, so switch __stack_pointer along with it.
  source->stackPointer = readStackPointer();
  activeContext = target;
  writeStackPointer(target->stackPointer);
  if (wasix_context_switch(target->id) != 0) {
    writeStackPointer(source->stackPointer);
    std::abort();
  }

  activeContext = source;
  auto transfer = source->incoming;
  auto *applyOntop = std::exchange(source->ontop, nullptr);
  if (!applyOntop)
    return transfer;

  auto *suspended = static_cast<WasixContext *>(transfer.fctx);
  transfer = applyOntop(transfer);
  if (!transfer.fctx && suspended && !suspended->isMain) {
    if (wasix_context_destroy(suspended->id) != 0)
      std::abort();
    delete suspended;
  }
  return transfer;
}

} // namespace

fcontext_t make_fcontext(void *stackPointer, std::size_t,
                         void (*entry)(transfer_t)) {
  auto *context = new WasixContext{};
  context->entry = entry;
  context->stackPointer = stackPointer;
  if (wasix_context_create(&context->id, contextEntry) != 0) {
    delete context;
    return nullptr;
  }
  return context;
}

transfer_t jump_fcontext(fcontext_t const target, void *data) {
  return switchContext(static_cast<WasixContext *>(target), data, nullptr);
}

transfer_t ontop_fcontext(fcontext_t const target, void *data,
                          transfer_t (*ontop)(transfer_t)) {
  return switchContext(static_cast<WasixContext *>(target), data, ontop);
}

} // namespace detail
} // namespace boost::context
