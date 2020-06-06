pragma solidity ^0.5.0;

import {UsingStorage} from "../storage/UsingStorage.sol";

contract UsingStorageTest is UsingStorage {
	function setUInt(uint256 _value) external {
		eternalStorage().setUint(getUintKey(), _value);
	}

	function getUInt() external view returns (uint256) {
		return eternalStorage().getUint(getUintKey());
	}

	function getUintKey() private pure returns (bytes32) {
		return keccak256(abi.encodePacked("_uint"));
	}
}
