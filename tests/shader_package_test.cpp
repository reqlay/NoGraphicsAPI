#include "../src/shader_package.hpp"
#include <stdio.h>

static uint32 failures = 0;

static void check(bool valid, const char* message)
{
    if (!valid) { ++failures; printf("FAIL: %s\n", message); }
}

int main()
{
    const uint32 original[]{0x5341474e, 1, 20, 24, 0x07230203, 0x00010500, 1, 2, 0, 0x07230203, 0x00010500, 3, 4, 0, 5};
    uint32 words[sizeof(original) / sizeof(uint32)];
    memcpy(words, original, sizeof(words));
    const gpu::ByteSpan package{reinterpret_cast<const byte*>(words), sizeof(words)};
    const gpu::ByteSpan native = gpu::detail::shader_package_code(package, false);
    const gpu::ByteSpan buffer = gpu::detail::shader_package_code(package, true);
    check(native.data == package.data + 16 && native.size == 20, "native payload is a borrowed span");
    check(buffer.data == package.data + 36 && buffer.size == 24, "buffer payload is a borrowed span");
    for (uint32 size = 0; size < sizeof(words); ++size)
        check(!gpu::detail::shader_package_code({package.data, size}, false).size, "truncated packages are rejected");
    check(!gpu::detail::shader_package_code({nullptr, sizeof(words)}, false).size, "null input is rejected");
    check(!gpu::detail::shader_package_code({package.data, sizeof(words) + 4}, false).size, "trailing bytes are rejected");
    const uint32 mutations[][2]{{0, 0}, {1, 2}, {2, 0}, {3, 16}, {2, 21}, {3, 25}, {2, 0xfffffffcu}, {3, 0xfffffffcu}, {4, 0}, {9, 0}};
    for (const uint32 (&mutation)[2] : mutations)
    {
        memcpy(words, original, sizeof(words));
        words[mutation[0]] = mutation[1];
        check(!gpu::detail::shader_package_code(package, false).size && !gpu::detail::shader_package_code(package, true).size,
            "both backends reject malformed packages, including damage to the unselected payload");
    }
    printf("Shader package: %u failures\n", failures);
    return failures ? 1 : 0;
}
