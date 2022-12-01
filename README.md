# Metabazaar

## OpenStore

1. Set application fee (`setAppFee(10)`)
2. (Optional) Set seller approval requirement (`setIsSellerApprovalRequired(true)`)
3. (Optional) Approve seller (`setSellerApproved(seller, true)`)

## Development

For testing, `waffle` is used along with `ethers`.

1. Run Hardhat node with `npm run node`.
2. Deploy contracts with `npm run deploy -- --network localhost`.
   Copy the contracts' addresses into the application.
