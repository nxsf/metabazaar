import { ethers } from "ethers";

export function ipnftTag(
  chainId: string,
  contractAddress: string,
  minterAddress: string,
  minterNonce: number
) {
  const tag = Buffer.alloc(80);

  tag.writeUint32BE(0x65766d01);
  tag.write(chainId.slice(2), 4, 32, "hex");
  tag.write(contractAddress.slice(2), 36, 20, "hex");
  tag.write(minterAddress.slice(2), 56, 20, "hex");
  tag.writeUInt32BE(minterNonce, 76);

  return tag;
}

export async function getChainId(
  provider: ethers.providers.Provider
): Promise<string> {
  // FIXME: It is 1337 locally, but 1 in the contract.
  // const chainId = (await provider.getNetwork()).chainId;
  const chainId = 1;
  return "0x" + chainId.toString(16).padStart(64, "0");
}
