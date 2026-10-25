"""Test the installed public helper, including dependency tracking and GPU execution."""

from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    cmake, api_build, configuration, generator, platform, slang, validator = sys.argv[1:]
    repository = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='shader consumer \u00e4 ', dir=api_build) as temporary:
        root = Path(temporary)
        source, build, prefix = root / 'source', root / 'build', root / 'installed'
        source.mkdir()

        def run(command):
            result = subprocess.run(list(map(str, command)), capture_output=True, text=True, encoding='utf-8', errors='replace')
            if result.returncode == 77:
                sys.exit(77)
            if result.returncode or 'NoGraphicsAPI validation:' in result.stderr:
                raise RuntimeError(result.stdout + result.stderr)
            return result.stdout

        run([cmake, '--install', api_build, '--config', configuration, '--prefix', prefix])
        for name in ('root_data_test.cpp', 'root_data.slang', 'root_data_shared.h', 'root_data_generate.slang', 'root_data_generate_shared.h'):
            (source / name).write_text((repository / 'tests' / name).read_text())
        (source / 'shader_code.h').write_text((repository / 'examples/common/shader_code.hpp').read_text())
        shared = source / 'root_data_shared.h'
        shared.write_text(shared.read_text() + '\n#define TEST_ADDEND 0\n')
        for name, old, new in (('root_data.slang', 'root.seed + lane;', 'root.seed + lane + TEST_ADDEND;'),
                               ('root_data_test.cpp', 'uint32 expected = seed + lane;', 'uint32 expected = seed + lane + TEST_ADDEND;')):
            path = source / name
            path.write_text(path.read_text().replace(old, new))
        (source / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.24)
project(InstalledConsumer LANGUAGES CXX)
find_package(NoGraphicsAPI CONFIG REQUIRED)
find_package(NoGraphicsAPIUtility CONFIG REQUIRED)
set(consume "${CMAKE_CURRENT_BINARY_DIR}/consume.${NOGRAPHICSAPI_SHADER_EXTENSION}")
set(generate "${CMAKE_CURRENT_BINARY_DIR}/generate.${NOGRAPHICSAPI_SHADER_EXTENSION}")
NoGraphicsAPI_compile_slang("${consume}" root_data.slang computeMain compute)
NoGraphicsAPI_compile_slang("${generate}" root_data_generate.slang computeMain compute)
add_executable(consumer root_data_test.cpp "${consume}" "${generate}")
target_link_libraries(consumer PRIVATE NoGraphicsAPI::NoGraphicsAPI NoGraphicsAPIUtility::allocators)
if(MSVC)
    target_compile_options(consumer PRIVATE /EHs-c- /GR-)
else()
    target_compile_options(consumer PRIVATE -fno-exceptions -fno-rtti)
endif()
target_compile_definitions(consumer PRIVATE NOGRAPHICSAPI_ROOT_DATA_PATH="${consume}" NOGRAPHICSAPI_ROOT_GENERATE_PATH="${generate}")
file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/program-$<CONFIG>.txt" CONTENT "$<TARGET_FILE:consumer>")
''')
        run([cmake, '-S', source, '-B', build, '-G', generator, *(['-A', platform] if platform else []),
             f'-DCMAKE_BUILD_TYPE={configuration}', f'-DCMAKE_PREFIX_PATH={prefix}',
             f'-DNOGRAPHICSAPI_SLANGC={slang}', f'-DNOGRAPHICSAPI_SPIRV_VAL={validator}'])
        build_command = [cmake, '--build', build, '--config', configuration, '--parallel', '4']
        run(build_command)
        executable = (build / f'program-{configuration}.txt').read_text(encoding='utf-8')
        run([executable])
        package = build / 'consume.shader'
        before = package.read_bytes()
        assert 'Compiling and validating' not in run(build_command), 'Unchanged builds must skip shader compilation'
        shared.write_text(shared.read_text().replace('TEST_ADDEND 0', 'TEST_ADDEND 3'))
        assert 'Compiling and validating' in run(build_command), 'Included header changes must compile shaders'
        assert package.read_bytes() != before, 'The included constant must change the shader package'
        run([executable])
        assert 'Compiling and validating' not in run(build_command), 'The next unchanged build must skip shader compilation'
        # An edit that changes no generated code must also settle after one rebuild.
        shared.write_text(shared.read_text() + '\n// Dependency tracking check.\n')
        assert 'Compiling and validating' in run(build_command)
        assert 'Compiling and validating' not in run(build_command)
        print('Installed shader helper: GPU results, included headers, and no-op builds passed')


if __name__ == '__main__':
    main()
