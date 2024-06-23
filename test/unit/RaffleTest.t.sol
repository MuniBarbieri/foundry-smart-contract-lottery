// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {Raffle} from "../../src/Raffle.sol";
import  {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";


contract RaffleTest is Test {
    // Events
    event EnteredRaffle(address indexed player);

    Raffle raffle;
    HelperConfig helperConfig;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint64 subscriptionId;
    uint32 callbackGasLimit;
    address link;
    uint256 deployerKey;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
         (raffle, helperConfig) = deployer.run();
        (
            entranceFee,
            interval,
            vrfCoordinator,
            gasLane,
            subscriptionId,
            callbackGasLimit,
            link,
            deployerKey
        ) = helperConfig.activeNetworkConfig();
        vm.deal(PLAYER, STARTING_USER_BALANCE);
    }

    function testRaffleInitializesInOpenState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    function testRaffleRevertsWhenYouDontPayEnough() public {
            vm.prank(PLAYER);
            vm.expectRevert(Raffle.Raffle__NotEnoughEth.selector);
            raffle.enterRaffle();
    }

    function testRaffleRecordsPlayWhenTheyEnter() public {
        // Arrange
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        address player = raffle.getPlayer(0);
        assert(player == PLAYER);
    }

//    modifier userEntersRaffle() {
//        vm.prank(PLAYER);
//        raffle.enterRaffle{value:entranceFee}();
//    }

    function testEmitsEventOnEntrance () public {
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, false, address(raffle));
        emit EnteredRaffle(PLAYER);
        raffle.enterRaffle{value:entranceFee}();
    }

    function testCantEnterWhenRaffleIsCalculating () public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp  + interval + 1);
        vm.roll(block.number + 1);
        raffle.performUpkeep("");

        vm.expectRevert(Raffle.Raffle__RaffleNotOpen.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    function testCheckUpkeepReturnsFalseIfItHasNoBalance () public {
        //Arrange
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        //act
        (bool upKeepNeeded, ) = raffle.checkUpkeep("");

        //Assert
        assert(!upKeepNeeded);
    }

    function testCheckUpkeepReturnsFalseIfRaffleNotOpen() public {
        //Arrange
        vm.prank(PLAYER);
        raffle.enterRaffle{value:entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        raffle.performUpkeep("");

        //Act
        (bool upkeepNeeded, ) = raffle.checkUpkeep("");
        //Assert
        assert(!upkeepNeeded);
    }

    function testPerformUpkeepCanOnlyRunIfCheckUpkeepReturnsTrue() public {
        //Arrange
        vm.prank(PLAYER);
        raffle.enterRaffle{value:entranceFee}();
        vm.warp(block.timestamp + interval +1);
        vm.roll(block.number + 1);

        //ACT / Assert
        (bool upKeepNeeded, ) = raffle.checkUpkeep("");
    }

    function testPerformUpKeepRevertsIfCheckUpkeepReturnsFalse() public {
        vm.expectRevert(abi.encodeWithSelector(Raffle.Raffle_UpkeepNotNeeded.selector,0,0,0)); //next line will revert
        raffle.performUpkeep("");
    }

    modifier raffleEnteredAndTimePassed(){
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    function testPerformUpkeepUpdatesRaffleStateAndEmitsRequestId ()
        public
        raffleEnteredAndTimePassed
    {
        //ACT
        vm.recordLogs();
        raffle.performUpkeep("");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        //0x00000000000001
        bytes32 requestId = entries[1].topics[1];

        Raffle.RaffleState state = raffle.getRaffleState();

        assert(uint256(state) == 1); // 1 is CALCULATING
        assert(uint256(requestId) > 0);
        assertEq(entries.length, 2);
        // signature of the event
        assertEq(entries[1].topics[0], keccak256("RequestedRaffleWinner(uint256)"));
        assertEq(entries[1].topics[1], requestId);
    }

    modifier skipFork() {
        if(block.chainid != 31337 ){
            return;
        }
        _;
    }

    // FUZZING TEST
    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep(uint256 randomRequestedId)
        public
        raffleEnteredAndTimePassed
        skipFork
    {
        //Arrange
        vm.expectRevert("nonexistent request");
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(randomRequestedId,address(raffle));
    }

    function testFulfillRandomWordsPickAWinnerResetAndSendsMoney() public raffleEnteredAndTimePassed skipFork {
        //Arrange
        uint256 additionalEntrants = 5;
        uint256 startingIndex = 1;

        for(uint256 i = startingIndex; i < startingIndex + additionalEntrants; i++){
            address player = address(uint160(i));
            hoax(player, STARTING_USER_BALANCE); // prank + deal
            raffle.enterRaffle{value: entranceFee}();
        }

        uint256 prize = entranceFee * (additionalEntrants + 1);

        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        uint256 previousTimeStamp = raffle.getLastTimeStamp();

        // pretend to be chainlink vrf to get random number and pick winner
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId),address(raffle));

        // Asserts
        assert(uint256(raffle.getRaffleState())==0);
        assert(raffle.getRecentWinner()!= address(0));
        assert(raffle.getLengthOfPlayers() == 0);
        assert(previousTimeStamp < raffle.getLastTimeStamp());
        assert(raffle.getRecentWinner().balance == STARTING_USER_BALANCE + prize - entranceFee);
    }

}