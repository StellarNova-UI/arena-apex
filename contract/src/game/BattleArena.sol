// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IMonNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function addExperience(uint256 tokenId, uint32 amount, string calldata source) external;
    function monStats(uint256 tokenId) external view returns (
        uint16 strength,
        uint16 agility,
        uint16 intelligence,
        uint16 defense,
        uint16 level,
        uint32 experience
    );
}

interface IFROZToken {
    function distributeGameReward(address player, uint256 amount, string calldata rewardType) external;
}

/**
 * @title BattleArena
 * @notice On-chain battle system for Arn-Apex Mons
 * @dev Handles matchmaking, battle results, rewards, and rankings
 */
contract BattleArena is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE"); // For off-chain battle resolution
    
    /// @notice Battle types
    enum BattleType { QuickBattle, Ranked, Tournament }
    
    /// @notice Battle status
    enum BattleStatus { Pending, InProgress, Completed, Cancelled }
    
    /// @notice Battle result
    enum BattleResult { None, Player1Win, Player2Win, Draw }
    
    /// @notice Battle data
    struct Battle {
        address player1;
        address player2;
        uint256 mon1Id;
        uint256 mon2Id;
        BattleType battleType;
        BattleStatus status;
        BattleResult result;
        uint256 wager;          // Optional FROZ wager
        uint256 startTime;
        uint256 endTime;
        bytes32 battleHash;     // Hash for battle verification
    }
    
    /// @notice Player stats
    struct PlayerStats {
        uint256 wins;
        uint256 losses;
        uint256 draws;
        uint256 winStreak;
        uint256 maxWinStreak;
        uint256 rankPoints;
        uint256 totalFrozEarned;
        uint256 lastBattleTime;
    }
    
    /// @notice Season data
    struct Season {
        uint256 startTime;
        uint256 endTime;
        uint256 prizePool;
        bool active;
    }
    
    /// @notice Mon NFT contract
    IMonNFT public monNFT;
    
    /// @notice FROZ token contract
    IFROZToken public frozToken;
    
    /// @notice FROZ ERC20 for transfers
    IERC20 public frozERC20;
    
    /// @notice Battle counter
    uint256 public nextBattleId = 1;
    
    /// @notice Current season
    uint256 public currentSeason = 1;
    
    /// @notice Rewards configuration
    uint256 public quickBattleReward = 75 * 1e18;      // 50-100 FROZ
    uint256 public rankedWinReward = 350 * 1e18;       // 200-500 FROZ
    uint256 public rankedLossReward = 50 * 1e18;       // Small reward for participation
    uint256 public xpPerWin = 100;
    uint256 public xpPerLoss = 25;
    
    /// @notice Rank points configuration
    uint256 public rankPointsPerWin = 25;
    uint256 public rankPointsPerLoss = 10;
    
    /// @notice Matchmaking queue
    mapping(BattleType => address[]) public matchQueue;
    
    /// @notice Player's queued Mon
    mapping(address => uint256) public queuedMon;
    
    /// @notice Battles
    mapping(uint256 => Battle) public battles;
    
    /// @notice Player stats
    mapping(address => PlayerStats) public playerStats;
    
    /// @notice Season data
    mapping(uint256 => Season) public seasons;
    
    /// @notice Season rankings (season => rank => player)
    mapping(uint256 => mapping(uint256 => address)) public seasonRankings;
    
    /// @notice Player's Mon is in battle
    mapping(uint256 => bool) public monInBattle;
    
    /// @notice Cooldown between battles (anti-spam)
    uint256 public battleCooldown = 30 seconds;
    
    /// @notice Events
    event BattleQueued(
        address indexed player,
        uint256 indexed monId,
        BattleType battleType
    );
    
    event BattleStarted(
        uint256 indexed battleId,
        address indexed player1,
        address indexed player2,
        uint256 mon1Id,
        uint256 mon2Id,
        BattleType battleType
    );
    
    event BattleCompleted(
        uint256 indexed battleId,
        address indexed winner,
        BattleResult result,
        uint256 reward
    );
    
    event RankUpdated(
        address indexed player,
        uint256 newRankPoints,
        int256 change
    );
    
    event SeasonStarted(
        uint256 indexed seasonId,
        uint256 startTime,
        uint256 endTime
    );
    
    event SeasonEnded(
        uint256 indexed seasonId,
        address[] topPlayers,
        uint256[] rewards
    );
    
    constructor(
        address _monNFT,
        address _frozToken,
        address _admin
    ) {
        require(_monNFT != address(0), "Invalid MonNFT");
        require(_frozToken != address(0), "Invalid FROZ");
        require(_admin != address(0), "Invalid admin");
        
        monNFT = IMonNFT(_monNFT);
        frozToken = IFROZToken(_frozToken);
        frozERC20 = IERC20(_frozToken);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(ORACLE_ROLE, _admin);
        
        // Initialize first season
        seasons[1] = Season({
            startTime: block.timestamp,
            endTime: block.timestamp + 90 days,
            prizePool: 0,
            active: true
        });
    }
    
    // ============ Matchmaking Functions ============
    
    /**
     * @notice Join matchmaking queue
     * @param monId Mon token ID to battle with
     * @param battleType Type of battle
     */
    function joinQueue(uint256 monId, BattleType battleType) external whenNotPaused nonReentrant {
        require(monNFT.ownerOf(monId) == msg.sender, "Not Mon owner");
        require(!monInBattle[monId], "Mon already in battle");
        require(queuedMon[msg.sender] == 0, "Already in queue");
        
        PlayerStats storage stats = playerStats[msg.sender];
        require(
            block.timestamp >= stats.lastBattleTime + battleCooldown,
            "Cooldown active"
        );
        
        queuedMon[msg.sender] = monId;
        matchQueue[battleType].push(msg.sender);
        
        emit BattleQueued(msg.sender, monId, battleType);
        
        // Try to match immediately
        _tryMatch(battleType);
    }
    
    /**
     * @notice Leave matchmaking queue
     */
    function leaveQueue() external nonReentrant {
        require(queuedMon[msg.sender] != 0, "Not in queue");
        
        // Remove from all queues
        _removeFromQueue(msg.sender, BattleType.QuickBattle);
        _removeFromQueue(msg.sender, BattleType.Ranked);
        
        queuedMon[msg.sender] = 0;
    }
    
    /**
     * @notice Create a wager battle (direct challenge)
     * @param opponentMon Opponent's Mon ID
     * @param myMon My Mon ID
     * @param wagerAmount FROZ wager amount
     */
    function createWagerBattle(
        uint256 opponentMon,
        uint256 myMon,
        uint256 wagerAmount
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(monNFT.ownerOf(myMon) == msg.sender, "Not Mon owner");
        require(!monInBattle[myMon], "Mon already in battle");
        require(wagerAmount > 0, "Must have wager");
        
        address opponent = monNFT.ownerOf(opponentMon);
        require(opponent != msg.sender, "Cannot challenge self");
        
        // Escrow wager
        frozERC20.safeTransferFrom(msg.sender, address(this), wagerAmount);
        
        uint256 battleId = nextBattleId++;
        
        battles[battleId] = Battle({
            player1: msg.sender,
            player2: opponent,
            mon1Id: myMon,
            mon2Id: opponentMon,
            battleType: BattleType.QuickBattle,
            status: BattleStatus.Pending,
            result: BattleResult.None,
            wager: wagerAmount,
            startTime: 0,
            endTime: 0,
            battleHash: bytes32(0)
        });
        
        monInBattle[myMon] = true;
        
        return battleId;
    }
    
    /**
     * @notice Accept a wager battle challenge
     * @param battleId Battle ID
     */
    function acceptWagerBattle(uint256 battleId) external whenNotPaused nonReentrant {
        Battle storage battle = battles[battleId];
        require(battle.status == BattleStatus.Pending, "Invalid status");
        require(battle.player2 == msg.sender, "Not challenged player");
        require(monNFT.ownerOf(battle.mon2Id) == msg.sender, "Not Mon owner");
        require(!monInBattle[battle.mon2Id], "Mon already in battle");
        
        // Escrow opponent's wager
        frozERC20.safeTransferFrom(msg.sender, address(this), battle.wager);
        
        battle.status = BattleStatus.InProgress;
        battle.startTime = block.timestamp;
        monInBattle[battle.mon2Id] = true;
        
        // Generate battle hash for off-chain resolution
        battle.battleHash = keccak256(abi.encodePacked(
            battleId,
            battle.mon1Id,
            battle.mon2Id,
            block.timestamp,
            block.prevrandao
        ));
        
        emit BattleStarted(
            battleId,
            battle.player1,
            battle.player2,
            battle.mon1Id,
            battle.mon2Id,
            battle.battleType
        );
    }
    
    // ============ Battle Resolution ============
    
    /**
     * @notice Submit battle result (only ORACLE_ROLE - off-chain game server)
     * @param battleId Battle ID
     * @param result Battle result
     * @param battleHash Battle verification hash
     */
    function submitBattleResult(
        uint256 battleId,
        BattleResult result,
        bytes32 battleHash
    ) external onlyRole(ORACLE_ROLE) nonReentrant {
        Battle storage battle = battles[battleId];
        require(battle.status == BattleStatus.InProgress, "Invalid status");
        require(battle.battleHash == battleHash, "Hash mismatch");
        require(result != BattleResult.None, "Invalid result");
        
        battle.status = BattleStatus.Completed;
        battle.result = result;
        battle.endTime = block.timestamp;
        
        // Release Mons
        monInBattle[battle.mon1Id] = false;
        monInBattle[battle.mon2Id] = false;
        
        // Update stats and distribute rewards
        _processResult(battleId);
    }
    
    /**
     * @notice Cancel a battle (admin or timeout)
     */
    function cancelBattle(uint256 battleId) external nonReentrant {
        Battle storage battle = battles[battleId];
        require(
            hasRole(OPERATOR_ROLE, msg.sender) ||
            (battle.status == BattleStatus.Pending && block.timestamp > battle.startTime + 10 minutes),
            "Cannot cancel"
        );
        
        battle.status = BattleStatus.Cancelled;
        
        // Release Mons
        monInBattle[battle.mon1Id] = false;
        if (battle.mon2Id != 0) {
            monInBattle[battle.mon2Id] = false;
        }
        
        // Refund wagers
        if (battle.wager > 0) {
            frozERC20.safeTransfer(battle.player1, battle.wager);
            if (battle.player2 != address(0)) {
                frozERC20.safeTransfer(battle.player2, battle.wager);
            }
        }
    }
    
    // ============ Leaderboard & Rankings ============
    
    /**
     * @notice Get player rank (1-indexed, 0 if unranked)
     */
    function getPlayerRank(address player) external view returns (uint256) {
        // Simplified: just return rank points position
        // In production, use off-chain indexing
        return playerStats[player].rankPoints;
    }
    
    /**
     * @notice Get top players (simplified view)
     */
    function getTopPlayers(uint256 count) external view returns (
        address[] memory players,
        uint256[] memory points
    ) {
        // In production, this would use off-chain indexing
        // Simplified on-chain version just returns empty for now
        players = new address[](0);
        points = new uint256[](0);
    }
    
    // ============ Season Management ============
    
    /**
     * @notice Start a new season
     */
    function startNewSeason() external onlyRole(OPERATOR_ROLE) {
        Season storage current = seasons[currentSeason];
        require(block.timestamp >= current.endTime, "Current season not ended");
        
        current.active = false;
        
        currentSeason++;
        seasons[currentSeason] = Season({
            startTime: block.timestamp,
            endTime: block.timestamp + 90 days,
            prizePool: 0,
            active: true
        });
        
        emit SeasonStarted(currentSeason, block.timestamp, block.timestamp + 90 days);
    }
    
    /**
     * @notice Add to season prize pool
     */
    function addToPrizePool(uint256 amount) external {
        frozERC20.safeTransferFrom(msg.sender, address(this), amount);
        seasons[currentSeason].prizePool += amount;
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get battle info
     */
    function getBattle(uint256 battleId) external view returns (Battle memory) {
        return battles[battleId];
    }
    
    /**
     * @notice Get player stats
     */
    function getPlayerStats(address player) external view returns (PlayerStats memory) {
        return playerStats[player];
    }
    
    /**
     * @notice Get queue length
     */
    function getQueueLength(BattleType battleType) external view returns (uint256) {
        return matchQueue[battleType].length;
    }
    
    /**
     * @notice Check if player is in queue
     */
    function isInQueue(address player) external view returns (bool) {
        return queuedMon[player] != 0;
    }
    
    // ============ Internal Functions ============
    
    function _tryMatch(BattleType battleType) internal {
        address[] storage queue = matchQueue[battleType];
        
        if (queue.length >= 2) {
            address player1 = queue[0];
            address player2 = queue[1];
            
            // Remove from queue
            queue[0] = queue[queue.length - 1];
            queue.pop();
            if (queue.length > 0) {
                queue[0] = queue[queue.length - 1];
                queue.pop();
            }
            
            uint256 mon1 = queuedMon[player1];
            uint256 mon2 = queuedMon[player2];
            
            queuedMon[player1] = 0;
            queuedMon[player2] = 0;
            
            // Create battle
            uint256 battleId = nextBattleId++;
            
            bytes32 hash = keccak256(abi.encodePacked(
                battleId,
                mon1,
                mon2,
                block.timestamp,
                block.prevrandao
            ));
            
            battles[battleId] = Battle({
                player1: player1,
                player2: player2,
                mon1Id: mon1,
                mon2Id: mon2,
                battleType: battleType,
                status: BattleStatus.InProgress,
                result: BattleResult.None,
                wager: 0,
                startTime: block.timestamp,
                endTime: 0,
                battleHash: hash
            });
            
            monInBattle[mon1] = true;
            monInBattle[mon2] = true;
            
            emit BattleStarted(battleId, player1, player2, mon1, mon2, battleType);
        }
    }
    
    function _removeFromQueue(address player, BattleType battleType) internal {
        address[] storage queue = matchQueue[battleType];
        for (uint256 i = 0; i < queue.length; i++) {
            if (queue[i] == player) {
                queue[i] = queue[queue.length - 1];
                queue.pop();
                break;
            }
        }
    }
    
    function _processResult(uint256 battleId) internal {
        Battle storage battle = battles[battleId];
        
        address winner;
        address loser;
        uint256 winnerMon;
        uint256 loserMon;
        
        if (battle.result == BattleResult.Player1Win) {
            winner = battle.player1;
            loser = battle.player2;
            winnerMon = battle.mon1Id;
            loserMon = battle.mon2Id;
        } else if (battle.result == BattleResult.Player2Win) {
            winner = battle.player2;
            loser = battle.player1;
            winnerMon = battle.mon2Id;
            loserMon = battle.mon1Id;
        }
        
        // Update player stats
        PlayerStats storage winnerStats = playerStats[winner];
        PlayerStats storage loserStats = playerStats[loser];
        
        uint256 reward;
        
        if (battle.result == BattleResult.Draw) {
            // Draw handling
            playerStats[battle.player1].draws++;
            playerStats[battle.player2].draws++;
            playerStats[battle.player1].winStreak = 0;
            playerStats[battle.player2].winStreak = 0;
            
            // Refund wagers on draw
            if (battle.wager > 0) {
                frozERC20.safeTransfer(battle.player1, battle.wager);
                frozERC20.safeTransfer(battle.player2, battle.wager);
            }
        } else {
            // Win/loss handling
            winnerStats.wins++;
            winnerStats.winStreak++;
            if (winnerStats.winStreak > winnerStats.maxWinStreak) {
                winnerStats.maxWinStreak = winnerStats.winStreak;
            }
            
            loserStats.losses++;
            loserStats.winStreak = 0;
            
            // Rank points
            if (battle.battleType == BattleType.Ranked) {
                winnerStats.rankPoints += rankPointsPerWin;
                if (loserStats.rankPoints >= rankPointsPerLoss) {
                    loserStats.rankPoints -= rankPointsPerLoss;
                }
                
                emit RankUpdated(winner, winnerStats.rankPoints, int256(rankPointsPerWin));
                emit RankUpdated(loser, loserStats.rankPoints, -int256(rankPointsPerLoss));
            }
            
            // Rewards
            if (battle.wager > 0) {
                // Winner takes all wagers
                reward = battle.wager * 2;
                frozERC20.safeTransfer(winner, reward);
            } else {
                // Standard rewards
                if (battle.battleType == BattleType.QuickBattle) {
                    reward = quickBattleReward;
                } else if (battle.battleType == BattleType.Ranked) {
                    reward = rankedWinReward;
                }
                
                // Mint rewards
                frozToken.distributeGameReward(winner, reward, "battle_win");
                frozToken.distributeGameReward(loser, rankedLossReward, "battle_participation");
            }
            
            winnerStats.totalFrozEarned += reward;
            
            // XP rewards
            monNFT.addExperience(winnerMon, uint32(xpPerWin), "battle_win");
            monNFT.addExperience(loserMon, uint32(xpPerLoss), "battle_loss");
        }
        
        // Update last battle time
        playerStats[battle.player1].lastBattleTime = block.timestamp;
        playerStats[battle.player2].lastBattleTime = block.timestamp;
        
        emit BattleCompleted(battleId, winner, battle.result, reward);
    }
    
    // ============ Admin Functions ============
    
    function setRewards(
        uint256 _quickBattleReward,
        uint256 _rankedWinReward,
        uint256 _rankedLossReward
    ) external onlyRole(OPERATOR_ROLE) {
        quickBattleReward = _quickBattleReward;
        rankedWinReward = _rankedWinReward;
        rankedLossReward = _rankedLossReward;
    }
    
    function setXpRewards(uint256 _xpPerWin, uint256 _xpPerLoss) external onlyRole(OPERATOR_ROLE) {
        xpPerWin = _xpPerWin;
        xpPerLoss = _xpPerLoss;
    }
    
    function setCooldown(uint256 _cooldown) external onlyRole(OPERATOR_ROLE) {
        battleCooldown = _cooldown;
    }
    
    function pause() external onlyRole(OPERATOR_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }
}
