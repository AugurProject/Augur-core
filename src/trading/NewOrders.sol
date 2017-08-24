/**
 * Copyright (C) 2015 Forecast Foundation OU, full GPL notice in LICENSE
 */

pragma solidity ^0.4.13;

import 'ROOT/Controller.sol';
import 'ROOT/libraries/math/SafeMathUint256.sol';
import 'ROOT/reporting/Interfaces.sol';
import 'ROOT/trading/NewOrdersFetcher.sol';


/**
 * @title Orders
 * @dev Storage of all data associated with orders
 */
// FIXME: This was named NewOrders to prevent naming conflicts with orders.se. Should be renamed to Orders.
contract NewOrders is Controlled {
    using SafeMathUint256 for uint256;

    event CancelOrder(address indexed market, address indexed sender, uint256 fxpPrice, uint256 fxpAmount, bytes20 orderId, uint8 outcome, uint256 orderType, uint256 cashRefund, uint256 sharesRefund);
    event CompleteSets(address indexed sender, address indexed market, uint256 indexed orderType, uint256 fxpAmount, uint256 numOutcomes, uint256 marketCreatorFee, uint256 reportingFee);
    event MakeOrder(address indexed market, address indexed sender, uint256 indexed orderType, uint256 fxpPrice, uint256 fxpAmount, uint8 outcome, bytes20 orderId, uint256 fxpMoneyEscrowed, uint256 fxpSharesEscrowed, uint256 tradeGroupId);
    event TakeOrder(address indexed market, uint256 indexed outcome, uint256 indexed orderType, bytes20 orderId, uint256 price, address maker, address taker, uint256 makerShares, uint256 makerTokens, uint256 takerShares, uint256 takerTokens, uint256 tradeGroupId);

    struct Order {
        uint256 fxpAmount;
        uint256 fxpPrice;
        address owner;
        uint256 fxpSharesEscrowed;
        uint256 fxpMoneyEscrowed;
        bytes20 betterOrderId;
        bytes20 worseOrderId;
        uint256 gasPrice; // FIXME: Remove deprecated gasPrice
    }

    struct MarketOrders {
        uint256 volume;
        uint256[] prices;
    }

    // Trade types
    // FIXME: Ideally, this should probably be an enum
    uint8 private constant BID = 1;
    uint8 private constant ASK = 2;

    mapping(bytes20 => Order) private orders;
    mapping(address => MarketOrders) private marketOrderData;
    mapping(bytes20 => bytes20) private bestOrder;
    mapping(bytes20 => bytes20) private worstOrder;

    // Getters
    function getOrders(bytes20 _orderId, uint256 _type, IMarket _market, uint8 _outcome) public constant returns (uint256, uint256, address, uint256, uint256, bytes20, bytes20, uint256) {
        Order _order = orders[_orderId];
        return (_order.fxpAmount, _order.fxpPrice, _order.owner, _order.fxpSharesEscrowed, _order.fxpMoneyEscrowed, _order.betterOrderId, _order.worseOrderId, _order.gasPrice);
    }

    function getMarketOrderData(IMarket _market) public constant returns (uint256, uint256[]) {
        return (marketOrderData[_market].volume, marketOrderData[_market].prices);
    }

    function getBestOrders(uint256 _type, IMarket _market, uint8 _outcome) public constant returns (bytes20) {
        return bestOrder[getBestOrderWorstOrderHash(_market, _outcome, _type)];
    }

    function getWorstOrders(uint256 _type, IMarket _market, uint8 _outcome) public constant returns (bytes20) {
        return worstOrder[getBestOrderWorstOrderHash(_market, _outcome, _type)];
    }

    function getAmount(bytes20 _orderId, uint256 _type, IMarket _market, uint8 _outcome) public constant returns (uint256) { 
        return orders[_orderId].fxpAmount;
    }

    function getPrice(bytes20 _orderId, uint256 _type, IMarket _market, uint8 _outcome) public constant returns (uint256) {
        return orders[_orderId].fxpPrice;
    }

    function getOrderOwner(bytes20 _orderId, uint256 _type, IMarket _market, uint8 _outcome) public constant returns (address) { 
        return orders[_orderId].owner;
    }

    function getOrderSharesEscrowed(bytes20 _orderId, uint256 _type, IMarket _market, uint8 _outcome) public constant returns (uint256) { 
        return orders[_orderId].fxpSharesEscrowed;
    }

    function getOrderMoneyEscrowed(bytes20 _orderId, uint256 _type, IMarket _market, uint8 _outcome) public constant returns (uint256) { 
        return orders[_orderId].fxpMoneyEscrowed;
    }

    function getVolume(IMarket _market) public constant returns (uint256) { 
        return marketOrderData[_market].volume;
    }

    function getLastOutcomePrice(IMarket _market, uint8 _outcome) public constant returns (uint256) { 
        return marketOrderData[_market].prices[_outcome];
    }

    function getBetterOrderId(bytes20 _orderId, uint256 _type, IMarket _market, uint8 _outcome) public constant returns (bytes20) { 
        return orders[_orderId].betterOrderId;
    }

    function getWorseOrderId(bytes20 _orderId, uint256 _type, IMarket _market, uint8 _outcome) public constant returns (bytes20) {
        return orders[_orderId].worseOrderId;
    }

    function getGasPrice(bytes20 _orderId, uint256 _type, IMarket _market, uint8 _outcome) public constant returns (uint256) { 
        return orders[_orderId].gasPrice;
    }

    function getBestOrderId(uint256 _type, IMarket _market, uint8 _outcome) public constant returns (bytes20) { 
        return bestOrder[getBestOrderWorstOrderHash(_market, _outcome, _type)];
    }

    function getWorstOrderId(uint256 _type, IMarket _market, uint8 _outcome) public constant returns (bytes20) { 
        return worstOrder[getBestOrderWorstOrderHash(_market, _outcome, _type)];
    }

    // FIXME: Currently, getOrderIdHash(), getBestOrderWorstOrderHash(), and makeOrder.makeOrder() are creating ripemd160 hash values of type bytes20.  This should probably be changed to create sha3/sha256 hash values of type bytes32.
    function getOrderIdHash(uint256 _type, IMarket _market, uint256 _fxpAmount, uint256 _fxpPrice, address _sender, uint256 _blockNumber, uint256 _outcome, uint256 _fxpMoneyEscrowed, uint256 _fxpSharesEscrowed) public constant returns (bytes20) {
        return ripemd160(_type, _market, _fxpAmount, _fxpPrice, _sender, _blockNumber, _outcome, _fxpMoneyEscrowed, _fxpSharesEscrowed);
    }

    function getBlockNumber() public constant returns (uint256) {
        return block.number;
    }

    function isBetterPrice(uint256 _type, IMarket _market, uint8 _outcome, uint256 _fxpPrice, bytes20 _orderId) public constant returns (bool) { 
        if (_type == BID) { 
            return (_fxpPrice > orders[_orderId].fxpPrice);
        } else {
            return (_fxpPrice < orders[_orderId].fxpPrice);
        }
    }

    function isWorsePrice(uint256 _type, IMarket _market, uint8 _outcome, uint256 _fxpPrice, bytes20 _orderId) public constant returns (bool) { 
        if (_type == BID) { 
            return (_fxpPrice < orders[_orderId].fxpPrice);
        } else {
            return (_fxpPrice > orders[_orderId].fxpPrice);
        }
    }

    function assertIsNotBetterPrice(uint256 _type, IMarket _market, uint8 _outcome, uint256 _fxpPrice, bytes20 _betterOrderId) public constant returns (bool) { 
        require(!isBetterPrice(_type, _market, _outcome, _fxpPrice, _betterOrderId));
        return true;
    }

    function assertIsNotWorsePrice(uint256 _type, IMarket _market, uint8 _outcome, uint256 _fxpPrice, bytes20 _worseOrderId) public returns (bool) { 
        require(!isWorsePrice(_type, _market, _outcome, _fxpPrice, _worseOrderId));
        return true;
    }

    function insertOrderIntoList(bytes20 _orderId, uint256 _type, IMarket _market, uint8 _outcome, uint256 _fxpPrice, bytes20 _betterOrderId, bytes20 _worseOrderId) internal onlyWhitelistedCallers returns (bool) { 
        bytes20 _bestOrderId = bestOrder[getBestOrderWorstOrderHash(_market, _outcome, _type)];
        bytes20 _worstOrderId = worstOrder[getBestOrderWorstOrderHash(_market, _outcome, _type)];
        NewOrdersFetcher _ordersFetcher = NewOrdersFetcher(controller.lookup("NewOrdersFetcher"));
        (_betterOrderId, _worseOrderId) = _ordersFetcher.findBoundingOrders(_type, _market, _outcome, _fxpPrice, _bestOrderId, _worstOrderId, _betterOrderId, _worseOrderId);
        if (_type == BID) {
            _bestOrderId = updateBestBidOrder(_orderId, _market, _fxpPrice, _outcome);
            _worstOrderId = updateWorstBidOrder(_orderId, _market, _fxpPrice, _outcome);
        } else {
            _bestOrderId = updateBestAskOrder(_orderId, _market, _fxpPrice, _outcome);
            _worstOrderId = updateWorstAskOrder(_orderId, _market, _fxpPrice, _outcome);
        }
        if (_bestOrderId == _orderId) { 
            _betterOrderId = 0;
        }
        if (_worstOrderId == _orderId) { 
            _worseOrderId = 0;
        }
        if (_betterOrderId != 0) {
            orders[_betterOrderId].worseOrderId = _orderId;
            orders[_orderId].betterOrderId = _betterOrderId;
        }
        if (_worseOrderId != 0) {
            orders[_worseOrderId].betterOrderId = _orderId;
            orders[_orderId].worseOrderId = _worseOrderId;
        }
        return true;
    }

    // FIXME: Remove unused parameters orderID and gasPrice
    function saveOrder(address orderId, uint256 _type, IMarket _market, uint256 _fxpAmount, uint256 _fxpPrice, address _sender, uint8 _outcome, uint256 _fxpMoneyEscrowed, uint256 _fxpSharesEscrowed, bytes20 _betterOrderId, bytes20 _worseOrderId, uint256 _tradeGroupId, uint256 gasPrice) public onlyWhitelistedCallers returns (bytes20 _orderId) { 
        require(_type == BID || _type == ASK);
        require(_outcome < _market.getNumberOfOutcomes());
        _orderId = getOrderIdHash(_type, _market, _fxpAmount, _fxpPrice, _sender, block.number, _outcome, _fxpMoneyEscrowed, _fxpSharesEscrowed);
        insertOrderIntoList(_orderId, _type, _market, _outcome, _fxpPrice, _betterOrderId, _worseOrderId);
        orders[_orderId].fxpPrice = _fxpPrice;
        orders[_orderId].fxpAmount = _fxpAmount;
        orders[_orderId].owner = _sender;
        orders[_orderId].fxpMoneyEscrowed = _fxpMoneyEscrowed;
        orders[_orderId].fxpSharesEscrowed = _fxpSharesEscrowed;
        MakeOrder(_market, _sender, _type, _fxpPrice, _fxpAmount, _outcome, _orderId, _fxpMoneyEscrowed, _fxpSharesEscrowed, _tradeGroupId);
        return _orderId;
    }

    function removeOrder(bytes20 _orderId, uint256 _type, IMarket _market, uint8 _outcome) public onlyWhitelistedCallers returns (bool) { 
        require(tx.gasprice <= orders[_orderId].gasPrice);
        removeOrderFromList(_orderId, _type, _market, _outcome);
        orders[_orderId].fxpPrice = 0;
        orders[_orderId].fxpAmount = 0;
        orders[_orderId].owner = 0;
        orders[_orderId].fxpMoneyEscrowed = 0;
        orders[_orderId].fxpSharesEscrowed = 0;
        orders[_orderId].gasPrice = 0;
        return true;
    }

    function fillOrder(bytes20 _orderId, uint256 _orderType, IMarket _market, uint8 _orderOutcome, uint256 _sharesFilled, uint256 _tokensFilled) public onlyWhitelistedCallers returns (bool) { 
        // FIXME: Should eventually be changed to `require(_market.getTypeName() == "Market")`
        require(_market != address(0));
        require(_orderOutcome < _market.getNumberOfOutcomes());
        require(_orderType == BID || _orderType == ASK);
        require(_orderId != 0);
        require(_sharesFilled <= orders[_orderId].fxpSharesEscrowed);
        require(_tokensFilled <= orders[_orderId].fxpMoneyEscrowed);
        require(tx.gasprice <= orders[_orderId].gasPrice);
        require(orders[_orderId].fxpPrice <= _market.getMaxDisplayPrice());
        require(orders[_orderId].fxpPrice >= _market.getMinDisplayPrice());
        require(_market.getMaxDisplayPrice() + _market.getMinDisplayPrice() <= 2**254);
        uint256 _fill = 0;
        if (_orderType == BID) {
            // We can't use safeSub here because it disallows subtracting negative numbers. Worst case here is an operation of 2**254 - 1 as required above, which won't overflow
            _fill = _sharesFilled + (_tokensFilled.fxpDiv(orders[_orderId].fxpPrice - _market.getMinDisplayPrice()));
        }
        if (_orderType == ASK) {
            // We can't use safeSub here because it disallows subtracting negative numbers. Worst case here is an operation of 2**254 - 1 as required above, which won't overflow
            _fill = _sharesFilled + (_tokensFilled.fxpDiv(_market.getMaxDisplayPrice() - orders[_orderId].fxpPrice));
        }
        require(_fill <= orders[_orderId].fxpAmount);
        orders[_orderId].fxpAmount -= _fill;
        orders[_orderId].fxpMoneyEscrowed -= _tokensFilled;
        orders[_orderId].fxpSharesEscrowed -= _sharesFilled;
        if (orders[_orderId].fxpAmount == 0) {
            require(orders[_orderId].fxpMoneyEscrowed == 0);
            require(orders[_orderId].fxpSharesEscrowed == 0);
            removeOrderFromList(_orderId, _orderType, _market, _orderOutcome);
            orders[_orderId].fxpPrice = 0;
            orders[_orderId].owner = 0;
            orders[_orderId].gasPrice = 0;
            orders[_orderId].betterOrderId = 0;
            orders[_orderId].worseOrderId = 0;
        }
        return true;
    }

    function takeOrderLog(IMarket _market, uint8 _orderOutcome, uint256 _orderType, bytes20 _orderId, address _taker, uint256 _makerSharesFilled, uint256 _makerTokensFilled, uint256 _takerSharesFilled, uint256 _takerTokensFilled, uint256 _tradeGroupId) public constant returns (bool) { 
        uint256 _price = orders[_orderId].fxpPrice;
        address _maker = orders[_orderId].owner;
        TakeOrder(_market, _orderOutcome, _orderType, _orderId, _price, _maker, _taker, _makerSharesFilled, _makerTokensFilled, _takerSharesFilled, _takerTokensFilled, _tradeGroupId);
        return true;
    }

    function completeSetsLog(address _sender, IMarket _market, uint256 _type, uint256 _fxpAmount, uint256 _numOutcomes, uint256 _marketCreatorFee, uint256 _reportingFee) public constant returns (bool) { 
        CompleteSets(_sender, _market, _type, _fxpAmount, _numOutcomes, _marketCreatorFee, _reportingFee);
        return true;
    }

    function cancelOrderLog(IMarket _market, address _sender, uint256 _fxpPrice, uint256 _fxpAmount, bytes20 _orderId, uint8 _outcome, uint256 _type, uint256 _fxpMoneyEscrowed, uint256 _fxpSharesEscrowed) public constant returns (bool) { 
        CancelOrder(_market, _sender, _fxpPrice, _fxpAmount, _orderId, _outcome, _type, _fxpMoneyEscrowed, _fxpSharesEscrowed);
        return true;
    }

    function modifyMarketVolume(IMarket _market, uint256 _fxpAmount) internal returns (bool) { 
        marketOrderData[_market].volume += _fxpAmount;
        _market.getBranch().getTopics().updatePopularity(_market.getTopic(), _fxpAmount);
        return true;
    }

    function setPrice(IMarket _market, uint8 _outcome, uint256 _fxpPrice) internal returns (bool) { 
        marketOrderData[_market].prices[_outcome] = _fxpPrice;
        return true;
    }

    function removeOrderFromList(bytes20 _orderId, uint256 _type, IMarket _market, uint8 _outcome) private returns (bool) { 
        bytes20 _betterOrderId = orders[_orderId].betterOrderId;
        bytes20 _worseOrderId = orders[_orderId].worseOrderId;
        if (bestOrder[getBestOrderWorstOrderHash(_market, _outcome, _type)] == _orderId) { 
            bestOrder[getBestOrderWorstOrderHash(_market, _outcome, _type)] = _worseOrderId;
        }
        if (worstOrder[getBestOrderWorstOrderHash(_market, _outcome, _type)] == _orderId) { 
            worstOrder[getBestOrderWorstOrderHash(_market, _outcome, _type)] = _betterOrderId;
        }
        if (_betterOrderId != 0) { 
            orders[_betterOrderId].worseOrderId = _worseOrderId;
        }
        if (_worseOrderId != 0) { 
            orders[_worseOrderId].betterOrderId = _betterOrderId;
        }
        orders[_orderId].betterOrderId = 0;
        orders[_orderId].worseOrderId = 0;
        return true;
    }

    /**
     * @dev If best bid is not set or price higher than best bid price, this order is the new best bid.
     */
    function updateBestBidOrder(bytes20 _orderId, IMarket _market, uint256 _fxpPrice, uint8 _outcome) private returns (bytes20) { 
        bytes20 _bestBidOrderId = bestOrder[getBestOrderWorstOrderHash(_market, _outcome, BID)];
        if (_bestBidOrderId == 0 || _fxpPrice > orders[_bestBidOrderId].fxpPrice) { 
            bestOrder[getBestOrderWorstOrderHash(_market, _outcome, BID)] = _orderId;
        }
        return bestOrder[getBestOrderWorstOrderHash(_market, _outcome, BID)];
    }

    /**
     * @dev If worst bid is not set or price lower than worst bid price, this order is the new worst bid.
     */
    function updateWorstBidOrder(bytes20 _orderId, IMarket _market, uint256 _fxpPrice, uint8 _outcome) private returns (bytes20) { 
        bytes20 _worstBidOrderId = worstOrder[getBestOrderWorstOrderHash(_market, _outcome, BID)];
        if (_worstBidOrderId == 0 || _fxpPrice < orders[_worstBidOrderId].fxpPrice) { 
            worstOrder[getBestOrderWorstOrderHash(_market, _outcome, BID)] = _orderId;
        }
        return worstOrder[getBestOrderWorstOrderHash(_market, _outcome, BID)];
    }

    /**
     * @dev If best ask is not set or price lower than best ask price, this order is the new best ask.
     */
    function updateBestAskOrder(bytes20 _orderId, IMarket _market, uint256 _fxpPrice, uint8 _outcome) private returns (bytes20) { 
        bytes20 _bestAskOrderId = bestOrder[getBestOrderWorstOrderHash(_market, _outcome, ASK)];
        if (_bestAskOrderId == 0 || _fxpPrice < orders[_bestAskOrderId].fxpPrice) { 
            bestOrder[getBestOrderWorstOrderHash(_market, _outcome, ASK)] = _orderId;
        }
        return bestOrder[getBestOrderWorstOrderHash(_market, _outcome, ASK)];
    }

    /**
     * @dev If worst ask is not set or price higher than worst ask price, this order is the new worst ask.
     */
    function updateWorstAskOrder(bytes20 _orderId, IMarket _market, uint256 _fxpPrice, uint8 _outcome) private returns (bytes20) {
        bytes20 _worstAskOrderId = worstOrder[getBestOrderWorstOrderHash(_market, _outcome, ASK)];
        if (_worstAskOrderId == 0 || _fxpPrice > orders[_worstAskOrderId].fxpPrice) { 
            worstOrder[getBestOrderWorstOrderHash(_market, _outcome, ASK)] = _orderId;
        }
        return worstOrder[getBestOrderWorstOrderHash(_market, _outcome, ASK)];
    }

    function getBestOrderWorstOrderHash(IMarket _market, uint8 _outcome, uint256 _type) private constant returns (bytes20) {
        return ripemd160(_market, _outcome, _type);
    }
}
