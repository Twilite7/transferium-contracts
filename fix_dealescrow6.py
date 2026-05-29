import re

deal_path = "contracts/core/DealEscrow.sol"
with open(deal_path, "r") as f:
    src = f.read()

# Remove 3 dead events
src = re.sub(r'    event MutualCancelExpired\(uint256 indexed dealId\);\n', '', src)
src = re.sub(r'    event SigningBonusRescued\([^)]+\);\n', '', src)
src = re.sub(r'    event TreasuryUpdated\(address indexed newTreasury\);\n', '', src)

# Revert _settleDeal local vars back to inline args (locals cost more with viaIR)
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

assert "MutualCancelExpired" not in src, "MutualCancelExpired still present"
assert "SigningBonusRescued" not in src, "SigningBonusRescued still present"
assert "TreasuryUpdated" not in src, "TreasuryUpdated still present"
assert "_pBps" not in src, "_pBps locals still present"

with open(deal_path, "w") as f:
    f.write(src)
print("Done.")
