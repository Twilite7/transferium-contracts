import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const PROXY = "0xFA8dCb6f0DB181DD9400888a1e0874Ebba94D7bA";

  // Try OpenZeppelin UUPS slots (both v4 and v5 layout)
  const slots = [
    // EIP-1967 logic slot
    "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc",
    // OZ v4 UUPS implementation slot (keccak256("eip1967.proxy.implementation") - 1)
    "0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3",
    // Slot 0 — in case it's a minimal proxy storing impl at slot 0
    "0x0000000000000000000000000000000000000000000000000000000000000000",
  ];

  for (const slot of slots) {
    const val = await ethers.provider.getStorage(PROXY, slot);
    console.log(`slot ${slot.slice(0,10)}...: ${val}`);
  }

  // Check if upgradeToAndCall exists with a static call providing more detail
  const [deployer] = await ethers.getSigners();
  const NEW_IMPL = "0x4f465F051602d68bfa756d14E7Ab9d2C7b085091";
  
  try {
    const iface = new ethers.Interface([
      "function upgradeToAndCall(address,bytes) external",
    ]);
    const data = iface.encodeFunctionData("upgradeToAndCall", [NEW_IMPL, "0x"]);
    const result = await ethers.provider.call({ to: PROXY, data, from: deployer.address });
    console.log("upgradeToAndCall static result:", result);
  } catch (e: any) {
    // Try to decode the revert
    const msg = e?.info?.error?.message ?? e?.message ?? "";
    console.log("upgradeToAndCall revert:", msg.slice(0, 300));
    if (e?.data) console.log("revert data:", e.data);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
