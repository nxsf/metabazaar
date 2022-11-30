import { expect, use } from "chai";
import { deployContract, MockProvider, solidity } from "ethereum-waffle";
import ERC1155DummyABI from "../../waffle/ERC1155Dummy.json";
import { Erc1155Dummy } from "../../waffle/types/Erc1155Dummy";
import OpenStoreABI from "../../waffle/OpenStore.json";
import { OpenStore } from "../../waffle/types/OpenStore";
import { BigNumber, BigNumberish, BytesLike, ethers } from "ethers";
import { keccak256 } from "@ethersproject/keccak256";

class ListingConfig {
  seller: string;
  app: string;
  price: BigNumberish;

  constructor(seller: string, app: string, price: BigNumberish) {
    this.seller = seller;
    this.app = app;
    this.price = price;
  }

  toBytes(): BytesLike {
    return ethers.utils.defaultAbiCoder.encode(
      ["address", "address", "uint256"],
      [this.seller, this.app, this.price]
    );
  }
}

use(solidity);

describe("OpenStore", async () => {
  const [w0, w1, w2, app, owner] = new MockProvider().getWallets();

  let erc1155Dummy: Erc1155Dummy;
  let openStore: OpenStore;

  before(async () => {
    erc1155Dummy = (await deployContract(
      owner,
      ERC1155DummyABI
    )) as Erc1155Dummy;

    openStore = (await deployContract(owner, OpenStoreABI)) as OpenStore;
  });

  describe("listing", () => {
    before(async () => {
      // Mint 50 tokens for w0.
      await erc1155Dummy.connect(w0).mint(w0.address, 1, 50, [], 10);

      // Transfer 40 tokens to w1.
      await erc1155Dummy
        .connect(w0)
        .safeTransferFrom(w0.address, w1.address, 1, 40, []);

      await expect(openStore.connect(app).setAppFee(5))
        .to.emit(openStore, "SetAppFee")
        .withArgs(app.address, 5);
      expect(await openStore.appFee(app.address)).to.eq(5);

      expect(await openStore.connect(app).setIsSellerApprovalRequired(true))
        .to.emit(openStore, "SetIsSellerApprovalRequired")
        .withArgs(app.address, true);
    });

    describe("when seller is not approved", () => {
      it("should fail", async () => {
        expect(await openStore.isSellerApproved(app.address, w1.address)).to.be
          .false;

        await expect(
          erc1155Dummy
            .connect(w1)
            .safeTransferFrom(
              w1.address,
              openStore.address,
              1,
              10,
              new ListingConfig(
                w1.address,
                app.address,
                ethers.utils.parseEther("0.25")
              ).toBytes()
            )
        ).to.be.revertedWith("OpenStore: seller not approved");
      });

      after(async () => {
        await expect(openStore.connect(app).setSellerApproved(w1.address, true))
          .to.emit(openStore, "SetSellerApproved")
          .withArgs(app.address, w1.address, true);
      });
    });

    describe("when seller is invalid", () => {
      it("should fail", async () => {
        await expect(
          erc1155Dummy
            .connect(w1)
            .safeTransferFrom(
              w1.address,
              openStore.address,
              1,
              10,
              new ListingConfig(
                w0.address,
                app.address,
                ethers.utils.parseEther("0.25")
              ).toBytes()
            )
        ).to.be.revertedWith("OpenStore: invalid seller");
      });
    });

    describe("when everything is set", () => {
      before(async () => {
        await expect(openStore.connect(app).setAppGratitude(10))
          .to.emit(openStore, "SetAppGratitude")
          .withArgs(app.address, 10);
      });

      it("should list token", async () => {
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
              openStore.address,
              1,
              10,
              new ListingConfig(
                w1.address,
                app.address,
                ethers.utils.parseEther("0.25")
              ).toBytes()
            )
        )
          .to.emit(openStore, "List")
          .withArgs([erc1155Dummy.address, 1], w1.address, app.address)
          .and.to.emit(openStore, "Replenish")
          .withArgs(
            [erc1155Dummy.address, 1],
            app.address,
            _listingId,
            ethers.utils.parseEther("0.25"),
            10
          );

        const listing = await openStore.getListing(_listingId);

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
          openStore
            .connect(w2)
            .purchase(
              listingId(erc1155Dummy.address, 1, w1.address, app.address),
              2,
              { value: ethers.utils.parseEther("0.49") }
            )
        ).to.be.revertedWith("OpenStore: invalid value");
      });
    });

    describe("when the eth value is greater than required", () => {
      it("should fail", async () => {
        await expect(
          openStore
            .connect(w2)
            .purchase(
              listingId(erc1155Dummy.address, 1, w1.address, app.address),
              2,
              { value: ethers.utils.parseEther("0.51") }
            )
        ).to.be.revertedWith("OpenStore: invalid value");
      });
    });

    it("should purchase token", async () => {
      // owner receives gratitude.
      const ownerBalanceBefore = await owner.getBalance();

      // app receives app fee.
      const appBalanceBefore = await app.getBalance();

      // w0 is royalty recipient.
      const w0BalanceBefore = await w0.getBalance();

      // w1 is seller.
      const w1BalanceBefore = await w1.getBalance();

      // w2 is buyer.
      const w2TokenBalanceBefore = await erc1155Dummy.balanceOf(w2.address, 1);

      await expect(
        openStore
          .connect(w2)
          .purchase(
            listingId(erc1155Dummy.address, 1, w1.address, app.address),
            2,
            { value: ethers.utils.parseEther("0.5") }
          )
      )
        .to.emit(openStore, "Purchase")
        .withArgs(
          [erc1155Dummy.address, 1],
          listingId(erc1155Dummy.address, 1, w1.address, app.address),
          w2.address,
          2,
          ethers.utils.parseEther("0.5"),
          w0.address,
          BigNumber.from("0x45a93abd01f5f5"), // 0.019607843137254901
          app.address,
          BigNumber.from("0x2026fc28179777"), // 0.009050063700989815 (app fee)
          BigNumber.from("0x014ff564e6d729"), // 0.000369390355142441 (gratitude)
          BigNumber.from("0x06893b2d89b19b6b") // 0.470972702806612843 (profit)
        );

      // w2 token balance should increase by 2.
      const w2TokenBalanceAfter = await erc1155Dummy.balanceOf(w2.address, 1);
      expect(w2TokenBalanceAfter).to.be.eq(w2TokenBalanceBefore.add(2));

      // w0 balance should increase by royalty.
      const w0BalanceAfter = await w0.getBalance();
      expect(w0BalanceAfter).to.be.eq(
        w0BalanceBefore.add(ethers.utils.parseEther("0.019607843137254901"))
      );

      // app balance should increase by app fee.
      const appBalanceAfter = await app.getBalance();
      expect(appBalanceAfter).to.be.eq(
        appBalanceBefore.add(ethers.utils.parseEther("0.009050063700989815"))
      );

      // owner balance should increase by gratitude.
      const ownerBalanceAfter = await owner.getBalance();
      expect(ownerBalanceAfter).to.be.eq(
        ownerBalanceBefore.add(ethers.utils.parseEther("0.000369390355142441"))
      );

      // w1 balance should increase by profit.
      const w1BalanceAfter = await w1.getBalance();
      expect(w1BalanceAfter).to.be.eq(
        w1BalanceBefore.add(ethers.utils.parseEther("0.470972702806612843"))
      );
    });

    describe("when insufficient stock", () => {
      it("should fail", async () => {
        await expect(
          openStore
            .connect(w2)
            .purchase(
              listingId(erc1155Dummy.address, 1, w1.address, app.address),
              49,
              { value: ethers.utils.parseEther("12.25") }
            )
        ).to.be.revertedWith("OpenStore: insufficient stock");
      });
    });
  });

  describe("replenishing stock", () => {
    it("works", async () => {
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
            openStore.address,
            1,
            10,
            new ListingConfig(
              w1.address,
              app.address,
              ethers.utils.parseEther("0.35")
            ).toBytes()
          )
      )
        .to.emit(openStore, "Replenish")
        .withArgs(
          [erc1155Dummy.address, 1],
          app.address,
          _listingId,
          ethers.utils.parseEther("0.35"),
          10
        );

      const listing = await openStore.getListing(_listingId);

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

      const listingStockSizeBefore = (await openStore.getListing(_listingId))
        .stockSize;

      await expect(openStore.connect(w1).withdraw(_listingId, w1.address, 8))
        .to.emit(openStore, "Withdraw")
        .withArgs(
          [erc1155Dummy.address, 1],
          app.address,
          _listingId,
          w1.address,
          8
        );

      // w1 token balance should increase by 8.
      const w1TokenBalanceAfter = await erc1155Dummy.balanceOf(w1.address, 1);
      expect(w1TokenBalanceAfter).to.be.eq(w1TokenBalanceBefore.add(8));

      // listing stock size should decrease by 8.
      const listingStockSizeAfter = await openStore.getListing(_listingId);
      expect(listingStockSizeAfter.stockSize).to.be.eq(
        listingStockSizeBefore.sub(8)
      );
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
