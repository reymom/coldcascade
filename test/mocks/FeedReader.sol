// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ICoreReader, Book } from "../../src/interfaces/ICoreReader.sol";

/// @dev The three words of `AggregatorV3Interface.latestRoundData` a reader would use.
interface IAggregatorV3Like {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice A feed whose answer the test sets. It answers in raw HyperCore units so that the scale
///         is not what the comparison is about.
contract FeedMock is IAggregatorV3Like {
    int256 public answer;

    function set(int256 value) external {
        answer = value;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, block.timestamp, block.timestamp, 0);
    }
}

/// @notice An `ICoreReader` over a Chainlink-shaped feed: one answer, copied into all four words.
///         This is the adapter anyone would write to run the desk on a chain that has a feed and
///         no book, and it is the reason the desk cannot run there. `oracle - mark` is identically
///         zero, so the regime never leans; bid and ask are the same number, so the clamp has no
///         touch to stop on. The type is filled. The mechanism is gone.
contract FeedReader is ICoreReader {
    IAggregatorV3Like public immutable FEED;

    error BadAnswer(int256 answer);

    constructor(IAggregatorV3Like feed) {
        FEED = feed;
    }

    function read(uint32) external view returns (Book memory) {
        (, int256 answer,,,) = FEED.latestRoundData();
        if (answer <= 0 || answer > int256(uint256(type(uint64).max))) revert BadAnswer(answer);
        uint64 mid = uint64(uint256(answer));
        return Book({ bid: mid, ask: mid, mark: mid, oracle: mid });
    }
}
