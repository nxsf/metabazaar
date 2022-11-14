// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";

contract ERC1155Dummy is ERC1155, IERC2981 {
    mapping(uint256 => address) public creators;
    mapping(uint256 => uint8) public royalty;

    constructor() ERC1155("") {}

    function mint(
        address account,
        uint256 id,
        uint256 amount,
        bytes memory data,
        uint8 _royalty
    ) public {
        _mint(account, id, amount, data);
        creators[id] = account;
        royalty[id] = _royalty;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IERC2981).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        override(IERC2981)
        returns (address receiver, uint256 royaltyAmount)
    {
        return (
            creators[tokenId],
            (salePrice * royalty[tokenId]) / type(uint8).max
        );
    }
}
