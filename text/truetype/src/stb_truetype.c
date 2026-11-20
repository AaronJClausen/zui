#include <stddef.h>

// No C library is linked: memory comes from the scratch a rasterizer is
// handed, and the math from the compiler's builtins or the Zig module.
// The Zig module exports these once it reads a font; they are weak so that
// a program that links this object but never reads a font still links.
__attribute__((weak)) void *zui_truetype_stbtt_allocate(size_t size, void *scratch);
__attribute__((weak)) double zui_truetype_stbtt_pow(double base, double exponent);
__attribute__((weak)) double zui_truetype_stbtt_fmod(double dividend, double divisor);
__attribute__((weak)) double zui_truetype_stbtt_cos(double angle);
__attribute__((weak)) double zui_truetype_stbtt_acos(double cosine);

static size_t zui_truetype_stbtt_strlen(const char *text) {
    size_t length = 0;
    while (text[length] != 0) length += 1;
    return length;
}

#define STBTT_malloc(size, scratch) zui_truetype_stbtt_allocate(size, scratch)
#define STBTT_free(pointer, scratch) ((void)(pointer), (void)(scratch))
#define STBTT_ifloor(x) ((int)__builtin_floor(x))
#define STBTT_iceil(x) ((int)__builtin_ceil(x))
#define STBTT_sqrt(x) __builtin_sqrt(x)
#define STBTT_pow(x, y) zui_truetype_stbtt_pow(x, y)
#define STBTT_fmod(x, y) zui_truetype_stbtt_fmod(x, y)
#define STBTT_cos(x) zui_truetype_stbtt_cos(x)
#define STBTT_acos(x) zui_truetype_stbtt_acos(x)
#define STBTT_fabs(x) __builtin_fabs(x)
#define STBTT_strlen(x) zui_truetype_stbtt_strlen(x)
#define STBTT_memcpy __builtin_memcpy
#define STBTT_memset __builtin_memset
#ifdef NDEBUG
#define STBTT_assert(x) ((void)0)
#else
#define STBTT_assert(x) ((x) ? (void)0 : __builtin_trap())
#endif

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
