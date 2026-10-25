#pragma once

#include <NoGraphicsAPI/NoGraphicsAPI.hpp>

#include "shader_code.hpp"
void read_binary_file(const char* path, gpu::Span<byte> data) noexcept;

double example_time_seconds() noexcept;

void* open_example_window(const char* title, uint32 width, uint32 height) noexcept;
bool pump_example_window(void* window) noexcept;
void close_example_window(void*& window) noexcept;
