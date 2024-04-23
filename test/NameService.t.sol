// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NameService} from "../src/NameService.sol";

contract NameServiceTest is Test {
    NameService public nameService;
    uint256 constant TEST_TIME = 1713867950;
    address testUser = makeAddr("user");
    address testUser2 = makeAddr("user2");

    uint256 constant PRICE_PER_CHAR = 0.001 ether;
    uint256 constant MIN_CHAR_ON_NAME = 3;
    uint256 constant MAX_CHAR_ON_NAME = 10;
    uint256 constant NAME_LOCK_TIME = 10 weeks;
    uint256 constant TIME_TO_COMPLETE_REGISTRATION = 10 minutes;
    uint256 constant TIME_TO_REGISTER_NAME = 5 minutes;

    function setUp() public {
        nameService = new NameService();
        vm.warp(TEST_TIME);
        vm.deal(testUser, 10 ether);
        vm.deal(testUser2, 10 ether);
    }

    function test_Registration() public {
        string memory name = "test";
        uint256 salt = 123;
        bytes32 nameHash = keccak256(abi.encode(name, salt));
        uint256 cost = bytes(name).length * PRICE_PER_CHAR;

        vm.startPrank(testUser);
        nameService.reserveName(nameHash);
        skip(TIME_TO_REGISTER_NAME);
        uint256 registerTime = block.timestamp;
        nameService.registerName{value: cost}(nameHash, name, salt);
        vm.stopPrank();
        nameHash = keccak256(abi.encode(name));
        (address owner, uint64 expirationTime) = nameService.registeredNames(nameHash);
        assertEq(owner, testUser);
        assertEq(expirationTime, registerTime + NAME_LOCK_TIME);
    }

    function test_Renewal() public {
        test_Registration();
        uint256 newTime = TEST_TIME + 1 weeks;
        string memory name = "test";
        bytes32 nameHash = keccak256(abi.encode(name));
        vm.warp(newTime);
        vm.prank(testUser);
        nameService.renewRegistration(name);

        (address owner, uint64 expirationTime) = nameService.registeredNames(nameHash);
        assertEq(owner, testUser);
        assertEq(expirationTime, newTime + NAME_LOCK_TIME);
    }

    function test_Recover() public {
        test_Registration();
        string memory name = "test";
        bytes32 nameHash = keccak256(abi.encode(name));
        uint256 cost = bytes(name).length * PRICE_PER_CHAR;
        uint256 balanceBefore = testUser.balance;
        vm.prank(testUser);
        nameService.deleteRegistration(name);

        uint256 balanceAfter = testUser.balance;
        (address owner, uint64 expirationTime) = nameService.registeredNames(nameHash);
        assertEq(balanceAfter - balanceBefore, cost);
        assertEq(owner, address(0));
        assertEq(expirationTime, 0);
    }

    function test_UserCanGetNameAfterExpiration() public {
        test_Registration();
        uint256 newTime = TEST_TIME + NAME_LOCK_TIME + 1;
        vm.warp(newTime);

        string memory name = "test";

        uint256 cost = bytes(name).length * PRICE_PER_CHAR;
        uint256 salt = 1234;
        bytes32 nameHash = keccak256(abi.encode(name, salt));
        vm.startPrank(testUser2);
        nameService.reserveName(nameHash);
        skip(TIME_TO_REGISTER_NAME);
        uint256 registerTime = block.timestamp;
        nameService.registerName{value: cost}(nameHash, name, salt);
        vm.stopPrank();

        nameHash = keccak256(abi.encode(name));
        (address owner, uint64 expirationTime) = nameService.registeredNames(nameHash);
        assertEq(owner, testUser2);
        assertEq(expirationTime, registerTime + NAME_LOCK_TIME);
    }

    function test_UserCanRecoverBalanceAfterNameIsRegisteredByAnotherUser() public {
        test_UserCanGetNameAfterExpiration();
        string memory name = "test";

        uint256 cost = bytes(name).length * PRICE_PER_CHAR;
        uint256 balanceBefore = testUser.balance;
        vm.prank(testUser);
        nameService.recoverBalance();
        uint256 balanceAfter = testUser.balance;
        assertEq(balanceAfter - balanceBefore, cost);
    }

    function test_UserCannotCompleteRegistrationUntilTime() public {
        string memory name = "test";
        uint256 salt = 123;
        bytes32 nameHash = keccak256(abi.encode(name, salt));
        uint256 cost = bytes(name).length * PRICE_PER_CHAR;

        vm.startPrank(testUser);
        nameService.reserveName(nameHash);
        vm.expectRevert(NameService.NameService__InvalidReservation.selector);
        nameService.registerName{value: cost}(nameHash, name, salt);
        vm.stopPrank();
    }

    function test_UserCannotCompleteRegistrationIfOverTime() public {
        string memory name = "test";
        uint256 salt = 123;
        bytes32 nameHash = keccak256(abi.encode(name, salt));
        uint256 cost = bytes(name).length * PRICE_PER_CHAR;

        vm.startPrank(testUser);
        nameService.reserveName(nameHash);
        skip(TIME_TO_COMPLETE_REGISTRATION + 1);
        vm.expectRevert(NameService.NameService__InvalidReservation.selector);
        nameService.registerName{value: cost}(nameHash, name, salt);
        vm.stopPrank();
    }

    function test_UserCannotRegisterNameWithOwner() public {
        test_Registration();
        string memory name = "test";
        uint256 salt = 1234;
        bytes32 nameHash = keccak256(abi.encode(name, salt));
        uint256 cost = bytes(name).length * PRICE_PER_CHAR;
        vm.startPrank(testUser2);
        nameService.reserveName(nameHash);
        skip(TIME_TO_REGISTER_NAME);
        vm.expectRevert(NameService.NameService__NameAlreadyRegistered.selector);
        nameService.registerName{value: cost}(nameHash, name, salt);
        vm.stopPrank();
    }

    function test_UserMustSendCorrectValueForNameRegister() public {
        string memory name = "test";
        uint256 salt = 123;
        bytes32 nameHash = keccak256(abi.encode(name, salt));
        uint256 cost = bytes(name).length * PRICE_PER_CHAR;

        vm.startPrank(testUser);
        nameService.reserveName(nameHash);
        skip(TIME_TO_REGISTER_NAME);
        vm.expectRevert(abi.encodeWithSelector(NameService.NameService__InvalidValue.selector, cost, 0));
        nameService.registerName{value: 0}(nameHash, name, salt);

        vm.expectRevert(abi.encodeWithSelector(NameService.NameService__InvalidValue.selector, cost, 1 ether));
        nameService.registerName{value: 1 ether}(nameHash, name, salt);
    }

    function test_UserCannotRegisterNameWithLengthBelowMin() public {
        string memory name = "te";
        uint256 salt = 1234;
        bytes32 nameHash = keccak256(abi.encode(name, salt));
        uint256 cost = bytes(name).length * PRICE_PER_CHAR;
        vm.startPrank(testUser2);
        nameService.reserveName(nameHash);
        skip(TIME_TO_REGISTER_NAME);
        vm.expectRevert(abi.encodeWithSelector(NameService.NameService__InvalidLength.selector, 2));
        nameService.registerName{value: cost}(nameHash, name, salt);
    }

    function test_UserCannotRegisterNameWithLengthAboveMax() public {
        string memory name = "teeeeeeeest";
        uint256 salt = 1234;
        bytes32 nameHash = keccak256(abi.encode(name, salt));
        uint256 cost = bytes(name).length * PRICE_PER_CHAR;
        vm.startPrank(testUser2);
        nameService.reserveName(nameHash);
        skip(TIME_TO_REGISTER_NAME);
        vm.expectRevert(abi.encodeWithSelector(NameService.NameService__InvalidLength.selector, 11));
        nameService.registerName{value: cost}(nameHash, name, salt);
    }

    function test_LongerNameShouldCostMore() public {
        string memory name1 = "test";
        uint256 salt1 = 123;
        bytes32 nameHash = keccak256(abi.encode(name1, salt1));
        uint256 cost1 = bytes(name1).length * PRICE_PER_CHAR;

        vm.startPrank(testUser);
        nameService.reserveName(nameHash);
        skip(TIME_TO_REGISTER_NAME);

        nameService.registerName{value: cost1}(nameHash, name1, salt1);
        vm.stopPrank();

        string memory name2 = "test123";
        uint256 salt2 = 123;
        bytes32 nameHash2 = keccak256(abi.encode(name2, salt2));
        uint256 cost2 = bytes(name2).length * PRICE_PER_CHAR;
        vm.startPrank(testUser2);
        nameService.reserveName(nameHash2);
        skip(TIME_TO_REGISTER_NAME);

        nameService.registerName{value: cost2}(nameHash2, name2, salt2);
        vm.stopPrank();

        assertGt(cost2, cost1);
    }

    function test_InvalidHashShouldFailRegistration() public {
        string memory name = "test";
        uint256 salt = 123;
        bytes32 nameHash = keccak256(abi.encode(name, salt));
        uint256 cost = bytes(name).length * PRICE_PER_CHAR;

        vm.startPrank(testUser);
        nameService.reserveName(nameHash);
        skip(TIME_TO_REGISTER_NAME);
        string memory nameGuess = "random";
        uint256 saltGuess = 11;
        bytes32 guessHash = keccak256(abi.encode(nameGuess, saltGuess));
        skip(TIME_TO_REGISTER_NAME);
        vm.expectRevert(abi.encodeWithSelector(NameService.NameService__InvalidHash.selector, nameHash, guessHash));
        nameService.registerName{value: cost}(nameHash, nameGuess, saltGuess);
    }

    function test_CannotOverWriteReservationUntilTimeExpired() public {
        string memory name = "test";
        uint256 salt = 123;
        bytes32 nameHash = keccak256(abi.encode(name, salt));
        vm.prank(testUser);
        nameService.reserveName(nameHash);
        vm.prank(testUser2);
        vm.expectRevert(NameService.NameService__HashAlreadyReserved.selector);
        nameService.reserveName(nameHash);

        vm.prank(testUser2);
        vm.expectRevert(NameService.NameService__InvalidReservation.selector);
        nameService.registerName(nameHash, name, salt);

        skip(TIME_TO_COMPLETE_REGISTRATION + 1);
        vm.prank(testUser2);
        nameService.reserveName(nameHash);
    }

    function test_NonOwnerCannotExtendTime() public {
        test_Registration();
        vm.prank(testUser2);
        vm.expectRevert(abi.encodeWithSelector(NameService.NameService__NotNameOwner.selector, testUser, testUser2));
        nameService.renewRegistration("test");
    }

    function test_NonOwnerCannotDelteRegistration() public {
        test_Registration();
        vm.prank(testUser2);
        vm.expectRevert(abi.encodeWithSelector(NameService.NameService__NotNameOwner.selector, testUser, testUser2));
        nameService.deleteRegistration("test");
    }
}
