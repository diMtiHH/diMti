import copy
import unittest

from check_xctest_result import EXPECTED, validate


class XCTestResultContract(unittest.TestCase):
    def setUp(self):
        self.cases = [
            {'nodeType': 'Test Case', 'nodeIdentifier': f'{owner}/{name}()', 'result': 'Passed'}
            for name, owner in EXPECTED.items()
        ]

    def report(self, cases=None):
        return {'testNodes': [{'nodeType': 'Test Suite', 'children': self.cases if cases is None else cases}]}

    def test_all_required_cases(self):
        self.assertEqual(len(validate(self.report())), 8)

    def test_empty_report_cannot_pass(self):
        with self.assertRaises(ValueError):
            validate(self.report([]))

    def test_missing_case_cannot_pass(self):
        with self.assertRaises(ValueError):
            validate(self.report(self.cases[:-1]))

    def test_skipped_case_cannot_pass(self):
        self.cases[0]['result'] = 'Skipped'
        with self.assertRaises(ValueError):
            validate(self.report())

    def test_failed_case_cannot_pass(self):
        self.cases[0]['result'] = 'Failed'
        with self.assertRaises(ValueError):
            validate(self.report())

    def test_retry_cannot_disguise_failure(self):
        failed = copy.deepcopy(self.cases[0])
        failed['result'] = 'Failed'
        with self.assertRaises(ValueError):
            validate(self.report([failed, *self.cases]))

    def test_duplicate_cannot_replace_missing_case(self):
        self.cases[0] = copy.deepcopy(self.cases[1])
        with self.assertRaises(ValueError):
            validate(self.report())

    def test_same_name_from_wrong_suite_cannot_pass(self):
        self.cases[0]['nodeIdentifier'] = self.cases[0]['nodeIdentifier'].replace('UniverseIntegrationTests', 'UnrelatedTests')
        with self.assertRaises(ValueError):
            validate(self.report())


if __name__ == '__main__':
    unittest.main()
