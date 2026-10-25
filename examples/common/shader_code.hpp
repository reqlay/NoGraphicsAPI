#pragma once
#include <NoGraphicsAPI/NoGraphicsAPI.hpp>
#include <stdio.h>
#include <stdlib.h>

// Free the returned bytes after creating the PSO.
inline gpu::Span<byte> read_shader(const char* path) noexcept
{
    FILE* file = fopen(path, "rb");
    if (!file) { fprintf(stderr, "Cannot open shader: %s\n", path); return {}; }
    fseek(file, 0, SEEK_END);
    const long size = ftell(file);
    rewind(file);
    if (size < 4 || size > 32 * 1024 * 1024) { fclose(file); return {}; }
    byte* data = static_cast<byte*>(malloc(size_t(size)));
    const bool valid = fread(data, 1, size_t(size), file) == size_t(size);
    fclose(file);
    if (!valid) { free(data); return {}; }
    return {data, uint64(size)};
}
