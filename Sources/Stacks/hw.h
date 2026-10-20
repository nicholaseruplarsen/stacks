// Thin C layer over the two private hardware interfaces Stats also uses:
// the AppleSMC user client (temperatures, voltages, currents, power) and
// IOReport (per-block energy and CPU/GPU frequency residency).
#pragma once
#include <stdbool.h>
#include <stdint.h>

/// Opens the SMC connection; returns false when unavailable.
bool smc_open(void);
/// Reads a 4-char SMC key as a number; returns false if missing or unreadable.
bool smc_read(const char *key, double *out);

typedef struct {
    double seconds;        // interval the energies cover
    double cpu_j, gpu_j, ane_j, dram_j;
    double ecpu_mhz, pcpu_mhz, gpu_mhz;       // residency-weighted, active states only
    double ecpu_active, pcpu_active, gpu_active; // fraction of time not idle/off
} ior_sample_t;

bool ior_open(void);
/// Fills `out` with the delta since the previous call; returns false on the first call.
bool ior_sample(ior_sample_t *out);
