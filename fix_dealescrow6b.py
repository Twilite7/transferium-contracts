import re

deal_path = "contracts/core/DealEscrow.sol"
with open(deal_path, "r") as f:
    src = f.read()

# Remove remaining dead events (MutualCancelExpired already removed, skip it)
src = re.sub(r'    event SigningBonusRescued\([^)]+\);\n', '', src)
src = re.sub(r'    event TreasuryUpdated\(address indexed newTreasury\);\n', '', src)

# Revert _settleDeal local vars back to inline args
src = re.sub(
    r'        uint256 _pBps  = \(protocolFeeBps > 0 && treasury != address\(0\)\) \? protocolFeeBps : 0;\n'
    r'        uint256 _soBps = \(deal\.sellOnBps > 0 && deal\.sellOnRecipient != address\(0\)\) \? deal\.sellOnBps : 0;\n'
    r'        uint256 _saBps = \(deal\.sellerAgentBps > 0 && deal\.sellerAgent != address\(0\)\) \? deal\.sellerAgentBps : 0;\n'
    r'        uint256 _baBps = \(deal\.buyerAgentBps > 0 && deal\.buyerAgent != address\(0\)\) \? deal\.buyerAgentBps : 0;\n'
    r'        \(\n'
    r'            uint256 protocolAmt,\n'
    r'            uint256 sellOnAmt,\n'
    r'            uint256 sellerAgentAmt,\n'
    r'            uint256 buyerAgentAmt,\n'
    r'            uint256 sellerAmt\n'
    r'        \) = FeeLib\.computeFees\(fee, _pBps, _soBps, _saBps, _baBps\);',
    '        (\n'
    '            uint256 protocolAmt,\n'
    '            uint256 sellOnAmt,\n'
    '            uint256 sellerAgentAmt,\n'
    '            uint256 buyerAgentAmt,\n'
    '            uint256 sellerAmt\n'
    '        ) = FeeLib.computeFees(\n'
    '            fee,\n'
    '            (protocolFeeBps > 0 && treasury != address(0)) ? protocolFeeBps : 0,\n'
    '            (deal.sellOnBps > 0 && deal.sellOnRecipient != address(0)) ? deal.sellOnBps : 0,\n'
    '            (deal.sellerAgentBps > 0 && deal.sellerAgent != address(0)) ? deal.sellerAgentBps : 0,\n'
    '            (deal.buyerAgentBps  > 0 && deal.buyerAgent  != address(0)) ? deal.buyerAgentBps  : 0\n'
    '        );',
    src
)

assert "SigningBonusRescued" not in src, "SigningBonusRescued still present"
assert "TreasuryUpdated" not in src, "TreasuryUpdated still present"
assert "_pBps" not in src, "_pBps locals still present"
# Check event gone but error still present
assert "event MutualCancelExpired" not in src, "event MutualCancelExpired still present"
assert "error MutualCancelExpiredError" in src, "error MutualCancelExpiredError was wrongly removed"

with open(deal_path, "w") as f:
    f.write(src)
print("Done.")
