import re

# ── Fix 1: Make validateInstallments external in FeeLib ───────────────────────
feelib_path = "contracts/libraries/FeeLib.sol"
with open(feelib_path, "r") as f:
    feelib = f.read()

feelib = feelib.replace(
    "    ) internal pure returns (uint256 count) {",
    "    ) external pure returns (uint256 count) {"
)
assert "external pure returns (uint256 count)" in feelib, "FeeLib change failed"

with open(feelib_path, "w") as f:
    f.write(feelib)
print("FeeLib: validateInstallments is now external.")

# ── Fix 2: Simplify _settleDeal ternaries in DealEscrow ───────────────────────
deal_path = "contracts/core/DealEscrow.sol"
with open(deal_path, "r") as f:
    src = f.read()

old_settle = (
    r'        \([\s\S]*?uint256 protocolAmt,\n'
    r'[\s\S]*?uint256 sellOnAmt,\n'
    r'[\s\S]*?uint256 sellerAgentAmt,\n'
    r'[\s\S]*?uint256 buyerAgentAmt,\n'
    r'[\s\S]*?uint256 sellerAmt\n'
    r'        \) = FeeLib\.computeFees\(\n'
    r'            fee,\n'
    r'            \(protocolFeeBps > 0 && treasury != address\(0\)\) \? protocolFeeBps : 0,\n'
    r'            \(deal\.sellOnBps > 0 && deal\.sellOnRecipient != address\(0\)\) \? deal\.sellOnBps : 0,\n'
    r'            \(deal\.sellerAgentBps > 0 && deal\.sellerAgent != address\(0\)\) \? deal\.sellerAgentBps : 0,\n'
    r'            \(deal\.buyerAgentBps  > 0 && deal\.buyerAgent  != address\(0\)\) \? deal\.buyerAgentBps  : 0\n'
    r'        \);'
)

new_settle = (
    '        uint256 _pBps  = (protocolFeeBps > 0 && treasury != address(0)) ? protocolFeeBps : 0;\n'
    '        uint256 _soBps = (deal.sellOnBps > 0 && deal.sellOnRecipient != address(0)) ? deal.sellOnBps : 0;\n'
    '        uint256 _saBps = (deal.sellerAgentBps > 0 && deal.sellerAgent != address(0)) ? deal.sellerAgentBps : 0;\n'
    '        uint256 _baBps = (deal.buyerAgentBps > 0 && deal.buyerAgent != address(0)) ? deal.buyerAgentBps : 0;\n'
    '        (\n'
    '            uint256 protocolAmt,\n'
    '            uint256 sellOnAmt,\n'
    '            uint256 sellerAgentAmt,\n'
    '            uint256 buyerAgentAmt,\n'
    '            uint256 sellerAmt\n'
    '        ) = FeeLib.computeFees(fee, _pBps, _soBps, _saBps, _baBps);'
)

result = re.sub(old_settle, new_settle, src, flags=re.DOTALL)
assert result != src, "settleDeal pattern not matched"

with open(deal_path, "w") as f:
    f.write(result)
print("DealEscrow: _settleDeal ternaries extracted.")
print("All done.")
