// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Etched at 0x3333…3333 so a test can read the bytes the desk handed to HyperCore.
/// @dev The real system contract accepts anything and tells the caller nothing — a malformed
///      action, an unaffordable order and a perfect one all return the same successful receipt.
///      So this records rather than validates: the assertions belong in the test, where they can
///      say which of the exchange's rules the payload was supposed to satisfy.
///
///      **It keeps no storage.** A `bytes` push costs more than the action it stands in for, which
///      would put ~22 000 gas of test scaffolding inside the one measurement that has to stay
///      honest — `cover`'s cost, which the desk pays so the taker does not. The log is enough:
///      `vm.expectEmit` compares the whole payload, which is a stricter assertion than reading a
///      recorded copy back and checking fields one at a time.
contract CoreWriterMock {
    event RawAction(bytes data);

    function sendRawAction(bytes calldata data) external {
        emit RawAction(data);
    }

    /// @notice The bytes `DeskAccount` is expected to produce, built independently of it.
    /// @dev One version byte, three id bytes big-endian, then the ABI encoding. A test that builds
    ///      the payload this way and compares whole is testing the layout, not echoing it.
    function limitOrder(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, uint8 tif, uint128 cloid)
        external
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(uint8(1), uint24(1), abi.encode(asset, isBuy, limitPx, sz, false, tif, cloid));
    }
}
