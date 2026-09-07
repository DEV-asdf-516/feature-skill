#!/usr/bin/env python3
"""Paid calls 없이 fixture 입력과 gate/full 일대일 비교를 검증한다."""
import copy
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CASES = ROOT / 'tests/validator-cases'


def compare(result, expected, mode='full'):
    with tempfile.TemporaryDirectory() as tmp:
        paths = [Path(tmp) / name for name in ('result.json', 'expected.json')]
        for path, data in zip(paths, (result, expected)):
            path.write_text(json.dumps(data))
        return subprocess.run(
            ['bash', str(ROOT / 'tests/validator-regression.sh'), 'compare',
             *map(str, paths), mode], capture_output=True
        ).returncode == 0


def main():
    required = {'action': 'REVISE_DOC', 'category': 'REQUIREMENT_CONTRADICTION'}
    security = {'action': 'REVISE_DOC', 'category': 'CHANGE_INTRODUCES_SECURITY_RISK'}
    expected = {'verdict': 'BLOCK', 'issues': [required, security]}
    result = {'verdict': 'BLOCK', 'blocking_issues': [security, required]}
    assert compare(result, expected)  # Order-independent.
    assert not compare(result, {'verdict': 'BLOCK', 'issues': [security, security]})
    wrong = copy.deepcopy(result)
    wrong['blocking_issues'] = [required, required]
    assert compare(wrong, expected, 'gate')
    assert not compare(wrong, expected)
    overlap = {'verdict': 'BLOCK', 'issues': [
        {'action': 'REVISE_DOC'}, security]}
    assert compare(result, overlap)
    assert not compare(wrong, overlap)
    wrong['blocking_issues'][0] = {**required, 'action': 'ASK_USER'}
    assert not compare(wrong, expected, 'gate')
    assert not compare({'verdict': 'PASS', 'blocking_issues': []}, expected, 'gate')
    allowed = {'verdict': 'BLOCK', 'issues': [
        {**required, 'category_any_of': ['REQUIREMENT_CONTRADICTION', 'REQUIREMENT_MISSING']}]}
    del allowed['issues'][0]['category']
    assert compare({'verdict': 'BLOCK', 'blocking_issues': [required]}, allowed)

    for case in sorted(CASES.glob('case-*')):
        exp = json.loads((case / 'expected.json').read_text())
        assert (case / 'input/request.md').is_file(), case
        assert (case / 'input/design.md').is_file(), case
        if exp['stage'] == 'impl':
            assert (case / 'input/implementation.md').is_file(), case
            assert (case / 'input/approach.md').is_file(), case
        for path in case.rglob('*.md'):
            for file, start, end in re.findall(r'(src/[\w./-]+):L(\d+)(?:-L(\d+))?', path.read_text()):
                source = case / file
                assert source.is_file(), (path, file)
                assert 1 <= int(start) <= int(end or start) <= len(source.read_text().splitlines()), (path, file)
        if 'requires_case' in exp:
            control = CASES / exp['requires_case']
            for path in (case / 'input').glob('*.md'):
                assert path.read_bytes() == (control / 'input' / path.name).read_bytes()
            assert (case / 'revised-input').is_dir()
    print('fixture inputs, refs, gate/full and one-to-one matching: OK')


if __name__ == '__main__':
    main()
