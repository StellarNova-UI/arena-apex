// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title MonNFT
 * @notice ERC-721 NFT contract for Arn-Apex Mons (game characters)
 * @dev Each Mon has stats, abilities, genetics, and can be bred and evolved
 */
contract MonNFT is ERC721, ERC721Enumerable, ERC721URIStorage, ERC721Royalty, AccessControl, ReentrancyGuard {
    using Strings for uint256;
    
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GAME_ROLE = keccak256("GAME_ROLE");
    bytes32 public constant BREEDER_ROLE = keccak256("BREEDER_ROLE");
    
    /// @notice Maximum supply of Genesis Mons
    uint256 public constant MAX_GENESIS_SUPPLY = 10000;
    
    /// @notice Current token ID counter
    uint256 private _tokenIdCounter;
    
    /// @notice Number of Genesis Mons minted
    uint256 public genesisMinted;
    
    /// @notice Base URI for metadata
    string public baseURI;
    
    /// @notice Rarity tiers
    enum Rarity { Common, Rare, Epic, Legendary, Mythic }
    
    /// @notice Mon class types
    enum MonClass { Assault, Support, Scout, Tank }
    
    /// @notice Evolution stages
    enum EvolutionStage { Base, Stage1, Stage2, Final }
    
    /// @notice Mon stats structure
    struct MonStats {
        uint16 strength;    // Physical damage
        uint16 agility;     // Speed & evasion
        uint16 intelligence; // Ability power
        uint16 defense;     // Damage reduction
        uint16 level;       // Current level (max 100)
        uint32 experience;  // XP points
    }
    
    /// @notice Mon data structure
    struct MonData {
        uint256 geneticId;      // Unique genetic identifier
        Rarity rarity;
        MonClass monClass;
        EvolutionStage evolution;
        uint8 breedCount;       // Times bred (max 7)
        uint256 parent1Id;      // 0 if genesis
        uint256 parent2Id;      // 0 if genesis
        uint256 birthTime;
        bool isGenesis;
    }
    
    /// @notice Mon abilities (up to 5 per Mon)
    struct MonAbilities {
        uint8[5] abilityIds;
        uint8 abilityCount;
    }
    
    /// @notice Mapping from token ID to Mon stats
    mapping(uint256 => MonStats) public monStats;
    
    /// @notice Mapping from token ID to Mon data
    mapping(uint256 => MonData) public monData;
    
    /// @notice Mapping from token ID to abilities
    mapping(uint256 => MonAbilities) public monAbilities;
    
    /// @notice Mapping from genetic ID to existence (prevents duplicates)
    mapping(uint256 => bool) public geneticIdExists;
    
    /// @notice Events
    event MonMinted(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 geneticId,
        Rarity rarity,
        MonClass monClass,
        bool isGenesis
    );
    
    event MonBred(
        uint256 indexed childId,
        uint256 indexed parent1Id,
        uint256 indexed parent2Id,
        address breeder
    );
    
    event MonEvolved(
        uint256 indexed tokenId,
        EvolutionStage fromStage,
        EvolutionStage toStage
    );
    
    event MonLevelUp(
        uint256 indexed tokenId,
        uint16 oldLevel,
        uint16 newLevel
    );
    
    event ExperienceGained(
        uint256 indexed tokenId,
        uint32 amount,
        string source
    );
    
    constructor(
        string memory _baseURI,
        address _admin,
        address _royaltyReceiver,
        uint96 _royaltyBps // 250 = 2.5%
    ) ERC721("Arn-Apex Mon", "MON") {
        baseURI = _baseURI;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MINTER_ROLE, _admin);
        _grantRole(GAME_ROLE, _admin);
        _grantRole(BREEDER_ROLE, _admin);
        
        // Set default royalty (2.5%)
        _setDefaultRoyalty(_royaltyReceiver, _royaltyBps);
    }
    
    /**
     * @notice Mint a Genesis Mon (limited to MAX_GENESIS_SUPPLY)
     * @param to Recipient address
     * @param rarity Mon rarity tier
     * @param monClass Mon class type
     * @param initialStats Initial stat values
     * @param abilityIds Array of ability IDs
     */
    function mintGenesis(
        address to,
        Rarity rarity,
        MonClass monClass,
        MonStats calldata initialStats,
        uint8[] calldata abilityIds
    ) external onlyRole(MINTER_ROLE) nonReentrant returns (uint256) {
        require(genesisMinted < MAX_GENESIS_SUPPLY, "Genesis supply exhausted");
        require(abilityIds.length <= 5, "Too many abilities");
        
        _tokenIdCounter++;
        uint256 tokenId = _tokenIdCounter;
        genesisMinted++;
        
        // Generate unique genetic ID
        uint256 geneticId = _generateGeneticId(tokenId, rarity, monClass);
        require(!geneticIdExists[geneticId], "Genetic ID collision");
        geneticIdExists[geneticId] = true;
        
        _safeMint(to, tokenId);
        
        // Set Mon data
        monData[tokenId] = MonData({
            geneticId: geneticId,
            rarity: rarity,
            monClass: monClass,
            evolution: EvolutionStage.Base,
            breedCount: 0,
            parent1Id: 0,
            parent2Id: 0,
            birthTime: block.timestamp,
            isGenesis: true
        });
        
        // Set initial stats
        monStats[tokenId] = initialStats;
        
        // Set abilities
        MonAbilities storage abilities = monAbilities[tokenId];
        abilities.abilityCount = uint8(abilityIds.length);
        for (uint8 i = 0; i < abilityIds.length; i++) {
            abilities.abilityIds[i] = abilityIds[i];
        }
        
        emit MonMinted(tokenId, to, geneticId, rarity, monClass, true);
        
        return tokenId;
    }
    
    /**
     * @notice Breed two Mons to create offspring
     * @param parent1Id First parent token ID
     * @param parent2Id Second parent token ID
     * @param to Recipient of the offspring
     */
    function breed(
        uint256 parent1Id,
        uint256 parent2Id,
        address to
    ) external onlyRole(BREEDER_ROLE) nonReentrant returns (uint256) {
        require(_ownerOf(parent1Id) != address(0), "Parent 1 doesn't exist");
        require(_ownerOf(parent2Id) != address(0), "Parent 2 doesn't exist");
        require(parent1Id != parent2Id, "Same parent");
        require(monData[parent1Id].breedCount < 7, "Parent 1 max breeds reached");
        require(monData[parent2Id].breedCount < 7, "Parent 2 max breeds reached");
        
        _tokenIdCounter++;
        uint256 childId = _tokenIdCounter;
        
        // Increment breed counts
        monData[parent1Id].breedCount++;
        monData[parent2Id].breedCount++;
        
        // Determine child rarity and class (simplified genetic algorithm)
        Rarity childRarity = _calculateChildRarity(parent1Id, parent2Id);
        MonClass childClass = _calculateChildClass(parent1Id, parent2Id);
        
        // Generate child genetic ID
        uint256 geneticId = _generateGeneticId(childId, childRarity, childClass);
        geneticIdExists[geneticId] = true;
        
        _safeMint(to, childId);
        
        // Set child data
        monData[childId] = MonData({
            geneticId: geneticId,
            rarity: childRarity,
            monClass: childClass,
            evolution: EvolutionStage.Base,
            breedCount: 0,
            parent1Id: parent1Id,
            parent2Id: parent2Id,
            birthTime: block.timestamp,
            isGenesis: false
        });
        
        // Inherit stats (50-70% of parents)
        MonStats storage p1Stats = monStats[parent1Id];
        MonStats storage p2Stats = monStats[parent2Id];
        
        monStats[childId] = MonStats({
            strength: uint16(((p1Stats.strength + p2Stats.strength) * 60) / 200),
            agility: uint16(((p1Stats.agility + p2Stats.agility) * 60) / 200),
            intelligence: uint16(((p1Stats.intelligence + p2Stats.intelligence) * 60) / 200),
            defense: uint16(((p1Stats.defense + p2Stats.defense) * 60) / 200),
            level: 1,
            experience: 0
        });
        
        // Inherit abilities (random selection from parents)
        _inheritAbilities(childId, parent1Id, parent2Id);
        
        emit MonBred(childId, parent1Id, parent2Id, to);
        emit MonMinted(childId, to, geneticId, childRarity, childClass, false);
        
        return childId;
    }
    
    /**
     * @notice Add experience to a Mon (only GAME_ROLE)
     * @param tokenId Mon token ID
     * @param amount XP amount
     * @param source Source of XP (battle, quest, etc.)
     */
    function addExperience(
        uint256 tokenId,
        uint32 amount,
        string calldata source
    ) external onlyRole(GAME_ROLE) {
        require(_ownerOf(tokenId) != address(0), "Mon doesn't exist");
        
        MonStats storage stats = monStats[tokenId];
        stats.experience += amount;
        
        emit ExperienceGained(tokenId, amount, source);
        
        // Check for level up
        uint16 newLevel = _calculateLevel(stats.experience);
        if (newLevel > stats.level && newLevel <= 100) {
            uint16 oldLevel = stats.level;
            stats.level = newLevel;
            
            // Stat boost on level up
            stats.strength += 2;
            stats.agility += 2;
            stats.intelligence += 2;
            stats.defense += 2;
            
            emit MonLevelUp(tokenId, oldLevel, newLevel);
        }
    }
    
    /**
     * @notice Evolve a Mon to the next stage (only GAME_ROLE)
     * @param tokenId Mon token ID
     */
    function evolve(uint256 tokenId) external onlyRole(GAME_ROLE) {
        require(_ownerOf(tokenId) != address(0), "Mon doesn't exist");
        
        MonData storage data = monData[tokenId];
        MonStats storage stats = monStats[tokenId];
        
        EvolutionStage currentStage = data.evolution;
        require(currentStage != EvolutionStage.Final, "Already at final stage");
        
        // Level requirements: Stage1 at 25, Stage2 at 50, Final at 75
        if (currentStage == EvolutionStage.Base) {
            require(stats.level >= 25, "Need level 25");
            data.evolution = EvolutionStage.Stage1;
        } else if (currentStage == EvolutionStage.Stage1) {
            require(stats.level >= 50, "Need level 50");
            data.evolution = EvolutionStage.Stage2;
        } else if (currentStage == EvolutionStage.Stage2) {
            require(stats.level >= 75, "Need level 75");
            data.evolution = EvolutionStage.Final;
        }
        
        // Stat boost on evolution
        stats.strength += 10;
        stats.agility += 10;
        stats.intelligence += 10;
        stats.defense += 10;
        
        emit MonEvolved(tokenId, currentStage, data.evolution);
    }
    
    /**
     * @notice Get full Mon info
     * @param tokenId Mon token ID
     */
    function getMonInfo(uint256 tokenId) external view returns (
        MonData memory data,
        MonStats memory stats,
        uint8[5] memory abilityIds,
        uint8 abilityCount
    ) {
        require(_ownerOf(tokenId) != address(0), "Mon doesn't exist");
        return (
            monData[tokenId],
            monStats[tokenId],
            monAbilities[tokenId].abilityIds,
            monAbilities[tokenId].abilityCount
        );
    }
    
    /**
     * @notice Set base URI (only admin)
     */
    function setBaseURI(string memory newBaseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        baseURI = newBaseURI;
    }
    
    /**
     * @notice Update royalty info (only admin)
     */
    function setRoyalty(address receiver, uint96 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDefaultRoyalty(receiver, feeBps);
    }
    
    // ============ Internal Functions ============
    
    function _generateGeneticId(
        uint256 tokenId,
        Rarity rarity,
        MonClass monClass
    ) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(
            tokenId,
            rarity,
            monClass,
            block.timestamp,
            block.prevrandao,
            msg.sender
        )));
    }
    
    function _calculateChildRarity(uint256 parent1Id, uint256 parent2Id) internal view returns (Rarity) {
        Rarity r1 = monData[parent1Id].rarity;
        Rarity r2 = monData[parent2Id].rarity;
        
        // Average of parents with 5% mutation chance for upgrade
        uint256 avgRarity = (uint256(r1) + uint256(r2)) / 2;
        uint256 rand = uint256(keccak256(abi.encodePacked(block.timestamp, parent1Id, parent2Id))) % 100;
        
        if (rand < 5 && avgRarity < uint256(Rarity.Mythic)) {
            return Rarity(avgRarity + 1);
        }
        return Rarity(avgRarity);
    }
    
    function _calculateChildClass(uint256 parent1Id, uint256 parent2Id) internal view returns (MonClass) {
        // Random class from one of the parents
        uint256 rand = uint256(keccak256(abi.encodePacked(block.timestamp, parent1Id))) % 2;
        return rand == 0 ? monData[parent1Id].monClass : monData[parent2Id].monClass;
    }
    
    function _inheritAbilities(uint256 childId, uint256 parent1Id, uint256 parent2Id) internal {
        MonAbilities storage p1Abilities = monAbilities[parent1Id];
        MonAbilities storage p2Abilities = monAbilities[parent2Id];
        MonAbilities storage childAbilities = monAbilities[childId];
        
        // Inherit 2-3 abilities randomly from parents
        uint8 count = 0;
        if (p1Abilities.abilityCount > 0) {
            childAbilities.abilityIds[count++] = p1Abilities.abilityIds[0];
        }
        if (p2Abilities.abilityCount > 0) {
            childAbilities.abilityIds[count++] = p2Abilities.abilityIds[0];
        }
        childAbilities.abilityCount = count;
    }
    
    function _calculateLevel(uint32 experience) internal pure returns (uint16) {
        // Simple level curve: level = sqrt(experience / 100)
        if (experience < 100) return 1;
        uint256 level = _sqrt(experience / 100);
        return level > 100 ? 100 : uint16(level);
    }
    
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
    
    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }
    
    // ============ Required Overrides ============
    
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }
    
    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value);
    }
    
    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }
    
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC721URIStorage, ERC721Royalty, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
