// C++ entry point for the consumer test (CONSUMER_CXX=ON): uses the C++
// standard library, so the C++ runtime/STL settings of the consumer (e.g. MSVC
// Debug: _ITERATOR_DEBUG_LEVEL=2, /MDd) meet the prebuilt libraries at link time.
#include <string>
#include <vector>

extern "C" int test_main(void);

int main()
{
    std::vector<std::string> v{"custom_ffmpeg"};
    return v.size() == 1 ? test_main() : 1;
}
