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
* @custom:dev-run-script scripts/deploy.ts
*/
contract StWSX is IStWSX, AccessControl, ReentrancyGuard {

    // testnet items
    // DAO: 0xB1cB92619902DA57b8f0f910AE553222DE9ACc56
    // VALIDATOR: 0x3e64F88C6C7a1310236B242180c0Ba1409d10F4d
    // WSX: 0x2D4e10Ee64CCF407C7F765B363348f7F62D2E06e
    // STAKING PROXY: 0xAEb6Cf65c48064aF0FA8554199CB8eAd499D92A5
    // COMPOUND STAKING PROXY: 0x0dD2c0b61C8a8FF8Fbf84a82a188B81247d5AdFe

    // ACL
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // other constants
    uint256 public constant MINIMUM_DEPOSIT_AMOUNT = 10**6;
    uint256 public constant DECIMAL_PRESCISION = 10000;

    // keeps track of the number of admins & oracle providers
    uint public numOracles;
    uint public numAdmins;

    // @dev the following can be updated by the DEFAULT_ADMIN_ROLE
    address private VALIDATOR_ADDRESS;
    IERC20 private _wsxToken;
    IStakingProxy private _stakingProxy;
    ICompoundStakeProxy private  _compoundStakeProxy;

    // TODO: our DAO protocol address here
    address public DAO_ADDRESS;

    // @dev protocol fees are represented as bips 100 = 1%
    uint public mintFee = 100;
    uint public rewardFee = 1000;

    // keeps track of total WSX in contract including reported rewards
    uint public totalPooledWSX;

    // waiting to be unstaked
    uint public waitingToUnstake;

    // amount that can be claimed
    uint public unstakedWSX;

    // accounting reports
    mapping(bytes32 => uint256) private _accountingReports;

    // pending unstake requests
    mapping(address => uint256) private _unstakeRequests;
    // pending unstake times
    mapping(address => uint256) private _latestUnstakeTime;
    // the last time that this contract has unstaked WSX
    uint256 public lastUnstakeTime;
    // last time of reported rewards
    uint256 public lastRewardsReport;

    constructor (address dao, address validator, address wsx, address stakingProxy, address compoundStakeProxy) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); // make the deployer admin
        numAdmins++;
        _grantRole(ORACLE_ROLE, msg.sender); // make the deployer provider temporarily as well
        numOracles++;

        // add our designated oracle
        _grantRole(ORACLE_ROLE, 0x872846e14F560FC899969942A00a7B0aC277726B);
        numOracles++;

        // This sets the initial share to WEI ratio that is also the denomination of wstWSX to stWSX
        _mintInitialShares(1);
        totalPooledWSX = 1;

        // HARD CODED ON DEPLOYMENT
        DAO_ADDRESS = dao;
        VALIDATOR_ADDRESS = validator;
        _wsxToken = IERC20(wsx);
        _stakingProxy = IStakingProxy(stakingProxy);
        _compoundStakeProxy = ICompoundStakeProxy(compoundStakeProxy);

        lastRewardsReport = block.timestamp;

    }

    function unstakeAvailableTimeOf(address adr) public view returns (uint){
        return (_latestUnstakeTime[adr] + (_stakingProxy._withdrawDelay() * 2));
    }

    function unstakeRequestTimeOf(address adr) public view returns (uint){
        return _latestUnstakeTime[adr];
    }

    function unstakeRequestAmountOf(address adr) public view returns (uint){
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
        // do not allow deposit less than minimum amount
        require(amount >= MINIMUM_DEPOSIT_AMOUNT, "Must deposit at least 100,000 WEI of WSX");

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

        emit Deposit(msg.sender, amount, sharesAmount, depositAmount, mintFeeAmount);
        emit FeesCollected(mintFeeAmount);

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
            block.timestamp > (_latestUnstakeTime[msg.sender] + (_stakingProxy._withdrawDelay() * 2)),
            "Insufficient time passed since unstake."
        );
        // confirm there is enough money in this contract
        require(unstakedWSX >= amount, "Not enough WSX to satisfy claim.");
        // confirm there is enough money in the WSX contract for this contract's balance
        require(_wsxToken.balanceOf(address(this)) >= amount, "Not enough WSX to satisfy claim.");

        // reset after claiming
        _unstakeRequests[msg.sender] = 0;
        unstakedWSX -= amount;

        // send WSX from this contract back to the user
        _wsxToken.transfer(msg.sender, amount);

        emit WithdrawalClaimed(msg.sender, amount);

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
        require(_unstakeRequests[msg.sender] == 0, "Already have one unstake in progress.");
        // must have enough stWSX balance to satisfy the unstake request
        require(_sharesOf(msg.sender) >= sharesToBurn, "Cannot unstake more than your stWSX balance.");

        // burn StWSX
        _burnShares(msg.sender, sharesToBurn);
        // remove from total pool
        totalPooledWSX -= wsxToUnstake;

        // user's unstaking time is stored to prevent multiple withdraws at once
        _latestUnstakeTime[msg.sender] = block.timestamp;

        // record how user wants to unstake
        _unstakeRequests[msg.sender] = wsxToUnstake;

        // update the aggregate amount to unstake across all users
        waitingToUnstake += wsxToUnstake;

        emit RequestUnstake(msg.sender, wsxToUnstake);

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
    * @notice Oracle function called regularly to unstake the funds requested by users
    * @dev This function can only initiate an unstake once every unstaking period.
    */
    function oracleUnstake() external onlyRole(ORACLE_ROLE) {
        // this function can only initiate an unstake once every staking period
        require(waitingToUnstake > 0, "No currency waiting to unstake");
        require(
            block.timestamp > (lastUnstakeTime + _stakingProxy._withdrawDelay()),
            "Insufficient time passed since last unstake"
        );

        lastUnstakeTime = block.timestamp;

        uint pendingWithdrawalAmount = _stakingProxy._pendingWithdrawAmounts(address(this));

        // claim any unstaked tokens that are avaiable
        if(pendingWithdrawalAmount > 0){
            _stakingProxy.withdrawUnstaked();
        }

        // initiate unstake for the next batch
        _stakingProxy.unstake(waitingToUnstake);

        emit OracleUnstaked(waitingToUnstake);

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
        uint pendingUnstakeAmount = _stakingProxy._pendingWithdrawAmounts(address(this));

        if(_stakingProxy._pendingWithdrawAmounts(address(this)) > 0){
            _stakingProxy.withdrawUnstaked();
        }

        uint withdrawnAmount = (pendingUnstakeAmount - _stakingProxy._pendingWithdrawAmounts(address(this)));

        emit OracleWithdrawUnstaked(withdrawnAmount);

        unstakedWSX += withdrawnAmount;

    }

    /*
    * @notice Claims the rewards that are waiting and payable to stWSX holders, it then updates the ledger based on collected rewards
    * @notice Oracle only calls once per day
    * @dev This function is called once per day to collect rewards and restake them through the CompoundStakeProxy
    * @param rewardTokenList The list of addresses that represent possible reward tokens
    * @param amountOutMins A list of minimum amounts during the conversion of the respective tokens in rewardTokenList
    */
    function oracleClaimRewards(address[] memory rewardTokenList, uint[] memory amountOutMins) external onlyRole(ORACLE_ROLE) {

        uint stakedAmountBefore = _stakingProxy.getStaker(address(this)).amount;

        // compound and autostake the WSX
        _compoundStakeProxy.harvestAndCompoundStake(rewardTokenList, amountOutMins);

        uint rewardAmount = _stakingProxy.getStaker(address(this)).amount - stakedAmountBefore;

         // get values before they are updated
        uint preShares = _getTotalShares();
        uint preWSX = _getTotalPooledWSX();

        // the time since the last report
        uint periodLength = block.timestamp - lastRewardsReport;

        lastRewardsReport = block.timestamp;

        // calculate the protocol reward fee
        uint rewardFeeAmount = calculateRewardFee(rewardAmount);

        // add the rewards net of fees to the pool
        totalPooledWSX += (rewardAmount - rewardFeeAmount);

        // put all WSX into pool since it's auto staked
        // mint shares to the DAO for the portion that is the fee
        uint rewardFeesShares = getSharesByPooledWSX(rewardFeeAmount);
        _mintShares(DAO_ADDRESS, rewardFeesShares);

        // add the reward fees WSX to the pool
        totalPooledWSX += rewardFeeAmount;

        emit OracleClaimedRewards(rewardAmount);
        emit RewardsDistributed(periodLength, rewardAmount, preWSX);
        emit FeesCollected(rewardFeeAmount);
        emit TokenRebased(block.timestamp, preShares, preWSX, _getTotalShares(), _getTotalPooledWSX(), rewardFeesShares);

    }

    // helper functions

    /*
    * @return totalPooledWSX the amount of WSX that is owned by the contract
    */
    function _getTotalPooledWSX() internal view override returns (uint256){
        return totalPooledWSX;
    }
    /*
    * @notice This function calculates the mint fee for a given amount a caller wishes to deposit.
    * @param amount The deposit amount to calculate a mint fee for
    * @return mintFeeAmount The total mint fee the caller will pay based on the amount
    */
    function calculateMintFee(uint amount) public view returns (uint){
        uint mintFeeAmount = amount * mintFee / DECIMAL_PRESCISION;
        return mintFeeAmount;
    }

    /*
    * @notice This function calculates the reward fee for a given amount.
    * @param amount The reward amount to calculate a reward fee for
    * @return rewardFeeAmount The total reward fee based on the amount
    */
    function calculateRewardFee(uint amount) public view returns (uint){
        uint rewardFeeAmount = amount * rewardFee / DECIMAL_PRESCISION;
        return rewardFeeAmount;
    }

    // Admin functions

    /*
    * @notice This function updates the mint fee.
    * @notice Only and Admin can update the mint fee.
    * @param newMintFee The new mintFee in bips 100 = 1%
    */
    function setMintFee(uint256 newMintFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newMintFee <= 3500, "Cannot be greater than 35%.");
        mintFee = newMintFee;
        emit MintFeeChanged(newMintFee);
    }

    /*
    * @notice This function updates the reward fee.
    * @notice Only and Admin can update the reward fee.
    * @param newRewardFee The new rewardFee in bips 100 = 1%
    */
    function setRewardFee(uint256 newRewardFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRewardFee <= 3500, "Cannot be greater than 35%.");
        rewardFee = newRewardFee;
        emit RewardFeeChanged(newRewardFee);
    }

    /*
    * @notice This function updates the DAO address should it change in the future.
    * @notice Only an Admin can update the DAO address.
    * @param daoAddress The new DAO address
    */
    function setDAOAddress(address daoAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(daoAddress != address(0), "address must be non-0");
        DAO_ADDRESS = daoAddress;
        emit DAOAddressChanged(daoAddress);
    }

    /*
    * @notice This function updates the CompoundStakeProxy address should it change in the future.
    * @notice Only an Admin can update the CompoundStakeProxy address.
    * @param compoundStakeProxyAddress The new CompoundStakeProxy address
    */
    function setCompoundStakeProxyAddress(address compoundStakeProxyAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(compoundStakeProxyAddress != address(0), "address must be non-0");
        _compoundStakeProxy = ICompoundStakeProxy(compoundStakeProxyAddress);
        emit CompoundStakeProxyAddressChanged(compoundStakeProxyAddress);
    }

    /*
    * @notice This function provides logic for granting of admin and oracle roles.
    * @notice Only an Admin can add a role to an account.
    * @param role The role to grant
    * @param account The new address to grant a role to
    */
    function grantRole(bytes32 role, address account) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        if(role == ORACLE_ROLE){
            require(!hasRole(ORACLE_ROLE, account), "Oracle role already added.");

            numOracles++;

            _grantRole(role, account);

            emit OracleAdded(account);
        }else if(role == DEFAULT_ADMIN_ROLE){
            require(!hasRole(DEFAULT_ADMIN_ROLE, account), "Admin role already added.");

            numAdmins++;

            _grantRole(role, account);

            emit AdminAdded(account);
        }else{
            _grantRole(role, account);
        }
    }

    /*
    * @notice This function provides logic for revoking of admin and oracle roles.
    * @notice Only an Admin can revoke a role to an account.
    * @param role The role to revoke
    * @param account The address to revoke a role from
    */
    function revokeRole(bytes32 role, address account) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        if(role == ORACLE_ROLE){
            require(hasRole(ORACLE_ROLE, account), "Address is not a recognized oracle.");
            require (numOracles > 1, "Cannot remove the only oracle.");

            _revokeRole(ORACLE_ROLE, account);
            numOracles--;

            emit OracleRemoved(account);
        }else if(role == DEFAULT_ADMIN_ROLE){
            require(hasRole(DEFAULT_ADMIN_ROLE, account), "Address is not a recognized admin.");
            require(msg.sender != account, "Admin cannot revoke its own role.");

            _revokeRole(DEFAULT_ADMIN_ROLE, account);
            numAdmins--;

            emit AdminRemoved(account);
        }else{
            _revokeRole(role, account);
        }
    }

    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (callerConfirmation != msg.sender) {
            revert AccessControlBadConfirmation();
        }

        if(role == ORACLE_ROLE){
            require(hasRole(ORACLE_ROLE, callerConfirmation), "Address is not a recognized oracle.");
            require (numOracles > 1, "Cannot remove the only oracle.");

            _revokeRole(ORACLE_ROLE, callerConfirmation);
            numOracles--;

            emit OracleRemoved(callerConfirmation);
        }else if(role == DEFAULT_ADMIN_ROLE){
            require(hasRole(DEFAULT_ADMIN_ROLE, callerConfirmation), "Address is not a recognized admin.");
            require (numAdmins > 1, "Cannot remove the only admin.");

            _revokeRole(DEFAULT_ADMIN_ROLE, callerConfirmation);
            numAdmins--;

            emit AdminRemoved(callerConfirmation);
        }else{
            _revokeRole(role, callerConfirmation);
        }
    }

    // called to report rewards value distributed
    event RewardsDistributed(uint periodLength, uint rewardsAmount, uint totalWSXBeforeReward);
    // call to report fees collected for the DAO
    event FeesCollected(uint feeAmount);
    // called when tokens are distributed
    event TokenRebased(
        uint indexed date,
        uint preTotalShares,
        uint preTotalEther,
        uint postTotalShares,
        uint postTotalEther,
        uint sharesMintedAsFees
    );
    // records a user deposit
    event Deposit(address indexed sender, uint amountDeposited, uint sharesIssued, uint stWSXReceived, uint mintFee);
    // user requests unstake
    event RequestUnstake(address sender, uint amount);
    // user claims tokens
    event WithdrawalClaimed(address sender, uint amount);
    // oracle has initiated unstake
    event OracleUnstaked(uint unstakedAmount);
    // oracle has withdrawn unstaked tokens
    event OracleWithdrawUnstaked(uint withdrawnAmount);
    // oracle has claimed rewards
    event OracleClaimedRewards(uint claimedRewards);

    // admin function event reporting
    event MintFeeChanged(uint newMintFee);
    event RewardFeeChanged(uint newRewardFee);
    event OracleAdded(address oracleAddress);
    event OracleRemoved(address oracleAddress);
    event AdminAdded(address adminAddress);
    event AdminRemoved(address adminAddress);
    event DAOAddressChanged(address daoAddress);
    event CompoundStakeProxyAddressChanged(address compoundStakeProxyAddress);

}
