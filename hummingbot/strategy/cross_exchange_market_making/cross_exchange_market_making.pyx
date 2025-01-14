from collections import (
    defaultdict,
    deque
)
from decimal import Decimal
import logging
from math import (
    floor,
    ceil
)
from typing import (
    List,
    Tuple,
    Optional
)
from hummingbot.core.clock cimport Clock
from hummingbot.core.event.events import TradeType
from hummingbot.core.data_type.limit_order cimport LimitOrder
from hummingbot.core.data_type.limit_order import LimitOrder
from hummingbot.core.network_iterator import NetworkStatus
from hummingbot.market.market_base cimport MarketBase
from hummingbot.market.market_base import (
    MarketBase,
    OrderType
)
from hummingbot.core.data_type.order_book import OrderBook
from hummingbot.strategy.strategy_base cimport StrategyBase
from hummingbot.strategy.strategy_base import StrategyBase
from hummingbot.core.utils.exchange_rate_conversion import ExchangeRateConversion

from .cross_exchange_market_pair import CrossExchangeMarketPair
from .order_id_market_pair_tracker import OrderIDMarketPairTracker

NaN = float("nan")
s_decimal_zero = Decimal(0)
s_decimal_nan = Decimal("nan")
s_logger = None


cdef class CrossExchangeMarketMakingStrategy(StrategyBase):
    OPTION_LOG_NULL_ORDER_SIZE = 1 << 0
    OPTION_LOG_REMOVING_ORDER = 1 << 1
    OPTION_LOG_ADJUST_ORDER = 1 << 2
    OPTION_LOG_CREATE_ORDER = 1 << 3
    OPTION_LOG_MAKER_ORDER_FILLED = 1 << 4
    OPTION_LOG_STATUS_REPORT = 1 << 5
    OPTION_LOG_MAKER_ORDER_HEDGED = 1 << 6
    OPTION_LOG_ALL = 0x7fffffffffffffff

    ORDER_ADJUST_SAMPLE_INTERVAL = 5
    ORDER_ADJUST_SAMPLE_WINDOW = 12

    SHADOW_MAKER_ORDER_KEEP_ALIVE_DURATION = 60.0 * 15
    CANCEL_EXPIRY_DURATION = 60.0

    @classmethod
    def logger(cls):
        global s_logger
        if s_logger is None:
            s_logger = logging.getLogger(__name__)
        return s_logger

    def __init__(self,
                 market_pairs: List[CrossExchangeMarketPair],
                 min_profitability: float,
                 order_amount: Optional[float] = 0.0,
                 order_size_taker_volume_factor: float = 0.25,
                 order_size_taker_balance_factor: float = 0.995,
                 order_size_portfolio_ratio_limit: float = 0.1667,
                 limit_order_min_expiration: float = 130.0,
                 adjust_order_enabled: bool = True,
                 anti_hysteresis_duration: float = 60.0,
                 active_order_canceling: bint = True,
                 cancel_order_threshold: float = 0.05,
                 top_depth_tolerance: float = 0,
                 logging_options: int = OPTION_LOG_ALL,
                 status_report_interval: float = 900):
        """
        Initializes a cross exchange market making strategy object.

        :param market_pairs: list of cross exchange market pairs
        :param min_profitability: minimum profitability ratio threshold, for actively cancelling unprofitable orders
        :param order_amount: override the limit order trade size, in base asset unit
        :param order_size_taker_volume_factor: maximum size limit of new limit orders, in terms of ratio of hedge-able
                                               volume on taker side
        :param order_size_taker_balance_factor: maximum size limit of new limit orders, in terms of ratio of asset
                                                balance available for hedging trade on taker side
        :param order_size_portfolio_ratio_limit: maximum size limit of new limit orders, in terms of ratio of total
                                                 portfolio value on both maker and taker markets
        :param limit_order_min_expiration: amount of time after which limit order will expire to be used alongside
                                           cancel_order_threshold
        :param cancel_order_threshold: if active order cancellation is disabled, the hedging loss ratio required for the
                                       strategy to force an order cancellation
        :param active_order_canceling: True if active order cancellation is enabled, False if disabled
        :param anti_hysteresis_duration: the minimum amount of time interval between adjusting limit order prices
        :param logging_options: bit field for what types of logging to enable in this strategy object
        :param status_report_interval: what is the time interval between outputting new network warnings
        """
        if len(market_pairs) < 0:
            raise ValueError(f"market_pairs must not be empty.")
        if not 0 <= order_size_taker_volume_factor <= 1:
            raise ValueError(f"order_size_taker_volume_factor must be between 0 and 1.")
        if not 0 <= order_size_taker_balance_factor <= 1:
            raise ValueError(f"order_size_taker_balance_factor must be between 0 and 1.")

        super().__init__()
        self._market_pairs = {
            (market_pair.maker.market, market_pair.maker.trading_pair): market_pair
            for market_pair in market_pairs
        }
        self._maker_markets = set([market_pair.maker.market for market_pair in market_pairs])
        self._taker_markets = set([market_pair.taker.market for market_pair in market_pairs])
        self._all_markets_ready = False
        self._min_profitability = min_profitability
        self._order_size_taker_volume_factor = order_size_taker_volume_factor
        self._order_size_taker_balance_factor = order_size_taker_balance_factor
        self._order_amount = order_amount
        self._order_size_portfolio_ratio_limit = order_size_portfolio_ratio_limit
        self._anti_hysteresis_timers = {}
        self._order_fill_buy_events = {}
        self._order_fill_sell_events = {}
        self._suggested_price_samples = {}
        self._active_order_canceling = active_order_canceling
        self._anti_hysteresis_duration = anti_hysteresis_duration
        self._cancel_order_threshold = cancel_order_threshold
        self._logging_options = <int64_t>logging_options
        self._last_timestamp = 0
        self._limit_order_min_expiration = limit_order_min_expiration
        self._status_report_interval = status_report_interval
        self._exchange_rate_conversion = ExchangeRateConversion.get_instance()
        self._market_pair_tracker = OrderIDMarketPairTracker()
        self._adjust_orders_enabled = adjust_order_enabled
        self._top_depth_tolerance = top_depth_tolerance

        cdef:
            list all_markets = list(self._maker_markets | self._taker_markets)

        self.c_add_markets(all_markets)

    @property
    def active_maker_orders(self) -> List[Tuple[MarketBase, LimitOrder]]:
        return self._sb_order_tracker.active_maker_orders

    @property
    def cached_maker_orders(self) -> List[Tuple[MarketBase, LimitOrder]]:
        return self._sb_order_tracker.shadow_maker_orders

    @property
    def active_bids(self) -> List[Tuple[MarketBase, LimitOrder]]:
        return [(market, limit_order) for market, limit_order in self.active_maker_orders if limit_order.is_buy]

    @property
    def active_asks(self) -> List[Tuple[MarketBase, LimitOrder]]:
        return [(market, limit_order) for market, limit_order in self.active_maker_orders if not limit_order.is_buy]

    @property
    def logging_options(self) -> int:
        return self._logging_options

    @logging_options.setter
    def logging_options(self, int64_t logging_options):
        self._logging_options = logging_options

    @property
    def exchange_rate_conversion(self) -> ExchangeRateConversion:
        return self._exchange_rate_conversion

    def format_status(self) -> str:
        cdef:
            list lines = []
            list warning_lines = []
            dict tracked_maker_orders = {}
            LimitOrder typed_limit_order

        # Go through the currently open limit orders, and group them by market pair.
        for _, limit_order in self.active_maker_orders:
            typed_limit_order = limit_order
            market_pair = self._market_pair_tracker.c_get_market_pair_from_order_id(typed_limit_order.client_order_id)
            if market_pair not in tracked_maker_orders:
                tracked_maker_orders[market_pair] = {typed_limit_order.client_order_id: typed_limit_order}
            else:
                tracked_maker_orders[market_pair][typed_limit_order.client_order_id] = typed_limit_order

        for market_pair in self._market_pairs.values():
            warning_lines.extend(self.network_warning([market_pair.maker, market_pair.taker]))

            markets_df = self.market_status_data_frame([market_pair.maker, market_pair.taker])
            lines.extend(["", "  Markets:"] +
                         ["    " + line for line in str(markets_df).split("\n")])

            assets_df = self.wallet_balance_data_frame([market_pair.maker, market_pair.taker])
            lines.extend(["", "  Assets:"] +
                         ["    " + line for line in str(assets_df).split("\n")])

            # See if there're any open orders.
            if market_pair in tracked_maker_orders and len(tracked_maker_orders[market_pair]) > 0:
                limit_orders = list(tracked_maker_orders[market_pair].values())
                df = LimitOrder.to_pandas(limit_orders)
                df_lines = str(df).split("\n")
                lines.extend(["", "  Active orders:"] +
                             ["    " + line for line in df_lines])
            else:
                lines.extend(["", "  No active maker orders."])

            warning_lines.extend(self.balance_warning([market_pair.maker, market_pair.taker]))

        if len(warning_lines) > 0:
            lines.extend(["", "  *** WARNINGS ***"] + warning_lines)

        return "\n".join(lines)

    # The following exposed Python functions are meant for unit tests
    # ---------------------------------------------------------------

    def get_order_size_after_portfolio_ratio_limit(self, market_pair: CrossExchangeMarketPair) -> float:
        return self.c_get_order_size_after_portfolio_ratio_limit(market_pair)

    def get_market_making_size(self, market_pair: CrossExchangeMarketPair, bint is_bid) -> float:
        return self.c_get_market_making_size(market_pair, is_bid)

    def get_market_making_price(self, market_pair: CrossExchangeMarketPair, bint is_bid, double size) -> float:
        return self.c_get_market_making_price(market_pair, is_bid, size)

    def get_adjusted_limit_order_size(self, market_pair: CrossExchangeMarketPair) -> float:
        return self.c_get_adjusted_limit_order_size(market_pair)

    def get_effective_hedging_price(self, market_pair: CrossExchangeMarketPair, bint is_bid, double size) -> Decimal:
        return self.c_calculate_effective_hedging_price(market_pair, is_bid, size)

    def check_if_still_profitable(self, market_pair: CrossExchangeMarketPair,
                                  LimitOrder active_order,
                                  double current_hedging_price) -> bool:
        return self.c_check_if_still_profitable(market_pair, active_order, current_hedging_price)

    def check_if_sufficient_balance(self, market_pair: CrossExchangeMarketPair,
                                    LimitOrder active_order) -> bool:
        return self.c_check_if_sufficient_balance(market_pair, active_order)

    # ---------------------------------------------------------------

    cdef c_start(self, Clock clock, double timestamp):
        StrategyBase.c_start(self, clock, timestamp)
        self._last_timestamp = timestamp

    cdef c_tick(self, double timestamp):
        """
        Clock tick entry point.

        For cross exchange market making strategy, this function mostly just checks the readiness and connection
        status of markets, and then delegates the processing of each market pair to c_process_market_pair().

        :param timestamp: current tick timestamp
        """
        StrategyBase.c_tick(self, timestamp)

        cdef:
            int64_t current_tick = <int64_t>(timestamp // self._status_report_interval)
            int64_t last_tick = <int64_t>(self._last_timestamp // self._status_report_interval)
            bint should_report_warnings = ((current_tick > last_tick) and
                                           (self._logging_options & self.OPTION_LOG_STATUS_REPORT))
            list active_maker_orders = self.active_maker_orders
            LimitOrder limit_order

        try:
            # Perform clock tick with the market pair tracker.
            self._market_pair_tracker.c_tick(timestamp)

            if not self._all_markets_ready:
                self._all_markets_ready = all([market.ready for market in self._sb_markets])
                if not self._all_markets_ready:
                    # Markets not ready yet. Don't do anything.
                    if should_report_warnings:
                        self.logger().warning(f"Markets are not ready. No market making trades are permitted.")
                    return
                else:
                    # Markets are ready, ok to proceed.
                    if self.OPTION_LOG_STATUS_REPORT:
                        self.logger().info(f"Markets are ready. Trading started.")

            if should_report_warnings:
                # Check if all markets are still connected or not. If not, log a warning.
                if not all([market.network_status is NetworkStatus.CONNECTED for market in self._sb_markets]):
                    self.logger().warning(f"WARNING: Some markets are not connected or are down at the moment. Market "
                                          f"making may be dangerous when markets or networks are unstable.")

            # Calculate a mapping from market pair to list of active limit orders on the market.
            market_pair_to_active_orders = defaultdict(list)

            for maker_market, limit_order in active_maker_orders:
                market_pair = self._market_pairs.get((maker_market, limit_order.symbol))
                if market_pair is None:
                    self.log_with_clock(logging.WARNING,
                                        f"The in-flight maker order in for the symbol '{limit_order.symbol}' "
                                        f"does not correspond to any whitelisted market pairs. Skipping.")
                    continue

                if not self._sb_order_tracker.c_has_in_flight_cancel(limit_order.client_order_id):
                    market_pair_to_active_orders[market_pair].append(limit_order)

            # Process each market pair independently.
            for market_pair in self._market_pairs.values():
                self.c_process_market_pair(market_pair, market_pair_to_active_orders[market_pair])
        finally:
            self._last_timestamp = timestamp

    cdef c_process_market_pair(self, object market_pair, list active_orders):
        """
        For market pair being managed by this strategy object, do the following:

         1. Check whether any of the existing orders need to be cancelled.
         2. Check if new orders should be created.

        For each market pair, only 1 active bid offer and 1 active ask offer is allowed at a time at maximum.

        If an active order is determined to be not needed at step 1, it would cancel the order within step 1.

        If there's no active order found in step 1, and condition allows (i.e. profitability, account balance, etc.),
        then a new limit order would be created at step 2.

        Combining step 1 and step 2 over time, means the offers made to the maker market side would be adjusted over
        time regularly.

        :param market_pair: cross exchange market pair
        :param active_orders: list of active limit orders associated with the market pair
        """
        cdef:
            object current_hedging_price
            MarketBase taker_market
            bint is_buy
            bint has_active_bid = False
            bint has_active_ask = False
            bint need_adjust_order = False
            double anti_hysteresis_timer = self._anti_hysteresis_timers.get(market_pair, 0)
            dict tracked_taker_orders = self._sb_order_tracker.c_get_taker_orders()

        global s_decimal_zero

        for active_order in active_orders:
            # Mark the has_active_bid and has_active_ask flags
            is_buy = active_order.is_buy
            if is_buy:
                has_active_bid = True
            else:
                has_active_ask = True

            # Suppose the active order is hedged on the taker market right now, what's the average price the hedge
            # would happen?
            current_hedging_price = self.c_calculate_effective_hedging_price(
                market_pair,
                is_buy,
                float(active_order.quantity)
            )

            # See if it's still profitable to keep the order on maker market. If not, remove it.
            if not self.c_check_if_still_profitable(market_pair, active_order, current_hedging_price):
                continue

            if not self._active_order_canceling:
                continue

            # See if I still have enough balance on my wallet to fill the order on maker market, and to hedge the
            # order on taker market. If not, adjust it.
            if not self.c_check_if_sufficient_balance(market_pair, active_order):
                continue

            # If prices have moved, one side is still profitable, here cancel and
            # place at the next tick.
            if self._current_timestamp > anti_hysteresis_timer:
                if not self.c_check_if_price_has_drifted(market_pair, active_order):
                    need_adjust_order = True
                    continue

        # If order adjustment is needed in the next tick, set the anti-hysteresis timer s.t. the next order adjustment
        # for the same pair wouldn't happen within the time limit.
        if need_adjust_order:
            self._anti_hysteresis_timers[market_pair] = self._current_timestamp + self._anti_hysteresis_duration

        # If there's both an active bid and ask, then there's no need to think about making new limit orders.
        if has_active_bid and has_active_ask:
            return

        # If there are pending market orders, wait for them to complete
        if len(tracked_taker_orders.get(market_pair, {})) > 0:
            return

        # See if it's profitable to place a limit order on maker market.
        self.c_check_and_create_new_orders(market_pair, has_active_bid, has_active_ask)

    cdef c_did_fill_order(self, object order_filled_event):
        """
        If a limit order previously made to the maker side has been filled, hedge it on the taker side.
        :param order_filled_event: event object
        """
        cdef:
            str order_id = order_filled_event.order_id
            object market_pair = self._market_pair_tracker.c_get_market_pair_from_order_id(order_id)
            tuple order_fill_record

        # Make sure to only hedge limit orders.
        if market_pair is not None and order_filled_event.order_type is OrderType.LIMIT:
            limit_order_record = self._sb_order_tracker.c_get_shadow_limit_order(order_id)
            order_fill_record = (limit_order_record, order_filled_event)

            # Store the limit order fill event in a map, s.t. it can be processed in c_check_and_hedge_orders()
            # later.
            if order_filled_event.trade_type is TradeType.BUY:
                if market_pair not in self._order_fill_buy_events:
                    self._order_fill_buy_events[market_pair] = [order_fill_record]
                else:
                    self._order_fill_buy_events[market_pair].append(order_fill_record)

                if self._logging_options & self.OPTION_LOG_MAKER_ORDER_FILLED:
                    self.log_with_clock(
                        logging.INFO,
                        f"({market_pair.maker.trading_pair}) Maker buy order of "
                        f"{order_filled_event.amount} {market_pair.maker.base_asset} filled."
                    )

            else:
                if market_pair not in self._order_fill_sell_events:
                    self._order_fill_sell_events[market_pair] = [order_fill_record]
                else:
                    self._order_fill_sell_events[market_pair].append(order_fill_record)

                if self._logging_options & self.OPTION_LOG_MAKER_ORDER_FILLED:
                    self.log_with_clock(
                        logging.INFO,
                        f"({market_pair.maker.trading_pair}) Maker sell order of "
                        f"{order_filled_event.amount} {market_pair.maker.base_asset} filled."
                    )

            # Call c_check_and_hedge_orders() to emit the market orders on the taker side.
            try:
                self.c_check_and_hedge_orders(market_pair)
            except Exception:
                self.log_with_clock(logging.ERROR, "Unexpected error.", exc_info=True)

    cdef c_did_complete_buy_order(self, object order_completed_event):
        """
        Output log message when a bid order (on maker side or taker side) is completely taken.
        :param order_completed_event: event object
        """
        cdef:
            str order_id = order_completed_event.order_id
            object market_pair = self._market_pair_tracker.c_get_market_pair_from_order_id(order_id)
            LimitOrder limit_order_record
            object order_type = order_completed_event.order_type

        if market_pair is not None:
            if order_type == OrderType.LIMIT:
                limit_order_record = self._sb_order_tracker.c_get_limit_order(market_pair.maker, order_id)
                self.log_with_clock(
                    logging.INFO,
                    f"({market_pair.maker.trading_pair}) Maker buy order {order_id} "
                    f"({limit_order_record.quantity} {limit_order_record.base_currency} @ "
                    f"{limit_order_record.price} {limit_order_record.quote_currency}) has been completely filled."
                )
            if order_type == OrderType.MARKET:
                market_order_record = self._sb_order_tracker.c_get_market_order(market_pair.taker, order_id)
                if market_order_record is not None:
                    self.log_with_clock(
                        logging.INFO,
                        f"({market_pair.taker.trading_pair}) Taker buy order {order_id} for "
                        f"({market_order_record.amount} {market_order_record.base_asset} has been completely filled."
                    )

    cdef c_did_complete_sell_order(self, object order_completed_event):
        """
        Output log message when a ask order (on maker side or taker side) is completely taken.
        :param order_completed_event: event object
        """
        cdef:
            str order_id = order_completed_event.order_id
            object market_pair = self._market_pair_tracker.c_get_market_pair_from_order_id(order_id)
            LimitOrder limit_order_record

        order_type = order_completed_event.order_type
        if market_pair is not None:
            if order_type == OrderType.LIMIT:
                limit_order_record = self._sb_order_tracker.c_get_limit_order(market_pair.maker, order_id)
                self.log_with_clock(
                    logging.INFO,
                    f"({market_pair.maker.trading_pair}) Maker sell order {order_id} "
                    f"({limit_order_record.quantity} {limit_order_record.base_currency} @ "
                    f"{limit_order_record.price} {limit_order_record.quote_currency}) has been completely filled."
                )
            if order_type == OrderType.MARKET:
                market_order_record = self._sb_order_tracker.c_get_market_order(market_pair.taker, order_id)
                if market_order_record is not None:
                    self.log_with_clock(
                        logging.INFO,
                        f"({market_pair.taker.trading_pair}) Taker sell order {order_id} for "
                        f"({market_order_record.amount} {market_order_record.base_asset} has been completely filled."
                    )

    cdef bint c_check_if_price_has_drifted(self, object market_pair, LimitOrder active_order):
        """
        Given a currently active limit order on maker side, check if its current price is still valid, based on the
        current hedging price on taker market, depth tolerance, and transient orders on the maker market captured by
        recent suggested price samples.

        If the active order's price is no longer valid, the order will be cancelled.

        This function is only used when active order cancellation is enabled.

        :param market_pair: cross exchange market pair
        :param active_order: a current active limit order in the market pair
        :return: True if the order stays, False if the order has been cancelled and we need to re place the orders.
        """
        cdef:
            bint is_buy = active_order.is_buy
            double order_price = float(active_order.price)
            double order_quantity = float(active_order.quantity)
            double suggested_price

        suggested_price = float(self.c_get_market_making_price(market_pair, is_buy, order_quantity))

        if suggested_price != order_price:

            if is_buy:
                if self._logging_options & self.OPTION_LOG_ADJUST_ORDER:
                    self.log_with_clock(
                        logging.INFO,
                        f"({market_pair.maker.trading_pair}) The current limit bid order for "
                        f"{active_order.quantity} {market_pair.maker.base_asset} at "
                        f"{order_price:.8g} {market_pair.maker.quote_asset} is now below the suggested order "
                        f"price at {suggested_price}. Going to cancel the old order and create a new one..."
                    )
                self.c_cancel_order(market_pair, active_order.client_order_id)
                self.log_with_clock(logging.DEBUG,
                                    f"Current buy order price={order_price}, "
                                    f"suggested order price={suggested_price}")
                return False
            else:
                if self._logging_options & self.OPTION_LOG_ADJUST_ORDER:
                    self.log_with_clock(
                        logging.INFO,
                        f"({market_pair.maker.trading_pair}) The current limit ask order for "
                        f"{active_order.quantity} {market_pair.maker.base_asset} at "
                        f"{order_price:.8g} {market_pair.maker.quote_asset} is now below the suggested order "
                        f"price at {suggested_price}. Going to cancel the old order and create a new one..."
                    )
                self.c_cancel_order(market_pair, active_order.client_order_id)
                self.log_with_clock(logging.DEBUG,
                                    f"Current sell order price={order_price}, "
                                    f"suggested order price={suggested_price}")
                return False

        return True

    cdef c_check_and_hedge_orders(self, object market_pair):
        """
        Look into the stored and un-hedged limit order fill events, and emit market orders to hedge them, depending on
        availability of funds on the taker market.

        :param market_pair: cross exchange market pair
        """
        cdef:
            MarketBase taker_market = market_pair.taker.market
            str taker_symbol = market_pair.taker.trading_pair
            OrderBook taker_order_book = market_pair.taker.order_book
            list buy_fill_records = self._order_fill_buy_events.get(market_pair, [])
            list sell_fill_records = self._order_fill_sell_events.get(market_pair, [])
            double buy_fill_quantity = sum([fill_event.amount for _, fill_event in buy_fill_records])
            double sell_fill_quantity = sum([fill_event.amount for _, fill_event in sell_fill_records])
            double taker_top
            double hedged_order_quantity
            double avg_fill_price

        global s_decimal_zero

        if buy_fill_quantity > 0:
            hedged_order_quantity = min(
                buy_fill_quantity,
                (taker_market.c_get_available_balance(market_pair.taker.base_asset) *
                 self._order_size_taker_balance_factor)
            )
            quantized_hedge_amount = taker_market.c_quantize_order_amount(taker_symbol, hedged_order_quantity)
            taker_top = taker_market.c_get_price(taker_symbol, False)
            avg_fill_price = (sum([r.price * r.amount for _, r in buy_fill_records]) /
                              sum([r.amount for _, r in buy_fill_records]))

            if quantized_hedge_amount > s_decimal_zero:
                self.c_sell_with_specific_market(market_pair, quantized_hedge_amount)

                del self._order_fill_buy_events[market_pair]
                if self._logging_options & self.OPTION_LOG_MAKER_ORDER_HEDGED:
                    self.log_with_clock(
                        logging.INFO,
                        f"({market_pair.maker.trading_pair}) Hedged maker buy order(s) of "
                        f"{buy_fill_quantity} {market_pair.maker.base_asset} on taker market to lock in profits. "
                        f"(maker avg price={avg_fill_price}, taker top={taker_top})"
                    )
            else:
                self.log_with_clock(
                    logging.INFO,
                    f"({market_pair.maker.trading_pair}) Current maker buy fill amount of "
                    f"{buy_fill_quantity} {market_pair.maker.base_asset} is less than the minimum order amount "
                    f"allowed on the taker market. No hedging possible yet."
                )

        if sell_fill_quantity > 0:
            hedged_order_quantity = min(
                sell_fill_quantity,
                (taker_market.c_get_available_balance(market_pair.taker.quote_asset) /
                 taker_order_book.c_get_price_for_volume(True, sell_fill_quantity).result_price *
                 self._order_size_taker_balance_factor)
            )
            quantized_hedge_amount = taker_market.c_quantize_order_amount(taker_symbol, hedged_order_quantity)
            taker_top = taker_market.c_get_price(taker_symbol, True)
            avg_fill_price = (sum([r.price * r.amount for _, r in sell_fill_records]) /
                              sum([r.amount for _, r in sell_fill_records]))

            if quantized_hedge_amount > s_decimal_zero:
                self.c_buy_with_specific_market(market_pair, quantized_hedge_amount)

                del self._order_fill_sell_events[market_pair]
                if self._logging_options & self.OPTION_LOG_MAKER_ORDER_HEDGED:
                    self.log_with_clock(
                        logging.INFO,
                        f"({market_pair.maker.trading_pair}) Hedged maker sell order(s) of "
                        f"{sell_fill_quantity} {market_pair.maker.base_asset} on taker market to lock in profits. "
                        f"(maker avg price={avg_fill_price}, taker top={taker_top})"
                    )
            else:
                self.log_with_clock(
                    logging.INFO,
                    f"({market_pair.maker.trading_pair}) Current maker sell fill amount of "
                    f"{sell_fill_quantity} {market_pair.maker.base_asset} is less than the minimum order amount "
                    f"allowed on the taker market. No hedging possible yet."
                )

    cdef object c_get_adjusted_limit_order_size(self, object market_pair):
        """
        Given the proposed order size of a proposed limit order (regardless of bid or ask), adjust and refine the order
        sizing according to either the trade size override setting (if it exists), or the portfolio ratio limit (if
        no trade size override exists).

        Also, this function will convert the input order size proposal from floating point to Decimal by quantizing the
        order size.

        :param market_pair: cross exchange market pair
        :rtype: Decimal
        """
        cdef:
            MarketBase maker_market = market_pair.maker.market
            str symbol = market_pair.maker.trading_pair
            double adjusted_order_size

        if self._order_amount and self._order_amount > 0:
            base_order_size = self._order_amount
            return maker_market.c_quantize_order_amount(symbol, base_order_size)
        else:
            return self.c_get_order_size_after_portfolio_ratio_limit(market_pair)

    cdef object c_get_order_size_after_portfolio_ratio_limit(self, object market_pair):
        """
        Given the proposed order size of a proposed limit order (regardless of bid or ask), adjust the order sizing
        according to the portfolio ratio limit.

        Also, this function will convert the input order size proposal from floating point to Decimal by quantizing the
        order size.

        :param market_pair: cross exchange market pair
        :rtype: Decimal
        """
        cdef:
            MarketBase maker_market = market_pair.maker.market
            str symbol = market_pair.maker.trading_pair
            double base_balance = maker_market.c_get_balance(market_pair.maker.base_asset)
            double quote_balance = maker_market.c_get_balance(market_pair.maker.quote_asset)
            double current_price = (maker_market.c_get_price(symbol, True) +
                                    maker_market.c_get_price(symbol, False)) * 0.5
            double maker_portfolio_value = base_balance + quote_balance / current_price
            double adjusted_order_size = maker_portfolio_value * self._order_size_portfolio_ratio_limit

        return maker_market.c_quantize_order_amount(symbol, adjusted_order_size)

    cdef object c_get_market_making_size(self,
                                         object market_pair,
                                         bint is_bid):
        """
        Get the ideal market making order size given a market pair and a side.

        This function does a few things:
         1. Calculate the largest order size possible given the current balances on both maker and taker markets.
         2. Calculate the largest order size possible that's still profitable after hedging.


        :param market_pair: The cross exchange market pair to calculate order price/size limits.
        :param is_bid: Whether the order to make will be bid or ask.
        :return: a Decimal which is the size of maker order.
        """
        cdef:
            MarketBase maker_market = market_pair.maker.market
            MarketBase taker_market = market_pair.taker.market
            OrderBook taker_order_book = market_pair.taker.order_book

        if is_bid:

            maker_balance_in_quote = maker_market.c_get_available_balance(market_pair.maker.quote_asset)

            taker_balance = (taker_market.c_get_available_balance(market_pair.taker.base_asset) *
                             self._order_size_taker_balance_factor)

            user_order = self.c_get_adjusted_limit_order_size(market_pair)

            try:
                taker_price = taker_order_book.c_get_vwap_for_volume(False, user_order).result_price
            except ZeroDivisionError:
                top_ask_price = taker_order_book.c_get_price(True)
                taker_price = top_ask_price

            maker_balance = maker_balance_in_quote / taker_price
            order_amount = min(maker_balance, taker_balance, user_order)

            return maker_market.c_quantize_order_amount(market_pair.maker.trading_pair, order_amount)

        else:

            maker_balance = maker_market.c_get_available_balance(market_pair.maker.base_asset)

            taker_balance_in_quote = (taker_market.c_get_available_balance(market_pair.taker.quote_asset) *
                                      self._order_size_taker_balance_factor)

            user_order = self.c_get_adjusted_limit_order_size(market_pair)

            try:
                taker_price = taker_order_book.c_get_vwap_for_volume(True, user_order).result_price
            except ZeroDivisionError:
                top_bid_price = taker_order_book.c_get_price(True)
                taker_price = top_bid_price

            taker_balance = taker_balance_in_quote / taker_price
            order_amount = min(maker_balance, taker_balance, user_order)

            return maker_market.c_quantize_order_amount(market_pair.maker.trading_pair, order_amount)

    cdef object c_get_market_making_price(self,
                                          object market_pair,
                                          bint is_bid,
                                          double size):
        """
        Get the ideal market making order price given a market pair, side and size.

        The price returned is calculated by adding the profitability to vwap of hedging it on the taker side.
        or if it's not possible to hedge the trade profitably, then the returned order price will be none.

        :param market_pair: The cross exchange market pair to calculate order price/size limits.
        :param is_bid: Whether the order to make will be bid or ask.
        :param size: size of the order.
        :return: a Decimal which is the price or None if order cannot be hedged on the taker market
        """
        cdef:
            MarketBase maker_market = market_pair.maker.market
            MarketBase taker_market = market_pair.taker.market
            OrderBook taker_order_book = market_pair.taker.order_book
            OrderBook maker_order_book = market_pair.maker.order_book
            double top_bid_price
            double top_ask_price
            double raw_size_limit

        top_bid_price, top_ask_price = self.c_get_top_bid_ask_from_price_samples(market_pair)

        if is_bid:
            # Calculate the next price above top bid
            price_quantum = maker_market.c_get_order_price_quantum(
                market_pair.maker.trading_pair,
                top_bid_price
            )
            price_above_bid = (ceil(Decimal(top_bid_price) / price_quantum) + 1) * price_quantum

            try:
                taker_price = taker_order_book.c_get_vwap_for_volume(False,
                                                                     size).result_price
            except ZeroDivisionError:
                return None

            # If quote assets are not same, convert them from taker's quote asset to maker's quote asset
            if market_pair.maker.quote_asset != market_pair.taker.quote_asset:
                taker_price *= self._exchange_rate_conversion.convert_token_value(1,
                                                                                  market_pair.taker.quote_asset,
                                                                                  market_pair.maker.quote_asset)

            # you are buying on the maker market and selling on the taker market
            maker_price = taker_price / (1 + self._min_profitability)

            if self._adjust_orders_enabled:
                # If your bid is higher than highest bid price, reduce it to one tick above the top bid price
                maker_price = min(maker_price, price_above_bid)

            price_quantum = maker_market.c_get_order_price_quantum(
                market_pair.maker.trading_pair,
                maker_price
            )

            # Rounds down for ensuring profitability
            maker_price = (floor(Decimal(maker_price) / price_quantum)) * price_quantum

            return maker_price
        else:
            # Calculate the next price below top ask
            price_quantum = maker_market.c_get_order_price_quantum(
                market_pair.maker.trading_pair,
                top_ask_price
            )
            next_price_below_top_ask = (floor(Decimal(top_ask_price) / price_quantum) - 1) * price_quantum

            try:
                taker_price = taker_order_book.c_get_vwap_for_volume(True,
                                                                     size).result_price
            except ZeroDivisionError:
                return None

            if market_pair.maker.quote_asset != market_pair.taker.quote_asset:
                taker_price *= self._exchange_rate_conversion.convert_token_value(1,
                                                                                  market_pair.taker.quote_asset,
                                                                                  market_pair.maker.quote_asset)

            # You are buying on the taker market and selling on the maker market
            maker_price = taker_price * (1 + self._min_profitability)

            if self._adjust_orders_enabled:
                # If your ask is lower than the the top ask, increase it to just one tick below top ask
                maker_price = max(maker_price, next_price_below_top_ask)

            price_quantum = maker_market.c_get_order_price_quantum(
                market_pair.maker.trading_pair,
                maker_price
            )

            # Rounds up for ensuring profitability
            maker_price = (ceil(Decimal(maker_price) / price_quantum)) * price_quantum

            return maker_price

    cdef object c_calculate_effective_hedging_price(self,
                                                    object market_pair,
                                                    bint is_bid,
                                                    double size):
        """
        Get the ideal market making order size and maximum order size given a market pair and a side.

        This function does a few things:
         1. Get the widest possible order price for market making on the maker market.
         2. Calculate the largest order size possible given the current balances on both maker and taker markets.
         3. Calculate the largest order size possible that's still profitable after hedging.

        The price returned is calculated from step 1. The order size returned is the minimum from 2 and 3. If either
        there's not enough balance for the maker order or the hedging trade; or if it's not possible to hedge the
        trade profitably, then the returned order size will be 0.

        :param market_pair: The cross exchange market pair to calculate order price/size limits.
        :param is_bid: Whether the order to make will be bid or ask.
        :param size: The size of the maker order.
        :return: a Decimal which is the hedging price
        """
        cdef:
            OrderBook taker_order_book = market_pair.taker.order_book

        # Calculate the next price from the top, and the order size limit.
        if is_bid:

            try:
                taker_price = taker_order_book.c_get_vwap_for_volume(False,
                                                                     size).result_price
            except ZeroDivisionError:
                return None

            # If quote assets are not same, convert them from taker's quote asset to maker's quote asset
            if market_pair.maker.quote_asset != market_pair.taker.quote_asset:
                taker_price *= self._exchange_rate_conversion.convert_token_value(1,
                                                                                  market_pair.taker.quote_asset,
                                                                                  market_pair.maker.quote_asset)

            return taker_price
        else:

            try:
                taker_price = taker_order_book.c_get_vwap_for_volume(True,
                                                                     size).result_price
            except ZeroDivisionError:
                return None

            if market_pair.maker.quote_asset != market_pair.taker.quote_asset:
                taker_price *= self._exchange_rate_conversion.convert_token_value(1,
                                                                                  market_pair.taker.quote_asset,
                                                                                  market_pair.maker.quote_asset)

            return taker_price

    cdef tuple c_get_suggested_price_samples(self, object market_pair):
        """
        Get the queues of order book price samples for a market pair.

        :param market_pair: The market pair under which samples were collected for.
        :return: (bid order price samples, ask order price samples)
        """
        if market_pair in self._suggested_price_samples:
            return self._suggested_price_samples[market_pair]
        return deque(), deque()

    cdef tuple c_get_top_bid_ask(self, object market_pair):
        """
        Calculate the top bid and ask using top depth tolerance in maker order book

        :param market_pair: cross exchange market pair
        :return: (top bid, top ask)
        """
        cdef:
            OrderBook maker_order_book = market_pair.maker.order_book

        if self._top_depth_tolerance == 0:

            top_bid_price = maker_order_book.c_get_price(False)

            top_ask_price = maker_order_book.c_get_price(True)

        else:
            # Use bid entries in maker order book
            top_bid_price = maker_order_book.c_get_price_for_volume(False, self._top_depth_tolerance)

            # Use ask entries in maker order book
            top_ask_price = maker_order_book.c_get_price_for_volume(True, self._top_depth_tolerance)

        return top_bid_price, top_ask_price

    cdef c_take_suggested_price_sample(self, object market_pair):
        """
        Record the bid and ask sample queues.

        These samples are later taken to check if price has drifted for new limit orders, s.t. new limit orders can
        properly take into account transient orders that appear and disappear frequently on the maker market.

        :param market_pair: cross exchange market pair
        """
        cdef:
            OrderBook maker_order_book = market_pair.maker.order_book

        if ((self._last_timestamp // self.ORDER_ADJUST_SAMPLE_INTERVAL) <
                (self._current_timestamp // self.ORDER_ADJUST_SAMPLE_INTERVAL)):
            if market_pair not in self._suggested_price_samples:
                self._suggested_price_samples[market_pair] = (deque(), deque())

            top_bid_price, top_ask_price = self.c_get_top_bid_ask_from_price_samples(market_pair)

            bid_price_samples_deque, ask_price_samples_deque = self._suggested_price_samples[market_pair]
            bid_price_samples_deque.append(top_bid_price)
            ask_price_samples_deque.append(top_ask_price)
            while len(bid_price_samples_deque) > self.ORDER_ADJUST_SAMPLE_WINDOW:
                bid_price_samples_deque.popleft()
            while len(ask_price_samples_deque) > self.ORDER_ADJUST_SAMPLE_WINDOW:
                ask_price_samples_deque.popleft()

    cdef tuple c_get_top_bid_ask_from_price_samples(self,
                                                    object market_pair):
        """
        Calculate the top bid and ask using earlier samples

        :param market_pair: cross exchange market pair
        :return: (top bid, top ask)
        """
        # Incorporate the past bid price samples.
        current_top_bid_price, current_top_ask_price = self.c_get_top_bid_ask(market_pair)

        bid_price_samples, ask_price_samples = self.c_get_suggested_price_samples(market_pair)

        top_bid_price = max(list(bid_price_samples) + [current_top_bid_price])

        # Incorporate the past ask price samples.
        top_ask_price = min(list(ask_price_samples) + [current_top_ask_price])

        return top_bid_price, top_ask_price

    cdef bint c_check_if_still_profitable(self,
                                          object market_pair,
                                          LimitOrder active_order,
                                          object current_hedging_price):
        """
        Check whether a currently active limit order should be cancelled or not, according to profitability metric.

        If active order canceling is enabled (e.g. for centralized exchanges), then the min profitability config is
        used as the threshold. If it is disabled (e.g. for decentralized exchanges), then the cancel order threshold
        is used instead.

        :param market_pair: cross exchange market pair
        :param active_order: the currently active order to check for cancellation
        :param current_hedging_price: the current average hedging price on taker market for the limit order
        :return: True if the limit order stays, False if the limit order is being cancelled.
        """
        cdef:
            bint is_buy = active_order.is_buy
            str limit_order_type_str = "bid" if is_buy else "ask"
            double order_price = float(active_order.price)
            double cancel_order_threshold

        if not self._active_order_canceling:
            cancel_order_threshold = self._cancel_order_threshold
        else:
            cancel_order_threshold = self._min_profitability

        if current_hedging_price is None:
            if self._logging_options & self.OPTION_LOG_REMOVING_ORDER:
                self.log_with_clock(
                    logging.INFO,
                    f"({market_pair.maker.trading_pair}) Limit {limit_order_type_str} order at "
                    f"{order_price:.8g} {market_pair.maker.quote_asset} is no longer profitable. "
                    f"Removing the order."
                )
            self.c_cancel_order(market_pair, active_order.client_order_id)
            return False
        else:
            current_hedging_price = float(current_hedging_price)

        if ((is_buy and current_hedging_price < order_price * (1 + cancel_order_threshold)) or
                (not is_buy and order_price < current_hedging_price * (1 + cancel_order_threshold))):

            if self._logging_options & self.OPTION_LOG_REMOVING_ORDER:
                self.log_with_clock(
                    logging.INFO,
                    f"({market_pair.maker.trading_pair}) Limit {limit_order_type_str} order at "
                    f"{order_price:.8g} {market_pair.maker.quote_asset} is no longer profitable. "
                    f"Removing the order."
                )
            self.c_cancel_order(market_pair, active_order.client_order_id)
            return False
        return True

    cdef bint c_check_if_sufficient_balance(self, object market_pair, LimitOrder active_order):
        """
        Check whether there's enough asset balance for a currently active limit order. If there's not enough asset
        balance for the order (e.g. because the required asset has been moved), cancel the active order.

        This function is only used when active order cancelled is enabled.

        :param market_pair: cross exchange market pair
        :param active_order: current limit order
        :return: True if there's sufficient balance for the limit order, False if there isn't and the order is being
                 cancelled.
        """
        cdef:
            bint is_buy = active_order.is_buy
            double order_price = float(active_order.price)
            MarketBase maker_market = market_pair.maker.market
            MarketBase taker_market = market_pair.taker.market

            double quote_asset_amount = maker_market.c_get_balance(market_pair.maker.quote_asset) if is_buy else \
                taker_market.c_get_balance(market_pair.taker.quote_asset)
            double base_asset_amount = taker_market.c_get_balance(market_pair.taker.base_asset) if is_buy else \
                maker_market.c_get_balance(market_pair.maker.base_asset)
            double order_size_limit

        order_size_limit = min(base_asset_amount, quote_asset_amount / order_price)
        quantized_size_limit = maker_market.c_quantize_order_amount(active_order.symbol, order_size_limit)

        if active_order.quantity > quantized_size_limit:
            if self._logging_options & self.OPTION_LOG_ADJUST_ORDER:
                self.log_with_clock(
                    logging.INFO,
                    f"({market_pair.maker.trading_pair}) Order size limit ({order_size_limit:.8g}) "
                    f"is now less than the current active order amount ({active_order.quantity:.8g}). "
                    f"Going to adjust the order."
                )
            self.c_cancel_order(market_pair, active_order.client_order_id)
            return False
        return True

    cdef c_check_and_create_new_orders(self, object market_pair, bint has_active_bid, bint has_active_ask):
        """
        Check and account for all applicable conditions for creating new limit orders (e.g. profitability, what's the
        right price given depth tolerance and transient orders on the market, account balances, etc.), and create new
        limit orders for market making.

        :param market_pair: cross exchange market pair
        :param has_active_bid: True if there's already an active bid on the maker side, False otherwise
        :param has_active_ask: True if there's already an active ask on the maker side, False otherwise
        """
        cdef:
            double effective_hedging_price

        # if there is no active bid, place bid again
        if not has_active_bid:
            bid_size = self.c_get_market_making_size(market_pair, True)

            # Check if bid size is greater than zero
            if bid_size > s_decimal_zero:

                bid_price = self.c_get_market_making_price(market_pair, True, bid_size)

                if bid_price is not None:
                    effective_hedging_price = self.c_calculate_effective_hedging_price(
                        market_pair,
                        True,
                        float(bid_size)
                    )
                    effective_hedging_price_adjusted = self._exchange_rate_conversion.adjust_token_rate(
                        market_pair.taker.quote_asset, effective_hedging_price
                    )
                    if self._logging_options & self.OPTION_LOG_CREATE_ORDER:
                        self.log_with_clock(
                            logging.INFO,
                            f"({market_pair.maker.trading_pair}) Creating limit bid order for "
                            f"{bid_size} {market_pair.maker.base_asset} at "
                            f"{bid_price} {market_pair.maker.quote_asset}. "
                            f"Current hedging price: {effective_hedging_price} {market_pair.taker.quote_asset} "
                            f"(Rate adjusted: {effective_hedging_price_adjusted:.2f} {market_pair.taker.quote_asset})."
                        )
                    self.c_buy_with_specific_market(
                        market_pair,
                        bid_size,
                        order_type=OrderType.LIMIT,
                        price=bid_price
                    )
                else:
                    if self._logging_options & self.OPTION_LOG_NULL_ORDER_SIZE:
                        self.log_with_clock(
                            logging.WARNING,
                            f"({market_pair.maker.trading_pair})"
                            f"Order book on taker is too thin to place order for size: {bid_size}"
                            f"Reduce order_size_portfolio_ratio_limit"
                        )
            else:
                if self._logging_options & self.OPTION_LOG_NULL_ORDER_SIZE:
                    self.log_with_clock(
                        logging.WARNING,
                        f"({market_pair.maker.trading_pair}) Attempting to place a limit bid but the "
                        f"bid size is 0. Skipping. Check available balance."
                    )
        # if there is no active ask, place ask again
        if not has_active_ask:
            ask_size = self.c_get_market_making_size(market_pair, False)

            # Check if ask size is greater than zero
            if ask_size > s_decimal_zero:

                ask_price = self.c_get_market_making_price(market_pair, False, ask_size)

                if ask_price is not None:
                    effective_hedging_price = self.c_calculate_effective_hedging_price(
                        market_pair,
                        False,
                        float(ask_size)
                    )
                    effective_hedging_price_adjusted = self._exchange_rate_conversion.adjust_token_rate(
                        market_pair.maker.quote_asset, effective_hedging_price
                    )
                    if self._logging_options & self.OPTION_LOG_CREATE_ORDER:
                        self.log_with_clock(
                            logging.INFO,
                            f"({market_pair.maker.trading_pair}) Creating limit ask order for "
                            f"{ask_size} {market_pair.maker.base_asset} at "
                            f"{ask_price} {market_pair.maker.quote_asset}. "
                            f"Current hedging price: {effective_hedging_price} {market_pair.maker.quote_asset} "
                            f"(Rate adjusted: {effective_hedging_price_adjusted:.2f} {market_pair.maker.quote_asset})."
                        )
                    self.c_sell_with_specific_market(
                        market_pair,
                        ask_size,
                        order_type=OrderType.LIMIT,
                        price=ask_price
                    )
                else:
                    if self._logging_options & self.OPTION_LOG_NULL_ORDER_SIZE:
                        self.log_with_clock(
                            logging.WARNING,
                            f"({market_pair.maker.trading_pair})"
                            f"Order book on taker is too thin to place order for size: {ask_size}"
                            f"Reduce order_size_portfolio_ratio_limit"
                        )
            else:
                if self._logging_options & self.OPTION_LOG_NULL_ORDER_SIZE:
                    self.log_with_clock(
                        logging.WARNING,
                        f"({market_pair.maker.trading_pair}) Attempting to place a limit ask but the "
                        f"ask size is 0. Skipping. Check available balance."
                    )

    # <editor-fold desc="+ Creating and canceling orders">
    # Override the default buy, sell and cancel functions to allow the use of XEMM market pair, and the correct
    # attribution of trades to XEMM market pairs.
    # ----------------------------------------------------------------------------------------------------------
    cdef str c_buy_with_specific_market(self, object market_pair, object amount,
                                        object order_type=OrderType.MARKET,
                                        object price=s_decimal_nan,
                                        double expiration_seconds=NaN):
        if not isinstance(market_pair, CrossExchangeMarketPair):
            raise TypeError("market_pair must be a CrossExchangeMarketPair.")

        market_symbol_pair = market_pair.maker if order_type is OrderType.LIMIT else market_pair.taker

        if not self._active_order_canceling:
            expiration_seconds = self._limit_order_min_expiration

        cdef:
            str order_id = StrategyBase.c_buy_with_specific_market(self, market_symbol_pair, amount,
                                                                   order_type=order_type, price=price,
                                                                   expiration_seconds=expiration_seconds)
        self._market_pair_tracker.c_start_tracking_order_id(order_id, market_pair)
        return order_id

    cdef str c_sell_with_specific_market(self, object market_pair, object amount,
                                         object order_type=OrderType.MARKET,
                                         object price=s_decimal_nan,
                                         double expiration_seconds=NaN):
        if not isinstance(market_pair, CrossExchangeMarketPair):
            raise TypeError("market_pair must be a CrossExchangeMarketPair.")

        market_symbol_pair = market_pair.maker if order_type is OrderType.LIMIT else market_pair.taker

        if not self._active_order_canceling:
            expiration_seconds = self._limit_order_min_expiration

        cdef:
            str order_id = StrategyBase.c_sell_with_specific_market(self, market_symbol_pair, amount,
                                                                    order_type=order_type, price=price,
                                                                    expiration_seconds=expiration_seconds)
        self._market_pair_tracker.c_start_tracking_order_id(order_id, market_pair)
        return order_id

    cdef c_cancel_order(self, object market_pair, str order_id):
        market_symbol_pair = self._sb_order_tracker.c_get_market_pair_from_order_id(order_id)
        StrategyBase.c_cancel_order(self, market_symbol_pair, order_id)
    # ----------------------------------------------------------------------------------------------------------
    # </editor-fold>

    # <editor-fold desc="+ Order tracking entry points">
    # Override the stop tracking entry points to include the market pair tracker as well.
    # ----------------------------------------------------------------------------------------------------------
    cdef c_stop_tracking_limit_order(self, object market_symbol_pair, str order_id):
        self._market_pair_tracker.c_stop_tracking_order_id(order_id)
        StrategyBase.c_stop_tracking_limit_order(self, market_symbol_pair, order_id)

    cdef c_stop_tracking_market_order(self, object market_symbol_pair, str order_id):
        self._market_pair_tracker.c_stop_tracking_order_id(order_id)
        StrategyBase.c_stop_tracking_market_order(self, market_symbol_pair, order_id)
    # ----------------------------------------------------------------------------------------------------------
    # </editor-fold>
