import re

# ── Step 1: Add validateInstallments to FeeLib ────────────────────────────────
feelib_path = "contracts/libraries/FeeLib.sol"
with open(feelib_path, "r") as f:
    feelib = f.read()

new_fn = '''
    /// @dev Validates installment schedule and returns the count.
    function validateInstallments(
        uint256[] calldata amounts,
        uint256[] calldata dueDates,
        uint256 transferFee
    ) internal pure returns (uint256 count) {
        count = amounts.length;
        if (count == 0 || count > 8) revert InvalidInstallmentSchedule();
        if (dueDates.length != count) revert InvalidInstallmentSchedule();
        uint256 sum = 0;
        for (uint256 i = 0; i < count; i++) {
            if (amounts[i] == 0) revert InvalidInstallmentSchedule();
            if (i > 0 && dueDates[i] <= dueDates[i - 1]) revert InvalidInstallmentSchedule();
            sum += amounts[i];
        }
        if (sum != transferFee) revert InvalidInstallmentSchedule();
    }
'''

feelib = re.sub(
    r'(library FeeLib \{)',
    r'\1\n    error InvalidInstallmentSchedule();',
    feelib
)
feelib = feelib.rstrip()
assert feelib.endswith('}'), "FeeLib doesn't end with }"
feelib = feelib[:-1] + new_fn + '}\n'

with open(feelib_path, "w") as f:
    f.write(feelib)

print("FeeLib updated.")

# ── Step 2: Update DealEscrow ─────────────────────────────────────────────────
deal_path = "contracts/core/DealEscrow.sol"
with open(deal_path, "r") as f:
    src = f.read()

# Remove the error declaration now in FeeLib
src = re.sub(r'    error InvalidInstallmentSchedule\(\);\n', '', src)

# Replace inline validation with library call
old_validation = (
    r'        // I validate installment schedule before storing\n'
    r'        uint256 instCount = p\.installmentAmounts\.length;\n'
    r'        if \(instCount == 0 \|\| instCount > 8\) revert InvalidInstallmentSchedule\(\);\n'
    r'        if \(p\.installmentDueDates\.length != instCount\) revert InvalidInstallmentSchedule\(\);\n'
    r'        uint256 instSum = 0;\n'
    r'        for \(uint256 i = 0; i < instCount; i\+\+\) \{\n'
    r'            if \(p\.installmentAmounts\[i\] == 0\) revert InvalidInstallmentSchedule\(\);\n'
    r'            if \(i > 0 && p\.installmentDueDates\[i\] <= p\.installmentDueDates\[i-1\]\) revert InvalidInstallmentSchedule\(\);\n'
    r'            instSum \+= p\.installmentAmounts\[i\];\n'
    r'        \}\n'
    r'        if \(instSum != p\.transferFee\) revert InvalidInstallmentSchedule\(\);\n'
)

new_validation = (
    '        uint256 instCount = FeeLib.validateInstallments(\n'
    '            p.installmentAmounts, p.installmentDueDates, p.transferFee\n'
    '        );\n'
)

result = re.sub(old_validation, new_validation, src)
assert result != src, "Validation block not found — pattern mismatch"

with open(deal_path, "w") as f:
    f.write(result)

print("DealEscrow updated.")
print("All done.")
