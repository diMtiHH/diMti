"""Reject empty, partial, skipped or retried XCTest results from our CI host."""
import json
from pathlib import Path
import re
import sys


EXPECTED = {
    'testnativeiosstorageclockandnotificationcancellationpreserverecovery':
        'UniverseIntegrationTests',
    'testnativeinvalidrecordsandmalformedsettingspreservesavedstate':
        'UniverseIntegrationTests',
    'testiosrunnerloadsthebundledmodelandchecksruanden':
        'UniverseIntegrationTests',
    'bundledmodelisaccessibletotheflutterworker': 'RunnerTests',
}


def test_cases(value):
    if isinstance(value, dict):
        if value.get('nodeType') == 'Test Case':
            yield value
        else:
            for child in value.values():
                yield from test_cases(child)
    elif isinstance(value, list):
        for child in value:
            yield from test_cases(child)


def validate(document):
    cases = list(test_cases(document))
    if len(cases) != len(EXPECTED):
        raise ValueError(f'Expected exactly 4 XCTest cases, found {len(cases)}')
    found = set()
    identifiers = []
    for case in cases:
        identifier = case.get('nodeIdentifier', '')
        method = re.sub(r'[^a-z0-9]', '', identifier.rsplit('/', 1)[-1].lower())
        if method not in EXPECTED or EXPECTED[method] not in identifier.split('/')[:-1]:
            raise ValueError(f'Unexpected test identity: {identifier}')
        if method in found or case.get('result') != 'Passed':
            raise ValueError(f'Duplicate or non-passing test: {identifier}: {case.get("result")}')
        found.add(method)
        identifiers.append(identifier)
    if found != set(EXPECTED):
        raise ValueError('Required XCTest cases are missing')
    return sorted(identifiers)


if __name__ == '__main__':
    passed = validate(json.loads(Path(sys.argv[1]).read_text(encoding='utf-8')))
    print('Verified XCTest results: 3 Flutter integration cases + 1 native resource case passed.')
    for name in passed:
        print(f'PASS {name}')
