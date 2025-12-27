// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/**
 * @title GSCNX Token (Pro Version)
 * @dev Standard ERC20 token with advanced liquidity infrastructure compatibility.
 * Optimized for PancakeSwap Infinity (V4) with ceiling division fees and robust ownership security.
 */
contract GSCNX is ERC20, ERC20Burnable, ERC20Permit, Ownable {

    uint8 private constant _DECIMALS = 6;
    uint256 public constant TOTAL_SUPPLY = 500_000_000_000 * 10 ** _DECIMALS;

    // --- Liquidity & Router Configuration ---

    /// @notice Identifies standard AMM pairs (V2/V3) for fee logic application.
    mapping(address => bool) public automatedMarketMakerPairs;

    /// @notice Whitelist for advanced liquidity routers (e.g., V4 Vaults, Cross-chain bridges).
    /// @dev Addresses marked 'true' bypass standard limits and fees.
    mapping(address => bool) public isLiquidityRouter;

    // --- Events ---

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event BuyTaxEnabledUpdated(bool enabled);
    event LiquidityRouterStatusUpdated(address indexed router, bool status);
    event InitialBuyFeeUpdated(uint256 newFee);
    
    // [Optimization 1] Added event: Anti-clamp status change
    event AntiSnipeEnabledUpdated(bool enabled);

    // --- Anti-Bot & Trading Controls ---

    mapping(address => uint256) private _lastBuyBlock;

    bool public tradingActive;
    bool public antiSnipeEnabled = true;
    
    // Master switch for Fee collection mechanism
    bool public buyTaxEnabled = true; 

    uint256 public tradingStartBlock;
    uint256 public tradingStartTime; 

    // --- Limits & Wallet Settings ---

    uint256 public maxTxAmount;
    uint256 public maxWallet;
    address public taxWallet;
    
    // --- Fee Structure ---
    
    // Final fee rates (Long-term policy)
    uint256 public constant FINAL_BUY_FEE = 500; // 5%
    uint256 public constant FINAL_SELL_FEE = 0;   

    // Initial fee rates (Launch phase - Adjustable)
    uint256 public initialBuyFee = 2000;        
    uint256 public constant initialSellFee = 0;
    
    // PancakeSwap V3 Factory (BSC Mainnet)
    address public constant FACTORY_V3 = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;

    constructor()
        ERC20("GSCNX", "GSCNX")
        ERC20Permit("GSCNX")
        Ownable(msg.sender)
    {
        _mint(msg.sender, TOTAL_SUPPLY);

        // Security Limits:
        // Max Transaction: 0.02% of Total Supply
        // Max Wallet: 1.0% of Total Supply
        maxTxAmount = TOTAL_SUPPLY * 1 / 5000; 
        maxWallet   = TOTAL_SUPPLY * 10 / 1000; 

        taxWallet = msg.sender;
    }

    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    // --- Administrative Functions ---

    /**
     * @dev Enables trading. This action is irreversible.
     */
    function enableTrading() external onlyOwner {
        require(!tradingActive, "Trading already active");
        tradingActive = true;
        tradingStartBlock = block.number;
        tradingStartTime = block.timestamp; 
    }

    function setTaxWallet(address _taxWallet) external onlyOwner {
        require(_taxWallet != address(0), "Invalid address");
        taxWallet = _taxWallet;
    }

    function setBuyTaxEnabled(bool _enabled) external onlyOwner {
        buyTaxEnabled = _enabled;
        emit BuyTaxEnabledUpdated(_enabled);
    }

    function setAntiSnipeEnabled(bool _enabled) external onlyOwner {
        antiSnipeEnabled = _enabled;
        emit AntiSnipeEnabledUpdated(_enabled);
    }

    function setLimits(uint256 _maxTx, uint256 _maxWallet) external onlyOwner {
        require(_maxTx >= TOTAL_SUPPLY / 5000, "Limit too low");
        require(_maxWallet >= (TOTAL_SUPPLY * 10) / 1000, "Wallet limit too low");
        maxTxAmount = _maxTx;
        maxWallet = _maxWallet;
    }

    function setAutomatedMarketMakerPair(address pair, bool value) external onlyOwner {
        require(pair != address(0), "Invalid pair address");
        automatedMarketMakerPairs[pair] = value;
        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function setLiquidityRouter(address _router, bool _status) external onlyOwner {
        require(_router != address(0), "Invalid address");
        isLiquidityRouter[_router] = _status;
        emit LiquidityRouterStatusUpdated(_router, _status);
    }

    function setInitialBuyFee(uint256 _fee) external onlyOwner {
        require(_fee <= 2500, "Safety: Fee exceeds limit"); 
        initialBuyFee = _fee;
        emit InitialBuyFeeUpdated(_fee);
    }
    
    function cacheV3Pools(address tokenB, uint24[] calldata fees) external onlyOwner {
        for (uint256 i = 0; i < fees.length; i++) {
            address pool = IPancakeV3Factory(FACTORY_V3).getPool(address(this), tokenB, fees[i]);
            if (pool != address(0)) {
                automatedMarketMakerPairs[pool] = true;
                emit SetAutomatedMarketMakerPair(pool, true);
            }
        }
    }

    // --- Core Logic ---

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        // 1. Infrastructure Exemption (Priority High)
        if (isLiquidityRouter[from] || isLiquidityRouter[to]) {
            super._update(from, to, amount);
            return;
        }

        // 2. Standard Exemptions
        bool isExempt = (from == owner() || to == owner() || from == address(this) || to == address(this) || from == taxWallet || to == taxWallet);
        if (isExempt) {
            super._update(from, to, amount);
            return;
        }

        if (!tradingActive) {
            require(automatedMarketMakerPairs[to] || automatedMarketMakerPairs[from], "Trading not active");
        }

        bool isBuy = automatedMarketMakerPairs[from]; 
        uint256 feeAmount = 0;

        if (tradingActive) {
            // A. Anti-Snipe & Limits
            if (antiSnipeEnabled) {
                if (isBuy) {
                    require(_lastBuyBlock[to] < block.number, "Rate limit: One tx per block");
                    _lastBuyBlock[to] = block.number;

                    require(amount <= maxTxAmount, "Exceeds maxTxAmount");
                    require(balanceOf(to) + amount <= maxWallet, "Exceeds maxWallet");

                    if (block.number <= tradingStartBlock + 8) {
                        require(amount <= maxTxAmount / 5, "Launch protection active");
                    }
                } 
                else if (automatedMarketMakerPairs[to]) { 
                    require(amount <= maxTxAmount, "Exceeds maxTxAmount");
                }
            }

            // B. Fee Calculation [Optimization 2: Rounding Up Algorithm]
            if (isBuy && buyTaxEnabled) {
                uint256 currentFeeRate;
                
                // Determine rate
                if (block.timestamp > tradingStartTime + 900) {
                    currentFeeRate = FINAL_BUY_FEE; 
                } else {
                    currentFeeRate = initialBuyFee; 
                }

                // Math: Ceiling Division (Round Up)
                // Formula: (amount * fee + 9999) / 10000
                // This ensures even 1 wei of theoretical fee results in 1 wei actual fee.
                if (amount > 0 && currentFeeRate > 0) {
                    feeAmount = (amount * currentFeeRate + 9999) / 10000;
                }
            } 
        }

        if (feeAmount > 0) {
            super._update(from, taxWallet, feeAmount);
            super._update(from, to, amount - feeAmount);
        } else {
            super._update(from, to, amount);
        }
    }

    /**
     * @dev Renounce Ownership override.
     * Prevents renouncing before trading is active to ensure contract is not deadlocked.
     */
    function renounceOwnership() public override onlyOwner {
        require(tradingActive, "Trading must be active");
        super.renounceOwnership();
    }

    /**
     * [Optimization 3 Implementation] Overrides transferOwnership.
     * If newOwner is the zero address, it enforces the same security checks as renounceOwnership.
     * This prevents bypassing the "renounce" restrictions via a direct "transfer to 0x0".
     */
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0)) {
            require(tradingActive, "Trading must be active");
        }
        super.transferOwnership(newOwner);
    }
}
