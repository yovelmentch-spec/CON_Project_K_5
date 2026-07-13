# ⚡ CNN Acceleration Using FFT on FPGA

## 📌 Project Overview

This project is based on the idea of accelerating neural network computations by transforming expensive matrix operations into FFT-based computations that are more suitable for hardware acceleration.

The original motivation comes from deep learning acceleration methods that use structured weight matrices, especially **block-circulant matrices**, to reduce both computation complexity and memory requirements.

In such a structure, matrix-vector multiplication can be reformulated as:

```text
FFT → Element-wise Multiplication → IFFT
```

Instead of performing a full direct matrix multiplication, the computation is moved into the frequency domain, where convolution-like operations become simple element-wise multiplications.

In this project, we focused on implementing the core computational block of this method:

```text
FFT Accelerator on FPGA
```

The project was developed in three main stages:

```text
Python Reference Model
        ↓
C Bare-Metal Implementation
        ↓
SystemVerilog FFT Hardware Implementation
```

---

## 🎯 Motivation

Convolutional Neural Networks (CNNs) require a large number of multiply-and-accumulate operations. These operations are computationally expensive, especially when running on general-purpose processors.

A major bottleneck in CNN inference is the large amount of matrix and convolution operations. These operations require:

* 🧮 Many arithmetic operations
* 🧠 Large storage for weights
* 🔁 High memory bandwidth
* 🔋 High energy consumption
* ⏱️ Long execution time on general-purpose processors

The main idea behind this project is to reduce the computational burden by using FFT-based computation and moving the heavy computation into dedicated FPGA hardware.

FPGA implementation allows the design to exploit:

* ⚙️ Parallelism
* 🚦 Pipelining
* 🔢 Fixed-point arithmetic
* 🧩 Dedicated datapaths
* 💾 On-chip memory usage
* 🔁 Hardware resource reuse

---

## 🧠 Background

In a CNN, convolution layers apply learned filters over input feature maps. These convolution operations can be represented as matrix operations.

However, direct matrix multiplication is expensive.

When the weight matrix has a **circulant** or **block-circulant** structure, the multiplication can be computed more efficiently using FFT.

For a circulant block `C` and an input vector `x`, the multiplication can be expressed as:

```text
C · x = IFFT( FFT(c) · FFT(x) )
```

Where:

* `c` is the vector that defines the circulant matrix
* `x` is the input vector
* `FFT(c)` and `FFT(x)` are their frequency-domain representations
* The multiplication in the frequency domain is element-wise
* `IFFT` converts the result back to the original domain

This approach reduces direct multiplication and creates a more hardware-friendly computation flow.

---

## 🏗️ Project Goal

The goal of this project was not to implement a full CNN accelerator from end to end.

Instead, we focused on a key computational kernel required by the acceleration method:

```text
FFT Hardware Core
```

The FFT block is a central part of the proposed acceleration flow because it enables the transformation of convolution or circulant matrix multiplication into frequency-domain computation.

The main objectives were:

* ✅ Understand the algorithmic acceleration method
* ✅ Build a Python reference model
* ✅ Implement a C bare-metal version for hardware-oriented control
* ✅ Implement the FFT core in SystemVerilog
* ✅ Prepare the design for FPGA-based execution
* ✅ Analyze hardware-related challenges such as bit width, timing, memory, and resource usage

---

## 🔄 Implementation Flow

### 🐍 1. Python Reference Model

The first stage was implemented in Python.

The purpose of the Python model was to:

* Validate the mathematical idea
* Generate input vectors
* Compute reference FFT results
* Compare direct computation against FFT-based computation
* Help debug later hardware implementations

Python was used as a high-level reference environment because it provides fast development and convenient numerical tools.

However, Python is not suitable as the final implementation for FPGA acceleration because it runs as software and does not represent actual hardware behavior, timing, or resource usage.

---

### 🧾 2. C Bare-Metal Implementation

The second stage was implemented in C bare-metal style.

The C implementation represents a more hardware-oriented software layer. It is closer to how an embedded processor would control an FPGA accelerator.

The C code is responsible for:

* Preparing input data
* Managing buffers
* Running the software version of the computation
* Measuring execution cycles
* Comparing direct and FFT-based computation
* Modeling quantized CNN-like behavior
* Preparing the control flow for a future hardware accelerator

In a real FPGA system, the processor typically controls the accelerator using memory-mapped registers such as:

```text
START
DONE
INPUT_ADDR
OUTPUT_ADDR
SIZE
CONTROL
STATUS
```

The C code acts as the host-control layer, while the SystemVerilog module performs the actual hardware computation.

---

### 🔧 3. SystemVerilog FFT Implementation

The final stage focused on implementing the FFT core in SystemVerilog.

Unlike Python or C, SystemVerilog does not describe software instructions. It describes actual digital hardware.

The FFT hardware includes:

* Datapath logic
* Butterfly computation stages
* Complex arithmetic
* Twiddle factor usage
* Fixed-point representation
* Pipeline-oriented structure
* FPGA-compatible control logic

The goal of the SystemVerilog implementation was to build a dedicated FFT hardware accelerator rather than simply execute FFT as software.

---

## 🧭 High-Level Architecture

The system can be described using the following block diagram:

```text
+----------------------------+
| 🐍 Python Reference Model  |
| - Generates inputs         |
| - Computes reference       |
| - Validates results        |
+-------------+--------------+
              |
              v
+----------------------------+
| 🧾 C Bare-Metal Layer      |
| - Prepares buffers         |
| - Controls execution       |
| - Measures cycles          |
| - Models quantization      |
+-------------+--------------+
              |
              v
+----------------------------+
| 💾 Register / Memory       |
| Interface                  |
| - Input buffer             |
| - Output buffer            |
| - Control registers        |
+-------------+--------------+
              |
              v
+----------------------------+
| 🔧 SystemVerilog FFT Core  |
| - Butterfly stages         |
| - Twiddle factors          |
| - Fixed-point math         |
| - Pipelined datapath       |
+-------------+--------------+
              |
              v
+----------------------------+
| ✅ Output / Verification   |
| - Read result              |
| - Compare to reference     |
+----------------------------+
```

---

## 📊 Data Flow

The algorithmic data flow is:

```text
Input Vector
     ↓
FFT of Input
     ↓
FFT of Circulant Weight Vector
     ↓
Element-wise Complex Multiplication
     ↓
IFFT
     ↓
Normalization / Requantization
     ↓
Output Vector
```

In the final hardware-oriented view:

```text
Memory → FFT Core → Frequency-Domain Multiply → IFFT → Output Memory
```

The software layer controls the hardware, but the heavy computation is intended to be performed by the FPGA accelerator.

---

## 🔢 Fixed-Point Arithmetic

One of the main hardware challenges was the transition from floating-point computation to fixed-point arithmetic.

In Python, values can be represented using floating-point numbers. However, floating-point arithmetic is expensive in FPGA hardware. It requires more logic, more area, more power, and often makes timing closure harder.

Therefore, the hardware implementation uses fixed-point arithmetic.

Fixed-point allows decimal values to be represented as scaled integers.

For example, a value such as:

```text
0.707
```

can be stored as an integer using a predefined scale factor.

This is especially important for FFT because FFT uses twiddle factors, which are based on sine and cosine values and are usually fractional.

Using fixed-point arithmetic allows the design to:

* Reduce hardware area
* Reduce power consumption
* Improve timing
* Use FPGA DSP blocks efficiently
* Control bit widths explicitly

The trade-off is numerical accuracy. Fixed-point introduces quantization error, so the bit width and scaling must be chosen carefully.

---

## 🎚️ Normalization and Requantization

After FFT, element-wise multiplication, and IFFT, the output values may exceed the target numeric range.

For example, if the final output should be represented as `int8`, the valid range is approximately:

```text
-128 to 127
```

However, the intermediate computation may produce larger values. Therefore, a normalization or requantization stage is required.

The purpose of this stage is to map the computed output back into the target range while preserving the relative values as much as possible.

A hardware-friendly approach is to avoid direct division and instead use:

```text
Multiply + Shift
```

For example:

```text
y_norm ≈ (y * multiplier) >> shift
```

This is preferred in FPGA because multiplication can be mapped to DSP blocks, while shifting is very cheap in hardware.

---

## ⚠️ Main Engineering Challenges

### 🔢 1. Floating-Point to Fixed-Point

The Python model uses floating-point arithmetic, while the FPGA implementation requires limited-width fixed-point numbers.

This creates challenges such as:

* Quantization error
* Overflow
* Rounding error
* Bit-width selection
* Scaling between FFT stages

---

### 🧮 2. Complex Arithmetic

FFT computation requires complex numbers.

A complex multiplication has the form:

```text
(a + jb)(c + jd)
```

Which becomes:

```text
real = a*c - b*d
imag = a*d + b*c
```

This requires multiple multiplications and additions, making it an important part of the hardware datapath.

---

### 🌊 3. Twiddle Factors

FFT requires twiddle factors based on sine and cosine values.

In hardware, these values must be stored as fixed-point constants, typically in ROM or included as precomputed values.

---

### ⏱️ 4. Timing and Critical Path

FFT stages may include multiplication, addition, subtraction, and register updates.

If too much combinational logic exists between registers, the design may fail timing.

Pipelining is therefore important to reduce the critical path and improve the maximum clock frequency.

---

### 💾 5. Memory Movement

Even if the FFT core is fast, the system can still be limited by data movement.

Memory bandwidth and buffer management are important considerations in accelerator design.

---

## ⚖️ Design Trade-Offs

### 🎯 Accuracy vs Hardware Cost

Using more bits improves numerical accuracy, but increases:

* Area
* Power
* Memory usage
* Routing complexity
* Critical path delay

Using fewer bits improves hardware efficiency but increases quantization error.

---

### ⚙️ Parallelism vs Resource Usage

More parallel FFT units can improve throughput, but consume more:

* DSP blocks
* LUTs
* Flip-flops
* BRAM
* Routing resources

---

### 🚦 Pipeline Depth vs Latency

Adding pipeline stages helps timing and throughput, but increases:

* Register count
* Latency
* Control complexity

---

### 🧠 Software vs Hardware Responsibility

The project separates responsibilities:

```text
Python          → Algorithm validation
C bare-metal    → Control and hardware-oriented execution flow
SystemVerilog   → Actual hardware accelerator
```

This separation makes the design easier to validate, debug, and extend.

---

## 💡 Why FPGA?

FPGA is suitable for this project because it allows the implementation of a dedicated hardware datapath for FFT computation.

Compared to running the same algorithm only in software, FPGA can provide:

* High parallelism
* Better energy efficiency
* Custom bit-width arithmetic
* Pipelined execution
* Dedicated memory structures
* Hardware-level optimization

The main benefit is that the computation is no longer limited to a general-purpose processor executing instructions sequentially. Instead, the FFT can be implemented as a custom hardware engine.

---

## 📦 Project Scope

This project focuses on the FFT acceleration block rather than a complete CNN implementation.

The reason for this scope is that FFT is the core computational component required for the larger CNN acceleration method. Implementing and understanding this block is a necessary step before building a full CNN accelerator.

Future extensions could include:

* Full FFT → Multiply → IFFT pipeline
* Complete CNN layer integration
* Real-input FFT optimization
* More advanced pipelining
* Bit-exact software reference model
* Hardware normalization using reciprocal multiply-and-shift
* Integration with memory-mapped control registers
* Performance and resource analysis on FPGA

---

## 🧩 Repository Structure

```text
.
├── hw/
│   └── xlrs/
│       └── FFT_conv/
│           └── SystemVerilog FFT accelerator files
│
├── sw/
│   └── apps/
│       └── Bare-metal C application files
│
├── sim/
│   └── Simulation-related files
│
├── main.py
│   └── Python reference model / validation scripts
│
└── README.md
```

---

## ✅ Summary

This project demonstrates the transition from a high-level neural-network acceleration idea into a hardware-oriented implementation.

The main idea is to use FFT as a computational accelerator for operations that can be reformulated using circulant or block-circulant structures.

The project flow was:

```text
Algorithm Understanding
        ↓
Python Reference Model
        ↓
C Bare-Metal Implementation
        ↓
SystemVerilog FFT Hardware Core
        ↓
FPGA-Oriented Accelerator Design
```

The project provided practical experience with:

* CNN acceleration concepts
* FFT-based computation
* FPGA-oriented design
* Fixed-point arithmetic
* Hardware/software partitioning
* RTL implementation
* Timing and resource trade-offs

The main lesson is that algorithmic efficiency does not automatically translate into hardware efficiency. To build an effective accelerator, the design must consider not only the mathematical operation, but also hardware constraints such as bit width, memory movement, pipelining, area, power, and timing.
