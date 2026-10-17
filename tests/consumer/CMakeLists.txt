# Consumer test: links a prebuilt FFmpeg the way a downstream project does —
# via find_package(CustomFFmpeg) only, no manual library lists.
#
#   cmake -S tests/consumer -B <build> -DCUSTOM_FFMPEG_ROOT=<prebuilt>/<platform>/<type>/<profile>
#         [-DCONSUMER_CXX=ON]   # add a C++ translation unit (C++ runtime/STL checks)
#   cmake --build <build> --config Release
#   ctest --test-dir <build> -C Release --output-on-failure
#
# The profile (full | lgpl | minimal) is taken from the root's directory name; static
# or shared is detected by FindCustomFFmpeg.
cmake_minimum_required(VERSION 3.25)
option(CONSUMER_CXX "Add a C++ translation unit to the test executable" OFF)
if(CONSUMER_CXX)
    project(custom_ffmpeg_consumer LANGUAGES C CXX)
else()
    project(custom_ffmpeg_consumer LANGUAGES C)
endif()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_LIST_DIR}/../../cmake")

if(NOT CUSTOM_FFMPEG_ROOT)
    message(FATAL_ERROR "Pass -DCUSTOM_FFMPEG_ROOT=<prebuilt>/<platform>/<type>/<profile>")
endif()
get_filename_component(CONSUMER_PROFILE "${CUSTOM_FFMPEG_ROOT}" NAME)

if(CONSUMER_PROFILE STREQUAL "minimal")
    find_package(CustomFFmpeg REQUIRED COMPONENTS swscale)
    set(_sources minimal_test.c)
    set(_link CustomFFmpeg::swscale)
elseif(CONSUMER_PROFILE STREQUAL "full" OR CONSUMER_PROFILE STREQUAL "lgpl")
    find_package(CustomFFmpeg REQUIRED
        COMPONENTS avutil avcodec avformat avdevice avfilter swscale swresample)
    set(_sources full_test.c)
    set(_link CustomFFmpeg::FFmpeg)
else()
    message(FATAL_ERROR "Unknown profile '${CONSUMER_PROFILE}' (expected full, lgpl or minimal)")
endif()

add_executable(consumer_test ${_sources})
if(CONSUMER_PROFILE STREQUAL "lgpl")
    target_compile_definitions(consumer_test PRIVATE CONSUMER_LGPL)
endif()
if(CONSUMER_CXX)
    # C++ main() calls the C test as test_main()
    target_sources(consumer_test PRIVATE main.cpp)
    target_compile_definitions(consumer_test PRIVATE CONSUMER_CXX)
endif()
target_link_libraries(consumer_test PRIVATE ${_link})

# Public hwcontext headers that need dependency headers shipped with the build
set(_hw_defs "")
if(IS_DIRECTORY "${CUSTOM_FFMPEG_INCLUDE_DIR}/AMF")
    list(APPEND _hw_defs CONSUMER_HW_AMF)
endif()
if(IS_DIRECTORY "${CUSTOM_FFMPEG_INCLUDE_DIR}/vpl")
    list(APPEND _hw_defs CONSUMER_HW_QSV)
endif()
if(IS_DIRECTORY "${CUSTOM_FFMPEG_INCLUDE_DIR}/va")
    list(APPEND _hw_defs CONSUMER_HW_VAAPI)
endif()
if(_hw_defs)
    target_sources(consumer_test PRIVATE hwcontext_test.c)
    target_compile_definitions(consumer_test PRIVATE ${_hw_defs})
    message(STATUS "hwcontext header checks: ${_hw_defs}")
endif()

message(STATUS "CustomFFmpeg shared: ${CUSTOM_FFMPEG_SHARED}")
message(STATUS "CustomFFmpeg extra libraries: ${CUSTOM_FFMPEG_EXTRA_LIBRARIES}")

if(CUSTOM_FFMPEG_SHARED)
    if(WIN32)
        # DLLs next to the executable
        add_custom_command(TARGET consumer_test POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                $<TARGET_RUNTIME_DLLS:consumer_test> $<TARGET_FILE_DIR:consumer_test>
            COMMAND_EXPAND_LISTS)
    else()
        set_target_properties(consumer_test PROPERTIES BUILD_RPATH "${CUSTOM_FFMPEG_ROOT}/lib")
    endif()
endif()

enable_testing()
add_test(NAME consumer_test COMMAND consumer_test)
