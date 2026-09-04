// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Deployed to testnet 998 to answer, on a real node, the one question a fork cannot:
///         does a view function reached through STATICCALL get two words back from 0x080e,
///         and how much gas does a bad index burn under a cap.
/// @dev The precompiles carry no bytecode, so revm returns empty data for them and every answer
///      here has to come from a Hyperliquid node. `direct` and `nested` both measure the same
///      thing — the gas the precompile frame itself consumes — so the two numbers are comparable
///      and their difference is the cost of the extra STATICCALL depth, not of the read.
contract Probe {
    address internal constant BBO = 0x000000000000000000000000000000000000080e;

    error ProbeCallFailed();
    error ProbeBadLength(uint256 length);

    /// @notice Depth 1: this contract staticcalls the precompile.
    function direct(uint32 perpIndex) external view returns (uint64 bid, uint64 ask, uint256 gasUsed) {
        return _bbo(perpIndex);
    }

    /// @notice Depth 2: this contract staticcalls itself, which staticcalls the precompile.
    ///         Same shape as router -> CoreQuote -> precompile.
    /// @dev `gasUsed` is the inner precompile frame's own cost, not the whole nested call, so it
    ///      stays directly comparable with `direct`.
    function nested(uint32 perpIndex) external view returns (uint64 bid, uint64 ask, uint256 gasUsed) {
        (bool ok, bytes memory ret) = address(this).staticcall(abi.encodeCall(this.direct, (perpIndex)));
        if (!ok) revert ProbeCallFailed();
        return abi.decode(ret, (uint64, uint64, uint256));
    }

    /// @notice One precompile frame, measured. `inputLength` bytes of `word` are sent to
    ///         `precompile` with `gasCap` forwarded; nothing sits between the two gas reads.
    /// @dev This is what sizes PRECOMPILE_GAS_CAP. The library caps every read with one constant,
    ///      so the constant has to clear the most expensive read, and the reads cost different
    ///      amounts: 0x080a returns a 256-byte record and 0x0809 returns one word.
    function frame(address precompile, uint256 inputLength, uint256 word, uint256 gasCap)
        external
        view
        returns (bool ok, uint256 gasUsed, uint256 returnLength)
    {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, word)
            let g := gas()
            ok := staticcall(gasCap, precompile, ptr, inputLength, 0x00, 0x00)
            gasUsed := sub(g, gas())
            returnLength := returndatasize()
        }
    }

    /// @notice What an invalid input costs under `gasCap`, and whether the outer frame survives it.
    /// @dev The input is four bytes where the precompile wants thirty-two. If `gasUsed` comes back
    ///      equal to `gasCap` the precompile burns everything forwarded, which is why the reader
    ///      caps the frame instead of estimating it.
    function badInput(uint256 gasCap) external view returns (bool ok, uint256 gasUsed) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0)
            let g := gas()
            ok := staticcall(gasCap, BBO, ptr, 0x04, 0x00, 0x00)
            gasUsed := sub(g, gas())
        }
    }

    function _bbo(uint32 perpIndex) private view returns (uint64 bid, uint64 ask, uint256 gasUsed) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, perpIndex)
            let g := gas()
            let ok := staticcall(gas(), BBO, ptr, 0x20, ptr, 0x40)
            gasUsed := sub(g, gas())
            if iszero(ok) {
                mstore(0x00, 0xfe0fd51f00000000000000000000000000000000000000000000000000000000)
                revert(0x00, 0x04)
            }
            if iszero(eq(returndatasize(), 0x40)) {
                mstore(0x00, 0xfee78c1400000000000000000000000000000000000000000000000000000000)
                mstore(0x04, returndatasize())
                revert(0x00, 0x24)
            }
            bid := mload(ptr)
            ask := mload(add(ptr, 0x20))
        }
    }
}
