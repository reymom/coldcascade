// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { CoreQuote } from "../CoreQuote.sol";
import { Book } from "../interfaces/ICoreReader.sol";
import { DeskParams } from "./DeskParams.sol";
import { HyperCore } from "./HyperCore.sol";

/// @notice Why a cover declined to send.
/// @dev `BelowLot` and `BelowExchangeMinimum` are the two rejections a desk can predict, and
///      predicting them is the point: HyperCore drops a bad order without failing the EVM
///      transaction that carried it, so an order sent into either wall would simply vanish.
enum SkipReason {
    Flat,
    NoNotional,
    BelowLot,
    BelowExchangeMinimum
}

/// @notice One cover's whole decision.
/// @dev `cover` and `coverPreview` compute it the same way and differ only in what they do with
///      it, which is the point: a preview that could disagree with the order is worth nothing.
///      `ok` false carries `reason`; the default is `Flat`, which is also what an empty plan means.
struct Plan {
    bool ok;
    SkipReason reason;
    bool isBuy;
    uint256 baseAmount;
    uint256 notional;
    uint64 limitPx;
    uint64 sz;
    uint64 mark;
}

/// @notice What the desk knows about itself, passed in rather than read from its storage.
/// @dev The library is delegatecalled, so it *could* reach the desk's slots directly. It does not,
///      on purpose: a library that knows a caller's storage layout breaks silently when that
///      layout changes. Everything arrives as an argument, so `plan` is a function of its inputs
///      and can be tested as one.
struct PlanInputs {
    address desk;
    address coreQuote;
    uint256 squareBase;
    uint64 maxNotional;
    uint16 maxSlippageBps;
}

/// @title HedgeOrder
/// @notice The arithmetic that turns a desk's position into one HyperCore order.
///
/// @dev **This is a deployed library, and the reason is HyperEVM's block.** Small blocks cap at
///      3 000 000 gas and code deposit is 200 gas a byte, so a contract's runtime size is a
///      deployment constraint before it is a taker cost. `plan` compiles to 2 186 bytes; inlined
///      into `DeskAccount` it put the implementation at 3 057 556 gas of deploy, over the ceiling.
///      As a `public` library function it is deployed once and delegatecalled, and the account
///      fits again with room for the rest of the week's surface.
///
///      The alternative was opting the deploying address into big blocks — 30 000 000 gas, one
///      minute — with `{"type": "evmUserModify", "usingBigBlocks": true}`. That needs the deployer
///      to hold Core user status and to sign an L1 action, which is a dependency this repo does
///      not otherwise have and would not be able to reproduce from a clean checkout.
library HedgeOrder {
    uint256 private constant BPS = 10_000;
    /// @dev `limitPx` and `sz` are `1e8 * the human readable value`, which is the exchange's scale
    ///      and not the token's. Every conversion below starts here.
    uint256 private constant ORDER_SCALE = 1e8;
    /// @dev *"Order must have minimum value of $10."* Not a policy of ours — an exchange rule, and
    ///      the reason a plan can be fully sized and then declined.
    uint256 private constant MIN_ORDER_USD = 10;
    /// @dev A raw L1 price is `USD * 10 ** (MAX_PRICE_DECIMALS - szDecimals)`.
    uint256 private constant MAX_PRICE_DECIMALS = 6;
    /// @dev *"Prices can have up to 5 significant figures."*
    uint256 private constant PRICE_SIG_FIGS = 100_000;

    error NoMark(uint32 perpIndex);
    /// @dev Every perp on HyperCore today has `szDecimals <= 5`, so both exponents below are
    ///      positive. An asset that broke that would silently underflow into an enormous scale, so
    ///      it is named and rejected instead.
    error PerpScaleUnsupported(uint32 perpIndex, uint8 szDecimals);

    /// @notice Everything one cover would do, decided from live reads and nothing remembered.
    ///
    /// @dev **The whole raw to 1e8 conversion, in one place, all of it read and none of it assumed.**
    ///      Four scales meet here and no two are the same:
    ///
    ///      - the desk's, where a balance is in the base token's own `decimals()` (UBTC: 8);
    ///      - HyperCore's position, where `szi` counts lots of `10 ** -szDecimals` (BTC: 1e-5);
    ///      - the precompiles' prices, `USD * 10 ** (6 - szDecimals)` (BTC: 10);
    ///      - the exchange's order fields, where `limitPx` and `sz` are `1e8 *` the human value.
    ///
    ///      Both legs are converted into the third of those before they are added, because that is
    ///      the only one the answer has to be expressed in.
    ///
    ///      `szDecimals` comes from `0x080a` rather than from `DeskParams`, because it is the
    ///      exchange's property and not the maker's: a desk configured against a stale one would
    ///      round its size onto the wrong grid and never know.
    ///
    ///      Two exchange rules are enforced here rather than discovered as silence:
    ///
    ///      - *"Sizes are rounded to the szDecimals of that asset"* — so `sz` is floored onto that
    ///        grid, and a size under one lot is not sent at all.
    ///      - *"Order must have minimum value of $10"* — checked in the exchange's own terms,
    ///        `sz * mark`, which needs no view on what the quote token is worth.
    ///
    ///      And one is satisfied by construction: *"prices can have up to 5 significant figures,
    ///      but no more than 6 - szDecimals decimal places."* The limit is computed in raw units,
    ///      which already carry exactly that many decimals, and truncated to five significant
    ///      figures before it is scaled up — so no price this builds can be rejected for its shape.
    ///
    ///      Skipping is not failing. A plan that hits the lot grid or the minimum comes back `ok`
    ///      false, and because the desk keeps no counter, the exposure it declined to cover is
    ///      still there to be found on the next call.
    function plan(DeskParams memory p, PlanInputs memory a) public view returns (Plan memory plan_) {

        // The same book the quote was priced from, by construction: CoreQuote's reader, not one
        // this account was configured with separately and could drift from.
        Book memory book = CoreQuote(a.coreQuote).READER().read(p.perpIndex);
        if (book.mark == 0) revert NoMark(p.perpIndex);
        plan_.mark = book.mark;

        uint8 szDecimals = HyperCore.szDecimals(p.perpIndex);
        if (szDecimals > MAX_PRICE_DECIMALS) revert PerpScaleUnsupported(p.perpIndex, szDecimals);
        uint256 lot = 10 ** (8 - szDecimals);
        uint256 baseUnit = 10 ** IERC20Metadata(p.base).decimals();

        // Spot inventory against the level the owner declared square, and the perp position
        // HyperCore says this account holds. Their sum is what is uncovered; its sign is the side.
        int256 spot = (int256(IERC20(p.base).balanceOf(a.desk)) - int256(a.squareBase))
            * int256(ORDER_SCALE) / int256(baseUnit);
        int256 hedged = int256(HyperCore.positionSzi(a.desk, p.perpIndex)) * int256(lot);
        int256 net = spot + hedged;
        if (net == 0) return plan_;

        plan_.isBuy = net < 0;
        uint256 sz = uint256(plan_.isBuy ? -net : net);

        plan_.baseAmount = sz * baseUnit / ORDER_SCALE;
        plan_.notional = plan_.baseAmount * uint256(book.mark) * p.pxNum / p.pxDen;
        if (plan_.notional == 0) {
            plan_.reason = SkipReason.NoNotional;
            return plan_;
        }
        // Over the ceiling, cover up to it. The remainder is not dropped and not remembered: it is
        // simply still uncovered, and the next call reads it again.
        if (plan_.notional > a.maxNotional) sz = Math.mulDiv(sz, a.maxNotional, plan_.notional);

        sz = sz / lot * lot;
        if (sz == 0) {
            plan_.reason = SkipReason.BelowLot;
            return plan_;
        }
        // `sz` is size * 1e8 and `mark` is USD * 10 ** (6 - szDecimals), so their product is the
        // order's dollar value in a scale that cancels without ever naming the quote token.
        if (sz * uint256(book.mark) < MIN_ORDER_USD * ORDER_SCALE * 10 ** (MAX_PRICE_DECIMALS - szDecimals)) {
            plan_.reason = SkipReason.BelowExchangeMinimum;
            return plan_;
        }

        // Recomputed off the size that survived the grid, so the event is the order and not the
        // request. `sz` is floored, never rounded up: the desk under-covers rather than over-sells.
        plan_.sz = uint64(sz);
        plan_.baseAmount = sz * baseUnit / ORDER_SCALE;
        plan_.notional = plan_.baseAmount * uint256(book.mark) * p.pxNum / p.pxDen;

        // A buy lifts the ask, a sell hits the bid. An IOC that does not cross rests for an instant
        // and dies, which HyperCore reports to nobody — hence the owner's bound is applied
        // *through* the touch, not away from it.
        uint256 touch = plan_.isBuy ? uint256(book.ask) : uint256(book.bid);
        uint256 slip = a.maxSlippageBps;
        uint256 raw = plan_.isBuy ? touch * (BPS + slip) / BPS : touch * (BPS - slip) / BPS;
        plan_.limitPx = uint64(_fiveSigFigs(raw, plan_.isBuy) * 10 ** (2 + szDecimals));

        plan_.ok = true;
        }

    /// @dev Truncate to five significant figures, rounding toward whichever side still crosses.
    ///      The limit is a backstop on an order that fills at the book, so at most one step of the
    ///      fifth digit — 0.001% at BTC's price — can sit outside the owner's bound. Rounding the
    ///      other way would keep the bound exact and cost the fill, which is the worse trade: an
    ///      unfilled hedge is an uncovered position that believes it is covered.
    function _fiveSigFigs(uint256 raw, bool roundUp) private pure returns (uint256) {
        uint256 unit = 1;
        uint256 head = raw;
        while (head >= PRICE_SIG_FIGS) {
            head /= 10;
            unit *= 10;
        }
        uint256 truncated = head * unit;
        if (roundUp && truncated != raw) truncated += unit;
        return truncated;
    }
}
