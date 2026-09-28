import { ethers } from "hardhat";

/**
 * Script to mint Genesis Mons for initial launch
 * Run after deployment: npx hardhat run scripts/mint-genesis.ts --network <network>
 */

// Update these addresses after deployment
const MON_NFT_ADDRESS = "YOUR_MON_NFT_ADDRESS";

// Genesis Mon configurations
const GENESIS_MONS = [
  {
    rarity: 3, // Legendary
    monClass: 0, // Assault
    stats: { strength: 85, agility: 70, intelligence: 60, defense: 75, level: 1, experience: 0 },
    abilities: [1, 2, 3], // Inferno Breath, Shadow Strike, Rocket Punch
    name: "Cyber-Draco Alpha",
  },
  {
    rarity: 4, // Mythic
    monClass: 3, // Tank
    stats: { strength: 70, agility: 50, intelligence: 80, defense: 95, level: 1, experience: 0 },
    abilities: [4, 5, 6], // Titan Shield, Firewall, System Overload
    name: "Titan-Guard Prime",
  },
  {
    rarity: 2, // Epic
    monClass: 2, // Scout
    stats: { strength: 55, agility: 95, intelligence: 70, defense: 45, level: 1, experience: 0 },
    abilities: [7, 8], // Stealth Strike, Phase Dash
    name: "Shadow-Runner X",
  },
  {
    rarity: 2, // Epic
    monClass: 1, // Support
    stats: { strength: 40, agility: 60, intelligence: 90, defense: 65, level: 1, experience: 0 },
    abilities: [9, 10, 11], // Heal Beam, Shield Boost, Energy Transfer
    name: "Medi-Core V2",
  },
];

async function main() {
  const [minter] = await ethers.getSigners();
  
  console.log("Minting Genesis Mons with account:", minter.address);
  
  const MonNFT = await ethers.getContractFactory("MonNFT");
  const monNFT = MonNFT.attach(MON_NFT_ADDRESS);
  
  for (let i = 0; i < GENESIS_MONS.length; i++) {
    const mon = GENESIS_MONS[i];
    
    console.log(`\nMinting ${mon.name}...`);
    
    const tx = await monNFT.mintGenesis(
      minter.address,
      mon.rarity,
      mon.monClass,
      mon.stats,
      mon.abilities
    );
    
    const receipt = await tx.wait();
    console.log(`Minted! TX: ${receipt?.hash}`);
    
    // Get the token ID from events
    const events = receipt?.logs || [];
    console.log(`Genesis Mon ${i + 1} minted successfully`);
  }
  
  const totalGenesis = await monNFT.genesisMinted();
  console.log(`\nTotal Genesis Mons minted: ${totalGenesis}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
