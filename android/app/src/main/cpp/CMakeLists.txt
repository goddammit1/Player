# libvibra.so — аудиоотпечатки для распознавания песен (Shazam).
# Исходники Vibra (GPL-3.0): vibra/, см. vibra/LICENSE.
cmake_minimum_required(VERSION 3.18)
project(player_vibra LANGUAGES C CXX)

set(V "${CMAKE_CURRENT_SOURCE_DIR}/vibra")
add_library(vibra SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/player_vibra.cpp"
  "${V}/lib/vibra.cpp"
  "${V}/lib/algorithm/signature.cpp"
  "${V}/lib/algorithm/frequency.cpp"
  "${V}/lib/algorithm/signature_generator.cpp"
  "${V}/lib/audio/wav.cpp"
  "${V}/lib/audio/downsampler.cpp"
  "${V}/third-party/kissfft/kiss_fft.c"
  "${V}/third-party/kissfft/kiss_fftr.c")
target_include_directories(vibra PRIVATE
  "${V}/include" "${V}/lib" "${V}/third-party/kissfft")
target_compile_definitions(vibra PRIVATE kiss_fft_scalar=double)
target_compile_options(vibra PRIVATE -fexceptions)
set_target_properties(vibra PROPERTIES CXX_STANDARD 11 CXX_STANDARD_REQUIRED YES)
# Android 15+: 16 KB страницы памяти.
target_link_options(vibra PRIVATE "-Wl,-z,max-page-size=16384")
target_link_libraries(vibra m)
