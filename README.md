## Development

For testing, `waffle` is used along with `ethers`.

1. Run Hardhat node with `npm run node`.
2. Deploy contracts with `npm run deploy -- --network localhost`.
   Copy the contracts' addresses into the application.
3. Enable application (`setAppEnabled(app, true)`)
4. Activate application (`setAppActive(true)`)
5. Set application fee (`setAppFee(10)`)
6. (Optional) Set application gratitude (`setAppGratitude(10)`)
7. (Optional) Set seller approval requirement (`setIsSellerApprovalRequired(true)`)
8. (Optional) Approve seller (`setSellerApproved(seller, true)`)
