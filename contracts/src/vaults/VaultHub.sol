// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.12;

import { PrivateVault } from "./PrivateVault.sol";
import { ITreasury } from "../../interfaces/treasury/ITreasury.sol";
import "../../interfaces/vaults/IVaultHub.sol";
import { Constant } from "../../libraries/Constant.sol";

contract VaultHub is IVaultHub {
    enum State {
        INIT_SUCCESS,
        SAVE_SUCCESS
    }
    event VaultInit(State indexed result, address indexed signer);
    event Save(State indexed result, address indexed signer);

    address public treasury = address(0);
    address public owner;
    uint256 public fee = 150000000000000;
    bytes32 public DOMAIN_SEPARATOR;
    address private validator;

    constructor(address _validator) {
        require(_validator != address(0));

        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                Constant.VAULTHUB_DOMAIN_TYPE_HASH,
                keccak256(bytes(Constant.VAULTHUB_DOMAIN_NAME)),
                keccak256(bytes(Constant.VAULTHUB_DOMAIN_VERSION)),
                chainId,
                address(this)
            )
        );

        owner = msg.sender;
        validator = _validator;
    }

    function setFee(uint256 _fee) external {
        require(msg.sender == owner, "vHub:caller must be owner");
        fee = _fee;
    }

    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "vHub:caller must be owner");
        require(newOwner != address(0), "vHub:ZERO ADDRESS");
        owner = newOwner;
    }

    function setTreasuryAddress(address _treasury) external {
        require(msg.sender == owner, "vHub:caller must be owner");
        require(treasury == address(0), "vHub:treasury has set");
        treasury = _treasury;
    }

    modifier treasuryValid() {
        require(treasury != address(0), "vHub:treasury ZERO address");
        _;
    }

    function calculateVaultAddress(bytes32 salt, bytes memory bytecode) internal view returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(abi.encodePacked(bytecode)))
                        )
                    )
                )
            );
    }

    function verifyPermit(
        address signer,
        bytes32 params,
        uint8 v,
        bytes32 r,
        bytes32 s,
        string memory notification
    ) internal pure {
        bytes32 paramsHash = keccak256(abi.encodePacked(params));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", paramsHash));

        //Determine whether the result address of ecrecover is equal to addr; if not, revert directly
        require(ecrecover(digest, v, r, s) == signer, notification);
    }

    function hasRegisterPermit(
        address addr,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view {
        require(addr != address(0), "vHub:caller address ZERO");
        require(deadline >= block.timestamp, "vHub:execute timeout");
        bytes32 params = keccak256(
            abi.encodePacked(addr, deadline, DOMAIN_SEPARATOR, Constant.VAULTHUB_VAULT_HAS_REGISTER_PERMIT_TYPE_HASH)
        );
        verifyPermit(addr, params, v, r, s, "vHub:has register permit ERROR");
    }

    function vaultHasRegister(
        address addr,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external view returns (bool) {
        hasRegisterPermit(addr, deadline, v, r, s);
        (bool done, ) = _vaultHasRegister(addr);
        return done;
    }

    // Determine whether a vault-name and password are registered
    function _vaultHasRegister(address addr) internal view returns (bool, address) {
        bytes32 salt = keccak256(abi.encodePacked(addr));
        bytes memory bytecode = abi.encodePacked(type(PrivateVault).creationCode, abi.encode(addr, this, validator));

        //Calculate the address of the private vault, record it as vaultAddr
        address vault = calculateVaultAddress(salt, bytecode);

        if (vault.code.length > 0 && vault.codehash == keccak256(abi.encodePacked(type(PrivateVault).runtimeCode))) {
            return (true, vault);
        }

        return (false, address(0));
    }

    function initPermit(
        address addr,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view {
        require(addr != address(0), "vHub:caller address ZERO");
        require(deadline >= block.timestamp, "vHub:execute timeout");
        bytes32 params = keccak256(
            abi.encodePacked(addr, deadline, DOMAIN_SEPARATOR, Constant.VAULTHUB_INIT_VAULT_PERMIT_TYPE_HASH)
        );
        verifyPermit(addr, params, v, r, s, "vHub:init permit ERROR");
    }

    function initPrivateVault(
        address addr,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (bool) {
        initPermit(addr, deadline, v, r, s);
        bytes32 salt = keccak256(abi.encodePacked(addr));
        bytes memory bytecode = abi.encodePacked(type(PrivateVault).creationCode, abi.encode(addr, this, validator));

        (bool done, ) = _vaultHasRegister(addr);
        require(done == false, "vHub:vault has been registed");
        //create2: deploy contract
        address vault;
        assembly {
            vault := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        if (vault == address(0)) {
            revert("vHub:create2 private vault ERROR");
        }

        emit VaultInit(State.INIT_SUCCESS, addr);

        return true;
    }

    function mintSavePermit(
        address addr,
        string memory data,
        string memory cryptoLabel,
        address labelHash,
        address receiver,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view {
        require(addr != address(0), "vHub:caller address ZERO");
        require(deadline >= block.timestamp, "vHub:execute timeout");
        bytes32 params = keccak256(
            abi.encodePacked(
                addr,
                bytes(data),
                bytes(cryptoLabel),
                labelHash,
                receiver,
                deadline,
                DOMAIN_SEPARATOR,
                Constant.VAULTHUB_MINT_SAVE_PERMIT_TYPE_HASH
            )
        );
        verifyPermit(addr, params, v, r, s, "vHub:mint save permit ERROR");
    }

    function savePrivateDataWithMinting(
        address addr,
        string memory data,
        string memory cryptoLabel,
        address labelHash,
        address receiver,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable treasuryValid {
        require(msg.value >= fee, "vHub:more than 0.00015");
        mintSavePermit(addr, data, cryptoLabel, labelHash, receiver, deadline, v, r, s);

        (bool done, address vault) = _vaultHasRegister(addr);
        require(done == true, "vHub:deploy vault firstly");
        require(PrivateVault(vault).minted() == false, "vHub:mint token has done");

        ITreasury(treasury).mint(receiver);

        PrivateVault(vault).saveWithMinting(data, cryptoLabel, labelHash);
        emit Save(State.SAVE_SUCCESS, addr);
    }

    function saveWithoutMintPermit(
        address addr,
        string memory data,
        string memory cryptoLabel,
        address labelHash,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view {
        require(addr != address(0), "vHub:caller address ZERO");
        require(deadline >= block.timestamp, "vHub:execute timeout");
        bytes32 params = keccak256(
            abi.encodePacked(
                addr,
                bytes(data),
                bytes(cryptoLabel),
                labelHash,
                deadline,
                DOMAIN_SEPARATOR,
                Constant.VAULTHUB_SAVE_PERMIT_TYPE_HASH
            )
        );
        verifyPermit(addr, params, v, r, s, "vHub:save permit ERROR");
    }

    function savePrivateDataWithoutMinting(
        address addr,
        string memory data,
        string memory cryptoLabel,
        address labelHash,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable {
        require(msg.value >= fee, "vHub:more than 0.00015");
        saveWithoutMintPermit(addr, data, cryptoLabel, labelHash, deadline, v, r, s);

        (bool done, address vault) = _vaultHasRegister(addr);
        require(done == true, "vHub:deploy vault firstly");

        PrivateVault(vault).saveWithoutMinting(data, cryptoLabel, labelHash);
        emit Save(State.SAVE_SUCCESS, addr);
    }

    function queryByIndexPermit(
        address addr,
        uint64 index,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view {
        require(addr != address(0), "vHub:caller address ZERO");
        require(deadline >= block.timestamp, "vHub:execute timeout");
        bytes32 params = keccak256(
            abi.encodePacked(addr, index, deadline, DOMAIN_SEPARATOR, Constant.VAULTHUB_INDEX_QUERY_PERMIT_TYPE_HASH)
        );
        verifyPermit(addr, params, v, r, s, "vHub:index query permit ERROR");
    }

    function queryPrivateDataByIndex(
        address addr,
        uint64 index,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external view returns (string memory) {
        queryByIndexPermit(addr, index, deadline, v, r, s);

        (bool done, address vault) = _vaultHasRegister(addr);
        require(done == true, "vHub:deploy vault firstly");

        return PrivateVault(vault).getPrivateDataByIndex(index);
    }

    function queryByNamePermit(
        address addr,
        address labelHash,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view {
        require(addr != address(0), "vHub:caller address ZERO");
        require(deadline >= block.timestamp, "vHub:execute timeout");
        bytes32 params = keccak256(
            abi.encodePacked(addr, labelHash, deadline, DOMAIN_SEPARATOR, Constant.VAULTHUB_NAME_QUERY_PERMIT_TYPE_HASH)
        );
        verifyPermit(addr, params, v, r, s, "vHub:name query permit ERROR");
    }

    function queryPrivateDataByName(
        address addr,
        address labelHash,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external view returns (string memory) {
        queryByNamePermit(addr, labelHash, deadline, v, r, s);

        (bool done, address vault) = _vaultHasRegister(addr);
        require(done == true, "vHub:deploy vault firstly");

        return PrivateVault(vault).getPrivateDataByName(labelHash);
    }

    function queryPrivateVaultAddressPermit(
        address addr,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view {
        require(addr != address(0), "vHub:caller address ZERO");
        require(deadline >= block.timestamp, "vHub:execute timeout");
        bytes32 params = keccak256(
            abi.encodePacked(
                addr,
                deadline,
                DOMAIN_SEPARATOR,
                Constant.VAULTHUB_QUERY_PRIVATE_VAULT_ADDRESS_PERMIT_TYPE_HASH
            )
        );
        verifyPermit(addr, params, v, r, s, "vHub:query vault address permit ERROR");
    }

    function queryPrivateVaultAddress(
        address addr,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external view returns (address) {
        queryPrivateVaultAddressPermit(addr, deadline, v, r, s);
        (bool done, address vault) = _vaultHasRegister(addr);
        require(done == true, "vHub:deploy vault firstly");
        return vault;
    }

    function hasMintedPermit(
        address addr,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view {
        require(addr != address(0), "vHub:caller address ZERO");
        require(deadline >= block.timestamp, "vHub:execute timeout");
        bytes32 params = keccak256(
            abi.encodePacked(addr, deadline, DOMAIN_SEPARATOR, Constant.VAULTHUB_HAS_MINTED_PERMIT_TYPE_HASH)
        );
        verifyPermit(addr, params, v, r, s, "vHub:has minted permit ERROR");
    }

    function hasMinted(
        address addr,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external view returns (bool) {
        hasMintedPermit(addr, deadline, v, r, s);
        (bool done, address vault) = _vaultHasRegister(addr);
        require(done == true, "vHub:deploy vault firstly");
        return PrivateVault(vault).minted();
    }

    function totalSavedItemsPermit(
        address addr,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view {
        require(addr != address(0), "vHub:caller address ZERO");
        require(deadline >= block.timestamp, "vHub:execute timeout");
        bytes32 params = keccak256(
            abi.encodePacked(addr, deadline, DOMAIN_SEPARATOR, Constant.VAULTHUB_TOTAL_SAVED_ITEMS_PERMIT_TYPE_HASH)
        );
        verifyPermit(addr, params, v, r, s, "vHub:get total saved permit ERROR");
    }

    function totalSavedItems(
        address addr,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external view returns (uint64) {
        totalSavedItemsPermit(addr, deadline, v, r, s);
        (bool done, address vault) = _vaultHasRegister(addr);
        require(done == true, "vHub:deploy vault firstly");
        return PrivateVault(vault).total();
    }

    function getLabelNamePermit(
        address addr,
        uint256 deadline,
        uint64 index,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view {
        require(addr != address(0), "vHub:caller address ZERO");
        require(deadline >= block.timestamp, "vHub:execute timeout");
        bytes32 params = keccak256(
            abi.encodePacked(
                addr,
                deadline,
                index,
                DOMAIN_SEPARATOR,
                Constant.VAULTHUB_GET_LABEL_NAME_BY_INDEX_TYPE_HASH
            )
        );
        verifyPermit(addr, params, v, r, s, "vHub:get lable name permit ERROR");
    }

    function getLabelNameByIndex(
        address addr,
        uint256 deadline,
        uint64 index,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external view returns (string memory) {
        getLabelNamePermit(addr, deadline, index, v, r, s);
        (bool done, address vault) = _vaultHasRegister(addr);
        require(done == true, "vHub:deploy vault firstly");
        return PrivateVault(vault).labelName(index);
    }

    function getLabelExistPermit(
        address addr,
        address labelHash,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view {
        require(addr != address(0), "vHub:caller address ZERO");
        require(deadline >= block.timestamp, "vHub:execute timeout");
        bytes32 params = keccak256(
            abi.encodePacked(addr, labelHash, deadline, DOMAIN_SEPARATOR, Constant.VAULTHUB_LABEL_EXIST_TYPE_HASH)
        );
        verifyPermit(addr, params, v, r, s, "vHub:lable exist permit ERROR");
    }

    function labelExist(
        address addr,
        address labelHash,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external view returns (bool) {
        getLabelExistPermit(addr, labelHash, deadline, v, r, s);
        (bool done, address vault) = _vaultHasRegister(addr);
        require(done == true, "vHub:deploy vault firstly");
        return PrivateVault(vault).labelIsExist(labelHash);
    }

    function withdrawETH(address payable receiver, uint256 amount) external returns (bool) {
        require(msg.sender == owner, "vHub:caller must be owner");
        receiver.transfer(amount);
        return true;
    }
}
