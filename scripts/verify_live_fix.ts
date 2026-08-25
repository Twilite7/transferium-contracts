import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  ethers.provider.pollingInterval = 15000;

  const REGISTRY = "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9";

  // Check the actual implementation slot (EIP-1967)
  const implSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bb";
  const implRaw = await ethers.provider.getStorage(REGISTRY, implSlot);
  const implAddr = ethers.getAddress("0x" + implRaw.slice(-40));
  console.log("Current implementation:", implAddr);
  console.log("Expected (our upgrade):  0x2B523Cb1360d1aE23C486d514fF4018703C539B9");
  console.log("Match:", implAddr.toLowerCase() === "0x2B523Cb1360d1aE23C486d514fF4018703C539B9".toLowerCase());

  const registry = await ethers.getContractAt("PlayerRegistry", REGISTRY);

  // Check REGISTRAR_ROLE constant and find who currently holds it, via recent RoleGranted events
  const REGISTRAR_ROLE = await registry.REGISTRAR_ROLE();
  console.log("\nREGISTRAR_ROLE:", REGISTRAR_ROLE);
}

main().catch(console.error);
