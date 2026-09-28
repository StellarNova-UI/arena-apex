// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Burnable.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title GameItems
 * @notice ERC-1155 contract for Arn-Apex game items (parts, materials, consumables)
 * @dev Supports multiple item types with different rarities and use cases
 */
contract GameItems is ERC1155, ERC1155Burnable, ERC1155Supply, AccessControl, ReentrancyGuard {
    using Strings for uint256;
    
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GAME_ROLE = keccak256("GAME_ROLE");
    
    /// @notice Item categories
    enum ItemCategory { Part, Material, Consumable, EvolutionStone, Upgrade }
    
    /// @notice Item rarity
    enum ItemRarity { Common, Rare, Epic, Legendary, Mythic }
    
    /// @notice Item data structure
    struct ItemType {
        string name;
        string description;
        ItemCategory category;
        ItemRarity rarity;
        uint256 maxSupply;      // 0 = unlimited
        uint256 frozPrice;      // Default price in FROZ (wei)
        bool tradable;
        bool consumable;
        bool active;
    }
    
    /// @notice Base URI for metadata
    string public baseURI;
    
    /// @notice Contract name for marketplaces
    string public name = "Arn-Apex Items";
    
    /// @notice Contract symbol
    string public symbol = "ITEM";
    
    /// @notice Next item type ID
    uint256 public nextItemTypeId = 1;
    
    /// @notice Mapping from item type ID to item data
    mapping(uint256 => ItemType) public itemTypes;
    
    /// @notice Mapping from item type ID to total minted
    mapping(uint256 => uint256) public totalMinted;
    
    /// @notice Events
    event ItemTypeCreated(
        uint256 indexed itemTypeId,
        string name,
        ItemCategory category,
        ItemRarity rarity
    );
    
    event ItemsMinted(
        uint256 indexed itemTypeId,
        address indexed to,
        uint256 amount
    );
    
    event ItemUsed(
        uint256 indexed itemTypeId,
        address indexed user,
        uint256 amount,
        string useCase
    );
    
    constructor(
        string memory _baseURI,
        address _admin
    ) ERC1155(_baseURI) {
        baseURI = _baseURI;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MINTER_ROLE, _admin);
        _grantRole(GAME_ROLE, _admin);
        
        // Initialize default item types
        _createDefaultItems();
    }
    
    /**
     * @notice Create a new item type (only admin)
     * @param _name Item name
     * @param _description Item description
     * @param _category Item category
     * @param _rarity Item rarity
     * @param _maxSupply Maximum supply (0 = unlimited)
     * @param _frozPrice Default FROZ price
     * @param _tradable Whether item can be traded
     * @param _consumable Whether item is consumed on use
     */
    function createItemType(
        string calldata _name,
        string calldata _description,
        ItemCategory _category,
        ItemRarity _rarity,
        uint256 _maxSupply,
        uint256 _frozPrice,
        bool _tradable,
        bool _consumable
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
        uint256 itemTypeId = nextItemTypeId++;
        
        itemTypes[itemTypeId] = ItemType({
            name: _name,
            description: _description,
            category: _category,
            rarity: _rarity,
            maxSupply: _maxSupply,
            frozPrice: _frozPrice,
            tradable: _tradable,
            consumable: _consumable,
            active: true
        });
        
        emit ItemTypeCreated(itemTypeId, _name, _category, _rarity);
        
        return itemTypeId;
    }
    
    /**
     * @notice Mint items (only MINTER_ROLE)
     * @param to Recipient address
     * @param itemTypeId Item type ID
     * @param amount Amount to mint
     */
    function mint(
        address to,
        uint256 itemTypeId,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) nonReentrant {
        require(itemTypes[itemTypeId].active, "Item type not active");
        
        ItemType storage item = itemTypes[itemTypeId];
        if (item.maxSupply > 0) {
            require(totalMinted[itemTypeId] + amount <= item.maxSupply, "Exceeds max supply");
        }
        
        totalMinted[itemTypeId] += amount;
        _mint(to, itemTypeId, amount, "");
        
        emit ItemsMinted(itemTypeId, to, amount);
    }
    
    /**
     * @notice Batch mint multiple items
     * @param to Recipient address
     * @param itemTypeIds Array of item type IDs
     * @param amounts Array of amounts
     */
    function mintBatch(
        address to,
        uint256[] calldata itemTypeIds,
        uint256[] calldata amounts
    ) external onlyRole(MINTER_ROLE) nonReentrant {
        require(itemTypeIds.length == amounts.length, "Length mismatch");
        
        for (uint256 i = 0; i < itemTypeIds.length; i++) {
            require(itemTypes[itemTypeIds[i]].active, "Item type not active");
            
            ItemType storage item = itemTypes[itemTypeIds[i]];
            if (item.maxSupply > 0) {
                require(
                    totalMinted[itemTypeIds[i]] + amounts[i] <= item.maxSupply,
                    "Exceeds max supply"
                );
            }
            totalMinted[itemTypeIds[i]] += amounts[i];
        }
        
        _mintBatch(to, itemTypeIds, amounts, "");
    }
    
    /**
     * @notice Use/consume an item in-game (only GAME_ROLE)
     * @param user User address
     * @param itemTypeId Item type ID
     * @param amount Amount to use
     * @param useCase Description of use (evolution, upgrade, etc.)
     */
    function useItem(
        address user,
        uint256 itemTypeId,
        uint256 amount,
        string calldata useCase
    ) external onlyRole(GAME_ROLE) nonReentrant {
        require(itemTypes[itemTypeId].active, "Item type not active");
        require(balanceOf(user, itemTypeId) >= amount, "Insufficient balance");
        
        ItemType storage item = itemTypes[itemTypeId];
        
        if (item.consumable) {
            _burn(user, itemTypeId, amount);
        }
        
        emit ItemUsed(itemTypeId, user, amount, useCase);
    }
    
    /**
     * @notice Distribute loot/rewards to player (only GAME_ROLE)
     * @param player Player address
     * @param itemTypeIds Array of item type IDs
     * @param amounts Array of amounts
     */
    function distributeLoot(
        address player,
        uint256[] calldata itemTypeIds,
        uint256[] calldata amounts
    ) external onlyRole(GAME_ROLE) nonReentrant {
        require(itemTypeIds.length == amounts.length, "Length mismatch");
        require(itemTypeIds.length <= 10, "Too many items");
        
        for (uint256 i = 0; i < itemTypeIds.length; i++) {
            if (itemTypes[itemTypeIds[i]].active && amounts[i] > 0) {
                ItemType storage item = itemTypes[itemTypeIds[i]];
                
                if (item.maxSupply == 0 || totalMinted[itemTypeIds[i]] + amounts[i] <= item.maxSupply) {
                    totalMinted[itemTypeIds[i]] += amounts[i];
                    _mint(player, itemTypeIds[i], amounts[i], "");
                    emit ItemsMinted(itemTypeIds[i], player, amounts[i]);
                }
            }
        }
    }
    
    /**
     * @notice Update item type (only admin)
     */
    function updateItemType(
        uint256 itemTypeId,
        uint256 newFrozPrice,
        bool newTradable,
        bool newActive
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(itemTypes[itemTypeId].active || newActive, "Item doesn't exist");
        
        ItemType storage item = itemTypes[itemTypeId];
        item.frozPrice = newFrozPrice;
        item.tradable = newTradable;
        item.active = newActive;
    }
    
    /**
     * @notice Get item type info
     */
    function getItemType(uint256 itemTypeId) external view returns (ItemType memory) {
        return itemTypes[itemTypeId];
    }
    
    /**
     * @notice Get remaining supply for an item type
     */
    function remainingSupply(uint256 itemTypeId) external view returns (uint256) {
        ItemType storage item = itemTypes[itemTypeId];
        if (item.maxSupply == 0) return type(uint256).max;
        return item.maxSupply - totalMinted[itemTypeId];
    }
    
    /**
     * @notice Set base URI (only admin)
     */
    function setBaseURI(string memory newBaseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        baseURI = newBaseURI;
    }
    
    /**
     * @notice URI for a token ID
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        return string(abi.encodePacked(baseURI, tokenId.toString(), ".json"));
    }
    
    // ============ Internal Functions ============
    
    function _createDefaultItems() internal {
        // Parts (ID 1-10)
        _createItem("Neural Chip", "Boosts intelligence stat", ItemCategory.Part, ItemRarity.Rare, 10000, 500 ether, true, false);
        _createItem("Plasma Core", "High-power energy source", ItemCategory.Part, ItemRarity.Legendary, 1000, 2500 ether, true, false);
        _createItem("Stealth Module", "Increases evasion", ItemCategory.Part, ItemRarity.Rare, 5000, 800 ether, true, false);
        _createItem("Titanium Plating", "Enhanced defense", ItemCategory.Part, ItemRarity.Epic, 3000, 1500 ether, true, false);
        _createItem("Quantum Drive", "Speed enhancement", ItemCategory.Part, ItemRarity.Legendary, 500, 5000 ether, true, false);
        
        // Materials (ID 6-10)
        _createItem("Scrap Metal", "Common crafting material", ItemCategory.Material, ItemRarity.Common, 0, 10 ether, true, true);
        _createItem("Energy Crystal", "Powers upgrades", ItemCategory.Material, ItemRarity.Rare, 0, 100 ether, true, true);
        _createItem("Nano Fiber", "Advanced material", ItemCategory.Material, ItemRarity.Epic, 0, 500 ether, true, true);
        _createItem("Dark Matter", "Rare element", ItemCategory.Material, ItemRarity.Legendary, 10000, 2000 ether, true, true);
        _createItem("Cosmic Dust", "Mythic material", ItemCategory.Material, ItemRarity.Mythic, 1000, 10000 ether, true, true);
        
        // Consumables (ID 11-15)
        _createItem("Health Pack", "Restores HP in battle", ItemCategory.Consumable, ItemRarity.Common, 0, 20 ether, true, true);
        _createItem("Energy Boost", "Restores ability cooldowns", ItemCategory.Consumable, ItemRarity.Rare, 0, 50 ether, true, true);
        _createItem("XP Potion", "Grants 1000 XP", ItemCategory.Consumable, ItemRarity.Rare, 0, 200 ether, true, true);
        _createItem("Lucky Charm", "Increases drop rate", ItemCategory.Consumable, ItemRarity.Epic, 5000, 1000 ether, true, true);
        _createItem("Revive Token", "Revives Mon in battle", ItemCategory.Consumable, ItemRarity.Legendary, 2000, 3000 ether, true, true);
        
        // Evolution Stones (ID 16-20)
        _createItem("Evolution Stone", "Triggers Stage 1 evolution", ItemCategory.EvolutionStone, ItemRarity.Rare, 0, 1000 ether, true, true);
        _createItem("Rare Evolution Stone", "Triggers Stage 2 evolution", ItemCategory.EvolutionStone, ItemRarity.Epic, 5000, 3000 ether, true, true);
        _createItem("Mythic Evolution Stone", "Triggers Final evolution", ItemCategory.EvolutionStone, ItemRarity.Mythic, 500, 10000 ether, true, true);
        
        // Upgrades (ID 19-20)
        _createItem("Stat Reset Token", "Resets Mon stats", ItemCategory.Upgrade, ItemRarity.Epic, 1000, 5000 ether, true, true);
        _createItem("Ability Scroll", "Teaches new ability", ItemCategory.Upgrade, ItemRarity.Legendary, 500, 8000 ether, true, true);
    }
    
    function _createItem(
        string memory _name,
        string memory _description,
        ItemCategory _category,
        ItemRarity _rarity,
        uint256 _maxSupply,
        uint256 _frozPrice,
        bool _tradable,
        bool _consumable
    ) internal returns (uint256) {
        uint256 itemTypeId = nextItemTypeId++;
        
        itemTypes[itemTypeId] = ItemType({
            name: _name,
            description: _description,
            category: _category,
            rarity: _rarity,
            maxSupply: _maxSupply,
            frozPrice: _frozPrice,
            tradable: _tradable,
            consumable: _consumable,
            active: true
        });
        
        emit ItemTypeCreated(itemTypeId, _name, _category, _rarity);
        
        return itemTypeId;
    }
    
    // ============ Required Overrides ============
    
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155, ERC1155Supply) {
        // Check tradability if transferring (not minting/burning)
        if (from != address(0) && to != address(0)) {
            for (uint256 i = 0; i < ids.length; i++) {
                require(itemTypes[ids[i]].tradable, "Item not tradable");
            }
        }
        
        super._update(from, to, ids, values);
    }
    
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
