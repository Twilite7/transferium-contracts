import re

deal_path = "contracts/core/DealEscrow.sol"
with open(deal_path, "r") as f:
    src = f.read()

src = re.sub(r'    error SigningBonusNotExpired\(\);\n', '', src)
src = re.sub(r'    error NoSigningBonusToRescue\(\);\n', '', src)

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
print("Done.")
