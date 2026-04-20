import { ethers } from "ethers";
import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { config } from "dotenv";

config({ path: '/home/kali/transferium-contracts/.env' });

const RPC_URL  = process.env.ARC_RPC_URL;
const PRIV_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const EURC     = process.env.EURC_ADDRESS;
const USDC     = process.env.USDC_ADDRESS;

const provider = new ethers.JsonRpcProvider(RPC_URL);
const signer   = new ethers.Wallet(PRIV_KEY, provider);

function loadArtifact(name) {
  const path = `artifacts/contracts/core/${name}.sol/${name}.json`;
  const art  = JSON.parse(readFileSync(path, "utf8"));
  return { abi: art.abi, bytecode: art.bytecode };
}

async function deploy(name, args = []) {
  console.log(`Deploying ${name}...`);
  const { abi, bytecode } = loadArtifact(name);
  const factory = new ethers.ContractFactory(abi, bytecode, signer);

  // I encode the deployment transaction manually to bypass eth_estimateGas
  const deployTx = await factory.getDeployTransaction(...args);

  const nonce    = await provider.getTransactionCount(signer.address);
  const feeData  = await provider.getFeeData();
  const network  = await provider.getNetwork();

  const tx = await signer.sendTransaction({
    data:     deployTx.data,
    gasLimit: 10_000_000n,
    gasPrice: feeData.gasPrice,
    nonce:    nonce,
    chainId:  network.chainId,
  });

  console.log(`   Tx sent: ${tx.hash}`);
  const receipt = await tx.wait();
  const address = receipt.contractAddress;
  console.log(`✅ ${name}: ${address}`);

  // I return a contract instance for subsequent calls
  const contract = new ethers.Contract(address, abi, signer);
  return { contract, address };
}

async function sendTx(to, data, description) {
  console.log(`   ${description}...`);
  const nonce   = await provider.getTransactionCount(signer.address);
  const feeData = await provider.getFeeData();
  const network = await provider.getNetwork();

  const tx = await signer.sendTransaction({
    to,
    data,
    gasLimit: 300_000n,
    gasPrice: feeData.gasPrice,
    nonce,
    chainId: network.chainId,
  });
  await tx.wait();
  console.log(`   ✅ ${description}`);
}

async function main() {
  console.log("─────────────────────────────────────────");
  console.log("Transferium Protocol — Deployment v2");
  console.log("─────────────────────────────────────────");
  console.log(`Deployer : ${signer.address}`);
  const network = await provider.getNetwork();
  console.log(`Chain ID : ${network.chainId}`);
  console.log("─────────────────────────────────────────\n");

  const { contract: registry,      address: registryAddress }      = await deploy("PlayerRegistry", [0n, 0n]);
  const { contract: transferWindow, address: transferWindowAddress } = await deploy("TransferWindow", []);
  const { contract: escrow,         address: escrowAddress }         = await deploy("TransferEscrow", [registryAddress, transferWindowAddress]);
  const { contract: loanEscrow,     address: loanEscrowAddress }     = await deploy("LoanEscrow",     [registryAddress, transferWindowAddress]);

  console.log("\nGranting roles...");
  const ESCROW_ROLE = await registry.ESCROW_ROLE();

  const iface = registry.interface;
  await sendTx(registryAddress, iface.encodeFunctionData("grantRole", [ESCROW_ROLE, escrowAddress]),     "ESCROW_ROLE → TransferEscrow");
  await sendTx(registryAddress, iface.encodeFunctionData("grantRole", [ESCROW_ROLE, loanEscrowAddress]), "ESCROW_ROLE → LoanEscrow");

  const escrowIface = escrow.interface;
  if (EURC) {
    console.log("\nWhitelisting EURC...");
    await sendTx(escrowAddress,     escrowIface.encodeFunctionData("approveToken", [EURC]), "EURC → TransferEscrow");
    await sendTx(loanEscrowAddress, escrowIface.encodeFunctionData("approveToken", [EURC]), "EURC → LoanEscrow");
  }

  if (USDC) {
    console.log("\nWhitelisting USDC...");
    await sendTx(escrowAddress,     escrowIface.encodeFunctionData("approveToken", [USDC]), "USDC → TransferEscrow");
    await sendTx(loanEscrowAddress, escrowIface.encodeFunctionData("approveToken", [USDC]), "USDC → LoanEscrow");
  }

  const addresses = {
    network:        "arc",
    chainId:        network.chainId.toString(),
    deployer:       signer.address,
    deployedAt:     new Date().toISOString(),
    PlayerRegistry: registryAddress,
    TransferWindow: transferWindowAddress,
    TransferEscrow: escrowAddress,
    LoanEscrow:     loanEscrowAddress,
    eurcAddress:    EURC ?? "NOT_SET",
    usdcAddress:    USDC ?? "NOT_SET",
  };

  try { mkdirSync("deployments"); } catch {}
  writeFileSync("deployments/addresses.json", JSON.stringify(addresses, null, 2));

  console.log("\n─────────────────────────────────────────");
  console.log("Deployment complete");
  console.log("Addresses written to deployments/addresses.json");
  console.log("─────────────────────────────────────────");
  console.log("\n⚠️  NEXT STEPS:");
  console.log("  1. Grant CLUB_ROLE on all three contracts to club wallets");
  console.log("  2. Grant REGISTRAR_ROLE on PlayerRegistry to league authority");
  console.log("  3. Grant LEAGUE_ROLE on TransferEscrow and LoanEscrow");
  console.log("  4. Schedule transfer window");
}

main().catch(err => { console.error(err); process.exit(1); });
