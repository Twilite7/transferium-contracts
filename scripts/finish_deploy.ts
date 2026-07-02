import { network } from "hardhat";
import * as fs from "fs";

const addresses = {
  chainId:             "5042002",
  deployer:            "0x13E569C96c7F884443d0c3Ac5019D020dE32bFb3",
  deployedAt:          new Date().toISOString(),
  AddressRegistry:     "0x69Ac5c37047e80AdD1905A1f8035f34aD6E0B063",
  PlayerRegistry:      "0x218b8d89627Ee2bBf56e3Da1717F908f0E07A27e",
  TransferWindow:      "0x626A7649441fe21bf8298A1Bf153FC299AF98884",
  FeeLib:              "0x233E017FFC5B3538E7BC2ff385e5af418eaDf1d7",
  TransferEscrow:      "0x4DC7369f7fAEb69ccE048e4D3b59BB8244865cCB",
  DealEscrow:          "0xe57fFA169A62A3260932cC9Cc26e684766121aF3",
  LoanEscrow:          "0xC1727db63042dB62C2731cB405E839AdC179F05F",
  ReleaseEscrow:       "0x9DFE784c513B1b214dd30137d12B11cfd52E4cCB",
  SwapEscrow:          "0xfE57734B3Ecee995Ea79b3855941B91da175800B",
  FreeTransferEscrow:  "0xe3d4CE8d057BF6e92606b5fdd504f335691b66D5",
  InstallmentEscrow:   "0x97856D1c99d981A95f737457AAc9d5006DA66EFB",
  VerificationManager: "0x13B797D6d782F000594145144Ad7d26747F1DFcf",
  TerminationManager:  "0xe09D0dD466FF3519968b8e537C88881D661f7d68",
  eurcAddress:         "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a",
  usdcAddress:         "0x3600000000000000000000000000000000000000",
};

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  const EURC = addresses.eurcAddress;
  const USDC = addresses.usdcAddress;

  // Wire TerminationManager
  const pr = await ethers.getContractAt("PlayerRegistry", addresses.PlayerRegistry, deployer);
  try {
    await (await pr.setTerminationManager(addresses.TerminationManager)).wait();
    console.log("✅ TerminationManager set");
  } catch (e: any) { console.log("TerminationManager:", e.message?.slice(0, 60)); }

  // Verify baseVerificationFee
  const baseFee = await pr.baseVerificationFee();
  console.log("✅ baseVerificationFee:", baseFee.toString(), "(should be 2000000)");

  // Approve tokens on escrow contracts
  for (const [name, addr] of [
    ["TransferEscrow",     addresses.TransferEscrow],
    ["DealEscrow",         addresses.DealEscrow],
    ["LoanEscrow",         addresses.LoanEscrow],
    ["ReleaseEscrow",      addresses.ReleaseEscrow],
    ["SwapEscrow",         addresses.SwapEscrow],
    ["FreeTransferEscrow", addresses.FreeTransferEscrow],
  ] as const) {
    const c = await ethers.getContractAt(name, addr, deployer);
    try { await (await c.approveToken(EURC)).wait(); console.log(`  EURC → ${name}`); } catch {}
    try { await (await c.approveToken(USDC)).wait(); console.log(`  USDC → ${name}`); } catch {}
  }

  // Write addresses.json
  fs.mkdirSync("/home/kali/transferium-contracts/deployments", { recursive: true });
  fs.writeFileSync(
    "/home/kali/transferium-contracts/deployments/addresses.json",
    JSON.stringify(addresses, null, 2)
  );
  console.log("\n✅ addresses.json written");

  console.log("\n=== Copy into frontend contracts.ts ===");
  for (const [k, v] of Object.entries(addresses)) {
    if (!["chainId","deployer","deployedAt","FeeLib"].includes(k))
      console.log(`  ${k.padEnd(20)}: '${v}',`);
  }
}

main().catch(console.error);
