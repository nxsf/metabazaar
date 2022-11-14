import { expect, use } from "chai";
import { deployContract, MockProvider, solidity } from "ethereum-waffle";
import ERC1155DummyABI from "../../waffle/ERC1155Dummy.json";
import { Erc1155Dummy } from "../../waffle/types/Erc1155Dummy";
import NFTSimpleListingABI from "../../waffle/NFTSimpleListing.json";
import { NftSimpleListing } from "../../waffle/types/NftSimpleListing";
import { BigNumber, BigNumberish, BytesLike, ethers } from "ethers";
import { keccak256 } from "@ethersproject/keccak256";

class ListingConfig {
  price: BigNumberish;
  app: string;

  constructor(price: BigNumberish, app: string) {
    this.price = price;
    this.app = app;
  }

  toBytes(): BytesLike {
    return ethers.utils.defaultAbiCoder.encode(
      ["address", "uint256"],
      [this.app.toString(), this.price]
    );
  }
}

use(solidity);

describe("NFTSimpleListing", async () => {
  const [w0, w1, w2, app] = new MockProvider().getWallets();

  let erc1155Dummy: Erc1155Dummy;
  let nftSimpleListing: NftSimpleListing;

  before(async () => {
    erc1155Dummy = (await deployContract(w0, ERC1155DummyABI)) as Erc1155Dummy;

    nftSimpleListing = (await deployContract(
      w0,
      NFTSimpleListingABI
    )) as NftSimpleListing;
  });

  describe("listing", () => {
    before(async () => {
      // Mint 50 tokens for w0.
      await erc1155Dummy.mint(w0.address, 1, 50, [], 10);

      // Transfer 40 tokens to w1.
      await erc1155Dummy.safeTransferFrom(w0.address, w1.address, 1, 40, []);
    });

    describe("requires app to be eligible", () => {
      it("should fail", async () => {
        await expect(
          erc1155Dummy
            .connect(w1)
            .safeTransferFrom(
              w1.address,
              nftSimpleListing.address,
              1,
              10,
              new ListingConfig(
                ethers.utils.parseEther("0.25"),
                app.address
              ).toBytes()
            )
        ).to.be.revertedWith("NFTSimpleListing: app not eligible");
      });
    });

    describe("when app is eligible", () => {
      before(async () => {
        await expect(nftSimpleListing.connect(app).setAppFee(5))
          .to.emit(nftSimpleListing, "SetAppFee")
          .withArgs(app.address, 5);
      });

      it("should list NFT", async () => {
        const _listingId = listingId(
          erc1155Dummy.address,
          1,
          w1.address,
          app.address
        );

        await expect(
          erc1155Dummy
            .connect(w1)
            .safeTransferFrom(
              w1.address,
              nftSimpleListing.address,
              1,
              10,
              new ListingConfig(
                ethers.utils.parseEther("0.25"),
                app.address
              ).toBytes()
            )
        )
          .to.emit(nftSimpleListing, "List")
          .withArgs(
            w1.address,
            [erc1155Dummy.address, 1],
            w1.address,
            app.address,
            _listingId,
            ethers.utils.parseEther("0.25"),
            10
          );

        const listing = await nftSimpleListing.getListing(_listingId);

        expect(listing.seller).to.be.eq(w1.address);
        expect(listing.token.contract_).to.be.eq(erc1155Dummy.address);
        expect(listing.token.id).to.be.eq(1);
        expect(listing.stockSize).to.be.eq(10);
        expect(listing.price).to.be.eq(ethers.utils.parseEther("0.25"));
        expect(listing.app).to.be.eq(app.address);
      });
    });
  });

  describe("purchasing", () => {
    describe("when value is less than required", () => {
      it("should fail", async () => {
        await expect(
          nftSimpleListing
            .connect(w2)
            .purchase(
              listingId(erc1155Dummy.address, 1, w1.address, app.address),
              2,
              { value: ethers.utils.parseEther("0.49") }
            )
        ).to.be.revertedWith("NFTSimpleListing: invalid value");
      });
    });

    describe("when the eth value is greater than required", () => {
      it("should fail", async () => {
        await expect(
          nftSimpleListing
            .connect(w2)
            .purchase(
              listingId(erc1155Dummy.address, 1, w1.address, app.address),
              2,
              { value: ethers.utils.parseEther("0.51") }
            )
        ).to.be.revertedWith("NFTSimpleListing: invalid value");
      });
    });

    it("should purchase NFT", async () => {
      // app receives app fee.
      const appBalanceBefore = await app.getBalance();

      // w0 is royalty recipient.
      const w0BalanceBefore = await w0.getBalance();

      // w1 is seller.
      const w1BalanceBefore = await w1.getBalance();

      // w2 is buyer.
      const w2TokenBalanceBefore = await erc1155Dummy.balanceOf(w2.address, 1);

      await expect(
        nftSimpleListing
          .connect(w2)
          .purchase(
            listingId(erc1155Dummy.address, 1, w1.address, app.address),
            2,
            { value: ethers.utils.parseEther("0.5") }
          )
      )
        .to.emit(nftSimpleListing, "Purchase")
        .withArgs(
          [erc1155Dummy.address, 1],
          listingId(erc1155Dummy.address, 1, w1.address, app.address),
          w2.address,
          2,
          ethers.utils.parseEther("0.5"),
          w0.address,
          BigNumber.from("0x45a93abd01f5f5"), // 0.019607843137254901
          app.address,
          BigNumber.from("0x2176f18cfe6ea0"), // 0.009419454056132256
          BigNumber.from("0x06893b2d89b19b6b") // 0.470972702806612843
        );

      // w2 token balance should increase by 2.
      const w2TokenBalanceAfter = await erc1155Dummy.balanceOf(w2.address, 1);
      expect(w2TokenBalanceAfter).to.be.eq(w2TokenBalanceBefore.add(2));

      // w0 balance should increase by 0.5 * (10 / 255) (royalty).
      const w0BalanceAfter = await w0.getBalance();
      expect(w0BalanceAfter).to.be.eq(
        w0BalanceBefore.add(ethers.utils.parseEther("0.019607843137254901"))
      );

      // app balance should increase by (0.5 - 0.5 * (10 / 255)) * 5 / 255 (app fee).
      const appBalanceAfter = await app.getBalance();
      expect(appBalanceAfter).to.be.eq(
        appBalanceBefore.add(ethers.utils.parseEther("0.009419454056132256"))
      );

      // w1 balance should increase by (0.5 - 0.5 * (10 / 255)) * 250 / 255 (seller).
      const w1BalanceAfter = await w1.getBalance();
      expect(w1BalanceAfter).to.be.eq(
        w1BalanceBefore.add(ethers.utils.parseEther("0.470972702806612843"))
      );
    });

    describe("when insufficient stock", () => {
      it("should fail", async () => {
        await expect(
          nftSimpleListing
            .connect(w2)
            .purchase(
              listingId(erc1155Dummy.address, 1, w1.address, app.address),
              49,
              { value: ethers.utils.parseEther("12.25") }
            )
        ).to.be.revertedWith("NFTSimpleListing: insufficient stock");
      });
    });
  });

  describe("replenishing stock", () => {
    it("should replenish stock", async () => {
      const _listingId = listingId(
        erc1155Dummy.address,
        1,
        w1.address,
        app.address
      );

      await expect(
        erc1155Dummy
          .connect(w1)
          .safeTransferFrom(
            w1.address,
            nftSimpleListing.address,
            1,
            10,
            new ListingConfig(
              ethers.utils.parseEther("0.35"),
              app.address
            ).toBytes()
          )
      )
        .to.emit(nftSimpleListing, "Replenish")
        .withArgs(
          [erc1155Dummy.address, 1],
          app.address,
          _listingId,
          w1.address,
          ethers.utils.parseEther("0.35"),
          10
        );

      const listing = await nftSimpleListing.getListing(_listingId);

      expect(listing.stockSize).to.be.eq(18);
      expect(listing.price).to.be.eq(ethers.utils.parseEther("0.35"));
    });
  });

  describe("withdrawing", () => {
    it("works", async () => {
      const _listingId = listingId(
        erc1155Dummy.address,
        1,
        w1.address,
        app.address
      );

      // w1 is seller.
      const w1TokenBalanceBefore = await erc1155Dummy.balanceOf(w1.address, 1);

      await expect(
        nftSimpleListing.connect(w1).withdraw(_listingId, w1.address, 18)
      )
        .to.emit(nftSimpleListing, "Withdraw")
        .withArgs(
          [erc1155Dummy.address, 1],
          app.address,
          _listingId,
          w1.address,
          w1.address,
          18
        );

      // w1 token balance should increase by 18.
      const w1TokenBalanceAfter = await erc1155Dummy.balanceOf(w1.address, 1);
      expect(w1TokenBalanceAfter).to.be.eq(w1TokenBalanceBefore.add(18));

      expect(
        (await nftSimpleListing.getListing(_listingId)).stockSize
      ).to.be.eq(0);
    });
  });
});

function listingId(
  tokenContract: string,
  tokenId: number,
  seller: string,
  app: string
): BytesLike {
  return keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["address", "uint256", "address", "address"],
      [tokenContract, tokenId, seller, app]
    )
  );
}
