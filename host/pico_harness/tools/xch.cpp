// xch.cpp — talk to the harness from a PC (Linux / macOS): sends commands,
// prints the output, appends the "CSV," lines to a file.
//
//   g++ -O2 -std=c++17 -o xch xch.cpp
//   ./xch /dev/ttyACM0 id "bitexact 5000" regression          (Linux)
//   ./xch /dev/cu.usbmodem1101 -o run1.csv "sclk 10" calibrate shmoo
//   ./xch /dev/ttyACM0                                         interactive
//
// Each argument is one command line; xch waits for the harness's "> "
// prompt after each (no timeout: exhaustive tests take minutes).
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <termios.h>
#include <unistd.h>
#include <sys/select.h>

static int fd = -1;
static FILE *csv = nullptr;
static std::string line;

static void send(const char *s, size_t n) {
    while (n) { ssize_t w = write(fd, s, n); if (w <= 0) { if (errno == EINTR) continue; perror("write"); exit(1); } s += w; n -= size_t(w); }
}

static void consume(const char *buf, ssize_t n) {
    fwrite(buf, 1, size_t(n), stdout);
    fflush(stdout);
    for (ssize_t i = 0; i < n; ++i) {
        if (buf[i] == '\n') {
            if (csv && line.rfind("CSV,", 0) == 0) { fprintf(csv, "%s\n", line.c_str() + 4); fflush(csv); }
            line.clear();
        } else if (buf[i] != '\r') line += buf[i];
    }
}

// read until the prompt "> " starts a line (or timeout_ms of silence if > 0)
static bool wait_prompt(int timeout_ms) {
    char buf[512];
    for (;;) {
        fd_set rs; FD_ZERO(&rs); FD_SET(fd, &rs);
        timeval tv{timeout_ms / 1000, (timeout_ms % 1000) * 1000};
        int r = select(fd + 1, &rs, nullptr, nullptr, timeout_ms > 0 ? &tv : nullptr);
        if (r < 0) { if (errno == EINTR) continue; return false; }
        if (r == 0) return false;
        ssize_t n = read(fd, buf, sizeof buf);
        if (n <= 0) return false;
        consume(buf, n);
        if (line == "> ") return true;
    }
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: xch <port> [-o file.csv] [command ...]\n"); return 2; }
    fd = open(argv[1], O_RDWR | O_NOCTTY);
    if (fd < 0) { perror(argv[1]); return 1; }
    termios t{};
    tcgetattr(fd, &t);
    cfmakeraw(&t);
    cfsetspeed(&t, B115200);
    t.c_cflag |= CLOCAL | CREAD;
    tcsetattr(fd, TCSANOW, &t);
    int first = 2;
    if (argc > 3 && !strcmp(argv[2], "-o")) {
        csv = fopen(argv[3], "a");
        if (!csv) { perror(argv[3]); return 1; }
        first = 4;
    }
    // get a fresh prompt
    send("\r", 1);
    wait_prompt(1500);
    if (first >= argc) {                     // interactive: stdin lines -> harness
        char in[256];
        while (fgets(in, sizeof in, stdin)) {
            size_t n = strlen(in);
            if (n && in[n - 1] == '\n') in[--n] = 0;
            send(in, n); send("\r", 1);
            wait_prompt(0);
        }
    } else {
        for (int i = first; i < argc; ++i) {
            send(argv[i], strlen(argv[i]));
            send("\r", 1);
            if (!wait_prompt(0)) { fprintf(stderr, "\nxch: lost the harness\n"); return 1; }
        }
    }
    printf("\n");
    if (csv) fclose(csv);
    return 0;
}
