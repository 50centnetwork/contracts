// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import '@openzeppelin/contracts/math/Math.sol';

contract NetworkReward {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant BLOCKS_PER_MONTH = 864000; // 86400 * 30 / 2
    
    // governance
    address public operator;

    // Info of each user.
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastRewardBlock;
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint; 
        uint256 lastRewardBlock;
        uint256 accTokenPerShare;
        bool isStarted;
    }

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    uint256 public currentPeriod = 0;
    uint256 public periodFinish;
    
    mapping(address => uint256[]) public _locks;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    IERC20 public token;
    uint256 public startBlock = 0;
    uint256 public daoFundDivRate = 0;
    address public daoFundAddr;
    uint256 public endLockedBlock = 0;
    uint256[] public arrReleaseBlock;
    uint256[] public arrPeriodReward;
    uint256[] public arrRewardPerBlock;

    uint256 public lockedRate = 8000;
    uint256 public totalTransfer = 0;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    constructor(address _token, 
                address _daoFundAddr, 
                uint256 _daoFundDivRate,
                uint256 _startBlock,
                uint256 _periodFinish,
                uint256 _endLockedBlock,
                uint256[] memory _arrReleaseBlock,
                uint256[] memory _arrPeriodReward,
                uint256[] memory _arrRewardPerBlock) public {
        token = IERC20(_token);
        daoFundAddr = _daoFundAddr;
        daoFundDivRate = _daoFundDivRate;
        startBlock = _startBlock;
        periodFinish = _periodFinish;
        endLockedBlock = _endLockedBlock;
        arrReleaseBlock = _arrReleaseBlock;
        arrPeriodReward = _arrPeriodReward;
        arrRewardPerBlock = _arrRewardPerBlock;

        operator = msg.sender;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "NetworkReward: caller is not the operator");
        _;
    }

    modifier checkhalve() {
        if (block.number >= arrPeriodReward[currentPeriod]) {
            if(currentPeriod <= arrPeriodReward.length - 1) {
                currentPeriod = currentPeriod + 1;
            }
        }
        _;
    }

    function getTokenPerBlock() internal view returns (uint256) {
        return arrRewardPerBlock[currentPeriod];
    }

    function checkPoolDuplicate(IERC20 _lpToken) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].lpToken != _lpToken, "NetworkReward: existing pool?");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate,
        uint256 _lastRewardBlock
    ) public onlyOperator {
        checkPoolDuplicate(_lpToken);
        if (_withUpdate) {
            massUpdatePools();
        }
        if (block.number < startBlock) {
            // chef is sleeping
            if (_lastRewardBlock == 0) {
                _lastRewardBlock = startBlock;
            } else {
                if (_lastRewardBlock < startBlock) {
                    _lastRewardBlock = startBlock;
                }
            }
        } else {
            // chef is cooking
            if (_lastRewardBlock == 0 || _lastRewardBlock < block.number) {
                _lastRewardBlock = block.number;
            }
        }
        bool _isStarted =
        (_lastRewardBlock <= startBlock) ||
        (_lastRewardBlock <= block.number);
        poolInfo.push(PoolInfo({
            lpToken : _lpToken,
            allocPoint : _allocPoint,
            lastRewardBlock : _lastRewardBlock,
            accTokenPerShare : 0,
            isStarted : _isStarted
        }));
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's Amount allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) public onlyOperator {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(
                _allocPoint
            );
        }
        pool.allocPoint = _allocPoint;
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _from, uint256 _to) public view returns (uint256) {
        uint256 tokenPerBlock = getTokenPerBlock();
        uint256 endBlock = Math.min(block.number, periodFinish);
        if (_from >= _to) return 0;
        if (_to >= endBlock) {
            if (_from >= endBlock) return 0;
            if (_from <= startBlock) return endBlock.sub(startBlock).mul(tokenPerBlock);
            return endBlock.sub(_from).mul(tokenPerBlock);
        } else {
            if (_to <= startBlock) return 0;
            if (_from <= startBlock) return _to.sub(startBlock).mul(tokenPerBlock);
            return _to.sub(_from).mul(tokenPerBlock);
        }
    }

    // View function to see pending Amounts on frontend.
    function pendingToken(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardBlock, block.number);
            uint256 _tokenReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            
            if(daoFundDivRate > 0) {
                uint256 daoFundAmount = _tokenReward.mul(daoFundDivRate).div(10000);
                _tokenReward = _tokenReward.sub(daoFundAmount);
            }
            
            accTokenPerShare = accTokenPerShare.add(
                _tokenReward.mul(1e18).div(lpSupply)
            );
        }
        return user.amount.mul(accTokenPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardBlock, block.number);
            uint256 _tokenReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);

            if(daoFundDivRate > 0) {
                uint256 daoFundAmount = _tokenReward.mul(daoFundDivRate).div(10000);
                safeTokenTransfer(daoFundAddr, daoFundAmount);
                _tokenReward = _tokenReward.sub(daoFundAmount);
            }

            pool.accTokenPerShare = pool.accTokenPerShare.add(
                _tokenReward.mul(1e18).div(lpSupply)
            );
        }
        pool.lastRewardBlock = block.number;
    }

    function harvest(uint256 _pid, address _account) external checkhalve {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_account];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accTokenPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                if(block.number < endLockedBlock) {
                    uint256 _lockedAmount = _pending.mul(lockedRate).div(10000);
                    lock(_account, _lockedAmount);
                    _pending = _pending.sub(_lockedAmount);
                } else if(user.lastRewardBlock < endLockedBlock) {
                    uint256 _mustLock = _pending.mul(endLockedBlock.sub(user.lastRewardBlock)).div(block.number.sub(user.lastRewardBlock));
                    uint256 _lockedAmount = _mustLock.mul(lockedRate).div(10000);
                    lock(_account, _lockedAmount);
                    _pending = _pending.sub(_lockedAmount);
                }
                safeTokenTransfer(_account, _pending);
                emit RewardPaid(_account, _pending);
            }
        }
        user.lastRewardBlock = block.number;
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e18);
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) public checkhalve {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accTokenPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                if(block.number < endLockedBlock) {
                    uint256 _lockedAmount = _pending.mul(lockedRate).div(10000);
                    lock(_sender, _lockedAmount);
                    _pending = _pending.sub(_lockedAmount);
                } else if(user.lastRewardBlock < endLockedBlock) {
                    uint256 _mustLock = _pending.mul(endLockedBlock.sub(user.lastRewardBlock)).div(block.number.sub(user.lastRewardBlock));
                    uint256 _lockedAmount = _mustLock.mul(lockedRate).div(10000);
                    lock(_sender, _lockedAmount);
                    _pending = _pending.sub(_lockedAmount);
                }
                safeTokenTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(_sender, address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.lastRewardBlock = block.number;
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public checkhalve {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accTokenPerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            if(block.number < endLockedBlock) {
                uint256 _lockedAmount = _pending.mul(lockedRate).div(10000);
                lock(_sender, _lockedAmount);
                _pending = _pending.sub(_lockedAmount);
            } else if(user.lastRewardBlock < endLockedBlock) {
                uint256 _mustLock = _pending.mul(endLockedBlock.sub(user.lastRewardBlock)).div(block.number.sub(user.lastRewardBlock));
                uint256 _lockedAmount = _mustLock.mul(lockedRate).div(10000);
                lock(_sender, _lockedAmount);
                _pending = _pending.sub(_lockedAmount);
            }
            safeTokenTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(_sender, _amount);
        }
        user.lastRewardBlock = block.number;
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    function lockOf(address _account) public view returns (uint256) {
        uint256 _amount = 0;
        for (uint256 idx = 0; idx < 4; ++idx) {
            _amount = _amount.add(_locks[_account][idx]);
        }
        return _amount;
    }

    function lock(address _account, uint256 _amount) internal {
        uint256 lockedAmount = _amount.mul(25).div(100);
        if(_locks[_account].length == 0) {
            _locks[_account] = [lockedAmount, lockedAmount, lockedAmount, lockedAmount];
        } else {
            for (uint256 idx = 0; idx < 4; ++idx) {
                _locks[_account][idx] = _locks[_account][idx].add(lockedAmount);
            }
        }
    }

    function canUnlockAmount(address _account) public view returns (uint256) {
        // When block number less than arrReleaseBlock[0], no Amounts can be unlocked
        if (block.number < arrReleaseBlock[0]) {
            return 0;
        }
        // When block number is more than arrReleaseBlock[0]
        // some Amounts can be released
        else
        {
            uint256 _amount = 0;
            if(_locks[_account].length > 0) {
                for (uint256 idx = 0; idx < 4; ++idx) {
                    if(block.number > arrReleaseBlock[idx]) {
                        _amount = _amount.add(_locks[_account][idx]);
                    }
                }
            }
            return _amount;
        }
    }

    function unlock() public {
        address _sender = msg.sender;
        uint256 _lockedAmount = lockOf(_sender);
        require(_lockedAmount > 0, "no locked Amount");
        
        uint256 amount = canUnlockAmount(_sender);
        require(amount > 0, "no Amount can be unlocked");

        safeTokenTransfer(_sender, amount);
        for (uint256 idx = 0; idx < 4; ++idx) {
            if(block.number > arrReleaseBlock[idx]) {
                _locks[_sender][idx] = 0;
            }
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe token transfer function, just in case if rounding error causes pool to not have enough Amounts.
    function safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 _tokenBal = token.balanceOf(address(this));
        if (_tokenBal > 0) {
            if (_amount > _tokenBal) {
                token.safeTransfer(_to, _tokenBal);
                totalTransfer = totalTransfer.add(_tokenBal);
            } else {
                token.safeTransfer(_to, _amount);
                totalTransfer = totalTransfer.add(_amount);
            }
        }
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setDAOFundAddr(address _daoFundAddr) public {
        require(msg.sender == daoFundAddr, "daoFundAddr: wut?");
        daoFundAddr = _daoFundAddr;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        if (block.number < startBlock + BLOCKS_PER_MONTH * 12) {
            // do not allow to drain core token (Amount or lps) before pool ends
            require(_token != token, "token");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.lpToken, "pool.lpToken");
            }
        }
        _token.safeTransfer(to, amount);
    }
}
