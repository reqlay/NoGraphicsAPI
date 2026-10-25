#pragma once
#include <NoGraphicsAPI/NoGraphicsAPI.hpp>
#include <string.h>

namespace gpu::detail
{
inline ByteSpan shader_package_code(ByteSpan package, bool descriptor_buffer) noexcept
{
    if (!package.data || package.size < 16) return {};
    uint32 header[4];
    memcpy(header, package.data, sizeof(header));
    if (header[0] != 0x5341474eu || header[1] != 1 || header[2] < 20 || header[3] < 20 || ((header[2] | header[3]) & 3u)
        || uint64(sizeof(header)) + header[2] + header[3] != package.size) return {};
    uint32 native_magic, buffer_magic;
    memcpy(&native_magic, package.data + sizeof(header), sizeof(native_magic));
    memcpy(&buffer_magic, package.data + sizeof(header) + header[2], sizeof(buffer_magic));
    if (native_magic != 0x07230203u || buffer_magic != 0x07230203u) return {};
    return {package.data + sizeof(header) + (descriptor_buffer ? header[2] : 0), header[descriptor_buffer ? 3 : 2]};
}
}
