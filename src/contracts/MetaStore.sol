// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.12;

import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC1155.sol";
import "@openzeppelin/contracts/interfaces/IERC1155Receiver.sol";
import "@openzeppelin/contracts/interfaces/IERC721Receiver.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title Meta Store
 * @author Fancy Software <fancysoft.eth>
 *
 * Send ERC721 and ERC1155 tokens to this contract to list them for sale
 * (see {onERC721Received}, {onERC1155Received} and {onERC1155BatchReceived}).
 *
 * A new listing is required to have an application address specified.
 * An application is considered eligible for a listing creation
 * if its {appFee} is positive (see {setAppFee}).
 *
 * Ideas:
 *
 * - Accept other tokens as payment (ERC20, ERC1155).
 */
contract MetaStore is IERC721Receiver, IERC1155Receiver {
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
        /// The application which would receive fee (constant).
        address payable app;
        /// Price for a single token (constant).
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

    /// Emitted when an application is registered.
    event SetAppFee(address indexed app, uint8 fee);

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
    event List(
        address operator,
        NFT token,
        address indexed seller,
        address indexed appAddress,
        bytes32 listingId,
        uint256 price,
        uint256 stockSize
    );

    /// Emitted when an existing listing is replenished, or created.
    event Replenish(
        NFT token,
        address indexed appAddress,
        bytes32 indexed listingId,
        address indexed operator,
        uint256 price,
        uint256 amount
    );

    /// Emitted when a token is withdrawn from a listing.
    event Withdraw(
        NFT token,
        address indexed appAddress,
        bytes32 indexed listingId,
        address indexed operator,
        address to,
        uint256 amount
    );

    /// Emitted when a token is purchased.
    event Purchase(
        NFT token,
        bytes32 indexed listingId,
        address indexed buyer,
        uint256 amount,
        uint256 income,
        address royaltyAddress,
        uint256 royaltyValue,
        address indexed appAddress,
        uint256 appFee,
        uint256 profit
    );

    // Mapping from listing ID to its struct.
    mapping(bytes32 => Listing) _listings;

    /**
     * Get an application fee.
     * If zero, the application is not not eligible
     * for listing creation (see {setAppFee}).
     */
    mapping(address => uint8) public appFee;

    /// Get the first (hence primary) listing ID for the given token, if any.
    mapping(address => mapping(uint256 => bytes32)) public primaryListingId;

    /**
     * Set the app fee for the caller, calculated as `fee / 255`.
     * Once set, the fee cannot be changed.
     *
     * @param fee must be non-zero.
     *
     * Emits {SetAppFee} event.
     */
    function setAppFee(uint8 fee) external {
        require(appFee[msg.sender] == 0, "MetaStore: already set fee");
        require(fee > 0, "MetaStore: fee must be non-zero");
        appFee[msg.sender] = fee;
        emit SetAppFee(msg.sender, fee);
    }

    /**
     * Send an ERC721 token to this contract to list it for sale.
     * Listing details are inferred from the transfer, and the `data` argument.
     * Application fee is taken from the actual {appFee} mapping.
     *
     * @param operator becomes the {Listing.seller}.
     * @param data ABI-encoded {ListingConfig} struct.
     *
     * Emits {List} event.
     *
     * @notice Replenishing of an ERC721 listing is not supported.
     */
    function onERC721Received(
        address operator,
        address,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        ListingConfig memory config = abi.decode(data, (ListingConfig));

        // TODO: Change to `from`?
        address seller = operator;
        bytes32 listingId = _listingId(
            msg.sender,
            tokenId,
            seller,
            config.app
        );

        if (_listings[listingId].seller == address(0)) {
            _initListing(
                operator,
                listingId,
                payable(seller),
                msg.sender,
                tokenId,
                1,
                config.price,
                config.app
            );
        } else {
            revert("MetaStore: ERC721 listing already exists");
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
        address,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external override returns (bytes4) {
        ListingConfig memory config = abi.decode(data, (ListingConfig));

        address seller = operator;
        bytes32 listingId = _listingId(msg.sender, id, seller, config.app);

        if (_listings[listingId].app == address(0)) {
            _initListing(
                operator,
                listingId,
                payable(seller),
                msg.sender,
                id,
                value,
                config.price,
                config.app
            );
        } else {
            _replenishListing(
                operator,
                config.app,
                listingId,
                config.price,
                value
            );
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
        address,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external override returns (bytes4) {
        ListingConfig memory config = abi.decode(data, (ListingConfig));
        address seller = operator;

        for (uint256 i = 0; i < ids.length; i++) {
            bytes32 listingId = _listingId(
                msg.sender,
                ids[i],
                seller,
                config.app
            );

            if (_listings[listingId].app == address(0)) {
                _initListing(
                    operator,
                    listingId,
                    payable(seller),
                    msg.sender,
                    ids[i],
                    values[i],
                    config.price,
                    config.app
                );
            } else {
                _replenishListing(
                    operator,
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
     * Purchase a token listed for sale.
     * Emits {Purchase} event.
     */
    function purchase(bytes32 listingId, uint256 amount) external payable {
        Listing storage listing = _listings[listingId];

        require(amount > 0, "MetaStore: amount must be positive");

        require(listing.stockSize >= amount, "MetaStore: insufficient stock");

        require(
            listing.price * amount == msg.value,
            "MetaStore: invalid value"
        );

        unchecked {
            listing.stockSize -= amount;
        }

        uint256 income = msg.value;
        uint256 profit = income;
        address royaltyAddress;
        uint256 royaltyValue;
        uint256 appFee_;

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

        // Then, transfer the application fee.
        if (profit > 0) {
            appFee_ = (profit * appFee[listing.app]) / 255;
            profit -= appFee_;
            listing.app.transfer(appFee_);
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
            profit
        );
    }

    /**
     * Withdraw tokens from a listing.
     * Emits {Withdraw} event.
     */
    function withdraw(
        bytes32 listingId,
        address to,
        uint256 amount
    ) external {
        Listing storage listing = _listings[listingId];

        require(listing.seller == msg.sender, "MetaStore: not the seller");

        require(listing.stockSize >= amount, "MetaStore: insufficient stock");

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

        emit Withdraw(
            listing.token,
            listing.app,
            listingId,
            msg.sender,
            to,
            amount
        );
    }

    /**
     * Get a listing by its ID, calculated as
     * `keccak256(abi.encode(tokenContract, tokenId, seller, app))`.
     * Reverts if the listing does not exist.
     */
    function getListing(bytes32 listingId)
        external
        view
        returns (Listing memory)
    {
        Listing memory listing = _listings[listingId];
        require(listing.app != address(0), "MetaStore: not found");
        return listing;
    }

    function supportsInterface(bytes4 interfaceId)
        external
        pure
        override
        returns (bool)
    {
        return
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == type(IERC721Receiver).interfaceId;
    }

    function _initListing(
        address operator,
        bytes32 listingId,
        address payable seller,
        address tokenContract,
        uint256 tokenId,
        uint256 stockSize,
        uint256 price,
        address payable app
    ) private {
        require(seller != address(0), "MetaStore: zero seller");
        require(appFee[app] > 0, "MetaStore: app not eligible");

        _listings[listingId].seller = seller;
        _listings[listingId].token.contract_ = tokenContract;
        _listings[listingId].token.id = tokenId;
        _listings[listingId].stockSize = stockSize;
        _listings[listingId].price = price;
        _listings[listingId].app = app;

        if (primaryListingId[tokenContract][tokenId] == 0) {
            primaryListingId[tokenContract][tokenId] = listingId;
        }

        emit List(
            operator,
            NFT(tokenContract, tokenId),
            seller,
            app,
            listingId,
            price,
            stockSize
        );
    }

    function _replenishListing(
        address operator,
        address appAddress,
        bytes32 listingId,
        uint256 price,
        uint256 amount
    ) internal {
        _listings[listingId].stockSize += amount;
        _listings[listingId].price = price;

        emit Replenish(
            _listings[listingId].token,
            appAddress,
            listingId,
            operator,
            price,
            amount
        );
    }

    function _isInterface(address contract_, bytes4 interfaceId)
        internal
        view
        returns (bool)
    {
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
