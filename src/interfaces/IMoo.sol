// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

// This code is inspired by StakeTogether (https://github.com/staketogether/st-v1-contracts) project.

//  _______
// <  Moo  >
//  -------
//         \   ^__^
//          \  (oo)\_______
//             (__)\       )\/\
//                 ||----w |
//                 ||     ||

/// @title Moo Interface
/// @custom:security-contact security@usda.gov
interface IMoo {

   /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
   /*                          STRUCTS                           */
   /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

   struct Report {
      uint beaconBalance;
      uint atTime;
   }

   struct Validator {
      bool isActive;
      bytes publicKey;
      address owner;
      bytes signature;
      bytes32 depositDataRoot;
   }

   /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
   /*                           ERRORS                           */
   /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

   error Rentrancy();
   error ZeroAddress();
   error QuorumNotMet();
   error ValidatorExists();
   error DepositTooSmall();
   error InsufficientShares();
   error InsufficientAmount();
   error WithdrawalTooEarly();
   error NotValidator(address);
   error TransferUnsuccessful(address token, address from, address to, uint amount);


   /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
   /*                           EVENTS                           */
   /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

   event ETHReceived(address sender, uint amount);
   event Harvested(address owner, uint amount, bool moo);
   event HarvestPlanned(address owner, uint amount, bool moo);
   event ReportExecuted(Report report, int beaconBalanceChange);
   event Bred(address owner, uint amount, uint shares, bool moo);
   event Milked(address owner, uint amount, uint shares, bool moo);
   event VotedForReport(Report report, address validatorOracle, uint currentVotes);
   event TransferShares(address indexed from, address indexed to, uint256 sharesAmount);

   event AddValidator(
      address indexed oracle,
      bytes publicKey,
      bytes withdrawalCredentials,
      bytes signature,
      bytes32 depositDataRoot
   );


   /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
   /*                          FUNCTIONS                         */
   /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

   /// @notice Mints proper amount of mETHane based on ETH you send
   /// @param _amount Amount of ETH to breed your cattle (increase your position)
   function breed(uint _amount) external payable;

   /// @notice Signals user withdrawal intention.
   /// @dev Protects against rewards sandwitching.
   function signalMilk() external;

   /// @notice Exchanges mETH for proper amount of ETH if Moo has enough balance.
   ///         If not, user's due ETH is added to withdrawal mapping and can be harvested later.
   /// @param _amount Amount of mETH to exchange for ETH
   /// @param _exchangeToWETH Optionally wraps ETH to WETH for composability with other DeFi protocols.
   function milk(uint _amount, bool _exchangeToWETH) external;

   /// @notice Withdraws from the harvest pool and transfers the funds to the sender.
   /// @param _recipient Account to withdraw pending funds for.
   /// @param _amount The amount to withdraw.
   /// @param _exchangeToWETH Optionally wraps ETH to WETH for composability with other DeFi protocols.
   function harvest(address _recipient, uint _amount, bool _exchangeToWETH) external;

   /// @notice Returns the total supply of the pool (contract balance + beacon balance).
   /// @dev already defined in ERC20
   /// @return Total supply value.
   // function totalSupply() external view returns (uint256);

   /// @notice Calculates the shares amount by wei.
   /// @dev already defined in ERC20
   /// @param _account The address of the account.
   /// @return Balance value of the given account.
   // function balanceOf(address _account) external view returns (uint256);

   /// @notice Calculates the wei amount by shares.
   /// @param _sharesAmount Amount of shares.
   /// @return Equivalent amount in wei.
   function weiByShares(uint256 _sharesAmount) external view returns (uint256);

   /// @notice Calculates the shares amount by wei.
   /// @param _amount Amount in wei.
   /// @return Equivalent amount in shares.
   function sharesByWei(uint256 _amount) external view returns (uint256);

   /// @notice Transfers a number of shares to the specified address.
   /// @param _to The address to transfer to.
   /// @param _sharesAmount The number of shares to be transferred.
   /// @return Equivalent amount in wei.
   function transferShares(address _to, uint256 _sharesAmount) external returns (uint256);

   /// @notice Deposits to beacon chain staking contract from array of validator provided values.
   function registerValidatorToBeaconChain(bytes calldata _publicKey) external;

   /// @notice Creates a new pending validator with the given parameters.
   /// @param _publicKey The public key of the validator.
   /// @param _signature The signature of the validator.
   /// @param _depositDataRoot The deposit data root for the validator.
   /// @dev Only a valid validator oracle can call this function.
   function addNewValidatorData(
      bytes calldata _publicKey,
      bytes calldata _signature,
      bytes32 _depositDataRoot
   ) external;

   /// @notice Allows validator to vote on current proposal.
   /// @dev Requires the caller to be the validator.
   /// @param _report The amount of shares related to the staking rewards.
   function voteForReport(Report calldata _report) external;

   /// @notice Allows validator to vote on current proposal.
   /// @dev Requires the validators consensus to execute.
   /// @param _report The amount of shares related to the staking rewards.
   function executeReport(Report calldata _report) external;

   /// @notice Emits an event on native asset transfer.
   receive() external payable;
}
