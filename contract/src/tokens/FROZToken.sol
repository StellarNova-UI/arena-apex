// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title FROZ Token
 * @notice The native utility and governance token of the Arn-Apex ecosystem
 * @dev ERC20 token with burning, permit (gasless approvals), and voting capabilities
 * 
 * Token Distribution (1 billion total supply):
 * - 40% Community rewards (battles, quests, tournaments)
 * - 25% Liquidity pools
 * - 20% Team (4-year vesting)
 * - 10% Treasury (DAO controlled)
 * - 5% Initial sale
 */
contract FROZToken is ERC20, ERC20Burnable, ERC20Permit, ERC20Votes, AccessControl, ReentrancyGuard {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant GAME_ROLE = keccak256("GAME_ROLE");
    
    /// @notice Maximum supply: 1 billion FROZ
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18;
    
    /// @notice Tracks total minted (for enforcing max supply)
    uint256 public totalMinted;
    
    /// @notice Treasury address for fee collection
    address public treasury;
    
    /// @notice Transfer fee basis points (0.1% = 10 bps, set to 0 by default)
    uint256 public transferFeeBps;
    
    /// @notice Addresses exempt from transfer fees
    mapping(address => bool) public feeExempt;
    
    /// @notice Emitted when treasury is updated
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    
    /// @notice Emitted when transfer fee is updated
    event TransferFeeUpdated(uint256 oldFee, uint256 newFee);
    
    /// @notice Emitted when game rewards are distributed
    event GameRewardDistributed(address indexed player, uint256 amount, string rewardType);
    
    constructor(
        address _treasury,
        address _admin
    ) ERC20("FROZ Token", "FROZ") ERC20Permit("FROZ Token") {
        require(_treasury != address(0), "Invalid treasury");
        require(_admin != address(0), "Invalid admin");
        
        treasury = _treasury;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MINTER_ROLE, _admin);
        
        // Mint initial allocations
        // Treasury: 10% = 100M FROZ
        _mint(_treasury, 100_000_000 * 10**18);
        totalMinted = 100_000_000 * 10**18;
        
        // Mark treasury as fee exempt
        feeExempt[_treasury] = true;
    }
    
    /**
     * @notice Mint new FROZ tokens (only MINTER_ROLE)
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(totalMinted + amount <= MAX_SUPPLY, "Exceeds max supply");
        totalMinted += amount;
        _mint(to, amount);
    }
    
    /**
     * @notice Distribute game rewards to players (only GAME_ROLE)
     * @param player Player address
     * @param amount Reward amount
     * @param rewardType Type of reward (battle, quest, tournament, etc.)
     */
    function distributeGameReward(
        address player,
        uint256 amount,
        string calldata rewardType
    ) external onlyRole(GAME_ROLE) nonReentrant {
        require(totalMinted + amount <= MAX_SUPPLY, "Exceeds max supply");
        require(player != address(0), "Invalid player");
        
        totalMinted += amount;
        _mint(player, amount);
        
        emit GameRewardDistributed(player, amount, rewardType);
    }
    
    /**
     * @notice Batch distribute rewards to multiple players
     * @param players Array of player addresses
     * @param amounts Array of reward amounts
     * @param rewardType Type of reward
     */
    function batchDistributeRewards(
        address[] calldata players,
        uint256[] calldata amounts,
        string calldata rewardType
    ) external onlyRole(GAME_ROLE) nonReentrant {
        require(players.length == amounts.length, "Length mismatch");
        require(players.length <= 100, "Batch too large");
        
        uint256 totalAmount;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
        }
        
        require(totalMinted + totalAmount <= MAX_SUPPLY, "Exceeds max supply");
        totalMinted += totalAmount;
        
        for (uint256 i = 0; i < players.length; i++) {
            if (players[i] != address(0) && amounts[i] > 0) {
                _mint(players[i], amounts[i]);
                emit GameRewardDistributed(players[i], amounts[i], rewardType);
            }
        }
    }
    
    /**
     * @notice Update treasury address (only admin)
     * @param newTreasury New treasury address
     */
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), "Invalid treasury");
        address oldTreasury = treasury;
        treasury = newTreasury;
        feeExempt[newTreasury] = true;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }
    
    /**
     * @notice Set transfer fee (only admin, max 1% = 100 bps)
     * @param newFeeBps New fee in basis points
     */
    function setTransferFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFeeBps <= 100, "Fee too high"); // Max 1%
        uint256 oldFee = transferFeeBps;
        transferFeeBps = newFeeBps;
        emit TransferFeeUpdated(oldFee, newFeeBps);
    }
    
    /**
     * @notice Set fee exemption status for an address
     * @param account Address to update
     * @param exempt Whether to exempt from fees
     */
    function setFeeExempt(address account, bool exempt) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeExempt[account] = exempt;
    }
    
    /**
     * @notice Returns remaining mintable supply
     */
    function remainingSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalMinted;
    }
    
    // ============ Overrides ============
    
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Votes) {
        // Apply transfer fee if applicable
        if (
            transferFeeBps > 0 &&
            from != address(0) &&
            to != address(0) &&
            !feeExempt[from] &&
            !feeExempt[to]
        ) {
            uint256 fee = (value * transferFeeBps) / 10000;
            if (fee > 0) {
                super._update(from, treasury, fee);
                value -= fee;
            }
        }
        
        super._update(from, to, value);
    }
    
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
