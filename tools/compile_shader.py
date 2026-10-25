#!/usr/bin/env python3
"""Compile one Slang entry point into a NoGraphicsAPI Vulkan shader package."""

import argparse
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


HEADER = struct.Struct('<4I')
MAGIC = 0x5341474E  # NGAS
VERSION = 1
SPIRV_MAGIC = 0x07230203


def unpack_shader(data):
    if len(data) < HEADER.size:
        raise ValueError('Truncated NoGraphicsAPI shader package')
    magic, version, native_size, buffer_size = HEADER.unpack_from(data)
    if magic != MAGIC or version != VERSION:
        raise ValueError('Unsupported NoGraphicsAPI shader package')
    if native_size < 20 or buffer_size < 20 or (native_size | buffer_size) & 3:
        raise ValueError('Invalid NoGraphicsAPI shader sizes')
    if HEADER.size + native_size + buffer_size != len(data):
        raise ValueError('Invalid NoGraphicsAPI shader package length')
    native = data[HEADER.size:HEADER.size + native_size]
    fallback = data[HEADER.size + native_size:]
    if any(struct.unpack_from('<I', code)[0] != SPIRV_MAGIC for code in (native, fallback)):
        raise ValueError('Invalid SPIR-V in NoGraphicsAPI shader package')
    return native, fallback


def pack_shader(native, fallback):
    package = HEADER.pack(MAGIC, VERSION, len(native), len(fallback)) + native + fallback
    unpack_shader(package)
    return package


def run(command):
    # Compiler tools must not change the console code page used by MSBuild's command scripts.
    result = subprocess.run([str(arg) for arg in command], capture_output=True, text=True, encoding='utf-8', errors='replace',
                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)


def publish(data, path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(data)
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def compile_shader(source, output, entry, stage, *, slang='slangc', spirv_val='spirv-val', spirv_opt='spirv-opt',
                   options=(), opt_config=None, debug_level=0, depfile=None):
    source, output = Path(source).resolve(), Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.shader-', dir=output.parent) as directory:
        scratch = Path(directory)
        command = [slang, source, '-entry', entry, '-stage', stage, '-target', 'spirv',
                   '-fvk-use-c-layout', '-matrix-layout-row-major', '-O3', *options,
                   '-emit-spirv-directly', '-fvk-use-entrypoint-name']
        if '-profile' not in options:
            command += ['-profile', 'spirv_1_5']
        if stage in ('mesh', 'amplification') and 'spvMeshShadingEXT' not in options:
            command += ['-capability', 'spvMeshShadingEXT']
        passes = []
        if opt_config:
            passes = [line.strip() for line in Path(opt_config).read_text(encoding='utf-8').splitlines()
                      if line.startswith('--') and not (debug_level and line.startswith('--strip-'))]
        binaries, dependencies = [], []
        for name, flags in (('native', ['-capability', 'spvDescriptorHeapEXT']),
                            ('buffer', ['-DNOGRAPHICSAPI_DESCRIPTOR_BUFFER'])):
            binary, dependency = scratch / f'{name}.spv', scratch / f'{name}.d'
            run(command + flags + [f'-g{debug_level}', '-depfile', dependency, '-o', binary])
            if passes:
                optimized = scratch / 'optimized.spv'
                run([spirv_opt, '--target-env=vulkan1.4', '--scalar-block-layout', *passes, binary, '-o', optimized])
                os.replace(optimized, binary)
            run([spirv_val, '--target-env', 'vulkan1.4', '--scalar-block-layout', binary])
            binaries.append(binary.read_bytes())
            dependencies.append(dependency.read_text(encoding='utf-8').split(': ', 1)[1].strip())
        if depfile:
            escaped = output.as_posix().replace('$', '$$').replace('#', r'\#').replace(' ', r'\ ').replace(':', r'\:')
            publish((escaped + ': ' + ' '.join(dependencies) + '\n').encode(), depfile)
        publish(pack_shader(*binaries), output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('-o', '--output', required=True)
    parser.add_argument('--entry', required=True)
    parser.add_argument('--stage', required=True)
    parser.add_argument('--slang', default='slangc')
    parser.add_argument('--spirv-val', default='spirv-val')
    parser.add_argument('--spirv-opt', default='spirv-opt')
    parser.add_argument('--opt-config')
    parser.add_argument('--debug-level', type=int, choices=(0, 1, 2), default=0)
    parser.add_argument('--depfile')
    arguments, options = parser.parse_known_args()
    if options[:1] == ['--']:
        options = options[1:]
    compile_shader(**vars(arguments), options=options)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
