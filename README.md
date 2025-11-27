# Mint Capacity Gate · Zama FHEVM

> Encrypted per-wallet mint limits for NFT collections. Track capacity without revealing how much each wallet has minted.

This project demonstrates how to implement **private mint limits** for an NFT collection using **Zama's fhEVM**. Instead of tracking mint counts in clear, the contract stores an **encrypted per-wallet counter** and a **global encrypted mint cap**.

For each wallet and mint attempt, the contract computes a single encrypted boolean:

* `1` → wallet still appears to be **within the private limit**
* `0` → wallet **seems to have reached or exceeded** the limit

Only this one-bit flag is made publicly decryptable. The exact limit and the exact minted count always remain encrypted.

Built for the **Zama Developer Program**, this project shows how fhEVM can act as a **privacy-preserving rate limiter** for NFT drops or other quota-based systems.

---

## 1. Concept & Motivation

Typical NFT collections implement mint limits like:

> *"Each wallet may mint at most 5 tokens."*

On a public chain, this is usually managed by storing a clear `uint256` counter per wallet. Anyone can see:

* how many tokens each address has minted
* the global limit configuration

With fhEVM, we can keep both the **limit** and the **counters** encrypted while still enforcing the rule on-chain.

**Goal:**

* enforce a **per-wallet cap** on mint activity;
* keep the **total minted per wallet** private;
* reveal only a one-bit answer: *"still allowed"* / *"limit reached"*.

This project acts as a standalone **Mint Capacity Gate** that an NFT contract or frontend can consult before allowing a mint.

---

## 2. Model: How the private limit is enforced

At a high level:

* The **admin** chooses a clear value `maxMintsPerWallet` (e.g. `5`).
* The frontend encrypts this number as `uint16` using the **Relayer SDK** and stores the ciphertext on-chain via `setMintPolicy`.
* For each wallet, the contract maintains an **encrypted counter** `eMinted`.
* When a wallet wants to mint more tokens, it submits an **encrypted delta** `eDelta` representing "how many I plan to mint now".

The contract then performs:

```text
minted_new = minted_old + delta
canStillMint = (minted_new <= maxMintsPerWallet)
```

In Solidity terms (ignoring encryption wrappers):

```solidity
uint16 minted = state[user].minted;
uint16 max    = maxMintsPerWallet;
uint16 delta  = request.delta;

minted += delta;
bool canStillMint = (minted <= max);
```

On fhEVM this is implemented with encrypted types:

* `euint16` for counters, deltas, and the global limit;
* `ebool` for `canStillMint`;
* homomorphic arithmetic and comparisons:

  * `FHE.add` for addition;
  * `FHE.le` for comparison `<=`.

Only `eCanStillMint` is made **publicly decryptable**. The encrypted `eMinted` and `eMaxMintsPerWallet` remain private.

### 2.1 Behaviour recap

* A wallet that has never interacted before starts with `minted = 0`.
* On the first call with `delta = 3` and limit `5`:

  * new total = `3` → `canStillMint = true`.
* Second call with `delta = 2`:

  * new total = `5` → `canStillMint = true`.
* Third call with `delta = 1`:

  * new total = `6` → `canStillMint = false` (and will stay `false` for further increments).

The contract never reveals the clear numbers – only whether the private inequality still holds.

---

## 3. FHE Data Flow

High-level architecture:

```text
User Browser             Relayer SDK               MintLimit Contract
─────────────           ────────────              ───────────────────
[Owner] enters cap  ─▶  createEncryptedInput ─▶  setMintPolicy
                      add16(maxMints)             FHE.fromExternal

[User] enters delta ─▶  createEncryptedInput ─▶  updateMintCounter
                      add16(delta)                FHE.add / FHE.le
                                                  │
                                                  ▼
                                           eCanStillMint (ebool)

[Anyone] reads flag  ◀─ relayer.publicDecrypt ◀─ handle from getMyMintHandles
```

### 3.1 Owner flow (encrypted policy)

1. Owner connects with their wallet.
2. Frontend collects a clear `maxMintsPerWallet` (e.g. `5`).
3. `createEncryptedInput(contract, owner)` is called and `add16(maxMints)` encodes the value.
4. The resulting handle + proof are sent to `setMintPolicy`.
5. The contract uses `FHE.fromExternal` to ingest the ciphertext into `eMaxMintsPerWallet` and calls `FHE.allowThis` so it can use it later.

### 3.2 User flow (encrypted counter)

1. User types a clear `delta` (e.g. `1` or `3`).
2. Frontend encrypts this via `add16(delta)` and `encrypt()`.
3. Contract receives `encDelta` + proof in `updateMintCounter`.
4. It imports the ciphertext as `eDelta`, adds it to `eMinted` with `FHE.add`, and compares the new total with `FHE.le(eMinted, eMaxMintsPerWallet)`.
5. The resulting `eCanStillMint` is marked publicly decryptable via `FHE.makePubliclyDecryptable`.

### 3.3 Reading the decision

* Anyone can call the view function `getMyMintHandles()` or `getCanMintHandleOf(address)` to obtain the eligibility handle.
* The frontend passes that handle to `relayer.publicDecrypt(handle)`.
* The decrypted value is interpreted as `true` (non-zero) or `false` (zero) and displayed in the UI.

The encrypted counter `eMinted` is never publicly decrypted, but the contract grants the user permission with `FHE.allow(eMinted, user)` so that they *could* use a signed `userDecrypt` flow if they want to introspect their own total.

---

## 4. User Interface & UX

The frontend is a single-page HTML app with a **two-column layout** plus a shared log.

1. **Left column – “Your minting capacity”**
2. **Right column – “Admin lane · encrypted limit”**
3. **Bottom strip – “Event console”**

All user-facing text is in English.

### 4.1 Left: "Your minting capacity"

This panel is what regular wallets interact with.

**Step 1 – Plan your mint**

* Input: `How many tokens are you about to mint?` (plain number).
* The user clicks **“Run encrypted check”**.
* The frontend:

  * encrypts the delta with the Relayer (as `uint16`),
  * calls `updateMintCounter` on the contract,
  * shows a temporary status like `"Encrypted check stored on-chain ✔"`.

A secondary button **“Sync decision”** re-reads the on-chain state and re-runs `publicDecrypt`.

**Step 2 – Result**

A rounded status pill reflects the decision:

* **Green dot + text:** `"You are still under the private cap"`
* **Red dot + text:** `"Limit appears to be reached"`
* **Yellow / grey:** `"No activity yet"` / `"No decision yet"`

The panel explains that only a one-bit answer is revealed; the cumulative count stays encrypted.

### 4.2 Right: "Admin lane · encrypted limit"

This panel is primarily for the contract owner.

Elements:

* Numeric input: `Max mints per wallet (uint16)`.
* Button: **“Publish encrypted cap”**

  * Encrypts the value via `add16(maxMints)`.
  * Calls `setMintPolicy` with the encrypted handle + proof.
  * On success, the UI displays `"Encrypted cap active ✔"`.
* A small tag in the header shows policy status:

  * `limit: active` (green) if `policyInitialized == true`.
  * `limit: not set` (red) otherwise.

Below that, a “Technical snapshot” shows:

* `Owner` address (shortened)
* `You` (current signer)
* `Relayer` status ("ready (Sepolia)" / "not ready")

### 4.3 Event console

At the bottom, a dark console-style panel logs:

* encrypted handles
* transaction hashes
* raw `publicDecrypt` results
* error messages from both the wallet and the Relayer

This is useful for debugging and for learning how fhEVM flows behave under the hood.

---

## 5. Smart Contract Overview

The main contract is `EncryptedMintLimitFHE.sol`.

### 5.1 Storage

* `eMaxMintsPerWallet` (`euint16`)

  * encrypted global per-wallet mint limit.
* `policyInitialized` (`bool`)

  * ensures users cannot update counters before a cap is set.
* `mints[address]` → `MintState`

  * `eMinted` (`euint16`) – encrypted mint counter for this wallet.
  * `eCanStillMint` (`ebool`) – encrypted eligibility flag.
  * `initialized` (`bool`) – has this wallet interacted at least once?

### 5.2 Key functions

* `setMintPolicy(externalEuint16 _maxMintsPerWallet, bytes proof)`

  * Owner-only.
  * Imports encrypted limit with `FHE.fromExternal`.
  * Calls `FHE.allowThis` to grant contract access.
  * Sets `policyInitialized = true`.

* `updateMintCounter(externalEuint16 encDelta, bytes proof)`

  * Open to any address (once policy is initialized).
  * Ingests `encDelta` into an `euint16` with `FHE.fromExternal`.
  * Grants access to contract + user (`FHE.allowThis`, `FHE.allow`).
  * If `!initialized`, sets `eMinted = eDelta`; else `eMinted = FHE.add(eMinted, eDelta)`.
  * Computes `eCanStillMint = FHE.le(eMinted, eMaxMintsPerWallet)`.
  * Calls `FHE.makePubliclyDecryptable(eCanStillMint)` so anyone can decrypt the flag.

* View helpers (no FHE ops, handles only):

  * `getMyMintHandles()` → `(mintedHandle, canStillMintHandle, initialized)` for `msg.sender`.
  * `getCanMintHandleOf(address)` → `(canStillMintHandle, initialized)` for arbitrary address.
  * `getMintedHandleOf(address)` → `(mintedHandle, initialized)` for arbitrary address.

### 5.3 Access control & privacy

* Standard `owner` pattern with `onlyOwner` modifier.
* Ciphertext permissions:

  * `FHE.allowThis` → contract can reuse ciphertexts.
  * `FHE.allow(eMinted, user)` → user can privately decrypt their own counter.
* Public decryption boundary:

  * Only `eCanStillMint` receives `FHE.makePubliclyDecryptable`.
  * Neither the global limit nor individual counters are exposed in clear.

---

## 6. Frontend & Relayer Integration

The frontend is a **single-file** `index.html` using:

* **Ethers v6 (ESM)** for wallet and contract calls.
* **@zama-fhe/relayer-sdk** for:

  * `createEncryptedInput` / `encrypt()`;
  * `publicDecrypt` to decode public flags.
* Plain HTML & CSS, no build system required.

### 6.1 Network & endpoints

* **Network:** Sepolia (`chainId = 11155111`, hex `0xaa36a7`).

* **Mint Gate contract:** deployed at

  ```text
  0x7D3a3ed2903d9e856f1Cd66Fd035C97ee41b3cC9
  ```

* **Relayer endpoints:**

  * `https://relayer.testnet.zama.org`
  * `https://gateway.testnet.zama.org`
  * Optionally, a local HTTPS proxy on `https://localhost:3443` can be used to avoid CORS restrictions in development.

---

## 7. Running Locally

### 7.1 Prerequisites

* Node.js (LTS recommended)
* MetaMask or another EIP‑1193‑compatible wallet
* Some Sepolia test ETH for the owner and user accounts

### 7.2 Steps

1. **Clone the repo**

   ```bash
   git clone https://github.com/your-handle/mint-capacity-gate.git
   cd mint-capacity-gate
   ```

2. **Serve the frontend**

   Because the Relayer SDK uses WebAssembly and workers, it should be served from an HTTP(S) server, not via `file://`.

   Minimal example using `serve`:

   ```bash
   npm install -g serve
   serve frontend -l 3033
   ```

   This assumes the `index.html` file lives in a `frontend/` folder.

3. **Open the dApp**

   Visit `http://localhost:3033` (or `https://…` if configured) in a browser with MetaMask.

4. **Connect and switch to Sepolia**

   Click **Connect wallet**. The app will prompt you to switch networks if needed.

5. **Test the flows**

   * As owner:

     * Set a cap (e.g. `5`) in the right column.
     * Click **Publish encrypted cap**.
   * As user:

     * Enter delta (e.g. `3`) and click **Run encrypted check**.
     * Click **Sync decision** to decrypt and display the latest eligibility flag.

> ⚠️ This is an educational demo. Do **not** use it with real funds or production NFT collections.

---

## 8. Project Structure

A minimal repository layout:

```text
mint-capacity-gate/
├── contracts/
│   └── EncryptedMintLimitFHE.sol   # fhEVM smart contract implementing the private cap
├── frontend/
│   └── index.html                  # Single-page UI + ethers + Relayer SDK
├── README.md
└── package.json                    # Optional dev dependencies & scripts
```

You can extend this with a full Hardhat/Foundry setup, NFT contracts, or a React frontend, but the core idea remains the same: **separate the NFT logic from a reusable privacy-preserving mint limiter.**

---

## 9. Future Extensions

Possible directions to evolve this prototype:

* Per-collection or per‑phase caps, using multiple encrypted limits.
* Soft and hard caps (e.g. warning threshold vs absolute maximum).
* Integration with actual ERC‑721 / ERC‑1155 contracts to block mints on-chain when the gate flag is `false`.
* Time-based decay (e.g. daily or weekly encrypted quotas).
* Exporting the `canStillMint` flag as an attestation or SBT for use by other dApps.

---

## 10. Built with Zama fhEVM

This project uses:

* **@fhevm/solidity** for encrypted types (`euint16`, `ebool`) and homomorphic operations.
* **@zama-fhe/relayer-sdk** for encrypted input handling and public decryption.

It is inspired by previous Zama builder projects that explored private leaderboards, ratings, limits, and gating logic, and adapts those patterns to the NFT minting world.

Feel free to fork, experiment, and integrate the **Mint Capacity Gate** into your own collections or quota-based systems.

---

**License:** MIT (or another OSS license of your choice).

**Made for the Zama Developer Program · Powered by Fully Homomorphic Encryption**
