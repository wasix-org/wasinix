#include <nix/util/archive.hh>
#include <nix/util/serialise.hh>

#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <string>

namespace {

bool isNixBase32(char c) {
  constexpr std::string_view alphabet = "0123456789abcdfghijklmnpqrsvwxyz";
  return alphabet.find(c) != std::string_view::npos;
}

bool isStoreNameChar(char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
         (c >= 'A' && c <= 'Z') || c == '+' || c == '-' || c == '.' ||
         c == '_' || c == '?' || c == '=';
}

class ReferenceHashSink : public nix::Sink {
public:
  void operator()(std::string_view data) override {
    for (char c : data) {
      if (isNixBase32(c)) {
        window.push_back(c);
        if (window.size() == 32) {
          hashes.insert(window);
          window.erase(0, 1);
        }
      } else {
        window.clear();
      }
      collectStorePath(c);
    }
  }

  void finish() { finishStorePath(); }

  std::set<std::string> hashes;
  std::map<std::string, std::set<std::string>> storePaths;

private:
  static constexpr std::string_view storePrefix = "/nix/store/";

  void matchStorePrefix(char c) {
    if (c == storePrefix[prefixLength])
      ++prefixLength;
    else
      prefixLength = c == storePrefix.front() ? 1 : 0;
    if (prefixLength == storePrefix.size()) {
      currentStorePath = storePrefix;
      prefixLength = 0;
    }
  }

  void collectStorePath(char c) {
    if (currentStorePath.empty()) {
      matchStorePrefix(c);
      return;
    }
    if (isStoreNameChar(c)) {
      currentStorePath.push_back(c);
      return;
    }
    finishStorePath();
    matchStorePrefix(c);
  }

  void finishStorePath() {
    if (currentStorePath.empty())
      return;
    auto baseName =
        std::string_view(currentStorePath).substr(storePrefix.size());
    if (baseName.size() >= 34 && baseName.size() <= 211 &&
        baseName[32] == '-') {
      auto hash = baseName.substr(0, 32);
      if (hash.find_first_not_of("0123456789abcdfghijklmnpqrsvwxyz") ==
          std::string_view::npos)
        storePaths[std::string(hash)].insert(currentStorePath);
    }
    currentStorePath.clear();
  }

  std::string window;
  std::string currentStorePath;
  std::size_t prefixLength = 0;
};

} // namespace

int main(int argc, char **argv) {
  if (argc != 3) {
    std::cerr << "usage: check-reference-scanner PATH MANIFEST\n";
    return 2;
  }

  ReferenceHashSink sink;
  nix::dumpPath(argv[1], sink);
  sink.finish();

  std::ofstream output(argv[2]);
  if (!output) {
    std::cerr << "cannot create reference manifest: " << argv[2] << '\n';
    return 1;
  }
  for (const auto &hash : sink.hashes) {
    output << hash;
    auto paths = sink.storePaths.find(hash);
    if (paths != sink.storePaths.end())
      output << '\t' << *paths->second.begin();
    output << '\n';
  }
}
