#include "example_support.hpp"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

using namespace gpu;

void read_binary_file(const char* path, Span<byte> data) noexcept
{
    FILE* file = fopen(path, "rb");
    assert(file);
    fread(data.data, 1, data.size, file);
    fclose(file);
}
