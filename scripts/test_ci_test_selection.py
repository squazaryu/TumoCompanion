"""Prevent Xcode's specific selectors from narrowing the complete unit target."""
from pathlib import Path
import re

text = (Path(__file__).resolve().parents[1] / '.github/workflows/ios-build.yml').read_text()
commands = re.findall(r'xcodebuild test.*?CODE_SIGNING_REQUIRED=NO', text, re.S)
selections = [set(re.findall(r'-only-testing:([^\s\\]+)', command)) for command in commands]
unit = [values for values in selections if 'UnleashedTests' in values]
assert len(unit) == 1 and unit[0] == {'UnleashedTests'}, (
    'Complete unit target must run alone, without narrowing class or UI selectors', selections)
ui = [values for values in selections if any(value.startswith('UnleashedUITests/') for value in values)]
assert len(ui) == 1 and not any(value.startswith('UnleashedTests') for value in ui[0])
assert {'UnleashedUITests/CommunityCleanupUITests', 'UnleashedUITests/FieldReportsUITests',
        'UnleashedUITests/FieldWorkflowsUITests',
        'UnleashedUITests/ConnectionStatusUITests'} <= ui[0]
assert 'name: Test complete unit target\n' in text
assert 'name: Test critical package channel and field UI\n' in text
print('Complete unit target and critical UI use independent Xcode invocations')
