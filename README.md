# Transferium Protocol

After building Zeno Estate — an RWA project on Arc — I started thinking about what else Arc's financial infrastructure could handle. Club-to-club football transfers involve escrow, legal documents, multi-party payments, installments, agent fees, sell-on clauses. It's one of the most complex financial transactions in sports and it's still done mostly off-chain with lawyers and wire transfers.

So I built Transferium. It's a proof of concept that Arc can handle something this complex. Right now it's scoped to football but the architecture is open to any sport where clubs transfer player registrations.

## What It Does

Clubs register players as NFTs. Before a player can be listed for transfer, a league registrar must verify their identity, medical clearance, and legal documents on-chain. Every document hash is unique — you can't reuse a medical report across players. Every player gets their own wallet for receiving sell-on fees and performance bonuses directly, no club middleman.

Transfers go through an escrow contract that handles the full deal structure — transfer fee, agent cut, sell-on clause, performance add-ons, salary guarantee. Loans have their own escrow with recall mechanics and option-to-buy. The transfer window is enforced at contract level — no transfers outside the window, period.

## Deployed on Arc Testnet (Chain ID 5042002)

| Contract | Address |
|---|---|
| PlayerRegistry | `0xdDa83cf2ADECD861Cc6aa947E167E29906BB77Ef` |
| TransferWindow | `0xcEDd544E087a670CcD4bBe0437F80BB6C8f837a4` |
| TransferEscrow | `0xa92C0648d97455D11713487FE6a1B784f74cB94A` |
| LoanEscrow | `0x2a0F089674ff1Eb1C035C19d61d4bfCc0360e9fC` |

Deployer: `0x13E569C96c7F884443d0c3Ac5019D020dE32bFb3`

## Contracts

**PlayerRegistry** — ERC-721. Each player is an NFT owned by their club. Handles registration, verification, medical clearance, legal docs, player wallet assignment, listing and delisting. Document hashes and player wallets are globally unique across the registry.

**TransferEscrow** — Permanent transfers. Supports transfer fee, agent fee, sell-on clause, performance add-ons, salary guarantee, and a dispute window before funds release.

**LoanEscrow** — Loans. Handles loan fees, recall with notice period, option to buy, and automatic settlement on expiry.

**TransferWindow** — League authority schedules open and close dates. Transfers outside the window are rejected at contract level.

## Security

- Role-based access: CLUB_ROLE, REGISTRAR_ROLE, ESCROW_ROLE, LEAGUE_ROLE
- Document hash uniqueness enforced globally
- Player wallet uniqueness enforced globally  
- Reentrancy protection on all state-changing functions
- Pausable for emergencies
- 33 tests passing

## Stack

Solidity 0.8.28, Hardhat, OpenZeppelin, Arc Testnet, EURC + USDC

## Run Tests

```bash
npx hardhat test
```

## Deploy

```bash
npx hardhat run scripts/deploy.ts --network arc
npx hardhat run scripts/setup-test-roles.ts --network arc
npx hardhat run scripts/open-test-window.ts --network arc
```

Frontend: [github.com/Twilite7/transferium-frontend](https://github.com/Twilite7/transferium-frontend)

---

Security over speed. Always.
