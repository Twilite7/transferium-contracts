import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  ethers.provider.pollingInterval = 15000;

  const REGISTRY = "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9";
  const WALLET_SET_BLOCK = 58751625;
  const registry = await ethers.getContractAt("PlayerRegistry", REGISTRY);
  const REGISTRAR_ROLE = await registry.REGISTRAR_ROLE();
  const wallet = "0x14F94f8bf5223C2a8BA90092c0F97dfF834C8Bba";

  // Was this wallet already a registrar AT the block where setPlayerWallet succeeded?
  const hadRoleAtThatBlock = await registry.hasRole(REGISTRAR_ROLE, wallet, { blockTag: WALLET_SET_BLOCK }).catch((e: any) => `error: ${e.message?.slice(0,100)}`);
  console.log(`Held REGISTRAR_ROLE at block ${WALLET_SET_BLOCK} (when setPlayerWallet ran):`, hadRoleAtThatBlock);

  const currentBlock = await ethers.provider.getBlockNumber();
  const grantFilter = registry.filters.RoleGranted(REGISTRAR_ROLE, wallet);
  // Search a window around and after the wallet-set block
  const granted = await registry.queryFilter(grantFilter, WALLET_SET_BLOCK - 100, currentBlock).catch((e: any) => {
    console.log("query failed:", e.message?.slice(0, 100));
    return [];
  });
  console.log(`\nRoleGranted(REGISTRAR_ROLE, wallet) events found: ${granted.length}`);
  for (const g of granted) {
    const block = await ethers.provider.getBlock(g.blockNumber);
    console.log(`  block ${g.blockNumber} (${block ? new Date(Number(block.timestamp)*1000).toISOString() : "?"}), tx ${g.transactionHash}`);
    console.log(`  ${g.blockNumber > WALLET_SET_BLOCK ? "AFTER" : "BEFORE"} the wallet was set (block ${WALLET_SET_BLOCK})`);
  }
}

main().catch(console.error);
