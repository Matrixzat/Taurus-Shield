cmake_minimum_required(VERSION 3.18)
project(subway_hook)

set(CMAKE_CXX_STANDARD 17)

add_library(main SHARED hook.cpp)

target_link_libraries(main
    android
    log
    dl
)

# Strip debug symbols for smaller output
target_compile_options(main PRIVATE -O2 -fvisibility=hidden)
set_target_properties(main PROPERTIES LINK_FLAGS "-Wl,--strip-all")
