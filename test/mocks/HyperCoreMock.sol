// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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
    address internal constant BBO = 0x000000000000000000000000000000000000080e;

    mapping(uint32 perpIndex => uint64) public px;   // mark at 0x0806, oracle at 0x0807
    mapping(uint32 perpIndex => uint64) public bid;  // 0x080e
    mapping(uint32 perpIndex => uint64) public ask;  // 0x080e
    uint64 public l1Block;                           // 0x0809

    /// @dev Words 0x080e answers with. Two is the truth; anything else exercises the length check.
    ///      Held as an explicit override rather than an initialised field, because vm.etch copies
    ///      code and not storage: a constructor default would be zero at the etched address.
    uint8 private _bboWords;
    bool private _bboWordsSet;
    /// @dev When set, a well-formed call burns everything forwarded, as a bad index does on 998.
    bool public burn;

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

    /// @dev Decodes the uint32 the precompile expects and answers in the precompile's own layout,
    ///      picked by address(this).
    fallback(bytes calldata input) external returns (bytes memory) {
        if (burn) _burnEverything();

        address self = address(this);
        if (self == L1_BLOCK_NUMBER) return abi.encode(uint256(l1Block));

        if (input.length != 32) _burnEverything();
        uint32 perpIndex = uint32(uint256(bytes32(input)));

        if (self == MARK_PX || self == ORACLE_PX) return abi.encode(uint256(px[perpIndex]));

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
