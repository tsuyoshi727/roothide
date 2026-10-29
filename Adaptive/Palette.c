#include "Palette.h"
#include <math.h>

bool TABRepresentativeRGB(const uint8_t *rgba, size_t count, double rgb[3]) {
    if (!rgba || !rgb || count == 0 || count > 32 * 32) return false;
    double sums[12][3] = {{0}}, weights[12] = {0};
    double neutral[3] = {0}, total = 0;
    size_t opaque = 0, chromatic = 0;
    for (size_t i = 0; i < count; ++i) {
        const uint8_t *p = rgba + i * 4;
        if (p[3] < 128) continue;
        double a = p[3] / 255.0;
        double r = fmin(1.0, p[0] / (255.0 * a));
        double g = fmin(1.0, p[1] / (255.0 * a));
        double b = fmin(1.0, p[2] / (255.0 * a));
        double hi = fmax(r, fmax(g, b)), lo = fmin(r, fmin(g, b));
        double delta = hi - lo;
        neutral[0] += r * a; neutral[1] += g * a; neutral[2] += b * a;
        total += a; ++opaque;
        if (hi < 0.22 || delta < hi * 0.22) continue;
        double hue;
        if (hi == r) hue = fmod((g - b) / delta + 6.0, 6.0);
        else if (hi == g) hue = (b - r) / delta + 2.0;
        else hue = (r - g) / delta + 4.0;
        size_t bin = (size_t)floor(hue * 2.0) % 12;
        double w = a * delta / hi * (0.35 + 0.65 * hi);
        weights[bin] += w;
        sums[bin][0] += r * w; sums[bin][1] += g * w; sums[bin][2] += b * w;
        ++chromatic;
    }
    if (!opaque) return false;
    // Ignore isolated colored specks in a neutral icon.
    if (chromatic >= 6 && chromatic * 100 >= opaque * 3) {
        size_t best = 0;
        double score = 0;
        for (size_t i = 0; i < 12; ++i) {
            double s = weights[i] + 0.5 * (weights[(i + 11) % 12] + weights[(i + 1) % 12]);
            if (s > score) { score = s; best = i; }
        }
        double w = 0;
        rgb[0] = rgb[1] = rgb[2] = 0;
        for (int offset = -1; offset <= 1; ++offset) {
            size_t i = (best + 12 + offset) % 12;
            double factor = offset == 0 ? 1.0 : 0.5;
            w += weights[i] * factor;
            for (size_t j = 0; j < 3; ++j) rgb[j] += sums[i][j] * factor;
        }
        if (w > 0) {
            for (size_t j = 0; j < 3; ++j) rgb[j] = fmin(1.0, fmax(0.0, rgb[j] / w));
            return true;
        }
    }
    // Neutral, black and white themes keep their actual average color.
    for (size_t j = 0; j < 3; ++j) rgb[j] = neutral[j] / total;
    return true;
}
