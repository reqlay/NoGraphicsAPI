#include <NoGraphicsAPI/NoGraphicsAPI.hpp>
#include <stdio.h>

int main()
{
    using namespace gpu;
    const DeviceInit init = create_device({.timestamp_query_count = 0});
    if (init.error == Error::unsupported) return 77;
    if (!init.device) return 1;
    Device* device = init.device;
    CommandPool* pool = create_command_pool(device);
    TimelinePoint completion{.semaphore = create_timeline_semaphore(device)};
    const GpuHeap readback = create_gpu_heap(device, 512, MemoryType::readback);
    bool valid = true;
    for (uint32 storage = 0; storage < 2; ++storage)
    {
        TextureDesc desc{.extent = {.x = 4, .y = 4, .z = 1}, .format = Format::rgba8_unorm, .srgb_views = true,
            .usage = TextureUsage::sampled | TextureUsage::color_attachment | TextureUsage::transfer_source};
        if (storage) desc.usage = desc.usage | TextureUsage::storage;
        const SizeAlign size = get_texture_size_align(device, desc);
        const TextureHeap heap = create_texture_heap(device, size.size);
        Texture* texture = create_texture(device, desc, heap, 0);
        RenderView* views[] = {create_render_view(texture), create_render_view(texture, {.format = Format::rgba8_srgb})};
        if (!views[0] || !views[1]) { fprintf(stderr, "Could not create the UNORM/sRGB render views.\n"); return 2; }
        CommandBuffer* commands = begin_commands(pool);
        initialize_texture(commands, texture);
        for (uint32 i = 0; i < 2; ++i)
        {
            if (i) barrier(commands, Stage::transfer, Access::transfer_read, Stage::color_output, Access::color_write);
            begin_render_pass(commands, {.colors = {{.render_view = views[i], .load = LoadOp::clear,
                .clear = {.x = 0.5f, .y = 0.5f, .z = 0.5f, .w = 1.0f}}}});
            end_render_pass(commands);
            barrier(commands, Stage::color_output, Access::color_write, Stage::transfer, Access::transfer_read);
            copy_texture_to_memory(commands, texture, {.gpu = readback.range.gpu + i * 256, .size = 64});
        }
        barrier(commands, Stage::transfer, Access::transfer_write, Stage::host, Access::host_read);
        end_commands(commands);
        ++completion.value;
        submit(device, {.commands = {commands}, .completion = completion});
        wait_timeline(completion);
        for (uint32 i = 0; i < 2; ++i)
        {
            const byte* data = readback.range.cpu + i * 256;
            // Vulkan fixed-point conversion permits either adjacent integer (fundamentals, floating-point to normalized fixed-point).
            const uint32 lower = i ? 187 : 127;
            for (uint32 pixel = 0; pixel < 16; ++pixel)
            {
                for (uint32 channel = 0; channel < 3; ++channel)
                    valid = valid && data[pixel * 4 + channel] >= lower && data[pixel * 4 + channel] <= lower + 1;
                valid = valid && data[pixel * 4 + 3] == 255;
            }
            printf("storage=%u view=%s channel=%u expected=%u..%u\n", storage, i ? "sRGB" : "UNORM", data[0], lower, lower + 1);
        }
        reset_command_pool(pool);
        destroy_render_view(views[0]);
        destroy_render_view(views[1]);
        destroy_texture(texture);
        destroy_texture_heap(heap);
    }
    wait_idle(device);
    destroy_gpu_heap(readback);
    destroy_command_pool(pool);
    destroy_timeline_semaphore(completion.semaphore);
    destroy_device(device);
    return valid ? 0 : 3;
}
