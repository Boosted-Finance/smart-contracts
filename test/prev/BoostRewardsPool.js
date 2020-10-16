const {constants, expectRevert, time} = require('@openzeppelin/test-helpers');
const {BN} = require('@openzeppelin/test-helpers/src/setup');
const {expect, assert} = require('chai');
const UniswapV2FactoryBytecode = require('@uniswap/v2-core/build/UniswapV2Factory.json');
const UniswapV2Router02Bytecode = require('@uniswap/v2-periphery/build/UniswapV2Router02.json');
const TruffleContract = require('@truffle/contract');
const BoostRewardsPool = artifacts.require('BoostRewardsPool');
const BoostGov = artifacts.require('BoostGov');
const BoostToken = artifacts.require('BoostToken');
const TestToken = artifacts.require('Token');
const WETH = artifacts.require('WETH9');
require('chai').use(require('chai-as-promised')).use(require('chai-bn')(BN)).should();

function getCurrentBlock() {
  return new Promise(function (fulfill, reject) {
    web3.eth.getBlockNumber(function (err, result) {
      if (err) reject(err);
      else fulfill(result);
    });
  });
}

function getCurrentBlockTime() {
  return new Promise(function (fulfill, reject) {
    web3.eth.getBlock('latest', false, function (err, result) {
      if (err) reject(err);
      else fulfill(result.timestamp);
    });
  });
}

async function mineBlocks(blocks) {
  for (let i = 0; i < blocks; i++) {
    await time.advanceBlock();
  }
}

function mineBlockAtTime(timestamp) {
  return new Promise((resolve, reject) => {
    web3.currentProvider.send.bind(web3.currentProvider)(
      {
        jsonrpc: '2.0',
        method: 'evm_mine',
        params: [timestamp],
        id: new Date().getTime(),
      },
      (err, res) => {
        if (err) {
          return reject(err);
        }
        resolve(res);
      }
    );
  });
}

const DURATION = 7 * 24 * 60 * 60;
const MAX_NUM_BOOSTERS = 5;
const USDT_CAP_AMOUNT = (10000 * 10 ** 6).valueOf();
const WBTC_CAP_AMOUNT = (1 * 10 ** 8).valueOf();
const REWARD_AMOUNT = web3.utils.toWei('4000');
const MAX_UINT256 = new BN(2).pow(new BN(256)).sub(new BN(1));
let START_TIME;

contract('BoostRewardsPool', ([governance, minter, alice]) => {
  before('init tokens and pools', async () => {
    // Set pool start time one day after
    START_TIME = await getCurrentBlockTime() + (24 * 60 * 60);

    // Setup tokens
    this.boost = await BoostToken.new({from: governance});
    this.usdt = await TestToken.new('Tether USDT', 'USDT', '6', {from: governance});
    this.wbtc = await TestToken.new('Wrapped Bitcoin', 'WBTC', '8', {from: governance});
    this.ycrv = await TestToken.new('Curve.fi yDAI/yUSDC/yUSDT/yTUSD', 'yDAI+yUSDC+yUSDT+yTUSD', '18', {
      from: governance,
    });
    this.weth = await WETH.new({from: governance});

    // Setup Uniswap
    const UniswapV2Factory = TruffleContract(UniswapV2FactoryBytecode);
    const UniswapV2Router02 = TruffleContract(UniswapV2Router02Bytecode);
    UniswapV2Factory.setProvider(web3.currentProvider);
    UniswapV2Router02.setProvider(web3.currentProvider);
    this.uniswapV2Factory = await UniswapV2Factory.new(governance, {from: governance});
    this.uniswapV2Router = await UniswapV2Router02.new(this.uniswapV2Factory.address, this.weth.address, {
      from: governance,
    });

    // Create Uniswap pair
    await this.boost.approve(this.uniswapV2Router.address, MAX_UINT256, {from: governance});
    await this.ycrv.approve(this.uniswapV2Router.address, MAX_UINT256, {from: governance});
    await this.uniswapV2Factory.createPair(this.boost.address, this.weth.address, {from: governance});
    await this.uniswapV2Factory.createPair(this.ycrv.address, this.weth.address, {from: governance});
    await this.uniswapV2Router.addLiquidityETH(
      this.boost.address,
      web3.utils.toWei('10000'),
      '0',
      '0',
      governance,
      MAX_UINT256,
      {value: web3.utils.toWei('100'), from: governance}
    );
    await this.uniswapV2Router.addLiquidityETH(
      this.ycrv.address,
      web3.utils.toWei('10000'),
      '0',
      '0',
      governance,
      MAX_UINT256,
      {value: web3.utils.toWei('100'), from: governance}
    );

    // Setup pools
    this.usdtPool = await BoostRewardsPool.new(
      USDT_CAP_AMOUNT,
      this.usdt.address,
      this.boost.address,
      governance,
      this.uniswapV2Router.address,
      START_TIME,
      DURATION,
      {
        from: governance,
      }
    );
    await this.boost.transfer(this.usdtPool.address, REWARD_AMOUNT, {from: governance});
    this.wbtcPool = await BoostRewardsPool.new(
      WBTC_CAP_AMOUNT,
      this.wbtc.address,
      this.boost.address,
      governance,
      this.uniswapV2Router.address,
      START_TIME,
      DURATION,
      {
        from: governance,
      }
    );
    await this.boost.transfer(this.wbtcPool.address, REWARD_AMOUNT, {from: governance});

    // Set balances and approvals
    await this.weth.deposit({value: web3.utils.toWei('100'), from: governance});
    await this.usdt.transfer(alice, 100000 * 10 ** 6, {from: governance});
    await this.wbtc.transfer(alice, 1000 * 10 ** 8, {from: governance});
    await this.weth.transfer(alice, web3.utils.toWei('100'), {from: governance});
    await this.usdt.approve(this.usdtPool.address, MAX_UINT256, {from: alice});
    await this.wbtc.approve(this.wbtcPool.address, MAX_UINT256, {from: alice});
    await this.boost.approve(this.usdtPool.address, MAX_UINT256, {from: alice});
    await this.boost.approve(this.wbtcPool.address, MAX_UINT256, {from: alice});

    // Deploy governance but don't set yet
    this.gov = await BoostGov.new(this.boost.address, this.ycrv.address, this.uniswapV2Router.address, {
      from: governance,
    });
  });

  it('should test the rewards pool constants', async () => {
    // USDT pool
    assert.equal(await this.usdtPool.boostToken(), this.boost.address);
    assert.equal(await this.usdtPool.uniswapRouter(), this.uniswapV2Router.address);
    assert.equal(await this.usdtPool.tokenCapAmount(), USDT_CAP_AMOUNT);
    assert.equal(await this.usdtPool.MAX_NUM_BOOSTERS(), MAX_NUM_BOOSTERS);
    assert.equal(await this.usdtPool.duration(), DURATION);
    assert.equal(await this.usdtPool.starttime(), START_TIME);

    // WBTC pool
    assert.equal(await this.wbtcPool.boostToken(), this.boost.address);
    assert.equal(await this.wbtcPool.uniswapRouter(), this.uniswapV2Router.address);
    assert.equal(await this.wbtcPool.tokenCapAmount(), WBTC_CAP_AMOUNT);
    assert.equal(await this.wbtcPool.MAX_NUM_BOOSTERS(), MAX_NUM_BOOSTERS);
    assert.equal(await this.wbtcPool.duration(), DURATION);
    assert.equal(await this.wbtcPool.starttime(), START_TIME);
  });

  it('should set the rewards per pool', async () => {
    await this.usdtPool.notifyRewardAmount(REWARD_AMOUNT, {from: governance});
    assert.equal((await this.usdtPool.rewardRate()).valueOf(), REWARD_AMOUNT / DURATION - 1);
    assert.equal(await this.usdtPool.lastUpdateTime(), START_TIME);
    assert.equal(await this.usdtPool.periodFinish(), START_TIME + DURATION);

    await this.wbtcPool.notifyRewardAmount(REWARD_AMOUNT, {from: governance});
    assert.equal((await this.wbtcPool.rewardRate()).valueOf(), REWARD_AMOUNT / DURATION - 1);
    assert.equal(await this.wbtcPool.lastUpdateTime(), START_TIME);
    assert.equal(await this.wbtcPool.periodFinish(), START_TIME + DURATION);
  });

  it('should test renouncing governanceship per pool', async () => {
    await this.usdtPool.renounceOwnership({from: governance});
    assert.equal(await this.usdtPool.governance(), constants.ZERO_ADDRESS);

    await this.wbtcPool.renounceOwnership({from: governance});
    assert.equal(await this.wbtcPool.governance(), constants.ZERO_ADDRESS);
  });

  it('should revert relevant functions if pool has not started yet', async () => {
    await expectRevert(this.usdtPool.stake(1000 * 10 ** 6, {from: alice}), 'not start');
    await expectRevert(this.wbtcPool.stake(0.1 * 10 ** 8, {from: alice}), 'not start');
    await expectRevert(this.usdtPool.getReward({from: alice}), 'not start');
    await expectRevert(this.wbtcPool.getReward({from: alice}), 'not start');
    await expectRevert(this.usdtPool.boost({from: alice}), 'not start');
    await expectRevert(this.wbtcPool.boost({from: alice}), 'not start');
    await expectRevert(this.usdtPool.withdraw(1, {from: alice}), 'not start');
    await expectRevert(this.wbtcPool.withdraw(1, {from: alice}), 'not start');
    await expectRevert(this.usdtPool.exit({from: alice}), 'not start');
    await expectRevert(this.wbtcPool.exit({from: alice}), 'not start');
  });

  it('should test staking at a pool', async () => {
    // Mine block and move timestamp to beyond pool start time
    await mineBlockAtTime(START_TIME + 15);

    await this.usdtPool.stake(1000 * 10 ** 6, {from: alice});
    assert.equal(await this.usdtPool.balanceOf(alice), 1000 * 10 ** 6);
    await this.wbtcPool.stake(0.5 * 10 ** 8, {from: alice});
    assert.equal(await this.wbtcPool.balanceOf(alice), 0.5 * 10 ** 8);
  });

  it('should revert staking at a pool with amount exceeding token  within first 24hours', async () => {
    await expectRevert(this.usdtPool.stake(20000 * 10 ** 6, {from: alice}), 'token cap exceeded');
    await expectRevert(this.wbtcPool.stake(2 * 10 ** 8, {from: alice}), 'token cap exceeded');
  });

  it('should revert staking at a pool with amount exceeding token cap', async () => {
    // Mine block and move timestamp to beyond 24hour token cap
    await mineBlockAtTime(START_TIME + 86400);

    await this.usdtPool.stake(20000 * 10 ** 6, {from: alice});
    assert.equal(await this.usdtPool.balanceOf(alice), 21000 * 10 ** 6);
    await this.wbtcPool.stake(2 * 10 ** 8, {from: alice});
    assert.equal(await this.wbtcPool.balanceOf(alice), 2.5 * 10 ** 8);
  });

  it('should test getting rewards from a pool', async () => {
    // Mine 1000 blocks
    mineBlocks(1000);

    await this.usdtPool.getReward({from: alice});
    await this.wbtcPool.getReward({from: alice});

    assert((await this.boost.balanceOf(alice)).should.be.a.bignumber.that.is.greaterThan('0'));
  });

  it('should revert purchasing yield boosters before intended start time', async () => {
    await expectRevert(this.usdtPool.boost({from: alice}), 'early boost purchase');
    await expectRevert(this.wbtcPool.boost({from: alice}), 'early boost purchase');
  });

  it('should successfully purchase yield boosters', async () => {
    // Mine block and move timestamp to beyond 2 days
    await mineBlockAtTime(START_TIME + 172800);

    await this.usdtPool.boost({from: alice});
    await this.wbtcPool.boost({from: alice});

    const boosterPriceUSDT = await this.usdtPool.boosterPrice();
    const boosterPriceWBTC = await this.wbtcPool.boosterPrice();
    const boostersBoughtUSDT = await this.usdtPool.numBoostersBought(alice);
    const boostersBoughtWBTC = await this.wbtcPool.numBoostersBought(alice);

    assert.equal(boosterPriceUSDT, 1 * 10 ** 18 * 1.05);
    assert.equal(boosterPriceWBTC, 1 * 10 ** 18 * 1.05);
    assert.equal(boostersBoughtUSDT, 1);
    assert.equal(boostersBoughtWBTC, 1);
  });

  it('should successfully set governance', async () => {
    await this.usdtPool.setGovernance(this.gov.address, {from: governance});
    await this.wbtcPool.setGovernance(this.gov.address, {from: governance});

    assert.equal(await this.usdtPool.governanceSetter(), constants.ZERO_ADDRESS);
    assert.equal(await this.wbtcPool.governanceSetter(), constants.ZERO_ADDRESS);
    assert.equal(await this.usdtPool.stablecoin(), this.ycrv.address);
    assert.equal(await this.wbtcPool.stablecoin(), this.ycrv.address);
  });

  it('should successfully purchase yield boosters, sending half of BOOST to Boost Governance', async () => {
    // Mine block and move timestamp to 1 hour
    await mineBlockAtTime((await getCurrentBlockTime()) + 3600);

    await this.usdtPool.boost({from: alice});
    await this.wbtcPool.boost({from: alice});

    assert((await this.ycrv.balanceOf(this.gov.address)).should.be.a.bignumber.that.is.greaterThan('0'));
  });

  it('should revert purchasing yield boosters consecutively within an hour', async () => {
    // Mine block and move timestamp to 1 hour
    await mineBlockAtTime((await getCurrentBlockTime()) + 3600);

    await this.usdtPool.boost({from: alice});
    await this.wbtcPool.boost({from: alice});
    await expectRevert(this.usdtPool.boost({from: alice}), 'early boost purchase');
    await expectRevert(this.wbtcPool.boost({from: alice}), 'early boost purchase');
  });

  it('should revert purchasing more than the max num allowed of boosters', async () => {
    for (let i = 3; i < MAX_NUM_BOOSTERS; i++) {
      await mineBlockAtTime((await getCurrentBlockTime()) + 3600);
      await this.usdtPool.boost({from: alice});
      await this.wbtcPool.boost({from: alice});
    }

    await mineBlockAtTime((await getCurrentBlockTime()) + 3600);
    await expectRevert(this.usdtPool.boost({from: alice}), 'max boosters bought');
    await expectRevert(this.wbtcPool.boost({from: alice}), 'max boosters bought');
  });

  it('should test withdrawing from a pool', async () => {
    const balanceUSDT = await this.usdt.balanceOf(alice);
    const balanceWBTC = await this.wbtc.balanceOf(alice);

    await this.usdtPool.withdraw((10 * 10 ** 6).valueOf(), {from: alice});
    await this.wbtcPool.withdraw((0.1 * 10 ** 8).valueOf(), {from: alice});

    assert.equal((await this.usdt.balanceOf(alice)).toString(), balanceUSDT.add(new BN(10 * 10 ** 6)));
    assert.equal((await this.wbtc.balanceOf(alice)).toString(), balanceWBTC.add(new BN(0.1 * 10 ** 8)));
  });

  it('should test exiting a pool', async () => {
    await this.usdtPool.exit({from: alice});
    await this.wbtcPool.exit({from: alice});

    assert.equal(await this.usdtPool.balanceOf(alice), 0);
    assert.equal(await this.wbtcPool.balanceOf(alice), 0);
  });
});
