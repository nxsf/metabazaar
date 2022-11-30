// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC1155.sol";
import "@openzeppelin/contracts/interfaces/IERC1155Receiver.sol";
import "@openzeppelin/contracts/interfaces/IERC721Receiver.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Open Store
 * @author Interplanetary Org
 *
 * Send ERC721 and ERC1155 tokens to this contract to list them for sale
 * (see {onERC721Received}, {onERC1155Received} and {onERC1155BatchReceived}).
 *
 * A listing has its target application, which is responsible for rendering
 * the listing in some sort of UI. An application must be explicitly
 * {isAppEnabled} and {isAppActive} for new listings to be created for it,
 * as well as existing listings to be purchased and replenished.
 *
 * An app may {setIsSellerApprovalRequired}.
 * In that case, a seller must be explicitly set {isSellerApproved},
 * which is however only required for the first (hence primary) listing
 * of a particular token for a particular application (see {primaryListingId}).
 * Subsequent, that is, secondary, listings of the same token
 * for the same application will not require any seller approval.
 */
contract OpenStore is IERC721Receiver, IERC1155Receiver, Ownable {
    /// An ERC721 or ERC1155 token configuration.
    struct NFT {
        address contract_;
        uint256 id;
    }

    /**
     * Listing configuration is passed upon listing creation or replenishment
     * encoded as the `data` argument of {onERC721Received},
     * {onERC1155Received} and {onERC1155BatchReceived}.
     */
    struct ListingConfig {
        /// The listing seller; must be approved for the target application.
        address payable seller;
        /// The target application.
        address payable app;
        /// Price for a single token.
        uint256 price;
    }

    /// A listing data structure.
    struct Listing {
        /// The listed token (constant).
        NFT token;
        /// The listing seller address (constant).
        address payable seller;
        /// The application which would receive {appFee} (constant).
        address payable app;
        /// Price for a single token (mutable).
        uint256 price;
        /// Current {token} balance of the listing, in wei (mutable).
        uint256 stockSize;
    }

    /// Emitted on {setAppEnabled}.
    event SetAppEnabled(address indexed app, bool enabled);

    /// Emitted on {setAppActive}.
    event SetAppActive(address indexed app, bool active);

    /// Emitted on {setAppFee}.
    event SetAppFee(address indexed app, uint8 fee);

    /// Emitted on {setAppGratitude}.
    event SetAppGratitude(address indexed app, uint8 gratitude);

    /// Emitted on {setIsSellerApprovalRequired}.
    event SetIsSellerApprovalRequired(address indexed app, bool required);

    /// Emitted on {setSellerApproved}.
    event SetSellerApproved(
        address indexed app,
        address indexed seller,
        bool approved
    );

    /**
     * Emitted when a listing is created.
     *
     * @notice A listing ID is calculated as `keccak256(abi.encode(
     * token.contract_,
     * token.id,
     * seller,
     * appAddress
     * ))`.
     */
    event List(NFT token, address indexed seller, address indexed appAddress);

    /// Emitted when an existing listing is replenished, or created.
    event Replenish(
        NFT token, // ADHOC: Excessive information.
        address indexed appAddress,
        bytes32 indexed listingId,
        uint256 price,
        uint256 amount
    );

    /// Emitted when a token is {withdraw}n from a listing.
    event Withdraw(
        NFT token, // ADHOC: Excessive information.
        address indexed appAddress,
        bytes32 indexed listingId,
        address to,
        uint256 amount
    );

    /// Emitted when a token is {purchase}d.
    event Purchase(
        NFT token, // ADHOC: Excessive information.
        bytes32 indexed listingId,
        address indexed buyer,
        uint256 amount,
        uint256 income,
        address royaltyAddress,
        uint256 royaltyValue,
        address indexed appAddress,
        uint256 appFee,
        uint256 appGratitude,
        uint256 profit
    );

    // Mapping from listing ID to its struct.
    mapping(bytes32 => Listing) _listings;

    /**
     * Return true if an application is enabled (controlled by the contract owner).
     * A disabled application is not eligible for listing creation.
     */
    mapping(address => bool) public isAppEnabled;

    /**
     * Return true if an application is active (controlled by the application).
     * An inactive application is not eligible for listing creation.
     */
    mapping(address => bool) public isAppActive;

    /// Get an application fee.
    mapping(address => uint8) public appFee;

    /**
     * A caller application may choose to transfer a portion
     * of its income to the contract owner.
     */
    mapping(address => uint8) public appGratitude;

    /// Return true if a seller approval is required for a particular application.
    mapping(address => bool) public isSellerApprovalRequired;

    // @dev app => (seller => approved).
    mapping(address => mapping(address => bool)) _sellerApprovals;

    // @dev app => (token contract => (token id => listing id)).
    mapping(address => mapping(address => mapping(uint256 => bytes32))) _primaryListingId;

    /**
     * Set whether an `app` is `enabled`.
     * Only the contract {owner} may enable an application.
     * Emits {SetAppEnabled} event.
     */
    function setAppEnabled(address app, bool enabled) external onlyOwner {
        require(isAppEnabled[app] != enabled, "OpenStore: already set");
        isAppEnabled[app] = enabled;
        emit SetAppEnabled(app, enabled);
    }

    /**
     * Set whether the caller application is `active`.
     * Only the application itself may set its activity.
     * Emits {SetAppActive} event.
     */
    function setAppActive(bool active) external {
        require(isAppActive[msg.sender] != active, "OpenStore: already set");
        isAppActive[msg.sender] = active;
        emit SetAppActive(msg.sender, active);
    }

    /**
     * Set the fee for the caller application, calculated as `fee / 255`.
     * Emits {SetAppFee} event.
     */
    function setAppFee(uint8 fee) external {
        appFee[msg.sender] = fee;
        emit SetAppFee(msg.sender, fee);
    }

    /**
     * Set gratitude for the caller application.
     * Emits {SetAppGratitude}.
     */
    function setAppGratitude(uint8 value) external {
        appGratitude[msg.sender] = value;
        emit SetAppGratitude(msg.sender, value);
    }

    /**
     * Set whether a seller approval is required for the caller application.
     * Emits {SetIsSellerApprovalRequired} event.
     */
    function setIsSellerApprovalRequired(bool required) external {
        require(
            isSellerApprovalRequired[msg.sender] != required,
            "OpenStore: already set"
        );

        isSellerApprovalRequired[msg.sender] = required;
        emit SetIsSellerApprovalRequired(msg.sender, required);
    }

    /**
     * Set whether `seller` is approved for the caller application.
     * Emits {SetSellerApproved}.
     */
    function setSellerApproved(address seller, bool approved) external {
        require(
            _sellerApprovals[msg.sender][seller] != approved,
            "OpenStore: already set"
        );

        _sellerApprovals[msg.sender][seller] = approved;
        emit SetSellerApproved(msg.sender, seller, approved);
    }

    /**
     * Send an ERC721 token to this contract to list it for sale.
     * Listing details are inferred from the transfer, and the `data` argument.
     * The seller is taken from the `data` argument; it must be either `operator`
     * or `from`.
     *
     * @param data ABI-encoded {ListingConfig} struct.
     *
     * Emits {List} and {Replenish} events.
     *
     * @notice Replenishing of an ERC721 listing is only usually possible
     * after a withdrawal (see {withdraw}).
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        ListingConfig memory config = abi.decode(data, (ListingConfig));

        address payable seller = config.seller;
        require(
            seller == operator || seller == from,
            "OpenStore: invalid seller"
        );

        bytes32 listingId = _listingId(
            msg.sender,
            tokenId,
            seller,
            config.app
        );

        if (_listings[listingId].seller == address(0)) {
            _initListing(
                listingId,
                seller,
                msg.sender,
                tokenId,
                1,
                config.price,
                config.app
            );
        } else {
            _replenishListing(config.app, listingId, config.price, 1);
        }

        return IERC721Receiver.onERC721Received.selector;
    }

    /**
     * Send an ERC1155 token to this contract to list it for sale.
     * See {onERC721Received} for details.
     * Emits {List} or {Replenish} event.
     */
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external override returns (bytes4) {
        ListingConfig memory config = abi.decode(data, (ListingConfig));

        address payable seller = config.seller;
        require(
            seller == operator || seller == from,
            "OpenStore: invalid seller"
        );

        bytes32 listingId = _listingId(msg.sender, id, seller, config.app);

        if (_listings[listingId].app == address(0)) {
            _initListing(
                listingId,
                seller,
                msg.sender,
                id,
                value,
                config.price,
                config.app
            );
        } else {
            _replenishListing(config.app, listingId, config.price, value);
        }

        return IERC1155Receiver.onERC1155Received.selector;
    }

    /**
     * Send a batch of ERC1155 tokens to this contract to list them for sale.
     * See {onERC721Received} for details.
     * Emits {List} or {Replenish} events.
     */
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external override returns (bytes4) {
        ListingConfig memory config = abi.decode(data, (ListingConfig));

        address payable seller = config.seller;
        require(
            seller == operator || seller == from,
            "OpenStore: invalid seller"
        );

        for (uint256 i = 0; i < ids.length; i++) {
            bytes32 listingId = _listingId(
                msg.sender,
                ids[i],
                seller,
                config.app
            );

            if (_listings[listingId].app == address(0)) {
                _initListing(
                    listingId,
                    seller,
                    msg.sender,
                    ids[i],
                    values[i],
                    config.price,
                    config.app
                );
            } else {
                _replenishListing(
                    config.app,
                    listingId,
                    config.price,
                    values[i]
                );
            }
        }

        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    /**
     * Purchase a token previously listed for sale.
     * Emits {Purchase} event.
     */
    function purchase(bytes32 listingId, uint256 amount) external payable {
        Listing storage listing = _listings[listingId];

        require(isAppEnabled[listing.app], "OpenStore: app not enabled");
        require(isAppActive[listing.app], "OpenStore: app not active");
        require(amount > 0, "OpenStore: amount must be positive");
        require(listing.stockSize >= amount, "OpenStore: insufficient stock");

        require(
            listing.price * amount == msg.value,
            "OpenStore: invalid value"
        );

        unchecked {
            listing.stockSize -= amount;
        }

        uint256 income = msg.value;
        uint256 profit = income;
        address royaltyAddress;
        uint256 royaltyValue;
        uint256 appFee_;
        uint256 appGragitude_;

        // Royalties are top priority for healthy economy.
        if (
            _isInterface(
                address(listing.token.contract_),
                type(IERC2981).interfaceId
            )
        ) {
            (royaltyAddress, royaltyValue) = IERC2981(
                address(listing.token.contract_)
            ).royaltyInfo(listing.token.id, profit);

            if (royaltyAddress != listing.seller && royaltyValue > 0) {
                profit -= royaltyValue;
                payable(royaltyAddress).transfer(royaltyValue);
            }
        }

        // Then, transfer the application and base fees.
        if (profit > 0) {
            appFee_ = (profit * appFee[listing.app]) / 255;
            appGragitude_ = (appFee_ * appGratitude[listing.app]) / 255;

            unchecked {
                profit -= appFee_;
                appFee_ -= appGragitude_;
            }

            if (appGragitude_ > 0) {
                payable(owner()).transfer(appGragitude_);
            }

            if (appFee_ > 0) {
                listing.app.transfer(appFee_);
            }
        }

        // Transfer what's left to the seller.
        if (profit > 0) {
            listing.seller.transfer(profit);
        }

        // Then transfer the NFTs to the buyer.
        if (
            _isInterface(
                address(listing.token.contract_),
                type(IERC721).interfaceId
            )
        ) {
            IERC721(listing.token.contract_).safeTransferFrom(
                address(this),
                msg.sender,
                listing.token.id,
                ""
            );
        } else if (
            _isInterface(
                address(listing.token.contract_),
                type(IERC1155).interfaceId
            )
        ) {
            IERC1155(listing.token.contract_).safeTransferFrom(
                address(this),
                msg.sender,
                listing.token.id,
                amount,
                ""
            );
        }

        // Finally, emit the event.
        emit Purchase(
            listing.token,
            listingId,
            msg.sender,
            amount,
            income,
            royaltyAddress,
            royaltyValue,
            listing.app,
            appFee_,
            appGragitude_,
            profit
        );
    }

    /**
     * Withdraw tokens from a listing.
     * Emits {Withdraw} event.
     */
    function withdraw(bytes32 listingId, address to, uint256 amount) external {
        Listing storage listing = _listings[listingId];

        require(listing.seller == msg.sender, "OpenStore: not the seller");

        require(listing.stockSize >= amount, "OpenStore: insufficient stock");

        unchecked {
            listing.stockSize -= amount;
        }

        if (
            _isInterface(
                address(listing.token.contract_),
                type(IERC721).interfaceId
            )
        ) {
            IERC721(listing.token.contract_).safeTransferFrom(
                address(this),
                to,
                listing.token.id,
                ""
            );
        } else if (
            _isInterface(
                address(listing.token.contract_),
                type(IERC1155).interfaceId
            )
        ) {
            IERC1155(listing.token.contract_).safeTransferFrom(
                address(this),
                to,
                listing.token.id,
                amount,
                ""
            );
        }

        emit Withdraw(listing.token, listing.app, listingId, to, amount);
    }

    /**
     * Returns true if the `seller` is approved for the `app`.
     */
    function isSellerApproved(
        address app,
        address seller
    ) public view returns (bool) {
        return _sellerApprovals[app][seller];
    }

    /**
     * Get a listing by its ID, calculated as
     * `keccak256(abi.encode(tokenContract, tokenId, seller, app))`.
     * Reverts if the listing does not exist.
     */
    function getListing(
        bytes32 listingId
    ) external view returns (Listing memory) {
        Listing memory listing = _listings[listingId];
        require(listing.app != address(0), "OpenStore: not found");
        return listing;
    }

    /**
     * Get the first (hence primary) listing ID
     * for the given token per appliation, if any.
     */
    function primaryListingId(
        address app,
        address tokenContract,
        uint256 tokenId
    ) external view returns (bytes32) {
        return _primaryListingId[app][tokenContract][tokenId];
    }

    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == type(IERC721Receiver).interfaceId;
    }

    function _initListing(
        bytes32 listingId,
        address payable seller,
        address tokenContract,
        uint256 tokenId,
        uint256 stockSize,
        uint256 price,
        address payable app
    ) private {
        require(isAppEnabled[app], "OpenStore: app not enabled");
        require(isAppActive[app], "OpenStore: app not active");

        if (_primaryListingId[app][tokenContract][tokenId] == 0) {
            require(
                !isSellerApprovalRequired[app] ||
                    isSellerApproved(app, seller),
                "OpenStore: seller not approved"
            );

            _primaryListingId[app][tokenContract][tokenId] = listingId;
        } else {
            // For secondary listings, there are no any seller restrictions.
        }

        _listings[listingId].seller = seller;
        _listings[listingId].token.contract_ = tokenContract;
        _listings[listingId].token.id = tokenId;
        _listings[listingId].stockSize = stockSize;
        _listings[listingId].price = price;
        _listings[listingId].app = app;

        emit List(NFT(tokenContract, tokenId), seller, app);

        emit Replenish(
            _listings[listingId].token,
            app,
            listingId,
            price,
            stockSize
        );
    }

    function _replenishListing(
        address appAddress,
        bytes32 listingId,
        uint256 price,
        uint256 amount
    ) internal {
        require(isAppEnabled[appAddress], "OpenStore: app not enabled");
        require(isAppActive[appAddress], "OpenStore: app not active");

        _listings[listingId].stockSize += amount;
        _listings[listingId].price = price;

        emit Replenish(
            _listings[listingId].token,
            appAddress,
            listingId,
            price,
            amount
        );
    }

    function _isInterface(
        address contract_,
        bytes4 interfaceId
    ) internal view returns (bool) {
        return IERC165(contract_).supportsInterface(interfaceId);
    }

    function _listingId(
        address tokenContract,
        uint256 tokenId,
        address seller,
        address app
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(tokenContract, tokenId, seller, app));
    }
}
