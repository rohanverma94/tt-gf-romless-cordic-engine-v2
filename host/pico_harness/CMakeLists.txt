# tt_um_xcordic test harness firmware — RP2040 (pico) / RP2350 (pico2).
#   ./build.sh               both boards, or:
#   cmake -B build -DPICO_BOARD=pico2 -DPICO_SDK_PATH=<sdk> && cmake --build build
# Pins: -DXC_PIN_SCLK=2 -DXC_PIN_MOSI=3 -DXC_PIN_MISO=4 -DXC_PIN_CS=5
#       -DXC_PIN_PROTO=6 -DXC_PIN_CPHA=7 -DXC_PIN_READY=8 -DXC_PIN_BUSY=9
#       -DXC_SPI_INST=spi0  (the SPI block of SCLK/MOSI/MISO, for `link hw`)
#       -DXC_FCLK_HZ=25000000  (default project clock; `fclk` changes it at run time)
cmake_minimum_required(VERSION 3.13)
include(pico_sdk_import.cmake)
project(xcordic_harness C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
pico_sdk_init()

add_executable(xcordic_harness
    src/main.cpp
    src/pico_hal.cpp
    src/suites.cpp)
target_include_directories(xcordic_harness PRIVATE src)
target_compile_options(xcordic_harness PRIVATE -O2 -Wall -Wextra -Wno-unused-parameter
    $<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions -fno-rtti>)
foreach(v XC_FCLK_HZ XC_PIN_SCLK XC_PIN_MOSI XC_PIN_MISO XC_PIN_CS XC_PIN_PROTO XC_PIN_CPHA XC_PIN_READY XC_PIN_BUSY XC_SPI_INST)
    if(DEFINED ${v})
        target_compile_definitions(xcordic_harness PRIVATE ${v}=${${v}})
    endif()
endforeach()
target_link_libraries(xcordic_harness pico_stdlib hardware_pio hardware_spi hardware_clocks hardware_vreg)
pico_enable_stdio_usb(xcordic_harness 1)
pico_enable_stdio_uart(xcordic_harness 0)
pico_add_extra_outputs(xcordic_harness)
