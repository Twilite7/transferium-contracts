import re

# ── Fix 1: Simplify parameterised errors in ProtocolFeeBase ───────────────────
base_path = "contracts/base/ProtocolFeeBase.sol"
with open(base_path, "r") as f:
    base = f.read()

base = base.replace(
    "    error ProtocolFeeTooHigh(uint256 provided, uint256 max);",
    "    error ProtocolFeeTooHigh();"
)
base = base.replace(
    "    error TreasuryUpdateNotReady(uint256 effectiveAt, uint256 now_);",
    "    error TreasuryUpdateNotReady();"
)
base = base.replace(
    "        if (bps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeTooHigh(bps, MAX_PROTOCOL_FEE_BPS);",
    "        if (bps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeTooHigh();"
)
base = base.replace(
    "            revert TreasuryUpdateNotReady(_pendingTreasuryEffectiveAt, block.timestamp);",
    "            revert TreasuryUpdateNotReady();"
)

assert "uint256 provided" not in base, "ProtocolFeeTooHigh still has params"
assert "uint256 effectiveAt" not in base, "TreasuryUpdateNotReady still has params"

with open(base_path, "w") as f:
    f.write(base)
print("ProtocolFeeBase: errors simplified.")

# ── Fix 2: Remove rescueSigningBonus from DealEscrow ─────────────────────────
deal_path = "contracts/core/DealEscrow.sol"
with open(deal_path, "r") as f:
    src = f.read()

# Remove the error declarations
src = re.sub(r'    error SigningBonusNotExpired\(\);\n', '', src)
src = re.sub(r'    error NoSigningBonusToRescue\(\);\n', '', src)

# Remove the function
src = re.sub(
    r'\n    // ── Signing bonus rescue \(league\).*?emit SigningBonusRescued\(dealId, recipient, deal\.signingBonusAmount\);\n    \}\n',
    '\n',
    src,
    flags=re.DOTALL
)

assert "rescueSigningBonus" not in src, "rescueSigningBonus still present"
assert "NoSigningBonusToRescue" not in src, "error still present"

with open(deal_path, "w") as f:
    f.write(src)
print("DealEscrow: rescueSigningBonus removed.")
print("All done.")
