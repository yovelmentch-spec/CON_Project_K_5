# ⚡ FFT Convolution Accelerator — Software Environment

## 📌 Overview

The `SW` directory contains the software and verification environment used to operate, test, and validate the FFT-based convolution accelerator.

The software flow connects three main components:

```text
Python Input Generator
          ↓
fft_test_config.txt
fft_test_in.txt
          ↓
K5 Bare-Metal C Application
          ↓
Software FFT or FPGA Accelerator
          ↓
fft_test_out.txt
          ↓
Python Reference Checker
```

Each component has a different responsibility:

| Component                | Main responsibility                                           |
| ------------------------ | ------------------------------------------------------------- |
| Python generator         | Generates input vectors and memory configuration              |
| Bare-metal C application | Loads data, controls execution, and dumps the output          |
| Python checker           | Reproduces the fixed-point algorithm and compares the results |

Together, these components create a complete test and verification flow for the FFT accelerator.

---

# 📂 Software Directory Structure

A typical software directory may contain:

```text
SW/
├── README.md
├── gen_FFT_test2.py
├── check_FFT2.py
├── FFT_conv.c
├── compile_job.sh
├── fft_test_config.txt
├── fft_test_in.txt
└── fft_test_out.txt
```

The generated text files are used to transfer data between the host simulation environment, the K5 bare-metal application, and the FPGA accelerator.

---

# 🔄 Complete Software Flow

The complete test process is:

```text
1. Generate random input vectors
                ↓
2. Generate aligned XMEM addresses
                ↓
3. Run the K5 bare-metal application
                ↓
4. Load C and X into XMEM
                ↓
5. Run either:
   - Software FFT implementation
   - SystemVerilog hardware accelerator
                ↓
6. Store the output vector in XMEM
                ↓
7. Dump the output to fft_test_out.txt
                ↓
8. Run the Python checker
                ↓
9. Compare hardware output against the reference
```

This structure allows the same input files to be used for both software execution and hardware acceleration.

---

# 🐍 1. Python Input Generator

## 🎯 Purpose

The Python generator creates the input and configuration files required by the K5 application.

It automatically performs the following operations:

✅ Selects the FFT length
✅ Selects the execution mode
✅ Generates two signed 8-bit input vectors
✅ Allocates addresses inside the XMEM region
✅ Aligns buffer addresses to 32-byte boundaries
✅ Converts configuration values to little-endian format
✅ Converts signed input values to hexadecimal bytes
✅ Writes the generated data into text files

The generator creates:

```text
fft_test_config.txt
fft_test_in.txt
```

---

## ⚙️ Main Configuration

The main test parameters are:

```python
n = 256
mode = 1
```

### FFT Length

`n` defines the number of elements in each input vector.

For:

```python
n = 256
```

the generator creates:

```text
256 values for vector C
256 values for vector X
512 input bytes in total
```

The current software and hardware implementations support:

```python
MAX_N = 256
```

Because the implementation uses a radix-2 FFT, `N` must be a power of two.

Valid examples include:

```text
8, 16, 32, 64, 128, 256
```

---

## 🎛️ Execution Modes

The mode is written into the configuration file and later read by the C application.

The software application interprets the modes as follows:

| Mode | Software behavior                                                                        |
| ---- | ---------------------------------------------------------------------------------------- |
| `0`  | Run naive circular convolution                                                           |
| `1`  | Run FFT-based circular convolution                                                       |
| `2`  | Calculate both naive and FFT paths, while the FFT result is written to the output buffer |

Mode `2` can be useful for internal performance or algorithm comparisons.

However, the output written to `fft_test_out.txt` is still selected from the FFT result when the mode is not zero.

---

## 🧠 XMEM Configuration

The XMEM base address is:

```python
XBOX_TCM_BASE_ADDR = 0x40000000
```

The total available memory size is defined as:

```python
XMEM_SIZE = 2 * 1024 * 32
```

This represents:

```text
2 × 1024 × 32 bytes
        =
65536 bytes
        =
64 KB
```

The generator reserves memory for three buffers:

```text
C input vector
X input vector
Y output vector
```

---

## 📐 Address Alignment

The generator aligns addresses to 32-byte boundaries:

```python
def align_to_32(addr):
    return (addr + 31) & ~31
```

An aligned address satisfies:

```text
address % 32 = 0
```

The memory layout is:

```text
Lower XMEM Address
        │
        ▼
┌─────────────────────────────┐
│ C input vector              │
│ N signed 8-bit values       │
└─────────────────────────────┘
        │
        ▼
      x_addr
┌─────────────────────────────┐
│ X input vector              │
│ N signed 8-bit values       │
└─────────────────────────────┘
        │
        ▼
      y_addr
┌─────────────────────────────┐
│ Y output vector             │
│ N signed 8-bit values       │
└─────────────────────────────┘
```

For `N = 256`, every vector occupies:

```text
256 bytes = 0x100 bytes
```

Therefore:

```text
x_addr = c_addr + 0x100
y_addr = x_addr + 0x100
```

---

## 📄 Configuration File

The generated `fft_test_config.txt` file contains five 32-bit values:

```text
c_addr
x_addr
y_addr
n
mode
```

Example:

```text
40 2a 00 40  # c_addr = 40002a40
40 2b 00 40  # x_addr = 40002b40
40 2c 00 40  # y_addr = 40002c40
00 01 00 00  # n = 00000100 (256 decimal)
01 00 00 00  # mode = 00000001 (1 decimal)
```

The values are written in little-endian byte order.

For example:

```text
32-bit value:          0x40002A40
Little-endian bytes:   40 2A 00 40
```

---

## 🔢 Input File

The generated `fft_test_in.txt` file contains:

```text
C[0], C[1], ..., C[N-1],
X[0], X[1], ..., X[N-1]
```

The input values are signed 8-bit integers:

```text
-128 ≤ value ≤ 127
```

They are written as raw hexadecimal bytes using two's-complement representation.

| Decimal | Hexadecimal byte |
| ------- | ---------------- |
| `0`     | `00`             |
| `1`     | `01`             |
| `127`   | `7f`             |
| `-1`    | `ff`             |
| `-2`    | `fe`             |
| `-128`  | `80`             |

The values are written using 32 bytes per line.

This makes the file easier to compare against the 32-byte XMEM block organization.

---

## 🎲 Reproducible Tests

By default, every execution generates new vectors and new memory addresses.

For reproducible debugging, fixed seeds can be added:

```python
random.seed(1)
np.random.seed(1)
```

This ensures that every execution produces the same:

```text
C vector
X vector
Memory offset
XMEM addresses
```

This is useful when investigating a specific mismatch between Python, C, and RTL.

---

# 🧾 2. K5 Bare-Metal C Application

## 🎯 Purpose

The C application is the central control layer of the software environment.

It is responsible for:

✅ Reading the generated configuration
✅ Loading the input vectors into XMEM
✅ Selecting software or hardware execution
✅ Configuring the accelerator registers
✅ Starting the hardware accelerator
✅ Waiting for the hardware to finish
✅ Measuring execution cycles
✅ Dumping the output to a file

The C application supports two execution paths:

```text
Software execution
        or
SystemVerilog hardware acceleration
```

The selection is made during compilation.

---

## 🧩 Main Data Types

The fixed-point complex number type is:

```c
typedef struct {
    int32_t re;
    int32_t im;
} cq15;
```

Each complex value contains:

```text
re → real component
im → imaginary component
```

Both components are stored as signed 32-bit integers.

The application configuration is stored in:

```c
typedef struct fft_conv_config {
    volatile int8_t *c_addr;
    volatile int8_t *x_addr;
    volatile int8_t *y_addr;
    int32_t n;
    int32_t mode;
} fft_conv_config_t;
```

This structure contains:

| Field    | Description                  |
| -------- | ---------------------------- |
| `c_addr` | Address of vector `C`        |
| `x_addr` | Address of vector `X`        |
| `y_addr` | Address of output vector `Y` |
| `n`      | FFT length                   |
| `mode`   | Selected execution mode      |

---

## 🗃️ Memory-Mapped Accelerator Registers

The accelerator is controlled through memory-mapped registers.

The register indexes are:

```c
#define FFT_C_ADDR_REG_IDX   0
#define FFT_X_ADDR_REG_IDX   1
#define FFT_Y_ADDR_REG_IDX   2
#define FFT_N_REG_IDX        3
#define FFT_MODE_REG_IDX     4
#define FFT_START_REG_IDX    5
#define FFT_DONE_REG_IDX     6
```

The application exposes registers for:

```text
C input address
X input address
Y output address
FFT length
Execution mode
Start command
Done status
```

The corresponding pointers are created relative to `XBOX_REGS_BASE_ADDR`.

The control flow is:

```text
Write addresses
      ↓
Write N and mode
      ↓
Set START = 1
      ↓
Wait until DONE = 1
```

---

## 📥 Loading the Configuration

The configuration file is opened using:

```c
int cfg_f = bm_fopen_r("fft_test_config.txt");
```

Five 32-bit values are loaded:

```c
uint32_t words[5] = {0};
```

They are interpreted as:

```text
words[0] → c_addr
words[1] → x_addr
words[2] → y_addr
words[3] → n
words[4] → mode
```

The application then prints the loaded values to the simulation log.

This helps confirm that the C application read the same values that were generated by Python.

---

## 📥 Loading Input Data into XMEM

The input file contains:

```text
C followed by X
```

The total number of bytes is:

```c
int total_bytes = 2 * cfg->n;
```

The application loads the input file directly into XMEM.

The intended layout is:

```text
cfg->c_addr[0 ... N-1]       = C
cfg->c_addr[N ... 2N-1]      = X
cfg->x_addr                  = cfg->c_addr + N
```

The C application explicitly recalculates:

```c
cfg->x_addr = base_addr + cfg->n;
```

This guarantees that vector `X` begins immediately after vector `C` in memory.

For the current configuration:

```text
N = 256
```

this matches the generator's 32-byte-aligned layout because 256 is already a multiple of 32.

For future configurations in which `N` is not divisible by 32, the generator and C memory-layout rules would need to be reviewed together.

---

## 🔍 Input Debug Verification

After loading the input vectors, the C application calculates:

```text
SUM_C
SUM_X
```

It also prints selected regions from both vectors:

```text
First 16 values
Values around index 64
Values around index 128
Values around index 192
Last 8 values
```

Example output:

```text
===== C APP LOADED VECTOR CHECK =====
SUM_C = ...
SUM_X = ...

APP_BUF[0] c=... x=...
APP_BUF[1] c=... x=...
```

The Python checker prints the same regions.

This allows direct comparison between:

```text
What Python generated
        and
What the C application loaded into XMEM
```

If the values differ at this stage, the problem is related to file loading, address calculation, or memory layout rather than the FFT algorithm.

---

## 🧱 Memory Fences

The C application uses:

```c
asm volatile ("fence rw, rw" ::: "memory");
```

The fence ensures ordering between memory reads and writes.

It is used:

```text
After loading input data
Before starting the accelerator
After writing accelerator registers
After accelerator completion
Before dumping output data
```

The fence helps prevent the processor or compiler from reordering memory operations around accelerator control operations.

A memory fence is not necessarily equivalent to a full data-cache flush.

If the K5 system uses a data cache that is not coherent with the accelerator, a dedicated cache clean or invalidate operation may also be required.

---

# 💻 Software FFT Implementation

## 🔢 Fixed-Point Representation

The software FFT uses Q15 multiplication.

The Q15 constants are:

```c
#define Q15_SHIFT 15
#define Q15_ONE   (1 << Q15_SHIFT)
```

A Q15 value represents a fractional number using 15 fractional bits.

Conceptually:

```text
Stored integer = Real value × 2¹⁵
```

For example:

```text
1.0  → approximately 32768
0.5  → approximately 16384
-0.5 → approximately -16384
```

---

## ⚙️ Q15 Multiplication

Q15 multiplication is implemented as:

```c
static inline int32_t q15_mul(int32_t a, int32_t b) {
    int64_t t = (int64_t)a * (int64_t)b;
    t += (1 << (Q15_SHIFT - 1));
    return (int32_t)(t >> Q15_SHIFT);
}
```

The multiplication uses a 64-bit intermediate value to avoid losing the upper product bits.

The operation includes:

```text
64-bit multiplication
        ↓
Add rounding value
        ↓
Shift right by 15
        ↓
Return Q15 result
```

The addition of:

```c
1 << 14
```

implements rounding before the right shift.

---

## 🔢 Complex Multiplication

Complex multiplication follows:

```text
(ar + j·ai)(br + j·bi)
```

The result is:

```text
Real = ar·br - ai·bi
Imag = ar·bi + ai·br
```

The C implementation uses Q15 multiplication for every product:

```c
r.re = q15_mul(a.re, b.re) - q15_mul(a.im, b.im);
r.im = q15_mul(a.re, b.im) + q15_mul(a.im, b.re);
```

The Python checker implements the same sequence to reproduce the fixed-point behavior.

---

## 🔀 Bit-Reversal Table

Before the iterative radix-2 FFT stages, the input is reordered using bit-reversed indexes.

For example, in an 8-point FFT:

```text
Decimal index     Binary     Reversed     New index
0                 000        000          0
1                 001        100          4
2                 010        010          2
3                 011        110          6
4                 100        001          1
```

The C application creates a bit-reversal lookup table during initialization.

This table is then used to reorder values before the butterfly stages.

---

## 🌀 Twiddle Factors

The twiddle factors are stored in:

```c
static cq15 W[MAX_N / 2];
```

They represent:

```text
Wₙᵏ = cos(2πk/N) - j·sin(2πk/N)
```

The software generates Q15 twiddle values using:

```c
W[k].re = (int32_t)(cos(ang) * Q15_ONE);
W[k].im = (int32_t)(sin(ang) * Q15_ONE);
```

The inverse FFT negates the imaginary component of the selected twiddle factor.

---

## 🦋 Scaled Radix-2 FFT

The software uses an iterative radix-2 FFT.

The stage lengths are:

```text
2
4
8
16
...
N
```

Each butterfly calculates:

```text
u = upper input
v = lower input × twiddle

upper output = u + v
lower output = u - v
```

The implementation divides both butterfly outputs by two:

```c
a[i + j].re = (u.re + v.re) >> 1;
a[i + j].im = (u.im + v.im) >> 1;

a[i + j + half].re = (u.re - v.re) >> 1;
a[i + j + half].im = (u.im - v.im) >> 1;
```

This stage-by-stage scaling reduces the risk of fixed-point overflow.

Because the division is performed at every stage, an `N`-point FFT receives an overall scaling factor related to:

```text
1 / N
```

The same scaling method is reproduced by the Python checker.

---

# 🔄 Software Circular Convolution

The software supports both naive circular convolution and FFT-based circular convolution.

## 🧮 Naive Convolution

The direct circular convolution is:

```text
y[i] = Σ C[k] × X[(i - k) mod N]
```

This method requires approximately:

```text
N² multiply-and-accumulate operations
```

The C implementation runs this path when:

```c
cfg->mode != 1
```

Therefore, it is executed in modes `0` and `2`.

---

## ⚡ FFT-Based Convolution

The FFT-based path performs:

```text
FFT(C)
   ↓
FFT(X)
   ↓
Pointwise complex multiplication
   ↓
IFFT
```

Mathematically:

```text
Y = IFFT(FFT(C) × FFT(X))
```

Before entering the FFT, each signed 8-bit input value is shifted left by 12:

```c
A[i].re = (int32_t)cfg->c_addr[i] << 12;
B[i].re = (int32_t)cfg->x_addr[i] << 12;
```

The imaginary parts are initialized to zero.

The software then performs:

```c
fft_inplace_q15(A, n, 0);
fft_inplace_q15(B, n, 0);
```

followed by pointwise complex multiplication and an inverse FFT.

---

# 📏 Output Normalization

The raw FFT result may exceed the signed 8-bit output range.

The application finds the maximum absolute result:

```text
max_fft = max(abs(tmp_fft[i]))
```

The values are normalized using:

```text
normalized = raw × 127 / maximum
```

The normalized result is limited to:

```text
-128 to 127
```

and stored as an `int8_t` value in the output buffer.

This normalization preserves the relative shape of the output while fitting the result into one signed byte.

---

# 🚀 Hardware Accelerator Execution

## ⚙️ Accelerator Configuration

When the hardware path is enabled, the C application writes:

```text
C address
X address
Y address
N
Mode
```

to the memory-mapped registers.

It then starts the accelerator:

```c
*FFT_START_REG = 1;
```

and waits for:

```c
while (!*FFT_DONE_REG) {
    // wait
}
```

The processor remains in the polling loop until the hardware sets the `DONE` register.

---

## 🔀 Selecting Hardware or Software Execution

The execution path is selected using compilation defines.

### Hardware enabled

```text
-DXON
```

causes:

```c
is_xlr_enabled = TRUE;
```

The application calls:

```c
fft_conv_xlr(&cfg);
```

### Hardware disabled

```text
-DXOFF
```

or compiling without `XON` causes the software path to run:

```c
init_infra(cfg.n);
fft_conv_sw(&cfg);
```

The `compile_job.sh` script determines which version is built.

---

## ⏱️ Cycle Measurement

The C application measures only the selected computation path.

The measured section surrounds either:

```text
Hardware accelerator execution
```

or:

```text
Software FFT/convolution execution
```

The result is printed as:

```text
*** Measured execution time: XXXXX cycles ***
```

This makes it possible to compare:

```text
Software cycle count
        against
Hardware accelerator cycle count
```

The input file loading and output file dumping are outside the measured computation section.

---

## 📤 Output Dump

After execution, the C application dumps `N` bytes from `y_addr`:

```c
bm_start_soc_store_hex_file(
    dump_f,
    cfg->n,
    32,
    (unsigned char*)cfg->y_addr
);
```

The output is written to:

```text
fft_test_out.txt
```

The dump uses 32 bytes per line.

This output file is later read by the Python checker.

---

# 🔍 3. Python Reference Checker

## 🎯 Purpose

The Python checker reproduces the fixed-point FFT computation and compares it against the output generated by the C application or FPGA accelerator.

It performs:

✅ Input-file parsing
✅ Signed `int8` conversion
✅ Q15 complex multiplication
✅ Radix-2 fixed-point FFT
✅ Pointwise frequency-domain multiplication
✅ Fixed-point IFFT
✅ Output normalization
✅ Hardware-versus-reference comparison
✅ Detailed debug printing

The checker reads:

```text
fft_test_in.txt
fft_test_out.txt
```

---

# 📖 Flexible File Parsing

The checker supports both hexadecimal and decimal input formats.

## Hexadecimal example

```text
53 09 46 1c a8 ff
```

## Decimal example

```text
83 9 70 28 -88 -1
```

Lines beginning with:

```text
#
```

are ignored.

This allows the generated files to contain explanatory comments without affecting the parser.

The parser recognizes two-digit hexadecimal tokens using:

```python
re.fullmatch(r"[0-9a-fA-F]{2}", p)
```

and signed decimal values using:

```python
re.fullmatch(r"-?\d+", p)
```

---

# 🔢 Signed 8-Bit Conversion

The file parser initially reads hexadecimal bytes as unsigned values.

For example:

```text
ff → 255
80 → 128
```

The function:

```python
def to_int8(v):
    v = int(v) & 0xFF

    if v >= 128:
        return v - 256

    return v
```

converts them back into signed values:

```text
255 → -1
254 → -2
128 → -128
127 → 127
```

This matches the interpretation of `int8_t` values in the C application and RTL design.

---

# 🔢 Python Q15 Multiplication

The Python checker reproduces the C and hardware Q15 multiplication:

```python
def q15_mul(a, b):
    t = np.int64(a) * np.int64(b)
    t += np.int64(1 << 14)
    return np.int32(t >> 15)
```

The operation uses a 64-bit intermediate value.

The steps are:

```text
Multiply
   ↓
Add rounding value
   ↓
Arithmetic right shift by 15
   ↓
Return signed 32-bit result
```

Using the same rounding and shifting rules is essential.

A floating-point NumPy FFT would not accurately reproduce the fixed-point hardware behavior.

---

# 🔢 Python Complex Multiplication

The function:

```python
def complex_mul(a, b):
```

calculates:

```text
Real = q15_mul(ar, br) - q15_mul(ai, bi)
Imag = q15_mul(ar, bi) + q15_mul(ai, br)
```

This matches the complex multiplication used by the C implementation and accelerator datapath.

---

# 🔀 Python Bit Reversal

The checker calculates the reversed index using:

```python
def bit_reverse(i, bits):
```

For each input index, the lowest `log₂(N)` bits are reversed.

The FFT input array is then reordered before processing the butterfly stages.

This matches the radix-2 decimation-in-time structure used by the C and RTL implementations.

---

# 🦋 Python Fixed-Point FFT

The main FFT function is:

```python
fft_fixed_scaled(inp, inverse=False)
```

It performs:

```text
Power-of-two validation
        ↓
Bit-reversal reordering
        ↓
Iterative radix-2 stages
        ↓
Q15 twiddle generation
        ↓
Complex butterfly operations
        ↓
Divide by two at every stage
```

The function rejects invalid lengths:

```python
if N <= 0 or (N & (N - 1)) != 0:
    raise RuntimeError(...)
```

---

## 🌀 Twiddle-Factor Generation

For every butterfly position, the checker calculates:

```python
angle = -2.0 * np.pi * j / length
```

For the inverse FFT:

```python
angle = -angle
```

The floating-point sine and cosine values are converted into Q15 integers:

```python
w_re = np.int32(int(np.cos(angle) * 32768))
w_im = np.int32(int(np.sin(angle) * 32768))
```

The use of Python's `int()` is intentional.

It truncates toward zero, matching the intended reference behavior for twiddle-factor generation.

---

## 📉 Per-Stage Scaling

Every butterfly output is shifted right by one:

```python
A[upper] = add_result >> 1
A[lower] = subtract_result >> 1
```

This is the same scaling policy used by the C and hardware FFT implementations.

It prevents the intermediate values from growing by one bit during every butterfly stage.

---

# 📥 Input Detection

The checker determines `N` directly from the input file.

Because the file contains:

```text
N values of C
followed by
N values of X
```

the checker calculates:

```python
N = len(in_nums) // 2
```

It verifies that:

```text
The input is not empty
The output is not empty
The input contains an even number of values
N is a power of two
The output contains at least N values
```

This avoids silently running the comparison with incomplete or malformed files.

---

# 🔍 Input-Loading Debug Prints

The checker prints:

```text
SUM_C
SUM_X
```

and selected vector regions:

```text
First 16 values
Around index 64
Around index 128
Around index 192
Last 8 values
```

These prints should be compared against the matching C application prints.

Expected comparison:

```text
PY_BUF[i] c=... x=...
APP_BUF[i] c=... x=...
```

If the Python and C values match, the input-file and XMEM-loading stages are working correctly.

---

# 🔼 Preparing FFT Inputs

The checker creates two complex arrays:

```python
A = np.zeros((N, 2), dtype=np.int32)
B = np.zeros((N, 2), dtype=np.int32)
```

The real components are initialized as:

```python
A[:, 0] = c << 12
B[:, 0] = x << 12
```

The imaginary components are zero.

This exactly follows the C implementation:

```text
Real input = signed int8 value shifted left by 12
Imaginary input = 0
```

---

# 🌀 Reference Computation Flow

The checker performs:

```python
A_f = fft_fixed_scaled(A, inverse=False)
B_f = fft_fixed_scaled(B, inverse=False)
```

followed by:

```python
Out[i] = complex_mul(A_f[i], B_f[i])
```

and then:

```python
Y_complex = fft_fixed_scaled(Out, inverse=True)
```

The complete mathematical flow is:

```text
C
 ↓
FFT(C)
       \
        × → IFFT → Raw output
       /
FFT(X)
 ↑
X
```

---

# 📏 Python Output Normalization

The checker extracts the real component:

```python
y_raw = Y_complex[:, 0]
```

It then finds:

```python
maxv = np.max(np.abs(y_raw))
```

To avoid division by zero:

```python
if maxv == 0:
    maxv = 1
```

The normalized reference is:

```python
y_ref_i64 = (y_raw * 127) // maxv
```

The result is converted back into signed 8-bit form.

---

## ⚠️ Division Semantics

Python's `//` operator performs floor division.

This is relevant for negative values.

For example:

```text
-5 // 2 = -3
```

In standard C integer division:

```text
-5 / 2 = -2
```

because C truncates toward zero.

Therefore, the Python checker reflects the intended hardware/reference normalization rule, but differences of one may occur if the RTL or C implementation uses truncation rather than floor division.

This is one reason the checker supports a small tolerance.

---

# 🎯 Comparison and Tolerance

The comparison tolerance is:

```python
TOLERANCE = 2
```

The checker calculates:

```python
diff = y_ref - hw
abs_diff = np.abs(diff)
```

A value is considered a mismatch when:

```text
absolute difference > 2
```

The checker reports:

```text
Maximum absolute error
Number of mismatches
Total number of output values
First 32 detailed comparisons
```

Example:

```text
Index | HW | REF | DIFF
    0 |  12 |  12 |    0
    1 | -35 | -34 |    1
    2 |  54 |  50 |    4
```

At the end, the checker prints:

```text
SUCCESS: MATCH
```

when no value exceeds the tolerance.

Otherwise, it prints:

```text
STILL DIFFS
```

---

# 🐛 Debug Output

The checker can print intermediate values from every major stage.

Debugging is enabled using:

```python
DEBUG_PRINT = True
DEBUG_COUNT = 16
```

The printed stages are:

```text
Input vectors
FFT of C
FFT of X
Pointwise multiplication
IFFT result
Normalized output
Final hardware comparison
```

These values can be compared against corresponding RTL `$display` messages.

A useful comparison sequence is:

```text
Python IN       ↔ RTL IN
Python CFFT     ↔ RTL FFT_C
Python XFFT     ↔ RTL FFT_X
Python MUL      ↔ RTL MUL
Python IFFT     ↔ RTL IFFT
Python NORM     ↔ RTL normalization
Python REF      ↔ dumped HW output
```

This allows the first incorrect stage to be located quickly.

---

# ▶️ Running the Software Flow

## Step 1 — Generate the Input Files

Run the Python input generator:

```bash
python3 gen_FFT_test2.py
```

Expected generated files:

```text
fft_test_config.txt
fft_test_in.txt
```

---

## Step 2 — Compile the K5 Application

Use the project compilation script:

```bash
./compile_job.sh
```

For hardware execution, the application should be compiled with:

```text
-DXON
```

For software execution, use:

```text
-DXOFF
```

or remove the hardware-enable define, depending on the build environment.

---

## Step 3 — Run the K5 Simulation

Run the application using the normal K5 simulation flow.

The application will:

```text
Load the configuration
Load C and X into XMEM
Run software or hardware execution
Print the cycle count
Dump Y into fft_test_out.txt
```

---

## Step 4 — Run the Checker

After `fft_test_out.txt` has been generated, run:

```bash
python3 check_FFT2.py
```

The checker will automatically detect `N`, calculate the reference result, and compare it against the dumped output.

---

# 🧪 Recommended Verification Procedure

When a mismatch occurs, check the stages in this order:

## 1. Verify the input-file length

For `N = 256`:

```text
fft_test_in.txt  → 512 values
fft_test_out.txt → at least 256 values
```

## 2. Compare Python and C input prints

Compare:

```text
SUM_C
SUM_X
PY_BUF[i]
APP_BUF[i]
```

## 3. Compare RTL input values

Verify that the accelerator reads the same `C` and `X` values.

## 4. Compare FFT(C)

Find the first mismatch between:

```text
Python CFFT
RTL FFT_C
```

## 5. Compare FFT(X)

Find the first mismatch between:

```text
Python XFFT
RTL FFT_X
```

## 6. Compare pointwise multiplication

Compare:

```text
Python MUL
RTL MUL
```

## 7. Compare IFFT

Compare:

```text
Python IFFT
RTL IFFT
```

## 8. Compare normalization

Check:

```text
Maximum absolute value
Signed multiplication
Division behavior
Output clipping
```

This staged method is more effective than looking only at the final output file.

---

# ⚠️ Important Implementation Details

* The input vectors are signed 8-bit values.
* The internal FFT values are signed 32-bit fixed-point values.
* Input samples are shifted left by 12 before entering the FFT.
* Q15 multiplication uses a 64-bit intermediate product.
* Q15 multiplication adds `2¹⁴` before shifting right by 15.
* The FFT divides each butterfly output by two at every stage.
* The FFT length must be a power of two.
* The current maximum supported length is 256.
* The output contains only the real component of the IFFT.
* The output is normalized to the signed 8-bit range.
* The input file stores `C` first and `X` second.
* The C application places `X` immediately after `C` in XMEM.
* Hardware execution uses memory-mapped `START` and `DONE` registers.
* Memory fences are used around processor/accelerator communication.
* The output checker allows a tolerance of two integer levels.
* Python floor division and C truncating division may differ for negative values.

---

# 📊 Software and Hardware Responsibilities

| Operation                | Python generator | C application | RTL accelerator | Python checker |
| ------------------------ | ---------------- | ------------- | --------------- | -------------- |
| Generate random inputs   | ✅                |               |                 |                |
| Generate addresses       | ✅                |               |                 |                |
| Load data into XMEM      |                  | ✅             |                 |                |
| Configure accelerator    |                  | ✅             |                 |                |
| FFT of C                 |                  | Optional      | ✅               | ✅              |
| FFT of X                 |                  | Optional      | ✅               | ✅              |
| Pointwise multiplication |                  | Optional      | ✅               | ✅              |
| IFFT                     |                  | Optional      | ✅               | ✅              |
| Normalization            |                  | Optional      | ✅               | ✅              |
| Cycle measurement        |                  | ✅             |                 |                |
| Dump output              |                  | ✅             |                 |                |
| Final comparison         |                  |               |                 | ✅              |

---

# 📚 Summary

The `SW` directory provides the full control and verification environment for the FFT convolution accelerator.

The Python generator prepares hardware-compatible test inputs:

```text
Random C and X vectors
Aligned XMEM addresses
Little-endian configuration values
```

The K5 bare-metal C application controls execution:

```text
Load input
Configure memory
Run software or hardware
Measure cycles
Dump output
```

The Python checker recreates the fixed-point datapath:

```text
Scaled FFT(C)
Scaled FFT(X)
Complex pointwise multiplication
Scaled IFFT
Signed normalization
Output comparison
```

Together, the three components provide:

✅ Automated test generation
✅ Software and hardware execution modes
✅ Fixed-point reference verification
✅ Intermediate-stage debugging
✅ Cycle-count measurement
✅ Reproducible FPGA accelerator testing
