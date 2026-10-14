// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Params} from "../src/Params.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {GameModule} from "../src/lib/GameModule.sol";
import {Robinhood} from "../src/lib/Robinhood.sol";
import {SwarmCode} from "../src/lib/SwarmCode.sol";

/// @dev Offline CREATE2 probe only. It deploys the complete batch in one transaction,
/// like the supplied protected floor, and exposes the prediction used by registration.
contract JobABatchProbe {
    function predictContract(uint64 launchNumber, uint256 index, bytes memory initCode) public view returns (address) {
        bytes32 salt = keccak256(abi.encode(launchNumber, index));
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(initCode)))))
            );
    }

    function deployAll(uint64 launchNumber, bytes[] memory codes) external returns (address[] memory deployed) {
        require(codes.length == 8, "job A requires eight contracts");
        deployed = new address[](8);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            require(code.length > 0 && code.length <= 49_152, "init code size");
            bytes32 salt = keccak256(abi.encode(launchNumber, i));
            address created;
            assembly ("memory-safe") {
                created := create2(0, add(code, 32), mload(code), salt)
            }
            require(created != address(0) && created.code.length != 0, "constructor failed");
            deployed[i] = created;
        }
    }
}

contract JobALaunchTest is Test {
    address private constant DESK = 0x5cb0686A4475D1F8a6c6e5240579080a4A05B609;
    address private constant TOKEN = 0x38B05971C79E738F64452BE83c78ec3D66535B7A;
    address private constant MARKET = 0x3C9599670893546A3DEF98608259a8e6582790CC;
    bytes32 private constant STARTER_ROOT = 0xb7d282d1c46f6062963bf2d134d058aa4de3af4cb7b092c5a0fd12ed74dc0f2c;
    bytes32 private constant FREE_ROOT = 0xdc0842e9fd0017b08be09e787e877c53cfb446ca52aabdb9770e5c33b49d1325;
    uint256 private constant SNAPSHOT_BLOCK = 26_182_375;
    uint256 private constant ENDOWMENT = 200_000_000 ether;
    bytes32 private constant CONFIG_HASH = 0x11ed7438974e96ecc962201e9c46422c7bf239d725876863fa25a56c734b20d3;

    string[8] private names =
        ["Params", "GameRegistry", "RewardPool", "FarmRewards", "FarmCore", "FarmItems", "PackSale", "StarterClaim"];
    bytes32[8] private hashes = [
        bytes32(0x26c9f36af040b02eba9644f52daeed84fae4e42eab9bdb23277d0bb28c6dc6c0),
        0xe41104da4edfb9a746e9080ce7b1885b5fe7609674a3a68fc5addbfd5a871531,
        0xecf3ae5ebb791318703b5e79960cfd243b7d89bdffa0e0501bee5146623764de,
        0xfa1a4087722916aeefae66aaf3400299a5e4cb8f4fc8e516a17cec7754e07506,
        0xc390b07ef7a9ab65bef3a1ec3b39c1a16e117543c9565fedc9342526aa57aa47,
        0x98f7224201d9e7e3d16bd8996c29a522cac5bd1b375181de8cfdc2c6b9639e76,
        0x7ecf36d55a73c01094e4434de085dfb39f17a1deda39a52ee38954f3a8e8737a,
        0x960e2782608b572a1385ec22ed3e1fb49cd0cccd9b3455ce7bf7f22e990dbd90
    ];
    uint256[8] private runtimeSizes = [uint256(3118), 2864, 4234, 17002, 22361, 13861, 12538, 5477];

    function testJobAPinsMatchTheBriefAndDeskPins() public view {
        for (uint256 i; i < names.length; ++i) {
            assertEq(keccak256(_creation(i)), hashes[i], names[i]);
        }
        assertTrue(SwarmCode.isParams(hashes[0]));
        assertTrue(SwarmCode.isRegistry(hashes[1]));
        assertEq(keccak256(abi.encode(STARTER_ROOT, FREE_ROOT, SNAPSHOT_BLOCK, ENDOWMENT)), CONFIG_HASH);
    }

    function testJobABatchOnEmptyChainPreservesReferencesAndRegistersRoles() public {
        vm.chainId(4663);
        // These external dependencies deliberately have no code in the local EVM.
        assertEq(DESK.code.length, 0);
        assertEq(TOKEN.code.length, 0);
        assertEq(MARKET.code.length, 0);
        assertEq(Robinhood.PROJECT_FACTORY.code.length, 0);
        vm.etch(Robinhood.PROJECT_FACTORY, type(JobABatchProbe).runtimeCode);
        JobABatchProbe factory = JobABatchProbe(Robinhood.PROJECT_FACTORY);

        // A local salt namespace, never a claimed or predicted production launch number.
        uint64 localLaunch = uint64(uint256(keccak256("BLACKOUT job A offline test")));
        bytes[] memory codes = new bytes[](8);
        address[8] memory predicted;
        codes[0] = bytes.concat(_creation(0), abi.encode(DESK, uint256(200), uint256(1 ether)));
        predicted[0] = factory.predictContract(localLaunch, 0, codes[0]);
        codes[1] = bytes.concat(
            _creation(1), abi.encode(TOKEN, predicted[0], MARKET, STARTER_ROOT, FREE_ROOT, SNAPSHOT_BLOCK, ENDOWMENT)
        );
        predicted[1] = factory.predictContract(localLaunch, 1, codes[1]);
        for (uint256 i = 2; i < 8; ++i) {
            codes[i] = bytes.concat(_creation(i), abi.encode(predicted[1]));
            predicted[i] = factory.predictContract(localLaunch, i, codes[i]);
        }
        for (uint256 i; i < 8; ++i) {
            assertEq(predicted[i].code.length, 0);
        }

        address[] memory deployed = factory.deployAll(localLaunch, codes);
        for (uint256 i; i < 8; ++i) {
            assertEq(deployed[i], predicted[i], names[i]);
            assertEq(deployed[i].balance, 0);
            assertEq(deployed[i].code.length, runtimeSizes[i], names[i]);
            _checkRuntime(deployed[i].code);
        }

        Params params = Params(deployed[0]);
        GameRegistry registry = GameRegistry(deployed[1]);
        assertEq(params.swarmWallet(), DESK);
        assertNotEq(params.swarmWallet(), address(factory));
        assertEq(params.get(Params.Key.HeartbeatBps), 200);
        assertEq(params.get(Params.Key.HeartbeatCap), 1 ether);
        assertEq(registry.token(), TOKEN);
        assertEq(registry.params(), deployed[0]);
        assertEq(registry.market(), MARKET);
        assertEq(registry.starterRoot(), STARTER_ROOT);
        assertEq(registry.freeRoot(), FREE_ROOT);
        assertEq(registry.snapshotBlock(), SNAPSHOT_BLOCK);
        assertEq(registry.endowment(), ENDOWMENT);
        assertEq(address(registry.factory()), address(factory));
        assertEq(registry.registered(), 0);

        // Registration is a later, permissionless action, not constructor initialization.
        for (uint256 role; role < 6; ++role) {
            uint256 index = role + 2;
            assertEq(address(GameModule(deployed[index]).registry()), deployed[1]);
            assertEq(registry.creationCodeHash(role), hashes[index]);
            assertEq(registry.register(role, localLaunch, index, _creation(index)), deployed[index]);
            assertEq(registry.module(role), deployed[index]);
        }
        assertEq(registry.registered(), 6);
        assertEq(DESK.code.length, 0);
        assertEq(TOKEN.code.length, 0);
        assertEq(MARKET.code.length, 0);
    }

    function _creation(uint256 index) private view returns (bytes memory) {
        return vm.getCode(string.concat(names[index], ".sol:", names[index]));
    }

    function _checkRuntime(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
        }
    }
}
