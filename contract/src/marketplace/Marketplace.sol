// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title Marketplace
 * @notice Decentralized marketplace for trading Mons (ERC721) and Items (ERC1155)
 * @dev Supports listings, offers, auctions, and instant swaps with FROZ token
 */
contract Marketplace is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    /// @notice Listing types
    enum ListingType { FixedPrice, Auction }
    
    /// @notice Asset types
    enum AssetType { ERC721, ERC1155 }
    
    /// @notice Listing structure
    struct Listing {
        address seller;
        address assetContract;
        uint256 tokenId;
        uint256 amount;         // 1 for ERC721, variable for ERC1155
        AssetType assetType;
        ListingType listingType;
        uint256 price;          // Fixed price or starting bid
        uint256 endTime;        // 0 for fixed price, timestamp for auction
        bool active;
    }
    
    /// @notice Auction bid structure
    struct Bid {
        address bidder;
        uint256 amount;
        uint256 timestamp;
    }
    
    /// @notice Offer structure (for unlisted items)
    struct Offer {
        address buyer;
        address assetContract;
        uint256 tokenId;
        uint256 amount;         // For ERC1155
        AssetType assetType;
        uint256 price;
        uint256 expiry;
        bool active;
    }
    
    /// @notice FROZ token contract
    IERC20 public immutable frozToken;
    
    /// @notice Treasury for fee collection
    address public treasury;
    
    /// @notice Trading fee in basis points (50 = 0.5%)
    uint256 public tradingFeeBps = 50;
    
    /// @notice Fee distribution: stakers get this %, rest goes to treasury
    uint256 public stakerFeeBps = 20; // 0.2% to stakers, 0.3% to treasury
    
    /// @notice Staking contract for fee distribution
    address public stakingContract;
    
    /// @notice Burn percentage of fees (10 = 10% of fees burned)
    uint256 public burnPercentage = 10;
    
    /// @notice Next listing ID
    uint256 public nextListingId = 1;
    
    /// @notice Next offer ID
    uint256 public nextOfferId = 1;
    
    /// @notice Mapping from listing ID to Listing
    mapping(uint256 => Listing) public listings;
    
    /// @notice Mapping from listing ID to highest bid
    mapping(uint256 => Bid) public highestBids;
    
    /// @notice Mapping from offer ID to Offer
    mapping(uint256 => Offer) public offers;
    
    /// @notice Mapping from asset contract + token ID + seller to listing ID
    mapping(address => mapping(uint256 => mapping(address => uint256))) public activeListings;
    
    /// @notice Approved asset contracts (Mon NFT, Game Items, etc.)
    mapping(address => bool) public approvedContracts;
    
    /// @notice Events
    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        address assetContract,
        uint256 tokenId,
        uint256 amount,
        uint256 price,
        ListingType listingType
    );
    
    event ListingCancelled(uint256 indexed listingId, address indexed seller);
    
    event Sale(
        uint256 indexed listingId,
        address indexed seller,
        address indexed buyer,
        uint256 price,
        uint256 fee
    );
    
    event BidPlaced(
        uint256 indexed listingId,
        address indexed bidder,
        uint256 amount
    );
    
    event AuctionEnded(
        uint256 indexed listingId,
        address indexed winner,
        uint256 finalPrice
    );
    
    event OfferCreated(
        uint256 indexed offerId,
        address indexed buyer,
        address assetContract,
        uint256 tokenId,
        uint256 price
    );
    
    event OfferAccepted(
        uint256 indexed offerId,
        address indexed seller,
        address indexed buyer,
        uint256 price
    );
    
    event OfferCancelled(uint256 indexed offerId, address indexed buyer);
    
    constructor(
        address _frozToken,
        address _treasury,
        address _admin
    ) {
        require(_frozToken != address(0), "Invalid FROZ");
        require(_treasury != address(0), "Invalid treasury");
        require(_admin != address(0), "Invalid admin");
        
        frozToken = IERC20(_frozToken);
        treasury = _treasury;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
    }
    
    // ============ Listing Functions ============
    
    /**
     * @notice Create a fixed-price listing
     * @param assetContract NFT contract address
     * @param tokenId Token ID
     * @param amount Amount (1 for ERC721)
     * @param assetType ERC721 or ERC1155
     * @param price Price in FROZ
     */
    function createListing(
        address assetContract,
        uint256 tokenId,
        uint256 amount,
        AssetType assetType,
        uint256 price
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(approvedContracts[assetContract], "Contract not approved");
        require(price > 0, "Price must be > 0");
        require(amount > 0, "Amount must be > 0");
        
        if (assetType == AssetType.ERC721) {
            require(amount == 1, "ERC721 amount must be 1");
            IERC721 nft = IERC721(assetContract);
            require(nft.ownerOf(tokenId) == msg.sender, "Not owner");
            require(
                nft.isApprovedForAll(msg.sender, address(this)) ||
                nft.getApproved(tokenId) == address(this),
                "Not approved"
            );
        } else {
            IERC1155 items = IERC1155(assetContract);
            require(items.balanceOf(msg.sender, tokenId) >= amount, "Insufficient balance");
            require(items.isApprovedForAll(msg.sender, address(this)), "Not approved");
        }
        
        uint256 listingId = nextListingId++;
        
        listings[listingId] = Listing({
            seller: msg.sender,
            assetContract: assetContract,
            tokenId: tokenId,
            amount: amount,
            assetType: assetType,
            listingType: ListingType.FixedPrice,
            price: price,
            endTime: 0,
            active: true
        });
        
        activeListings[assetContract][tokenId][msg.sender] = listingId;
        
        emit ListingCreated(listingId, msg.sender, assetContract, tokenId, amount, price, ListingType.FixedPrice);
        
        return listingId;
    }
    
    /**
     * @notice Create an auction listing
     * @param assetContract NFT contract address
     * @param tokenId Token ID
     * @param amount Amount (1 for ERC721)
     * @param assetType ERC721 or ERC1155
     * @param startingPrice Starting bid price
     * @param duration Auction duration in seconds
     */
    function createAuction(
        address assetContract,
        uint256 tokenId,
        uint256 amount,
        AssetType assetType,
        uint256 startingPrice,
        uint256 duration
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(approvedContracts[assetContract], "Contract not approved");
        require(startingPrice > 0, "Price must be > 0");
        require(duration >= 1 hours && duration <= 30 days, "Invalid duration");
        
        if (assetType == AssetType.ERC721) {
            require(amount == 1, "ERC721 amount must be 1");
            IERC721 nft = IERC721(assetContract);
            require(nft.ownerOf(tokenId) == msg.sender, "Not owner");
            require(
                nft.isApprovedForAll(msg.sender, address(this)) ||
                nft.getApproved(tokenId) == address(this),
                "Not approved"
            );
            // Transfer to marketplace for escrow
            nft.transferFrom(msg.sender, address(this), tokenId);
        } else {
            IERC1155 items = IERC1155(assetContract);
            require(items.balanceOf(msg.sender, tokenId) >= amount, "Insufficient balance");
            require(items.isApprovedForAll(msg.sender, address(this)), "Not approved");
            // Transfer to marketplace for escrow
            items.safeTransferFrom(msg.sender, address(this), tokenId, amount, "");
        }
        
        uint256 listingId = nextListingId++;
        
        listings[listingId] = Listing({
            seller: msg.sender,
            assetContract: assetContract,
            tokenId: tokenId,
            amount: amount,
            assetType: assetType,
            listingType: ListingType.Auction,
            price: startingPrice,
            endTime: block.timestamp + duration,
            active: true
        });
        
        activeListings[assetContract][tokenId][msg.sender] = listingId;
        
        emit ListingCreated(listingId, msg.sender, assetContract, tokenId, amount, startingPrice, ListingType.Auction);
        
        return listingId;
    }
    
    /**
     * @notice Buy a fixed-price listing
     * @param listingId Listing ID
     */
    function buy(uint256 listingId) external whenNotPaused nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.active, "Listing not active");
        require(listing.listingType == ListingType.FixedPrice, "Not fixed price");
        require(listing.seller != msg.sender, "Cannot buy own listing");
        
        uint256 price = listing.price;
        uint256 fee = (price * tradingFeeBps) / 10000;
        
        // Transfer FROZ from buyer
        frozToken.safeTransferFrom(msg.sender, address(this), price);
        
        // Distribute fees
        _distributeFees(fee);
        
        // Transfer remaining to seller
        frozToken.safeTransfer(listing.seller, price - fee);
        
        // Transfer asset to buyer
        _transferAsset(listing, msg.sender);
        
        // Mark listing as inactive
        listing.active = false;
        delete activeListings[listing.assetContract][listing.tokenId][listing.seller];
        
        emit Sale(listingId, listing.seller, msg.sender, price, fee);
    }
    
    /**
     * @notice Place a bid on an auction
     * @param listingId Listing ID
     * @param bidAmount Bid amount in FROZ
     */
    function placeBid(uint256 listingId, uint256 bidAmount) external whenNotPaused nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.active, "Listing not active");
        require(listing.listingType == ListingType.Auction, "Not an auction");
        require(block.timestamp < listing.endTime, "Auction ended");
        require(listing.seller != msg.sender, "Cannot bid on own auction");
        
        Bid storage currentBid = highestBids[listingId];
        require(bidAmount >= listing.price, "Below starting price");
        require(bidAmount > currentBid.amount, "Bid too low");
        
        // Refund previous bidder
        if (currentBid.bidder != address(0)) {
            frozToken.safeTransfer(currentBid.bidder, currentBid.amount);
        }
        
        // Take new bid
        frozToken.safeTransferFrom(msg.sender, address(this), bidAmount);
        
        highestBids[listingId] = Bid({
            bidder: msg.sender,
            amount: bidAmount,
            timestamp: block.timestamp
        });
        
        emit BidPlaced(listingId, msg.sender, bidAmount);
    }
    
    /**
     * @notice End an auction and transfer to winner
     * @param listingId Listing ID
     */
    function endAuction(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.active, "Listing not active");
        require(listing.listingType == ListingType.Auction, "Not an auction");
        require(block.timestamp >= listing.endTime, "Auction not ended");
        
        Bid storage winningBid = highestBids[listingId];
        
        if (winningBid.bidder != address(0)) {
            uint256 fee = (winningBid.amount * tradingFeeBps) / 10000;
            
            // Distribute fees
            _distributeFees(fee);
            
            // Transfer to seller
            frozToken.safeTransfer(listing.seller, winningBid.amount - fee);
            
            // Transfer asset to winner
            _transferAssetFromEscrow(listing, winningBid.bidder);
            
            emit AuctionEnded(listingId, winningBid.bidder, winningBid.amount);
            emit Sale(listingId, listing.seller, winningBid.bidder, winningBid.amount, fee);
        } else {
            // No bids - return asset to seller
            _transferAssetFromEscrow(listing, listing.seller);
            emit AuctionEnded(listingId, address(0), 0);
        }
        
        listing.active = false;
        delete activeListings[listing.assetContract][listing.tokenId][listing.seller];
    }
    
    /**
     * @notice Cancel a listing (only seller or admin)
     * @param listingId Listing ID
     */
    function cancelListing(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.active, "Listing not active");
        require(
            listing.seller == msg.sender || hasRole(OPERATOR_ROLE, msg.sender),
            "Not authorized"
        );
        
        if (listing.listingType == ListingType.Auction) {
            require(highestBids[listingId].bidder == address(0), "Cannot cancel with bids");
            // Return escrowed asset
            _transferAssetFromEscrow(listing, listing.seller);
        }
        
        listing.active = false;
        delete activeListings[listing.assetContract][listing.tokenId][listing.seller];
        
        emit ListingCancelled(listingId, listing.seller);
    }
    
    // ============ Offer Functions ============
    
    /**
     * @notice Create an offer for an unlisted item
     * @param assetContract NFT contract address
     * @param tokenId Token ID
     * @param amount Amount (1 for ERC721)
     * @param assetType ERC721 or ERC1155
     * @param price Offer price in FROZ
     * @param duration Offer duration in seconds
     */
    function createOffer(
        address assetContract,
        uint256 tokenId,
        uint256 amount,
        AssetType assetType,
        uint256 price,
        uint256 duration
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(approvedContracts[assetContract], "Contract not approved");
        require(price > 0, "Price must be > 0");
        require(duration >= 1 hours && duration <= 30 days, "Invalid duration");
        
        // Escrow FROZ
        frozToken.safeTransferFrom(msg.sender, address(this), price);
        
        uint256 offerId = nextOfferId++;
        
        offers[offerId] = Offer({
            buyer: msg.sender,
            assetContract: assetContract,
            tokenId: tokenId,
            amount: amount,
            assetType: assetType,
            price: price,
            expiry: block.timestamp + duration,
            active: true
        });
        
        emit OfferCreated(offerId, msg.sender, assetContract, tokenId, price);
        
        return offerId;
    }
    
    /**
     * @notice Accept an offer (asset owner)
     * @param offerId Offer ID
     */
    function acceptOffer(uint256 offerId) external whenNotPaused nonReentrant {
        Offer storage offer = offers[offerId];
        require(offer.active, "Offer not active");
        require(block.timestamp < offer.expiry, "Offer expired");
        
        // Verify ownership and approval
        if (offer.assetType == AssetType.ERC721) {
            IERC721 nft = IERC721(offer.assetContract);
            require(nft.ownerOf(offer.tokenId) == msg.sender, "Not owner");
            require(
                nft.isApprovedForAll(msg.sender, address(this)) ||
                nft.getApproved(offer.tokenId) == address(this),
                "Not approved"
            );
            // Transfer NFT to buyer
            nft.transferFrom(msg.sender, offer.buyer, offer.tokenId);
        } else {
            IERC1155 items = IERC1155(offer.assetContract);
            require(items.balanceOf(msg.sender, offer.tokenId) >= offer.amount, "Insufficient balance");
            require(items.isApprovedForAll(msg.sender, address(this)), "Not approved");
            // Transfer items to buyer
            items.safeTransferFrom(msg.sender, offer.buyer, offer.tokenId, offer.amount, "");
        }
        
        uint256 fee = (offer.price * tradingFeeBps) / 10000;
        
        // Distribute fees
        _distributeFees(fee);
        
        // Transfer to seller
        frozToken.safeTransfer(msg.sender, offer.price - fee);
        
        offer.active = false;
        
        emit OfferAccepted(offerId, msg.sender, offer.buyer, offer.price);
    }
    
    /**
     * @notice Cancel an offer (buyer only)
     * @param offerId Offer ID
     */
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = offers[offerId];
        require(offer.active, "Offer not active");
        require(offer.buyer == msg.sender, "Not offer owner");
        
        // Refund escrowed FROZ
        frozToken.safeTransfer(msg.sender, offer.price);
        
        offer.active = false;
        
        emit OfferCancelled(offerId, msg.sender);
    }
    
    // ============ Admin Functions ============
    
    function setApprovedContract(address contractAddress, bool approved) external onlyRole(OPERATOR_ROLE) {
        approvedContracts[contractAddress] = approved;
    }
    
    function setTradingFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFeeBps <= 500, "Fee too high"); // Max 5%
        tradingFeeBps = newFeeBps;
    }
    
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), "Invalid treasury");
        treasury = newTreasury;
    }
    
    function setStakingContract(address _stakingContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stakingContract = _stakingContract;
    }
    
    function pause() external onlyRole(OPERATOR_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }
    
    // ============ Internal Functions ============
    
    function _distributeFees(uint256 fee) internal {
        if (fee == 0) return;
        
        // Burn portion
        uint256 burnAmount = (fee * burnPercentage) / 100;
        if (burnAmount > 0) {
            // Transfer to dead address (or call burn if token supports it)
            frozToken.safeTransfer(address(0xdead), burnAmount);
        }
        
        uint256 remaining = fee - burnAmount;
        
        // Staker portion
        uint256 stakerAmount = (remaining * stakerFeeBps) / tradingFeeBps;
        if (stakerAmount > 0 && stakingContract != address(0)) {
            frozToken.safeTransfer(stakingContract, stakerAmount);
        } else {
            stakerAmount = 0;
        }
        
        // Treasury gets the rest
        uint256 treasuryAmount = remaining - stakerAmount;
        if (treasuryAmount > 0) {
            frozToken.safeTransfer(treasury, treasuryAmount);
        }
    }
    
    function _transferAsset(Listing storage listing, address to) internal {
        if (listing.assetType == AssetType.ERC721) {
            IERC721(listing.assetContract).transferFrom(listing.seller, to, listing.tokenId);
        } else {
            IERC1155(listing.assetContract).safeTransferFrom(
                listing.seller,
                to,
                listing.tokenId,
                listing.amount,
                ""
            );
        }
    }
    
    function _transferAssetFromEscrow(Listing storage listing, address to) internal {
        if (listing.assetType == AssetType.ERC721) {
            IERC721(listing.assetContract).transferFrom(address(this), to, listing.tokenId);
        } else {
            IERC1155(listing.assetContract).safeTransferFrom(
                address(this),
                to,
                listing.tokenId,
                listing.amount,
                ""
            );
        }
    }
    
    // Required to receive ERC1155
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }
    
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}
