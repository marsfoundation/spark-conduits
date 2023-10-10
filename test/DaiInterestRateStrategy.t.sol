// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import 'dss-test/DssTest.sol';

import { DaiInterestRateStrategy, DataTypes } from '../src/DaiInterestRateStrategy.sol';

import { DaiMock, InterestRateDataSourceMock } from './mocks/Mocks.sol';

contract DaiInterestRateStrategyTestBase is DssTest {

    uint256 constant RBPS         = RAY / 10_000;
    uint256 constant ONE_TRILLION = 1_000_000_000_000;

    InterestRateDataSourceMock dataSource;
    DaiMock                    dai;
    DaiInterestRateStrategy    interestStrategy;

    function setUp() public {
        dataSource = new InterestRateDataSourceMock();
        dai        = new DaiMock();

        dataSource.setSubsidyRate(3_50 * RBPS);

        interestStrategy = new DaiInterestRateStrategy(
            address(dai),
            dataSource,
            30 * RBPS,
            75_00 * RBPS
        );
    }

}

contract DaiInterestRateStrategyConstructorTests is DaiInterestRateStrategyTestBase {

    function test_constructor() public {
        assertEq(address(interestStrategy.dataSource()), address(dataSource));
        assertEq(interestStrategy.spread(),              30 * RBPS);
        assertEq(interestStrategy.maxRate(),             7_500 * RBPS);

        // Recompute should occur
        assertEq(interestStrategy.getDebtRatio(),           0);
        assertEq(interestStrategy.getBaseBorrowRate(),      3_80 * RBPS);
        assertEq(interestStrategy.getLastUpdateTimestamp(), block.timestamp);
    }

}

contract DaiInterestRateStrategyRecomputeTests is DaiInterestRateStrategyTestBase {

    event Recompute(uint256 debtRatio, uint256 baseBorrowRate);

    function test_recompute() public {
        dataSource.setCurrentDebt(50 * WAD);
        dataSource.setTargetDebt(100 * WAD);
        dataSource.setSubsidyRate(4_00 * RBPS);

        vm.warp(block.timestamp + 1 days);

        assertEq(interestStrategy.getDebtRatio(),           0);
        assertEq(interestStrategy.getBaseBorrowRate(),      3_80 * RBPS);
        assertEq(interestStrategy.getLastUpdateTimestamp(), block.timestamp - 1 days);

        vm.expectEmit();
        emit Recompute(WAD / 2, 4_30 * RBPS);
        interestStrategy.recompute();

        assertEq(interestStrategy.getDebtRatio(),           WAD / 2);
        assertEq(interestStrategy.getBaseBorrowRate(),      4_30 * RBPS);
        assertEq(interestStrategy.getLastUpdateTimestamp(), block.timestamp);
    }

}

contract DaiInterestRateStrategyCalculateInterestRatesTests is DaiInterestRateStrategyTestBase {

    function test_calculateInterestRates_zero_usage_zero_limit() public {
        assertEq(dataSource.getInterestData(address(dai)).currentDebt, 0);
        assertRates(
            0,
            0,
            3_80 * RBPS,
            "Should be base borrow at 0 / 0"
        );
    }

    function test_calculateInterestRates_zero_usage_some_limit() public {
        dataSource.setCurrentDebt(100 * WAD);
        dataSource.setTargetDebt(100 * WAD);
        interestStrategy.recompute();
        assertRates(
            0,
            0,
            3_80 * RBPS,
            "Should be base borrow at 0 / 100"
        );
    }

    function test_calculateInterestRates_some_usage_some_limit() public {
        dataSource.setCurrentDebt(100 * WAD);
        dataSource.setTargetDebt(100 * WAD);
        dai.setLiquidity(50 * WAD);
        interestStrategy.recompute();
        assertRates(
            50 * WAD,
            1_90 * RBPS,
            3_80 * RBPS,
            "Should be base borrow at 50 / 100"
        );
    }

    function test_calculateInterestRates_over_capacity() public {
        dataSource.setCurrentDebt(100 * WAD);
        dataSource.setTargetDebt(50 * WAD);
        dai.setLiquidity(0);
        interestStrategy.recompute();
        assertRates(
            100 * WAD,
            39_40 * RBPS,
            39_40 * RBPS,
            "Should be ~half way between base and max borrow 100 / 50"
        );
    }

    function test_calculateInterestRates_fuzz(
        uint256 baseRate,
        uint256 subsidyRate,
        uint256 currentDebt,
        uint256 targetDebt,
        uint256 totalVariableDebt,
        uint256 liquidity,
        uint256 spread,
        uint256 maxRate
    ) public {
        // Keep the numbers sane
        baseRate          = _bound(baseRate,          0, 200_00 * RBPS);
        subsidyRate       = _bound(subsidyRate,       0, baseRate);
        currentDebt       = _bound(currentDebt,       0, ONE_TRILLION * WAD);
        targetDebt        = _bound(targetDebt,        0, ONE_TRILLION * WAD);
        totalVariableDebt = _bound(totalVariableDebt, 0, ONE_TRILLION * WAD);
        liquidity         = _bound(liquidity,         0, ONE_TRILLION * WAD);
        maxRate           = _bound(maxRate,           0, 200_00 * RBPS);
        spread            = _bound(spread,            0, maxRate);

        interestStrategy = new DaiInterestRateStrategy(
            address(dai),
            dataSource,
            spread,
            maxRate
        );

        dataSource.setBaseRate(baseRate);
        dataSource.setSubsidyRate(subsidyRate);
        dataSource.setCurrentDebt(currentDebt);
        dataSource.setTargetDebt(targetDebt);

        dai.setLiquidity(liquidity);
        interestStrategy.recompute();

        uint256 utilization = totalVariableDebt > 0
            ? totalVariableDebt * WAD / (totalVariableDebt + liquidity)
            : 0;

        (uint256 supplyRate,, uint256 borrowRate)
            = interestStrategy.calculateInterestRates(DataTypes.CalculateInterestRatesParams(
                0,
                0,
                0,
                0,
                totalVariableDebt,
                0,
                0,
                address(dai),
                address(0)
            ));

        assertEq(
            borrowRate * utilization / WAD,
            supplyRate,
            "borrowRate * utilization == supplyRate"
        );

        assertGe(
            borrowRate,
            interestStrategy.getBaseBorrowRate(),
            "borrowRate >= base rate + spread"
        );

        assertLe(utilization, WAD,        "utilization < 1");
        assertGe(borrowRate,  supplyRate, "borrowRate >= supplyRate");
        assertLe(borrowRate,  maxRate,    "borrowRate <= maxRate");
    }

    function assertRates(
        uint256 totalVariableDebt,
        uint256 expectedSupplyRate,
        uint256 expectedBorrowRate,
        string memory errorMessage
    ) internal {
        (uint256 supplyRate,, uint256 borrowRate)
            = interestStrategy.calculateInterestRates(DataTypes.CalculateInterestRatesParams(
                0,
                0,
                0,
                0,
                totalVariableDebt,
                0,
                0,
                address(dai),
                address(0)
            ));

        assertEq(supplyRate, expectedSupplyRate, errorMessage);
        assertEq(borrowRate, expectedBorrowRate, errorMessage);
    }

}
