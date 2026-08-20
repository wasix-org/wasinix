#include <boost/coroutine2/coroutine.hpp>
#include <boost/coroutine2/protected_fixedsize_stack.hpp>

#include <cstdio>
#include <stdexcept>

namespace {

struct CountDestruction {
  int &count;
  ~CountDestruction() { ++count; }
};

} // namespace

int main() {
  using Coroutine = boost::coroutines2::coroutine<int>;
  auto stack = [] {
    return boost::coroutines2::protected_fixedsize_stack(512 * 1024);
  };

  int destructions = 0;
  {
    Coroutine::pull_type abandoned(stack(), [&](Coroutine::push_type &yield) {
      CountDestruction guard{destructions};
      yield(1);
      yield(2);
    });
    if (abandoned.get() != 1)
      return 1;
  }
  if (destructions != 1)
    return 2;

  int total = 0;
  Coroutine::push_type sink(stack(), [&](Coroutine::pull_type &values) {
    while (values) {
      total += values.get();
      values();
    }
  });
  sink(20);
  sink(22);
  if (total != 42)
    return 3;

  try {
    Coroutine::pull_type failed(stack(), [](Coroutine::push_type &) {
      throw std::runtime_error("boom");
    });
    return 4;
  } catch (std::runtime_error const &) {
  }

  Coroutine::pull_type outer(stack(), [&](Coroutine::push_type &yield) {
    Coroutine::pull_type inner(stack(), [](Coroutine::push_type &innerYield) {
      innerYield(3);
      innerYield(4);
    });
    for (int value : inner)
      yield(value * value);
  });
  total = 0;
  for (int value : outer)
    total += value;
  if (total != 25)
    return 5;

  std::puts("boost context ok");
  return 0;
}
