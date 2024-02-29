// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts/utils/Multicall.sol';

import {IMoo} from "./interfaces/IMoo.sol";
import {IDepositContract} from "./interfaces/IDepositContract.sol";

// This code is inspired by StakeTogether (https://github.com/staketogether/st-v1-contracts) project.
// Please note that the code MOOST NOT be used live. It's created for educational purposees only.

//  ______
// < Moo! >
//  -----
//         \   ^__^
//          \  (oo)\_______
//             (__)\       )\/\
//                 ||----w |
//                 ||     ||


contract Moo is IMoo, ERC20, Multicall {
   uint reentrancyGuard = 1;

   mapping(bytes => Validator) pendingValidators;
   mapping(bytes => Validator) validators;
   mapping(address => bool) validatorOracles;
   mapping(address => bool) suspendedValidatorOracles;
   mapping(bytes32 => Report) reports;
   mapping(bytes32 => uint256) votes;

   address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // mainnet WETH
   IDepositContract beaconDepositContract = IDepositContract(0x00000000219ab540356cBB839Cbe05303d7705Fa); // mainnet ETH deposit contract

   uint256 public totalShares; /// Total number of shares.
   mapping(address => uint256) public shares; /// Mapping of addresses to their shares.
   mapping(address => uint256) public earliestWithdrawalPossible; /// Mapping of addresses to time at which they can withdraw.
   mapping(address => uint256) public pendingWithdrawals; /// Mapping of addresses to their pending withdrawals.

   bytes public withdrawalCredentials; /// Credentials for withdrawals.
   uint256 public beaconBalance; /// Beacon balance (includes transient Beacon balance on router).

   uint public MIN_REPORT_VOTING_QUORUM = 3; /// minimum quorum of oracles that agree on the beacon balance
   uint public minDeposit = 100000000000000; /// minimum deposit user can make. 1e15 wei
   uint public WITHDRAWAL_COOLDOWN = 24 * 60 * 60 * 1000; /// withdrawal cooldown in millis
   uint public DEPOSIT_AMOUNT = 32e18; /// Amount required to create new Ethereum validator

   modifier onlyValidatorOracle() {
      if (
         !(validatorOracles[msg.sender] || !suspendedValidatorOracles[msg.sender])
      ) {
         revert NotValidator(msg.sender);
      }

      _;
   }

   modifier nonReentrant() {
      unchecked {
         reentrancyGuard++;
      }

      if(reentrancyGuard == 3) {
         revert Rentrancy();
      }

      _;

      unchecked {
         reentrancyGuard--;
      }
   }
   
   /// @notice Makes sure that amount passed as parameter is not zero.
   ///         Used to protect against removing whole liquidity from
   ///         the protocol and perform empty pool attack in next transaction.
   modifier nonZero(uint amount) {
      _;

      amount > 0;
   }

   constructor() ERC20("mETHane", "mETH") {}

   /// @inheritdoc IMoo
   function breed(uint _amount) external payable override {
      // protect against first depositor issue and minting more than sent

      if (msg.value < minDeposit || msg.value < _amount) {
         revert DepositTooSmall();
      }

      uint sharesToMint = sharesByWei(_amount);

      _mintShares(msg.sender, sharesToMint);

      
      emit Bred(msg.sender, _amount, sharesToMint, true);
   }

   /// @inheritdoc IMoo
   function signalMilk() public {
      earliestWithdrawalPossible[msg.sender] = block.timestamp + WITHDRAWAL_COOLDOWN;

   }

   /// @inheritdoc IMoo
   function milk(uint _amount, bool _exchangeToWETH) external nonReentrant nonZero(totalSupply()) {

      uint sharesToBurn = weiByShares(_amount);

      
      if (earliestWithdrawalPossible[msg.sender] > block.timestamp) {
         revert WithdrawalTooEarly();
      }

      signalMilk();

      if (sharesToBurn > shares[msg.sender]) {
         revert InsufficientShares();
      }

      // Early return. User can use `harvest` to retrieve their balance whenever there will be enough funds.
      if (_amount >= address(this).balance) {
         pendingWithdrawals[msg.sender] = _amount;
         _burnShares(msg.sender, sharesToBurn);

         emit HarvestPlanned(msg.sender, _amount, false);
         return;
      }

      _burnShares(msg.sender, sharesToBurn);

      emit Milked(msg.sender, _amount, sharesToBurn, true);

      if (_exchangeToWETH) {
         _convertToWETH(sharesToBurn, msg.sender);
      } else {
         (bool success,) = payable(msg.sender).call{value: _amount}(""); 

         if(!success) {
            revert InsufficientAmount();
         }
      }
   }

   /// @inheritdoc IMoo
   function harvest(address _recipient, uint _amount, bool _exchangeToWETH) external nonReentrant {
      if (earliestWithdrawalPossible[_recipient] > block.timestamp) {
         revert WithdrawalTooEarly();
      }

      if (_amount > pendingWithdrawals[_recipient]) {
         revert InsufficientAmount();
      }

      // take whatever you can, if the balance is not enough
      _amount = _amount > address(this).balance ? address(this).balance : _amount;

      // No explicit protection against not enough balance, because both native and WETH transfer will fail in this case.
      if (_exchangeToWETH) {
         _convertToWETH(_amount, _recipient);
      } else {
         // use low level assembly to skip return memory copying
         assembly {
            let result := call(gas(), _recipient, _amount, 0, 0, 0, 0)

            switch result
            case 0 {
               // this is only occurence, we're ok with not using custom error here
               revert(0, 0)
            }
            default {

               // return no data
               return(0, 0)
            }
         }
      }

      pendingWithdrawals[_recipient] -= _amount;

      emit Harvested(msg.sender, _amount, true);
   }

   /// @inheritdoc IMoo
   function weiByShares(
      uint256 _sharesAmount
   ) public view override returns (uint256) {
      return Math.mulDiv(_sharesAmount, totalSupply(), totalShares);
   }

   /// @inheritdoc IMoo
   function sharesByWei(
      uint256 _amount
   ) public view override returns (uint256) {
      if (totalShares == 0) {
         // if it's first deposit, mint 1:1
         return _amount;
      }

      return Math.mulDiv(_amount, totalShares, totalSupply());
   }

   /// @notice converts ETH to WETH and sends it to receipient
   function _convertToWETH(uint _amount, address _recipient) internal {
      bytes memory calldataDeposit = abi.encodePacked(keccak256("deposit()"));

      bytes4 selectorTransfer = bytes4(keccak256("transfer(address,uint)"));
      bytes memory calldataTransfer = abi.encodeWithSelector(selectorTransfer, _recipient, _amount);

      (bool successDeposit,) = WETH.call{value: _amount}(calldataDeposit);

      (bool successTransfer, bytes memory returndataTransfer) = WETH.call(calldataTransfer);

      if (
         !successTransfer ||
         !successDeposit  ||
         (returndataTransfer.length != 0 && !abi.decode(returndataTransfer, (bool)))
      ) {
            revert TransferUnsuccessful(WETH, address(this), _recipient, _amount);
        }
   }

   /// @inheritdoc IMoo
   function transferShares(
      address _to,
      uint256 _sharesAmount
   ) external override returns (uint256) {
       _transferShares(msg.sender, _to, _sharesAmount);
       return weiByShares(_sharesAmount);
   }

  /// @notice Transfers an amount of wei from one address to another.
  /// @param _from The address to transfer from.
  /// @param _to The address to transfer to.
  /// @param _amount The amount to be transferred.
  function _update(address _from, address _to, uint256 _amount) internal override {
    uint256 _sharesToTransfer = sharesByWei(_amount);
    _transferShares(_from, _to, _sharesToTransfer);
    emit Transfer(_from, _to, _amount);
  }

  /// @notice Internal function to handle the transfer of shares.
  /// @param _from The address to transfer from.
  /// @param _to The address to transfer to.
  /// @param _sharesAmount The number of shares to be transferred.
  function _transferShares(
    address _from,
    address _to,
    uint256 _sharesAmount
  ) private {
    if (_from == address(0)) revert ZeroAddress();
    if (_to == address(0)) revert ZeroAddress();
    if (_sharesAmount > shares[_from]) revert InsufficientShares();
    shares[_from] -= _sharesAmount;
    shares[_to] += _sharesAmount;
    emit TransferShares(_from, _to, _sharesAmount);
  }

  /// @notice Internal function to mint shares to a given address.
  /// @param _to Address to mint shares to.
  /// @param _sharesAmount Amount of shares to mint.
  function _mintShares(address _to, uint256 _sharesAmount) private {
    if (_to == address(0)) revert ZeroAddress();
    shares[_to] += _sharesAmount;
    totalShares += _sharesAmount;
    emit TransferShares(address(0), _to, _sharesAmount);
  }

  /// @notice Internal function to burn shares from a given address.
  /// @param _account Address to burn shares from.
  /// @param _sharesAmount Amount of shares to burn.
  function _burnShares(address _account, uint256 _sharesAmount) private {
    if (_account == address(0)) revert ZeroAddress();
    if (_sharesAmount > shares[_account]) revert InsufficientShares();
    shares[_account] -= _sharesAmount;
    totalShares -= _sharesAmount;
    emit TransferShares(address(0), _account, _sharesAmount);
  }


  function totalSupply() public view override returns (uint256) {
    return address(this).balance + beaconBalance;
  }


   function balanceOf(
      address _account
   ) public view override returns (uint256) {
      return weiByShares(shares[_account]);
   }

   /// @inheritdoc IMoo
   function registerValidatorToBeaconChain(bytes calldata _publicKey) external {
      if (address(this).balance < DEPOSIT_AMOUNT) revert InsufficientAmount();
      if (!validators[_publicKey].isActive) revert ValidatorExists();

      Validator storage validator = pendingValidators[_publicKey];

      beaconBalance = beaconBalance + DEPOSIT_AMOUNT;

      beaconDepositContract.deposit{ value: DEPOSIT_AMOUNT }(
         validator.publicKey,
         withdrawalCredentials,
         validator.signature,
         validator.depositDataRoot
      );

      delete pendingValidators[_publicKey];

      validator.isActive = true;
      validators[_publicKey] = validator;
   }

   /// @inheritdoc IMoo
   function addNewValidatorData(
      bytes calldata _publicKey,
      bytes calldata _signature,
      bytes32 _depositDataRoot
   ) external override onlyValidatorOracle {
      pendingValidators[_publicKey] = Validator({
         isActive: false,
         publicKey: _publicKey,
         owner: msg.sender,
         signature: _signature,
         depositDataRoot: _depositDataRoot 
      });

      emit AddValidator(
         msg.sender,
         _publicKey,
         withdrawalCredentials,
         _signature,
         _depositDataRoot
      );
  }

   /// @inheritdoc IMoo
   function voteForReport(Report calldata _report) external onlyValidatorOracle {
      // because it's only param, it's ok to use msg.data
      bytes32 reportHash = keccak256(abi.encode(_report.beaconBalance, _report.atTime));
      
      reports[reportHash] = _report;
      votes[reportHash] += 1;

      emit VotedForReport(_report, msg.sender, votes[reportHash]);
   }

   /// @inheritdoc IMoo
   function executeReport(Report calldata _report) external onlyValidatorOracle {
      // because it's only param, it's ok to use msg.data
      bytes32 reportHash = keccak256(abi.encode(_report.beaconBalance, _report.atTime));

      uint256 votesFor = votes[reportHash];

      if (votesFor < MIN_REPORT_VOTING_QUORUM) {
         revert QuorumNotMet();
      }
      
      uint256 previousBeaconBalance = beaconBalance;
      int256 balanceChange = int256(previousBeaconBalance) - int256(_report.beaconBalance);

      beaconBalance = _report.beaconBalance;

      emit ReportExecuted(_report, balanceChange);
   }

   /// @inheritdoc IMoo
   receive() external payable override {
      emit ETHReceived(msg.sender, msg.value);
   }
}
