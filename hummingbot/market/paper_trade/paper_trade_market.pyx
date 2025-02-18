# distutils: sources=['hummingbot/core/cpp/Utils.cpp', 'hummingbot/core/cpp/LimitOrder.cpp', 'hummingbot/core/cpp/OrderExpirationEntry.cpp']

import asyncio
from async_timeout import timeout
from collections import deque, defaultdict
from cpython cimport PyObject
from cython.operator cimport (
    postincrement as inc,
    dereference as deref,
    address
)
from decimal import Decimal
from functools import partial
import hummingbot
from libcpp cimport bool as cppbool
from libcpp.vector cimport vector
import logging
import math
import pandas as pd
import random
import time
from typing import (
    Dict,
    List,
    Coroutine,
    Tuple)

from hummingbot.core.clock cimport Clock
from hummingbot.core.clock import (
    ClockMode,
    Clock
)
from hummingbot.core.Utils cimport (
    getIteratorFromReverseIterator,
    reverse_iterator
)
from hummingbot.core.data_type.cancellation_result import CancellationResult
from hummingbot.core.data_type.composite_order_book import CompositeOrderBook
from hummingbot.core.data_type.composite_order_book cimport CompositeOrderBook
from hummingbot.core.data_type.limit_order cimport c_create_limit_order_from_cpp_limit_order
from hummingbot.core.data_type.limit_order import LimitOrder
from hummingbot.core.data_type.order_book cimport OrderBook
from hummingbot.core.data_type.order_book_tracker import OrderBookTracker
from hummingbot.core.event.events import (
    MarketEvent,
    OrderType,
    OrderExpiredEvent,
    TradeType,
    TradeFee,
    BuyOrderCompletedEvent,
    OrderFilledEvent,
    SellOrderCompletedEvent,
    MarketOrderFailureEvent,
    OrderBookEvent,
    BuyOrderCreatedEvent,
    SellOrderCreatedEvent,
    OrderBookTradeEvent,
    OrderCancelledEvent
)
from hummingbot.core.event.event_listener cimport EventListener
from hummingbot.core.network_iterator import NetworkStatus
from hummingbot.market.market_base import MarketBase
from hummingbot.market.paper_trade.trading_pair import TradingPair
from hummingbot.core.utils.async_utils import safe_ensure_future

from .market_config import (
    MarketConfig,
    AssetType
)
ptm_logger = None
s_decimal_0 = Decimal(0)


cdef class QuantizationParams:
    cdef:
        str symbol
        int price_precision
        int price_decimals
        int order_size_precision
        int order_size_decimals

    def __init__(self,
                 str symbol,
                 int price_precision,
                 int price_decimals,
                 int order_size_precision,
                 int order_size_decimals):
        self.symbol = symbol
        self.price_precision = price_precision
        self.price_decimals = price_decimals
        self.order_size_precision = order_size_precision
        self.order_size_decimals = order_size_decimals

    def __repr__(self) -> str:
        return (f"QuantizationParams('{self.symbol}', {self.price_precision}, {self.price_decimals}, "
                f"{self.order_size_precision}, {self.order_size_decimals})")


cdef class QueuedOrder:
    cdef:
        double create_timestamp
        str _order_id
        bint _is_buy
        str _trading_pair
        double _amount

    def __init__(self, create_timestamp: float, order_id: str, is_buy: bool, trading_pair: str, amount: float):
        self.create_timestamp = create_timestamp
        self._order_id = order_id
        self._is_buy = is_buy
        self._trading_pair = trading_pair
        self._amount = amount

    @property
    def timestamp(self) -> double:
        return self.create_timestamp

    @property
    def order_id(self) -> str:
        return self._order_id

    @property
    def is_buy(self) -> bint:
        return self._is_buy

    @property
    def trading_pair(self) -> str:
        return self._trading_pair

    @property
    def amount(self) -> double:
        return self._amount

    def __repr__(self) -> str:
        return (f"QueuedOrder({self.create_timestamp}, '{self.order_id}', {self.is_buy}, '{self.trading_pair}', "
                f"{self.amount})")


cdef class OrderBookTradeListener(EventListener):
    cdef:
        MarketBase _market

    def __init__(self, market: MarketBase):
        super().__init__()
        self._market = market

    cdef c_call(self, object event_object):
        try:
            self._market.match_trade_to_limit_orders(event_object)
        except Exception as e:
            self.logger().error("Error call trade listener.", exc_info=True)

cdef class OrderBookMarketOrderFillListener(EventListener):
    cdef:
        MarketBase _market

    def __init__(self, market: MarketBase):
        super().__init__()
        self._market = market

    cdef c_call(self, object event_object):

        if event_object.symbol not in self._market.order_books or event_object.order_type != OrderType.MARKET:
            return
        order_book = self._market.order_books[event_object.symbol]
        order_book.record_filled_order(event_object)


cdef class PaperTradeMarket(MarketBase):
    TRADE_EXECUTION_DELAY = 5.0
    ORDER_FILLED_EVENT_TAG = MarketEvent.OrderFilled.value
    SELL_ORDER_COMPLETED_EVENT_TAG = MarketEvent.SellOrderCompleted.value
    BUY_ORDER_COMPLETED_EVENT_TAG = MarketEvent.BuyOrderCompleted.value
    MARKET_ORDER_CANCELLED_EVENT_TAG = MarketEvent.OrderCancelled.value
    MARKET_ORDER_FAILURE_EVENT_TAG = MarketEvent.OrderFailure.value
    ORDER_BOOK_TRADE_EVENT_TAG = OrderBookEvent.TradeEvent.value
    MARKET_SELL_ORDER_CREATED_EVENT_TAG = MarketEvent.SellOrderCreated.value
    MARKET_BUY_ORDER_CREATED_EVENT_TAG = MarketEvent.BuyOrderCreated.value

    def __init__(self, order_book_tracker: OrderBookTracker, config: MarketConfig, target_market: type):
        super(MarketBase, self).__init__()
        order_book_tracker.data_source.order_book_create_function = lambda: CompositeOrderBook()
        self._paper_trade_market_initialized = False
        self._trading_pairs = {}
        self._account_balance = {}
        self._config = config
        self._queued_orders = deque()
        self._quantization_params = {}
        self._order_tracker_task = None
        self._order_book_tracker = order_book_tracker
        self._order_book_trade_listener = OrderBookTradeListener(self)
        self._target_market = target_market
        self._market_order_filled_listener = OrderBookMarketOrderFillListener(self)
        self.c_add_listener(self.ORDER_FILLED_EVENT_TAG, self._market_order_filled_listener)

    @classmethod
    def random_order_id(cls, order_side: str, symbol: str) -> str:
        vals = [random.choice(range(0, 256)) for i in range(0, 13)]
        return f"{order_side}://" + symbol + "/" + "".join([f"{val:02x}" for val in vals])

    def init_paper_trade_market(self):
        for trading_pair_str, order_book in self._order_book_tracker.order_books.items():
            assert type(order_book) is CompositeOrderBook
            base_asset, quote_asset = self.split_symbol(trading_pair_str)
            self._trading_pairs[trading_pair_str] = TradingPair(trading_pair_str, base_asset, quote_asset)
            (<CompositeOrderBook>order_book).c_add_listener(
                self.ORDER_BOOK_TRADE_EVENT_TAG,
                self._order_book_trade_listener
            )

    def split_symbol(self, trading_pair: str) -> Tuple[str, str]:
        return self._target_market.split_symbol(trading_pair)

    #<editor-fold desc="Property">
    @property
    def trading_pair(self) -> Dict[str, TradingPair]:
        return self._trading_pairs

    @property
    def name(self) -> str:
        return self._order_book_tracker.exchange_name

    @property
    def display_name(self) -> str:
        return f"{self._order_book_tracker.exchange_name}_PaperTrade"

    @property
    def order_books(self) -> Dict[str, CompositeOrderBook]:
        return self._order_book_tracker.order_books

    @property
    def status_dict(self) -> Dict[str, bool]:
        return {
            "order_books_initialized": self._order_book_tracker and len(self._order_book_tracker.order_books) > 0
        }

    @property
    def ready(self):
        if all(self.status_dict.values()):
            if not self._paper_trade_market_initialized:
                self.init_paper_trade_market()
                self._paper_trade_market_initialized = True
            return True
        else:
            return False

    @property
    def queued_orders(self) -> List[QueuedOrder]:
        return self._queued_orders

    @property
    def limit_orders(self) -> List[LimitOrder]:
        cdef:
            LimitOrdersIterator map_it
            SingleSymbolLimitOrders *single_symbol_collection_ptr
            SingleSymbolLimitOrdersIterator collection_it
            SingleSymbolLimitOrdersRIterator collection_rit
            const CPPLimitOrder *cpp_limit_order_ptr
            list retval = []

        map_it = self._bid_limit_orders.begin()
        while map_it != self._bid_limit_orders.end():
            single_symbol_collection_ptr = address(deref(map_it).second)
            collection_rit = single_symbol_collection_ptr.rbegin()
            while collection_rit != single_symbol_collection_ptr.rend():
                cpp_limit_order_ptr = address(deref(collection_rit))
                retval.append(c_create_limit_order_from_cpp_limit_order(deref(cpp_limit_order_ptr)))
                inc(collection_rit)
            inc(map_it)

        map_it = self._ask_limit_orders.begin()
        while map_it != self._ask_limit_orders.end():
            single_symbol_collection_ptr = address(deref(map_it).second)
            collection_it = single_symbol_collection_ptr.begin()
            while collection_it != single_symbol_collection_ptr.end():
                cpp_limit_order_ptr = address(deref(collection_it))
                retval.append(c_create_limit_order_from_cpp_limit_order(deref(cpp_limit_order_ptr)))
                inc(collection_it)
            inc(map_it)

        return retval

    @property
    def on_hold_balances(self) -> Dict[str, Decimal]:
        _on_hold_balances = defaultdict(Decimal)
        for limit_order in self.limit_orders:
            if limit_order.is_buy:
                _on_hold_balances[limit_order.quote_currency] += limit_order.quantity * limit_order.price
            else:
                _on_hold_balances[limit_order.base_currency] += limit_order.quantity
        return _on_hold_balances

    @property
    def available_balances(self) ->  Dict[str, Decimal]:
        _available_balances = self._account_balance.copy()
        for trading_pair_str, balance in _available_balances.items():
            _available_balances[trading_pair_str] -= self.on_hold_balances[trading_pair_str]
        return _available_balances

    #</editor-fold>

    cdef c_start(self, Clock clock, double timestamp):
        MarketBase.c_start(self, clock, timestamp)

    async def start_network(self):
        await self.stop_network()
        self._order_tracker_task = safe_ensure_future(self._order_book_tracker.start())

    async def stop_network(self):
        if self._order_tracker_task is not None:
            self._order_book_tracker.stop()
            self._order_tracker_task.cancel()

    async def check_network(self) -> NetworkStatus:
        return NetworkStatus.CONNECTED

    cdef c_set_balance(self, str currency, double balance):
        ## (refactor) to pass in Decimal
        self._account_balance[currency.upper()] = Decimal(str(balance))

    cdef double c_get_balance(self, str currency) except? -1:
        if currency.upper() not in self._account_balance:
            self.logger().warning(f"Account balance does not have asset {currency.upper()}.")
            return 0.0
        ## (refactor) to return in Decimal
        return float(self._account_balance[currency.upper()])

    cdef c_tick(self, double timestamp):
        MarketBase.c_tick(self, timestamp)
        self.c_process_market_orders()
        self.c_process_crossed_limit_orders()

    cdef str c_buy(self, str trading_pair_str, double amount, object order_type = OrderType.MARKET, double price = 0.0,
                   dict kwargs = {}):
        if trading_pair_str not in self._trading_pairs:
            raise ValueError(f"Trading symbol '{trading_pair_str}' does not existing in current data set.")

        cdef:
            str order_id = self.random_order_id("buy", trading_pair_str)
            str quote_asset = self._trading_pairs[trading_pair_str].quote_asset
            string cpp_order_id = order_id.encode("utf8")
            string cpp_trading_pair_str = trading_pair_str.encode("utf8")
            string cpp_base_asset = self._trading_pairs[trading_pair_str].base_asset.encode("utf8")
            string cpp_quote_asset = quote_asset.encode("utf8")
            LimitOrdersIterator map_it
            SingleSymbolLimitOrders *limit_orders_collection_ptr = NULL
            pair[LimitOrders.iterator, cppbool] insert_result

        quantized_price = (self.c_quantize_order_price(trading_pair_str, price)
                         if order_type is OrderType.LIMIT
                         else s_decimal_0)
        quantized_amount = self.c_quantize_order_amount(trading_pair_str, amount)
        if order_type is OrderType.MARKET:
            self._queued_orders.append(QueuedOrder(self._current_timestamp, order_id, True, trading_pair_str,
                                                   quantized_amount))
        elif order_type is OrderType.LIMIT:

            map_it = self._bid_limit_orders.find(cpp_trading_pair_str)

            if map_it == self._bid_limit_orders.end():
                insert_result = self._bid_limit_orders.insert(LimitOrdersPair(cpp_trading_pair_str,
                                                                              SingleSymbolLimitOrders()))
                map_it = insert_result.first
            limit_orders_collection_ptr = address(deref(map_it).second)
            limit_orders_collection_ptr.insert(CPPLimitOrder(
                cpp_order_id,
                cpp_trading_pair_str,
                True,
                cpp_base_asset,
                cpp_quote_asset,
                <PyObject *> quantized_price,
                <PyObject *> quantized_amount
            ))
        self.c_trigger_event(self.MARKET_BUY_ORDER_CREATED_EVENT_TAG,
                             BuyOrderCreatedEvent(
                                 self._current_timestamp,
                                 order_type,
                                 trading_pair_str,
                                 float(quantized_amount),
                                 float(quantized_price),
                                 order_id
                             ))
        return order_id

    cdef str c_sell(self, str trading_pair_str, double amount, object order_type = OrderType.MARKET, double price = 0.0,
                    dict kwargs = {}):
        if trading_pair_str not in self._trading_pairs:
                raise ValueError(f"Trading symbol '{trading_pair_str}' does not existing in current data set.")
        cdef:
            str order_id = self.random_order_id("sell", trading_pair_str)
            str base_asset = self._trading_pairs[trading_pair_str].base_asset
            string cpp_order_id = order_id.encode("utf8")
            string cpp_trading_pair_str = trading_pair_str.encode("utf8")
            string cpp_base_asset = base_asset.encode("utf8")
            string cpp_quote_asset = self._trading_pairs[trading_pair_str].quote_asset.encode("utf8")
            LimitOrdersIterator map_it
            SingleSymbolLimitOrders *limit_orders_collection_ptr = NULL
            pair[LimitOrders.iterator, cppbool] insert_result

        quantized_price = (self.c_quantize_order_price(trading_pair_str, price)
                         if order_type is OrderType.LIMIT
                         else s_decimal_0)
        quantized_amount = self.c_quantize_order_amount(trading_pair_str, amount)
        if order_type is OrderType.MARKET:
            self._queued_orders.append(QueuedOrder(self._current_timestamp, order_id, False, trading_pair_str,
                                                   quantized_amount))
        elif order_type is OrderType.LIMIT:
            map_it = self._ask_limit_orders.find(cpp_trading_pair_str)

            if map_it == self._ask_limit_orders.end():
                insert_result = self._ask_limit_orders.insert(LimitOrdersPair(cpp_trading_pair_str,
                                                                              SingleSymbolLimitOrders()))
                map_it = insert_result.first
            limit_orders_collection_ptr = address(deref(map_it).second)
            limit_orders_collection_ptr.insert(CPPLimitOrder(
                cpp_order_id,
                cpp_trading_pair_str,
                False,
                cpp_base_asset,
                cpp_quote_asset,
                <PyObject *> quantized_price,
                <PyObject *> quantized_amount
            ))
        self.c_trigger_event(self.MARKET_SELL_ORDER_CREATED_EVENT_TAG,
                             SellOrderCreatedEvent(
                                 self._current_timestamp,
                                 order_type,
                                 trading_pair_str,
                                 float(quantized_amount),
                                 float(quantized_price),
                                 order_id
                             ))
        return order_id

    cdef c_execute_buy(self, str order_id, str trading_pair, double amount):
        cdef:
            double quote_balance
            double base_balance
        quote_asset = self._trading_pairs[trading_pair].quote_asset
        base_asset = self._trading_pairs[trading_pair].base_asset
        quote_balance = self.c_get_balance(quote_asset)
        base_balance = self.c_get_balance(base_asset)
        config = self._config
        order_book = self.order_books[trading_pair]
        buy_entries = order_book.simulate_buy(amount)
        # Calculate the quote currency needed, including fees.
        total_quote_needed = sum(row.price * row.amount for row in buy_entries)

        if total_quote_needed > quote_balance:
            raise ValueError(f"Insufficient {quote_asset} balance available for buy order. "
                             f"{quote_balance} {quote_asset} available vs. "
                             f"{total_quote_needed} {quote_asset} required for the order.")

        # Calculate the base currency acquired, including fees.
        total_base_acquired = sum(row.amount for row in buy_entries)

        self.c_set_balance(quote_asset, quote_balance - total_quote_needed)
        self.c_set_balance(base_asset, base_balance + total_base_acquired)

        order_filled_events = OrderFilledEvent.order_filled_events_from_order_book_rows(
            self._current_timestamp, order_id, trading_pair, TradeType.BUY, OrderType.MARKET, TradeFee(0.0), buy_entries
        )

        for order_filled_event in order_filled_events:
            self.c_trigger_event(self.ORDER_FILLED_EVENT_TAG, order_filled_event)

        self.c_trigger_event(self.BUY_ORDER_COMPLETED_EVENT_TAG,
                             BuyOrderCompletedEvent(self._current_timestamp,
                                                    order_id,
                                                    base_asset,
                                                    quote_asset,
                                                    base_asset if \
                                                        config.buy_fees_asset is AssetType.BASE_CURRENCY else \
                                                        quote_asset,
                                                    total_base_acquired,
                                                    total_quote_needed,
                                                    0,
                                                    OrderType.MARKET))

    cdef c_execute_sell(self, str order_id, str trading_pair_str, double amount):
        cdef:
            double quote_asset_amount
            double base_asset_amount
        config = self._config
        quote_asset = self._trading_pairs[trading_pair_str].quote_asset
        quote_asset_amount = self.c_get_balance(quote_asset)
        base_asset = self._trading_pairs[trading_pair_str].base_asset
        base_asset_amount = self.c_get_balance(base_asset)

        if amount > base_asset_amount:
            raise ValueError(f"Insufficient {base_asset} balance available for sell order. "
                             f"{base_asset_amount} {base_asset} available vs. "
                             f"{amount} {base_asset} required for the order.")

        order_book = self.order_books[trading_pair_str]

        # Calculate the base currency used, including fees.
        sold_amount = amount
        fee_amount = amount * config.sell_fees_amount
        if config.sell_fees_asset is AssetType.BASE_CURRENCY:
            sold_amount -= fee_amount
        sell_entries = order_book.simulate_sell(sold_amount)

        # Calculate the quote currency acquired, including fees.
        acquired_amount = sum(row.price * row.amount for row in sell_entries)
        bought_amount = acquired_amount
        if config.sell_fees_asset is AssetType.QUOTE_CURRENCY:
            fee_amount = acquired_amount * config.sell_fees_amount
            acquired_amount -= fee_amount

        self.c_set_balance(quote_asset,
                           quote_asset_amount + acquired_amount)
        self.c_set_balance(base_asset,
                           base_asset_amount - amount)

        order_filled_events = OrderFilledEvent.order_filled_events_from_order_book_rows(
            self._current_timestamp, order_id, trading_pair_str, TradeType.SELL,
            OrderType.MARKET, TradeFee(0.0), sell_entries
        )

        for order_filled_event in order_filled_events:
            self.c_trigger_event(self.ORDER_FILLED_EVENT_TAG, order_filled_event)


        self.c_trigger_event(self.SELL_ORDER_COMPLETED_EVENT_TAG,
                             SellOrderCompletedEvent(self._current_timestamp,
                                                     order_id,
                                                     base_asset,
                                                     quote_asset,
                                                     base_asset if \
                                                        config.sell_fees_asset is AssetType.BASE_CURRENCY else \
                                                        quote_asset,
                                                     sold_amount,
                                                     bought_amount,
                                                     fee_amount,
                                                     OrderType.MARKET))

    cdef c_process_market_orders(self):
        cdef:
            QueuedOrder front_order = None
        while len(self._queued_orders) > 0:
            front_order = self._queued_orders[0]
            if front_order.create_timestamp <= self._current_timestamp - self.TRADE_EXECUTION_DELAY:
                self._queued_orders.popleft()
                try:
                    if front_order.is_buy:
                        self.c_execute_buy(front_order.order_id, front_order.trading_pair, front_order.amount)
                    else:
                        self.c_execute_sell(front_order.order_id, front_order.trading_pair, front_order.amount)
                except Exception as e:
                    self.logger().error("Error executing queued order.", exc_info=True)
            else:
                return

    cdef c_delete_limit_order(self,
                              LimitOrders *limit_orders_map_ptr,
                              LimitOrdersIterator *map_it_ptr,
                              const SingleSymbolLimitOrdersIterator orders_it):
        cdef:
            SingleSymbolLimitOrders *orders_collection_ptr = address(deref(deref(map_it_ptr)).second)
        try:
            orders_collection_ptr.erase(orders_it)
            if orders_collection_ptr.empty():
                map_it_ptr[0] = limit_orders_map_ptr.erase(deref(map_it_ptr))
            return True
        except Exception as err:
            self.logger().error("Error deleting limit order.", exc_info=True)
            return False

    cdef c_process_limit_bid_order(self,
                                   LimitOrders *limit_orders_map_ptr,
                                   LimitOrdersIterator *map_it_ptr,
                                   SingleSymbolLimitOrdersIterator orders_it):
        cdef:
            const CPPLimitOrder *cpp_limit_order_ptr = address(deref(orders_it))
            str symbol = cpp_limit_order_ptr.getSymbol().decode("utf8")
            str quote_asset = cpp_limit_order_ptr.getQuoteCurrency().decode("utf8")
            str base_asset = cpp_limit_order_ptr.getBaseCurrency().decode("utf8")
            str order_id = cpp_limit_order_ptr.getClientOrderID().decode("utf8")
            double quote_asset_balance = self.c_get_balance(quote_asset)
            double quote_asset_traded = (float(<object> cpp_limit_order_ptr.getPrice()) *
                                            float(<object> cpp_limit_order_ptr.getQuantity()))
            double base_asset_traded = float(<object> cpp_limit_order_ptr.getQuantity())

        # Check if there's enough balance to satisfy the order. If not, remove the limit order without doing anything.
        if quote_asset_balance < quote_asset_traded:
            self.logger().warning(f"Not enough {quote_asset} balance to fill limit buy order on {symbol}. "
                                  f"{quote_asset_traded:.8g} {quote_asset} needed vs. "
                                  f"{quote_asset_balance:.8g} {quote_asset} available.")

            self.c_delete_limit_order(limit_orders_map_ptr, map_it_ptr, orders_it)
            return

        # Adjust the market balances according to the trade done.
        self.c_set_balance(quote_asset, self.c_get_balance(quote_asset) - quote_asset_traded)
        self.c_set_balance(base_asset, self.c_get_balance(base_asset) + base_asset_traded)

        # Emit the trade and order completed events.
        config = self._config

        self.c_trigger_event(self.ORDER_FILLED_EVENT_TAG,
                             OrderFilledEvent(self._current_timestamp,
                                              order_id,
                                              symbol,
                                              TradeType.BUY,
                                              OrderType.LIMIT,
                                              float(<object> cpp_limit_order_ptr.getPrice()),
                                              float(<object> cpp_limit_order_ptr.getQuantity()),
                                              TradeFee(0.0)
                                              ))

        self.c_trigger_event(self.BUY_ORDER_COMPLETED_EVENT_TAG,
                             BuyOrderCompletedEvent(self._current_timestamp,
                                                    order_id,
                                                    base_asset,
                                                    quote_asset,
                                                    base_asset if \
                                                        config.buy_fees_asset is AssetType.BASE_CURRENCY else \
                                                        quote_asset,
                                                    base_asset_traded,
                                                    quote_asset_traded,
                                                    0.0,
                                                    OrderType.LIMIT))
        self.c_delete_limit_order(limit_orders_map_ptr, map_it_ptr, orders_it)

    cdef c_process_limit_ask_order(self,
                                   LimitOrders *limit_orders_map_ptr,
                                   LimitOrdersIterator *map_it_ptr,
                                   SingleSymbolLimitOrdersIterator orders_it):
        cdef:
            const CPPLimitOrder *cpp_limit_order_ptr = address(deref(orders_it))
            str trading_pair_str = cpp_limit_order_ptr.getSymbol().decode("utf8")
            str quote_asset = cpp_limit_order_ptr.getQuoteCurrency().decode("utf8")
            str base_asset = cpp_limit_order_ptr.getBaseCurrency().decode("utf8")
            str order_id = cpp_limit_order_ptr.getClientOrderID().decode("utf8")
            double base_asset_balance = self.c_get_balance(base_asset)
            double quote_asset_traded = (float(<object> cpp_limit_order_ptr.getPrice()) *
                                            float(<object> cpp_limit_order_ptr.getQuantity()))
            double base_asset_traded = float(<object> cpp_limit_order_ptr.getQuantity())

        # Check if there's enough balance to satisfy the order. If not, remove the limit order without doing anything.
        if base_asset_balance < base_asset_traded:
            self.logger().warning(f"Not enough {base_asset} balance to fill limit sell order on {trading_pair_str}. "
                                  f"{base_asset_traded:.8g} {base_asset} needed vs. "
                                  f"{base_asset_balance:.8g} {base_asset} available.")
            self.c_delete_limit_order(limit_orders_map_ptr, map_it_ptr, orders_it)
            return

        # Adjust the market balances according to the trade done.
        self.c_set_balance(quote_asset, self.c_get_balance(quote_asset) + quote_asset_traded)
        self.c_set_balance(base_asset, self.c_get_balance(base_asset) - base_asset_traded)

        # Emit the trade and order completed events.
        config = self._config
        self.c_trigger_event(self.ORDER_FILLED_EVENT_TAG,
                             OrderFilledEvent(self._current_timestamp,
                                              order_id,
                                              trading_pair_str,
                                              TradeType.SELL,
                                              OrderType.LIMIT,
                                              float(<object> cpp_limit_order_ptr.getPrice()),
                                              float(<object> cpp_limit_order_ptr.getQuantity()),
                                              TradeFee(0.0)
                                              ))
        self.c_trigger_event(self.SELL_ORDER_COMPLETED_EVENT_TAG,
                             SellOrderCompletedEvent(self._current_timestamp,
                                                     order_id,
                                                     base_asset,
                                                     quote_asset,
                                                     base_asset if \
                                                         config.sell_fees_asset is AssetType.BASE_CURRENCY else \
                                                         quote_asset,
                                                     base_asset_traded,
                                                     quote_asset_traded,
                                                     0.0,
                                                     OrderType.LIMIT))
        self.c_delete_limit_order(limit_orders_map_ptr, map_it_ptr, orders_it)

    cdef c_process_limit_order(self,
                               bint is_buy,
                               LimitOrders *limit_orders_map_ptr,
                               LimitOrdersIterator *map_it_ptr,
                               SingleSymbolLimitOrdersIterator orders_it):
        try:
            if is_buy:
                self.c_process_limit_bid_order(limit_orders_map_ptr, map_it_ptr, orders_it)
            else:
                self.c_process_limit_ask_order(limit_orders_map_ptr, map_it_ptr, orders_it)
        except Exception as e:
            self.logger().error(f"Error processing limit order.", exc_info=True)

    cdef c_process_crossed_limit_orders_for_symbol(self,
                                                   bint is_buy,
                                                   LimitOrders *limit_orders_map_ptr,
                                                   LimitOrdersIterator *map_it_ptr):
        """
        Trigger limit orders when the opposite side of the order book has crossed the limit order's price.
        This implies someone was ready to fill the limit order, if that limit order was on the market.

        :param is_buy: are the limit orders on the bid side?
        :param limit_orders_map_ptr: pointer to the limit orders map
        :param map_it_ptr: limit orders map iterator, which implies the symbol being processed
        """
        cdef:
            str symbol = deref(deref(map_it_ptr)).first.decode("utf8")
            double opposite_order_book_price = self.c_get_price(symbol, is_buy)
            SingleSymbolLimitOrders *orders_collection_ptr = address(deref(deref(map_it_ptr)).second)
            SingleSymbolLimitOrdersIterator orders_it = orders_collection_ptr.begin()
            SingleSymbolLimitOrdersRIterator orders_rit = orders_collection_ptr.rbegin()
            vector[SingleSymbolLimitOrdersIterator] process_order_its
            const CPPLimitOrder *cpp_limit_order_ptr = NULL

        if is_buy:
            while orders_rit != orders_collection_ptr.rend():
                cpp_limit_order_ptr = address(deref(orders_rit))
                if opposite_order_book_price > float(<object>cpp_limit_order_ptr.getPrice()):
                    break
                process_order_its.push_back(getIteratorFromReverseIterator(
                    <reverse_iterator[SingleSymbolLimitOrdersIterator]>orders_rit))
                inc(orders_rit)
        else:
            while orders_it != orders_collection_ptr.end():
                cpp_limit_order_ptr = address(deref(orders_it))
                if opposite_order_book_price < float(<object>cpp_limit_order_ptr.getPrice()):
                    break
                process_order_its.push_back(orders_it)
                inc(orders_it)

        for orders_it in process_order_its:
            self.c_process_limit_order(is_buy, limit_orders_map_ptr, map_it_ptr, orders_it)

    cdef c_process_crossed_limit_orders(self):
        cdef:
            LimitOrders *limit_orders_ptr = address(self._bid_limit_orders)
            LimitOrdersIterator map_it = limit_orders_ptr.begin()

        while map_it != limit_orders_ptr.end():
            self.c_process_crossed_limit_orders_for_symbol(True, limit_orders_ptr, address(map_it))
            if map_it != limit_orders_ptr.end():
                inc(map_it)

        limit_orders_ptr = address(self._ask_limit_orders)
        map_it = limit_orders_ptr.begin()

        while map_it != limit_orders_ptr.end():
            self.c_process_crossed_limit_orders_for_symbol(False, limit_orders_ptr, address(map_it))
            if map_it != limit_orders_ptr.end():
                inc(map_it)

    #<editor-fold desc="Event listener functions">
    cdef c_match_trade_to_limit_orders(self, object order_book_trade_event):
        """
        Trigger limit orders when incoming market orders have crossed the limit order's price.

        :param order_book_trade_event: trade event from order book
        """
        cdef:
            string cpp_trading_pair = order_book_trade_event.symbol.encode("utf8")
            bint is_maker_buy = order_book_trade_event.type is TradeType.SELL
            double trade_price = order_book_trade_event.price
            double trade_quantity = order_book_trade_event.amount
            LimitOrders *limit_orders_map_ptr = (address(self._bid_limit_orders)
                                                 if is_maker_buy
                                                 else address(self._ask_limit_orders))
            LimitOrdersIterator map_it = limit_orders_map_ptr.find(cpp_trading_pair)
            SingleSymbolLimitOrders *orders_collection_ptr = NULL
            SingleSymbolLimitOrdersIterator orders_it
            SingleSymbolLimitOrdersRIterator orders_rit
            vector[SingleSymbolLimitOrdersIterator] process_order_its
            const CPPLimitOrder *cpp_limit_order_ptr = NULL

        if map_it == limit_orders_map_ptr.end():
            return

        orders_collection_ptr = address(deref(map_it).second)
        if is_maker_buy:
            orders_rit = orders_collection_ptr.rbegin()
            while orders_rit != orders_collection_ptr.rend():
                cpp_limit_order_ptr = address(deref(orders_rit))
                if float(<object>cpp_limit_order_ptr.getPrice()) <= trade_price:
                    break
                process_order_its.push_back(getIteratorFromReverseIterator(
                    <reverse_iterator[SingleSymbolLimitOrdersIterator]>orders_rit))
                inc(orders_rit)
        else:
            orders_it = orders_collection_ptr.begin()
            while orders_it != orders_collection_ptr.end():
                cpp_limit_order_ptr = address(deref(orders_it))
                if float(<object>cpp_limit_order_ptr.getPrice()) >= trade_price:
                    break
                process_order_its.push_back(orders_it)
                inc(orders_it)

        for orders_it in process_order_its:
            self.c_process_limit_order(is_maker_buy, limit_orders_map_ptr, address(map_it), orders_it)


    #</editor-fold>
    cdef double c_get_available_balance(self, str currency) except? -1:
        return float(self.available_balances[currency.upper()])

    async def get_active_exchange_markets(self) -> pd.DataFrame:
        return await self._order_book_tracker.data_source.get_active_exchange_markets()

    async def cancel_all(self, timeout_seconds: float) -> List[CancellationResult]:
        cdef:
            LimitOrders *limit_orders_map_ptr
            list cancellation_results = []
        limit_orders_map_ptr = address(self._bid_limit_orders)
        for trading_pair_str in self._trading_pairs.keys():
            results = self.c_cancel_order_from_orders_map(limit_orders_map_ptr, trading_pair_str, cancel_all=True)
            cancellation_results.extend(results)

        limit_orders_map_ptr = address(self._ask_limit_orders)
        for trading_pair_str in self._trading_pairs.keys():
            results = self.c_cancel_order_from_orders_map(limit_orders_map_ptr, trading_pair_str, cancel_all=True)
            cancellation_results.extend(results)
        return cancellation_results

    cdef object c_cancel_order_from_orders_map(self, LimitOrders *orders_map, str trading_pair_str,
                                             bint cancel_all = False,
                                             str client_order_id = None):
        cdef:
            string cpp_symbol = trading_pair_str.encode("utf8")
            LimitOrdersIterator map_it = orders_map.find(cpp_symbol)
            SingleSymbolLimitOrders *limit_orders_collection_ptr = NULL
            SingleSymbolLimitOrdersIterator orders_it
            vector[SingleSymbolLimitOrdersIterator] process_order_its
            const CPPLimitOrder *limit_order_ptr = NULL
            str limit_order_cid
            list cancellation_results = []
        try:
            if map_it == orders_map.end():
                return []

            limit_orders_collection_ptr = address(deref(map_it).second)
            orders_it = limit_orders_collection_ptr.begin()
            while orders_it != limit_orders_collection_ptr.end():
                limit_order_ptr = address(deref(orders_it))
                limit_order_cid = limit_order_ptr.getClientOrderID().decode("utf8")
                if (not cancel_all and limit_order_cid == client_order_id) or cancel_all:
                    process_order_its.push_back(orders_it)
                inc(orders_it)

            for orders_it in process_order_its:
                limit_order_ptr = address(deref(orders_it))
                limit_order_cid = limit_order_ptr.getClientOrderID().decode("utf8")
                delete_success = self.c_delete_limit_order(orders_map, address(map_it), orders_it)
                cancellation_results.append(CancellationResult(limit_order_cid,
                                                               delete_success))
                self.c_trigger_event(self.MARKET_ORDER_CANCELLED_EVENT_TAG,
                                     OrderCancelledEvent(self._current_timestamp,
                                                         limit_order_cid)
                                     )
            return cancellation_results
        except Exception as err:
            self.logger().error(f"Error canceling order.", exc_info=True)

    cdef c_cancel(self, str trading_pair_str, str client_order_id):
        cdef:
            string cpp_trading_pair = trading_pair_str.encode("utf8")
            string cpp_client_order_id = client_order_id.encode("utf8")
            str trade_type = client_order_id.split("://")[0]
            bint is_maker_buy = trade_type.upper() == "BUY"
            LimitOrders *limit_orders_map_ptr = (address(self._bid_limit_orders)
                                                 if is_maker_buy
                                                 else address(self._ask_limit_orders))
        self.c_cancel_order_from_orders_map(limit_orders_map_ptr, trading_pair_str, client_order_id)

    cdef object c_get_fee(self, str base_asset, str quote_asset, object order_type, object order_side,
                          double amount, double price):
        return TradeFee(0)

    cdef OrderBook c_get_order_book(self, str symbol):
        if symbol not in self._trading_pairs:
            raise ValueError(f"No order book exists for '{symbol}'.")
        return self._order_book_tracker.order_books[symbol]

    cdef double c_get_price(self, str symbol, bint is_buy) except? -1:
        cdef:
            OrderBook order_book
        order_book = self.c_get_order_book(symbol)
        return order_book.c_get_price(is_buy)

    cdef object c_get_order_price_quantum(self, str symbol, double price):
        cdef:
            QuantizationParams q_params
        if symbol in self._quantization_params:
            q_params = self._quantization_params[symbol]
            decimals_quantum = Decimal(f"1e-{q_params.price_decimals}")
            if price > 0:
                precision_quantum = Decimal(f"1e{math.ceil(math.log10(price)) - q_params.price_precision}")
            else:
                precision_quantum = Decimal(0)
            return max(precision_quantum, decimals_quantum)
        else:
            return Decimal(f"1e-15")

    cdef object c_get_order_size_quantum(self, str symbol, double order_size):
        cdef:
            QuantizationParams q_params
        if symbol in self._quantization_params:
            q_params = self._quantization_params[symbol]
            decimals_quantum = Decimal(f"1e-{q_params.order_size_decimals}")
            if order_size > 0:
                precision_quantum = Decimal(f"1e{math.ceil(math.log10(order_size)) - q_params.order_size_precision}")
            else:
                precision_quantum = Decimal(0)
            return max(precision_quantum, decimals_quantum)
        else:
            return Decimal(f"1e-15")

    cdef object c_quantize_order_price(self, str symbol, double price):
        price = float('%.7g' % price) # hard code to round to 8 significant digits
        price_quantum = self.c_get_order_price_quantum(symbol, price)
        return round(Decimal('%s' % price) / price_quantum) * price_quantum

    cdef object c_quantize_order_amount(self, str symbol, double amount, double price = 0.0):
        amount = float('%.7g' % amount)# hard code to round to 8 significant digits
        if amount <= 1e-7:
            amount = 0
        order_size_quantum = self.c_get_order_size_quantum(symbol, amount)
        return (Decimal('%s' % amount) // order_size_quantum) * order_size_quantum

    def get_all_balances(self) -> Dict[str, float]:
        return self._account_balance.copy()

    #<editor-fold desc="Python wrapper for cdef functions">
    def match_trade_to_limit_orders(self, event_object: OrderBookTradeEvent):
        self.c_match_trade_to_limit_orders(event_object)

    def get_balance(self, currency: str):
        return self.c_get_balance(currency)

    def set_balance(self, currency: str, balance: double):
        self.c_set_balance(currency, balance)
    #</editor-fold>