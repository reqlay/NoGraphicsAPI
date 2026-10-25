"""Exercise the public compiler with real Slang, including a failed second variant."""

from pathlib import Path
import subprocess
import sys
import tempfile

repository = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(repository / 'tools'))
from compile_shader import unpack_shader


def main():
    slang, validator, directory = sys.argv[1:]
    Path(directory).mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=directory, prefix='shader package ') as temporary:
        root = Path(temporary)
        source, output, dependency = root / 'shader.slang', root / 'shader.shader', root / 'shader.d'
        source.write_text((repository / 'tests/root_data.slang').read_text())
        (root / 'root_data_shared.h').write_text((repository / 'tests/root_data_shared.h').read_text())
        command = [sys.executable, str(repository / 'tools/compile_shader.py'), str(source), '-o', str(output),
                   '--entry', 'computeMain', '--stage', 'compute', '--slang', slang, '--spirv-val', validator,
                   '--depfile', str(dependency), '--', '-I' + str(repository / 'include'), '-I' + str(repository / 'utility/include')]
        subprocess.run(command, check=True)
        package = output.read_bytes()
        native, buffer = unpack_shader(package)
        assert native != buffer, 'The package must contain the two distinct binding ABIs'
        assert 'root_data_shared.h' in dependency.read_text(), 'Shared includes must participate in incremental builds'
        for name, code in (('native', native), ('buffer', buffer)):
            binary = root / (name + '.spv')
            binary.write_bytes(code)
            subprocess.run([validator, '--target-env', 'vulkan1.4', '--scalar-block-layout', str(binary)], check=True)
        subprocess.run(command, check=True)
        assert output.read_bytes() == package, 'Identical inputs produce identical packages'
        timestamp = output.stat().st_mtime_ns
        source.write_text(source.read_text() + '\n#ifdef NOGRAPHICSAPI_DESCRIPTOR_BUFFER\n#error Failed second variant\n#endif\n')
        failed = subprocess.run(command, capture_output=True, text=True)
        assert failed.returncode and 'Failed second variant' in failed.stderr, failed.stdout + failed.stderr
        assert output.read_bytes() == package and output.stat().st_mtime_ns == timestamp, 'A failed variant must not replace the package'
        print('Public shader compiler: validated both variants, tracked includes, stable output, atomic failure')


if __name__ == '__main__':
    main()
