const {expectRevert} = require('@openzeppelin/test-helpers');
const {ethers} = require('ethers');
const BN = ethers.BigNumber;
const {assert} = require('chai');
const UniswapV2FactoryBytecode = require('@uniswap/v2-core/build/UniswapV2Factory.json');
const UniswapV2Router02Bytecode = require('@uniswap/v2-periphery/build/UniswapV2Router02.json');
const TruffleContract = require('@truffle/contract');
const Treasury = artifacts.require('TreasuryV2');
const Gov = artifacts.require('BoostGovV2');
const BoostToken = artifacts.require('BoostToken');
const TestToken = artifacts.require('Token');
const WETH = artifacts.require('WETH9');

contract('BoostGov', ([governance, alice]) => {
  before('init uniswap, tokens, and governance', async() => {
    this.boost = await BoostToken.new({from: governance});
    this.weth = await WETH.new({from: governance});
    this.ycrv = await TestToken.new('Curve.fi yDAI/yUSDC/yUSDT/yTUSD', 'yDAI+yUSDC+yUSDT+yTUSD', '18', {
      from: governance
    });

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
    await this.boost.approve(this.uniswapV2Router.address, ethers.constants.MaxUint256, {from: governance});
    await this.ycrv.approve(this.uniswapV2Router.address, ethers.constants.MaxUint256, {from: governance});
    await this.uniswapV2Factory.createPair(this.boost.address, this.weth.address, {from: governance});
    await this.uniswapV2Factory.createPair(this.ycrv.address, this.weth.address, {from: governance});
    await this.uniswapV2Router.addLiquidityETH(
      this.boost.address,
      web3.utils.toWei('10000'),
      '0',
      '0',
      governance,
      ethers.constants.MaxUint256,
      {value: web3.utils.toWei('100'), from: governance}
    );
    await this.uniswapV2Router.addLiquidityETH(
      this.ycrv.address,
      web3.utils.toWei('10000'),
      '0',
      '0',
      governance,
      ethers.constants.MaxUint256,
      {value: web3.utils.toWei('100'), from: governance}
    );

    // Deploy treasury
    this.treasury = await Treasury.new(
      this.uniswapV2Router.address,
      this.ycrv.address,
      this.boost.address,
      governance,
      {from: governance}
    );

    // Deploy gov
    this.gov = await Gov.new(
      this.boost.address,
      this.treasury.address,
      this.uniswapV2Router.address,
      {from: governance}
    );

    // Bootstrap user balances
    await this.ycrv.transfer(this.gov.address, web3.utils.toWei('10000'), {from: governance});
    await this.ycrv.transfer(alice, web3.utils.toWei('10000'), {from: governance});
    await this.boost.transfer(alice, web3.utils.toWei('1000'), {from: governance});

    // Set balances and approvals
    await this.weth.deposit({value: web3.utils.toWei('300'), from: governance});
    await this.weth.transfer(alice, web3.utils.toWei('100'), {from: governance});
    await this.ycrv.approve(this.treasury.address, ethers.constants.MaxUint256, {from: alice});
    await this.weth.approve(this.treasury.address, ethers.constants.MaxUint256, {from: alice});
    await this.boost.approve(this.treasury.address, ethers.constants.MaxUint256, {from: alice});
  });

  it('should have correct variable instantiations', async() => {
    assert.equal((await this.treasury.defaultToken()).toString(), this.ycrv.address);
    assert.equal((await this.treasury.boostToken()).toString(), this.boost.address);
    assert.equal((await this.treasury.swapRouter()).toString(), this.uniswapV2Router.address);
    assert.equal((await this.treasury.ecoFund()).toString(), governance);
    assert.equal((await this.treasury.gov()).toString(), ethers.constants.AddressZero);
  });

  it('should not have unauthorized set stuff', async() => {
    await expectRevert(
      this.treasury.setSwapRouter(governance, {from: alice}),
      "Ownable: caller is not the owner"
    );

    await expectRevert(
      this.treasury.setEcoFund(governance, {from: alice}),
      "Ownable: caller is not the owner"
    );

    await expectRevert(
      this.treasury.setGov(this.gov.address, {from: alice}),
      "not authorized"
    );

    await expectRevert(
      this.treasury.setFundPercentage(1, {from: alice}),
      "Ownable: caller is not the owner"
    );

    await expectRevert(
      this.treasury.setBurnPercentage(1, {from: alice}),
      "Ownable: caller is not the owner"
    );

    await expectRevert(
      this.treasury.withdraw(5, alice, {from: alice}),
      "not gov"
    );
  });

  it('should have owner set swap router', async() => {
    await this.treasury.setSwapRouter(alice, {from: governance});
    assert.equal(await this.treasury.swapRouter(), alice);
    await this.treasury.setSwapRouter(this.uniswapV2Router.address, {from: governance});
    assert.equal(await this.treasury.swapRouter(), this.uniswapV2Router.address);
  });

  it('should have owner set eco fund', async() => {
    await this.treasury.setEcoFund(alice, {from: governance});
    assert.equal(await this.treasury.ecoFund(), alice);
    await this.treasury.setEcoFund(governance, {from: governance});
    assert.equal(await this.treasury.ecoFund(), governance);
  });

  it('should have owner set eco percentage', async() => {
    await this.treasury.setFundPercentage(250, {from: governance});
    assert.equal((await this.treasury.fundPercentage()).toString(), 250);
  });

  it('should revert if eco percentage threshold exceeded', async() => {
    await expectRevert(
      this.treasury.setFundPercentage(1501, {from: governance}),
      "exceed max percent"
    );
  });

  it('should have owner set burn percentage', async() => {
    await this.treasury.setBurnPercentage(1234, {from: governance});
    assert.equal((await this.treasury.burnPercentage()).toString(), 1234);
  });

  it('should revert if burn percentage threshold exceeded', async() => {
    await expectRevert(
      this.treasury.setBurnPercentage(10001, {from: governance}),
      "exceed max percent"
    );
  });

  it('should successfully deposit, with variables updated accordingly', async() => {
    // round 1 deposit
    await this.treasury.deposit(this.weth.address, 1000, {from: alice});
    let ecoFundBal = await this.treasury.ecoFundAmts(this.weth.address);
    let reportedBal = await this.treasury.balanceOf(this.weth.address);
    let wethBal = await this.weth.balanceOf(this.treasury.address);
    assert.isTrue(ecoFundBal.gt(ethers.constants.Zero));
    assert.isTrue((ecoFundBal.add(reportedBal)).eq(wethBal));

    // round 2 deposit
    await this.treasury.deposit(this.weth.address, 1000, {from: alice});
    let ecoFundBal2 = await this.treasury.ecoFundAmts(this.weth.address);
    let reportedBal2 = await this.treasury.balanceOf(this.weth.address);
    let wethBal2 = await this.weth.balanceOf(this.treasury.address);
    assert.isTrue(ecoFundBal2.gt(ecoFundBal));
    assert.isTrue(reportedBal2.gt(reportedBal));
    assert.isTrue(wethBal2.gt(wethBal));
    assert.isTrue((ecoFundBal2.add(reportedBal2)).eq(wethBal2));
  });

  it('should withdraw eco fund', async() => {
    let ecoFundAmt = await this.treasury.ecoFundAmts(this.weth.address);
    let currentGovBal = await this.weth.balanceOf(governance);
    await this.treasury.withdrawEcoFund(this.weth.address, ecoFundAmt);
    let newGovBal = await this.weth.balanceOf(governance); 
    assert.isTrue(newGovBal.gt(currentGovBal));
    assert.isTrue((await this.treasury.ecoFundAmts(this.weth.address)).isZero())
  });

  it('should fail converting X -> Y if X = boost or yCRV', async() => {
    await expectRevert(
      this.treasury.convertToDefaultToken(
        [this.boost.address, this.weth.address],
        1000
      ),
      "src can't be boost"
    );

    await expectRevert(
      this.treasury.convertToBoostToken(
        [this.boost.address, this.weth.address],
        1000
      ),
      "src can't be boost"
    );

    await expectRevert(
      this.treasury.convertToDefaultToken(
        [this.ycrv.address, this.weth.address],
        1000
      ),
      "src can't be defaultToken"
    );

    await expectRevert(
      this.treasury.convertToBoostToken(
        [this.ycrv.address, this.weth.address],
        1000
      ),
      "src can't be defaultToken"
    );
  });

  it('should fail converting X -> Y if Y != boost or yCRV', async() => {
    await expectRevert(
      this.treasury.convertToDefaultToken(
        [this.weth.address, this.boost.address],
        1000
      ),
      "dest not defaultToken"
    );

    await expectRevert(
      this.treasury.convertToBoostToken(
        [this.weth.address, this.ycrv.address],
        1000
      ),
      "dest not boostToken"
    );
  });

  it('should fail converting if there is insufficient funds', async() => {
    await expectRevert(
      this.treasury.convertToDefaultToken(
        [this.weth.address, this.ycrv.address],
        9999999
      ),
      "insufficient funds"
    );

    await expectRevert(
      this.treasury.convertToBoostToken(
        [this.weth.address, this.boost.address],
        9999999
      ),
      "insufficient funds"
    );
  });

  it('should be able to perform valid conversions', async() => {
    let wethBal = await this.weth.balanceOf(this.treasury.address);
    let ycrvBal = await this.ycrv.balanceOf(this.treasury.address);
    let boostBal = await this.boost.balanceOf(this.treasury.address);
    await this.treasury.convertToDefaultToken(
      [this.weth.address, this.ycrv.address],
      10
    );
    let newWethBal = await this.weth.balanceOf(this.treasury.address);
    assert.isTrue(wethBal.gt(newWethBal));
    wethBal = newWethBal;

    await this.treasury.convertToBoostToken(
      [this.weth.address, this.boost.address],
      10
    );
    newWethBal = await this.weth.balanceOf(this.treasury.address);
    assert.isTrue(wethBal.gt(newWethBal));
    assert.isTrue(ycrvBal.lt(await this.ycrv.balanceOf(this.treasury.address)));
    assert.isTrue(boostBal.lt(await this.boost.balanceOf(this.treasury.address)));
  });

  it("should only be able to set gov once", async() => {
    await this.treasury.setGov(this.gov.address, {from: governance});
    assert.equal((await this.treasury.gov()), this.gov.address);
    await expectRevert(
      this.treasury.setGov(alice, {from: governance}),
      "not authorized"
    );
  });

  it("should revert if treasury doesn't have sufficient funds for withdrawal", async() => {
    let tempTreasury = await Treasury.new(
      this.uniswapV2Router.address,
      this.ycrv.address,
      this.boost.address,
      governance,
      {from: governance}
    );

    await tempTreasury.setGov(governance,{from: governance});
    await this.ycrv.approve(tempTreasury.address, 1000, {from: alice});
    await tempTreasury.deposit(this.ycrv.address, 1000, {from: alice});
    await expectRevert(
      tempTreasury.withdraw(10000, alice, {from: governance}),
      "insufficient funds"
    );
  });

  it("should reward gov voters with boost tokens", async() => {
    await this.treasury.deposit(this.boost.address, 10000, {from: alice});
    await this.treasury.rewardVoters();
    assert.isTrue((await this.boost.balanceOf(this.gov.address)).gt(ethers.constants.Zero));
  });
});
