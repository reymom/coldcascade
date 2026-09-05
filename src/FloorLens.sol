// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CoreQuote } from "./CoreQuote.sol";
import { DeskAccount } from "./DeskAccount.sol";
import { ICoreReader, Book } from "./interfaces/ICoreReader.sol";
import { IMapOracle, LiquidationMap } from "./interfaces/IMapOracle.sol";
import { DeskParams } from "./libs/DeskParams.sol";
import { Regime, Side } from "./libs/Regime.sol";
import { HyperCore } from "./libs/HyperCore.sol";

/// @title FloorLens
/// @notice Everything the Floor draws, in one `eth_call`. A view contract with no state, no owner
///         and no constructor argument, which is why the page can plant it with a state override
///         and read a desk that has not been deployed yet.
///
/// @dev **Why one call and not six.** The HyperCore precompiles ignore the block tag — a read
///      pinned 200 000 blocks back answers with the current book (`results/999_live_quote.md`).
///      There is no consistent snapshot to pin to, so a page that reads the book, then the desk's
///      bounds, then the regime is reading three different books, and a single 10-raw tick between
///      them is enough to put a band on screen that contradicts its own arithmetic. Batching the
///      reads into one frame is the only way the four numbers on the Floor are the same four
///      numbers, and it is the reason this contract exists at all.
///
///      **Nothing here is allowed to fail the page.** An address that is not a desk, a perp with no
///      book, a map oracle that reverts: each degrades to a blank field on one row. A console that
///      goes dark because one desk is misconfigured is worse than a console with one empty row, and
///      the honest reading of an empty field — *this could not be read* — is the one the page shows.
contract FloorLens {
    /// @notice One row of the desk table, whether or not the desk is on chain.
    /// @dev `account` is zero for a params-only row: the canonical parameters answering against the
    ///      live book before anything is deployed. Everything downstream of `params` is identical
    ///      in both cases, because the quote is a pure function of the book and the parameters.
    struct DeskView {
        address account;
        string label;
        address owner;
        bool open;
        bytes32 strategyHash;
        DeskParams params;
        uint256 baseBalance;
        uint256 quoteBalance;
        bool quoted;            // false when the book or the parameters would not price
        uint256 bidPx;          // the desk's own bid, raw L1 units
        uint256 askPx;
        Side lean;
        Regime regime;
        LiquidationMap map;     // this desk's own oracle, as its quote sees it
        bool hedgeArmed;
        bool coverIsBuy;
        uint256 coverBase;
        uint256 coverNotional;
    }

    struct FloorView {
        uint256 chainId;
        uint256 blockNumber;
        uint256 timestamp;
        bool bookOk;
        Book book;
        uint64 l1Block;
        DeskView[] desks;
    }

    /// @notice The whole screen: chain, book, and one row per desk.
    /// @param q The `CoreQuote` every row is priced by; its own READER is the book's source.
    /// @param perpIndex The perp the header shows. Rows price against their own `params.perpIndex`.
    /// @param accounts Deployed `DeskAccount`s, in table order.
    /// @param previews Parameter sets with no account behind them, appended after `accounts`.
    function floor(CoreQuote q, uint32 perpIndex, address[] calldata accounts, DeskParams[] calldata previews)
        external
        view
        returns (FloorView memory v)
    {
        v.chainId = block.chainid;
        v.blockNumber = block.number;
        v.timestamp = block.timestamp;
        (v.bookOk, v.book) = _book(q.READER(), perpIndex);
        v.l1Block = _l1Block();

        v.desks = new DeskView[](accounts.length + previews.length);
        for (uint256 i; i < accounts.length; ++i) {
            // An address that is not a desk is a blank row, not a dead page.
            try this.deskAt(q, accounts[i]) returns (DeskView memory d) {
                v.desks[i] = d;
            } catch {
                v.desks[i].account = accounts[i];
            }
        }
        for (uint256 i; i < previews.length; ++i) {
            v.desks[accounts.length + i] = _quoted(q, previews[i], DeskView({
                account: address(0),
                label: "",
                owner: address(0),
                open: false,
                strategyHash: bytes32(0),
                params: previews[i],
                baseBalance: 0,
                quoteBalance: 0,
                quoted: false,
                bidPx: 0,
                askPx: 0,
                lean: Side.None,
                regime: Regime({ lean: Side.None, dislocationBps: 0, mapBelow: 0, mapAbove: 0, mapFresh: false }),
                map: LiquidationMap({ belowNotional: 0, aboveNotional: 0, updatedAt: 0 }),
                hedgeArmed: false,
                coverIsBuy: false,
                coverBase: 0,
                coverNotional: 0
            }));
        }
    }

    /// @notice One deployed desk. External so `floor` can reach it through a catchable frame.
    function deskAt(CoreQuote q, address account) external view returns (DeskView memory d) {
        DeskAccount desk = DeskAccount(account);
        DeskParams memory p = desk.params();

        d.account = account;
        d.label = desk.label();
        d.owner = desk.owner();
        d.open = desk.isOpen();
        d.strategyHash = desk.strategyHash();
        d.params = p;
        d.baseBalance = _balance(p.base, account);
        d.quoteBalance = _balance(p.quote, account);
        d.hedgeArmed = desk.hedgeArmed();

        // Disarmed, flat, or an unreadable book all preview as nothing to cover, which is what the
        // hedge column should say in each of those cases anyway.
        try desk.coverPreview() returns (bool would, bool isBuy, uint256 base, uint256 notional) {
            (d.coverIsBuy, d.coverBase, d.coverNotional) = would ? (isBuy, base, notional) : (false, 0, 0);
        } catch { }

        return _quoted(q, p, d);
    }

    /// @notice A parameter set with no desk behind it: what the canonical band would be right now.
    function deskOf(CoreQuote q, DeskParams calldata p) external view returns (DeskView memory d) {
        d.params = p;
        return _quoted(q, p, d);
    }

    /// @notice `HyperCore.l1BlockNumber`, in a frame `floor` can catch. Zero off a real node.
    function l1BlockNumber() external view returns (uint64) {
        return HyperCore.l1BlockNumber();
    }

    /// @dev The three reads that depend on the book, each fail-soft. `quoted` is the one flag the
    ///      page needs: false means this row has no price right now, and the reason is on screen as
    ///      an empty band rather than as a number that was made up to fill it.
    function _quoted(CoreQuote q, DeskParams memory p, DeskView memory d) private view returns (DeskView memory) {
        try q.bounds(p) returns (uint256 bidPx, uint256 askPx, Side lean) {
            (d.quoted, d.bidPx, d.askPx, d.lean) = (true, bidPx, askPx, lean);
        } catch { }
        try q.regime(p) returns (Regime memory r) {
            d.regime = r;
        } catch { }
        if (p.mapOracle != address(0)) {
            try IMapOracle(p.mapOracle).map(p.perpIndex) returns (LiquidationMap memory m) {
                d.map = m;
            } catch { }
        }
        return d;
    }

    function _book(ICoreReader reader, uint32 perpIndex) private view returns (bool ok, Book memory book) {
        try reader.read(perpIndex) returns (Book memory fresh) {
            return (fresh.bid != 0 && fresh.ask != 0 && fresh.mark != 0 && fresh.oracle != 0, fresh);
        } catch {
            return (false, book);
        }
    }

    function _l1Block() private view returns (uint64) {
        try this.l1BlockNumber() returns (uint64 l1) {
            return l1;
        } catch {
            return 0;
        }
    }

    /// @dev A token that is not a token reads as a zero balance, not as a dead row.
    function _balance(address token, address holder) private view returns (uint256) {
        if (token == address(0)) return 0;
        try IERC20(token).balanceOf(holder) returns (uint256 balance) {
            return balance;
        } catch {
            return 0;
        }
    }
}
