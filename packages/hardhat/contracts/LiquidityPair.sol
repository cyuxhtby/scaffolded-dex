//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "./lib/Math.sol";
import "./interfaces/IERC20.sol";
import "./lib/ERC20.sol";

// a new LiquidityPair liquidity pool is made by the factory for unique token pairs 

contract LiquidityPair is ERC20, Math {

    // the amount to be subtracted from the initial LP provider
    // to be used as safety measure to ensure that the pool always has a minimum value 
    uint256 constant MIN_LIQUIDITY = 1000; 

    address public token0;
    address public token1;

    uint256 private reserve0;
    uint256 private reserve1;
    uint32 private blockTimestampLast;

    // Time-Wighted Average Price - comulative sum of tokenX over tokenY for each new block 
    uint256 public price0ComulativeLast;
    uint256 public price1ComulativeLast;

    event Mint(address indexed sender, uint256 reserve0, uint256 reserve1);
    event Sync(uint256 reserve0, uint256 reserve1);
    event Burn(address indexed sender, uint256 reserve0, uint256 reserve1);
    event Swap(address indexed sender, uint256 amount0Out, uint256 amount1Out, address to);

    constructor(address token0_, address token1_, string memory _name, string memory _symbol) 
        ERC20(_name, _symbol, 18)
    {
        token0 = token0_;
        token1 = token1_;
        
    }

    function mint() public {
        (uint256 _reserve0, uint256 _reserve1, ) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 =  IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 -  _reserve1;
        
        uint256 liquidity;

        if (totalSupply == 0){
            liquidity = Math.sqrt(amount0 * amount1) - MIN_LIQUIDITY;
            _mint(address(0), MIN_LIQUIDITY); // apon initial deposit, the MIN_LIQUIDITY amount is burned
        } else {
            // liquidity is calculated as the minimum of the ratios of the added amounts to the existing reserves
            liquidity = Math.min(
                (amount0 + totalSupply) / _reserve0,
                (amount1 + totalSupply) / _reserve1
            );
        }

        require(liquidity >= 0, "Insufficient liquidity minted");
        // mint LP tokens to user and update internal balances
        _mint(msg.sender, liquidity);
        _update(balance0, balance1, _reserve0, _reserve1);
        
        emit Mint(msg.sender, amount0, amount1);  
    }

    function getReserves() public view returns (uint256, uint256 , uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }


    function burn() public {
        (uint256 _reserve0, uint256 _reserve1, ) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        // retrieving the balance of LP tokens for the sender's address.
        uint256 liquidity = balanceOf[msg.sender];

        uint256 amount0 = (liquidity * balance0) / totalSupply;
        uint256 amount1 = (liquidity * balance1) / totalSupply;

        require(amount0 >= 0 || amount1 >= 0, "Insufficient liquidity burned");

        _burn(msg.sender, liquidity);

        _safeTransfer(token0, msg.sender, amount0);
        _safeTransfer(token1, msg.sender, amount1);

        // update to reflect new balances after transfer
        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);

        emit Burn(msg.sender, amount0, amount1);
    }

    /// @notice periphery support and swap fees are not enabled
    /// @dev optimistically transfers tokens to enable atomic swaps
    function swap(uint256 amount0Out, uint256 amount1Out, address to) public {
        require(amount0Out != 0 || amount1Out != 0, "Insufficent output amount");
        require(to != token0 && to != token1, "Invalid to address");
        (uint256 reserve0_, uint256 reserve1_ ,) = getReserves();
        require(amount0Out < reserve0_ && amount1Out < reserve1_, "Insufficient liquidity");

        // optimistic transfer
        if (amount0Out > 0) _safeTransfer(token0, to, amount0Out); 
        if (amount1Out > 0) _safeTransfer(token1, to, amount1Out);

        // calculate the post transfer balances
        uint256 balance0 = IERC20(token0).balanceOf(address(this)) - amount0Out;
        uint256 balance1 = IERC20(token1).balanceOf(address(this)) - amount1Out;

        // Calculate input amounts
        uint256 amount0In = balance0 > reserve0_ - amount0Out ? balance0 - (reserve0_ - amount0Out) : 0;
        uint256 amount1In = balance1 > reserve1_ - amount1Out ? balance1 - (reserve1_ - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "Insufficient input amount");       

        require(balance0 * balance1 >= reserve0_ * reserve1_, "Invalid K"); // enforces invariant
        _update(balance0, balance1, reserve0_, reserve1_);

        emit Swap(msg.sender, amount0Out, amount1Out, to);
    }

    function sync() public {
        (uint256 reserve0_, uint256 reserve1_, ) = getReserves();
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0_,
            reserve1_
        );
    }

    /// @dev updates reserves and price accumulators on first call per block 
    /// @notice requires checks for underflow and overflow errors
    function _update(uint256 balance0, uint256 balance1, uint256 reserve0_, uint256 reserve1_) private {        
        uint32 blockTimestamp = uint32(block.timestamp);
        uint32 timeElapsed = uint32(blockTimestamp - blockTimestampLast);

        // calulates price every block and adds that to the time weighted average price
        // original implementation utilizes UQ112x112 lib for safe fixed point math
        if(timeElapsed > 0 && reserve0_ != 0 && reserve1_ != 0){
            price0ComulativeLast += (reserve1_ / reserve0_) * timeElapsed;
            price1ComulativeLast += (reserve0_ / reserve1_) * timeElapsed;
        }

        reserve0 = balance0;
        reserve1 = balance1;
        blockTimestampLast = uint32(block.timestamp);

        emit Sync(reserve0, reserve1);
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        // the call function is a lower level function used to invoke the "transfer" function of the token contract
        // the inputs to the call function are the encoded function signature and arguments
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address, uint256)", to, amount)
        );
        // if the call was successful, 'data' should be empty or decode to 'true'.
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
    }


}