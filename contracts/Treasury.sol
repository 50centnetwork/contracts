// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IBoardroom.sol";

/**
 * @title Basis Cash Treasury contract
 * @notice Monetary policy logic to adjust supplies of basis cash assets
 * @author Summer Smith & Rick Sanchez
 */
contract Treasury is ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public migrated = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // core components
    address public cash;
    address public bond;
    address public share;

    address public boardroom;
    address public priceOracle;

    // price
    uint256 public peggedPrice;
    uint256 public cashPriceCeiling;
    uint256 public cashPriceCeilingForRedeemBond; // when redeeming bond

    uint256 public seigniorageSaved;

    // protocol parameters
    uint256 public maxSupplyExpansionPercent;
    uint256 public maxSupplyExpansionPercentInDebtPhase;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageBoardroomPercent;
    uint256 public seigniorageBoardroomPercentInDebtPhase;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // Marketing Fund
    address public marketingFund;

    /* =================== Events =================== */

    event Migration(address indexed target);
    event RedeemedBonds(address indexed from, uint256 cashAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 cashAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event MarketingFundFunded(uint256 timestamp, uint256 seigniorage);
    event ExpansionRateChanged(uint256 maxSupplyExpansionPercent, uint256 maxSupplyExpansionPercentInDebtPhase);
    event NewEpoch(uint256 epoch, uint256 cashPrice);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "onlyOperator");
        _;
    }

    function checkCondition() private view {
        require(!migrated, "Migrated");
        require(now >= startTime, "Not started yet");
    }

    function checkEpoch() private  {
        require(now >= nextEpochPoint(), "Not opened yet");

        epoch = epoch.add(1);
        epochSupplyContractionLeft = IERC20(cash).totalSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    function checkOperator() private view {
        require(
            IBasisAsset(cash).operator() == address(this) &&
                IBasisAsset(bond).operator() == address(this) &&
                IBasisAsset(share).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            "Permissions required"
        );
    }

    constructor(
        address _cash,
        address _bond,
        address _share,
        address _priceOracle,
        address _marketingFund,
        uint256 _startTime
    ) public {
        require(block.timestamp < _startTime, "late");

        cash = _cash;
        bond = _bond;
        share = _share;
        priceOracle = _priceOracle;
        marketingFund = _marketingFund;
        startTime = _startTime;

        peggedPrice = 0.5 ether;
        cashPriceCeiling = peggedPrice.mul(102).div(100);
        cashPriceCeilingForRedeemBond = peggedPrice.mul(130).div(100);

        maxSupplyExpansionPercent = 250;
        maxSupplyExpansionPercentInDebtPhase = 250;
        bondDepletionFloorPercent = 10000;
        seigniorageBoardroomPercent = 5000;
        seigniorageBoardroomPercentInDebtPhase = 5000;
        maxSupplyContractionPercent = 300;
        maxDebtRatioPercent = 3500;
        seigniorageSaved = IERC20(cash).balanceOf(address(this));

        operator = msg.sender;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // flags
    function isMigrated() public view returns (bool) {
        return migrated;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getCashPrice() public view returns (uint256 cashPrice) {
        try IOracle(priceOracle).consult(cash, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Oracle consult cash price failed");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _totalCash = IERC20(cash).balanceOf(address(this));
        uint256 _rate = getBondExchangeRate();
        if (_rate > 0) {
            _redeemableBonds = _totalCash.mul(1e18).div(_rate);
        }
    }

    function getBondExchangeRate() public view returns (uint256 _rate) {
        uint256 _cashPrice = getCashPrice();
        if (_cashPrice > cashPriceCeiling) {
            _rate = Math.min(_cashPrice, cashPriceCeilingForRedeemBond).mul(2);
        } else {
            _rate = 9**17;
        }
    }

    /* ========== GOVERNANCE ========== */

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setBoardroom(address _boardroom) external onlyOperator {
        boardroom = _boardroom;
    }

    function setCashOracle(address _priceOracle) external onlyOperator {
        priceOracle = _priceOracle;
    }

    function setCashPriceCeiling(uint256 _cashPriceCeiling) external onlyOperator {
        require(_cashPriceCeiling >= peggedPrice && _cashPriceCeiling <= peggedPrice.mul(120).div(100), "out of range"); // [$0.5, $0.6]
        cashPriceCeiling = _cashPriceCeiling;
    }

    function setCashPriceMaxPremium(uint256 _cashPriceCeilingForRedeemBond) external onlyOperator {
        require(_cashPriceCeilingForRedeemBond >= peggedPrice && _cashPriceCeilingForRedeemBond <= peggedPrice.mul(200).div(100), "out of range"); // [$0.5, $1.0]
        cashPriceCeilingForRedeemBond = _cashPriceCeilingForRedeemBond;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent, uint256 _maxSupplyExpansionPercentInDebtPhase) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 3000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 30%]
        require(
            _maxSupplyExpansionPercentInDebtPhase >= 10 && _maxSupplyExpansionPercentInDebtPhase <= 3000,
            "_maxSupplyExpansionPercentInDebtPhase: out of range"
        ); // [0.1%, 30%]
        require(
            _maxSupplyExpansionPercent <= _maxSupplyExpansionPercentInDebtPhase,
            "_maxSupplyExpansionPercent is over _maxSupplyExpansionPercentInDebtPhase"
        );
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
        maxSupplyExpansionPercentInDebtPhase = _maxSupplyExpansionPercentInDebtPhase;
        emit ExpansionRateChanged(_maxSupplyExpansionPercent, _maxSupplyExpansionPercentInDebtPhase);
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 13000, "out of range"); // [5%, 130%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setSeigniorageBoardroomPercent(uint256 _seigniorageBoardroomPercent) external onlyOperator {
        require(_seigniorageBoardroomPercent >= 3000 && _seigniorageBoardroomPercent <= 10000, "out of range"); // [30%, 100%]
        seigniorageBoardroomPercent = _seigniorageBoardroomPercent;
    }

    function setSeigniorageBoardroomPercentInDebtPhase(uint256 _seigniorageBoardroomPercentInDebtPhase) external onlyOperator {
        require(_seigniorageBoardroomPercentInDebtPhase >= 3000 && _seigniorageBoardroomPercentInDebtPhase <= 10000, "out of range"); // [30%, 100%]
        seigniorageBoardroomPercentInDebtPhase = _seigniorageBoardroomPercentInDebtPhase;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 3000, "out of range"); // [0.1%, 30%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setMarketingFund(address _marketingFund) external onlyOperator {
        require(_marketingFund != address(0), "zero");
        marketingFund = _marketingFund;
    }

    function migrate(address target) external onlyOperator {
        require(!migrated, "Migrated");
        checkOperator();

        // cash
        Operator(cash).transferOperator(target);
        Operator(cash).transferOwnership(target);
        IERC20(cash).transfer(target, IERC20(cash).balanceOf(address(this)));

        // bond
        Operator(bond).transferOperator(target);
        Operator(bond).transferOwnership(target);
        IERC20(bond).transfer(target, IERC20(bond).balanceOf(address(this)));

        // share
        Operator(share).transferOperator(target);
        Operator(share).transferOwnership(target);
        IERC20(share).transfer(target, IERC20(share).balanceOf(address(this)));

        migrated = true;
        emit Migration(target);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateCashPrice() internal {
        try IOracle(priceOracle).update() {} catch {}
    }

    function buyBonds(uint256 amount, uint256 targetPrice) external onlyOneBlock {
        checkCondition();
        checkOperator();
        require(amount > 0, "Zero amount");

        uint256 cashPrice = getCashPrice();
        require(cashPrice == targetPrice, "Cash price moved");
        require(
            cashPrice < peggedPrice, // price < $0.5
            "CashPrice < 0.5"
        );

        require(amount <= epochSupplyContractionLeft, "No bond left");

        uint256 cashSupply = IERC20(cash).totalSupply();
        uint256 newBondSupply = IERC20(bond).totalSupply().add(amount);
        require(newBondSupply <= cashSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(cash).burnFrom(msg.sender, amount);
        IBasisAsset(bond).mint(msg.sender, amount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(amount);
        _updateCashPrice();

        emit BoughtBonds(msg.sender, amount, amount);
    }

    function redeemBonds(uint256 amount, uint256 targetPrice) external onlyOneBlock {
        checkCondition();
        checkOperator();
        require(amount > 0, "Zero amount");

        uint256 cashPrice = getCashPrice();
        require(cashPrice == targetPrice, "Cash price moved");
        
        uint256 _rate = getBondExchangeRate();
        require(_rate > 0, "Invalid bond rate");

        uint256 _cashAmount = amount.mul(_rate).div(1e18);
        require(IERC20(cash).balanceOf(address(this)) >= _cashAmount, "Treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _cashAmount));

        IBasisAsset(bond).burnFrom(msg.sender, amount);
        IERC20(cash).safeTransfer(msg.sender, _cashAmount);

        _updateCashPrice();

        emit RedeemedBonds(msg.sender, _cashAmount, amount);
    }

    function _sendToBoardRoom(uint256 _amount) internal {
        IBasisAsset(cash).mint(address(this), _amount);
        IERC20(cash).safeApprove(boardroom, 0);
        IERC20(cash).safeApprove(boardroom, _amount);
        IBoardroom(boardroom).allocateSeigniorage(_amount);
        emit BoardroomFunded(now, _amount);
    }

    function allocateSeigniorage() external onlyOneBlock {
        checkCondition();
        checkEpoch();
        checkOperator();
        _updateCashPrice();
        uint256 cashSupply = IERC20(cash).totalSupply().sub(seigniorageSaved);
        uint256 cashPrice = getCashPrice();

        emit NewEpoch(epoch, cashPrice);
        if (cashPrice > cashPriceCeiling) {
            uint256 bondSupply = IERC20(bond).totalSupply();
            uint256 _percentage = cashPrice.sub(peggedPrice);
            
            if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                // saved enough to pay debt, mint as usual rate
                uint256 _mse = maxSupplyExpansionPercent.mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                uint256 _seigniorage = cashSupply.mul(_percentage).div(1e18);
                uint256 _savedForBoardRoom = _seigniorage.mul(seigniorageBoardroomPercent).div(10000);
                _sendToBoardRoom(_savedForBoardRoom);
            
                IBasisAsset(cash).mint(marketingFund, _seigniorage - _savedForBoardRoom);
                emit MarketingFundFunded(now, _seigniorage - _savedForBoardRoom);
            } else {
                // have not saved enough to pay debt, mint more
                uint256 _mse = maxSupplyExpansionPercentInDebtPhase.mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                uint256 _seigniorage = cashSupply.mul(_percentage).div(1e18);
                uint256 _savedForBoardRoom = _seigniorage.mul(seigniorageBoardroomPercentInDebtPhase).div(10000);
                _sendToBoardRoom(_savedForBoardRoom);

                uint256 _savedForBond = _seigniorage.sub(_savedForBoardRoom);
                
                seigniorageSaved = seigniorageSaved.add(_savedForBond);
                IBasisAsset(cash).mint(address(this), _savedForBond);
                emit TreasuryFunded(now, _savedForBond);
            }
        }
    }
    
    /* ========== RECOVER UNSUPPORTED ========== */

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(cash), "cash");
        require(address(_token) != address(bond), "bond");
        require(address(_token) != address(share), "share");
        _token.safeTransfer(_to, _amount);
    }

    /* ========== BOARDROOM CONTROLLING FUNCTIONS ========== */

    function boardroomSetOperator(address _operator) external onlyOperator {
        IBoardroom(boardroom).setOperator(_operator);
    }

    function boardroomSetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        IBoardroom(boardroom).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function boardroomAllocateSeigniorage(uint256 amount) external onlyOperator {
        IBoardroom(boardroom).allocateSeigniorage(amount);
    }

    function boardroomGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        IBoardroom(boardroom).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
