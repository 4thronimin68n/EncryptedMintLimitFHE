// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;



import {
  FHE,
  ebool,
  euint16,
  externalEuint16
} from "@fhevm/solidity/lib/FHE.sol";

import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedMintLimitFHE is ZamaEthereumConfig {
  // ---------- Ownership ----------
  address public owner;

  modifier onlyOwner() {
    require(msg.sender == owner, "Not owner");
    _;
  }

  constructor() {
    owner = msg.sender;
  }

  function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), "zero owner");
    owner = newOwner;
  }

  // ---------- Simple reentrancy guard (for future payable flows) ----------
  uint256 private _locked = 1;

  modifier nonReentrant() {
    require(_locked == 1, "reentrancy");
    _locked = 2;
    _;
    _locked = 1;
  }

  // ---------- Global encrypted mint policy ----------
  //
  // maxMintsPerWallet: same encrypted limit for all wallets.
  // Stored as euint16; never publicly decrypted.
  //
  // canStillMint := (mintedSoFar + delta <= maxMintsPerWallet)

  euint16 private eMaxMintsPerWallet;
  bool    public policyInitialized;

  event MintPolicyUpdated(bytes32 maxMintsHandle);

  /**
   * Owner sets the encrypted max-mint-per-wallet.
   *
   * The argument must be an external encrypted uint16 produced by the Relayer SDK
   * (createEncryptedInput + add16(maxMints)).
   *
   * `proof` is the input proof returned by the Relayer.
   */
  function setMintPolicy(
    externalEuint16 _maxMintsPerWallet,
    bytes calldata  proof
  ) external onlyOwner {
    eMaxMintsPerWallet = FHE.fromExternal(_maxMintsPerWallet, proof);

    // Allow this contract to keep using the encrypted limit.
    FHE.allowThis(eMaxMintsPerWallet);

    policyInitialized = true;

    emit MintPolicyUpdated(FHE.toBytes32(eMaxMintsPerWallet));
  }

  // ---------- Per-wallet encrypted counters ----------

  struct MintState {
    // Encrypted total number of mints for this wallet.
    euint16 eMinted;

    // Encrypted flag: 1 if still within limit after the last update, 0 otherwise.
    // This handle is made publicly decryptable.
    ebool   eCanStillMint;

    bool    initialized;
  }

  mapping(address => MintState) private mints;

  event MintUpdated(
    address indexed user,
    bytes32 mintedHandle,
    bytes32 canStillMintHandle
  );

  /**
   * User reports an encrypted mint delta (how many tokens they intend to mint).
   *
   * Off-chain:
   *  - UI decides a clear `delta` (e.g. 1, 2, ...).
   *  - Relayer SDK:
   *      const buf = relayer.createEncryptedInput(contract, user);
   *      buf.add16(delta);
   *      const { handles, inputProof } = await buf.encrypt();
   *    => pass handles[0] and inputProof to this function.
   *
   * On-chain:
   *  - The contract imports `encDelta` and adds it to the encrypted counter.
   *  - It compares the new encrypted total against the encrypted maxMintsPerWallet.
   *  - The resulting eCanStillMint flag is made publicly decryptable.
   *
   * This function does not mint NFTs; it only updates the encrypted counter
   * and the public- decryptable eligibility flag. An NFT contract can call
   * this limiter before executing its own mint, and/or let the frontend
   * decrypt eCanStillMint via publicDecrypt.
   */
  function updateMintCounter(
    externalEuint16 encDelta,
    bytes calldata  proof
  ) external nonReentrant {
    require(policyInitialized, "Policy not set");

    MintState storage S = mints[msg.sender];

    // 1. Import encrypted delta from external handle
    euint16 eDelta = FHE.fromExternal(encDelta, proof);

    // Allow contract + user to work with this ciphertext
    FHE.allowThis(eDelta);
    FHE.allow(eDelta, msg.sender);

    // 2. Update encrypted minted count:
    //    if first time: minted := delta
    //    else:         minted := minted + delta
    if (!S.initialized) {
      S.eMinted = eDelta;
      S.initialized = true;
    } else {
      S.eMinted = FHE.add(S.eMinted, eDelta);
    }

    // Keep contract and user access on the running counter
    FHE.allowThis(S.eMinted);
    FHE.allow(S.eMinted, msg.sender);

    // 3. Compare encrypted total vs encrypted maxMintsPerWallet
    //    canStillMint := (minted <= maxMintsPerWallet)
    ebool canStill = FHE.le(S.eMinted, eMaxMintsPerWallet);
    S.eCanStillMint = canStill;

    // Allow contract to keep using the flag
    FHE.allowThis(S.eCanStillMint);

    // Make ONLY this boolean publicly decryptable
    FHE.makePubliclyDecryptable(S.eCanStillMint);

    emit MintUpdated(
      msg.sender,
      FHE.toBytes32(S.eMinted),
      FHE.toBytes32(S.eCanStillMint)
    );
  }

  // ---------- View helpers (handles only, no FHE ops) ----------

  /**
   * Returns, for msg.sender:
   *  - mintedHandle: encrypted total number of mints (private; user can userDecrypt).
   *  - canStillMintHandle: publicly decryptable ebool flag.
   *  - initialized: whether this wallet has ever called updateMintCounter().
   */
  function getMyMintHandles()
    external
    view
    returns (bytes32 mintedHandle, bytes32 canStillMintHandle, bool initialized)
  {
    MintState storage S = mints[msg.sender];
    return (
      FHE.toBytes32(S.eMinted),
      FHE.toBytes32(S.eCanStillMint),
      S.initialized
    );
  }

  /**
   * Public lookup of someone else's "canStillMint" handle.
   * Anyone can call Relayer publicDecrypt() over this handle to see whether
   * the wallet is still within its private mint limit, without learning the
   * actual limit or the exact minted count.
   */
  function getCanMintHandleOf(address who)
    external
    view
    returns (bytes32 canStillMintHandle, bool initialized)
  {
    MintState storage S = mints[who];
    return (FHE.toBytes32(S.eCanStillMint), S.initialized);
  }

  /**
   * Optional helper: expose the encrypted minted counter handle for any address.
   * The raw count remains private; only addresses that have been granted access
   * via FHE.allow(...) can decrypt it with signed userDecrypt.
   */
  function getMintedHandleOf(address who)
    external
    view
    returns (bytes32 mintedHandle, bool initialized)
  {
    MintState storage S = mints[who];
    return (FHE.toBytes32(S.eMinted), S.initialized);
  }
}
