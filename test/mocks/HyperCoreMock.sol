// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PerpAssetInfo } from "../../src/libs/HyperCore.sol";

/// @notice Etched at each precompile address with vm.etch (tests) or anvil_setCode (demo).
///         Every instance answers for its own address, so one bytecode serves 0x0806, 0x0807,
///         0x0809 and 0x080e. The real precompiles have no code; this is how a fork gets a book.
/// @dev Storage is per-address, which is what makes one bytecode enough: `px` holds mark at
///      0x0806 and oracle at 0x0807. The failure knobs reproduce what 998 actually does — a
///      malformed call consumes every gas unit forwarded and returns nothing, it does not revert
///      with a reason — so a test of the gas cap tests the real hazard.
contract HyperCoreMock {
    address internal constant MARK_PX = 0x0000000000000000000000000000000000000806;
    address internal constant ORACLE_PX = 0x0000000000000000000000000000000000000807;
    address internal constant L1_BLOCK_NUMBER = 0x0000000000000000000000000000000000000809;
    address internal constant POSITION = 0x0000000000000000000000000000000000000800;
    address internal constant PERP_ASSET_INFO = 0x000000000000000000000000000000000000080a;
    address internal constant BBO = 0x000000000000000000000000000000000000080e;

    mapping(uint32 perpIndex => uint64) public px;   // mark at 0x0806, oracle at 0x0807
    mapping(uint32 perpIndex => uint64) public bid;  // 0x080e
    mapping(uint32 perpIndex => uint64) public ask;  // 0x080e
    uint64 public l1Block;                           // 0x0809
    mapping(uint32 perpIndex => PerpAssetInfo) private _assetInfo;  // 0x080a
    /// @dev 0x0800, keyed by account and perp. This is what makes a desk's hedge state readable
    ///      rather than remembered, so a test drives it exactly the way a fill would.
    mapping(address user => mapping(uint32 perpIndex => int64)) public szi;

    /// @dev Words 0x080e answers with. Two is the truth; anything else exercises the length check.
    ///      Held as an explicit override rather than an initialised field, because vm.etch copies
    ///      code and not storage: a constructor default would be zero at the etched address.
    uint8 private _bboWords;
    bool private _bboWordsSet;
    /// @dev When set, a well-formed call burns everything forwarded, as a bad index does on 998.
    bool public burn;
    /// @dev When set, 0x080a answers with a buffer that is non-empty and the wrong shape: the
    ///      leading offset is not 0x20 and the record is short. `HyperCore.szDecimals` reads a
    ///      fixed offset rather than decoding, so this is the case that separates a checked read
    ///      from one that returns whatever happened to be at that word.
    bool public malformAssetInfo;

    function setPx(uint32 perpIndex, uint64 value) external {
        px[perpIndex] = value;
    }

    function setBbo(uint32 perpIndex, uint64 bid_, uint64 ask_) external {
        bid[perpIndex] = bid_;
        ask[perpIndex] = ask_;
    }

    function setL1Block(uint64 value) external {
        l1Block = value;
    }

    /// @dev `szDecimals` is the field the desk reads: it sets the lot grid a hedge is rounded onto
    ///      and the exponent every price scale is built from. The rest of the record is carried so
    ///      the mock returns the real layout — a struct that decodes by luck is a test that passes
    ///      by luck.
    function setAssetInfo(uint32 perpIndex, string calldata coin, uint32 marginTableId, uint8 szDecimals_, uint8 maxLeverage, bool onlyIsolated) external {
        _assetInfo[perpIndex] = PerpAssetInfo(coin, marginTableId, szDecimals_, maxLeverage, onlyIsolated);
    }

    function assetInfo(uint32 perpIndex) external view returns (PerpAssetInfo memory) {
        return _assetInfo[perpIndex];
    }

    function setBboWords(uint8 words) external {
        _bboWords = words;
        _bboWordsSet = true;
    }

    function bboWords() public view returns (uint8) {
        return _bboWordsSet ? _bboWords : 2;
    }

    function setBurn(bool value) external {
        burn = value;
    }

    function setMalformAssetInfo(bool value) external {
        malformAssetInfo = value;
    }

    /// @notice Put a position on an account, in lots — what a fill on HyperCore would leave behind.
    function setPosition(address user, uint32 perpIndex, int64 lots) external {
        szi[user][perpIndex] = lots;
    }

    /// @dev Decodes the uint32 the precompile expects and answers in the precompile's own layout,
    ///      picked by address(this).
    fallback(bytes calldata input) external returns (bytes memory) {
        if (burn) _burnEverything();

        address self = address(this);
        if (self == L1_BLOCK_NUMBER) return abi.encode(uint256(l1Block));

        // 0x0800 is the one read keyed by an account, so it is the one that takes two words.
        if (self == POSITION) {
            if (input.length != 64) _burnEverything();
            (address user, uint32 perp) = abi.decode(input, (address, uint32));
            return abi.encode(szi[user][perp], uint64(0), int64(0), uint32(20), false);
        }

        if (input.length != 32) _burnEverything();
        uint32 perpIndex = uint32(uint256(bytes32(input)));

        if (self == MARK_PX || self == ORACLE_PX) return abi.encode(uint256(px[perpIndex]));

        if (self == PERP_ASSET_INFO) {
            if (malformAssetInfo) return abi.encode(uint256(0x40), uint256(7), uint256(9));
            return abi.encode(_assetInfo[perpIndex]);
        }

        if (self == BBO) {
            uint8 words = bboWords();
            bytes memory out = new bytes(uint256(words) * 32);
            if (words > 0) {
                uint256 b = uint256(bid[perpIndex]);
                assembly ("memory-safe") {
                    mstore(add(out, 0x20), b)
                }
            }
            if (words > 1) {
                uint256 a = uint256(ask[perpIndex]);
                assembly ("memory-safe") {
                    mstore(add(out, 0x40), a)
                }
            }
            return out;
        }

        _burnEverything();
    }

    /// @dev INVALID consumes the whole frame and returns no data, which is the precompile's own
    ///      behaviour on a bad input. A plain revert would be a kinder failure than the real one.
    function _burnEverything() private pure {
        assembly ("memory-safe") {
            invalid()
        }
    }
}
