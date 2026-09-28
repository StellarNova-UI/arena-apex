# Arn-Apex Smart Contracts

Smart contracts for the Arn-Apex game ecosystem, including tokens, NFTs, marketplace, staking, and battle mechanics.

## Overview

| Contract | Description |
|----------|-------------|
| `FROZToken` | ERC-20 governance and utility token with minting, burning, and game rewards |
| `MonNFT` | ERC-721 NFT for game characters (Mons) with stats, abilities, breeding, and evolution |
| `GameItems` | ERC-1155 multi-token for game items (parts, materials, consumables) |
| `Marketplace` | Decentralized marketplace for trading Mons and items |
| `Staking` | DeFi staking pools for FROZ and LP tokens |
| `BattleArena` | On-chain battle system with matchmaking and rewards |

## Quick Start

### Prerequisites

- Node.js 18+
- npm or yarn
- A wallet with testnet ETH (for Sepolia) or mainnet ETH

### Installation

```bash
cd contract
npm install
```

### Configuration

1. Copy `.env.example` to `.env`:
```bash
cp .env.example .env
```

2. Fill in your environment variables:
```env
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_KEY
PRIVATE_KEY=your_private_key_without_0x
ETHERSCAN_API_KEY=your_etherscan_key
```

### Compile

```bash
npm run compile
```

### Test

```bash
npm run test
```

### Deploy

**Local (Hardhat Network):**
```bash
# Start local node
npm run node

# In another terminal
npm run deploy:local
```

**Sepolia Testnet:**
```bash
npm run deploy:sepolia
```

**Mainnet:**
```bash
npm run deploy:mainnet
```

## Contract Architecture

```
contract/
├── src/
│   ├── tokens/
│   │   └── FROZToken.sol       # ERC-20 utility/governance token
│   ├── nft/
│   │   ├── MonNFT.sol          # ERC-721 game characters
│   │   └── GameItems.sol       # ERC-1155 game items
│   ├── marketplace/
│   │   └── Marketplace.sol     # Trading platform
│   ├── defi/
│   │   └── Staking.sol         # Staking pools
│   └── game/
│       └── BattleArena.sol     # Battle mechanics
├── scripts/
│   ├── deploy.ts               # Main deployment script
│   └── mint-genesis.ts         # Genesis Mon minting
└── test/                       # Test files
```

## Token Economics

### FROZ Token
- **Total Supply:** 1 billion FROZ
- **Distribution:**
  - 40% Community rewards (battles, quests, tournaments)
  - 25% Liquidity pools
  - 20% Team (4-year vesting)
  - 10% Treasury (DAO controlled)
  - 5% Initial sale

### Earning FROZ
- Win battles: 50-500 FROZ
- Complete quests: 100-1,000 FROZ
- Tournament prizes: 5,000-50,000 FROZ
- Staking rewards: 45-200% APY

## Mon NFT System

### Stats
Each Mon has four core stats (0-100 scale):
- **STR (Strength):** Physical damage
- **AGI (Agility):** Speed and evasion
- **INT (Intelligence):** Ability power
- **DEF (Defense):** Damage reduction

### Rarity Tiers
- Common
- Rare
- Epic
- Legendary
- Mythic

### Classes
- Assault (high damage)
- Support (healing/buffs)
- Scout (speed/evasion)
- Tank (high defense)

### Evolution
- **Base → Stage 1:** Level 25 + Evolution Stone
- **Stage 1 → Stage 2:** Level 50 + Rare Evolution Stone
- **Stage 2 → Final:** Level 75 + Mythic Evolution Stone

### Breeding
- Two Mons can breed to create offspring
- Offspring inherits 50-70% of parent stats
- 5% mutation chance for stat/ability upgrade
- Max 7 breeds per Mon
- Cost: 500 FROZ + materials

## Game Items

### Categories
| ID Range | Category | Examples |
|----------|----------|----------|
| 1-5 | Parts | Neural Chip, Plasma Core, Stealth Module |
| 6-10 | Materials | Scrap Metal, Energy Crystal, Dark Matter |
| 11-15 | Consumables | Health Pack, XP Potion, Revive Token |
| 16-18 | Evolution Stones | Basic, Rare, Mythic |
| 19-20 | Upgrades | Stat Reset Token, Ability Scroll |

## Marketplace

### Features
- Fixed-price listings
- Auction with bidding
- Offers for unlisted items
- 0.5% trading fee (split: 0.2% stakers, 0.2% treasury, 0.1% burned)

### Trading Flow
1. Seller approves Marketplace contract
2. Seller creates listing (price, duration)
3. Buyer purchases with FROZ
4. Smart contract transfers NFT to buyer, FROZ to seller
5. Fee distributed automatically

## Staking

### Pool Types
| Pool | APY | Lock Period |
|------|-----|-------------|
| Flexible FROZ | 45% | None |
| Locked FROZ | 200% | 90 days |
| FROZ-ETH LP | 120% | None |
| FROZ-USDT LP | 85% | None |

### Voting Power
Staked FROZ grants voting power for DAO governance (1 staked FROZ = 1 vote).

## Battle System

### Match Types
- **Quick Battle:** 1v1, 50-100 FROZ reward
- **Ranked:** 1v1, affects ranking, 200-500 FROZ reward
- **Tournament:** Bracket-style, large prize pools
- **Wager:** Direct challenge with FROZ stake

### Battle Flow
1. Player joins matchmaking queue with Mon
2. System matches players with similar rank
3. Battle hash generated for off-chain resolution
4. Game server (Oracle) submits result
5. Rewards distributed, XP granted, rankings updated

### XP System
- Win: +100 XP
- Loss: +25 XP
- Level = sqrt(XP / 100), max 100

## Security

### Access Control
All contracts use OpenZeppelin's AccessControl:
- `DEFAULT_ADMIN_ROLE`: Full admin access
- `MINTER_ROLE`: Can mint tokens/NFTs
- `GAME_ROLE`: Can distribute game rewards
- `OPERATOR_ROLE`: Can pause/configure contracts
- `ORACLE_ROLE`: Can submit battle results

### Audits
- [ ] Internal review completed
- [ ] External audit pending

## Gas Optimization
- Uses Solidity 0.8.20 with optimizer (200 runs)
- viaIR enabled for complex contracts
- Batch operations for multiple transfers
- Events for off-chain indexing

## Frontend Integration

### Required ABIs
After compilation, ABIs are available in `artifacts/`:
```
artifacts/src/tokens/FROZToken.sol/FROZToken.json
artifacts/src/nft/MonNFT.sol/MonNFT.json
artifacts/src/nft/GameItems.sol/GameItems.json
artifacts/src/marketplace/Marketplace.sol/Marketplace.json
artifacts/src/defi/Staking.sol/Staking.json
artifacts/src/game/BattleArena.sol/BattleArena.json
```

### Example: Connect with ethers.js
```typescript
import { ethers } from "ethers";
import FROZTokenABI from "./artifacts/FROZToken.json";

const provider = new ethers.BrowserProvider(window.ethereum);
const signer = await provider.getSigner();

const frozToken = new ethers.Contract(
  "0x...", // Contract address
  FROZTokenABI.abi,
  signer
);

// Check balance
const balance = await frozToken.balanceOf(signer.address);
console.log("FROZ Balance:", ethers.formatEther(balance));
```

## License

MIT License - see [LICENSE](LICENSE)

## Links

- [Whitepaper](https://arn-apex.io/whitepaper)
- [Documentation](https://docs.arn-apex.io)
- [Discord](https://discord.gg/arn-apex)
- [Twitter](https://twitter.com/arnApex)
