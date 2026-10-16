# Pepe2Pepe (P2P)

A fixed-supply ERC-20 implemented in `src/Pepe2Pepe.sol` using OpenZeppelin Contracts v5.1.0.

| Property | Value |
| --- | --- |
| Solidity contract | `Pepe2Pepe` |
| Token name | `Pepe2Pepe` |
| Symbol | `P2P` |
| Decimals | 18 |
| Whole-token supply | 1,000,000,000 |
| Base-unit supply | 1000000000000000000000000000 (10^27) |
| Constructor arguments | None |
| Initial recipient | Constructor caller (`msg.sender`) |

The constructor calls `_mint` once for the entire `INITIAL_SUPPLY`. There are no external mint or burn methods, fees, transfer taxes, rebases, limits, owner roles, pause/blacklist controls, proxies, or upgrades. Ordinary and delegated transfers deliver the exact requested amount. The token has no external calls or oracle dependencies.

Assumptions and ERC-20 behavior:

- No additional tokenomics were requested; standard ERC-20 behavior applies.
- Zero-value transfers and self-transfers are allowed. Transfers to the zero address and approvals for the zero spender revert.
- Delegated transfers require allowance, including when the spender is the source account. Finite allowances decrease; maximum `uint256` approvals remain unchanged, following OpenZeppelin semantics.
- Successful transfers emit `Transfer`; approvals emit `Approval`. Allowance consumption during `transferFrom` does not emit another `Approval` event.
- Failed operations revert atomically with OpenZeppelin ERC-6093 custom errors.

## Build and verification

Install Foundry with Solidity 0.8.26 available. Dependencies are included as ordinary files under `lib/`; no package download, submodule, environment configuration, RPC, or wallet is needed for compilation and tests. Foundry pins Solidity 0.8.26, targets Cancun, and disables the metadata bytecode hash for reproducible launch bytecode.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x32b10ba662ce0ea6b9f619edba818484ee5f68b392ff55f7e4b8afc9fac9e8c0 forge test
forge fmt --check
```

Tests cover metadata, exact supply, constructor mint event and factory recipient, transfers and events, approvals and revocation, finite/infinite allowances, invalid addresses, overdraws, rollback on failed delegated transfers, unauthorized holder spending, absent administrative methods, and fuzzed conservation and allowance accounting. Test addresses are local fixtures only; the production constructor takes no address parameters.

## Deployment and operation

Deploy `Pepe2Pepe` directly from its compiled creation bytecode without constructor arguments or initialization calls. A launch factory deploying it receives every base unit; the transaction origin does not. The constructor does not distribute allocations or configure a pool. The launch system is responsible for subsequent distribution, liquidity setup, and recording and verifying the deployed contract address and bytecode. No application contracts or launch manifest are included.

The intended launch chain is Ethereum (chain ID 1); the token itself is chain-independent. Its constructor requires no external deployed contracts. Confirm the deployment network supports the configured EVM target.

After launch, no settings or administrator actions are required or available. The deploying recipient is responsible for distributing its supply; holders are responsible for token custody and approvals. Prefer bounded approvals, revoke unused allowances, and set an existing allowance to zero before changing it if the spender is untrusted. Assets sent to the token contract itself cannot be recovered by an administrator.

Foundry tests and a source review address the supplied security checklist's applicable items: supply exposure, access control, zero addresses, arithmetic, transfer conservation, and absence of external callbacks or privileged operations. They are not an independent audit. Independent adversarial review and explorer verification remain release responsibilities; no deployment or transaction broadcast is performed here.

## Vendored dependency

`lib/openzeppelin-contracts/` contains the unmodified ERC-20 implementation and its required interfaces and context from the OpenZeppelin Contracts `v5.1.0` tag, plus the upstream MIT license. See its `UPSTREAM.md` for file provenance. Test tooling uses a small local cheatcode interface and needs no test library.
