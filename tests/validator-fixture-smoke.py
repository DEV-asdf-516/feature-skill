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

    schema = json.loads((ROOT / '.claude/skills/feature/schemas/spec-review.schema.json').read_text())
    issue_props = schema['properties']['blocking_issues']['items']['properties']
    assert 'REUSE_DISCOVERY_GAP' in issue_props['category']['enum']
    for case in sorted(CASES.glob('case-*')):
        exp = json.loads((case / 'expected.json').read_text())
        for issue in exp['issues']:  # expected 라벨은 스키마 enum 안의 값이어야 한다
            for field in ('action', 'category', 'evidence_type', 'origin'):
                for value in [issue[field]] if field in issue else issue.get(field + '_any_of', []):
                    assert value in issue_props[field]['enum'], (case, field, value)
        assert (case / 'input/request.md').is_file(), case
        assert (case / 'input/design.md').is_file(), case
        if exp['stage'] == 'impl':
            assert (case / 'input/implementation.md').is_file(), case
            assert (case / 'input/approach.md').is_file(), case
        for path in case.rglob('*.md'):
            for file, start, end in re.findall(r'((?:src|db)/[\w./-]+|conventions\.md):L(\d+)(?:-L(\d+))?', path.read_text()):
                source = case / file
                assert source.is_file(), (path, file)
                assert 1 <= int(start) <= int(end or start) <= len(source.read_text().splitlines()), (path, file)
        if 'requires_case' in exp:
            control = CASES / exp['requires_case']
            for path in (case / 'input').glob('*.md'):
                assert path.read_bytes() == (control / 'input' / path.name).read_bytes()
            assert (case / 'revised-input').is_dir()
            # Round 2 사례의 고정 Round 1 리뷰는 현재 계약 버전이어야 한다(러너가 schema_version 불일치를 응답 오류로 거부)
            assert json.loads((case / 'prev-review.json').read_text())['schema_version'] == schema['properties']['schema_version']['enum'][0], case
    # v19 교차 검증 사례: BLOCK 넷 + 과잉 BLOCK 대조군(PASS) 둘. 기대 verdict 와 사례가 쓰는 입력(conventions.md·호출부 src)이 실제로 있는지 본다.
    v19 = {
        'case-25-unrequested-product-behavior': 'BLOCK', 'case-26-missed-direct-caller': 'BLOCK',
        'case-27-explicit-convention-conflict': 'BLOCK', 'case-28-competing-structure-false-evidence': 'BLOCK',
        'case-29-equivalent-expression-pass': 'PASS', 'case-30-derived-technical-change-pass': 'PASS',
    }
    for name, verdict in v19.items():
        exp = json.loads((CASES / name / 'expected.json').read_text())
        assert exp['verdict'] == verdict and len(exp['issues']) == (1 if verdict == 'BLOCK' else 0), name
        assert (CASES / name / 'manual-check.txt').is_file(), name
    for name in ('case-27-explicit-convention-conflict', 'case-29-equivalent-expression-pass'):
        assert (CASES / name / 'conventions.md').is_file(), name
    # 27/29, 25/30 은 같은 request·design·src 위의 대조군이어야 한다(차이는 구현 문서뿐)
    for a, b in (('case-27-explicit-convention-conflict', 'case-29-equivalent-expression-pass'),
                 ('case-25-unrequested-product-behavior', 'case-30-derived-technical-change-pass')):
        for rel in ('input/request.md', 'input/design.md'):
            assert (CASES / a / rel).read_bytes() == (CASES / b / rel).read_bytes(), (a, b, rel)
        assert sorted(p.name for p in (CASES / a / 'src').iterdir()) == sorted(p.name for p in (CASES / b / 'src').iterdir()), (a, b)
    harness = (ROOT / 'tests/validator-regression.sh').read_text()
    assert 'cp "$case_dir/conventions.md" "$target/conventions.md"' in harness  # 하니스가 conventions 를 검증자에게 전달
    assert schema['properties']['schema_version']['enum'] == [int(re.search(r'^VALIDATOR_CONTRACT_VERSION=(\d+)', (ROOT / '.claude/skills/feature/config.sh').read_text(), re.M).group(1))]
    for prompt in ('validator-review-impl.md', 'validator-review-design.md'):
        text = (ROOT / '.claude/skills/feature/prompts' / prompt).read_text()
        assert '문서 주장의 교차 검증' in text and '${PROJECT_CONVENTIONS}' in text, prompt
    print('fixture inputs, refs, gate/full and one-to-one matching: OK')


if __name__ == '__main__':
    main()
