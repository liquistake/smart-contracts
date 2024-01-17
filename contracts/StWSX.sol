// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import "./IStWSX.sol";
import "./IStakingProxy.sol";
import "./ICompoundStakeProxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title Liquid staking pool implementation
 *
 * LiquiStake is a SX Network liquid staking protocol solving the problem of frozen WSX staked with validators
 * being unavailable for transfers and DeFi.
 *
 * Since balances of all token holders change when the amount of total pooled WSX
 * changes, this token cannot fully implement ERC20 standard: it only emits `Transfer`
 * events upon explicit transfer between holders. In contrast, when LiquiStake oracle reports
 * rewards, no Transfer events are generated: doing so would require emitting an event
 * for each token holder and thus running an unbounded loop.
 *
 * ---
 *
 * @dev StWSX is derived from `IStWSX`.
 *
 */
contract StWSX is IStWSX, AccessControl, ReentrancyGuard {
    // testnet items
    // STAKING PROXY: 0xAEb6Cf65c48064aF0FA8554199CB8eAd499D92A5
    // WSX: 0x2D4e10Ee64CCF407C7F765B363348f7F62D2E06e
    // VALIDATOR: 0x3e64F88C6C7a1310236B242180c0Ba1409d10F4d
    // DAO: 0xB1cB92619902DA57b8f0f910AE553222DE9ACc56

    // ACL
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // other constants
    uint256 public constant MINIMUM_DEPOSIT_AMOUNT = 10 ** 6;

    // keeps track of the number of oracle providers
    uint public numOracles = 0;

    // @dev the following can be updated by the ADMIN_ROLE
    address private VALIDATOR_ADDRESS;
    IERC20 private _wsxToken;
    IStakingProxy private _stakingProxy;
    ICompoundStakeProxy private _compoundStakeProxy;

    // TODO: our DAO protocol address here
    address DAO_ADDRESS;

    // @dev protocol fees are represented as bips 100 = 1%
    uint public mintFee = 100;
    uint public rewardFee = 1000;

    // slippage tollerated when compounding WSX as bips 100 = 1%
    uint public maxSlippage = 200;

    // keeps track of total WSX in contract including reported rewards
    uint totalPooledWSX = 0;

    // waiting to be unstaked
    uint public waitingToUnstake = 0;

    // amount that can be claimed
    uint public unstakedWSX = 0;

    // accounting reports
    mapping(bytes32 => uint256) private _accountingReports;

    // pending unstake requests
    mapping(address => uint256) private _unstakeRequests;
    // pending unstake times
    mapping(address => uint256) private _latestUnstakeTime;
    // the last time that this contract has unstaked WSX
    uint256 public lastUnstakeTime = 0;
    // last time of reported rewards
    uint256 public lastRewardsReport;

    constructor() {
        _grantRole(ADMIN_ROLE, msg.sender); // make the deployer admin
        _grantRole(ORACLE_ROLE, msg.sender); // make the deployer provider temporarily as well

        // add our designated oracle
        _grantRole(ORACLE_ROLE, 0x872846e14F560FC899969942A00a7B0aC277726B);

        // This sets the initial share to WEI ratio that is also the denomination of wstWSX to stWSX
        _mintInitialShares(1);
        totalPooledWSX = 1;

        // currently all test net, these will be moved to a setup script
        DAO_ADDRESS = 0xB1cB92619902DA57b8f0f910AE553222DE9ACc56;
        VALIDATOR_ADDRESS = 0x3e64F88C6C7a1310236B242180c0Ba1409d10F4d;
        _wsxToken = IERC20(0x2D4e10Ee64CCF407C7F765B363348f7F62D2E06e);
        _stakingProxy = IStakingProxy(
            0xAEb6Cf65c48064aF0FA8554199CB8eAd499D92A5
        );
        _compoundStakeProxy = ICompoundStakeProxy(
            0x0dD2c0b61C8a8FF8Fbf84a82a188B81247d5AdFe
        );

        lastRewardsReport = block.timestamp;
    }

    function unstakeAvailableTimeOf(address adr) public view returns (uint) {
        return (_latestUnstakeTime[adr] + (_stakingProxy._withdrawDelay() * 2));
    }

    function unstakeRequestTimeOf(address adr) public view returns (uint) {
        return _latestUnstakeTime[adr];
    }

    function unstakeRequestAmountOf(address adr) public view returns (uint) {
        return _unstakeRequests[adr];
    }

    /*
     * @notice Send funds to the pool
     * @dev Users are able to submit their funds by transacting to the deposit function.
     * A user will need to Approve the WSX contract to allow the stWSX to spend on its behalf.
     * deposit() automatically stakes the tokens and mints stWSX to represents the user's claim
     * on the pool with respect to how much they contributed.
     * @param amount The amount of WSX to deposit for staking into stWSX
     */
    function deposit(uint amount) external nonReentrant {
        // do not allow zero deposit amount
        require(amount > 0, "ZERO_DEPOSIT");
        require(
            amount >= MINIMUM_DEPOSIT_AMOUNT,
            "Must deposit at least 100,000 WEI of WSX"
        );

        // transfer funds
        _wsxToken.transferFrom(msg.sender, address(this), amount);

        // capture minting fee
        uint mintFeeAmount = calculateMintFee(amount);

        // transfer the mint fee to the DAO treasury
        _wsxToken.transfer(DAO_ADDRESS, mintFeeAmount);

        // amount the user is credited for depositing net of mint fees
        uint256 depositAmount = amount - mintFeeAmount;

        // approve deposit into staking contract
        _wsxToken.approve(address(_stakingProxy), depositAmount);

        // stake funds
        _stakingProxy.stake(depositAmount, VALIDATOR_ADDRESS);

        // calculate new shares
        uint sharesAmount = getSharesByPooledWSX(depositAmount);

        // mint new StWSX Tokens
        _mintShares(msg.sender, sharesAmount);

        // increase total WSX by amount deposited
        totalPooledWSX += depositAmount;

        _emitTransferAfterMintingShares(msg.sender, sharesAmount);
        emit Deposit(
            msg.sender,
            amount,
            sharesAmount,
            depositAmount,
            mintFeeAmount
        );
        emit FeesCollected(block.timestamp, mintFeeAmount);
    }

    /*
     * @notice Claims all WSX that has been unstaked and withdrawn from the validator
     * @dev A user must wait for the unstaking period to pass before claiming funds.
     * A User must first submit a request to claim via unstake() to initate the process.
     */
    function claim() external nonReentrant {
        uint amount = _unstakeRequests[msg.sender];

        // user has to have a balance waiting to be claimed
        require(amount != 0, "Nothing to claim.");
        // user must wait two periods to ensure that the WSX they are claiming has been withdrawn
        require(
            block.timestamp >
                (_latestUnstakeTime[msg.sender] +
                    (_stakingProxy._withdrawDelay() * 2)),
            "Insufficient time passed since unstake."
        );
        // confirm there is enough money in this contract
        require(unstakedWSX >= amount, "Not enough WSX to satisfy claim.");
        // confirm there is enough money in the WSX contract for this contract's balance
        require(
            _wsxToken.balanceOf(address(this)) >= amount,
            "Not enough WSX to satisfy claim."
        );

        // reset after claiming
        _unstakeRequests[msg.sender] = 0;
        unstakedWSX -= amount;

        // send WSX from this contract back to the user
        _wsxToken.transfer(msg.sender, amount);
    }

    /*
     * @notice Initiates an unstake request for a user's balance converting stWSX to WSX
     * @dev A user must wait for the unstaking period to pass before claiming funds.
     * When the unstaking period is over they can collect funds via claim().
     * Once initiated withdrawals cannot be undone and a user can only have one withdrawal at a time.
     * @param amount The amount to unstake from the validator
     */
    function unstake(uint amount) external nonReentrant {
        // calculate items before modification
        uint sharesToBurn = getSharesByPooledWSX(amount);
        uint wsxToUnstake = getPooledWSXByShares(getSharesByPooledWSX(amount));

        // must unstake an amount
        require(amount > 0, "Cannot unstake zero amount.");
        // cannot have multiple unstakes in progress at once
        require(
            _unstakeRequests[msg.sender] == 0,
            "Already have one unstake in progress."
        );
        // must have enough stWSX balance to satisfy the unstake request
        require(
            _sharesOf(msg.sender) >= sharesToBurn,
            "Cannot unstake more than your stWSX balance."
        );

        // burn StWSX
        _burnShares(msg.sender, sharesToBurn);
        // remove from total pool
        totalPooledWSX -= wsxToUnstake;

        // user's unstaking time is stored to prevent multiple withdraws at once
        _latestUnstakeTime[msg.sender] = block.timestamp;

        // record how user wants to unstake
        _unstakeRequests[msg.sender] += wsxToUnstake;

        // update the aggregate amount to unstake across all users
        waitingToUnstake += wsxToUnstake;
    }

    /*
     * @notice Provides the amount of WSX that is pending withdrawal from the validator
     * @dev Used for oracle management
     * @return amount The amount to pending to unstake from the validator
     */
    function getPendingWithdrawAmount() external view returns (uint) {
        return _stakingProxy._pendingWithdrawAmounts(address(this));
    }

    /*
     * @notice Forces any unstaked funds to be withdrawn from the validator
     * @dev Used in case of issue with oracle, overrides lastUnstakeTime
     */
    function forceWithdrawUnstaked() external onlyRole(ADMIN_ROLE) {
        _stakingProxy.withdrawUnstaked();
    }

    /*
     * @notice Forces the validator to unstake the funds requested by users
     * @dev Used in case of issue with oracle, overrides lastUnstakeTime
     */
    function forceUnstake() external onlyRole(ADMIN_ROLE) {
        _stakingProxy.unstake(waitingToUnstake);
        waitingToUnstake = 0;
    }

    /*
     * @notice Oracle function called regularly to unstake the funds requested by users
     * @dev This function can only initiate an unstake once every unstaking period.
     */
    function oracleUnstake() external onlyRole(ORACLE_ROLE) {
        // this function can only initiate an unstake once every staking period
        require(waitingToUnstake > 0, "No currency waiting to unstake");
        require(
            block.timestamp >
                (lastUnstakeTime + _stakingProxy._withdrawDelay()),
            "Insufficient time passed since last unstake"
        );

        lastUnstakeTime = block.timestamp;

        // claim any unstaked tokens that are avaiable
        if (_stakingProxy._pendingWithdrawAmounts(address(this)) > 0) {
            _stakingProxy.withdrawUnstaked();
        }

        // initiate unstake for the next batch
        _stakingProxy.unstake(waitingToUnstake);

        // reset after initiating unstake
        waitingToUnstake = 0;
    }

    /*
     * @notice Oracle function called regularly to withdraw unstaked funds from validator through StakingProxy
     * @dev This function is called after unstaking is completed by the StakingProxy
     */
    function oracleWithdrawUnstaked() external onlyRole(ORACLE_ROLE) {
        // claim any unstaked tokens that are avaiable
        // the WSX balance of this contract will be updated and stores the real funds that can be transfered with claim()
        if (_stakingProxy._pendingWithdrawAmounts(address(this)) > 0) {
            _stakingProxy.withdrawUnstaked();
        }
    }

    /*
     * @notice Claims the rewards that are waiting and payable to stWSX holders
     * @notice Oracle only calls once per day
     * @dev This function is called once per day to collect rewards and restake them through the CompoundStakeProxy
     */
    function oracleClaimRewards() external onlyRole(ORACLE_ROLE) {
        // from staking contract get reward token list
        address[] memory rewardTokenList = _stakingProxy.getRewardTokenList();

        // get rewards for each token and calculate the max slippage
        uint[] memory rewardTokenAmounts = new uint[](rewardTokenList.length);
        uint[] memory amountOutMins = new uint[](rewardTokenList.length);

        for (uint c = 0; c < rewardTokenList.length; c++) {
            uint rewards;
            uint commissions;
            (rewards, commissions) = _stakingProxy.pendingRewards(
                rewardTokenList[c],
                address(this)
            );
            rewardTokenAmounts[c] = rewards - commissions;
            amountOutMins[c] = calculateMaxSlippage(rewardTokenAmounts[c]);
        }

        // compound and autostake the WSX
        _compoundStakeProxy.harvestAndCompoundStake(
            rewardTokenList,
            amountOutMins
        );
    }

    /*
     * @notice This is used to do the accounting of unstaked withdrawals on the StakingProxy
     * @notice Triggered by a Withdraw event from the StakingProxy
     * @dev This function is called to report the amount that is unstaked from the StakingProxy and can be withdrawn from stWSX
     * @param amount The amount to increase the withdraw pool by
     */
    function oracleReportUnstakedWithdraw(
        uint amount
    ) external onlyRole(ORACLE_ROLE) {
        unstakedWSX += amount;
    }

    /*
     * @notice Updates rewards for the specified market hash and reward token
     * @notice Oracle function called after a StakeCompounded event is emited from CompoundStakeProxy
     * @dev This function is called to do the accounting for the rewards and rebases the token
     * @param amount The amount to increase the total pool by, this is reported by the CompoundStakeProxy StakeCompounded event
     */
    function oracleReportRewards(
        uint amount,
        bytes32 transactionHash
    ) external onlyRole(ORACLE_ROLE) {
        require(
            _accountingReports[transactionHash] == 0,
            "Transaction hash already reported."
        );

        // record this transaction has in history
        _accountingReports[transactionHash] = amount;

        // get values before they are updated
        uint preShares = _getTotalShares();
        uint preWSX = _getTotalPooledWSX();

        // the time since the last report
        uint periodLength = block.timestamp - lastRewardsReport;

        lastRewardsReport = block.timestamp;

        // add the WSX to the pool
        totalPooledWSX += amount;

        // calculate the protocol reward fee
        uint rewardFeeAmount = calculateRewardFee(amount);

        // put all WSX into pool since it's auto staked
        // mint shares to the DAO for the portion that is the fee
        uint rewardFeesShares = getSharesByPooledWSX(rewardFeeAmount);
        _mintShares(DAO_ADDRESS, rewardFeesShares);

        emit RewardsDistributed(block.timestamp, periodLength, amount, preWSX);
        emit FeesCollected(block.timestamp, rewardFeeAmount);
        emit TokenRebased(
            block.timestamp,
            preShares,
            preWSX,
            _getTotalShares(),
            _getTotalPooledWSX(),
            rewardFeesShares
        );
    }

    // helper functions

    /*
     * @return totalPooledWSX the amount of WSX that is owned by the contract
     */
    function _getTotalPooledWSX() internal view override returns (uint256) {
        return totalPooledWSX;
    }
    /*
     * @notice This function calculates the mint fee for a given amount a caller wishes to deposit.
     * @param amount The deposit amount to calculate a mint fee for
     * @return mintFeeAmount The total mint fee the caller will pay based on the amount
     */
    function calculateMintFee(uint amount) public view returns (uint) {
        uint mintFeeAmount = (amount * mintFee) / 10000;
        return mintFeeAmount;
    }

    /*
     * @notice This function calculates the reward fee for a given amount.
     * @param amount The reward amount to calculate a reward fee for
     * @return rewardFeeAmount The total reward fee based on the amount
     */
    function calculateRewardFee(uint amount) public view returns (uint) {
        uint rewardFeeAmount = (amount * rewardFee) / 10000;
        return rewardFeeAmount;
    }

    /*
     * @notice This function calculates the maximum tolerated slippage for a given amount.
     * @param amount The amount that will be converted before slippage
     * @return maxSlippageAmount The amount that will be converted after slippage
     */
    function calculateMaxSlippage(uint amount) public view returns (uint) {
        uint maxSlippageAmount = (amount * (10000 - maxSlippage)) / 10000;
        return maxSlippageAmount;
    }

    // Admin functions

    /*
     * @notice This function updates the mint fee.
     * @notice Only and Admin can update the mint fee.
     * @param newMintFee The new mintFee in bips 100 = 1%
     */
    function setMintFee(uint256 newMintFee) external onlyRole(ADMIN_ROLE) {
        mintFee = newMintFee;
    }

    /*
     * @notice This function updates the reward fee.
     * @notice Only and Admin can update the reward fee.
     * @param newRewardFee The new rewardFee in bips 100 = 1%
     */
    function setRewardFee(uint256 newRewardFee) external onlyRole(ADMIN_ROLE) {
        rewardFee = newRewardFee;
    }

    /*
     * @notice This function updates the maximum tolerated slippage.
     * @notice Only and Admin can update max slippage.
     * @param newMaxSlippage The new max slippage in bips 100 = 1%
     */
    function setMaxSlippage(
        uint256 newMaxSlippage
    ) external onlyRole(ADMIN_ROLE) {
        maxSlippage = newMaxSlippage;
    }

    /*
     * @notice This function updates the Staking Proxy address should it change in the future.
     * @notice Only an Admin can update the Staking Proxy address.
     * @param stakingProxyAddress The new Staking Proxy Address
     */
    function setStakingProxy(
        address stakingProxyAddress
    ) external onlyRole(ADMIN_ROLE) {
        require(stakingProxyAddress != address(0), "address must be non-0");
        _stakingProxy = IStakingProxy(stakingProxyAddress);
    }

    /*
     * @notice This function updates the Compound Stake Proxy Address should it change in the future.
     * @notice Only an Admin can update the Compound Stake Proxy Address.
     * @param stakingProxyAddress The new Compound Stake Proxy Address
     */
    function setCompoundStakeProxy(
        address compoundStakeProxyAddress
    ) external onlyRole(ADMIN_ROLE) {
        require(
            compoundStakeProxyAddress != address(0),
            "address must be non-0"
        );
        _compoundStakeProxy = ICompoundStakeProxy(compoundStakeProxyAddress);
    }

    /*
     * @notice This function updates the WSX Address should it change in the future.
     * @notice Only and Admin can update the WSX Address.
     * @param wsxAddress The new WSX Address
     */
    function setWSXToken(address wsxAddress) external onlyRole(ADMIN_ROLE) {
        require(wsxAddress != address(0), "address must be non-0");
        _wsxToken = IERC20(wsxAddress);
    }

    /*
     * @notice This function updates the DAO Address should it change in the future.
     * @notice Only an Admin can update the DAO Address.
     * @param daoAddress The new DAO Address
     */
    function setDAOAddress(address daoAddress) external onlyRole(ADMIN_ROLE) {
        require(daoAddress != address(0), "address must be non-0");
        DAO_ADDRESS = daoAddress;
    }

    /*
     * @notice This function updates the validator address should it change in the future.
     * @notice Only an Admin can update the validator address.
     * @param validatorAddress The new validator address
     */
    function setValidatorAddress(
        address validatorAddress
    ) external onlyRole(ADMIN_ROLE) {
        require(validatorAddress != address(0), "address must be non-0");
        VALIDATOR_ADDRESS = validatorAddress;
    }

    /*
     * @notice This function grants permission for an address to become an oracle.
     * @notice Only an Admin can add an oracle.
     * @param oracleAddress The new oracle address
     */
    function addOracle(address oracleAddress) external onlyRole(ADMIN_ROLE) {
        require(!hasRole(ORACLE_ROLE, oracleAddress), "Oracle already added.");

        _grantRole(ORACLE_ROLE, oracleAddress);
        numOracles++;

        emit OracleAdded(oracleAddress);
    }

    /*
     * @notice This function removes permission for an address that is an oracle.
     * @notice Only an Admin can remove an oracle.
     * @param oracleAddress The oracle address to remove permissions from
     */
    function removeOracle(address oracleAddress) external onlyRole(ADMIN_ROLE) {
        require(
            !hasRole(ORACLE_ROLE, oracleAddress),
            "Address is not a recognized oracle."
        );
        require(numOracles > 1, "Cannot remove the only oracle.");

        _revokeRole(ORACLE_ROLE, oracleAddress);
        numOracles--;

        emit OracleRemoved(oracleAddress);
    }

    /*
     * @notice This function grants permission for an address to become an admin.
     * @notice Only an Admin can add an admin.
     * @param oracleAddress The new oracle address
     */
    function addAdmin(address adminAddress) external onlyRole(ADMIN_ROLE) {
        require(!hasRole(ADMIN_ROLE, adminAddress), "Admin already added.");

        _grantRole(ADMIN_ROLE, adminAddress);

        emit AdminAdded(adminAddress);
    }

    /*
     * @notice This function removes permission for an address that is an admin.
     * @notice Only an Admin can remove an admin.
     * @param adminAddress The admin address to remove permissions from
     */
    function removeAdmin(address adminAddress) external onlyRole(ADMIN_ROLE) {
        require(
            !hasRole(ADMIN_ROLE, adminAddress),
            "Address is not a recognized admin."
        );

        _revokeRole(ADMIN_ROLE, adminAddress);

        emit AdminRemoved(adminAddress);
    }

    // called to report rewards value distributed
    event RewardsDistributed(
        uint256 timestamp,
        uint periodLength,
        uint256 rewardsAmount,
        uint256 totalWSXBeforeReward
    );
    // call to report fees collected for the DAO
    event FeesCollected(uint256 timestamp, uint256 feeAmount);
    // called when tokens are distributed
    event TokenRebased(
        uint256 indexed reportTimestamp,
        uint256 preTotalShares,
        uint256 preTotalEther,
        uint256 postTotalShares,
        uint256 postTotalEther,
        uint256 sharesMintedAsFees
    );
    // records a user deposit
    event Deposit(
        address indexed sender,
        uint256 amountDeposited,
        uint sharesIssued,
        uint stWSXReceived,
        uint mintFee
    );

    // admin function event reporting
    event MaxSlippageChanged(uint newMaxSlippage);
    event MintFeeChanged(uint newMintFee);
    event RewardFeeChanged(uint newRewardFee);
    event OracleAdded(address oracleAddress);
    event OracleRemoved(address oracleAddress);
    event AdminAdded(address adminAddress);
    event AdminRemoved(address adminAddress);
}
