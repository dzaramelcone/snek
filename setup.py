"""Build _snek Zig extension via setuptools."""

import platform
import shutil
import subprocess
from pathlib import Path

from setuptools import Extension, setup
from setuptools.command.build_ext import build_ext


class ZigExtension(Extension):
    def __init__(self, name: str):
        super().__init__(name, sources=[])


class ZigBuildExt(build_ext):
    def build_extension(self, ext: Extension) -> None:
        subprocess.check_call(["zig", "build", "pyext", "-Doptimize=ReleaseFast"])

        is_darwin = platform.system() == "Darwin"
        src = Path("zig-out/lib/lib_snek.dylib" if is_darwin else "zig-out/lib/lib_snek.so")
        dst = Path(self.get_ext_fullpath(ext.name))
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)

        if is_darwin:
            subprocess.check_call(["codesign", "-fs", "-", str(dst)])


setup(
    ext_modules=[ZigExtension("snek._snek")],
    cmdclass={"build_ext": ZigBuildExt},
)
