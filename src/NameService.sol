// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

/**
 * @title Simple Name Service
 * @author FranciSco Figueira
 */
contract NameService {
    uint256 constant PRICE_PER_CHAR = 0.001 ether;

    uint256 constant MIN_CHAR_ON_NAME = 3;
    uint256 constant MAX_CHAR_ON_NAME = 10;

    uint256 constant NAME_LOCK_TIME = 10 weeks;
    uint256 constant TIME_TO_COMPLETE_REGISTRATION = 10 minutes;
    uint256 constant TIME_TO_REGISTER_NAME = 5 minutes;

    modifier nonreentrant() {
        assembly {
            if tload(0) { revert(0, 0) }
            tstore(0, 1)
        }
        _;
        assembly {
            tstore(0, 0)
        }
    }

    struct Reservation {
        address user;
        uint64 reservationTime;
    }

    struct NameRegister {
        address owner;
        uint64 expirationTime;
    }

    /**
     * @notice Hash of name +salt that are reserved to finalize registration, the key is given by keccak256(abi.encode(name, salt)).
     */
    mapping(bytes32 => Reservation) public reservations;
    /**
     * @notice Record of registered names, their owner and expiration time. The key is given by keccak256(abi.encode(name)).
     */
    mapping(bytes32 => NameRegister) public registeredNames;
    /**
     * @notice After a name is expired, a new user can register it, and free up the locked balance of the previous user, this mapping
     * keeps track of the freed balances of each user.
     */
    mapping(address => uint256) public balanceToRecover;

    error NameService__InvalidValue(uint256 want, uint256 have);
    error NameService__InvalidLength(uint256 have);
    error NameService__NameAlreadyRegistered();
    error NameService__HashAlreadyReserved();
    error NameService__InvalidReservation();
    error NameService__TransferFailed();
    error NameService__InvalidHash(bytes32 want, bytes32 have);
    error NameService__NotNameOwner(address want, address have);

    event nameReserved(bytes32 nameHash, address indexed user, uint256 expirationTime);
    event nameRegistered(string name, address indexed user, uint256 expirationTime);
    event nameRegistrationTaken(string name, address indexed user);
    event nameRegistrationRenwed(string name, address indexed user, uint256 newExpirationTime);
    event nameRegistrationDeleted(string name);

    /**
     * @dev Function to place a reservation on the desired name, the name registration can be finalized by calling registerName
     * after TIME_TO_REGISTER_NAME has passed, and is reserved up to TIME_TO_COMPLETE_REGISTRATION.
     * @param nameHash  the hash of the name together with a random salt in the form keccak256(abi.encode(name, salt))
     */
    function reserveName(bytes32 nameHash) public {
        uint256 reservationTime = reservations[nameHash].reservationTime;
        if (reservationTime + TIME_TO_COMPLETE_REGISTRATION > block.timestamp) {
            revert NameService__HashAlreadyReserved();
        }
        reservations[nameHash] = Reservation(msg.sender, uint64(block.timestamp));
        emit nameReserved(nameHash, msg.sender, block.timestamp + TIME_TO_COMPLETE_REGISTRATION);
    }

    /**
     * @dev Function to finalize name registration, the value sent must be equal to the name length times PRICE_PER_BYTE.
     * If the name is already registered and not expired the function will revert, if it's registered but expired the ownership of the name will be transferred
     * and the previous owner will be able to withdraw the balance.
     * If a malicious user tries to front run name after the tx to register is in mempool and the name is visible, they will need to call reserveName first which will,
     * make them wait for TIME_TO_COMPLETE_REGISTRATION until they can call this function, which should allow the original user to have the transaction inserted in a block before that happens.
     * These parameters can be adjusted as necessary depending on the deployment chain characteristics.
     * @param nameHash nameHash used in reserveName function
     * @param name name that user wishes to register
     * @param salt salt used to create the nameHash
     */
    function registerName(bytes32 nameHash, string calldata name, uint256 salt) public payable {
        if (bytes(name).length > MAX_CHAR_ON_NAME || bytes(name).length < MIN_CHAR_ON_NAME) {
            revert NameService__InvalidLength(bytes(name).length);
        }
        Reservation memory reservation = reservations[nameHash];
        if (
            msg.sender != reservation.user
                || block.timestamp > uint256(reservation.reservationTime) + TIME_TO_COMPLETE_REGISTRATION
                || block.timestamp < uint256(reservation.reservationTime) + TIME_TO_REGISTER_NAME
        ) {
            revert NameService__InvalidReservation();
        }

        bytes32 computedHash = keccak256(abi.encode(name, salt));
        if (computedHash != nameHash) {
            revert NameService__InvalidHash(nameHash, computedHash);
        }

        bytes32 registrationHash = keccak256(abi.encode(name));
        NameRegister memory register = registeredNames[registrationHash];
        uint256 cost = bytes(name).length * PRICE_PER_CHAR;

        if (register.expirationTime > block.timestamp) {
            revert NameService__NameAlreadyRegistered();
        }
        if (register.owner != address(0)) {
            emit nameRegistrationTaken(name, register.owner);
            balanceToRecover[register.owner] += cost;
        }

        if (msg.value != cost) {
            revert NameService__InvalidValue(cost, msg.value);
        }
        registeredNames[registrationHash] = NameRegister(msg.sender, uint64(block.timestamp + NAME_LOCK_TIME));
        emit nameRegistered(name, msg.sender, block.timestamp + NAME_LOCK_TIME);
    }

    /**
     * @dev Function allows user to renew onwership of a given name, the caller must be the owner of the name
     * @param name name to renew
     */
    function renewRegistration(string calldata name) external {
        bytes32 registrationHash = keccak256(abi.encode(name));
        NameRegister storage register = registeredNames[registrationHash];
        if (msg.sender != register.owner) {
            revert NameService__NotNameOwner(register.owner, msg.sender);
        }
        register.expirationTime = uint64(block.timestamp + NAME_LOCK_TIME);
        emit nameRegistrationRenwed(name, msg.sender, block.timestamp + NAME_LOCK_TIME);
    }

    /**
     * @dev Function allows user to give up ownership of a name and retireve the funds that were locked when the name was registered.
     * The caller must be the owner of the name.
     * @param name name to give up
     */
    function deleteRegistration(string calldata name) external nonreentrant {
        bytes32 registrationHash = keccak256(abi.encode(name));
        NameRegister storage register = registeredNames[registrationHash];
        if (msg.sender != register.owner) {
            revert NameService__NotNameOwner(register.owner, msg.sender);
        }
        delete(registeredNames[registrationHash]);
        uint256 feePaid = bytes(name).length * PRICE_PER_CHAR;
        (bool success,) = payable(msg.sender).call{value: feePaid}("");
        if (!success) {
            revert NameService__TransferFailed();
        }
        emit nameRegistrationDeleted(name);
    }

    /**
     * @dev Allows a user to recover any balance that was used to registered names that were expired and registered by new users.
     */
    function recoverBalance() external nonreentrant {
        uint256 userBalance = balanceToRecover[msg.sender];
        if (userBalance != 0) {
            delete(balanceToRecover[msg.sender]);
            (bool success,) = payable(msg.sender).call{value: userBalance}("");
            if (!success) {
                revert NameService__TransferFailed();
            }
        }
    }
}
