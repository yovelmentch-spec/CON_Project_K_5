```python
import numpy as np
import random

# --------------------------------------------------------------------------------------
# Little-endian and hexadecimal helper functions

def uint32_ltlend_hex_str(val):
    """
    Convert a 32-bit unsigned integer into a little-endian hexadecimal byte string.
    Example:
        0x12345678 -> "78 56 34 12 "
    """
    val &= 0xFFFFFFFF
    bigend_hex_str = '%08x' % val

    return '%s %s %s %s ' % (
        bigend_hex_str[6:8],
        bigend_hex_str[4:6],
        bigend_hex_str[2:4],
        bigend_hex_str[0:2]
    )


def int8_hex_str(val):
    """
    Convert a signed 8-bit integer into its two's-complement hexadecimal representation.
    Example:
        -1 -> "ff"
        127 -> "7f"
    """
    val = int(val) & 0xFF
    return '%02x' % val


# --------------------------------------------------------------------------------------
# K5 / XMEM configuration

XBOX_TCM_BASE_ADDR = 0x40000000

# Total available XMEM size:
# 2 banks * 1024 words * 32 bytes = 64 KB
XMEM_SIZE = 2 * 1024 * 32

MAX_N = 256


# --------------------------------------------------------------------------------------
# FFT convolution test configuration

# Fixed vector size used for comparison
n = 256

# Operation mode:
# 1 = FFT-based convolution
# 2 = Compare naive convolution against FFT-based convolution
mode = 1


# --------------------------------------------------------------------------------------
# Address alignment helper

def align_to_32(addr):
    """
    Align an address or size upward to the nearest 32-byte boundary.
    """
    return (addr + 31) & ~31


# --------------------------------------------------------------------------------------
# Calculate aligned addresses for the input and output vectors

# Each input vector contains n signed 8-bit values, therefore its size is n bytes
total_vector_size = n

# Choose a random aligned offset while reserving enough space for:
# 1. Vector C
# 2. Vector X
# 3. Output vector Y
base_ofst = align_to_32(
    random.randint(
        0,
        XMEM_SIZE - (3 * align_to_32(total_vector_size))
    )
)

# Calculate the absolute XMEM addresses
c_addr = XBOX_TCM_BASE_ADDR + base_ofst
x_addr = c_addr + align_to_32(total_vector_size)
y_addr = x_addr + align_to_32(total_vector_size)


# --------------------------------------------------------------------------------------
# Write the FFT test configuration file

with open('fft_test_config.txt', 'w') as config_file:
    config_file.write('# K5-XBOX FFT configuration - 32-byte aligned\n\n')

    config_file.write(
        '%s # c_addr = %08x\n'
        % (uint32_ltlend_hex_str(c_addr), c_addr)
    )

    config_file.write(
        '%s # x_addr = %08x\n'
        % (uint32_ltlend_hex_str(x_addr), x_addr)
    )

    config_file.write(
        '%s # y_addr = %08x\n'
        % (uint32_ltlend_hex_str(y_addr), y_addr)
    )

    config_file.write(
        '%s # n = %08x (%d decimal)\n'
        % (uint32_ltlend_hex_str(n), n, n)
    )

    config_file.write(
        '%s # mode = %08x (%d decimal)\n'
        % (uint32_ltlend_hex_str(mode), mode, mode)
    )


# --------------------------------------------------------------------------------------
# Generate random signed 8-bit input vectors

# int16 is used during generation so that the full signed int8 range,
# from -128 to 127, can be represented safely before conversion to hexadecimal
c_vec = np.random.randint(
    -128,
    128,
    size=n,
    dtype=np.int16
)

x_vec = np.random.randint(
    -128,
    128,
    size=n,
    dtype=np.int16
)


# --------------------------------------------------------------------------------------
# Write the FFT input data file

with open('fft_test_in.txt', 'w') as test_in_file:
    test_in_file.write('# FFT input data: vector C followed by vector X\n\n')

    # Write 32 bytes per line for easier visual comparison with XMEM layout
    num_bytes_per_line = 32

    # Store vector C first, followed immediately by vector X
    all_bytes = list(c_vec) + list(x_vec)

    for i, value in enumerate(all_bytes):
        test_in_file.write(int8_hex_str(value))

        if (i + 1) % num_bytes_per_line == 0:
            test_in_file.write('\n')
        else:
            test_in_file.write(' ')


# --------------------------------------------------------------------------------------
# Print generation summary

print('Generated input and configuration files with 32-byte alignment.')
print(f'N={n}, Mode={mode}')
print(
    f'Addresses: '
    f'C=0x{c_addr:08x}, '
    f'X=0x{x_addr:08x}, '
    f'Y=0x{y_addr:08x}'
)
```
