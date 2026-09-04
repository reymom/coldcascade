// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Etched at each precompile address with vm.etch (tests) or anvil_setCode (demo).
///         Every instance answers for its own address, so one bytecode serves 0x0806, 0x0807,
///         0x0809 and 0x080e. The real precompiles have no code; this is how a fork gets a book.
contract HyperCoreMock {
    mapping(uint32 perpIndex => uint64) public px;   // mark at 0x0806, oracle at 0x0807
    mapping(uint32 perpIndex => uint64) public bid;  // 0x080e
    mapping(uint32 perpIndex => uint64) public ask;  // 0x080e
    uint64 public l1Block;                           // 0x0809

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

    /// @dev Decodes the uint32 the precompile expects and answers in the precompile's own layout,
    ///      picked by address(this).
    fallback(bytes calldata input) external returns (bytes memory) {
        revert("todo");
    }
}
