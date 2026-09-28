import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());
  
  // ============ Deploy FROZ Token ============
  console.log("\n--- Deploying FROZ Token ---");
  const FROZToken = await ethers.getContractFactory("FROZToken");
  const frozToken = await FROZToken.deploy(
    deployer.address, // treasury
    deployer.address  // admin
  );
  await frozToken.waitForDeployment();
  const frozAddress = await frozToken.getAddress();
  console.log("FROZ Token deployed to:", frozAddress);
  
  // ============ Deploy Mon NFT ============
  console.log("\n--- Deploying Mon NFT ---");
  const MonNFT = await ethers.getContractFactory("MonNFT");
  const monNFT = await MonNFT.deploy(
    "https://api.arn-apex.io/mon/",  // baseURI
    deployer.address,                 // admin
    deployer.address,                 // royalty receiver
    250                               // 2.5% royalty
  );
  await monNFT.waitForDeployment();
  const monAddress = await monNFT.getAddress();
  console.log("Mon NFT deployed to:", monAddress);
  
  // ============ Deploy Game Items ============
  console.log("\n--- Deploying Game Items ---");
  const GameItems = await ethers.getContractFactory("GameItems");
  const gameItems = await GameItems.deploy(
    "https://api.arn-apex.io/items/",  // baseURI
    deployer.address                    // admin
  );
  await gameItems.waitForDeployment();
  const itemsAddress = await gameItems.getAddress();
  console.log("Game Items deployed to:", itemsAddress);
  
  // ============ Deploy Marketplace ============
  console.log("\n--- Deploying Marketplace ---");
  const Marketplace = await ethers.getContractFactory("Marketplace");
  const marketplace = await Marketplace.deploy(
    frozAddress,      // FROZ token
    deployer.address, // treasury
    deployer.address  // admin
  );
  await marketplace.waitForDeployment();
  const marketplaceAddress = await marketplace.getAddress();
  console.log("Marketplace deployed to:", marketplaceAddress);
  
  // ============ Deploy Staking ============
  console.log("\n--- Deploying Staking ---");
  const Staking = await ethers.getContractFactory("Staking");
  const staking = await Staking.deploy(
    frozAddress,      // FROZ token
    deployer.address  // admin
  );
  await staking.waitForDeployment();
  const stakingAddress = await staking.getAddress();
  console.log("Staking deployed to:", stakingAddress);
  
  // ============ Deploy Battle Arena ============
  console.log("\n--- Deploying Battle Arena ---");
  const BattleArena = await ethers.getContractFactory("BattleArena");
  const battleArena = await BattleArena.deploy(
    monAddress,       // Mon NFT
    frozAddress,      // FROZ token
    deployer.address  // admin
  );
  await battleArena.waitForDeployment();
  const battleAddress = await battleArena.getAddress();
  console.log("Battle Arena deployed to:", battleAddress);
  
  // ============ Configure Contracts ============
  console.log("\n--- Configuring Contracts ---");
  
  // Approve contracts on marketplace
  console.log("Approving Mon NFT on Marketplace...");
  await marketplace.setApprovedContract(monAddress, true);
  
  console.log("Approving Game Items on Marketplace...");
  await marketplace.setApprovedContract(itemsAddress, true);
  
  // Set staking contract on marketplace (for fee distribution)
  console.log("Setting staking contract on Marketplace...");
  await marketplace.setStakingContract(stakingAddress);
  
  // Grant GAME_ROLE to BattleArena on FROZ token
  console.log("Granting GAME_ROLE to Battle Arena...");
  const GAME_ROLE = ethers.keccak256(ethers.toUtf8Bytes("GAME_ROLE"));
  await frozToken.grantRole(GAME_ROLE, battleAddress);
  
  // Grant GAME_ROLE to BattleArena on Mon NFT
  console.log("Granting GAME_ROLE to Battle Arena on Mon NFT...");
  await monNFT.grantRole(GAME_ROLE, battleAddress);
  
  // ============ Summary ============
  console.log("\n========================================");
  console.log("           DEPLOYMENT COMPLETE          ");
  console.log("========================================");
  console.log("\nContract Addresses:");
  console.log("-------------------");
  console.log(`FROZ Token:     ${frozAddress}`);
  console.log(`Mon NFT:        ${monAddress}`);
  console.log(`Game Items:     ${itemsAddress}`);
  console.log(`Marketplace:    ${marketplaceAddress}`);
  console.log(`Staking:        ${stakingAddress}`);
  console.log(`Battle Arena:   ${battleAddress}`);
  console.log("\n========================================");
  
  // Save deployment addresses
  const deploymentInfo = {
    network: (await ethers.provider.getNetwork()).name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      FROZToken: frozAddress,
      MonNFT: monAddress,
      GameItems: itemsAddress,
      Marketplace: marketplaceAddress,
      Staking: stakingAddress,
      BattleArena: battleAddress,
    },
  };
  
  console.log("\nDeployment Info (save this):");
  console.log(JSON.stringify(deploymentInfo, null, 2));
  
  return deploymentInfo;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
