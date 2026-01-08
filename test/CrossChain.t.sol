// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ============================================
// ============== IMPORTS =====================
// ============================================

// Foundry
import {Test, console} from "forge-std/Test.sol";

// CCIP Local Simulator
import {CCIPLocalSimulatorFork, Register} from "@chainlink-local/src/ccip/CCIPLocalSimulatorFork.sol";

// CCIP Contracts
import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {RegistryModuleOwnerCustom} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {TokenPool} from "@ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {RateLimiter} from "@ccip/contracts/src/v0.8/ccip/libraries/RateLimiter.sol";
import {Client} from "@ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

// Project Contracts
import {RebaseToken} from "../src/RebaseToken.sol";
import {RebaseTokenPool} from "../src/RebaseTokenPool.sol";
import {Vault} from "../src/Vault.sol";
import {IRebaseToken} from "../src/interfaces/IRebaseToken.sol";

// ============================================
// ============== CONTRACT ====================
// ============================================

contract CrossChainTest is Test {
    // ============================================
    // ============== STATE VARIABLES =============
    // ============================================

    // Users
    address owner = makeAddr("owner");
    address user = makeAddr("user");
    uint256 SEND_VALUE = 1e5;

    // Fork IDs
    uint256 sepoliaFork;
    uint256 arbSepoliaFork;

    // CCIP Simulator
    CCIPLocalSimulatorFork ccipLocalSimulatorFork;

    // Tokens
    RebaseToken sepoliaToken;
    RebaseToken arbSepoliaToken;

    // Vault
    Vault vault;

    // Token Pools
    RebaseTokenPool sepoliaPool;
    RebaseTokenPool arbSepoliaPool;

    // Network Details
    Register.NetworkDetails sepoliaNetworkDetails;
    Register.NetworkDetails arbSepoliaNetworkDetails;

    // ============================================
    // ============== SETUP =======================
    // ============================================

    function setUp() public {
        // Initialize owner
        owner = makeAddr("owner");

        // Create forks
        sepoliaFork = vm.createSelectFork("sepolia");
        arbSepoliaFork = vm.createFork("arbitrum-sepolia");

        // Initialize CCIP simulator
        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        // ----------------------------------------
        // Step 1: Deploy and configure on Sepolia
        // ----------------------------------------
        sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(
            block.chainid
        );

        vm.startPrank(owner);

        // Deploy contracts
        sepoliaToken = new RebaseToken();
        vault = new Vault(IRebaseToken(address(sepoliaToken)));
        sepoliaPool = new RebaseTokenPool(
            IERC20(address(sepoliaToken)),
            new address[](0),
            sepoliaNetworkDetails.rmnProxyAddress,
            sepoliaNetworkDetails.routerAddress
        );

        // Grant roles
        sepoliaToken.grantMintAndBurnRole(address(vault));
        sepoliaToken.grantMintAndBurnRole(address(sepoliaPool));

        // Register token in CCIP
        RegistryModuleOwnerCustom(
            sepoliaNetworkDetails.registryModuleOwnerCustomAddress
        ).registerAdminViaOwner(address(sepoliaToken));

        TokenAdminRegistry(sepoliaNetworkDetails.tokenAdminRegistryAddress)
            .acceptAdminRole(address(sepoliaToken));

        TokenAdminRegistry(sepoliaNetworkDetails.tokenAdminRegistryAddress)
            .setPool(address(sepoliaToken), address(sepoliaPool));

        vm.stopPrank();

        // ------------------------------------------------
        // Step 2: Deploy and configure on Arbitrum Sepolia
        // ------------------------------------------------
        vm.selectFork(arbSepoliaFork);
        arbSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(
            block.chainid
        );

        vm.startPrank(owner);

        // Deploy contracts
        arbSepoliaToken = new RebaseToken();
        arbSepoliaPool = new RebaseTokenPool(
            IERC20(address(arbSepoliaToken)),
            new address[](0),
            arbSepoliaNetworkDetails.rmnProxyAddress,
            arbSepoliaNetworkDetails.routerAddress
        );

        // Grant roles
        arbSepoliaToken.grantMintAndBurnRole(address(arbSepoliaPool));

        // Register token in CCIP
        RegistryModuleOwnerCustom(
            arbSepoliaNetworkDetails.registryModuleOwnerCustomAddress
        ).registerAdminViaOwner(address(arbSepoliaToken));

        TokenAdminRegistry(arbSepoliaNetworkDetails.tokenAdminRegistryAddress)
            .acceptAdminRole(address(arbSepoliaToken));

        TokenAdminRegistry(arbSepoliaNetworkDetails.tokenAdminRegistryAddress)
            .setPool(address(arbSepoliaToken), address(arbSepoliaPool));

        vm.stopPrank();
        // ----------------------------------------
        // Step 3: Configure token pools for cross-chain
        // ----------------------------------------

        // Configure Sepolia pool to know about Arbitrum pool
        configureTokenPool(
            sepoliaFork,
            address(sepoliaPool),
            arbSepoliaNetworkDetails.chainSelector,
            address(arbSepoliaPool),
            address(arbSepoliaToken)
        );

        // Configure Arbitrum pool to know about Sepolia pool
        configureTokenPool(
            arbSepoliaFork,
            address(arbSepoliaPool),
            sepoliaNetworkDetails.chainSelector,
            address(sepoliaPool),
            address(sepoliaToken)
        );
    }

    // ============================================
    // ============== HELPER FUNCTIONS ============
    // ============================================

    /**
     * @dev Configures a token pool for cross-chain communication
     * @param fork Fork ID to switch to
     * @param localPool Address of the local token pool
     * @param remoteChainSelector Chain selector of the remote chain
     * @param remotePool Address of the remote token pool
     * @param remoteTokenAddress Address of the remote token
     */
    function configureTokenPool(
        uint256 fork,
        address localPool,
        uint64 remoteChainSelector,
        address remotePool,
        address remoteTokenAddress
    ) public {
        vm.selectFork(fork);
        vm.prank(owner);

        // Prepare remote pool addresses
        bytes[] memory remotePoolAddresses = new bytes[](1);
        remotePoolAddresses[0] = abi.encode(remotePool);

        // Create chain update config
        TokenPool.ChainUpdate[]
            memory chainsToAdd = new TokenPool.ChainUpdate[](1);
        chainsToAdd[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remoteChainSelector,
            remotePoolAddresses: remotePoolAddresses,
            remoteTokenAddress: abi.encode(remoteTokenAddress),
            outboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: false,
                capacity: 0,
                rate: 0
            }),
            inboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: false,
                capacity: 0,
                rate: 0
            })
        });

        // Apply chain updates
        TokenPool(localPool).applyChainUpdates(new uint64[](0), chainsToAdd);
    }

    /**
     * @dev Bridges tokens from one chain to another
     * @param amountToBridge Amount of tokens to bridge
     * @param localFork Fork ID of the source chain
     * @param remoteFork Fork ID of the destination chain
     * @param localNetworkDetails Network details of the source chain
     * @param remoteNetworkDetails Network details of the destination chain
     * @param localToken Token contract on the source chain
     * @param remoteToken Token contract on the destination chain
     */
    function bridgeTokens(
        uint256 amountToBridge,
        uint256 localFork,
        uint256 remoteFork,
        Register.NetworkDetails memory localNetworkDetails,
        Register.NetworkDetails memory remoteNetworkDetails,
        RebaseToken localToken,
        RebaseToken remoteToken
    ) public {
        // ----------------------------------------
        // Step 1: Prepare on source chain
        // ----------------------------------------
        vm.selectFork(localFork);

        // Create token amount array for CCIP message
        Client.EVMTokenAmount[]
            memory tokenAmount = new Client.EVMTokenAmount[](1);
        tokenAmount[0] = Client.EVMTokenAmount({
            token: address(localToken),
            amount: amountToBridge
        });

        // Create CCIP message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(user),
            data: "",
            tokenAmounts: tokenAmount,
            feeToken: localNetworkDetails.linkAddress,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({
                    gasLimit: 100_000,
                    allowOutOfOrderExecution: false
                })
            )
        });

        // ----------------------------------------
        // Step 2: Calculate fee and get LINK
        // ----------------------------------------
        uint256 fee = IRouterClient(localNetworkDetails.routerAddress).getFee(
            remoteNetworkDetails.chainSelector,
            message
        );
        ccipLocalSimulatorFork.requestLinkFromFaucet(user, fee);

        // ----------------------------------------
        // Step 3: Approve tokens
        // ----------------------------------------
        vm.startPrank(user);
        IERC20(localNetworkDetails.linkAddress).approve(
            localNetworkDetails.routerAddress,
            fee
        );
        IERC20(address(localToken)).approve(
            localNetworkDetails.routerAddress,
            amountToBridge
        );

        // ----------------------------------------
        // Step 4: Send CCIP message
        // ----------------------------------------
        uint256 localBalanceBefore = localToken.balanceOf(user);
        IRouterClient(localNetworkDetails.routerAddress).ccipSend(
            remoteNetworkDetails.chainSelector,
            message
        );
        assertEq(
            localToken.balanceOf(user),
            localBalanceBefore - amountToBridge
        );

        // Store interest rate for verification
        uint256 localUserInterestRate = localToken.getUserInterestRate(user);
        vm.stopPrank();

        // ----------------------------------------
        // Step 5: Receive on destination chain
        // ----------------------------------------
        // switchChainAndRouteMessage switches to destination and routes the message
        // It needs the DESTINATION fork ID (where message should be delivered)
        ccipLocalSimulatorFork.switchChainAndRouteMessage(remoteFork);

        // ----------------------------------------
        // Step 6: Verify results
        // ----------------------------------------
        assertEq(remoteToken.balanceOf(user), amountToBridge);
        assertEq(remoteToken.getUserInterestRate(user), localUserInterestRate);
    }

    function testBridgeAllTokens() public {
        vm.selectFork(sepoliaFork);
        vm.deal(user, SEND_VALUE);
        vm.prank(user);
        Vault(payable(address(vault))).deposit{value: SEND_VALUE}();
        assertEq(sepoliaToken.balanceOf(user), SEND_VALUE);
        bridgeTokens(
            SEND_VALUE,
            sepoliaFork,
            arbSepoliaFork,
            sepoliaNetworkDetails,
            arbSepoliaNetworkDetails,
            sepoliaToken,
            arbSepoliaToken
        );
        vm.selectFork(arbSepoliaFork);
        vm.warp(block.timestamp + 20 minutes);
        bridgeTokens(
            arbSepoliaToken.balanceOf(user),
            arbSepoliaFork,
            sepoliaFork,
            arbSepoliaNetworkDetails,
            sepoliaNetworkDetails,
            arbSepoliaToken,
            sepoliaToken
        );
    }
}
