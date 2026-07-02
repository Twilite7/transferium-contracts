import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const PROXY = "0x1bA3D6557dA3A6a861b2D27596c3c22A75c6c535";

  // _bidders is mapping(uint256 => address[]) 
  // Find its storage slot by checking the contract layout
  const escrow = await ethers.getContractAt("TransferEscrow", PROXY);

  // Get the storage slot of _bidders mapping for offerId=1
  // Slot of mapping value = keccak256(key . mapping_slot)
  // We need to find the mapping slot first — check a few candidates
  for (let slot = 0; slot < 20; slot++) {
    const mappingSlot = ethers.solidityPackedKeccak256(
      ["uint256", "uint256"],
      [1, slot]
    );
    // This gives the slot of the array itself; slot+0 = length
    const lengthHex = await ethers.provider.getStorage(PROXY, mappingSlot);
    const length = parseInt(lengthHex, 16);
    if (length > 0 && length < 100) {
      console.log(`Slot ${slot}: _bidders[1].length = ${length}`);
      // Read first element
      const arrayDataSlot = ethers.solidityPackedKeccak256(["bytes32"], [mappingSlot]);
      const first = await ethers.provider.getStorage(PROXY, arrayDataSlot);
      console.log(`  _bidders[1][0] = 0x${first.slice(26)}`);
    }
  }

  // Also check _bidCount directly
  for (let slot = 0; slot < 20; slot++) {
    const mappingSlot = ethers.solidityPackedKeccak256(
      ["uint256", "uint256"],
      [1, slot]
    );
    const val = await ethers.provider.getStorage(PROXY, mappingSlot);
    if (val !== "0x0000000000000000000000000000000000000000000000000000000000000000" && 
        parseInt(val, 16) < 1000) {
      console.log(`Non-zero at mapping slot ${slot}: ${parseInt(val, 16)}`);
    }
  }
}

main().catch(console.error);
