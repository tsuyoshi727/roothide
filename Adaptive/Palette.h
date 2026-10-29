#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Input is tightly packed RGBA8 with premultiplied alpha, never a caller-sized VLA.
bool TABRepresentativeRGB(const uint8_t *rgba, size_t count, double rgb[3]);
