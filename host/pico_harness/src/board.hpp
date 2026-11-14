// board.hpp — Pico pins of the harness. Override any of them at configure
// time, e.g.  cmake -DXC_PIN_SCLK=10 ...  (see CMakeLists.txt).
//
// SCLK/MOSI/MISO default to GP2/GP3/GP4, which are also SPI0's SCK/TX/RX, so
// the hardware-SPI master (`link hw`) works on the same wires. If you move
// them, keep them on one SPI block's pins or `link hw` is unavailable.
#pragma once

#ifndef XC_PIN_SCLK
#define XC_PIN_SCLK 2      // -> ui[0] SCLK
#endif
#ifndef XC_PIN_MOSI
#define XC_PIN_MOSI 3      // -> ui[1] MOSI
#endif
#ifndef XC_PIN_MISO
#define XC_PIN_MISO 4      // <- uo[0] MISO
#endif
#ifndef XC_PIN_CS
#define XC_PIN_CS 5        // -> ui[2] CS_N
#endif
#ifndef XC_PIN_PROTO
#define XC_PIN_PROTO 6     // -> ui[3] PROTO
#endif
#ifndef XC_PIN_CPHA
#define XC_PIN_CPHA 7      // -> ui[4] CPHA
#endif
#ifndef XC_PIN_READY
#define XC_PIN_READY 8     // <- uo[1] DATA_READY
#endif
#ifndef XC_PIN_BUSY
#define XC_PIN_BUSY 9      // <- uo[2] BUSY
#endif
#ifndef XC_SPI_INST
#define XC_SPI_INST spi0   // the SPI block that owns SCLK/MOSI/MISO (for `link hw`)
#endif
