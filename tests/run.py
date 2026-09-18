#!/usr/bin/env python3
"""Run mock bridge tests and compile the production bridge; never launch WeType."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import version_profile


def main():
    profile = json.loads((ROOT / 'profiles/wetype-2.2.3-657.json').read_text())
    version_profile.check_review(profile, profile)
    generated = version_profile.header(profile)
    for macro in ('WT_SESSION_GETTER_ADDRESS', 'WT_SESSION_ID_GETTER_ADDRESS', 'WT_MODE_TIPS_ADDRESS'):
        assert f'#define {macro} ' in generated
    stale = copy.deepcopy(profile)
    del stale['symbols']['mode_tips']
    try:
        version_profile.check_review(stale, stale)
    except ValueError:
        pass
    else:
        raise AssertionError('Profile without the reviewed mode-tip ABI was accepted')

    with tempfile.TemporaryDirectory(prefix='wetype-mode-tips-') as directory:
        work = Path(directory)
        (work / 'state-profile.h').write_text(generated)
        compiler = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-O2', '-Wall', '-Wextra', '-Werror',
                    '-arch', 'arm64', '-mmacosx-version-min=11.0']
        frameworks = ['-framework', 'Cocoa', '-framework', 'Carbon']
        subprocess.run([*compiler, str(ROOT / 'tests/bridge-mode-tips.m'), *frameworks,
                        '-o', str(work / 'test')], check=True)
        subprocess.run([str(work / 'test')], check=True)
        subprocess.run([*compiler, '-I', directory, '-dynamiclib', str(ROOT / 'src/bridge.m'),
                        str(ROOT / 'src/state.m'), *frameworks, '-o', str(work / 'bridge.dylib')], check=True)
    print('profile checks and production bridge compile passed')


if __name__ == '__main__':
    main()
