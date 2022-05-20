// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import './interfaces/IAthanasiaOtc.sol';
import './interfaces/IStakingHelper.sol';
import './interfaces/ITreasury.sol';

contract AthanasiaOtc is IAthanasiaOtc, Ownable, Pausable {
    using SafeERC20 for IERC20;

    uint256 constant PRICE_MULTIPLIER = 10**9;

    IERC20 public immutable HEC;
    IERC20 public immutable sHEC;
    IStakingHelper public immutable stakingHelper;
    ITreasury public immutable treasury;

    mapping(address => TokenInfo) public collections;
    mapping(address => mapping(address => bool)) public whitelist;
    mapping(address => mapping(address => uint256))
        public userPurchasedForCollection;

    /* ======= CONSTRUCTOR ======= */

    constructor(
        address _HEC,
        address _sHEC,
        address _stakingHelper,
        address _treasury
    ) {
        require(_HEC != address(0), 'OTC: Invalid HEC');
        require(_sHEC != address(0), 'OTC: Invalid sHEC');
        require(_stakingHelper != address(0), 'OTC: Invalid staking helper');
        require(_treasury != address(0), 'OTC: Invalid treasury');

        HEC = IERC20(_HEC);
        sHEC = IERC20(_sHEC);
        stakingHelper = IStakingHelper(_stakingHelper);
        treasury = ITreasury(_treasury);
    }

    /* ======= MODIFIER ======= */

    modifier onlyExistingCollection(address collection) {
        require(
            collections[collection].totalAmount > 0,
            'OTC: Unregistered collection'
        );
        _;
    }

    modifier onlyWhitelisted(address collection, address sender) {
        require(whitelist[collection][sender], 'OTC: Not whitelisted sender');
        _;
    }

    ///////////////////////////////////////////////////////
    //               MANAGER CALLED FUNCTIONS            //
    ///////////////////////////////////////////////////////

    function registerCollection(
        address collection,
        address otcToken,
        uint256 otcPrice,
        uint256 totalAmount
    ) external override onlyOwner whenNotPaused {
        require(collection != address(0), 'OTC: Invalid collection');
        require(otcPrice > 0, 'OTC: Invalid otc price');
        require(totalAmount > 0, 'OTC: Invalid total amount');

        TokenInfo storage info = collections[collection];

        require(info.purchasedAmount == 0, 'OTC: Already purchased collection');

        info.otcToken = otcToken;
        info.otcPrice = otcPrice;
        info.totalAmount = totalAmount;
    }

    function addWhitelist(address collection, address[] memory senders)
        external
        onlyOwner
        whenNotPaused
        onlyExistingCollection(collection)
    {
        uint256 length = senders.length;

        for (uint256 i = 0; i < length; i++) {
            address sender = senders[i];

            if (!whitelist[collection][sender]) {
                whitelist[collection][sender] = true;
            }
        }
    }

    function removeWhitelist(address collection, address[] memory senders)
        external
        onlyOwner
        whenNotPaused
        onlyExistingCollection(collection)
    {
        uint256 length = senders.length;

        for (uint256 i = 0; i < length; i++) {
            address sender = senders[i];

            if (whitelist[collection][sender]) {
                whitelist[collection][sender] = false;
            }
        }
    }

    function withdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner whenNotPaused {
        require(to != address(0), 'OTC: Invalid to');
        require(amount > 0, 'OTC: Invalid amount');

        if (token == address(0)) {
            (bool success, ) = payable(to).call{value: amount}('');
            require(success, 'OTC: ETH withdraw failed');
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function pause() external onlyOwner whenNotPaused {
        return _pause();
    }

    function unpause() external onlyOwner whenPaused {
        return _unpause();
    }

    ///////////////////////////////////////////////////////
    //                  VIEW FUNCTIONS                   //
    ///////////////////////////////////////////////////////

    function validateCollection(
        address collection,
        address otcToken,
        uint256 otcPrice
    ) external view override returns (bool) {
        TokenInfo memory info = collections[collection];

        return info.otcToken == otcToken && info.otcPrice == otcPrice;
    }

    ///////////////////////////////////////////////////////
    //               USER CALLED FUNCTIONS               //
    ///////////////////////////////////////////////////////

    function otc(
        address collection,
        uint256 amountToPurchase,
        uint256 expectedCost
    )
        external
        payable
        override
        whenNotPaused
        onlyExistingCollection(collection)
        onlyWhitelisted(collection, msg.sender)
    {
        TokenInfo memory info = collections[collection];
        uint256 cost = (amountToPurchase * info.otcPrice) / PRICE_MULTIPLIER;

        require(cost == expectedCost, 'OTC: Mismatch to the expected cost');
        require(
            info.purchasedAmount + amountToPurchase <= info.totalAmount,
            'OTC: Exceed total amount'
        );

        if (info.otcToken == address(0)) {
            require(msg.value == cost, 'OTC: Mismatch to the ETH value');
        } else {
            IERC20(info.otcToken).safeTransferFrom(
                msg.sender,
                address(this),
                cost
            );
        }

        // Update purchased amount
        info.purchasedAmount += amountToPurchase;

        // Mint HEC
        treasury.mintRewards(address(this), amountToPurchase);

        // Stake HEC and Transfer sHEC to user
        HEC.approve(address(stakingHelper), amountToPurchase);
        stakingHelper.stake(amountToPurchase, msg.sender);

        userPurchasedForCollection[collection][msg.sender] += amountToPurchase;
    }
}
